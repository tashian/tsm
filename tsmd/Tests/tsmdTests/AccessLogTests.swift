import XCTest
@testable import tsmd

final class AccessLogTests: XCTestCase {
    var tmpDir: URL!
    var logPath: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsmd-log-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        logPath = tmpDir.appendingPathComponent("access.log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testLogWritesEntry() throws {
        let log = FileAccessLog(path: logPath)
        try log.log(method: "vault.get", secret: "my_key", command: "gh pr list", result: "ok")

        let content = try String(contentsOf: logPath, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)

        let entry = try JSONDecoder().decode(AccessLogEntry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(entry.method, "vault.get")
        XCTAssertEqual(entry.secret, "my_key")
        XCTAssertEqual(entry.command, "gh pr list")
        XCTAssertEqual(entry.result, "ok")
        XCTAssertFalse(entry.ts.isEmpty)
    }

    func testMultipleEntriesAppend() throws {
        let log = FileAccessLog(path: logPath)
        try log.log(method: "vault.get", secret: "a", command: nil, result: "ok")
        try log.log(method: "vault.get", secret: "b", command: nil, result: "ok")
        try log.log(method: "vault.lock", secret: nil, command: nil, result: "ok")

        let content = try String(contentsOf: logPath, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
    }

    func testNilSecret() throws {
        let log = FileAccessLog(path: logPath)
        try log.log(method: "vault.lock", secret: nil, command: nil, result: "ok")

        let content = try String(contentsOf: logPath, encoding: .utf8)
        let entry = try JSONDecoder().decode(AccessLogEntry.self, from: Data(content.utf8))
        XCTAssertNil(entry.secret)
    }

    func testLogRotation() throws {
        let log = FileAccessLog(path: logPath, maxSize: 500)

        for i in 0..<20 {
            try log.log(method: "vault.get", secret: "key_\(i)", command: nil, result: "ok")
        }

        let backup = logPath.deletingPathExtension().appendingPathExtension("1.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testLogCreatesParentDirectories() throws {
        let nested = tmpDir.appendingPathComponent("a/b/access.log")
        let log = FileAccessLog(path: nested)
        try log.log(method: "vault.get", secret: "k", command: nil, result: "ok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testDecodesOldLineWithClientID() throws {
        let old = #"{"ts":"2026-01-01T00:00:00Z","method":"vault.get","secret":"k","client_id":"cli/pid:1","result":"ok"}"#
        let entry = try JSONDecoder().decode(AccessLogEntry.self, from: Data(old.utf8))
        XCTAssertNil(entry.command)
        XCTAssertEqual(entry.secret, "k")
    }

    func testNoClientIDWritten() throws {
        let log = FileAccessLog(path: logPath)
        try log.log(method: "vault.lock", secret: nil, command: nil, result: "ok")
        let content = try String(contentsOf: logPath, encoding: .utf8)
        XCTAssertFalse(content.contains("client_id"))
    }
}
