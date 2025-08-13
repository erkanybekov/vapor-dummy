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
        case userEmail = "email"
        case username = "username"
    }
    
    var subject: SubjectClaim
    var expiration: ExpirationClaim
    var issuedAt: IssuedAtClaim
    var issuer: IssuerClaim
    var audience: AudienceClaim
    var tokenType: String
    var userEmail: String
    var username: String
    
    func verify(using key: some JWTAlgorithm) throws {
        try expiration.verifyNotExpired()
    }
    
    init(user: User, expiration: Date = Date().addingTimeInterval(3600)) {
        self.subject = SubjectClaim(value: user.id?.uuidString ?? "")
        self.expiration = ExpirationClaim(value: expiration)
        self.issuedAt = IssuedAtClaim(value: Date())
        self.issuer = IssuerClaim(value: "vapor-auth-service")
        self.audience = AudienceClaim(value: "vapor-client")
        self.tokenType = "access"
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
    private let application: Application
    private let database: any Database
    
    init(application: Application, database: any Database) {
        self.application = application
        self.database = database
    }
    
    func generateAccessToken(for user: User) async throws -> String {
        let payload = AccessTokenPayload(user: user)
        // Create a mock request to access JWT signing functionality
        let request = Request(application: application, method: .GET, url: URI(path: "/"), on: application.eventLoopGroup.next())
        return try await request.jwt.sign(payload)
    }
    
    func generateRefreshToken(for user: User) async throws -> String {
        let payload = RefreshTokenPayload(user: user)
        // Create a mock request to access JWT signing functionality
        let request = Request(application: application, method: .GET, url: URI(path: "/"), on: application.eventLoopGroup.next())
        return try await request.jwt.sign(payload)
    }
    
    func validateToken(_ token: String) async throws -> UUID {
        // First check if it's an access token
        do {
            // Create a mock request to access JWT verification functionality
            let request = Request(application: application, method: .GET, url: URI(path: "/"), on: application.eventLoopGroup.next())
            request.headers.bearerAuthorization = BearerAuthorization(token: token)
            let accessPayload = try await request.jwt.verify(as: AccessTokenPayload.self)
            let userIdString = accessPayload.subject.value
            
            guard let userId = UUID(uuidString: userIdString) else {
                throw AuthError.invalidToken
            }
            
            // Check if token is revoked
            let isRevoked = try await RevokedTokenModel
                .query(on: database)
                .filter(\.$tokenId == token)
                .first() != nil
            
            if isRevoked {
                throw AuthError.tokenRevoked
            }
            
            return userId
        } catch {
            // If access token validation fails, try refresh token
            do {
                // Create a mock request to access JWT verification functionality
                let request2 = Request(application: application, method: .GET, url: URI(path: "/"), on: application.eventLoopGroup.next())
                request2.headers.bearerAuthorization = BearerAuthorization(token: token)
                let refreshPayload = try await request2.jwt.verify(as: RefreshTokenPayload.self)
                let userIdString = refreshPayload.subject.value
                
                guard let userId = UUID(uuidString: userIdString) else {
                    throw AuthError.invalidToken
                }
                
                // Check if refresh token is revoked
                let isRevoked = try await RevokedTokenModel
                    .query(on: database)
                    .filter(\.$tokenId == refreshPayload.tokenId)
                    .first() != nil
                
                if isRevoked {
                    throw AuthError.tokenRevoked
                }
                
                return userId
            } catch {
                throw AuthError.invalidToken
            }
        }
    }
    
    func revokeToken(_ token: String) async throws {
        // Try to decode as access token first
        do {
            // Create a mock request to access JWT verification functionality
            let request = Request(application: application, method: .GET, url: URI(path: "/"), on: application.eventLoopGroup.next())
            request.headers.bearerAuthorization = BearerAuthorization(token: token)
            let accessPayload = try await request.jwt.verify(as: AccessTokenPayload.self)
            let userIdString = accessPayload.subject.value
            
            guard let userId = UUID(uuidString: userIdString) else {
                throw AuthError.invalidToken
            }
            
            let revokedToken = RevokedTokenModel(
                tokenId: token,
                userId: userId,
                expiresAt: accessPayload.expiration.value
            )
            
            try await revokedToken.save(on: database)
            return
        } catch {
            // Try as refresh token
            do {
                // Create a mock request to access JWT verification functionality
                let request = Request(application: application, method: .GET, url: URI(path: "/"), on: application.eventLoopGroup.next())
                request.headers.bearerAuthorization = BearerAuthorization(token: token)
                let refreshPayload = try await request.jwt.verify(as: RefreshTokenPayload.self)
                let userIdString = refreshPayload.subject.value
                
                guard let userId = UUID(uuidString: userIdString) else {
                    throw AuthError.invalidToken
                }
                
                let revokedToken = RevokedTokenModel(
                    tokenId: refreshPayload.tokenId,
                    userId: userId,
                    expiresAt: refreshPayload.expiration.value
                )
                
                try await revokedToken.save(on: database)
            } catch {
                throw AuthError.invalidToken
            }
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
