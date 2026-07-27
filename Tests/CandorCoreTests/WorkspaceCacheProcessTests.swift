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

    // ── THE SWEEP MUST NOT DELETE A FILE IT DID NOT WRITE ────────────────────────────────────────
    //
    // `.candor/deps` is the directory SPEC §2 tells a user to drop reports into: for a BINARY
    // dependency `--workspace` cannot scan, for a package whose report was produced by hand, or for
    // another engine's report in a polyglot repo. The first version of the sweep removed every `*.json`
    // this run's own path-dep scans had not produced, which is exactly those files. Unrecoverably.
    //
    // This is not an analysis defect and that is why it is worth stating separately: candor's contract
    // is that it does not destroy information, and a file the user chose to put there is information.
    //
    // The SECOND fixture is the pre-existing suite above and it must stay green — the sweep exists for a
    // real reason (`43a0eaa`: a stale child report standing in for a failed rescan) and the fix is to
    // distinguish reports this run OWNS from reports it merely FOUND, never to stop sweeping.

    /// A report for a package that is not a local path dep at all — the binary-dependency case.
    @discardableResult
    private func placeUserReport(_ root: URL, named: String) throws -> URL {
        let deps = root.appendingPathComponent("app/.candor/deps")
        try FileManager.default.createDirectory(at: deps, withIntermediateDirectories: true)
        let f = deps.appendingPathComponent("\(named).json")
        try "{\"candor\":{\"version\":\"hand-written\"},\"package\":\"\(named)\",\"functions\":[]}"
            .write(to: f, atomically: true, encoding: .utf8)
        return f
    }

    func testAReportTheRunDidNotWriteIsNeverASweepCandidate() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = try placeUserReport(root, named: "BinaryDep")

        // (a) a clean run sweeps nothing anyway — but it must not touch the file even so
        XCTAssertEqual(try scan(bin, root, out: "clean").code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path),
                      "a user-placed report must survive a run that sweeps nothing")

        // (b) …and it must survive the run where the sweep DOES fire, which is the real defect
        try breakDep(root, 0)
        let r = try scan(bin, root, out: "swept")
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path),
                      "the sweep removed a report `--workspace` never wrote — unrecoverable, and nothing "
                      + "to do with the stale path-dep report it was aimed at")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("app/.candor/deps/Dep0.json").path),
            "…while the report it DOES own is still swept: the fix is ownership, not restraint")
        // the file it left alone is DISCLOSED rather than silently ignored
        XCTAssertTrue(r.err.contains("does not produce") && r.err.contains("BinaryDep.json"),
                      "a report the run leaves in place must be named: \(r.err)")
        XCTAssertTrue(r.err.contains("removed 1 stale report"),
                      "only the owned report is counted: \(r.err)")
    }

    /// …and the ownership derivation must find the file of a dep whose scan has NEVER succeeded in this
    /// process, which is the case where no package name was recorded: the name comes from the
    /// dependency's own `Package.swift`. Without that fallback a run over a warm cache leaves the stale
    /// report exactly where `43a0eaa` found it.
    ///
    /// THE DIRECTORY IS DELIBERATELY NAMED DIFFERENTLY FROM THE PACKAGE. With `Dep0/` holding package
    /// `Dep0` the last resort — the directory basename — produces the right answer too, so the
    /// `Package.swift` branch could be deleted and this row would still pass: a test that cannot reach
    /// the code it names is not a test. Here the basename is `libdep-src` and only the manifest says
    /// `Dep0`, so exactly one branch can find the file.
    // ── …AND NEVER A FILE THIS RUN WROTE ─────────────────────────────────────────────────────────
    //
    // Ownership is by NAME. Two local path deps can derive the SAME report name — the ordinary shape is
    // one package vendored twice, an upstream checkout beside a fork — and when one of them scans and
    // the other fails, the FAILED dep "owns" the file the healthy one wrote seconds ago. The sweep
    // deleted it. Then, because a non-empty sweep triggers the second fixpoint round, the retry rewrote
    // it and the second sweep deleted it AGAIN.
    //
    // `b4f6cbc` closed the sibling of this (a file the USER put there) with a rule about who wrote a
    // file; this is the same rule one step stronger, and it is the simplest form of it: never delete a
    // file this run wrote. `confirmed` already holds exactly that set.

    /// A workspace holding the same package twice: `Shared/` scans and is EFFECTFUL, `vendor/Shared/`
    /// derives the same report name and fails, `Ghost/` fails with a genuinely stale report on disk.
    /// Plus a user-placed report for a binary dep. All four fates in one run.
    private func makeCollidingWorkspace() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-ws-\(UUID().uuidString)")
        func pkg(_ rel: String, name: String, target: String, body: String, broken: Bool) throws {
            try fm.createDirectory(at: root.appendingPathComponent("\(rel)/Sources/\(target)"),
                                   withIntermediateDirectories: true)
            try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "\(name)", targets: [.target(name: "\(target)")])
            """.write(to: root.appendingPathComponent("\(rel)/Package.swift"), atomically: true, encoding: .utf8)
            try body.write(to: root.appendingPathComponent("\(rel)/Sources/\(target)/S.swift"),
                           atomically: true, encoding: .utf8)
            if broken {
                try fm.createDirectory(at: root.appendingPathComponent("\(rel)/.candor"), withIntermediateDirectories: true)
                try "policy ./ci/strict.candor\n"
                    .write(to: root.appendingPathComponent("\(rel)/.candor/config"), atomically: true, encoding: .utf8)
            }
        }
        // the healthy one, and it PERFORMS Fs — so the consumer's answer is a positive effect rather
        // than an absence, and a lost report shows up as a lost `Fs` and not just a missing file
        try pkg("Shared", name: "Shared", target: "Shared", body: """
        import Foundation
        public func work() { try? "s".write(toFile: "/tmp/candor-shared.txt", atomically: true, encoding: .utf8) }
        """, broken: false)
        // the same PACKAGE name from a different path, and it fails to scan
        try pkg("vendor/Shared", name: "Shared", target: "Shared",
                body: "public func vendored() { }\n", broken: true)
        // a failed dep whose stale report really is nobody else's — the control that keeps the sweep alive
        try pkg("Ghost", name: "Ghost", target: "Ghost", body: "public func ghost() { }\n", broken: true)

        try fm.createDirectory(at: root.appendingPathComponent("app/Sources/App"), withIntermediateDirectories: true)
        try "import Shared\npublic func use() { work() }\n"
            .write(to: root.appendingPathComponent("app/Sources/App/U.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(path: "../Shared"),
                .package(path: "../vendor/Shared"),
                .package(path: "../Ghost"),
            ],
            targets: [.target(name: "App")])
        """.write(to: root.appendingPathComponent("app/Package.swift"), atomically: true, encoding: .utf8)

        let deps = root.appendingPathComponent("app/.candor/deps")
        try fm.createDirectory(at: deps, withIntermediateDirectories: true)
        // a file this run neither wrote nor owns…
        try "{\"candor\":{\"version\":\"hand-written\"},\"package\":\"BinaryDep\",\"functions\":[]}"
            .write(to: deps.appendingPathComponent("BinaryDep.json"), atomically: true, encoding: .utf8)
        // …and one it did not write but DOES own: genuinely stale, and it must still go
        try "{\"candor\":{\"version\":\"hand-written\"},\"package\":\"Ghost\",\"functions\":[]}"
            .write(to: deps.appendingPathComponent("Ghost.json"), atomically: true, encoding: .utf8)
        return root
    }

    func testAFailedDepDoesNotSweepTheReportAHealthySiblingJustWrote() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = try makeCollidingWorkspace()
        defer { try? fm.removeItem(at: root) }
        let deps = root.appendingPathComponent("app/.candor/deps")

        let r = try scan(bin, root, out: "coll")
        XCTAssertEqual(r.code, 0, r.err)

        // THE DEFECT: the file the healthy dep wrote THIS RUN, deleted on the failed dep's behalf —
        // and deleted a second time after the retry rewrote it.
        XCTAssertTrue(fm.fileExists(atPath: deps.appendingPathComponent("Shared.json").path),
                      "`Shared/` scanned cleanly and its report was written this run; the sweep deleted "
                      + "it because `vendor/Shared/` derives the same report name and failed. Deleting a "
                      + "file this run produced is unrecoverable and has nothing to do with staleness.")
        // …and the analysis consequence, which is what makes it more than a housekeeping bug
        let by = try appFns(root, "coll")
        XCTAssertEqual(by["use"]?["inferred"] as? [String], ["Fs"],
                       "the consumer's answer comes from that report — with it deleted, `use` fell back "
                       + "to `invisible: ['Shared']` and the dependency's real file write went unseen")
        XCTAssertEqual(by["use"]?["paths"] as? [String], ["/tmp/candor-shared.txt"],
                       "…and its literal surface with it")

        // THE SWEEP IS STILL A SWEEP — the failed dep whose report is nobody else's still loses it
        XCTAssertFalse(fm.fileExists(atPath: deps.appendingPathComponent("Ghost.json").path),
                       "`Ghost/` failed and its stale report is not a sibling's answer — it must still "
                       + "go, or the fix is 'stop sweeping' rather than 'never delete what you wrote'")
        // …and a report this run neither wrote nor owns is still left alone (b4f6cbc's row)
        XCTAssertTrue(fm.fileExists(atPath: deps.appendingPathComponent("BinaryDep.json").path))
        XCTAssertTrue(r.err.contains("removed 1 stale report") && r.err.contains("Ghost.json"),
                      "exactly one removal, and it is named: \(r.err)")

        // A FALSE DISCLOSURE IS WORSE THAN A MISSING ONE. The per-dep failure line used to say the
        // cache's report "has been removed so the package falls back to the κ ledger" — untrue here,
        // and the file under that name is a DIFFERENT package's answer.
        XCTAssertTrue(r.err.contains("is one ANOTHER local path dep produced this run"),
                      "the collision must be named, not papered over: \(r.err)")
        XCTAssertEqual(r.err.components(separatedBy: "falls back to the κ ledger").count - 1, 1,
                       "only Ghost's line may claim the ledger fallback: \(r.err)")
    }

    func testAStaleReportIsSweptWhenOnlyTheDepManifestNamesIt() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-ws-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("libdep-src/Sources/Dep0"),
                               withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Dep0", targets: [.target(name: "Dep0")])
        """.write(to: root.appendingPathComponent("libdep-src/Package.swift"), atomically: true, encoding: .utf8)
        try "public func work0() { }\n"
            .write(to: root.appendingPathComponent("libdep-src/Sources/Dep0/D.swift"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("app/Sources/App"), withIntermediateDirectories: true)
        try "import Dep0\npublic func use0() { work0() }\n"
            .write(to: root.appendingPathComponent("app/Sources/App/Use0.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(path: "../libdep-src"),
            ],
            targets: [.target(name: "App")])
        """.write(to: root.appendingPathComponent("app/Package.swift"), atomically: true, encoding: .utf8)

        XCTAssertEqual(try scan(bin, root, out: "warm").code, 0)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("app/.candor/deps/Dep0.json").path),
                      "the report is filed under the PACKAGE name, not the directory name")
        // now break it, in a fresh process that never records a package name for this dep
        try """
        import Foundation
        public func work0() { try? "s".write(toFile: "/tmp/leak0.txt", atomically: true, encoding: .utf8) }
        """.write(to: root.appendingPathComponent("libdep-src/Sources/Dep0/D.swift"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("libdep-src/.candor"), withIntermediateDirectories: true)
        try "policy ./ci/strict.candor\n"
            .write(to: root.appendingPathComponent("libdep-src/.candor/config"), atomically: true, encoding: .utf8)

        let r = try scan(bin, root, out: "cold")
        XCTAssertEqual(r.code, 0)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("app/.candor/deps/Dep0.json").path),
                       "the manifest's `name:` is the only source that finds this file — without it the "
                       + "stale report survives and `43a0eaa`'s false all-clear is back")
        XCTAssertEqual(try appFns(root, "cold")["use0"]?["invisible"] as? [String], ["Dep0"])
    }
}
