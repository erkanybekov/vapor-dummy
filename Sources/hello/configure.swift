import Vapor
import Fluent
import FluentPostgresDriver
import JWT

// configures your application
public func configure(_ app: Application) async throws {
    // MARK: - Database Configuration
    // Configure PostgreSQL database
    app.databases.use(
        .postgres(
            configuration: .init(
                hostname: Environment.get("DATABASE_HOST") ?? "localhost",
                port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? 5432,
                username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
                password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
                database: Environment.get("DATABASE_NAME") ?? "vapor_database",
                tls: .disable
            )
        ),
        as: .psql
    )
    
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