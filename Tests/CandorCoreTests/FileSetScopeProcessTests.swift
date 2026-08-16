import XCTest
import Foundation

/// ⟨0.29⟩ THE FILE SET — what a report says about code it never opened (candor-spec/FILE-SET-DESIGN.md).
///
/// ⟨0.21⟩ gave the report a completeness manifest, and `unanalyzed` names files the engine OPENED and
/// failed on. It says nothing about files never opened at all, and a consumer cannot tell the two apart:
/// `analyzed.count` is a NUMERATOR whose denominator — the engine's file selector — is invisible. Measured
/// on this engine 2026-08-15: `deny Exec` over a package holding `Tests/Helper.swift` with a live
/// `Process().run()` answered `policy ✓`, exit 0, with nothing on stderr and no key in the report.
///
/// Rung 2 of the FILE-SET-DESIGN ladder — DISCLOSE + PEEK. The scope is declared (`excluded`), the
/// excluded files are READ, and an effect the policy denies in one of them is reported as its own kind
/// (`outOfScope`). No verdict moves.
///
/// THE PORT OF candor-rust's `the_peek_reports_a_denied_effect_outside_the_scope_without_moving_the_verdict`
/// and `the_report_declares_what_the_scan_chose_not_to_open`, which are the spec-by-example for this rung.
final class FileSetScopeProcessTests: XCTestCase {

    private var bin: URL!
    private var dir: URL!

    override func setUpWithError() throws {
        bin = try ProcessHarness.binaryURL(for: Self.self)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("candor-fileset-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "peek", targets: [.target(name: "App")])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func add(_ a: Int) -> Int { a + 1 }\n"
            .write(to: dir.appendingPathComponent("Sources/App/Lib.swift"), atomically: true, encoding: .utf8)
        // THE FIXTURE EXECS `/bin/ls`, NOT `curl`, AND THAT IS THE POINT — see the policy-bound row below.
        try """
        import Foundation
        public func helper() {
            let p = Process()
            p.launchPath = "/bin/ls"
            try? p.run()
        }
        """.write(to: dir.appendingPathComponent("Tests/Helper.swift"), atomically: true, encoding: .utf8)
        try "deny Exec\n".write(to: dir.appendingPathComponent("exec.policy"), atomically: true, encoding: .utf8)
        try "deny Net\n".write(to: dir.appendingPathComponent("net.policy"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func p(_ rel: String) -> String { dir.appendingPathComponent(rel).path }

    private func doc(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], out)
    }

    /// THE SCOPE. `analyzed.count` is a numerator; the selection that produced it appeared nowhere, so a
    /// consumer could not tell whether the answer was to the question they asked.
    ///
    /// Asserts the REASON STRING, not the key's presence: a block whose reasons a consumer cannot read is
    /// a count, and a count does not say whether the exclusion matches your question. (PART 39 was wrong
    /// twice in one day by asking whether a key was there rather than what it said.)
    func testTheReportDeclaresWhatTheScanChoseNotToOpen() throws {
        let r = try ProcessHarness.run(bin, [dir.path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        let ex = try XCTUnwrap(d["excluded"] as? [[String: Any]],
                               "`excluded` must be present, even when empty (⟨0.27⟩): \(r.out)")
        func find(_ cls: String) -> [String: Any]? { ex.first { $0["class"] as? String == cls } }

        let harness = try XCTUnwrap(find("harness-target"), "Tests/ must be declared as excluded: \(ex)")
        XCTAssertEqual(harness["count"] as? Int, 1)
        let why = harness["reason"] as? String ?? ""
        XCTAssertTrue(why.contains("HARNESS") && why.contains("CI"),
                      "the reason must say WHY and what it costs, not just name the class: \(why)")

        // ⟨0.29⟩ `peeked` IS AN OUTCOME, and this scan configures NO POLICY — no peek ran, nothing was
        // read, so `false` is the honest answer even for a class the peek is willing to read. This row
        // asserted `true` while the flag was a per-class constant, which is the overclaim the flag exists
        // to prevent. The TRUE case is asserted in the peek row, where a read actually happens.
        XCTAssertEqual(harness["peeked"] as? Bool, false,
                       "no policy ⇒ no peek ⇒ no class may claim to have been read: \(harness)")

        let manifest = try XCTUnwrap(find("manifest"), "Package.swift must be declared as excluded: \(ex)")
        XCTAssertEqual(manifest["count"] as? Int, 1)
        XCTAssertTrue((manifest["reason"] as? String ?? "").contains("swift build"),
                      "the manifest's reason must say it runs on every build: \(manifest)")

        // …and the excluded files are genuinely NOT in the analyzed set — otherwise the block would be
        // describing an exclusion that did not happen, which is a different and worse kind of wrong.
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertFalse(fns.contains { $0.contains("helper") },
                       "Tests/Helper.swift was scanned after all — the exclusion block would be fiction: \(fns)")
    }

    /// THE PEEK — an effect in a file the gate did not judge is REPORTED, and changes no verdict.
    ///
    /// Three rows in one, because the bounds ARE the design and each is a way this becomes noise:
    /// `deny Exec` finds it, `deny Net` over the SAME tree says nothing (bounded by the policy), and no
    /// policy at all says nothing (policy-scoped). The exit code does not move in any of them.
    ///
    /// THE FIXTURE EXECS `/bin/ls` WITH NO ARGUMENT, AND THAT IS THE POINT. Both engines ported before
    /// this one first used a `curl http://…` spelling, which the classifier reads as Net AS WELL AS Exec
    /// — so the `deny Net` row matched legitimately and read as a broken bound. The fixture could not
    /// test the thing it claimed to. An argument-free `/bin/ls` isolates Exec.
    func testThePeekReportsADeniedEffectOutsideTheScopeWithoutMovingTheVerdict() throws {
        let r = try ProcessHarness.run(bin, [dir.path, "--json", "--policy", p("exec.policy")])
        let d = try doc(r.out)
        let oos = try XCTUnwrap(d["outOfScope"] as? [[String: Any]],
                                "a configured policy must answer, even with []: \(r.out)")
        XCTAssertEqual(oos.count, 1, "the test helper's Exec must be reported: \(oos)")
        XCTAssertEqual(oos[0]["class"] as? String, "harness-target")
        XCTAssertEqual(oos[0]["effects"] as? [String] ?? [], ["Exec"])
        XCTAssertEqual(oos[0]["path"] as? String, "Tests/Helper.swift",
                       "named from the PROJECT-relative path the `excluded` block already disclosed")
        XCTAssertTrue((oos[0]["reason"] as? String ?? "").contains("did NOT judge"),
                      "the reason must say the gate did not judge it: \(oos[0])")
        // ⟨0.29⟩ …and NOW the class may say it was read, because on this run it was.
        let exRead = try XCTUnwrap(d["excluded"] as? [[String: Any]], r.out)
        let harnessRead = try XCTUnwrap(exRead.first { $0["class"] as? String == "harness-target" }, "\(exRead)")
        XCTAssertEqual(harnessRead["peeked"] as? Bool, true,
                       "the peek READ this class on this run, so the flag must say so: \(harnessRead)")
        // THE VERDICT DOES NOT MOVE. This is the promise of the chosen rung: a file the gate declined to
        // judge must not decide an exit code, and must not appear among the judged functions.
        XCTAssertEqual(r.code, 0, "an out-of-scope finding must not change the exit code: \(r.err)")
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertFalse(fns.contains("helper"),
                       "the out-of-scope function must NOT be folded into the report's functions: \(fns)")
        // …and it reaches the OPERATOR, not just the machine — above the verdict, since a caveat printed
        // below a green tick is a caveat nobody reaches.
        XCTAssertTrue(r.err.contains("OUTSIDE this scan's scope"), "stderr must carry it too: \(r.err)")

        // BOUNDED BY THE POLICY: the same tree under `deny Net` says nothing about an Exec.
        let net = try ProcessHarness.run(bin, [dir.path, "--json", "--policy", p("net.policy")])
        let netOos = try XCTUnwrap(try doc(net.out)["outOfScope"] as? [[String: Any]],
                                   "a configured policy still answers — with []: \(net.out)")
        XCTAssertTrue(netOos.isEmpty,
                      "`deny Net` must not report an Exec in an excluded file: \(netOos)")
        XCTAssertEqual(net.code, 0, net.err)

        // POLICY-SCOPED: no policy, no peek, and the key is ABSENT rather than empty — nothing was asked,
        // so an empty list would be a claim (⟨0.26⟩: absence means "this producer cannot answer").
        let none = try ProcessHarness.run(bin, [dir.path, "--json"])
        XCTAssertNil(try doc(none.out)["outOfScope"],
                     "with no policy the key must be absent, not empty: \(none.out)")
    }

    /// THE CONTROL, and it is the row that matters most: a package with nothing to exclude must still
    /// EMIT the key, as an empty list — ⟨0.27⟩'s zero-match rule, and ⟨0.26⟩'s reading that an absent key
    /// means "this producer cannot answer". Without it the rows above pass against an engine that
    /// declares exclusions it invented, or one that fails everything.
    func testAPackageWithNothingExcludedStillDeclaresAnEmptyScope() throws {
        let clean = dir.appendingPathComponent("clean")
        try FileManager.default.createDirectory(at: clean.appendingPathComponent("Sources/App"),
                                                withIntermediateDirectories: true)
        try "public func add(_ a: Int) -> Int { a + 1 }\n"
            .write(to: clean.appendingPathComponent("Sources/App/Lib.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [clean.path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let ex = try XCTUnwrap(try doc(r.out)["excluded"] as? [[String: Any]],
                               "the key must be emitted even with nothing to say: \(r.out)")
        XCTAssertTrue(ex.isEmpty, "nothing was excluded, so the list must be empty: \(ex)")
    }

    /// THE CLASS THE PEEK DOES NOT READ SAYS SO — and this is the row that makes `peeked` more than
    /// decoration. `.build/` holds checked-out dependency sources: unbounded, and other people's tests are
    /// not a finding about your project, so the peek is held out of it deliberately. An empty
    /// `outOfScope` beside a silently-unread class would be certifying files nobody opened, which is
    /// ⟨0.26⟩'s partial-manifest failure — a partial answer worse than an absent one.
    func testTheClassThePeekWillNotReadIsDeclaredUnpeeked() throws {
        let build = dir.appendingPathComponent(".build/checkouts/Dep/Sources")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try """
        import Foundation
        public func vendored() { let p = Process(); p.launchPath = "/bin/ls"; try? p.run() }
        """.write(to: build.appendingPathComponent("Dep.swift"), atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, [dir.path, "--json", "--policy", p("exec.policy")])
        let d = try doc(r.out)
        let ex = try XCTUnwrap(d["excluded"] as? [[String: Any]], r.out)
        let bo = try XCTUnwrap(ex.first { $0["class"] as? String == "build-output" },
                               "`.build/` must be declared as excluded: \(ex)")
        XCTAssertEqual(bo["peeked"] as? Bool, false,
                       "…and declared UNPEEKED, or `outOfScope: []` would be a claim about it: \(bo)")
        XCTAssertTrue((bo["reason"] as? String ?? "").contains("NOT read by the peek"),
                      "the reason must say the peek skips it: \(bo)")
        // …and the vendored Exec is genuinely absent from the findings, so the flag describes what
        // happened rather than what was intended.
        let oos = try XCTUnwrap(d["outOfScope"] as? [[String: Any]], r.out)
        XCTAssertFalse(oos.contains { ($0["path"] as? String ?? "").contains(".build") },
                       "the peek must not have read `.build/` after all: \(oos)")
        XCTAssertEqual(r.code, 0, r.err)
    }

    /// ⟨0.21⟩'S HALF STAYS ⟨0.21⟩'S. A file the selector DID reach and could not parse belongs in
    /// `unanalyzed`, never in `excluded` — opened-and-failed and never-opened are different claims, and a
    /// rung that blurs them turns a fail-closed exit 2 into an advisory count.
    func testAParseFailureStaysInUnanalyzedRatherThanTheScopeBlock() throws {
        try "func broken( {{{ \n".write(to: dir.appendingPathComponent("Sources/App/Broken.swift"),
                                        atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [dir.path, "--json"])
        let d = try doc(r.out)
        let un = (d["unanalyzed"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        XCTAssertTrue(un.contains { $0.hasSuffix("Broken.swift") },
                      "the unparseable file must be ⟨0.21⟩ `unanalyzed`: \(d["unanalyzed"] ?? "absent")")
        let classes = (d["excluded"] as? [[String: Any]] ?? []).compactMap { $0["class"] as? String }
        XCTAssertFalse(classes.contains("unparsed"), "…and must not have leaked into the scope block: \(classes)")
    }
}
