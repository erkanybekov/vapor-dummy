@testable import hello
import Foundation
import Testing
import VaporTesting

extension DatabaseTests {
    /// End-to-end tests of the auth HTTP API.
    @Suite("Auth API")
    struct AuthAPITests {
        private func login(_ app: Application, email: String, password: String, ip: String? = nil) async throws -> HTTPStatus {
            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.POST, "api/v1/auth/login", beforeRequest: { req in
                if let ip { req.headers.replaceOrAdd(name: .xForwardedFor, value: ip) }
                try req.content.encode(["email": email, "password": password])
            }, afterResponse: { res in
                status = res.status
            })
            return status
        }

        private func refresh(_ app: Application, with token: String) async throws -> (HTTPStatus, Tokens?) {
            var result: (HTTPStatus, Tokens?) = (.internalServerError, nil)
            try await app.testing().test(.POST, "api/v1/auth/refresh", beforeRequest: { req in
                try req.content.encode(["refreshToken": token])
            }, afterResponse: { res in
                result = (res.status, res.status == .ok ? try res.content.decode(Tokens.self) : nil)
            })
            return result
        }

        private func me(_ app: Application, bearer token: String) async throws -> HTTPStatus {
            var status: HTTPStatus = .internalServerError
            try await app.testing().test(.GET, "api/v1/auth/me", headers: ["Authorization": "Bearer \(token)"]) { res in
                status = res.status
            }
            return status
        }

        // MARK: - Tests

        @Test("Health check reports a connected database")
        func health() async throws {
            try await withTestApp { app in
                try await app.testing().test(.GET, "api/v1/health") { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("connected"))
                }
            }
        }

        @Test("Register, then sign in only with the right password")
        func registerAndLogin() async throws {
            try await withTestApp { app in
                let email = uniqueEmail()
                let tokens = try await register(app, email: email)
                #expect(try await me(app, bearer: tokens.accessToken) == .ok)

                #expect(try await login(app, email: email, password: "Wr0ngPassword") == .unauthorized)
                #expect(try await login(app, email: email.uppercased(), password: DatabaseTests.password) == .ok)
                #expect(try await login(app, email: "not-an-email", password: DatabaseTests.password) == .unauthorized)
            }
        }

        @Test("Registration rejects a taken email and a weak password")
        func registrationValidation() async throws {
            try await withTestApp { app in
                let email = uniqueEmail()
                _ = try await register(app, email: email)

                for (email, password, expected) in [(email, DatabaseTests.password, HTTPStatus.conflict), (uniqueEmail(), "weak", .badRequest)] {
                    try await app.testing().test(.POST, "api/v1/auth/register", beforeRequest: { req in
                        try req.content.encode(["email": email, "username": "tester", "password": password])
                    }, afterResponse: { res in
                        #expect(res.status == expected)
                    })
                }
            }
        }

        @Test("A refresh token works once and is replaced by a new one")
        func refreshRotates() async throws {
            try await withTestApp { app in
                let tokens = try await register(app, email: uniqueEmail())

                let (status, rotated) = try await refresh(app, with: tokens.refreshToken)
                #expect(status == .ok)
                let next = try #require(rotated)
                #expect(try await me(app, bearer: next.accessToken) == .ok)

                #expect(try await refresh(app, with: tokens.refreshToken).0 == .unauthorized)
                #expect(try await refresh(app, with: next.refreshToken).0 == .ok)
            }
        }

        @Test("Tokens only work for their own purpose")
        func tokenTypesAreNotInterchangeable() async throws {
            try await withTestApp { app in
                let tokens = try await register(app, email: uniqueEmail())

                #expect(try await refresh(app, with: tokens.accessToken).0 == .unauthorized)
                #expect(try await me(app, bearer: tokens.refreshToken) == .unauthorized)
                #expect(try await me(app, bearer: "not-a-jwt") == .unauthorized)
            }
        }

        @Test("Logout revokes the access and the refresh token")
        func logoutRevokesTokens() async throws {
            try await withTestApp { app in
                let tokens = try await register(app, email: uniqueEmail())

                try await app.testing().test(.POST, "api/v1/auth/logout", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: tokens.accessToken)
                    try req.content.encode(["refreshToken": tokens.refreshToken])
                }, afterResponse: { res in
                    #expect(res.status == .ok)
                })

                #expect(try await me(app, bearer: tokens.accessToken) == .unauthorized)
                #expect(try await refresh(app, with: tokens.refreshToken).0 == .unauthorized)
                try await app.testing().test(.GET, "api/v1/calls/ws?token=\(tokens.accessToken)") { res in
                    #expect(res.status == .unauthorized)
                }
            }
        }

        @Test("Five wrong passwords lock the account for a while, from any IP")
        func failedLoginsLockAccount() async throws {
            try await withTestApp { app in
                let email = uniqueEmail()
                _ = try await register(app, email: email)

                for attempt in 1...5 {
                    #expect(try await login(app, email: email, password: "Wr0ngPassword", ip: "198.51.100.\(attempt)") == .unauthorized)
                }
                #expect(try await login(app, email: email, password: DatabaseTests.password, ip: "198.51.100.99") == .tooManyRequests)
            }
        }

        @Test("Registration is rate limited per client IP, which forged entries cannot change")
        func registrationRateLimit() async throws {
            try await withTestApp { app in
                /// As Render delivers it: what the client forged, then the client's address, then a proxy.
                func attempt(from ip: String, forged: String) async throws -> (HTTPStatus, String?) {
                    var result: (HTTPStatus, String?) = (.internalServerError, nil)
                    try await app.testing().test(.POST, "api/v1/auth/register", beforeRequest: { req in
                        req.headers.replaceOrAdd(name: .xForwardedFor, value: "\(forged), \(ip), 10.9.9.9")
                        // A weak password fails fast, without hashing; it still counts.
                        try req.content.encode(["email": uniqueEmail(), "username": "tester", "password": "weak"])
                    }, afterResponse: { res in
                        result = (res.status, res.headers.first(name: "Retry-After"))
                    })
                    return result
                }

                for n in 1...10 {
                    // A different forged entry each time must not reset the count.
                    #expect(try await attempt(from: "203.0.113.7", forged: "1.1.1.\(n)").0 == .badRequest)
                }
                let (status, retryAfter) = try await attempt(from: "203.0.113.7", forged: "1.1.1.99")
                #expect(status == .tooManyRequests)
                #expect(retryAfter.flatMap(Int.init).map { $0 > 0 } == true)
                #expect(try await attempt(from: "203.0.113.8", forged: "1.1.1.1").0 == .badRequest)
            }
        }

        @Test("Todos need a valid access token")
        func todosRequireAuth() async throws {
            try await withTestApp { app in
                try await app.testing().test(.GET, "api/v1/todos") { res in
                    #expect(res.status == .unauthorized)
                }

                let tokens = try await register(app, email: uniqueEmail())
                let auth: HTTPHeaders = ["Authorization": "Bearer \(tokens.accessToken)"]
                try await app.testing().test(.POST, "api/v1/todos", headers: auth, beforeRequest: { req in
                    try req.content.encode(["title": "Buy milk"])
                }, afterResponse: { res in
                    #expect(res.status == .ok || res.status == .created)
                })
                try await app.testing().test(.GET, "api/v1/todos", headers: auth) { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Buy milk"))
                }
            }
        }

        @Test("Unknown API paths are 404, not the web app")
        func unknownAPIPath() async throws {
            try await withTestApp { app in
                try await app.testing().test(.GET, "api/v1/nope") { res in
                    #expect(res.status == .notFound)
                }
            }
        }
    }
}
