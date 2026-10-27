@testable import hello
import Foundation
import Testing

// MARK: - Test Doubles

final class FakeChatConnection: ChatConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [ChatServerMessage] = []

    func send(_ message: ChatServerMessage) {
        lock.withLock { sent.append(message) }
    }

    func close() {}

    var frames: [ChatServerMessage] { lock.withLock { sent } }
    var types: [String] { frames.map(\.type) }

    var messageSeqs: [Int] {
        frames.compactMap { if case let .message(message) = $0 { message.seq } else { nil } }
    }

    var lastPresence: [String]? {
        frames.compactMap { if case let .presence(online) = $0 { online.map(\.username) } else { nil } }.last
    }

    var typingEvents: [String] {
        frames.compactMap { if case let .typing(user, isTyping) = $0 { "\(user.username):\(isTyping)" } else { nil } }
    }

    func clear() {
        lock.withLock { sent.removeAll() }
    }
}

private let alice = ChatUser(id: UUID(), username: "alice")
private let bob = ChatUser(id: UUID(), username: "bob")

private func message(_ seq: Int, by author: ChatUser = alice, in room: String = "general") -> ChatMessage {
    ChatMessage(seq: seq, room: room, author: author, text: "m\(seq)", sentAt: Date(), clientId: "c\(seq)")
}

private func connected(_ hub: ChatHub, _ user: ChatUser, room: String = "general", history: [ChatMessage] = []) async -> FakeChatConnection {
    let connection = FakeChatConnection()
    await hub.join(connection, user: user, room: room)
    await hub.start(connection, room: room, history: ChatHistory(messages: history, hasMore: false))
    return connection
}

// MARK: - Hub

@Suite("Chat Hub")
struct ChatHubTests {
    @Test("welcome comes first, with who is online and the history")
    func welcome() async throws {
        let hub = ChatHub()
        _ = await connected(hub, bob)
        let connection = await connected(hub, alice, history: [message(1), message(2)])

        guard case let .welcome(room, you, online, messages, hasMore) = try #require(connection.frames.first) else {
            Issue.record("first frame is \(connection.types)")
            return
        }
        #expect(room == "general")
        #expect(you == alice)
        #expect(online.map(\.username) == ["alice", "bob"])
        #expect(messages.map(\.seq) == [1, 2])
        #expect(!hasMore)
    }

    @Test("Messages sent while history loads arrive after welcome, without the ones history had")
    func heldMessages() async {
        let hub = ChatHub()
        let connection = FakeChatConnection()
        await hub.join(connection, user: alice, room: "general")
        await hub.broadcast(message(2))
        await hub.broadcast(message(3))
        #expect(connection.frames.isEmpty)

        await hub.start(connection, room: "general", history: ChatHistory(messages: [message(1), message(2)], hasMore: false))
        #expect(connection.types == ["welcome", "message"])
        #expect(connection.messageSeqs == [3])

        // A late live copy of a message that history already had is not repeated.
        await hub.broadcast(message(2))
        #expect(connection.messageSeqs == [3])
    }

    @Test("Messages reach everyone in the room, the sender included, and nobody outside it")
    func broadcastStaysInRoom() async {
        let hub = ChatHub()
        let a = await connected(hub, alice)
        let b = await connected(hub, bob)
        let elsewhere = await connected(hub, bob, room: "random")

        await hub.broadcast(message(1))
        #expect(a.messageSeqs == [1])
        #expect(b.messageSeqs == [1])
        #expect(elsewhere.messageSeqs.isEmpty)
    }

    @Test("Presence counts a user once, however many sockets they have")
    func presence() async {
        let hub = ChatHub()
        let a = await connected(hub, alice)
        let bobPhone = await connected(hub, bob)
        #expect(a.lastPresence == ["alice", "bob"])

        a.clear()
        let bobLaptop = await connected(hub, bob)
        #expect(a.lastPresence == nil)

        await hub.leave(bobPhone, room: "general")
        #expect(a.lastPresence == nil)
        await hub.leave(bobLaptop, room: "general")
        #expect(a.lastPresence == ["alice"])
    }

    @Test("Typing goes to the others only, and stops when the typist leaves")
    func typing() async {
        let hub = ChatHub()
        let a = await connected(hub, alice)
        let b = await connected(hub, bob)

        await hub.setTyping(b, room: "general", isTyping: true)
        await hub.setTyping(b, room: "general", isTyping: true)
        #expect(a.typingEvents == ["bob:true", "bob:true"])
        #expect(b.typingEvents.isEmpty)

        // Someone joining now sees who is typing.
        let late = await connected(hub, alice)
        #expect(late.typingEvents == ["bob:true"])

        await hub.leave(b, room: "general")
        #expect(a.typingEvents.last == "bob:false")
    }
}

// MARK: - Wire Format

@Suite("Chat wire format")
struct ChatWireFormatTests {
    private func decode(_ json: String) throws -> ChatClientMessage {
        try JSONDecoder().decode(ChatClientMessage.self, from: Data(json.utf8))
    }

    private func encode(_ message: ChatServerMessage) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Client frames decode by their type")
    func clientFrames() throws {
        #expect(try decode(#"{"type":"send","clientId":"a1","text":"hi"}"#) == .send(clientId: "a1", text: "hi"))
        #expect(try decode(#"{"type":"typing","isTyping":false}"#) == .typing(isTyping: false))
        #expect(try decode(#"{"type":"ping"}"#) == .ping)
        #expect(throws: DecodingError.self) { try decode(#"{"type":"shout","text":"hi"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"type":"send","text":"no id"}"#) }
    }

    @Test("Server frames carry their type and ISO 8601 dates")
    func serverFrames() throws {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let frame = try encode(.message(ChatMessage(seq: 7, room: "general", author: alice, text: "hi", sentAt: sentAt, clientId: "a1")))
        #expect(frame["type"] as? String == "message")
        let body = try #require(frame["message"] as? [String: Any])
        #expect(body["seq"] as? Int == 7)
        #expect(body["sentAt"] as? String == "2023-11-14T22:13:20Z")
        #expect(body["clientId"] as? String == "a1")

        let error = try encode(.error(code: .rateLimited, message: "slow down", clientId: nil))
        #expect(error["code"] as? String == "rate_limited")
        #expect(error["clientId"] == nil)
        #expect(try encode(.pong).keys.sorted() == ["type"])
    }

    @Test("Room names are URL-safe")
    func roomNames() {
        #expect(ChatLimits.isValidRoom("general"))
        #expect(ChatLimits.isValidRoom("ios-lesson-2"))
        #expect(!ChatLimits.isValidRoom(""))
        #expect(!ChatLimits.isValidRoom("General"))
        #expect(!ChatLimits.isValidRoom("a/b"))
        #expect(!ChatLimits.isValidRoom(String(repeating: "a", count: 33)))
    }
}
