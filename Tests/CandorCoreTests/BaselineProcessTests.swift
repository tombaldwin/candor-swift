import XCTest
import Foundation

/// Process-level pins for the AS-EFF-005 baseline regression guard (SPEC §7 item 5, Baseline.swift) —
/// semantics mirror candor-java's Policy.checkBaseline exactly. The full exit-code matrix (TESTING.md
/// §2.5): gain → 1, clean → 0, absent → 0 + note, doctored/versionless → 2 WITHOUT evaluating,
/// unparseable → 2, config `baseline` key with a config-home-anchored relative value, the new-fn
/// exemption, and the AS-EFF-005 records joining the --gate-json verdict.
final class BaselineProcessTests: XCTestCase {

    /// A `Billing.charge` that reaches Clock only — the "before" state a baseline is recorded from.
    private static let beforeSrc = """
    import Foundation
    struct Billing { func charge() { _ = Date() } }
    Billing().charge()
    """

    /// The same qual, now ALSO reaching Fs — the regression the guard exists to catch.
    private static let gainedSrc = """
    import Foundation
    struct Billing { func charge() { _ = Date(); try? FileManager.default.removeItem(atPath: "/x") } }
    Billing().charge()
    """

    /// Record a same-build baseline: scan `src` with --json and save the envelope to `to`.
    private func recordBaseline(_ bin: URL, src: String, to: URL) throws {
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "baseline recording scan must be clean — stderr: \(r.err)")
        try r.out.write(to: to, atomically: true, encoding: .utf8)
    }

    // ── gain → [AS-EFF-005] + exit 1; the diagnostic names the GAINED set ─────────────────────────
    func testGainedEffectFailsWithAsEff005() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-base-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: base) }
        try recordBaseline(bin, src: Self.beforeSrc, to: base)

        let root = try ProcessHarness.makePackage(Self.gainedSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": base.path])
        XCTAssertEqual(r.code, 1, "an existing fn gaining an effect must exit 1 — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("[AS-EFF-005]"), "the AS-EFF-005 line is on stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("`Billing.charge` gained effect { Fs } not present in the baseline"),
                      "the diagnostic names the gained set, not the fn's full set: \(r.err)")
    }

    // ── clean (same-build baseline, no gain) → exit 0 ──────────────────────────────────────────────
    func testCleanAgainstOwnBaselineExitsZero() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-base-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: base) }
        try recordBaseline(bin, src: Self.gainedSrc, to: base)

        let root = try ProcessHarness.makePackage(Self.gainedSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": base.path])
        XCTAssertEqual(r.code, 0, "no gain vs the baseline is a clean gate — stderr: \(r.err)")
        XCTAssertFalse(r.err.contains("AS-EFF-005"), "no violation may be reported: \(r.err)")
    }

    // ── a NEW function is exempt (reviewed as new code, not a regression) ──────────────────────────
    func testNewFunctionIsExempt() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-base-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: base) }
        try recordBaseline(bin, src: Self.beforeSrc, to: base)

        // `charge` unchanged; `wipe` is NEW (absent from the baseline) and effectful.
        let root = try ProcessHarness.makePackage("""
        import Foundation
        struct Billing { func charge() { _ = Date() } }
        func wipe() { try? FileManager.default.removeItem(atPath: "/x") }
        Billing().charge(); wipe()
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": base.path])
        XCTAssertEqual(r.code, 0, "a new fn is exempt from the ratchet — stderr: \(r.err)")
        XCTAssertFalse(r.err.contains("AS-EFF-005"), "no violation for a new fn: \(r.err)")
    }

    // ── absent baseline file → stderr note, guard inactive, exit 0 ─────────────────────────────────
    func testAbsentBaselineIsANoteAndExitZero() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.gainedSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("no-such-baseline.json")
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": missing.path])
        XCTAssertEqual(r.code, 0, "an absent baseline is 'ratchet not adopted', not a failure — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("does not exist") && r.err.contains("regression guard is not active"),
                      "the note discloses the inactive guard: \(r.err)")
    }

    // ── a DOCTORED producing version → exit 2 WITHOUT evaluating (§2.1: cross-build is invalid input) ─
    func testCrossBuildBaselineRefusesToEvaluate() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-base-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: base) }
        try recordBaseline(bin, src: Self.beforeSrc, to: base)
        // Doctor the envelope's producing version — the report is otherwise perfectly parseable.
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: base)) as! [String: Any]
        var candor = obj["candor"] as! [String: Any]
        candor["version"] = "candor-doctored-0.0.0"
        obj["candor"] = candor
        try JSONSerialization.data(withJSONObject: obj).write(to: base)

        // The scan HAS a gain vs this baseline — it must NOT be evaluated (exit 2, no AS-EFF-005 wave).
        let root = try ProcessHarness.makePackage(Self.gainedSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": base.path])
        XCTAssertEqual(r.code, 2, "a cross-build baseline is invalid gate input — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("was produced by engine build candor-doctored-0.0.0"),
                      "the diagnostic names both builds: \(r.err)")
        // The refusal prose itself names AS-EFF-005 — assert no VIOLATION LINE (the `[code]` form).
        XCTAssertFalse(r.err.contains("[AS-EFF-005]"), "must exit WITHOUT evaluating — no violation wave: \(r.err)")
    }

    // ── a VERSIONLESS (legacy bare-array) baseline → exit 2 (no provenance to compare, §2.1) ────────
    func testVersionlessBaselineRefusesToEvaluate() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.gainedSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("bare.json")
        try #"[{"fn": "Billing.charge", "inferred": ["Clock"]}]"#.write(to: base, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": base.path])
        XCTAssertEqual(r.code, 2, "a versionless baseline cannot be trusted — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("no provenance header"), "stderr: \(r.err)")
        XCTAssertFalse(r.err.contains("[AS-EFF-005]"), "must exit WITHOUT evaluating: \(r.err)")
    }

    // ── an UNPARSEABLE baseline → exit 2 (present-but-corrupt must never silently disable the guard) ─
    func testUnparseableBaselineFailsClosed() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.gainedSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("garbage.json")
        try "{not json".write(to: base, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": base.path])
        XCTAssertEqual(r.code, 2, "a corrupt baseline is invalid gate input, never a silent pass — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("could not be parsed"), "stderr: \(r.err)")
    }

    // ── config `baseline` key: a RELATIVE value anchors to the config's home dir, from ANY cwd ──────
    func testConfigBaselineKeyWithRelativeAnchor() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.gainedSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let candorDir = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candorDir, withIntermediateDirectories: true)
        try recordBaseline(bin, src: Self.beforeSrc, to: candorDir.appendingPathComponent("base.json"))
        // `.candor/base.json` is CONFIG-HOME-relative (the dir holding `.candor/`), like `policy`.
        try "baseline .candor/base.json\n".write(to: candorDir.appendingPathComponent("config"),
                                                 atomically: true, encoding: .utf8)
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let r = try ProcessHarness.run(bin, [root.path, "--json"], cwd: elsewhere)
        XCTAssertEqual(r.code, 1, "the checked-in config's baseline gates from ANY cwd — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("[AS-EFF-005]") && r.err.contains("Billing.charge"),
                      "the gain fires through the config surface: \(r.err)")
    }

    // ── the AS-EFF-005 records join the --gate-json verdict (same list as the exit code) ────────────
    func testBaselineViolationJoinsGateJsonVerdict() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-base-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: base) }
        try recordBaseline(bin, src: Self.beforeSrc, to: base)

        let root = try ProcessHarness.makePackage(Self.gainedSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let verdict = root.appendingPathComponent("verdict.json")
        let r = try ProcessHarness.run(bin, [root.path, "--json", "--gate-json", verdict.path],
                                       env: ["CANDOR_BASELINE": base.path])
        XCTAssertEqual(r.code, 1)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict)) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, false, "the verdict agrees with the exit code")
        let viols = obj?["violations"] as? [[String: Any]] ?? []
        XCTAssertEqual(viols.count, 1, "one AS-EFF-005 record: \(viols)")
        XCTAssertEqual(viols.first?["rule"] as? String, "AS-EFF-005")
        XCTAssertEqual(viols.first?["fn"] as? String, "Billing.charge")
        XCTAssertEqual(viols.first?["effects"] as? [String], ["Fs"], "effects = the GAINED set")
    }
}
