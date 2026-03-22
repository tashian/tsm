import Foundation

enum Paths {
    static var configDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            return URL(fileURLWithPath: xdg).appendingPathComponent("tsm")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tsm")
    }

    static var dataDir: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] {
            return URL(fileURLWithPath: xdg).appendingPathComponent("tsm")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/tsm")
    }

    static var socketPath: String {
        if let sock = ProcessInfo.processInfo.environment["TSM_AUTH_SOCK"] {
            return sock
        }
        let runtimeDir: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] {
            runtimeDir = xdg
        } else if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] {
            runtimeDir = tmpdir
        } else {
            runtimeDir = NSTemporaryDirectory()
        }
        return (runtimeDir as NSString).appendingPathComponent("tsm/vault.sock")
    }

    static var vaultFile: URL { dataDir.appendingPathComponent("vault.enc") }
    static var accessLog: URL { dataDir.appendingPathComponent("access.log") }
    static var configFile: URL { configDir.appendingPathComponent("config.json") }
}
