@testable import hello
import Foundation
import Testing
import VaporTesting

extension DatabaseTests {
    @Suite("Todo API")
    struct TodoAPITests {
        private struct Page: Decodable {
            let todos: [TodoResponse]
            let pagination: PaginationMeta
        }

        @Test("A huge page number is just an empty page")
        func hugePage() async throws {
            try await withTestApp { app in
                let tokens = try await register(app, email: uniqueEmail())
                let auth: HTTPHeaders = ["Authorization": "Bearer \(tokens.accessToken)"]

                try await app.testing().test(.GET, "api/v1/todos?page=\(Int.max)&limit=100", headers: auth) { res in
                    #expect(res.status == .ok)
                    let page = try res.content.decode(Page.self)
                    #expect(page.todos.isEmpty)
                    #expect(page.pagination.page == TodoUseCase.maxPage)
                }
            }
        }
    }
}
