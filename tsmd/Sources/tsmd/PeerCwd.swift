import Foundation
import Darwin

/// Closure type matching `proc_pidinfo`'s signature, exposed so tests can
/// inject a fake without touching the kernel. The real production callsite
/// uses `proc_pidinfo` directly.
typealias ProcPidInfoFn = (pid_t, Int32, UInt64, UnsafeMutableRawPointer?, Int32) -> Int32

enum PeerCwd {
    /// Return the connecting peer process's current working directory by
    /// asking the kernel via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
    ///
    /// Why the daemon does this rather than letting the CLI claim its cwd:
    /// the CLI is untrusted in this dimension. A malicious binary could
    /// trivially send `cwd=/somewhere/else` to exfiltrate scoped secrets.
    /// The kernel's view, indexed by the peer's real pid (already pulled
    /// from `LOCAL_PEERPID` upstream), is the only honest source.
    ///
    /// Returns nil when the kernel call fails or the process has gone
    /// away mid-call. Callers should treat nil as "out of scope" — global
    /// secrets remain accessible, project-scoped secrets do not.
    ///
    /// The closure injection mirrors `PeerSession.resolveDurableSessionID`'s
    /// `sessionOf` / `parentOf` parameters so the test suite can fake the
    /// syscall layer.
    static func resolve(
        peerPID: pid_t,
        proc: ProcPidInfoFn = { proc_pidinfo($0, $1, $2, $3, $4) }
    ) -> String? {
        var info = proc_vnodepathinfo()
        let stride = MemoryLayout<proc_vnodepathinfo>.stride
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc(peerPID, PROC_PIDVNODEPATHINFO, 0, UnsafeMutableRawPointer(ptr), Int32(stride))
        }
        // The kernel writes exactly `stride` bytes on success. Anything less
        // means a truncated read or process-gone, both of which we fail closed on.
        guard rc >= Int32(stride) else { return nil }

        // `vip_path` is a fixed-size NUL-terminated C string of MAXPATHLEN.
        let path: String = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            // Find the NUL terminator and decode the prefix as UTF-8.
            let bytes = raw.bindMemory(to: UInt8.self)
            var len = 0
            while len < bytes.count && bytes[len] != 0 { len += 1 }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[0..<len]), as: UTF8.self)
        }
        guard !path.isEmpty else { return nil }
        return path
    }
}
