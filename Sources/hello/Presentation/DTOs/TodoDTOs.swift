import Vapor
import Foundation

// MARK: - Request DTOs

struct CreateTodoRequest: Content {
    let title: String
    let description: String?
}

struct UpdateTodoRequest: Content {
    let title: String?
    let description: String?
    let completed: Bool?
}

// MARK: - Response DTOs

struct TodoResponse: Content {
    let id: UUID
    let title: String
    let description: String?
    let completed: Bool
    let createdAt: Date?
    let updatedAt: Date?
    
    init(from todo: Todo) {
        self.id = todo.id!
        self.title = todo.title
        self.description = todo.description
        self.completed = todo.completed
        self.createdAt = todo.createdAt
        self.updatedAt = todo.updatedAt
    }
}

struct TodoListResponse: Content {
    let todos: [TodoResponse]
    let count: Int
    
    init(todos: [Todo]) {
        self.todos = todos.map { TodoResponse(from: $0) }
        self.count = todos.count
    }
}

struct PaginatedTodoResponse: Content {
    let todos: [TodoResponse]
    let pagination: PaginationMeta
    
    init(todos: [Todo], page: Int, limit: Int, total: Int) {
        self.todos = todos.map { TodoResponse(from: $0) }
        self.pagination = PaginationMeta(
            page: page,
            limit: limit,
            total: total,
            totalPages: (total + limit - 1) / limit
        )
    }
}

struct PaginationMeta: Content {
    let page: Int
    let limit: Int
    let total: Int
    let totalPages: Int
}
