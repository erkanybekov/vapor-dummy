import Foundation

// MARK: - Todo Domain Entity

struct Todo: Sendable {
    let id: UUID?
    let title: String
    let description: String?
    let completed: Bool
    let createdAt: Date?
    let updatedAt: Date?
    let userId: UUID // Todos belong to users
    
    init(
        id: UUID? = nil,
        title: String,
        description: String? = nil,
        completed: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        userId: UUID
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.completed = completed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.userId = userId
    }
}
