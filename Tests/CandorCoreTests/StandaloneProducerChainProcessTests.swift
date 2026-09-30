import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R836 / R838 / R839 — **A REPORT PRODUCED WITHOUT A CHAIN IS STILL READ BY ONE.**
///
/// The ordinary ⟨0.39⟩ workflow scans a middle library on its own and hands its report to whoever
/// consumes it. R567(a) (`dbe3f68`) refused the key for any receiver whose chain crossed a member this
/// engine could not type, and disclosed the refusal ONLY in a chained scan — on the premise that an
/// unchained package's κ ledger already discloses. For a MEMBER call it does not: the ledger is
/// report-level (`coverage.uncovered`), per-row `invisible` fires only for unqualified calls, and a
/// consumer chaining the report reads neither. So the middle library published neither key nor
/// disclosure and a three-package chain fell SILENT against v0.39.2 — `Client.shared.fetch()` (R836 as
/// filed), but equally `n.parent.visit()` and `Theme.dark.apply()`, which R826's singleton re-admission
/// did not reach. EXECUTED: every consumer function below was built with `swift build` and run, and its
/// effect printed (`fx/g1`, `fx/g3` in the R836 lane's scratch).
///
/// The fix keeps the release's owner as a FLOOR (its key is published again, in both modes), resolves the
/// hops whose type IS established — nested, module-qualified and generic type paths (R838), a singleton
/// on a type the package only extends (R839) — and discloses a genuine guess beside the floor key in a
/// standalone scan too.
///
/// The bar these assert is MONOTONE against v0.39.2: every gate below that exits 1 on the release exits 1
/// here. The release's values are stated beside each assertion.
final class StandaloneProducerChainProcessTests: XCTestCase {

    struct Row { let inferred: Set<String>; let unknownWhy: Set<String>; let dispatchesOn: Set<String> }

    static let depPackage = """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "RatesCore",
        products: [.library(name: "RatesCore", targets: ["RatesCore"])],
        targets: [.target(name: "RatesCore")])
    """
    static let libPackage = """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "LibA", products: [.library(name: "LibA", targets: ["LibA"])],
        dependencies: [.package(path: "../dep")],
        targets: [.target(name: "LibA", dependencies: [.product(name: "RatesCore", package: "dep")])])
    """
    static let appPackage = """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
        dependencies: [.package(path: "../lib"), .package(path: "../dep")],
        targets: [.target(name: "App", dependencies: [.product(name: "LibA", package: "lib"),
                                                      .product(name: "RatesCore", package: "dep")])])
    """

    static let dep = """
    import Foundation
    public final class Client { public static let shared = Client(); public init() {}
        public func fetch() { _ = ProcessInfo.processInfo.environment["Y"] } }
    public final class Node { public init() {}; public var parent: Node { Node() }
        public func visit() { _ = ProcessInfo.processInfo.environment["Y"] } }
    public final class Theme { public static let dark = Theme(); public init() {}
        public func apply() { _ = ProcessInfo.processInfo.environment["Y"] } }
    public final class Loop { public init() {}; public func spin() { _ = ProcessInfo.processInfo.environment["Y"] } }
    public final class Chan2 { public init() {}; public var loop: Loop { Loop() } }
    public enum Outer { public final class Inner { public static let shared = Inner(); public init() {}
        public func fetch() { _ = ProcessInfo.processInfo.environment["Y"] } } }
    public final class Box<T> { public static var shared: Box<T> { Box<T>() }; public init() {}
        public func fetch() { _ = ProcessInfo.processInfo.environment["Y"] } }
    public final class Svc { public static let shared = Svc(); public init() {}
        public func fetch() { _ = ProcessInfo.processInfo.environment["Y"] } }
    """

    static let lib = """
    import RatesCore
    public func viaShared() { Client.shared.fetch() }
    public func viaParent(_ n: Node) { n.parent.visit() }
    public func viaTheme() { Theme.dark.apply() }
    public func viaLoopMiss(_ c: Chan2) { c.loop.spin() }
    public func viaNested() { Outer.Inner.shared.fetch() }
    public func viaQualNested() { RatesCore.Outer.Inner.shared.fetch() }
    public func viaGeneric() { Box<Int>.shared.fetch() }
    public func viaExtShared() { Svc.shared.fetch() }
    public func viaExtBound() { let s = Svc.shared; s.fetch() }
    extension Svc { public func localExtra() -> Int { 1 } }
    """

    static let app = """
    import LibA
    import RatesCore
    func tShared() { viaShared() }
    func tParent() { viaParent(Node()) }
    func tTheme() { viaTheme() }
    func tLoopMiss() { viaLoopMiss(Chan2()) }
    func tNested() { viaNested() }
    func tQualNested() { viaQualNested() }
    func tGeneric() { viaGeneric() }
    func tExtShared() { viaExtShared() }
    func tExtBound() { viaExtBound() }
    """

    /// dep scanned standalone; lib scanned STANDALONE (`libChained: false`) or chained on dep; app chained
    /// on both. Returns lib rows, app rows, and `deny <policy>` exits over the app.
    func run(libChained: Bool, policies: [String: String], env: [String: String] = [:], label: String)
        throws -> (lib: [String: Row], app: [String: Row], gates: [String: Int32]) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r836-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["dep/Package.swift": Self.depPackage, "dep/Sources/RatesCore/lib.swift": Self.dep,
                     "lib/Package.swift": Self.libPackage, "lib/Sources/LibA/a.swift": Self.lib,
                     "app/Package.swift": Self.appPackage, "app/Sources/App/app.swift": Self.app]
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let depOnly = root.appendingPathComponent("depOnly"), all = root.appendingPathComponent("all")
        for d in [depOnly, all] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        func clean(_ dir: URL) throws {
            for f in try FileManager.default.contentsOfDirectory(atPath: dir.path)
            where f.hasSuffix(".callgraph.json") || f.hasSuffix(".hierarchy.json") {
                try FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        var r = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path,
                                             "--out", depOnly.appendingPathComponent("dep").path], env: env)
        XCTAssertEqual(r.code, 0, "dep scan: \(r.err)")
        try clean(depOnly)
        var libEnv = env
        if libChained { libEnv["CANDOR_DEPS"] = depOnly.path }
        r = try ProcessHarness.run(bin, [root.appendingPathComponent("lib").path,
                                         "--out", all.appendingPathComponent("lib").path], env: libEnv)
        XCTAssertEqual(r.code, 0, "lib scan: \(r.err)")
        try FileManager.default.copyItem(at: depOnly.appendingPathComponent("dep.RatesCore.Swift.json"),
                                         to: all.appendingPathComponent("dep.RatesCore.Swift.json"))
        try clean(all)
        var chainEnv = env; chainEnv["CANDOR_DEPS"] = all.path
        let appDir = root.appendingPathComponent("app").path
        r = try ProcessHarness.run(bin, [appDir, "--out", root.appendingPathComponent("ch").path], env: chainEnv)
        XCTAssertEqual(r.code, 0, "app scan: \(r.err)")
        func rows(_ u: URL) throws -> [String: Row] {
            let d = try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as? [String: Any]
            var out: [String: Row] = [:]
            for f in (d?["functions"] as? [[String: Any]]) ?? [] {
                out[(f["fn"] as? String) ?? "?"] = Row(
                    inferred: Set((f["inferred"] as? [String]) ?? []),
                    unknownWhy: Set((f["unknownWhy"] as? [String]) ?? []),
                    dispatchesOn: Set((f["dispatchesOn"] as? [String]) ?? []))
            }
            return out
        }
        var gates: [String: Int32] = [:]
        for (name, text) in policies {
            let p = root.appendingPathComponent("\(name).policy")
            try text.write(to: p, atomically: true, encoding: .utf8)
            gates[name] = try ProcessHarness.run(bin, [appDir, "--policy", p.path,
                                                       "--out", root.appendingPathComponent("g-\(name)").path],
                                                 env: chainEnv).code
        }
        return (try rows(all.appendingPathComponent("lib.LibA.Swift.json")),
                try rows(root.appendingPathComponent("ch.App.Swift.json")), gates)
    }

    static func policies(_ fns: [String]) -> [String: String] {
        var p: [String: String] = [:]
        for f in fns { p["env-\(f)"] = "deny Env \(f)\n"; p["envunk-\(f)"] = "deny Env Unknown \(f)\n" }
        return p
    }

    /// R836 as filed and its siblings: the middle library scanned WITHOUT `CANDOR_DEPS`.
    ///
    ///     fn          v0.39.2 deny Env / deny Env Unknown     6938f8b        here
    ///     tShared     1 / 1                                   0 / 0          1 / 1
    ///     tParent     1 / 1                                   0 / 0          1 / 1   (+ Unknown)
    ///     tTheme      1 / 1                                   0 / 0          1 / 1   (+ Unknown)
    ///     tLoopMiss   0 / 0                                   0 / 0          0 / 1   (disclosed)
    ///     tNested     0 / 0                                   0 / 0          1 / 1   (R838, resolved)
    ///     tQualNested 0 / 0                                   0 / 0          1 / 1
    ///     tGeneric    0 / 0                                   0 / 0          1 / 1
    ///     tExtShared  0 / 0                                   0 / 0          1 / 1   (R839)
    ///     tExtBound   0 / 0                                   0 / 0          1 / 1   (R839, bound)
    func testAMiddleLibraryScannedStandaloneStillCarriesTheChain() throws {
        let fns = ["tShared", "tParent", "tTheme", "tLoopMiss", "tNested", "tQualNested", "tGeneric",
                   "tExtShared", "tExtBound"]
        let r = try run(libChained: false, policies: Self.policies(fns), label: "solo")
        for fn in fns {
            XCTAssertEqual(r.gates["envunk-\(fn)"], 1,
                           "\(fn): `deny Env Unknown` over code that reads the environment — got \(r.gates["envunk-\(fn)"] ?? -1); app row \(String(describing: r.app[fn]))")
        }
        for fn in fns where fn != "tLoopMiss" {
            XCTAssertEqual(r.gates["env-\(fn)"], 1, "\(fn): `deny Env` (1 on v0.39.2 for tShared/tParent/tTheme)")
        }
        // the producer side: the release's key is PUBLISHED by the standalone middle library
        XCTAssertEqual(r.lib["viaShared"]?.dispatchesOn, ["RatesCore#Client.fetch"],
                       "the key v0.39.2 published and 6938f8b withheld; got \(String(describing: r.lib["viaShared"]))")
        XCTAssertTrue(r.lib["viaParent"]?.dispatchesOn.contains("RatesCore#Node.visit") ?? false, "the floor key")
        XCTAssertTrue(r.lib["viaParent"]?.unknownWhy.contains("dispatch:untyped cross-package receiver") ?? false,
                      "…and the guess disclosed IN THE STANDALONE REPORT, where a consumer will read it")
        XCTAssertTrue(r.lib["viaNested"]?.dispatchesOn.contains("RatesCore#Outer.Inner.fetch") ?? false,
                      "R838: the nested type path is the key, spelled as the dependency's hash spells it")
        XCTAssertTrue(r.lib["viaGeneric"]?.dispatchesOn.contains("RatesCore#Box.fetch") ?? false, "generic")
        XCTAssertEqual(r.lib["viaExtShared"]?.dispatchesOn, ["RatesCore#Svc.fetch"], "R839")
        // a CONVENTION hop is a resolution: no hedge on the standalone row (v0.39.2 parity)
        XCTAssertTrue(r.lib["viaShared"]?.unknownWhy.isEmpty ?? false, "no hedge on a convention owner")
    }

    /// The same program with the middle library CHAINED: the release's charges, plus the resolutions.
    func testTheSameChainWithTheMiddleChainedAgrees() throws {
        let fns = ["tShared", "tParent", "tTheme", "tNested", "tQualNested", "tGeneric", "tExtShared", "tExtBound"]
        let r = try run(libChained: true, policies: Self.policies(fns), label: "chain")
        for fn in fns {
            XCTAssertEqual(r.gates["env-\(fn)"], 1, "\(fn): got app row \(String(describing: r.app[fn]))")
        }
        XCTAssertEqual(r.lib["viaParent"]?.inferred, ["Env", "Unknown"],
                       "the floor's answer AND the disclosure; 6938f8b gave ['Unknown'] (`deny Env` 1 -> 0)")
        XCTAssertEqual(r.lib["viaNested"]?.inferred, ["Env"], "R838 resolved, not hedged")
    }

    /// §1b — the standalone disclosure is what the kill switch removes, and the release's own behaviour
    /// (`CANDOR_R567A_OFF=1`: floor only) leaves the miss-through-a-guess silent, as v0.39.2 did.
    func testTheStandaloneDisclosureCanFail() throws {
        let p = ["envunk-tLoopMiss": "deny Env Unknown tLoopMiss\n"]
        let on = try run(libChained: false, policies: p, label: "cal-on")
        let off = try run(libChained: false, policies: p, env: ["CANDOR_R836_OFF": "1"], label: "cal-off")
        let rel = try run(libChained: false, policies: p, env: ["CANDOR_R567A_OFF": "1"], label: "cal-rel")
        XCTAssertEqual(on.gates["envunk-tLoopMiss"], 1)
        XCTAssertEqual(off.gates["envunk-tLoopMiss"], 0, "CANDOR_R836_OFF must re-open the standalone silence")
        XCTAssertEqual(rel.gates["envunk-tLoopMiss"], 0, "the release's own answer, for comparison")
    }
}

/// SPEC §2 rule 1 ⟨0.25⟩ at the CROSS-PACKAGE join: two chained packages answering one key is an
/// ambiguous key, and it is UNIONED — never dropped. The engine dropped it (`hits.count == 1`), latent
/// until R567(b) (`8931087`) published the bare spelling of every overloaded dependency member and made
/// keys collide across packages: RxAlamofire's four `ObservableType.validate` rows went `['Unknown']` on
/// v0.39.2 -> ABSENT. EXECUTED below: `extension A { func viaSelf() { go() } }` really runs `A.go` (Env);
/// two packages declare a `go`, the implicit-self call is keyed on the leaf, both answer.
final class AmbiguousCrossPackageJoinProcessTests: XCTestCase {

    func testTwoPackagesAnsweringOneKeyAreUnionedNotDropped() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-union-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files: [String: String] = [
            "depa/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "PA", products: [.library(name: "PA", targets: ["PA"])], targets: [.target(name: "PA")])
            """,
            "depa/Sources/PA/a.swift": """
            import Foundation
            open class A { public init() {}; open func go() { _ = ProcessInfo.processInfo.environment["Y"] } }
            """,
            "depb/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "PB", products: [.library(name: "PB", targets: ["PB"])], targets: [.target(name: "PB")])
            """,
            "depb/Sources/PB/b.swift": """
            import Foundation
            public final class B { public init() {}; public func go() { _ = FileManager.default.fileExists(atPath: "/tmp") } }
            """,
            "app/Package.swift": """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
                dependencies: [.package(path: "../depa"), .package(path: "../depb")],
                targets: [.target(name: "App", dependencies: [.product(name: "PA", package: "depa"),
                                                              .product(name: "PB", package: "depb")])])
            """,
            "app/Sources/App/app.swift": """
            import PA
            import PB
            extension A { public func viaSelf() { go() } }
            """,
        ]
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let depR = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depR, withIntermediateDirectories: true)
        for d in ["depa", "depb"] {
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent(d).path, "--out", depR.appendingPathComponent(d).path])
            XCTAssertEqual(r.code, 0, r.err)
        }
        for f in try FileManager.default.contentsOfDirectory(atPath: depR.path)
        where f.hasSuffix(".callgraph.json") || f.hasSuffix(".hierarchy.json") {
            try FileManager.default.removeItem(at: depR.appendingPathComponent(f))
        }
        func scan(_ env: [String: String]) throws -> Set<String>? {
            var e = env; e["CANDOR_DEPS"] = depR.path
            let out = root.appendingPathComponent("ch-\(env.keys.sorted().joined())")
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", out.path], env: e)
            XCTAssertEqual(r.code, 0, r.err)
            let d = try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: out.path + ".App.Swift.json"))) as? [String: Any]
            let row = ((d?["functions"] as? [[String: Any]]) ?? []).first { ($0["fn"] as? String) == "A.viaSelf" }
            return row.map { Set(($0["inferred"] as? [String]) ?? []) }
        }
        let on = try scan([:])
        XCTAssertTrue(on?.contains("Env") ?? false,
                      "the real callee's Env must reach the row through the union; got \(String(describing: on))")
        XCTAssertTrue(on?.contains("Fs") ?? false,
                      "…and the other package's answer too — the union over-charges by design (SPEC ⟨0.25⟩); "
                      + "if this narrows, say which contributor was dropped and why that is not a pick")
        let off = try scan(["CANDOR_JOIN_UNION_OFF": "1"])
        XCTAssertNil(off, "§1b: with the drop restored the row is ABSENT — the purity claim this closes")
    }
}
