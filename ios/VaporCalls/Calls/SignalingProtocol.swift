import Foundation

// Wire format of the call WebSocket. Mirrors Sources/hello/Domain/Entities/SignalingMessage.swift
// on the server and web/src/calls/protocol.ts in the web app.

nonisolated enum CallRole: String, Codable, Sendable {
    case caller, callee
}

nonisolated struct CallPeer: Codable, Sendable, Equatable, Identifiable {
    let userId: UUID
    let username: String
    let deviceId: String
    let deviceName: String

    var id: String { deviceId }
}

nonisolated struct CallUser: Codable, Sendable, Equatable {
    let id: UUID
    let username: String
}

nonisolated struct IceServerConfig: Codable, Sendable, Equatable {
    let urls: [String]
    let username: String?
    let credential: String?
}

nonisolated struct IceCandidatePayload: Codable, Sendable, Equatable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int32?
    var usernameFragment: String? = nil
}

nonisolated struct SignalPayload: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case offer, answer, candidate
    }

    let kind: Kind
    var sdp: String? = nil
    var candidate: IceCandidatePayload? = nil
}

// MARK: - Server → client

nonisolated enum ServerMessage: Decodable, Sendable, Equatable {
    case hello(userId: UUID, deviceId: String, iceServers: [IceServerConfig])
    case presence(devices: [CallPeer])
    case ringing(callId: UUID, callee: CallUser, devices: Int)
    case incoming(callId: UUID, caller: CallPeer, video: Bool)
    case accepted(callId: UUID, peer: CallPeer, role: CallRole, video: Bool)
    case resumed(callId: UUID, peer: CallPeer, role: CallRole, video: Bool)
    case reconnecting(callId: UUID)
    case ended(callId: UUID, reason: CallEndReason)
    case signal(callId: UUID, from: String, signal: SignalPayload)
    case error(code: String, message: String, callId: UUID?)
    case pong
    /// A type this build does not know yet; ignored instead of failing.
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type, userId, deviceId, iceServers, devices, callId, callee, caller
        case video, peer, role, reason, from, signal, code, message
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(userId: try c.decode(UUID.self, forKey: .userId),
                          deviceId: try c.decode(String.self, forKey: .deviceId),
                          iceServers: try c.decode([IceServerConfig].self, forKey: .iceServers))
        case "presence":
            self = .presence(devices: try c.decode([CallPeer].self, forKey: .devices))
        case "call.ringing":
            self = .ringing(callId: try c.decode(UUID.self, forKey: .callId),
                            callee: try c.decode(CallUser.self, forKey: .callee),
                            devices: try c.decode(Int.self, forKey: .devices))
        case "call.incoming":
            self = .incoming(callId: try c.decode(UUID.self, forKey: .callId),
                             caller: try c.decode(CallPeer.self, forKey: .caller),
                             video: try c.decode(Bool.self, forKey: .video))
        case "call.accepted", "call.resumed":
            let callId = try c.decode(UUID.self, forKey: .callId)
            let peer = try c.decode(CallPeer.self, forKey: .peer)
            let role = try c.decode(CallRole.self, forKey: .role)
            let video = try c.decode(Bool.self, forKey: .video)
            self = type == "call.accepted"
                ? .accepted(callId: callId, peer: peer, role: role, video: video)
                : .resumed(callId: callId, peer: peer, role: role, video: video)
        case "call.reconnecting":
            self = .reconnecting(callId: try c.decode(UUID.self, forKey: .callId))
        case "call.ended":
            self = .ended(callId: try c.decode(UUID.self, forKey: .callId),
                          reason: try c.decode(CallEndReason.self, forKey: .reason))
        case "call.signal":
            self = .signal(callId: try c.decode(UUID.self, forKey: .callId),
                           from: try c.decode(String.self, forKey: .from),
                           signal: try c.decode(SignalPayload.self, forKey: .signal))
        case "error":
            self = .error(code: try c.decode(String.self, forKey: .code),
                          message: try c.decode(String.self, forKey: .message),
                          callId: try c.decodeIfPresent(UUID.self, forKey: .callId))
        case "pong":
            self = .pong
        default:
            self = .unknown(type: type)
        }
    }
}

// MARK: - Client → server

nonisolated enum ClientMessage: Encodable, Sendable, Equatable {
    case invite(calleeEmail: String?, calleeId: UUID?, video: Bool)
    case accept(callId: UUID)
    case decline(callId: UUID)
    case hangup(callId: UUID)
    case signal(callId: UUID, signal: SignalPayload)
    case ping

    private enum CodingKeys: String, CodingKey {
        case type, calleeEmail, calleeId, video, callId, signal
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .invite(email, id, video):
            try c.encode("call.invite", forKey: .type)
            try c.encodeIfPresent(email, forKey: .calleeEmail)
            try c.encodeIfPresent(id, forKey: .calleeId)
            try c.encode(video, forKey: .video)
        case let .accept(callId):
            try c.encode("call.accept", forKey: .type)
            try c.encode(callId, forKey: .callId)
        case let .decline(callId):
            try c.encode("call.decline", forKey: .type)
            try c.encode(callId, forKey: .callId)
        case let .hangup(callId):
            try c.encode("call.hangup", forKey: .type)
            try c.encode(callId, forKey: .callId)
        case let .signal(callId, signal):
            try c.encode("call.signal", forKey: .type)
            try c.encode(callId, forKey: .callId)
            try c.encode(signal, forKey: .signal)
        case .ping:
            try c.encode("ping", forKey: .type)
        }
    }
}

// MARK: - Log names

extension ServerMessage {
    /// Short description for logs; never includes SDP or ICE details.
    nonisolated var logName: String {
        switch self {
        case .hello: "hello"
        case let .presence(devices): "presence (\(devices.count) devices)"
        case let .ringing(id, _, n): "call.ringing \(id.uuidString.prefix(8)) on \(n)"
        case let .incoming(id, caller, video): "call.incoming \(id.uuidString.prefix(8)) from \(caller.deviceName)\(video ? " video" : "")"
        case let .accepted(id, _, role, _): "call.accepted \(id.uuidString.prefix(8)) as \(role.rawValue)"
        case let .resumed(id, _, role, _): "call.resumed \(id.uuidString.prefix(8)) as \(role.rawValue)"
        case let .reconnecting(id): "call.reconnecting \(id.uuidString.prefix(8))"
        case let .ended(id, reason): "call.ended \(id.uuidString.prefix(8)) \(reason.rawValue)"
        case let .signal(_, _, signal): "call.signal \(signal.kind.rawValue)"
        case let .error(code, message, _): "error \(code): \(message)"
        case .pong: "pong"
        case let .unknown(type): "unknown \(type)"
        }
    }
}

extension ClientMessage {
    nonisolated var logName: String {
        switch self {
        case let .invite(email, id, video): "call.invite \(email ?? id?.uuidString ?? "?")\(video ? " video" : "")"
        case let .accept(id): "call.accept \(id.uuidString.prefix(8))"
        case let .decline(id): "call.decline \(id.uuidString.prefix(8))"
        case let .hangup(id): "call.hangup \(id.uuidString.prefix(8))"
        case let .signal(_, signal): "call.signal \(signal.kind.rawValue)"
        case .ping: "ping"
        }
    }
}

nonisolated enum SignalingErrorText {
    static func text(for code: String, fallback: String) -> String {
        switch code {
        case "user_not_found": "Пользователь не найден"
        case "already_in_call": "Сначала завершите текущий звонок"
        case "call_not_found": "Звонок уже завершён"
        case "rate_limited": "Слишком много запросов, подождите"
        case "too_many_devices": "Подключено слишком много устройств"
        default: fallback
        }
    }
}
