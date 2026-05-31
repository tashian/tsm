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
            throw VaultError.authFailed
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
}
