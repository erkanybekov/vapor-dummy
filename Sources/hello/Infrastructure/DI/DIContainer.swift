import Vapor
import Fluent
import JWT
import NIOConcurrencyHelpers

// MARK: - Dependency Injection Container
final class DIContainer {
    static func configure(app: Application) throws {
        // Register database-dependent services
        app.userRepository = UserRepository(database: app.db)
        app.todoRepository = TodoRepository(database: app.db)
        
        // Register services
        let passwordHasher = BCryptPasswordHasher()
        let tokenService = JWTTokenService(keys: app.jwt.keys, database: app.db)
        app.rateLimiter = RateLimiter()
        app.lifecycle.use(RevokedTokenCleanup(tokenService: tokenService, logger: app.logger))
        
        // Register use cases
        app.authUseCase = AuthUseCase(
            userRepository: app.userRepository!,
            passwordHasher: passwordHasher,
            tokenService: tokenService
        )
        
        app.todoUseCase = TodoUseCase(
            todoRepository: app.todoRepository!
        )

        // Calls: signaling hub + background call history writer
        let callRepository = CallRepository(database: app.db)
        let callRecorder = CallRecorder(repository: callRepository, logger: app.logger)
        app.callRepository = callRepository
        app.iceServerProvider = IceServerProvider.fromEnvironment()
        app.callHub = CallHub(
            configuration: callHubConfiguration(),
            logger: app.logger,
            onRecord: { callRecorder.record($0) }
        )
        app.lifecycle.use(CallRecorderLifecycle(recorder: callRecorder))

        // Chat (WebSocket training ground)
        app.chatHub = ChatHub()
        app.chatRepository = ChatRepository(database: app.db)

        if app.iceServerProvider?.hasTURN == false {
            app.logger.warning("TURN is not configured: calls between devices behind strict NATs or mobile carriers may fail to connect. Set TURN_URLS and TURN_SECRET.")
        }
    }

    private static func callHubConfiguration() -> CallHub.Configuration {
        var configuration = CallHub.Configuration()
        if let seconds = Environment.get("CALL_RING_TIMEOUT_SECONDS").flatMap(Int.init) {
            configuration.ringTimeout = .seconds(seconds)
        }
        if let seconds = Environment.get("CALL_RECONNECT_GRACE_SECONDS").flatMap(Int.init) {
            configuration.reconnectGrace = .seconds(seconds)
        }
        return configuration
    }
}

// MARK: - Revoked Token Cleanup

/// Deletes revocation records of expired tokens at startup and then hourly,
/// so the table stays as small as the set of tokens that are still valid.
private final class RevokedTokenCleanup: LifecycleHandler, Sendable {
    private let tokenService: any TokenServiceProtocol
    private let logger: Logger
    private let task = NIOLockedValueBox<Task<Void, Never>?>(nil)

    init(tokenService: any TokenServiceProtocol, logger: Logger) {
        self.tokenService = tokenService
        self.logger = logger
    }

    func didBootAsync(_ application: Application) async throws {
        task.withLockedValue {
            $0 = Task { [tokenService, logger] in
                while !Task.isCancelled {
                    do {
                        try await tokenService.purgeExpiredRevocations()
                    } catch {
                        logger.warning("Failed to purge expired revoked tokens", metadata: ["error": "\(error)"])
                    }
                    try? await Task.sleep(for: .seconds(60 * 60))
                }
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        let running = task.withLockedValue { task in
            defer { task = nil }
            return task
        }
        running?.cancel()
        await running?.value
    }
}

// MARK: - Call Recorder Lifecycle

/// Flushes pending call history writes before the database shuts down.
private struct CallRecorderLifecycle: LifecycleHandler {
    let recorder: CallRecorder

    func shutdownAsync(_ application: Application) async {
        await recorder.shutdown()
    }
}
