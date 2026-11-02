import Fluent
import FluentPostgresDriver

struct CreateChatMessage: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("chat_messages")
            .field("seq", .int64, .identifier(auto: true))
            .field("room", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("username", .string, .required)
            .field("text", .string, .required)
            .field("client_id", .string, .required)
            .field("sent_at", .datetime, .required)
            .unique(on: "user_id", "client_id")
            .create()
        // History is always read per room, newest first.
        let sql = database as! any SQLDatabase
        try await sql.raw("CREATE INDEX chat_messages_room_seq_idx ON chat_messages (room, seq)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("chat_messages").delete()
    }
}
