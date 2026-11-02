import Vapor
import Foundation

// MARK: - Request DTOs

struct AddContactRequest: Content {
    let email: String
}

// MARK: - Response DTOs

struct ContactResponse: Content {
    let id: UUID
    let username: String
    /// Always false for a contact who may not be seen (see `Contact.isMutual`).
    let online: Bool
}

struct ContactListResponse: Content {
    let contacts: [ContactResponse]
}

struct BlockedUsersResponse: Content {
    let users: [CallUser]
}
