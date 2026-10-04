import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R832 + R859 — two consumer-side silences over a CHAINED dependency, both executed.
///
/// **R832** — a call through a dependency's STATIC factory, `Client.make().fetch()` and its bound
/// spelling, was ABSENT on v0.39.2 and v0.39.3 alike. The producer already published
/// `typeSurface.returns {"RatesCore#Client.make": "RatesCore#Client"}`; the consumer asked `returns` only
/// for a BARE factory (`build().fetch()`), so the static spelling formed no marker and no key at all.
/// A second hop made it worse: a consumer declaring ANY `make()` of its own typed the dependency's factory
/// by that LEAF (`rootOf`'s `returns[member]` arm) and keyed a member of the wrong type — still silent.
///
/// **R859** — `func f(_ t: any PSub) { t.pTok() }` where the dependency declares `protocol PSub: PBase`
/// and `extension PBase { func pTok() }` reads env: `[]`, `deny Env Unknown` 0. The producer keys the body
/// `PBase.pTok`, the wire carries no supertypes (R843), so the consumer's `PSub.pTok` key misses and the
/// miss read as purity. The generic spelling discloses at v0.39.3 (R705); the existential did not, nor did
/// a LOCAL protocol refining the dependency's one (`protocol LSub: PBase`), which dropped the call outright.
///
/// Every consumer function below was built with `swift build` and RUN; each performs the env read its
/// gate asserts (the R832 lane's `fx/` in its scratch). The bar is MONOTONE against v0.39.3: nothing
/// here can turn a gate that exits 1 there into 0 — every arm only adds an entry, a key or a disclosure.
final class StaticFactoryAndInheritedMemberProcessTests: XCTestCase {

    static let depPackage = """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "RatesCore",
        products: [.library(name: "RatesCore", targets: ["RatesCore"])],
        targets: [.target(name: "RatesCore")])
    """
    static let appPackage = """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
        dependencies: [.package(path: "../dep")],
        targets: [.target(name: "App", dependencies: [.product(name: "RatesCore", package: "dep")])])
    """

    static let dep = """
    import Foundation
    public protocol Fetcher { func pfetch() }
    public final class Client: Fetcher {
        public init() {}
        public static func make() -> Client { Client() }
        public static func makeG<T>(_ t: T) -> Client { Client() }
        public static func makeProto() -> any Fetcher { Client() }
        public static func makeOpt() -> Client? { Client() }
        public func fetch() { _ = ProcessInfo.processInfo.environment["Y"] }
        public func pfetch() { _ = ProcessInfo.processInfo.environment["Y"] }
    }
    extension Client { public static func ext() -> Client { Client() } }
    public enum Factory { public static func client() -> Client { Client() } }
    public enum Outer { public final class Inner { public init() {}
        public static func make() -> Inner { Inner() }
        public func fetch() { _ = ProcessInfo.processInfo.environment["Y"] } } }
    public func mkOpt() -> Client? { Client() }
    public protocol PBase {}
    extension PBase { public func pTok() { _ = ProcessInfo.processInfo.environment["Y"] } }
    public protocol PSub: PBase {}
    public protocol PSub2: PSub {}
    public protocol PSubD: PBase {}
    public struct DConf: PSubD { public init() {} }
    public protocol PReqW { func rw() }
    public protocol PQuiet {}
    extension PQuiet { public func qTok() -> Int { 1 } }
    public protocol PQSub: PQuiet {}
    public final class DepClass { public init() {}; public func plain() -> Int { 2 } }
    """

    static let app = """
    import RatesCore
    import Foundation
    final class LocalT { static func make() -> LocalT { LocalT() }
        func run() { _ = ProcessInfo.processInfo.environment["Y"] } }
    func fDirect() { Client.make().fetch() }
    func fBound() { let c = Client.make(); c.fetch() }
    func fGeneric() { Client.makeG(1).fetch() }
    func fExt() { Client.ext().fetch() }
    func fOtherType() { Factory.client().fetch() }
    func fNested() { Outer.Inner.make().fetch() }
    func fQualified() { RatesCore.Client.make().fetch() }
    func fProto() { Client.makeProto().pfetch() }
    func fOpt() { Client.makeOpt()?.fetch() }
    func fIfLet() { if let c = Client.makeOpt() { c.fetch() } }
    func fGuardLet() { guard let c = Client.makeOpt() else { return }; c.fetch() }
    func fFreeIfLet() { if let c = mkOpt() { c.fetch() } }
    func fLocal() { LocalT.make().run() }
    func fPlatform() { let o = LocalT(); _ = Unmanaged.passUnretained(o).toOpaque() }
    struct SConf: PSub {}
    struct SConf2: PSub2 {}
    struct QConf: PQSub {}
    protocol LSub: PBase {}
    struct LConf: LSub {}
    protocol LSub2: PSub {}
    struct LConf2: LSub2 {}
    protocol LW: PReqW {}
    struct LWC: LW { func rw() { _ = ProcessInfo.processInfo.environment["Y"] } }
    func gAny(_ t: any PSub) { t.pTok() }
    func gTwice(_ t: any PSub2) { t.pTok() }
    func gDepConformer(_ t: any PSubD) { t.pTok() }
    func gBare(_ t: PSub) { t.pTok() }
    func gLocalRefine(_ t: any LSub) { t.pTok() }
    func gLocalRefineTwice(_ t: any LSub2) { t.pTok() }
    func gLocalWitness(_ t: any LW) { t.rw() }
    func gQuiet(_ t: PQSub) -> Int { t.qTok() }
    func gDepClass(_ d: DepClass) -> Int { d.plain() }
    func c_fDirect() { fDirect() }
    func c_fBound() { fBound() }
    func c_fProto() { fProto() }
    func c_gAny() { gAny(SConf()) }
    func c_gLocalRefine() { gLocalRefine(LConf()) }
    """

    struct Row { let inferred: Set<String>; let unknownWhy: Set<String> }

    func run(_ policies: [String: String], env: [String: String] = [:], label: String)
        throws -> (rows: [String: Row], gates: [String: Int32]) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r832-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["dep/Package.swift": Self.depPackage, "dep/Sources/RatesCore/lib.swift": Self.dep,
                     "app/Package.swift": Self.appPackage, "app/Sources/App/app.swift": Self.app]
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let deps = root.appendingPathComponent("deps")
        try FileManager.default.createDirectory(at: deps, withIntermediateDirectories: true)
        var r = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path,
                                             "--out", deps.appendingPathComponent("dep").path], env: env)
        XCTAssertEqual(r.code, 0, "dep scan: \(r.err)")
        for f in try FileManager.default.contentsOfDirectory(atPath: deps.path)
        where f.hasSuffix(".callgraph.json") || f.hasSuffix(".hierarchy.json") {
            try FileManager.default.removeItem(at: deps.appendingPathComponent(f))
        }
        var chainEnv = env; chainEnv["CANDOR_DEPS"] = deps.path
        let appDir = root.appendingPathComponent("app").path
        r = try ProcessHarness.run(bin, [appDir, "--out", root.appendingPathComponent("ch").path], env: chainEnv)
        XCTAssertEqual(r.code, 0, "app scan: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = Row(inferred: Set((f["inferred"] as? [String]) ?? []),
                                                    unknownWhy: Set((f["unknownWhy"] as? [String]) ?? []))
        }
        var gates: [String: Int32] = [:]
        for (name, text) in policies {
            let p = root.appendingPathComponent("\(name).policy")
            try text.write(to: p, atomically: true, encoding: .utf8)
            gates[name] = try ProcessHarness.run(bin, [appDir, "--policy", p.path,
                                                       "--out", root.appendingPathComponent("g-\(name)").path],
                                                 env: chainEnv).code
        }
        return (rows, gates)
    }

    static func policies(env fns: [String], envUnknown ufns: [String]) -> [String: String] {
        var p: [String: String] = [:]
        for f in fns { p["env-\(f)"] = "deny Env \(f)\n" }
        for f in ufns { p["envunk-\(f)"] = "deny Env Unknown \(f)\n" }
        return p
    }

    /// R832 — every static-factory spelling whose returned type the dependency PUBLISHES is RESOLVED to
    /// the real effect (`deny Env` 0 -> 1 on the unit and on its caller); a factory returning a type the
    /// producer does not publish (`any Fetcher`, `Client?`) is DISCLOSED (`deny Env Unknown` 0 -> 1).
    ///
    ///     fn            v0.39.2   v0.39.3   here
    ///     fDirect       0/0       0/0       1/1       (deny Env / deny Env Unknown)
    ///     fBound..fQualified  0/0 0/0       1/1       — fBound/fQualified also need the LocalT leaf fix
    ///     fProto,fOpt,fIfLet,fGuardLet,fFreeIfLet   0/0   0/0   0/1
    func testAStaticDependencyFactoryIsAskedAndAnswered() throws {
        let resolved = ["fDirect", "fBound", "fGeneric", "fExt", "fOtherType", "fNested", "fQualified",
                        "c_fDirect", "c_fBound"]
        let disclosed = ["fProto", "fOpt", "fIfLet", "fGuardLet", "fFreeIfLet", "c_fProto"]
        let r = try run(Self.policies(env: resolved, envUnknown: disclosed), label: "r832")
        for fn in resolved {
            XCTAssertEqual(r.gates["env-\(fn)"], 1, "\(fn): `deny Env` over code that reads env; row \(String(describing: r.rows[fn]))")
        }
        for fn in disclosed {
            XCTAssertEqual(r.gates["envunk-\(fn)"], 1, "\(fn): `deny Env Unknown`; row \(String(describing: r.rows[fn]))")
        }
        // controls: the release's answers stand, and a platform static call gains no hedge
        XCTAssertEqual(r.rows["fLocal"]?.inferred, ["Env"], "a LOCAL type's static factory is local resolution's")
        XCTAssertFalse(r.rows["fPlatform"]?.inferred.contains("Unknown") ?? false,
                       "`Unmanaged.passUnretained(o).toOpaque()` — no chained report names `Unmanaged`: no hedge")
    }

    /// R859 — the inherited dependency member through an existential, a bare protocol with a local
    /// conformer, a twice-refined protocol, a dependency conformer, and a LOCAL refinement.
    ///
    ///     fn                 v0.39.2   v0.39.3   here   (deny Env / deny Env Unknown)
    ///     gAny               0/0       0/0       0/1
    ///     gTwice             0/0       0/0       0/1
    ///     gDepConformer      0/0       0/0       0/1
    ///     gBare              0/0       0/0       0/1    (a local conformer is the evidence)
    ///     gLocalRefine       ABSENT    ABSENT    1/1    (resolved: `PBase.pTok` asked by its own key)
    ///     gLocalRefineTwice  ABSENT    ABSENT    0/1
    ///     gLocalWitness      ABSENT    ABSENT    1/1    (the local conformer's witness)
    func testAnInheritedDependencyMemberIsNotAPurityClaim() throws {
        let resolved = ["gLocalRefine", "gLocalWitness", "c_gLocalRefine"]
        let disclosed = ["gAny", "gTwice", "gDepConformer", "gBare", "gLocalRefineTwice", "c_gAny"]
        let r = try run(Self.policies(env: resolved, envUnknown: disclosed), label: "r859")
        for fn in resolved {
            XCTAssertEqual(r.gates["env-\(fn)"], 1, "\(fn): row \(String(describing: r.rows[fn]))")
        }
        for fn in disclosed {
            XCTAssertEqual(r.gates["envunk-\(fn)"], 1, "\(fn): row \(String(describing: r.rows[fn]))")
        }
        XCTAssertTrue(r.rows["gAny"]?.unknownWhy.contains("dispatch:PSub.pTok") ?? false, "R705's own token")
        // precision controls: no body under the leaf anywhere in the chain, so the miss IS a purity claim
        // (both rows exist only for their ⟨0.39⟩ `dispatchesOn` key; `inferred` is what a gate reads)
        XCTAssertEqual(r.rows["gQuiet"]?.inferred ?? [], [], "a PURE inherited member stays pure — no `qTok` body exists to hide")
        XCTAssertEqual(r.rows["gDepClass"]?.inferred ?? [], [], "a concrete dependency class's pure member is not this population")
    }

    /// §1b — each kill switch restores v0.39.3's silence, so the assertions above are shown able to fail.
    func testTheKillSwitchesRestoreTheSilence() throws {
        let p = ["env-fDirect": "deny Env fDirect\n", "envunk-gAny": "deny Env Unknown gAny\n",
                 "env-gLocalRefine": "deny Env gLocalRefine\n"]
        let r832Off = try run(p, env: ["CANDOR_R832_OFF": "1"], label: "r832off")
        XCTAssertEqual(r832Off.gates["env-fDirect"], 0, "CANDOR_R832_OFF=1 is v0.39.3: fDirect silent")
        // ⟨0.40⟩ the R843 walk reaches the same inherited member through the dependency's published
        // `types`, independently of R859's disclosure — so v0.39.3 is BOTH switches off, and R859's alone
        // must still leave gAny gated (by the resolution rather than the hedge).
        let r859Only = try run(p, env: ["CANDOR_R859_OFF": "1"], label: "r859only")
        XCTAssertEqual(r859Only.gates["envunk-gAny"], 1, "CANDOR_R859_OFF=1 alone: the ⟨0.40⟩ walk still answers gAny")
        let r859Off = try run(p, env: ["CANDOR_R859_OFF": "1", "CANDOR_R843_OFF": "1"], label: "r859off")
        XCTAssertEqual(r859Off.gates["envunk-gAny"], 0, "CANDOR_R859_OFF=1 + CANDOR_R843_OFF=1 is v0.39.3: gAny silent")
        XCTAssertEqual(r859Off.gates["env-gLocalRefine"], 0, "CANDOR_R859_OFF=1: the local refinement drops")
        XCTAssertEqual(r859Off.gates["env-fDirect"], 1, "…and leaves R832 alone")
    }
}
