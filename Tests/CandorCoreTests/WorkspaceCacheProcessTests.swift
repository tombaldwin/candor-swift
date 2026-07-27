import XCTest
import Foundation

/// `--workspace`'s `.candor/deps` cache must never stand in for a scan that did not happen.
///
/// The directory is a DISK cache that outlives the run, and `loadDepReports` walks all of it. A local
/// path dependency whose child scan FAILS was silently skipped (its stderr went to `/dev/null`), so the
/// PREVIOUS run's report stayed on disk and was chained as though it were this run's answer — and §2
/// rule 3 turns a chained report's silence into a purity claim. The candor-rust `39bbc8b` shape (a
/// fail-closed abort cached as a false all-clear) reached through a different door.
///
/// The reproduction that drove the fix, with the COLD arm as the control that proves it is the cache and
/// not a general limitation:
///
///   run 1  dep pure, scans clean                     -> .candor/deps/DepLib.json written
///   dep then performs Fs and gains a `.candor/config` naming a policy the consumer cannot resolve
///   run 2  WARM  -> `useDep` ABSENT from `functions`  (a ⟨0.21⟩ purity claim)
///   run 2  COLD  -> `useDep` -> invisible: ['DepLib'], and the κ ledger names it
final class WorkspaceCacheProcessTests: XCTestCase {

    /// app + `depCount` local path deps. Each dep starts PURE and scannable.
    private func makeWorkspace(depCount: Int = 1) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-ws-\(UUID().uuidString)")
        let fm = FileManager.default
        var depDecls: [String] = []
        for i in 0..<depCount {
            let name = "Dep\(i)"
            try fm.createDirectory(at: root.appendingPathComponent("\(name)/Sources/\(name)"),
                                   withIntermediateDirectories: true)
            try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "\(name)", targets: [.target(name: "\(name)")])
            """.write(to: root.appendingPathComponent("\(name)/Package.swift"), atomically: true, encoding: .utf8)
            try "public func work\(i)() { }\n"
                .write(to: root.appendingPathComponent("\(name)/Sources/\(name)/D.swift"),
                       atomically: true, encoding: .utf8)
            depDecls.append(".package(path: \"../\(name)\")")
        }
        try fm.createDirectory(at: root.appendingPathComponent("app/Sources/App"), withIntermediateDirectories: true)
        // ONE APP FILE PER DEP. The per-fn `invisible` attribution for an unqualified call is
        // FILE-granular by design (a syntactic engine cannot pin which import a dropped call lands in,
        // so it names every blind module in scope). Sharing one file would put the failed dep's hedge on
        // the healthy dep's caller too, and the "a healthy sibling is untouched" assertion would be
        // measuring that over-approximation instead of the sweep.
        for i in 0..<depCount {
            try "import Dep\(i)\npublic func use\(i)() { work\(i)() }\n"
                .write(to: root.appendingPathComponent("app/Sources/App/Use\(i).swift"),
                       atomically: true, encoding: .utf8)
        }
        // ONE `.package(path:)` PER LINE. The discovery regex takes the FIRST `path:` match on a line
        // (deliberately — see the "single-line dep decl" note in main.swift), so a fixture that puts two
        // on one line silently declares only one dep and the multi-dep tests below would be measuring a
        // one-dep workspace.
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
        \(depDecls.map { "        \($0)," }.joined(separator: "\n"))
            ],
            targets: [.target(name: "App")])
        """.write(to: root.appendingPathComponent("app/Package.swift"), atomically: true, encoding: .utf8)
        return root
    }

    /// Make dep `i` perform Fs AND become unscannable — the realistic pair: the dependency's own repo
    /// carries a `.candor/config` naming a policy path the consumer's checkout does not have (§3.4
    /// resolves it against the CONFIG's dir), so the child scan fails closed (exit 2, "gate NOT
    /// enforced") exactly where the consumer needs an answer. Note the separator is WHITESPACE — an
    /// `=` or `:` parses as an unknown key and the child would exit 0, i.e. the fixture would be
    /// measuring nothing (standing bar item 7d: name the thing your arms actually differ in).
    private func breakDep(_ root: URL, _ i: Int) throws {
        let name = "Dep\(i)"
        try """
        import Foundation
        public func work\(i)() { try? "s".write(toFile: "/tmp/leak\(i).txt", atomically: true, encoding: .utf8) }
        """.write(to: root.appendingPathComponent("\(name)/Sources/\(name)/D.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("\(name)/.candor"),
                                                withIntermediateDirectories: true)
        try "policy ./ci/strict.candor\n"
            .write(to: root.appendingPathComponent("\(name)/.candor/config"), atomically: true, encoding: .utf8)
    }

    private func scan(_ bin: URL, _ root: URL, out: String) throws -> (out: String, err: String, code: Int32) {
        try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--workspace",
                                     "--out", root.appendingPathComponent(out).path])
    }

    private func appFns(_ root: URL, _ out: String) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("\(out).App.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return by
    }

    // ── THE DEFECT ────────────────────────────────────────────────────────────────────────────────
    func testAFailedDepScanDoesNotLeaveThePreviousRunsReportStandingIn() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        // run 1 warms the cache
        XCTAssertEqual(try scan(bin, root, out: "r1").code, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("app/.candor/deps/Dep0.json").path),
            "run 1 must write the dep report the run 2 arm depends on")

        try breakDep(root, 0)
        let r = try scan(bin, root, out: "r2")
        XCTAssertEqual(r.code, 0)
        let by = try appFns(root, "r2")

        XCTAssertNotNil(by["use0"],
                        "a call into a dependency whose scan FAILED must not be absent from `functions` — "
                        + "absence is a ⟨0.21⟩ purity claim, here backed only by a previous run's artefact")
        XCTAssertEqual(by["use0"]?["invisible"] as? [String], ["Dep0"],
                       "it falls back to the κ ledger's hedge")
        XCTAssertTrue(r.err.contains("could NOT scan the local path dependency"),
                      "the failure must be disclosed, with the child's own reason: \(r.err)")
        XCTAssertTrue(r.err.contains("removed 1 stale report"),
                      "the stale artefact must be named as removed: \(r.err)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("app/.candor/deps/Dep0.json").path),
            "the unconfirmed report must be gone, or the NEXT run inherits the same false all-clear")
    }

    /// The COLD control: the same broken state with no cache at all must give the same answer. This is
    /// what makes the row above a CACHE defect rather than a general limitation.
    func testTheColdControlAgreesWithTheSweptWarmRun() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try breakDep(root, 0)
        let r = try scan(bin, root, out: "cold")     // never warmed
        XCTAssertEqual(r.code, 0)
        let by = try appFns(root, "cold")
        XCTAssertEqual(by["use0"]?["invisible"] as? [String], ["Dep0"])
        XCTAssertTrue(r.err.contains("classifier doesn't cover") && r.err.contains("Dep0"), r.err)
        // the count line must not claim there are no path deps when there is one that failed
        XCTAssertFalse(r.err.contains("no local path deps found"),
                       "there IS a local path dep — it failed; the two must not read the same: \(r.err)")
    }

    // ── THE SECOND FIXTURE: what must STILL work ──────────────────────────────────────────────────

    /// A clean workspace run must sweep NOTHING and chain as before. The sharp part is the SECOND run:
    /// a dep whose report is byte-unchanged takes the `prev == out` branch and is never rewritten, so a
    /// sweep keyed on "was written this run" would delete a valid cache it had just verified.
    func testARepeatedCleanRunSweepsNothingAndKeepsChaining() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeWorkspace(depCount: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        for (i, out) in ["first", "second", "third"].enumerated() {
            let r = try scan(bin, root, out: out)
            XCTAssertEqual(r.code, 0)
            XCTAssertFalse(r.err.contains("removed"), "run \(i + 1) must sweep nothing: \(r.err)")
            XCTAssertFalse(r.err.contains("could NOT scan"), "run \(i + 1): \(r.err)")
            XCTAssertTrue(r.err.contains("chained 2 workspace dep report(s)"), "run \(i + 1): \(r.err)")
            for d in ["Dep0", "Dep1"] {
                XCTAssertTrue(FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("app/.candor/deps/\(d).json").path),
                    "run \(i + 1) must keep \(d)'s report")
            }
            // both packages stay COVERED — no hedge, no ledger entry
            XCTAssertFalse(r.err.contains("classifier doesn't cover"), "run \(i + 1): \(r.err)")
        }
    }

    /// THE SWEEP ALONE IS NOT ENOUGH, and this is the row that proves the re-run is load-bearing rather
    /// than belt-and-braces. Every child is spawned with `CANDOR_DEPS` pointing at the SAME cache, so a
    /// sibling that scans cleanly can chain the stale report we are about to remove — and that sibling's
    /// report is then chained by the parent. Sweeping after the fixpoint would leave the false all-clear
    /// exactly one hop away from where it was found.
    func testASiblingThatChainedTheStaleReportIsRescannedAfterTheSweep() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeWorkspace(depCount: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        // Dep1 calls into Dep0, so Dep1's own scan resolves `work0` only through the shared cache.
        try "import Dep0\npublic func work1() { work0() }\n"
            .write(to: root.appendingPathComponent("Dep1/Sources/Dep1/D.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try scan(bin, root, out: "warm").code, 0)

        try breakDep(root, 0)
        let r = try scan(bin, root, out: "after")
        XCTAssertEqual(r.code, 0)
        let dep1 = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("app/.candor/deps/Dep1.json"))) as! [String: Any]
        let work1 = ((dep1["functions"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
            .first { $0["fn"] as? String == "work1" }
        XCTAssertEqual(work1?["invisible"] as? [String], ["Dep0"],
                       "Dep1 scanned cleanly, but its answer about Dep0 came from a report this run "
                       + "removed — it must be re-derived without it, not left claiming purity")
        // …and the parent inherits the honest answer through the chain.
        XCTAssertEqual(try appFns(root, "after")["use1"]?["invisible"] as? [String], ["Dep0"])
    }

    /// The sweep is per-REPORT, not per-run: one dep failing must not cost the other dep its answer.
    func testOneFailedDepDoesNotSweepAHealthySiblingsReport() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeWorkspace(depCount: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try scan(bin, root, out: "warm").code, 0)
        try breakDep(root, 0)
        let r = try scan(bin, root, out: "after")
        XCTAssertEqual(r.code, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("app/.candor/deps/Dep0.json").path), "the failed dep is swept")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("app/.candor/deps/Dep1.json").path), "the healthy dep is kept")
        let by = try appFns(root, "after")
        XCTAssertEqual(by["use0"]?["invisible"] as? [String], ["Dep0"], "the failed dep hedges")
        XCTAssertNil(by["use1"], "the healthy dep's silence is still a purity claim")
        XCTAssertTrue(r.err.contains("chained 1 workspace dep report(s)"), r.err)
    }
}
