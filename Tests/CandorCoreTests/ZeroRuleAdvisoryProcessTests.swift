import XCTest
import Foundation

/// ⟨0.28⟩ SPEC §2 — **AN ADVISORY VERB OVER A ZERO-RULE POLICY ANSWERS WITH THE CAVEAT DOCUMENT.** §6.2
/// makes a configured zero-rule policy an exit-2 refusal for the GATE; `fix-gate` and `unverified` share
/// its loader and were not touched by that rung — measured on this engine, both answered
/// `{"ok": true, "<results>": []}` at exit 0 over a comments-only policy, an empty result set
/// indistinguishable from "asked and everything passed". The rule: the caveat document INSTEAD of the
/// result document — result keys and `ok` withheld, `unevaluated` carrying the whole-policy entry (the
/// gate's own §3.1 shape) — and the EXIT UNCHANGED (a disclosure, not an exit code).
final class ZeroRuleAdvisoryProcessTests: XCTestCase {

    private var bin: URL!
    private var dir: URL!

    override func setUpWithError() throws {
        bin = try ProcessHarness.binaryURL(for: Self.self)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("candor-zerorule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {
          "candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.28"},
          "functions": [
            {"fn": "A.doNet", "inferred": ["Net", "Unknown"], "direct": ["Net", "Unknown"],
             "unknownWhy": ["callback:opaque"], "calls": []}
          ],
          "analyzed": {"count": 1}
        }
        """.write(to: dir.appendingPathComponent("r.json"), atomically: true, encoding: .utf8)
        try """
        {
          "candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.28"},
          "functions": [
            {"fn": "P.doNet", "inferred": ["Net"], "direct": ["Net"], "calls": []}
          ],
          "analyzed": {"count": 1},
          "unanalyzed": [{"path": "src/Broken.swift", "reason": "parse error"}]
        }
        """.write(to: dir.appendingPathComponent("partial.json"), atomically: true, encoding: .utf8)
        try "# placeholder — no rules yet\n"
            .write(to: dir.appendingPathComponent("zero.policy"), atomically: true, encoding: .utf8)
        // `deny Fs`: A.doNet PASSES it (no Fs) while carrying Unknown — the PASS-but-Unknown hole
        // `unverified` exists to name, so the intact control below has a real finding to keep.
        try "deny Fs\n"
            .write(to: dir.appendingPathComponent("deny.policy"), atomically: true, encoding: .utf8)
        try "allow Net api.example.com\n"
            .write(to: dir.appendingPathComponent("allow.policy"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func p(_ rel: String) -> String { dir.appendingPathComponent(rel).path }

    private func doc(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], out)
    }

    /// `unverified` withholds its result keys and carries the whole-policy `unevaluated` entry. The
    /// withheld `ok`/`unverified` are the load-bearing half: an empty list here reads as "asked and
    /// clear", the claim ⟨0.27⟩'s refusal document is forbidden `violations` for.
    func testUnverifiedOverAZeroRulePolicyEmitsTheCaveatDocument() throws {
        let r = try ProcessHarness.run(bin, ["unverified", "--report", p("r.json"),
                                             "--policy", p("zero.policy"), "--json"])
        XCTAssertEqual(r.code, 0, "the exit is UNCHANGED — advisory, not the gate's 2: \(r.err)")
        let d = try doc(r.out)
        XCTAssertNil(d["ok"], "`ok` is withheld — no question was asked: \(r.out)")
        XCTAssertNil(d["unverified"], "the result key is withheld, never an empty list: \(r.out)")
        let un = try XCTUnwrap(d["unevaluated"] as? [[String: Any]], r.out)
        XCTAssertEqual(un.count, 1)
        XCTAssertTrue((un[0]["rule"] as? String ?? "").contains("entire policy"),
                      "the whole-policy entry, the §3.1 shape for a policy with no lines to name")
    }

    /// …and `--strict` over a COMPLETE report keeps exit 0 too — before this rung the same argv exited 0
    /// (no holes to find), and the clause pins the exit as unchanged.
    func testUnverifiedStrictOverAZeroRulePolicyKeepsExitZero() throws {
        let r = try ProcessHarness.run(bin, ["unverified", "--report", p("r.json"),
                                             "--policy", p("zero.policy"), "--json", "--strict"])
        XCTAssertEqual(r.code, 0, r.err)
    }

    /// `--strict` over an INCOMPLETE report keeps ITS standing exit 2 (emitAdvisoryAnswer's rule, and the
    /// gate refuses those bytes as well) — "unchanged" cell by cell, not one blanket zero. The ⟨0.28⟩
    /// completeness keys ride the caveat document.
    func testUnverifiedStrictOverAZeroRulePolicyAndAPartialReportKeepsItsRefusal() throws {
        let r = try ProcessHarness.run(bin, ["unverified", "--report", p("partial.json"),
                                             "--policy", p("zero.policy"), "--json", "--strict"])
        XCTAssertEqual(r.code, 2, r.err)
        let d = try doc(r.out)
        XCTAssertEqual(d["incomplete"] as? Bool, true, "an unread unit qualifies a non-answer too")
        XCTAssertNil(d["unverified"], r.out)
        XCTAssertNotNil(d["unevaluated"], r.out)
    }

    /// `fix-gate` takes the identical rule: no `ok`, no `remedies`, the whole-policy entry, exit 0.
    func testFixGateOverAZeroRulePolicyEmitsTheCaveatDocument() throws {
        let r = try ProcessHarness.run(bin, ["fix-gate", "--report", p("r.json"),
                                             "--policy", p("zero.policy"), "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        XCTAssertNil(d["ok"], r.out)
        XCTAssertNil(d["remedies"], "an empty remedy list certifies \"no crossings\" over a policy that "
                     + "asked nothing: \(r.out)")
        XCTAssertNotNil(d["unevaluated"], r.out)
    }

    /// THE RULE-VECTOR CONTROL: an allow-only policy is NOT zero-rule — the check reads every vector,
    /// not `.deny` alone (the reference engine's first-draft mistake, recorded on the shared predicate).
    func testAnAllowOnlyPolicyIsNotZeroRule() throws {
        let r = try ProcessHarness.run(bin, ["unverified", "--report", p("r.json"),
                                             "--policy", p("allow.policy"), "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        XCTAssertNotNil(d["ok"], "a policy with a rule answers normally: \(r.out)")
        XCTAssertNotNil(d["unverified"], r.out)
    }

    /// THE INTACT CONTROL: a one-rule policy's answer keeps its pre-⟨0.28⟩ shape exactly — `ok` and the
    /// result key present, no whole-policy `unevaluated`.
    func testARealPolicyAnswersUnchanged() throws {
        let r = try ProcessHarness.run(bin, ["unverified", "--report", p("r.json"),
                                             "--policy", p("deny.policy"), "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        XCTAssertEqual(d["ok"] as? Bool, false, "the Unknown hole is named: \(r.out)")
        XCTAssertEqual((d["unverified"] as? [Any])?.count, 1, r.out)
        XCTAssertNil(d["unevaluated"], r.out)
    }
}
