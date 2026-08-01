import XCTest
import Foundation

/// A CLASS-SCOPED `deny Unknown[…]` MUST MEAN THE SAME THING TO `fix-gate` AND `unverified` AS IT DOES
/// TO THE GATE.
///
/// `DenyRule.unknownClasses` was parsed and populated, and NEITHER `deniedLayer` (the `fix`/`fix-gate`
/// crossing predicate) NOR `unverifiedHoleRule` (the provable-purity predicate) consulted it. Both
/// therefore read a narrowed rule as if it were the bare `deny Unknown`, and they broke in OPPOSITE
/// directions off the same missing conjunct. MEASURED on `deny Unknown[reflect,unresolved] app` over a
/// report whose only hole is `native:dlopen`:
///
///     gate                 exit 0                          correct — the class is excluded
///     fix-gate --strict    exit 1 + a remedy naming         OVER-CHARGE: a red CI check and a hoist
///                          `app.nativeHole`                 instruction for a boundary the policy
///                                                           does not deny
///     unverified --strict  exit 0, `ok: true`               UNDER-REPORT, and the worse half
///
/// The second is why both halves land in one change. The layer PASSES the function while it is still
/// carrying an `Unknown` — that IS a pass-but-Unknown hole, the exact object `unverified` exists to
/// name — and `unverified` certified it clean. The verb whose entire job is *"your green gate is not
/// provably green"* returned a green of its own. Closing only the `fix-gate` fabrication would have
/// killed an over-charge and left its silent mirror standing, which is this project's most expensive
/// recorded pattern.
///
/// EVERY ROW HERE HAS A MIRROR, and the mirrors are the load-bearing half. A predicate that consults a
/// filter can only ever NARROW what it reports, so the failure mode introduced by the fix is a LOST
/// disclosure: a hole that should still be named, silently dropped. So each "must now be silent" row is
/// paired with a "must still fire" row where the policy's classes DO match the function's, and each
/// "must now fire" row with one where the rule genuinely bites and `unverified` must stay quiet because
/// the gate is already reporting it.
final class ScopedUnknownRemedyProcessTests: XCTestCase {

    /// Two functions, one `Unknown`, whose reason class is `why` — `app.entry` INHERITS it, so the row
    /// also pins that the class travels (SPEC §4 makes `unknownWhy` direct-only; a predicate reading the
    /// direct field would see nothing at all at the caller).
    private func report(why: String, extraEffect: String? = nil) -> String {
        let inf = extraEffect.map { "\"Unknown\", \"\($0)\"" } ?? "\"Unknown\""
        let dir = extraEffect.map { "\"Unknown\", \"\($0)\"" } ?? "\"Unknown\""
        return """
        {
          "spec": "0.24",
          "analyzed": {"count": 2},
          "functions": [
            {"fn": "app.nativeHole", "inferred": [\(inf)], "direct": [\(dir)],
             "unknownWhy": ["\(why)"], "calls": [], "loc": "a.swift:1"},
            {"fn": "app.entry", "inferred": [\(inf)], "direct": [], "unknownWhy": [],
             "calls": ["app.nativeHole"], "loc": "a.swift:9"}
          ]
        }
        """
    }

    /// Writes the report + policy into a fresh dir and runs `verb --report … --policy … --strict --json`.
    /// `gate` has no `--strict` (its exit code IS the verdict), and passing an unknown flag exits 2 —
    /// which would have made the two CONTROL rows fail for a reason that has nothing to do with classes.
    private func run(verb: String, policy: String, report: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> (out: String, err: String, code: Int32) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-scopedunknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rp = root.appendingPathComponent("app.Swift.json")
        let pp = root.appendingPathComponent("policy.txt")
        try report.write(to: rp, atomically: true, encoding: .utf8)
        try (policy + "\n").write(to: pp, atomically: true, encoding: .utf8)
        let strict = verb == "gate" ? [] : ["--strict"]
        return try ProcessHarness.run(bin, [verb, "--report", rp.path, "--policy", pp.path] + strict + ["--json"])
    }

    private func remedyCount(_ out: String) throws -> Int {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        return (obj["remedies"] as? [[String: Any]])?.count ?? 0
    }

    private func holeNames(_ out: String) throws -> [String] {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        return ((obj["unverified"] as? [[String: Any]]) ?? []).compactMap { $0["fn"] as? String }.sorted()
    }

    // ── the CONTROL: what the gate itself says, which is what the other two must agree with ─────────

    func testTheGateItselfExcludesTheUnmatchedClass() throws {
        let r = try run(verb: "gate", policy: "deny Unknown[reflect,unresolved] app", report: report(why: "native:dlopen"))
        XCTAssertEqual(r.code, 0, "a `native` hole is outside `[reflect,unresolved]` — the gate is the ground truth here")
    }

    func testTheGateItselfFiresOnTheMatchedClass() throws {
        let r = try run(verb: "gate", policy: "deny Unknown[reflect,unresolved] app", report: report(why: "reflect:NSClassFromString"))
        XCTAssertEqual(r.code, 1, "a `reflect` hole IS denied — without this the whole comparison is vacuous")
    }

    // ── HALF 1: the `fix-gate` OVER-CHARGE ──────────────────────────────────────────────────────────

    func testFixGateOffersNoRemedyForAnUnknownTheRuleDoesNotDeny() throws {
        let r = try run(verb: "fix-gate", policy: "deny Unknown[reflect,unresolved] app", report: report(why: "native:dlopen"))
        XCTAssertEqual(try remedyCount(r.out), 0,
                       "a remedy is an instruction to hoist a boundary — the policy does not deny this one")
        XCTAssertEqual(r.code, 0, "`--strict` must not redden CI for a crossing that is not a crossing")
    }

    /// THE MIRROR. The fix can only narrow, so the hazard is a remedy that stops being offered. When the
    /// policy's classes DO cover the hole, the remedy must arrive exactly as before.
    func testFixGateStillOffersTheRemedyWhenTheClassMatches() throws {
        let r = try run(verb: "fix-gate", policy: "deny Unknown[reflect,unresolved] app", report: report(why: "reflect:NSClassFromString"))
        XCTAssertEqual(try remedyCount(r.out), 1, "LOST DISCLOSURE: the class matches, the remedy must stand")
        XCTAssertEqual(r.code, 1)
    }

    /// THE SECOND MIRROR: the unnarrowed rule. `deny Unknown app` names no class, so it denies every
    /// `Unknown` whatever its reason — a filter applied where none was written is the same bug inverted.
    func testFixGateBareDenyUnknownIsUnnarrowed() throws {
        let r = try run(verb: "fix-gate", policy: "deny Unknown app", report: report(why: "native:dlopen"))
        XCTAssertEqual(try remedyCount(r.out), 1, "a bare `deny Unknown` must keep catching every class")
        XCTAssertEqual(r.code, 1)
    }

    /// THE THIRD MIRROR: a rule denying a REAL effect alongside a narrowed `Unknown`. The `Net` half is
    /// untouched by any class filter and must still produce its remedy, so the narrowing cannot be
    /// implemented as "this rule is off".
    func testFixGateKeepsTheRealEffectRemedyWhenOnlyTheUnknownIsNarrowedAway() throws {
        let r = try run(verb: "fix-gate", policy: "deny Net Unknown[reflect] app", report: report(why: "native:dlopen", extraEffect: "Net"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let effects = Set(((obj["remedies"] as? [[String: Any]]) ?? []).compactMap { $0["effect"] as? String })
        XCTAssertEqual(effects, ["Net"], "the Net crossing is real; only the Unknown one is outside the classes")
    }

    // ── HALF 2: the `unverified` UNDER-REPORT — the cardinal-sin half ────────────────────────────────

    func testUnverifiedNamesTheHoleTheNarrowedRuleLetsThrough() throws {
        let r = try run(verb: "unverified", policy: "deny Unknown[reflect,unresolved] app", report: report(why: "native:dlopen"))
        XCTAssertEqual(try holeNames(r.out), ["app.entry", "app.nativeHole"],
                       "the layer PASSES both while they carry an Unknown — that is what a hole IS")
        XCTAssertEqual(r.code, 1, "`--strict` exists to fail on exactly this")
    }

    /// A DEFECT THIS FIX MADE REACHABLE, and therefore this fix's to close. `ruleUpgrade` reconstructs the
    /// rule and its `Unknown`-forbidding upgrade; a rule that already NAMED `Unknown` could never be
    /// returned by `unverifiedHoleRule` before, so the branch went unexercised — and it reconstructed the
    /// source form with the class filter silently dropped and appended a second token, offering the
    /// operator `deny Unknown Unknown app` as the edit that fixes their gate. The upgrade for a narrowed
    /// rule is the same rule UNNARROWED.
    func testTheOfferedUpgradeForANarrowedRuleIsThatRuleUnnarrowed() throws {
        let r = try run(verb: "unverified", policy: "deny Unknown[reflect,unresolved] app", report: report(why: "native:dlopen"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(obj["unverified"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["upgrade"] as? String }), ["deny Unknown app"],
                       "`deny Unknown Unknown app` is not a policy line anyone can paste")
        XCTAssertEqual(Set(rows.compactMap { $0["rule"] as? String }), ["deny Unknown[reflect,unresolved] app"],
                       "the source form must keep the classes — they are why this function is a hole")
    }

    /// THE MIRROR for that: an UNNARROWED rule's upgrade is untouched, so the repair above cannot have
    /// moved the shape every other engine agrees on (conformance PART 12d).
    func testTheOfferedUpgradeForAnOrdinaryRuleIsUnchanged() throws {
        let r = try run(verb: "unverified", policy: "deny Exec app", report: report(why: "native:dlopen"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(obj["unverified"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["upgrade"] as? String }), ["deny Exec Unknown app"])
        XCTAssertEqual(Set(rows.compactMap { $0["rule"] as? String }), ["deny Exec app"])
    }

    /// THE MIRROR. When the rule genuinely bites, the function is a GATE VIOLATION, not an unverified
    /// pass — `unverified` must stay silent or it duplicates the gate and reports a failure as a caveat.
    func testUnverifiedStaysSilentWhenTheRuleActuallyDeniesTheHole() throws {
        let r = try run(verb: "unverified", policy: "deny Unknown[reflect,unresolved] app", report: report(why: "reflect:NSClassFromString"))
        XCTAssertEqual(try holeNames(r.out), [], "the gate reports this one; it is not a pass-but-Unknown")
        XCTAssertEqual(r.code, 0)
    }

    /// THE SECOND MIRROR: `unverified`'s pre-existing job, which the new conjunct must not disturb — a
    /// `deny Exec` layer passing an `Unknown` function is a hole no matter what class it is.
    func testUnverifiedStillNamesTheOrdinaryHoleUnderAnUnrelatedDeny() throws {
        let r = try run(verb: "unverified", policy: "deny Exec app", report: report(why: "native:dlopen"))
        XCTAssertEqual(try holeNames(r.out), ["app.entry", "app.nativeHole"])
        XCTAssertEqual(r.code, 1)
    }

    /// THE THIRD MIRROR: the bare `deny Unknown app` DOES deny both functions, so neither is a hole —
    /// pinning that the fix did not turn `unverified` into "every Unknown, always".
    func testUnverifiedStaysSilentUnderABareDenyUnknown() throws {
        let r = try run(verb: "unverified", policy: "deny Unknown app", report: report(why: "native:dlopen"))
        XCTAssertEqual(try holeNames(r.out), [], "a bare `deny Unknown` catches these — the gate owns them")
        XCTAssertEqual(r.code, 0)
    }
}
