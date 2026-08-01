import XCTest
import Foundation

/// ⟨0.24⟩ SPEC §3.2 — **AN ADVISORY VERB MAY BE LESS CERTAIN THAN THE GATE, NEVER MORE** (candor-spec
/// `4fd140c`). The third instance of a law that was written after three separate local patches, and the
/// one that named it: over a report carrying `hosts` but NO `netClass`, `gate --report` REFUSES on §3.1
/// answerability while the advisory verbs answer anyway.
///
/// MEASURED on this engine before the fix, over the conformance R11 report (`app.nativeHole` = an Unknown
/// the policy's class filter excludes; `app.noClass` = `Net` + `hosts` and no `netClass`; `app.writes` =
/// a plain `Fs` violator), under `deny Net[unknown-host] app`:
///
///     gate --report      exit 2   it could NOT judge `app.noClass` — the field the filter reads is absent
///     unverified --json  exit 0   `ok:false`, and the ONLY function named is `app.nativeHole`
///     unverified --strict exit 0  green
///     fix-gate  --strict exit 0   green, `ok:true`
///
/// `app.noClass` is CLEARED by the verb whose entire job is "your green gate is not provably green",
/// while the gate itself declined to clear it over the identical bytes. The mechanism on THIS engine is
/// not the fallback derivation the ruling describes — `matcherNetClasses` reads `netClass` verbatim and
/// derives nothing — it is that `unverified` had no channel for a function that carries no `Unknown` at
/// all, so an unanswerable rule simply fell off the end. Same direction of error, different mechanism,
/// which is exactly why §3.2 states the invariant as a COMPARISON: **U_clear ⊆ G_clear.**
///
/// NOTE THE HISTORY the conformance row records: a WEAKER form of this assertion (gate-not-clean ⇒ the
/// verb names SOMETHING) passed on all four engines while the defect stood, because the verb names a
/// DIFFERENT hole. Only the per-function form catches it, and so every row here names a function.
///
/// **EVERY ROW HAS A MIRROR, and the mirrors are the load-bearing half.** This fix can only ever ADD
/// names, so the hazard it introduces is an OVER-report: a function the gate CAN clear that starts being
/// named, which would turn `unverified --strict` into noise and make the disclosure worthless. The
/// mirrors pin both sides of the answerability boundary — evidence present ⇒ silent, evidence absent ⇒
/// named — plus the two shapes that must not change at all (a bare unnarrowed rule, and a narrowed rule
/// whose evidence IS carried).
final class AdvisoryBoundProcessTests: XCTestCase {

    // ── fixtures ────────────────────────────────────────────────────────────────────────────────────

    /// The conformance R11 report, verbatim (candor-spec `gen_rung024.py`, `R11_REPORT`). Handed to all
    /// four engines there; handed to the three verbs here.
    private static let r11 = """
    {
      "candor": {"version": "handwritten", "spec": "0.23"},
      "package": "app",
      "analyzed": {"count": 3, "digest": "0"},
      "functions": [
        {"fn": "app.nativeHole", "inferred": ["Unknown"], "direct": ["Unknown"],
         "unknownWhy": ["native:dlopen"]},
        {"fn": "app.noClass", "inferred": ["Net"], "direct": ["Net"], "hosts": ["api.example.com"]},
        {"fn": "app.writes", "inferred": ["Fs"], "direct": ["Fs"], "paths": ["/etc/hosts"]}
      ]
    }
    """

    /// The same shape with the evidence PRESENT — the mirror's report. One `netClass` token is the only
    /// difference from `r11`, which is what makes the pair a controlled comparison.
    private static func netClassed(_ klass: String) -> String {
        """
        {
          "candor": {"version": "handwritten", "spec": "0.23"},
          "package": "app",
          "analyzed": {"count": 3, "digest": "0"},
          "functions": [
            {"fn": "app.nativeHole", "inferred": ["Unknown"], "direct": ["Unknown"],
             "unknownWhy": ["native:dlopen"]},
            {"fn": "app.noClass", "inferred": ["Net"], "direct": ["Net"], "hosts": ["api.example.com"],
             "netClass": ["\(klass)"]},
            {"fn": "app.writes", "inferred": ["Fs"], "direct": ["Fs"], "paths": ["/etc/hosts"]}
          ]
        }
        """
    }

    /// An INHERITED `Unknown` with no reason reachable anywhere in the report — the reason-class arm of
    /// the same refusal. NOT a reasonless DIRECT `Unknown`: §6.2's CONTRIBUTION gives that one
    /// `unresolved`, so the gate ANSWERS it and this file would be measuring the wrong thing (SPEC §3.1
    /// records that over-broad refusal by name; `gateInputFromReport` closed it).
    private static let inheritedUnknown = """
    {
      "spec": "0.24", "analyzed": {"count": 1},
      "functions": [
        {"fn": "app.inherited", "inferred": ["Unknown"], "direct": [], "unknownWhy": [], "calls": [],
         "loc": "a.swift:1"}
      ]
    }
    """

    // ── harness ─────────────────────────────────────────────────────────────────────────────────────

    private func run(verb: String, policy: String, report: String,
                     extra: [String] = []) throws -> (out: String, err: String, code: Int32) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-advbound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rp = root.appendingPathComponent("app.Swift.json")
        let pp = root.appendingPathComponent("policy.txt")
        try report.write(to: rp, atomically: true, encoding: .utf8)
        try (policy + "\n").write(to: pp, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [verb, "--report", rp.path, "--policy", pp.path] + extra)
    }

    private func doc(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    private func named(_ out: String) throws -> [String] {
        (((try doc(out))["unverified"] as? [[String: Any]]) ?? []).compactMap { $0["fn"] as? String }.sorted()
    }

    private func unevaluatedRules(_ out: String) throws -> [String] {
        (((try doc(out))["unevaluated"] as? [[String: Any]]) ?? []).compactMap { $0["rule"] as? String }.sorted()
    }

    // ── the CONTROL: what the gate says, which is the bound every row below is measured against ──────

    func testTheGateRefusesTheReportItCannotJudge() throws {
        let g = try run(verb: "gate", policy: "deny Net[unknown-host] app", report: Self.r11)
        XCTAssertEqual(g.code, 2,
                       "the whole comparison is vacuous unless the gate genuinely WITHHOLDS here — `app.noClass` "
                       + "carries Net with no `netClass`, so the destination filter has nothing to read")
    }

    func testTheGateClearsTheSameReportOnceTheEvidenceIsCarried() throws {
        let g = try run(verb: "gate", policy: "deny Net[unknown-host] app",
                        report: Self.netClassed("known-partner"))
        XCTAssertEqual(g.code, 0, "one token of evidence and the question is answerable — and answered NO")
    }

    func testTheGateChargesWhenTheCarriedEvidenceMatches() throws {
        let g = try run(verb: "gate", policy: "deny Net[unknown-host] app",
                        report: Self.netClassed("unknown-host"))
        XCTAssertEqual(g.code, 1, "…and answered YES — the third leg, without which `0` proves nothing")
    }

    // ── THE DEFECT: `unverified` cleared the function the gate could not ─────────────────────────────

    func testUnverifiedNamesTheFunctionTheGateCouldNotJudge() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app", report: Self.r11,
                        extra: ["--json"])
        XCTAssertTrue(try named(r.out).contains("app.noClass"),
                      "U_clear ⊄ G_clear: the gate exited 2 because it could not judge `app.noClass`, and the "
                      + "verb cleared it. Naming `app.nativeHole` instead satisfies a bare non-empty check "
                      + "while still clearing the one the gate withheld on — which is the defect, not a near-miss")
    }

    /// The reason recorded is the MISSING EVIDENCE, never a derived class — and it travels in the GATE'S
    /// OWN `unevaluated: [{rule, why}]` shape (§3.1, candor-spec `fc4b5f6`), not a second spelling.
    func testUnverifiedCarriesTheGatesUnevaluatedShape() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app", report: Self.r11,
                        extra: ["--json"])
        XCTAssertEqual(try unevaluatedRules(r.out), ["deny Net[unknown-host] app"],
                       "`rule` is the RAW policy line, verbatim — the field a consumer joins the named "
                       + "function back to")
        let rows = try XCTUnwrap((try doc(r.out))["unevaluated"] as? [[String: Any]])
        let why = try XCTUnwrap(rows.first?["why"] as? String)
        XCTAssertTrue(why.contains("netClass") && why.contains("absent"),
                      "the reason must name the evidence that is MISSING, so an operator can supply it")
        XCTAssertTrue(why.contains("app.noClass"),
                      "…and the function that defeated the rule, or the operator cannot find it")
        XCTAssertFalse(why.contains("reaches unknown-host") || why.contains("destination class is"),
                       "…and must never read as a claim about which destination class the function reaches — "
                       + "that is the derivation the gate declined to make")
    }

    /// The entry for a function the gate could not judge must not carry a REASON CLASS it does not have.
    /// `unknownWhy` is the hole's own reasons; there are none here, and echoing anything into it would be
    /// the second opinion §3.2 forbids.
    func testTheNamedFunctionCarriesNoInventedReason() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app", report: Self.r11,
                        extra: ["--json"])
        let rows = try XCTUnwrap((try doc(r.out))["unverified"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first(where: { ($0["fn"] as? String) == "app.noClass" }))
        XCTAssertEqual((row["unknownWhy"] as? [String]) ?? [], [],
                       "`app.noClass` carries no Unknown at all — any reason here would be invented")
        XCTAssertEqual(row["rule"] as? String, "deny Net[unknown-host] app",
                       "the raw line, so the row joins to its `unevaluated` entry")
        XCTAssertEqual(row["upgrade"] as? String, "deny Net app",
                       "the actionable edit is to STOP depending on evidence this report does not carry — "
                       + "derived from the POLICY alone. `deny Net[unknown-host] Unknown app` would be the "
                       + "hole-widening upgrade for a different situation entirely")
    }

    func testUnverifiedStrictExitsTwoWhereTheGateRefuses() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app", report: Self.r11,
                        extra: ["--json", "--strict"])
        XCTAssertEqual(r.code, 2,
                       "2 is could-not-fully-evaluate, matching the gate — not the 1 that would claim an "
                       + "ordinary finding, and certainly not the 0 that certified this before")
        XCTAssertNil((try doc(r.out))["ok"],
                     "`ok` is OMITTED when a rule went unjudged (SPEC §3.2's `whatif` shape): `true` would "
                     + "certify a question nobody answered and `false` would assert a finding nobody made")
    }

    // ── MIRROR 1: the evidence IS carried — the verb must go back to silence ─────────────────────────

    func testUnverifiedDoesNotNameTheFunctionOnceTheEvidenceIsCarried() throws {
        for klass in ["known-partner", "unknown-host"] {
            let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app",
                            report: Self.netClassed(klass), extra: ["--json", "--strict"])
            XCTAssertFalse(try named(r.out).contains("app.noClass"),
                           "OVER-REPORT (netClass=\(klass)): the gate can judge this function, so naming it "
                           + "on answerability grounds is the verb being less certain than the gate — noise, "
                           + "and the failure mode this fix introduces if it is written as a blanket")
            XCTAssertEqual(try unevaluatedRules(r.out), [],
                           "nothing went unevaluated (netClass=\(klass)) — the disclosure must not ride along")
            XCTAssertNotNil((try doc(r.out))["ok"], "…and `ok` comes back (netClass=\(klass))")
        }
    }

    /// MIRROR 2: a BARE `deny Net app` reads no class field at all, so it is answerable over the very
    /// report the narrowed form could not be. A blanket "Net entry without netClass ⇒ name it" would fail
    /// this row, and it is the difference between a rule that could not be read and a field that is absent.
    func testABareDenyNetIsAnswerableOverTheSameReport() throws {
        let g = try run(verb: "gate", policy: "deny Net app", report: Self.r11)
        XCTAssertEqual(g.code, 1, "the control: bare, this report is a plain violation")
        let r = try run(verb: "unverified", policy: "deny Net app", report: Self.r11,
                        extra: ["--json", "--strict"])
        XCTAssertEqual(try unevaluatedRules(r.out), [],
                       "no rule narrows, so no rule can be unanswerable")
        XCTAssertFalse(try named(r.out).contains("app.noClass"),
                       "the gate CHARGES this one; `unverified` reporting it back would be a finding "
                       + "restated as a caveat")
    }

    /// MIRROR 3: the ⟨0.19⟩/⟨0.20⟩ behaviour this rung must leave alone — a narrowed rule that PASSES an
    /// Unknown-carrying function still yields the ordinary hole, with the ordinary Unknown-widening
    /// upgrade. `app.nativeHole` is that function in every row above.
    func testTheOrdinaryHoleAndItsUpgradeAreUnchanged() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app",
                        report: Self.netClassed("known-partner"), extra: ["--json"])
        let rows = try XCTUnwrap((try doc(r.out))["unverified"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first(where: { ($0["fn"] as? String) == "app.nativeHole" }))
        XCTAssertEqual(row["rule"] as? String, "deny Net[unknown-host] app")
        XCTAssertEqual(row["upgrade"] as? String, "deny Net[unknown-host] Unknown app")
        XCTAssertEqual((row["unknownWhy"] as? [String]) ?? [], ["native:dlopen"])
    }

    // ── the REASON-CLASS arm of the same refusal ─────────────────────────────────────────────────────

    /// Here the containment already held BY ACCIDENT — the function carries `Unknown`, the narrowed rule
    /// does not bite it, so it was already named as an ordinary hole. What was missing is the DISCLOSURE
    /// that the gate refused, and the exit code that matches it. A row that only checked "is it named"
    /// would read green on this arm today, which is the same trap the conformance row's weaker form fell
    /// into.
    func testTheUnknownClassArmDisclosesAndExitsTwo() throws {
        let g = try run(verb: "gate", policy: "deny Unknown[dispatch] app", report: Self.inheritedUnknown)
        XCTAssertEqual(g.code, 2, "the control: no reason reachable, so the reason filter cannot be read")
        let r = try run(verb: "unverified", policy: "deny Unknown[dispatch] app",
                        report: Self.inheritedUnknown, extra: ["--json", "--strict"])
        XCTAssertTrue(try named(r.out).contains("app.inherited"))
        XCTAssertEqual(try unevaluatedRules(r.out), ["deny Unknown[dispatch] app"])
        XCTAssertEqual(r.code, 2, "the gate exited 2; `--strict` was exiting 0 over the identical bytes")
    }

    /// MIRROR: give that Unknown a reachable reason and the rule becomes answerable — no disclosure, and
    /// `--strict` goes back to the ordinary 1-on-a-finding.
    func testTheUnknownClassArmIsSilentOnceAReasonIsReachable() throws {
        let withReason = """
        {
          "spec": "0.24", "analyzed": {"count": 1},
          "functions": [
            {"fn": "app.inherited", "inferred": ["Unknown"], "direct": ["Unknown"],
             "unknownWhy": ["native:dlopen"], "calls": [], "loc": "a.swift:1"}
          ]
        }
        """
        let g = try run(verb: "gate", policy: "deny Unknown[dispatch] app", report: withReason)
        XCTAssertEqual(g.code, 0, "the class is `native`, outside `[dispatch]` — answered, and answered NO")
        let r = try run(verb: "unverified", policy: "deny Unknown[dispatch] app", report: withReason,
                        extra: ["--json", "--strict"])
        XCTAssertEqual(try unevaluatedRules(r.out), [], "OVER-REPORT: this rule was answerable")
        XCTAssertEqual(r.code, 1, "a hole is still a hole — the ordinary `--strict` finding")
    }

    // ── `fix-gate`: no remedy premised on evidence the gate refused to read ──────────────────────────

    func testFixGateDisclosesAndExitsTwoWhereTheGateRefuses() throws {
        let r = try run(verb: "fix-gate", policy: "deny Net[unknown-host] app", report: Self.r11,
                        extra: ["--json", "--strict"])
        XCTAssertEqual(try unevaluatedRules(r.out), ["deny Net[unknown-host] app"],
                       "the gate's own shape, on the verb that was answering `ok:true` over it")
        XCTAssertEqual(r.code, 2)
        XCTAssertNil((try doc(r.out))["ok"])
    }

    /// A HOIST PLAN FOR A BOUNDARY THE GATE COULD NOT ADJUDICATE is a confident instruction resting on a
    /// guess. `app.deep.send` carries `netClass: unknown-host` and IS denied; its caller `app.entry` is
    /// under the same `app` scope and carries `Net` with no `netClass`, so the climb in `computeRemedy`
    /// asks `deniedLayer` and gets NOT-FORBIDDEN — not because the destination is tolerated, but because
    /// the filter had nothing to read. `app.entry` becomes the hoist FRONTIER, and the operator is told
    /// to move the effect to a layer nobody established may hold it.
    ///
    /// (The scope matters and is why an earlier cut of this fixture measured nothing: put the caller
    /// OUTSIDE the rule's scope and it is genuinely allowed — the rule does not govern it, the gate can
    /// say so, and there is no refusal to be bounded by.)
    private static let hoistBoundary = """
    {
      "spec": "0.24", "analyzed": {"count": 2},
      "functions": [
        {"fn": "app.deep.send", "inferred": ["Net"], "direct": ["Net"], "netClass": ["unknown-host"],
         "calls": [], "loc": "a.swift:1"},
        {"fn": "app.entry", "inferred": ["Net"], "direct": [], %@ "calls": ["app.deep.send"],
         "loc": "a.swift:9"}
      ]
    }
    """

    func testFixGateOffersNoHoistOntoAnUnadjudicableBoundary() throws {
        let report = Self.hoistBoundary.replacingOccurrences(of: "%@", with: "")
        // THE CONTROL, and it is exit 1 rather than exit 2 by design: §3.1's precedence says a CERTAIN
        // violation dominates a refusal, and `app.deep.send` is one. The refusal is not swallowed — it
        // rides the verdict as `unevaluated`, which is the gate saying it could not adjudicate
        // `app.entry` while charging what it was sure of. That is the state the remedy must respect.
        let g = try run(verb: "gate", policy: "deny Net[unknown-host] app", report: report,
                        extra: ["--gate-json", "-"])
        XCTAssertEqual(g.code, 1)
        XCTAssertEqual(try unevaluatedRules(g.out), ["deny Net[unknown-host] app"],
                       "no refusal in the gate's own verdict would mean this fixture measures nothing")
        let r = try run(verb: "fix-gate", policy: "deny Net[unknown-host] app", report: report,
                        extra: ["--json"])
        let remedies = ((try doc(r.out))["remedies"] as? [[String: Any]]) ?? []
        let targets = remedies.flatMap { ($0["hoistTo"] as? [String]) ?? [] }
        XCTAssertFalse(targets.contains("app.entry"),
                       "the gate could not decide whether `app.entry` is an allowed layer for Net — the "
                       + "remedy asserts that it is")
        XCTAssertEqual(try unevaluatedRules(r.out), ["deny Net[unknown-host] app"],
                       "withholding without disclosing would trade one silence for another")
    }

    /// THE MIRROR for that, and the one that decides whether this is a fix or a mute button: carry the
    /// evidence on `app.entry` — a destination the rule tolerates, so it is still the allowed frontier —
    /// and the identical hoist must come back.
    func testFixGateStillOffersTheHoistWhenTheBoundaryIsAdjudicable() throws {
        let report = Self.hoistBoundary.replacingOccurrences(of: "%@", with: "\"netClass\": [\"known-partner\"],")
        let g = try run(verb: "gate", policy: "deny Net[unknown-host] app", report: report)
        XCTAssertEqual(g.code, 1, "the control: adjudicable, and `app.deep.send` is a real violation")
        let r = try run(verb: "fix-gate", policy: "deny Net[unknown-host] app", report: report,
                        extra: ["--json"])
        let remedies = ((try doc(r.out))["remedies"] as? [[String: Any]]) ?? []
        let targets = remedies.flatMap { ($0["hoistTo"] as? [String]) ?? [] }
        XCTAssertEqual(targets, ["app.entry"], "LOST DISCLOSURE: the boundary is adjudicable and the plan stands")
        XCTAssertEqual(try unevaluatedRules(r.out), [])
    }

    /// MIRROR: an unanswerable rule on ONE effect must not silence a remedy for ANOTHER. The suppression
    /// is keyed on the effect whose filter could not be read, not on "this policy went unanswered" — the
    /// gate itself keeps charging the violations it is sure of (§3.1 precedence), and a verb that stopped
    /// would be LESS useful than the gate rather than merely less certain.
    func testAnUnanswerableNetRuleDoesNotSilenceAnFsRemedy() throws {
        let r = try run(verb: "fix-gate", policy: "deny Net[unknown-host] app\ndeny Fs app",
                        report: Self.r11, extra: ["--json"])
        let effects = Set((((try doc(r.out))["remedies"] as? [[String: Any]]) ?? [])
            .compactMap { $0["effect"] as? String })
        XCTAssertTrue(effects.contains("Fs"),
                      "`app.writes` is a certain Fs crossing; the unanswerable Net filter says nothing about it")
    }

    // ── `fix`: the same claim, one function at a time ────────────────────────────────────────────────

    /// `fix <fn> Net` answered `crossing:false, reason:"not-forbidden"` — a positive claim about a rule
    /// the gate declined to evaluate.
    func testFixDoesNotReportNotForbiddenForARuleTheGateRefused() throws {
        let r = try run(verb: "fix", policy: "deny Net[unknown-host] app", report: Self.r11,
                        extra: ["app.noClass", "Net", "--json"])
        let d = try doc(r.out)
        XCTAssertEqual(d["reason"] as? String, "unanswerable",
                       "`not-forbidden` asserts the rule was evaluated and did not fire")
        XCTAssertNil(d["crossing"],
                     "and `crossing: false` asserts the other half of the same thing — the rule that "
                     + "governs `app.noClass` could not be read, so whether it crosses is undetermined")
        XCTAssertEqual(try unevaluatedRules(r.out), ["deny Net[unknown-host] app"])
    }

    /// THE DEFECT THIS CHANGE NEARLY INTRODUCED IN THE MIRROR DIRECTION. `app.deep.send` carries
    /// `netClass: unknown-host` and IS a crossing the gate CHARGES; only the hoist plan rests on
    /// `app.entry`, which the gate could not adjudicate. Withholding the plan by answering
    /// `crossing: false` would have turned a charged violation into a non-finding — a silent
    /// under-report arriving inside a fix for its opposite. The plan is withheld; the crossing is not.
    func testFixStillReportsTheCertainCrossingWhenOnlyThePlanIsWithheld() throws {
        let report = Self.hoistBoundary.replacingOccurrences(of: "%@", with: "")
        let r = try run(verb: "fix", policy: "deny Net[unknown-host] app", report: report,
                        extra: ["app.deep.send", "Net", "--json"])
        let d = try doc(r.out)
        XCTAssertEqual(d["crossing"] as? Bool, true, "the gate charges this one — it must not go quiet")
        XCTAssertEqual(d["reason"] as? String, "unanswerable")
        XCTAssertNil(d["hoistTo"], "…and the plan, which rests on `app.entry`, is the part withheld")
        XCTAssertEqual(try unevaluatedRules(r.out), ["deny Net[unknown-host] app"])
    }

    /// MIRROR: with the evidence carried, `not-forbidden` is a statement again and must come back.
    func testFixStillReportsNotForbiddenWhenTheRuleWasEvaluated() throws {
        let r = try run(verb: "fix", policy: "deny Net[unknown-host] app",
                        report: Self.netClassed("known-partner"), extra: ["app.noClass", "Net", "--json"])
        let d = try doc(r.out)
        XCTAssertEqual(d["reason"] as? String, "not-forbidden")
        XCTAssertNil(d["unevaluated"])
    }

    // ── THE PER-ENTRY `why`: the reason must reach the reader who is holding ONE ENTRY ───────────────
    //
    // The rung above put the unjudged function into `unverified` and its reason into the top-level
    // `unevaluated[]`. That is enough for a reader of the DOCUMENT and not enough for a reader of an
    // ENTRY — the two are joined only by the raw rule string, and nothing in the entry says the join is
    // even required. MEASURED four-way over the R11 report under `deny Net[unknown-host] app`, per-entry
    // key sets (NOT the union — the two entry kinds differ, and that is the whole finding):
    //
    //                 ORDINARY HOLE (`app.nativeHole`)    UNJUDGED (`app.noClass`)
    //     rust    [fn, rule, unknownWhy, upgrade]     [fn, rule, why]
    //     java    [fn, rule, unknownWhy, upgrade]     [fn, rule, unknownWhy, upgrade, why]
    //     ts      [fn, rule, unknownWhy, upgrade]     [fn, rule, why]
    //     swift   [fn, rule, unknownWhy, upgrade]     [fn, rule, unknownWhy, upgrade]      ← no `why`
    //
    // TWO THINGS THE MEASUREMENT CORRECTS, and both change what gets written:
    //
    //  1. `why` IS NOT A UNIVERSAL KEY. No engine puts one on an ordinary hole, and none should — an
    //     ordinary hole's reason is `unknownWhy`, and a second reason field beside it would invite a
    //     reader to treat the absence of a gate refusal as a statement about the hole. The key is
    //     emitted exactly where the gate WITHHELD, which is the one place a per-entry reader currently
    //     cannot tell that anything was withheld at all.
    //
    //  2. THE OVERLAP ARM IS WHERE SWIFT LOSES THE MOST, and it is invisible in the `Net` column above.
    //     Under `deny Unknown[dispatch] app` over an inherited-Unknown report, the function is BOTH an
    //     ordinary hole and unjudged. rust and ts emit TWO rows for that one (fn, rule) — the hole row
    //     and a separate `why` row. java merges. swift dedupes to one row on `seenPair` and the reason
    //     is dropped: not relocated to `unevaluated` for that ENTRY's sake, just absent. So the fix
    //     cannot be "add `why` to the rows the answerability pass appends" — the arm that needs it most
    //     has no such row. It attaches to the (fn, rule) PAIR, whichever pass emitted it, which is
    //     java's merged shape and the only one of the three that leaves swift's one-row rule intact.
    //
    // The three engines that carry it do NOT agree with each other, so this is not a majority vote: it
    // is that a per-entry reader written against ANY of the three finds nothing in swift's entry, and
    // the reason is sitting one array away under a key the entry never mentions.

    /// The `unverified` rows, as raw dictionaries.
    private func rows(_ out: String) throws -> [[String: Any]] {
        try XCTUnwrap((try doc(out))["unverified"] as? [[String: Any]])
    }

    /// THE DEFECT, `Net` arm: `app.noClass` is named, and nothing in its entry says why.
    func testTheUnjudgedEntryCarriesItsOwnWhy() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app", report: Self.r11,
                        extra: ["--json"])
        let row = try XCTUnwrap(try rows(r.out).first(where: { ($0["fn"] as? String) == "app.noClass" }))
        let why = try XCTUnwrap(row["why"] as? String,
                                "a consumer holding THIS entry cannot say why it is unverified without "
                                + "joining back to `unevaluated[]` on the raw rule string — and nothing in "
                                + "the entry tells them that join exists. rust, java and ts all carry it")
        XCTAssertTrue(why.contains("netClass") && why.contains("app.noClass"),
                      "it must name the MISSING EVIDENCE and the function, exactly as the disclosure does")
    }

    /// THE DEFECT, reason-class arm — the one swift's `seenPair` dedupe hides. The row exists (it is the
    /// ordinary hole), so every assertion the rung above makes passes, and the refusal still never
    /// reaches the entry.
    func testTheOverlappingEntryCarriesItsWhyToo() throws {
        let r = try run(verb: "unverified", policy: "deny Unknown[dispatch] app",
                        report: Self.inheritedUnknown, extra: ["--json"])
        let mine = try rows(r.out).filter { ($0["fn"] as? String) == "app.inherited" }
        XCTAssertEqual(mine.count, 1,
                       "swift emits ONE row per (fn, rule) and this change must not make it two — the "
                       + "reason travels ON the row, it does not earn a row of its own")
        let why = try XCTUnwrap(mine.first?["why"] as? String,
                                "the hole row won the tie and the refusal was dropped: `unverified` says "
                                + "this function is a hole, and never that the gate could not judge it")
        XCTAssertTrue(why.contains("app.inherited") && why.contains("unknownWhy"),
                      "the reason-class refusal names the channel that is missing")
        XCTAssertEqual((mine.first?["unknownWhy"] as? [String]) ?? [], [],
                       "…and the keys the row already carried are untouched — this ADDS one")
        XCTAssertEqual(mine.first?["upgrade"] as? String, "deny Unknown app")
    }

    /// ONE SPELLING (§3.2: inventing a second is the mistake the document has already made four times).
    /// The entry's reason and the disclosure's are the same bytes, so a reader who does perform the join
    /// gets no second, subtly different account of the same refusal.
    func testTheEntryWhyIsTheDisclosuresOwnBytes() throws {
        for (pol, report, fn) in [("deny Net[unknown-host] app", Self.r11, "app.noClass"),
                                  ("deny Unknown[dispatch] app", Self.inheritedUnknown, "app.inherited")] {
            let r = try run(verb: "unverified", policy: pol, report: report, extra: ["--json"])
            let row = try XCTUnwrap(try rows(r.out).first(where: { ($0["fn"] as? String) == fn }))
            let disc = try XCTUnwrap(((try doc(r.out))["unevaluated"] as? [[String: Any]])?
                                        .first(where: { ($0["rule"] as? String) == pol })?["why"] as? String)
            XCTAssertEqual(row["why"] as? String, disc,
                           "(\(pol)) the entry and the disclosure must not drift into two accounts")
        }
    }

    /// MIRROR — THE LOAD-BEARING ONE. An entry that is unverified for a reason that is NOT a withheld
    /// rule keeps exactly what it carries today. A blanket `why` would make the key meaningless (every
    /// entry has one, so its presence says nothing) and would put a gate-refusal reason on rows where no
    /// rule was refused — the over-report mirror of the lost disclosure.
    func testAnOrdinaryHoleCarriesNoWhyAtAll() throws {
        // (a) narrowed rule, evidence PRESENT — nothing is unanswerable anywhere in this run.
        // (b) a bare rule over the very report the narrowed form could not be answered on.
        for (name, pol, report) in [("evidence-carried", "deny Net[unknown-host] app",
                                     Self.netClassed("known-partner")),
                                    ("bare-rule", "deny Fs app", Self.r11)] {
            let r = try run(verb: "unverified", policy: pol, report: report, extra: ["--json"])
            let all = try rows(r.out)
            XCTAssertEqual(all.map { Set($0.keys) },
                           all.map { _ in Set(["fn", "rule", "unknownWhy", "upgrade"]) },
                           "(\(name)) every row here is an ORDINARY hole; the key set is the four-way "
                           + "agreed one and `why` is not in it: \(all.map { $0.keys.sorted() })")
            let row = try XCTUnwrap(all.first(where: { ($0["fn"] as? String) == "app.nativeHole" }),
                                    "(\(name)) vacuous unless the hole is actually there")
            XCTAssertEqual((row["unknownWhy"] as? [String]) ?? [], ["native:dlopen"],
                           "(\(name)) the hole's OWN reason, unrepurposed")
        }
    }

    /// MIRROR: the shape of the whole answer is unchanged — same rows, same order, same other keys. The
    /// counts are today's, measured before the change; a fix that added or dropped a row would be doing
    /// something other than carrying a reason across.
    func testTheAnswerGainsAKeyAndNothingElse() throws {
        let r = try run(verb: "unverified", policy: "deny Net[unknown-host] app", report: Self.r11,
                        extra: ["--json"])
        let all = try rows(r.out)
        XCTAssertEqual(all.compactMap { $0["fn"] as? String }, ["app.nativeHole", "app.noClass"],
                       "two rows, in this order, before and after")
        XCTAssertEqual(Set(all.first?.keys.map { $0 } ?? []), ["fn", "rule", "unknownWhy", "upgrade"],
                       "the ordinary hole is untouched")
        XCTAssertEqual(Set(all.last?.keys.map { $0 } ?? []), ["fn", "rule", "unknownWhy", "upgrade", "why"],
                       "the unjudged row gains `why` and keeps `unknownWhy` + `upgrade` — java's merged "
                       + "shape. Dropping them to match rust/ts would trade a lost disclosure for two more")
    }
}
