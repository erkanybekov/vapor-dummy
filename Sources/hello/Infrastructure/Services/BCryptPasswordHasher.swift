import Vapor
import Foundation

// MARK: - BCrypt Password Hasher Implementation
final class BCryptPasswordHasher: PasswordHasherProtocol, Sendable {
    private let cost: Int
    
    init(cost: Int = 12) {
        self.cost = cost
    }
    
    func hash(_ password: String) throws -> String {
        return try Bcrypt.hash(password, cost: cost)
    }
    
    func verify(_ password: String, against hash: String) throws -> Bool {
        return try Bcrypt.verify(password, created: hash)
    }
}
