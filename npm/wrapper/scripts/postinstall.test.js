"use strict";

// Tests for postinstall.js. Uses Node's built-in test runner so we don't
// need any dev dependencies in the wrapper package.
//
//   node --test scripts/postinstall.test.js

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const {
    resolveTsmdPath,
    findRunningTsmdPids,
    stopPids,
    main,
} = require("./postinstall.js");

// --- resolveTsmdPath --------------------------------------------------------

test("resolveTsmdPath returns <pkgDir>/bin/tsmd when platform pkg is installed", () => {
    const fakePkgJson = "/fake/node_modules/@tashian/tsm-darwin-arm64/package.json";
    const requireResolve = (id) => {
        assert.equal(id, "@tashian/tsm-darwin-arm64/package.json");
        return fakePkgJson;
    };
    const got = resolveTsmdPath({ requireResolve });
    assert.equal(got, path.join(path.dirname(fakePkgJson), "bin", "tsmd"));
});

test("resolveTsmdPath returns null when platform pkg is missing", () => {
    const requireResolve = () => {
        const err = new Error("Cannot find module");
        err.code = "MODULE_NOT_FOUND";
        throw err;
    };
    const got = resolveTsmdPath({ requireResolve });
    assert.equal(got, null);
});

// --- findRunningTsmdPids ----------------------------------------------------

function fakeExecFor(responses) {
    // responses is keyed by the joined args of pgrep, value is either
    // { stdout: "..." } or { error: { code, status } }.
    return (cmd, args) => {
        const key = args.join(" ");
        const r = responses[key];
        if (!r) {
            throw new Error(`unexpected exec: ${cmd} ${key}`);
        }
        if (r.error) {
            const e = new Error(r.error.message || "exec failed");
            if (r.error.code) e.code = r.error.code;
            if (typeof r.error.status === "number") e.status = r.error.status;
            throw e;
        }
        return Buffer.from(r.stdout || "");
    };
}

test("findRunningTsmdPids returns [] when no processes match", () => {
    const tsmdPath = "/u/.npm/.../bin/tsmd";
    // pgrep exits 1 with no stdout when no match; execFileSync throws.
    const exec = fakeExecFor({
        [`-f ${tsmdPath}`]: { error: { status: 1, message: "no match" } },
        [`-u ${process.env.USER || "nobody"} -f ^.*tsmd( |$)`]: {
            error: { status: 1, message: "no match" },
        },
    });
    const got = findRunningTsmdPids(tsmdPath, { execFileSync: exec });
    assert.deepEqual(got, []);
});

test("findRunningTsmdPids returns single pid from path-strict pass", () => {
    const tsmdPath = "/u/.npm/.../bin/tsmd";
    const exec = fakeExecFor({
        [`-f ${tsmdPath}`]: { stdout: "12345\n" },
        [`-u ${process.env.USER || "nobody"} -f ^.*tsmd( |$)`]: {
            error: { status: 1 },
        },
    });
    const got = findRunningTsmdPids(tsmdPath, { execFileSync: exec });
    assert.deepEqual(got, [12345]);
});

test("findRunningTsmdPids dedupes pids across both passes", () => {
    const tsmdPath = "/u/.npm/.../bin/tsmd";
    const exec = fakeExecFor({
        [`-f ${tsmdPath}`]: { stdout: "12345\n" },
        [`-u ${process.env.USER || "nobody"} -f ^.*tsmd( |$)`]: {
            // permissive pass: returns the same pid plus another (Homebrew remnant)
            stdout: "12345\n67890\n",
        },
    });
    const got = findRunningTsmdPids(tsmdPath, { execFileSync: exec });
    assert.deepEqual(got.sort(), [12345, 67890]);
});

test("findRunningTsmdPids returns multiple pids from a single pass", () => {
    const tsmdPath = "/u/.npm/.../bin/tsmd";
    const exec = fakeExecFor({
        [`-f ${tsmdPath}`]: { stdout: "111\n222\n333\n" },
        [`-u ${process.env.USER || "nobody"} -f ^.*tsmd( |$)`]: {
            error: { status: 1 },
        },
    });
    const got = findRunningTsmdPids(tsmdPath, { execFileSync: exec });
    assert.deepEqual(got.sort((a, b) => a - b), [111, 222, 333]);
});

test("findRunningTsmdPids returns [] when pgrep binary is not found", () => {
    const tsmdPath = "/u/.npm/.../bin/tsmd";
    const exec = (cmd, args) => {
        const e = new Error("spawn pgrep ENOENT");
        e.code = "ENOENT";
        throw e;
    };
    const got = findRunningTsmdPids(tsmdPath, { execFileSync: exec });
    assert.deepEqual(got, []);
});

// --- stopPids ---------------------------------------------------------------

test("stopPids is a no-op for empty list", () => {
    let called = false;
    const kill = () => {
        called = true;
    };
    stopPids([], { kill });
    assert.equal(called, false);
});

test("stopPids sends SIGTERM to each pid", () => {
    const sent = [];
    const kill = (pid, sig) => sent.push([pid, sig]);
    stopPids([1, 2, 3], { kill });
    assert.deepEqual(sent, [
        [1, "SIGTERM"],
        [2, "SIGTERM"],
        [3, "SIGTERM"],
    ]);
});

test("stopPids tolerates EPERM with a warning, does not throw", () => {
    const warned = [];
    const kill = (pid) => {
        const e = new Error("operation not permitted");
        e.code = "EPERM";
        throw e;
    };
    const warn = (msg) => warned.push(msg);
    stopPids([42], { kill, warn });
    assert.equal(warned.length, 1);
    assert.match(warned[0], /42/);
    assert.match(warned[0], /EPERM/);
});

test("stopPids swallows ESRCH silently", () => {
    const warned = [];
    const kill = () => {
        const e = new Error("no such process");
        e.code = "ESRCH";
        throw e;
    };
    const warn = (msg) => warned.push(msg);
    stopPids([7], { kill, warn });
    assert.deepEqual(warned, []);
});

test("stopPids re-warns on unexpected error codes but does not throw", () => {
    const warned = [];
    const kill = () => {
        const e = new Error("kaboom");
        e.code = "EWHATEVER";
        throw e;
    };
    const warn = (msg) => warned.push(msg);
    stopPids([99], { kill, warn });
    assert.equal(warned.length, 1);
    assert.match(warned[0], /99/);
});

// --- main -------------------------------------------------------------------

test("main no-ops on non-darwin", () => {
    const calls = { resolve: 0, find: 0, kill: 0 };
    const code = main({
        platform: "linux",
        resolveTsmdPath: () => {
            calls.resolve++;
            return "/should/not/be/used";
        },
        findRunningTsmdPids: () => {
            calls.find++;
            return [1];
        },
        stopPids: () => {
            calls.kill++;
        },
    });
    assert.equal(code, 0);
    assert.deepEqual(calls, { resolve: 0, find: 0, kill: 0 });
});

test("main no-ops when platform package is missing", () => {
    let killed = false;
    const code = main({
        platform: "darwin",
        resolveTsmdPath: () => null,
        findRunningTsmdPids: () => {
            throw new Error("should not be called");
        },
        stopPids: () => {
            killed = true;
        },
    });
    assert.equal(code, 0);
    assert.equal(killed, false);
});

test("main resolves, finds, and kills on darwin", () => {
    const seen = {};
    const code = main({
        platform: "darwin",
        resolveTsmdPath: () => "/p/bin/tsmd",
        findRunningTsmdPids: (p) => {
            seen.path = p;
            return [101];
        },
        stopPids: (pids) => {
            seen.pids = pids;
        },
    });
    assert.equal(code, 0);
    assert.equal(seen.path, "/p/bin/tsmd");
    assert.deepEqual(seen.pids, [101]);
});

test("main returns 0 even if find throws (postinstall must not fail)", () => {
    const code = main({
        platform: "darwin",
        resolveTsmdPath: () => "/p/bin/tsmd",
        findRunningTsmdPids: () => {
            throw new Error("unexpected pgrep failure");
        },
        stopPids: () => {},
    });
    assert.equal(code, 0);
});
