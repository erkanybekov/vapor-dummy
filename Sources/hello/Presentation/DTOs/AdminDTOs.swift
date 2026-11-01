import Vapor
import Foundation

// MARK: - Request DTOs

struct AdminUpdateUserRequest: Content {
    let isActive: Bool?
    let isAdmin: Bool?
}

// MARK: - Response DTOs

struct AdminStatsResponse: Content {
    let users: Int
    let activeUsers: Int
    let admins: Int
    let onlineUsers: Int
    let activeCalls: Int
    let callsLastDay: Int

    init(from stats: AdminStats) {
        self.users = stats.users.total
        self.activeUsers = stats.users.active
        self.admins = stats.users.admins
        self.onlineUsers = stats.onlineUsers
        self.activeCalls = stats.activeCalls
        self.callsLastDay = stats.callsLastDay
    }
}

/// Spelled out instead of reusing the domain `User`, so that the password hash stays out.
struct AdminUserResponse: Content {
    let id: UUID?
    let email: String
    let username: String
    let isActive: Bool
    let isAdmin: Bool
    let online: Bool
    let createdAt: Date?

    init(from user: User, online: Bool) {
        self.id = user.id
        self.email = user.email
        self.username = user.username
        self.isActive = user.isActive
        self.isAdmin = user.isAdmin
        self.online = online
        self.createdAt = user.createdAt
    }
}

struct AdminUserListResponse: Content {
    let users: [AdminUserResponse]
    let pagination: PaginationMeta
}

struct AdminCallResponse: Content {
    let id: UUID
    let callerId: UUID
    let callerUsername: String?
    let calleeId: UUID
    let calleeUsername: String?
    let video: Bool
    let status: CallStatus
    let endReason: CallEndReason?
    let startedAt: Date
    let duration: TimeInterval?

    init(from record: CallRecord, usernames: [UUID: String]) {
        self.id = record.id
        self.callerId = record.callerId
        self.callerUsername = usernames[record.callerId]
        self.calleeId = record.calleeId
        self.calleeUsername = usernames[record.calleeId]
        self.video = record.video
        self.status = record.status
        self.endReason = record.endReason
        self.startedAt = record.startedAt
        self.duration = record.duration
    }
}

struct AdminCallListResponse: Content {
    let calls: [AdminCallResponse]
    let pagination: PaginationMeta
}

extension PaginationMeta {
    init(page: Int, limit: Int, total: Int) {
        self.init(page: page, limit: limit, total: total, totalPages: (total + limit - 1) / limit)
    }
}
