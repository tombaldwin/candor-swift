import XCTest
import Foundation

/// ⟨0.24⟩ `gate --report <locator> --policy <file>` (SPEC §3.1) — apply a policy to an EXISTING report,
/// with no scan.
///
/// PROCESS-LEVEL ON PURPOSE. The verb's contract is MACHINE OUTPUT (an exit code and a `--gate-json`
/// document), so every assertion here runs the SHIPPED binary and parses what it actually wrote. The
/// reference engine found a bug in its own `gate` code that its unit test PASSED against — a `static`
/// had captured stdout at class load, so swapping `System.out` in-process left the trailer going to the
/// real console and the in-process assertion never saw the corrupted document.
final class GateReportVerbProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// A throwaway directory with a `.candor/` report tree written by hand, so a signature can be posed
    /// EXACTLY (which is the whole point of the verb). Returns the root.
    private func makeReportDir(report: String,
                               callgraph: String? = nil,
                               dep: String? = nil,
                               config: String? = nil,
                               policy: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-gate-\(UUID().uuidString)")
        let candor = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candor, withIntermediateDirectories: true)
        try report.write(to: candor.appendingPathComponent("report.App.Swift.json"), atomically: true, encoding: .utf8)
        if let callgraph {
            try callgraph.write(to: candor.appendingPathComponent("report.App.Swift.callgraph.json"),
                                atomically: true, encoding: .utf8)
        }
        if let dep {
            let deps = candor.appendingPathComponent("deps")
            try FileManager.default.createDirectory(at: deps, withIntermediateDirectories: true)
            try dep.write(to: deps.appendingPathComponent("dep.Lib.Swift.json"), atomically: true, encoding: .utf8)
        }
        if let config {
            try config.write(to: candor.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        try policy.write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        return root
    }

    private func envelope(_ fns: String, analyzed: Int = 3, extra: String = "") -> String {
        """
        {"candor":{"spec":"0.23","toolchain":"swiftsyntax","version":"candor-swift-0.23.1"},
         "package":"App","analyzed":{"count":\(analyzed),"digest":"1111111111111111"}\(extra),
         "functions":[\(fns)]}
        """
    }

    private func fnEntry(_ fn: String, _ inferred: [String], calls: [String] = [], why: [String]? = nil,
                       netClass: [String]? = nil, hosts: [String]? = nil) -> String {
        func arr(_ xs: [String]) -> String { "[" + xs.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        var s = """
        {"fn":"\(fn)","loc":"a.swift:1:1","inferred":\(arr(inferred)),"direct":\(arr(inferred)),
         "declared":[],"undeclared":[],"overdeclared":[],"unresolved":\(inferred.contains("Unknown")),
         "hash":"App#\(fn)","calls":\(arr(calls))
        """
        if let why { s += ",\"unknownWhy\":\(arr(why))" }
        if let netClass { s += ",\"netClass\":\(arr(netClass))" }
        if let hosts { s += ",\"hosts\":\(arr(hosts))" }
        return s + "}"
    }

    // ── THE MUST NOT ────────────────────────────────────────────────────────────────────────────────

    /// SPEC §3.1 ⟨0.24⟩: "a report entry that is ABSENT is absent — the ⟨0.21⟩ purity claim — and MUST
    /// NOT be back-filled from a callgraph sidecar or a chained dep."
    ///
    /// `app.Facade.load` is ABSENT from the report. Three baits sit beside it, each on a channel this
    /// codebase really has:
    ///   1. a `.callgraph.json` sidecar sharing the loader's exact glob prefix, naming it and edging it
    ///      to a `Net`-bearing unit (`loadFixModel`, which serves fix/fix-gate/tour/path, merges it);
    ///   2. a chained dep report giving it `Net` outright (`loadDepReports`, Deps.swift, joins these on
    ///      the SCAN path);
    ///   3. a `.candor/config` `deps` key wiring that dep dir in — inside the one directory this verb
    ///      DOES open a config from, so the bait is on the path the code actually walks.
    ///
    /// Under `deny Net app.Facade` the verdict must be CLEAN. Verified by mutation: back-filling from
    /// either the sidecar or the dep flips this to exit 1 (measured, 2026-07-27).
    func testAbsentEntryIsNotBackfilledFromSidecarDepOrConfig() throws {
        let root = try makeReportDir(
            report: envelope(fnEntry("app.Wire.send", ["Net"], netClass: ["unknown-host"], hosts: ["ok.example.com"])),
            callgraph: #"{"app.Facade.load":["app.Wire.send"],"app.Wire.send":[]}"#,
            dep: envelope(fnEntry("app.Facade.load", ["Net"], netClass: ["unknown-host"], hosts: ["evil.example.com"]),
                          analyzed: 1).replacingOccurrences(of: "\"package\":\"App\"", with: "\"package\":\"Lib\""),
            config: "deps .candor/deps\n",
            policy: "deny Net app.Facade\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 0, "an ABSENT entry is the ⟨0.21⟩ purity claim; the sidecar/dep/config baits must not fill it in. stderr: \(r.err)")
    }

    /// THE POSITIVE CONTROL, and it is what stops the test above being a test of a gate that never fires:
    /// the same directory, the same three baits, over a report that DOES carry the effect.
    func testPositiveControlSameBaitsButTheReportCarriesTheEffect() throws {
        let root = try makeReportDir(
            report: envelope(fnEntry("app.Wire.send", ["Net"], netClass: ["unknown-host"], hosts: ["ok.example.com"])
                             + "," + fnEntry("app.Facade.load", ["Net"], netClass: ["unknown-host"], hosts: ["evil.example.com"])),
            callgraph: #"{"app.Facade.load":["app.Wire.send"],"app.Wire.send":[]}"#,
            dep: envelope(fnEntry("app.Facade.load", ["Net"]), analyzed: 1),
            config: "deps .candor/deps\n",
            policy: "deny Net app.Facade\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 1, "the same policy over a report that CARRIES the effect must fail. stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-006"), "and name the rule: \(r.err)")
    }

    // ── ANSWERABILITY: three refusals, each measured as fail-OPEN if approximated ───────────────────

    func testForbidIsRefusedWholePolicy() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Wire.send", ["Net"], netClass: ["unknown-host"])),
                                     policy: "forbid app.Domain -> app.Infra\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 2, "a `forbid` rule the wire cannot answer must be refused, never evaluated")
        XCTAssertTrue(r.err.contains("forbid"), "the message names the offending rule KIND: \(r.err)")
        XCTAssertTrue(r.err.contains("scan time"), "and carries the remedy: \(r.err)")
    }

    /// Whole-policy, not per-rule: enforcing the answerable half and exiting 0 is gateless-green.
    func testAllowIsRefusedEvenBesideAnAnswerableDeny() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Wire.send", ["Net", "Exec"], netClass: ["unknown-host"])),
                                     policy: "deny Net app.Nothing\nallow Exec git\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 2, "the AS-EFF-008 completeness marker does not ride the wire — refuse, don't approximate")
        XCTAssertTrue(r.err.contains("allow"), "the message names the rule kind: \(r.err)")
        XCTAssertTrue(r.err.contains("unknown-host"), "and says why the obvious reconstruction is wrong: \(r.err)")
    }

    /// THE THIRD CASE, and the one that was a LIVE fail-open rather than a theoretical one. Measured on
    /// this engine with the refusal disabled (2026-07-27):
    ///
    ///     deny Net[unknown-host] over a Net entry with NO netClass  -> exit 0   (bare `deny Net` -> 1)
    ///     deny Unknown[dispatch] over an Unknown with no reachable
    ///       reason (no unknownWhy, no `calls` edge)                 -> exit 0   (bare `deny Unknown` -> 1)
    ///
    /// An absent optional field silently un-scoping a fail-closed security gate. The bare arms are
    /// asserted here too, because they are what make the scoped exit-0 a RELAXATION rather than a
    /// signature that simply does not violate.
    func testScopedDenyOverAnAbsentScopingFieldIsRefused() throws {
        let noNetClass = try makeReportDir(report: envelope(fnEntry("app.Sender.send", ["Net"]), analyzed: 1),
                                           policy: "deny Net[unknown-host] app\n")
        defer { try? FileManager.default.removeItem(at: noNetClass) }
        let scoped = try ProcessHarness.run(bin(), ["gate", "--report", noNetClass.path,
                                                    "--policy", noNetClass.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(scoped.code, 2, "a Net entry with no `netClass` cannot answer a destination-scoped deny")
        XCTAssertTrue(scoped.err.contains("deny Net[unknown-host] app"), "names the exact deny LINE: \(scoped.err)")
        XCTAssertTrue(scoped.err.contains("app.Sender.send"), "and the FUNCTION: \(scoped.err)")
        XCTAssertTrue(scoped.err.contains("scan time"), "and the remedy: \(scoped.err)")

        try "deny Net app\n".write(to: noNetClass.appendingPathComponent("bare.txt"), atomically: true, encoding: .utf8)
        let bare = try ProcessHarness.run(bin(), ["gate", "--report", noNetClass.path,
                                                  "--policy", noNetClass.appendingPathComponent("bare.txt").path])
        XCTAssertEqual(bare.code, 1, "the BARE deny fires on the same signature — which is what makes the scoped exit 0 a relaxation")
    }

    func testScopedUnknownDenyWithNoReachableReasonIsRefused() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Caller.run", ["Unknown"]), analyzed: 1),
                                     policy: "deny Unknown[dispatch] app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let scoped = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                    "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(scoped.code, 2, "an Unknown with neither its own unknownWhy nor a `calls` edge to one cannot answer a reason-scoped deny")
        XCTAssertTrue(scoped.err.contains("deny Unknown[dispatch] app"), "names the exact deny line: \(scoped.err)")
        XCTAssertTrue(scoped.err.contains("app.Caller.run"), "and the function: \(scoped.err)")

        try "deny Unknown app\n".write(to: root.appendingPathComponent("bare.txt"), atomically: true, encoding: .utf8)
        let bare = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                  "--policy", root.appendingPathComponent("bare.txt").path])
        XCTAssertEqual(bare.code, 1, "the bare `deny Unknown` fires on the same signature")
    }

    /// PER-(rule, function), not per policy: a scoped rule whose OWN matches carry their evidence still
    /// evaluates. Two entries, one with `netClass` and one without, and a rule scoped to the answerable one.
    func testScopedDenyStillEvaluatesWhenItsOwnMatchesCarryTheEvidence() throws {
        let fns = fnEntry("ok.Sender.send", ["Net"], netClass: ["unknown-host"]) + ","
                + fnEntry("mystery.Sender.send", ["Net"])
        let root = try makeReportDir(report: envelope(fns, analyzed: 2), policy: "deny Net[unknown-host] ok\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 1, "the evidence-less entry is out of this rule's scope, so the rule is answerable and fires. stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("ok.Sender.send"), "on the answerable entry: \(r.err)")
    }

    // ── EQUIVALENCE with `scan --policy` — the acceptance test, and it is BYTE-LEVEL ────────────────

    /// SPEC §3.1 ⟨0.24⟩: "For any report a scan produced, `gate --report <it> --policy P` MUST produce a
    /// `--gate-json` document BYTE-EQUAL to `scan --policy P`'s — `analyzed.count`, `reasonClass`,
    /// `netClass` and the coverage advisory included."
    ///
    /// A representative slice here (the full sweep is 80 rows over four corpora, run out of tree); this
    /// fixture is built so the `netClass` and `reasonClass` arms of the verdict are non-vacuous.
    func testGateJsonIsByteEqualToTheScanRoute() throws {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func reachesNet() { URLSession.shared.dataTask(with: URL(string: "https://api.example.com/x")!).resume() }
        @dynamicMemberLookup struct Bag { subscript(dynamicMember m: String) -> String { m } }
        func viaReflect(_ b: Bag) -> String { return b.anything }
        protocol Port { func go() }
        func viaPort(_ p: Port) { p.go() }
        func readsFile() { _ = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) }
        func all(_ b: Bag, _ p: Port) { reachesNet(); _ = viaReflect(b); viaPort(p); readsFile() }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let cfg = root.appendingPathComponent("cfg")
        try "".write(to: cfg, atomically: true, encoding: .utf8)   // pin BOTH routes to the same config

        let policies = ["pure", "deny Net", "deny Fs", "deny Unknown", "deny Net Unknown",
                        "deny Net Unknown[dispatch]", "deny Fs Unknown[reflect,unresolved]",
                        "deny Net[unknown-host]", "deny Clipboard", "pure ZzzNoSuchScope",
                        "deny Net\ndeny Fs\ndeny Unknown[dynamic,unresolved]", "deny Db Ipc"]
        for (i, text) in policies.enumerated() {
            let pol = root.appendingPathComponent("p\(i)")
            try (text + "\n").write(to: pol, atomically: true, encoding: .utf8)
            let scanV = root.appendingPathComponent("scan\(i).json")
            let gateV = root.appendingPathComponent("gate\(i).json")
            for u in [scanV, gateV] { try? FileManager.default.removeItem(at: u) }   // delete before measuring

            let s = try ProcessHarness.run(bin(), [root.path, "--out", root.appendingPathComponent("r").path,
                                                   "--policy", pol.path, "--gate-json", scanV.path],
                                           env: ["CANDOR_CONFIG": cfg.path])
            let g = try ProcessHarness.run(bin(), ["gate", "--report", root.appendingPathComponent("r").path,
                                                   "--policy", pol.path, "--gate-json", gateV.path],
                                           env: ["CANDOR_CONFIG": cfg.path])
            XCTAssertEqual(s.code, g.code, "exit codes must match for `\(text)` (scan \(s.code) vs gate \(g.code))")
            let a = try Data(contentsOf: scanV), b = try Data(contentsOf: gateV)
            XCTAssertEqual(a, b, "the two --gate-json documents must be BYTE-EQUAL for `\(text)`:\n"
                           + "scan: \(String(decoding: a, as: UTF8.self))\ngate: \(String(decoding: b, as: UTF8.self))")
            XCTAssertFalse(g.err.contains("cannot evaluate"), "no refusal may fire on a self-produced report: \(g.err)")
        }
    }

    /// `--json` IS `--gate-json -`: the verb's machine output is the VERDICT (a scan's `--json` writes the
    /// report, and there is no report to write here). Asserted on the SHIPPED binary's stdout, parsed —
    /// a stray prose line on stdout is exactly the class this cannot be trusted to catch in-process.
    func testJsonIsGateJsonDashAndStdoutIsOneCleanDocument() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Wire.send", ["Net"], netClass: ["unknown-host"]), analyzed: 1),
                                     policy: "deny Net app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("pol.txt").path
        let viaJson = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", pol, "--json"])
        let viaDash = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", pol, "--gate-json", "-"])
        XCTAssertEqual(viaJson.out, viaDash.out, "`--json` must be exactly `--gate-json -`")
        XCTAssertEqual(viaJson.code, 1)
        let d = try JSONSerialization.jsonObject(with: Data(viaJson.out.utf8)) as? [String: Any]
        XCTAssertEqual(d?["ok"] as? Bool, false, "stdout is ONE verdict document, uncorrupted by prose: \(viaJson.out)")
        XCTAssertEqual((d?["violations"] as? [Any])?.count, 1)
        XCTAssertTrue(viaJson.err.contains("policy violation"), "the prose went to stderr: \(viaJson.err)")
    }

    // ── grammar + fail-loud ─────────────────────────────────────────────────────────────────────────

    func testStrayPositionalIsAUsageError() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Wire.send", ["Net"], netClass: ["unknown-host"]), analyzed: 1),
                                     policy: "deny Net app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", root.path, "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 2, "`gate` takes no positionals — a swallowed token is how a gate runs green")
        XCTAssertTrue(r.err.contains("unexpected argument"), r.err)
    }

    func testGateJsonCannotSwallowTheNextFlag() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Wire.send", ["Net"], netClass: ["unknown-host"]), analyzed: 1),
                                     policy: "deny Net app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--gate-json", "--policy",
                                               root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 2, "`--gate-json --policy p` must fail, not eat the policy and run gateless-green")
        // The MESSAGE matters, not just the exit: without the dash-check `--gate-json` swallows `--policy`
        // and the policy PATH lands as a stray positional, so the run still exits 2 — for the wrong reason,
        // and one `--gate-json <path> --policy p` reordering away from being green.
        XCTAssertTrue(r.err.contains("--gate-json requires a value"),
                      "the dash-check must be what rejects it, not the stray-positional guard: \(r.err)")
    }

    func testUnreadablePolicyAndMissingPolicyBothExit2() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Wire.send", ["Net"], netClass: ["unknown-host"]), analyzed: 1),
                                     policy: "deny Net app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", root.path + "/nope"])
        XCTAssertEqual(missing.code, 2, "an unreadable policy is exit 2, policy NOT evaluated")
        let none = try ProcessHarness.run(bin(), ["gate", "--report", root.path], cwd: root)
        XCTAssertEqual(none.code, 2, "no policy at all is exit 2, never a silent green")
    }

    /// SPEC §3.1's found-but-corrupt rule: a report with no `functions` key is corrupt input, not an
    /// effect-free package. Gating it green would be the §4 false all-clear.
    func testCorruptReportIsRefusedNotReadAsEmpty() throws {
        let root = try makeReportDir(report: #"{"candor":{"spec":"0.23"},"package":"App"}"#,
                                     policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 2, "a report with no `functions` array must fail loud, never gate green")
        XCTAssertTrue(r.err.contains("functions"), r.err)
    }

    /// ⟨0.21⟩ COMPLETENESS MANIFEST: the report DECLARES units candor could not analyze, so a gate over it
    /// cannot certify — exit 2, and the verdict carries `incomplete` + `unanalyzed` for a machine reader.
    func testAnIncompleteReportCannotBeGreen() throws {
        let root = try makeReportDir(
            report: envelope(fnEntry("app.Wire.send", ["Log"]), analyzed: 2,
                             extra: #","unanalyzed":[{"path":"Sources/App/locked.swift","reason":"source failed to read"}]"#),
            policy: "deny Net app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("v.json")
        try? FileManager.default.removeItem(at: v)
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path,
                                               "--gate-json", v.path])
        XCTAssertEqual(r.code, 2, "a gate cannot be green over unanalyzed code: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
        XCTAssertEqual(d?["ok"] as? Bool, false)
        XCTAssertEqual(d?["incomplete"] as? Bool, true, "the incompleteness is machine-legible in the verdict")
        XCTAssertEqual((d?["unanalyzed"] as? [Any])?.count, 1)
    }

    // ── ⟨0.24⟩ A REPORT THAT JUDGED NOTHING (SPEC §2's three-row table, bound to this verb by §3.1) ──
    //
    // MEASURED before the fix, on a count-0 report with `deny Net`: exit 0, stdout empty, stderr exactly
    // `candor-swift: policy ✓` — the literal §3.1 forbids, with no trace anywhere that the gate had judged
    // nothing at all. The reading is a DISCLOSURE, not an exit code: §3.1's byte-equality MUST binds the
    // gate route to `scan --policy`, and a scan of an empty facade package exits 0 with a clean verdict,
    // so moving the exit code or the document here would split the verb. §3.3 also enumerates exactly two
    // exit-2 causes and a judged-nothing dependency is neither.

    /// The FLOOR arm. `analyzed.count: 0` with `functions: []` — nothing was judged, so the caveat MUST
    /// fire on stderr while the exit code and the `--gate-json` document stay exactly where they were.
    func testACountZeroReportGetsALoudCaveatButKeepsItsExitCodeAndVerdict() throws {
        let root = try makeReportDir(report: envelope("", analyzed: 0), policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("v.json")
        try? FileManager.default.removeItem(at: v)
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path,
                                               "--gate-json", v.path])
        XCTAssertEqual(r.code, 0, "the exit code is UNMOVED — §3.1's byte-equality MUST binds this route to "
                       + "`scan --policy`, and a scan of an empty facade package exits 0: \(r.err)")
        XCTAssertTrue(r.err.contains("judged NOTHING"),
                      "…and the disclosure is what changes: a human reading `policy ✓` must be told the "
                      + "gate judged nothing. stderr was: \(r.err)")
        XCTAssertTrue(r.err.contains("certifies NOTHING"), "the caveat must say what it MEANS: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
        XCTAssertEqual(d?["ok"] as? Bool, true, "the verdict document is UNMOVED too — a refusal here would "
                       + "assert an effect the consumer has no evidence for: \(d ?? [:])")
        XCTAssertEqual((d?["analyzed"] as? [String: Any])?["count"] as? Int, 0,
                       "the machine channel was already correct and stays correct: \(d ?? [:])")
    }

    /// THE CONTROL, WITHOUT WHICH THE ROW ABOVE IS A TEST OF AN UNCONDITIONAL PRINT. The same empty
    /// `functions` list with `analyzed.count: 3` is a legitimate all-pure claim §2 rule 3 says a consumer
    /// SHOULD believe — one integer apart, and the caveat must NOT fire. A fix that caveated both would
    /// have disabled the reading, not implemented it.
    func testAnAllPureReportWithAJudgedCountGetsNoCaveat() throws {
        let root = try makeReportDir(report: envelope("", analyzed: 3), policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertFalse(r.err.contains("judged NOTHING"),
                       "`count: 3` with `functions: []` is a POSITIVE all-pure claim and must not be hedged: \(r.err)")
    }

    /// The unreadable-manifest rows reach the same advisory, because a claim that cannot be READ is not a
    /// claim (SPEC §2 ⟨0.24⟩ + the present-but-unparseable rule). `count: true` is the one that was live in
    /// this engine — Foundation bridges it through `as? Int` as `1` — and it must neither be believed here
    /// nor put a fabricated `1` in the verdict document's `analyzed.count`.
    func testAnUnreadableCountIsNotAJudgmentClaimAndNeverReachesTheVerdict() throws {
        for (name, count) in [("boolean", "true"), ("fractional", "2.5"), ("negative", "-1"), ("string", "\"2\"")] {
            let report = """
            {"candor":{"spec":"0.23","toolchain":"swiftsyntax","version":"candor-swift-0.23.1"},
             "package":"App","analyzed":{"count":\(count),"digest":"1111111111111111"},"functions":[]}
            """
            let root = try makeReportDir(report: report, policy: "deny Net\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let v = root.appendingPathComponent("v.json")
            try? FileManager.default.removeItem(at: v)
            let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                   "--policy", root.appendingPathComponent("pol.txt").path,
                                                   "--gate-json", v.path])
            XCTAssertTrue(r.err.contains("judged NOTHING"),
                          "\(name): a `count` that cannot be read is not a judgment claim: \(r.err)")
            let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
            XCTAssertEqual((d?["analyzed"] as? [String: Any])?["count"] as? Int, 0,
                           "\(name): an unreadable count must contribute NOTHING to the verdict's own "
                           + "`analyzed.count` — a fabricated number in the machine channel is the mirror "
                           + "of the missing disclosure: \(d ?? [:])")
        }
    }

    /// The §3.3.1 locator, all three forms, over the same report — a dir, the full `.json` path, and the
    /// bare prefix must reach the same verdict (`gate` inherits the grammar, it does not redefine it).
    func testAllThreeLocatorFormsReachTheSameVerdict() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Wire.send", ["Net"], netClass: ["unknown-host"]), analyzed: 1),
                                     policy: "deny Net app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("pol.txt").path
        let full = root.appendingPathComponent(".candor/report.App.Swift.json").path
        let prefix = root.appendingPathComponent(".candor/report").path
        for locator in [root.path, full, prefix] {
            let r = try ProcessHarness.run(bin(), ["gate", "--report", locator, "--policy", pol])
            XCTAssertEqual(r.code, 1, "locator form `\(locator)` must reach the same verdict: \(r.err)")
        }
    }
}
