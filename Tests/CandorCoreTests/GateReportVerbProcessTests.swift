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

    /// `direct` DEFAULTS to `inferred` — the ordinary entry, whose effects it raises itself — and is
    /// overridable because ⟨0.24⟩ made the distinction load-bearing: §6.2's contribution fires on a
    /// DIRECT `Unknown` the entry named no reason for, and never on an INHERITED one. A fixture that
    /// leaves this defaulted is posing a direct effect whether it means to or not.
    private func fnEntry(_ fn: String, _ inferred: [String], calls: [String] = [], why: [String]? = nil,
                       netClass: [String]? = nil, hosts: [String]? = nil, direct: [String]? = nil) -> String {
        func arr(_ xs: [String]) -> String { "[" + xs.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        var s = """
        {"fn":"\(fn)","loc":"a.swift:1:1","inferred":\(arr(inferred)),"direct":\(arr(direct ?? inferred)),
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

    /// ⟨0.24⟩ THE FIXTURE MOVED, AND THE MOVE IS THE POINT. It used to pose `app.Caller.run` with
    /// `direct: ["Unknown"]` — because the helper defaults `direct` to `inferred` — while its prose said
    /// "an Unknown with neither its own unknownWhy nor a `calls` edge". Those are two different states,
    /// and the minimal-refusal rule (SPEC §3.1) separates them: a reasonless DIRECT `Unknown` CONTRIBUTES
    /// `unresolved` from the entry alone, so it is ANSWERABLE and this refusal is over-broad on it (pinned
    /// now by `testAReasonlessDirectUnknownIsAnsweredNotRefused`). The genuinely uncomputable state is the
    /// INHERITED one — `direct: []`, no `calls` — where the reason lives in a callee the report does not
    /// name, and it is the one this test now poses. The fixture had picked one spelling of two.
    func testScopedUnknownDenyWithNoReachableReasonIsRefused() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Caller.run", ["Unknown"], direct: []), analyzed: 1),
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

    // ── ⟨0.24⟩ THE REFUSAL IS MINIMAL (SPEC §3.1) ───────────────────────────────────────────────────
    //
    // A class-scoped `deny` is not unanswerable merely because some evidence is missing. The class set
    // only ever GROWS (§6.2 — a reason is CONTRIBUTED, never retracted) and `Reject` is upward-closed in
    // it (PAPER3 Lemma 2), so when the classes determinable FROM THE ENTRY ALONE already intersect the
    // filter, the rule FIRES and no further evidence could change that. Only an EMPTY determinable set is
    // genuinely open.
    //
    // MEASURED four-way on the review's fixture, one entry, `direct: ["Unknown"]`, no `unknownWhy`, no
    // `calls`, all four binaries rebuilt at HEAD:
    //
    //     deny Unknown[unresolved]              rust 1   ts 1   java 1   swift 2   <- over-broad
    //     deny Unknown[unresolved] app.direct   rust 1   ts 1   java 1   swift 2   <- and with a scope
    //
    // SPEC §3.1 names this engine's refusal as the over-broad one: exit 2 is not wrong in the fail-closed
    // sense, it is a WORSE answer than the correct one.

    /// A reasonless DIRECT `Unknown` CONTRIBUTES `unresolved` (§6.2), which is determinable from the entry
    /// alone with no transitive step — so `deny Unknown[unresolved]` is ANSWERED, and the answer is that
    /// it fires. Both the bare and the scoped form, because the review measured both at exit 2.
    func testAReasonlessDirectUnknownIsAnsweredNotRefused() throws {
        let entry = """
        {"fn":"app.direct","loc":"a.swift:1:1","inferred":["Unknown"],"direct":["Unknown"],
         "declared":[],"undeclared":[],"overdeclared":[],"unresolved":true,"hash":"App#direct"}
        """
        for rule in ["deny Unknown[unresolved]", "deny Unknown[unresolved] app.direct"] {
            let root = try makeReportDir(report: envelope(entry, analyzed: 1), policy: rule + "\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                   "--policy", root.appendingPathComponent("pol.txt").path])
            XCTAssertEqual(r.code, 1, "`\(rule)`: a reasonless DIRECT Unknown contributes `unresolved` from "
                           + "the entry ALONE, so the question is answerable and the answer is that the rule "
                           + "fires. Refusing is a worse answer than the correct one (SPEC §3.1). stderr: \(r.err)")
            XCTAssertTrue(r.err.contains("app.direct"), "`\(rule)`: and it names the function: \(r.err)")
        }
    }

    /// THE CONTROL FOR THE ROW ABOVE, and the one the fix must NOT swallow: an `Unknown` that is INHERITED
    /// with no `calls` edge to a reason is still the uncomputable state, and must still be refused. Its
    /// `direct` set does not contain `Unknown`, which is exactly what separates the two — keying the
    /// contribution on the reason set being EMPTY instead would mark this one too, and that is the mirror
    /// fabrication (measured elsewhere at 435 functions where the legitimate count is 0).
    ///
    /// THE REFUSAL MUST ALSO NAME THE RIGHT FUNCTION. Three Unknown carriers here: `app.mystery` raises it
    /// directly with no reason (→ `unresolved`), `app.inheritU` inherits it through a `calls` edge to
    /// `app.mystery` (→ `unresolved`, transitively), and `app.orphanU` inherits it from NOWHERE the report
    /// names. Only the third is unanswerable. MEASURED before the fix: swift refused naming `app.inheritU`
    /// where rust, ts and java all name `app.orphanU` — the same exit code, with the remedy pointing at
    /// the wrong function.
    ///
    /// ⟨0.24⟩ **THE EXIT MOVED FROM 2 TO 1 UNDER THE PRECEDENCE CORRECTION, and that is the ruling
    /// working, not a regression.** This same policy FIRES on `app.mystery` and `app.inheritU` — both
    /// contribute `unresolved` from evidence the report carries — so the policy is Rejected, `Reject` is
    /// upward-closed (PAPER3 Lemma 2), and whatever `app.orphanU` would have resolved to cannot un-reject
    /// it (SPEC §3.1, candor-spec `7271c69`). The property this row exists for is UNCHANGED and still
    /// asserted: the refusal disclosure must name the entry whose reason channel is actually missing. It
    /// is now read off the refusal LINES specifically, because the violation lines legitimately name the
    /// other two and a whole-stderr `contains` can no longer tell the two channels apart.
    func testTheRefusalNamesTheEntryWhoseReasonChannelIsActuallyMissing() throws {
        let entries = [
            #"{"fn":"app.mystery","loc":"a.swift:1:1","inferred":["Unknown"],"direct":["Unknown"],"declared":[],"undeclared":[],"overdeclared":[],"unresolved":true,"hash":"App#mystery"}"#,
            #"{"fn":"app.inheritU","loc":"a.swift:5:1","inferred":["Unknown"],"direct":[],"declared":[],"undeclared":[],"overdeclared":[],"unresolved":false,"hash":"App#inheritU","calls":["app.mystery"]}"#,
            #"{"fn":"app.orphanU","loc":"a.swift:9:1","inferred":["Unknown"],"direct":[],"declared":[],"undeclared":[],"overdeclared":[],"unresolved":false,"hash":"App#orphanU"}"#,
        ].joined(separator: ",")
        let root = try makeReportDir(report: envelope(entries, analyzed: 3),
                                     policy: "deny Unknown[dispatch,unresolved]\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 1, "the same policy FIRES on the two entries that DO contribute a class, so "
                       + "a certain violation dominates the unanswerable third (SPEC §3.1). stderr: \(r.err)")
        // The refusal LINES only — the violation lines legitimately name the other two entries.
        let refusalLines = r.err.split(separator: "\n").filter { $0.contains("narrows on the Unknown REASON CLASS") }
        XCTAssertEqual(refusalLines.count, 1, "exactly one rule went unanswered: \(r.err)")
        let refusal = refusalLines.joined()
        XCTAssertTrue(refusal.contains("app.orphanU"),
                      "the refusal must name the entry whose reason channel is ACTUALLY missing — a remedy "
                      + "pointing at the wrong function is worth as little as no remedy: \(refusal)")
        XCTAssertFalse(refusal.contains("app.inheritU"),
                       "`app.inheritU` reaches `app.mystery`'s contributed `unresolved` through its own "
                       + "`calls` edge, so it is not the unanswerable one: \(refusal)")
        XCTAssertFalse(refusal.contains("app.mystery"),
                       "…and `app.mystery` contributes `unresolved` from its own DIRECT Unknown: \(refusal)")
        // …and the unanswered rule is still DISCLOSED beside the verdict it is not part of.
        XCTAssertTrue(r.err.contains("could not be evaluated"),
                      "exit 1 reports the violation it is sure of; it does not conceal the part it could "
                      + "not read (SPEC §3.1): \(r.err)")
    }

    /// The anti-flood control on the other side: a narrowed filter that does NOT include `unresolved` must
    /// not be made to fire by the contribution. `unresolved` is a real class now, not a stand-in for "no
    /// class", so `deny Unknown[dispatch]` over a reasonless direct Unknown is ANSWERED — and the answer
    /// is that it does not fire.
    func testTheContributedUnresolvedDoesNotSatisfyAnUnrelatedClassFilter() throws {
        let entry = """
        {"fn":"app.direct","loc":"a.swift:1:1","inferred":["Unknown"],"direct":["Unknown"],
         "declared":[],"undeclared":[],"overdeclared":[],"unresolved":true,"hash":"App#direct"}
        """
        let root = try makeReportDir(report: envelope(entry, analyzed: 1), policy: "deny Unknown[dispatch]\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 0, "`unresolved` is a real class, not a wildcard — `[dispatch]` must not be "
                       + "satisfied by it, or every narrowed filter matches everything: \(r.err)")
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

    /// ⟨0.24⟩ A KEY THAT IS PRESENT BUT UNPARSEABLE IS CORRUPT INPUT AND IS NEVER COERCED TO ITS EMPTY
    /// VALUE (SPEC §2, candor-spec `38ba3e2`). On every key in this format the language's convenience
    /// default is the PERMISSIVE value (`0`, `[]`, absent), so a reader that recovers from a type mismatch
    /// by substituting it converts corrupt input into a claim — and the claim is always the safe-looking
    /// one. MEASURED before the fix, `deny Net` over each of these, all four binaries rebuilt at HEAD:
    ///
    ///     entry with NO `fn`, `inferred: ["Net"]`   rust 2   ts 2   java 2   swift 0   <- silently dropped
    ///     entry with `inferred: [1]`                rust 2   ts 0   java 0   swift 0   <- three fail open
    ///
    /// The first row is the cardinal-sin shape exactly: a CORRUPT entry became an ABSENT one, and under
    /// ⟨0.21⟩ absent is a positive purity claim. Each row here carries an effect the policy denies, so a
    /// pass can only come from the entry having been dropped — which is what makes the exit code the test.
    func testAPresentButUnparseableKeyIsRefusedNotCoercedToEmpty() throws {
        let cases: [(String, String, String)] = [
            ("no fn key", #"{"loc":"a.swift:1:1","inferred":["Net"],"direct":["Net"],"hash":"App#x"}"#, "`fn`"),
            ("fn not a string", #"{"fn":7,"inferred":["Net"],"direct":["Net"],"hash":"App#x"}"#, "`fn`"),
            ("fn empty", #"{"fn":"","inferred":["Net"],"direct":["Net"],"hash":"App#x"}"#, "`fn`"),
            ("inferred holds a number", #"{"fn":"app.bad","inferred":[1],"direct":[1],"hash":"App#bad"}"#, "app.bad"),
            ("inferred is a bare string", #"{"fn":"app.bad","inferred":"Net","direct":["Net"],"hash":"App#bad"}"#, "app.bad"),
            ("calls holds a number", #"{"fn":"app.bad","inferred":["Net"],"direct":["Net"],"calls":[3],"hash":"App#bad"}"#, "app.bad"),
            ("netClass is an object", #"{"fn":"app.bad","inferred":["Net"],"direct":["Net"],"netClass":{},"hash":"App#bad"}"#, "app.bad"),
            ("unknownWhy holds null", #"{"fn":"app.bad","inferred":["Unknown"],"direct":["Unknown"],"unknownWhy":[null],"hash":"App#bad"}"#, "app.bad"),
        ]
        for (name, entry, mustName) in cases {
            let root = try makeReportDir(report: envelope(entry, analyzed: 1), policy: "deny Net Unknown\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                   "--policy", root.appendingPathComponent("pol.txt").path])
            XCTAssertEqual(r.code, 2, "\(name): a corrupt entry silently becoming an absent one is a ⟨0.21⟩ "
                           + "purity claim about a function the report was trying to tell you about. stderr: \(r.err)")
            XCTAssertTrue(r.err.contains(mustName),
                          "\(name): the refusal must NAME what it could not read (\(mustName)): \(r.err)")
        }
    }

    /// THE CONTROL. An ABSENT key still takes its documented default — that is the distinction the rule
    /// turns on, and conflating absent with present-but-unparseable would refuse every legitimate report.
    /// A minimal §2 entry carries `fn` and `inferred` and nothing else; it must gate normally, both ways.
    func testAnAbsentOptionalKeyStillTakesItsDefault() throws {
        let bare = #"{"fn":"app.Wire.send","inferred":["Net"],"hash":"App#send"}"#
        let root = try makeReportDir(report: envelope(bare, analyzed: 1), policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let deny = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                  "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(deny.code, 1, "an entry with no `direct`/`calls`/`hosts`/… is ordinary, not corrupt: \(deny.err)")
        try "deny Fs\n".write(to: root.appendingPathComponent("fs.txt"), atomically: true, encoding: .utf8)
        let clean = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                  "--policy", root.appendingPathComponent("fs.txt").path])
        XCTAssertEqual(clean.code, 0, "…and it is not refused for a rule it simply does not violate: \(clean.err)")
    }

    /// `unanalyzed` IS THE SHARPEST CASE, because its NON-EMPTINESS is the fail-closed trigger: read as
    /// empty, `NOT certified` (exit 2) becomes `policy ✓` (exit 0). Both spellings candor-spec `38ba3e2`
    /// measured — a bare string list, and the right shape under the wrong field names, which is exactly
    /// what a hand-built or foreign-produced report yields.
    func testAnUnparseableUnanalyzedCannotBecomeAnEmptyOne() throws {
        for (name, raw) in [("bare string list", #"["Sources/App/locked.swift"]"#),
                            ("wrong field names", #"[{"unit":"App.x","why":"unreadable"}]"#),
                            ("not a list", #""oops""#)] {
            let root = try makeReportDir(
                report: envelope(fnEntry("app.Wire.send", ["Log"]), analyzed: 2,
                                 extra: ",\"unanalyzed\":\(raw)"),
                policy: "deny Net\n")
            defer { try? FileManager.default.removeItem(at: root) }
            let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                   "--policy", root.appendingPathComponent("pol.txt").path])
            XCTAssertEqual(r.code, 2, "\(name): a completeness declaration that cannot be read is still a "
                           + "declaration — reading it as an empty list is how a report saying it could not "
                           + "read its own source gates green. stderr: \(r.err)")
            XCTAssertTrue(r.err.contains("unanalyzed"), "\(name): and the refusal names the key: \(r.err)")
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

    // ── ⟨0.24⟩ PRECEDENCE: a CERTAIN violation dominates a refusal (SPEC §3.1) ──────────────────────

    /// **THE HARM IS IN THE DOCUMENT, NOT THE EXIT CODE**, so this test asserts the document.
    ///
    /// One policy, two rules: `deny Fs` FIRES on evidence the report carries, and
    /// `deny Net[unknown-host] app` is unanswerable (the `Net` entry has no `netClass`). MEASURED on this
    /// engine before the fix (2026-07-28):
    ///
    ///     deny Fs                                  ->  exit 1, document names `app.writes`
    ///     deny Net[unknown-host] app               ->  exit 2, no document
    ///     BOTH IN ONE POLICY                       ->  exit 2, NO DOCUMENT AT ALL
    ///
    /// The third row deleted a CERTAIN violation from the machine-consumer channel — byte-identical in
    /// harm to the ⟨0.21⟩ incomplete-analysis path. `Reject` is upward-closed (PAPER3 Lemma 2), so however
    /// the unanswerable rule would have resolved cannot un-reject a policy a firing rule already rejected:
    /// exit 1 is CERTAIN there, not merely fail-closed, and it names the violation where exit 2 names
    /// nothing (candor-spec `7271c69`, which corrects its own ruling of an hour earlier).
    ///
    /// THE TWO CONTROLS ARE NOT OPTIONAL. Without the refuse-only row this cannot tell "the violation
    /// dominated the refusal" from "the scoped rule was answerable all along and there was never a refusal
    /// to dominate"; without the fire-only row a gate that has stopped evaluating anything scores OK.
    /// A broken invocation returns ONE code; these three demand 1, 2 and 1.
    func testACertainViolationDominatesARefusalAndTheDocumentCarriesIt() throws {
        let fns = fnEntry("app.writes", ["Fs"]) + "," + fnEntry("app.calls", ["Net"])
        let root = try makeReportDir(report: envelope(fns, analyzed: 2),
                                     policy: "deny Fs\ndeny Net[unknown-host] app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        func policyFile(_ name: String, _ text: String) throws -> String {
            let u = root.appendingPathComponent(name)
            try text.write(to: u, atomically: true, encoding: .utf8)
            return u.path
        }
        // CONTROL 1 — the firing rule ALONE fires.
        let fireOnly = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                      "--policy", try policyFile("fire.txt", "deny Fs\n")])
        XCTAssertEqual(fireOnly.code, 1, "control: `deny Fs` alone must fire, else the fixture is inert. stderr: \(fireOnly.err)")
        // CONTROL 2 — the unanswerable rule ALONE still refuses, so there IS a refusal to dominate.
        let refuseOnly = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                        "--policy", try policyFile("refuse.txt", "deny Net[unknown-host] app\n")])
        XCTAssertEqual(refuseOnly.code, 2, "control: the scoped rule alone must still refuse. stderr: \(refuseOnly.err)")

        // THE ROW. Delete the document before measuring — a stale artifact here reads as a pass.
        let v = root.appendingPathComponent("v.json")
        try? FileManager.default.removeItem(at: v)
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path,
                                               "--gate-json", v.path])
        XCTAssertEqual(r.code, 1, "a rule FIRED on evidence the report carries; an unanswered rule cannot "
                       + "un-reject a rejected policy (Lemma 2). stderr: \(r.err)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v.path),
                      "the verdict document must exist — its absence IS the harm this row is about")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
        XCTAssertEqual(d?["ok"] as? Bool, false)
        let vs = d?["violations"] as? [[String: Any]] ?? []
        XCTAssertEqual(vs.count, 1, "the CERTAIN finding must survive into the machine channel: \(String(describing: d))")
        XCTAssertEqual(vs.first?["fn"] as? String, "app.writes",
                       "and it must NAME the function — an exit-code-only assertion passes on a route that "
                       + "exits 1 with `violations: []`")
        // …and the part it could not read is still disclosed. Exit 1 reports the violation it is sure of;
        // it does not conceal the unanswered rule (SPEC §3.1).
        XCTAssertTrue(r.err.contains("deny Net[unknown-host] app"),
                      "the unanswered rule must still be named on stderr: \(r.err)")
    }

    /// ⟨0.24⟩ **THE PRECEDENCE FIX INTRODUCED A FABRICATION, AND THIS ROW IS THE ONE THAT CATCHES IT**
    /// (SPEC §3.1, candor-spec `5a8cf48` — found by implementing `7271c69`, not by reading it).
    ///
    /// Removing the refusal's short-circuit made the evaluator reach code it had never reached. The
    /// reason-class matcher floored an unknown class set at `unresolved`, so a scoped
    /// `deny Unknown[unresolved]` over an entry whose `Unknown` is INHERITED and reasonless began
    /// emitting an actual VIOLATION RECORD. MEASURED on this engine after the precedence commit and
    /// before this one, one entry (`app.orphanU`, `inferred: [Unknown]`, `direct: []`, no `calls`):
    ///
    ///     exit 1, violations: [{fn: "app.orphanU", …}]
    ///     …in the SAME run whose stderr said `deny Unknown[unresolved] app.orphanU` could not be
    ///     evaluated over that function. A self-contradicting document.
    ///
    /// That floor is the right fail-closed default for a MATCHER ("could this rule apply?") and the wrong
    /// basis for a FIRING ("did it?"); the two questions shared one helper safely only while the refusal
    /// short-circuited before the difference could show. **A fail-closed default is not portable between a
    /// predicate that GUARDS and one that CHARGES.**
    ///
    /// THE SHARP ROW IS THE SECOND ONE: the SAME rule fires on one function and is withheld on another,
    /// in one run. Whole-policy withholding cannot express that, and a fixture with only the withheld
    /// function cannot tell "withheld correctly" from "the gate stopped working".
    func testAWithheldRuleIsNotChargedOnADefaultNobodyRecorded() throws {
        // ROW 1 — the withheld function ALONE. No violation may be manufactured for it.
        let sole = try makeReportDir(report: envelope(fnEntry("app.orphanU", ["Unknown"], direct: []), analyzed: 1),
                                     policy: "deny Unknown[unresolved] app.orphanU\n")
        defer { try? FileManager.default.removeItem(at: sole) }
        let v = sole.appendingPathComponent("v.json")
        try? FileManager.default.removeItem(at: v)
        let r1 = try ProcessHarness.run(bin(), ["gate", "--report", sole.path,
                                                "--policy", sole.appendingPathComponent("pol.txt").path,
                                                "--gate-json", v.path])
        XCTAssertEqual(r1.code, 2, "nothing fired, so this is a sole refusal: \(r1.err)")
        let d1 = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
        XCTAssertEqual(d1?["refused"] as? Bool, true, "…and it is the REFUSAL document, not a verdict")
        XCTAssertFalse(d1?.keys.contains("violations") ?? true,
                       "the matcher's `unresolved` floor must not become grounds to EMIT a violation "
                       + "naming a function whose reason nobody recorded: \(String(describing: d1))")

        // ROW 2 — ONE rule, TWO functions, and it must fire on exactly the evidenced one. `app.named`
        // raises `Unknown` DIRECTLY and names no reason, so §6.2 CONTRIBUTES `unresolved` from its own
        // entry and the rule is ANSWERED there; `app.orphanU` INHERITS it from nowhere the report names,
        // so the rule is withheld. Withholding is per (rule, function), never whole-policy.
        let both = try makeReportDir(
            report: envelope(fnEntry("app.named", ["Unknown"], direct: ["Unknown"]) + ","
                             + fnEntry("app.orphanU", ["Unknown"], direct: []), analyzed: 2),
            policy: "deny Unknown[unresolved]\n")
        defer { try? FileManager.default.removeItem(at: both) }
        let v2 = both.appendingPathComponent("v.json")
        try? FileManager.default.removeItem(at: v2)
        let r2 = try ProcessHarness.run(bin(), ["gate", "--report", both.path,
                                                "--policy", both.appendingPathComponent("pol.txt").path,
                                                "--gate-json", v2.path])
        XCTAssertEqual(r2.code, 1, "exit 1 for what fired: \(r2.err)")
        let d2 = try JSONSerialization.jsonObject(with: Data(contentsOf: v2)) as? [String: Any]
        let fns = (d2?["violations"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertEqual(fns, ["app.named"],
                       "exactly the evidenced function — `app.orphanU`'s presence here would be the "
                       + "fabrication, and its ABSENCE while `app.named` is present is what proves the "
                       + "withholding is per (rule, function) rather than whole-policy: \(fns)")
        XCTAssertTrue(r2.err.contains("app.orphanU"),
                      "…and a disclosure for what could not be evaluated: \(r2.err)")
    }

    // ── ⟨0.24⟩ A REFUSAL MUST STILL WRITE A DOCUMENT (SPEC §3.1) ────────────────────────────────────

    /// **THE STALE-VERDICT HAZARD.** The canonical CI wrapper is
    /// `candor-swift gate … --gate-json v.json || true` then `jq .ok v.json`. A refusal used to write
    /// nothing at all, so that wrapper re-read **the PREVIOUS run's document as current** — a green file
    /// from yesterday's clean run, still on disk, is how a refusal becomes an all-clear.
    ///
    /// **THE FIXTURE SEEDS THE STALE GREEN FILE FIRST, ON PURPOSE.** Starting from an absent path can only
    /// show that a file was created; it can never show that the reader was rescued from the value that was
    /// actually there. MEASURED 2026-07-28: before, `v.json` was left byte-for-byte as seeded and `.ok`
    /// read `true`; after, `.ok` reads false and `.refused` reads true.
    ///
    /// **NO `violations` KEY, ASSERTED AS ABSENT AND NOT AS EMPTY.** The gate is making no claim about
    /// violations here, and `[]` is precisely the claim it cannot make — every consumer in existence reads
    /// an empty array as "we looked and found none". A `== []` assertion would pass on the fail-open shape.
    func testARefusalStillWritesAFailClosedDocument() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Sender.send", ["Net"]), analyzed: 1),
                                     policy: "deny Net[unknown-host] app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("v.json")
        let stale = #"{"analyzed":{"count":9},"ok":true,"spec":"0.24","violations":[]}"#
        try stale.write(to: v, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path,
                                               "--gate-json", v.path])
        XCTAssertEqual(r.code, 2, "the sole refusal still exits 2: \(r.err)")
        let written = try String(contentsOf: v, encoding: .utf8)
        XCTAssertNotEqual(written, stale, "the refusal must OVERWRITE the previous run's verdict — leaving "
                          + "it is how yesterday's green becomes today's all-clear")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
        XCTAssertEqual(d?["ok"] as? Bool, false, "a consumer keying only on `ok` must land on FAIL: \(written)")
        XCTAssertEqual(d?["refused"] as? Bool, true, "and one keying on `refused` learns why: \(written)")
        XCTAssertFalse((d?["reason"] as? String ?? "").isEmpty, "the reason travels with it: \(written)")
        XCTAssertFalse(d?.keys.contains("violations") ?? true,
                       "ABSENT, not empty — an empty array is exactly the claim a refusal cannot make, and "
                       + "a `== []` assertion would pass on the fail-open shape: \(written)")

        // CONTROL — an ANSWERABLE policy over the same report still writes a real verdict WITH a
        // `violations` key, so "always write a refusal document" cannot pass by refusing everything.
        let bare = root.appendingPathComponent("bare.txt")
        try "deny Net app\n".write(to: bare, atomically: true, encoding: .utf8)
        let v2 = root.appendingPathComponent("v2.json")
        try? FileManager.default.removeItem(at: v2)
        let ok = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy", bare.path,
                                                "--gate-json", v2.path])
        XCTAssertEqual(ok.code, 1, "the bare deny is answerable and fires: \(ok.err)")
        let d2 = try JSONSerialization.jsonObject(with: Data(contentsOf: v2)) as? [String: Any]
        XCTAssertNil(d2?["refused"], "an evaluated gate is not a refusal")
        XCTAssertEqual((d2?["violations"] as? [Any])?.count, 1, "and it carries its violations")
    }

    /// The other two answerability refusals take the same document — the hazard is the PATH, not the rule
    /// kind, and a wrapper cannot know which refusal it is about to hit.
    func testTheForbidAndAllowRefusalsAlsoWriteTheDocument() throws {
        for (name, policy) in [("forbid", "forbid app.Domain -> app.Infra\n"),
                               ("allow", "allow Exec git\n")] {
            let root = try makeReportDir(report: envelope(fnEntry("app.Wire.send", ["Net", "Exec"],
                                                                  netClass: ["unknown-host"]), analyzed: 1),
                                         policy: policy)
            defer { try? FileManager.default.removeItem(at: root) }
            let v = root.appendingPathComponent("v.json")
            try #"{"ok":true,"spec":"0.24","violations":[]}"#.write(to: v, atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                   "--policy", root.appendingPathComponent("pol.txt").path,
                                                   "--gate-json", v.path])
            XCTAssertEqual(r.code, 2, "\(name): still refused")
            let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
            XCTAssertEqual(d?["ok"] as? Bool, false, "\(name): the stale green must be gone")
            XCTAssertEqual(d?["refused"] as? Bool, true, "\(name)")
            XCTAssertFalse(d?.keys.contains("violations") ?? true, "\(name): ABSENT, not empty")
        }
    }

    // ── ⟨0.24⟩ THE FOURTH AMBIENT CHANNEL: policy VOCABULARY anchors at the POLICY (SPEC §3.1) ──────

    /// §3.1's MUST NOT names three channels an effect must never enter a gate through. A review found a
    /// FOURTH that no engine tested: `.candor/config`'s `unknown-alias`. **The two routes anchored
    /// DIFFERENTLY** — every gate verb at the policy file's directory, every scan route at the target — so
    /// with the policy filed OUTSIDE the scan target the same rule expanded differently, and §3.1's
    /// byte-equality MUST was breakable by a file that is neither the report nor the policy.
    ///
    /// MEASURED on this engine before the fix, one report + one policy `deny Unknown[corp]`, with
    /// `unknown-alias corp = reflect` filed beside the POLICY and the target's only hole in the `indirect`
    /// class:
    ///
    ///     gate --report R --policy P   exit 0   alias found — the rule narrows to [reflect], no match
    ///     scan TARGET   --policy P     exit 1   alias NOT found — the rule widened to a bare deny Unknown
    ///
    /// The fixture files the policy OUTSIDE the scan target on purpose: with the two in the same tree the
    /// two anchors coincide and the row is vacuous.
    func testPolicyVocabularyAnchorsAtThePolicyOnBothRoutes() throws {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func hole(_ f: () -> Void) { f() }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        // The policy + its vocabulary live in a SEPARATE tree — the whole point of the row.
        let pdir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-polvocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pdir.appendingPathComponent(".candor"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pdir) }
        try "unknown-alias corp = reflect\n".write(to: pdir.appendingPathComponent(".candor/config"),
                                                   atomically: true, encoding: .utf8)
        let pol = pdir.appendingPathComponent("pol.txt")
        try "deny Unknown[corp]\n".write(to: pol, atomically: true, encoding: .utf8)

        let rep = root.appendingPathComponent("r")
        let scanV = root.appendingPathComponent("scan.json"), gateV = root.appendingPathComponent("gate.json")
        for u in [scanV, gateV] { try? FileManager.default.removeItem(at: u) }
        let s = try ProcessHarness.run(bin(), [root.path, "--out", rep.path, "--policy", pol.path,
                                               "--gate-json", scanV.path])
        let g = try ProcessHarness.run(bin(), ["gate", "--report", rep.path, "--policy", pol.path,
                                               "--gate-json", gateV.path])
        XCTAssertEqual(s.code, 0, "the alias resolves on the SCAN route too, so the rule narrows to "
                       + "[reflect] and does not fire. stderr: \(s.err)")
        XCTAssertEqual(g.code, 0, "…as it always did on the gate route: \(g.err)")
        XCTAssertEqual(try Data(contentsOf: scanV), try Data(contentsOf: gateV),
                       "and §3.1's byte-equality holds by CONSTRUCTION, not by the two routes happening to "
                       + "be pointed at the same directory")

        // …AND THE AMBIENCE IS DISCLOSED. A verdict changed by a file the operator cannot see named is the
        // ambient-input failure this format exists to refuse.
        // KEY AND SHAPE ARE FOUR-WAY: `policyVocabulary: {config, aliases}`, matching java and ts exactly.
        // This engine shipped it for one commit as a `configSources` string list; conformance PART 27 R9's
        // key-parity arm measured three names for one field across four engines, which is the hole
        // WITHIN-engine byte-equality is structurally blind to.
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: gateV)) as? [String: Any]
        let pv = try XCTUnwrap(d?["policyVocabulary"] as? [String: Any],
                               "the config whose vocabulary PARTICIPATED must be named: \(String(describing: d))")
        XCTAssertEqual(pv["config"] as? String, pdir.appendingPathComponent(".candor/config").path)
        XCTAssertEqual(pv["aliases"] as? [String], ["corp"],
                       "…and WHICH aliases it supplied — naming the file alone leaves the reader to diff "
                       + "a config against a policy to find out what acted")

        // CONTROL — the same policy with a BUILT-IN token uses no config vocabulary, so the key is ABSENT.
        // Without this the assertion above passes on an engine that names the config unconditionally.
        let plain = pdir.appendingPathComponent("plain.txt")
        try "deny Unknown[reflect]\n".write(to: plain, atomically: true, encoding: .utf8)
        let v2 = root.appendingPathComponent("v2.json")
        try? FileManager.default.removeItem(at: v2)
        _ = try ProcessHarness.run(bin(), ["gate", "--report", rep.path, "--policy", plain.path,
                                           "--gate-json", v2.path])
        let d2 = try JSONSerialization.jsonObject(with: Data(contentsOf: v2)) as? [String: Any]
        XCTAssertNil(d2?["policyVocabulary"],
                     "a config that defines aliases nobody asked for is not an input to this verdict")
    }

    // ── ⟨0.24⟩ NEITHER RULE HAS A CARVE-OUT (SPEC §3.1, candor-spec `1503368`) ──────────────────────

    /// **PRECEDENCE BINDS `forbid`/`allow` TOO.** These refusals are whole-policy and used to exit 2
    /// before the report was even opened, so a firing `deny Fs` standing beside a `forbid` rule exited 2
    /// with the certain violation absent from the document — the identical harm the precedence fix closed
    /// one rung up, surviving under a different rule KIND. Lemma 2 does not care which kind of refusal
    /// stands beside the firing rule. The whole-policy granularity governs which rules go UNEVALUATED; it
    /// was never a licence to suppress a violation that was evaluated and certain.
    ///
    /// AND THE REFUSED RULES ARE STILL NEVER EVALUATED — asserted here by the `allow Exec git` arm: the
    /// AS-EFF-008 surface-completeness marker does not ride the wire, so certifying that rule off this
    /// report would be the fail-open the refusal exists for. The document must carry the AS-EFF-006
    /// finding and NOTHING from AS-EFF-008.
    func testACertainViolationDominatesTheForbidAndAllowRefusalsToo() throws {
        for (name, policy) in [("forbid", "deny Fs\nforbid app.Domain -> app.Infra\n"),
                               ("allow", "deny Fs\nallow Exec git\n")] {
            let root = try makeReportDir(report: envelope(fnEntry("app.writes", ["Fs", "Exec"]), analyzed: 1),
                                         policy: policy)
            defer { try? FileManager.default.removeItem(at: root) }
            let v = root.appendingPathComponent("v.json")
            try? FileManager.default.removeItem(at: v)
            let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                   "--policy", root.appendingPathComponent("pol.txt").path,
                                                   "--gate-json", v.path])
            XCTAssertEqual(r.code, 1, "\(name): the `deny Fs` fired on evidence the report carries, and no "
                           + "resolution of the refused rule can un-reject a rejected policy. stderr: \(r.err)")
            let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
            let vs = d?["violations"] as? [[String: Any]] ?? []
            XCTAssertEqual(vs.count, 1, "\(name): exactly the certain finding: \(String(describing: d))")
            XCTAssertEqual(vs.first?["rule"] as? String, "AS-EFF-006",
                           "\(name): the REFUSED rule is still never evaluated — an AS-EFF-008 record here "
                           + "would be the certification the refusal exists to prevent")
            XCTAssertTrue(r.err.contains(name), "\(name): and the unevaluated rule is disclosed: \(r.err)")
        }
    }

    /// **AND THE SOLE `forbid`/`allow` REFUSAL STILL REFUSES** — the control for the row above. Without it
    /// "a violation dominates" is indistinguishable from "the refusal was deleted".
    func testAForbidOrAllowRefusalWithNoFiringRuleStillRefuses() throws {
        for (name, policy) in [("forbid", "forbid app.Domain -> app.Infra\n"), ("allow", "allow Exec git\n")] {
            let root = try makeReportDir(report: envelope(fnEntry("app.writes", ["Fs", "Exec"]), analyzed: 1),
                                         policy: policy)
            defer { try? FileManager.default.removeItem(at: root) }
            let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                                   "--policy", root.appendingPathComponent("pol.txt").path])
            XCTAssertEqual(r.code, 2, "\(name): with nothing certain beside it, this is still a refusal")
        }
    }

    /// **THE REFUSAL DOCUMENT HAS NO EXEMPT CAUSE.** §3.3 mandated writing no document when the policy or
    /// gate config is unreadable, and two rows here pinned that — but the argument that required a
    /// document (a CI wrapper re-reads the previous run's verdict as current) is exactly as true there. A
    /// stale green does not care why this run declined to overwrite it. An unreadable policy has no rules
    /// to reason about, which is precisely why the document carries no `violations` key.
    func testEveryExit2CauseWritesTheRefusalDocument() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Wire.send", ["Net"], netClass: ["unknown-host"]), analyzed: 1),
                                     policy: "deny Net app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = try makeReportDir(report: #"{"candor":{"spec":"0.23"},"package":"App"}"#,
                                        policy: "deny Net\n")
        defer { try? FileManager.default.removeItem(at: corrupt) }
        let cases: [(String, [String])] = [
            ("an unreadable policy", ["gate", "--report", root.path, "--policy", root.path + "/nope"]),
            ("a report that never loaded AS one", ["gate", "--report", corrupt.path,
                                                   "--policy", corrupt.appendingPathComponent("pol.txt").path]),
            ("no report at the locator", ["gate", "--report", root.path + "/nothing-here",
                                          "--policy", root.appendingPathComponent("pol.txt").path]),
        ]
        for (name, args) in cases {
            let v = root.appendingPathComponent("cause.json")
            // SEEDED, not deleted: the hazard is the value that was already there.
            try #"{"ok":true,"spec":"0.24","violations":[]}"#.write(to: v, atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(bin(), args + ["--gate-json", v.path])
            XCTAssertEqual(r.code, 2, "\(name): still exit 2")
            let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
            XCTAssertEqual(d?["ok"] as? Bool, false, "\(name): the stale green must be gone")
            XCTAssertEqual(d?["refused"] as? Bool, true, "\(name)")
            XCTAssertFalse(d?.keys.contains("violations") ?? true, "\(name): ABSENT, not empty")
        }
        // AND THE ONE CASE THAT STILL WRITES NOTHING, because there is no sink yet: a USAGE error inside
        // the flag loop, where `--gate-json`'s value is not yet known or is the thing being rejected.
        let v2 = root.appendingPathComponent("usage.json")
        let seeded = #"{"ok":true,"spec":"0.24","violations":[]}"#
        try seeded.write(to: v2, atomically: true, encoding: .utf8)
        let usage = try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--gate-json", "--policy",
                                                   root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(usage.code, 2, usage.err)
        XCTAssertEqual(try String(contentsOf: v2, encoding: .utf8), seeded,
                       "a flag-loop usage error has no resolved sink to write to — and `--gate-json "
                       + "--policy p` is exactly the invocation whose `--gate-json` value is the flag it "
                       + "would have swallowed")
    }

    /// `--json` IS `--gate-json -` on the refusal path too — otherwise the one consumer that pipes the
    /// verdict instead of filing it gets NOTHING on stdout and reads it as an empty result.
    func testTheRefusalDocumentAlsoRidesJsonToStdout() throws {
        let root = try makeReportDir(report: envelope(fnEntry("app.Sender.send", ["Net"]), analyzed: 1),
                                     policy: "deny Net[unknown-host] app\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path, "--json"])
        XCTAssertEqual(r.code, 2)
        let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertEqual(d?["ok"] as? Bool, false, "stdout is ONE refusal document, uncorrupted by prose: \(r.out)")
        XCTAssertEqual(d?["refused"] as? Bool, true)
        XCTAssertFalse(d?.keys.contains("violations") ?? true, "ABSENT, not empty: \(r.out)")
    }
}
