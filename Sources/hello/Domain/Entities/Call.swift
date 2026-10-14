import Foundation

// MARK: - Call Domain Entities

/// Lifecycle status of a call as stored in call history.
enum CallStatus: String, Codable, Sendable {
    case ringing      // invite sent, nobody answered yet
    case active       // answered, media is flowing peer-to-peer
    case completed    // answered and later ended
    case missed       // nobody answered (caller cancelled, timeout, callee went offline)
    case declined     // callee declined
    case busy         // every callee device was already in a call
    case unavailable  // callee had no online devices
}

/// Why a call ended. Sent to clients in `call.ended` and stored in history.
enum CallEndReason: String, Codable, Sendable {
    case hangup                                  // one side hung up an active call
    case cancelled                               // caller hung up before anyone answered
    case declined                                // callee declined
    case timeout                                 // nobody answered in time
    case busy                                    // every callee device is in another call
    case unavailable                             // callee has no online devices
    case answeredElsewhere = "answered_elsewhere" // another device of the callee picked up
    case connectionLost = "connection_lost"      // a party did not reconnect within the grace period
}

/// One device taking part in signaling. A user can have several (iPhone, Mac, browser tab).
struct CallPeer: Codable, Sendable, Equatable {
    let userId: UUID
    let username: String
    let deviceId: String
    var deviceName: String
}

/// Minimal public info about a user, used when addressing calls.
struct CallUser: Codable, Sendable, Equatable {
    let id: UUID
    let username: String
}

/// Persistent record of a call for call history.
struct CallRecord: Sendable, Equatable {
    let id: UUID
    let callerId: UUID
    let calleeId: UUID
    let callerDeviceId: String
    var calleeDeviceId: String?
    let video: Bool
    var status: CallStatus
    var endReason: CallEndReason?
    let startedAt: Date
    var answeredAt: Date?
    var endedAt: Date?

    init(
        id: UUID,
        callerId: UUID,
        calleeId: UUID,
        callerDeviceId: String,
        calleeDeviceId: String? = nil,
        video: Bool,
        status: CallStatus = .ringing,
        endReason: CallEndReason? = nil,
        startedAt: Date = Date(),
        answeredAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.callerId = callerId
        self.calleeId = calleeId
        self.callerDeviceId = callerDeviceId
        self.calleeDeviceId = calleeDeviceId
        self.video = video
        self.status = status
        self.endReason = endReason
        self.startedAt = startedAt
        self.answeredAt = answeredAt
        self.endedAt = endedAt
    }

    /// Talk time in seconds, if the call was answered and has ended.
    var duration: TimeInterval? {
        guard let answeredAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(answeredAt)
    }

    /// Marks the record as finished and derives the final status from the reason.
    mutating func finish(reason: CallEndReason, at date: Date = Date()) {
        endReason = reason
        endedAt = date
        if answeredAt != nil {
            status = .completed
            return
        }
        switch reason {
        case .declined: status = .declined
        case .busy: status = .busy
        case .unavailable: status = .unavailable
        case .hangup, .cancelled, .timeout, .answeredElsewhere, .connectionLost: status = .missed
        }
    }
}

// MARK: - ICE Servers

/// STUN/TURN server description in the shape `RTCPeerConnection` expects.
struct IceServer: Codable, Sendable, Equatable {
    let urls: [String]
    let username: String?
    let credential: String?

    init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}
