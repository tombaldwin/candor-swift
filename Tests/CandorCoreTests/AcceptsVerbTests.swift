import XCTest
import Foundation

/// SPEC §6.2 ⟨0.41⟩ `accepts`, END TO END through the real binary. The cross-engine rows are conformance PART 106;
/// this pins the engine's own wiring: the verb answers from the gate's own facts, writes no file, can only accept
/// less, and its refusals and usage errors say what they are.
final class AcceptsVerbTests: XCTestCase {
    private var bin: URL!
    private var dir: URL!

    override func setUpWithError() throws {
        bin = try ProcessHarness.binaryURL(for: Self.self)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("candor-accepts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // dao.a does Fs and Clock; dao.k does Clock (keeps `deny Fs Clock dao` bound).
        try """
        {
          "candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.40"},
          "functions": [
            {"fn": "dao.a", "hash": "ha", "inferred": ["Fs"], "direct": ["Fs"], "calls": []},
            {"fn": "dao.b", "hash": "hb", "inferred": ["Fs", "Clock"], "direct": ["Fs", "Clock"], "calls": []},
            {"fn": "dao.k", "hash": "hk", "inferred": ["Clock"], "direct": ["Clock"], "calls": []}
          ],
          "analyzed": {"count": 3}
        }
        """.write(to: dir.appendingPathComponent("r.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func p(_ rel: String) -> String { dir.appendingPathComponent(rel).path }
    private func policy(_ name: String, _ text: String) throws -> String {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return p(name)
    }
    private func accepts(_ pol: String, _ extra: [String] = []) throws -> (out: String, err: String, code: Int32) {
        try ProcessHarness.run(bin, ["accepts", "--report", p("r.json"), "--policy", pol] + extra)
    }

    func testAStaleLineIsDeletedAndNothingElseChanges() throws {
        let pol = try policy("a.pol", "deny Fs dao\naccept dao.zz Fs for deny Fs dao because gone # keep\naccept dao.a Fs for deny Fs dao because known\n")
        let r = try accepts(pol)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.out, "deny Fs dao\naccept dao.a Fs for deny Fs dao because known\n")
    }

    func testTheVerbWritesNoFile() throws {
        let text = "deny Fs dao\naccept dao.zz Fs for deny Fs dao because gone\n"
        let pol = try policy("w.pol", text)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        _ = try accepts(pol, ["--adopt", "--because", "adopted today"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), before)
        XCTAssertEqual(try String(contentsOfFile: pol, encoding: .utf8), text, "the policy file's bytes are unchanged")
    }

    func testAnOverWideEntryIsNarrowedToTheRowsItAccepted() throws {
        let pol = try policy("n.pol", "deny Fs Clock dao\naccept dao.a Fs Clock Net for deny Fs Clock dao because r # why\n")
        let r = try accepts(pol)
        XCTAssertEqual(r.out, "deny Fs Clock dao\naccept dao.a Fs for deny Fs Clock dao because r # why\n")
    }

    /// ◆ an exceeded entry is NEVER widened: the line stays, and a COMMENT proposes the replacement.
    func testAnExceededEntryIsProposedInACommentNeverWidened() throws {
        let pol = try policy("e.pol", "deny Fs Clock dao\naccept dao.b Fs for deny Fs Clock dao because r\n")
        let r = try accepts(pol)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.out, "deny Fs Clock dao\naccept dao.b Fs for deny Fs Clock dao because r\n"
            + "# candor-accepts: exceeded (adds Clock) — REPLACE the line above with: accept dao.b Clock Fs for deny Fs Clock dao because r\n")
        // a second run over its own output prints it unchanged (the verb's comments are regenerated)
        let again = try accepts(try policy("e2.pol", r.out))
        XCTAssertEqual(again.out, r.out)
    }

    /// ◆ a refresh never writes a line for a violation no entry names; --adopt does, with ONLY the operator's reason.
    func testAdoptAppendsOneLinePerUnnamedViolationWithTheOperatorsReason() throws {
        let pol = try policy("d.pol", "deny Fs dao")
        let refresh = try accepts(pol)
        XCTAssertEqual(refresh.out, "deny Fs dao", "a refresh adds nothing")
        let r = try accepts(pol, ["--adopt", "--because", "pre-existing   at adoption"])
        XCTAssertEqual(r.out, "deny Fs dao\naccept dao.a Fs for deny Fs dao because pre-existing at adoption\n"
                            + "accept dao.b Fs for deny Fs dao because pre-existing at adoption\n")
    }

    func testJsonCarriesThePlanWhoseTextIsTheProposal() throws {
        let pol = try policy("j.pol", "deny Fs dao\naccept dao.zz Fs for deny Fs dao because gone\n")
        let r = try accepts(pol, ["--json"])
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["mode"] as? String, "refresh")
        XCTAssertEqual(d["text"] as? String, "deny Fs dao\n")
        XCTAssertEqual((d["removed"] as? [[String: Any]])?.first?["line"] as? Int, 2)
        let after = try XCTUnwrap(d["after"] as? [String: Any])
        XCTAssertEqual(after["exit"] as? Int, 1, "two unnamed violations remain red")
        XCTAssertEqual((d["unnamed"] as? [[String: Any]])?.count, 2)
    }

    func testUsageErrors() throws {
        let pol = try policy("u.pol", "deny Fs dao\n")
        XCTAssertEqual(try accepts(pol, ["--strict"]).code, 2)
        XCTAssertEqual(try accepts(pol, ["--because", "x"]).code, 2, "--because without --adopt")
        XCTAssertEqual(try accepts(pol, ["--adopt"]).code, 2, "--adopt without --because")
        XCTAssertEqual(try accepts(pol, ["--adopt", "--because", "see #12"]).code, 2, "a # would cut the reason")
        XCTAssertEqual(try accepts(pol, ["--adopt", "--because", "   "]).code, 2, "no token")
        XCTAssertEqual(try accepts(pol, ["positional"]).code, 2)
        let verb = try ProcessHarness.run(bin, ["accept", "--policy", pol])
        XCTAssertEqual(verb.code, 2)
        XCTAssertTrue(verb.err.contains("accepts"), "`accept` as a verb names `accepts`: \(verb.err)")
    }

    func testAnEmptyPolicyRefusesAndNamesTheRedirectTrap() throws {
        let r = try accepts(try policy("empty.pol", ""))
        XCTAssertEqual(r.code, 2)
        XCTAssertEqual(r.out, "", "no proposal")
        XCTAssertTrue(r.err.contains("redirect") && r.err.contains("EMPTIES"), r.err)
    }

    func testAnUnreadableReportIsExit2WithNoProposalAndNoMarkerFile() throws {
        let r = try ProcessHarness.run(bin, ["accepts", "--report", p("missing.json"), "--policy", try policy("m.pol", "deny Fs dao\n")])
        XCTAssertEqual(r.code, 2)
        XCTAssertEqual(r.out, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p("missing.json.refused.json")), "a verb that writes no file writes no refusal marker")
    }

    /// On this engine the gate derives a reason class for EVERY `Unknown` row (`unresolved` when the report names
    /// none), so the "exceeded by an `Unknown` with no classes" case — where no valid `Unknown[…]` line could be
    /// written and the verb makes no proposal — is a defensive arm that the route cannot reach. What is pinned is
    /// the reachable behaviour: the proposal names the derived class, never an empty `Unknown[]`.
    func testAnExceededUnknownIsProposedWithTheClassTheGateDerived() throws {
        try """
        {"candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.40"},
         "functions": [{"fn": "dao.u", "hash": "hu", "inferred": ["Unknown"], "direct": ["Unknown"], "calls": []}],
         "analyzed": {"count": 1}}
        """.write(to: dir.appendingPathComponent("u.json"), atomically: true, encoding: .utf8)
        let pol = try policy("x.pol", "deny Unknown dao\naccept dao.u Unknown[dispatch] for deny Unknown dao because r\n")
        let r = try ProcessHarness.run(bin, ["accepts", "--report", p("u.json"), "--policy", pol])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("exceeded (adds Unknown[unresolved])"), r.out)
        XCTAssertFalse(r.out.contains("Unknown[]"), r.out)
    }
}
