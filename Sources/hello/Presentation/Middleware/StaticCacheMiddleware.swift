import Vapor

// MARK: - Static Cache Middleware

/// Cache policy for the built web app (`web/` → `Public/`). Vite puts a content
/// hash in every asset file name, so assets can be cached forever, while HTML
/// must be revalidated so a new deploy is picked up on the next page load.
/// Register before `FileMiddleware` so it sees the file responses.
struct StaticCacheMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        guard request.method == .GET, response.status == .ok || response.status == .notModified else {
            return response
        }
        if request.url.path.hasPrefix("/assets/") {
            response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable")
        } else if response.headers.contentType == .html {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        }
        return response
    }
}
