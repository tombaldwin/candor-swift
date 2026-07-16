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
        // The bracketed `[AS-EFF-005]` is the violation-line marker; the ⟨0.16⟩ absent-sidecar note
        // (this baseline was recorded via --json, no sidecar) mentions the rule name in prose, so match
        // the violation FORM, not the bare string.
        XCTAssertFalse(r.err.contains("[AS-EFF-005]"), "no violation may be reported: \(r.err)")
    }

    // ── a NEW function is exempt (reviewed as new code, not a regression) ──────────────────────────
    func testNewFunctionIsExempt() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-base-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: base) }
        try recordBaseline(bin, src: Self.beforeSrc, to: base)

        // `charge` unchanged; `wipe` is NEW (absent from the baseline) and effectful. `wipe` is NOT
        // invoked at the top level — the top-level `<main>` unit must stay identical to the baseline's
        // (calling `wipe()` there would make `<main>` itself gain Fs, a genuine top-level regression the
        // ratchet SHOULD catch — a different property than "a new function is exempt").
        let root = try ProcessHarness.makePackage("""
        import Foundation
        struct Billing { func charge() { _ = Date() } }
        func wipe() { try? FileManager.default.removeItem(atPath: "/x") }
        Billing().charge()
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": base.path])
        XCTAssertEqual(r.code, 0, "a new fn is exempt from the ratchet — stderr: \(r.err)")
        // Match the bracketed violation FORM: the ⟨0.16⟩ absent-sidecar note (--json baseline, no
        // sidecar) names the rule in prose. `wipe` is genuinely absent from BOTH report and (absent)
        // sidecar, so it stays exempt regardless.
        XCTAssertFalse(r.err.contains("[AS-EFF-005]"), "no violation for a new fn: \(r.err)")
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
        // gainedSrc calls `Billing().charge()` at the top level, so the Fs gain regresses BOTH the method
        // AND the `<main>` top-level unit that transitively reaches it — two AS-EFF-005 records.
        XCTAssertEqual(viols.count, 2, "the method gain and its top-level transitive gain: \(viols)")
        XCTAssertTrue(viols.allSatisfy { $0["rule"] as? String == "AS-EFF-005" })
        let byFn = Dictionary(uniqueKeysWithValues: viols.compactMap { v -> (String, [String: Any])? in
            (v["fn"] as? String).map { ($0, v) } })
        XCTAssertEqual(byFn["Billing.charge"]?["effects"] as? [String], ["Fs"], "effects = the GAINED set")
        XCTAssertEqual(byFn["<main>"]?["effects"] as? [String], ["Fs"], "the top-level caller gained Fs transitively")
    }

    // ── ⟨0.16⟩ callgraph-aware existence: a formerly-PURE fn turning effectful ────────────────
    //
    // The pre-⟨0.16⟩ guard keyed existence on the REPORT, which OMITS pure functions — so a fn that
    // shipped pure and now performs an effect read as absent ("new code") and escaped the guard, the
    // sharpest supply-chain shape. ⟨0.16⟩ keys existence on the baseline CALLGRAPH sidecar (which lists
    // pure leaves), reusing the `gains` verb's origin rule. These pins need the sidecar, so the baseline
    // is recorded with `--out <prefix>` (writes `<prefix>.<pkg>.Swift.callgraph.json`) rather than a
    // `--json` stdout redirect (which writes no sidecar). SPEC §7 item 5, the ⟨0.16⟩ paragraph.

    /// A leaf that is PURE at baseline (uppercased only) — reports omit it; only the callgraph sidecar
    /// records it. Not reachable from any effectful (reported) fn, so its gain is the ONLY regression.
    private static let pureLeafSrc = """
    import Foundation
    func fmt(_ s: String) -> String { s.uppercased() }
    func fetchIt() { _ = URLSession.shared.dataTask(with: URL(string: "https://x.example.com/")!) { _, _, _ in } }
    fetchIt()
    """

    /// The same shape, but `fmt` now reads a file — the formerly-pure→effectful transition ⟨0.16⟩ catches.
    private static let pureLeafGainsFsSrc = """
    import Foundation
    func fmt(_ s: String) -> String { _ = try? String(contentsOfFile: "/etc/hosts"); return s.uppercased() }
    func fetchIt() { _ = URLSession.shared.dataTask(with: URL(string: "https://x.example.com/")!) { _, _, _ in } }
    fetchIt()
    """

    /// Record a same-build baseline WITH its callgraph sidecar (`--out <prefix>`). Returns the temp dir
    /// holding `<prefix>.<pkg>.Swift.json` + `.callgraph.json` and the exact report-file path (what
    /// CANDOR_BASELINE names). Callers `defer` removal of the returned dir.
    private func recordBaselineWithSidecar(_ bin: URL, src: String) throws -> (dir: URL, report: URL) {
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-bl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = dir.appendingPathComponent("baseline").path
        let r = try ProcessHarness.run(bin, [root.path, "--out", prefix])
        XCTAssertEqual(r.code, 0, "baseline recording scan must be clean — stderr: \(r.err)")
        let report = try XCTUnwrap(
            (try FileManager.default.contentsOfDirectory(atPath: dir.path))
                .first { $0.hasSuffix(".Swift.json") && !$0.hasSuffix(".callgraph.json") && !$0.hasSuffix(".hierarchy.json") }
                .map { dir.appendingPathComponent($0) },
            "the --out scan wrote a report file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path.replacingOccurrences(of: ".Swift.json", with: ".Swift.callgraph.json")),
                      "the --out scan wrote the callgraph sidecar")
        return (dir, report)
    }

    private func sidecarPath(for report: URL) -> String {
        (report.path as NSString).deletingPathExtension + ".callgraph.json"
    }

    /// (1) Sidecar PRESENT: a fn present in the baseline callgraph (even pure — ∅ effects) that now
    ///     performs ANY effect is a GAIN. exit 1, `fmt` flagged.
    func testSidecarPresentPureToEffectfulIsCaught() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let (dir, report) = try recordBaselineWithSidecar(bin, src: Self.pureLeafSrc)
        defer { try? FileManager.default.removeItem(at: dir) }

        let root = try ProcessHarness.makePackage(Self.pureLeafGainsFsSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": report.path])
        XCTAssertEqual(r.code, 1, "a formerly-pure fn turning effectful must be caught — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("`fmt` gained effect { Fs } not present in the baseline"),
                      "the pure→effectful leaf `fmt` is the flagged gain: \(r.err)")
    }

    /// (2) Sidecar ABSENT: degrade to report-only existence (the formerly-pure fn reads as new and is
    ///     NOT caught) — exit 0 — WITH a stderr note. Deleting the sidecar must not fail.
    func testSidecarAbsentDegradesWithNote() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let (dir, report) = try recordBaselineWithSidecar(bin, src: Self.pureLeafSrc)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(atPath: sidecarPath(for: report))

        let root = try ProcessHarness.makePackage(Self.pureLeafGainsFsSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": report.path])
        XCTAssertEqual(r.code, 0, "no sidecar → report-only existence, the pure leaf reads as new: \(r.err)")
        XCTAssertFalse(r.err.contains("[AS-EFF-005]"), "the pure leaf is NOT flagged without the sidecar: \(r.err)")
        XCTAssertTrue(r.err.contains("no baseline callgraph sidecar"),
                      "the degradation is DISCLOSED on stderr, never silent: \(r.err)")
    }

    /// The same pure-leaf shape, but `fmt` now invokes an OPAQUE function-typed value (annotated
    /// `() -> Void`), which the §4 contract reads as Unknown — an unresolved call, NOT a real effect.
    /// `pure`/`deny` policies exclude Unknown, and on real dependency bumps it is dominated by resolution
    /// noise, so a pure→Unknown-only gain is ADVISORY, never a CI-breaking AS-EFF-005 regression.
    private static let pureLeafGainsUnknownSrc = """
    import Foundation
    func fmt(_ s: String, _ opaque: () -> Void) -> String { opaque(); return s.uppercased() }
    func fetchIt() { _ = URLSession.shared.dataTask(with: URL(string: "https://x.example.com/")!) { _, _, _ in } }
    fetchIt()
    """

    /// (1b) Sidecar PRESENT, a formerly-pure fn gains ONLY Unknown (an unresolved call, no real effect):
    ///      ADVISORY note on stderr, exit UNCHANGED (0) — NOT the [AS-EFF-005] violation line. Unknown is
    ///      the §4 trust marker, dominated by resolution noise on version bumps.
    func testSidecarPresentPureToUnknownIsAdvisoryNotViolation() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let (dir, report) = try recordBaselineWithSidecar(bin, src: Self.pureLeafSrc)
        defer { try? FileManager.default.removeItem(at: dir) }

        let root = try ProcessHarness.makePackage(Self.pureLeafGainsUnknownSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": report.path])
        XCTAssertEqual(r.code, 0, "an Unknown-only gain is advisory, not a regression — stderr: \(r.err)")
        XCTAssertFalse(r.err.contains("[AS-EFF-005]"), "no violation line for an Unknown-only gain: \(r.err)")
        XCTAssertTrue(r.err.contains("gained an unresolved call (Unknown)") && r.err.contains("advisory, NOT a regression"),
                      "the Unknown-only gain is disclosed as an advisory note: \(r.err)")
        XCTAssertTrue(r.err.contains("fmt"), "the advisory names the gaining function: \(r.err)")
    }

    /// (1c) The advisory verdict is consistent with --gate-json: an Unknown-only gain must NOT set
    ///      ok:false (exit 0, no violation records), or the machine verdict would disagree with the exit.
    func testUnknownOnlyGainKeepsGateJsonOk() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let (dir, report) = try recordBaselineWithSidecar(bin, src: Self.pureLeafSrc)
        defer { try? FileManager.default.removeItem(at: dir) }

        let root = try ProcessHarness.makePackage(Self.pureLeafGainsUnknownSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let verdict = root.appendingPathComponent("verdict.json")
        let r = try ProcessHarness.run(bin, [root.path, "--json", "--gate-json", verdict.path],
                                       env: ["CANDOR_BASELINE": report.path])
        XCTAssertEqual(r.code, 0, "an Unknown-only gain leaves the gate clean — stderr: \(r.err)")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict)) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true, "the advisory must NOT set ok:false")
        let viols = obj?["violations"] as? [[String: Any]] ?? []
        XCTAssertTrue(viols.allSatisfy { $0["rule"] as? String != "AS-EFF-005" },
                      "no AS-EFF-005 record for an Unknown-only gain: \(viols)")
    }

    /// (3) Sidecar PRESENT-but-corrupt: fail CLOSED (exit 2), like a corrupt baseline — a broken sidecar
    ///     must not silently narrow the guard back to report-only.
    func testCorruptSidecarFailsClosed() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let (dir, report) = try recordBaselineWithSidecar(bin, src: Self.pureLeafSrc)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{ \"fmt\": [".write(toFile: sidecarPath(for: report), atomically: true, encoding: .utf8)

        let root = try ProcessHarness.makePackage(Self.pureLeafGainsFsSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_BASELINE": report.path])
        XCTAssertEqual(r.code, 2, "a corrupt sidecar fails closed, like a corrupt baseline: \(r.err)")
        XCTAssertTrue(r.err.contains("callgraph sidecar") && r.err.contains("could not be parsed"),
                      "the exit-2 note names the corrupt sidecar: \(r.err)")
        XCTAssertFalse(r.err.contains("[AS-EFF-005]"), "no gate wave is emitted when we fail closed: \(r.err)")
    }
}
