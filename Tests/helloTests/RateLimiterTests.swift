@testable import hello
import Foundation
import Testing

@Suite("RateLimiter")
struct RateLimiterTests {
    /// A clock the test moves by hand.
    final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = ContinuousClock.now

        var now: ContinuousClock.Instant { lock.withLock { current } }

        func advance(by duration: Duration) {
            lock.withLock { current += duration }
        }
    }

    let rule = RateLimiter.Rule(limit: 3, window: .seconds(60))

    @Test("Allows hits up to the limit, then says how long to wait")
    func limitsHits() async {
        let clock = ManualClock()
        let limiter = RateLimiter(now: { clock.now })

        for _ in 0..<3 {
            #expect(await limiter.hit("ip", rule: rule) == nil)
        }
        clock.advance(by: .seconds(20))
        #expect(await limiter.hit("ip", rule: rule) == .seconds(40))
    }

    @Test("A new window starts once the old one ends")
    func windowResets() async {
        let clock = ManualClock()
        let limiter = RateLimiter(now: { clock.now })

        for _ in 0..<4 { _ = await limiter.hit("ip", rule: rule) }
        clock.advance(by: .seconds(60))
        #expect(await limiter.hit("ip", rule: rule) == nil)
    }

    @Test("Keys are counted separately")
    func keysAreSeparate() async {
        let limiter = RateLimiter()

        for _ in 0..<4 { _ = await limiter.hit("a", rule: rule) }
        #expect(await limiter.hit("a", rule: rule) != nil)
        #expect(await limiter.hit("b", rule: rule) == nil)
    }

    @Test("retryAfter blocks once the limit is reached, without counting")
    func retryAfter() async {
        let clock = ManualClock()
        let limiter = RateLimiter(now: { clock.now })

        #expect(await limiter.retryAfter("account", rule: rule) == nil)
        for _ in 0..<2 { _ = await limiter.hit("account", rule: rule) }
        #expect(await limiter.retryAfter("account", rule: rule) == nil)
        _ = await limiter.hit("account", rule: rule)
        #expect(await limiter.retryAfter("account", rule: rule) == .seconds(60))

        await limiter.reset("account")
        #expect(await limiter.retryAfter("account", rule: rule) == nil)
    }
}
