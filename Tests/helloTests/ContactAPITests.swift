@testable import hello
import Foundation
import Testing
import VaporTesting

extension DatabaseTests {
    /// Contacts and blocks over REST, and how they act on the call socket.
    @Suite("Contact API")
    struct ContactAPITests {
        private struct Account {
            let id: UUID
            let email: String
            let token: String
            var auth: HTTPHeaders { ["Authorization": "Bearer \(token)"] }
        }

        private struct ContactList: Decodable {
            let contacts: [ContactResponse]
        }

        private struct BlockList: Decodable {
            let users: [CallUser]
        }

        private func account(_ app: Application, _ username: String) async throws -> Account {
            let email = uniqueEmail()
            let tokens = try await register(app, email: email, username: username)
            return Account(id: try await userId(app, token: tokens.accessToken), email: email, token: tokens.accessToken)
        }

        private func add(_ app: Application, email: String, to account: Account) async throws -> HTTPStatus {
            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.POST, "api/v1/contacts", headers: account.auth, beforeRequest: { req in
                try req.content.encode(["email": email])
            }, afterResponse: { res in
                status = res.status
            })
            return status
        }

        private func contacts(_ app: Application, of account: Account) async throws -> [ContactResponse] {
            var list: [ContactResponse] = []
            try await app.testing().test(.GET, "api/v1/contacts", headers: account.auth) { res in
                list = try res.content.decode(ContactList.self).contacts
            }
            return list
        }

        private func blocked(_ app: Application, by account: Account) async throws -> [CallUser] {
            var users: [CallUser] = []
            try await app.testing().test(.GET, "api/v1/blocks", headers: account.auth) { res in
                users = try res.content.decode(BlockList.self).users
            }
            return users
        }

        private func send(_ app: Application, _ method: HTTPMethod, _ path: String, as account: Account) async throws -> HTTPStatus {
            var status: HTTPStatus = .internalServerError
            try await app.testing().test(method, path, headers: account.auth) { res in
                status = res.status
            }
            return status
        }

        private func socket(_ app: Application, port: Int, for account: Account) async throws -> TestSocket {
            let socket = try await TestSocket.connect("ws://127.0.0.1:\(port)/api/v1/calls/ws?deviceId=phone", token: account.token, on: app)
            _ = try await socket.next("hello")
            return socket
        }

        /// A socket closes asynchronously on the server, so the first contact's status settles a moment later.
        private func waitForOnline(_ expected: Bool, in list: Account, _ app: Application) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while try await contacts(app, of: list).first?.online != expected {
                guard ContinuousClock.now < deadline else {
                    Issue.record("The contact's online status is still not \(expected)")
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        // MARK: - Tests

        @Test("Contacts are one-way, and adding someone twice changes nothing")
        func addAndRemove() async throws {
            try await withTestApp { app in
                let alice = try await account(app, "Alice")
                let bob = try await account(app, "Bob")

                #expect(try await add(app, email: bob.email.uppercased(), to: alice) == .ok)
                #expect(try await add(app, email: bob.email, to: alice) == .ok)

                let list = try await contacts(app, of: alice)
                #expect(list.map(\.id) == [bob.id])
                #expect(list.first?.username == "Bob")
                #expect(try await contacts(app, of: bob).isEmpty)

                #expect(try await send(app, .DELETE, "api/v1/contacts/\(bob.id)", as: alice) == .ok)
                #expect(try await contacts(app, of: alice).isEmpty)
            }
        }

        @Test("Contacts come sorted by name")
        func sorted() async throws {
            try await withTestApp { app in
                let alice = try await account(app, "Alice")
                for name in ["zoe", "Bob", "мария"] {
                    let other = try await account(app, name)
                    #expect(try await add(app, email: other.email, to: alice) == .ok)
                }
                let names = try await contacts(app, of: alice).map(\.username)
                #expect(names == ["Bob", "zoe", "мария"])
            }
        }

        @Test("You cannot add an unknown user or yourself, or use a malformed id")
        func invalidTargets() async throws {
            try await withTestApp { app in
                let alice = try await account(app, "Alice")
                #expect(try await add(app, email: uniqueEmail(), to: alice) == .notFound)
                #expect(try await add(app, email: alice.email, to: alice) == .badRequest)
                #expect(try await send(app, .PUT, "api/v1/blocks/\(alice.id)", as: alice) == .badRequest)
                #expect(try await send(app, .PUT, "api/v1/blocks/\(UUID())", as: alice) == .notFound)
                #expect(try await send(app, .DELETE, "api/v1/contacts/not-a-uuid", as: alice) == .badRequest)
            }
        }

        @Test("Looking up emails is rate limited per account")
        func addIsRateLimited() async throws {
            try await withTestApp { app in
                let alice = try await account(app, "Alice")
                for _ in 1...30 {
                    #expect(try await add(app, email: uniqueEmail(), to: alice) == .notFound)
                }
                #expect(try await add(app, email: uniqueEmail(), to: alice) == .tooManyRequests)
            }
        }

        @Test("Contacts need a valid access token")
        func requiresAuth() async throws {
            try await withTestApp { app in
                for path in ["api/v1/contacts", "api/v1/blocks"] {
                    try await app.testing().test(.GET, path) { res in
                        #expect(res.status == .unauthorized)
                    }
                }
            }
        }

        @Test("Online status shows only between mutual contacts, and they hear about changes")
        func mutualPresence() async throws {
            try await withServer { app, port in
                let alice = try await account(app, "Alice")
                let bob = try await account(app, "Bob")
                let carol = try await account(app, "Carol")
                let aliceSocket = try await socket(app, port: port, for: alice)
                let carolSocket = try await socket(app, port: port, for: carol)

                // One-way so far: Bob going online stays hidden from Alice.
                #expect(try await add(app, email: bob.email, to: alice) == .ok)
                _ = try await aliceSocket.next("contacts.changed")
                let hiddenSocket = try await socket(app, port: port, for: bob)
                #expect(try await contacts(app, of: alice).first?.online == false)
                try await hiddenSocket.close()

                // Bob adds her back while offline, and Alice is told.
                #expect(try await add(app, email: alice.email, to: bob) == .ok)
                _ = try await aliceSocket.next("contacts.changed")

                let bobSocket = try await socket(app, port: port, for: bob)
                _ = try await aliceSocket.next("contacts.changed")
                try await waitForOnline(true, in: alice, app)

                try await bobSocket.close()
                _ = try await aliceSocket.next("contacts.changed")
                try await waitForOnline(false, in: alice, app)

                #expect(carolSocket.count("contacts.changed") == 0)
                try await aliceSocket.close()
                try await carolSocket.close()
            }
        }

        @Test("A blocked caller just sees the callee as unavailable, until unblocked")
        func blockedCaller() async throws {
            try await withServer { app, port in
                let alice = try await account(app, "Alice")
                let bob = try await account(app, "Bob")
                #expect(try await add(app, email: bob.email, to: alice) == .ok)
                #expect(try await add(app, email: alice.email, to: bob) == .ok)
                let aliceSocket = try await socket(app, port: port, for: alice)
                let bobSocket = try await socket(app, port: port, for: bob)

                #expect(try await contacts(app, of: bob).first?.online == true)
                #expect(try await send(app, .PUT, "api/v1/blocks/\(bob.id)", as: alice) == .ok)
                #expect(try await send(app, .PUT, "api/v1/blocks/\(bob.id)", as: alice) == .ok)

                // Off her list and on the blocked one; she also disappears from his view.
                #expect(try await contacts(app, of: alice).isEmpty)
                #expect(try await blocked(app, by: alice).map(\.id) == [bob.id])
                #expect(try await contacts(app, of: bob).first?.online == false)
                #expect(try await add(app, email: bob.email, to: alice) == .conflict)

                try await bobSocket.send(["type": "call.invite", "calleeEmail": alice.email])
                let ended = try await bobSocket.next("call.ended")
                #expect(ended["reason"] as? String == "unavailable")
                #expect(aliceSocket.count("call.incoming") == 0)
                let history = try #require(app.callRepository)
                #expect(try await history.history(for: alice.id, limit: 10).isEmpty)

                #expect(try await send(app, .DELETE, "api/v1/blocks/\(bob.id)", as: alice) == .ok)
                #expect(try await blocked(app, by: alice).isEmpty)
                try await bobSocket.send(["type": "call.invite", "calleeEmail": alice.email])
                _ = try await aliceSocket.next("call.incoming")

                try await aliceSocket.close()
                try await bobSocket.close()
            }
        }
    }
}
