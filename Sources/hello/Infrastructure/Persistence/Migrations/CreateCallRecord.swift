import Fluent

struct CreateCallRecord: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("call_records")
            .id()
            .field("caller_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("callee_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("caller_device_id", .string, .required)
            .field("callee_device_id", .string)
            .field("video", .bool, .required)
            .field("status", .string, .required)
            .field("end_reason", .string)
            .field("started_at", .datetime, .required)
            .field("answered_at", .datetime)
            .field("ended_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("call_records").delete()
    }
}
