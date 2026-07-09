import XCTest
import Foundation

/// Process-level pins for the §6.2 `forbid <scope> -> <scope>` layer-flow rule (AS-EFF-009) — the
/// Gate.swift enforcement loop (the reverse-reachability walk over the call-graph sidecar). It IS
/// exercised cross-repo by conformance PART 16, but TESTING.md §3 requires the engine-local pin:
/// an engine-local regression must go red in THIS repo's CI, not wait for the spec repo's.
final class ForbidGateProcessTests: XCTestCase {

    /// The layered fixture: enum namespaces as layers, `Web.handler` reaching `Repo.save`
    /// TRANSITIVELY (through `Service.orchestrate`) — forbid is a reachability rule, so the pin
    /// must cross an intermediate hop, not just a direct edge. `Web.cousin` shares the `Web`
    /// namespace but never reaches `Repo` (the green twin).
    private let layered = """
    import Foundation
    enum Web {
        static func handler() { Service.orchestrate() }
        static func cousin() -> Int { 40 + 2 }
    }
    enum Service {
        static func orchestrate() { Repo.save() }
    }
    enum Repo {
        static func save() { _ = FileManager.default.contents(atPath: "/db") }
    }
    """

    private func runPolicy(_ fixture: String, _ policy: String) throws -> (out: String, err: String, code: Int32) {
        let bin = try ProcessHarness.binaryURL(for: ForbidGateProcessTests.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("policy.txt")
        try policy.write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--json", "--policy", pol.path])
    }

    // ── forbid FIRES across the layer boundary: exit 1 + the AS-EFF-009 line names both ends ───────
    func testForbidFiresAcrossLayersTransitively() throws {
        let r = try runPolicy(layered, "forbid Web -> Repo\n")
        XCTAssertEqual(r.code, 1, "a forbidden transitive reach must exit 1 — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("[AS-EFF-009]"), "the violation carries the 009 rule code: \(r.err)")
        XCTAssertTrue(r.err.contains("`Web.handler`") && r.err.contains("`Repo.save`"),
                      "the 009 line names the reaching fn AND the reached fn: \(r.err)")
        XCTAssertFalse(r.err.contains("Web.cousin"), "the cousin never reaches Repo — it must not be flagged: \(r.err)")
    }

    // ── the COUSIN rule passes: same namespace, no reach into the forbidden scope → exit 0 ──────────
    func testForbidCousinScopePassesClean() throws {
        let r = try runPolicy(layered, "forbid Web.cousin -> Repo\n")
        XCTAssertEqual(r.code, 0, "Web.cousin reaches no Repo fn — the gate must pass: \(r.err)")
        XCTAssertTrue(r.err.contains("policy ✓"), "expected the clean-gate marker: \(r.err)")
        XCTAssertFalse(r.err.contains("AS-EFF-009"), "no 009 may fire for an unreaching scope: \(r.err)")
    }

    // ── a CYCLIC call graph terminates (the seen-set guard) and still finds the boundary reach ─────
    // Mutual recursion Loop.a <-> Loop.b where b also crosses into Repo: without the seen-set the
    // walk revisits a/b forever. The pin is termination (the spawn returns at all) + the reach is
    // still found THROUGH the cycle (exit 1, 009 on Loop.a).
    func testForbidTerminatesOnCyclicCallGraph() throws {
        let cyclic = layered + """

        enum Loop {
            static func a() { Loop.b() }
            static func b() { Loop.a(); Repo.save() }
        }
        """
        let r = try runPolicy(cyclic, "forbid Loop.a -> Repo\n")
        XCTAssertEqual(r.code, 1, "the reach through the cycle must still be found — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("[AS-EFF-009]") && r.err.contains("`Loop.a`") && r.err.contains("`Repo.save`"),
                      "the 009 names the cycle entry and the boundary fn: \(r.err)")
        // and the cyclic green twin: a rule whose `to` scope nothing in the cycle reaches terminates clean.
        let g = try runPolicy(cyclic, "forbid Loop -> Nowhere\n")
        XCTAssertEqual(g.code, 0, "a cyclic graph with no boundary reach must terminate AND pass: \(g.err)")
    }

    // ── forbid + --gate-json: the 009 record reaches the structured verdict with effects: [] ────────
    // (§3.3: the violations list serializes the SAME records that set the exit code; a 009 concerns
    // layer flow, not a specific effect set, so `effects` is empty.)
    func testForbidViolationSerializesInGateJson() throws {
        let bin = try ProcessHarness.binaryURL(for: ForbidGateProcessTests.self)
        let root = try ProcessHarness.makePackage(layered)
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("policy.txt")
        try "forbid Web -> Repo\n".write(to: pol, atomically: true, encoding: .utf8)
        let gate = root.appendingPathComponent("gate.json")

        let r = try ProcessHarness.run(bin, [root.path, "--json", "--policy", pol.path, "--gate-json", gate.path])
        XCTAssertEqual(r.code, 1)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: gate)) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        let viols = obj?["violations"] as? [[String: Any]] ?? []
        XCTAssertEqual(viols.count, 1, "one 009 violation in the verdict")
        XCTAssertEqual(viols.first?["rule"] as? String, "AS-EFF-009")
        XCTAssertEqual(viols.first?["fn"] as? String, "Web.handler")
        XCTAssertEqual(viols.first?["effects"] as? [String], [], "009 is layer-flow — its effect set is empty")
    }
}
