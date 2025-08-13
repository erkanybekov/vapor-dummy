import Foundation

// MARK: - Domain Errors
public enum AuthError: Error, LocalizedError {
    case invalidCredentials
    case userNotFound
    case userNotActive
    case emailAlreadyExists
    case invalidToken
    case tokenExpired
    case tokenRevoked
    case passwordTooWeak
    case invalidEmail
    
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password"
        case .userNotFound:
            return "User not found"
        case .userNotActive:
            return "User account is not active"
        case .emailAlreadyExists:
            return "Email address is already registered"
        case .invalidToken:
            return "Invalid token"
        case .tokenExpired:
            return "Token has expired"
        case .tokenRevoked:
            return "Token has been revoked"
        case .passwordTooWeak:
            return "Password does not meet security requirements"
        case .invalidEmail:
            return "Invalid email format"
        }
    }
}

// MARK: - Authentication Use Case
public final class AuthUseCase: Sendable {
    private let userRepository: any UserRepositoryProtocol
    private let passwordHasher: any PasswordHasherProtocol
    private let tokenService: any TokenServiceProtocol
    
    public init(
        userRepository: any UserRepositoryProtocol,
        passwordHasher: any PasswordHasherProtocol,
        tokenService: any TokenServiceProtocol
    ) {
        self.userRepository = userRepository
        self.passwordHasher = passwordHasher
        self.tokenService = tokenService
    }
    
    // MARK: - Public Methods
    
    public func login(credentials: UserCredentials) async throws -> AuthToken {
        // Validate email format
        guard isValidEmail(credentials.email) else {
            throw AuthError.invalidEmail
        }
        
        // Find user by email
        guard let user = try await userRepository.find(by: credentials.email) else {
            throw AuthError.invalidCredentials
        }
        
        // Check if user is active
        guard user.isActive else {
            throw AuthError.userNotActive
        }
        
        // Verify password
        guard try passwordHasher.verify(credentials.password, against: user.passwordHash) else {
            throw AuthError.invalidCredentials
        }
        
        // Generate tokens
        let accessToken = try await tokenService.generateAccessToken(for: user)
        let refreshToken = try await tokenService.generateRefreshToken(for: user)
        
        return AuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: 3600 // 1 hour
        )
    }
    
    public func register(email: String, username: String, password: String) async throws -> User {
        // Validate inputs
        guard isValidEmail(email) else {
            throw AuthError.invalidEmail
        }
        
        guard isPasswordStrong(password) else {
            throw AuthError.passwordTooWeak
        }
        
        // Check if user already exists
        if let _ = try await userRepository.find(by: email) {
            throw AuthError.emailAlreadyExists
        }
        
        // Hash password
        let passwordHash = try passwordHasher.hash(password)
        
        // Create user
        let newUser = User(
            email: email,
            username: username,
            passwordHash: passwordHash,
            isActive: true,
            createdAt: Date(),
            updatedAt: Date()
        )
        
        return try await userRepository.create(newUser)
    }
    
    public func refreshToken(_ refreshToken: String) async throws -> AuthToken {
        // Validate refresh token and get user ID
        let userId = try await tokenService.validateToken(refreshToken)
        
        // Find user
        guard let user = try await userRepository.find(by: userId) else {
            throw AuthError.userNotFound
        }
        
        guard user.isActive else {
            throw AuthError.userNotActive
        }
        
        // Generate new tokens
        let newAccessToken = try await tokenService.generateAccessToken(for: user)
        let newRefreshToken = try await tokenService.generateRefreshToken(for: user)
        
        // Revoke old refresh token
        try await tokenService.revokeToken(refreshToken)
        
        return AuthToken(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            expiresIn: 3600
        )
    }
    
    public func validateAccessToken(_ token: String) async throws -> User {
        let userId = try await tokenService.validateToken(token)
        
        guard let user = try await userRepository.find(by: userId) else {
            throw AuthError.userNotFound
        }
        
        guard user.isActive else {
            throw AuthError.userNotActive
        }
        
        return user
    }
    
    public func logout(_ token: String) async throws {
        try await tokenService.revokeToken(token)
    }
    
    // MARK: - Private Methods
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    private func isPasswordStrong(_ password: String) -> Bool {
        // At least 8 characters, contains uppercase, lowercase, and number
        let passwordRegex = "^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d)[a-zA-Z\\d@$!%*?&]{8,}$"
        let passwordPredicate = NSPredicate(format: "SELF MATCHES %@", passwordRegex)
        return passwordPredicate.evaluate(with: password)
    }
}
