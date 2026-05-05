import Foundation

/// Tracks the timestamp of the most recent client activity. Used by the
/// daemon to decide when it can shut itself down: combined with the vault's
/// locked state, an idle window past the threshold means no client cares
/// about this process anymore, so a fresh `tsm` invocation may as well
/// respawn from the latest binary on disk.
actor IdleTracker {
    private(set) var lastActivityAt: Date

    init(now: Date = Date()) {
        self.lastActivityAt = now
    }

    func bump(now: Date = Date()) {
        lastActivityAt = now
    }

    func isIdle(idleSeconds: TimeInterval, now: Date = Date()) -> Bool {
        return now.timeIntervalSince(lastActivityAt) >= idleSeconds
    }
}
