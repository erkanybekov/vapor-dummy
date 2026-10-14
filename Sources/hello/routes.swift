import Vapor

// MARK: - Routes Configuration

func routes(_ app: Application) throws {
    // API versioning
    let api = app.grouped("api", "v1")
    
    // Register controllers
    try registerControllers(api: api, app: app)
}

// MARK: - Controller Registration

private func registerControllers(api: any RoutesBuilder, app: Application) throws {
    // Health Controller
    try api.register(collection: HealthController())
    
    // Auth Controller
    guard let authUseCase = app.authUseCase else {
        throw Abort(.internalServerError, reason: "AuthUseCase not configured")
    }
    try api.register(collection: AuthController(authUseCase: authUseCase))
    
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
        userRepository: userRepository
    ))
}
