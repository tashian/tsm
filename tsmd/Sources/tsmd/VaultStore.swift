import Foundation

struct FileVaultStore: VaultStoreProvider, Sendable {
    let path: URL

    init(path: URL = Paths.vaultFile) {
        self.path = path
    }

    func exists() -> Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    func read() throws -> VaultEnvelope {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(VaultEnvelope.self, from: data)
    }

    func write(_ envelope: VaultEnvelope) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)

        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path.path
        )
    }

    func delete() throws {
        if exists() {
            try FileManager.default.removeItem(at: path)
        }
    }
}
