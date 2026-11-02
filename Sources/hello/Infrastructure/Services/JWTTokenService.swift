import Vapor
import JWTKit
import Foundation
import Fluent

// MARK: - JWT Payload Structures
struct AccessTokenPayload: JWTPayload {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case issuedAt = "iat"
        case issuer = "iss"
        case audience = "aud"
        case tokenType = "type"
        case tokenId = "jti"
        case userEmail = "email"
        case username = "username"
    }

    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var issuedAt: IssuedAtClaim
    var issuer: IssuerClaim
    var audience: AudienceClaim
    var tokenType: String
    /// Lets a single token be revoked on logout. Tokens issued before it was added have none.
    var tokenId: String?
    var userEmail: String
    var username: String

    func verify(using key: some JWTAlgorithm) throws {
        try expiration.verifyNotExpired()
        guard tokenType == "access" else {
            throw JWTError.claimVerificationFailure(failedClaim: nil, reason: "not an access token")
        }
    }

    init(user: User, expiration: Date = Date().addingTimeInterval(3600)) {
        self.subject = SubjectClaim(value: user.id?.uuidString ?? "")
        self.expiration = ExpirationClaim(value: expiration)
        self.issuedAt = IssuedAtClaim(value: Date())
        self.issuer = IssuerClaim(value: "vapor-auth-service")
        self.audience = AudienceClaim(value: "vapor-client")
        self.tokenType = "access"
        self.tokenId = UUID().uuidString
        self.userEmail = user.email
        self.username = user.username
    }
}

struct RefreshTokenPayload: JWTPayload {
    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
        case issuedAt = "iat"
        case issuer = "iss"
        case audience = "aud"
        case tokenType = "type"
        case tokenId = "jti"
    }

    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var issuedAt: IssuedAtClaim
    var issuer: IssuerClaim
    var audience: AudienceClaim
    var tokenType: String
    var tokenId: String

    func verify(using key: some JWTAlgorithm) throws {
        try expiration.verifyNotExpired()
        guard tokenType == "refresh" else {
            throw JWTError.claimVerificationFailure(failedClaim: nil, reason: "not a refresh token")
        }
    }

    init(user: User, expiration: Date = Date().addingTimeInterval(604800)) { // 7 days
        self.subject = SubjectClaim(value: user.id?.uuidString ?? "")
        self.expiration = ExpirationClaim(value: expiration)
        self.issuedAt = IssuedAtClaim(value: Date())
        self.issuer = IssuerClaim(value: "vapor-auth-service")
        self.audience = AudienceClaim(value: "vapor-client")
        self.tokenType = "refresh"
        self.tokenId = UUID().uuidString
    }
}

// MARK: - Revoked Token Model (for token blacklisting)
final class RevokedTokenModel: Model, @unchecked Sendable {
    static let schema = "revoked_tokens"

    @ID(key: .id)
    var id: UUID?

    /// The token's `jti`; unique, so a refresh token can be consumed only once.
    @Field(key: "token_id")
    var tokenId: String

    @Field(key: "user_id")
    var userId: UUID

    @Timestamp(key: "revoked_at", on: .create)
    var revokedAt: Date?

    @Timestamp(key: "expires_at", on: .none)
    var expiresAt: Date?

    init() { }

    init(tokenId: String, userId: UUID, expiresAt: Date) {
        self.tokenId = tokenId
        self.userId = userId
        self.expiresAt = expiresAt
    }
}

// MARK: - JWT Token Service Implementation
final class JWTTokenService: TokenServiceProtocol, @unchecked Sendable {
    private let keys: JWTKeyCollection
    private let database: any Database

    init(keys: JWTKeyCollection, database: any Database) {
        self.keys = keys
        self.database = database
    }

    func generateAccessToken(for user: User) async throws -> String {
        try await keys.sign(AccessTokenPayload(user: user))
    }

    func generateRefreshToken(for user: User) async throws -> String {
        try await keys.sign(RefreshTokenPayload(user: user))
    }

    func validateAccessToken(_ token: String) async throws -> UUID {
        let payload = try await verify(token, as: AccessTokenPayload.self)
        guard let userId = UUID(uuidString: payload.subject.value) else {
            throw AuthError.invalidToken
        }
        if let tokenId = payload.tokenId, try await isRevoked(tokenId) {
            throw AuthError.tokenRevoked
        }
        return userId
    }

    func consumeRefreshToken(_ token: String) async throws -> UUID {
        let payload = try await verify(token, as: RefreshTokenPayload.self)
        guard let userId = UUID(uuidString: payload.subject.value) else {
            throw AuthError.invalidToken
        }
        // The insert is the check: token_id is unique, so of two concurrent
        // refreshes with the same token only one gets through.
        guard try await revoke(tokenId: payload.tokenId, userId: userId, expiresAt: payload.expiration.value) else {
            throw AuthError.tokenRevoked
        }
        return userId
    }

    func revokeToken(_ token: String) async throws {
        if let access = try? await keys.verify(token, as: AccessTokenPayload.self) {
            guard let tokenId = access.tokenId, let userId = UUID(uuidString: access.subject.value) else { return }
            _ = try await revoke(tokenId: tokenId, userId: userId, expiresAt: access.expiration.value)
        } else if let refresh = try? await keys.verify(token, as: RefreshTokenPayload.self) {
            guard let userId = UUID(uuidString: refresh.subject.value) else { return }
            _ = try await revoke(tokenId: refresh.tokenId, userId: userId, expiresAt: refresh.expiration.value)
        }
        // Anything else is already unusable: expired, forged or malformed.
    }

    func purgeExpiredRevocations() async throws {
        // An expired token fails its signature check anyway, so its row is no longer needed.
        try await RevokedTokenModel.query(on: database)
            .filter(\.$expiresAt < Date())
            .delete()
    }

    // MARK: - Private

    private func verify<Payload: JWTPayload>(_ token: String, as type: Payload.Type) async throws -> Payload {
        do {
            return try await keys.verify(token, as: type)
        } catch let error as JWTError where error.errorType == .claimVerificationFailure {
            if error.failedClaim is ExpirationClaim { throw AuthError.tokenExpired }
            throw AuthError.invalidToken
        } catch {
            throw AuthError.invalidToken
        }
    }

    private func isRevoked(_ tokenId: String) async throws -> Bool {
        try await RevokedTokenModel.query(on: database)
            .filter(\.$tokenId == tokenId)
            .first() != nil
    }

    /// Returns false if the token was already revoked.
    private func revoke(tokenId: String, userId: UUID, expiresAt: Date) async throws -> Bool {
        do {
            try await RevokedTokenModel(tokenId: tokenId, userId: userId, expiresAt: expiresAt).create(on: database)
            return true
        } catch let error as any DatabaseError where error.isConstraintFailure {
            return false
        }
    }
}

// MARK: - JWT Configuration Extensions
extension JWKIdentifier {
    static let `public` = JWKIdentifier(string: "public")
    static let `private` = JWKIdentifier(string: "private")
}

extension String {
    var bytes: [UInt8] {
        Data(self.utf8).map { $0 }
    }
}
