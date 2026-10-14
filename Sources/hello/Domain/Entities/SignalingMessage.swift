import Foundation

// MARK: - Signaling Protocol
//
// JSON messages exchanged over the call WebSocket. Every message has a `type`
// field; the remaining fields depend on the type. Media never goes through the
// server: clients exchange SDP offers/answers and ICE candidates here and then
// connect peer-to-peer (or via TURN) with WebRTC.

/// Which side of the call the receiving device is on. The caller creates the SDP offer.
enum CallRole: String, Codable, Sendable {
    case caller
    case callee
}

/// WebRTC negotiation payload relayed between the two devices of an active call.
struct SignalPayload: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case offer
        case answer
        case candidate
    }

    struct Candidate: Codable, Sendable, Equatable {
        let candidate: String
        let sdpMid: String?
        let sdpMLineIndex: Int?
        let usernameFragment: String?
    }

    static let maxSDPLength = 64 * 1024

    let kind: Kind
    let sdp: String?
    let candidate: Candidate?

    init(kind: Kind, sdp: String? = nil, candidate: Candidate? = nil) {
        self.kind = kind
        self.sdp = sdp
        self.candidate = candidate
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sdp, candidate
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        sdp = try container.decodeIfPresent(String.self, forKey: .sdp)
        candidate = try container.decodeIfPresent(Candidate.self, forKey: .candidate)

        switch kind {
        case .offer, .answer:
            guard let sdp, !sdp.isEmpty, sdp.utf8.count <= Self.maxSDPLength else {
                throw DecodingError.dataCorruptedError(forKey: .sdp, in: container, debugDescription: "\(kind.rawValue) requires a non-empty sdp")
            }
        case .candidate:
            guard candidate != nil else {
                throw DecodingError.dataCorruptedError(forKey: .candidate, in: container, debugDescription: "candidate requires a candidate object")
            }
        }
    }
}

// MARK: - Client → Server

enum ClientMessage: Decodable, Sendable, Equatable {
    /// Start a call. Address the callee by id or by email; calling your own
    /// account rings your other online devices.
    case invite(calleeId: UUID?, calleeEmail: String?, video: Bool)
    case accept(callId: UUID)
    case decline(callId: UUID)
    case hangup(callId: UUID)
    case signal(callId: UUID, signal: SignalPayload)
    case ping

    private enum CodingKeys: String, CodingKey {
        case type, callId, calleeId, calleeEmail, video, signal
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "call.invite":
            let calleeId = try container.decodeIfPresent(UUID.self, forKey: .calleeId)
            let calleeEmail = try container.decodeIfPresent(String.self, forKey: .calleeEmail)
            guard calleeId != nil || calleeEmail != nil else {
                throw DecodingError.dataCorruptedError(forKey: .calleeId, in: container, debugDescription: "call.invite requires calleeId or calleeEmail")
            }
            let video = try container.decodeIfPresent(Bool.self, forKey: .video) ?? true
            self = .invite(calleeId: calleeId, calleeEmail: calleeEmail, video: video)
        case "call.accept":
            self = .accept(callId: try container.decode(UUID.self, forKey: .callId))
        case "call.decline":
            self = .decline(callId: try container.decode(UUID.self, forKey: .callId))
        case "call.hangup":
            self = .hangup(callId: try container.decode(UUID.self, forKey: .callId))
        case "call.signal":
            self = .signal(
                callId: try container.decode(UUID.self, forKey: .callId),
                signal: try container.decode(SignalPayload.self, forKey: .signal)
            )
        case "ping":
            self = .ping
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown message type '\(type)'")
        }
    }
}

// MARK: - Server → Client

enum SignalingErrorCode: String, Codable, Sendable {
    case badRequest = "bad_request"
    case rateLimited = "rate_limited"
    case alreadyInCall = "already_in_call"
    case callNotFound = "call_not_found"
    case userNotFound = "user_not_found"
    case tooManyDevices = "too_many_devices"
    case peerUnavailable = "peer_unavailable"
}

enum ServerMessage: Encodable, Sendable, Equatable {
    /// First message after connecting.
    case hello(userId: UUID, deviceId: String, iceServers: [IceServer])
    /// Online devices of your own account (sent whenever the set changes).
    case presence(devices: [CallPeer])
    /// To the caller: the invite is ringing on `devices` callee devices.
    case callRinging(callId: UUID, callee: CallUser, devices: Int)
    /// To every free callee device.
    case callIncoming(callId: UUID, caller: CallPeer, video: Bool)
    /// To both parties once a callee device answers. `role == .caller` sends the offer.
    case callAccepted(callId: UUID, peer: CallPeer, role: CallRole, video: Bool)
    /// To both parties after one of them reconnected mid-call. The caller should restart ICE.
    case callResumed(callId: UUID, peer: CallPeer, role: CallRole, video: Bool)
    /// The other party dropped off; the server waits for it to reconnect.
    case callReconnecting(callId: UUID)
    case callEnded(callId: UUID, reason: CallEndReason)
    /// Relayed WebRTC negotiation from the other party.
    case callSignal(callId: UUID, from: String, signal: SignalPayload)
    case error(code: SignalingErrorCode, message: String, callId: UUID?)
    case pong

    private enum CodingKeys: String, CodingKey {
        case type, userId, deviceId, iceServers, devices, callId, callee, caller
        case video, peer, role, reason, from, signal, code, message
    }

    var type: String {
        switch self {
        case .hello: "hello"
        case .presence: "presence"
        case .callRinging: "call.ringing"
        case .callIncoming: "call.incoming"
        case .callAccepted: "call.accepted"
        case .callResumed: "call.resumed"
        case .callReconnecting: "call.reconnecting"
        case .callEnded: "call.ended"
        case .callSignal: "call.signal"
        case .error: "error"
        case .pong: "pong"
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case let .hello(userId, deviceId, iceServers):
            try container.encode(userId, forKey: .userId)
            try container.encode(deviceId, forKey: .deviceId)
            try container.encode(iceServers, forKey: .iceServers)
        case let .presence(devices):
            try container.encode(devices, forKey: .devices)
        case let .callRinging(callId, callee, devices):
            try container.encode(callId, forKey: .callId)
            try container.encode(callee, forKey: .callee)
            try container.encode(devices, forKey: .devices)
        case let .callIncoming(callId, caller, video):
            try container.encode(callId, forKey: .callId)
            try container.encode(caller, forKey: .caller)
            try container.encode(video, forKey: .video)
        case let .callAccepted(callId, peer, role, video), let .callResumed(callId, peer, role, video):
            try container.encode(callId, forKey: .callId)
            try container.encode(peer, forKey: .peer)
            try container.encode(role, forKey: .role)
            try container.encode(video, forKey: .video)
        case let .callReconnecting(callId):
            try container.encode(callId, forKey: .callId)
        case let .callEnded(callId, reason):
            try container.encode(callId, forKey: .callId)
            try container.encode(reason, forKey: .reason)
        case let .callSignal(callId, from, signal):
            try container.encode(callId, forKey: .callId)
            try container.encode(from, forKey: .from)
            try container.encode(signal, forKey: .signal)
        case let .error(code, message, callId):
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(callId, forKey: .callId)
        case .pong:
            break
        }
    }
}
