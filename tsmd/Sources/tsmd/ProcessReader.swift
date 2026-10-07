import Foundation
import Darwin

/// A process's argv and environment, as the kernel reports them.
struct ProcArgs: Equatable, Sendable {
    let argv: [String]
    let env: [String: String]
}

/// Reads data about other processes. A protocol so tests can supply fake
/// process trees.
protocol ProcessReader: Sendable {
    func args(of pid: pid_t) -> ProcArgs?
    func parent(of pid: pid_t) -> pid_t?
    func cwd(of pid: pid_t) -> String?
}

struct KernelProcessReader: ProcessReader {
    func args(of pid: pid_t) -> ProcArgs? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, u_int(mib.count), &argmax, &size, nil, 0) == 0, argmax > 0 else {
            return nil
        }
        var buf = [UInt8](repeating: 0, count: Int(argmax))
        var len = buf.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else { return nil }
        return Self.parse(Array(buf.prefix(len)))
    }

    func parent(of pid: pid_t) -> pid_t? { PeerSession.ppid(of: pid) }

    func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Parses a KERN_PROCARGS2 buffer: an Int32 argc, the exec path, NUL
    /// padding, argc NUL-terminated argv strings, then NUL-terminated
    /// KEY=VALUE environment strings. Returns nil if the buffer is too short
    /// for the argc it claims.
    static func parse(_ buf: [UInt8]) -> ProcArgs? {
        guard buf.count >= 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }
        var i = 4
        while i < buf.count, buf[i] != 0 { i += 1 }   // exec path
        while i < buf.count, buf[i] == 0 { i += 1 }   // padding

        func next() -> String? {
            guard i < buf.count else { return nil }
            let start = i
            while i < buf.count, buf[i] != 0 { i += 1 }
            guard i < buf.count else { return nil }   // no terminator
            let s = String(decoding: buf[start..<i], as: UTF8.self)
            i += 1
            return s
        }

        var argv: [String] = []
        for _ in 0..<argc {
            guard let a = next() else { return nil }
            argv.append(a)
        }
        var env: [String: String] = [:]
        while let e = next(), !e.isEmpty {
            guard let eq = e.firstIndex(of: "=") else { continue }
            env[String(e[..<eq])] = String(e[e.index(after: eq)...])
        }
        return ProcArgs(argv: argv, env: env)
    }
}
