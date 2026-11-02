import Foundation
import Observation

/// App-wide state: the session, the API client, and — while signed in — the call manager.
@Observable
final class AppModel {
    let sessionStore = SessionStore()
    let api: APIClient
    private(set) var calls: CallManager?

    var user: User? { sessionStore.session?.user }

    init() {
        api = APIClient(sessionStore: sessionStore)
        Log.info("App started", .app, ["server": ServerEnvironment.baseURL.absoluteString, "device": DeviceIdentity.name])
        if sessionStore.session != nil { startCalls() }
    }

    func signIn(email: String, password: String) async throws {
        let response = try await api.login(email: email, password: password)
        signedIn(response)
    }

    func register(email: String, username: String, password: String) async throws {
        let response = try await api.register(email: email, username: username, password: password)
        signedIn(response)
    }

    func signOut() async {
        Log.info("Signing out", .auth)
        stopCalls()
        await api.logout()
        sessionStore.set(nil)
    }

    /// The session ended outside our control (refresh token rejected).
    func sessionEnded() {
        Log.notice("Session ended", .auth)
        stopCalls()
    }

    /// Refreshes the stored user; a rejected session signs out via the API client.
    func validateSession() async {
        guard sessionStore.session != nil, let user = try? await api.me(), var session = sessionStore.session else { return }
        session.user = user
        sessionStore.set(session)
    }

    private func signedIn(_ response: AuthResponse) {
        Log.info("Signed in as \(response.user.username)", .auth)
        sessionStore.set(Session(accessToken: response.accessToken, refreshToken: response.refreshToken, user: response.user))
        startCalls()
    }

    private func startCalls() {
        guard calls == nil else { return }
        let manager = CallManager(api: api)
        manager.start()
        calls = manager
    }

    private func stopCalls() {
        calls?.stop()
        calls = nil
    }
}
