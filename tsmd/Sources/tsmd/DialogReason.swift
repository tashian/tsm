import Foundation

/// Builds the Touch ID dialog reason. macOS shows it as
/// "tsmd is trying to <reason>." and adds the period itself.
enum DialogReason {
    enum Action { case unlock, access }

    static func make(_ action: Action, secrets: [String], command: String?) -> String {
        let names = secrets.map { "'\($0)'" }.joined(separator: " and ")
        var head: String
        switch action {
        case .unlock:
            head = "unlock the vault"
            if !names.isEmpty { head += " and access " + names }
        case .access:
            head = "access " + names
        }
        guard let command, !command.isEmpty else { return head }
        return head + ":\n\n" + CommandText.truncate(command, limit: CommandText.dialogLimit)
    }
}
