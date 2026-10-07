import XCTest
@testable import tsmd

final class CommandTextTests: XCTestCase {
    func testJoinPlainArgs() {
        XCTAssertEqual(CommandText.join(["gh", "pr", "list", "--repo", "tashian/tsm"]),
                       "gh pr list --repo tashian/tsm")
    }

    func testJoinQuotesSpacesAndMetacharacters() {
        XCTAssertEqual(CommandText.join(["curl", "-H", "A: b", "https://x/y?q=1"]),
                       "curl -H 'A: b' 'https://x/y?q=1'")
        XCTAssertEqual(CommandText.join(["sh", "-c", "echo $HOME"]), "sh -c 'echo $HOME'")
    }

    func testQuoteEmptyAndSingleQuote() {
        XCTAssertEqual(CommandText.quote(""), "''")
        XCTAssertEqual(CommandText.quote("it's"), #"'it'\''s'"#)
    }

    func testCleanReplacesNewlines() {
        XCTAssertEqual(CommandText.clean("cd /x\ntsm get a\t| wc\r"), "cd /x tsm get a | wc ")
    }

    func testCleanRemovesControlAndFormatCharacters() {
        XCTAssertEqual(CommandText.clean("a\u{07}b\u{1B}[31mc"), "ab[31mc")
        // Right-to-left override could reorder what the user reads.
        XCTAssertEqual(CommandText.clean("gh \u{202E}lruc"), "gh lruc")
        XCTAssertEqual(CommandText.clean("x\u{200B}y"), "xy")
    }

    func testJoinCleansBeforeQuoting() {
        XCTAssertEqual(CommandText.join(["echo", "a\nb"]), "echo 'a b'")
    }

    func testTruncateShortUnchanged() {
        XCTAssertEqual(CommandText.truncate("gh pr list", limit: 300), "gh pr list")
    }

    func testTruncateKeepsHeadAndTail() {
        let long = "python3 " + String(repeating: "x", count: 400) + " --out end.json"
        let t = CommandText.truncate(long, limit: 300)
        XCTAssertEqual(t.count, 300)
        XCTAssertTrue(t.hasPrefix("python3 "))
        XCTAssertTrue(t.hasSuffix("--out end.json"))
        XCTAssertTrue(t.contains("…"))
    }
}
