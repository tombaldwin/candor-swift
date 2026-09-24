import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R565 — **A MODULE IS NOT A PACKAGE, AND SPEC §2 KEYS ON THE PACKAGE.**
///
/// Every §2 chain gate in this engine asked `deps.isChained(m)` with an `m` straight out of
/// `fileImports` — a MODULE — while every key in the index is `<PACKAGE>#<qual>`, because SPEC §2 ⟨0.39⟩
/// obligation 2 says the key is "fully qualified in the OWNING package's namespace, the same namespace
/// that package's entry hashes use". For any dependency whose `Package(name:)` differs from its module
/// names — `swift-nio`/`NIOCore`, `swift-collections`/`DequeModule`, `swift-atomics`/`Atomics`, i.e. the
/// normal shape of a real SwiftPM dependency — the whole chain was a NO-OP: loaded, parsed, indexed,
/// never consulted. The κ coverage ledger had the identical confusion one direction over.
///
/// THE PROCESS ARM IS THE CALIBRATION, and it is a ONE-VARIABLE A/B: the two arms differ only in the
/// dependency manifest's `Package(name:)` string. Same sources, same `.package(path:)` reference, same
/// `.product(name:package:)`, same binary.
///
///     Package(name: "RatesDep"),  module RatesCore   go -> [] invisible:[RatesCore]   deny Fs exit 0
///     Package(name: "RatesCore"), module RatesCore   go -> ['Fs']                     deny Fs exit 1
///
/// The second arm is the CONTROL and it is not optional: the pre-fix engine already passed it, so a
/// "fix" that resolved nothing at all — or one that broke module-name-equals-package-name chaining,
/// which is what every hand-written fixture and conformance PART in this family looks like — is caught
/// by exactly one of the two arms.
final class DepModulePackageKeyingProcessTests: XCTestCase {

    // MARK: - the map, unit-level (injected filesystem, no spawn)

    private func fakeFS(_ files: [String: String], _ dirs: [String: [String]])
        -> (read: (String) -> String?, list: (String) -> [String]?) {
        ({ files[$0] }, { dirs[$0] })
    }

    func testAModuleResolvesToItsOwningPackageThroughTheDependencysOwnManifest() {
        let (read, list) = fakeFS([
            "/root/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "App",
                dependencies: [.package(path: "../dep"),
                               .package(url: "https://example.com/swift-nio", from: "2.0.0")],
                targets: [.target(name: "App")])
            """,
            "/dep/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "RatesDep",
                products: [.library(name: "RatesCore", targets: ["RatesCore"])],
                targets: [.target(name: "RatesCore"), .testTarget(name: "RatesCoreTests")])
            """,
            "/root/.build/checkouts/swift-nio/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "swift-nio",
                products: [.library(name: "NIOCore", targets: ["NIOCore"])],
                targets: [.target(name: "NIOCore"), .target(name: "NIOPosix")])
            """,
        ], ["/root/.build/checkouts": ["swift-nio"]])
        let map = dependencyModulePackages(rootDir: "/root", readManifest: read, listDir: list)

        XCTAssertEqual(map["RatesCore"], "RatesDep",
                       "a local path dependency whose `Package(name:)` differs from its target name is "
                       + "the whole defect — without this entry `deps.isChained(\"RatesCore\")` is false "
                       + "and the report is never consulted")
        XCTAssertEqual(map["NIOCore"], "swift-nio", "a materialised checkout resolves the same way")
        XCTAssertEqual(map["NIOPosix"], "swift-nio",
                       "EVERY module of the package, not only the one named by a product — the join "
                       + "gate is asked per IMPORT")
        XCTAssertNil(map["App"],
                     "the ROOT package is not a dependency: its modules are the scan's own and "
                     + "`importableByFile` already answers for them")
        XCTAssertNil(map["RatesCoreTests"], "a test target is not importable by a consumer")
    }

    func testAModuleTwoPACKAGESCLAIMIsDroppedRatherThanGuessed() {
        let (read, list) = fakeFS([
            "/root/Package.swift": """
            import PackageDescription
            let package = Package(name: "App",
                dependencies: [.package(path: "../a"), .package(path: "../b")],
                targets: [.target(name: "App")])
            """,
            "/a/Package.swift": """
            import PackageDescription
            let package = Package(name: "PkgA", targets: [.target(name: "Shared"), .target(name: "OnlyA")])
            """,
            "/b/Package.swift": """
            import PackageDescription
            let package = Package(name: "PkgB", targets: [.target(name: "Shared")])
            """,
        ], [:])
        let map = dependencyModulePackages(rootDir: "/root", readManifest: read, listDir: list)
        XCTAssertNil(map["Shared"],
                     "two packages declaring one module name is the §2 rule-1 posture: DROP, never pick. "
                     + "An unmapped module falls back to ITSELF, which is exactly the pre-fix key — so "
                     + "the ambiguous case is a no-change, not a wrong change")
        XCTAssertEqual(map["OnlyA"], "PkgA",
                       "…and the unambiguous sibling in the same manifest still resolves, or the drop "
                       + "above could be a whole-manifest failure wearing an ambiguity's clothes")
    }

    func testAModuleWhoseNameAlreadyIsItsPackageNameNeedsNoEntry() {
        let (read, list) = fakeFS([
            "/root/Package.swift": """
            import PackageDescription
            let package = Package(name: "App", dependencies: [.package(path: "../same")],
                targets: [.target(name: "App")])
            """,
            "/same/Package.swift": """
            import PackageDescription
            let package = Package(name: "Alamofire", targets: [.target(name: "Alamofire")])
            """,
        ], [:])
        let map = dependencyModulePackages(rootDir: "/root", readManifest: read, listDir: list)
        XCTAssertTrue(map.isEmpty, "nothing to resolve; got \(map)")
    }

    // MARK: - end to end: the gate flips, and only the arm under test moves

    private struct Arm {
        let depPackageName: String
        let label: String
        /// A SECOND target in the same dependency package, imported by the consumer alongside the first.
        /// `swift-nio` shipping `NIOCore` AND `NIOPosix` is the ordinary shape, and it is the one the fix
        /// itself can break: every §2 join gates on `hits.count == 1`, so asking one package's index once
        /// per imported MODULE collects one entry twice and refuses the join as ambiguous.
        var secondModule: Bool = false
    }

    private func runArm(_ arm: Arm) throws -> (inferred: Set<String>, invisible: Set<String>,
                                               uncovered: Set<String>, gateExit: Int32) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r565-\(arm.label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        // THE ONE VARIABLE. Everything below is byte-identical between the two arms.
        let extraTarget = arm.secondModule ? ", .target(name: \"RatesExtra\")" : ""
        let extraProduct = arm.secondModule
            ? ", .library(name: \"RatesExtra\", targets: [\"RatesExtra\"])" : ""
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(arm.depPackageName)",
            products: [.library(name: "RatesCore", targets: ["RatesCore"])\(extraProduct)],
            targets: [.target(name: "RatesCore")\(extraTarget)])
        """)
        if arm.secondModule {
            try write("dep/Sources/RatesExtra/extra.swift", "public func extraPure() -> Int { return 1 }\n")
        }
        try write("dep/Sources/RatesCore/lib.swift", """
        import Foundation
        public func hit() -> String {
            return (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
        }
        """)
        let extraLink = arm.secondModule
            ? ", .product(name: \"RatesExtra\", package: \"dep\")" : ""
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [
                .product(name: "RatesCore", package: "dep")\(extraLink)])])
        """)
        try write("app/Sources/App/app.swift", """
        import RatesCore
        \(arm.secondModule ? "import RatesExtra" : "")
        public func go() -> String { return hit() }
        """)
        try write("deny.policy", "deny Fs\n")

        let depDir = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path,
                                              "--out", depDir.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        // §E3 — the dependency report must actually CARRY the effect, or both arms below are assertions
        // about nothing. Named by discovery, never hard-coded: the filename IS the package name, which is
        // the variable under test.
        let written = try FileManager.default.contentsOfDirectory(atPath: depDir.path)
            .filter { $0.hasSuffix(".Swift.json") && !$0.contains("callgraph") && !$0.contains("hierarchy") }
        XCTAssertEqual(written, ["r.\(arm.depPackageName).Swift.json"],
                       "the report is filed under `Package(name:)`, which is also the `hash` prefix the "
                       + "consumer must ask on; got \(written)")
        let depDoc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: depDir.appendingPathComponent(written.first ?? ""))) as? [String: Any]
        let depFns = (depDoc?["functions"] as? [[String: Any]]) ?? []
        XCTAssertEqual(depFns.compactMap { $0["hash"] as? String }, ["\(arm.depPackageName)#hit"],
                       "the dependency must publish exactly the key the consumer will ask for — and "
                       + "exactly ONE entry, so the consumer's `hits.count == 1` gate is a statement "
                       + "about how many times the index was ASKED")
        // the chaining loader refuses a directory holding anything but reports
        for extra in try FileManager.default.contentsOfDirectory(atPath: depDir.path)
        where extra != written.first {
            try FileManager.default.removeItem(at: depDir.appendingPathComponent(extra))
        }

        let out = root.appendingPathComponent("ch")
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", out.path],
                                       env: ["CANDOR_DEPS": depDir.path])
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        let fns = (d?["functions"] as? [[String: Any]]) ?? []
        let go = fns.first { ($0["fn"] as? String) == "go" }
        let cov = (d?["coverage"] as? [String: Any])?["uncovered"] as? [[String: Any]] ?? []

        let g = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                             "--policy", root.appendingPathComponent("deny.policy").path,
                                             "--out", root.appendingPathComponent("g").path],
                                       env: ["CANDOR_DEPS": depDir.path])
        return (Set((go?["inferred"] as? [String]) ?? []),
                Set((go?["invisible"] as? [String]) ?? []),
                Set(cov.compactMap { $0["name"] as? String }),
                g.code)
    }

    func testAChainedDependencyJoinsWhenItsPackageNameDiffersFromItsModuleName() throws {
        let differs = try runArm(Arm(depPackageName: "RatesDep", label: "differs"))
        XCTAssertEqual(differs.inferred, ["Fs"],
                       "the dependency's `RatesDep#hit` is `Fs` and the consumer's `go()` calls it. "
                       + "Before R565 the join asked `RatesCore#hit` — the MODULE — matched nothing, and "
                       + "`go` came back with `inferred: []`")
        XCTAssertTrue(differs.invisible.isEmpty,
                      "…and the κ hedge must clear with it: a package a trusted report COVERS is not a "
                      + "blind spot (§2 rule 3). Two voices that disagree is the state this leaves "
                      + "otherwise; got \(differs.invisible.sorted())")
        XCTAssertFalse(differs.uncovered.contains("RatesCore"),
                       "the scan-level ledger is the same question and must move with it; "
                       + "got \(differs.uncovered.sorted())")
        XCTAssertEqual(differs.gateExit, 1,
                       "`deny Fs` over code that reaches `/etc/hosts` through a chained dependency: "
                       + "exit 0 here is the gate-level shape of the defect")
    }

    func testTheCONTROLArmWherePackageNameEqualsModuleNameIsUnchanged() throws {
        let same = try runArm(Arm(depPackageName: "RatesCore", label: "same"))
        XCTAssertEqual(same.inferred, ["Fs"],
                       "CONTROL: this arm ALREADY passed before R565 — it is what every hand-written "
                       + "fixture and conformance PART in this family looks like. A fix that resolved a "
                       + "module to the wrong package, or that broke the dedup, reds here and not above")
        XCTAssertTrue(same.invisible.isEmpty)
        XCTAssertFalse(same.uncovered.contains("RatesCore"))
        XCTAssertEqual(same.gateExit, 1)
    }

    func testTwoModulesOfOneChainedPackageStillJoin() throws {
        let two = try runArm(Arm(depPackageName: "RatesDep", label: "two", secondModule: true))
        XCTAssertEqual(two.inferred, ["Fs"],
                       "`swift-nio` shipping `NIOCore` AND `NIOPosix` is the ordinary shape of the "
                       + "dependency this fix exists for. Resolving each imported MODULE to the same "
                       + "package and asking the index once PER MODULE collects one entry twice, and "
                       + "`hits.count == 1` then refuses the join — a loss manufactured by the fix, "
                       + "invisible to the single-module arms above")
        XCTAssertTrue(two.invisible.isEmpty)
        XCTAssertEqual(two.gateExit, 1)
    }

    /// **THE PUBLISH HALF, and it is a different site from every arm above.** ⟨0.39⟩ obligation 1's
    /// `dispatchesOn` key and obligation 2's `interfaceUnion` hash are the SAME namespace — `applyDepEntry`
    /// feeds a `dispatchesOn` key straight into `deps.lookup(k)` and into `unionOwnImplementors`, which
    /// compares it against `abstractionOwnerPkg`. Spelling one of them with a module and the other with a
    /// package makes the join silently miss, which is how fixing only the ASK half would have left this.
    ///
    /// MEASURED on the four-package corpus: 21 rows moved keys like
    /// `NIOEmbedded#EmbeddedChannel.finish` → `swift-nio#EmbeddedChannel.finish` — the first is a key
    /// swift-nio's own report cannot answer, because its entry hashes are `swift-nio#…`.
    func testAPublishedDispatchKeyNamesTheOWNINGPACKAGEAndNotTheModule() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r565-pub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "RatesDep",
            products: [.library(name: "RatesCore", targets: ["RatesCore"])],
            targets: [.target(name: "RatesCore")])
        """)
        try write("dep/Sources/RatesCore/lib.swift", """
        public protocol Backend { func size() -> Int }
        """)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [.product(name: "RatesCore", package: "dep")])])
        """)
        try write("app/Sources/App/app.swift", """
        import RatesCore
        public func appSize(_ b: Backend) -> Int { return b.size() }
        """)
        let out = root.appendingPathComponent("p")
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", out.path])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("p.App.Swift.json"))) as? [String: Any]
        let fns = (d?["functions"] as? [[String: Any]]) ?? []
        let keys = Set(fns.flatMap { ($0["dispatchesOn"] as? [String]) ?? [] })
        XCTAssertTrue(keys.contains("RatesDep#Backend.size"),
                      "obligation 1's key is `<owning pkg>#<type path>.<member>` (DepEntry.dispatchesOn's "
                      + "own wire contract). `RatesCore#Backend.size` names the MODULE, and the owning "
                      + "package's entry hashes are `RatesDep#…`, so no consumer could ever join it; "
                      + "got \(keys.sorted())")
        XCTAssertFalse(keys.contains("RatesCore#Backend.size"),
                       "…and the module spelling must be GONE, not merely joined by a second one — "
                       + "SPEC §2 ⟨0.39⟩ obligation 2: an engine MUST NOT invent a second spelling; "
                       + "got \(keys.sorted())")
    }
}
