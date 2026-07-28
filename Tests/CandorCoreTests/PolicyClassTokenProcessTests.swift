import XCTest
import Foundation

/// ⟨0.24⟩ **AN UNRECOGNISED REASON-CLASS TOKEN IN A POLICY IS A POLICY ERROR** (SPEC §6.2, candor-spec
/// `382a7e0`, which WITHDRAWS its own asymmetry argument).
///
/// The clause used to justify the query/policy asymmetry by asserting that dropping an unrecognised class
/// token on the POLICY side can only WIDEN a rule, so the failure is loud. Measured four-way, it does
/// both — and the common case is the fail-open one, because a typo lands beside correct tokens far more
/// often than alone. MEASURED ON THIS ENGINE, 2026-07-28, over a signature whose ONLY hole class is
/// `indirect` (a closure-parameter call, `callback:f`):
///
///     deny Unknown[dispatch,indirct]   TYPO BESIDE A VALID TOKEN
///       before  the token was dropped, the rule NARROWED to `[dispatch]`, and it stopped gating the
///               `indirect` hole it was written for — EXIT 0 on both routes, while the operator reads a
///               gate that looks armed. FAIL-OPEN.
///     deny Unknown[corp]               SOLE UNRECOGNISED TOKEN
///       before  "candor: ignoring policy rule (unknown reason-class/alias `corp`)" … and then the rule
///               was KEPT and WIDENED to a bare `deny Unknown` — exit 1. A FALSE DISCLOSURE, the
///               `net-partner` class PART 13b exists for: the engine said it was ignoring a rule it was
///               enforcing.
///     after   both exit 2 on BOTH ROUTES, naming the token and the accepted set.
///
/// THE FIXTURE IS BUILT SO THE TYPO ROW IS GENUINELY FAIL-OPEN: the surviving token (`dispatch`) is a
/// class this signature does NOT carry, so the narrowed rule tolerates. A first draft paired the typo
/// with `indirect` — the class the signature DOES carry — and the narrowed rule still fired, so the row
/// failed before the fix for the wrong reason and demonstrated nothing.
///
/// PROCESS-LEVEL because the contract is an EXIT CODE on the shipped binary, and because the two routes
/// (`scan --policy` and `gate --report`) must refuse the same policies — that is a property of the two
/// CLIs, not of the parser they share.
final class PolicyClassTokenProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// A scan fixture with EXACTLY ONE reason class: candor-swift records a closure-parameter call as
    /// `callback:f`, which classifies to `indirect`. A rule that narrows to `indirect` fires; a rule that
    /// loses `indirect` to a typo and keeps only `dispatch` does not.
    private func makeScanFixture() throws -> URL {
        try ProcessHarness.makePackage("""
        import Foundation
        func hole(_ f: () -> Void) { f() }
        """)
    }

    /// The same signature as a hand-written report, for the `gate --report` route.
    private func makeReportDir(_ policy: String, config: String? = nil) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-classtok-\(UUID().uuidString)")
        let candor = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candor, withIntermediateDirectories: true)
        try """
        {"candor":{"spec":"0.23","toolchain":"swiftsyntax","version":"handwritten"},
         "package":"App","analyzed":{"count":1,"digest":"1111111111111111"},
         "functions":[{"fn":"app.hole","loc":"a.swift:1:1","inferred":["Unknown"],"direct":["Unknown"],
                       "declared":[],"undeclared":[],"overdeclared":[],"unresolved":true,
                       "hash":"App#hole","calls":[],"unknownWhy":["callback:f"]}]}
        """.write(to: candor.appendingPathComponent("report.App.Swift.json"), atomically: true, encoding: .utf8)
        if let config {
            try config.write(to: candor.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        try policy.write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        return root
    }

    // ── THE TYPO-BESIDE-VALID-TOKENS ROW COMES FIRST — it is the fail-open one ──────────────────────

    func testATypoBesideValidTokensIsAPolicyErrorOnTheReportRoute() throws {
        let root = try makeReportDir("deny Unknown[dispatch,indirct] app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 2, "a typo BESIDE valid tokens silently NARROWS the rule — it stops gating "
                       + "the class it was written for while the gate still looks armed. stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("`indirct`"), "the message must name the TOKEN: \(r.err)")
        XCTAssertTrue(r.err.contains("unresolved"), "and list the accepted set: \(r.err)")
        XCTAssertFalse(r.err.contains("policy ✓"), "and no verdict may be printed: \(r.err)")
    }

    func testATypoBesideValidTokensIsAPolicyErrorOnTheScanRoute() throws {
        let root = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("pol.txt")
        try "deny Unknown[dispatch,indirct]\n".write(to: pol, atomically: true, encoding: .utf8)
        let v = root.appendingPathComponent("v.json")
        try? FileManager.default.removeItem(at: v)
        let r = try ProcessHarness.run(bin(), [root.path, "--out", root.appendingPathComponent("r").path,
                                               "--policy", pol.path, "--gate-json", v.path])
        XCTAssertEqual(r.code, 2, "the SCAN route must refuse the same policy — two routes that disagree "
                       + "about which policies are readable is the split §3.1 exists to prevent. stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("`indirct`"), "naming the token: \(r.err)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.path),
                       "and NO verdict document — the unreadable-policy posture writes nothing, so the two "
                       + "routes cannot disagree about a policy neither of them could read")
    }

    // ── THE SOLE-UNRECOGNISED-TOKEN ROW: it WIDENED, and the disclosure was FALSE ───────────────────

    func testASoleUnrecognisedTokenIsAPolicyErrorOnBothRoutes() throws {
        let reportRoot = try makeReportDir("deny Unknown[corp] app\n")
        defer { try? FileManager.default.removeItem(at: reportRoot) }
        let g = try ProcessHarness.run(bin(), ["gate", "--report", reportRoot.path,
                                               "--policy", reportRoot.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(g.code, 2, "before: the engine printed `ignoring policy rule` and then KEPT and "
                       + "WIDENED it to a bare `deny Unknown`, exiting 1 — a FALSE disclosure. stderr: \(g.err)")
        XCTAssertTrue(g.err.contains("`corp`"), "naming the token: \(g.err)")
        XCTAssertFalse(g.err.contains("ignoring policy rule"),
                       "and NOT the old false line, which said it was ignoring a rule it was enforcing: \(g.err)")

        let scanRoot = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: scanRoot) }
        let pol = scanRoot.appendingPathComponent("pol.txt")
        try "deny Unknown[corp]\n".write(to: pol, atomically: true, encoding: .utf8)
        let s = try ProcessHarness.run(bin(), [scanRoot.path, "--out", scanRoot.appendingPathComponent("r").path,
                                               "--policy", pol.path])
        XCTAssertEqual(s.code, 2, "same on the scan route: \(s.err)")
    }

    // ── THE CONTROLS. Without these the rows above pass on a gate that refuses everything ───────────

    /// A CORRECTLY-SPELLED narrowed rule over the SAME signature still FIRES. Without this the rows above
    /// cannot tell "the typo was refused" from "this fixture has no hole and nothing was ever gated".
    func testTheCorrectlySpelledRuleStillFiresOnBothRoutes() throws {
        let reportRoot = try makeReportDir("deny Unknown[dispatch,indirect] app\n")
        defer { try? FileManager.default.removeItem(at: reportRoot) }
        let g = try ProcessHarness.run(bin(), ["gate", "--report", reportRoot.path,
                                               "--policy", reportRoot.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(g.code, 1, "control: the correctly-spelled rule must fire, else the fixture is inert. stderr: \(g.err)")

        let scanRoot = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: scanRoot) }
        let pol = scanRoot.appendingPathComponent("pol.txt")
        try "deny Unknown[dispatch,indirect]\n".write(to: pol, atomically: true, encoding: .utf8)
        let s = try ProcessHarness.run(bin(), [scanRoot.path, "--out", scanRoot.appendingPathComponent("r").path,
                                               "--policy", pol.path])
        XCTAssertEqual(s.code, 1, "control on the scan route: \(s.err)")
    }

    /// A `.candor/config` `unknown-alias` STILL RESOLVES — the refusal must not have eaten ⟨0.19⟩, whose
    /// whole point is that an installation may add vocabulary the built-in set does not carry.
    func testAConfigDefinedAliasIsNotAnUnrecognisedToken() throws {
        let root = try makeReportDir("deny Unknown[house] app\n", config: "unknown-alias house = indirect\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 1, "a config alias is policy VOCABULARY, not a typo — refusing it would have "
                       + "deleted the ⟨0.19⟩ feature. stderr: \(r.err)")
        XCTAssertFalse(r.err.contains("policy error"), r.err)
    }

    /// THE ADVISORY READERS ARE UNCHANGED, and this is deliberate rather than an oversight: `parsepolicy`
    /// is the conformance suite's four-way grammar witness (PART 4) and its battery contains
    /// `deny Fs Unknown[bogus,reflect] io` on purpose. A parser that refused would delete the witness
    /// instead of fixing the gate — so the RULES still parse, and it is the GATE routes that refuse.
    func testParsePolicyStillDumpsAPolicyCarryingAnUnrecognisedToken() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-classtok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("pol.txt")
        try "deny Fs Unknown[bogus,reflect] io\n".write(to: pol, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin(), ["parsepolicy", pol.path])
        XCTAssertEqual(r.code, 0, "the grammar witness must still produce a parse: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        let deny = d?["deny"] as? [[String: Any]] ?? []
        XCTAssertEqual(deny.count, 1, "and the rule is still in it: \(r.out)")
        XCTAssertEqual(deny.first?["unknownClasses"] as? [String], ["reflect"],
                       "with the same expansion the four-way differential pins: \(r.out)")
    }
}
