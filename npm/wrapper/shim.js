"use strict";

const path = require("node:path");
const { spawnSync } = require("node:child_process");

const platforms = {
    "darwin-arm64": "@tashian/tsm-darwin-arm64",
};

const key = `${process.platform}-${process.arch}`;
const pkg = platforms[key];

if (!pkg) {
    console.error(
        `tsm: unsupported platform ${key}. ` +
            `tsm currently ships binaries for: ${Object.keys(platforms).join(", ")}.`,
    );
    process.exit(1);
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
    process.exit(1);
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

const result = spawnSync(tsm, process.argv.slice(2), { stdio: "inherit" });

if (result.error) {
    console.error(`tsm: failed to exec ${tsm}: ${result.error.message}`);
    process.exit(1);
}

process.exit(result.status ?? 1);
