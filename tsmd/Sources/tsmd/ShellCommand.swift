import Foundation

/// Finds the command a shell was started to run with `-c`, and removes the
/// wrapper that agent harnesses put around it.
enum ShellCommand {
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh"]

    static func command(fromShellArgv argv: [String]) -> String? {
        script(fromShellArgv: argv).map(unwrapEval)
    }

    /// The script argument of `<shell> [options] -c [options] <script>`, or
    /// nil if argv is not a shell started with -c.
    static func script(fromShellArgv argv: [String]) -> String? {
        guard let first = argv.first else { return nil }
        var name = (first as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }   // login shells: "-zsh"
        guard shells.contains(name) else { return nil }
        var sawC = false
        for arg in argv.dropFirst() {
            if arg.hasPrefix("-") {
                if !arg.hasPrefix("--") && arg.dropFirst().contains("c") { sawC = true }
                continue
            }
            return sawC ? arg : nil
        }
        return nil
    }

    /// Returns the first shell word after `eval ` with its quoting removed.
    /// Claude Code's Bash tool runs the user's command as `eval '<command>'`
    /// inside a longer script. Returns the script unchanged when it has no
    /// `eval '` or the word does not end.
    static func unwrapEval(_ script: String) -> String {
        guard let found = script.range(of: "eval '") else { return script }
        let chars = Array(script[script.index(before: found.upperBound)...])  // from the opening quote
        var out = ""
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "'":
                guard let close = chars[(i + 1)...].firstIndex(of: "'") else { return script }
                out += String(chars[(i + 1)..<close])
                i = close + 1
            case "\"":
                var j = i + 1
                while j < chars.count, chars[j] != "\"" {
                    if chars[j] == "\\", j + 1 < chars.count, "\"\\$`".contains(chars[j + 1]) { j += 1 }
                    out.append(chars[j])
                    j += 1
                }
                guard j < chars.count else { return script }
                i = j + 1
            case "\\":
                guard i + 1 < chars.count else { return script }
                out.append(chars[i + 1])
                i += 2
            case " ", "\t", "\n", ";", "&", "|", "<", ">":
                return out
            default:
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}
