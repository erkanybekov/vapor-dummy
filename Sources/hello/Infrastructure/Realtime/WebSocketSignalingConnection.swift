import Vapor

// MARK: - WebSocket Signaling Connection

/// Adapts a Vapor `WebSocket` to the hub's `SignalingConnection`. Writes are
/// queued on the socket's event loop, so `send` never blocks the hub.
final class WebSocketSignalingConnection: SignalingConnection {
    private let webSocket: WebSocket
    private let logger: Logger

    init(webSocket: WebSocket, logger: Logger) {
        self.webSocket = webSocket
        self.logger = logger
    }

    func send(_ message: ServerMessage) {
        do {
            let data = try JSONEncoder().encode(message)
            webSocket.send(String(decoding: data, as: UTF8.self), promise: nil)
        } catch {
            logger.error("Failed to encode signaling message", metadata: ["type": "\(message.type)", "error": "\(error)"])
        }
    }

    /// Close code telling the client it was replaced or refused and must not auto-reconnect.
    static let kickedCloseCode: UInt16 = 4000

    func close() {
        webSocket.close(code: .unknown(Self.kickedCloseCode), promise: nil)
    }
}
