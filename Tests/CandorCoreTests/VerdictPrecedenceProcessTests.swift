import XCTest
import Foundation

/// ⟨0.24⟩ **PRECEDENCE BINDS THE VERDICT, NOT THE POLICY GATE — a certain BASELINE regression was deleted
/// by an unrelated refusal, in all four engines** (SPEC §3.1, candor-spec `4c79958`).
///
/// MEASURED 2026-07-28 — a pure function gains an `Fs` call, scanned against a frozen baseline:
///
///     control (no policy)          exit 1, violations: ["AS-EFF-005"]
///     + a policy with a bad token  exit 2, NO `violations` key    ← THE REGRESSION IS DELETED
///
/// A typo in a policy token downgraded *"your change added an effect"* to *"could not evaluate"*, and the
/// regression disappeared from the machine channel. On THIS engine it did not even survive on stderr:
/// the violation lines print BELOW the policy block, so `refuseGateAndExit` ran before them and the
/// finding was lost on both channels. It is fail-LOUD (`ok:false`), so it is not a stale green — it is a
/// lost finding.
///
/// Three individually-correct decisions composed into it: the baseline guard runs first *by design*, the
/// earlier precedence repair was scoped to the policy gate's own violation list, and "a refusal document
/// carries no `violations` key" was justified by every exit-2 site running before anything could be
/// recorded — **a claim about ORDERING that reads as a claim about SHAPE.**
///
/// THE ASSERTION IS ON THE DOCUMENT, not on the exit code. stderr is not the machine channel; a CI job
/// keying on `--gate-json` is exactly the consumer the finding vanished from.
///
/// THE TWO MIRRORS, both pinned below: a SOLE refusal still refuses with no `violations` key (`[]` is the
/// one claim it cannot make), and the refused policy is still NOT EVALUATED — a `deny Fs` standing beside
/// the bad token must not fire, or the relaxation would have converted "could not read this policy" into
/// "enforced it anyway".
final class VerdictPrecedenceProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// A package whose `work` is PURE, scanned to a frozen baseline; `work` then gains an `Fs` call.
    /// Returns (root, baselinePath) with the source already mutated, so every row scans the regression.
    private func makeRegressedFixture() throws -> (root: URL, baseline: String) {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func work() -> Int { return 1 + 1 }
        func other() { _ = try? String(contentsOfFile: "/etc/other", encoding: .utf8) }
        """)
        let base = root.appendingPathComponent("base")
        let r = try ProcessHarness.run(bin(), [root.path, "--out", base.path])
        XCTAssertEqual(r.code, 0, "the baseline scan must be clean: \(r.err)")
        let baselineFile = base.path + ".App.Swift.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: baselineFile), "baseline not written: \(r.err)")
        // `work` GAINS Fs — the AS-EFF-005 regression.
        try """
        import Foundation
        func work() -> Int {
            _ = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)
            return 1 + 1
        }
        func other() { _ = try? String(contentsOfFile: "/etc/other", encoding: .utf8) }
        """.write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        return (root, baselineFile)
    }

    private func verdict(_ url: URL) throws -> [String: Any] {
        guard let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            XCTFail("--gate-json at \(url.path) is not a JSON object"); return [:]
        }
        return d
    }

    // ── THE CONTROL. Without it the rows below cannot tell a repaired verdict from an inert fixture ──

    func testTheControlChargesTheBaselineRegression() throws {
        let f = try makeRegressedFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let v = f.root.appendingPathComponent("v.json")
        let r = try ProcessHarness.run(bin(), [f.root.path, "--out", f.root.appendingPathComponent("r").path,
                                               "--gate-json", v.path],
                                       env: ["CANDOR_BASELINE": f.baseline])
        XCTAssertEqual(r.code, 1, "control: `work` gained Fs. stderr: \(r.err)")
        let d = try verdict(v)
        XCTAssertEqual((d["violations"] as? [[String: Any]])?.first?["rule"] as? String, "AS-EFF-005")
    }

    // ── THE ROW. The assertion is that the violation is IN THE DOCUMENT ─────────────────────────────

    func testAPolicyTokenErrorDoesNotDeleteTheBaselineRegressionFromTheDocument() throws {
        let f = try makeRegressedFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let pol = f.root.appendingPathComponent("pol.txt")
        try "deny Unknown[dispatch,nativ]\n".write(to: pol, atomically: true, encoding: .utf8)
        let v = f.root.appendingPathComponent("v.json")
        let r = try ProcessHarness.run(bin(), [f.root.path, "--out", f.root.appendingPathComponent("r").path,
                                               "--policy", pol.path, "--gate-json", v.path],
                                       env: ["CANDOR_BASELINE": f.baseline])
        XCTAssertEqual(r.code, 1, "a certain violation dominates a refusal (SPEC §3.1). stderr: \(r.err)")
        let d = try verdict(v)
        let vs = d["violations"] as? [[String: Any]]
        XCTAssertEqual(vs?.count, 1, "THE REGRESSION MUST BE IN THE DOCUMENT — stderr is not the machine "
                       + "channel, and a CI job keying on --gate-json is the consumer it vanished from: \(d)")
        XCTAssertEqual(vs?.first?["rule"] as? String, "AS-EFF-005")
        XCTAssertNil(d["refused"], "the run ENDED with a refusal it could not evaluate, but it did not "
                     + "evaluate NOTHING — the refusal arm must not conflate the two: \(d)")
        XCTAssertEqual(d["ok"] as? Bool, false)
        // …and the refusal is NOT swallowed: the human channel still says the policy went unevaluated.
        XCTAssertTrue(r.err.contains("`nativ`"), "the refusal must still be disclosed: \(r.err)")
    }

    /// The same defect through a DIFFERENT exit-2 cause, because the rule is over the verdict rather than
    /// over one refusal site: an UNREADABLE policy beside an established regression.
    func testAnUnreadablePolicyDoesNotDeleteTheBaselineRegressionEither() throws {
        let f = try makeRegressedFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let v = f.root.appendingPathComponent("v.json")
        let r = try ProcessHarness.run(bin(), [f.root.path, "--out", f.root.appendingPathComponent("r").path,
                                               "--policy", f.root.appendingPathComponent("nope.txt").path,
                                               "--gate-json", v.path],
                                       env: ["CANDOR_BASELINE": f.baseline])
        XCTAssertEqual(r.code, 1, "stderr: \(r.err)")
        let d = try verdict(v)
        XCTAssertEqual((d["violations"] as? [[String: Any]])?.count, 1,
                       "an unreadable policy is a refusal like any other, and the rule is over the VERDICT: \(d)")
    }

    // ── THE MIRRORS ────────────────────────────────────────────────────────────────────────────────

    /// A SOLE refusal — nothing was established — still refuses, and the document still carries NO
    /// `violations` key. `[]` is precisely the claim it cannot make: every consumer reads an empty array
    /// as "we looked and found none".
    func testASoleRefusalStillRefusesWithNoViolationsKey() throws {
        let f = try makeRegressedFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let pol = f.root.appendingPathComponent("pol.txt")
        try "deny Unknown[dispatch,nativ]\n".write(to: pol, atomically: true, encoding: .utf8)
        let v = f.root.appendingPathComponent("v.json")
        let r = try ProcessHarness.run(bin(), [f.root.path, "--out", f.root.appendingPathComponent("r").path,
                                               "--policy", pol.path, "--gate-json", v.path])   // no baseline
        XCTAssertEqual(r.code, 2, "with nothing established there is genuinely no verdict. stderr: \(r.err)")
        let d = try verdict(v)
        XCTAssertEqual(d["refused"] as? Bool, true)
        XCTAssertFalse(d.keys.contains("violations"), "ABSENT, not empty: \(d)")
    }

    /// **THE FAIL-OPEN MIRROR.** The refused policy must still go UNEVALUATED. A `deny Fs` standing beside
    /// the bad token would fire on both functions here — if the relaxation let the policy run, "could not
    /// read this policy" would have quietly become "enforced it anyway", which is the opposite error and
    /// the more dangerous one (it enforces a rule the operator did not write).
    func testTheRefusedPolicyIsStillNotEvaluated() throws {
        let f = try makeRegressedFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let pol = f.root.appendingPathComponent("pol.txt")
        try "deny Fs\ndeny Unknown[dispatch,nativ]\n".write(to: pol, atomically: true, encoding: .utf8)
        let v = f.root.appendingPathComponent("v.json")
        let r = try ProcessHarness.run(bin(), [f.root.path, "--out", f.root.appendingPathComponent("r").path,
                                               "--policy", pol.path, "--gate-json", v.path],
                                       env: ["CANDOR_BASELINE": f.baseline])
        XCTAssertEqual(r.code, 1, "stderr: \(r.err)")
        let rules = ((try verdict(v))["violations"] as? [[String: Any]])?.compactMap { $0["rule"] as? String }
        XCTAssertEqual(rules, ["AS-EFF-005"], "ONLY what was already certain. A `deny Fs` in a policy the "
                       + "engine refused to read must NOT fire — the policy is unevaluated, not enforced. "
                       + "Got: \(String(describing: rules))")
    }
}
