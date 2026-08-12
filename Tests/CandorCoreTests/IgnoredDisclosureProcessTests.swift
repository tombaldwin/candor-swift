import XCTest
import Foundation

/// ⟨0.28⟩ SPEC §6.2 — **THE VERDICT DOCUMENT CARRIES THE LINES THE PARSE DROPPED** as
/// `ignored: [{line, text, reason}]`, omitted when nothing was dropped. The zero-rule refusal fires
/// only at ZERO survivors, so before this key a policy where nine of ten lines were dropped answered
/// `{"ok": true, "violations": []}` with the document saying nothing about the nine gates that were
/// never asked — a gateless green arriving at every fraction below 100%, while the per-line warnings
/// sat on stderr (not the machine channel). Distinct from `unevaluated`: that carries rules that PARSED
/// and could not be answered; this carries text that never became a rule at all. No engine implemented
/// it — a MUST with no consumer, the exact defect shape this rung spent a day on.
final class IgnoredDisclosureProcessTests: XCTestCase {

    private var bin: URL!
    private var dir: URL!

    override func setUpWithError() throws {
        bin = try ProcessHarness.binaryURL(for: Self.self)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("candor-ignored-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {
          "candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.28"},
          "functions": [
            {"fn": "B.doFs", "inferred": ["Fs"], "direct": ["Fs"], "calls": []}
          ],
          "analyzed": {"count": 1}
        }
        """.write(to: dir.appendingPathComponent("r.json"), atomically: true, encoding: .utf8)
        // One surviving rule (line 1), three lines the forward-compat leniency drops. The comment and
        // blank line must NOT appear in `ignored` — they never tried to be rules.
        try """
        deny Fs
        frobnicate all the things
        allow Net
        forbid a b c
        # a comment is not a dropped rule

        """.write(to: dir.appendingPathComponent("dropped.policy"), atomically: true, encoding: .utf8)
        try "deny Fs\n".write(to: dir.appendingPathComponent("clean.policy"), atomically: true, encoding: .utf8)
        // A rule the report PASSES beside the same dropped lines — the exit-0 gateless-green row.
        try """
        deny Exec
        frobnicate all the things
        """.write(to: dir.appendingPathComponent("passing.policy"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func p(_ rel: String) -> String { dir.appendingPathComponent(rel).path }

    private func verdict(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], out)
    }

    private func assertDroppedThree(_ d: [String: Any], _ ctx: String) throws {
        let ig = try XCTUnwrap(d["ignored"] as? [[String: Any]], ctx)
        XCTAssertEqual(ig.count, 3, ctx)
        XCTAssertEqual(ig.map { $0["line"] as? Int }, [2, 3, 4], "1-based line numbers: \(ctx)")
        XCTAssertEqual(ig[0]["text"] as? String, "frobnicate all the things",
                       "the source line, verbatim: \(ctx)")
        XCTAssertEqual(ig[0]["reason"] as? String, "unknown rule kind `frobnicate`", ctx)
        XCTAssertEqual(ig[1]["reason"] as? String, "allow names no values", ctx)
        XCTAssertEqual(ig[2]["reason"] as? String, "want `forbid <scope> -> <scope>`", ctx)
    }

    /// `gate --report` (the supply-chain route): the exit-1 verdict names the violation it is sure of
    /// AND the three lines that never became rules.
    func testGateReportVerdictCarriesTheDroppedLines() throws {
        let r = try ProcessHarness.run(bin, ["gate", "--report", p("r.json"),
                                             "--policy", p("dropped.policy"), "--json"])
        XCTAssertEqual(r.code, 1, "the surviving deny Fs fires: \(r.err)")
        let d = try verdict(r.out)
        XCTAssertEqual(d["ok"] as? Bool, false)
        try assertDroppedThree(d, r.out)
    }

    /// THE LOAD-BEARING ROW — the gateless green: a policy whose surviving rule PASSES ships
    /// `ok: true` at exit 0, and `ignored` is what tells the consumer the gate it is reading is
    /// smaller than the gate that was written.
    func testAPassingVerdictStillDisclosesWhatWasDropped() throws {
        let r = try ProcessHarness.run(bin, ["gate", "--report", p("r.json"),
                                             "--policy", p("passing.policy"), "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try verdict(r.out)
        XCTAssertEqual(d["ok"] as? Bool, true)
        let ig = try XCTUnwrap(d["ignored"] as? [[String: Any]], r.out)
        XCTAssertEqual(ig.count, 1, r.out)
        XCTAssertEqual(ig[0]["line"] as? Int, 2)
    }

    /// The SCAN route carries it too — §6.2 measured the defect on both, and a route is not covered by
    /// its sibling.
    func testScanRouteVerdictCarriesTheDroppedLines() throws {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func doFs() { FileManager.default.createFile(atPath: "/tmp/x", contents: nil) }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--policy", p("dropped.policy"),
                                             "--gate-json", "-"])
        XCTAssertEqual(r.code, 1, r.err)
        try assertDroppedThree(try verdict(r.out), r.out)
    }

    /// THE CONTROL: a clean policy's verdict carries NO `ignored` key — byte-identity is the property
    /// this rung must not spend. (Comments and blank lines never tried to be rules; the dropped.policy
    /// fixture pins that they are absent from the list by asserting exactly three entries.)
    func testACleanPolicysVerdictOmitsTheKey() throws {
        let r = try ProcessHarness.run(bin, ["gate", "--report", p("r.json"),
                                             "--policy", p("clean.policy"), "--json"])
        XCTAssertEqual(r.code, 1, r.err)
        XCTAssertNil(try verdict(r.out)["ignored"], r.out)
    }

    /// THE BOUNDARY: a typo'd effect token is a policy ERROR at exit 2 (⟨0.24⟩), not an ignored line —
    /// what follows the leniency is the residue, never the refusals.
    func testATypodEffectTokenStaysAnExitTwoPolicyError() throws {
        try "deny Nett app\n".write(to: dir.appendingPathComponent("typo.policy"),
                                    atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, ["gate", "--report", p("r.json"),
                                             "--policy", p("typo.policy"), "--json"])
        XCTAssertEqual(r.code, 2, "the gate refuses — this line is not `ignored` residue: \(r.err)")
        let d = try verdict(r.out)
        XCTAssertEqual(d["refused"] as? Bool, true, r.out)
        XCTAssertNil(d["ignored"], "a refusal document is not a verdict: \(r.out)")
    }
}
