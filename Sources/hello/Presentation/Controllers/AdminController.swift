import Vapor

// MARK: - Admin Controller
//
// GET   /api/v1/admin/stats          totals and what is live right now (admin)
// GET   /api/v1/admin/users          users, newest first: ?page=&limit=&search= (admin)
// PATCH /api/v1/admin/users/:userId  block or unblock, grant or revoke admin (admin)
// GET   /api/v1/admin/calls          everyone's calls, newest first: ?page=&limit= (admin)

final class AdminController: RouteCollection, Sendable {
    /// Far beyond any real list, and it keeps the database offset from overflowing.
    private static let maxPage = 1_000_000

    private let admin: AdminUseCase

    init(admin: AdminUseCase) {
        self.admin = admin
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped("admin").grouped(JWTBearerAuthenticator(), UserAuthenticator(), AdminGuard())

        protected.get("stats", use: getStats)
        protected.get("users", use: getUsers)
        protected.patch("users", ":userId", use: updateUser)
        protected.get("calls", use: getCalls)
    }

    func getStats(_ req: Request) async throws -> AdminStatsResponse {
        AdminStatsResponse(from: try await admin.stats())
    }

    func getUsers(_ req: Request) async throws -> AdminUserListResponse {
        let (page, limit) = pageParameters(req)
        let search = req.query[String.self, at: "search"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try await admin.users(search: search?.isEmpty == false ? search : nil, page: page, limit: limit)
        return AdminUserListResponse(
            users: result.users.map { user in
                AdminUserResponse(from: user, online: user.id.map(result.online.contains) ?? false)
            },
            pagination: PaginationMeta(page: page, limit: limit, total: result.total)
        )
    }

    func updateUser(_ req: Request) async throws -> MessageResponse {
        guard let adminId = try req.auth.require(User.self).id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        guard let userId = req.parameters.get("userId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        let request = try req.content.decode(AdminUpdateUserRequest.self)

        let user = try await admin.updateUser(userId, isActive: request.isActive, isAdmin: request.isAdmin, by: adminId)
        req.logger.notice("Admin changed a user", metadata: [
            "admin": "\(adminId)",
            "user": "\(userId)",
            "isActive": "\(user.isActive)",
            "isAdmin": "\(user.isAdmin)",
        ])
        return MessageResponse(message: "User updated")
    }

    func getCalls(_ req: Request) async throws -> AdminCallListResponse {
        let (page, limit) = pageParameters(req)
        let result = try await admin.calls(page: page, limit: limit)
        return AdminCallListResponse(
            calls: result.records.map { AdminCallResponse(from: $0, usernames: result.usernames) },
            pagination: PaginationMeta(page: page, limit: limit, total: result.total)
        )
    }

    // MARK: - Helpers

    private func pageParameters(_ req: Request) -> (page: Int, limit: Int) {
        let page = min(max(req.query[Int.self, at: "page"] ?? 1, 1), Self.maxPage)
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 20, 1), 100)
        return (page, limit)
    }
}
