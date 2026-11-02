import Foundation
import Observation
import Security

nonisolated struct Session: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var user: User
}

/// The signed-in session, kept in the Keychain so tokens survive relaunches
/// and are readable after the first unlock (needed while a call runs locked).
@Observable
final class SessionStore {
    private(set) var session: Session?

    private let service = "com.erlankanybekov.VaporCalls"
    private let account = "session"

    init() {
        session = load()
    }

    func set(_ session: Session?) {
        self.session = session
        if let session, let data = try? JSONEncoder().encode(session) {
            save(data)
        } else {
            delete()
        }
    }

    // MARK: - Keychain

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func load() -> Session? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    private func save(_ data: Data) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    private func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
