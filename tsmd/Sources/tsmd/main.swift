import Foundation

// Usage: tsmd [--socket <path>]
let args = CommandLine.arguments
var socketPath: String? = nil

var i = 1
while i < args.count {
    if args[i] == "--socket" && i + 1 < args.count {
        socketPath = args[i + 1]
        i += 2
    } else {
        fputs("Usage: tsmd [--socket <path>]\n", stderr)
        Foundation.exit(1)
    }
}

do {
    let daemon = Daemon(socketPath: socketPath)
    try daemon.run()
} catch {
    fputs("tsmd: \(error)\n", stderr)
    Foundation.exit(1)
}
