import Vapor

// MARK: - Contact Controller
//
// GET    /api/v1/contacts          the contact list with online status (protected)
// POST   /api/v1/contacts          add a contact by email (protected)
// DELETE /api/v1/contacts/:userId  remove a contact (protected)
// GET    /api/v1/blocks            blocked users (protected)
// PUT    /api/v1/blocks/:userId    block a user (protected)
// DELETE /api/v1/blocks/:userId    unblock a user (protected)
//
// After a change, the affected users get `contacts.changed` on the call socket and
// reload the list, so this list stays the only source of truth for online status.

final class ContactController: RouteCollection, Sendable {
    /// Per account: the answer tells whether an email is registered.
    private static let addLimit = RateLimiter.Rule(limit: 30, window: .seconds(10 * 60))

    private let contacts: ContactUseCase
    private let hub: CallHub
    private let rateLimiter: RateLimiter

    init(contacts: ContactUseCase, hub: CallHub, rateLimiter: RateLimiter) {
        self.contacts = contacts
        self.hub = hub
        self.rateLimiter = rateLimiter
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(JWTBearerAuthenticator(), UserAuthenticator())

        let contacts = protected.grouped("contacts")
        contacts.get(use: getContacts)
        contacts.post(use: addContact)
        contacts.delete(":userId", use: removeContact)

        let blocks = protected.grouped("blocks")
        blocks.get(use: getBlocked)
        blocks.put(":userId", use: blockUser)
        blocks.delete(":userId", use: unblockUser)
    }

    // MARK: - Contacts

    func getContacts(_ req: Request) async throws -> ContactListResponse {
        let userId = try currentUserId(req)
        let list = try await contacts.contacts(of: userId)
        let online = await hub.onlineUsers(among: Set(list.filter(\.isMutual).map(\.user.id)))
        return ContactListResponse(contacts: list.map { contact in
            ContactResponse(id: contact.user.id, username: contact.user.username, online: online.contains(contact.user.id))
        })
    }

    func addContact(_ req: Request) async throws -> ContactResponse {
        let userId = try currentUserId(req)
        if let wait = await rateLimiter.hit("contact-adds:\(userId)", rule: Self.addLimit) {
            throw Abort.tooManyRequests(retryAfter: wait)
        }
        let request = try req.content.decode(AddContactRequest.self)

        let contact = try await contacts.addContact(email: request.email, to: userId)
        guard contact.isMutual else {
            await hub.notifyContactsChanged(for: [userId])
            return ContactResponse(id: contact.user.id, username: contact.user.username, online: false)
        }
        // Each side can now see the other's status.
        await hub.notifyContactsChanged(for: [userId, contact.user.id])
        let online = await hub.onlineUsers(among: [contact.user.id])
        return ContactResponse(id: contact.user.id, username: contact.user.username, online: !online.isEmpty)
    }

    func removeContact(_ req: Request) async throws -> MessageResponse {
        let userId = try currentUserId(req)
        let contactId = try targetUserId(req)
        try await contacts.removeContact(contactId, from: userId)
        await hub.notifyContactsChanged(for: [userId, contactId])
        return MessageResponse(message: "Contact removed")
    }

    // MARK: - Blocks

    func getBlocked(_ req: Request) async throws -> BlockedUsersResponse {
        BlockedUsersResponse(users: try await contacts.blockedUsers(by: try currentUserId(req)))
    }

    func blockUser(_ req: Request) async throws -> MessageResponse {
        let userId = try currentUserId(req)
        let blockedId = try targetUserId(req)
        try await contacts.block(blockedId, by: userId)
        await hub.notifyContactsChanged(for: [userId, blockedId])
        return MessageResponse(message: "User blocked")
    }

    func unblockUser(_ req: Request) async throws -> MessageResponse {
        let userId = try currentUserId(req)
        try await contacts.unblock(try targetUserId(req), by: userId)
        await hub.notifyContactsChanged(for: [userId])
        return MessageResponse(message: "User unblocked")
    }

    // MARK: - Helpers

    private func currentUserId(_ req: Request) throws -> UUID {
        guard let userId = try req.auth.require(User.self).id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        return userId
    }

    private func targetUserId(_ req: Request) throws -> UUID {
        guard let userId = req.parameters.get("userId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        return userId
    }
}
