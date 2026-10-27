import Vapor

// MARK: - Chat Controller
//
// GET /api/v1/chat/ws?room=general&after=<seq>     WebSocket chat (see Chat.swift)
// GET /api/v1/chat/rooms/:room/messages?before=     older history, newest page first (protected)

final class ChatController: RouteCollection, Sendable {
    /// A chat frame is small; this leaves room for a 2000-character message with escaping.
    private static let maxFrameSize = 16 * 1024

    private let hub: ChatHub
    private let repository: any ChatRepositoryProtocol
    private let authUseCase: AuthUseCase

    init(hub: ChatHub, repository: any ChatRepositoryProtocol, authUseCase: AuthUseCase) {
        self.hub = hub
        self.repository = repository
        self.authUseCase = authUseCase
    }

    func boot(routes: any RoutesBuilder) throws {
        let chat = routes.grouped("chat")

        chat.get("ws", use: upgrade)

        let protected = chat.grouped(JWTBearerAuthenticator(), UserAuthenticator())
        protected.get("rooms", ":room", "messages", use: getMessages)
    }

    // MARK: - WebSocket

    func upgrade(_ req: Request) async throws -> Response {
        _ = try await req.authenticateWebSocket(with: authUseCase)
        let room = req.query[String.self, at: "room"] ?? "general"
        guard ChatLimits.isValidRoom(room) else {
            throw Abort.rejectedUpgrade(.badRequest, reason: "Room names are 1-32 lowercase letters, digits or dashes")
        }
        return req.webSocket(maxFrameSize: .init(integerLiteral: Self.maxFrameSize), onUpgrade: runSession)
    }

    func runSession(_ req: Request, _ ws: WebSocket) async {
        guard let user = req.auth.get(User.self), let userId = user.id else {
            try? await ws.close(code: .policyViolation)
            return
        }
        let me = ChatUser(id: userId, username: user.username)
        let room = req.query[String.self, at: "room"] ?? "general"
        let after = req.query[Int.self, at: "after"]
        let connection = WebSocketChatConnection(webSocket: ws, logger: req.logger)

        // A peer that vanished without closing (phone lost signal) stops answering
        // pings, and the socket is closed.
        ws.pingInterval = .seconds(20)

        // Handle frames one at a time, in arrival order. (WebSocketKit's async
        // `onText` would start a Task per frame, which does not keep the order.)
        let (frames, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(64))
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
                connection.send(.error(code: .badRequest, message: "Send JSON as text frames", clientId: nil))
            }
        }.get()

        await hub.join(connection, user: me, room: room)
        do {
            let history = try await repository.history(room: room, after: after, before: nil, limit: ChatLimits.historyPageSize)
            await hub.start(connection, room: room, history: history)
        } catch {
            req.logger.error("Failed to load chat history", metadata: ["room": "\(room)", "error": "\(error)"])
            await hub.leave(connection, room: room)
            try? await ws.close(code: .unexpectedServerError)
            return
        }

        var rateLimit = TokenBucket(capacity: 20, refillPerSecond: 5)
        for await text in frames {
            guard rateLimit.take() else {
                connection.send(.error(code: .rateLimited, message: "Too many messages, slow down", clientId: nil))
                continue
            }
            await handle(text, from: me, room: room, connection: connection, logger: req.logger)
        }

        await hub.leave(connection, room: room)
    }

    private func handle(_ text: String, from user: ChatUser, room: String, connection: WebSocketChatConnection, logger: Logger) async {
        let message: ChatClientMessage
        do {
            message = try JSONDecoder().decode(ChatClientMessage.self, from: Data(text.utf8))
        } catch {
            connection.send(.error(code: .badRequest, message: Self.describe(error), clientId: nil))
            return
        }

        switch message {
        case .ping:
            connection.send(.pong)
        case let .typing(isTyping):
            await hub.setTyping(connection, room: room, isTyping: isTyping)
        case let .send(clientId, rawText):
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...ChatLimits.maxClientIdLength).contains(clientId.count) else {
                connection.send(.error(code: .invalidMessage, message: "clientId must be 1-\(ChatLimits.maxClientIdLength) characters", clientId: nil))
                return
            }
            guard (1...ChatLimits.maxTextLength).contains(text.count) else {
                connection.send(.error(code: .invalidMessage, message: "Text must be 1-\(ChatLimits.maxTextLength) characters", clientId: clientId))
                return
            }
            do {
                let (saved, isNew) = try await repository.save(room: room, author: user, text: text, clientId: clientId)
                await hub.setTyping(connection, room: room, isTyping: false)
                if isNew {
                    await hub.broadcast(saved)
                } else {
                    // A resend of a stored message: only the sender needs the confirmation.
                    connection.send(.message(saved))
                }
            } catch {
                logger.error("Failed to save chat message", metadata: ["room": "\(room)", "error": "\(error)"])
                connection.send(.error(code: .serverError, message: "Message not saved, try again", clientId: clientId))
            }
        }
    }

    // MARK: - REST

    /// Older messages for scrolling up: the page before `before`, oldest first.
    func getMessages(_ req: Request) async throws -> ChatHistoryResponse {
        guard let room = req.parameters.get("room"), ChatLimits.isValidRoom(room) else {
            throw Abort(.badRequest, reason: "Invalid room")
        }
        let limit = min(max(req.query[Int.self, at: "limit"] ?? ChatLimits.historyPageSize, 1), 100)
        let history = try await repository.history(room: room, after: nil, before: req.query[Int.self, at: "before"], limit: limit)
        return ChatHistoryResponse(messages: history.messages, hasMore: history.hasMore)
    }

    // MARK: - Helpers

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

struct ChatHistoryResponse: Content {
    let messages: [ChatMessage]
    let hasMore: Bool
}
