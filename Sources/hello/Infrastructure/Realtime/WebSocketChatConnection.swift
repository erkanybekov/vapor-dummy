import Vapor

// MARK: - WebSocket Chat Connection

/// Adapts a Vapor `WebSocket` to the chat hub. Writes are queued on the socket's
/// event loop, so `send` never blocks the hub.
final class WebSocketChatConnection: ChatConnection {
    private let webSocket: WebSocket
    private let logger: Logger

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(webSocket: WebSocket, logger: Logger) {
        self.webSocket = webSocket
        self.logger = logger
    }

    func send(_ message: ChatServerMessage) {
        do {
            let data = try Self.encoder.encode(message)
            webSocket.send(String(decoding: data, as: UTF8.self), promise: nil)
        } catch {
            logger.error("Failed to encode chat message", metadata: ["type": "\(message.type)", "error": "\(error)"])
        }
    }

    func close() {
        webSocket.close(code: .normalClosure, promise: nil)
    }
}
