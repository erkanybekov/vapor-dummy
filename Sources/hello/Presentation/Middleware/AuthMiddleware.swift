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

// MARK: - WebSocket Authentication

extension Request {
    /// Authenticates a WebSocket upgrade. Call it in the route handler, before
    /// `webSocket(...)`, so a bad token gets a real `401` response. (A failing
    /// `shouldUpgrade` makes Vapor drop the TCP connection instead, which clients
    /// cannot tell apart from a network error.) Browsers cannot set headers on a
    /// WebSocket, so the access token may also come as `?token=`; native clients
    /// should send the Authorization header.
    func authenticateWebSocket(with authUseCase: AuthUseCase) async throws -> User {
        guard let token = headers.bearerAuthorization?.token ?? query[String.self, at: "token"] else {
            throw Abort.rejectedUpgrade(.unauthorized, reason: "Missing access token")
        }
        guard let user = try? await authUseCase.validateAccessToken(token) else {
            throw Abort.rejectedUpgrade(.unauthorized, reason: "Invalid access token")
        }
        auth.login(user)
        return user
    }
}

extension Abort {
    /// An error answer to a WebSocket upgrade request. It tells the client to close the
    /// connection: once the server has parsed an upgrade request it no longer reads
    /// HTTP on that connection, so a client reusing it (URLSession does) would hang.
    static func rejectedUpgrade(_ status: HTTPResponseStatus, reason: String) -> Abort {
        Abort(status, headers: ["Connection": "close"], reason: reason)
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
