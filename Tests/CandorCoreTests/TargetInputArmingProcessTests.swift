import XCTest
import Foundation

/// ⟨0.28⟩ SPEC §3.3.1 (3) — **THE SCAN TARGET IS AN INPUT ARMING MUST NOT TOUCH.** Measured DESTROYING
/// operator data on this engine before the fix:
///
///   · `app.swift --policy P --gate-json app.swift` replaced the operator's SOURCE FILE with the armed
///     verdict document. The family folklore said swift was shielded because its targets are
///     directories; `sourcePaths = [target]` in main.swift is the single-file route that made the
///     shield folklore. (ts and java reproduced the same destroyer through their own single-artifact
///     targets.)
///   · `p.app.json --out p --zzz-not-a-flag` armed the TARGET itself — a report-shaped file whose name
///     sits under the `--out` prefix — and the exit-2 skips disarm, so the placeholder was permanent.
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
}
