import Foundation

final class Daemon: @unchecked Sendable {
    let socketPath: String
    let vault: Vault
    let idleTracker: IdleTracker
    let server: SocketServer
    let idleQuitSeconds: TimeInterval
    let tickInterval: TimeInterval
    private var ttlTimer: DispatchSourceTimer?
    private var systemEvents: SystemEvents?
    private var shutdownObserver: NSObjectProtocol?
    private let shutdownSemaphore = DispatchSemaphore(value: 0)

    init(
        socketPath: String? = nil,
        idleQuitSeconds: TimeInterval = 1800,
        tickInterval: TimeInterval = 15,
        vault: Vault? = nil,
        idleTracker: IdleTracker? = nil
    ) {
        let path = socketPath ?? Paths.socketPath

        let resolvedVault = vault ?? {
            let crypto = AESGCMCrypto()
            let keychain = MacKeychain()
            let auth = TouchIDAuth()
            let store = FileVaultStore()
            let accessLog = FileAccessLog()
            return Vault(
                crypto: crypto,
                keychain: keychain,
                auth: auth,
                store: store,
                accessLog: accessLog
            )
        }()
        let resolvedTracker = idleTracker ?? IdleTracker()

        self.vault = resolvedVault
        self.idleTracker = resolvedTracker
        self.idleQuitSeconds = idleQuitSeconds
        self.tickInterval = tickInterval

        let handler = JSONRPCHandler(vault: resolvedVault, idleTracker: resolvedTracker)
        self.server = SocketServer(socketPath: path, handler: handler)
        self.socketPath = path
    }

    /// True when the vault has no decrypted state AND no client has talked
    /// to the daemon for at least `idleQuitSeconds`. The periodic timer in
    /// `run()` calls this and posts `.tsmdShutdown` when it returns true.
    func shouldIdleQuit(now: Date = Date()) async -> Bool {
        let locked = await vault.isLocked
        let idle = await idleTracker.isIdle(idleSeconds: idleQuitSeconds, now: now)
        return locked && idle
    }

    func run() throws {
        try server.start()

        // Print socket path for parent process to capture
        print(socketPath)
        fflush(stdout)

        // Periodic tick: expire stale sessions, then decide whether the daemon
        // can quit because nobody is using it. `tickInterval` defaults to 15 s
        // — short enough that a 60 s TTL expires close to its target while
        // keeping idle CPU near zero, and tunable down for tests.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task {
                await self.vault.checkTTL()
                if await self.shouldIdleQuit() {
                    NotificationCenter.default.post(name: .tsmdShutdown, object: nil)
                }
            }
        }
        timer.resume()
        ttlTimer = timer

        let events = SystemEvents { [weak self] in
            guard let self = self else { return }
            Task { await self.vault.lockAll() }
        }
        events.start()
        systemEvents = events

        // Listen for shutdown notification (from daemon.shutdown RPC or the
        // idle-quit tick).
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
