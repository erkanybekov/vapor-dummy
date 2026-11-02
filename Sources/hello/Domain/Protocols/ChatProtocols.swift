import Foundation

// MARK: - Chat Repository Protocol

struct ChatHistory: Sendable {
    /// Oldest first.
    let messages: [ChatMessage]
    /// Older messages in the requested range were left out.
    let hasMore: Bool
}

protocol ChatRepositoryProtocol: Sendable {
    /// Stores the message. If this author already sent this `clientId` (a resend after a
    /// reconnect), returns the stored message with `isNew` false instead.
    func save(room: String, author: ChatUser, text: String, clientId: String) async throws -> (message: ChatMessage, isNew: Bool)
    /// The newest `limit` messages of the room with `after < seq < before` (each bound optional).
    func history(room: String, after: Int?, before: Int?, limit: Int) async throws -> ChatHistory
}

// MARK: - Chat Connection

/// One open chat socket. Must be safe to call from any thread and must not block.
protocol ChatConnection: AnyObject, Sendable {
    func send(_ message: ChatServerMessage)
    func close()
}
