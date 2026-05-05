"use strict";

const path = require("node:path");
const { spawnSync, execFileSync } = require("node:child_process");

const platforms = {
    "darwin-arm64": "@tashian/tsm-darwin-arm64",
};

// pgrep -u $USER -f '^.*tsmd( |$)' — every tsmd process owned by the current
// user. Empty list on no-match, ENOENT, or any other failure: the shim must
// never block tsm.
function pgrepUserTsmds({ execFileSync: exec = execFileSync } = {}) {
    const user = process.env.USER || "nobody";
    let out;
    try {
        out = exec("pgrep", ["-u", user, "-f", "^.*tsmd( |$)"], {
            stdio: ["ignore", "pipe", "ignore"],
        });
    } catch {
        return [];
    }
    return String(out)
        .split("\n")
        .map((s) => s.trim())
        .filter(Boolean)
        .map((s) => parseInt(s, 10))
        .filter((n) => Number.isFinite(n) && n > 0);
}

// First whitespace-delimited token of `ps -p PID -o args=` — argv[0], i.e.
// the path the kernel exec'd. Returns null if ps fails or produces no
// output (e.g. the process exited between pgrep and ps).
function getPidArgv0(pid, { execFileSync: exec = execFileSync } = {}) {
    let out;
    try {
        out = exec("ps", ["-p", String(pid), "-o", "args="], {
            stdio: ["ignore", "pipe", "ignore"],
        });
    } catch {
        return null;
    }
    const line = String(out).trim();
    if (!line) {
        return null;
    }
    return line.split(/\s+/)[0];
}

// Tsmd pids whose argv[0] is anything other than expectedPath. "Stale" =
// launched from a different prefix — e.g. ~/.local/bin/tsmd left over from
// a manual install before this user upgraded via npm/bun.
function findStaleTsmdPids(expectedPath, deps = {}) {
    const pids = pgrepUserTsmds(deps);
    const stale = [];
    for (const pid of pids) {
        const argv0 = getPidArgv0(pid, deps);
        if (argv0 && argv0 !== expectedPath) {
            stale.push(pid);
        }
    }
    return stale;
}

// SIGTERM each pid. Swallow ESRCH (race) and EPERM (cross-user daemon —
// possible after a stray `sudo npm install`); silently swallow anything
// else. The daemon's own SIGTERM handler closes the socket and zeros the
// master key on exit; the next `tsm` command will EnsureRunning a fresh
// daemon at TSM_TSMD_BIN.
function killStalePids(pids, { kill = process.kill.bind(process) } = {}) {
    for (const pid of pids) {
        try {
            kill(pid, "SIGTERM");
        } catch {
            // best effort
        }
    }
}

function main(argv = process.argv) {
    const key = `${process.platform}-${process.arch}`;
    const pkg = platforms[key];

    if (!pkg) {
        console.error(
            `tsm: unsupported platform ${key}. ` +
                `tsm currently ships binaries for: ${Object.keys(platforms).join(", ")}.`,
        );
        return 1;
    }

    let pkgRoot;
    try {
        pkgRoot = path.dirname(require.resolve(`${pkg}/package.json`));
    } catch {
        console.error(
            `tsm: prebuilt binary package "${pkg}" was not installed.\n` +
                `npm or bun likely skipped it because of an OS/arch mismatch, or you used --no-optional.\n` +
                `Reinstall without --no-optional, or build from source: https://github.com/tashian/tsm`,
        );
        return 1;
    }

    const binDir = path.join(pkgRoot, "bin");
    const tsm = path.join(binDir, "tsm");
    const tsmd = path.join(binDir, "tsmd");

    // tsm finds tsmd next to its own executable (internal/paths/paths.go), but
    // global installs symlink the wrapper, and os.Executable() on Darwin can
    // return the symlink path. Pinning TSM_TSMD_BIN sidesteps that entirely.
    if (!process.env.TSM_TSMD_BIN) {
        process.env.TSM_TSMD_BIN = tsmd;
    }

    // SIGTERM any tsmd whose argv[0] doesn't match TSM_TSMD_BIN — stale from
    // a previous install at a different prefix. Bun skips lifecycle scripts
    // by default and there's no consumer package.json on a global install
    // for `trustedDependencies` to apply, so the shim is the reliable place
    // to do this. Cheap (one pgrep + one ps per stale process), no-op when
    // the running daemon already matches.
    try {
        const stale = findStaleTsmdPids(process.env.TSM_TSMD_BIN);
        killStalePids(stale);
    } catch {
        // never block tsm
    }

    const result = spawnSync(tsm, argv.slice(2), { stdio: "inherit" });

    if (result.error) {
        console.error(`tsm: failed to exec ${tsm}: ${result.error.message}`);
        return 1;
    }

    return result.status ?? 1;
}

module.exports = {
    pgrepUserTsmds,
    getPidArgv0,
    findStaleTsmdPids,
    killStalePids,
    main,
};

if (require.main === module) {
    process.exit(main());
}
