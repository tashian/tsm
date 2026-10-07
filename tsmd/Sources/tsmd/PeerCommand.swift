import Foundation

/// What the daemon knows about the process on the other end of a connection.
struct PeerInfo: Equatable, Sendable {
    /// The command to show the user: cleaned, not truncated. nil if unknown.
    let command: String?
    /// Secret names the command will read, from `tsm run --env` or `tsm get NAME`.
    let secrets: [String]

    static let unknown = PeerInfo(command: nil, secrets: [])
}

/// Finds the command that will receive a secret, from the kernel's view of
/// the peer process and its ancestors. Nothing here comes from the client.
enum PeerCommand {
    static let trustedDirs: Set<String> = [
        "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin",
    ]
    /// The npm package runs the real tsm binary from one of these.
    static let launchers: Set<String> = ["node", "bun"]
    static let maxAncestors = 3

    static func describe(
        peerPID: pid_t,
        reader: ProcessReader = KernelProcessReader(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> PeerInfo {
        guard let peer = reader.args(of: peerPID), let argv0 = peer.argv.first else { return .unknown }
        guard basename(argv0) == "tsm" else {
            return PeerInfo(command: CommandText.join(peer.argv), secrets: [])
        }
        let args = Array(peer.argv.dropFirst())
        if let run = TsmArgv.run(args) {
            let target = displayTarget(run.target, env: peer.env, cwd: reader.cwd(of: peerPID),
                                       isExecutable: isExecutable)
            return PeerInfo(command: CommandText.join(target), secrets: run.secrets)
        }
        let secrets = TsmArgv.getSecret(args).map { [$0] } ?? []
        let command = shellCommand(above: peerPID, reader: reader) ?? CommandText.join(["tsm"] + args)
        return PeerInfo(command: command, secrets: secrets)
    }

    /// The `-c` command of the nearest shell ancestor, going up through
    /// node/bun launchers only.
    private static func shellCommand(above pid: pid_t, reader: ProcessReader) -> String? {
        var current = pid
        for _ in 0..<maxAncestors {
            guard let parent = reader.parent(of: current), parent > 1,
                  let args = reader.args(of: parent) else { return nil }
            if let command = ShellCommand.command(fromShellArgv: args.argv) {
                return CommandText.clean(command)
            }
            guard let first = args.argv.first, launchers.contains(basename(first)) else { return nil }
            current = parent
        }
        return nil
    }

    /// The target argv as the dialog shows it: the program as typed when it
    /// resolves into a trusted directory, its absolute path when not.
    private static func displayTarget(_ target: [String], env: [String: String], cwd: String?,
                                      isExecutable: (String) -> Bool) -> [String] {
        guard let program = target.first else { return target }
        let resolved: String?
        if program.contains("/") {
            if program.hasPrefix("/") {
                resolved = program
            } else {
                resolved = cwd.map { ($0 as NSString).appendingPathComponent(program) }
            }
        } else {
            resolved = (env["PATH"] ?? "")
                .split(separator: ":")
                .map { (String($0) as NSString).appendingPathComponent(program) }
                .first(where: isExecutable)
        }
        guard let path = resolved.map({ ($0 as NSString).standardizingPath }) else { return target }
        if trustedDirs.contains((path as NSString).deletingLastPathComponent) { return target }
        return [path] + target.dropFirst()
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
