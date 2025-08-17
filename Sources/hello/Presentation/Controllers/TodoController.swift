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
        
        protected.get(use: getAllTodos)              // GET /todos (with optional pagination)
        protected.post(use: createTodo)              // POST /todos
        protected.get(":id", use: getTodo)           // GET /todos/:id
        protected.put(":id", use: updateTodo)        // PUT /todos/:id
        protected.delete(":id", use: deleteTodo)     // DELETE /todos/:id
        protected.patch(":id", "toggle", use: toggleTodo) // PATCH /todos/:id/toggle
    }
    
    // MARK: - CRUD Endpoints
    
    func getAllTodos(_ req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        guard let userId = user.id else {
            throw Abort(.unauthorized, reason: "User ID not found")
        }
        
        // Check for pagination parameters
        let pageStr: String? = req.query["page"]
        let limitStr: String? = req.query["limit"]
        let page = Int(pageStr ?? "1") ?? 1
        let limit = Int(limitStr ?? "20") ?? 20
        
        // If pagination parameters provided, use paginated response
        if pageStr != nil || limitStr != nil {
            let result = try await todoUseCase.getTodosPaginated(for: userId, page: page, limit: limit)
            let response = PaginatedTodoResponse(
                todos: result.todos,
                page: max(1, page),
                limit: min(max(1, limit), 100),
                total: result.total
            )
            return try await response.encodeResponse(for: req)
        } else {
            // Default: return all todos (backward compatibility)
            let todos = try await todoUseCase.getTodos(for: userId)
            let response = TodoListResponse(todos: todos)
            return try await response.encodeResponse(for: req)
        }
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
