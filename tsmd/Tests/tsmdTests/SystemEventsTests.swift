import XCTest
@testable import tsmd

final class SystemEventsTests: XCTestCase {
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
