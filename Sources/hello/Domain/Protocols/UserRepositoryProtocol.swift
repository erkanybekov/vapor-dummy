import Foundation

// MARK: - Repository Protocol (Domain Layer)
public protocol UserRepositoryProtocol: Sendable {
    func find(by id: UUID) async throws -> User?
    func find(by email: String) async throws -> User?
    func create(_ user: User) async throws -> User
    func update(_ user: User) async throws -> User
    func delete(by id: UUID) async throws
}

// MARK: - Auth Service Protocol (Domain Layer)
public protocol AuthServiceProtocol: Sendable {
    func authenticate(credentials: UserCredentials) async throws -> AuthToken
    func refreshToken(_ refreshToken: String) async throws -> AuthToken
    func validateAccessToken(_ token: String) async throws -> User
    func revokeToken(_ token: String) async throws
}

// MARK: - Password Hasher Protocol
public protocol PasswordHasherProtocol: Sendable {
    func hash(_ password: String) throws -> String
    func verify(_ password: String, against hash: String) throws -> Bool
}

// MARK: - Token Service Protocol
public protocol TokenServiceProtocol: Sendable {
    func generateAccessToken(for user: User) async throws -> String
    func generateRefreshToken(for user: User) async throws -> String
    func validateToken(_ token: String) async throws -> UUID // Returns user ID
    func revokeToken(_ token: String) async throws
}
