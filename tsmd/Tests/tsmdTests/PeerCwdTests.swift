import XCTest
import Darwin
@testable import tsmd

final class PeerCwdTests: XCTestCase {
    /// Build a fake `proc_pidinfo` that writes a `proc_vnodepathinfo` whose
    /// `pvi_cdir.vip_path` contains the given UTF-8 string.
    private func fakeProc(returningPath path: String, bytesReturned: Int32? = nil) -> ProcPidInfoFn {
        return { _, flavor, _, buffer, bufsize in
            guard flavor == PROC_PIDVNODEPATHINFO else { return -1 }
            let stride = MemoryLayout<proc_vnodepathinfo>.stride
            guard Int(bufsize) >= stride, let buffer = buffer else { return -1 }
            // Zero the destination, then memcpy the path bytes (NUL-terminated).
            memset(buffer, 0, stride)
            let info = buffer.assumingMemoryBound(to: proc_vnodepathinfo.self)
            withUnsafeMutableBytes(of: &info.pointee.pvi_cdir.vip_path) { dst in
                let bytes = path.utf8CString
                let limit = min(bytes.count, dst.count)
                for i in 0..<limit {
                    dst[i] = UInt8(bitPattern: bytes[i])
                }
            }
            return bytesReturned ?? Int32(stride)
        }
    }

    private func failingProc(rc: Int32 = 0) -> ProcPidInfoFn {
        return { _, _, _, _, _ in rc }
    }

    func testResolveReturnsCwdString() {
        let result = PeerCwd.resolve(peerPID: 1234, proc: fakeProc(returningPath: "/tmp/foo"))
        XCTAssertEqual(result, "/tmp/foo")
    }

    func testResolveHandlesLongPathNearMaxPathLen() {
        // Construct a path comfortably long but well under MAXPATHLEN (1024 on Darwin).
        let component = String(repeating: "a", count: 50)
        let path = "/" + Array(repeating: component, count: 12).joined(separator: "/")
        let result = PeerCwd.resolve(peerPID: 1234, proc: fakeProc(returningPath: path))
        XCTAssertEqual(result, path)
    }

    func testResolveReturnsNilOnZeroReturn() {
        // proc_pidinfo returning 0 means the process is gone or the call failed.
        let result = PeerCwd.resolve(peerPID: 1234, proc: failingProc(rc: 0))
        XCTAssertNil(result)
    }

    func testResolveReturnsNilOnShortReturn() {
        // A short return means the kernel didn't fill the struct; fail closed.
        let result = PeerCwd.resolve(peerPID: 1234,
                                     proc: fakeProc(returningPath: "/tmp/foo", bytesReturned: 4))
        XCTAssertNil(result)
    }

    func testResolveReturnsNilOnEmptyPath() {
        // An empty cwd (no NUL-prefixed string) shouldn't be treated as scope-matching root "/".
        let result = PeerCwd.resolve(peerPID: 1234, proc: fakeProc(returningPath: ""))
        XCTAssertNil(result)
    }
}
