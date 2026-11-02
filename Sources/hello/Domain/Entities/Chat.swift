import Foundation

// MARK: - Chat
//
// A group chat over WebSocket, kept small on purpose: it is the training ground
// for writing WebSocket clients (see the guide in the web app). Every frame is a
// JSON object with a "type" field.
//
// Client → server: send, typing, ping
// Server → client: welcome, message, presence, typing, error, pong

struct ChatUser: Codable, Hashable, Sendable {
    let id: UUID
    let username: String
}

struct ChatMessage: Codable, Equatable, Sendable {
    /// Assigned by the server and always increasing. Clients sort by it and, when
    /// reconnecting, pass the last one they have as `?after=` to get what they missed.
    let seq: Int
    let room: String
    let author: ChatUser
    let text: String
    let sentAt: Date
    /// The sender's own id for the message, echoed back so the sender can replace its
    /// pending copy, and so a resend after a reconnect is not stored twice.
    let clientId: String
}

enum ChatLimits {
    static let maxTextLength = 2000
    static let maxClientIdLength = 64
    static let historyPageSize = 50

    /// Room names travel in URLs: lowercase letters, digits and dashes.
    static func isValidRoom(_ room: String) -> Bool {
        (1...32).contains(room.count) && room.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}

// MARK: - Client → Server

enum ChatClientMessage: Decodable, Equatable {
    case send(clientId: String, text: String)
    case typing(isTyping: Bool)
    case ping

    private enum CodingKeys: String, CodingKey {
        case type, clientId, text, isTyping
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "send":
            self = .send(
                clientId: try container.decode(String.self, forKey: .clientId),
                text: try container.decode(String.self, forKey: .text)
            )
        case "typing":
            self = .typing(isTyping: try container.decode(Bool.self, forKey: .isTyping))
        case "ping":
            self = .ping
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown message type '\(type)'")
        }
    }
}

// MARK: - Server → Client

enum ChatErrorCode: String, Codable, Sendable {
    case badRequest = "bad_request"
    case rateLimited = "rate_limited"
    case invalidMessage = "invalid_message"
    case serverError = "server_error"
}

enum ChatServerMessage: Encodable, Equatable, Sendable {
    /// First frame on every connection: who you are, who is here, and recent history
    /// (oldest first). `hasMore` means older messages exist than the ones included.
    case welcome(room: String, you: ChatUser, online: [ChatUser], messages: [ChatMessage], hasMore: Bool)
    case message(ChatMessage)
    case presence(online: [ChatUser])
    case typing(user: ChatUser, isTyping: Bool)
    /// `clientId` is set when the error is about a message the client tried to send.
    case error(code: ChatErrorCode, message: String, clientId: String?)
    case pong

    private enum CodingKeys: String, CodingKey {
        case type, room, you, online, messages, hasMore, message, user, isTyping, code, clientId
    }

    var type: String {
        switch self {
        case .welcome: "welcome"
        case .message: "message"
        case .presence: "presence"
        case .typing: "typing"
        case .error: "error"
        case .pong: "pong"
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case let .welcome(room, you, online, messages, hasMore):
            try container.encode(room, forKey: .room)
            try container.encode(you, forKey: .you)
            try container.encode(online, forKey: .online)
            try container.encode(messages, forKey: .messages)
            try container.encode(hasMore, forKey: .hasMore)
        case let .message(message):
            try container.encode(message, forKey: .message)
        case let .presence(online):
            try container.encode(online, forKey: .online)
        case let .typing(user, isTyping):
            try container.encode(user, forKey: .user)
            try container.encode(isTyping, forKey: .isTyping)
        case let .error(code, message, clientId):
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(clientId, forKey: .clientId)
        case .pong:
            break
        }
    }
}
