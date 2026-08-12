import XCTest
import Foundation

/// SPEC §3.3.1 ⟨0.28⟩ — **A REPEATED `--out` IS THE SAME RULE AS THE REPEATED VERDICT SINK**: refused at
/// exit 2, with the fail-closed report at EVERY prefix named. Before the fix this engine took the LAST
/// prefix, so `--out A --out B` scanned into B and left A holding a previous run's whole report set —
/// readable as current, and a `gate --report A` over it answers from a scan that never ran (measured on
/// this engine 2026-08-12: A's report byte-identical to the previous good run, exit 0).
final class RepeatedOutSinkProcessTests: XCTestCase {

    private var bin: URL!
    private var root: URL!

    /// A previous good run's report — carries `candor` + `functions`, so the armer positively
    /// identifies it as its own §2 report.
    private let staleReport =
        #"{"candor":{"version":"x"},"functions":[{"fn":"App.f","inferred":["Net"]}],"analyzed":{"count":1}}"#

    override func setUpWithError() throws {
        bin = try ProcessHarness.binaryURL(for: Self.self)
        root = try ProcessHarness.makePackage("""
        import Foundation
        func doFs() { FileManager.default.createFile(atPath: "/tmp/x", contents: nil) }
        """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The load-bearing half: BOTH prefixes get the fail-closed report. Refusing without arming the
    /// loser leaves its stale set readable as current — most of the defect.
    func testRepeatedOutRefusesAndArmsEveryPrefixNamed() throws {
        let a = root.appendingPathComponent("a.App.Swift.json")
        let b = root.appendingPathComponent("b.App.Swift.json")
        try staleReport.write(to: a, atomically: true, encoding: .utf8)
        try staleReport.write(to: b, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, [root.path,
                                             "--out", root.appendingPathComponent("a").path,
                                             "--out", root.appendingPathComponent("b").path])
        XCTAssertEqual(r.code, 2, r.err)
        XCTAssertTrue(r.err.contains("--out given more than once"),
                      "the diagnostic names the rule: \(r.err)")
        XCTAssertTrue(r.err.contains("a.App") || r.err.contains(root.appendingPathComponent("a").path),
                      "…and every prefix named: \(r.err)")
        for (name, url) in [("a", a), ("b", b)] {
            let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            XCTAssertEqual((doc?["analyzed"] as? [String: Any])?["count"] as? Int, 0,
                           "prefix \(name)'s previous report holds the fail-closed empty — a stale set "
                           + "must not survive readable as current")
            XCTAssertEqual((doc?["functions"] as? [Any])?.count, 0)
        }
    }

    /// Two spellings of ONE prefix are one sink and are NOT refused — the §3.3.1 artifact rule, applied
    /// to the prefix through its (existing) parent directory.
    func testTwoSpellingsOfOnePrefixAreOneSink() throws {
        let r = try ProcessHarness.run(bin, [root.path,
                                             "--out", root.appendingPathComponent("p").path,
                                             "--out", root.path + "/./p"])
        XCTAssertEqual(r.code, 0, "one artifact named twice is not an ambiguity: \(r.err)")
        let report = root.appendingPathComponent("p.App.Swift.json")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        XCTAssertEqual((doc?["analyzed"] as? [String: Any])?["count"] as? Int, 1,
                       "a real report was written — the run scanned")
    }

    /// The refusal is a broken gate config like any other exit-2: a verdict sink named in the same argv
    /// receives the refusal document (not a previous run's green), and the `--json` stream receives the
    /// fail-closed report as its only content.
    func testRepeatedOutRefusalReachesTheVerdictSinkAndTheStream() throws {
        let v = root.appendingPathComponent("v.json")
        try #"{"ok": true}"#.write(to: v, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path,
                                             "--out", root.appendingPathComponent("a").path,
                                             "--out", root.appendingPathComponent("b").path,
                                             "--gate-json", v.path])
        XCTAssertEqual(r.code, 2, r.err)
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
        XCTAssertEqual(doc?["refused"] as? Bool, true,
                       "the pre-seeded green must not survive the refusal")

        let s = try ProcessHarness.run(bin, [root.path,
                                             "--out", root.appendingPathComponent("a").path,
                                             "--out", root.appendingPathComponent("b").path,
                                             "--json"])
        XCTAssertEqual(s.code, 2, s.err)
        let stream = try JSONSerialization.jsonObject(with: Data(s.out.utf8)) as? [String: Any]
        XCTAssertEqual((stream?["analyzed"] as? [String: Any])?["count"] as? Int, 0,
                       "the stream's only content is the fail-closed report, not zero bytes")
    }

    /// The single-`--out` path is untouched: one prefix scans, writes a real report, exits 0.
    func testSingleOutStillScansNormally() throws {
        let r = try ProcessHarness.run(bin, [root.path,
                                             "--out", root.appendingPathComponent("solo").path])
        XCTAssertEqual(r.code, 0, r.err)
        let report = root.appendingPathComponent("solo.App.Swift.json")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        XCTAssertEqual((doc?["analyzed"] as? [String: Any])?["count"] as? Int, 1)
    }
}
