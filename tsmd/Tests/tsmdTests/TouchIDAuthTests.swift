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

    func testClamshellReasonPointsAtKeyboardPairing() {
        // What macOS returns from canEvaluatePolicy with the lid closed when the
        // Magic Keyboard with Touch ID has lost its pairing with this Mac:
        // systemCancel, with only the lid named in the debug text. A paired
        // keyboard works with the lid closed, so the fix is to pair it again.
        let reason = TouchIDAuth.unavailableReason(
            laError(.systemCancel, debug: "Touch ID is not available in closed clamshell mode."))
        XCTAssertTrue(reason.hasPrefix("Touch ID is not available in closed clamshell mode."), reason)
        XCTAssertTrue(reason.contains("USB cable"), reason)
        XCTAssertFalse(reason.contains("not available: Touch ID is not available"),
            "don't repeat macOS's own prefix: \(reason)")
    }

    func testDebugTextIsPrefixedWhenItDoesNotNameTouchID() {
        let reason = TouchIDAuth.unavailableReason(
            laError(.systemCancel, debug: "No console session."))
        XCTAssertEqual(reason, "Touch ID is not available: No console session.")
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
