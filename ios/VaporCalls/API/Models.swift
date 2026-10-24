import Foundation

// Mirrors of the Vapor DTOs (Sources/hello/Presentation/DTOs).

nonisolated struct User: Codable, Sendable, Equatable {
    let id: UUID
    let email: String
    let username: String
    let isActive: Bool
}

nonisolated struct AuthResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double
    let tokenType: String
    let user: User
}

nonisolated struct Todo: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var description: String?
    var completed: Bool
    let createdAt: Date?
    let updatedAt: Date?
}

nonisolated struct PaginationMeta: Codable, Sendable {
    let page: Int
    let limit: Int
    let total: Int
    let totalPages: Int
}

nonisolated struct TodoPage: Codable, Sendable {
    let todos: [Todo]
    let pagination: PaginationMeta
}

nonisolated enum CallStatus: String, Codable, Sendable {
    case ringing, active, completed, missed, declined, busy, unavailable
}

nonisolated enum CallEndReason: String, Codable, Sendable {
    case hangup, cancelled, declined, timeout, busy, unavailable
    case answeredElsewhere = "answered_elsewhere"
    case connectionLost = "connection_lost"

    var text: String {
        switch self {
        case .hangup: "Звонок завершён"
        case .cancelled: "Звонок отменён"
        case .declined: "Отклонено"
        case .timeout: "Нет ответа"
        case .busy: "Занято"
        case .unavailable: "Нет устройств онлайн"
        case .answeredElsewhere: "Ответили на другом устройстве"
        case .connectionLost: "Связь потеряна"
        }
    }
}

nonisolated struct CallHistoryItem: Codable, Sendable, Identifiable {
    enum Direction: String, Codable, Sendable {
        case outgoing, incoming
        case selfCall = "self"
    }

    let id: UUID
    let direction: Direction
    let peerUserId: UUID
    let peerUsername: String?
    let video: Bool
    let status: CallStatus
    let endReason: CallEndReason?
    let startedAt: Date
    let duration: Double?
}

nonisolated struct CallHistoryResponse: Codable, Sendable {
    let calls: [CallHistoryItem]
}
