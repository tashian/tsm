import Foundation
import Darwin

enum PeerSession {
    /// Walk up the session-leader chain starting from `peerPID`'s session and
    /// return the first ancestor session whose leader was not spawned by an
    /// agent harness (i.e., whose parent lives in the system session, sid=1).
    ///
    /// Why: agent tool harnesses like Claude Code's Bash tool call `setsid()`
    /// for every spawned command so they can deliver clean process-group
    /// signals. That means every `tsm` invocation from such an agent has a
    /// distinct sid, and keying unlock TTL on the raw peer sid forces a
    /// fresh Touch ID prompt on every call. Walking up collapses every
    /// ephemeral setsid'd child of the same agent into a single shared
    /// session id, while stopping at sid=1 keeps real terminal sessions
    /// (login, sshd, screen, distinct iTerm tabs) isolated from each other.
    static func resolveDurableSessionID(
        peerPID: pid_t,
        sessionOf: (pid_t) -> pid_t = { getsid($0) },
        parentOf: (pid_t) -> pid_t? = ppid(of:),
        maxHops: Int = 8
    ) -> pid_t? {
        var sid = sessionOf(peerPID)
        guard sid > 0 else { return nil }

        for _ in 0..<maxHops {
            // A session leader's pid equals its sid, so `sid` is the leader's pid.
            guard let leaderParent = parentOf(sid), leaderParent > 1 else { break }
            let parentSid = sessionOf(leaderParent)
            guard parentSid > 0 else { break }
            if parentSid == 1 { break }       // crossed into launchd's system session
            if parentSid == sid { break }     // defensive: shouldn't happen for real session leaders
            sid = parentSid
        }
        return sid
    }

    /// Look up a process's parent pid via `proc_pidinfo(PROC_PIDTBSDINFO)`.
    /// Returns nil if the process is gone or info is unavailable.
    static func ppid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard r == Int32(size) else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
