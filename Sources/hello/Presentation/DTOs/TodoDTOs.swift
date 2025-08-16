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
