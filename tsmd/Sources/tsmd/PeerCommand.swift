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
        isExecutable: (String) -> Bool = isExecutableFile
    ) -> PeerInfo {
        guard let peer = reader.args(of: peerPID), !peer.argv.isEmpty else { return .unknown }
        // Identity comes from the executable path; argv[0] is the peer's to set.
        let exe = reader.executablePath(of: peerPID)
        guard let exe, basename(exe) == "tsm" else {
            return PeerInfo(command: display(peer.argv, exe: exe), secrets: [])
        }
        let args = Array(peer.argv.dropFirst())
        if let run = TsmArgv.run(args) {
            let target = displayTarget(run.target, env: peer.env, cwd: reader.cwd(of: peerPID),
                                       isExecutable: isExecutable)
            return PeerInfo(command: CommandText.join(target), secrets: run.secrets.filter(isValidName))
        }
        let secrets = TsmArgv.getSecret(args).map { [$0] }?.filter(isValidName) ?? []
        let command = ancestorCommand(above: peerPID, reader: reader) ?? CommandText.join(["tsm"] + args)
        return PeerInfo(command: command, secrets: secrets)
    }

    /// The command that started `tsm` at `pid`, from its nearest ancestor
    /// that is not a node/bun launcher:
    /// - a shell started with -c: its command, harness wrapper removed;
    /// - an interactive shell: nil (the caller shows tsm's own argv);
    /// - anything else (python3 -c, bash x.sh, …): that process's argv.
    private static func ancestorCommand(above pid: pid_t, reader: ProcessReader) -> String? {
        var current = pid
        var last: (argv: [String], exe: String?)?
        for _ in 0..<maxAncestors {
            guard let parent = reader.parent(of: current), parent > 1,
                  let args = reader.args(of: parent), !args.argv.isEmpty else { break }
            let exe = reader.executablePath(of: parent)
            let name = exe.map(basename) ?? ""
            if launchers.contains(name) {
                last = (args.argv, exe)
                current = parent
                continue
            }
            if ShellCommand.shells.contains(name) {
                if let command = ShellCommand.command(fromShellArgv: args.argv) {
                    return CommandText.clean(command)
                }
                if ShellCommand.isInteractive(args.argv) { return nil }
            }
            return display(args.argv, exe: exe)
        }
        return last.map { display($0.argv, exe: $0.exe) }
    }

    /// argv as one line, with the kernel's executable path in place of argv[0].
    private static func display(_ argv: [String], exe: String?) -> String {
        CommandText.join([exe ?? argv[0]] + argv.dropFirst())
    }

    /// Secret names the vault would accept. Anything else is text the peer
    /// chose, and must not reach the dialog's first line.
    private static func isValidName(_ name: String) -> Bool {
        (try? NameValidation.validate(name)) != nil
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

    /// A regular file with an execute bit, as Go's exec.LookPath requires.
    /// FileManager.isExecutableFile also accepts directories.
    static func isExecutableFile(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
