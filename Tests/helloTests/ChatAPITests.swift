@testable import hello
import Foundation
import Testing
import VaporTesting

/// A WebSocket client for tests: collects incoming JSON frames and waits for them.
private final class TestSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[String: Any]] = []
    private var socket: WebSocket?

    static func connect(_ url: String, token: String, on app: Application) async throws -> TestSocket {
        let client = TestSocket()
        try await WebSocket.connect(to: url, headers: ["Authorization": "Bearer \(token)"], on: app.eventLoopGroup) { ws in
            client.lock.withLock { client.socket = ws }
            ws.onText { _, text in
                guard let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
                client.lock.withLock { client.frames.append(frame) }
            }
        }.get()
        return client
    }

    func send(_ frame: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        let socket = try #require(lock.withLock { self.socket })
        try await socket.send(String(decoding: data, as: UTF8.self))
    }

    func close() async throws {
        try await lock.withLock { socket }?.close()
    }

    /// Removes and returns the first frame of this type, waiting up to `timeout` for it.
    func next(_ type: String, timeout: Duration = .seconds(5)) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let frame: [String: Any]? = lock.withLock {
                guard let index = frames.firstIndex(where: { $0["type"] as? String == type }) else { return nil }
                return frames.remove(at: index)
            }
            if let frame { return frame }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("No '\(type)' frame within \(timeout); got \(lock.withLock { frames.map { $0["type"] ?? "?" } })")
        throw CancellationError()
    }

    func count(_ type: String) -> Int {
        lock.withLock { frames.filter { $0["type"] as? String == type }.count }
    }
}

private func usernames(_ value: Any?) -> [String] {
    (value as? [[String: Any]] ?? []).compactMap { $0["username"] as? String }
}

private func texts(_ value: Any?) -> [String] {
    (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
}

extension DatabaseTests {
    /// The chat over a real socket: the server listens on a random local port.
    @Suite("Chat API")
    struct ChatAPITests {
        private func withServer(_ test: (Application, Int) async throws -> Void) async throws {
            try await withTestApp { app in
                try await app.asyncBoot()
                try await app.server.start(address: .hostname("127.0.0.1", port: 0))
                do {
                    let port = try #require(app.http.server.shared.localAddress?.port)
                    try await test(app, port)
                } catch {
                    await app.server.shutdown()
                    throw error
                }
                await app.server.shutdown()
            }
        }

        @Test("Two people chat live; a reconnect with ?after= catches up on what was missed")
        func liveChat() async throws {
            try await withServer { app, port in
                let alice = try await register(app, email: uniqueEmail(), username: "alice")
                let bob = try await register(app, email: uniqueEmail(), username: "bob")
                let url = "ws://127.0.0.1:\(port)/api/v1/chat/ws?room=lobby"

                let a = try await TestSocket.connect(url, token: alice.accessToken, on: app)
                let welcome = try await a.next("welcome")
                #expect(welcome["room"] as? String == "lobby")
                #expect(usernames(welcome["online"]) == ["alice"])
                #expect(texts(welcome["messages"]).isEmpty)

                let b = try await TestSocket.connect(url, token: bob.accessToken, on: app)
                _ = try await b.next("welcome")
                #expect(usernames(try await a.next("presence")["online"]) == ["alice", "bob"])

                try await b.send(["type": "typing", "isTyping": true])
                let typing = try await a.next("typing")
                #expect((typing["user"] as? [String: Any])?["username"] as? String == "bob")

                // The sender gets its own message back: that is the delivery confirmation.
                try await a.send(["type": "send", "clientId": "a-1", "text": "  Привет  "])
                let echo = try #require(try await a.next("message")["message"] as? [String: Any])
                let received = try #require(try await b.next("message")["message"] as? [String: Any])
                #expect(echo["text"] as? String == "Привет")
                #expect(echo["clientId"] as? String == "a-1")
                #expect(echo["seq"] as? Int == received["seq"] as? Int)
                let firstSeq = try #require(echo["seq"] as? Int)

                // A resend with the same clientId is confirmed to the sender, not stored again.
                try await a.send(["type": "send", "clientId": "a-1", "text": "Привет"])
                #expect(try await a.next("message")["message"].flatMap { ($0 as? [String: Any])?["seq"] as? Int } == firstSeq)

                try await a.close()
                #expect(usernames(try await b.next("presence")["online"]) == ["bob"])
                #expect(b.count("message") == 0)

                for (id, text) in [("b-1", "one"), ("b-2", "two")] {
                    try await b.send(["type": "send", "clientId": id, "text": text])
                    _ = try await b.next("message")
                }

                let again = try await TestSocket.connect(url + "&after=\(firstSeq)", token: alice.accessToken, on: app)
                let catchUp = try await again.next("welcome")
                #expect(texts(catchUp["messages"]) == ["one", "two"])
                #expect(catchUp["hasMore"] as? Bool == false)
                try await again.close()
                try await b.close()
            }
        }

        @Test("Bad frames get an error frame, and the connection stays open")
        func errors() async throws {
            try await withServer { app, port in
                let alice = try await register(app, email: uniqueEmail(), username: "alice")
                let a = try await TestSocket.connect("ws://127.0.0.1:\(port)/api/v1/chat/ws", token: alice.accessToken, on: app)
                _ = try await a.next("welcome")

                try await a.send(["type": "shout"])
                #expect(try await a.next("error")["code"] as? String == "bad_request")

                try await a.send(["type": "send", "clientId": "x", "text": String(repeating: "a", count: 2001)])
                let tooLong = try await a.next("error")
                #expect(tooLong["code"] as? String == "invalid_message")
                #expect(tooLong["clientId"] as? String == "x")

                try await a.send(["type": "ping"])
                _ = try await a.next("pong")
                try await a.close()
            }
        }

        @Test("The upgrade needs a token and a valid room")
        func upgradeChecks() async throws {
            try await withTestApp { app in
                try await app.testing().test(.GET, "api/v1/chat/ws") { res in
                    #expect(res.status == .unauthorized)
                    // The client must not reuse this connection for its next attempt.
                    #expect(res.headers[.connection].contains("close"))
                }
                let tokens = try await register(app, email: uniqueEmail())
                try await app.testing().test(.GET, "api/v1/chat/ws?room=Bad%20Room&token=\(tokens.accessToken)") { res in
                    #expect(res.status == .badRequest)
                }
            }
        }

        @Test("Older history pages through REST, newest page first")
        func historyPages() async throws {
            try await withTestApp { app in
                let email = uniqueEmail()
                let tokens = try await register(app, email: email)
                let repository = try #require(app.chatRepository)
                // Messages need a real author row for the foreign key.
                let user = try #require(try await app.userRepository?.find(by: email))
                let writer = ChatUser(id: try #require(user.id), username: user.username)
                var seqs: [Int] = []
                for n in 1...5 {
                    seqs.append(try await repository.save(room: "general", author: writer, text: "m\(n)", clientId: "c\(n)").message.seq)
                }

                let page = try await repository.history(room: "general", after: nil, before: seqs[3], limit: 2)
                #expect(page.messages.map(\.text) == ["m2", "m3"])
                #expect(page.hasMore)

                try await app.testing().test(.GET, "api/v1/chat/rooms/general/messages?before=\(seqs[1])", headers: ["Authorization": "Bearer \(tokens.accessToken)"]) { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("\"m1\""))
                    #expect(!res.body.string.contains("\"m2\""))
                }
                try await app.testing().test(.GET, "api/v1/chat/rooms/general/messages") { res in
                    #expect(res.status == .unauthorized)
                }
            }
        }
    }
}
