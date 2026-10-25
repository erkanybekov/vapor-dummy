import Foundation

struct APIError: LocalizedError {
    /// HTTP status, or 0 when the server could not be reached.
    let status: Int
    let message: String

    var errorDescription: String? { message }
}

/// Talks to the Vapor REST API. Refreshes the access token shortly before it
/// expires, and on a 401 refreshes once and retries. Refresh tokens are
/// single-use on the server, so concurrent callers share one refresh.
final class APIClient {
    private let sessionStore: SessionStore
    private var refreshTask: Task<Session, any Error>?

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    // MARK: - Tokens

    /// A valid access token, refreshed first if it expires within a minute.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let session = sessionStore.session else { throw APIError(status: 401, message: "Нужно войти") }
        if !forceRefresh, let expiry = Self.expiry(of: session.accessToken), expiry.timeIntervalSinceNow > 60 {
            return session.accessToken
        }
        return try await refresh().accessToken
    }

    func refresh() async throws -> Session {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> Session {
        guard let session = sessionStore.session else { throw APIError(status: 401, message: "Нужно войти") }
        do {
            let response: AuthResponse = try await perform("POST", "auth/refresh", body: ["refreshToken": session.refreshToken], token: nil)
            let next = Session(accessToken: response.accessToken, refreshToken: response.refreshToken, user: response.user)
            sessionStore.set(next)
            Log.info("Access token refreshed", .auth)
            return next
        } catch let error as APIError where error.status == 401 || error.status == 403 {
            Log.warning("Refresh token rejected, signing out", .auth, ["status": "\(error.status)"])
            sessionStore.set(nil)
            throw error
        }
    }

    static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Requests

    func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await authorized("GET", path, body: Optional<String>.none)
    }

    func send<Response: Decodable>(_ method: String, _ path: String, body: (some Encodable)? = Optional<String>.none) async throws -> Response {
        try await authorized(method, path, body: body)
    }

    func sendWithoutAuth<Response: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> Response {
        try await perform(method, path, body: body, token: nil)
    }

    private func authorized<Response: Decodable>(_ method: String, _ path: String, body: (some Encodable)?) async throws -> Response {
        do {
            return try await perform(method, path, body: body, token: try await accessToken())
        } catch let error as APIError where error.status == 401 {
            // Rejected before expiry (revoked, secret rotated): refresh once and retry.
            Log.notice("401 on \(method) \(path), refreshing and retrying", .auth)
            return try await perform(method, path, body: body, token: try await refresh().accessToken)
        }
    }

    /// `path` may carry a query ("todos?page=1"); `appending(path:)` alone would escape the "?".
    static func url(for path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1)
        var components = URLComponents(
            url: ServerEnvironment.apiURL.appending(path: String(parts.first ?? "")),
            resolvingAgainstBaseURL: false
        )!
        if parts.count > 1 { components.percentEncodedQuery = String(parts[1]) }
        return components.url!
    }

    private func perform<Response: Decodable>(_ method: String, _ path: String, body: (some Encodable)?, token: String?) async throws -> Response {
        var request = URLRequest(url: Self.url(for: path))
        request.httpMethod = method
        request.timeoutInterval = 70 // the free Render instance can take a minute to wake up
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            // Recorded in the Pulse network inspector (with secrets redacted).
            (data, response) = try await Log.session.data(for: request)
        } catch {
            Log.error(error, .api, "\(method) \(path)")
            throw APIError(status: 0, message: "Нет связи с сервером")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reason = (try? JSONDecoder().decode([String: AnyDecodable].self, from: data))?["reason"]?.string
            Log.warning("\(method) \(path) → \(status)", .api, ["reason": reason ?? "—"])
            throw APIError(status: status, message: reason ?? "Ошибка сервера (\(status))")
        }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            Log.error(error, .api, "Decoding \(Response.self) from \(path)")
            throw APIError(status: status, message: "Неожиданный ответ сервера")
        }
    }
}

/// Decodes any JSON value; only strings are kept (used to read `reason`).
private nonisolated struct AnyDecodable: Decodable {
    let string: String?

    init(from decoder: any Decoder) throws {
        string = try? decoder.singleValueContainer().decode(String.self)
    }
}

// MARK: - Endpoints

extension APIClient {
    private struct LoginBody: Encodable { let email: String; let password: String }
    private struct RegisterBody: Encodable { let email: String; let username: String; let password: String }
    private struct NewTodo: Encodable { let title: String; let description: String? }
    struct TodoChanges: Encodable { var title: String?; var description: String?; var completed: Bool? }
    private struct Message: Decodable { let message: String }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await sendWithoutAuth("POST", "auth/login", body: LoginBody(email: email, password: password))
    }

    func register(email: String, username: String, password: String) async throws -> AuthResponse {
        try await sendWithoutAuth("POST", "auth/register", body: RegisterBody(email: email, username: username, password: password))
    }

    func me() async throws -> User {
        try await get("auth/me")
    }

    /// Revokes both tokens on the server. Refreshes first if due, so the refresh
    /// token revoked is the current one.
    func logout() async {
        guard (try? await accessToken()) != nil, let session = sessionStore.session else { return }
        let _: Message? = try? await send("POST", "auth/logout", body: ["refreshToken": session.refreshToken])
    }

    func todos(page: Int, limit: Int) async throws -> TodoPage {
        try await get("todos?page=\(page)&limit=\(limit)")
    }

    func createTodo(title: String, description: String?) async throws -> Todo {
        try await send("POST", "todos", body: NewTodo(title: title, description: description))
    }

    func updateTodo(id: UUID, changes: TodoChanges) async throws -> Todo {
        try await send("PUT", "todos/\(id.uuidString)", body: changes)
    }

    func toggleTodo(id: UUID) async throws -> Todo {
        try await send("PATCH", "todos/\(id.uuidString)/toggle")
    }

    func deleteTodo(id: UUID) async throws {
        let _: Message = try await send("DELETE", "todos/\(id.uuidString)")
    }

    func callHistory(limit: Int = 30) async throws -> [CallHistoryItem] {
        let response: CallHistoryResponse = try await get("calls/history?limit=\(limit)")
        return response.calls
    }
}
