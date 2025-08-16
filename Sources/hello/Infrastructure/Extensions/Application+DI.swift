import Vapor

// MARK: - Application Dependency Injection Extensions

extension Application {
    // MARK: Storage Keys
    
    private struct AuthUseCaseKey: StorageKey, Sendable {
        typealias Value = AuthUseCase
    }
    
    private struct UserRepositoryKey: StorageKey, Sendable {
        typealias Value = any UserRepositoryProtocol
    }
    
    private struct TodoRepositoryKey: StorageKey, Sendable {
        typealias Value = any TodoRepositoryProtocol
    }
    
    private struct TodoUseCaseKey: StorageKey, Sendable {
        typealias Value = TodoUseCase
    }
    
    // MARK: Properties
    
    var authUseCase: AuthUseCase? {
        get { storage[AuthUseCaseKey.self] }
        set { storage[AuthUseCaseKey.self] = newValue }
    }
    
    var userRepository: (any UserRepositoryProtocol)? {
        get { storage[UserRepositoryKey.self] }
        set { storage[UserRepositoryKey.self] = newValue }
    }
    
    var todoRepository: (any TodoRepositoryProtocol)? {
        get { storage[TodoRepositoryKey.self] }
        set { storage[TodoRepositoryKey.self] = newValue }
    }
    
    var todoUseCase: TodoUseCase? {
        get { storage[TodoUseCaseKey.self] }
        set { storage[TodoUseCaseKey.self] = newValue }
    }
}
