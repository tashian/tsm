import LocalAuthentication
import XCTest
@testable import tsmd

/// TouchIDAuth must say why LocalAuthentication refused to evaluate the
/// biometric policy. A generic "Authentication required" tells the user to
/// touch a sensor that no prompt was shown for.
final class TouchIDAuthTests: XCTestCase {
    private func laError(_ code: LAError.Code, debug: String? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: "Authentication canceled."]
        if let debug { info[NSDebugDescriptionErrorKey] = debug }
        return NSError(domain: LAErrorDomain, code: code.rawValue, userInfo: info)
    }

    func testClamshellReasonIsReported() {
        // What macOS returns from canEvaluatePolicy with the lid closed and no
        // Touch ID keyboard: systemCancel, with the cause only in the debug text.
        let reason = TouchIDAuth.unavailableReason(
            laError(.systemCancel, debug: "Touch ID is not available in closed clamshell mode."))
        XCTAssertEqual(reason,
            "Touch ID is not available: Touch ID is not available in closed clamshell mode.")
    }

    func testLockoutReasonTellsUserToUsePassword() {
        let reason = TouchIDAuth.unavailableReason(laError(.biometryLockout))
        XCTAssertTrue(reason.contains("locked"), reason)
        XCTAssertTrue(reason.contains("password"), reason)
    }

    func testNotEnrolledReason() {
        let reason = TouchIDAuth.unavailableReason(laError(.biometryNotEnrolled))
        XCTAssertTrue(reason.contains("No fingerprints"), reason)
    }

    func testFallsBackToLocalizedDescription() {
        let reason = TouchIDAuth.unavailableReason(laError(.biometryNotAvailable))
        XCTAssertEqual(reason, "Touch ID is not available: Authentication canceled.")
    }

    func testNilErrorStillGivesAReason() {
        XCTAssertEqual(TouchIDAuth.unavailableReason(nil), "Touch ID is not available.")
    }
}
