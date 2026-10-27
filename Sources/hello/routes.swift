import Vapor

// MARK: - Routes Configuration

func routes(_ app: Application) throws {
    // API versioning
    let api = app.grouped("api", "v1")
    
    // Register controllers
    try registerControllers(api: api, app: app)

    // Web app: client-side routes (/todos, /calls, ...) are not files on disk,
    // so answer them with index.html and let the React router take over.
    app.get("**") { req async throws -> Response in
        let path = req.url.path
        let looksLikeFile = path.split(separator: "/").last?.contains(".") ?? false
        guard !path.hasPrefix("/api/"), !looksLikeFile else {
            throw Abort(.notFound)
        }
        let index = req.application.directory.publicDirectory + "index.html"
        guard FileManager.default.fileExists(atPath: index) else {
            throw Abort(.notFound)
        }
        let response = try await req.fileio.asyncStreamFile(at: index)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        return response
    }
}

// MARK: - Controller Registration

private func registerControllers(api: any RoutesBuilder, app: Application) throws {
    // Health Controller
    try api.register(collection: HealthController())
    
    // Auth Controller
    guard let authUseCase = app.authUseCase, let rateLimiter = app.rateLimiter else {
        throw Abort(.internalServerError, reason: "AuthUseCase not configured")
    }
    try api.register(collection: AuthController(authUseCase: authUseCase, rateLimiter: rateLimiter))
    
    // Todo Controller  
    guard let todoUseCase = app.todoUseCase else {
        throw Abort(.internalServerError, reason: "TodoUseCase not configured")
    }
    try api.register(collection: TodoController(todoUseCase: todoUseCase))

    // Call Controller (video calls signaling)
    guard let callHub = app.callHub,
          let iceServerProvider = app.iceServerProvider,
          let callRepository = app.callRepository,
          let userRepository = app.userRepository else {
        throw Abort(.internalServerError, reason: "Call services not configured")
    }
    try api.register(collection: CallController(
        hub: callHub,
        iceServers: iceServerProvider,
        callRepository: callRepository,
        userRepository: userRepository,
        authUseCase: authUseCase
    ))

    // Chat Controller (WebSocket training ground)
    guard let chatHub = app.chatHub, let chatRepository = app.chatRepository else {
        throw Abort(.internalServerError, reason: "Chat services not configured")
    }
    try api.register(collection: ChatController(hub: chatHub, repository: chatRepository, authUseCase: authUseCase))
}
