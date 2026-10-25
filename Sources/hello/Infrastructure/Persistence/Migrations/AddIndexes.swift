import Fluent
import FluentPostgresDriver

/// Indexes for lookups that run on every request or page load. `token_id` becomes
/// unique, which is what makes a refresh token single-use (see JWTTokenService).
struct AddIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = database as! any SQLDatabase
        // Old rows: expired ones are useless, and duplicates would block the unique index.
        try await sql.raw("DELETE FROM revoked_tokens WHERE expires_at < NOW()").run()
        try await sql.raw("""
            DELETE FROM revoked_tokens a USING revoked_tokens b
            WHERE a.token_id = b.token_id AND a.id > b.id
            """).run()
        try await sql.raw("CREATE UNIQUE INDEX revoked_tokens_token_id_key ON revoked_tokens (token_id)").run()
        try await sql.raw("CREATE INDEX revoked_tokens_expires_at_idx ON revoked_tokens (expires_at)").run()
        try await sql.raw("CREATE INDEX todos_user_id_idx ON todos (user_id)").run()
        try await sql.raw("CREATE INDEX call_records_caller_started_idx ON call_records (caller_id, started_at DESC)").run()
        try await sql.raw("CREATE INDEX call_records_callee_started_idx ON call_records (callee_id, started_at DESC)").run()
    }

    func revert(on database: any Database) async throws {
        let sql = database as! any SQLDatabase
        for index in [
            "revoked_tokens_token_id_key",
            "revoked_tokens_expires_at_idx",
            "todos_user_id_idx",
            "call_records_caller_started_idx",
            "call_records_callee_started_idx",
        ] {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index)").run()
        }
    }
}
