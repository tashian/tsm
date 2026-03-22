import Foundation
import LocalAuthentication

struct TouchIDAuth: AuthProvider, Sendable {
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
