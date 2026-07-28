import XCTest
import Foundation

/// ⟨0.24⟩ **`unevaluated` IS A DOCUMENT FIELD, NOT A STDERR LINE** (SPEC §3.1, candor-spec `fc4b5f6`).
///
/// The exit-1 clause said the gate "MUST still disclose which rules could not be evaluated" and named no
/// field, no shape and no channel — sitting beside the clause requiring every machine field to be pinned
/// in the rung that introduces it. MEASURED on `deny Fs` + `allow Fs /var/data`, exit 1:
///
///     rust    NOTHING in the document — stderr only
///     swift   NOTHING in the document — stderr only            ← this engine
///     java    "unevaluated": [{"rule": "forbid (× 1)"}]        ← a KIND AGGREGATE; WHICH rules is lost
///     ts      "unevaluated": [{"rule": "<raw line>", "why"}]   ← correct, and the pinned shape
///
/// **A machine consumer of this engine's exit-1 verdict could not see that any rule went unanswered at
/// all** — a finding that never reaches the consumer, arriving through the disclosure this rung added to
/// stop exactly that. stderr is not the machine channel; that is the same distinction that made the
/// ⟨0.21⟩ incomplete-analysis defect a defect.
///
/// `rule` IS THE RAW LINE, and the two-`forbid` row is what makes that assertion bite: java's aggregate
/// collapses two lines to `"forbid (× 2)"`, which answers *how many* when the operator's question is
/// *which*. A `why` that merely MENTIONS the rule is not a field a consumer can read the rule out of.
final class UnevaluatedDisclosureProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// A one-entry report carrying `Fs`, so `deny Fs` FIRES and the exit-1 arm is reachable.
    private func makeReportRoot(_ policy: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-unevald-\(UUID().uuidString)")
        let candor = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candor, withIntermediateDirectories: true)
        try """
        {"candor":{"spec":"0.23","toolchain":"swiftsyntax","version":"handwritten"},
         "package":"App","analyzed":{"count":1,"digest":"1111111111111111"},
         "functions":[{"fn":"app.readIt","loc":"a.swift:1:1","inferred":["Fs"],"direct":["Fs"],
                       "hash":"App#readIt","calls":[],"paths":["/etc/hosts"]}]}
        """.write(to: candor.appendingPathComponent("report.App.Swift.json"), atomically: true, encoding: .utf8)
        try policy.write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        return root
    }

    private func gate(_ root: URL, _ extra: [String] = []) throws -> (doc: [String: Any], code: Int32, err: String) {
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path,
                                               "--json"] + extra)
        let d = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any] ?? [:]
        return (d, r.code, r.err)
    }

    private func unevaluated(_ d: [String: Any]) -> [(rule: String, why: String)] {
        ((d["unevaluated"] as? [[String: Any]]) ?? []).map {
            (rule: $0["rule"] as? String ?? "", why: $0["why"] as? String ?? "")
        }
    }

    // ── THE ROW, exactly as measured ───────────────────────────────────────────────────────────────

    func testTheExitOneVerdictNamesTheRuleItCouldNotEvaluate() throws {
        let root = try makeReportRoot("deny Fs\nallow Fs /var/data\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let g = try gate(root)
        XCTAssertEqual(g.code, 1, "the `deny Fs` fires; the `allow` cannot be evaluated. stderr: \(g.err)")
        XCTAssertEqual((g.doc["violations"] as? [[String: Any]])?.count, 1, "\(g.doc)")
        let u = unevaluated(g.doc)
        XCTAssertEqual(u.count, 1, "the machine consumer must SEE that a rule went unanswered — before "
                       + "this it lived on stderr only, so a CI job keying on --gate-json read a verdict "
                       + "that silently did not answer the policy: \(g.doc)")
        XCTAssertEqual(u.first?.rule, "allow Fs /var/data", "the RAW policy line, verbatim")
        XCTAssertFalse(u.first?.why.isEmpty ?? true, "and why it could not be decided")
    }

    /// **THE ANTI-AGGREGATE ROW.** Two `forbid` lines refused for one reason: the shape must still name
    /// BOTH, because the reference engine's `"forbid (× 2)"` answers "how many" and loses "which".
    func testTwoRulesOfOneKindAreTwoEntriesNotAnAggregate() throws {
        let root = try makeReportRoot("deny Fs\nforbid web -> db\nforbid api -> infra\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let g = try gate(root)
        XCTAssertEqual(g.code, 1, "stderr: \(g.err)")
        let rules = unevaluated(g.doc).map(\.rule).sorted()
        XCTAssertEqual(rules, ["forbid api -> infra", "forbid web -> db"],
                       "ONE ENTRY PER RULE — a kind aggregate loses which lines went unanswered: \(g.doc)")
    }

    /// The SOLE-refusal arm carries it too. Withholding it there would put the whole disclosure back on
    /// stderr in exactly the case where the document says nothing else about the policy.
    func testTheRefusalDocumentAlsoCarriesTheUnevaluatedRules() throws {
        let root = try makeReportRoot("allow Fs /var/data\nforbid web -> db\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let g = try gate(root)
        XCTAssertEqual(g.code, 2, "nothing certain to report. stderr: \(g.err)")
        XCTAssertEqual(g.doc["refused"] as? Bool, true, "\(g.doc)")
        XCTAssertEqual(unevaluated(g.doc).map(\.rule).sorted(), ["allow Fs /var/data", "forbid web -> db"],
                       "\(g.doc)")
        XCTAssertNotNil(g.doc["reason"] as? String, "and `reason` stays a STRING naming the cause: \(g.doc)")
    }

    /// It rides `--gate-json <path>` identically — `--json` IS `--gate-json -`, and a consumer must not
    /// be able to tell the two sinks apart.
    func testItRidesTheGateJsonFileSinkToo() throws {
        let root = try makeReportRoot("deny Fs\nallow Fs /var/data\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("v.json")
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path,
                                               "--gate-json", v.path])
        XCTAssertEqual(r.code, 1, "stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any] ?? [:]
        XCTAssertEqual(unevaluated(d).first?.rule, "allow Fs /var/data", "\(d)")
    }

    // ── THE MIRROR. Omitted when empty, so a fully-answered verdict stays byte-identical ────────────

    func testAFullyAnsweredVerdictHasNoUnevaluatedKeyAtAll() throws {
        let root = try makeReportRoot("deny Fs\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let g = try gate(root)
        XCTAssertEqual(g.code, 1, "stderr: \(g.err)")
        XCTAssertFalse(g.doc.keys.contains("unevaluated"),
                       "OMITTED when empty — an empty array would claim the gate looked for unanswerable "
                       + "rules and is a different statement from having answered everything: \(g.doc)")

        let clean = try makeReportRoot("deny Net\n")
        defer { try? FileManager.default.removeItem(at: clean) }
        let c = try gate(clean)
        XCTAssertEqual(c.code, 0, "stderr: \(c.err)")
        XCTAssertFalse(c.doc.keys.contains("unevaluated"), "…and on a green gate too: \(c.doc)")
    }
}
