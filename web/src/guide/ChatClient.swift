import Foundation
import Network
import Observation

// MARK: - Протокол (что ходит по сокету)

struct ChatUser: Codable, Hashable, Sendable {
    let id: UUID
    let username: String
}

struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    let seq: Int          // номер от сервера: по нему сортируем и убираем дубли
    let room: String
    let author: ChatUser
    let text: String
    let sentAt: Date
    let clientId: String  // наш id сообщения, сервер возвращает его обратно
    var id: Int { seq }
}

struct Welcome: Decodable, Sendable {
    let room: String
    let you: ChatUser
    let online: [ChatUser]
    let messages: [ChatMessage]
    let hasMore: Bool
}

/// Всё, что может прислать сервер. Неизвестный type не роняет клиент.
enum ServerEvent: Decodable, Sendable {
    case welcome(Welcome)
    case message(ChatMessage)
    case presence([ChatUser])
    case typing(user: ChatUser, isTyping: Bool)
    case error(code: String, message: String, clientId: String?)
    case pong
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case type, message, online, user, isTyping, code, clientId
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "welcome":
            self = .welcome(try Welcome(from: decoder))
        case "message":
            self = .message(try c.decode(ChatMessage.self, forKey: .message))
        case "presence":
            self = .presence(try c.decode([ChatUser].self, forKey: .online))
        case "typing":
            self = .typing(user: try c.decode(ChatUser.self, forKey: .user),
                           isTyping: try c.decode(Bool.self, forKey: .isTyping))
        case "error":
            self = .error(code: try c.decode(String.self, forKey: .code),
                          message: try c.decode(String.self, forKey: .message),
                          clientId: try c.decodeIfPresent(String.self, forKey: .clientId))
        case "pong":
            self = .pong
        case let other:
            self = .unknown(other)
        }
    }
}

/// Всё, что отправляем мы.
enum ClientFrame: Encodable, Sendable {
    case send(clientId: String, text: String)
    case typing(Bool)
    case ping

    private enum CodingKeys: String, CodingKey {
        case type, clientId, text, isTyping
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .send(clientId, text):
            try c.encode("send", forKey: .type)
            try c.encode(clientId, forKey: .clientId)
            try c.encode(text, forKey: .text)
        case let .typing(isTyping):
            try c.encode("typing", forKey: .type)
            try c.encode(isTyping, forKey: .isTyping)
        case .ping:
            try c.encode("ping", forKey: .type)
        }
    }
}

// MARK: - Клиент

/// Держит одно соединение с комнатой чата: переподключается сам, догружает
/// пропущенное, досылает неотправленное. Всё состояние живёт на главном потоке,
/// поэтому SwiftUI может читать его напрямую.
@MainActor
@Observable
final class ChatClient {
    enum State: Equatable {
        case disconnected, connecting, connected
    }

    /// Сообщение, которое мы отправили, но сервер ещё не подтвердил.
    struct Pending: Identifiable, Equatable {
        let clientId: String
        let text: String
        var failed = false
        var id: String { clientId }
    }

    private(set) var state: State = .disconnected
    private(set) var me: ChatUser?
    private(set) var messages: [ChatMessage] = []
    private(set) var pending: [Pending] = []
    private(set) var online: [ChatUser] = []
    private(set) var typingUsers: [ChatUser] = []
    private(set) var lastError: String?

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let room: String
    /// Возвращает access-токен; `true` — «этот отвергнут, обнови».
    @ObservationIgnored private let token: (_ forceRefresh: Bool) async throws -> String

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var connecting = false
    /// Растёт при каждом подключении: старые циклы видят, что они уже не главные.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var tokenRejected = false
    @ObservationIgnored private var awaitingPong = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var typingSentAt: Date?
    @ObservationIgnored private var typingUntil: [UUID: Date] = [:]

    @ObservationIgnored private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(url: URL, room: String = "general", token: @escaping (_ forceRefresh: Bool) async throws -> String) {
        self.url = url
        self.room = room
        self.token = token
    }

    // MARK: Управление

    func start() {
        guard !running else { return }
        running = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.reconnectNow() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        connect()
    }

    func stop() {
        running = false
        generation += 1
        connecting = false
        reconnectTask?.cancel()
        pingTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = .disconnected
    }

    /// Сеть вернулась или приложение открыли: не ждём паузу, подключаемся сразу.
    func reconnectNow() {
        guard running, task == nil, !connecting else { return }
        reconnectTask?.cancel()
        attempt = 0
        connect()
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let item = Pending(clientId: UUID().uuidString, text: text)
        pending.append(item)
        typingSentAt = nil
        // Без соединения сообщение ждёт в pending и уйдёт после следующего welcome.
        if state == .connected {
            transmit(.send(clientId: item.clientId, text: item.text))
        }
    }

    func retry(_ item: Pending) {
        guard let index = pending.firstIndex(of: item) else { return }
        pending[index].failed = false
        if state == .connected {
            transmit(.send(clientId: item.clientId, text: item.text))
        }
    }

    /// Звать на каждое изменение поля ввода. Шлёт typing не чаще раза в 3 с.
    func draftChanged(_ draft: String) {
        guard state == .connected else { return }
        if draft.isEmpty {
            if typingSentAt != nil { transmit(.typing(false)) }
            typingSentAt = nil
        } else if typingSentAt.map({ Date().timeIntervalSince($0) > 3 }) ?? true {
            typingSentAt = Date()
            transmit(.typing(true))
        }
    }

    // MARK: Соединение

    private func connect() {
        guard running, task == nil, !connecting else { return }
        connecting = true
        generation += 1
        let generation = generation
        state = .connecting

        Task {
            let accessToken: String
            do {
                accessToken = try await token(tokenRejected)
            } catch {
                guard generation == self.generation else { return }
                connecting = false
                scheduleReconnect()
                return
            }
            guard generation == self.generation, running else { return }
            connecting = false

            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var query = [URLQueryItem(name: "room", value: room)]
            // Переподключение: просим только то, что пропустили.
            if let lastSeq = messages.last?.seq {
                query.append(URLQueryItem(name: "after", value: String(lastSeq)))
            }
            components.queryItems = query
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()
            await receive(from: task, generation: generation, resuming: messages.last != nil)
        }
    }

    private func receive(from task: URLSessionWebSocketTask, generation: Int, resuming: Bool) async {
        do {
            while true {
                let frame = try await task.receive()
                guard generation == self.generation else { return }
                switch frame {
                case let .string(text): handle(Data(text.utf8), resuming: resuming)
                case let .data(data): handle(data, resuming: resuming)
                @unknown default: break
                }
            }
        } catch {
            guard generation == self.generation else { return }
            // Ответ на рукопожатие виден даже после ошибки: 401 значит «обнови токен».
            let status = (task.response as? HTTPURLResponse)?.statusCode
            tokenRejected = status == 401
            self.task = nil
            pingTask?.cancel()
            state = .disconnected
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard running else { return }
        // 0.5, 1, 2, 4 … до 30 с, плюс случайная добавка, чтобы клиенты не ломились разом.
        let delay = min(30, 0.5 * pow(2, Double(attempt))) + Double.random(in: 0...0.5)
        attempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func transmit(_ frame: ClientFrame) {
        guard let task, let data = try? JSONEncoder().encode(frame) else { return }
        Task {
            // Если отправка не удалась, receive() тоже упадёт и запустит переподключение.
            try? await task.send(.string(String(decoding: data, as: UTF8.self)))
        }
    }

    /// Раз в 20 с ping. Не пришёл pong до следующего — соединение мёртвое, рвём его сами.
    private func startPinging(_ task: URLSessionWebSocketTask, generation: Int) {
        pingTask?.cancel()
        awaitingPong = false
        pingTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(20))
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                if awaitingPong {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
                awaitingPong = true
                task.sendPing { [weak self] error in
                    guard error == nil else { return }
                    Task { @MainActor in self?.awaitingPong = false }
                }
            }
        }
    }

    // MARK: Входящие

    private func handle(_ data: Data, resuming: Bool) {
        let event: ServerEvent
        do {
            event = try decoder.decode(ServerEvent.self, from: data)
        } catch {
            lastError = "Непонятный кадр: \(error)"
            return
        }

        switch event {
        case let .welcome(welcome):
            state = .connected
            attempt = 0
            tokenRejected = false
            me = welcome.you
            online = welcome.online
            if resuming && welcome.hasMore {
                // Пропустили больше, чем сервер отдал: между старым и новым дыра.
                messages = welcome.messages
            } else {
                merge(welcome.messages)
            }
            // Досылаем всё неподтверждённое. Повтор с тем же clientId сервер не задвоит.
            for item in pending where !item.failed {
                transmit(.send(clientId: item.clientId, text: item.text))
            }
            if let task { startPinging(task, generation: generation) }

        case let .message(message):
            merge([message])
            pending.removeAll { $0.clientId == message.clientId }
            typingUntil[message.author.id] = nil
            refreshTyping()

        case let .presence(users):
            online = users

        case let .typing(user, isTyping):
            typingUntil[user.id] = isTyping ? Date().addingTimeInterval(6) : nil
            refreshTyping(adding: isTyping ? user : nil)
            if isTyping {
                // Повторов нет 6 с — человек перестал печатать или пропал.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6.1))
                    self?.refreshTyping()
                }
            }

        case let .error(_, message, clientId):
            lastError = message
            if let clientId, let index = pending.firstIndex(where: { $0.clientId == clientId }) {
                pending[index].failed = true
            }

        case .pong, .unknown:
            break
        }
    }

    /// Добавляет сообщения без дублей и по порядку seq.
    private func merge(_ incoming: [ChatMessage]) {
        var bySeq = Dictionary(messages.map { ($0.seq, $0) }, uniquingKeysWith: { first, _ in first })
        for message in incoming {
            bySeq[message.seq] = message
        }
        messages = bySeq.values.sorted { $0.seq < $1.seq }
    }

    private func refreshTyping(adding user: ChatUser? = nil) {
        let now = Date()
        var users = typingUsers
        if let user, !users.contains(user) { users.append(user) }
        typingUsers = users.filter { (typingUntil[$0.id] ?? .distantPast) > now }
    }
}
