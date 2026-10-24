import Foundation

/// Which Vapor server the app talks to. Production is the Render deploy; the
/// login screen can switch to a local `swift run` for development (the
/// simulator reaches the Mac's localhost directly).
enum ServerEnvironment {
    static let production = URL(string: "https://vapor-calls.onrender.com")!
    static let local = URL(string: "http://localhost:8080")!

    private static let key = "server.baseURL"

    static var baseURL: URL {
        get { UserDefaults.standard.url(forKey: key) ?? production }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var apiURL: URL { baseURL.appending(path: "api/v1") }

    /// ws(s)://host/api/v1/calls/ws
    static var signalingURL: URL {
        var components = URLComponents(url: apiURL.appending(path: "calls/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }
}
