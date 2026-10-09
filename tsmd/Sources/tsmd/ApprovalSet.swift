import Foundation

/// Confirm-gated secrets the user approved in a Touch ID dialog on one
/// connection. Lives as long as the connection. Names match without case,
/// as the vault's lookup does.
final class ApprovalSet: @unchecked Sendable {
    private var names: Set<String> = []
    private let lock = NSLock()

    init() {}

    func contains(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.contains(name.lowercased())
    }

    func insert(_ more: [String]) {
        lock.lock()
        defer { lock.unlock() }
        names.formUnion(more.map { $0.lowercased() })
    }
}
