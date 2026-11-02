import Vapor
import Crypto
import Foundation

// MARK: - ICE Server Provider
//
// WebRTC needs STUN to discover each device's public address and TURN to relay
// media when a direct connection is impossible (symmetric NAT, strict mobile
// carriers, corporate Wi-Fi). STUN is free and stateless; TURN carries the
// actual media, so it is authenticated.
//
// Environment:
//   STUN_URLS        comma-separated, default "stun:stun.l.google.com:19302"
//   TURN_URLS        comma-separated, e.g. "turn:turn.example.com:3478?transport=udp,turns:turn.example.com:5349"
//   TURN_SECRET      coturn `static-auth-secret` → short-lived per-user credentials (preferred)
//   TURN_USERNAME / TURN_CREDENTIAL   static credentials (hosted TURN providers)
//   TURN_TTL_SECONDS lifetime of generated credentials, default 86400

struct IceServerProvider: Sendable {
    let stunURLs: [String]
    let turnURLs: [String]
    let turnSecret: String?
    let turnUsername: String?
    let turnCredential: String?
    let credentialTTL: Int

    init(
        stunURLs: [String] = ["stun:stun.l.google.com:19302"],
        turnURLs: [String] = [],
        turnSecret: String? = nil,
        turnUsername: String? = nil,
        turnCredential: String? = nil,
        credentialTTL: Int = 86_400
    ) {
        self.stunURLs = stunURLs
        self.turnURLs = turnURLs
        self.turnSecret = turnSecret
        self.turnUsername = turnUsername
        self.turnCredential = turnCredential
        self.credentialTTL = credentialTTL
    }

    static func fromEnvironment() -> IceServerProvider {
        func list(_ key: String) -> [String]? {
            Environment.get(key)?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        func value(_ key: String) -> String? {
            Environment.get(key).flatMap { $0.isEmpty ? nil : $0 }
        }

        return IceServerProvider(
            stunURLs: list("STUN_URLS") ?? ["stun:stun.l.google.com:19302"],
            turnURLs: list("TURN_URLS") ?? [],
            turnSecret: value("TURN_SECRET"),
            turnUsername: value("TURN_USERNAME"),
            turnCredential: value("TURN_CREDENTIAL"),
            credentialTTL: value("TURN_TTL_SECONDS").flatMap(Int.init) ?? 86_400
        )
    }

    var hasTURN: Bool {
        !turnURLs.isEmpty && (turnSecret != nil || (turnUsername != nil && turnCredential != nil))
    }

    func servers(for userId: UUID, now: Date = Date()) -> [IceServer] {
        var servers: [IceServer] = []
        if !stunURLs.isEmpty {
            servers.append(IceServer(urls: stunURLs))
        }
        guard !turnURLs.isEmpty else { return servers }

        if let turnSecret {
            // coturn REST API scheme: username = "<expiry>:<user>", password = base64(HMAC-SHA1(secret, username)).
            let expiry = Int(now.timeIntervalSince1970) + credentialTTL
            let username = "\(expiry):\(userId.uuidString)"
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: SymmetricKey(data: Data(turnSecret.utf8)))
            servers.append(IceServer(urls: turnURLs, username: username, credential: Data(mac).base64EncodedString()))
        } else if let turnUsername, let turnCredential {
            servers.append(IceServer(urls: turnURLs, username: turnUsername, credential: turnCredential))
        }
        return servers
    }
}
