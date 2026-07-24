import XCTest
import Foundation

/// PROCESS-layer pins over the SCAN-COMPLETENESS NUDGE — the stderr hint that rides straight after the
/// κ coverage ledger when a scan leans HEAVILY on modules it never saw (the candor-java port, that
/// engine's commit 8b5d0b0).
///
/// The point of the hint is that an uncovered module is a MISSING INPUT, not a precision defect: on the
/// JVM side a real 18.7k-fn webapp scanned app-only could prove Net on 465 functions, and the same gate
/// over the deployed artifact (app + its 222 dependency jars) proved Net on 5,865. So the trigger is
/// ledger VOLUME, never the module COUNT — five util modules touched once each is not the signal, one
/// dependency pulled into fifty files is. This suite pins that distinction in both directions, pins the
/// threshold at its literal boundary (49 silent / 50 fires — a fixture derived from the constant would
/// keep passing if the constant drifted), and pins the safety contract: the hint is stderr-only and can
/// never reach a machine consumer's stdout.
///
/// UNIT NOTE: candor-java sums CALLS into uncovered packages; this engine's ledger counts IMPORT
/// DECLARATIONS (one per `import M` per file), the closest quantity a syntactic Swift scan measures —
/// so these fixtures spread their imports over FILES, which is how the volume actually accrues here.
final class ScanCompletenessNudgeProcessTests: XCTestCase {

    /// The stable fragment of the hint: asserted rather than the whole sentence so wording can be
    /// tuned, but the CLAIM (these modules are unscanned, so their effects are invisible) cannot drift.
    /// Deliberately the same fragment candor-java's ScanCompletenessGuardTest matches.
    private let nudgeMark = "are not scanned, so their effects are invisible here"
    private let singularNudgeMark = "is not scanned, so their effects are invisible here"

    /// A package making `imports` import declarations of `modules` distinct UNCOVERED modules — no
    /// platform/κ/internal module among them, so the κ ledger names exactly `modules` entries whose
    /// counts sum to `imports`. ONE import per file (that is the unit this engine counts), each with a
    /// module-qualified call so the fixture is a genuine reach and not a stray import line.
    /// - Parameter scannable: when true, each uncovered module is also materialised as a fetched SwiftPM
    ///   checkout (`.build/checkouts/<M>Pkg/Sources/<M>/`), which is what marks it SCANNABLE and therefore
    ///   nudge-worthy. When false the modules look like Apple platform frameworks — imported, never
    ///   fetchable — and the nudge must stay silent however high the volume, because "scan them too" would
    ///   be advice the user cannot act on.
    private func makeUncoveredPackage(modules: Int, imports: Int, scannable: Bool = true) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-nudge-\(UUID().uuidString)")
        let srcDir = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // main.swift imports nothing — the ledger volume comes only from the F<i>.swift files below.
        try "print(\"hi\")\n".write(to: srcDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        for i in 0..<imports {
            let m = "UncoveredSDK\((i % modules) + 1)"
            try """
            import \(m)
            func f\(i)() { \(m).doThing() }
            """.write(to: srcDir.appendingPathComponent("F\(i).swift"), atomically: true, encoding: .utf8)
        }
        if scannable {
            for k in 1...modules {
                let m = "UncoveredSDK\(k)"
                // The SwiftPM checkout layout the scan probes: .build/checkouts/<pkg>/Sources/<Module>/.
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(".build/checkouts/\(m)Pkg/Sources/\(m)"),
                    withIntermediateDirectories: true)
            }
        }
        return root
    }

    private func scan(_ root: URL, _ extraArgs: [String] = []) throws -> (out: String, err: String, code: Int32) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        return try ProcessHarness.run(bin, [root.path] + extraArgs)
    }

    // ── the trigger ──────────────────────────────────────────────────────────────────────────────────

    func testHeavyImportVolumeIntoUnscannedModulesNudges() throws {
        let root = try makeUncoveredPackage(modules: 2, imports: 60)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try scan(root)
        XCTAssertEqual(r.code, 0, "advisory only — the exit code is untouched: \(r.err)")
        XCTAssertTrue(r.err.contains(nudgeMark), "the nudge names what is lost — visibility: \(r.err)")
        XCTAssertTrue(r.err.contains("60 imports pull in 2 dependency modules"), "it reports the measured volume: \(r.err)")
        XCTAssertTrue(r.err.contains("DETERMINED"),
                      "it promises VISIBILITY (determined effects), never dispatch resolution: \(r.err)")
        XCTAssertTrue(r.err.contains("--workspace") && r.err.contains("CANDOR_DEPS"),
                      "it carries the swift remedy — chain the dep reports: \(r.err)")
        // the conformance-matched ledger line is untouched and still leads the disclosure
        XCTAssertTrue(r.err.contains("classifier doesn't cover 2 modules this code imports"), r.err)
    }

    /// Pins the THRESHOLD ITSELF at its literal boundary. Both fixtures hold the module count fixed, so
    /// only the volume moves — and neither number is derived from the constant, so a drift to 5 or 500
    /// fails this test instead of silently passing.
    func testNudgeThresholdIsPinnedAtItsBoundary() throws {
        let below = try makeUncoveredPackage(modules: 2, imports: 49)
        defer { try? FileManager.default.removeItem(at: below) }
        let rBelow = try scan(below)
        XCTAssertEqual(rBelow.code, 0, rBelow.err)
        XCTAssertTrue(rBelow.err.contains("classifier doesn't cover"),
                      "precondition: the ledger IS non-empty at 49 — only the nudge is withheld: \(rBelow.err)")
        XCTAssertFalse(rBelow.err.contains(nudgeMark), "49 imports is below the bar — silent: \(rBelow.err)")

        let at = try makeUncoveredPackage(modules: 2, imports: 50)
        defer { try? FileManager.default.removeItem(at: at) }
        let rAt = try scan(at)
        XCTAssertEqual(rAt.code, 0, rAt.err)
        XCTAssertTrue(rAt.err.contains(nudgeMark), "50 imports is the bar — fires: \(rAt.err)")
    }

    /// VOLUME, NOT COUNT — the reason the JVM engine's own build output (519 calls into just 4 packages)
    /// needed a volume trigger. Many modules touched once each stay silent…
    func testManyModulesAtLowVolumeStaySilent() throws {
        let root = try makeUncoveredPackage(modules: 20, imports: 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try scan(root)
        XCTAssertTrue(r.err.contains("classifier doesn't cover 20 modules"),
                      "precondition: 20 uncovered modules ARE on the ledger: \(r.err)")
        XCTAssertFalse(r.err.contains(nudgeMark),
                       "a count-keyed trigger would fire here; volume is the signal: \(r.err)")
    }

    /// …and ONE module pulled into fifty files fires, which is the case a count threshold misses
    /// entirely. Also pins the singular grammar (`1 module that is not scanned`).
    func testSingleModuleAtHighVolumeNudges() throws {
        let root = try makeUncoveredPackage(modules: 1, imports: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try scan(root)
        XCTAssertTrue(r.err.contains(singularNudgeMark), "one heavily-used module IS the signal: \(r.err)")
        XCTAssertTrue(r.err.contains("50 imports pull in 1 dependency module"), r.err)
    }

    func testFullyCoveredScanIsSilent() throws {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func g() { _ = try? String(contentsOfFile: "/x") }
        g()
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try scan(root)
        XCTAssertFalse(r.err.contains("doesn't cover"), r.err)
        XCTAssertFalse(r.err.contains("invisible here"),
                       "nothing uncovered → no ledger and no nudge: \(r.err)")
    }

    // ── the safety contract ──────────────────────────────────────────────────────────────────────────

    /// The load-bearing property: the hint rides stderr and CANNOT corrupt a machine consumer. `--json`
    /// promises PURE JSON on stdout, and the gate verdict/exit must read exactly as it would without it.
    func testNudgeNeverContaminatesJsonStdoutOrTheVerdict() throws {
        let root = try makeUncoveredPackage(modules: 2, imports: 60)
        defer { try? FileManager.default.removeItem(at: root) }

        let r = try scan(root, ["--json"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains(nudgeMark), "precondition: the nudge DID fire on this scan")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
                              "stdout must stay pure JSON while stderr carries the hint: \(r.out)")
        XCTAssertNotNil(d["functions"], r.out)
        XCTAssertFalse(r.out.contains("hint"), "no advisory text may leak into the report document: \(r.out)")

        // a FAILING gate keeps its verdict and its exit code with the hint printed alongside. The
        // violation is a REAL Fs reach added to the fixture — a blind-module call is `invisible`, not
        // Unknown, so the uncovered imports alone give the gate nothing to catch.
        try """
        import Foundation
        func readsAFile() { _ = try? String(contentsOfFile: "/x") }
        """.write(to: root.appendingPathComponent("Sources/App/Effectful.swift"),
                  atomically: true, encoding: .utf8)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-nudge-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = dir.appendingPathComponent("deny.policy")
        try "deny Fs\n".write(to: policy, atomically: true, encoding: .utf8)
        let verdictPath = dir.appendingPathComponent("verdict.json").path
        let g = try scan(root, ["--json", "--policy", policy.path, "--gate-json", verdictPath])
        XCTAssertEqual(g.code, 1, "the gate exit is the gate's, not the advisory's: \(g.err)")
        XCTAssertTrue(g.err.contains(nudgeMark), "precondition: the nudge fired on the gated run too")
        let v = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(try String(contentsOfFile: verdictPath, encoding: .utf8).utf8)) as? [String: Any])
        XCTAssertEqual(v["ok"] as? Bool, false, "\(v)")
        XCTAssertFalse((try String(contentsOfFile: verdictPath, encoding: .utf8)).contains("hint"),
                       "the verdict document is untouched by the advisory")
    }

    // ── the discriminator: only NUDGE where the remedy is actionable ──────────────────────────────────

    /// THE REASON THIS PORT IS SCOPED. A Swift ledger is mostly Apple frameworks with no source to scan
    /// (a real 2.9k-fn SwiftUI app measured 22 uncovered modules / 49 imports, almost all platform).
    /// Volume alone would nudge that user toward a remedy they cannot act on — a dead end. So an
    /// unfetchable module must never contribute, however loud: same volume as the firing case above,
    /// minus the checkouts, must be SILENT.
    func testPlatformFrameworkVolumeNeverNudges() throws {
        let root = try makeUncoveredPackage(modules: 2, imports: 60, scannable: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try scan(root)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("classifier doesn't cover"),
                      "precondition: the ledger still discloses the gap — only the REMEDY is withheld: \(r.err)")
        XCTAssertFalse(r.err.contains(nudgeMark),
                       "nothing here is scannable, so 'scan them too' would be a dead end: \(r.err)")
    }

    /// The discriminator is per-module, not all-or-nothing: an app mixing a fetched dependency with
    /// platform frameworks nudges on the dependency's volume ALONE.
    func testOnlyScannableModulesCountTowardTheThreshold() throws {
        let root = try makeUncoveredPackage(modules: 2, imports: 60, scannable: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Demote ONE of the two modules to "platform framework" by removing only its checkout: its 30
        // imports must stop counting, dropping the volume to 30 — below the bar — so the nudge goes quiet.
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(".build/checkouts/UncoveredSDK2Pkg"))
        let r = try scan(root)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertFalse(r.err.contains(nudgeMark),
                       "only the 30 scannable imports count, which is under the bar: \(r.err)")
    }
}
