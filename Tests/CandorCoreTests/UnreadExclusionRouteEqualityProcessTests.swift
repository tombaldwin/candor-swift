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
/// THE SUBTLETY, and the reason four of these six rows are OVER-CHARGE CONTROLS: `peeked: false` has two
/// causes and only one of them licenses a refusal — "the peek opened those files and could not read
/// them" (unread code: refuse) versus "no peek ran, because nothing was asked" (an absence of QUESTION:
/// do not). ⟨0.29⟩ already separates them, in the `outOfScope` key: OMITTED when no policy was
/// configured, present-and-empty when one was and the peek came back clean. Reading `peeked` without
/// that conjunct fails every pre-⟨0.30⟩ report and every no-policy report on contact.
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
    private func envelope(excluded: String?, outOfScope: String?) -> String {
        var extra = ""
        if let excluded { extra += ",\"excluded\":\(excluded)" }
        if let outOfScope { extra += ",\"outOfScope\":\(outOfScope)" }
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
    func testAFullyPeekedReportStillGatesGreen() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":true,"reason":"tests"}]"#,
                               outOfScope: "[]"),
            policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("verdict.json")
        let r = try gate(root, verdict: v)
        XCTAssertEqual(r.code, 0, "the peek read every excluded class and found nothing — nothing is "
                       + "unread, so there is nothing to refuse over: \(r.err)")
        let d = try doc(try String(contentsOf: v, encoding: .utf8))
        XCTAssertEqual(d["ok"] as? Bool, true, "…and the DOCUMENT must say so too: \(d)")
        XCTAssertNil(d["incomplete"], "a complete verdict carries no `incomplete` key: \(d)")
    }

    /// CONTROL 2 — NOTHING WAS ASKED, SO NOTHING IS OWED. A report produced WITHOUT a policy omits
    /// `outOfScope` (⟨0.29⟩) and marks every class `peeked: false`, because no peek ran. Refusing here
    /// would make every pre-⟨0.30⟩ report and every no-policy report exit 2 the moment a policy touched
    /// it — the failure candor-java measured before it added the same conjunct.
    func testAReportProducedWithNoPolicyDoesNotRefuse() throws {
        let root = try makeReportDir(
            envelope: envelope(excluded: #"[{"class":"harness-target","count":2,"peeked":false,"reason":"tests"}]"#,
                               outOfScope: nil),
            policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("verdict.json")
        let r = try gate(root, verdict: v)
        XCTAssertEqual(r.code, 0, "`outOfScope` is ABSENT — the producing scan was never asked, so "
                       + "`peeked: false` records an absence of QUESTION, not of evidence: \(r.err)")
        let d = try doc(try String(contentsOf: v, encoding: .utf8))
        XCTAssertEqual(d["ok"] as? Bool, true, "…and the DOCUMENT must say so too: \(d)")
    }

    /// CONTROL 3 — A DERIVED EXCLUSION HIDES NOTHING. `judgedElsewhere` is the PRODUCER's statement that
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

    /// CONTROL 4 — THE CARVE-OUT IS READ OFF THE PRODUCER, NOT OFF THE CLASS TOKEN. The same concept is
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

    // ── THE DEFECT ────────────────────────────────────────────────────────────────────────────────

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
}
