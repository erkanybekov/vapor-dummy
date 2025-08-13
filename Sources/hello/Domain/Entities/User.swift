import Foundation

// MARK: - Domain Entity
public struct User {
    public let id: UUID?
    public let email: String
    public let username: String
    public let passwordHash: String
    public let isActive: Bool
    public let createdAt: Date?
    public let updatedAt: Date?
    
    public init(
        id: UUID? = nil,
        email: String,
        username: String,
        passwordHash: String,
        isActive: Bool = true,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.username = username
        self.passwordHash = passwordHash
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Domain Value Objects
public struct UserCredentials {
    public let email: String
    public let password: String
    
    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public struct AuthToken {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: TimeInterval
    public let tokenType: String
    
    public init(
        accessToken: String,
        refreshToken: String,
        expiresIn: TimeInterval,
        tokenType: String = "Bearer"
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
    }
}
