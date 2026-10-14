import Vapor
import Foundation

// MARK: - Response DTOs

struct IceServersResponse: Content {
    let iceServers: [IceServer]
    /// Seconds until generated TURN credentials expire.
    let ttl: Int
}

enum CallDirection: String, Codable {
    case outgoing
    case incoming
    /// Called your own account from another device.
    case selfCall = "self"
}

struct CallHistoryItem: Content {
    let id: UUID
    let direction: CallDirection
    let peerUserId: UUID
    let video: Bool
    let status: CallStatus
    let endReason: CallEndReason?
    let startedAt: Date
    let answeredAt: Date?
    let endedAt: Date?
    let duration: TimeInterval?

    init(record: CallRecord, viewer: UUID) {
        self.id = record.id
        if record.callerId == record.calleeId {
            self.direction = .selfCall
        } else {
            self.direction = record.callerId == viewer ? .outgoing : .incoming
        }
        self.peerUserId = record.callerId == viewer ? record.calleeId : record.callerId
        self.video = record.video
        self.status = record.status
        self.endReason = record.endReason
        self.startedAt = record.startedAt
        self.answeredAt = record.answeredAt
        self.endedAt = record.endedAt
        self.duration = record.duration
    }
}

struct CallHistoryResponse: Content {
    let calls: [CallHistoryItem]
}
