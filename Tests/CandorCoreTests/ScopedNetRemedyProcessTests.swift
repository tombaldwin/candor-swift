import XCTest
import Foundation

/// A CLASS-SCOPED `deny Net[…]` MUST MEAN THE SAME THING TO `fix-gate` AND `unverified` AS IT DOES TO
/// THE GATE — the ⟨0.20⟩ destination-class sibling of `ScopedUnknownRemedyProcessTests`.
///
/// `DenyRule.netClasses` was parsed and populated and neither `deniedLayer` (the `fix`/`fix-gate`
/// crossing predicate) nor `unverifiedHoleRule` (the provable-purity predicate) consulted it, exactly as
/// neither consulted `unknownClasses` before ⟨0.24⟩. Both therefore read `deny Net[unknown-host]` as the
/// bare `deny Net`, and broke in OPPOSITE directions off that one missing conjunct. MEASURED on
/// `deny Net[unknown-host] app` over a report whose only Net reaches `known-partner`:
///
///     gate                 exit 0                          correct — the destination class is excluded
///     fix-gate --strict    exit 1 + a remedy naming         OVER-CHARGE: a red CI check and a hoist
///                          `app.callPartner`                instruction for a boundary the policy
///                                                           does not deny
///     unverified --strict  exit 0, `ok: true`               UNDER-REPORT, and the worse half
///
/// The second is the reason both halves land in one change. The layer PASSES the function while it is
/// still carrying an `Unknown` — that IS a pass-but-Unknown hole, the object `unverified` exists to
/// name — and `unverified` certified it clean.
///
/// WHAT MAKES THIS ONE DIFFERENT from the reason-class round, and it is the whole of the work: a Net
/// destination class cannot be DERIVED from the fields `FixFn`/`UnverifiedFn` carried. A reason class
/// resolves out of `unknownWhy` + `direct` + `calls`; a destination class needs the host surface and the
/// project's partner set, neither of which is on those records. It is threaded instead — the report's
/// own ⟨0.20⟩ `netClass`, which the producer already floors at `unknown-host` and already accumulates
/// transitively, read verbatim the way `gate --report` reads it.
///
/// EVERY ROW HERE HAS A MIRROR, and the mirrors are the load-bearing half: a predicate that consults a
/// filter can only ever NARROW what it reports, so the failure mode this fix could introduce is a LOST
/// disclosure — a remedy that stops being offered, a hole that stops being named.
final class ScopedNetRemedyProcessTests: XCTestCase {

    /// Two functions reaching `netClass`, `app.entry` INHERITING the reach from `app.callPartner`. The
    /// `netClass` field sits on BOTH entries because it is transitive on the wire (the producer derives
    /// it from the accumulated host surface) — which is why no fixpoint is needed here and a verbatim
    /// read is the correct threading.
    private func report(netClass: String, unknown: Bool, extraEffect: String? = nil) -> String {
        var effs = ["\"Net\""]
        if unknown { effs.append("\"Unknown\"") }
        if let x = extraEffect { effs.append("\"\(x)\"") }
        let inf = effs.joined(separator: ", ")
        let why = unknown ? "\"dispatch:Port.send\"" : ""
        return """
        {
          "spec": "0.24",
          "analyzed": {"count": 2},
          "functions": [
            {"fn": "app.callPartner", "inferred": [\(inf)], "direct": [\(inf)],
             "netClass": ["\(netClass)"], "unknownWhy": [\(why)], "calls": [], "loc": "a.swift:1"},
            {"fn": "app.entry", "inferred": [\(inf)], "direct": [], "netClass": ["\(netClass)"],
             "unknownWhy": [], "calls": ["app.callPartner"], "loc": "a.swift:9"}
          ]
        }
        """
    }

    /// Writes the report + policy into a fresh dir and runs `verb --report … --policy … --strict --json`.
    /// `gate` has no `--strict` (its exit code IS the verdict) and an unknown flag exits 2, which would
    /// make the two CONTROL rows fail for a reason unrelated to destination classes.
    private func run(verb: String, policy: String, report: String) throws -> (out: String, err: String, code: Int32) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-scopednet-\(UUID().uuidString)")
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

    func testTheGateItselfExcludesTheUnmatchedDestinationClass() throws {
        let r = try run(verb: "gate", policy: "deny Net[unknown-host] app",
                        report: report(netClass: "known-partner", unknown: false))
        XCTAssertEqual(r.code, 0, "a declared partner is outside `[unknown-host]` — the gate is the ground truth here")
    }

    func testTheGateItselfFiresOnTheMatchedDestinationClass() throws {
        let r = try run(verb: "gate", policy: "deny Net[unknown-host] app",
                        report: report(netClass: "unknown-host", unknown: false))
        XCTAssertEqual(r.code, 1, "an unknown host IS denied — without this the whole comparison is vacuous")
    }

    // ── HALF 1: the `fix-gate` OVER-CHARGE ──────────────────────────────────────────────────────────

    func testFixGateOffersNoRemedyForANetTheRuleDoesNotDeny() throws {
        let r = try run(verb: "fix-gate", policy: "deny Net[unknown-host] app",
                        report: report(netClass: "known-partner", unknown: false))
        XCTAssertEqual(try remedyCount(r.out), 0,
                       "a remedy is an instruction to hoist a boundary — the policy does not deny this one")
        XCTAssertEqual(r.code, 0, "`--strict` must not redden CI for a crossing that is not a crossing")
    }

    /// THE MIRROR. The fix can only narrow, so the hazard it introduces is a remedy that stops being
    /// offered. When the policy's destination classes DO cover the reach, the remedy must arrive as before.
    func testFixGateStillOffersTheRemedyWhenTheDestinationClassMatches() throws {
        let r = try run(verb: "fix-gate", policy: "deny Net[unknown-host] app",
                        report: report(netClass: "unknown-host", unknown: false))
        XCTAssertEqual(try remedyCount(r.out), 1, "LOST DISCLOSURE: the class matches, the remedy must stand")
        XCTAssertEqual(r.code, 1)
    }

    /// THE SECOND MIRROR: the unnarrowed rule. `deny Net app` names no destination class, so it denies
    /// every Net whatever it reaches — a filter applied where none was written is the same bug inverted.
    func testFixGateBareDenyNetIsUnnarrowed() throws {
        let r = try run(verb: "fix-gate", policy: "deny Net app",
                        report: report(netClass: "known-partner", unknown: false))
        XCTAssertEqual(try remedyCount(r.out), 1, "a bare `deny Net` must keep catching every destination")
        XCTAssertEqual(r.code, 1)
    }

    /// THE THIRD MIRROR: a rule denying another effect alongside a narrowed `Net`. The `Exec` half is
    /// untouched by any destination filter and must still produce its remedy, so the narrowing cannot be
    /// implemented as "this rule is off".
    func testFixGateKeepsTheOtherEffectRemedyWhenOnlyNetIsNarrowedAway() throws {
        let r = try run(verb: "fix-gate", policy: "deny Exec Net[unknown-host] app",
                        report: report(netClass: "known-partner", unknown: false, extraEffect: "Exec"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let effects = Set(((obj["remedies"] as? [[String: Any]]) ?? []).compactMap { $0["effect"] as? String })
        XCTAssertEqual(effects, ["Exec"], "the Exec crossing is real; only the Net one is outside the classes")
    }

    /// THE FOURTH MIRROR: a report carrying NO `netClass` at all (a pre-⟨0.20⟩ or foreign producer). An
    /// empty set means NOT-forbidden, deliberately and in both callers — `evaluateGate` withholds the rule
    /// on that (rule, function) pair rather than charging on a default, and `fix-gate` must not invent a
    /// hoist for a rule the gate declined to evaluate. The absence travels on the gate's own refusal.
    func testFixGateWithholdsTheRemedyWhenTheReportCarriesNoNetClass() throws {
        let noField = """
        {
          "spec": "0.24", "analyzed": {"count": 1},
          "functions": [
            {"fn": "app.callPartner", "inferred": ["Net"], "direct": ["Net"], "calls": [], "loc": "a.swift:1"}
          ]
        }
        """
        let r = try run(verb: "fix-gate", policy: "deny Net[unknown-host] app", report: noField)
        XCTAssertEqual(try remedyCount(r.out), 0,
                       "the gate REFUSES this report (exit 2, unanswerable) — a remedy would assert a crossing "
                       + "nobody established")
        let g = try run(verb: "gate", policy: "deny Net[unknown-host] app", report: noField)
        XCTAssertEqual(g.code, 2, "the control: the gate's answer here is a refusal, not a violation")
    }

    // ── HALF 2: the `unverified` UNDER-REPORT — the cardinal-sin half ────────────────────────────────

    func testUnverifiedNamesTheHoleTheNarrowedNetRuleLetsThrough() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app",
                        report: report(netClass: "known-partner", unknown: true))
        XCTAssertEqual(try holeNames(r.out), ["app.callPartner", "app.entry"],
                       "the layer PASSES both while they carry an Unknown — that is what a hole IS")
        XCTAssertEqual(r.code, 1, "`--strict` exists to fail on exactly this")
    }

    /// A DEFECT THIS FIX MADE REACHABLE FROM THE HOT PATH, and therefore this fix's to close.
    /// `ruleUpgrade` reconstructed the source form from `effects` + `scope` alone, so a `Net` narrowing
    /// was dropped from BOTH halves of the note: it told the operator their rule was `deny Net app` when
    /// they wrote `deny Net[unknown-host] app`, and offered `deny Net Unknown app` as the edit that fixes
    /// it — an edit which ALSO silently widens the Net denial from one destination class to all of them.
    /// The upgrade for a narrowed rule adds `Unknown` and touches nothing else (matching the rust
    /// reference's per-term reconstruction, which conformance PART 12d pins).
    func testTheOfferedUpgradeKeepsTheNetNarrowing() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app",
                        report: report(netClass: "known-partner", unknown: true))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(obj["unverified"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["rule"] as? String }), ["deny Net[unknown-host] app"],
                       "the source form must keep the destination filter — it is why this function passes")
        XCTAssertEqual(Set(rows.compactMap { $0["upgrade"] as? String }), ["deny Net[unknown-host] Unknown app"],
                       "`deny Net Unknown app` widens the operator's rule while claiming to add one token")
    }

    /// THE MIRROR for that: an UNNARROWED rule's upgrade is untouched, so the repair cannot have moved the
    /// shape every other engine agrees on (conformance PART 12d).
    func testTheOfferedUpgradeForAnOrdinaryRuleIsUnchanged() throws {
        let r = try run(verb: "unverified", policy: "deny Exec app",
                        report: report(netClass: "known-partner", unknown: true))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(obj["unverified"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["rule"] as? String }), ["deny Exec app"])
        XCTAssertEqual(Set(rows.compactMap { $0["upgrade"] as? String }), ["deny Exec Unknown app"])
    }

    /// THE MIRROR. When the rule genuinely bites, the function is a GATE VIOLATION, not an unverified
    /// pass — `unverified` must stay silent or it reports a failure back as a caveat.
    func testUnverifiedStaysSilentWhenTheNetRuleActuallyDenies() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app",
                        report: report(netClass: "unknown-host", unknown: true))
        XCTAssertEqual(try holeNames(r.out), [], "the gate reports this one; it is not a pass-but-Unknown")
        XCTAssertEqual(r.code, 0)
    }

    /// THE SECOND MIRROR: `unverified`'s pre-existing job, which the new conjunct must not disturb — a
    /// `deny Exec` layer passing an `Unknown` function is a hole whatever its Net reaches.
    func testUnverifiedStillNamesTheOrdinaryHoleUnderAnUnrelatedDeny() throws {
        let r = try run(verb: "unverified", policy: "deny Exec app",
                        report: report(netClass: "known-partner", unknown: true))
        XCTAssertEqual(try holeNames(r.out), ["app.callPartner", "app.entry"])
        XCTAssertEqual(r.code, 1)
    }

    /// THE THIRD MIRROR: the bare `deny Net app` DOES deny both functions, so neither is a hole — pinning
    /// that the fix did not turn `unverified` into "every Unknown, always".
    func testUnverifiedStaysSilentUnderABareDenyNet() throws {
        let r = try run(verb: "unverified", policy: "deny Net app",
                        report: report(netClass: "known-partner", unknown: true))
        XCTAssertEqual(try holeNames(r.out), [], "a bare `deny Net` catches these — the gate owns them")
        XCTAssertEqual(r.code, 0)
    }
}
