import Fluent
import Vapor
import Foundation

// MARK: - Call Record Model

final class CallRecordModel: Model, @unchecked Sendable {
    static let schema = "call_records"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "caller_id")
    var callerId: UUID

    @Field(key: "callee_id")
    var calleeId: UUID

    @Field(key: "caller_device_id")
    var callerDeviceId: String

    @OptionalField(key: "callee_device_id")
    var calleeDeviceId: String?

    @Field(key: "video")
    var video: Bool

    @Field(key: "status")
    var status: String

    @OptionalField(key: "end_reason")
    var endReason: String?

    @Field(key: "started_at")
    var startedAt: Date

    @OptionalField(key: "answered_at")
    var answeredAt: Date?

    @OptionalField(key: "ended_at")
    var endedAt: Date?

    init() { }

    init(record: CallRecord) {
        self.id = record.id
        self.callerId = record.callerId
        self.calleeId = record.calleeId
        self.callerDeviceId = record.callerDeviceId
        self.video = record.video
        self.startedAt = record.startedAt
        apply(record)
    }

    /// Copies the mutable part of the record onto the model.
    func apply(_ record: CallRecord) {
        self.calleeDeviceId = record.calleeDeviceId
        self.status = record.status.rawValue
        self.endReason = record.endReason?.rawValue
        self.answeredAt = record.answeredAt
        self.endedAt = record.endedAt
    }
}

// MARK: - Model to Domain Conversion

extension CallRecordModel {
    func toDomain() -> CallRecord {
        return CallRecord(
            id: self.id ?? UUID(),
            callerId: self.callerId,
            calleeId: self.calleeId,
            callerDeviceId: self.callerDeviceId,
            calleeDeviceId: self.calleeDeviceId,
            video: self.video,
            status: CallStatus(rawValue: self.status) ?? .missed,
            endReason: self.endReason.flatMap(CallEndReason.init(rawValue:)),
            startedAt: self.startedAt,
            answeredAt: self.answeredAt,
            endedAt: self.endedAt
        )
    }
}

// MARK: - Call Repository Implementation

final class CallRepository: CallRepositoryProtocol {
    private let database: any Database

    init(database: any Database) {
        self.database = database
    }

    func save(_ record: CallRecord) async throws {
        if let existing = try await CallRecordModel.find(record.id, on: database) {
            existing.apply(record)
            try await existing.update(on: database)
        } else {
            try await CallRecordModel(record: record).create(on: database)
        }
    }

    func history(for userId: UUID, limit: Int) async throws -> [CallRecord] {
        let models = try await CallRecordModel
            .query(on: database)
            .group(.or) { group in
                group.filter(\.$callerId == userId).filter(\.$calleeId == userId)
            }
            .sort(\.$startedAt, .descending)
            .limit(limit)
            .all()

        return models.map { $0.toDomain() }
    }
}

// MARK: - Call Recorder

/// Writes call history in the background, strictly in the order the hub produced
/// the snapshots, so signaling never waits on the database and a slow or failing
/// database never breaks a call.
final class CallRecorder: Sendable {
    private let continuation: AsyncStream<CallRecord>.Continuation
    private let worker: Task<Void, Never>

    init(repository: any CallRepositoryProtocol, logger: Logger) {
        let (stream, continuation) = AsyncStream.makeStream(of: CallRecord.self, bufferingPolicy: .bufferingNewest(10_000))
        self.continuation = continuation
        self.worker = Task {
            for await record in stream {
                do {
                    try await repository.save(record)
                } catch {
                    logger.error("Failed to save call record", metadata: ["call": "\(record.id)", "error": "\(error)"])
                }
            }
        }
    }

    func record(_ record: CallRecord) {
        continuation.yield(record)
    }

    /// Flushes pending writes. Call during shutdown, before the database goes away.
    func shutdown() async {
        continuation.finish()
        await worker.value
    }
}
