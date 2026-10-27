import Vapor
import Fluent
import FluentPostgresDriver
import JWT
import NIOSSL

// configures your application
public func configure(_ app: Application) async throws {
    // MARK: - Database Configuration
    // Never log credentials: logs end up in the hosting dashboard.
    print("🔍 Environment: \(app.environment)")
    
    // Try DATABASE_URL first (Render's preferred method)
    if let databaseURL = Environment.get("DATABASE_URL") ?? Environment.get("POSTGRES_URL"), !databaseURL.isEmpty {
        // Parse URL components for TLS configuration
        guard let url = URL(string: databaseURL),
              let host = url.host,
              let user = url.user,
              let password = url.password,
              let database = url.path.dropFirst().description.isEmpty ? nil : String(url.path.dropFirst()) else {
            fatalError("Invalid DATABASE_URL format")
        }
        
        let port = url.port ?? 5432
        print("🔍 Using DATABASE_URL: \(host):\(port)/\(database) user=\(user)")
        
        // Configure SSL for Render (required)
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none  // Skip cert verification for managed DB
        
        app.databases.use(.postgres(
            configuration: .init(
                hostname: host,
                port: port,
                username: user,
                password: password,
                database: database,
                tls: .require(try NIOSSLContext(configuration: tlsConfig))
            )
        ), as: .psql)
    } 
    // Individual environment variables, or the docker-compose defaults in development
    // and tests. Tests use their own database because they drop the tables they create.
    else if Environment.get("DATABASE_HOST")?.isEmpty == false || app.environment == .development || app.environment == .testing {
        let dbHost = Environment.get("DATABASE_HOST").flatMap { $0.isEmpty ? nil : $0 } ?? "localhost"
        let dbPort = Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? 5432
        let dbUsername = Environment.get("DATABASE_USER") ?? Environment.get("DATABASE_USERNAME") ?? "vapor_username"
        let dbPassword = Environment.get("DATABASE_PASSWORD") ?? "vapor_password"
        let dbName = Environment.get("DATABASE_NAME") ?? (app.environment == .testing ? "vapor_test" : "vapor_database")
        
        print("🔍 Database: \(dbHost):\(dbPort) db=\(dbName) user=\(dbUsername)")
        
        app.databases.use(
            .postgres(
                configuration: .init(
                    hostname: dbHost,
                    port: dbPort,
                    username: dbUsername,
                    password: dbPassword,
                    database: dbName,
                    tls: .disable
                )
            ),
            as: .psql
        )
    }
    // Production without database config should fail
    else {
        fatalError("❌ CRITICAL: No database configuration found in production! Please ensure the database service 'vapor-todo-db' exists in your Render dashboard and is linked to this web service.")
    }
    
    // MARK: - JWT Configuration
    try await configureJWT(app)
    
    // MARK: - Migrations
    app.migrations.add(CreateUser())
    app.migrations.add(CreateRevokedToken())
    app.migrations.add(CreateTodo())
    app.migrations.add(CreateCallRecord())
    app.migrations.add(AddIndexes())
    app.migrations.add(CreateChatMessage())

    // Run migrations automatically
    // For initial deployment, we'll run migrations in production too
    // In a real app, you'd want a separate migration command
    try await app.autoMigrate()
    
    // MARK: - Middleware
    // Enable file serving from /Public folder
    app.middleware.use(StaticCacheMiddleware())
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory, defaultFile: "index.html"))
    
    // CORS middleware for API access
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: getAllowedOrigins(for: app.environment),
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
    )
    app.middleware.use(CORSMiddleware(configuration: corsConfiguration))
    
    // Error handling middleware
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    
    // MARK: - JSON Encoder Configuration
    // Configure JSON encoder for consistent key ordering
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    
    // MARK: - Dependency Injection
    try DIContainer.configure(app: app)
    
    // MARK: - Routes
    try routes(app)
}

// MARK: - JWT Configuration
private func configureJWT(_ app: Application) async throws {
    // Anyone who knows the secret can mint tokens for any user, so production
    // refuses to start with a missing, short or default one.
    let secretKey: String
    if let configured = Environment.get("JWT_SECRET"), !configured.isEmpty {
        guard configured.utf8.count >= 32 else {
            fatalError("❌ CRITICAL: JWT_SECRET must be at least 32 characters. Generate one with: openssl rand -hex 32")
        }
        secretKey = configured
    } else if app.environment == .production {
        fatalError("❌ CRITICAL: JWT_SECRET is not set. Generate one with: openssl rand -hex 32")
    } else {
        app.logger.warning("JWT_SECRET is not set, using an insecure development key")
        secretKey = "insecure-development-only-jwt-secret"
    }
    
    await app.jwt.keys.add(hmac: HMACKey(from: secretKey), digestAlgorithm: .sha256)
}

// MARK: - CORS Configuration
private func getAllowedOrigins(for environment: Environment) -> CORSMiddleware.AllowOriginSetting {
    switch environment {
    case .development, .testing:
        // Development: Allow localhost and common dev ports
        return .originBased
    case .production:
        // Production: Whitelist specific domains
        let allowedDomains = Environment.get("CORS_ALLOWED_ORIGINS")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        
        if allowedDomains.isEmpty {
            // Fallback: Allow only HTTPS origins (more secure than .all)
            return .custom("https://your-frontend-domain.com")
        }
        
        return .any(allowedDomains)
    default:
        return .none
    }
}
