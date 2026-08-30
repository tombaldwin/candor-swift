import XCTest
import Foundation

/// SPEC §2 ⟨0.33⟩/⟨0.34⟩ — the CROSS-POLICY rung, `CandorCore.unaskedCrossPolicyRules`. `excluded[].peeked`
/// says a file was OPENED during the peek; `scannedUnder.deny` says WHICH deny set that peek was bounded
/// by (⟨0.29⟩ only peeks for effects the PRODUCER's own policy denies). A gate applying a DIFFERENT
/// policy to that report cannot treat an empty finding in those files as an answer for a rule the
/// producer's peek was never asked about — `peeked:true` is only true relative to the producer's OWN
/// deny set, not to whatever policy a later `gate --report` run applies.
///
/// This whole rung — three call sites (`GateReportCLI.swift`, `FixCLI.swift`, referenced from
/// `Gate.swift`) built across ⟨0.33⟩ and ⟨0.34⟩ — had ZERO process-level test coverage before this file:
/// no test anywhere constructed a report whose `scannedUnder` deny set does not cover the gating policy's
/// rules. `swift build`, `swift test`, `smoke.sh`, `fabrication_probe.py`, `fuzz.py` and
/// `ci/self-gate.sh` all stay green whether or not `unaskedCrossPolicyRules`'s body does anything at all —
/// none of them exercises a report carrying `scannedUnder`.
final class CrossPolicyRulesProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// A throwaway `.candor/report.App.Swift.json` + policy file, exactly as `gate --report` reads them.
    private func makeReportDir(report: String, policy: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-crosspolicy-\(UUID().uuidString)")
        let candor = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candor, withIntermediateDirectories: true)
        try report.write(to: candor.appendingPathComponent("report.App.Swift.json"), atomically: true, encoding: .utf8)
        try policy.write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        return root
    }

    /// A report whose producer peeked ONE excluded file, bounded by `scannedUnder.deny`. `spec` names
    /// the producing engine's declared `candor.spec`, which decides which of the two ⟨0.34⟩ wordings
    /// fires when the gating policy asks about a rule that set does not cover.
    private func report(scannedUnderDeny: [String], spec: String) -> String {
        let denyJoined = scannedUnderDeny.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"candor":{"spec":"\(spec)","toolchain":"swiftsyntax","version":"candor-swift-0.33.1"},
         "package":"App","analyzed":{"count":1,"digest":"1111111111111111"},
         "excluded":[{"class":"vendored","count":1,"peeked":true,"reason":"vendored code"}],
         "scannedUnder":{"deny":[\(denyJoined)]},
         "functions":[]}
        """
    }

    private func run(_ root: URL) throws -> (out: String, err: String, code: Int32) {
        defer { try? FileManager.default.removeItem(at: root) }
        return try ProcessHarness.run(bin(), ["gate", "--report", root.path, "--policy",
                                               root.appendingPathComponent("pol.txt").path])
    }

    /// The rules the refusal actually NAMES, lifted out of the sentence rather than probed for with a
    /// substring. `nil` when the sentence is not there at all.
    ///
    /// **WHY THIS EXISTS.** The assertion below used to be `XCTAssertFalse(err.contains("Net,"))`, and
    /// `"Net,"` CANNOT OCCUR: `canonicalDenySet` returns its rules lexicographically SORTED, so `Net` is
    /// always last in the list and always followed by `.`, never by `,`. The row therefore could not
    /// fail — MEASURED 2026-08-30 by making `unaskedCrossPolicyRules` return every rule including the
    /// covered one, which is exactly the defect the row is named for: all four rows in this file stayed
    /// GREEN, this one included. A needle that cannot appear is not a weak assertion, it is the ABSENCE
    /// of one wearing the shape of coverage.
    private func namedRules(_ err: String) -> [String]? {
        let head = "rule(s) of this policy: "
        guard let a = err.range(of: head) else { return nil }
        let rest = err[a.upperBound...]
        guard let b = rest.range(of: ". The excluded") else { return nil }
        return rest[..<b.lowerBound].components(separatedBy: ", ").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// THE GAIN. The producer peeked under `deny Net` only; this gate applies `deny Net` AND `deny Db`.
    /// `Db` was never asked, so the verdict must be INCOMPLETE — exit 2, naming `Db` and not `Net`.
    ///
    /// Naming the ASKED rule as unasked is not cosmetic: the remedy the operator is handed is "re-run the
    /// producing scan under THE SAME policy", and a refusal that lists a rule the producer DID hold sends
    /// them to change a policy that was already right. The list is read as a LIST, so this holds whatever
    /// order the canonical set happens to sort into.
    func testUncoveredRuleRefusesAndNamesOnlyTheUnaskedOne() throws {
        let root = try makeReportDir(report: report(scannedUnderDeny: ["deny Net"], spec: "0.33"),
                                      policy: "deny Net\ndeny Db\n")
        let r = try run(root)
        XCTAssertEqual(r.code, 2, "a rule the producer's peek was never asked about must not certify — stdout: \(r.out) stderr: \(r.err)")
        guard let named = namedRules(r.err) else {
            return XCTFail("the refusal must name the uncovered rules in its own sentence — stderr: \(r.err)")
        }
        XCTAssertTrue(named.contains { $0.contains("Db") },
                      "the refusal must name the uncovered rule — named \(named), stderr: \(r.err)")
        XCTAssertFalse(named.contains { $0.contains("Net") },
                       "the ASKED rule (Net) must not be named as uncovered — named \(named), stderr: \(r.err)")
        // …and the COUNT in the sentence must agree with the list beside it. They are separate
        // interpolations of the same array, so a fix that filters one and not the other reads as
        // consistent to a substring test and is not.
        XCTAssertTrue(r.err.contains("cover \(named.count) rule(s) of this policy:"),
                      "the stated count must match the list it introduces — named \(named): \(r.err)")
    }

    /// THE MIRROR — the over-charge control. The SAME producer, but the gating policy asks ONLY `deny
    /// Net`, which the peek's own deny set fully covers. Nothing was left unasked, so the gate must reach
    /// its ordinary green exit rather than refuse on a rule that was, in fact, asked.
    func testFullyCoveredPolicyDoesNotRefuse() throws {
        let root = try makeReportDir(report: report(scannedUnderDeny: ["deny Net"], spec: "0.33"),
                                      policy: "deny Net\n")
        let r = try run(root)
        XCTAssertEqual(r.code, 0, "a fully-covered deny set must not be refused as cross-policy — stdout: \(r.out) stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("policy ✓"), "stderr: \(r.err)")
    }

    /// ⟨0.34⟩ THE WORDING SPLIT. When the ONLY contributing report predates ⟨0.33⟩, the cause is not "a
    /// producer chose a different policy" — it is "no producer here could yet WRITE `scannedUnder` at
    /// all". Both stay exit 2 / INCOMPLETE; only the sentence differs (SPEC ⟨0.34⟩ forbids the age from
    /// moving the verdict itself).
    func testPreThirtyThreeReportNamesItsAgeNotADifferentPolicyChoice() throws {
        let root = try makeReportDir(report: report(scannedUnderDeny: ["deny Net"], spec: "0.32"),
                                      policy: "deny Net\ndeny Db\n")
        let r = try run(root)
        XCTAssertEqual(r.code, 2, "stdout: \(r.out) stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("before ⟨0.33⟩"), "an all-pre-0.33 gap must name its real cause — stderr: \(r.err)")
    }

    /// …and the mirror of THAT: a single ≥⟨0.33⟩ contributor is enough to fall to the ordinary wording,
    /// even though its `spec` alone (0.33) is what the wording split is choosing between.
    func testAtOrAfterThirtyThreeReportNamesThePolicyGapNotItsAge() throws {
        let root = try makeReportDir(report: report(scannedUnderDeny: ["deny Net"], spec: "0.33"),
                                      policy: "deny Net\ndeny Db\n")
        let r = try run(root)
        XCTAssertEqual(r.code, 2, "stdout: \(r.out) stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("does not cover"), "a ≥0.33 contributor names the policy gap — stderr: \(r.err)")
        XCTAssertFalse(r.err.contains("before ⟨0.33⟩"), "stderr: \(r.err)")
    }
}
