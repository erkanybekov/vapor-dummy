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
    
    private struct CallRepositoryKey: StorageKey, Sendable {
        typealias Value = any CallRepositoryProtocol
    }
    
    private struct CallHubKey: StorageKey, Sendable {
        typealias Value = CallHub
    }
    
    private struct IceServerProviderKey: StorageKey, Sendable {
        typealias Value = IceServerProvider
    }
    
    private struct RateLimiterKey: StorageKey, Sendable {
        typealias Value = RateLimiter
    }
    
    private struct ChatHubKey: StorageKey, Sendable {
        typealias Value = ChatHub
    }
    
    private struct ChatRepositoryKey: StorageKey, Sendable {
        typealias Value = any ChatRepositoryProtocol
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
    
    var callRepository: (any CallRepositoryProtocol)? {
        get { storage[CallRepositoryKey.self] }
        set { storage[CallRepositoryKey.self] = newValue }
    }
    
    var callHub: CallHub? {
        get { storage[CallHubKey.self] }
        set { storage[CallHubKey.self] = newValue }
    }
    
    var iceServerProvider: IceServerProvider? {
        get { storage[IceServerProviderKey.self] }
        set { storage[IceServerProviderKey.self] = newValue }
    }
    
    var rateLimiter: RateLimiter? {
        get { storage[RateLimiterKey.self] }
        set { storage[RateLimiterKey.self] = newValue }
    }
    
    var chatHub: ChatHub? {
        get { storage[ChatHubKey.self] }
        set { storage[ChatHubKey.self] = newValue }
    }
    
    var chatRepository: (any ChatRepositoryProtocol)? {
        get { storage[ChatRepositoryKey.self] }
        set { storage[ChatRepositoryKey.self] = newValue }
    }
}
