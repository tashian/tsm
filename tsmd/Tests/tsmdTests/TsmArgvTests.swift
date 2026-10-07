import XCTest
@testable import tsmd

final class TsmArgvTests: XCTestCase {
    func testRunSecretsAndTarget() throws {
        let r = try XCTUnwrap(TsmArgv.run(["run", "--env", "GITHUB_TOKEN=gh-pat", "--", "gh", "pr", "list"]))
        XCTAssertEqual(r.secrets, ["gh-pat"])
        XCTAssertEqual(r.target, ["gh", "pr", "list"])
    }

    func testRunManyEnvAndEqualsForm() throws {
        let r = try XCTUnwrap(TsmArgv.run(
            ["run", "--env=A=key-a", "--env", "B=key-b", "--env", "C=key-a", "--", "./deploy.sh", "prod"]))
        XCTAssertEqual(r.secrets, ["key-a", "key-b"])   // unique, in order
        XCTAssertEqual(r.target, ["./deploy.sh", "prod"])
    }

    func testRunWithoutDoubleDash() throws {
        let r = try XCTUnwrap(TsmArgv.run(["run", "--env", "A=k", "gh", "pr"]))
        XCTAssertEqual(r.target, ["gh", "pr"])
    }

    func testRunBareDashIsPositional() throws {
        // pflag treats "-" as an argument, so cobra runs a program named "-".
        let r = try XCTUnwrap(TsmArgv.run(["run", "-", "--env", "T=gh-pat", "--", "gh", "pr", "list"]))
        XCTAssertEqual(r.target, ["-", "gh", "pr", "list"])
        XCTAssertEqual(r.secrets, ["gh-pat"])
    }

    func testRunPositionalBeforeEnv() throws {
        // cobra intersperses flags: positionals before "--" come first.
        let r = try XCTUnwrap(TsmArgv.run(["run", "gh", "--env", "T=x", "--", "pr", "list"]))
        XCTAssertEqual(r.target, ["gh", "pr", "list"])
        XCTAssertEqual(r.secrets, ["x"])
    }

    func testBareDashIsNotASubcommandFlag() {
        XCTAssertNil(TsmArgv.run(["-", "run", "--env", "A=k", "--", "x"]))
        XCTAssertEqual(TsmArgv.getSecret(["get", "-"]), "-")
    }

    func testRunAfterGlobalFlag() throws {
        let r = try XCTUnwrap(TsmArgv.run(["--json", "run", "--env", "A=k", "--", "true"]))
        XCTAssertEqual(r.secrets, ["k"])
    }

    func testNotRun() {
        XCTAssertNil(TsmArgv.run(["get", "x"]))
        XCTAssertNil(TsmArgv.run([]))
    }

    func testGetSecret() {
        XCTAssertEqual(TsmArgv.getSecret(["get", "gh-pat"]), "gh-pat")
        XCTAssertEqual(TsmArgv.getSecret(["get", "--to-file", "/tmp/x", "gh-pat"]), "gh-pat")
        XCTAssertEqual(TsmArgv.getSecret(["get", "--format=pgpass", "db"]), "db")
        XCTAssertEqual(TsmArgv.getSecret(["get", "--format", "env GITHUB_TOKEN", "gh-pat"]), "gh-pat")
    }

    func testGetAfterGlobalFlag() {
        XCTAssertEqual(TsmArgv.getSecret(["--json", "get", "gh-pat"]), "gh-pat")
    }

    func testGetWithoutName() {
        XCTAssertNil(TsmArgv.getSecret(["get"]))
        XCTAssertNil(TsmArgv.getSecret(["list"]))
    }
}
