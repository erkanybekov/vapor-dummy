import Vapor

func routes(_ app: Application) throws {
    // Health check route
    app.get { req async in
        return ["message": "🚀 Vapor Clean Architecture API is running!"]
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }
    
    // API versioning
    let api = app.grouped("api", "v1")
    
    // Register Auth Controller
    guard let authUseCase = app.authUseCase else {
        throw Abort(.internalServerError, reason: "AuthUseCase not configured")
    }
    
    let authController = AuthController(authUseCase: authUseCase)
    try api.register(collection: authController)
    
    // Health check with database status
    api.get("health") { req async throws in
        // Simple database connectivity check
        let isDbConnected: Bool
        do {
            _ = try await UserModel.query(on: req.db).count()
            isDbConnected = true
        } catch {
            isDbConnected = false
        }
        
        return [
            "status": "healthy",
            "database": isDbConnected ? "connected" : "disconnected",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
}
