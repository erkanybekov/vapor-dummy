@testable import hello
import Foundation
import Testing
import VaporTesting

/// Tests against a real Postgres database: `vapor_test` on localhost by default, or
/// DATABASE_HOST / DATABASE_NAME / ... (see configure.swift). Every test drops the
/// tables when done, so all suites that use the database are nested here and run
/// one test at a time.
@Suite("Database", .serialized)
struct DatabaseTests {
    struct Tokens: Decodable {
        let accessToken: String
        let refreshToken: String
    }

    static let password = "Passw0rd123"

    static func withTestApp(_ test: (Application) async throws -> Void) async throws {
        try await withApp(configure: configure) { app in
            do {
                try await test(app)
            } catch {
                try? await app.autoRevert()
                throw error
            }
            try await app.autoRevert()
        }
    }

    /// For tests over real sockets: the server listens on a random local port.
    static func withServer(_ test: (Application, Int) async throws -> Void) async throws {
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

    static func uniqueEmail() -> String {
        "user-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    }

    static func register(_ app: Application, email: String, username: String = "tester") async throws -> Tokens {
        var tokens: Tokens?
        try await app.testing().test(.POST, "api/v1/auth/register", beforeRequest: { req in
            try req.content.encode(["email": email, "username": username, "password": password])
        }, afterResponse: { res in
            #expect(res.status == .ok)
            tokens = try res.content.decode(Tokens.self)
        })
        return try #require(tokens)
    }

    static func userId(_ app: Application, token: String) async throws -> UUID {
        var id: UUID?
        try await app.testing().test(.GET, "api/v1/auth/me", headers: ["Authorization": "Bearer \(token)"]) { res in
            id = try res.content.decode(UserResponse.self).id
        }
        return try #require(id)
    }
}
