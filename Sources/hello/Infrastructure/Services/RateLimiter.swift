import Vapor

// MARK: - Rate Limiter

/// Counts attempts per key in fixed windows, in memory. Enough for one server
/// instance; several instances would need a shared store such as Redis.
actor RateLimiter {
    struct Rule: Sendable {
        let limit: Int
        let window: Duration
    }

    private struct Window {
        var count: Int
        let endsAt: ContinuousClock.Instant
    }

    private var windows: [String: Window] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant
    private var nextSweep: ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
        self.nextSweep = now()
    }

    /// Counts an attempt. Returns nil if it is within the limit, otherwise how long
    /// until the key may try again.
    func hit(_ key: String, rule: Rule) -> Duration? {
        let now = now()
        sweep(at: now)
        var window = windows[key].flatMap { $0.endsAt > now ? $0 : nil } ?? Window(count: 0, endsAt: now + rule.window)
        window.count += 1
        windows[key] = window
        return window.count > rule.limit ? window.endsAt - now : nil
    }

    /// How long until the key may try again, without counting an attempt; nil if it may now.
    func retryAfter(_ key: String, rule: Rule) -> Duration? {
        let now = now()
        guard let window = windows[key], window.endsAt > now, window.count >= rule.limit else { return nil }
        return window.endsAt - now
    }

    func reset(_ key: String) {
        windows[key] = nil
    }

    /// Drops finished windows once a minute, so keys that stop coming don't pile up.
    private func sweep(at now: ContinuousClock.Instant) {
        guard now >= nextSweep else { return }
        windows = windows.filter { $0.value.endsAt > now }
        nextSweep = now + .seconds(60)
    }
}

// MARK: - Rate Limit Middleware

/// Rejects a client with `429 Too Many Requests` once it exceeds `rule` on these routes.
struct RateLimitMiddleware: AsyncMiddleware {
    let limiter: RateLimiter
    let name: String
    let rule: RateLimiter.Rule

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let ip = request.clientIP
        if let wait = await limiter.hit("\(name):\(ip)", rule: rule) {
            // The raw proxy headers show whether `clientIP` picked the right address.
            request.logger.warning("Rate limited", metadata: [
                "limit": .string(name),
                "client-ip": .string(ip),
                "x-forwarded-for": .string(request.headers[.xForwardedFor].joined(separator: ", ")),
                "cf-connecting-ip": .string(request.headers.first(name: "CF-Connecting-IP") ?? "-"),
            ])
            throw Abort.tooManyRequests(retryAfter: wait)
        }
        return try await next.respond(to: request)
    }
}

extension Abort {
    static func tooManyRequests(retryAfter wait: Duration) -> Abort {
        let seconds = max(1, Int(wait.components.seconds) + (wait.components.attoseconds > 0 ? 1 : 0))
        return Abort(
            .tooManyRequests,
            headers: ["Retry-After": "\(seconds)"],
            reason: "Too many attempts, try again in \(seconds) s"
        )
    }
}
