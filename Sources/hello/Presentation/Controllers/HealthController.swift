import Vapor
import Fluent

// MARK: - Health Check Controller

final class HealthController: RouteCollection, Sendable {
    
    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: healthCheck)
        routes.get(use: rootMessage)
    }
    
    // MARK: - Health Check Endpoint
    
    func healthCheck(_ req: Request) async throws -> Response {
        let isDbConnected = await checkDatabaseConnection(req)
        
        let response = [
            "status": isDbConnected ? "healthy" : "unhealthy",
            "database": isDbConnected ? "connected" : "disconnected",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        // Monitors and the hosting platform look at the status code, not the body.
        return try await response.encodeResponse(status: isDbConnected ? .ok : .serviceUnavailable, for: req)
    }
    
    // MARK: - Root Endpoint
    
    func rootMessage(_ req: Request) async throws -> Response {
        let response = ["message": "🚀 Vapor Clean Architecture API is running!"]
        return try await response.encodeResponse(for: req)
    }
    
    // MARK: - Private Methods
    
    private func checkDatabaseConnection(_ req: Request) async -> Bool {
        do {
            _ = try await UserModel.query(on: req.db).count()
            return true
        } catch {
            return false
        }
    }
}
