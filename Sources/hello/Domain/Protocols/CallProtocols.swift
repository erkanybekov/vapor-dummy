import Foundation

// MARK: - Call Repository Protocol

protocol CallRepositoryProtocol: Sendable {
    /// Inserts the record or updates it if a record with the same id exists.
    func save(_ record: CallRecord) async throws
    /// Most recent calls where the user was caller or callee.
    func history(for userId: UUID, limit: Int) async throws -> [CallRecord]
}

// MARK: - Signaling Connection

/// One live socket of one device. Implementations must be safe to call from any
/// thread and must not block: `send` enqueues the message and returns.
protocol SignalingConnection: AnyObject, Sendable {
    func send(_ message: ServerMessage)
    func close()
}
