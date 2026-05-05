"use strict";

// Tests for the helper functions exported by shim.js. The shim itself runs
// every time someone invokes `tsm`, so it has to fail-open on every error
// path; these tests pin that behavior down.
//
//   node --test scripts/shim.test.js

const test = require("node:test");
const assert = require("node:assert/strict");

const {
    pgrepUserTsmds,
    getPidArgv0,
    findStaleTsmdPids,
    killStalePids,
} = require("../shim.js");

const USER = process.env.USER || "nobody";

// Build a fake execFileSync that dispatches on `${cmd} ${args.join(" ")}`.
function fakeExecFor(responses) {
    return (cmd, args) => {
        const key = `${cmd} ${args.join(" ")}`;
        const r = responses[key];
        if (!r) {
            throw new Error(`unexpected exec: ${key}`);
        }
        if (r.error) {
            const e = new Error(r.error.message || "exec failed");
            if (r.error.code) e.code = r.error.code;
            throw e;
        }
        return Buffer.from(r.stdout || "");
    };
}

// --- pgrepUserTsmds ---------------------------------------------------------

test("pgrepUserTsmds returns [] when pgrep finds no match", () => {
    const exec = fakeExecFor({
        [`pgrep -u ${USER} -f ^.*tsmd( |$)`]: { error: { message: "no match" } },
    });
    assert.deepEqual(pgrepUserTsmds({ execFileSync: exec }), []);
});

test("pgrepUserTsmds returns [] when pgrep is missing (ENOENT)", () => {
    const exec = (cmd) => {
        const e = new Error(`spawn ${cmd} ENOENT`);
        e.code = "ENOENT";
        throw e;
    };
    assert.deepEqual(pgrepUserTsmds({ execFileSync: exec }), []);
});

test("pgrepUserTsmds parses pids out of pgrep stdout", () => {
    const exec = fakeExecFor({
        [`pgrep -u ${USER} -f ^.*tsmd( |$)`]: { stdout: "111\n222\n" },
    });
    const got = pgrepUserTsmds({ execFileSync: exec }).sort((a, b) => a - b);
    assert.deepEqual(got, [111, 222]);
});

// --- getPidArgv0 ------------------------------------------------------------

test("getPidArgv0 returns first whitespace-delimited token of `ps args`", () => {
    const exec = fakeExecFor({
        "ps -p 111 -o args=": {
            stdout: "/Users/x/.local/bin/tsmd --socket /tmp/s\n",
        },
    });
    assert.equal(
        getPidArgv0(111, { execFileSync: exec }),
        "/Users/x/.local/bin/tsmd",
    );
});

test("getPidArgv0 returns null when ps errors (process gone race)", () => {
    const exec = fakeExecFor({
        "ps -p 111 -o args=": { error: { message: "no such proc" } },
    });
    assert.equal(getPidArgv0(111, { execFileSync: exec }), null);
});

test("getPidArgv0 returns null on empty stdout", () => {
    const exec = fakeExecFor({
        "ps -p 111 -o args=": { stdout: "" },
    });
    assert.equal(getPidArgv0(111, { execFileSync: exec }), null);
});

// --- findStaleTsmdPids ------------------------------------------------------

test("findStaleTsmdPids returns pids whose argv0 differs from expected path", () => {
    const expected = "/new/prefix/bin/tsmd";
    const exec = fakeExecFor({
        [`pgrep -u ${USER} -f ^.*tsmd( |$)`]: { stdout: "111\n222\n333\n" },
        "ps -p 111 -o args=": {
            stdout: "/Users/x/.local/bin/tsmd --socket /tmp/a\n",
        },
        "ps -p 222 -o args=": {
            stdout: "/new/prefix/bin/tsmd --socket /tmp/b\n",
        },
        "ps -p 333 -o args=": {
            stdout: "/opt/homebrew/bin/tsmd --socket /tmp/c\n",
        },
    });
    const stale = findStaleTsmdPids(expected, { execFileSync: exec });
    assert.deepEqual(
        stale.sort((a, b) => a - b),
        [111, 333],
    );
});

test("findStaleTsmdPids returns [] when only the expected daemon is running", () => {
    const expected = "/new/prefix/bin/tsmd";
    const exec = fakeExecFor({
        [`pgrep -u ${USER} -f ^.*tsmd( |$)`]: { stdout: "222\n" },
        "ps -p 222 -o args=": {
            stdout: "/new/prefix/bin/tsmd --socket /tmp/b\n",
        },
    });
    assert.deepEqual(findStaleTsmdPids(expected, { execFileSync: exec }), []);
});

test("findStaleTsmdPids returns [] when no tsmd is running at all", () => {
    const exec = fakeExecFor({
        [`pgrep -u ${USER} -f ^.*tsmd( |$)`]: { error: { message: "none" } },
    });
    assert.deepEqual(
        findStaleTsmdPids("/new/prefix/bin/tsmd", { execFileSync: exec }),
        [],
    );
});

test("findStaleTsmdPids skips pids whose ps lookup races (process gone)", () => {
    const exec = fakeExecFor({
        [`pgrep -u ${USER} -f ^.*tsmd( |$)`]: { stdout: "111\n222\n" },
        "ps -p 111 -o args=": { error: { message: "gone" } },
        "ps -p 222 -o args=": { stdout: "/old/tsmd --socket s\n" },
    });
    assert.deepEqual(
        findStaleTsmdPids("/new/prefix/bin/tsmd", { execFileSync: exec }),
        [222],
    );
});

// --- killStalePids ----------------------------------------------------------

test("killStalePids sends SIGTERM to each pid", () => {
    const sent = [];
    killStalePids([1, 2, 3], { kill: (pid, sig) => sent.push([pid, sig]) });
    assert.deepEqual(sent, [
        [1, "SIGTERM"],
        [2, "SIGTERM"],
        [3, "SIGTERM"],
    ]);
});

test("killStalePids swallows ESRCH and EPERM, does not throw", () => {
    const tries = [];
    const kill = (pid) => {
        tries.push(pid);
        const e = new Error("x");
        e.code = pid === 1 ? "ESRCH" : "EPERM";
        throw e;
    };
    killStalePids([1, 2], { kill });
    assert.deepEqual(tries, [1, 2]);
});

test("killStalePids is a no-op for empty list", () => {
    let called = false;
    killStalePids([], {
        kill: () => {
            called = true;
        },
    });
    assert.equal(called, false);
});
