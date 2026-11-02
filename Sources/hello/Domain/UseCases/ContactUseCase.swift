import Foundation
import Vapor

// MARK: - Contact Use Case

final class ContactUseCase: Sendable {
    private let contactRepository: any ContactRepositoryProtocol
    private let userRepository: any UserRepositoryProtocol

    init(contactRepository: any ContactRepositoryProtocol, userRepository: any UserRepositoryProtocol) {
        self.contactRepository = contactRepository
        self.userRepository = userRepository
    }

    func contacts(of userId: UUID) async throws -> [Contact] {
        try await contactRepository.contacts(of: userId)
    }

    func addContact(email: String, to userId: UUID) async throws -> Contact {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let user = try await userRepository.find(by: email), user.isActive, let contactId = user.id else {
            throw Abort(.notFound, reason: "User not found")
        }
        guard contactId != userId else {
            throw Abort(.badRequest, reason: "You cannot add yourself")
        }
        guard try await !contactRepository.isBlocked(contactId, by: userId) else {
            throw Abort(.conflict, reason: "Unblock this user first")
        }

        try await contactRepository.add(contactId, to: userId)
        let isMutual = try await contactRepository.mutualContactIds(of: userId).contains(contactId)
        return Contact(user: CallUser(id: contactId, username: user.username), isMutual: isMutual)
    }

    func removeContact(_ contactId: UUID, from userId: UUID) async throws {
        try await contactRepository.remove(contactId, from: userId)
    }

    func blockedUsers(by userId: UUID) async throws -> [CallUser] {
        try await contactRepository.blockedUsers(by: userId)
    }

    func block(_ blockedId: UUID, by userId: UUID) async throws {
        guard blockedId != userId else {
            throw Abort(.badRequest, reason: "You cannot block yourself")
        }
        guard try await userRepository.find(by: blockedId) != nil else {
            throw Abort(.notFound, reason: "User not found")
        }
        try await contactRepository.block(blockedId, by: userId)
    }

    func unblock(_ blockedId: UUID, by userId: UUID) async throws {
        try await contactRepository.unblock(blockedId, by: userId)
    }
}
