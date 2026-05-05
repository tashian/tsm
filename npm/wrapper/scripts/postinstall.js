"use strict";

// postinstall.js — stop any running tsmd so the next `tsm` command picks up
// the freshly installed binary.
//
// Why SIGTERM instead of an RPC `tsm daemon stop`: the postinstall runs after
// the new binaries land, but the running daemon is still the *old* one (and
// may live in a different prefix entirely, e.g. Homebrew). SIGTERM is simple
// and version-independent. The daemon's own SIGTERM handler closes the socket
// and zeros the master key on process exit. The next `tsm` command will
// EnsureRunning and respawn the new binary on demand.
//
// This script must never fail the install. All errors are swallowed or
// downgraded to a warning on stderr.

const path = require("node:path");
const { execFileSync } = require("node:child_process");

// Resolve the absolute path of the tsmd binary that just landed via the
// optional platform package. Returns null if the platform package isn't
// installed (e.g. user passed --no-optional, or we're on an unsupported arch
// — main() should not even call this on non-darwin).
function resolveTsmdPath({ requireResolve = require.resolve } = {}) {
    try {
        const pkgJson = requireResolve("@tashian/tsm-darwin-arm64/package.json");
        return path.join(path.dirname(pkgJson), "bin", "tsmd");
    } catch {
        return null;
    }
}

// Run pgrep with a single arg list and return the parsed PIDs. pgrep exits 1
// when there are no matches; we treat that (and ENOENT) as "no pids".
function pgrepPids(args, exec) {
    let out;
    try {
        out = exec("pgrep", args, { stdio: ["ignore", "pipe", "ignore"] });
    } catch (err) {
        // status 1 = no match, ENOENT = pgrep missing. Either way: no pids.
        return [];
    }
    return String(out)
        .split("\n")
        .map((s) => s.trim())
        .filter(Boolean)
        .map((s) => parseInt(s, 10))
        .filter((n) => Number.isFinite(n) && n > 0);
}

// Find any running tsmd processes worth stopping. Two passes:
//   1. Path-strict: pgrep -f <absolute path of new tsmd>. Catches the common
//      case where the user is upgrading an npm-installed tsm.
//   2. Permissive owned-pid: pgrep -u $USER -f 'tsmd( |$)'. Catches the
//      cross-prefix case (Homebrew tsmd running, user upgrades to npm) and
//      the case where the daemon was launched from ~/.local/bin etc. Scoped
//      to the current user so we never touch a system-wide daemon owned by
//      someone else.
function findRunningTsmdPids(tsmdPath, { execFileSync: exec = execFileSync } = {}) {
    const pids = new Set();
    for (const p of pgrepPids(["-f", tsmdPath], exec)) {
        pids.add(p);
    }
    const user = process.env.USER || "nobody";
    for (const p of pgrepPids(["-u", user, "-f", "^.*tsmd( |$)"], exec)) {
        pids.add(p);
    }
    return Array.from(pids);
}

// SIGTERM each pid. Tolerates EPERM (daemon owned by another user — possible
// after a stray `sudo npm install`) with a warning. Swallows ESRCH (process
// already gone, race between pgrep and kill).
function stopPids(pids, { kill = process.kill.bind(process), warn = console.warn } = {}) {
    for (const pid of pids) {
        try {
            kill(pid, "SIGTERM");
        } catch (err) {
            if (err && err.code === "ESRCH") {
                continue;
            }
            if (err && err.code === "EPERM") {
                warn(
                    `tsm: could not stop pid ${pid} (EPERM). ` +
                        `Run 'sudo pkill tsmd' once, then 'tsm status' to respawn.`,
                );
                continue;
            }
            warn(`tsm: could not stop pid ${pid}: ${err && err.message ? err.message : err}`);
        }
    }
}

// Glue. Always returns 0 — postinstall must not fail npm install.
function main(deps = {}) {
    const platform = deps.platform || process.platform;
    if (platform !== "darwin") {
        return 0;
    }
    const resolve = deps.resolveTsmdPath || resolveTsmdPath;
    const find = deps.findRunningTsmdPids || findRunningTsmdPids;
    const stop = deps.stopPids || stopPids;

    let tsmdPath;
    try {
        tsmdPath = resolve();
    } catch {
        return 0;
    }
    if (!tsmdPath) {
        return 0;
    }

    let pids;
    try {
        pids = find(tsmdPath);
    } catch {
        return 0;
    }

    try {
        stop(pids);
    } catch {
        // last-ditch swallow
    }
    return 0;
}

module.exports = {
    resolveTsmdPath,
    findRunningTsmdPids,
    stopPids,
    main,
};

if (require.main === module) {
    process.exit(main());
}
