import Vapor
import JWT

// MARK: - Call Controller
//
// GET /api/v1/calls/ws            WebSocket signaling (see SignalingMessage.swift)
// GET /api/v1/calls/ice-servers   STUN/TURN config for RTCPeerConnection (protected)
// GET /api/v1/calls/history       recent calls of the current user (protected)

final class CallController: RouteCollection, Sendable {
    /// An audio+video SDP offer is a few KB; leave headroom for many codecs.
    private static let maxFrameSize = 128 * 1024

    private let hub: CallHub
    private let iceServers: IceServerProvider
    private let callRepository: any CallRepositoryProtocol
    private let userRepository: any UserRepositoryProtocol

    init(
        hub: CallHub,
        iceServers: IceServerProvider,
        callRepository: any CallRepositoryProtocol,
        userRepository: any UserRepositoryProtocol
    ) {
        self.hub = hub
        self.iceServers = iceServers
        self.callRepository = callRepository
        self.userRepository = userRepository
    }

    func boot(routes: any RoutesBuilder) throws {
        let calls = routes.grouped("calls")

        calls.get("ws", use: upgrade)

        let protected = calls.grouped(JWTBearerAuthenticator(), UserAuthenticator())
        protected.get("ice-servers", use: getIceServers)
        protected.get("history", use: getHistory)
    }

    // MARK: - WebSocket

    /// Authenticates before upgrading, so a bad token gets a real `401` response.
    /// (A failing `shouldUpgrade` makes Vapor drop the TCP connection instead,
    /// which clients cannot tell apart from a network error.)
    func upgrade(_ req: Request) async throws -> Response {
        // Browsers cannot set headers on a WebSocket, so the access token may also
        // come as ?token=. Native clients should send the Authorization header.
        guard let token = req.headers.bearerAuthorization?.token ?? req.query[String.self, at: "token"] else {
            throw Abort(.unauthorized, reason: "Missing access token")
        }
        guard let payload = try? await req.jwt.verify(token, as: AccessTokenPayload.self),
              payload.tokenType == "access",
              let userId = UUID(uuidString: payload.subject.value),
              let user = try await userRepository.find(by: userId),
              user.isActive else {
            throw Abort(.unauthorized, reason: "Invalid access token")
        }
        req.auth.login(user)
        return req.webSocket(maxFrameSize: .init(integerLiteral: Self.maxFrameSize), onUpgrade: runSession)
    }

    func runSession(_ req: Request, _ ws: WebSocket) async {
        guard let user = req.auth.get(User.self), let userId = user.id else {
            try? await ws.close(code: .policyViolation)
            return
        }

        let peer = CallPeer(
            userId: userId,
            username: user.username,
            deviceId: Self.sanitizedDeviceId(req.query["deviceId"]) ?? UUID().uuidString,
            deviceName: Self.sanitizedDeviceName(req.query["deviceName"]) ?? "Unknown device"
        )
        let connection = WebSocketSignalingConnection(webSocket: ws, logger: req.logger)

        // Detect peers that vanished without closing the socket (phone lost signal):
        // if a ping goes unanswered until the next one, the socket is closed.
        ws.pingInterval = .seconds(15)

        // Handle messages strictly in arrival order: an SDP offer must reach the
        // other side before the ICE candidates that follow it. (WebSocketKit's async
        // `onText` spawns a Task per message, which does not preserve order.)
        let (messages, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(256))
        ws.onClose.whenComplete { _ in
            continuation.finish()
        }
        // Callbacks live in event-loop-bound storage: install them on the socket's loop.
        try? await ws.eventLoop.submit {
            ws.onText { ws, text in
                if case .dropped = continuation.yield(text) {
                    ws.close(code: .policyViolation, promise: nil)
                }
            }
            ws.onBinary { _, _ in
                connection.send(.error(code: .badRequest, message: "Binary frames are not supported", callId: nil))
            }
        }.get()

        // Clients wait for `hello` before sending: it goes out only after the
        // handlers above are installed.
        await hub.connect(connection, peer: peer, iceServers: iceServers.servers(for: userId))

        var rateLimit = TokenBucket(capacity: 60, refillPerSecond: 20)
        for await text in messages {
            guard rateLimit.take() else {
                connection.send(.error(code: .rateLimited, message: "Too many messages", callId: nil))
                continue
            }
            await handle(text, from: peer, connection: connection)
        }

        await hub.disconnect(connection, userId: userId, deviceId: peer.deviceId)
    }

    private func handle(_ text: String, from peer: CallPeer, connection: WebSocketSignalingConnection) async {
        let message: ClientMessage
        do {
            message = try JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8))
        } catch {
            connection.send(.error(code: .badRequest, message: Self.describe(error), callId: nil))
            return
        }

        let command: CallHub.Command
        switch message {
        case .ping:
            connection.send(.pong)
            return
        case let .invite(calleeId, calleeEmail, video):
            guard let callee = await resolveCallee(id: calleeId, email: calleeEmail) else {
                connection.send(.error(code: .userNotFound, message: "User not found", callId: nil))
                return
            }
            command = .invite(callee: callee, video: video)
        case let .accept(callId):
            command = .accept(callId: callId)
        case let .decline(callId):
            command = .decline(callId: callId)
        case let .hangup(callId):
            command = .hangup(callId: callId)
        case let .signal(callId, signal):
            command = .signal(callId: callId, signal: signal)
        }

        await hub.handle(command, from: connection, userId: peer.userId, deviceId: peer.deviceId)
    }

    private func resolveCallee(id: UUID?, email: String?) async -> CallUser? {
        let user: User?
        if let id {
            user = try? await userRepository.find(by: id)
        } else if let email {
            user = try? await userRepository.find(by: email.trimmingCharacters(in: .whitespaces))
        } else {
            user = nil
        }
        guard let user, user.isActive, let id = user.id else { return nil }
        return CallUser(id: id, username: user.username)
    }

    // MARK: - REST

    func getIceServers(_ req: Request) async throws -> IceServersResponse {
        let user = try req.auth.require(User.self)
        guard let userId = user.id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        return IceServersResponse(iceServers: iceServers.servers(for: userId), ttl: iceServers.credentialTTL)
    }

    func getHistory(_ req: Request) async throws -> CallHistoryResponse {
        let user = try req.auth.require(User.self)
        guard let userId = user.id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 50, 1), 200)
        let records = try await callRepository.history(for: userId, limit: limit)
        return CallHistoryResponse(calls: records.map { CallHistoryItem(record: $0, viewer: userId) })
    }

    // MARK: - Helpers

    static func sanitizedDeviceId(_ raw: String?) -> String? {
        guard let raw, (1...64).contains(raw.count) else { return nil }
        let allowed = raw.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
        }
        return allowed ? raw : nil
    }

    static func sanitizedDeviceName(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(64))
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let DecodingError.dataCorrupted(context):
            return "Malformed message: \(context.debugDescription)"
        case let DecodingError.keyNotFound(key, _):
            return "Malformed message: missing '\(key.stringValue)'"
        case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "Malformed message: invalid value at '\(path)'"
        default:
            return "Malformed message"
        }
    }
}

// MARK: - Rate Limiting

/// Per-connection token bucket: allows short bursts (ICE candidates arrive in
/// clumps) while capping the sustained rate.
struct TokenBucket {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant

    init(capacity: Double, refillPerSecond: Double) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefill = .now
    }

    mutating func take() -> Bool {
        let now = ContinuousClock.Instant.now
        let elapsed = lastRefill.duration(to: now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(capacity, tokens + seconds * refillPerSecond)
        lastRefill = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
