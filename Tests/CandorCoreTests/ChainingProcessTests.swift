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
    /// `extraApp` appends source to the app target — used by the COVERAGE tests, which need a call the
    /// dep report has NO entry for. Defaulted to empty so every pre-existing test's input is byte-for-byte
    /// what it was: a fixture change and a regression must stay distinguishable.
    private func makeChainFixture(extraApp: String = "") throws -> (root: URL, dep: URL, app: URL) {
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
        \(extraApp)
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
        XCTAssertFalse(r.err.contains("classifier doesn't cover"), "the covered package must not be in the κ ledger: \(r.err)")
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

    // ── (b2) AN UNTRUSTED REPORT GRANTS NO COVERAGE (§2 rule 3's trust qualifier) ──────────────────
    //
    // Rule 3 turns a report's SILENCE into a purity claim. §2.1 says this producer's assertions are not
    // ours to repeat. Granting coverage on a stale report therefore makes the purity claim on the
    // authority of a report the engine has just refused to trust: the keys it CARRIES read `Unknown`
    // (right) while every key it simply does not contain reads PURE (wrong, and silent). The sharp row is
    // `goUnlisted`, whose callee has no entry in the report at all.
    //
    // THE SECOND FIXTURE IS WRITTEN FIRST, below and beside this one, because the obvious fix — drop the
    // package from the dep index outright — is the mirror sin: the JOIN is what produces rule 2's
    // downgrade, so an uncoverd-AND-unchained package would send `go` from a disclosed `Unknown` back to
    // an undisclosed pure. `testStaleDepDowngradesToUnknown` above is that control and must stay green.

    func testStaleDepGrantsNoCoverage() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
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

        // the key the untrusted report does NOT carry must keep its hedge, not read pure
        XCTAssertNotNil(by["goUnlisted"],
                        "a call an UNTRUSTED report does not answer must not be absent from `functions` — "
                        + "absence is a ⟨0.21⟩ purity claim made on the authority of a refused report")
        XCTAssertEqual(by["goUnlisted"]?["invisible"] as? [String], ["RatesDep"],
                       "an unanswered key under a stale report falls back to the κ ledger's hedge")
        // and the scan-level ledger keeps naming the package
        XCTAssertTrue(r.err.contains("classifier doesn't cover") && r.err.contains("RatesDep"),
                      "an untrusted report must not exempt its package from the κ ledger: \(r.err)")
        // the load itself discloses which packages were downgraded
        XCTAssertTrue(r.err.contains("granted NO coverage") && r.err.contains("RatesDep"),
                      "the loader must name the untrusted package: \(r.err)")
    }

    // THE SECOND DIRECTION, and the reason the fix is a SPLIT rather than a drop: the keys the untrusted
    // report DOES carry must still be looked up, or rule 2's downgrade disappears with the coverage.
    // (`testStaleDepDowngradesToUnknown` asserts the same property on the un-extended fixture; this one
    // asserts it survives beside the new hedge, in the same report.)
    func testStaleDepStillDowngradesTheKeysItDoesCarry() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
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
        XCTAssertEqual(Set(by["go"]?["inferred"] as? [String] ?? []), ["Unknown"],
                       "removing coverage must NOT remove the join — `go` still downgrades (§2 rule 2)")
        XCTAssertEqual(by["go"]?["unknownWhy"] as? [String], ["dep-stale:RatesDep"])
        XCTAssertTrue(by["go"]?["unresolved"] as? Bool ?? false,
                      "an entry carrying Unknown carries the marker that says so")
    }

    // A package chained TWICE — once fresh, once stale — IS covered: the fresh report makes the claim.
    // Without this the stale arm would strip the coverage the fresh one earned (the mirror sin: a real
    // purity claim degraded to a hedge by a report that adds nothing).
    func testPackageChainedFreshAndStaleKeepsItsCoverage() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let stale = root.appendingPathComponent("dep-stale.json")
        try doctor(depReport, to: stale) { d in
            var candor = d["candor"] as! [String: Any]
            candor["version"] = "candor-doctored-0.0.0"
            d["candor"] = candor
        }
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": "\(depReport.path):\(stale.path)"])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertNil(by["goUnlisted"], "the FRESH report covers the package — its silence is still a claim")
        XCTAssertFalse(r.err.contains("classifier doesn't cover"),
                       "a package with a fresh report must stay out of the κ ledger: \(r.err)")
        // …and the DISCLOSURE must agree with the behaviour. Without the `stalePkgs.subtract(coveredPkgs)`
        // reconciliation the loader announces a package as uncovered while it is covered — a FALSE
        // disclosure, which is worse than a missing one, and the only thing that reconciliation changes.
        XCTAssertFalse(r.err.contains("granted NO coverage"),
                       "RatesDep IS covered by the fresh report — the loader must not announce otherwise: \(r.err)")
    }

    // …and the FRESH-only control, so the hedge above is provably the stale arm's doing and not a general
    // change to how an unanswered key reads.
    func testFreshDepStillMakesSilenceAPurityClaim() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertNil(by["goUnlisted"],
                     "a TRUSTED report's silence is its purity claim (§2 rule 3) — unchanged")
        XCTAssertFalse(r.err.contains("classifier doesn't cover"), "\(r.err)")
        XCTAssertFalse(r.err.contains("granted NO coverage"), "no stale report here: \(r.err)")
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
        XCTAssertFalse(r.err.contains("classifier doesn't cover"),
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
        XCTAssertTrue(r.err.contains("classifier doesn't cover") && r.err.contains("RatesDep"), "ledger must name RatesDep")
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

    // ── CANDOR_DEPS naming a DIRECTORY (Deps.swift's walk mode): every *.json report under it loads,
    // the callgraph/hierarchy SIDECARS are skipped by name, and the walk is deterministic (sorted) —
    // this mode had zero coverage in any suite. Two dep packages prove multi-report loading; the
    // sidecars sit beside them exactly as a real `--out` scan leaves them.
    func testDepsDirectoryLoadsReportsAndSkipsSidecars() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        // a SECOND dep package (GeoDep, Fs at a literal path) + an app importing both
        let dep2 = root.appendingPathComponent("dep2")
        try fm.createDirectory(at: dep2.appendingPathComponent("Sources/GeoDep"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "GeoDep", targets: [.target(name: "GeoDep")])
        """.write(to: dep2.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public func locate() { _ = FileManager.default.contents(atPath: "/geo.db") }
        """.write(to: dep2.appendingPathComponent("Sources/GeoDep/Geo.swift"), atomically: true, encoding: .utf8)
        try """
        import RatesDep
        import GeoDep
        public func go() { hit() }
        public func find() { locate() }
        """.write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)

        // scan both deps INTO one directory — each leaves its report + callgraph + hierarchy sidecars
        let depDir = root.appendingPathComponent("depdir")
        try fm.createDirectory(at: depDir, withIntermediateDirectories: true)
        XCTAssertEqual(try run(bin, [dep.path, "--out", depDir.appendingPathComponent("dep").path]).code, 0)
        XCTAssertEqual(try run(bin, [dep2.path, "--out", depDir.appendingPathComponent("dep2").path]).code, 0)
        let listing = try fm.contentsOfDirectory(atPath: depDir.path)
        XCTAssertTrue(listing.contains { $0.contains("callgraph") } && listing.contains { $0.contains("hierarchy") },
                      "the fixture dir must hold the sidecars the walk has to skip; got \(listing)")

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depDir.path])
        XCTAssertEqual(r.code, 0, "a directory of reports (with sidecars) must load cleanly; stderr: \(r.err)")
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertEqual(by["go"]?["inferred"] as? [String], ["Net"], "the RatesDep report in the dir must join")
        XCTAssertEqual(by["find"]?["inferred"] as? [String], ["Fs"], "the GeoDep report in the dir must join too")
        XCTAssertEqual(by["find"]?["paths"] as? [String], ["/geo.db"], "surfaces carry across the dir-loaded join")
        XCTAssertFalse(r.err.contains("classifier doesn't cover"),
                       "both packages are covered by the dir's reports — the ledger stays quiet: \(r.err)")
    }

    // an EMPTY directory is a configured-but-useless deps source: nothing loads, so the dep packages
    // read blind again — but loading itself must not fail (a dir with no *.json is not an error, it
    // is zero coverage; the fail-closed paths are per-file).
    func testDepsEmptyDirectoryCoversNothing() throws {
        let bin = try binaryURL()
        let (root, _, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyDir = root.appendingPathComponent("empty-deps")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": emptyDir.path])
        XCTAssertEqual(r.code, 0, "an empty deps dir loads zero reports, not an error; stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("classifier doesn't cover") && r.err.contains("RatesDep"),
                      "with no report loaded the dep package is blind again — the ledger names it: \(r.err)")
    }

    // an EXISTING report file the process cannot READ (chmod 000) must fail closed (exit 2) — the
    // Deps.swift `fm.contents == nil` arm, distinct from not-found (token test above) and bad-JSON.
    func testUnreadableDepReportFileExits2() throws {
        try XCTSkipIf(geteuid() == 0, "root reads through 0000 permissions — the arm is untestable as root")
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let locked = root.appendingPathComponent("locked.json")
        try FileManager.default.copyItem(at: depReport, to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": locked.path])
        XCTAssertEqual(r.code, 2, "an existing-but-unreadable dep report must fail closed; stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("could not be read"), "the diagnostic names the read failure: \(r.err)")
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
    // ── THE FRESH+STALE COLLISION: chaining must be MONOTONE ─────────────────────────────────────
    //
    // A dep directory holding a package TWICE — one fresh report and one left over from a previous
    // engine build — is the ordinary situation, not a corner: candor-rust measured it at 7/167 of its
    // own dep reports, 9/259 on pgman, 30/378 on ebman, and found this there.
    //
    // Two mechanisms met. §2 rule 1 withdraws a key two entries share, so the fresh `{Net}` entry and
    // the stale `{Unknown}` entry for `RatesDep#hit` cancelled each other and the key resolved to
    // NOTHING. `stalePkgs.subtract(coveredPkgs)` then (correctly) left the package COVERED on the fresh
    // report's authority, so §2 rule 3 turned that nothing into a purity claim. Measured before the fix,
    // on a dep whose only function performs the effect:
    //
    //     unchained          go -> invisible: ['RatesDep']
    //     FRESH only         go -> ['Net']
    //     STALE only         go -> ['Unknown'], dep-stale:RatesDep
    //     FRESH *and* STALE  go -> ABSENT FROM `functions`      the cardinal sin
    //
    // Strictly worse than not chaining at all, and non-monotone: ADDING a report removed an answer.
    // Rule 1 exists because two DIFFERENT dependency functions can share a leaf key; §2.1 has already
    // ranked these two producers, so preferring the trusted one is not a guess. Found by candor-rust
    // and handed over; verified here on this engine's own fixture before a line was written.
    func testAStaleReportBesideAFreshOneChangesNothing() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let stale = root.appendingPathComponent("dep-stale.json")
        try doctor(depReport, to: stale) { d in
            var candor = d["candor"] as! [String: Any]
            candor["version"] = "candor-doctored-0.0.0"
            d["candor"] = candor
        }
        func scanApp(_ spec: String, _ out: String) throws -> [String: [String: Any]] {
            let r = try run(bin, [app.path, "--out", root.appendingPathComponent(out).path],
                            env: ["CANDOR_DEPS": spec])
            XCTAssertEqual(r.code, 0, r.err)
            return try fns(ofReport: root.appendingPathComponent("\(out).App.Swift.json"))
        }
        // the CONTROL — one trusted report — is what "changes nothing" is measured against
        let fresh = try scanApp(depReport.path, "app-fresh")
        XCTAssertEqual(Set(fresh["go"]?["inferred"] as? [String] ?? []), ["Net"],
                       "the control must be live, or the row below asserts nothing")

        let both = try scanApp("\(depReport.path):\(stale.path)", "app-both")
        XCTAssertEqual(Set(both["go"]?["inferred"] as? [String] ?? []), ["Net"],
                       "a stale report BESIDE a fresh one must not withdraw the fresh answer — the key "
                       + "resolved to nothing and coverage turned that into a ⟨0.21⟩ purity claim")
        XCTAssertEqual(both["go"]?["hosts"] as? [String], fresh["go"]?["hosts"] as? [String],
                       "…and the literal surface travels exactly as it does without the stale report")
        XCTAssertEqual(Set(both["goMember"]?["inferred"] as? [String] ?? []), ["Net"],
                       "the same through the member-call key shape")
        XCTAssertNil(both["goUnlisted"], "coverage is unchanged too: the fresh report's silence still claims")
        // the ORDER of the two reports must not matter either
        let reversed = try scanApp("\(stale.path):\(depReport.path)", "app-rev")
        XCTAssertEqual(Set(reversed["go"]?["inferred"] as? [String] ?? []), ["Net"],
                       "trust decides, not load order")
    }

    /// THE SECOND DIRECTION, and it is §2 rule 1 itself: two TRUSTED reports that disagree about a key
    /// must still withdraw it. Preferring the trusted producer is a TRUST ordering, not a licence to
    /// pick between two dependency functions — `testAmbiguousKeyIsDroppedNotGuessed` above is the
    /// pre-existing pin and must stay green; this row adds the stale-vs-stale case, which withdraws the
    /// key too but RECOVERABLY, so a trusted report arriving afterwards can still answer it.
    func testTwoStaleReportsWithdrawTheKeyButATrustedOneReclaimsIt() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        var stales: [String] = []
        for (i, v) in ["candor-doctored-0.0.0", "some-other-build-9.9.9"].enumerated() {
            let u = root.appendingPathComponent("stale\(i).json")
            try doctor(depReport, to: u) { d in
                var candor = d["candor"] as! [String: Any]
                candor["version"] = v
                d["candor"] = candor
            }
            stales.append(u.path)
        }
        func scanApp(_ spec: String, _ out: String) throws -> (fns: [String: [String: Any]], err: String) {
            let r = try run(bin, [app.path, "--out", root.appendingPathComponent(out).path],
                            env: ["CANDOR_DEPS": spec])
            XCTAssertEqual(r.code, 0, r.err)
            return (try fns(ofReport: root.appendingPathComponent("\(out).App.Swift.json")), r.err)
        }
        // two UNTRUSTED reports disagree about the key: withdrawn, and neither grants coverage — so the
        // call keeps the κ ledger's hedge instead of reading pure. Never absent.
        let two = try scanApp(stales.joined(separator: ":"), "app-2stale")
        XCTAssertNotNil(two.fns["go"], "a withdrawn key under NO coverage must not read as a purity claim")
        XCTAssertEqual(two.fns["go"]?["invisible"] as? [String], ["RatesDep"])
        // …and a trusted report arriving after them reclaims it: the stale-level withdrawal is not final.
        let recovered = try scanApp("\(stales.joined(separator: ":")):\(depReport.path)", "app-recover")
        XCTAssertEqual(Set(recovered.fns["go"]?["inferred"] as? [String] ?? []), ["Net"],
                       "a stale/stale withdrawal must not outrank a trusted report that answers the key")
    }
}
