import Vapor
import Foundation

// MARK: - Request DTOs

struct LoginRequest: Content {
    let email: String
    let password: String
}

struct RegisterRequest: Content {
    let email: String
    let username: String
    let password: String
}

struct RefreshTokenRequest: Content {
    let refreshToken: String
}

// MARK: - Response DTOs

struct AuthResponse: Content {
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval
    let tokenType: String
    let user: UserResponse
}

struct UserResponse: Content {
    let id: UUID?
    let email: String
    let username: String
    let isActive: Bool
    let createdAt: Date?
    
    init(from user: User) {
        self.id = user.id
        self.email = user.email
        self.username = user.username
        self.isActive = user.isActive
        self.createdAt = user.createdAt
    }
}

struct MessageResponse: Content {
    let message: String
}
