import Foundation
import XCTest

/// SOUNDNESS R952 (swift half) — a SCOPED `allow` that binds no function is a zero-match like any other scoped
/// rule. Conformance PART 36 cells (c5)–(c7), reproduced here over one Net-reaching fixture:
///   (c5) `allow Net in zzz.nomatch h`  → exit 0, `ok`, the "matched NO function" line, `zeroMatch` names it;
///   (c6) `allow Net in fetch h`        → exit 1 (AS-EFF-008: `fetch` reaches a host off the list), no zeroMatch;
///   (c7) `allow Net h` (SCOPELESS)     → exit 1, no zeroMatch — a scopeless rule binds everything, exempt.
/// And `gate --report` still REFUSES `allow` (exit 2, no zeroMatch). On f01a417 (c5) exited 0 with NO line and
/// NO `zeroMatch` — a gate that cannot fail. `CANDOR_R952_OFF` restores that.
final class AllowZeroMatchProcessTests: XCTestCase {
    static let src = """
    import Foundation
    func fetch() { URLSession.shared.dataTask(with: URL(string: "https://evil.example.com/x")!).resume() }
    fetch()
    """

    private func gate(_ rule: String, env: [String: String] = [:])
        throws -> (code: Int32, err: String, zeroMatch: [String]?, ok: Bool?, root: URL) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.src)
        let pol = root.appendingPathComponent("p.policy"), gj = root.appendingPathComponent("gj.json")
        try (rule + "\n").write(to: pol, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--gate-json", gj.path,
                                             "--out", root.appendingPathComponent("o/r").path], env: env)
        let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: gj))) as? [String: Any]
        return (r.code, r.out + r.err, d?["zeroMatch"] as? [String], d?["ok"] as? Bool, root)
    }

    func testC5AScopedAllowThatBindsNothingIsDisclosed() throws {
        let g = try gate("allow Net in zzz.nomatch h")
        defer { try? FileManager.default.removeItem(at: g.root) }
        XCTAssertEqual(g.code, 0, "exit code is unchanged: a zero-match is disclosed, not refused")
        XCTAssertEqual(g.ok, true)
        XCTAssertTrue(g.err.contains("matched NO function — `allow Net in zzz.nomatch h`"), g.err)
        XCTAssertEqual(g.zeroMatch, ["allow Net in zzz.nomatch h"])
        let off = try gate("allow Net in zzz.nomatch h", env: ["CANDOR_R952_OFF": "1"])
        defer { try? FileManager.default.removeItem(at: off.root) }
        XCTAssertNil(off.zeroMatch, "§1b — the release did not disclose it")
        XCTAssertFalse(off.err.contains("matched NO function"))
    }

    func testC6ABoundScopedAllowStillGates() throws {
        let g = try gate("allow Net in fetch h")
        defer { try? FileManager.default.removeItem(at: g.root) }
        XCTAssertEqual(g.code, 1, g.err)
        XCTAssertTrue(g.err.contains("AS-EFF-008"), g.err)
        XCTAssertNil(g.zeroMatch)
    }

    func testC7AScopelessAllowIsExempt() throws {
        let g = try gate("allow Net h")
        defer { try? FileManager.default.removeItem(at: g.root) }
        XCTAssertEqual(g.code, 1, g.err)
        XCTAssertNil(g.zeroMatch)
        XCTAssertFalse(g.err.contains("matched NO function"))
    }

    func testGateReportStillRefusesAllow() throws {
        let g = try gate("allow Net in fetch h")   // produces the report at o/r.App.Swift.json
        defer { try? FileManager.default.removeItem(at: g.root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = g.root.appendingPathComponent("p2.policy"), gj = g.root.appendingPathComponent("gr.json")
        try "allow Net in zzz.nomatch h\n".write(to: pol, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, ["gate", "--report", g.root.appendingPathComponent("o/r.App.Swift.json").path,
                                             "--policy", pol.path, "--gate-json", gj.path])
        XCTAssertEqual(r.code, 2, r.err)
        let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: gj))) as? [String: Any]
        XCTAssertNil(d?["zeroMatch"])
    }
}
