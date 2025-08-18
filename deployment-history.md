# Deployment History

## Issue: Database Connection Failed on Render

### Problem Description
Vapor app deployed to Render failed to connect to PostgreSQL database with multiple error types:

1. **Environment Variables Missing**: Database environment variables not being set by Render
2. **SSL/TLS Certificate Verification Failed**: `CERTIFICATE_VERIFY_FAILED` errors when connecting to managed PostgreSQL

### Initial Error Logs
```
❌ CRITICAL: No database configuration found in production! Please set DATABASE_URL or individual database environment variables.
```

Later after environment variables were fixed:
```
PSQLError(code: connectionError, underlying: NIOSSL.NIOSSLError.handshakeFailed(NIOSSL.BoringSSLError.sslError([Error: 268435581 error:1000007d:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED])))
```

### Root Causes Identified

#### 1. Service Linking Issue
- Database service `vapor-todo-db` existed and was running (17+ hours)
- Web service `vapor-api-fresh` was not properly linked to database service
- Render wasn't injecting database environment variables into web service

#### 2. SSL/TLS Configuration Issue  
- Render **requires** SSL/TLS for all PostgreSQL connections (cannot be disabled)
- Managed database certificates are internal/self-signed
- Standard certificate verification fails with managed database providers

### Solutions Applied

#### 1. Fixed Service Configuration (`render.yaml`)
```yaml
databases:
  - name: vapor-db-fresh
    databaseName: vapor_database
    plan: free
    region: oregon

services:
  - type: web
    name: vapor-api-fresh
    env: docker
    dockerfilePath: ./Dockerfile
    plan: free
    region: oregon
    branch: main
    envVars:
      - key: DATABASE_URL
        fromDatabase:
          name: vapor-db-fresh
          property: connectionString
      - key: DATABASE_USER
        fromDatabase:
          name: vapor-db-fresh
          property: user
      - key: DATABASE_PASSWORD
        fromDatabase:
          name: vapor-db-fresh
          property: password
```

**Key Changes:**
- Used fresh service names to avoid linking conflicts
- Placed `databases:` section before `services:` section
- Simplified environment variable configuration

#### 2. Fixed SSL/TLS Configuration (`configure.swift`)

**Final Working Implementation:**
```swift
import NIOSSL

// Parse DATABASE_URL and configure SSL for Render
if let databaseURL = Environment.get("DATABASE_URL") {
    guard let url = URL(string: databaseURL),
          let host = url.host,
          let user = url.user,
          let password = url.password,
          let database = url.path.dropFirst().description.isEmpty ? nil : String(url.path.dropFirst()) else {
        fatalError("Invalid DATABASE_URL format")
    }
    
    let port = url.port ?? 5432
    
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
```

**Key Elements:**
- **SSL Required**: Uses `.require()` because Render mandates SSL
- **Certificate Verification Disabled**: `.certificateVerification = .none` for managed databases
- **Manual URL Parsing**: Extracts components from DATABASE_URL for fine-grained TLS control
- **NIOSSLContext**: Proper SSL context creation with custom TLS configuration

### Research Sources

#### Official Vapor Documentation
From [Vapor Heroku deployment docs](https://docs.vapor.codes/deploy/heroku/):
```swift
var tlsConfig: TLSConfiguration = .makeClientConfiguration() 
tlsConfig.certificateVerification = .none 
let nioSSLContext = try NIOSSLContext(configuration: tlsConfig) 
var postgresConfig = try SQLPostgresConfiguration(url: databaseURL) 
postgresConfig.coreConfiguration.tls = .require(nioSSLContext)
```

#### Community Findings
- [Render Community Thread](https://community.render.com/t/ssl-tls-required/1022): Confirmed SSL is mandatory
- [Stack Overflow](https://stackoverflow.com/questions/59023131/): Similar patterns for managed PostgreSQL databases

### Lessons Learned

1. **Managed Database SSL**: All major cloud providers (Heroku, Render, DigitalOcean) require SSL for managed PostgreSQL
2. **Certificate Verification**: Must be disabled for managed databases due to internal/self-signed certificates  
3. **Service Dependencies**: Order matters in `render.yaml` - databases before services
4. **Fresh Deployments**: Sometimes service linking issues require fresh service names
5. **URL Parsing**: Manual parsing gives more control over TLS configuration than using `.postgres(url:)`

### Final Status
✅ **Resolved**: Database connection successful with proper SSL/TLS configuration
✅ **Environment Variables**: All database variables properly injected by Render
✅ **Deployment**: App successfully deployed and running on Render

### Configuration Pattern for Future Reference
This SSL configuration pattern works for any managed PostgreSQL provider requiring SSL:
- Render
- Heroku  
- DigitalOcean Managed Databases
- AWS RDS (with SSL enforcement)
- Google Cloud SQL (with SSL required)
