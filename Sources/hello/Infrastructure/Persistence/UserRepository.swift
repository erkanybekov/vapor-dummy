import Vapor
import Fluent
import Foundation

// MARK: - Fluent User Model (Infrastructure Layer)
final class UserModel: Model, @unchecked Sendable {
    static let schema = "users"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "email")
    var email: String
    
    @Field(key: "username")
    var username: String
    
    @Field(key: "password_hash")
    var passwordHash: String
    
    @Field(key: "is_active")
    var isActive: Bool

    @Field(key: "is_admin")
    var isAdmin: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() { }
    
    init(
        id: UUID? = nil,
        email: String,
        username: String,
        passwordHash: String,
        isActive: Bool = true,
        isAdmin: Bool = false
    ) {
        self.id = id
        self.email = email
        self.username = username
        self.passwordHash = passwordHash
        self.isActive = isActive
        self.isAdmin = isAdmin
    }
}

// MARK: - Domain Model Conversion Extensions
extension UserModel {
    func toDomain() -> User {
        return User(
            id: self.id,
            email: self.email,
            username: self.username,
            passwordHash: self.passwordHash,
            isActive: self.isActive,
            isAdmin: self.isAdmin,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt
        )
    }

    func fromDomain(_ user: User) {
        self.id = user.id
        self.email = user.email
        self.username = user.username
        self.passwordHash = user.passwordHash
        self.isActive = user.isActive
        self.isAdmin = user.isAdmin
    }
}

// MARK: - User Repository Implementation
final class UserRepository: UserRepositoryProtocol, @unchecked Sendable {
    private let database: any Database
    
    init(database: any Database) {
        self.database = database
    }
    
    func find(by id: UUID) async throws -> User? {
        let userModel = try await UserModel
            .query(on: database)
            .filter(\.$id == id)
            .first()
        
        return userModel?.toDomain()
    }
    
    func find(by email: String) async throws -> User? {
        let userModel = try await UserModel
            .query(on: database)
            .filter(\.$email == email.lowercased())
            .first()
        
        return userModel?.toDomain()
    }
    
    func create(_ user: User) async throws -> User {
        let userModel = UserModel()
        userModel.fromDomain(user)
        userModel.email = user.email.lowercased() // Normalize email
        
        try await userModel.save(on: database)
        return userModel.toDomain()
    }
    
    func update(_ user: User) async throws -> User {
        guard let id = user.id else {
            throw Abort(.badRequest, reason: "User ID is required for update")
        }
        
        guard let userModel = try await UserModel.find(id, on: database) else {
            throw Abort(.notFound, reason: "User not found")
        }
        
        userModel.fromDomain(user)
        userModel.email = user.email.lowercased() // Normalize email
        
        try await userModel.save(on: database)
        return userModel.toDomain()
    }
    
    func delete(by id: UUID) async throws {
        guard let userModel = try await UserModel.find(id, on: database) else {
            throw Abort(.notFound, reason: "User not found")
        }
        
        try await userModel.delete(on: database)
    }

    func page(search: String?, page: Int, limit: Int) async throws -> (users: [User], total: Int) {
        let query = UserModel.query(on: database)
        if let search {
            // Fluent's `~~` is LIKE, which is case-sensitive in Postgres.
            let escaped = search
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            query.group(.or) { group in
                group.filter(\.$email, .custom("ILIKE"), "%\(escaped)%")
                group.filter(\.$username, .custom("ILIKE"), "%\(escaped)%")
            }
        }

        let total = try await query.copy().count()
        let userModels = try await query
            .sort(\.$createdAt, .descending)
            .sort(\.$id)
            .offset((page - 1) * limit)
            .limit(limit)
            .all()

        return (users: userModels.map { $0.toDomain() }, total: total)
    }

    func counts() async throws -> UserCounts {
        UserCounts(
            total: try await UserModel.query(on: database).count(),
            active: try await UserModel.query(on: database).filter(\.$isActive == true).count(),
            admins: try await UserModel.query(on: database).filter(\.$isAdmin == true).count()
        )
    }

    func usernames(of ids: Set<UUID>) async throws -> [UUID: String] {
        let userModels = try await UserModel
            .query(on: database)
            .filter(\.$id ~~ ids)
            .all()

        return Dictionary(uniqueKeysWithValues: userModels.compactMap { model in
            model.id.map { ($0, model.username) }
        })
    }
}
