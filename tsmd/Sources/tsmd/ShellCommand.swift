import Foundation

/// Finds the command a shell was started to run with `-c`, and removes the
/// wrapper that agent harnesses put around it.
enum ShellCommand {
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh"]

    /// Long options that take the next argument as their value.
    private static let longValueOptions: Set<String> = ["--rcfile", "--init-file", "--emulate", "--init-command"]
    /// Letters in a short-option cluster that take the next argument: -o/-O
    /// (sh, bash, zsh, ksh) and -C (fish --init-command).
    private static let shortValueLetters: Set<Character> = ["o", "O", "C"]

    /// Statements Claude Code's Bash tool puts before `eval '<command>'`.
    private static let wrapperPrefixPatterns: [NSRegularExpression] = [
        #"^source \S*/\.claude/shell-snapshots/snapshot-[A-Za-z0-9_-]+\.sh 2>/dev/null \|\| true$"#,
        #"^shopt -u extglob 2>/dev/null \|\| true$"#,
        #"^\{ \\builtin unalias -- '[A-Za-z0-9_]+'; \\builtin unset -f -- '[A-Za-z0-9_]+'; \} >/dev/null 2>&1 \|\| true$"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    /// What Claude Code's Bash tool puts after the eval word.
    private static let wrapperTrailer = try! NSRegularExpression(pattern: #"^ < /dev/null && pwd -P >\| \S+$"#)

    static func command(fromShellArgv argv: [String]) -> String? {
        script(fromShellArgv: argv).map(unwrapEval)
    }

    /// The script argument of `<shell> [options] -c [options] <script>`, or
    /// nil if argv is not a shell started with -c.
    static func script(fromShellArgv argv: [String]) -> String? {
        guard let first = argv.first, shells.contains(shellName(first)) else { return nil }
        var sawC = false
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--command", i + 1 < argv.count { return argv[i + 1] }
            if arg.hasPrefix("--command=") { return String(arg.dropFirst("--command=".count)) }
            if arg == "--" || arg == "-" {
                i += 1
                break
            }
            if arg.hasPrefix("--") {
                i += longValueOptions.contains(arg) ? 2 : 1
                continue
            }
            if (arg.hasPrefix("-") || arg.hasPrefix("+")) && arg.count > 1 {
                let letters = arg.dropFirst()
                if letters.contains("c") { sawC = true }
                i += 1 + letters.filter { shortValueLetters.contains($0) }.count
                continue
            }
            return sawC ? arg : nil
        }
        return sawC && i < argv.count ? argv[i] : nil
    }

    /// A shell with no script and no -c: a terminal tab, not a command.
    static func isInteractive(_ argv: [String]) -> Bool {
        guard let first = argv.first, shells.contains(shellName(first)) else { return false }
        return script(fromShellArgv: argv) == nil
            && argv.dropFirst().allSatisfy { $0.hasPrefix("-") || $0.hasPrefix("+") }
    }

    /// Returns the command inside Claude Code's Bash tool wrapper:
    /// `source <snapshot> … && eval '<command>' < /dev/null && pwd -P >| <file>`.
    /// The script must match that wrapper exactly: only known statements
    /// before `eval`, one shell word after it, and the known trailer at the
    /// end. Otherwise the script is returned unchanged, so nothing outside
    /// the eval word can hide.
    static func unwrapEval(_ script: String) -> String {
        guard let found = script.range(of: "eval '") else { return script }
        guard prefixIsWrapper(String(script[..<found.lowerBound])) else { return script }
        let chars = Array(script[script.index(before: found.upperBound)...])  // from the opening quote
        guard let (word, end) = shellWord(chars), matches(wrapperTrailer, String(chars[end...])) else {
            return script
        }
        return word
    }

    private static func prefixIsWrapper(_ prefix: String) -> Bool {
        if prefix.isEmpty { return true }
        guard prefix.hasSuffix(" && ") else { return false }
        return prefix.dropLast(" && ".count)
            .components(separatedBy: " && ")
            .allSatisfy { statement in wrapperPrefixPatterns.contains { matches($0, statement) } }
    }

    /// Parses one POSIX shell word from the start of `chars`. Returns the
    /// word with quoting removed and the index where it ends, or nil if a
    /// quote does not close.
    private static func shellWord(_ chars: [Character]) -> (String, Int)? {
        var out = ""
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "'":
                guard let close = chars[(i + 1)...].firstIndex(of: "'") else { return nil }
                out += String(chars[(i + 1)..<close])
                i = close + 1
            case "\"":
                var j = i + 1
                while j < chars.count, chars[j] != "\"" {
                    if chars[j] == "\\", j + 1 < chars.count, "\"\\$`".contains(chars[j + 1]) { j += 1 }
                    out.append(chars[j])
                    j += 1
                }
                guard j < chars.count else { return nil }
                i = j + 1
            case "\\":
                guard i + 1 < chars.count else { return nil }
                out.append(chars[i + 1])
                i += 2
            case " ", "\t", "\n", ";", "&", "|", "<", ">":
                return (out, i)
            default:
                out.append(chars[i])
                i += 1
            }
        }
        return (out, i)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// "/bin/bash" → "bash"; login shells start with "-": "-zsh" → "zsh".
    private static func shellName(_ argv0: String) -> String {
        var name = (argv0 as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }
}
