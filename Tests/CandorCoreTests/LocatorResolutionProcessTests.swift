import XCTest
import Foundation

/// SPEC §3.1 ⟨0.28⟩ — WHAT EACH `--report` LOCATOR FORM RESOLVES TO. Three engines were measured
/// disagreeing, each internally consistent, and this one resolved a FILE to its whole prefix-sibling
/// UNION: `resolveReportLocator` stripped `<prefix>.<pkg>.Swift.json` back to `<prefix>`, so naming one
/// artifact silently read three. The pinned rule:
///   · a FILE resolves to that file and its §2.2 sidecars — NOT the prefix siblings beside it;
///   · a PREFIX resolves to the whole matching set, unioned;
///   · a DIRECTORY resolves to what discovery finds (`<dir>/.candor/report…`).
final class LocatorResolutionProcessTests: XCTestCase {

    private var bin: URL!
    private var root: URL!

    override func setUpWithError() throws {
        bin = try ProcessHarness.binaryURL(for: LocatorResolutionProcessTests.self)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("candor-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Two sibling reports under one prefix `r`, deliberately DIFFERENT: A carries only Net, B only
        // Fs — so any answer mentioning B's function under A's file locator is the union, measured.
        try report(pkg: "A", fn: "A.doNet", effect: "Net")
            .write(to: root.appendingPathComponent("r.A.Swift.json"), atomically: true, encoding: .utf8)
        try report(pkg: "B", fn: "B.doFs", effect: "Fs")
            .write(to: root.appendingPathComponent("r.B.Swift.json"), atomically: true, encoding: .utf8)
        try #"{"A.doNet": []}"#
            .write(to: root.appendingPathComponent("r.A.Swift.callgraph.json"), atomically: true, encoding: .utf8)
        try "deny Fs\n".write(to: root.appendingPathComponent("denyfs.policy"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func report(pkg: String, fn: String, effect: String) -> String {
        """
        {
          "candor": {"version": "candor-swift-test", "toolchain": "swiftsyntax", "spec": "0.28"},
          "package": "\(pkg)",
          "functions": [
            {"fn": "\(fn)", "inferred": ["\(effect)"], "direct": ["\(effect)"], "calls": []}
          ],
          "analyzed": {"count": 1}
        }
        """
    }

    private func p(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    // ── FILE: that file, never the sibling union ────────────────────────────────────────────────────

    /// `gate --report <one sibling file>` judges THAT file: B's Fs must not fire, and `analyzed.count`
    /// is that file's count, not the sum. Before ⟨0.28⟩ this exited 1 on `B.doFs` with count 2.
    func testGateOverAFileLocatorReadsOnlyThatFile() throws {
        let r = try ProcessHarness.run(bin, ["gate", "--report", p("r.A.Swift.json"),
                                             "--policy", p("denyfs.policy"), "--json"])
        XCTAssertEqual(r.code, 0, "A carries no Fs, so a file-scoped gate is clean — stderr: \(r.err)")
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(doc["ok"] as? Bool, true)
        XCTAssertEqual((doc["analyzed"] as? [String: Any])?["count"] as? Int, 1,
                       "the count is the named file's, not the sibling union's")
    }

    /// `path` over A's file must not trace a function that lives only in sibling B.
    func testPathOverAFileLocatorCannotSeeTheSibling() throws {
        let r = try ProcessHarness.run(bin, ["path", "B.doFs", "Fs",
                                             "--report", p("r.A.Swift.json"), "--json"])
        XCTAssertEqual(r.code, 2, "B.doFs lives only in the sibling — a file locator must fail loud, "
                       + "never answer from a file the operator did not name")
        XCTAssertTrue(r.err.contains("no function matching"), "stderr: \(r.err)")
    }

    /// …and the file's OWN content still answers, with its §2.2 callgraph sidecar picked up.
    func testPathOverAFileLocatorAnswersFromThatFile() throws {
        let r = try ProcessHarness.run(bin, ["path", "A.doNet", "Net",
                                             "--report", p("r.A.Swift.json"), "--json"])
        XCTAssertEqual(r.code, 0, "stderr: \(r.err)")
        XCTAssertTrue(r.out.contains("A.doNet"))
    }

    /// `gains` resolves each side by the same rule: a file-locator current names only its own
    /// functions. The baseline is a COPY of A placed where no sibling shares its prefix, so under the
    /// pre-⟨0.28⟩ union reading the current side gains `B.doFs` — the assertion fails naming the union,
    /// not vacuously.
    func testGainsOverAFileLocatorReadsOnlyThatFile() throws {
        let baseDir = root.appendingPathComponent("base")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let base = baseDir.appendingPathComponent("old.A.Swift.json")
        try report(pkg: "A", fn: "A.doNet", effect: "Net")
            .write(to: base, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, ["gains", p("r.A.Swift.json"), base.path, "--json"])
        XCTAssertEqual(r.code, 0, "stderr: \(r.err)")
        XCTAssertFalse(r.out.contains("B.doFs"),
                       "the sibling's function surfaced through a FILE locator — the union is back")
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual((doc["gained"] as? [Any])?.count, 0,
                       "A vs a byte-equal baseline gains nothing when the file locator reads one file")
    }

    /// A locator naming a §2.2 SIDECAR resolves to the report it is a sidecar OF — one file, not the
    /// prefix set.
    func testSidecarLocatorResolvesToItsReportFile() throws {
        let r = try ProcessHarness.run(bin, ["path", "A.doNet", "Net",
                                             "--report", p("r.A.Swift.callgraph.json"), "--json"])
        XCTAssertEqual(r.code, 0, "stderr: \(r.err)")
        XCTAssertTrue(r.out.contains("A.doNet"))
        let sib = try ProcessHarness.run(bin, ["path", "B.doFs", "Fs",
                                               "--report", p("r.A.Swift.callgraph.json"), "--json"])
        XCTAssertEqual(sib.code, 2, "a sidecar locator must not widen to the prefix union either")
    }

    /// **THE SIBLING SWEEP the test above never took.** `resolveReportLocator` (`FixCLI.swift`) normalizes
    /// a §2.2 sidecar locator to its report file over `reportSidecarSegments()`'s five reserved names —
    /// `calibrated`, `callgraph`, `hierarchy`, `layerreach`, `locs` — because `--report <a foreign .json>`
    /// is supported and the other three are the SIBLING engines' data segments, never written by this one.
    /// Until this test, only `callgraph` had ever been posed here: a guard-deletion sweep found the other
    /// four each individually removable from that loop (and from the two other hand-written copies of the
    /// same list) with the full suite staying green. Without normalization a sidecar locator falls through
    /// to the file-locator arm UNCHANGED, reads its own (non-report) bytes as a report, and fails — the
    /// same failure the ⟨0.28⟩ fix closed for `callgraph`, reopened per sibling name.
    func testForeignSidecarLocatorsAlsoResolveToTheirReportFile() throws {
        for seg in ["calibrated", "hierarchy", "layerreach", "locs"] {
            let sidecar = root.appendingPathComponent("r.A.Swift.\(seg).json")
            try #"{"placeholder":"\#(seg)"}"#.write(to: sidecar, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: sidecar) }

            let r = try ProcessHarness.run(bin, ["path", "A.doNet", "Net", "--report", sidecar.path, "--json"])
            XCTAssertEqual(r.code, 0, "[\(seg)] a sidecar locator must resolve to its report file: \(r.err)")
            XCTAssertTrue(r.out.contains("A.doNet"), "[\(seg)] stdout: \(r.out)")

            let sib = try ProcessHarness.run(bin, ["path", "B.doFs", "Fs", "--report", sidecar.path, "--json"])
            XCTAssertEqual(sib.code, 2, "[\(seg)] a sidecar locator must not widen to the prefix union either")
        }
    }

    /// A `.json` file locator that names NO existing file fails LOUD — it must not quietly widen to
    /// whatever siblings share its directory.
    func testMissingFileLocatorFailsLoud() throws {
        let r = try ProcessHarness.run(bin, ["path", "A.doNet", "Net",
                                             "--report", p("nosuch.A.Swift.json"), "--json"])
        XCTAssertEqual(r.code, 2)
        XCTAssertTrue(r.err.contains("no report"), "stderr: \(r.err)")
    }

    // ── PREFIX: the whole matching set, unioned ─────────────────────────────────────────────────────

    /// The prefix form still unions the sibling set — the ⟨0.24⟩ behaviour, untouched by the file rule.
    func testPrefixLocatorStillUnionsTheSiblingSet() throws {
        let r = try ProcessHarness.run(bin, ["gate", "--report", p("r"),
                                             "--policy", p("denyfs.policy"), "--json"])
        XCTAssertEqual(r.code, 1, "the prefix names BOTH reports, so B's Fs fires — stderr: \(r.err)")
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual((doc["analyzed"] as? [String: Any])?["count"] as? Int, 2)
        XCTAssertTrue(r.out.contains("B.doFs"))
    }

    // ── DIRECTORY: what discovery finds ─────────────────────────────────────────────────────────────

    /// A directory locator resolves to `<dir>/.candor/report…` — the discovery spelling.
    func testDirectoryLocatorResolvesToDotCandorDiscovery() throws {
        let cdir = root.appendingPathComponent("proj/.candor")
        try FileManager.default.createDirectory(at: cdir, withIntermediateDirectories: true)
        try report(pkg: "P", fn: "P.go", effect: "Net")
            .write(to: cdir.appendingPathComponent("report.P.Swift.json"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, ["path", "P.go", "Net",
                                             "--report", p("proj"), "--json"])
        XCTAssertEqual(r.code, 0, "stderr: \(r.err)")
        XCTAssertTrue(r.out.contains("P.go"))
    }
}
