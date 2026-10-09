import Foundation

/// Reads secret names and the target command from a `tsm` argv (argv[0]
/// removed). Must match the flags in cmd/root.go, cmd/run.go, and cmd/get.go.
enum TsmArgv {
    /// `tsm get` flags that take a value.
    private static let getValueFlags: Set<String> = ["--to-file", "--format"]

    /// pflag's rule: a token is a flag when it starts with "-" and is longer
    /// than one character. A bare "-" is an argument.
    private static func isFlag(_ a: String) -> Bool { a.hasPrefix("-") && a.count > 1 }

    /// Splits off the subcommand. Global flags before it (`--json`) take no value.
    private static func subcommand(_ args: [String]) -> (name: String, rest: [String])? {
        guard let i = args.firstIndex(where: { !isFlag($0) }) else { return nil }
        return (args[i], Array(args[(i + 1)...]))
    }

    /// The target is what cobra passes to `tsm run` as args: every
    /// positional before "--" (flags may come between them), then
    /// everything after "--".
    static func run(_ args: [String]) -> (secrets: [String], target: [String])? {
        guard let sub = subcommand(args), sub.name == "run" else { return nil }
        let rest = sub.rest
        var values: [String] = []
        var target: [String] = []
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "--" {
                target += rest[(i + 1)...]
                break
            } else if a == "--env" {
                if i + 1 < rest.count { values.append(rest[i + 1]) }
                i += 2
            } else if a.hasPrefix("--env=") {
                values.append(String(a.dropFirst("--env=".count)))
                i += 1
            } else if isFlag(a) {
                i += 1
            } else {
                target.append(a)
                i += 1
            }
        }
        var secrets: [String] = []
        for v in values {
            guard let eq = v.firstIndex(of: "=") else { continue }
            let secret = String(v[v.index(after: eq)...])
            if !secret.isEmpty && !secrets.contains(secret) { secrets.append(secret) }
        }
        return (secrets, target)
    }

    static func getSecret(_ args: [String]) -> String? {
        guard let sub = subcommand(args), sub.name == "get" else { return nil }
        let rest = sub.rest
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if getValueFlags.contains(a) {
                i += 2
            } else if isFlag(a) {
                i += 1
            } else {
                return a
            }
        }
        return nil
    }
}
