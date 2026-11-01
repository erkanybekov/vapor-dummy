import Foundation

// MARK: - Contact Repository Protocol

protocol ContactRepositoryProtocol: Sendable {
    /// The user's contacts, sorted by name.
    func contacts(of userId: UUID) async throws -> [Contact]
    /// Adding someone already on the list changes nothing.
    func add(_ contactId: UUID, to userId: UUID) async throws
    func remove(_ contactId: UUID, from userId: UUID) async throws
    /// Users who may see this user's online status (see `Contact.isMutual`).
    func mutualContactIds(of userId: UUID) async throws -> Set<UUID>

    /// The users this user has blocked, sorted by name.
    func blockedUsers(by userId: UUID) async throws -> [CallUser]
    /// Also takes the blocked user off the contact list.
    func block(_ blockedId: UUID, by userId: UUID) async throws
    func unblock(_ blockedId: UUID, by userId: UUID) async throws
    func isBlocked(_ userId: UUID, by blockerId: UUID) async throws -> Bool
}
