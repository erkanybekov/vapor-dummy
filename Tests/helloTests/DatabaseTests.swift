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
}
