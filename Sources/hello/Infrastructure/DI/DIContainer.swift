import Vapor
import Fluent

// MARK: - Dependency Injection Container
final class DIContainer {
    static func configure(app: Application) throws {
        // Register database-dependent services
        app.userRepository = UserRepository(database: app.db)
        app.todoRepository = TodoRepository(database: app.db)
        
        // Register services
        let passwordHasher = BCryptPasswordHasher()
        let tokenService = JWTTokenService(application: app, database: app.db)
        
        // Register use cases
        app.authUseCase = AuthUseCase(
            userRepository: app.userRepository!,
            passwordHasher: passwordHasher,
            tokenService: tokenService
        )
        
        app.todoUseCase = TodoUseCase(
            todoRepository: app.todoRepository!
        )
    }
}
