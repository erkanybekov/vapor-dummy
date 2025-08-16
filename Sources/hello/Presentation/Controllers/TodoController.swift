import Vapor

// MARK: - Todo Controller

final class TodoController: RouteCollection, Sendable {
    private let todoUseCase: TodoUseCase
    
    init(todoUseCase: TodoUseCase) {
        self.todoUseCase = todoUseCase
    }
    
    func boot(routes: any RoutesBuilder) throws {
        let todos = routes.grouped("todos")
        
        // Protected routes - require authentication
        let protected = todos.grouped(JWTBearerAuthenticator(), UserAuthenticator())
        
        protected.get(use: getAllTodos)              // GET /todos
        protected.post(use: createTodo)              // POST /todos
        protected.get(":id", use: getTodo)           // GET /todos/:id
        protected.put(":id", use: updateTodo)        // PUT /todos/:id
        protected.delete(":id", use: deleteTodo)     // DELETE /todos/:id
        protected.patch(":id", "toggle", use: toggleTodo) // PATCH /todos/:id/toggle
    }
    
    // MARK: - CRUD Endpoints
    
    func getAllTodos(_ req: Request) async throws -> TodoListResponse {
        let user = try req.auth.require(User.self)
        guard let userId = user.id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        
        let todos = try await todoUseCase.getTodos(for: userId)
        return TodoListResponse(todos: todos)
    }
    
    func createTodo(_ req: Request) async throws -> TodoResponse {
        let user = try req.auth.require(User.self)
        guard let userId = user.id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        
        let createRequest = try req.content.decode(CreateTodoRequest.self)
        
        let todo = try await todoUseCase.createTodo(
            title: createRequest.title,
            description: createRequest.description,
            userId: userId
        )
        
        return TodoResponse(from: todo)
    }
    
    func getTodo(_ req: Request) async throws -> TodoResponse {
        let user = try req.auth.require(User.self)
        guard let userId = user.id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        
        guard let todoId = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid todo ID")
        }
        
        let todo = try await todoUseCase.getTodo(id: todoId, userId: userId)
        return TodoResponse(from: todo)
    }
    
    func updateTodo(_ req: Request) async throws -> TodoResponse {
        let user = try req.auth.require(User.self)
        guard let userId = user.id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        
        guard let todoId = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid todo ID")
        }
        
        let updateRequest = try req.content.decode(UpdateTodoRequest.self)
        
        let todo = try await todoUseCase.updateTodo(
            id: todoId,
            title: updateRequest.title,
            description: updateRequest.description,
            completed: updateRequest.completed,
            userId: userId
        )
        
        return TodoResponse(from: todo)
    }
    
    func deleteTodo(_ req: Request) async throws -> MessageResponse {
        let user = try req.auth.require(User.self)
        guard let userId = user.id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        
        guard let todoId = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid todo ID")
        }
        
        try await todoUseCase.deleteTodo(id: todoId, userId: userId)
        
        return MessageResponse(message: "Todo deleted successfully")
    }
    
    func toggleTodo(_ req: Request) async throws -> TodoResponse {
        let user = try req.auth.require(User.self)
        guard let userId = user.id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        
        guard let todoId = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid todo ID")
        }
        
        let todo = try await todoUseCase.toggleTodo(id: todoId, userId: userId)
        return TodoResponse(from: todo)
    }
}
