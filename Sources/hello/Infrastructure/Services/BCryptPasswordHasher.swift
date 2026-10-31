import Vapor
import Foundation
import NIOPosix

// MARK: - BCrypt Password Hasher Implementation

/// Bcrypt is slow on purpose and holds its thread the whole time, so it runs on the
/// blocking thread pool: Swift Concurrency has only a few threads, shared with the
/// request handlers and the call hub.
final class BCryptPasswordHasher: PasswordHasherProtocol, Sendable {
    private let threadPool: NIOThreadPool
    private let cost: Int

    init(threadPool: NIOThreadPool, cost: Int = 12) {
        self.threadPool = threadPool
        self.cost = cost
    }

    func hash(_ password: String) async throws -> String {
        try await threadPool.runIfActive { [cost] in
            try Bcrypt.hash(password, cost: cost)
        }
    }

    func verify(_ password: String, against hash: String) async throws -> Bool {
        try await threadPool.runIfActive {
            try Bcrypt.verify(password, created: hash)
        }
    }
}
