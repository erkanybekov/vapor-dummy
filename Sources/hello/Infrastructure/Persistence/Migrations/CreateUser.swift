import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .id()
            .field("email", .string, .required)
            .field("username", .string, .required)
            .field("password_hash", .string, .required)
            .field("is_active", .bool, .required, .custom("DEFAULT TRUE"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "email")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users").delete()
    }
}

struct CreateRevokedToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("revoked_tokens")
            .id()
            .field("token_id", .string, .required)
            .field("user_id", .uuid, .required)
            .field("revoked_at", .datetime)
            .field("expires_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("revoked_tokens").delete()
    }
}
