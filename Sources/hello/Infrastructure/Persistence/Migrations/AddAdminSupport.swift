import Fluent
import FluentPostgresDriver

/// The admin flag, and indexes for the admin panel's newest-first lists.
struct AddAdminSupport: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = database as! any SQLDatabase
        try await sql.raw("ALTER TABLE users ADD COLUMN is_admin BOOLEAN NOT NULL DEFAULT FALSE").run()
        try await sql.raw("CREATE INDEX users_created_at_idx ON users (created_at DESC)").run()
        try await sql.raw("CREATE INDEX call_records_started_idx ON call_records (started_at DESC)").run()
    }

    func revert(on database: any Database) async throws {
        let sql = database as! any SQLDatabase
        try await sql.raw("DROP INDEX IF EXISTS call_records_started_idx").run()
        try await sql.raw("DROP INDEX IF EXISTS users_created_at_idx").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN is_admin").run()
    }
}
