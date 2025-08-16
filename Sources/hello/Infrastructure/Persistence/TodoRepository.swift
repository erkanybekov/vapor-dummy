import Fluent
import Vapor
import Foundation

// MARK: - Todo Model

final class TodoModel: Model, @unchecked Sendable {
    static let schema = "todos"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "title")
    var title: String
    
    @OptionalField(key: "description")
    var description: String?
    
    @Field(key: "completed")
    var completed: Bool
    
    @Parent(key: "user_id")
    var user: UserModel
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() { }
    
    init(
        id: UUID? = nil,
        title: String,
        description: String? = nil,
        completed: Bool = false,
        userId: UUID
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.completed = completed
        self.$user.id = userId
    }
}

// MARK: - Model to Domain Conversion

extension TodoModel {
    func toDomain() -> Todo {
        return Todo(
            id: self.id,
            title: self.title,
            description: self.description,
            completed: self.completed,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt,
            userId: self.$user.id
        )
    }
}

// MARK: - Todo Repository Protocol

protocol TodoRepositoryProtocol: Sendable {
    func create(_ todo: Todo) async throws -> Todo
    func find(by id: UUID) async throws -> Todo?
    func findAll(for userId: UUID) async throws -> [Todo]
    func update(_ todo: Todo) async throws -> Todo
    func delete(by id: UUID) async throws
}

// MARK: - Todo Repository Implementation

final class TodoRepository: TodoRepositoryProtocol {
    private let database: any Database
    
    init(database: any Database) {
        self.database = database
    }
    
    func create(_ todo: Todo) async throws -> Todo {
        let todoModel = TodoModel(
            title: todo.title,
            description: todo.description,
            completed: todo.completed,
            userId: todo.userId
        )
        
        try await todoModel.save(on: database)
        return todoModel.toDomain()
    }
    
    func find(by id: UUID) async throws -> Todo? {
        guard let todoModel = try await TodoModel.find(id, on: database) else {
            return nil
        }
        return todoModel.toDomain()
    }
    
    func findAll(for userId: UUID) async throws -> [Todo] {
        let todoModels = try await TodoModel
            .query(on: database)
            .filter(\.$user.$id == userId)
            .sort(\.$createdAt, .descending)
            .all()
        
        return todoModels.map { $0.toDomain() }
    }
    
    func update(_ todo: Todo) async throws -> Todo {
        guard let id = todo.id,
              let todoModel = try await TodoModel.find(id, on: database) else {
            throw Abort(.notFound, reason: "Todo not found")
        }
        
        todoModel.title = todo.title
        todoModel.description = todo.description
        todoModel.completed = todo.completed
        
        try await todoModel.save(on: database)
        return todoModel.toDomain()
    }
    
    func delete(by id: UUID) async throws {
        guard let todoModel = try await TodoModel.find(id, on: database) else {
            throw Abort(.notFound, reason: "Todo not found")
        }
        
        try await todoModel.delete(on: database)
    }
}
