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

    /// THE GAIN. The producer peeked under `deny Net` only; this gate applies `deny Net` AND `deny Db`.
    /// `Db` was never asked, so the verdict must be INCOMPLETE — exit 2, naming `Db` and not `Net`.
    func testUncoveredRuleRefusesAndNamesOnlyTheUnaskedOne() throws {
        let root = try makeReportDir(report: report(scannedUnderDeny: ["deny Net"], spec: "0.33"),
                                      policy: "deny Net\ndeny Db\n")
        let r = try run(root)
        XCTAssertEqual(r.code, 2, "a rule the producer's peek was never asked about must not certify — stdout: \(r.out) stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("Db"), "the refusal must name the uncovered rule — stderr: \(r.err)")
        XCTAssertFalse(r.err.contains("does not cover") && r.err.contains("Net,"),
                       "the ASKED rule (Net) must not be named as uncovered — stderr: \(r.err)")
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
