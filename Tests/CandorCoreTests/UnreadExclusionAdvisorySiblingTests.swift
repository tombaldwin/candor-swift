import XCTest
import Foundation

/// **⟨0.32⟩ THE UNREAD-CLASS CAUSE REACHES THE ADVISORY SIBLINGS TOO** (SPEC §3.2).
///
/// §3.2's relation is that an advisory verb may be LESS certain than the gate over the same bytes and
/// never MORE. The ⟨0.32⟩ unread-class rule landed on `gate --report` and stopped there, so the moment
/// that route started refusing, MEASURED on one no-policy report of a tree whose test helper spawns
/// `/bin/sh` under `deny Exec`:
///
///     gate --report N --policy P        exit 2   {"ok": false, "incomplete": true}
///     fix-gate  --report N --policy P --strict   exit 0   {"ok": true, "remedies": []}
///     unverified --report N --policy P --strict  exit 0   {"ok": true, "unverified": []}
///
/// and the two documents on the right are the AGENT's half of this tool. ⟨0.30⟩'s half of the same rung
/// already reaches these verbs (`outOfScope` is an arm of `isIncomplete`); closing a cause on the gate
/// and not on its siblings is exactly how that half drifted first, which is why these rows exist in the
/// same change rather than after the next review finds them.
///
/// THE CONDITION IS APPLIED ONCE, in `armingUnread`, against THIS run's policy — only a `deny`/`pure`
/// rule's answer depends on code outside the scan's scope. `unread` deliberately is NOT an unconditional
/// arm of `isIncomplete`: it is non-empty on almost every no-policy report, and a verb that hedged on
/// every run would teach its reader to skip the hedge.
final class UnreadExclusionAdvisorySiblingTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// An SPM tree whose EXCLUDED harness target performs `Exec`, scanned BOTH ways: `N` with no policy
    /// (the shape a CI publishes) and `P` with one (the peek runs). A real scan, not a hand-authored
    /// report, so `peeked` comes back through the engine's own machinery.
    private func tree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-advisory-unread-\(UUID().uuidString)")
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
        try "forbid ui -> db\n".write(to: root.appendingPathComponent("noask.txt"),
                                      atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(try bin(), [root.path, "--out", root.appendingPathComponent("N").path],
                                   cwd: root)
        _ = try ProcessHarness.run(try bin(), [root.path, "--out", root.appendingPathComponent("P").path,
                                               "--policy", root.appendingPathComponent("pol.txt").path],
                                   cwd: root)
        return root
    }

    private func advisory(_ root: URL, verb: String, report: String, policy: String)
        throws -> (out: String, err: String, code: Int32) {
        try ProcessHarness.run(try bin(),
                               [verb, "--report", root.appendingPathComponent(report).path,
                                "--policy", root.appendingPathComponent(policy).path, "--strict", "--json"],
                               cwd: root)
    }

    private func doc(_ s: String) throws -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw XCTSkip("not JSON: \(s)")
        }
        return o
    }

    /// **THE DEFECT.** Over the report `gate --report` refuses, `--strict` must not certify — and the
    /// DOCUMENT matters as much as the exit, because that document is what an agent reads. `ok` is
    /// WITHHELD rather than set false: these verbs have no finding, they have no basis for one.
    func testTheStrictAdvisoryVerbsDoNotCertifyOverAnUnreadClass() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        // THE PREMISE, asserted so a broken fixture cannot pass as a green: the no-policy report really
        // does publish an unpeeked class with no `judgedElsewhere` carve-out on it.
        let rep = try doc(try String(contentsOf: root.appendingPathComponent("N.App.Swift.json"),
                                     encoding: .utf8))
        let ex = try XCTUnwrap(rep["excluded"] as? [[String: Any]], "\(rep)")
        let ht = try XCTUnwrap(ex.first { $0["class"] as? String == "harness-target" }, "\(ex)")
        XCTAssertEqual(ht["peeked"] as? Bool, false, "the fixture must publish an UNREAD class: \(ht)")
        XCTAssertNil(ht["judgedElsewhere"], "…with no producer carve-out on it: \(ht)")

        let gate = try ProcessHarness.run(try bin(),
                                          ["gate", "--report", root.appendingPathComponent("N").path,
                                           "--policy", root.appendingPathComponent("pol.txt").path],
                                          cwd: root)
        XCTAssertEqual(gate.code, 2, "the gate is the benchmark §3.2 measures against: \(gate.err)")

        for verb in ["fix-gate", "unverified"] {
            let r = try advisory(root, verb: verb, report: "N", policy: "pol.txt")
            XCTAssertEqual(r.code, 2, "\(verb): §3.2 — never MORE certain than the gate: \(r.err)")
            let d = try doc(r.out)
            XCTAssertEqual(d["incomplete"] as? Bool, true, "\(verb): the DOCUMENT must say so: \(d)")
            XCTAssertNil(d["ok"], "\(verb): `ok` is WITHHELD, not false — there is no finding here: \(d)")
        }
    }

    /// **⟨0.32⟩ THE OTHER SIDE OF THE SAME BOUNDARY: A DESCRIPTIVE VERB RETURNS ITS DATA *AND* THE
    /// WARNING — IT DOES NOT REPLACE THE DATA WITH THE WARNING.**
    ///
    /// RULED 2026-08-25, four-way. ⟨0.28⟩ Rung A tells a verb *whose pinned shape cannot carry the
    /// caveat* to emit the CAVEAT DOCUMENT INSTEAD of its result, and the ⟨0.32⟩ unread-class cause then
    /// armed that substitution on nearly every no-policy report — so in the three engines that ship
    /// `show`/`map`, `show <fn> --json` and `map --json` answered `{"incomplete": true}` and the result
    /// was GONE. `show` and `map` CERTIFY NOTHING, so there is no claim for a pessimism rule to protect;
    /// the remedy is the one `gains --json` already applies (its data, plus `incomplete: true` beside it).
    ///
    /// **THIS ENGINE SHIPS NEITHER VERB** (its surface is `path tour gains fix fix-gate unverified
    /// privacy-manifest gate parsepolicy`), so the substitution has no site here and nothing changed. What
    /// it DOES ship on the descriptive side is `path` and `tour`, and this row pins them on the ruled
    /// behaviour so a later `show`/`map` port cannot arrive with the shape the ruling rejects.
    ///
    /// The CERTIFYING half is `testTheStrictAdvisoryVerbsDoNotCertifyOverAnUnreadClass` above and it must
    /// NOT move: those verbs answer `ok`, and conformance PARTs 62 and 67 pin their refusal.
    func testTheDescriptiveVerbsKeepTheirResultBesideTheHedge() throws {
        // ITS OWN TREE, because the shared one's library target is deliberately PURE — `path`/`tour` over
        // an empty `functions` would assert nothing, and an empty result is exactly the answer this row is
        // supposed to be able to tell apart from a withheld one.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-descriptive-unread-\(UUID().uuidString)")
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
        try """
        import Foundation
        public func readIt(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
        public func wrapper(_ p: String) -> Int { readIt(p).count }
        """.write(to: root.appendingPathComponent("Sources/App/Lib.swift"), atomically: true, encoding: .utf8)
        try "import XCTest\nfinal class T: XCTestCase { func testX() {} }\n"
            .write(to: root.appendingPathComponent("Tests/AppTests/T.swift"), atomically: true, encoding: .utf8)
        let rep = root.appendingPathComponent("N").path
        _ = try ProcessHarness.run(try bin(), [root.path, "--out", rep], cwd: root)
        // THE PREMISE, asserted so a broken fixture cannot pass as a green.
        let env = try doc(try String(contentsOf: root.appendingPathComponent("N.App.Swift.json"),
                                     encoding: .utf8))
        let ex = try XCTUnwrap(env["excluded"] as? [[String: Any]], "\(env)")
        XCTAssertTrue(ex.contains { $0["peeked"] as? Bool == false },
                      "the fixture must publish an UNREAD class: \(ex)")

        let tour = try ProcessHarness.run(try bin(), ["tour", "--report", rep, "--json"], cwd: root)
        XCTAssertEqual(tour.code, 0, "a descriptive hedge is a DISCLOSURE, not an exit code: \(tour.err)")
        let td = try doc(tour.out)
        XCTAssertEqual(td["incomplete"] as? Bool, true, "the warning travels: \(td)")
        XCTAssertFalse((td["reaches"] as? [Any] ?? []).isEmpty,
                       "…BESIDE the result, never instead of it: \(td)")

        let path = try ProcessHarness.run(try bin(), ["path", "wrapper", "Fs", "--report", rep, "--json"],
                                          cwd: root)
        XCTAssertEqual(path.code, 0, "\(path.err)")
        let pd = try doc(path.out)
        XCTAssertEqual(pd["incomplete"] as? Bool, true, "the warning travels: \(pd)")
        XCTAssertFalse((pd["path"] as? [Any] ?? []).isEmpty,
                       "…BESIDE the result, never instead of it: \(pd)")

        // …AND THE SURFACE DECLARATION IS ASSERTED, not assumed. If `show`/`map` are ever ported here they
        // must arrive on the ruled shape, and this row failing is the reminder to write that assertion.
        //
        // ⟨0.32⟩ `callers` AND `impact` JOIN THE LIST. They were measured on 2026-08-25 in the three
        // engines that DO ship them and found to carry no completeness reader at all — the SILENT half of
        // the `show`/`map` class, answering `{"direct":[…]}` and `{"affectedCount":…,"affected":[…]}` flat
        // over a report naming an unread class. Fixed there (rust/ts/java, the caveat spread beside the
        // answer); absent here, and this row is what stops a later port arriving with the defect.
        for verb in ["show", "map", "callers", "impact"] {
            let r = try ProcessHarness.run(try bin(), [verb, "--report", rep, "--json"], cwd: root)
            XCTAssertNotEqual(r.code, 0,
                              "\(verb) is not on this engine's verb surface — if it has been ported, pin "
                              + "it on data-beside-the-hedge here (⟨0.32⟩ ruling): \(r.out)")
        }
    }

    /// ⟨0.32⟩ **`path`'S EMPTY-CHAIN ARM, WHICH IS THE SHARPER HALF AND IS A SEPARATE EMIT SITE.**
    /// `{"path": []}` is *this function does not reach that effect* — the precise reassurance a reader
    /// asks `path` for — and over a class the producing scan never opened the effect could enter through a
    /// callee that contributes no entry to the graph at all, so the chain is not merely missing, it is
    /// unreachable by construction.
    ///
    /// MEASURED, NOT ASSUMED, and its own row because the sibling engines had to be TAUGHT this arm: in
    /// candor-rust, candor-ts and candor-java `path` had no completeness reader whatsoever on 2026-08-25
    /// and all three of its emit sites answered flat. This engine already hedges here; the row is what
    /// keeps that true, and what makes the "candor-swift does not have this defect" claim a measurement.
    func testPathsEmptyChainCarriesTheHedgeToo() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-empty-path-unread-\(UUID().uuidString)")
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
        try """
        import Foundation
        public func readIt(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
        public func wrapper(_ p: String) -> Int { readIt(p).count }
        """.write(to: root.appendingPathComponent("Sources/App/Lib.swift"), atomically: true, encoding: .utf8)
        try "import XCTest\nfinal class T: XCTestCase { func testX() {} }\n"
            .write(to: root.appendingPathComponent("Tests/AppTests/T.swift"), atomically: true, encoding: .utf8)
        let rep = root.appendingPathComponent("N").path
        _ = try ProcessHarness.run(try bin(), [root.path, "--out", rep], cwd: root)
        // THE PREMISE, so a broken fixture cannot pass as a green.
        let env = try doc(try String(contentsOf: root.appendingPathComponent("N.App.Swift.json"),
                                     encoding: .utf8))
        let ex = try XCTUnwrap(env["excluded"] as? [[String: Any]], "\(env)")
        XCTAssertTrue(ex.contains { $0["peeked"] as? Bool == false },
                      "the fixture must publish an UNREAD class: \(ex)")

        // `wrapper` performs Fs and NOT Net, so this is the honest empty answer — the one that must still
        // say it is partial.
        let empty = try ProcessHarness.run(try bin(), ["path", "wrapper", "Net", "--report", rep, "--json"],
                                           cwd: root)
        XCTAssertEqual(empty.code, 0, "the hedge is a disclosure, not an exit code: \(empty.err)")
        let ed = try doc(empty.out)
        XCTAssertEqual(ed["incomplete"] as? Bool, true,
                       "an empty `path` over an unread class is a determined negative and must hedge: \(ed)")
        XCTAssertEqual((ed["path"] as? [Any])?.count, 0,
                       "…and the (empty) chain is PRESENT, not withheld — a consumer must be able to tell "
                       + "the answer the report supports from one that was taken away: \(ed)")
    }

    /// CONTROL — A POLICY WITH NO DENY RULE IS NOT CHARGED FOR THE PEEK. A `forbid`-only policy is
    /// refused on this route for the `forbid` rule's OWN unanswerability, and the row asserts WHICH: an
    /// exit code alone would pass a build that had started hedging every allowlist run.
    func testAPolicyWithNoDenyRuleIsNotArmedByAnUnreadClass() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        for verb in ["fix-gate", "unverified"] {
            let r = try advisory(root, verb: verb, report: "N", policy: "noask.txt")
            let d = try doc(r.out)
            XCTAssertNil(d["incomplete"],
                         "\(verb): a `forbid` rule's answer does not depend on code outside the scan's "
                         + "scope, so an unread class is not this run's problem: \(d)")
            XCTAssertNotNil(d["unevaluated"],
                            "\(verb): …and the refusal that DOES stand is the forbid rule's: \(d)")
        }
    }

    /// CONTROL — A CLEAN TREE STILL CERTIFIES ON ALL FOUR ROUTES. The cheapest way to pass the defect
    /// row is to hedge unconditionally; this row is what that costs. Nothing excluded but the manifest,
    /// and the peek read it, so there is nothing for any route to withhold over.
    func testACleanlyPeekedTreeStillCertifiesOnEveryRoute() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-advisory-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.target(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func add(_ a: Int) -> Int { a + 1 }\n"
            .write(to: root.appendingPathComponent("Sources/App/Lib.swift"), atomically: true, encoding: .utf8)
        try "deny Exec\n".write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        let scan = try ProcessHarness.run(try bin(),
                                          [root.path, "--out", root.appendingPathComponent("C").path,
                                           "--policy", root.appendingPathComponent("pol.txt").path],
                                          cwd: root)
        XCTAssertEqual(scan.code, 0, "the peek read everything it excluded: \(scan.err)")
        let gate = try ProcessHarness.run(try bin(),
                                          ["gate", "--report", root.appendingPathComponent("C").path,
                                           "--policy", root.appendingPathComponent("pol.txt").path],
                                          cwd: root)
        XCTAssertEqual(gate.code, 0, "…so the gate is green: \(gate.err)")
        for verb in ["fix-gate", "unverified"] {
            let r = try advisory(root, verb: verb, report: "C", policy: "pol.txt")
            XCTAssertEqual(r.code, 0, "\(verb): \(r.err)")
            let d = try doc(r.out)
            XCTAssertEqual(d["ok"] as? Bool, true, "\(verb): a clean run still says so: \(d)")
            XCTAssertNil(d["incomplete"], "\(verb): …and hedges nothing: \(d)")
        }
    }
}
