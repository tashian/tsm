import XCTest
@testable import tsmd

final class IdleTrackerTests: XCTestCase {
    func testInitialActivityTimeIsTheGivenNow() async {
        let t0 = Date(timeIntervalSince1970: 1000)
        let tracker = IdleTracker(now: t0)
        let last = await tracker.lastActivityAt
        XCTAssertEqual(last, t0)
    }

    func testBumpUpdatesActivityTime() async {
        let t0 = Date(timeIntervalSince1970: 1000)
        let tracker = IdleTracker(now: t0)
        let t1 = Date(timeIntervalSince1970: 2000)
        await tracker.bump(now: t1)
        let last = await tracker.lastActivityAt
        XCTAssertEqual(last, t1)
    }

    func testIsIdleFalseBeforeThreshold() async {
        let t0 = Date(timeIntervalSince1970: 1000)
        let tracker = IdleTracker(now: t0)
        let isIdle = await tracker.isIdle(
            idleSeconds: 60,
            now: Date(timeIntervalSince1970: 1030)
        )
        XCTAssertFalse(isIdle)
    }

    func testIsIdleTrueAfterThreshold() async {
        let t0 = Date(timeIntervalSince1970: 1000)
        let tracker = IdleTracker(now: t0)
        let isIdle = await tracker.isIdle(
            idleSeconds: 60,
            now: Date(timeIntervalSince1970: 1061)
        )
        XCTAssertTrue(isIdle)
    }

    func testIsIdleTrueAtExactThreshold() async {
        let t0 = Date(timeIntervalSince1970: 1000)
        let tracker = IdleTracker(now: t0)
        // Exact boundary uses >= so we don't dance around drift in the
        // 15s polling timer that wraps this check in production.
        let isIdle = await tracker.isIdle(
            idleSeconds: 60,
            now: Date(timeIntervalSince1970: 1060)
        )
        XCTAssertTrue(isIdle)
    }

    func testBumpResetsIdleness() async {
        let t0 = Date(timeIntervalSince1970: 1000)
        let tracker = IdleTracker(now: t0)
        await tracker.bump(now: Date(timeIntervalSince1970: 2000))

        let isIdleEarly = await tracker.isIdle(
            idleSeconds: 60,
            now: Date(timeIntervalSince1970: 2050)
        )
        XCTAssertFalse(isIdleEarly, "bump should reset the idle window")

        let isIdleLate = await tracker.isIdle(
            idleSeconds: 60,
            now: Date(timeIntervalSince1970: 2070)
        )
        XCTAssertTrue(isIdleLate)
    }
}
