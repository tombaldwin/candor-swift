import XCTest
import Foundation

/// ⟨0.29⟩ THE `only <A> -> <B> [<C> …]` PERMISSION FORM (SPEC §6.2, AS-EFF-011).
///
/// **`forbid` FAILS OPEN; `only` FAILS SAFE.** A dependency you forgot to prohibit is silently permitted,
/// so "this package is a leaf" could only be spelled by enumerating what it must not reach — an ALLOWLIST
/// in the unsafe direction, because a package added tomorrow is not on the list and nothing says so. That
/// is the hazard candor refuses everywhere in the analysis, sitting in the POLICY LANGUAGE. Found by
/// pointing candor's own architecture gate at candor, where the natural
/// `forbid <pkg>.model -> <pkg>` self-fires: a scope matches a contiguous run of segments, and `model`
/// sits under the very prefix it is trying to protect itself from.
final class OnlyPermissionProcessTests: XCTestCase {

    private var bin: URL!
    private var dir: URL!

    override func setUpWithError() throws {
        bin = try ProcessHarness.binaryURL(for: Self.self)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("candor-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/S"),
                                                withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "S", targets: [.target(name: "S")])
        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // `model` reaches `util` and `infra`; `util` itself reaches `deep`, which no rule ever permits —
        // the fixture for the stop-at-permitted rule.
        try """
        enum model {
          static func shape() -> Int { return util.helper() }
          static func leaks() -> Int { return infra.dbRead() }
        }
        enum util { static func helper() -> Int { return deep.inner() } }
        enum infra { static func dbRead() -> Int { return 9 } }
        enum deep { static func inner() -> Int { return 1 } }
        """.write(to: dir.appendingPathComponent("Sources/S/a.swift"), atomically: true, encoding: .utf8)
        try "only model -> util\n".write(to: dir.appendingPathComponent("short.policy"),
                                         atomically: true, encoding: .utf8)
        try "only model -> util infra\n".write(to: dir.appendingPathComponent("full.policy"),
                                               atomically: true, encoding: .utf8)
        try "only nosuch -> util\n".write(to: dir.appendingPathComponent("zero.policy"),
                                          atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func p(_ rel: String) -> String { dir.appendingPathComponent(rel).path }

    /// The form's whole point: what the list omits is a violation, what it names is not — and the tail is
    /// a LIST, which is the one ergonomic difference from `forbid`.
    func testWhatThePermissionListOmitsIsAViolation() throws {
        let bad = try ProcessHarness.run(bin, [dir.path, "--out", p("r"), "--policy", p("short.policy")])
        XCTAssertEqual(bad.code, 1, bad.out + bad.err)
        // ⟨0.29⟩ ITS OWN CODE, both halves: 011 present AND 009 absent — a suppression written for a
        // `forbid` crossing must not silently mute this.
        XCTAssertTrue((bad.out + bad.err).contains("AS-EFF-011"), bad.out + bad.err)
        XCTAssertFalse((bad.out + bad.err).contains("AS-EFF-009"),
                       "an `only` violation must not also carry `forbid`'s code: \(bad.out)\(bad.err)")
        XCTAssertTrue((bad.out + bad.err).contains("infra.dbRead"),
                      "the message must name what was reached: \(bad.out)\(bad.err)")
        XCTAssertTrue((bad.out + bad.err).contains("only model -> util"),
                      "…and the rule that says so: \(bad.out)\(bad.err)")

        let ok = try ProcessHarness.run(bin, [dir.path, "--out", p("r2"), "--policy", p("full.policy")])
        XCTAssertEqual(ok.code, 0, ok.out + ok.err)
    }

    /// THE WALK STOPS AT A PERMITTED SCOPE, and this row pins it. `util` is permitted and itself reaches
    /// `deep`, which nothing permits. If the walk descended past a permitted scope this would fire, and
    /// `only` would demand the transitive closure of everything you permit — the same
    /// enumeration-that-rots one level down, which would make the form useless for the leaf case it
    /// exists for. A permitted callee's own dependencies are governed by the rules about IT.
    func testAPermittedScopesOwnDependenciesAreNotThisRulesBusiness() throws {
        let r = try ProcessHarness.run(bin, [dir.path, "--out", p("r3"), "--policy", p("full.policy")])
        XCTAssertEqual(r.code, 0, "`deep` sits BEYOND a permitted scope: \(r.out)\(r.err)")
        XCTAssertFalse((r.out + r.err).contains("deep"), r.out + r.err)
    }

    /// ZERO-MATCH IS MEASURED ON `from`, deliberately NOT on either endpoint the way a `forbid` counts. A
    /// forbid's subject is the pair; an `only`'s subject is the scope it makes a PROMISE about — so a rule
    /// whose destinations all resolve while its `from` names nothing has bound nothing at all, which is
    /// exactly the typo that leaves an operator believing a leaf is protected.
    func testARuleWhoseFromBindsNothingIsDisclosedThoughItsDestinationResolves() throws {
        let r = try ProcessHarness.run(bin, [dir.path, "--out", p("r4"), "--policy", p("zero.policy")])
        XCTAssertEqual(r.code, 0, "a zero-match rule is a DISCLOSURE, never a verdict change")
        XCTAssertTrue(r.err.contains("matched NO function"),
                      "`util` resolves, so counting either endpoint would have hidden this: \(r.err)")
        XCTAssertTrue(r.err.contains("only nosuch -> util"), r.err)
    }

    /// An `only`-only policy is ARMED: it must not trip the ⟨0.28⟩ zero-rule refusal, whose own doc
    /// comment says a check reading a SUBSET of the rule kinds is the false-answer shape it exists to
    /// close. A kind added by a later rung has to reach it.
    func testAnOnlyOnlyPolicyIsNotAZeroRuleFile() throws {
        let r = try ProcessHarness.run(bin, [dir.path, "--out", p("r5"), "--policy", p("full.policy")])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertFalse(r.err.contains("NO RULES"),
                       "the policy is armed — refusing it would be the fail-closed guard turned into a "
                       + "false refusal by the rung that added the kind: \(r.err)")
    }

    /// REFUSED ON A REPORT ROUTE, exit 2 — and for a STRICTER reason than `forbid`'s. Both match on NAME,
    /// which a report's effect-relevant wire cannot settle; but `forbid` asks whether ONE named crossing
    /// is present, while `only` asks whether EVERYTHING reached is on a list, so a report that omits a
    /// crossing turns a green into a claim of COMPLETENESS. The advisory arms are here because that is
    /// where this class of defect hides — the gate got §3.1's rule and its siblings did not.
    func testAReportRouteRefusesAnOnlyRuleRatherThanEvaluatingIt() throws {
        _ = try ProcessHarness.run(bin, [dir.path, "--out", p("g")])
        let report = try XCTUnwrap(
            (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .first { $0.hasPrefix("g.") && $0.hasSuffix(".Swift.json")
                         && !$0.contains("callgraph") && !$0.contains("hierarchy") && !$0.contains("locs") },
            "the scan wrote no report to gate over")

        let g = try ProcessHarness.run(bin, ["gate", "--report", p(report), "--policy", p("short.policy")])
        XCTAssertEqual(g.code, 2, "an unanswerable rule is refused, never evaluated: \(g.err)")
        XCTAssertTrue((g.out + g.err).contains("only model -> util"), g.out + g.err)
        XCTAssertFalse((g.out + g.err).contains("AS-EFF-011"),
                       "no violation may be drawn from a report for this kind: \(g.out)\(g.err)")

        for verb in ["unverified", "fix-gate"] {
            let a = try ProcessHarness.run(bin, [verb, "--report", p(report),
                                                 "--policy", p("short.policy"), "--strict"])
            XCTAssertEqual(a.code, 2, "\(verb) certified over a rule the gate refuses: \(a.err)")
        }
    }
}
