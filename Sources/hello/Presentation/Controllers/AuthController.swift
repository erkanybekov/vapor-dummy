import Vapor

// MARK: - Authentication Controller
// Clean, focused controller that handles authentication endpoints only
final class AuthController: RouteCollection, Sendable {
    private let authUseCase: AuthUseCase
    
    init(authUseCase: AuthUseCase) {
        self.authUseCase = authUseCase
    }
    
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        
        // Public routes
        auth.post("login", use: login)
        auth.post("register", use: register)
        auth.post("refresh", use: refreshToken)
        
        // Protected routes (require authentication)
        let protected = auth.grouped(JWTBearerAuthenticator(), UserAuthenticator())
        protected.post("logout", use: logout)
        protected.get("me", use: getCurrentUser)
    }
    
    // MARK: - Route Handlers
    
    func login(_ req: Request) async throws -> AuthResponse {
        let loginRequest = try req.content.decode(LoginRequest.self)
        
        let credentials = UserCredentials(
            email: loginRequest.email,
            password: loginRequest.password
        )
        
        do {
            let authToken = try await authUseCase.login(credentials: credentials)
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
                throw Abort(.unauthorized, reason: error.localizedDescription)
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
        
        do {
            try await authUseCase.logout(authHeader.token)
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
