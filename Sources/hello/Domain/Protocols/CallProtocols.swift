import Foundation

// MARK: - Call Repository Protocol

protocol CallRepositoryProtocol: Sendable {
    /// Inserts the record or updates it if a record with the same id exists.
    func save(_ record: CallRecord) async throws
    /// Most recent calls where the user was caller or callee.
    func history(for userId: UUID, limit: Int) async throws -> [CallRecord]
    /// One page of everyone's calls, newest first.
    func page(page: Int, limit: Int) async throws -> (records: [CallRecord], total: Int)
    /// How many calls started at or after the date.
    func count(since date: Date) async throws -> Int
    /// Finishes every call still marked ringing or active and returns how many there were.
    func finishInterrupted() async throws -> Int
}

// MARK: - Signaling Connection

/// One live socket of one device. Implementations must be safe to call from any
/// thread and must not block: `send` enqueues the message and returns.
protocol SignalingConnection: AnyObject, Sendable {
    func send(_ message: ServerMessage)
    /// Closes for good: the client was replaced or refused and must not auto-reconnect.
    func close()
    /// Closes so that the client reconnects, which makes it authenticate again.
    func closeForReauthentication()
}
