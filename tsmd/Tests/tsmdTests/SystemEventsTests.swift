import XCTest
@testable import tsmd

final class SystemEventsTests: XCTestCase {
    func testStartStopReleasesIOKitResources() throws {
        // Create + start + stop multiple times in sequence; tests exit cleanly
        // (no leaked io_object_t, no double-free crash) only if start/stop
        // properly pair acquisition and release of IOKit resources.
        for _ in 0..<3 {
            let events = SystemEvents(onLock: {})
            events.start()
            events.stop()
        }
    }

    func testScreenLockNotificationFiresHandler() async throws {
        let exp = expectation(description: "lock handler called")
        let events = SystemEvents(onLock: {
            exp.fulfill()
        })
        events.start()
        defer { events.stop() }

        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, userInfo: nil, deliverImmediately: true
        )

        await fulfillment(of: [exp], timeout: 2.0)
    }
}
