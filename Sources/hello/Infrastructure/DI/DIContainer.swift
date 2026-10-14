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

// MARK: - Call Recorder Lifecycle

/// Flushes pending call history writes before the database shuts down.
private struct CallRecorderLifecycle: LifecycleHandler {
    let recorder: CallRecorder

    func shutdownAsync(_ application: Application) async {
        await recorder.shutdown()
    }
}
