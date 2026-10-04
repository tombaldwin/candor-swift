import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R826 + R827 — two regressions against the released v0.39.2, both in the §2 chain, both
/// found by the v0.39.3 release panel, both EXECUTED (every consumer function below was built with
/// `swift build` and run; its effect printed) before these assertions were written.
///
/// R826 — R567(a) (`dbe3f68`) refused every receiver chain that walked an untyped `.member` hop, the
/// singleton accessor included. `Client.shared.fetch()` on a chained dependency whose `fetch` reads the
/// environment went `['Env']` -> `['Unknown']`, and `deny Env viaShared` 1 -> 0, while the bound
/// spelling `let s = Client.shared; s.fetch()` kept `['Env']`.
///
/// R827 — R565 (`cb84836`) mapped EVERY target of a dependency's manifest to its package, a C target
/// included, so the chained Swift report was taken as covering a C module it cannot contain. A caller
/// of a C function that really calls `getenv` lost its `invisible` hedge and left `functions[]`.
final class SingletonConventionAndCoverageProcessTests: XCTestCase {

    struct Row { let inferred: Set<String>; let unknownWhy: Set<String>; let invisible: Set<String>
                 let dispatchesOn: Set<String> }

    /// Writes `files` under a temp root, scans every `dep*/` package with this binary (each report
    /// chained), scans `app/`, and runs each `policies` entry as a gate. Returns the consumer's rows and
    /// the gate exits by policy name.
    func run(_ files: [String: String], policies: [String: String] = [:], env: [String: String] = [:],
             label: String) throws -> (rows: [String: Row], gates: [String: Int32]) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r826-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let depR = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depR, withIntermediateDirectories: true)
        let deps = Set(files.keys.compactMap { k -> String? in
            let first = String(k.split(separator: "/").first ?? "")
            return first.hasPrefix("dep") ? first : nil
        }).sorted()
        for d in deps {
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent(d).path,
                                                 "--out", depR.appendingPathComponent(d).path], env: env)
            XCTAssertEqual(r.code, 0, "dependency scan \(d) must succeed — stderr: \(r.err)")
        }
        for f in try FileManager.default.contentsOfDirectory(atPath: depR.path)
        where f.hasSuffix(".callgraph.json") || f.hasSuffix(".hierarchy.json") {
            try FileManager.default.removeItem(at: depR.appendingPathComponent(f))
        }
        var chainEnv = env; chainEnv["CANDOR_DEPS"] = depR.path
        let app = root.appendingPathComponent("app").path
        let r = try ProcessHarness.run(bin, [app, "--out", root.appendingPathComponent("ch").path], env: chainEnv)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = Row(
                inferred: Set((f["inferred"] as? [String]) ?? []),
                unknownWhy: Set((f["unknownWhy"] as? [String]) ?? []),
                invisible: Set((f["invisible"] as? [String]) ?? []),
                dispatchesOn: Set((f["dispatchesOn"] as? [String]) ?? []))
        }
        var gates: [String: Int32] = [:]
        for (name, text) in policies {
            let p = root.appendingPathComponent("\(name).policy")
            try text.write(to: p, atomically: true, encoding: .utf8)
            gates[name] = try ProcessHarness.run(bin, [app, "--policy", p.path,
                                                       "--out", root.appendingPathComponent("g-\(name)").path],
                                                 env: chainEnv).code
        }
        return (rows, gates)
    }

    // MARK: - R826

    static let singletonDep = """
    import Foundation
    public final class Client {
        public static let shared = Client()
        public static let `default` = Client()
        public static var current: Client { Client() }
        public static let main = Client()
        public static let other = Other()
        public let inner = Other()
        public init() {}
        public func fetch() { _ = ProcessInfo.processInfo.environment["Y"] }
        public func pureFn() -> Int { 1 }
        public static func sfetch() { _ = ProcessInfo.processInfo.environment["Y"] }
    }
    public final class Other {
        public init() {}
        public func ping() { _ = ProcessInfo.processInfo.environment["Y"] }
    }
    public struct Cfg {
        public static let shared = Cfg()
        public init() {}
        public func fetch() { _ = ProcessInfo.processInfo.environment["Y"] }
    }
    public final class Opt {
        public static let shared: Opt? = Opt()
        public func fetch() { _ = ProcessInfo.processInfo.environment["Y"] }
    }
    public enum Ns { public static let shared = Other() }
    public final class Wrong {
        public static let shared = Other()
        public func ping() { _ = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) }
    }
    """

    static let singletonApp = """
    import RatesCore
    func aShared() { Client.shared.fetch() }
    func aBound() { let s = Client.shared; s.fetch() }
    func aDefault() { Client.default.fetch() }
    func aCurrent() { Client.current.fetch() }
    func aMain() { Client.main.fetch() }
    func aStruct() { Cfg.shared.fetch() }
    func aQualified() { RatesCore.Client.shared.fetch() }
    func aQualStatic() { RatesCore.Client.sfetch() }
    func aDotSelf() { Client.shared.self.fetch() }
    func aOptional() { Opt.shared?.fetch() }
    func aOtherPing() { Client.other.ping() }
    func aInnerPing() { Client.shared.inner.ping() }
    func aNsMiss() { Ns.shared.ping() }
    func aPure() -> Int { Client.shared.pureFn() }
    func aWrong() { Wrong.shared.ping() }
    func aWrongBound() { let w = Wrong.shared; w.ping() }
    """

    func singletonFiles() -> [String: String] {
        [
            "dep/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "RatesDep",
                products: [.library(name: "RatesCore", targets: ["RatesCore"])],
                targets: [.target(name: "RatesCore")])
            """,
            "dep/Sources/RatesCore/lib.swift": Self.singletonDep,
            "app/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
                dependencies: [.package(path: "../dep")],
                targets: [.target(name: "App", dependencies: [.product(name: "RatesCore", package: "dep")])])
            """,
            "app/Sources/App/app.swift": Self.singletonApp,
        ]
    }

    /// The row's own shape and its sibling spellings: every singleton accessor in `SINGLETON_ACCESSORS`
    /// on a dependency type, a struct, an optional singleton, `.self`, and the module-qualified type —
    /// each charged the dependency's `Env` exactly as the bound spelling is, with no hedge.
    func testASingletonAccessorOnAChainedDependencyTypeIsChargedNotHedged() throws {
        let (rows, gates) = try run(singletonFiles(),
                                    policies: ["shared": "deny Env aShared\n", "qualStatic": "deny Env aQualStatic\n"],
                                    label: "charge")
        for fn in ["aShared", "aBound", "aDefault", "aCurrent", "aMain", "aStruct", "aQualified",
                   "aQualStatic", "aDotSelf"] {
            XCTAssertEqual(rows[fn]?.inferred, ["Env"], "\(fn): the dependency's answer, not a hedge; got \(String(describing: rows[fn]))")
            XCTAssertTrue(rows[fn]?.unknownWhy.isEmpty ?? false, "\(fn): a join that ANSWERED is not disclosed")
        }
        // ⟨0.40⟩ (SPEC §2 ⟨0.40⟩, R843) — `Opt.shared: Opt?` is a WRAPPER, and a wrapper's payload MUST NOT be
        // published in `holds`. So nothing the dependency says confirms that `Opt.shared?` holds an `Opt`: the
        // convention's join is KEPT (the `Env`) and the guess is DISCLOSED beside it. Every other row above is
        // answered by the dependency's own `holds`, which is why it alone carries no hedge.
        XCTAssertEqual(rows["aOptional"]?.inferred, ["Env", "Unknown"],
                       "aOptional: the guess kept AND hedged; got \(String(describing: rows["aOptional"]))")
        XCTAssertEqual(rows["aShared"]?.inferred, rows["aBound"]?.inferred,
                       "the direct and bound spellings of one program agree (R617's property, on a hit)")
        XCTAssertTrue(rows["aShared"]?.dispatchesOn.contains("RatesDep#Client.fetch") ?? false,
                      "obligation 1 publishes the key the join asked; got \(String(describing: rows["aShared"]))")
        XCTAssertEqual(gates["shared"], 1, "GATE LEVEL — `deny Env aShared` is exit 1 on v0.39.2 and must stay so")
        XCTAssertEqual(gates["qualStatic"], 1, "GATE LEVEL — a module qualifier is a spelling, not an opaque hop")
    }

    /// The half of the convention the release did NOT have: a key the dependency does not answer
    /// discloses rather than certifying purity, because a miss cannot tell "pure" from "`.shared` is not a
    /// `Client`". And a hop that is NOT a singleton accessor (`Client.other`, `Client.shared.inner`) is a
    /// GUESS: it keeps the release's key as a floor (R836) and discloses beside it.
    func testAMissDisclosesAndAGuessedOwnerDisclosesBesideTheReleaseKey() throws {
        let (rows, _) = try run(singletonFiles(), label: "miss")
        for fn in ["aPure", "aNsMiss", "aOtherPing", "aInnerPing"] {
            XCTAssertTrue(rows[fn]?.inferred.contains("Unknown") ?? false, "\(fn): got \(String(describing: rows[fn]))")
            XCTAssertTrue(rows[fn]?.unknownWhy.contains("dispatch:untyped cross-package receiver") ?? false, fn)
        }
        XCTAssertTrue(rows["aOtherPing"]?.dispatchesOn.contains("RatesDep#Client.ping") ?? false,
                      "`Client.other` is not a singleton accessor: the release keyed it on the outer base, "
                      + "and that key is the floor; got \(String(describing: rows["aOtherPing"]))")
        XCTAssertTrue(rows["aPure"]?.dispatchesOn.contains("RatesDep#Client.pureFn") ?? false,
                      "a convention owner's key is published on a MISS too, as v0.39.2 published it — "
                      + "withholding it left a consumer's own implementors nothing to answer (R836)")
    }

    /// THE RESIDUAL, stated as the property it has rather than as a value it should have. `Wrong.shared` is
    /// an `Other`, and `Wrong` ALSO declares `ping` — so the convention key lands on the wrong member
    /// (`Fs`; the executed program reads `Env`). v0.39.2 answers identically, and so does the BOUND
    /// spelling at every version; closing it needs the static's declared type, which no report carries.
    /// What is pinned is that the two spellings AGREE, so the direct one is never the looser of the two.
    func testTheDirectAndBoundSpellingsAgreeEvenWhereTheConventionIsWrong() throws {
        let (rows, _) = try run(singletonFiles(), label: "wrong")
        XCTAssertEqual(rows["aWrong"]?.inferred, rows["aWrongBound"]?.inferred,
                       "direct \(String(describing: rows["aWrong"])) vs bound \(String(describing: rows["aWrongBound"]))")
    }

    // MARK: - R827

    func coverageFiles() -> [String: String] {
        [
            "dep/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "RatesDep",
                products: [.library(name: "RatesCore", targets: ["RatesCore"]),
                           .library(name: "CShim", targets: ["CShim"]),
                           .library(name: "OShim", targets: ["OShim"]),
                           .library(name: "SysShim", targets: ["SysShim"]),
                           .library(name: "CBin", targets: ["CBin"]),
                           .library(name: "ReCore", targets: ["ReCore"])],
                targets: [.target(name: "CShim"), .target(name: "OShim"),
                          .systemLibrary(name: "SysShim"),
                          .binaryTarget(name: "CBin", path: "CBin.xcframework"),
                          .target(name: "RatesCore"),
                          .target(name: "ReCore", dependencies: ["CShim"])])
            """,
            "dep/Sources/RatesCore/lib.swift": """
            import Foundation
            public func known() { _ = ProcessInfo.processInfo.environment["Y"] }
            public func pureSwift() -> Int { 1 }
            """,
            "dep/Sources/ReCore/lib.swift": "@_exported import CShim\npublic func reKnown() -> Int { 2 }\n",
            "dep/Sources/CShim/include/cshim.h": "int shim_getenv(void);\n",
            "dep/Sources/CShim/shim.c": "#include <stdlib.h>\nint shim_getenv(void){ return getenv(\"Y\") != 0; }\n",
            "dep/Sources/OShim/include/oshim.h": "int oshim_getenv(void);\n",
            "dep/Sources/OShim/oshim.m": "#import <Foundation/Foundation.h>\nint oshim_getenv(void){ return [[NSProcessInfo processInfo] environment][@\"Y\"] != nil; }\n",
            "dep/Sources/SysShim/module.modulemap": "module SysShim [system] { header \"sysshim.h\" export * }\n",
            "dep/Sources/SysShim/sysshim.h": "#include <stdlib.h>\nstatic inline int sys_getenv(void){ return getenv(\"Y\") != 0; }\n",
            // a SECOND dependency whose C module has the PACKAGE's own name — the shape that was silent
            // on v0.39.2 too, since `pkgOfModule` is the identity there
            "dep2/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "CSame",
                products: [.library(name: "CSame", targets: ["CSame"]), .library(name: "CSameSwift", targets: ["CSameSwift"])],
                targets: [.target(name: "CSame"), .target(name: "CSameSwift")])
            """,
            "dep2/Sources/CSame/include/csame.h": "int same_getenv(void);\n",
            "dep2/Sources/CSame/same.c": "#include <stdlib.h>\nint same_getenv(void){ return getenv(\"Y\") != 0; }\n",
            "dep2/Sources/CSameSwift/lib.swift": "public func s2() -> Int { 4 }\n",
            "app/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "App",
                dependencies: [.package(path: "../dep"), .package(path: "../dep2")],
                targets: [.target(name: "App", dependencies: [
                    .product(name: "RatesCore", package: "dep"), .product(name: "CShim", package: "dep"),
                    .product(name: "OShim", package: "dep"), .product(name: "SysShim", package: "dep"),
                    .product(name: "CBin", package: "dep"), .product(name: "ReCore", package: "dep"),
                    .product(name: "CSame", package: "dep2")])])
            """,
            "app/Sources/App/c.swift": "import CShim\nfunc callShim() -> Int32 { shim_getenv() }\n",
            "app/Sources/App/o.swift": "import OShim\nfunc callObjc() -> Int32 { oshim_getenv() }\n",
            "app/Sources/App/s.swift": "import SysShim\nfunc callSys() -> Int32 { sys_getenv() }\n",
            "app/Sources/App/b.swift": "import CBin\nfunc callBin() -> Int32 { bin_getenv() }\n",
            "app/Sources/App/r.swift": "import ReCore\nfunc callReexport() -> Int32 { shim_getenv() }\n",
            "app/Sources/App/x.swift": "import CSame\nfunc callSame() -> Int32 { same_getenv() }\n",
            "app/Sources/App/k.swift": "import RatesCore\nfunc callKnown() { known() }\nfunc callPure() -> Int { pureSwift() }\n",
        ]
    }

    /// A caller of a function in a module no Swift report can contain keeps the `invisible` hedge naming
    /// THAT module — a C target, an Objective-C target, a `.systemLibrary`, a `.binaryTarget`, a C module
    /// re-exported through a covered Swift module, and a C module named like its own package — while the
    /// Swift half of the same package stays chained (R565's gain, kept).
    func testAModuleNoSwiftReportCanContainIsNeverTakenAsCovered() throws {
        let (rows, _) = try run(coverageFiles(), label: "cov")
        let cases = ["callShim": "CShim", "callObjc": "OShim", "callSys": "SysShim", "callBin": "CBin",
                     "callReexport": "CShim", "callSame": "CSame"]
        for (fn, module) in cases {
            XCTAssertNotNil(rows[fn], "\(fn) ABSENT — under ⟨0.21⟩ a purity claim over a call into \(module)")
            XCTAssertTrue(rows[fn]?.invisible.contains(module) ?? false,
                          "\(fn) must name \(module) as invisible; got \(String(describing: rows[fn]))")
        }
        XCTAssertEqual(rows["callKnown"]?.inferred, ["Env"],
                       "R565 KEPT — the Swift target of the same package is still chained and answered")
        XCTAssertNil(rows["callPure"], "…and a pure Swift function there is still legitimately absent")
    }

    // MARK: - R827, unit level

    func testOwnershipSeparatesSwiftTargetsFromEverythingElse() {
        let manifests: [String: String] = [
            "/root/Package.swift": """
            import PackageDescription
            let package = Package(name: "App", dependencies: [.package(path: "../dep")], targets: [.target(name: "App")])
            """,
            "/dep/Package.swift": """
            import PackageDescription
            let package = Package(name: "RatesDep",
                products: [.library(name: "Prod", targets: ["CShim"])],
                targets: [.target(name: "RatesCore"), .target(name: "CShim"), .target(name: "Mixed"),
                          .target(name: "Lost"), .systemLibrary(name: "Sys"),
                          .binaryTarget(name: "Bin", path: "Bin.xcframework"), .target(name: "ReCore")])
            """,
        ]
        let sources: [String: [String]] = [
            "RatesCore": ["/dep/Sources/RatesCore/a.swift"],
            "CShim": ["/dep/Sources/CShim/shim.c", "/dep/Sources/CShim/include/cshim.h"],
            "Mixed": ["/dep/Sources/Mixed/a.swift", "/dep/Sources/Mixed/b.m"],
            "ReCore": ["/dep/Sources/ReCore/r.swift"],
        ]
        let texts = ["/dep/Sources/ReCore/r.swift":
                        "@preconcurrency @_exported import struct CShim.Thing\n@_exported import RatesCore\n"]
        let o = dependencyModuleOwnership(rootDir: "/root", readManifest: { manifests[$0] }, listDir: { _ in nil },
                                          targetSources: { _, t in sources[t.name] }, readSource: { texts[$0] })
        XCTAssertEqual(o.packages, ["RatesCore": "RatesDep", "ReCore": "RatesDep"],
                       "only Swift-bearing targets map; a PRODUCT name (`Prod`) is not a module")
        XCTAssertEqual(o.notSwiftCoverable, ["CShim", "Mixed", "Lost", "Sys", "Bin"],
                       "C, mixed, unreadable (`Lost` — no sources found is not 'no sources'), systemLibrary, binaryTarget")
        XCTAssertEqual(o.reexports["ReCore"], ["CShim", "RatesCore"])
    }

    // MARK: - R837

    /// SOUNDNESS R837 — the re-export reader is the PARSER, so every spelling Swift accepts is one
    /// spelling. The regex it replaced missed `@_exported` on its own line (the consumer's caller of the
    /// re-exported C function went `invisible ['ReCore']` on v0.39.2 -> ABSENT at `6938f8b`).
    func testReexportsAreReadByTheParserInEverySpelling() {
        let src = """
        @_exported
        import CShimA
        @_exported /* keep */ import CShimB
        @preconcurrency
          @_exported import struct CShimC.Thing
        #if os(Linux)
        @_exported import CShimD
        #else
        @_exported import CShimE
        #endif
        import NotExported
        // @_exported import InAComment
        let s = "@_exported import InAString"
        """
        XCTAssertEqual(reexportedModules(source: src), ["CShimA", "CShimB", "CShimC", "CShimD", "CShimE"])
    }
}
