# Vault hardening: shorter TTL, per-session unlock, lifecycle auto-lock

**Status:** Design approved 2026-04-26. Implementation pending.

## Motivation

Three changes that together harden tsm against realistic same-user threats while preserving the core promise: *inside a single shell or agent session, the vault remains open for the TTL with no extra Touch ID*.

1. **Shorten the default TTL** (12 h → 30 min) and consolidate it as a single source of truth in the daemon vault config; expose a duration-friendly CLI surface. The current 12 h window is generous; reducing it cuts the steady-state exposure if any of the other defenses fail. While we're touching this code, fix a pre-existing bug: today the CLI has its own `ttl_hours` config field that no code reads — it never reaches the daemon.
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

## Change 1 — TTL default 30 minutes, single source of truth, duration-friendly CLI

### One source of truth: the daemon vault config

Today `ttl_hours` exists in two places:

- `tsmd/Sources/tsmd/Models.swift` `Config.ttlHours = 12` — the value the daemon actually uses, embedded in the encrypted vault.
- `cmd/config.go` `tsmConfig.TTLHours = 12` — a value written to a local CLI config file by `tsm config set ttl_hours`. **Nothing in the CLI ever reads it back to drive behavior.** It never reaches the daemon. This is a pre-existing bug; the CLAUDE.md note about "changes propagate after the next lock/unlock cycle" describes the intended wiring, not the current behavior.

The fix: the daemon vault's `config` is the single source of truth for TTL. The CLI exposes TTL via JSON-RPC, with no local default and no local copy. The CLI's local config file keeps only client-side concerns (update-check settings).

### Vault config schema

`tsmd/Sources/tsmd/Models.swift` `Config`:

```swift
struct Config: Codable {
    var ttlSeconds: Int = 1800
    enum CodingKeys: String, CodingKey {
        case ttlSeconds = "ttl_seconds"
    }
}
```

`ttlHours` field and its `CodingKey` are deleted entirely. Vaults written before this change have `ttl_seconds` absent → `Codable` default of 1800 applies. Old `ttl_hours` field in the JSON is silently ignored. The project is pre-release; this break is acceptable and is **not** documented as a deprecation.

### New JSON-RPC methods

`vault.config.get`
- Params: none.
- Result: `{"ttl_seconds": <int>}`.
- Authorization: requires the calling session to be unlocked. (Reading the TTL value is low-sensitivity, but gating it keeps the surface uniform; revisit if a use case appears.)

`vault.config.set`
- Params: `{"ttl_seconds": <positive int>}`. Other config keys can be added later in the same shape.
- Result: the updated config (`{"ttl_seconds": <int>}`).
- Authorization: requires the calling session to be unlocked. The new value is persisted by re-encrypting and writing the vault envelope (the same `persist()` path used by other writes).
- Validation: `ttl_seconds >= 1`. No upper bound enforced by the daemon; the CLI may set its own UX-friendly cap.

### CLI surface

`cmd/config.go` becomes a thin wrapper over RPC for the TTL key, plus a local file for client-side keys:

- `tsm config set ttl <duration>` — parses `<duration>` with Go's `time.ParseDuration`, converts to seconds, calls `vault.config.set`. Examples: `30m`, `1h`, `90s`, `1h30m`. Rejects values < 1 s or non-integer-seconds (e.g. `500ms`) with a clear error.
- `tsm config get ttl` — calls `vault.config.get`, prints the value as a Go duration via `time.Duration(seconds * time.Second).String()`. Output for 1800: `30m0s`.
- `tsm config set update_check <bool>` and friends — read/write the local CLI config file as today.
- `tsm config` (no args) — prints a combined view: a `vault` section populated via `vault.config.get` (errors gracefully if locked or daemon unavailable) and a `client` section from the local file.

The CLI's local `tsmConfig` struct loses its `TTLHours` field. `defaultConfig` loses its `TTLHours` initializer.

The CLI key `ttl_hours` is removed entirely. The new key is `ttl`. (Renaming `ttl_seconds` → `ttl` at the CLI surface is fine because the CLI accepts/displays durations, not raw seconds; the wire and storage names remain `ttl_seconds`.)

### TTL math

`Vault.checkTTL()` and `Vault.status()` switch from `Double(ttlHours) * 3600` to `Double(ttlSeconds)`. Daemon TTL polling interval (currently 60 s in `Daemon.swift`) is reduced to **15 s** so the auto-lock check still fires close to the configured TTL even when users set short values like 60 s.

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
    let ttlSeconds = data?.config.ttlSeconds ?? 1800
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
- The CLI's local config file is rewritten without the `ttl_hours` key the next time `saveConfig` runs; users who previously set `ttl_hours` there were getting no benefit anyway (it never reached the daemon).
- No daemon-state migration is needed (state lives in memory; restart re-locks).
- Pre-release; users with custom `ttl_hours` settings will pick up the new 30-min default and can re-set with `tsm config set ttl 30m` (or whatever duration).

## Testing

### tsmd unit (XCTest)

- **Per-session map.** Three sessions unlock independently; each has its own TTL; expiring one does not affect the others.
- **Last-session lock.** Last unlocked session expires (or `lock(sid:)` is called) → master key is zeroed, `data == nil`, `unlockedSessions` is empty.
- **Authorization gate.** Calling `get(sid:)` for a sid not in the map returns `VaultError.locked` even when another sid *is* unlocked.
- **TTL math.** Boundary conditions at `ttlSeconds - 1`, `ttlSeconds`, `ttlSeconds + 1`.
- **Stale-vault config.** A `Config` decoded from JSON that contains only the old `ttl_hours` key resolves to `ttlSeconds == 1800` (the default).
- **`vault.config.set` round-trip.** Set `ttl_seconds` to a non-default value, restart the test vault, confirm the new value is persisted and used by `checkTTL`.
- **`vault.config.set` while locked.** Returns `VaultError.locked` for the calling session.

### tsmd integration

- **Two real connections, distinct sessions.** Test harness forks twice with `setsid()` between forks, each child opens its own connection, calls `unlock`, and verifies independent TTL state. Confirms `LOCAL_PEERPID` + `getsid()` resolution works end-to-end.
- **Screen-lock listener.** Test harness posts `com.apple.screenIsLocked` via `DistributedNotificationCenter`; assert all sessions are locked and `data == nil` after observer fires.
- **Sleep listener.** Exercised at the API-binding level only (registration succeeds, callback signature compiles). Faking `kIOMessageSystemWillSleep` reliably in CI is not worth the effort.

### CLI smoke

- `tsm config set ttl 20m` followed by `tsm config get ttl` prints `20m0s`.
- `tsm config set ttl 90s` accepts the value (`90s` → 90).
- `tsm config set ttl 500ms` errors (sub-second not allowed).
- `tsm config set ttl 0` errors (positive required).
- `tsm config set ttl_hours 4` errors (key removed).
- `tsm config get ttl` while the daemon is locked returns the same locked-vault error as other unlock-required commands.

## Out of scope (future work)

- **Code-signing peer check.** Verify that the connecting peer's binary matches a `SecRequirement` (e.g. `identifier "com.tashian.tsm" and anchor apple generic`). Requires:
  - `getsockopt(LOCAL_PEERAUDITTOKEN)` to get a race-free audit token,
  - `SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token], [], &code)`,
  - `SecCodeCheckValidity(code, [], requirement)`.
  Postponed until tsm has a Developer-ID signing pipeline; ad-hoc cdhash pinning is too brittle.
- **Per-PID unlock binding.** A more aggressive mode where each connecting PID needs its own Touch ID. Useful for paranoid users; could ship later as `tsm config set unlock_scope per_process`. Default would remain per-session.
