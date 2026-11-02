import Fluent
import FluentPostgresDriver

struct CreateContact: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("contacts")
            .id()
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("contact_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "owner_id", "contact_id")
            .create()
        try await database.schema("blocks")
            .id()
            .field("blocker_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("blocked_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "blocker_id", "blocked_id")
            .create()
        // The unique constraints cover lookups by owner; these cover "who added or blocked me".
        let sql = database as! any SQLDatabase
        try await sql.raw("CREATE INDEX contacts_contact_id_idx ON contacts (contact_id)").run()
        try await sql.raw("CREATE INDEX blocks_blocked_id_idx ON blocks (blocked_id)").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("blocks").delete()
        try await database.schema("contacts").delete()
    }
}
