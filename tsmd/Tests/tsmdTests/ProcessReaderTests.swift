import XCTest
@testable import tsmd

final class ProcessReaderTests: XCTestCase {
    /// Builds a KERN_PROCARGS2 buffer: Int32 argc, exec path, NUL padding,
    /// argv strings, env strings, each NUL-terminated.
    private func buffer(argv: [String], env: [String], execPath: String = "/x/tsm") -> [UInt8] {
        var argc = Int32(argv.count)
        var buf = withUnsafeBytes(of: &argc) { Array($0) }
        buf += Array(execPath.utf8) + [0, 0, 0]
        for a in argv { buf += Array(a.utf8) + [0] }
        for e in env { buf += Array(e.utf8) + [0] }
        buf += [0]
        return buf
    }

    func testParseArgvAndEnv() {
        let buf = buffer(argv: ["tsm", "get", "gh-pat"], env: ["PATH=/bin:/usr/bin", "HOME=/Users/x"])
        let parsed = KernelProcessReader.parse(buf)
        XCTAssertEqual(parsed?.argv, ["tsm", "get", "gh-pat"])
        XCTAssertEqual(parsed?.env["PATH"], "/bin:/usr/bin")
        XCTAssertEqual(parsed?.env["HOME"], "/Users/x")
    }

    func testParseEnvValueWithEquals() {
        let buf = buffer(argv: ["a"], env: ["X=a=b"])
        XCTAssertEqual(KernelProcessReader.parse(buf)?.env["X"], "a=b")
    }

    func testParseTooShortIsNil() {
        XCTAssertNil(KernelProcessReader.parse([1, 0]))
    }

    func testParseMissingArgsIsNil() {
        var buf = buffer(argv: ["only-one"], env: [])
        buf[0] = 3   // claim three args
        // Remove the env terminator so the buffer ends after one arg.
        buf.removeLast()
        XCTAssertNil(KernelProcessReader.parse(buf))
    }

    func testParseInvalidUTF8() {
        var argc: Int32 = 1
        var buf = withUnsafeBytes(of: &argc) { Array($0) }
        buf += Array("/x".utf8) + [0, 0]
        buf += [0x74, 0xFF, 0x6D, 0]   // "t", invalid byte, "m"
        buf += [0]
        XCTAssertEqual(KernelProcessReader.parse(buf)?.argv, ["t\u{FFFD}m"])
    }

    func testReadsOwnProcess() throws {
        let reader = KernelProcessReader()
        let me = getpid()
        let args = try XCTUnwrap(reader.args(of: me))
        XCTAssertEqual(args.argv, CommandLine.arguments)
        XCTAssertFalse(args.env.isEmpty)
        XCTAssertEqual(reader.parent(of: me), getppid())
        let cwd = try XCTUnwrap(reader.cwd(of: me))
        XCTAssertEqual(
            URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        )
    }

    func testExecutablePathOfOwnProcess() throws {
        let path = try XCTUnwrap(KernelProcessReader().executablePath(of: getpid()))
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertEqual((path as NSString).lastPathComponent,
                       (CommandLine.arguments[0] as NSString).lastPathComponent)
    }

    func testExecutablePathOfMissingProcessIsNil() {
        XCTAssertNil(KernelProcessReader().executablePath(of: Int32.max))
    }

    func testMissingProcessIsNil() {
        // PID 0 is the kernel; a normal user cannot read its args.
        XCTAssertNil(KernelProcessReader().args(of: 0))
    }
}
