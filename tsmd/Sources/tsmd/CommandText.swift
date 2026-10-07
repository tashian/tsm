import Foundation

/// Turns process arguments into one line of text that a person can read in a
/// Touch ID dialog, and that cannot hide or reorder what will run.
enum CommandText {
    static let dialogLimit = 300

    private static let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")

    /// Replaces newline, carriage return, and tab with a space. Removes all
    /// other control (Cc) and format (Cf) characters; Cf includes the
    /// bidirectional overrides.
    static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\n" || u == "\r" || u == "\t" {
                out.append(" ")
                continue
            }
            switch u.properties.generalCategory {
            case .control, .format: continue
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Single-quotes an argument the way a POSIX shell would need it, unless
    /// it contains only characters that need no quoting.
    static func quote(_ arg: String) -> String {
        if arg.isEmpty { return "''" }
        if arg.unicodeScalars.allSatisfy({ safe.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func join(_ argv: [String]) -> String {
        argv.map { quote(clean($0)) }.joined(separator: " ")
    }

    /// Keeps the start (the program) and the end of a long command, and puts
    /// "…" in place of the middle.
    static func truncate(_ s: String, limit: Int) -> String {
        guard s.count > limit, limit > 1 else { return s }
        let head = limit / 2
        let tail = limit - head - 1
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }
}
