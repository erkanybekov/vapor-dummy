import Foundation

// MARK: - Contact Domain Entities

/// Someone on a user's list. Adding needs no consent, like a phone's address book,
/// so seeing a contact's online status takes both sides having added each other.
struct Contact: Sendable, Equatable {
    let user: CallUser
    /// They added you too, and neither of you has blocked the other.
    let isMutual: Bool
}
