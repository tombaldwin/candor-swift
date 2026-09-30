import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R844 / R845 / R846 / R847 — THE JOINS THAT STILL ASSUMED ONE CHAINED PACKAGE ANSWERS.
///
/// R565 chains every ordinary SwiftPM dependency (a `Package(name:)` that differs from its module), so a
/// consumer importing two dependencies that both declare `Client` now has TWO chained reports answering
/// `Client.token`. Every consumer program below was built with `swift build` and RUN; its effect printed
/// (the R844 lane's scratch, `fx/a1`, `fx/a3`, `fx/r846x`, `fx/r847b`).
///
/// - R844: the property / `deinit` / stringification join kept `hits.count == 1` and DROPPED the read.
/// - R845: the `typeSurface` factory join refused two answering packages and read `Unknown`.
/// - R846: the ⟨0.25⟩ union (R842) must not fire where the SOURCE names the module (`RatesCore.Client`).
/// - R847: a bare name — a local binding read as a global, or a function reference — was joined against
///   `pkg#<leaf>`, which the index mints for every METHOD, and charged an unrelated member's effects.
final class AmbiguousChainKeyProcessTests: XCTestCase {

    struct Row { let inferred: Set<String> }

    /// deps/<dir> scanned standalone, then `app` chained on every dep report. Rows by fn name.
    func run(_ files: [String: String], env: [String: String] = [:], label: String) throws -> [String: Row] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r844-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let depR = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depR, withIntermediateDirectories: true)
        for d in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("deps").path).sorted() {
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent("deps/\(d)").path,
                                                 "--out", depR.appendingPathComponent(d).path], env: env)
            XCTAssertEqual(r.code, 0, "dep \(d): \(r.err)")
        }
        for f in try FileManager.default.contentsOfDirectory(atPath: depR.path)
        where f.hasSuffix(".callgraph.json") || f.hasSuffix(".hierarchy.json") {
            try FileManager.default.removeItem(at: depR.appendingPathComponent(f))
        }
        var e = env; e["CANDOR_DEPS"] = depR.path
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out",
                                             root.appendingPathComponent("ch").path], env: e)
        XCTAssertEqual(r.code, 0, "app: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = Row(inferred: Set((f["inferred"] as? [String]) ?? []))
        }
        return rows
    }

    static func pkg(_ name: String, _ products: String, deps: String = "", targetDeps: String = "") -> String {
        """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(name)", products: [\(products)],
            dependencies: [\(deps)], targets: [\(targetDeps)])
        """
    }

    static let ratesClient = """
    import Foundation
    public final class Client: CustomStringConvertible {
        public init() {}
        public var token: String { ProcessInfo.processInfo.environment["Y"] ?? "" }
        public func fetch() -> String { ProcessInfo.processInfo.environment["Y"] ?? "" }
        public var description: String { ProcessInfo.processInfo.environment["Y"] ?? "" }
        deinit { print("ENV_DEINIT", ProcessInfo.processInfo.environment["Y"] ?? "") }
    }
    public func makeClient() -> Client { Client() }
    """
    static let otherClient = """
    import Foundation
    import RatesCore
    public final class Client: CustomStringConvertible {
        public init() {}
        public var token: String { (try? String(contentsOfFile: "/etc/hosts")) ?? "" }
        public func fetch() -> String { (try? String(contentsOfFile: "/etc/hosts")) ?? "" }
        public var description: String { (try? String(contentsOfFile: "/etc/hosts")) ?? "" }
        deinit { print("FS_DEINIT", ((try? String(contentsOfFile: "/etc/hosts")) ?? "").count) }
    }
    public final class Gadget { public init() {}; public func fetch() -> String { (try? String(contentsOfFile: "/etc/hosts")) ?? "" } }
    public func makeClient(_ n: Int) -> Gadget { Gadget() }
    extension RatesCore.Client { public func extra() -> String { (try? String(contentsOfFile: "/etc/hosts")) ?? "" } }
    """

    func twoClients(_ app: String) -> [String: String] {
        [
            "deps/RatesCore/Package.swift": Self.pkg("RatesCore", #".library(name: "RatesCore", targets: ["RatesCore"])"#,
                                                    targetDeps: #".target(name: "RatesCore")"#),
            "deps/RatesCore/Sources/RatesCore/C.swift": Self.ratesClient,
            // `other-kit` ≠ `OtherKit`: the shape v0.39.2 left unchained and R565 chains.
            "deps/other-kit/Package.swift": Self.pkg("other-kit", #".library(name: "OtherKit", targets: ["OtherKit"])"#,
                                                    deps: #".package(path: "../RatesCore")"#,
                                                    targetDeps: #".target(name: "OtherKit", dependencies: [.product(name: "RatesCore", package: "RatesCore")])"#),
            "deps/other-kit/Sources/OtherKit/C.swift": Self.otherClient,
            "app/Package.swift": Self.pkg("App", #".library(name: "App", targets: ["App"])"#,
                                          deps: #".package(path: "../deps/RatesCore"), .package(path: "../deps/other-kit")"#,
                                          targetDeps: #".target(name: "App", dependencies: [.product(name: "RatesCore", package: "RatesCore"), .product(name: "OtherKit", package: "other-kit")])"#),
            "app/Sources/App/app.swift": app,
        ]
    }

    static let a1App = """
    import RatesCore
    import OtherKit
    func propTok(c: RatesCore.Client) -> String { c.token }
    func methTok(c: RatesCore.Client) -> String { c.fetch() }
    func strTok(c: RatesCore.Client) -> String { "\\(c)" }
    func ctorDrop() { _ = RatesCore.Client() }
    func inferredLocal() -> String { let c = RatesCore.Client(); return c.fetch() }
    func extraTok(c: RatesCore.Client) -> String { c.extra() }
    func otherTok(c: OtherKit.Client) -> String { c.token }
    """

    /// R844 + R846 — every spelling reads the `Client` the source names; a member another package adds by
    /// extension is still reached; nothing drops.
    func testTwoPackagesDeclaringOneTypeNameJoinTheOneTheSourceNames() throws {
        let r = try run(twoClients(Self.a1App), label: "a1")
        // R849 — every one also DISCLOSES: OtherKit answers the same key, and the report cannot say whether that
        // entry is OtherKit's own `Client` or an `extension RatesCore.Client` overload the call may reach.
        for fn in ["propTok", "strTok", "ctorDrop", "methTok", "inferredLocal"] {
            XCTAssertEqual(r[fn]?.inferred, ["Env", "Unknown"],
                           "\(fn): RatesCore's Client reads the environment and nothing else — ABSENT is R844 "
                           + "(0/0 against v0.39.2), `Fs` is R846 (the union over a module the source named); "
                           + "got \(String(describing: r[fn]))")
        }
        XCTAssertEqual(r["extraTok"]?.inferred, ["Fs"],
                       "a member ANOTHER package adds to `RatesCore.Client` by extension lives in that package: "
                       + "preferring the named module must fall back, or this is silent")
        XCTAssertEqual(r["otherTok"]?.inferred, ["Fs", "Unknown"],
                       "`OtherKit.Client.token` reads a file; v0.39.2 charged RatesCore's `Env` here (only one "
                       + "package was chained) — a fabrication, removed")
    }

    func testTheUnionAndTheModulePreferenceCanFail() throws {
        let off = try run(twoClients(Self.a1App), env: ["CANDOR_JOIN_UNION_OFF": "1", "CANDOR_R846_OFF": "1"],
                          label: "a1-union-off")
        XCTAssertNil(off["propTok"], "§1b: the drop restored (and no module preference to answer first) — R844's absence")
        let noPref = try run(twoClients(Self.a1App), env: ["CANDOR_R846_OFF": "1"], label: "a1-846-off")
        XCTAssertTrue(noPref["methTok"]?.inferred.contains("Fs") ?? false, "§1b: without R846 the union fabricates")
    }

    /// R845 — two chained packages answering a factory: union, not a hedge. `makeClient()` (no argument)
    /// is RatesCore's, so OtherKit's `Gadget.fetch` `Fs` is the stated over-charge of the union.
    func testTwoPackagesAnsweringAFactoryAreUnioned() throws {
        let app = """
        import RatesCore
        import OtherKit
        func factoryBound() -> String { let c = makeClient(); return c.fetch() }
        func factoryDirect() -> String { makeClient().fetch() }
        """
        let r = try run(twoClients(app), label: "a3")
        for fn in ["factoryBound", "factoryDirect"] {
            XCTAssertTrue(r[fn]?.inferred.contains("Env") ?? false,
                          "\(fn): v0.39.2 charged Env; a refusal read `Unknown` (`deny Env` 1 -> 0); got \(String(describing: r[fn]))")
        }
        let off = try run(twoClients(app), env: ["CANDOR_JOIN_UNION_OFF": "1"], label: "a3-off")
        XCTAssertEqual(off["factoryDirect"]?.inferred, ["Unknown"], "§1b")
    }

    /// R847 — a bare name is a dependency declaration only if it is a FREE one, or an implicit-`self`
    /// member of the enclosing type's chain. Local bindings and function references to them no longer
    /// reach an unrelated method sharing the leaf; the four genuine spellings still join.
    func testABareNameReachesOnlyWhatSwiftNameLookupCouldReach() throws {
        let dep = """
        import Foundation
        @inline(never) func envRead(_ t: String) -> String { ProcessInfo.processInfo.environment["Y"] ?? t }
        public struct Stream { public struct Iterator { public init() {}; public mutating func next() -> Int? { _ = envRead("N"); return nil } } }
        public final class Client { public init() {}; public var token: String { envRead("T") } }
        extension Client { public func tokenLen(_ s: String) -> Int { envRead("L").count + s.count } }
        open class Base { public init() {}; public var baseTok: String { envRead("B") } }
        public var gTok: String { envRead("G") }
        """
        let app = """
        import RatesCore
        func argRef(_ xs: [Int]) -> [String] { var it = xs.makeIterator(); var out = [String](); while let next = it.next() { out.append(String(next)) }; return out }
        func baseRead(_ xs: [String]) -> Int { var it = xs.makeIterator(); var n = 0; while let next = it.next() { n += next.count }; return n }
        extension Client { func viaSelfProp() -> String { token } }
        func tSelfProp() -> String { Client().viaSelfProp() }
        final class Sub: Base { func inherited() -> String { baseTok } }
        func tInherited() -> String { Sub().inherited() }
        extension Client { func refLen() -> [Int] { ["a"].map(tokenLen) } }
        func tRefLen() -> [Int] { Client().refLen() }
        func depGlobal() -> String { gTok }
        func realNext() -> Int? { var i = Stream.Iterator(); return i.next() }
        """
        let files = [
            "deps/RatesCore/Package.swift": Self.pkg("RatesCore", #".library(name: "RatesCore", targets: ["RatesCore"])"#,
                                                    targetDeps: #".target(name: "RatesCore")"#),
            "deps/RatesCore/Sources/RatesCore/lib.swift": dep,
            "app/Package.swift": Self.pkg("App", #".library(name: "App", targets: ["App"])"#,
                                          deps: #".package(path: "../deps/RatesCore")"#,
                                          targetDeps: #".target(name: "App", dependencies: [.product(name: "RatesCore", package: "RatesCore")])"#),
            "app/Sources/App/app.swift": app,
        ]
        let r = try run(files, label: "r847")
        XCTAssertFalse(r["argRef"]?.inferred.contains("Env") ?? false,
                       "`String(next)` passes a LOCAL; `Stream.Iterator.next` is not what it names; got \(String(describing: r["argRef"]))")
        XCTAssertNil(r["baseRead"], "`next.count` reads a LOCAL; executed, it reads no environment")
        for fn in ["tSelfProp", "tInherited", "tRefLen", "depGlobal", "realNext"] {
            XCTAssertEqual(r[fn]?.inferred, ["Env"], "\(fn): a genuine reach must survive; got \(String(describing: r[fn]))")
        }
        let off = try run(files, env: ["CANDOR_R847_OFF": "1"], label: "r847-off")
        XCTAssertTrue(off["baseRead"]?.inferred.contains("Env") ?? false, "§1b: the leaf join restored fabricates")
    }

    /// SOUNDNESS R848 — the implicit-`self` walk sees only the CONSUMER's supertype edges; the dependency's own
    /// (`Mid: Grand`, `PSub: PBase`) are in no report. Where the walk cannot PROVE the bare name is not the
    /// dependency's, v0.39.2's `pkg#<leaf>` join is the floor. EXECUTED (the fourth review's `p4a`/`p4b`/`p4d`).
    func testAMemberOneHopUpInsideTheDependencyIsStillReached() throws {
        let dep = """
        import Foundation
        @inline(never) func envRead(_ t: String) -> String { ProcessInfo.processInfo.environment["Y"] ?? t }
        open class Grand { public init() {}; public var grandTok: String { envRead("G") }
            public func grandFn(_ s: String) -> Int { envRead("F").count } }
        open class Mid: Grand {}
        public protocol PBase {}
        extension PBase { public var pTok: String { envRead("P") }; public func pFn(_ s: String) -> Int { envRead("Q").count } }
        public protocol PSub: PBase {}
        """
        let app = """
        import RatesCore
        final class Sub3: Mid { func viaGrand() -> String { grandTok }; func refGrand() -> [Int] { ["a"].map(grandFn) } }
        struct S: PSub { func viaPSub() -> String { pTok }; func refPSub() -> [Int] { ["a"].map(pFn) } }
        protocol LocalP: PBase {}
        struct SC: LocalP { func viaLocalP() -> String { pTok } }
        extension Mid { func extReadInherited() -> String { grandTok } }
        """
        let files = [
            "deps/RatesCore/Package.swift": Self.pkg("RatesCore", #".library(name: "RatesCore", targets: ["RatesCore"])"#,
                                                    targetDeps: #".target(name: "RatesCore")"#),
            "deps/RatesCore/Sources/RatesCore/lib.swift": dep,
            "app/Package.swift": Self.pkg("App", #".library(name: "App", targets: ["App"])"#,
                                          deps: #".package(path: "../deps/RatesCore")"#,
                                          targetDeps: #".target(name: "App", dependencies: [.product(name: "RatesCore", package: "RatesCore")])"#),
            "app/Sources/App/app.swift": app,
        ]
        let r = try run(files, label: "r848")
        for fn in ["Sub3.viaGrand", "Sub3.refGrand", "S.viaPSub", "S.refPSub", "SC.viaLocalP", "Mid.extReadInherited"] {
            XCTAssertTrue(r[fn]?.inferred.contains("Env") ?? false,
                          "\(fn): 1 on v0.39.2, ABSENT at 4814c39 (R848); got \(String(describing: r[fn]))")
        }
        let off = try run(files, env: ["CANDOR_R848_OFF": "1"], label: "r848-off")
        XCTAssertNil(off["Sub3.viaGrand"], "§1b: without the floor the grandparent's member is lost")
    }

    /// SOUNDNESS R849 — ThirdKit's `extension RatesCore.Client { func fetch(_:) }` beside RatesCore's own
    /// `fetch()`: the named module answers, and the other package's same key is DISCLOSED, not dropped
    /// (EXECUTED `FS_READ`; `deny Fs` 0 on v0.39.2 and at 4814c39).
    func testAnotherPackagesAnswerBesideTheNamedModuleIsDisclosed() throws {
        let files = [
            "deps/RatesCore/Package.swift": Self.pkg("RatesCore", #".library(name: "RatesCore", targets: ["RatesCore"])"#,
                                                    targetDeps: #".target(name: "RatesCore")"#),
            "deps/RatesCore/Sources/RatesCore/lib.swift": """
            import Foundation
            public final class Client { public init() {}
              public func fetch() -> String { ProcessInfo.processInfo.environment["Y"] ?? "" } }
            """,
            "deps/ThirdKit/Package.swift": Self.pkg("ThirdKit", #".library(name: "ThirdKit", targets: ["ThirdKit"])"#,
                                                   deps: #".package(path: "../RatesCore")"#,
                                                   targetDeps: #".target(name: "ThirdKit", dependencies: [.product(name: "RatesCore", package: "RatesCore")])"#),
            "deps/ThirdKit/Sources/ThirdKit/lib.swift": """
            import Foundation
            import RatesCore
            extension RatesCore.Client {
              public func fetch(_ path: String) -> Int { (try? String(contentsOfFile: path))?.count ?? -1 } }
            """,
            "app/Package.swift": Self.pkg("App", #".library(name: "App", targets: ["App"])"#,
                                          deps: #".package(path: "../deps/RatesCore"), .package(path: "../deps/ThirdKit")"#,
                                          targetDeps: #".target(name: "App", dependencies: [.product(name: "RatesCore", package: "RatesCore"), .product(name: "ThirdKit", package: "ThirdKit")])"#),
            "app/Sources/App/app.swift": """
            import RatesCore
            import ThirdKit
            func annot(_ c: RatesCore.Client) -> Int { c.fetch("/etc/hosts") }
            """,
        ]
        let r = try run(files, label: "r849")
        XCTAssertTrue(r["annot"]?.inferred.contains("Unknown") ?? false,
                      "the other package's `Client.fetch` must be disclosed, not dropped; got \(String(describing: r["annot"]))")
        let off = try run(files, env: ["CANDOR_R849_OFF": "1"], label: "r849-off")
        XCTAssertFalse(off["annot"]?.inferred.contains("Unknown") ?? true, "§1b")
    }
}
