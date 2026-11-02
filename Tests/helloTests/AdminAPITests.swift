@testable import hello
import Foundation
import Testing
import VaporTesting

extension DatabaseTests {
    /// The admin API: who gets in, and what blocking does to an account.
    @Suite("Admin API")
    struct AdminAPITests {
        private struct Account {
            let id: UUID
            let email: String
            let tokens: Tokens
            var auth: HTTPHeaders { ["Authorization": "Bearer \(tokens.accessToken)"] }
        }

        private struct UserList: Decodable {
            let users: [AdminUserResponse]
            let pagination: PaginationMeta
        }

        private struct CallList: Decodable {
            let calls: [AdminCallResponse]
            let pagination: PaginationMeta
        }

        private func account(_ app: Application, _ username: String, admin: Bool = false) async throws -> Account {
            let email = uniqueEmail()
            let tokens = try await register(app, email: email, username: username)
            let id = try await userId(app, token: tokens.accessToken)
            if admin {
                let repository = try #require(app.userRepository)
                let user = try #require(try await repository.find(by: id))
                _ = try await repository.update(user.with(isAdmin: true))
            }
            return Account(id: id, email: email, tokens: tokens)
        }

        private func status(_ app: Application, _ method: HTTPMethod, _ path: String, as account: Account? = nil) async throws -> HTTPStatus {
            var status: HTTPStatus = .internalServerError
            try await app.testing().test(method, path, headers: account?.auth ?? [:]) { res in
                status = res.status
            }
            return status
        }

        private func change(_ app: Application, _ id: UUID, isActive: Bool? = nil, isAdmin: Bool? = nil, as admin: Account) async throws -> HTTPStatus {
            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.PATCH, "api/v1/admin/users/\(id)", headers: admin.auth, beforeRequest: { req in
                try req.content.encode(AdminUpdateUserRequest(isActive: isActive, isAdmin: isAdmin))
            }, afterResponse: { res in
                status = res.status
            })
            return status
        }

        private func users(_ app: Application, query: String = "", as admin: Account) async throws -> UserList {
            var list: UserList?
            try await app.testing().test(.GET, "api/v1/admin/users?\(query)", headers: admin.auth) { res in
                #expect(res.status == .ok)
                list = try res.content.decode(UserList.self)
            }
            return try #require(list)
        }

        private func stats(_ app: Application, as admin: Account) async throws -> AdminStatsResponse {
            var stats: AdminStatsResponse?
            try await app.testing().test(.GET, "api/v1/admin/stats", headers: admin.auth) { res in
                stats = try res.content.decode(AdminStatsResponse.self)
            }
            return try #require(stats)
        }

        private func login(_ app: Application, _ account: Account) async throws -> HTTPStatus {
            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.POST, "api/v1/auth/login", beforeRequest: { req in
                try req.content.encode(["email": account.email, "password": password])
            }, afterResponse: { res in
                status = res.status
            })
            return status
        }

        private func callSocket(_ app: Application, port: Int, for account: Account) async throws -> TestSocket {
            let socket = try await TestSocket.connect("ws://127.0.0.1:\(port)/api/v1/calls/ws?deviceId=phone", token: account.tokens.accessToken, on: app)
            _ = try await socket.next("hello")
            return socket
        }

        // MARK: - Tests

        @Test("Every route is closed to guests and to regular users")
        func onlyAdminsGetIn() async throws {
            try await withTestApp { app in
                let user = try await account(app, "User")
                let admin = try await account(app, "Admin", admin: true)
                let routes: [(HTTPMethod, String)] = [
                    (.GET, "api/v1/admin/stats"),
                    (.GET, "api/v1/admin/users"),
                    (.GET, "api/v1/admin/calls"),
                    (.PATCH, "api/v1/admin/users/\(user.id)"),
                ]

                for (method, path) in routes {
                    #expect(try await status(app, method, path) == .unauthorized)
                    #expect(try await status(app, method, path, as: user) == .forbidden)
                }
                for (method, path) in routes where method == .GET {
                    #expect(try await status(app, method, path, as: admin) == .ok)
                }
            }
        }

        @Test("Registering cannot make you an admin")
        func noSelfPromotion() async throws {
            struct Registration: Content {
                let email, username, password: String
                let isAdmin: Bool
            }
            try await withTestApp { app in
                var token: String?
                try await app.testing().test(.POST, "api/v1/auth/register", beforeRequest: { req in
                    try req.content.encode(Registration(email: uniqueEmail(), username: "Mallory", password: password, isAdmin: true))
                }, afterResponse: { res in
                    #expect(res.status == .ok)
                    let response = try res.content.decode(AuthResponse.self)
                    #expect(response.user.isAdmin == false)
                    token = response.accessToken
                })

                let id = try await userId(app, token: try #require(token))
                #expect(try await app.userRepository?.find(by: id)?.isAdmin == false)
            }
        }

        @Test("Granting and revoking work on the next request, with the same token")
        func roleChangesAtOnce() async throws {
            try await withTestApp { app in
                let admin = try await account(app, "Admin", admin: true)
                let user = try await account(app, "User")

                #expect(try await change(app, user.id, isAdmin: true, as: admin) == .ok)
                #expect(try await status(app, .GET, "api/v1/admin/stats", as: user) == .ok)

                #expect(try await change(app, user.id, isAdmin: false, as: admin) == .ok)
                #expect(try await status(app, .GET, "api/v1/admin/stats", as: user) == .forbidden)
            }
        }

        @Test("Users come newest first and paged, and search ignores case and wildcards")
        func listAndSearch() async throws {
            try await withTestApp { app in
                let admin = try await account(app, "Admin", admin: true)
                let alice = try await account(app, "Alice")
                let maria = try await account(app, "Мария")

                let everyone = try await users(app, as: admin)
                #expect(everyone.users.map(\.id) == [maria.id, alice.id, admin.id])
                #expect(everyone.pagination.total == 3)

                let second = try await users(app, query: "page=2&limit=2", as: admin)
                #expect(second.users.map(\.id) == [admin.id])
                #expect(second.pagination.totalPages == 2)

                #expect(try await users(app, query: "search=ALI", as: admin).users.map(\.id) == [alice.id])
                #expect(try await users(app, query: "search=%D0%BC%D0%B0%D1%80", as: admin).users.map(\.id) == [maria.id])
                #expect(try await users(app, query: "search=\(alice.email.prefix(13))", as: admin).users.map(\.id) == [alice.id])
                // Literal characters here, not LIKE wildcards that would match everyone.
                #expect(try await users(app, query: "search=%25", as: admin).users.isEmpty)
                #expect(try await users(app, query: "search=_", as: admin).users.isEmpty)
            }
        }

        @Test("The user list never carries a password hash")
        func noPasswordHash() async throws {
            try await withTestApp { app in
                let admin = try await account(app, "Admin", admin: true)
                try await app.testing().test(.GET, "api/v1/admin/users", headers: admin.auth) { res in
                    #expect(res.body.string.lowercased().contains("password") == false)
                    #expect(res.body.string.contains("$2") == false)
                }
            }
        }

        @Test("Blocking cuts an account off at once, and unblocking lets it back in")
        func blockAndUnblock() async throws {
            try await withServer { app, port in
                let admin = try await account(app, "Admin", admin: true)
                let user = try await account(app, "User")
                let call = try await callSocket(app, port: port, for: user)
                let chat = try await TestSocket.connect("ws://127.0.0.1:\(port)/api/v1/chat/ws", token: user.tokens.accessToken, on: app)
                _ = try await chat.next("welcome")

                #expect(try await change(app, user.id, isActive: false, as: admin) == .ok)

                try await call.waitUntilClosed()
                try await chat.waitUntilClosed()
                #expect(try await status(app, .GET, "api/v1/auth/me", as: user) == .unauthorized)
                #expect(try await login(app, user) == .forbidden)
                try await app.testing().test(.POST, "api/v1/auth/refresh", beforeRequest: { req in
                    try req.content.encode(["refreshToken": user.tokens.refreshToken])
                }, afterResponse: { res in
                    #expect(res.status == .forbidden)
                })
                await #expect(throws: (any Error).self) {
                    _ = try await TestSocket.connect("ws://127.0.0.1:\(port)/api/v1/calls/ws?deviceId=phone", token: user.tokens.accessToken, on: app)
                }

                #expect(try await change(app, user.id, isActive: true, as: admin) == .ok)
                #expect(try await login(app, user) == .ok)
            }
        }

        @Test("An admin cannot change their own account, and targets are checked")
        func invalidChanges() async throws {
            try await withTestApp { app in
                let admin = try await account(app, "Admin", admin: true)

                #expect(try await change(app, admin.id, isActive: false, as: admin) == .badRequest)
                #expect(try await change(app, admin.id, isAdmin: false, as: admin) == .badRequest)
                #expect(try await status(app, .GET, "api/v1/admin/stats", as: admin) == .ok)

                #expect(try await change(app, UUID(), isActive: false, as: admin) == .notFound)
                #expect(try await status(app, .PATCH, "api/v1/admin/users/not-a-uuid", as: admin) == .badRequest)
            }
        }

        @Test("Stats and the call list show what is happening on the server")
        func statsAndCalls() async throws {
            try await withServer { app, port in
                let admin = try await account(app, "Admin", admin: true)
                let alice = try await account(app, "Alice")
                let bob = try await account(app, "Bob")
                let aliceSocket = try await callSocket(app, port: port, for: alice)
                let bobSocket = try await callSocket(app, port: port, for: bob)

                try await aliceSocket.send(["type": "call.invite", "calleeEmail": bob.email, "video": true])
                let callId = try #require(try await bobSocket.next("call.incoming")["callId"] as? String)
                try await bobSocket.send(["type": "call.accept", "callId": callId])
                _ = try await aliceSocket.next("call.accepted")

                let live = try await stats(app, as: admin)
                #expect(live.users == 3)
                #expect(live.activeUsers == 3)
                #expect(live.admins == 1)
                #expect(live.onlineUsers == 2)
                #expect(live.activeCalls == 1)
                #expect(live.callsLastDay == 1)
                #expect(try await users(app, as: admin).users.filter(\.online).count == 2)

                try await aliceSocket.send(["type": "call.hangup", "callId": callId])
                _ = try await bobSocket.next("call.ended")
                #expect(try await stats(app, as: admin).activeCalls == 0)

                // History is written in the background.
                var call: AdminCallResponse?
                let deadline = ContinuousClock.now + .seconds(5)
                while call?.status != .completed, ContinuousClock.now < deadline {
                    try await app.testing().test(.GET, "api/v1/admin/calls", headers: admin.auth) { res in
                        call = try res.content.decode(CallList.self).calls.first
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(call?.status == .completed)
                #expect(call?.callerUsername == "Alice")
                #expect(call?.calleeUsername == "Bob")
                #expect(call?.video == true)

                try await aliceSocket.close()
                try await bobSocket.close()
            }
        }

        @Test("A huge page number is just an empty page")
        func hugePage() async throws {
            try await withTestApp { app in
                let admin = try await account(app, "Admin", admin: true)
                let query = "page=\(Int.max)&limit=100"
                #expect(try await users(app, query: query, as: admin).users.isEmpty)
                #expect(try await status(app, .GET, "api/v1/admin/calls?\(query)", as: admin) == .ok)
            }
        }

        @Test("grant-admin changes an existing account and refuses an unknown email")
        func grantAdminCommand() async throws {
            func run(_ arguments: String..., app: Application) async throws {
                var context = CommandContext(console: app.console, input: CommandInput(arguments: ["hello"] + arguments))
                context.application = app
                try await GrantAdminCommand().run(using: &context)
            }

            try await withTestApp { app in
                let user = try await account(app, "User")

                try await run(user.email.uppercased(), app: app)
                #expect(try await status(app, .GET, "api/v1/admin/stats", as: user) == .ok)

                try await run(user.email, "--revoke", app: app)
                #expect(try await status(app, .GET, "api/v1/admin/stats", as: user) == .forbidden)

                try await run(uniqueEmail(), app: app)
                #expect(try await app.userRepository?.counts().admins == 0)
            }
        }
    }
}
