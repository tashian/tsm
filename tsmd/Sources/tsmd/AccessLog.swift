import Foundation

struct AccessLogEntry: Codable {
    let ts: String
    let method: String
    let secret: String?
    /// The command the daemon read from the peer process. Older lines have
    /// `client_id` in its place; the decoder ignores that key.
    let command: String?
    let result: String
}

final class FileAccessLog: AccessLogProvider, @unchecked Sendable {
    let path: URL
    private let maxSize: Int
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(path: URL = Paths.accessLog, maxSize: Int = 10 * 1024 * 1024) {
        self.path = path
        self.maxSize = maxSize
    }

    func log(method: String, secret: String?, command: String?, result: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let entry = AccessLogEntry(
            ts: dateFormatter.string(from: Date()),
            method: method,
            secret: secret,
            command: command,
            result: result
        )
        let data = try encoder.encode(entry)
        var line = data
        line.append(0x0A)

        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int, size >= maxSize {
            try rotate()
            // Recreate the file after rotation
            FileManager.default.createFile(atPath: path.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }

        let handle = try FileHandle(forWritingTo: path)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(line)
    }

    private func rotate() throws {
        let backup = path.deletingPathExtension().appendingPathExtension("1.log")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.moveItem(at: path, to: backup)
    }
}
