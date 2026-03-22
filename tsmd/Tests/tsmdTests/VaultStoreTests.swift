import XCTest
@testable import tsmd

final class VaultStoreTests: XCTestCase {
    var tmpDir: URL!
    var store: FileVaultStore!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsmd-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = FileVaultStore(path: tmpDir.appendingPathComponent("vault.enc"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testExistsReturnsFalseWhenNoFile() {
        XCTAssertFalse(store.exists())
    }

    func testWriteThenReadRoundTrip() throws {
        let envelope = VaultEnvelope(
            version: 1,
            algorithm: "aes-256-gcm",
            recovery: nil,
            nonce: "bm9uY2U=",
            ciphertext: "Y2lwaGVy"
        )
        try store.write(envelope)
        XCTAssertTrue(store.exists())

        let read = try store.read()
        XCTAssertEqual(read.version, 1)
        XCTAssertEqual(read.algorithm, "aes-256-gcm")
        XCTAssertEqual(read.nonce, "bm9uY2U=")
        XCTAssertEqual(read.ciphertext, "Y2lwaGVy")
    }

    func testWriteWithRecoveryParams() throws {
        let envelope = VaultEnvelope(
            version: 1,
            algorithm: "aes-256-gcm",
            recovery: RecoveryParams(salt: "c2FsdA==", iterations: 600_000),
            nonce: "bm9uY2U=",
            ciphertext: "Y2lwaGVy"
        )
        try store.write(envelope)
        let read = try store.read()
        XCTAssertEqual(read.recovery?.iterations, 600_000)
    }

    func testDeleteRemovesFile() throws {
        let envelope = VaultEnvelope(
            version: 1, algorithm: "aes-256-gcm", recovery: nil,
            nonce: "bm9uY2U=", ciphertext: "Y2lwaGVy"
        )
        try store.write(envelope)
        XCTAssertTrue(store.exists())
        try store.delete()
        XCTAssertFalse(store.exists())
    }

    func testDeleteWhenNoFileDoesNotThrow() throws {
        XCTAssertNoThrow(try store.delete())
    }

    func testFilePermissions() throws {
        let envelope = VaultEnvelope(
            version: 1, algorithm: "aes-256-gcm", recovery: nil,
            nonce: "bm9uY2U=", ciphertext: "Y2lwaGVy"
        )
        try store.write(envelope)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.path.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testWriteCreatesParentDirectories() throws {
        let nested = tmpDir.appendingPathComponent("a/b/c/vault.enc")
        let nestedStore = FileVaultStore(path: nested)
        let envelope = VaultEnvelope(
            version: 1, algorithm: "aes-256-gcm", recovery: nil,
            nonce: "bm9uY2U=", ciphertext: "Y2lwaGVy"
        )
        try nestedStore.write(envelope)
        XCTAssertTrue(nestedStore.exists())
    }
}
