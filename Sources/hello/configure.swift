import Vapor
import Fluent
import FluentPostgresDriver
import JWT

// configures your application
public func configure(_ app: Application) async throws {
    // MARK: - Database Configuration
    // Debug environment variables
    print("🔍 Environment: \(app.environment)")
    print("🔍 All environment variables:")
    ProcessInfo.processInfo.environment.forEach { key, value in
        if key.contains("DATABASE") || key.contains("POSTGRES") {
            print("  \(key): \(value)")
        }
    }
    print("🔍 DATABASE_URL: \(Environment.get("DATABASE_URL") ?? "NOT SET")")
    print("🔍 DATABASE_HOST: \(Environment.get("DATABASE_HOST") ?? "NOT SET")")
    print("🔍 DATABASE_PORT: \(Environment.get("DATABASE_PORT") ?? "NOT SET")")
    print("🔍 DATABASE_NAME: \(Environment.get("DATABASE_NAME") ?? "NOT SET")")
    print("🔍 DATABASE_USERNAME: \(Environment.get("DATABASE_USERNAME") ?? "NOT SET")")
    print("🔍 DATABASE_PASSWORD: \(Environment.get("DATABASE_PASSWORD")?.count ?? 0) chars")
    
    // Try DATABASE_URL first (Render's preferred method)
    if let databaseURL = Environment.get("DATABASE_URL") ?? Environment.get("POSTGRES_URL"), !databaseURL.isEmpty {
        print("🔍 Using DATABASE_URL: \(databaseURL)")
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
    } 
    // Try individual environment variables (fallback for Render)
    else if let dbHost = Environment.get("DATABASE_HOST"),
            !dbHost.isEmpty,
            dbHost != "localhost" {
        let dbPort = Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? 5432
        let dbUsername = Environment.get("DATABASE_USER") ?? Environment.get("DATABASE_USERNAME") ?? "vapor_user"
        let dbPassword = Environment.get("DATABASE_PASSWORD") ?? ""
        let dbName = Environment.get("DATABASE_NAME") ?? "vapor_database"
        
        print("🔍 Using individual env vars: \(dbHost):\(dbPort) db=\(dbName) user=\(dbUsername)")
        
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
    // Local development fallback
    else if app.environment == .development {
        print("⚠️ No database configuration found, using local development defaults")
        let dbHost = "localhost"
        let dbPort = 5432
        let dbUsername = "vapor_username"
        let dbPassword = "vapor_password"
        let dbName = "vapor_database"
        
        print("🔍 Local dev config: \(dbHost):\(dbPort) db=\(dbName) user=\(dbUsername)")
        
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
        fatalError("❌ CRITICAL: No database configuration found in production! Please set DATABASE_URL or individual database environment variables.")
    }
    
    // MARK: - JWT Configuration
    try await configureJWT(app)
    
    // MARK: - Migrations
    app.migrations.add(CreateUser())
    app.migrations.add(CreateRevokedToken())
    app.migrations.add(CreateTodo())
    
    // Run migrations automatically
    // For initial deployment, we'll run migrations in production too
    // In a real app, you'd want a separate migration command
    try await app.autoMigrate()
    
    // MARK: - Middleware
    // Enable file serving from /Public folder
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    
    // CORS middleware for API access
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: getAllowedOrigins(for: app.environment),
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
    )
    app.middleware.use(CORSMiddleware(configuration: corsConfiguration))
    
    // Error handling middleware
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    
    // MARK: - Dependency Injection
    try DIContainer.configure(app: app)
    
    // MARK: - Routes
    try routes(app)
}

// MARK: - JWT Configuration
private func configureJWT(_ app: Application) async throws {
    // JWTKit 5.0+ configuration
    // In production, use environment variables for secrets
    let secretKey = Environment.get("JWT_SECRET") ?? "your-256-bit-secret-key-here-must-be-very-secure"
    
    // Add HMAC key for JWTKit 5.0+ using the correct API
    // Create HMACKey from the secret string
    let key = HMACKey(from: secretKey)
    await app.jwt.keys.add(hmac: key, digestAlgorithm: .sha256)
}

// MARK: - Key Generation (Development Only)
private func generateKeysIfNeeded(privateKeyPath: String, publicKeyPath: String) {
    let fileManager = FileManager.default
    
    if !fileManager.fileExists(atPath: privateKeyPath) || !fileManager.fileExists(atPath: publicKeyPath) {
        print("🔑 JWT keys not found. Generating new keys...")
        print("⚠️  In production, use pre-generated keys stored securely!")
        
        // For development, we'll create simple HMAC keys instead of RSA
        // In production, use proper RSA key generation
        let secretKey = [UInt8].random(count: 32).base64String()
        
        do {
            try secretKey.write(toFile: privateKeyPath, atomically: true, encoding: .utf8)
            try secretKey.write(toFile: publicKeyPath, atomically: true, encoding: .utf8)
            print("✅ Development keys generated successfully")
        } catch {
            print("❌ Failed to generate keys: \(error)")
        }
    }
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

// MARK: - Extensions
extension [UInt8] {
    static func random(count: Int) -> [UInt8] {
        return (0..<count).map { _ in UInt8.random(in: 0...255) }
    }
    
    func base64String() -> String {
        return Data(self).base64EncodedString()
    }
}