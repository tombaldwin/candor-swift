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
