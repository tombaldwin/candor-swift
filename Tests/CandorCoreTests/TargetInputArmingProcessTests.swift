import XCTest
import Foundation

/// ⟨0.28⟩ SPEC §3.3.1 (3) — **THE SCAN TARGET IS AN INPUT ARMING MUST NOT TOUCH**, and (1)'s
/// precondition — *"`--out` has been parsed and accepted"* — binds the pre-pass to the flag loop's own
/// grammar. Both halves were measured DESTROYING operator data on this engine before the fix:
///
///   · `app.swift --policy P --gate-json app.swift` replaced the operator's SOURCE FILE with the armed
///     verdict document. The family folklore said swift was shielded because its targets are
///     directories; `sourcePaths = [target]` in main.swift is the single-file route that made the
///     shield folklore. (ts and java reproduced the same destroyer through their own single-artifact
///     targets.)
///   · `p.app.json --out p --zzz-not-a-flag` armed the TARGET itself — a report-shaped file whose name
///     sits under the `--out` prefix — and the exit-2 skips disarm, so the placeholder was permanent.
///   · `--policy --out X` armed X on an argv the parse loop NEVER accepts (`--out` there is the
///     rejected VALUE position of `--policy`), and `--out X --help` armed X behind an exit-0 that was
///     never going to scan. Both left X's previous reports as permanent placeholders.
///
/// Every destructive row here asserts **BYTES**, not exit codes: the pre-fix runs exited 2 as well, so
/// an exit assertion cannot see the regression these tests exist to catch.
final class TargetInputArmingProcessTests: XCTestCase {

    private func makeDir() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-targetarm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A previous good run's report, the artifact the `--out` armer rewrites.
    private let reportShaped =
        #"{"candor":{"version":"x"},"functions":[{"fn":"App.f","inferred":["Net"]}]}"#

    // ── §3.3.1 (3): the target itself, on the VERDICT sink route ──────────────────────────────────────

    /// `--gate-json <the single-file target>` must refuse having written NOTHING. Before the fix this
    /// argv wrote the fail-closed verdict OVER the source file (arming runs before the flag loop, so no
    /// later diagnostic could have saved it), then scanned the wreckage.
    func testGateJsonNamingTheSingleFileTargetRefusesWithBytesIntact() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("app.swift")
        let source = "import Foundation\nfunc doNet() { _ = URLSession.shared }\ndoNet()\n"
        try source.write(to: app, atomically: true, encoding: .utf8)
        let pol = dir.appendingPathComponent("pol.txt")
        try "deny Net\n".write(to: pol, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, [app.path, "--policy", pol.path, "--gate-json", app.path])
        XCTAssertEqual(r.code, 2, "a sink naming an input refuses (exit 2): \(r.err)")
        XCTAssertTrue(r.err.contains("names the SAME FILE as the scan target"),
                      "…and the refusal names WHICH input, so the operator can re-point the sink: \(r.err)")
        // THE LOAD-BEARING ASSERTION. The pre-fix run ALSO exited 2 (it gated its own wreckage), so
        // only the bytes can tell the refusal from the destruction.
        XCTAssertEqual(try String(contentsOf: app, encoding: .utf8), source,
                       "the operator's source file is byte-for-byte untouched — nothing was written")
    }

    /// THE CONTROL THAT KEEPS THE FIX EXACT-ARTIFACT. A verdict written INTO the scanned tree
    /// (`<target>/.candor/…`, the pattern this project ships in CI) is ordinary usage; a
    /// containment-shaped registration — "the sink may not be under the target" — would refuse it. This
    /// row is why the target registers as ONE artifact and `sameArtifact` does the comparing.
    func testVerdictInsideTheScannedTreeIsStillOrdinaryUsage() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func doNet() { _ = URLSession.shared.dataTask(with: URL(string: "https://x.example.com")!) }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("pol.txt")
        try "deny Net\n".write(to: pol, atomically: true, encoding: .utf8)
        let verdict = root.appendingPathComponent(".candor/verdict.json")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".candor"),
                                                withIntermediateDirectories: true)

        let r = try ProcessHarness.run(bin, [root.path, "--policy", pol.path,
                                             "--gate-json", verdict.path])
        XCTAssertEqual(r.code, 1, "the gate fires on the violation — the run was not refused: \(r.err)")
        let v = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict)) as? [String: Any]
        XCTAssertEqual(v?["ok"] as? Bool, false,
                       "…and the verdict landed inside the tree being scanned, as it always could")
    }

    // ── §3.3.1 (3): the target itself, on the REPORT (`--out`) sink route ─────────────────────────────

    /// A target that is itself report-shaped AND named under the `--out` prefix must survive the armer.
    /// Before the fix the arm loop positively identified it as a previous run's report (it carries
    /// `candor` + `functions` — the identification is by content, so being the TARGET was invisible)
    /// and the unknown-flag exit-2 skipped disarm: the placeholder was permanent.
    func testOutArmingLeavesAReportShapedTargetIntact() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("p.app.json")
        try reportShaped.write(to: target, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, [target.path,
                                             "--out", dir.appendingPathComponent("p").path,
                                             "--zzz-not-a-flag"])
        XCTAssertEqual(r.code, 2, "the unknown flag still refuses: \(r.err)")
        XCTAssertTrue(r.err.contains("which this run READS (the scan target)"),
                      "the armer says WHY it left the file, through the same runInputs exemption the "
                      + "verdict sink asks: \(r.err)")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), reportShaped,
                       "the target is byte-for-byte untouched past the exit-2 that skips disarm")
    }

    // ── §3.3.1 (1): the pre-pass may only arm what the flag loop would ACCEPT ─────────────────────────

    /// `--policy --out X`: the loop refuses at `--policy` (`--out` is its rejected VALUE, never a flag),
    /// so no run under this argv ever owns X — arming it turned X's previous reports into permanent
    /// placeholders on a parse the loop never accepts.
    func testValueShapedOutIsNotArmedWhenTheLoopWouldRefuseFirst() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prev = dir.appendingPathComponent("X.app.Swift.json")
        try reportShaped.write(to: prev, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, ["--policy", "--out",
                                             dir.appendingPathComponent("X").path])
        XCTAssertEqual(r.code, 2, r.err)
        XCTAssertTrue(r.err.contains("--policy requires a value"),
                      "the loop's own diagnostic decides this argv: \(r.err)")
        XCTAssertEqual(try String(contentsOf: prev, encoding: .utf8), reportShaped,
                       "X was never parsed as a sink, so its previous report survives byte-for-byte")

        // THE CONTROL THAT KEEPS THIS FROM BECOMING "NEVER ARM". `--out X --zzz`: the loop accepts
        // `--out X` BEFORE refusing, so the previous set is armed and the placeholder is the rung
        // working — a failed run must not leave a stale report readable as current.
        let armed = dir.appendingPathComponent("armed.app.Swift.json")
        try reportShaped.write(to: armed, atomically: true, encoding: .utf8)
        let f = try ProcessHarness.run(bin, ["--out", dir.appendingPathComponent("armed").path,
                                             "--zzz-not-a-flag"])
        XCTAssertEqual(f.code, 2, f.err)
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: armed)) as? [String: Any]
        XCTAssertEqual((doc?["analyzed"] as? [String: Any])?["count"] as? Int, 0,
                       "an --out the loop ACCEPTED before its exit still arms — the fail-closed empty "
                       + "replaces the stale report, exactly as before this fix")
    }

    /// `--out X --help` answers the help at exit 0 and never scans: there is no failed run for a stale
    /// report to survive, so arming had nothing to protect against — it only destroyed. Measured before
    /// the fix: the help printed, the exit was 0, and X's reports held the placeholder permanently.
    func testInformationalArgvDoesNotArmTheOutReports() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prev = dir.appendingPathComponent("X.app.Swift.json")
        try reportShaped.write(to: prev, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, ["--out", dir.appendingPathComponent("X").path, "--help"])
        XCTAssertEqual(r.code, 0, "the help answers as ever: \(r.err)")
        XCTAssertEqual(try String(contentsOf: prev, encoding: .utf8), reportShaped,
                       "a doc lookup must not eat the previous run's report")
    }

    // ── ⟨0.28⟩ THE SCAN TARGET EXPANDS TO THE FILES THE RUN WILL PARSE ────────────────────────────────

    /// A sink UNDER a directory target bearing the extension this engine parses is refused: it is not
    /// the target artifact (the exact-artifact rule cannot see it) but it IS a file the walk is about to
    /// read. Measured before the fix: `<dir> --gate-json <dir>/extra.swift` replaced the source with the
    /// armed verdict, scanned the wreckage as an unparseable source, and REPORTED SUCCESS (exit 0 on a
    /// clean policy) — the verdict sitting in the source tree.
    func testGateJsonAtASourceUnderTheDirectoryTargetRefusesWithBytesIntact() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func doFs() { FileManager.default.createFile(atPath: "/tmp/x", contents: nil) }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = root.appendingPathComponent("Sources/App/extra.swift")
        let source = "func pureThing() -> Int { 41 + 1 }\n"
        try source.write(to: extra, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, [root.path, "--gate-json", extra.path])
        XCTAssertEqual(r.code, 2, "a sink at a parsed source refuses (exit 2): \(r.err)")
        XCTAssertTrue(r.err.contains("lies under the scan target and ends `.swift`"),
                      "the refusal names the mechanism: \(r.err)")
        // THE LOAD-BEARING ASSERTION — the pre-fix run exited 0, but a weaker regression could refuse
        // AFTER arming; only the bytes tell the refusal from the destruction.
        XCTAssertEqual(try String(contentsOf: extra, encoding: .utf8), source,
                       "the operator's source file is byte-for-byte untouched — nothing was written")
    }

    /// …and a `.swift` sink that does not exist yet is the SAME refusal: arming would CREATE it, and the
    /// file walk that runs afterwards would then parse the verdict document as source.
    func testGateJsonAtANotYetExistingSwiftPathUnderTheTargetRefuses() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func doFs() { FileManager.default.createFile(atPath: "/tmp/x", contents: nil) }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = root.appendingPathComponent("Sources/App/new.swift")

        let r = try ProcessHarness.run(bin, [root.path, "--gate-json", sink.path])
        XCTAssertEqual(r.code, 2, r.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.path),
                       "nothing was written — arming a new .swift under the target would hand the walk "
                       + "a verdict document as source")
    }

    /// The repeated-sink route applies the same rule (a rule shipped on one route and not its sibling is
    /// the measured ⟨0.28⟩ habit): the source path takes the input exemption — bytes intact — while the
    /// OTHER named sink still receives the refusal document.
    func testRepeatedSinkRouteExemptsTheSourceAndRefusesTheSibling() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func doFs() { FileManager.default.createFile(atPath: "/tmp/x", contents: nil) }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = root.appendingPathComponent("Sources/App/extra.swift")
        let source = "func pureThing() -> Int { 41 + 1 }\n"
        try source.write(to: extra, atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("v.json")
        try #"{"ok": true}"#.write(to: other, atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, [root.path, "--gate-json", extra.path,
                                             "--gate-json", other.path])
        XCTAssertEqual(r.code, 2, r.err)
        XCTAssertEqual(try String(contentsOf: extra, encoding: .utf8), source,
                       "the source path is exempt — nothing written there")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: other)) as? [String: Any]
        XCTAssertEqual(doc?["refused"] as? Bool, true,
                       "the other named sink gets the refusal — its pre-seeded green must not survive")
    }

    /// THE CONTROL: `<target>/.candor/verdict.json` is under the target and is NOT a parsed source —
    /// the recommended layout keeps working. (A blanket under-the-target rule fails this row.)
    func testDotCandorSinkUnderTheTargetStaysPermitted() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func doFs() { FileManager.default.createFile(atPath: "/tmp/x", contents: nil) }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("pol.txt")
        try "deny Fs\n".write(to: pol, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out"),
                                                withIntermediateDirectories: true)
        let sink = root.appendingPathComponent("out/verdict.json")

        let r = try ProcessHarness.run(bin, [root.path, "--policy", pol.path,
                                             "--gate-json", sink.path])
        XCTAssertEqual(r.code, 1, "the gate runs and fires — the sink under the target is ordinary "
                       + "usage: \(r.err)")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: sink)) as? [String: Any]
        XCTAssertEqual(doc?["ok"] as? Bool, false)
        XCTAssertNotNil(doc?["violations"], "a real verdict, not a refusal")
    }
}
