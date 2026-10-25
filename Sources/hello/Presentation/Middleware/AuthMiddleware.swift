import Vapor

// MARK: - JWT Bearer Authenticator

struct JWTBearerAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        // Checks the signature, expiry, revocation (logout) and that the user is active.
        // On failure the request stays unauthenticated and UserAuthenticator answers 401.
        guard let authUseCase = request.application.authUseCase,
              let user = try? await authUseCase.validateAccessToken(bearer.token) else {
            return
        }
        request.auth.login(user)
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
