import Foundation
import Vapor

// MARK: - Admin Use Case

struct AdminStats: Sendable {
    let users: UserCounts
    let onlineUsers: Int
    let activeCalls: Int
    let callsLastDay: Int
}

final class AdminUseCase: Sendable {
    private let userRepository: any UserRepositoryProtocol
    private let callRepository: any CallRepositoryProtocol
    private let callHub: CallHub
    private let chatHub: ChatHub

    init(
        userRepository: any UserRepositoryProtocol,
        callRepository: any CallRepositoryProtocol,
        callHub: CallHub,
        chatHub: ChatHub
    ) {
        self.userRepository = userRepository
        self.callRepository = callRepository
        self.callHub = callHub
        self.chatHub = chatHub
    }

    func stats() async throws -> AdminStats {
        let live = await callHub.liveCounts()
        return AdminStats(
            users: try await userRepository.counts(),
            onlineUsers: live.onlineUsers,
            activeCalls: live.activeCalls,
            callsLastDay: try await callRepository.count(since: Date().addingTimeInterval(-24 * 60 * 60))
        )
    }

    func users(search: String?, page: Int, limit: Int) async throws -> (users: [User], online: Set<UUID>, total: Int) {
        let result = try await userRepository.page(search: search, page: page, limit: limit)
        let online = await callHub.onlineUsers(among: Set(result.users.compactMap(\.id)))
        return (users: result.users, online: online, total: result.total)
    }

    func calls(page: Int, limit: Int) async throws -> (records: [CallRecord], usernames: [UUID: String], total: Int) {
        let result = try await callRepository.page(page: page, limit: limit)
        let usernames = try await userRepository.usernames(of: Set(result.records.flatMap { [$0.callerId, $0.calleeId] }))
        return (records: result.records, usernames: usernames, total: result.total)
    }

    func updateUser(_ id: UUID, isActive: Bool?, isAdmin: Bool?, by adminId: UUID) async throws -> User {
        // Nobody can lock themselves out, so the panel always keeps at least one admin.
        guard id != adminId else {
            throw Abort(.badRequest, reason: "You cannot change your own account")
        }
        guard let user = try await userRepository.find(by: id) else {
            throw Abort(.notFound, reason: "User not found")
        }

        let updated = try await userRepository.update(user.with(isActive: isActive, isAdmin: isAdmin))
        if user.isActive && !updated.isActive {
            // Requests are refused from now on, but a socket is checked only when it
            // connects: closing it sends the client back through that check. A call in
            // progress ends once the reconnect grace period runs out.
            await callHub.closeConnections(of: id)
            await chatHub.closeConnections(of: id)
        }
        return updated
    }
}
