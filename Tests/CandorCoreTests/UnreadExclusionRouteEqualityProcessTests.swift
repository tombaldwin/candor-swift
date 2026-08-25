import XCTest
import Foundation

/// ⟨0.32⟩ **CODE THIS SCAN DID NOT READ MAKES THE VERDICT INCOMPLETE — ON BOTH ROUTES** (SPEC §3.1).
///
/// The rung landed on the scan route only. `excluded[].peeked == false` was already serialized in the
/// report, `gate --report` read the same document, and it certified CLEAN where `scan --policy` refused:
/// MEASURED on swift-syntax under `deny Net`, scan exit 2 `{"ok":false,"incomplete":true}` against gate
/// exit 0 `{"ok":true}`. That is a §3.1 ROUTE-EQUALITY violation in the fail-OPEN direction — the gate a
/// CI actually runs was the one that passed — and nothing in the suite could see it, because the rung
/// shipped with no test on either route.
///
/// PROCESS-LEVEL, and every row reads the VERDICT DOCUMENT rather than the exit code alone. The failure
/// this file exists to catch is exactly a document and an exit disagreeing about one run.
///
/// THE CONJUNCT THIS FILE FIRST GOT WRONG, and the reason so many of these rows are OVER-CHARGE
/// CONTROLS. `peeked: false` does have two causes — "the peek opened those files and could not read
/// them" and "no peek ran, because nothing was asked" — and the first version of this rung carved the
/// second out by keying on the PRODUCER'S HISTORY (`outOfScope` present ⇒ that scan was asked). **That
/// was itself a fail-open, MEASURED:** a ⟨0.29⟩-era report of a tree with a `Tests/` directory, written
/// by a bare `candor-swift <dir> --out N`, carries `excluded[].peeked: false` and omits `outOfScope`, so
/// the whole rule was skipped in exactly the case it exists for — `candor-swift <dir> --policy
/// 'deny Exec'` exited 2 naming the test helper that spawns `/bin/sh`, and `gate --report N --policy
/// 'deny Exec'` over the same tree answered exit 0, `ok: true`, `policy ✓`.
///
/// **THE RULE, restated: a class the producing scan did not READ licenses nothing, and whether that
/// matters is decided by the policy in force NOW, not by the producer's history.** From a REPORT the two
/// causes are indistinguishable, because they leave the identical hole — those files' effects are absent
/// from `functions` because nothing looked — and ⟨0.21⟩ licenses a purity claim only over units the scan
/// judged. `excluded` is MANDATORY from ⟨0.29⟩ (SPEC §2.2), so "the producer had no policy" is not a
/// reason to believe its silence. The carve-out that remains is about the QUESTION: only a `deny`/`pure`
/// rule's answer depends on code outside the scan's scope, which is the same short-circuit the
/// producer's own peek applies (`peekRules` is its DENY list).
final class UnreadExclusionRouteEqualityProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// A `.candor/` tree holding ONE hand-authored report, so the `excluded`/`outOfScope` pair can be
    /// posed exactly — which is the whole point, since the two keys are what the route reads.
    private func makeReportDir(envelope: String, policy: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-unread-\(UUID().uuidString)")
        let candor = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candor, withIntermediateDirectories: true)
        try envelope.write(to: candor.appendingPathComponent("report.App.Swift.json"),
                           atomically: true, encoding: .utf8)
        try policy.write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        return root
    }

    /// The §2 envelope, with the two keys this rung turns on supplied per row. `excluded` and
    /// `outOfScope` are spelled by the CALLER, including their ABSENCE — `nil` omits the key, which is
    /// the ⟨0.26⟩ cannot-answer form and a different claim from `[]`.
    ///
    /// ⟨0.33⟩ …and a THIRD key, `scannedUnder` — the deny set the producing scan's peek was BOUNDED BY
    /// (SPEC §2 ⟨0.33⟩), raw JSON exactly like its siblings. `nil` omits it, which after this rung is a
    /// DIFFERENT claim from an empty `excluded[].peeked` history: an `excluded` entry with `peeked: true`
    /// beside an ABSENT `scannedUnder` is the pre-⟨0.33⟩ producer shape and fails closed on its own.
    private func envelope(excluded: String?, outOfScope: String?, scannedUnder: String? = nil) -> String {
        var extra = ""
        if let excluded { extra += ",\"excluded\":\(excluded)" }
        if let outOfScope { extra += ",\"outOfScope\":\(outOfScope)" }
        if let scannedUnder { extra += ",\"scannedUnder\":\(scannedUnder)" }
        return """
        {"candor":{"spec":"0.32","toolchain":"swiftsyntax","version":"candor-swift-0.32.0"},
         "package":"App","analyzed":{"count":2,"digest":"1111111111111111"}\(extra),
         "functions":[{"fn":"app.Lib.add","loc":"a.swift:1:1","inferred":[],"direct":[],
                       "declared":[],"undeclared":[],"overdeclared":[],"unresolved":false,
                       "hash":"App#add","calls":[]}]}
        """
    }

    private func gate(_ root: URL, verdict: URL? = nil) throws -> (out: String, err: String, code: Int32) {
        var args = ["gate", "--report", root.appendingPathComponent(".candor/report").path,
                    "--policy", root.appendingPathComponent("pol.txt").path]
        if let verdict { args += ["--gate-json", verdict.path] }
        return try ProcessHarness.run(try bin(), args, cwd: root)
    }

    private func doc(_ s: String) throws -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw XCTSkip("not JSON: \(s)")
        }
        return o
    }

    // ── THE OVER-CHARGE CONTROLS, WRITTEN AND GREEN BEFORE THE FIX ─────────────────────────────────

    /// CONTROL 1 — A FULLY-PEEKED REPORT STILL GATES GREEN. The refusal keys on `peeked: false`, so the
    /// cheapest way to "fix" the fail-open is to refuse over every report that declares an exclusion at
    /// all. That value passes the defect row below while deleting the verb.
    ///
    /// ⟨0.33⟩ …AND "ASKED" IS NOW PART OF THE FIXTURE RATHER THAN AN ASSUMPTION. `peeked: true` is true
    /// only relative to the deny set the producer HELD (SPEC §2 ⟨0.33⟩), so this control only says what
    /// it claims when the producer's `scannedUnder` covers the rule being gated. Before that key existed
    /// the fixture could not express the difference; `testAPeekedReportWithoutScannedUnderRefuses` below
    /// drives the identical bytes WITHOUT it and requires exit 2.
    func testAFullyPeekedReportStillGatesGreen() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":true,"reason":"tests"}]"#,
                               outOfScope: "[]", scannedUnder: #"{"deny":["deny Net"]}"#),
            policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("verdict.json")
        let r = try gate(root, verdict: v)
        XCTAssertEqual(r.code, 0, "a class the producer READ, under THIS question, hides nothing: \(r.err)")
        let d = try doc(try String(contentsOf: v, encoding: .utf8))
        XCTAssertEqual(d["ok"] as? Bool, true, "…and the DOCUMENT must say so too: \(d)")
        XCTAssertNil(d["incomplete"], "a complete verdict carries no `incomplete` key: \(d)")
    }

    /// ⟨0.33⟩ THE HOLE THE `scannedUnder` KEY EXISTS FOR — a class the producer READ, but read while
    /// holding a deny set that does not cover THIS gate's rule. MEASURED on candor-java 0.32.1 over a
    /// real tree whose excluded source runs `Runtime.exec("id")`:
    ///
    ///     candor <tree> --policy 'deny Net'  --json A   -> exit 0, `peeked: true`, `outOfScope: []`
    ///     candor <tree> --policy 'deny Exec'            -> exit 2  (there IS an Exec out there)
    ///     candor gate --report A --policy 'deny Exec'   -> exit 0, `no violations`   <- the fail-open
    ///
    /// ⟨0.32⟩'s unread-class rule correctly does not fire here — the class really was read — and the
    /// ⟨0.29⟩ bound had filtered what the peek LOOKED FOR to the producer's denied effects, so the `Exec`
    /// was seen and discarded as out of that question.
    func testAPeekedReportUnderADifferentDenySetRefuses() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":true,"reason":"tests"}]"#,
                               outOfScope: "[]", scannedUnder: #"{"deny":["deny Net"]}"#),
            policy: "deny Exec\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 2, "the peek was bounded by `deny Net`, so its empty finding answers "
                       + "nothing about `deny Exec`: \(r.err)")
        XCTAssertTrue(r.err.contains("deny Exec"),
                      "…and the refusal must NAME the rule that went unasked: \(r.err)")
        XCTAssertTrue(r.err.contains("THE SAME policy"),
                      "…and the remedy must say THE SAME policy, not merely A policy — the loose reading "
                      + "is what PRODUCES this hole, because the operator DID scan with a policy: \(r.err)")
    }

    /// ⟨0.33⟩ AN ABSENT `scannedUnder` IS THE EMPTY SET, so a pre-⟨0.33⟩ report carrying `peeked: true`
    /// fails closed — the same shape ⟨0.32⟩ took over a ⟨0.29⟩-era no-policy report. Under the ⟨0.29⟩
    /// bound a class reaches `peeked: true` only when the producing scan HELD a deny rule, so the
    /// absence identifies a pre-rung producer precisely and the remedy is exact: re-scan with a current
    /// engine under this gate's own policy.
    func testAPeekedReportWithoutScannedUnderRefuses() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":true,"reason":"tests"}]"#,
                               outOfScope: "[]"),
            policy: "deny Exec\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 2, "a producer that does not say what it was asked cannot be read as "
                       + "having been asked THIS: \(r.err)")
    }

    /// ⟨0.33⟩ THE COVERAGE CONTROL, and it is why the key is the RULE SET rather than a digest: a
    /// producer that held `deny Net` AND `deny Exec` fully answers a consumer asking only one of them. A
    /// digest could decide only equality and would refuse this — same implementation cost, strictly
    /// worse answer.
    func testASupersetProducerStillCertifies() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":true,"reason":"tests"}]"#,
                               outOfScope: "[]", scannedUnder: #"{"deny":["deny Exec","deny Net"]}"#),
            policy: "deny Exec\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 0, "`deny Exec` is covered by the producer's set, so refusing it is a "
                       + "pure over-charge: \(r.err)")
    }

    /// ⟨0.33⟩ THE OVER-CHARGE CONTROL THE DESIGN NAMES FIRST, because a careless implementation gets it
    /// wrong in the LOUD direction: with NO class peeked, differing policies must still certify. The
    /// effect sets of ANALYZED code are policy-independent — only the PEEK was ever bounded by a deny
    /// set — so refusing here would redden every scan-then-gate pipeline in the family for a difference
    /// that changed no evidence.
    func testDifferingPoliciesOverAnUnpeekedNothingStillCertify() throws {
        let root = try makeReportDir(envelope: envelope(excluded: "[]", outOfScope: nil,
                                                        scannedUnder: #"{"deny":["deny Net"]}"#),
                                     policy: "deny Exec\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 0, "nothing was peeked, so no answer here was bounded by the producer's "
                       + "deny set: \(r.err)")
    }

    /// ⟨0.33⟩ A GARBLED `scannedUnder` MUST NOT MANUFACTURE COVERAGE. The fail-open direction here is the
    /// MIRROR of `peeked`'s: there the safe-looking value was "no exclusions", here it would be "the
    /// producer held these rules".
    func testAGarbledScannedUnderCannotCertify() throws {
        let shapes = [#""deny Exec""#, "7", "true", "null", "{}", #"{"deny":"deny Exec"}"#,
                      #"{"deny":7}"#, #"{"deny":["deny Exec",7]}"#]
        for shape in shapes {
            let root = try makeReportDir(
                envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":true,"reason":"tests"}]"#,
                                   outOfScope: "[]", scannedUnder: shape),
                policy: "deny Exec\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let r = try gate(root)
            XCTAssertEqual(r.code, 2, "`scannedUnder`: \(shape) is not the §2 shape, and reading it as "
                           + "coverage certifies a question the producer was never put: \(r.err)")
        }
    }

    /// CONTROL 2 — AN ABSENT `excluded` STILL GATES GREEN. `excluded` became mandatory at ⟨0.29⟩; a
    /// producer older than that carries no such key, and refusing over its ABSENCE would refuse every
    /// report written before the rung existed. ⟨0.26⟩'s absent-vs-empty rule cuts the other way here:
    /// there is no claim to fail closed on, only a format that predates the question.
    func testAnAbsentExcludedKeyStillGatesGreen() throws {
        let root = try makeReportDir(envelope: envelope(excluded: nil, outOfScope: nil),
                                     policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("verdict.json")
        let r = try gate(root, verdict: v)
        XCTAssertEqual(r.code, 0, "a pre-⟨0.29⟩ producer names no exclusion at all: \(r.err)")
        let d = try doc(try String(contentsOf: v, encoding: .utf8))
        XCTAssertEqual(d["ok"] as? Bool, true, "…and the DOCUMENT must say so too: \(d)")
        XCTAssertNil(d["incomplete"], "a complete verdict carries no `incomplete` key: \(d)")
    }

    /// CONTROL 3 — A POLICY WITH NO DENY RULE IS NOT REFUSED FOR WANT OF A PEEK. Only a `deny`/`pure`
    /// rule's answer depends on code outside the scan's scope; `allow`/`forbid`/`only` are answered — or,
    /// on this route, refused — for reasons of their own. This route refuses an `allow` rule UNIFORMLY
    /// and earlier, so the row asserts WHICH refusal fired: an exit code alone would pass a build that
    /// had started charging every allowlist gate for a peek nobody asked for.
    func testAPolicyWithNoDenyRuleIsNotRefusedForWantOfAPeek() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":false,"reason":"tests"}]"#,
                               outOfScope: nil),
            policy: "allow Net api.example.com\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 2, "the `allow` rule is unanswerable from a report: \(r.err)")
        XCTAssertTrue(r.err.contains("is an `allow` rule"),
                      "…and THAT is the refusal, stated in the allow rule's own words: \(r.err)")
        XCTAssertFalse(r.err.contains("did not READ"),
                       "an allowlist gate must not be charged for an unread class — its answer does not "
                       + "depend on code outside the scan's scope: \(r.err)")
    }

    /// CONTROL 4 — `pure` IS A DENY RULE AND MUST STILL ARM THE RULE. It is spelled with no effect list
    /// at all, so an implementation that flattened the policy into effect NAMES before asking "does this
    /// policy deny anything?" would find the empty set and silently disarm the strictest policy the
    /// grammar has. That exact flattening was MEASURED on this engine's own peek at ⟨0.30⟩ — `pure`
    /// contributed nothing, the peek never ran, and the strictest policy passed where `deny Exec` exited
    /// 2 on the identical tree.
    func testPureCountsAsADenyRuleAndStillArmsTheUnreadRule() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":false,"reason":"tests"}]"#,
                               outOfScope: nil),
            policy: "pure\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 2, "`pure` denies every effect — it is the LAST policy that should "
                       + "tolerate code nobody read: \(r.err)")
        XCTAssertTrue(r.err.contains("did not READ"),
                      "…and for the unread class, not for something else: \(r.err)")
    }

    /// CONTROL 5 — A DERIVED EXCLUSION HIDES NOTHING. `judgedElsewhere` is the PRODUCER's statement that
    /// this class is a copy of code the same scan already judged (`.build/`, whose files are the checked
    /// -out sources). Every SPM project with a build directory carries one, so ignoring the carve-out
    /// would refuse over essentially every real report.
    func testADerivedExclusionDoesNotRefuse() throws {
        let root = try makeReportDir(
            envelope: envelope(
                excluded: #"[{"class":"build-output","count":9,"peeked":false,"judgedElsewhere":true,"reason":"derived"}]"#,
                outOfScope: "[]"),
            policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("verdict.json")
        let r = try gate(root, verdict: v)
        XCTAssertEqual(r.code, 0, "the producer declared the class DERIVED — it hides no unjudged "
                       + "code, so it cannot make a verdict incomplete: \(r.err)")
        let d = try doc(try String(contentsOf: v, encoding: .utf8))
        XCTAssertEqual(d["ok"] as? Bool, true, "…and the DOCUMENT must say so too: \(d)")
    }

    /// CONTROL 6 — THE CARVE-OUT IS READ OFF THE PRODUCER, NOT OFF THE CLASS TOKEN. The same concept is
    /// spelled `build-output` here, `build-output-archive` in candor-java and `build-script` in
    /// candor-rust — and rust's is code that RUNS and must fail closed. So a class NAMED `build-output`
    /// with no `judgedElsewhere` on it must still refuse: keying on the token would gate another
    /// engine's report differently from the engine that wrote it.
    func testTheDerivedCarveOutComesFromTheFlagAndNotTheClassName() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"build-output","count":9,"peeked":false,"reason":"derived"}]"#,
                               outOfScope: "[]"),
            policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 2, "no `judgedElsewhere` on the wire means the producer made no such "
                       + "claim, whatever the class is called: \(r.err)")
    }

    /// CONTROL 7 — **THE CARVE-OUT IS PER ENTRY, and this is the pair that shows it.** One report, two
    /// unpeeked classes: `build-output`, which every built SPM tree carries and which the producer flags
    /// `judgedElsewhere: true`, and `manifest`, which it does not. The refusal must fire and must name
    /// `manifest` ALONE. A whole-report reading in either direction is wrong in a different way — "any
    /// carve-out silences the report" is the fail-open, "any unread class ignores the carve-out" starts
    /// refusing every real package in the world — and only a row carrying both can tell them apart.
    ///
    /// MEASURED on a real scan of a tree with a `.build/` and a `Package.swift`, which is what makes it
    /// worth pinning: this is the shape of essentially every report this engine will ever be handed.
    func testTheCarveOutIsAppliedPerEntryAndNamesOnlyTheUnreadClass() throws {
        let root = try makeReportDir(
            envelope: envelope(
                excluded: #"[{"class":"build-output","count":9,"peeked":false,"judgedElsewhere":true,"reason":"derived"},"#
                          + #"{"class":"manifest","count":1,"peeked":false,"reason":"build config"}]"#,
                outOfScope: nil),
            policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 2, "`manifest` went unread and carries no carve-out: \(r.err)")
        XCTAssertTrue(r.err.contains("manifest"), "…and it must be NAMED: \(r.err)")
        XCTAssertFalse(r.err.contains("build-output"),
                       "…while the class the PRODUCER declared derived must not be named: naming it "
                       + "would send the operator to re-scan a directory that hides nothing: \(r.err)")
    }

    // ── CORRUPT INPUT FAILS CLOSED, NAMING THE KEY ────────────────────────────────────────────────

    /// `excluded` now MOVES the verdict, so its members are read as strictly as `unanalyzed`'s: a
    /// present-but-unreadable flag is corrupt input NAMED in the refusal, never coerced to the
    /// safe-LOOKING value. **The two flags are the sharpest case Foundation offers.** JSON `true`
    /// bridges to `__NSCFBoolean`, but so does the INTEGER 1 bridge to a number `as? Bool` accepts —
    /// this engine has already shipped one live defect through that bridge (`analyzed: {count: true}`
    /// read as JUDGED), so `"judgedElsewhere": "yes"` silently carving out a class, or `"peeked": 1`
    /// silently reading as read, is a hazard with a precedent rather than a hypothetical.
    func testANonBooleanFlagOnAnExcludedMemberIsCorruptInput() throws {
        let shapes: [(String, String)] = [
            ("judgedElsewhere: a string",
             #"[{"class":"build-output","count":9,"peeked":false,"judgedElsewhere":"yes","reason":"d"}]"#),
            ("judgedElsewhere: a number",
             #"[{"class":"build-output","count":9,"peeked":false,"judgedElsewhere":1,"reason":"d"}]"#),
            ("peeked: a string",
             #"[{"class":"harness-target","count":2,"peeked":"yes","reason":"tests"}]"#),
            ("peeked: a number",
             #"[{"class":"harness-target","count":2,"peeked":1,"reason":"tests"}]"#),
        ]
        for (name, exc) in shapes {
            let root = try makeReportDir(envelope: envelope(excluded: exc, outOfScope: nil),
                                         policy: "deny Net\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let r = try gate(root)
            XCTAssertEqual(r.code, 2, "\(name): a flag that cannot be read is not a flag that says "
                           + "`false`, and the carve-out must never be granted by garbage: \(r.err)")
            XCTAssertTrue(r.err.contains("corrupt") && r.err.contains("excluded"),
                          "\(name): the refusal must NAME the key, or the operator cannot fix the "
                          + "producer: \(r.err)")
        }
    }

    /// **THE WHOLE SHAPE TABLE FOR THE TWO FLAGS, IN ONE PLACE** — because the rows above each pose one
    /// spelling, and what has to hold is that every OTHER spelling lands on the fail-closed side. A JSON
    /// `null` is a PRESENT key and therefore corrupt rather than absent: that is the ⟨0.26⟩ distinction,
    /// and it is the reading candor-ts takes (`"k" in e && typeof e.k !== "boolean"`) and candor-rust
    /// gets from serde. Both readings refuse, so that row is about the family answering one wire the
    /// same way rather than about soundness — the kind of difference a four-way conformance run exists
    /// for and a single-engine suite never sees.
    func testTheExcludedFlagShapeTable() throws {
        // (name, `excluded` JSON, expected exit, expected marker on stderr)
        let rows: [(String, String, Int32, String)] = [
            ("peeked absent", #"[{"class":"harness-target","count":1,"reason":"r"}]"#, 2, "did not READ"),
            ("peeked false",  #"[{"class":"harness-target","count":1,"peeked":false,"reason":"r"}]"#, 2, "did not READ"),
            ("peeked true",   #"[{"class":"harness-target","count":1,"peeked":true,"reason":"r"}]"#, 0, "policy ✓"),
            ("je true",       #"[{"class":"harness-target","count":1,"peeked":false,"judgedElsewhere":true,"reason":"r"}]"#, 0, "policy ✓"),
            ("je false",      #"[{"class":"harness-target","count":1,"peeked":false,"judgedElsewhere":false,"reason":"r"}]"#, 2, "did not READ"),
            ("je null",       #"[{"class":"harness-target","count":1,"peeked":false,"judgedElsewhere":null,"reason":"r"}]"#, 2, "corrupt"),
            ("je 1",          #"[{"class":"harness-target","count":1,"peeked":false,"judgedElsewhere":1,"reason":"r"}]"#, 2, "corrupt"),
            ("je string",     #"[{"class":"harness-target","count":1,"peeked":false,"judgedElsewhere":"yes","reason":"r"}]"#, 2, "corrupt"),
            ("peeked 1",      #"[{"class":"harness-target","count":1,"peeked":1,"reason":"r"}]"#, 2, "corrupt"),
            ("peeked string", #"[{"class":"harness-target","count":1,"peeked":"yes","reason":"r"}]"#, 2, "corrupt"),
            ("excluded []",   "[]", 0, "policy ✓"),
        ]
        for (name, exc, want, marker) in rows {
            // ⟨0.33⟩ EVERY ROW CARRIES A `scannedUnder` COVERING `deny Net` — this table is about the
            // `peeked`/`judgedElsewhere` FLAGS, and without it the "peeked true" row would test the
            // ⟨0.33⟩ cause (an absent `scannedUnder`) instead of the flag shape it names.
            let root = try makeReportDir(envelope: envelope(excluded: exc, outOfScope: nil,
                                                            scannedUnder: #"{"deny":["deny Net"]}"#),
                                         policy: "deny Net\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let r = try gate(root)
            XCTAssertEqual(r.code, want, "\(name): \(r.err)")
            XCTAssertTrue(r.err.contains(marker), "\(name): expected `\(marker)`: \(r.err)")
        }
    }

    // ── THE DEFECT ────────────────────────────────────────────────────────────────────────────────

    /// **THE FAIL-OPEN THIS ROW EXISTS FOR — and it is the shape a CI actually produces.** A report
    /// written by a bare `candor-swift <dir> --out N` omits `outOfScope` (no peek was asked for) and
    /// marks every class `peeked: false`. Keying the rule on that ABSENCE — the producer's HISTORY —
    /// skipped it in exactly the case it exists for, and the route certified `ok: true` over a tree
    /// whose test target spawns a subprocess while `scan --policy 'deny Exec'` exited 2 naming it.
    ///
    /// `excluded` is MANDATORY from ⟨0.29⟩ (SPEC §2.2), so this report is not an old producer's silence:
    /// it is a current producer stating it never opened those files. From here the two causes of
    /// `peeked: false` are indistinguishable and leave the identical hole, and ⟨0.21⟩ licenses a purity
    /// claim only over units the scan judged. Whether the hole matters is decided by the policy in force
    /// NOW — which denies an effect, so it does.
    func testAReportProducedWithNoPolicyStillRefusesUnderADenyRule() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":false,"reason":"tests"}]"#,
                               outOfScope: nil),
            policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("verdict.json")
        let r = try gate(root, verdict: v)
        XCTAssertEqual(r.code, 2, "the producer says it never READ `harness-target`; that it was never "
                       + "asked to is a fact about the producer, not about the code: \(r.err)")
        XCTAssertTrue(r.err.contains("harness-target"), "…and the class must be NAMED: \(r.err)")
        let d = try doc(try String(contentsOf: v, encoding: .utf8))
        XCTAssertEqual(d["ok"] as? Bool, false, "the DOCUMENT is what a CI consumer reads: \(d)")
        XCTAssertEqual(d["incomplete"] as? Bool, true,
                       "…and the exit and the document are one decision, not two: \(d)")
    }

    /// THE FAIL-OPEN. The peek WAS asked (`outOfScope` present) and came back unable to read a class.
    /// `scan --policy` exits 2 over exactly this state; `gate --report` read the same two keys off the
    /// same document and answered `ok: true`.
    func testAnUnreadExclusionClassMakesTheGateRouteIncomplete() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":false,"reason":"tests"},"#
                                          + #"{"class":"manifest","count":1,"peeked":true,"reason":"build config"}]"#,
                               outOfScope: "[]"),
            policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("verdict.json")
        let r = try gate(root, verdict: v)
        XCTAssertEqual(r.code, 2, "the report says the scan did not READ `harness-target`; a gate "
                       + "cannot be green over code nobody opened: \(r.err)")
        XCTAssertTrue(r.err.contains("harness-target"),
                      "…and the human channel must NAME the class, or the operator cannot act: \(r.err)")
        let d = try doc(try String(contentsOf: v, encoding: .utf8))
        XCTAssertEqual(d["ok"] as? Bool, false, "the DOCUMENT is what a CI consumer reads: \(d)")
        XCTAssertEqual(d["incomplete"] as? Bool, true, "…and it must say WHY it is not a pass: \(d)")
    }

    /// A REAL VIOLATION STILL DOMINATES (SPEC §3.1: violation 1 > refusal 2 > incomplete 2, forced by
    /// PAPER3 Lemma 2). Exit 1 names the finding it is certain of; demoting it to a bare "something went
    /// unread" would delete the actionable half of the answer.
    func testAViolationStillDominatesTheUnreadClass() throws {
        let root = try makeReportDir(
            envelope: """
            {"candor":{"spec":"0.32","toolchain":"swiftsyntax","version":"candor-swift-0.32.0"},
             "package":"App","analyzed":{"count":2,"digest":"1111111111111111"},
             "excluded":[{"class":"harness-target","count":2,"peeked":false,"reason":"tests"}],
             "outOfScope":[],
             "functions":[{"fn":"app.Wire.send","loc":"a.swift:1:1","inferred":["Net"],"direct":["Net"],
                           "declared":[],"undeclared":[],"overdeclared":[],"unresolved":false,
                           "hash":"App#send","calls":[],"netClass":["unknown-host"]}]}
            """,
            policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 1, "a rule FIRED on evidence this report carries: \(r.err)")
    }

    /// **AND THE GREEN TICK IS NOT PRINTED AT ALL.** This route printed `candor-swift: policy ✓` above
    /// its exit-2 arms, so an incomplete verdict led with a green tick and contradicted itself one line
    /// later — and an operator scanning CI output reads the tick and stops. The scan route moved its own
    /// tick below its arms at ⟨0.30⟩; this one kept the old position, which would have put a third cause
    /// under it. Asserted on all THREE causes, because a fix that moved only the new arm's tick would
    /// leave the other two saying it.
    func testNoGreenTickIsPrintedOnAnyIncompleteVerdict() throws {
        let causes: [(String, String)] = [
            ("unread", envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":false,"reason":"t"}]"#,
                                outOfScope: "[]")),
            ("outOfScope", envelope(excluded: "[]", outOfScope:
                #"[{"fn":"t.helper","path":"Tests/x.swift","effects":["Net"],"class":"harness-target","reason":"r"}]"#)),
            ("unanalyzed", """
             {"candor":{"spec":"0.32","toolchain":"swiftsyntax","version":"candor-swift-0.32.0"},
              "package":"App","analyzed":{"count":2,"digest":"1111111111111111"},
              "unanalyzed":[{"path":"Sources/App/Broken.swift","reason":"parse error"}],
              "functions":[{"fn":"app.Lib.add","loc":"a.swift:1:1","inferred":[],"direct":[],
                            "declared":[],"undeclared":[],"overdeclared":[],"unresolved":false,
                            "hash":"App#add","calls":[]}]}
             """),
        ]
        for (name, env) in causes {
            let root = try makeReportDir(envelope: env, policy: "deny Net\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let r = try gate(root)
            XCTAssertEqual(r.code, 2, "\(name): expected an incomplete verdict: \(r.err)")
            XCTAssertFalse(r.err.contains("policy ✓"),
                           "\(name): a verdict that is NOT certified must not lead with the clean-gate "
                           + "marker — it is the line a human stops reading at: \(r.err)")
        }
    }

    /// THE CONTROL FOR THE ROW ABOVE: a genuinely clean gate still prints the tick. Suppressing it
    /// everywhere would pass that assertion while deleting the only thing a human reads on success.
    func testACleanGateStillPrintsTheGreenTick() throws {
        let root = try makeReportDir(envelope: envelope(excluded: "[]", outOfScope: "[]"),
                                     policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try gate(root)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("policy ✓"), "expected the clean-gate marker: \(r.err)")
    }

    // ── ROUTE EQUALITY, END TO END ────────────────────────────────────────────────────────────────

    /// **THE ACCEPTANCE TEST §3.1 ACTUALLY STATES: the two documents are BYTE-EQUAL.** Exit codes alone
    /// would have passed a fix that moved the exit and left `ok: true` on the wire — the split ⟨0.26⟩
    /// calls worse than saying nothing, and the shape ⟨0.30⟩ already shipped once.
    ///
    /// A REAL SCAN, not a hand-authored report: the fixture puts an unparseable file in `Tests/`, which
    /// the parent scan EXCLUDES (harness-target) and the peek child then cannot read — so `peeked` comes
    /// back false through the engine's own machinery rather than because a fixture asserted it.
    func testBothRoutesWriteTheSameVerdictOverAnUnreadClass() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-unread-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tests/AppTests"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.target(name: "App"),
                                                     .testTarget(name: "AppTests", dependencies: ["App"])])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func add(_ a: Int) -> Int { a + 1 }\n"
            .write(to: root.appendingPathComponent("Sources/App/Lib.swift"), atomically: true, encoding: .utf8)
        try "func broken( {{{ \n"
            .write(to: root.appendingPathComponent("Tests/AppTests/Broken.swift"), atomically: true, encoding: .utf8)
        try "deny Net\n".write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)

        let scanVerdict = root.appendingPathComponent("scan.verdict.json")
        let scan = try ProcessHarness.run(try bin(),
                                          [root.path, "--policy", root.appendingPathComponent("pol.txt").path,
                                           "--gate-json", scanVerdict.path],
                                          cwd: root)
        XCTAssertEqual(scan.code, 2, "the peek could not read the excluded harness target: \(scan.err)")
        // The fixture REACHED the code: assert the state this rung keys on, so a row that stops firing
        // because the walk changed is distinguishable from one that stops firing because the fix broke.
        let rep = try doc(try String(contentsOf: root.appendingPathComponent(".candor/report.App.Swift.json"),
                                     encoding: .utf8))
        let ex = try XCTUnwrap(rep["excluded"] as? [[String: Any]], "\(rep)")
        XCTAssertEqual(ex.first { $0["class"] as? String == "harness-target" }?["peeked"] as? Bool, false,
                       "the fixture must actually produce an UNREAD class, or this row proves nothing: \(ex)")
        XCTAssertNotNil(rep["outOfScope"], "…and the peek must have been ASKED: \(rep)")

        let gateVerdict = root.appendingPathComponent("gate.verdict.json")
        let g = try gate(root, verdict: gateVerdict)
        XCTAssertEqual(g.code, scan.code, "§3.1: the two routes answer the same over one report: \(g.err)")
        let a = try Data(contentsOf: scanVerdict), b = try Data(contentsOf: gateVerdict)
        XCTAssertEqual(String(data: a, encoding: .utf8), String(data: b, encoding: .utf8),
                       "§3.1 makes BYTE-EQUALITY the acceptance test, not exit-code agreement")
    }

    /// **THE DEFECT, END TO END, ON THE SHAPE A CI PRODUCES:** scan in one job with no policy, gate the
    /// published artifact in another. The tree is ordinary — a test target whose helper spawns
    /// `/bin/sh` — and the no-policy scan publishes it as `excluded: [{class: "harness-target",
    /// peeked: false}]` with `outOfScope` ABSENT. MEASURED at `258794a`: `scan --policy 'deny Exec'`
    /// exit 2 `{"ok":false,"incomplete":true}` against `gate --report N --policy 'deny Exec'` exit 0
    /// `{"ok":true}` + `policy ✓`, over the same source tree.
    func testGatingANoPolicyReportOfATreeWithUnreadCodeRefuses() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-unread-nopolicy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tests/AppTests"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.target(name: "App"),
                                                     .testTarget(name: "AppTests", dependencies: ["App"])])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func add(_ a: Int) -> Int { a + 1 }\n"
            .write(to: root.appendingPathComponent("Sources/App/Lib.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import XCTest
        func helper() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); try? p.run() }
        """.write(to: root.appendingPathComponent("Tests/AppTests/Helper.swift"),
                  atomically: true, encoding: .utf8)
        try "deny Exec\n".write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        let pol = root.appendingPathComponent("pol.txt").path

        // THE SCAN ROUTE, asked the question: the peek reads the harness target and names the Exec.
        let scan = try ProcessHarness.run(try bin(), [root.path, "--policy", pol, "--out",
                                                      root.appendingPathComponent("P").path], cwd: root)
        XCTAssertEqual(scan.code, 2, "the peek found a denied effect outside the scan's scope: \(scan.err)")

        // …AND THE SAME TREE SCANNED WITH NO POLICY, which is what a CI publishes.
        let n = root.appendingPathComponent("N")
        let bare = try ProcessHarness.run(try bin(), [root.path, "--out", n.path], cwd: root)
        XCTAssertEqual(bare.code, 0, "a bare scan is not a gate: \(bare.err)")
        // THE FIXTURE REACHED THE CODE — assert the exact wire state the rule keys on, so a row that
        // stops firing because the walk changed is distinguishable from one the fix broke.
        let rep = try doc(try String(contentsOf: root.appendingPathComponent("N.App.Swift.json"),
                                     encoding: .utf8))
        let ex = try XCTUnwrap(rep["excluded"] as? [[String: Any]], "\(rep)")
        XCTAssertEqual(ex.first { $0["class"] as? String == "harness-target" }?["peeked"] as? Bool, false,
                       "the no-policy scan must publish the class as UNREAD: \(ex)")
        XCTAssertNil(rep["outOfScope"],
                     "…and it must omit `outOfScope`, which is the absence the old rule keyed on: \(rep)")

        let verdict = root.appendingPathComponent("gate.verdict.json")
        let g = try ProcessHarness.run(try bin(), ["gate", "--report", n.path, "--policy", pol,
                                                   "--gate-json", verdict.path], cwd: root)
        XCTAssertEqual(g.code, 2, "gating a report of code nobody READ cannot be a pass: \(g.err)")
        XCTAssertTrue(g.err.contains("harness-target"), "…and the class must be NAMED: \(g.err)")
        XCTAssertFalse(g.err.contains("policy ✓"), "…and no green tick may precede it: \(g.err)")
        let d = try doc(try String(contentsOf: verdict, encoding: .utf8))
        XCTAssertEqual(d["ok"] as? Bool, false, "the DOCUMENT is the CI's half of the answer: \(d)")
        XCTAssertEqual(d["incomplete"] as? Bool, true, "…and it names WHY: \(d)")
    }

    /// **THE OVER-CHARGE CONTROL WITH THE MOST TO LOSE: an ordinary built SPM tree.** Every package
    /// anyone has ever run `swift build` in carries a `.build/`, which this engine excludes as
    /// `build-output` and deliberately does NOT peek — so it rides every real report as
    /// `peeked: false`. It is also `judgedElsewhere: true` (a derived copy of sources already read),
    /// and if that carve-out ever came off, this rung would start refusing essentially every gate in
    /// the wild. Both routes, over a real scan, with the `.build/` holding code that WOULD trip the
    /// policy if the class were read as unjudged.
    func testAnSpmTreeWithABuildDirectoryStillGatesGreenOnBothRoutes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-unread-buildout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".build/checkouts/dep/Sources"),
                               withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.target(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func add(_ a: Int) -> Int { a + 1 }\n"
            .write(to: root.appendingPathComponent("Sources/App/Lib.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public func spawn() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); try? p.run() }
        """.write(to: root.appendingPathComponent(".build/checkouts/dep/Sources/Dep.swift"),
                  atomically: true, encoding: .utf8)
        try "deny Exec\n".write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        let pol = root.appendingPathComponent("pol.txt").path

        let scanVerdict = root.appendingPathComponent("scan.verdict.json")
        let scan = try ProcessHarness.run(try bin(), [root.path, "--policy", pol,
                                                      "--out", root.appendingPathComponent("P").path,
                                                      "--gate-json", scanVerdict.path], cwd: root)
        XCTAssertEqual(scan.code, 0, "`.build/` is derived and the rest was read: \(scan.err)")
        // THE FIXTURE REACHED THE CODE: the class really is on the wire, really unpeeked, and really
        // carved out by the PRODUCER's flag — otherwise this row would pass over an empty `excluded`.
        let rep = try doc(try String(contentsOf: root.appendingPathComponent("P.App.Swift.json"),
                                     encoding: .utf8))
        let ex = try XCTUnwrap(rep["excluded"] as? [[String: Any]], "\(rep)")
        let bo = try XCTUnwrap(ex.first { $0["class"] as? String == "build-output" }, "\(ex)")
        XCTAssertEqual(bo["peeked"] as? Bool, false, "the peek holds `.build/` back on purpose: \(bo)")
        XCTAssertEqual(bo["judgedElsewhere"] as? Bool, true, "…and says why it is safe to: \(bo)")

        let gateVerdict = root.appendingPathComponent("gate.verdict.json")
        let g = try ProcessHarness.run(try bin(), ["gate", "--report",
                                                   root.appendingPathComponent("P").path, "--policy", pol,
                                                   "--gate-json", gateVerdict.path], cwd: root)
        XCTAssertEqual(g.code, 0, "…and the report route must not start refusing every built package "
                       + "in the world: \(g.err)")
        let a = try Data(contentsOf: scanVerdict), b = try Data(contentsOf: gateVerdict)
        XCTAssertEqual(String(data: a, encoding: .utf8), String(data: b, encoding: .utf8),
                       "§3.1 byte-equality holds on the green side too")
    }
}
