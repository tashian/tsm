import XCTest
@testable import tsmd

final class ShellCommandTests: XCTestCase {
    func testBashDashC() {
        XCTAssertEqual(ShellCommand.script(fromShellArgv: ["/bin/bash", "-c", "tsm get a | wc -c"]),
                       "tsm get a | wc -c")
    }

    func testFlagsAroundDashC() {
        XCTAssertEqual(ShellCommand.script(fromShellArgv: ["zsh", "-c", "-l", "x"]), "x")
        XCTAssertEqual(ShellCommand.script(fromShellArgv: ["bash", "-lc", "x"]), "x")
        XCTAssertEqual(ShellCommand.script(fromShellArgv: ["bash", "--login", "-c", "x"]), "x")
        XCTAssertEqual(ShellCommand.script(fromShellArgv: ["/opt/homebrew/bin/fish", "-c", "x"]), "x")
    }

    func testNotAShellCommand() {
        XCTAssertNil(ShellCommand.script(fromShellArgv: ["-zsh"]))                 // interactive login shell
        XCTAssertNil(ShellCommand.script(fromShellArgv: ["/opt/homebrew/bin/fish"]))
        XCTAssertNil(ShellCommand.script(fromShellArgv: ["bash", "script.sh"]))
        XCTAssertNil(ShellCommand.script(fromShellArgv: ["node", "-c", "x"]))     // not a shell
        XCTAssertNil(ShellCommand.script(fromShellArgv: []))
    }

    func testUnwrapClaudeCodeWrapper() {
        let script = #"source /Users/carl/.claude/shell-snapshots/snapshot-bash-1.sh 2>/dev/null || true && shopt -u extglob 2>/dev/null || true && eval 'tsm get gh-pat | curl -sH @- https://api.github.com/user' < /dev/null && pwd -P >| /tmp/claude-36fb-cwd"#
        XCTAssertEqual(ShellCommand.unwrapEval(script),
                       "tsm get gh-pat | curl -sH @- https://api.github.com/user")
    }

    func testUnwrapDoubleQuoteEscapeStyle() {
        // Claude Code writes ' inside the command as '"'"'.
        let script = #"true && eval 'curl -H '"'"'A: b'"'"' https://x | tsm get k' < /dev/null"#
        XCTAssertEqual(ShellCommand.unwrapEval(script), "curl -H 'A: b' https://x | tsm get k")
    }

    func testUnwrapBackslashEscapeStyle() {
        let script = #"eval 'echo '\''hi'\'' && tsm get a' < /dev/null"#
        XCTAssertEqual(ShellCommand.unwrapEval(script), "echo 'hi' && tsm get a")
    }

    func testUnwrapWithoutEvalIsUnchanged() {
        XCTAssertEqual(ShellCommand.unwrapEval("tsm get a | wc -c"), "tsm get a | wc -c")
    }

    func testUnwrapUnterminatedIsUnchanged() {
        let script = "eval 'tsm get a"
        XCTAssertEqual(ShellCommand.unwrapEval(script), script)
    }

    func testCommandCombinesBoth() {
        let argv = ["/opt/homebrew/bin/bash", "-c", "x && eval 'tsm get a | wc -c' < /dev/null"]
        XCTAssertEqual(ShellCommand.command(fromShellArgv: argv), "tsm get a | wc -c")
    }
}
