import Vapor
import JWT

// MARK: - JWT Bearer Authenticator

struct JWTBearerAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        do {
            // Verify JWT token
            let payload = try await request.jwt.verify(as: AccessTokenPayload.self)
            
            // Extract user ID from JWT
            guard let userId = UUID(uuidString: payload.subject.value),
                  let userRepository = request.application.userRepository,
                  let user = try await userRepository.find(by: userId),
                  user.isActive else {
                return
            }
            
            // Authenticate the user
            request.auth.login(user)
        } catch {
            // Authentication failed silently
            return
        }
    }
}

// MARK: - User Authenticator

struct UserAuthenticator: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.auth.has(User.self) else {
            throw Abort(.unauthorized, reason: "Authentication required")
        }
        return try await next.respond(to: request)
    }
}
