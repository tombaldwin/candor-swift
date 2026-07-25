import XCTest
import Foundation

/// Process-level pins for the SCAN-BOUNDARY vein: code candor analyses SOUNDLY inside one package,
/// split across a package boundary with the dependency's report chained via `CANDOR_DEPS` — the
/// arrangement candor's own docs recommend — and the effect DISAPPEARS.
/// (candor-spec/SOUNDNESS-VEIN-crossing-the-scan-boundary.md; reproduced in all four engines.)
///
/// Every case here is checked against a ONE-PACKAGE CONTROL holding byte-identical function bodies,
/// so a failure is a boundary effect and never a general limitation. The gate is the point: the
/// under-report is not merely report-level, it flips `deny` from exit 1 (violation, correct) to
/// exit 0 (a false all-clear) on identical source.
final class ScanBoundaryVeinProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        let bundleDir = Bundle(for: ScanBoundaryVeinProcessTests.self).bundleURL.deletingLastPathComponent()
        let exe = bundleDir.appendingPathComponent("candor-swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: exe.path),
                          "candor-swift binary not built next to the test bundle (\(exe.path)) — run `swift build` first")
        return exe
    }

    private func run(_ binary: URL, _ args: [String], env: [String: String] = [:]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT"] {
            environment.removeValue(forKey: k)
        }
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), p.terminationStatus)
    }

    /// The dependency's source. `Entry.description` reaches Env, so EVERY implicit stringification of
    /// an `Entry` runs it; `Plain.description` is pure and is the no-fabrication control (a pure
    /// witness is absent from the dep report, so joining must add nothing).
    private static let depSource = """
    import Foundation

    public struct Entry: CustomStringConvertible {
        public init() {}
        public var description: String {
            let v = ProcessInfo.processInfo.environment["ENTRY_FMT"] ?? ""
            return "entry\\(v)"
        }
    }

    public struct Plain: CustomStringConvertible {
        public init() {}
        public var description: String { return "plain" }
    }
    """

    /// The consumer's source, with `IMPORT` replaced by `import DepLib` (split) or nothing (control).
    /// Three stringification forms, all of which resolve through the same operand-type resolver:
    /// a declared-type operand, an inline construction, and a `[Entry]` element bound to `$0`.
    private static let appSource = """
    IMPORT
    public func describeTyped(_ e: Entry) -> String { return "got \\(e)" }
    public func describeInline() -> String { return "got \\(Entry())" }
    public func describeMapped(_ es: [Entry]) -> [String] { return es.map { "\\($0)" } }
    public func describePure(_ p: Plain) -> String { return "got \\(p)" }
    """

    /// (root, depDir, appDir, ctlDir) — the split pair plus the one-package control.
    private func makeFixture() throws -> (root: URL, dep: URL, app: URL, ctl: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-vein-\(UUID().uuidString)")
        let dep = root.appendingPathComponent("deplib")
        let app = root.appendingPathComponent("app")
        let ctl = root.appendingPathComponent("ctl")
        let fm = FileManager.default
        try fm.createDirectory(at: dep.appendingPathComponent("Sources/DepLib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: ctl.appendingPathComponent("Sources/Ctl"), withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "DepLib", targets: [.target(name: "DepLib")])
        """.write(to: dep.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.write(to: dep.appendingPathComponent("Sources/DepLib/Lib.swift"),
                                 atomically: true, encoding: .utf8)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [.package(path: "../deplib")],
            targets: [.target(name: "App", dependencies: [.product(name: "DepLib", package: "deplib")])]
        )
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "import DepLib")
            .write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)

        // the CONTROL: the same two sources in ONE package, so the analysis is fully in-scan
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Ctl", targets: [.target(name: "Ctl")])
        """.write(to: ctl.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.write(to: ctl.appendingPathComponent("Sources/Ctl/Lib.swift"),
                                 atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "")
            .write(to: ctl.appendingPathComponent("Sources/Ctl/App.swift"), atomically: true, encoding: .utf8)
        return (root, dep, app, ctl)
    }

    private func scanDep(_ bin: URL, _ dep: URL, root: URL) throws -> URL {
        let r = try run(bin, [dep.path, "--out", root.appendingPathComponent("dep-r").path])
        XCTAssertEqual(r.code, 0, "dep scan must succeed; stderr: \(r.err)")
        return root.appendingPathComponent("dep-r.DepLib.Swift.json")
    }

    private func fns(ofReport url: URL) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let name = f["fn"] as? String { out[name] = f }
        }
        return out
    }

    private func policy(_ root: URL, _ lines: [String]) throws -> URL {
        let p = root.appendingPathComponent("candor.policy")
        try lines.joined(separator: "\n").appending("\n").write(to: p, atomically: true, encoding: .utf8)
        return p
    }

    // ── IMPLICIT STRINGIFICATION of a DEPENDENCY type ─────────────────────────────────────────────
    // `"\(e)"` where `e: DepLib.Entry` runs `Entry.description`, which reaches Env. The dep's report
    // records that accessor under `DepLib#Entry.description` — the join key this engine already
    // derives elsewhere — but both stringification rungs were LOCAL-only (`localTypes` for the
    // concrete witness, `localProtocols`/`conformers` for the CHA one), so the site recorded NOTHING,
    // not even Unknown, and the consumer certified clean.
    func testDependencyStringificationReachesItsWitness() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        // the one-package CONTROL gets all three forms right — that is what the split must match
        XCTAssertEqual(try run(bin, [ctl.path, "--out", root.appendingPathComponent("ctl-r").path]).code, 0)
        let ctlFns = try fns(ofReport: root.appendingPathComponent("ctl-r.Ctl.Swift.json"))
        for fn in ["describeTyped", "describeInline", "describeMapped"] {
            XCTAssertEqual(ctlFns[fn]?["inferred"] as? [String], ["Env"],
                           "CONTROL: \(fn) must reach Env in one package; got \(ctlFns[fn] ?? [:])")
        }

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0, "chained app scan must succeed; stderr: \(r.err)")
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        for fn in ["describeTyped", "describeInline", "describeMapped"] {
            XCTAssertEqual(by[fn]?["inferred"] as? [String], ["Env"],
                           "\(fn) must reach the dep's `description` across the scan boundary; got \(by[fn] ?? [:])")
        }
    }

    // NO FABRICATION: a dep type whose `description` is PURE is omitted from the dep report (silence
    // is the purity claim, §2 rule 3), so the same join must add exactly nothing.
    func testPureDependencyWitnessStaysPure() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertNil(by["describePure"],
                     "interpolating a dep type with a PURE description must stay pure; got \(by["describePure"] ?? [:])")
    }

    // The join is gated on the FILE's imports and on a package a loaded report COVERS: an app that
    // does not import the dep resolves to nothing, exactly as before — the joins-never-guess rule.
    func testStringificationJoinRequiresTheImport() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        // drop the import: the same source, now naming a type from no covered package in scope
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "")
            .write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertNil(by["describeTyped"], "no import of the covered package → no join; got \(by["describeTyped"] ?? [:])")
    }

    // THE GATE — the consequential form. `deny Env` on the three stringifying functions must fail
    // the SAME way in both arrangements; before the fix the chained scan PASSED (a false all-clear).
    func testDenyGateDoesNotFlipAcrossTheBoundary() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let pol = try policy(root, ["deny Env Unknown describeTyped",
                                    "deny Env Unknown describeInline",
                                    "deny Env Unknown describeMapped"])

        let control = try run(bin, [ctl.path, "--policy", pol.path,
                                    "--out", root.appendingPathComponent("ctl-g").path])
        XCTAssertEqual(control.code, 1, "CONTROL: one package must fail the deny gate; stderr: \(control.err)")

        let split = try run(bin, [app.path, "--policy", pol.path,
                                  "--out", root.appendingPathComponent("app-g").path],
                            env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(split.code, 1,
                       "split + chained must fail the SAME gate — exit 0 here is the false all-clear; stderr: \(split.err)")
    }

    // A STALE dep report is not trusted at this join either (§2.1): the witness reads Unknown with
    // its origin named, never a stale effect claim — and `deny Env Unknown` still fails closed.
    func testStaleDepMakesTheWitnessUnknownNotPure() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let stale = root.appendingPathComponent("dep-stale.json")
        var d = try JSONSerialization.jsonObject(with: Data(contentsOf: depReport)) as! [String: Any]
        var candor = d["candor"] as! [String: Any]
        candor["version"] = "candor-doctored-0.0.0"
        d["candor"] = candor
        try JSONSerialization.data(withJSONObject: d).write(to: stale)

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": stale.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        let inferred = Set(by["describeTyped"]?["inferred"] as? [String] ?? [])
        XCTAssertTrue(inferred.contains("Unknown"), "a stale dep's witness must read Unknown; got \(inferred)")
        XCTAssertFalse(inferred.contains("Env"), "never a stale effect claim")
        XCTAssertEqual(by["describeTyped"]?["unknownWhy"] as? [String], ["dep-stale:DepLib"],
                       "the Unknown must name its origin (spec 0.6 unknownWhy)")
    }
}
