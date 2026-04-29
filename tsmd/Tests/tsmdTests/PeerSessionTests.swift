import XCTest
@testable import tsmd

final class PeerSessionTests: XCTestCase {
    /// Process tree fixture: each pid maps to (sid, ppid).
    private struct Tree {
        let nodes: [pid_t: (sid: pid_t, ppid: pid_t)]

        func sessionOf(_ pid: pid_t) -> pid_t {
            nodes[pid]?.sid ?? 0
        }

        func parentOf(_ pid: pid_t) -> pid_t? {
            nodes[pid]?.ppid
        }
    }

    private func resolve(_ tree: Tree, peer: pid_t, maxHops: Int = 8) -> pid_t? {
        PeerSession.resolveDurableSessionID(
            peerPID: peer,
            sessionOf: tree.sessionOf,
            parentOf: tree.parentOf,
            maxHops: maxHops
        )
    }

    // Direct CLI invocation from a terminal shell:
    //   launchd(1, sid=1) → iTermServer(50, sid=1) → login(100, sid=100, leader)
    //     → fish(200, sid=100) → tsm(300, sid=100)
    // Expect: peer's own sid (100) is returned unchanged because the session
    // leader's parent (iTermServer) lives in the system session.
    func testDirectShellInvocationReturnsPeerSid() {
        let tree = Tree(nodes: [
            1:   (sid: 1,   ppid: 0),
            50:  (sid: 1,   ppid: 1),
            100: (sid: 100, ppid: 50),
            200: (sid: 100, ppid: 100),
            300: (sid: 100, ppid: 200),
        ])
        XCTAssertEqual(resolve(tree, peer: 300), 100)
    }

    // Claude Code spawns each Bash command via setsid:
    //   ... login(100, sid=100) → fish(200, sid=100) → claude(300, sid=100)
    //     → bash(400, sid=400, setsid'd) → tsm(500, sid=400)
    // Without the walk we'd return 400 (a fresh sid per Bash invocation).
    // With the walk we cross the setsid boundary once and return claude's
    // sid (100), which is shared by every Bash spawned from the same claude.
    func testAgentSetsidChildCollapsesToAgentSession() {
        let tree = Tree(nodes: [
            1:   (sid: 1,   ppid: 0),
            50:  (sid: 1,   ppid: 1),
            100: (sid: 100, ppid: 50),
            200: (sid: 100, ppid: 100),
            300: (sid: 100, ppid: 200),
            400: (sid: 400, ppid: 300),
            500: (sid: 400, ppid: 400),
        ])
        XCTAssertEqual(resolve(tree, peer: 500), 100)
    }

    // Two distinct agent-Bash invocations (sid 400 and sid 600) under the
    // same parent claude (sid 100) must collapse to the same key.
    func testTwoSetsidSiblingsShareKey() {
        let tree = Tree(nodes: [
            1:   (sid: 1,   ppid: 0),
            100: (sid: 100, ppid: 1),
            300: (sid: 100, ppid: 100),
            400: (sid: 400, ppid: 300),  // first bash (setsid'd)
            500: (sid: 400, ppid: 400),  // tsm via first bash
            600: (sid: 600, ppid: 300),  // second bash (setsid'd)
            700: (sid: 600, ppid: 600),  // tsm via second bash
        ])
        XCTAssertEqual(resolve(tree, peer: 500), 100)
        XCTAssertEqual(resolve(tree, peer: 700), 100)
    }

    // Two distinct iTerm tabs each have their own login session leader,
    // both parented by iTermServer in sid=1. They must NOT collapse — each
    // returns its own login sid.
    func testTwoTerminalTabsRemainIsolated() {
        let tree = Tree(nodes: [
            1:   (sid: 1,   ppid: 0),
            50:  (sid: 1,   ppid: 1),
            100: (sid: 100, ppid: 50),  // tab A login
            200: (sid: 100, ppid: 100), // tab A shell
            150: (sid: 150, ppid: 50),  // tab B login
            250: (sid: 150, ppid: 150), // tab B shell
        ])
        XCTAssertEqual(resolve(tree, peer: 200), 100)
        XCTAssertEqual(resolve(tree, peer: 250), 150)
    }

    // Nested ephemeral sessions (e.g., agent → setsid wrapper → setsid bash).
    // The walk should keep climbing until the next parent is in sid=1.
    func testNestedSetsidWalksMultipleHops() {
        let tree = Tree(nodes: [
            1:   (sid: 1,   ppid: 0),
            100: (sid: 100, ppid: 1),   // agent (parented by launchd)
            200: (sid: 200, ppid: 100), // outer setsid'd shim
            300: (sid: 300, ppid: 200), // inner setsid'd bash
            400: (sid: 300, ppid: 300), // tsm
        ])
        XCTAssertEqual(resolve(tree, peer: 400), 100)
    }

    // Defensive: unknown pids in the tree (the leader's parent has gone
    // away) cause the walk to stop early and return the current sid.
    func testMissingAncestorStopsWalk() {
        let tree = Tree(nodes: [
            400: (sid: 400, ppid: 999), // ppid not in fixture
            500: (sid: 400, ppid: 400),
        ])
        XCTAssertEqual(resolve(tree, peer: 500), 400)
    }

    // Defensive: maxHops bounds the walk so we can't loop forever even on
    // a pathological / inconsistent tree.
    func testMaxHopsBoundsTheWalk() {
        // A tree where every leader's parent introduces yet another fresh
        // session — pathological but legal as far as the walker knows.
        var nodes: [pid_t: (sid: pid_t, ppid: pid_t)] = [:]
        for i: pid_t in 1...20 {
            nodes[i * 10] = (sid: i * 10, ppid: (i + 1) * 10)
        }
        let tree = Tree(nodes: nodes)
        // Without a hop limit this would walk to the end. With maxHops=3
        // we should land exactly 3 hops from the start.
        let result = resolve(tree, peer: 10, maxHops: 3)
        XCTAssertEqual(result, 40)
    }

    func testZeroSidReturnsNil() {
        let tree = Tree(nodes: [42: (sid: 0, ppid: 1)])
        XCTAssertNil(resolve(tree, peer: 42))
    }
}
