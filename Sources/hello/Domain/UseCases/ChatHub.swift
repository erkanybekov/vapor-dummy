import Foundation

// MARK: - Chat Hub

/// Who is connected to which room, and the fan-out of frames to them. Storing
/// messages is not its job: the controller saves a message, then hands it to `broadcast`.
///
/// A connection joins in two steps so it neither misses nor duplicates anything:
/// `join` registers it and from then on holds live messages back, the controller
/// loads history, and `start` sends `welcome` with that history followed by the
/// held-back messages it did not already contain.
actor ChatHub {
    private struct Member {
        let connection: any ChatConnection
        let user: ChatUser
        /// Live messages that arrived before `start`; nil once started.
        var held: [ChatMessage]? = []
        /// Seqs already delivered in `welcome`, so a live copy is not sent again.
        var delivered: Set<Int> = []
        var isTyping = false
    }

    private var rooms: [String: [ObjectIdentifier: Member]] = [:]

    func join(_ connection: any ChatConnection, user: ChatUser, room: String) {
        let wasOnline = online(in: room).contains(user)
        rooms[room, default: [:]][ObjectIdentifier(connection)] = Member(connection: connection, user: user)
        if !wasOnline {
            send(.presence(online: online(in: room)), in: room)
        }
    }

    func start(_ connection: any ChatConnection, room: String, history: ChatHistory) {
        let id = ObjectIdentifier(connection)
        guard var member = rooms[room]?[id], let held = member.held else { return }
        member.held = nil
        member.delivered = Set(history.messages.map(\.seq))
        rooms[room]?[id] = member

        connection.send(.welcome(
            room: room,
            you: member.user,
            online: online(in: room),
            messages: history.messages,
            hasMore: history.hasMore
        ))
        for message in held.sorted(by: { $0.seq < $1.seq }) where !member.delivered.contains(message.seq) {
            connection.send(.message(message))
        }
        for other in rooms[room, default: [:]].values where other.isTyping && other.user != member.user {
            connection.send(.typing(user: other.user, isTyping: true))
        }
    }

    func leave(_ connection: any ChatConnection, room: String) {
        guard let member = rooms[room]?.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        if rooms[room]?.isEmpty == true {
            rooms[room] = nil
        }
        if member.isTyping {
            send(.typing(user: member.user, isTyping: false), in: room, except: member.user)
        }
        if !online(in: room).contains(member.user) {
            send(.presence(online: online(in: room)), in: room)
        }
    }

    /// Delivers a stored message to everyone in its room, the sender's own sockets included:
    /// that echo is how the sender learns the message was stored.
    func broadcast(_ message: ChatMessage) {
        guard let members = rooms[message.room] else { return }
        for (id, var member) in members where !member.delivered.contains(message.seq) {
            if member.held != nil {
                member.held?.append(message)
                rooms[message.room]?[id] = member
            } else {
                member.connection.send(.message(message))
            }
        }
    }

    /// Relays typing to the others in the room. Clients repeat `true` every few seconds
    /// while typing and treat it as expired after a few more, so every `true` is relayed.
    func setTyping(_ connection: any ChatConnection, room: String, isTyping: Bool) {
        let id = ObjectIdentifier(connection)
        guard var member = rooms[room]?[id], member.held == nil else { return }
        let wasTyping = member.isTyping
        member.isTyping = isTyping
        rooms[room]?[id] = member
        if isTyping || wasTyping {
            send(.typing(user: member.user, isTyping: isTyping), in: room, except: member.user)
        }
    }

    /// Distinct users with at least one socket in the room, by name.
    func online(in room: String) -> [ChatUser] {
        let users = Set(rooms[room, default: [:]].values.map(\.user))
        return users.sorted { ($0.username, $0.id.uuidString) < ($1.username, $1.id.uuidString) }
    }

    /// Sends to started members only; members still joining get the state in `welcome`.
    private func send(_ message: ChatServerMessage, in room: String, except user: ChatUser? = nil) {
        for member in rooms[room, default: [:]].values where member.held == nil && member.user != user {
            member.connection.send(message)
        }
    }
}
