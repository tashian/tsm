# Vault hardening: shorter TTL, per-session unlock, lifecycle auto-lock

**Status:** Design approved 2026-04-26. Implementation pending.

## Motivation

Three changes that together harden tsm against realistic same-user threats while preserving the core promise: *inside a single shell or agent session, the vault remains open for the TTL with no extra Touch ID*.

1. **Shorten the default TTL** (12 h → 10 min). The current 12 h window is generous; reducing it cuts the steady-state exposure if any of the other defenses fail.
2. **Bind unlock state to the calling POSIX session.** Today the daemon has one global "unlocked" state; any same-user process can read secrets during the TTL window. After this change, each session unlocks independently — a malicious LaunchAgent, browser-helper, or separate-terminal process must Touch ID on its own (which is visible to the user) before it can read.
3. **Auto-lock on screen-lock and sleep.** Catches the "user walked away" case where TTL hasn't yet elapsed.

A fourth idea — verifying the connecting binary's code signature so non-`tsm` processes can't speak the JSON-RPC protocol — is **out of scope** for v1. It requires Developer-ID-signed binaries (ad-hoc cdhash changes on every rebuild). Filed as future work below.

## Threat model

**In scope:**
- *Cross-session same-user malware.* Background process running as the user (LaunchAgent, browser exploit child, separate terminal) attempts to read secrets while the user's main session has the vault unlocked.
- *Absent user.* User locks the screen or the machine sleeps while the TTL window is still open.

**Residual risk (knowingly accepted):**
- *Same-session attacker.* A process inside the same POSIX session as the user's unlocked agent (e.g. a malicious tool running inside the same shell) is still trusted within the TTL. Mitigations available to the user: shorter TTL, manual `tsm lock`, screen lock. Closing this would require per-PID unlock binding, which breaks the "agent invokes tsm many times" promise.
- *Hostile signed-impersonator.* A non-`tsm` binary that knows the JSON-RPC protocol can connect to the socket and call methods directly. Mitigated only by per-session unlock (it still has to Touch ID to read anything if it's in a different session). Code-signing peer check would close the same-session variant; deferred.

## Change 1 — TTL default 10 minutes, units in seconds

### Vault config schema

`tsmd/Sources/tsmd/Models.swift` `Config`:

```swift
struct Config: Codable {
    var ttlSeconds: Int = 600
    enum CodingKeys: String, CodingKey {
        case ttlSeconds = "ttl_seconds"
    }
}
```

`ttlHours` field and its `CodingKey` are deleted entirely. Vaults written before this change have `ttl_seconds` absent → `Codable` default of 600 applies. Old `ttl_hours` field in the JSON is silently ignored. The project is pre-release; this break is acceptable and is **not** documented as a deprecation.

### CLI mirror

`cmd/config.go`:

```go
type Config struct {
    TTLSeconds int `json:"ttl_seconds"`
}

var defaultConfig = Config{
    TTLSeconds: 600,
}
```

`tsm config get ttl_seconds` and `tsm config set ttl_seconds N` are the only TTL commands. `ttl_hours` is removed from the CLI surface entirely; the case is dropped from the get/set switches.

### TTL math

`Vault.checkTTL()` and `Vault.status()` switch from `Double(ttlHours) * 3600` to `Double(ttlSeconds)`. Daemon TTL polling interval (currently 60 s in `Daemon.swift`) is reduced to **15 s** so a 600 s TTL still expires within ~2.5% of its target.

## Change 2 — Per-session unlock state

### Concept

The daemon tracks unlock state per **POSIX session ID** (`sid_t`). The master key is loaded into daemon memory on the first session unlock and stays resident as long as ≥1 session is currently unlocked. When the last session expires or is locked, the key is zeroed.

A "session" here is the value returned by `getsid(peer_pid)` on the connecting socket peer. Sessions are inherited across `fork()`/`exec()`, so a shell and all of its descendants (including agents and the agents' subprocesses) share the same `sid`. Distinct sessions arise from `setsid()` — login shells, tmux panes, LaunchAgents, daemons.

### Data structure

`Vault` adds:

```swift
private struct SessionState {
    let sid: sid_t
    let unlockTime: Date
}

private var unlockedSessions: [sid_t: SessionState] = [:]
private var masterKey: Data?
private var data: VaultData?
```

`unlockTime` becomes the per-session `unlockTime`. `data` and `masterKey` remain singular: the vault contents and the master key are the same regardless of which session is asking — only the *authorization* is per-session.

### Resolving the peer session

`SocketServer.handleConnection(_:)` resolves the peer session ID once per accepted connection, before any RPC is processed:

```swift
private func peerSessionID(fd: Int32) -> sid_t? {
    var pid: pid_t = 0
    var len = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else {
        return nil
    }
    let sid = getsid(pid)
    return sid >= 0 ? sid : nil
}
```

The resolved `sid` is attached to the connection's request context and threaded into each `JSONRPCHandler` call. If `peerSessionID` returns nil (peer died, syscall error), the connection is closed immediately with a JSON-RPC internal-error response — unauthenticated traffic is never processed.

### Vault API changes

Public methods that today gate on `data != nil` (`get`, `list`, `add`, `edit`, `remove`) take a `sessionID: sid_t` parameter and gate on:

```swift
private func authorized(_ sid: sid_t) throws {
    guard data != nil else { throw VaultError.locked }
    guard let state = unlockedSessions[sid] else { throw VaultError.locked }
    let elapsed = Date().timeIntervalSince(state.unlockTime)
    let ttlSeconds = data?.config.ttlSeconds ?? 600
    guard elapsed < Double(ttlSeconds) else {
        unlockedSessions.removeValue(forKey: sid)
        if unlockedSessions.isEmpty { lockAll() }
        throw VaultError.locked
    }
}
```

`unlock(passphrase:sessionID:)`:
- If `data == nil`, performs the normal Touch-ID-or-passphrase flow, loads the master key, decrypts vault data, then registers `unlockedSessions[sid] = .init(sid: sid, unlockTime: now)`.
- If `data != nil` (some other session has the vault unlocked) but `sid` is not in the map: still requires Touch ID for the new session, then registers `sid` (no need to re-derive the key).
- If `sid` is already in the map: refreshes its `unlockTime` (an explicit `tsm unlock` re-arms the TTL for that session). This matches today's behavior of returning a fresh TTL on a successful unlock call.

`lock(sessionID:)`:
- Removes the entry for `sid`.
- If the map becomes empty, calls `lockAll()`: zeros the master key, clears `data`, clears `unlockTime`-style state.
- An explicit no-arg `lockAll()` is also exposed to the daemon for screen-lock/sleep handlers.

`status(sessionID:)`:
- If `data == nil` or `sid` not in the map: locked, ttl nil.
- Otherwise: unlocked, ttl = `ttlSeconds - elapsed`.

`checkTTL()` (timer-driven): walks `unlockedSessions`, removes expired entries; if all entries are gone, calls `lockAll()`.

### Audit log

The session ID is included in `clientId` for `accessLog.log(...)` calls. Format: `sid=<sid>;…` so existing log fields are preserved. Per-session unlock and lock events are also logged (`vault.unlock` / `vault.lock` with `clientId=sid=…`).

### Behavior for the canonical bash → Claude Code → tsm scenario

1. Terminal opens bash → bash gets session `S1` (terminal called `setsid`).
2. `claude` runs from bash → inherits `S1`.
3. Claude's bash tool runs `tsm get xyz` → inherits `S1` → daemon resolves peer sid = `S1`.
4. Daemon: `S1` not in map → Touch ID → register `S1` → return value.
5. Subsequent `tsm get` from Claude's bash tool → new PID, same `S1` → already authorized, within TTL → no Touch ID, returns value.
6. Concurrent `tsm get` from a different terminal pane (`S2`) → not in map → Touch ID → register `S2`. Both sessions now active independently with their own TTL clocks.

A new tmux pane is its own session and will Touch-ID once. This is acceptable: each pane is a logically separate workspace.

## Change 3 — Auto-lock on screen lock and sleep

`Daemon.run()` registers two listeners after `server.start()`:

### Screen lock

```swift
let center = DistributedNotificationCenter.default()
screenLockObserver = center.addObserver(
    forName: NSNotification.Name("com.apple.screenIsLocked"),
    object: nil, queue: nil
) { [weak self] _ in
    Task { await self?.vault.lockAll() }
}
```

Foundation-only, no AppKit dependency.

### System sleep

```swift
var rootPort: io_object_t = 0
let port = IORegisterForSystemPower(
    Unmanaged.passUnretained(self).toOpaque(),
    &notifyPortRef,
    { (refcon, service, messageType, messageArgument) in
        guard messageType == UInt32(kIOMessageSystemWillSleep) else { return }
        let daemon = Unmanaged<Daemon>.fromOpaque(refcon!).takeUnretainedValue()
        Task { await daemon.vault.lockAll() }
        IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
    },
    &rootPort
)
CFRunLoopAddSource(
    CFRunLoopGetCurrent(),
    IONotificationPortGetRunLoopSource(notifyPortRef).takeUnretainedValue(),
    .defaultMode
)
```

The handler must call `IOAllowPowerChange` so the system isn't blocked. `vault.lockAll()` is fast (zeroing a 32-byte key + clearing a small map) so synchronous completion before acking is fine; using `Task { … }` here is just to bridge into the actor.

### Cleanup

`Daemon.shutdown()` deregisters both observers, deallocates the IO notification port, and removes the run-loop source.

### Wake behavior

Nothing is required on wake. The next `tsm` call from any session is treated as locked, runs Touch ID, re-unlocks, and registers the calling session normally.

## Migration

- Vault file format envelope `version` is **not** bumped. The only change is the `Config` field rename (`ttl_hours` → `ttl_seconds`); the JSON decoder silently drops the unknown old field and uses the new default for the missing new field.
- No daemon-state migration is needed (state lives in memory; restart re-locks).
- No CLI migration is needed beyond the source change.
- Pre-release; users with custom `ttl_hours` settings will pick up the new 10-min default and can re-set with `tsm config set ttl_seconds N`.

## Testing

### tsmd unit (XCTest)

- **Per-session map.** Three sessions unlock independently; each has its own TTL; expiring one does not affect the others.
- **Last-session lock.** Last unlocked session expires (or `lock(sid:)` is called) → master key is zeroed, `data == nil`, `unlockedSessions` is empty.
- **Authorization gate.** Calling `get(sid:)` for a sid not in the map returns `VaultError.locked` even when another sid *is* unlocked.
- **TTL math.** Boundary conditions at `ttlSeconds - 1`, `ttlSeconds`, `ttlSeconds + 1`.
- **Stale-vault config.** A `Config` decoded from JSON that contains only the old `ttl_hours` key resolves to `ttlSeconds == 600` (the default).

### tsmd integration

- **Two real connections, distinct sessions.** Test harness forks twice with `setsid()` between forks, each child opens its own connection, calls `unlock`, and verifies independent TTL state. Confirms `LOCAL_PEERPID` + `getsid()` resolution works end-to-end.
- **Screen-lock listener.** Test harness posts `com.apple.screenIsLocked` via `DistributedNotificationCenter`; assert all sessions are locked and `data == nil` after observer fires.
- **Sleep listener.** Exercised at the API-binding level only (registration succeeds, callback signature compiles). Faking `kIOMessageSystemWillSleep` reliably in CI is not worth the effort.

### CLI smoke

- `tsm config set ttl_seconds 1200` followed by `tsm config get ttl_seconds` round-trips.
- `tsm config get ttl_hours` errors (key removed).

## Out of scope (future work)

- **Code-signing peer check.** Verify that the connecting peer's binary matches a `SecRequirement` (e.g. `identifier "com.tashian.tsm" and anchor apple generic`). Requires:
  - `getsockopt(LOCAL_PEERAUDITTOKEN)` to get a race-free audit token,
  - `SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token], [], &code)`,
  - `SecCodeCheckValidity(code, [], requirement)`.
  Postponed until tsm has a Developer-ID signing pipeline; ad-hoc cdhash pinning is too brittle.
- **Per-PID unlock binding.** A more aggressive mode where each connecting PID needs its own Touch ID. Useful for paranoid users; could ship later as `tsm config set unlock_scope per_process`. Default would remain per-session.
