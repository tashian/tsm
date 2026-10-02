import Foundation
import LocalAuthentication

struct TouchIDAuth: AuthProvider, Sendable {
    /// True when biometrics can be evaluated right now (enrolled, not locked
    /// out, GUI session present). Presents no UI. Returns false in headless
    /// contexts with no console session, so callers can refuse cleanly instead
    /// of triggering a prompt nobody can see.
    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // No prompt was shown. Say why, so the caller doesn't wait for (or
            // tell the user to touch) a dialog that will never appear.
            throw VaultError.authUnavailable(Self.unavailableReason(error))
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            guard success else {
                throw VaultError.authFailed
            }
        } catch {
            throw VaultError.authFailed
        }
    }

    /// Human-readable cause for a failed `canEvaluatePolicy`. macOS often puts
    /// the real cause only in the debug description — with the lid closed it
    /// returns `systemCancel` ("Authentication canceled.") and the debug text
    /// "Touch ID is not available in closed clamshell mode."
    static func unavailableReason(_ error: NSError?) -> String {
        guard let error else { return "Touch ID is not available." }
        if error.domain == LAErrorDomain {
            switch LAError.Code(rawValue: error.code) {
            case .biometryLockout:
                return "Touch ID is locked after too many failed attempts. "
                    + "Unlock your Mac with your password to turn it back on."
            case .biometryNotEnrolled:
                return "No fingerprints are enrolled for Touch ID. "
                    + "Add one in System Settings > Touch ID & Password."
            case .passcodeNotSet:
                return "Touch ID requires a login password, and none is set."
            default:
                break
            }
        }
        let detail = (error.userInfo[NSDebugDescriptionErrorKey] as? String)
            ?? error.localizedDescription
        return "Touch ID is not available: \(detail)"
    }
}
