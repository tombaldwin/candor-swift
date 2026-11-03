import XCTest
import Foundation

/// SPEC §6.2 ⟨0.41⟩ `accept` lines, END TO END through the real binary — both routes, the advisory verbs, and the
/// two properties the rung must not spend: a policy WITHOUT `accept` lines keeps its verdict byte for byte, and
/// every doubt leaves the row red. The matching rows (prefix, effect subset, rule line, twins, class filter) are
/// pinned at the function boundary in `AcceptLinesSettleTests`; this file pins that the routes WIRE them.
final class AcceptLinesProcessTests: XCTestCase {

    private var bin: URL!
    private var dir: URL!

    override func setUpWithError() throws {
        bin = try ProcessHarness.binaryURL(for: Self.self)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("candor-accept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // dao.a does Fs (the known violation), dao.k does Clock (keeps `deny Fs dao` bound), dao.ab is a NEIGHBOUR
        // whose name merely starts with dao.a.
        try """
        {
          "candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.40"},
          "functions": [
            {"fn": "dao.a", "hash": "ha", "inferred": ["Fs"], "direct": ["Fs"], "calls": []},
            {"fn": "dao.k", "hash": "hk", "inferred": ["Clock"], "direct": ["Clock"], "calls": []}
          ],
          "analyzed": {"count": 3}
        }
        """.write(to: dir.appendingPathComponent("r.json"), atomically: true, encoding: .utf8)
        try """
        {
          "candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.40"},
          "functions": [
            {"fn": "dao.ab", "hash": "hab", "inferred": ["Fs"], "direct": ["Fs"], "calls": []},
            {"fn": "dao.k", "hash": "hk", "inferred": ["Clock"], "direct": ["Clock"], "calls": []}
          ],
          "analyzed": {"count": 3}
        }
        """.write(to: dir.appendingPathComponent("neighbour.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func p(_ rel: String) -> String { dir.appendingPathComponent(rel).path }
    private func policy(_ name: String, _ lines: [String]) throws -> String {
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return p(name)
    }
    private func doc(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], out)
    }
    private func gate(_ report: String, _ pol: String) throws -> (doc: [String: Any], code: Int32, err: String) {
        let r = try ProcessHarness.run(bin, ["gate", "--report", report, "--policy", pol, "--json"])
        return (try doc(r.out), r.code, r.err)
    }

    private let accept = "accept dao.a Fs for deny Fs dao because known since 2026"

    // ── the rung's one move ───────────────────────────────────────────────────────────────────────────

    func testAnAcceptedViolationLeavesViolationsAndIsListed() throws {
        let g = try gate(p("r.json"), try policy("a.pol", ["deny Fs dao", accept]))
        XCTAssertEqual(g.code, 0, g.err)
        XCTAssertEqual(g.doc["ok"] as? Bool, true)
        XCTAssertEqual((g.doc["violations"] as? [Any])?.count, 0)
        let acc = try XCTUnwrap(g.doc["accepted"] as? [[String: Any]])
        XCTAssertEqual(acc.count, 1)
        XCTAssertEqual(acc[0]["rule"] as? String, "AS-EFF-006")
        XCTAssertEqual(acc[0]["fn"] as? String, "dao.a")
        XCTAssertEqual(acc[0]["hash"] as? String, "ha")
        XCTAssertEqual(acc[0]["effects"] as? [String], ["Fs"])
        XCTAssertEqual(acc[0]["line"] as? Int, 2)
        XCTAssertEqual(acc[0]["policyRule"] as? String, "deny Fs dao")
        XCTAssertEqual(acc[0]["because"] as? String, "known since 2026")
        XCTAssertEqual(acc[0]["status"] as? String, "accepted")
        XCTAssertNil(g.doc["ignored"], "a valid directive is not a dropped line")
        XCTAssertTrue(g.err.contains("1 violation(s) accepted by policy; 0 new"),
                      "the human channel prints the COUNT on every run with an accepted row: \(g.err)")
    }

    /// THE CONTROL: the same policy without the directive is red — the acceptance, not the fixture, flipped it.
    func testWithoutTheLineTheSamePolicyIsRedAndCarriesNoAcceptedKey() throws {
        let g = try gate(p("r.json"), try policy("c.pol", ["deny Fs dao"]))
        XCTAssertEqual(g.code, 1, g.err)
        XCTAssertNil(g.doc["accepted"])
    }

    /// ◆ over-accept through the real binary: `dao.a` must not accept `dao.ab`.
    func testAPrefixNeighbourStaysRedAndTheEntryIsStale() throws {
        let g = try gate(p("neighbour.json"), try policy("n.pol", ["deny Fs dao", accept]))
        XCTAssertEqual(g.code, 1, g.err)
        let rules = (g.doc["violations"] as? [[String: Any]] ?? []).map { ($0["rule"] as? String ?? "") + ":" + ($0["fn"] as? String ?? "") }
        XCTAssertEqual(Set(rules), ["AS-EFF-006:dao.ab", "AS-EFF-012:dao.a"], "\(rules)")
        let stale = (g.doc["violations"] as? [[String: Any]] ?? []).first { ($0["rule"] as? String) == "AS-EFF-012" }
        XCTAssertTrue((stale?["detail"] as? String ?? "").contains("Delete line 2"), "the stale row names its remedy: \(String(describing: stale))")
        XCTAssertEqual((g.doc["accepted"] as? [Any])?.count, 0, "`accepted` is present and empty: a stale entry is a violation row, not an item")
    }

    /// A rule the `gate --report` route cannot evaluate (`forbid`) is unevaluated, and an accepted row beside it is
    /// NOT an established violation: exit 2 with the refusal document, which carries neither key.
    func testAcceptedBesideARefusedRuleIsExitTwoNotZeroNotOne() throws {
        let g = try gate(p("r.json"), try policy("f.pol", ["deny Fs dao", accept, "forbid dao -> infra"]))
        XCTAssertEqual(g.code, 2, g.err)
        XCTAssertEqual(g.doc["refused"] as? Bool, true)
        XCTAssertNil(g.doc["violations"]); XCTAssertNil(g.doc["accepted"])
        XCTAssertTrue(g.err.contains("1 violation(s) accepted by policy"), "the human channel still prints the count: \(g.err)")
    }

    func testAnEntryNamingARefusedRuleIsUnjudgedAndAcceptsNothing() throws {
        let g = try gate(p("r.json"), try policy("u.pol", ["deny Fs dao", "forbid dao -> infra",
                                                          "accept dao.a for forbid dao -> infra because x"]))
        XCTAssertEqual(g.code, 1, g.err)
        let acc = try XCTUnwrap(g.doc["accepted"] as? [[String: Any]])
        XCTAssertEqual(acc.map { $0["status"] as? String }, ["unjudged"])
        XCTAssertEqual((g.doc["violations"] as? [[String: Any]])?.count, 1, "the deny Fs row stays")
    }

    func testAnAcceptOnlyPolicyStillRefusesAtExitTwo() throws {
        let g = try gate(p("r.json"), try policy("o.pol", [accept]))
        XCTAssertEqual(g.code, 2, g.err)
        XCTAssertEqual(g.doc["refused"] as? Bool, true)
    }

    func testATypoedEffectIsThePolicyErrorAtExitTwo() throws {
        let r = try ProcessHarness.run(bin, ["gate", "--report", p("r.json"), "--policy",
                                             try policy("t.pol", ["deny Fs dao", "accept dao.a Fss for deny Fs dao because x"]), "--json"])
        XCTAssertEqual(r.code, 2, r.err)
        XCTAssertNil(try doc(r.out)["accepted"])
    }

    func testMalformedLinesAreListedInIgnoredAndTheViolationStays() throws {
        let g = try gate(p("r.json"), try policy("m.pol", ["deny Fs dao", "accept dao.a Fs for deny Fs dao",
                                                          "accept dao.a Fs for deny Fs app because x"]))
        XCTAssertEqual(g.code, 1, g.err)
        XCTAssertNil(g.doc["accepted"], "no line became an entry")
        XCTAssertEqual((g.doc["ignored"] as? [[String: Any]])?.compactMap { $0["line"] as? Int }, [2, 3])
    }

    // ── the two routes agree (§3.1) ─────────────────────────────────────────────────────────────────────

    func testScanAndGateReportAnswerTheSameOverTheReportTheScanWrote() throws {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func doFs() { _ = FileManager.default.contents(atPath: "/x") }
        func other() { _ = FileManager.default.contents(atPath: "/y") }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = try policy("s.pol", ["deny Fs", "accept doFs Fs for deny Fs because known"])
        let out = p("scan-out")
        let s = try ProcessHarness.run(bin, [root.path, "--policy", pol, "--gate-json", p("s.json"), "--out", out])
        XCTAssertEqual(s.code, 1, "`other` is not accepted: \(s.err)")
        let sd = try doc(try String(contentsOfFile: p("s.json"), encoding: .utf8))
        let r = try ProcessHarness.run(bin, ["gate", "--report", out, "--policy", pol, "--gate-json", p("g.json")])
        XCTAssertEqual(r.code, 1, r.err)
        let gd = try doc(try String(contentsOfFile: p("g.json"), encoding: .utf8))
        func canon(_ v: Any?) -> String {
            guard let v, let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "nil" }
            return String(decoding: d, as: UTF8.self)
        }
        XCTAssertEqual(canon(sd["accepted"]), canon(gd["accepted"]), "`accepted` is in the EVALUATED PROJECTION: byte-equal on both routes")
        XCTAssertEqual(canon(sd["violations"]), canon(gd["violations"]))
        let acc = try XCTUnwrap(sd["accepted"] as? [[String: Any]])
        XCTAssertEqual(acc.map { $0["fn"] as? String }, ["doFs"])
        XCTAssertEqual((sd["violations"] as? [[String: Any]])?.map { $0["fn"] as? String }, ["other"])
        XCTAssertTrue(s.err.contains("1 violation(s) accepted by policy; 1 new"), s.err)
    }

    /// An unanalysable source makes the run INCOMPLETE; with nothing left in `violations` that is exit 2, and the
    /// document then makes no claim about violations — neither `violations` nor `accepted` — but ONLY when the
    /// policy carries an entry (a policy without the directive keeps `violations: []`, byte-identical).
    func testIncompleteWithNothingLeftIsExitTwoAndWithholdsBothKeysOnlyWhenEntriesExist() throws {
        let root = try ProcessHarness.makeFilesPackage([
            "main.swift": "import Foundation\nfunc doFs() { _ = FileManager.default.contents(atPath: \"/x\") }\n",
            "broken.swift": "func (( {\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let withAccept = try policy("i1.pol", ["deny Fs", "accept doFs Fs for deny Fs because known"])
        let a = try ProcessHarness.run(bin, [root.path, "--policy", withAccept, "--gate-json", "-"])
        XCTAssertEqual(a.code, 2, a.err)
        let ad = try doc(a.out)
        XCTAssertEqual(ad["incomplete"] as? Bool, true)
        XCTAssertNil(ad["violations"]); XCTAssertNil(ad["accepted"])
        let without = try policy("i2.pol", ["deny Fs"])
        let b = try ProcessHarness.run(bin, [root.path, "--policy", without, "--gate-json", "-"])
        // control: here `doFs` is a real violation (exit 1); the no-entry incomplete document is covered by the
        // existing completeness tests — assert only that the key set is unchanged for a policy without `accept`.
        XCTAssertEqual(b.code, 1, b.err)
        XCTAssertNotNil(try doc(b.out)["violations"])
        XCTAssertNil(try doc(b.out)["accepted"])
    }

    // ── no `accept` line ⇒ nothing moves ──────────────────────────────────────────────────────────────

    func testAPolicyWithoutAcceptLinesCarriesNoAcceptedKeyOnAnyRoute() throws {
        for pol in [["deny Fs dao"], ["deny Clock dao"], ["pure dao"]] {
            let g = try gate(p("r.json"), try policy("z.pol", pol))
            XCTAssertNil(g.doc["accepted"], "\(pol): \(g.doc)")
            XCTAssertFalse(g.err.contains("accepted by policy"), g.err)
        }
    }

    // ── the advisory verbs ───────────────────────────────────────────────────────────────────────────

    /// `unverified` MUST NOT describe a unit with an accepted violation as clean: `ok` is withheld, the units named.
    func testUnverifiedWithholdsOkOverAnAcceptedUnitAndDoesNotAcceptItself() throws {
        let pol = try policy("v.pol", ["deny Fs dao", accept])
        let r = try ProcessHarness.run(bin, ["unverified", "--report", p("r.json"), "--policy", pol, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        XCTAssertNil(d["ok"], "an accepted violation is still a violation, only a reviewed one: \(r.out)")
        XCTAssertEqual(d["accepted"] as? [String], ["dao.a"])
        // control: without the line the verb says ok (no Unknown holes anywhere)
        let c = try ProcessHarness.run(bin, ["unverified", "--report", p("r.json"),
                                             "--policy", try policy("v0.pol", ["deny Fs dao"]), "--json"])
        XCTAssertEqual(try doc(c.out)["ok"] as? Bool, true, c.out)
        XCTAssertNil(try doc(c.out)["accepted"])
    }

    /// `fix-gate` follows the gate on a STALE entry (AS-EFF-012, exit 1): it must not exit 0 beside one.
    func testFixGateStrictFollowsTheGateOnAStaleEntry() throws {
        // a rule nothing violates, so the ONLY outstanding finding is the stale entry
        let quiet = try policy("x2.pol", ["deny Rand dao", "accept dao.zzz Rand for deny Rand dao because x"])
        let g = try gate(p("r.json"), quiet)
        XCTAssertEqual(g.code, 1, "the gate fails on the stale entry: \(g.err)")
        let r = try ProcessHarness.run(bin, ["fix-gate", "--report", p("r.json"), "--policy", quiet, "--json", "--strict"])
        XCTAssertEqual(r.code, 1, "fix-gate --strict must not exit 0 where the gate exits 1: \(r.out) \(r.err)")
        XCTAssertNotEqual(try doc(r.out)["ok"] as? Bool, true, "no all-clear beside a stale acceptance: \(r.out)")
        XCTAssertEqual((try doc(r.out)["staleAccepts"] as? [[String: Any]])?.count, 1)
    }
}
