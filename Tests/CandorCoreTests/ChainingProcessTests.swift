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

    /// See ProcessHarness.binaryURL — the private copy this replaced resolved WRONG on Linux.
    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: ChainingProcessTests.self)
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
        let exited = ProcessHarness.exitLatch(p)   // NOT waitUntilExit — see ProcessHarness.exitLatch
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
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
    /// pre-existing pin and must stay green; this row covers the stale side, where the key is
    /// recoverable so a trusted report arriving afterwards can still answer it.
    ///
    /// THE IDENTICAL-ENTRY EXEMPTION APPLIES AT EVERY TRUST LEVEL, and the first arm of this row used
    /// to assert the opposite. `ca5feb0` landed the exemption on the TRUSTED arm only; candor-rust
    /// (`6f2210c`) exempts identical entries regardless of trust, and the argument never mentions
    /// trust — rule 1 forbids PICKING between candidates and there is nothing to pick when they are
    /// equal. Withdrawing cost the §2.1 `Unknown` downgrade, which is the one thing the stale arm
    /// exists to produce:
    ///
    ///   pre   go -> invisible: ['RatesDep']                          the ledger hedge, no class
    ///   post  go -> ['Unknown'], unknownWhy ['dep-stale:RatesDep']   §2.1's downgrade, back
    ///
    /// so `deny E Unknown[…]` fires again on a package a distrusted report cannot vouch for. The
    /// direction is a hedge gaining a class, never an effect appearing.
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
        // Two UNTRUSTED reports for one package say the IDENTICAL thing about the key — a stale entry
        // is built from nothing but its package and the key begins with that package, so they cannot
        // differ. Nothing to pick, so the key stands and §2.1's downgrade survives.
        let two = try scanApp(stales.joined(separator: ":"), "app-2stale")
        XCTAssertNotNil(two.fns["go"], "a key under NO coverage must never read as a purity claim")
        XCTAssertEqual(Set(two.fns["go"]?["inferred"] as? [String] ?? []), ["Unknown"],
                       "withdrawing two entries that AGREE costs the §2.1 downgrade — the one thing the "
                       + "stale arm exists to produce — and hands the site back to the coverage hedge")
        XCTAssertEqual(two.fns["go"]?["unknownWhy"] as? [String], ["dep-stale:RatesDep"],
                       "…with the class, which is what `deny E Unknown[…]` reads")
        XCTAssertNil(two.fns["go"]?["invisible"],
                     "the key ANSWERED, so it is not a blind spot; the answer is that we do not trust it")
        // …and a trusted report arriving after them reclaims it: the stale-level withdrawal is not final.
        let recovered = try scanApp("\(stales.joined(separator: ":")):\(depReport.path)", "app-recover")
        XCTAssertEqual(Set(recovered.fns["go"]?["inferred"] as? [String] ?? []), ["Net"],
                       "a stale/stale withdrawal must not outrank a trusted report that answers the key")
    }

    // ── ⟨0.21⟩ A REPORT THAT DECLARES ITSELF INCOMPLETE GRANTS NO COVERAGE ────────────────────────
    //
    // §2 rule 3 turns a report's SILENCE into a purity claim. A report carrying a non-empty ⟨0.21⟩
    // `unanalyzed` has just said it never read some of its own source, so its silence about that source
    // answers nothing — and it was still registering full coverage for its package. The same door
    // `stalePkgs` closed, read one step earlier: staleness asks whether to believe what the report SAYS,
    // completeness asks whether its silence means anything.
    //
    // Found by candor-ts's own sweep (`21277eb`) and carried across here — the thing the sweep exists to
    // do, and it had not been done: swift, rust and java all gated coverage on STALENESS alone.
    // candor-ts measured the single-tree control over the same sources at exit 2 ("a gate cannot be green
    // over unanalyzed code"), so chaining an incomplete report was strictly WORSE than not chaining it:
    // the dependency's own scan refused to certify a gate over itself and the consumer certified one on
    // its behalf.
    //
    // THE TREATMENT DIFFERS FROM STALENESS, and that difference is the point. A stale report's entries
    // are assertions from a build this engine does not trust, so they are downgraded to `Unknown`. An
    // incomplete report's entries were derived from source it DID read and are true, so they are kept
    // exactly as they are and only COVERAGE is withheld. Strictly additive: no effect is ever removed.

    private func incompleteVariant(_ report: URL, to out: URL) throws {
        try doctor(report, to: out) { d in
            d["unanalyzed"] = [["path": "Sources/RatesDep/Broken.swift", "reason": "source failed to read"]]
        }
    }

    /// A MALFORMED manifest has not made a completeness claim, so it must not be read as one.
    ///
    /// `(obj?["unanalyzed"] as? [Any]) ?? []` made a FAILED CAST indistinguishable from an ABSENT key, so
    /// `"oops"`, `{}` and `null` all collapsed to the empty array and the report was read COMPLETE —
    /// buying it full coverage, which is the door the well-formed case closes, reopened by a garbled one.
    /// Found by the candor-rust pass while porting this shape (it reported ts and swift both failing open);
    /// candor-java fails closed, candor-rust adopted that reading, candor-ts fixed its half in `26a89fc`.
    ///
    /// BOTH DIRECTIONS ARE IN THIS ONE TEST DELIBERATELY. Reading ABSENT as incomplete is the opposite
    /// error and withholds coverage from every report with nothing to declare — java measured that mistake
    /// at 7 failing tests, ts at 15 — so the absent/empty rows are as load-bearing as the malformed ones.
    func testAMalformedUnanalyzedManifestGrantsNoCoverage() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        // (shape, expectComplete) — the two that ARE claims, and the three that only look like one.
        let cases: [(String, Any?, Bool)] = [
            ("absent",  nil,             true),
            ("empty",   [] as [Any],     true),
            ("string",  "oops",          false),
            ("object",  [:] as [String: Any], false),
            ("null",    NSNull(),        false),
        ]
        for (name, value, expectComplete) in cases {
            let variant = root.appendingPathComponent("dep-\(name).json")
            try doctor(depReport, to: variant) { d in
                if let v = value { d["unanalyzed"] = v } else { d.removeValue(forKey: "unanalyzed") }
            }
            let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-\(name)").path],
                            env: ["CANDOR_DEPS": variant.path])
            XCTAssertEqual(r.code, 0, "\(name): scan failed")
            let by = try fns(ofReport: root.appendingPathComponent("app-\(name).App.Swift.json"))
            if expectComplete {
                XCTAssertNil(by["goUnlisted"]?["invisible"],
                             "\(name): a report that made no incompleteness claim must still grant coverage — "
                             + "withholding it here floods every report that has nothing to declare")
            } else {
                XCTAssertEqual(by["goUnlisted"]?["invisible"] as? [String], ["RatesDep"],
                               "\(name): a report that GARBLED its completeness claim has not made one, and "
                               + "its silence must not buy coverage")
            }
        }
    }

    /// THE SECOND FIXTURE, WRITTEN FIRST. A COMPLETE report must still grant coverage, or the change is
    /// indistinguishable from "chained coverage no longer exists" and re-opens the κ-hedge flood §2 rule
    /// 3 exists to close. `testFreshDepStillMakesSilenceAPurityClaim` above is the same control on the
    /// staleness axis and is untouched.
    func testACompleteDepReportStillGrantsCoverage() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-c").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-c.App.Swift.json"))
        XCTAssertNil(by["goUnlisted"], "a COMPLETE report's silence is still its purity claim")
        XCTAssertFalse(r.err.contains("could not analyze"), "no incompleteness here: \(r.err)")
        XCTAssertFalse(r.err.contains("classifier doesn't cover"), r.err)
    }

    func testAnIncompleteDepReportGrantsNoCoverageButKeepsItsEntries() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let incomplete = root.appendingPathComponent("dep-incomplete.json")
        try incompleteVariant(depReport, to: incomplete)

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-i").path],
                        env: ["CANDOR_DEPS": incomplete.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-i.App.Swift.json"))

        // the key it does NOT answer must stop reading pure
        XCTAssertNotNil(by["goUnlisted"],
                        "a key an INCOMPLETE report does not answer must not be absent from `functions` — "
                        + "absence is a ⟨0.21⟩ purity claim, made by a report that just said it never read "
                        + "some of its own source")
        XCTAssertEqual(by["goUnlisted"]?["invisible"] as? [String], ["RatesDep"],
                       "it falls back to the κ ledger's hedge")
        XCTAssertTrue(r.err.contains("could not analyze") && r.err.contains("RatesDep"),
                      "the load must name the package whose coverage was withheld: \(r.err)")

        // THE ENTRIES IT DOES CARRY ARE UNTOUCHED — this is what separates incompleteness from staleness.
        // Treating them alike would downgrade a true answer to `Unknown`, which no evidence supports.
        XCTAssertEqual(Set(by["go"]?["inferred"] as? [String] ?? []), ["Net"],
                       "an entry the incomplete report DOES carry is applied unchanged — not downgraded")
        XCTAssertEqual(by["go"]?["hosts"] as? [String], ["rates.internal:7070"],
                       "…and so is its literal surface, unlike a stale report's")
        XCTAssertNil(by["go"]?["unknownWhy"], "nothing is hedged about an answer it actually gave")
    }

    /// THE TRADE candor-ts MEASURED GOING THE WRONG WAY, and the reason this row exists at all.
    /// Withholding coverage sends the site to the κ-ledger arm, so an engine whose half-1 disclosure is
    /// gated on COVERAGE silently REPLACES the unanswerable-key `Unknown` with the `invisible` hedge —
    /// `deny E Unknown[dispatch]` going exit 1 -> exit 0, a gate lost to a fix whose whole argument is
    /// that it only adds disclosure. This engine gates half 1 on `isChained`, so both voices must speak.
    func testHalf1StillDisclosesUnderAnIncompleteDepReport() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goHalf1() {
            let c = makeClient()
            c.send()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let incomplete = root.appendingPathComponent("dep-incomplete.json")
        try incompleteVariant(depReport, to: incomplete)

        func half1(_ spec: String, _ out: String) throws -> [String: Any]? {
            let r = try run(bin, [app.path, "--out", root.appendingPathComponent(out).path],
                            env: ["CANDOR_DEPS": spec])
            XCTAssertEqual(r.code, 0, r.err)
            return try fns(ofReport: root.appendingPathComponent("\(out).App.Swift.json"))["goHalf1"]
        }
        // the control: under a COMPLETE report half 1 discloses
        let complete = try half1(depReport.path, "app-h1c")
        XCTAssertEqual(complete?["unknownWhy"] as? [String], ["dispatch:untyped cross-package receiver"],
                       "the trigger must be live, or the row below asserts nothing")

        let under = try half1(incomplete.path, "app-h1i")
        XCTAssertEqual(under?["unknownWhy"] as? [String], ["dispatch:untyped cross-package receiver"],
                       "half 1's disclosure must SURVIVE the withheld coverage — the ledger hedge adds to "
                       + "it, it does not replace it, or `deny E Unknown[dispatch]` is narrowed by a fix "
                       + "whose whole argument is that it only adds disclosure")
        XCTAssertTrue(Set(under?["inferred"] as? [String] ?? []).contains("Unknown"))
        XCTAssertEqual(under?["invisible"] as? [String], ["RatesDep"], "…and the ledger speaks too")
    }

    /// A PACKAGE CHAINED TWICE, ONCE COMPLETE AND ONCE NOT, IS **NOT** COVERED — INCOMPLETENESS WINS.
    ///
    /// This row used to assert the opposite, on the reading that a complete report makes its coverage
    /// claim on its own authority and that announcing a covered package as uncovered would be a FALSE
    /// disclosure. It is not false, and the reading is wrong for one reason: **two reports covering one
    /// package do not cover the same SOURCE.** Coverage turns SILENCE into a purity claim (§2 rule 3),
    /// so a set of reports' silence is only as strong as the weakest completeness claim in it. Report A
    /// answered for the source A read and never claimed more; report B said in as many words that it
    /// could not read some of the package — and complete-wins cancelled exactly that hedge.
    ///
    /// This test PINNED THE DEFECT (standing bar item 7g). It is inverted here rather than deleted,
    /// with the measurement attached, and the flip instructions are: `Deps.swift`'s
    /// `coveredPkgs.subtract(incompletePkgs)` is the one line; running it the other way restores
    /// complete-wins and this row goes red.
    func testPackageChainedCompleteAndIncompleteLosesItsCoverage() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let incomplete = root.appendingPathComponent("dep-incomplete.json")
        try incompleteVariant(depReport, to: incomplete)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-ci").path],
                        env: ["CANDOR_DEPS": "\(depReport.path):\(incomplete.path)"])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-ci.App.Swift.json"))
        XCTAssertEqual(by["goUnlisted"]?["invisible"] as? [String], ["RatesDep"],
                       "one of the two chained reports declares source it could not analyze, so the "
                       + "package's silence about a key NEITHER answers is not a purity claim. Measured "
                       + "with the incomplete report chained ALONE it hedges; complete-wins cancelled it.")
        XCTAssertTrue(r.err.contains("could not analyze") && r.err.contains("RatesDep"),
                      "…and the ledger says which package and why: \(r.err)")
        // THE ENTRIES ARE UNTOUCHED — the cost of this is a hedge, never an effect. Incompleteness
        // withholds coverage and nothing else, so an answered key still answers, with its surface.
        XCTAssertEqual(Set(by["go"]?["inferred"] as? [String] ?? []), ["Net"])
        XCTAssertEqual(by["go"]?["hosts"] as? [String], ["rates.internal:7070"])
    }

    /// THE SECOND FIXTURE, WRITTEN FIRST: two COMPLETE reports for one package still cover it. Without
    /// this the change above is indistinguishable from "a package chained twice loses its coverage",
    /// which would flood every workspace that reaches a package through two paths.
    func testAPackageChainedTwiceByTwoCompleteReportsKeepsItsCoverage() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let copy = root.appendingPathComponent("dep-copy.json")
        try doctor(depReport, to: copy) { _ in }
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-cc").path],
                        env: ["CANDOR_DEPS": "\(depReport.path):\(copy.path)"])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-cc.App.Swift.json"))
        XCTAssertNil(by["goUnlisted"], "neither report hedges, so the package is covered and silence claims")
        XCTAssertFalse(r.err.contains("could not analyze"), r.err)
        XCTAssertEqual(Set(by["go"]?["inferred"] as? [String] ?? []), ["Net"],
                       "…and the identical-entry exemption keeps the answer (see `insert`)")
    }

    /// THE SHARPER FORM, and it is candor-rust `63bbe87`'s argument arriving on the COMPLETENESS axis
    /// rather than the staleness one. §2 rule 1 forbids picking between two candidates, so this index
    /// DROPS a key two TRUSTED reports disagree under — and under complete-wins the package stayed
    /// covered, which turned the withdrawn key into a positive purity claim over a function BOTH
    /// reports call effectful.
    ///
    ///   C alone  go -> ['Exec']    A alone  go -> ['Net']    A and C  go -> ABSENT FROM `functions`
    func testAWithdrawnKeyUnderAnIncompleteSiblingDoesNotReadPure() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        // a second FRESH report for RatesDep that disagrees about `hit` AND declares itself incomplete
        let other = root.appendingPathComponent("dep-other.json")
        try doctor(depReport, to: other) { d in
            var fns: [Any] = []
            for case var f as [String: Any] in (d["functions"] as? [Any]) ?? [] {
                if f["fn"] as? String == "hit" {
                    f["inferred"] = ["Exec"]; f["cmds"] = ["/bin/ls"]; f.removeValue(forKey: "hosts")
                }
                fns.append(f)
            }
            d["functions"] = fns
            d["unanalyzed"] = [["path": "Sources/RatesDep/Other.swift", "reason": "source failed to read"]]
        }
        // the control: chained ALONE it answers, so the row below is about the collision and not about
        // the report being unusable
        let solo = try run(bin, [app.path, "--out", root.appendingPathComponent("app-solo").path],
                           env: ["CANDOR_DEPS": other.path])
        XCTAssertEqual(solo.code, 0)
        XCTAssertEqual(Set(try fns(ofReport: root.appendingPathComponent("app-solo.App.Swift.json"))["go"]?["inferred"] as? [String] ?? []),
                       ["Exec"], "the disagreeing report must answer on its own, or this proves nothing")

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-ac").path],
                        env: ["CANDOR_DEPS": "\(depReport.path):\(other.path)"])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-ac.App.Swift.json"))
        XCTAssertNotNil(by["go"],
                        "the key is withdrawn as ambiguous, which is right — but with the package still "
                        + "COVERED that withdrawal read as a ⟨0.21⟩ purity claim over a function both "
                        + "reports call effectful. A withdrawn key must fall back to disclosure.")
        XCTAssertEqual(by["go"]?["invisible"] as? [String], ["RatesDep"])
    }

    /// STALENESS IS CHECKED FIRST. A report this engine does not trust cannot be trusted about its own
    /// completeness either, so its `unanalyzed` buys it nothing beyond the downgrade it already has — and
    /// it must land in `stalePkgs`, not `incompletePkgs`, or rule 2's `Unknown` downgrade is lost.
    func testAStaleReportThatAlsoDeclaresItselfIncompleteIsStillTreatedAsStale() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let both = root.appendingPathComponent("dep-both.json")
        try doctor(depReport, to: both) { d in
            var candor = d["candor"] as! [String: Any]
            candor["version"] = "candor-doctored-0.0.0"
            d["candor"] = candor
            d["unanalyzed"] = [["path": "x.swift", "reason": "source failed to read"]]
        }
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-b").path],
                        env: ["CANDOR_DEPS": both.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-b.App.Swift.json"))
        XCTAssertEqual(Set(by["go"]?["inferred"] as? [String] ?? []), ["Unknown"],
                       "rule 2's downgrade still applies — the incompleteness must not divert it")
        XCTAssertEqual(by["go"]?["unknownWhy"] as? [String], ["dep-stale:RatesDep"])
        XCTAssertTrue(r.err.contains("granted NO coverage"), "the STALE disclosure is the one that fires: \(r.err)")
        XCTAssertFalse(r.err.contains("could not analyze"),
                       "…and not the incompleteness one, which would claim its `unanalyzed` was believed: \(r.err)")
    }

    // ── ⟨0.24⟩ `analyzed.count == 0` IS "I JUDGED NOTHING" ────────────────────────────────────────
    //
    // A chained report carrying `functions: []` and `analyzed.count: 0` bought a consumer MORE
    // confidence than not chaining the package at all: every call into it dropped out of `functions`,
    // which under ⟨0.21⟩ is a positive purity claim, with no advisory in either channel — while the
    // UNCHAINED arm over the same sources correctly discloses `invisible` + `coverage.uncovered` + the
    // κ nudge. Strictly more confident than having no report, which is the one thing a report may never
    // buy. Conformance PART 26 measured 64 live cells ABSENT in this engine.
    //
    // THE WIRE ALREADY SAID WHICH IT WAS. A `pub use`-style facade package scans to `count: 0`; an
    // all-pure two-function package scans to `count: 2` with the same empty `functions`. Nothing read the
    // integer, so both read as an all-clear.
    //
    // THE SECOND ROW IS THE CONTROL AND IT IS WHY THIS IS NOT A ONE-LINER: `count: n>0` with an empty
    // `functions` is a legitimate all-pure claim that §2 rule 3 says a consumer SHOULD believe, and a fix
    // that hedged BOTH rows would have disabled chained coverage rather than implemented the rule.
    // `testEmptyDepReportIsAPurityClaim` above is the pre-existing pin on that row and is untouched;
    // `testTheAllPureArmAndTheJudgedNothingArmDiverge` below is the in-repo CONTROL SEPARATION.

    /// Doctor the report to `functions: []` with `analyzed.count` forced to `zero` (the ⟨0.24⟩ FLOOR arm)
    /// or left exactly as produced (the CONTROL arm). One integer apart, deliberately.
    private func emptiedVariant(_ report: URL, to out: URL, zeroCount: Bool) throws {
        try doctor(report, to: out) { d in
            d["functions"] = [Any]()
            if zeroCount {
                var a = (d["analyzed"] as? [String: Any]) ?? [:]
                a["count"] = 0
                d["analyzed"] = a
            }
        }
    }

    /// THE SECOND FIXTURE, WRITTEN FIRST — the control. An all-pure dep report (`functions: []`,
    /// `analyzed.count` as produced) must still grant full coverage and gain NO hedge: that is §2 rule 3,
    /// and a change that also hedged here would have deleted chained coverage instead of fixing it.
    func testAnAllPureDepReportWithAJudgedCountStillGrantsCoverage() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let allPure = root.appendingPathComponent("dep-allpure.json")
        try emptiedVariant(depReport, to: allPure, zeroCount: false)
        // the arm is only a control if its `analyzed.count` really is non-zero — assert the input
        let count = ((try JSONSerialization.jsonObject(with: Data(contentsOf: allPure)) as? [String: Any])?["analyzed"]
                     as? [String: Any])?["count"] as? Int
        XCTAssertGreaterThan(count ?? 0, 0,
                             "the CONTROL arm must carry a POSITIVE judged count, or it is the FLOOR arm and "
                             + "this test asserts the opposite of what it says")

        let policy = root.appendingPathComponent("deny-net.policy")
        try "deny Net\n".write(to: policy, atomically: true, encoding: .utf8)
        let verdict = root.appendingPathComponent("verdict-allpure.json")
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-ap").path,
                              "--policy", policy.path, "--gate-json", verdict.path],
                        env: ["CANDOR_DEPS": allPure.path])
        XCTAssertEqual(r.code, 0, "an all-pure dep's claim is believed, so the gate is green: \(r.err)")
        let by = try fns(ofReport: root.appendingPathComponent("app-ap.App.Swift.json"))
        for fn in ["go", "goMember", "goUnlisted"] {
            XCTAssertNil(by[fn], "\(fn): an all-pure report's silence is its purity CLAIM (§2 rule 3) and "
                         + "⟨0.24⟩ must not hedge it; got \(by[fn] ?? [:])")
        }
        let env = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("app-ap.App.Swift.json"))) as? [String: Any]
        XCTAssertNil(env?["coverage"], "…and the κ ledger must not name a covered package")
        XCTAssertFalse(r.err.contains("judged NOTHING"),
                       "the ⟨0.24⟩ advisory must NOT fire on a positive all-pure claim: \(r.err)")
        XCTAssertFalse(r.err.contains("classifier doesn't cover"), r.err)
        let v = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict)) as? [String: Any]
        XCTAssertNil(v?["coverage"], "the machine-readable verdict carries no caveat either: \(v ?? [:])")
    }

    /// THE FLOOR ARM. `analyzed.count: 0` means the producer judged nothing, so its silence licenses
    /// nothing: the package is NOT COVERED and the consumer must carry exactly the disclosure it would
    /// carry with no dep report at all — per-fn `invisible`, the `coverage.uncovered` envelope, the κ
    /// stderr nudge and the gate verdict's caveat. Asserted AGAINST the unchained arm rather than against
    /// a hand-written expectation, because "exactly as if unchained" is the rule §2 states.
    func testADepReportThatJudgedNothingGrantsNoCoverage() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let zero = root.appendingPathComponent("dep-zero.json")
        try emptiedVariant(depReport, to: zero, zeroCount: true)
        let policy = root.appendingPathComponent("deny-net.policy")
        try "deny Net\n".write(to: policy, atomically: true, encoding: .utf8)

        let verdict = root.appendingPathComponent("verdict-zero.json")
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-z").path,
                              "--policy", policy.path, "--gate-json", verdict.path],
                        env: ["CANDOR_DEPS": zero.path])
        XCTAssertEqual(r.code, 0, r.err)
        let by = try fns(ofReport: root.appendingPathComponent("app-z.App.Swift.json"))
        for fn in ["go", "goMember", "goUnlisted"] {
            XCTAssertEqual(by[fn]?["invisible"] as? [String], ["RatesDep"],
                           "\(fn): a report that judged NOTHING makes no purity claim about it — absence "
                           + "from `functions` here is the ⟨0.21⟩ claim the cardinal sin is made of")
        }
        let env = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("app-z.App.Swift.json"))) as? [String: Any]
        let uncovered = (env?["coverage"] as? [String: Any])?["uncovered"] as? [[String: Any]]
        XCTAssertEqual(uncovered?.map { $0["name"] as? String }, ["RatesDep"],
                       "the κ ledger travels with the report (⟨0.15⟩), naming the package nobody judged")
        XCTAssertTrue(r.err.contains("judged NOTHING") && r.err.contains("RatesDep"),
                      "the advisory must NAME the package and say what it means: \(r.err)")
        XCTAssertTrue(r.err.contains("classifier doesn't cover"),
                      "…and the ordinary κ nudge fires too, exactly as unchained: \(r.err)")
        let v = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict)) as? [String: Any]
        XCTAssertEqual((v?["coverage"] as? [String: Any])?["packages"] as? [String], ["RatesDep"],
                       "the gate verdict re-discloses it (⟨0.15⟩ verdict-preserving), so a MACHINE consumer "
                       + "of a green gate learns the package was never judged: \(v ?? [:])")

        // …and the whole point: this is the UNCHAINED answer, not a smaller one. Compared arm-to-arm
        // rather than to a literal, because the rule is "exactly as if the package were not chained".
        let u = try run(bin, [app.path, "--out", root.appendingPathComponent("app-u").path,
                              "--policy", policy.path])
        XCTAssertEqual(u.code, 0, u.err)
        let unchained = try fns(ofReport: root.appendingPathComponent("app-u.App.Swift.json"))
        XCTAssertEqual(Set(by.keys), Set(unchained.keys),
                       "the same functions are reported chained-but-unjudged as unchained")
        for fn in unchained.keys {
            XCTAssertEqual(by[fn]?["invisible"] as? [String], unchained[fn]?["invisible"] as? [String],
                           "\(fn): the same disclosure, arm for arm")
            XCTAssertEqual(by[fn]?["inferred"] as? [String], unchained[fn]?["inferred"] as? [String],
                           "\(fn): …and no effect invented or lost on the way")
        }
    }

    /// CONTROL SEPARATION, in-repo. Conformance PART 26 prints this comparison for all four engines and
    /// printed INDISTINGUISHABLE for every one of them; the two arms differ by ONE integer and a correct
    /// implementation must answer them DIFFERENTLY. Pinned here so the separation cannot be lost quietly
    /// between conformance runs.
    func testTheAllPureArmAndTheJudgedNothingArmDiverge() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        var out: [Bool: [String: [String: Any]]] = [:]
        for zero in [true, false] {
            let variant = root.appendingPathComponent("dep-sep-\(zero).json")
            try emptiedVariant(depReport, to: variant, zeroCount: zero)
            let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-sep-\(zero)").path],
                            env: ["CANDOR_DEPS": variant.path])
            XCTAssertEqual(r.code, 0, r.err)
            out[zero] = try fns(ofReport: root.appendingPathComponent("app-sep-\(zero).App.Swift.json"))
        }
        XCTAssertNotEqual(Set(out[true]!.keys), Set(out[false]!.keys),
                          "the FLOOR arm and the CONTROL arm differ only in `analyzed.count`, and an engine "
                          + "that answers them the same is not reading the manifest at all")
        XCTAssertEqual(out[true]?["go"]?["invisible"] as? [String], ["RatesDep"], "count 0 -> not covered")
        XCTAssertNil(out[false]?["go"], "count n>0 -> covered, believed all-pure")
    }

    /// ⟨0.24⟩ A DEP ENTRY THAT IS PRESENT BUT UNPARSEABLE IS CORRUPT INPUT, NEVER AN ABSENT ONE (SPEC §2,
    /// candor-spec `38ba3e2`). The file header already states the principle — a dep report that does not
    /// parse FAILS the run, because "silently skipping either would make every call into that dep read
    /// pure" — and `(e[k] as? [Any]) ?? []` undid it one entry down.
    ///
    /// MEASURED before the fix on this exact fixture, `deny Fs`, with the dep's `hit` entry doctored:
    ///
    ///     intact dep report   go -> ['Fs']                     exit 1   the gate catches it
    ///     unchained control   go -> invisible: ['RatesDep']    exit 0   the honest hedge
    ///     `fn` key deleted    go -> ABSENT from `functions`    exit 0   a ⟨0.21⟩ PURITY CLAIM
    ///     `inferred: [1]`     go -> ABSENT from `functions`    exit 0   a ⟨0.21⟩ PURITY CLAIM
    ///
    /// Both corrupt arms are strictly MORE confident than not chaining the package at all, over a function
    /// the dep report was trying to say was effectful. The two arms of the intact/unchained pair are the
    /// controls that make that reading non-vacuous, and both are asserted here.
    func testACorruptDepEntryFailsClosedRatherThanReadingPure() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        // CONTROL 1 — the intact report answers, so the corrupt arms below are not just a broken fixture.
        let policy = root.appendingPathComponent("deny-net.policy")
        try "deny Net\n".write(to: policy, atomically: true, encoding: .utf8)
        let ok = try run(bin, [app.path, "--out", root.appendingPathComponent("app-ok").path,
                               "--policy", policy.path], env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(ok.code, 1, "the INTACT dep report must make the gate fire, or the arms below prove "
                       + "nothing: \(ok.err)")

        // CONTROL 2 — unchained, the honest hedge the corrupt arms must never be more confident than.
        let un = try run(bin, [app.path, "--out", root.appendingPathComponent("app-un").path])
        XCTAssertEqual(un.code, 0, un.err)
        let unchained = try fns(ofReport: root.appendingPathComponent("app-un.App.Swift.json"))
        XCTAssertEqual(unchained["go"]?["invisible"] as? [String], ["RatesDep"],
                       "the unchained arm discloses; a chained-but-corrupt one must not do better")

        let corruptions: [(String, (inout [String: Any]) -> Void)] = [
            ("no fn key", { d in
                var fns = d["functions"] as! [[String: Any]]
                fns[0].removeValue(forKey: "fn"); d["functions"] = fns }),
            ("fn not a string", { d in
                var fns = d["functions"] as! [[String: Any]]; fns[0]["fn"] = 7; d["functions"] = fns }),
            ("inferred holds a number", { d in
                var fns = d["functions"] as! [[String: Any]]; fns[0]["inferred"] = [1]; d["functions"] = fns }),
            ("hosts is a bare string", { d in
                var fns = d["functions"] as! [[String: Any]]; fns[0]["hosts"] = "h"; d["functions"] = fns }),
            ("unknownWhy holds null", { d in
                var fns = d["functions"] as! [[String: Any]]
                fns[0]["inferred"] = ["Unknown"]; fns[0]["unknownWhy"] = [NSNull()]; d["functions"] = fns }),
        ]
        for (name, mutate) in corruptions {
            let variant = root.appendingPathComponent("dep-corrupt-\(name.replacingOccurrences(of: " ", with: "-")).json")
            try doctor(depReport, to: variant, mutate: mutate)
            let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-c").path,
                                  "--policy", policy.path], env: ["CANDOR_DEPS": variant.path])
            XCTAssertEqual(r.code, 2, "\(name): a corrupt dep entry must FAIL the run, not be skipped — "
                           + "skipping it makes every call it answers read pure, which is the exact care "
                           + "this file's header takes one level up. stderr: \(r.err)")
            XCTAssertTrue(r.err.contains(variant.lastPathComponent),
                          "\(name): and the refusal names the report: \(r.err)")
        }
    }

    /// THE CONTROL FOR THE ROW ABOVE. An ABSENT optional key still takes its documented default — a dep
    /// entry carrying only `fn`, `hash` and `inferred` is ordinary, not corrupt, and must still join.
    /// Conflating absent with present-but-unparseable would refuse every report in the wild.
    func testADepEntryWithOnlyItsRequiredKeysStillJoins() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let minimal = root.appendingPathComponent("dep-minimal.json")
        try doctor(depReport, to: minimal) { d in
            d["functions"] = (d["functions"] as! [[String: Any]]).map { e in
                ["fn": e["fn"]!, "hash": e["hash"]!, "inferred": e["inferred"]!] as [String: Any]
            }
        }
        let policy = root.appendingPathComponent("deny-net.policy")
        try "deny Net\n".write(to: policy, atomically: true, encoding: .utf8)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-min").path,
                              "--policy", policy.path], env: ["CANDOR_DEPS": minimal.path])
        XCTAssertEqual(r.code, 1, "an entry with no `hosts`/`calls`/`unknownWhy`/… is ordinary, and its "
                       + "effect must still cross the join: \(r.err)")
    }

    /// The manifest is only a claim when it IS one. The anti-flood rows matter as much as the fail-closed
    /// ones: reading a pre-⟨0.21⟩ producer's ABSENT manifest as "judged nothing" would withdraw coverage
    /// from every report that predates the rung — the `unanalyzed` absent/garbled mistake in a new costume
    /// (java measured that one at 7 failing tests, ts at 15).
    ///
    /// ⟨0.24⟩ **THE `bool_true` ROW IS THE ONE THAT WAS LIVE, AND SPEC §2 NAMES THIS ENGINE FOR IT.**
    /// Foundation bridges a JSON `true` to `__NSCFBoolean`, and `__NSCFBoolean as? Int` SUCCEEDS with `1` —
    /// so `analyzed: {count: true}` read as JUDGED and granted full coverage **byte-identically to
    /// `count: 2`**, and `goUnlisted` then dropped out of `functions` entirely: a ⟨0.21⟩ positive purity
    /// claim licensed by a manifest that made no readable claim at all. MEASURED before the fix, one
    /// integer's worth of difference between this row and `count_two` producing zero difference in output.
    /// The other three engines fail closed here only because their JSON readers are stricter, not because
    /// anyone tested it — which is why the row is in the table rather than in a note.
    ///
    /// `float_integral` is the anti-flood control for the numeric half: `2.0` is a legitimate JSON
    /// spelling of 2 and must still be believed, so the rejection is of NON-INTEGRAL values, not of the
    /// double representation.
    func testAnAbsentOrGarbledAnalyzedManifestIsReadAsAClaimOnlyWhenItIsOne() throws {
        let bin = try binaryURL()
        let (root, dep, app) = try makeChainFixture(extraApp: """
        public func goUnlisted() {
            brandNewApi()
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        // (name, `analyzed` value — .some(nil) removes the key, keepEntries, expect covered)
        let cases: [(String, Any??, Bool, Bool)] = [
            ("count_zero",    .some(["count": 0, "digest": "x"] as [String: Any]), false, false),
            ("count_two",     .some(["count": 2, "digest": "x"] as [String: Any]), false, true),
            ("absent_empty",  .some(nil),                                          false, false),
            ("absent_entries", .some(nil),                                         true,  true),
            ("string",        .some("oops"),                                       true,  false),
            ("no_count",      .some([:] as [String: Any]),                         true,  false),
            ("null",          .some(NSNull()),                                     true,  false),
            // ⟨0.24⟩ A BOOLEAN IS NOT AN INTEGER — the live one. `as? Int` on `__NSCFBoolean` yields 1.
            ("bool_true",     .some(["count": true, "digest": "x"] as [String: Any]),  false, false),
            ("bool_false",    .some(["count": false, "digest": "x"] as [String: Any]), false, false),
            // …nor is a fraction, nor a negative count. All three "no readable claim" (SPEC §2 ⟨0.24⟩).
            ("fractional",    .some(["count": 2.5, "digest": "x"] as [String: Any]),   true,  false),
            ("negative",      .some(["count": -1, "digest": "x"] as [String: Any]),    true,  false),
            ("count_string",  .some(["count": "2", "digest": "x"] as [String: Any]),   true,  false),
            // …but `2.0` IS 2. The anti-flood control for the numeric half.
            ("float_integral", .some(["count": 2.0, "digest": "x"] as [String: Any]),  false, true),
        ]
        for (name, value, keepEntries, expectCovered) in cases {
            let variant = root.appendingPathComponent("dep-a-\(name).json")
            try doctor(depReport, to: variant) { d in
                if !keepEntries { d["functions"] = [Any]() }
                if let v = value, let vv = v { d["analyzed"] = vv } else { d.removeValue(forKey: "analyzed") }
            }
            let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-a-\(name)").path],
                            env: ["CANDOR_DEPS": variant.path])
            XCTAssertEqual(r.code, 0, "\(name): scan failed: \(r.err)")
            let by = try fns(ofReport: root.appendingPathComponent("app-a-\(name).App.Swift.json"))
            if expectCovered {
                XCTAssertNil(by["goUnlisted"],
                             "\(name): this report DID judge something, and its silence is the claim §2 rule 3 "
                             + "says to believe — withholding coverage here floods every pre-rung report")
            } else {
                XCTAssertEqual(by["goUnlisted"]?["invisible"] as? [String], ["RatesDep"],
                               "\(name): a report that judged nothing — or garbled the manifest that would "
                               + "have said otherwise — has made no claim, so its silence buys nothing")
            }
            if keepEntries {
                // ENTRIES ARE KEPT EITHER WAY. Withholding coverage may never take a real answer with it:
                // that is the mirror sin, and it is what makes this strictly additive.
                XCTAssertEqual(Set(by["go"]?["inferred"] as? [String] ?? []), ["Net"],
                               "\(name): the entries the report DOES carry still answer")
            }
        }
    }
}
