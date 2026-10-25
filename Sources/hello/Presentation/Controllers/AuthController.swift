import Vapor

// MARK: - Authentication Controller
// Clean, focused controller that handles authentication endpoints only
final class AuthController: RouteCollection, Sendable {
    private enum Limits {
        // Per client IP
        static let login = RateLimiter.Rule(limit: 20, window: .seconds(5 * 60))
        static let register = RateLimiter.Rule(limit: 10, window: .seconds(60 * 60))
        static let refresh = RateLimiter.Rule(limit: 60, window: .seconds(5 * 60))
        // Per account, whatever IPs the attempts come from
        static let failedLogins = RateLimiter.Rule(limit: 5, window: .seconds(15 * 60))
    }
    
    private let authUseCase: AuthUseCase
    private let rateLimiter: RateLimiter
    
    init(authUseCase: AuthUseCase, rateLimiter: RateLimiter) {
        self.authUseCase = authUseCase
        self.rateLimiter = rateLimiter
    }
    
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        
        // Public routes, rate limited against password guessing and sign-up spam
        auth.grouped(RateLimitMiddleware(limiter: rateLimiter, name: "login", rule: Limits.login))
            .post("login", use: login)
        auth.grouped(RateLimitMiddleware(limiter: rateLimiter, name: "register", rule: Limits.register))
            .post("register", use: register)
        auth.grouped(RateLimitMiddleware(limiter: rateLimiter, name: "refresh", rule: Limits.refresh))
            .post("refresh", use: refreshToken)
        
        // Protected routes (require authentication)
        let protected = auth.grouped(JWTBearerAuthenticator(), UserAuthenticator())
        protected.post("logout", use: logout)
        protected.get("me", use: getCurrentUser)
    }
    
    // MARK: - Route Handlers
    
    func login(_ req: Request) async throws -> AuthResponse {
        let loginRequest = try req.content.decode(LoginRequest.self)
        
        let failuresKey = "login-failures:\(loginRequest.email.lowercased())"
        if let wait = await rateLimiter.retryAfter(failuresKey, rule: Limits.failedLogins) {
            throw Abort.tooManyRequests(retryAfter: wait)
        }
        
        let credentials = UserCredentials(
            email: loginRequest.email,
            password: loginRequest.password
        )
        
        do {
            let authToken = try await authUseCase.login(credentials: credentials)
            await rateLimiter.reset(failuresKey)
            let user = try await authUseCase.validateAccessToken(authToken.accessToken)
            
            return AuthResponse(
                accessToken: authToken.accessToken,
                refreshToken: authToken.refreshToken,
                expiresIn: authToken.expiresIn,
                tokenType: authToken.tokenType,
                user: UserResponse(from: user)
            )
        } catch let error as AuthError {
            switch error {
            case .invalidCredentials, .userNotFound:
                _ = await rateLimiter.hit(failuresKey, rule: Limits.failedLogins)
                throw Abort(.unauthorized, reason: error.localizedDescription)
            case .invalidEmail:
                throw Abort(.unauthorized, reason: AuthError.invalidCredentials.localizedDescription)
            case .userNotActive:
                throw Abort(.forbidden, reason: error.localizedDescription)
            default:
                throw Abort(.internalServerError, reason: "Authentication failed")
            }
        }
    }
    
    func register(_ req: Request) async throws -> AuthResponse {
        let registerRequest = try req.content.decode(RegisterRequest.self)
        
        do {
            let user = try await authUseCase.register(
                email: registerRequest.email,
                username: registerRequest.username,
                password: registerRequest.password
            )
            
            // Auto-login after registration
            let credentials = UserCredentials(
                email: registerRequest.email,
                password: registerRequest.password
            )
            
            let authToken = try await authUseCase.login(credentials: credentials)
            
            return AuthResponse(
                accessToken: authToken.accessToken,
                refreshToken: authToken.refreshToken,
                expiresIn: authToken.expiresIn,
                tokenType: authToken.tokenType,
                user: UserResponse(from: user)
            )
        } catch let error as AuthError {
            switch error {
            case .emailAlreadyExists:
                throw Abort(.conflict, reason: error.localizedDescription)
            case .passwordTooWeak, .invalidEmail:
                throw Abort(.badRequest, reason: error.localizedDescription)
            default:
                throw Abort(.internalServerError, reason: "Registration failed")
            }
        }
    }
    
    func refreshToken(_ req: Request) async throws -> AuthResponse {
        let refreshRequest = try req.content.decode(RefreshTokenRequest.self)
        
        do {
            let authToken = try await authUseCase.refreshToken(refreshRequest.refreshToken)
            let user = try await authUseCase.validateAccessToken(authToken.accessToken)
            
            return AuthResponse(
                accessToken: authToken.accessToken,
                refreshToken: authToken.refreshToken,
                expiresIn: authToken.expiresIn,
                tokenType: authToken.tokenType,
                user: UserResponse(from: user)
            )
        } catch let error as AuthError {
            switch error {
            case .invalidToken, .tokenExpired, .tokenRevoked:
                throw Abort(.unauthorized, reason: error.localizedDescription)
            case .userNotFound, .userNotActive:
                throw Abort(.forbidden, reason: error.localizedDescription)
            default:
                throw Abort(.internalServerError, reason: "Token refresh failed")
            }
        }
    }
    
    func logout(_ req: Request) async throws -> MessageResponse {
        let _ = try req.auth.require(User.self)
        
        // Extract token from Authorization header
        guard let authHeader = req.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Authorization header missing")
        }
        
        // Clients send their refresh token too, so it stops working as well.
        let refreshToken = (try? req.content.decode(LogoutRequest.self))?.refreshToken
        
        do {
            try await authUseCase.logout(accessToken: authHeader.token, refreshToken: refreshToken)
            return MessageResponse(message: "Successfully logged out")
        } catch {
            throw Abort(.internalServerError, reason: "Logout failed")
        }
    }
    
    func getCurrentUser(_ req: Request) async throws -> UserResponse {
        let user = try req.auth.require(User.self)
        return UserResponse(from: user)
    }
}

// MARK: - User Authenticatable

extension User: Authenticatable {}
