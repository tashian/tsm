import Foundation

final class Daemon: @unchecked Sendable {
    let socketPath: String
    let vault: Vault
    let server: SocketServer
    private var ttlTimer: DispatchSourceTimer?
    private var systemEvents: SystemEvents?
    private var shutdownObserver: NSObjectProtocol?
    private let shutdownSemaphore = DispatchSemaphore(value: 0)

    init(socketPath: String? = nil) {
        let path = socketPath ?? Paths.socketPath

        let crypto = AESGCMCrypto()
        let keychain = MacKeychain()
        let auth = TouchIDAuth()
        let store = FileVaultStore()
        let accessLog = FileAccessLog()

        self.vault = Vault(
            crypto: crypto,
            keychain: keychain,
            auth: auth,
            store: store,
            accessLog: accessLog
        )
        let handler = JSONRPCHandler(vault: vault)
        self.server = SocketServer(socketPath: path, handler: handler)
        self.socketPath = path
    }

    func run() throws {
        try server.start()

        // Print socket path for parent process to capture
        print(socketPath)
        fflush(stdout)

        // TTL check every 60 seconds
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { await self.vault.checkTTL() }
        }
        timer.resume()
        ttlTimer = timer

        let events = SystemEvents { [weak self] in
            guard let self = self else { return }
            Task { await self.vault.lockAll() }
        }
        events.start()
        systemEvents = events

        // Listen for shutdown notification (from daemon.shutdown RPC)
        shutdownObserver = NotificationCenter.default.addObserver(
            forName: .tsmdShutdown, object: nil, queue: nil
        ) { [weak self] _ in
            self?.shutdown()
        }

        // Handle SIGTERM and SIGINT
        let signalCallback: @convention(c) (Int32) -> Void = { _ in
            NotificationCenter.default.post(name: .tsmdShutdown, object: nil)
        }
        signal(SIGTERM, signalCallback)
        signal(SIGINT, signalCallback)

        // Block until shutdown
        shutdownSemaphore.wait()
    }

    func shutdown() {
        systemEvents?.stop()
        systemEvents = nil
        ttlTimer?.cancel()
        server.stop()
        if let observer = shutdownObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        shutdownSemaphore.signal()
    }
}
