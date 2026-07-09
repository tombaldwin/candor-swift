import XCTest
import Foundation

/// Process-level pins for consumer-side report chaining (SPEC §2, `CANDOR_DEPS` + the config `deps`
/// key) — the same dep+app shape conformance PART 14 uses for the other three engines: a dep whose
/// one function reaches Net at a literal host, an app calling it, and three dep-report variants:
///
///   FRESH  → JOIN-INHERIT: the app fn inherits exactly {Net} AND the `rates.internal:7070` literal,
///            through BOTH join shapes this engine derives (bare free call `hit()` → `pkg#leaf`;
///            member call on a resolved external owner `c.fetch()` → `pkg#Owner.leaf`).
///   STALE  → a doctored producing version is not trusted (§2.1 at the join): the call reads
///            `Unknown` (never a stale Net claim), surfaces are NOT carried, and `unknownWhy`
///            names the origin (`dep-stale:<pkg>`).
///   EMPTY  → an all-pure dep's empty report is a purity CLAIM (§2 rule 3): the call reads pure,
///            no `invisible` disclosure, and the κ ledger must NOT name the covered package.
///
/// Plus the fail-closed loading paths (a token naming no readable file / an unparseable report →
/// exit 2 — a configured dep must never silently read pure), the §2-rule-1 ambiguity drop, the
/// config `deps` anchoring, and CANDOR_DEPS-over-config precedence.
final class ChainingProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        let bundleDir = Bundle(for: ChainingProcessTests.self).bundleURL.deletingLastPathComponent()
        let exe = bundleDir.appendingPathComponent("candor-swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: exe.path),
                          "candor-swift binary not built next to the test bundle (\(exe.path)) — run `swift build` first")
        return exe
    }

    /// Run the binary with a SANITIZED environment (no inherited CANDOR_* can leak into a fixture
    /// scan) plus the given overrides. Returns (stdout, stderr, exitCode).
    private func run(_ binary: URL, _ args: [String], env: [String: String] = [:]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS"] { environment.removeValue(forKey: k) }
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

    /// A throwaway root holding the PART 14 dep+app pair. `deproot/` is the RatesDep package (one
    /// class method + one free fn, both reaching Net at the pinned literal); `approot/` imports it
    /// and calls through both join shapes. Returns (root, depDir, appDir).
    private func makeChainFixture() throws -> (root: URL, dep: URL, app: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-chain-\(UUID().uuidString)")
        let dep = root.appendingPathComponent("dep"), app = root.appendingPathComponent("app")
        let fm = FileManager.default
        try fm.createDirectory(at: dep.appendingPathComponent("Sources/RatesDep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "RatesDep", targets: [.target(name: "RatesDep")])
        """.write(to: dep.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public class RatesClient {
            public init() {}
            public func fetch() {
                let t = URLSession.shared.dataTask(with: "http://rates.internal:7070/x") { _, _, _ in }
                t.resume()
            }
        }
        public func hit() {
            RatesClient().fetch()
        }
        """.write(to: dep.appendingPathComponent("Sources/RatesDep/Rates.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.target(name: "App")])
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import RatesDep
        public func go() {
            hit()
        }
        public func goMember() {
            let c = RatesClient()
            c.fetch()
        }
        """.write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)
        return (root, dep, app)
    }

    /// Scan the dep and return its report path; the caller doctors variants from it.
    private func scanDep(_ bin: URL, _ dep: URL, root: URL) throws -> URL {
        let r = try run(bin, [dep.path, "--out", root.appendingPathComponent("dep-r").path])
        XCTAssertEqual(r.code, 0, "dep scan must succeed; stderr: \(r.err)")
        return root.appendingPathComponent("dep-r.RatesDep.Swift.json")
    }

    private func fns(ofReport url: URL) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let name = f["fn"] as? String { out[name] = f }
        }
        return out
    }

    private func doctor(_ report: URL, to out: URL, mutate: (inout [String: Any]) -> Void) throws {
        var d = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as! [String: Any]
        mutate(&d)
        try JSONSerialization.data(withJSONObject: d).write(to: out)
    }

    // ── (a) JOIN-INHERIT: effects AND literal surfaces, through both key shapes ───────────────────
    func testFreshDepJoinInheritsEffectsAndSurfaces() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0, "chained app scan must succeed; stderr: \(r.err)")
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        for fn in ["go", "goMember"] {
            XCTAssertEqual(by[fn]?["inferred"] as? [String], ["Net"],
                           "\(fn) must inherit exactly {Net} across the join; got \(by[fn] ?? [:])")
            XCTAssertEqual(by[fn]?["hosts"] as? [String], ["rates.internal:7070"],
                           "\(fn) must inherit the dep's literal Net surface")
            XCTAssertNil(by[fn]?["invisible"], "a joined call is covered, not blind")
        }
        XCTAssertFalse(r.err.contains("κ doesn't know"), "the covered package must not be in the κ ledger: \(r.err)")
    }

    // ── (b) STALE-DOWNGRADE: a doctored producing version is not trusted at the join ──────────────
    func testStaleDepDowngradesToUnknown() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let stale = root.appendingPathComponent("dep-stale.json")
        try doctor(depReport, to: stale) { d in
            var candor = d["candor"] as! [String: Any]
            candor["version"] = "candor-doctored-0.0.0"
            d["candor"] = candor
        }

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": stale.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        for fn in ["go", "goMember"] {
            let inferred = Set(by[fn]?["inferred"] as? [String] ?? [])
            XCTAssertTrue(inferred.contains("Unknown"), "\(fn): a stale dep must read Unknown; got \(inferred)")
            XCTAssertFalse(inferred.contains("Net"), "\(fn): never a stale Net claim")
            XCTAssertNil(by[fn]?["hosts"], "\(fn): a stale dep's surfaces are not trusted either")
            XCTAssertEqual(by[fn]?["unknownWhy"] as? [String], ["dep-stale:RatesDep"],
                           "the Unknown must name its origin (spec 0.6 unknownWhy)")
        }
    }

    // a MISSING producing version is as unverifiable as a mismatched one (the family condition).
    func testVersionlessDepIsStale() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let unversioned = root.appendingPathComponent("dep-unversioned.json")
        try doctor(depReport, to: unversioned) { d in
            var candor = d["candor"] as! [String: Any]
            candor.removeValue(forKey: "version")
            d["candor"] = candor
        }
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": unversioned.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertEqual(Set(by["go"]?["inferred"] as? [String] ?? []), ["Unknown"])
    }

    // ── (c) EMPTY-REPORT COVERAGE: silence is a purity claim; the ledger stays quiet ───────────────
    func testEmptyDepReportIsAPurityClaim() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let empty = root.appendingPathComponent("dep-empty.json")
        try doctor(depReport, to: empty) { d in d["functions"] = [Any]() }

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": empty.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        for fn in ["go", "goMember"] {
            XCTAssertNil(by[fn], "\(fn) must read PURE against an all-pure dep's empty report; got \(by[fn] ?? [:])")
        }
        XCTAssertFalse(r.err.contains("κ doesn't know"),
                       "an empty report still COVERS its package — the ledger must not name RatesDep: \(r.err)")
    }

    // WITHOUT the dep report the same calls are blind: invisible discloses, the ledger names the
    // package — the contrast that proves the chain (not some κ rule) is what resolved them above.
    func testWithoutDepsTheDepPackageIsBlind() throws {
        let bin = try binaryURL()
        let (root, _, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertEqual(by["go"]?["invisible"] as? [String], ["RatesDep"])
        XCTAssertTrue(r.err.contains("κ doesn't know") && r.err.contains("RatesDep"), "ledger must name RatesDep")
    }

    // ── fail-closed loading (the CANDOR_CONFIG posture) ───────────────────────────────────────────
    func testDepsTokenNamingNoFileExits2() throws {
        let bin = try binaryURL()
        let (root, _, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": root.appendingPathComponent("no-such.json").path])
        XCTAssertEqual(r.code, 2, "a dep token naming no readable file must fail closed; stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("CANDOR_DEPS"), "the failure must name the source: \(r.err)")
    }

    func testUnparseableDepReportExits2() throws {
        let bin = try binaryURL()
        let (root, _, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = root.appendingPathComponent("garbage.json")
        try "{not json".write(to: garbage, atomically: true, encoding: .utf8)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": garbage.path])
        XCTAssertEqual(r.code, 2, "an unparseable dep report must fail closed, never read pure; stderr: \(r.err)")
    }

    // ── §2 rule 1: an ambiguous key is dropped, never picked from ─────────────────────────────────
    func testAmbiguousJoinKeyIsDropped() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        // Duplicate the `hit` entry under a second qual with the same LEAF (`Other.hit`): now BOTH
        // `RatesDep#hit` (leaf collision) is ambiguous — the bare `hit()` call must NOT join. The
        // tail2 key `RatesDep#RatesClient.fetch` stays unique, so goMember still joins — the drop is
        // per-KEY, not per-report.
        let ambiguous = root.appendingPathComponent("dep-ambiguous.json")
        try doctor(depReport, to: ambiguous) { d in
            var fns = d["functions"] as! [[String: Any]]
            if var dup = fns.first(where: { $0["fn"] as? String == "hit" }) {
                dup["fn"] = "Other.hit"
                dup["hash"] = "RatesDep#Other.hit"
                dup["inferred"] = ["Exec"]   // a DIFFERENT claim — picking either would be a guess
                fns.append(dup)
            }
            d["functions"] = fns
        }
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": ambiguous.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        let goInferred = Set(by["go"]?["inferred"] as? [String] ?? [])
        XCTAssertFalse(goInferred.contains("Net") || goInferred.contains("Exec"),
                       "an ambiguous leaf key must not join either candidate; got \(goInferred)")
        XCTAssertEqual(by["goMember"]?["inferred"] as? [String], ["Net"],
                       "the unique tail2 key must still join — ambiguity is per-key")
    }

    // ── config `deps` (relative → anchored to the config's home dir) + env precedence ─────────────
    func testConfigDepsKeyAnchorsRelativePathsAndEnvOverrides() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let candorDir = app.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candorDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: depReport, to: candorDir.appendingPathComponent("dep.json"))
        try "deps .candor/dep.json\n".write(to: candorDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        // config route: the RELATIVE value resolves against the config's home (the app root), no
        // matter that the test process' CWD is elsewhere.
        let r1 = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path])
        XCTAssertEqual(r1.code, 0, "config-deps scan must succeed; stderr: \(r1.err)")
        var by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertEqual(by["go"]?["inferred"] as? [String], ["Net"], "the config `deps` key must chain")

        // env precedence: CANDOR_DEPS (a stale variant) overrides the config's fresh report.
        let stale = root.appendingPathComponent("dep-stale.json")
        try doctor(depReport, to: stale) { d in
            var candor = d["candor"] as! [String: Any]
            candor["version"] = "candor-doctored-0.0.0"
            d["candor"] = candor
        }
        let r2 = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r2").path],
                         env: ["CANDOR_DEPS": stale.path])
        XCTAssertEqual(r2.code, 0)
        by = try fns(ofReport: root.appendingPathComponent("app-r2.App.Swift.json"))
        XCTAssertEqual(Set(by["go"]?["inferred"] as? [String] ?? []), ["Unknown"],
                       "CANDOR_DEPS must override the config `deps` key (env over config, like `policy`)")
    }
}
