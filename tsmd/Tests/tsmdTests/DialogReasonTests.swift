import XCTest
@testable import tsmd

final class DialogReasonTests: XCTestCase {
    func testUnlockWithSecretAndCommand() {
        XCTAssertEqual(DialogReason.make(.unlock, secrets: ["gh-pat"], command: "gh pr list --repo tashian/tsm"),
                       "unlock the vault and access 'gh-pat':\n\ngh pr list --repo tashian/tsm")
    }

    func testUnlockWithCommandOnly() {
        XCTAssertEqual(DialogReason.make(.unlock, secrets: [], command: "tsm list --json"),
                       "unlock the vault:\n\ntsm list --json")
    }

    func testUnlockPlain() {
        XCTAssertEqual(DialogReason.make(.unlock, secrets: [], command: nil), "unlock the vault")
        XCTAssertEqual(DialogReason.make(.unlock, secrets: [], command: ""), "unlock the vault")
    }

    func testAccessManySecrets() {
        XCTAssertEqual(DialogReason.make(.access, secrets: ["openai-key", "anthropic-key"],
                                         command: "python3 scripts/eval.py --model gpt-5"),
                       "access 'openai-key' and 'anthropic-key':\n\npython3 scripts/eval.py --model gpt-5")
    }

    func testAccessWithoutCommand() {
        XCTAssertEqual(DialogReason.make(.access, secrets: ["gh-pat"], command: nil), "access 'gh-pat'")
    }

    func testLongCommandIsTruncated() {
        let command = "python3 " + String(repeating: "a", count: 500)
        let reason = DialogReason.make(.access, secrets: ["k"], command: command)
        let shown = reason.components(separatedBy: "\n\n")[1]
        XCTAssertEqual(shown.count, CommandText.dialogLimit)
        XCTAssertTrue(shown.hasPrefix("python3 "))
    }
}
