import Fluent
import Vapor
import Foundation

// MARK: - Contact Models

final class ContactModel: Model, @unchecked Sendable {
    static let schema = "contacts"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "owner_id")
    var ownerId: UUID

    @Field(key: "contact_id")
    var contactId: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(ownerId: UUID, contactId: UUID) {
        self.ownerId = ownerId
        self.contactId = contactId
    }
}

final class BlockModel: Model, @unchecked Sendable {
    static let schema = "blocks"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "blocker_id")
    var blockerId: UUID

    @Field(key: "blocked_id")
    var blockedId: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(blockerId: UUID, blockedId: UUID) {
        self.blockerId = blockerId
        self.blockedId = blockedId
    }
}

// MARK: - Contact Repository Implementation

final class ContactRepository: ContactRepositoryProtocol, @unchecked Sendable {
    private let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func contacts(of userId: UUID) async throws -> [Contact] {
        let ids = try await ContactModel.query(on: database)
            .filter(\.$ownerId == userId)
            .all(\.$contactId)
        let mutual = try await mutualContactIds(of: userId)
        return try await activeUsers(ids).map { Contact(user: $0, isMutual: mutual.contains($0.id)) }
    }

    func add(_ contactId: UUID, to userId: UUID) async throws {
        do {
            try await ContactModel(ownerId: userId, contactId: contactId).create(on: database)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Already on the list.
        }
    }

    func remove(_ contactId: UUID, from userId: UUID) async throws {
        try await ContactModel.query(on: database)
            .filter(\.$ownerId == userId)
            .filter(\.$contactId == contactId)
            .delete()
    }

    func mutualContactIds(of userId: UUID) async throws -> Set<UUID> {
        let added = try await ContactModel.query(on: database)
            .filter(\.$ownerId == userId)
            .all(\.$contactId)
        let addedBy = try await ContactModel.query(on: database)
            .filter(\.$contactId == userId)
            .all(\.$ownerId)
        let blocks = try await BlockModel.query(on: database)
            .group(.or) { group in
                group.filter(\.$blockerId == userId).filter(\.$blockedId == userId)
            }
            .all()
        let blocked = blocks.map { $0.blockerId == userId ? $0.blockedId : $0.blockerId }
        return Set(added).intersection(addedBy).subtracting(blocked)
    }

    func blockedUsers(by userId: UUID) async throws -> [CallUser] {
        let ids = try await BlockModel.query(on: database)
            .filter(\.$blockerId == userId)
            .all(\.$blockedId)
        return try await activeUsers(ids)
    }

    func block(_ blockedId: UUID, by userId: UUID) async throws {
        try await remove(blockedId, from: userId)
        do {
            try await BlockModel(blockerId: userId, blockedId: blockedId).create(on: database)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Already blocked.
        }
    }

    func unblock(_ blockedId: UUID, by userId: UUID) async throws {
        try await BlockModel.query(on: database)
            .filter(\.$blockerId == userId)
            .filter(\.$blockedId == blockedId)
            .delete()
    }

    func isBlocked(_ userId: UUID, by blockerId: UUID) async throws -> Bool {
        try await BlockModel.query(on: database)
            .filter(\.$blockerId == blockerId)
            .filter(\.$blockedId == userId)
            .first() != nil
    }

    // MARK: - Private

    private func activeUsers(_ ids: [UUID]) async throws -> [CallUser] {
        guard !ids.isEmpty else { return [] }
        let users = try await UserModel.query(on: database)
            .filter(\.$id ~~ ids)
            .filter(\.$isActive == true)
            .all()
        return try users
            .map { CallUser(id: try $0.requireID(), username: $0.username) }
            .sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
    }
}
