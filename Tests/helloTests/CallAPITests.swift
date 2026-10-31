@testable import hello
import Foundation
import Testing
import VaporTesting

extension DatabaseTests {
    /// Call history in Postgres and the signaling socket on a real server.
    @Suite("Call API")
    struct CallAPITests {
        @Test("A restart finishes the calls it interrupted, with no made-up duration")
        func finishesInterruptedCalls() async throws {
            try await withTestApp { app in
                // No request yet: the first one would boot the app before the records exist.
                let users = try #require(app.userRepository)
                let user = try await users.create(User(email: uniqueEmail(), username: "tester", passwordHash: "unused"))
                let me = try #require(user.id)
                let repository = try #require(app.callRepository)

                func record(_ status: CallStatus, answeredAt: Date? = nil) -> CallRecord {
                    CallRecord(id: UUID(), callerId: me, calleeId: me, callerDeviceId: "phone", video: true, status: status, answeredAt: answeredAt)
                }
                let ringing = record(.ringing)
                let active = record(.active, answeredAt: Date())
                var ended = record(.active, answeredAt: Date())
                ended.finish(reason: .hangup)
                for call in [ringing, active, ended] {
                    try await repository.save(call)
                }

                try await app.asyncBoot()

                #expect(try await repository.finishInterrupted() == 0)
                let history = try await repository.history(for: me, limit: 10)
                let byId = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
                #expect(byId[ringing.id]?.status == .missed)
                #expect(byId[active.id]?.status == .completed)
                #expect(byId[active.id]?.endReason == .connectionLost)
                #expect(byId[active.id]?.answeredAt != nil)
                #expect(byId[active.id]?.duration == nil)
                #expect(byId[ended.id]?.endReason == .hangup)
            }
        }

        @Test("Invites are limited per account")
        func inviteLimit() async throws {
            try await withServer { app, port in
                let email = uniqueEmail()
                let tokens = try await register(app, email: email)
                let socket = try await TestSocket.connect("ws://127.0.0.1:\(port)/api/v1/calls/ws?deviceId=phone", token: tokens.accessToken, on: app)
                _ = try await socket.next("hello")

                // With no other device online a call to yourself ends at once, so nothing
                // but the limit stops the next invite, and each one writes a history row.
                for _ in 1...11 {
                    try await socket.send(["type": "call.invite", "calleeEmail": email])
                }

                let error = try await socket.next("error")
                #expect(error["code"] as? String == "rate_limited")
                #expect(socket.count("call.ended") == 10)
                try await socket.close()
            }
        }

        @Test("Logout closes the account's call and chat sockets")
        func logoutClosesSockets() async throws {
            try await withServer { app, port in
                let tokens = try await register(app, email: uniqueEmail())
                let call = try await TestSocket.connect("ws://127.0.0.1:\(port)/api/v1/calls/ws?deviceId=phone", token: tokens.accessToken, on: app)
                let chat = try await TestSocket.connect("ws://127.0.0.1:\(port)/api/v1/chat/ws", token: tokens.accessToken, on: app)
                _ = try await call.next("hello")
                _ = try await chat.next("welcome")

                try await app.testing().test(.POST, "api/v1/auth/logout", headers: ["Authorization": "Bearer \(tokens.accessToken)"]) { res in
                    #expect(res.status == .ok)
                }

                try await call.waitUntilClosed()
                try await chat.waitUntilClosed()
            }
        }
    }
}
