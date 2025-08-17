import Foundation
import Vapor

// MARK: - Todo Use Case

final class TodoUseCase: Sendable {
    private let todoRepository: any TodoRepositoryProtocol
    
    init(todoRepository: any TodoRepositoryProtocol) {
        self.todoRepository = todoRepository
    }
    
    // MARK: - CRUD Operations
    
    func createTodo(title: String, description: String?, userId: UUID) async throws -> Todo {
        // Validate input
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Title cannot be empty")
        }
        
        guard title.count <= 200 else {
            throw Abort(.badRequest, reason: "Title too long (max 200 characters)")
        }
        
        if let desc = description, desc.count > 1000 {
            throw Abort(.badRequest, reason: "Description too long (max 1000 characters)")
        }
        
        let todo = Todo(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description?.trimmingCharacters(in: .whitespacesAndNewlines),
            userId: userId
        )
        
        return try await todoRepository.create(todo)
    }
    
    func getTodos(for userId: UUID) async throws -> [Todo] {
        return try await todoRepository.findAll(for: userId)
    }
    
    func getTodosPaginated(for userId: UUID, page: Int, limit: Int) async throws -> (todos: [Todo], total: Int) {
        // Validate pagination parameters
        let validatedPage = max(1, page)
        let validatedLimit = min(max(1, limit), 100) // Max 100 items per page
        
        // Get paginated todos and total count concurrently
        async let todos = todoRepository.findPaginated(for: userId, page: validatedPage, limit: validatedLimit)
        async let total = todoRepository.count(for: userId)
        
        return (todos: try await todos, total: try await total)
    }
    
    func getTodo(id: UUID, userId: UUID) async throws -> Todo {
        guard let todo = try await todoRepository.find(by: id) else {
            throw Abort(.notFound, reason: "Todo not found")
        }
        
        // Ensure user owns this todo
        guard todo.userId == userId else {
            throw Abort(.forbidden, reason: "Access denied")
        }
        
        return todo
    }
    
    func updateTodo(
        id: UUID,
        title: String?,
        description: String?,
        completed: Bool?,
        userId: UUID
    ) async throws -> Todo {
        // Get existing todo
        let existingTodo = try await getTodo(id: id, userId: userId)
        
        // Validate new title if provided
        if let newTitle = title {
            guard !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Abort(.badRequest, reason: "Title cannot be empty")
            }
            guard newTitle.count <= 200 else {
                throw Abort(.badRequest, reason: "Title too long (max 200 characters)")
            }
        }
        
        // Validate description if provided
        if let desc = description, desc.count > 1000 {
            throw Abort(.badRequest, reason: "Description too long (max 1000 characters)")
        }
        
        // Create updated todo
        let updatedTodo = Todo(
            id: existingTodo.id,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? existingTodo.title,
            description: description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? existingTodo.description,
            completed: completed ?? existingTodo.completed,
            createdAt: existingTodo.createdAt,
            updatedAt: existingTodo.updatedAt,
            userId: existingTodo.userId
        )
        
        return try await todoRepository.update(updatedTodo)
    }
    
    func deleteTodo(id: UUID, userId: UUID) async throws {
        // Ensure todo exists and user owns it
        _ = try await getTodo(id: id, userId: userId)
        
        // Delete the todo
        try await todoRepository.delete(by: id)
    }
    
    func toggleTodo(id: UUID, userId: UUID) async throws -> Todo {
        let todo = try await getTodo(id: id, userId: userId)
        return try await updateTodo(
            id: id,
            title: nil,
            description: nil,
            completed: !todo.completed,
            userId: userId
        )
    }
}
