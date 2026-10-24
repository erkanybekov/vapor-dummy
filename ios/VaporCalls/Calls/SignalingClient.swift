import Foundation
import UIKit

/// Keeps one signaling WebSocket alive while the app is in the foreground:
/// exponential backoff on failure, immediate reconnect when the app becomes
/// active again, and an app-level ping so proxies keep the socket open.
///
/// iOS suspends the app soon after it goes to the background, which kills the
/// socket; waking a closed app for a call needs VoIP push (PushKit), which a
/// free Personal Team cannot use.
final class SignalingClient {
    enum State: Equatable {
        case offline, connecting, online
    }

    var onMessage: (ServerMessage) -> Void = { _ in }
    var onState: (State) -> Void = { _ in }

    private let getToken: (_ force: Bool) async throws -> String
    private let deviceId: String
    private let deviceName: String

    private var task: URLSessionWebSocketTask?
    private var running = false
    /// Bumped by stop(); work started for an older generation is discarded.
    private var generation = 0
    private var connecting = false
    private var gotHello = false
    private var attempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    init(deviceId: String, deviceName: String, getToken: @escaping (_ force: Bool) async throws -> String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.getToken = getToken
    }

    func start() {
        guard !running else { return }
        running = true
        attempt = 0
        connect()
    }

    func stop() {
        running = false
        generation += 1
        connecting = false
        reconnectTask?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        gotHello = false
        onState(.offline)
    }

    /// Reconnect right away (app came to the foreground, network changed).
    func wake() {
        guard running, task == nil, !connecting else { return }
        reconnectTask?.cancel()
        attempt = 0
        connect()
    }

    @discardableResult
    func send(_ message: ClientMessage) -> Bool {
        guard let task, gotHello, let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return false }
        task.send(.string(text)) { _ in }
        return true
    }

    // MARK: - Connection

    private func connect() {
        guard running, task == nil, !connecting else { return }
        connecting = true
        let generation = self.generation
        onState(.connecting)

        Task {
            let token: String
            do {
                // If the last socket died before `hello`, the token may have been
                // rejected (a WebSocket cannot see the 401), so refresh it.
                token = try await getToken(attempt > 0)
            } catch {
                guard generation == self.generation else { return }
                connecting = false
                scheduleReconnect()
                return
            }
            guard generation == self.generation, running else { return }
            connecting = false

            var components = URLComponents(url: ServerEnvironment.signalingURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "deviceId", value: deviceId),
                URLQueryItem(name: "deviceName", value: deviceName),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let task = URLSession.shared.webSocketTask(with: request)
            task.maximumMessageSize = 1 << 20
            self.task = task
            gotHello = false
            task.resume()
            await receive(on: task, generation: generation)
        }
    }

    private func receive(on task: URLSessionWebSocketTask, generation: Int) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                closed(task, generation: generation)
                return
            }
            guard generation == self.generation, task === self.task else { return }

            let data: Data? = switch message {
            case let .string(text): text.data(using: .utf8)
            case let .data(data): data
            @unknown default: nil
            }
            guard let data, let decoded = try? JSONDecoder().decode(ServerMessage.self, from: data) else { continue }

            if case .hello = decoded {
                // Only now does the server accept messages from us.
                gotHello = true
                attempt = 0
                onState(.online)
                startPinging(generation: generation)
            }
            onMessage(decoded)
        }
    }

    private func closed(_ task: URLSessionWebSocketTask, generation: Int) {
        guard generation == self.generation, task === self.task else { return }
        self.task = nil
        gotHello = false
        pingTask?.cancel()
        onState(.offline)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard running else { return }
        let delay = min(10.0, 0.5 * pow(2, Double(attempt))) + Double.random(in: 0...0.3)
        attempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func startPinging(generation: Int) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, generation == self.generation else { return }
                send(.ping)
            }
        }
    }
}

// MARK: - Device identity

enum DeviceIdentity {
    /// Stable per install, so the server can resume a call after the app reconnects.
    static let id: String = {
        let key = "device.id"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static var name: String {
        #if targetEnvironment(simulator)
        "\(UIDevice.current.model) Simulator · App"
        #else
        "\(UIDevice.current.model) · App"
        #endif
    }
}
