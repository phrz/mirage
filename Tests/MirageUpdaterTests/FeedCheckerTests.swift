import XCTest
@testable import MirageUpdater

/// The feed check cadence (after mac-daddy's first live run): stale records, the Welcome rate limit, one in flight.
final class FeedCheckerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testStaleness() {
        XCTAssertTrue(FeedChecker.isStale(lastCheck: nil, now: now), "never checked")
        XCTAssertFalse(FeedChecker.isStale(lastCheck: now.addingTimeInterval(-599), now: now))
        XCTAssertTrue(FeedChecker.isStale(lastCheck: now.addingTimeInterval(-600), now: now))
        XCTAssertTrue(FeedChecker.isStale(lastCheck: now.addingTimeInterval(3600), now: now), "a clock set back")
        XCTAssertFalse(FeedChecker.isStale(lastCheck: now.addingTimeInterval(30), now: now), "a few seconds of skew")
    }

    func testHourlyAndNewDay() {
        XCTAssertFalse(FeedChecker.isDue(lastCheck: now.addingTimeInterval(-3000), now: now))
        XCTAssertTrue(FeedChecker.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(FeedChecker.isDue(lastCheck: now.addingTimeInterval(-3600), now: now, jitter: 300), "jitter moves it")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let midnight = cal.startOfDay(for: now)
        XCTAssertTrue(FeedChecker.isNewDay(lastCheck: midnight.addingTimeInterval(-60), now: midnight.addingTimeInterval(60), calendar: cal))
        XCTAssertFalse(FeedChecker.isNewDay(lastCheck: midnight.addingTimeInterval(60), now: midnight.addingTimeInterval(7200), calendar: cal))
    }

    /// A Welcome re-checks only a stale record, at most once per 10 min, never beside a check in flight.
    func testTheWelcomeRateLimit() {
        let c = FeedChecker()
        XCTAssertFalse(c.begin(welcome: true, lastCheck: now.addingTimeInterval(-60), now: now), "fresh: no re-check")
        XCTAssertTrue(c.begin(welcome: true, lastCheck: now.addingTimeInterval(-900), now: now))
        XCTAssertFalse(c.begin(welcome: true, lastCheck: now.addingTimeInterval(-900), now: now), "one in flight")
        XCTAssertFalse(c.begin(welcome: false, lastCheck: nil, now: now), "the hourly one waits too")
        c.end()
        // The check failed (the record stayed stale): the next Welcome within 10 min does not try again.
        XCTAssertFalse(c.begin(welcome: true, lastCheck: now.addingTimeInterval(-900), now: now.addingTimeInterval(599)))
        XCTAssertTrue(c.begin(welcome: true, lastCheck: now.addingTimeInterval(-900), now: now.addingTimeInterval(600)))
        c.end()
        XCTAssertTrue(c.begin(welcome: false, lastCheck: now, now: now.addingTimeInterval(601)), "the hourly check is not rate-limited by Welcomes")
        XCTAssertTrue(c.running)
        c.end()
        XCTAssertFalse(c.running)
    }
}
