import XCTest
import Foundation

/// ⟨0.40⟩ (SPEC §2 ⟨0.40⟩; SOUNDNESS R843; conformance PART 95) — THE DECLARED-TYPE SURFACE, BOTH HALVES.
///
/// PART 95 pins the rung four-way; these rows pin the swift halves in this repo's own suite, and one of
/// them pins what PART 95 as written CANNOT: the kind-only key read as an empty list. PART 95's
/// `o14_kind_only` holder (`HolderK`) declares no `m2`, so the singleton convention's own lookup MISSES
/// and the release's "untyped cross-package receiver" disclosure supplies the `Unknown` whatever the walk
/// does — measured: a consumer with the `?? []` mutant passes o14 there. Here the holder DOES declare
/// `m2`, so the guess HITS silently and only the walk's miss can disclose; the same mutant fails
/// `testAKindOnlyKeyIsAMissNeverAnEmptyList`.
final class DeclaredTypeSurfaceProcessTests: XCTestCase {

    static let base = """
    public struct Tok { public init() {} }
    """
    static let dep = """
    import Foundation
    import Base
    public final class Other {
        public init() {}
        public func ping() { _ = ProcessInfo.processInfo.environment["HOME"] }
    }
    public final class Wrong {
        public static let shared: Other = Other()
        public init() {}
        public func ping() { _ = FileManager.default.fileExists(atPath: "/tmp") }
    }
    public protocol PBase {}
    extension PBase {
        public func pTok() { _ = ProcessInfo.processInfo.environment["HOME"] }
    }
    extension Tok: PBase {}
    public protocol PA2 {}
    extension PA2 {
        public func m2() { _ = FileManager.default.fileExists(atPath: "/tmp") }
    }
    public protocol PQ2: PA2 {}
    extension PQ2 {
        public func m2() { _ = ProcessInfo.processInfo.environment["HOME"] }
    }
    public protocol PM2: PQ2 {}
    public final class T2: PA2, PM2 { public init() {} }
    public final class HolderK {
        public static let shared: T2 = T2()
        public init() {}
        public func m2() { _ = FileManager.default.fileExists(atPath: "/tmp") }
    }
    extension Equatable {
        public func eqLeak() { _ = ProcessInfo.processInfo.environment["HOME"] }
    }
    public struct EqT: Equatable { public init() {} }
    public struct HashT: Hashable { public init() {} }
    public struct Plain { public init() {}; public func quiet() {} }
    public struct InnerS {
        public init() {}
        public var leakv: Int { _ = ProcessInfo.processInfo.environment["HOME"]; return 1 }
    }
    @dynamicMemberLookup
    public struct DynW {
        public init() {}
        var inner = InnerS()
        public subscript<T>(dynamicMember kp: KeyPath<InnerS, T>) -> T { inner[keyPath: kp] }
    }
    """
    static let app = """
    import Base
    import Dep
    func viaStatic() { Wrong.shared.ping() }
    func callsStatic() { viaStatic() }
    func viaAdds() { Tok().pTok() }
    func viaKindOnly() { HolderK.shared.m2() }
    func viaEq(_ e: EqT) { e.eqLeak() }
    func callsEq() { viaEq(EqT()) }
    func viaHash(_ h: HashT) { h.eqLeak() }
    func viaPlain(_ p: Plain) { p.quiet() }
    func viaDyn(_ w: DynW) { _ = w.leakv }
    func callsDyn() { viaDyn(DynW()) }
    """

    static func pkg(_ name: String, deps: [(String, String)]) -> String {
        let d = deps.map { ".package(path: \"../\($0.1)\")" }.joined(separator: ", ")
        let p = deps.map { ".product(name: \"\($0.0)\", package: \"\($0.1)\")" }.joined(separator: ", ")
        return """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
            dependencies: [\(d)], targets: [.target(name: "\(name)", dependencies: [\(p)])])
        """
    }

    struct Row { let inferred: Set<String>; let unknownWhy: Set<String> }

    /// base -> dep (chained on base) -> app (chained on both). `doctor` rewrites the dependency's report
    /// before the consumer reads it; the consumer's source never moves.
    func run(doctor: (inout [String: Any]) -> Void = { _ in }, env: [String: String] = [:],
             gates: [String: String] = [:], label: String) throws -> (rows: [String: Row], gates: [String: Int32]) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r843-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["base/Package.swift": Self.pkg("Base", deps: []),
                     "base/Sources/Base/b.swift": Self.base,
                     "dep/Package.swift": Self.pkg("Dep", deps: [("Base", "base")]),
                     "dep/Sources/Dep/d.swift": Self.dep,
                     "app/Package.swift": Self.pkg("App", deps: [("Base", "base"), ("Dep", "dep")]),
                     "app/Sources/App/a.swift": Self.app]
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let r = root.appendingPathComponent("r")
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        XCTAssertEqual(try ProcessHarness.run(bin, [root.appendingPathComponent("base").path, "--out",
                                                    r.appendingPathComponent("base").path], env: env).code, 0)
        let baseRep = r.appendingPathComponent("base.Base.Swift.json")
        var depEnv = env; depEnv["CANDOR_DEPS"] = baseRep.path
        XCTAssertEqual(try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path, "--out",
                                                    r.appendingPathComponent("dep").path], env: depEnv).code, 0)
        let depRep = r.appendingPathComponent("dep.Dep.Swift.json")
        var dj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: depRep)) as? [String: Any])
        doctor(&dj)
        try JSONSerialization.data(withJSONObject: dj).write(to: depRep)
        var appEnv = env; appEnv["CANDOR_DEPS"] = "\(baseRep.path) \(depRep.path)"
        let app = root.appendingPathComponent("app").path
        XCTAssertEqual(try ProcessHarness.run(bin, [app, "--out", root.appendingPathComponent("ch").path],
                                              env: appEnv).code, 0)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            guard let fn = f["fn"] as? String else { continue }
            rows[fn] = Row(inferred: Set((f["inferred"] as? [String]) ?? []),
                           unknownWhy: Set((f["unknownWhy"] as? [String]) ?? []))
        }
        var exits: [String: Int32] = [:]
        for (name, text) in gates {
            let p = root.appendingPathComponent("\(name).policy")
            try text.write(to: p, atomically: true, encoding: .utf8)
            exits[name] = try ProcessHarness.run(bin, [app, "--policy", p.path, "--out",
                                                       root.appendingPathComponent("g-\(name)").path],
                                                 env: appEnv).code
        }
        return (rows, exits)
    }

    static func surface(_ d: inout [String: Any]) -> [String: Any] { (d["typeSurface"] as? [String: Any]) ?? [:] }

    /// THE PRODUCER: the four keys, in `resolves`, spelled in the owning package's namespace.
    func testTheProducerPublishesTheFourKeys() throws {
        var seen: [String: Any] = [:]
        _ = try run(doctor: { seen = $0 }, label: "producer")
        let ts = Self.surface(&seen)
        XCTAssertEqual((ts["holds"] as? [String: String])?["Dep#Wrong.shared"], "Dep#Other")
        XCTAssertEqual((ts["adds"] as? [String: [String]])?["Base#Tok"], ["Dep#PBase"],
                       "a conformance added to ANOTHER package's type is keyed in THAT package's namespace")
        let types = try XCTUnwrap(ts["types"] as? [String: [String: Any]])
        XCTAssertEqual(types["Dep#T2"]?["kind"] as? String, "final")
        XCTAssertEqual(Set(types["Dep#T2"]?["supers"] as? [String] ?? []), ["Dep#PA2", "Dep#PM2"])
        XCTAssertEqual(types["Dep#PM2"]?["supers"] as? [String], ["Dep#PQ2"])
        XCTAssertTrue(Set(seen["resolves"] as? [String] ?? []).isSuperset(of: ["holds", "returnsProtocol", "types", "adds"]))
    }

    /// A HIT ADDS AND KEEPS THE GUESS (R831): the declared `Other.ping` (Env) joins beside the convention's
    /// `Wrong.ping` (Fs), on the unit AND its caller — and `CANDOR_R843_OFF=1` is 0.39.3's silence.
    func testAHoldsHitAddsTheDeclaredTargetAndKeepsTheGuess() throws {
        let g = ["unit": "deny Env viaStatic\n", "caller": "deny Env callsStatic\n", "guess": "deny Fs viaStatic\n"]
        let on = try run(gates: g, label: "hit")
        XCTAssertEqual(on.rows["viaStatic"]?.inferred, ["Env", "Fs"], "got \(String(describing: on.rows["viaStatic"]))")
        XCTAssertEqual(on.gates, ["unit": 1, "caller": 1, "guess": 1])
        let off = try run(env: ["CANDOR_R843_OFF": "1"], gates: g, label: "hitoff")
        XCTAssertEqual(off.gates, ["unit": 0, "caller": 0, "guess": 1], "the switch restores 0.39.3")
    }

    /// AN OLDER PRODUCER EARNS A HEDGE, NEVER A CERTIFICATION (PART 95 o1): with the ⟨0.40⟩ keys stripped
    /// the guess is kept AND disclosed.
    func testAnOlderProducerKeepsTheGuessAndHedges() throws {
        let r = try run(doctor: { d in
            var ts = Self.surface(&d)
            for k in ["holds", "types", "adds", "returnsProtocol"] { ts.removeValue(forKey: k) }
            d["typeSurface"] = ts
            d["resolves"] = (d["resolves"] as? [String] ?? []).filter { !["holds", "types", "adds", "returnsProtocol"].contains($0) }
        }, label: "old")
        XCTAssertEqual(r.rows["viaStatic"]?.inferred, ["Fs", "Unknown"], "got \(String(describing: r.rows["viaStatic"]))")
    }

    /// `adds` RESOLVES, AND IS NEVER COMPLETE (PART 95 r8, o10): `Tok().pTok()` runs the dependency's
    /// `PBase.pTok`; withholding the `adds` entry must disclose, never read pure.
    func testAConformanceTheDependencyAddsResolvesAndItsAbsenceDiscloses() throws {
        let on = try run(label: "adds")
        XCTAssertEqual(on.rows["viaAdds"]?.inferred, ["Env"], "got \(String(describing: on.rows["viaAdds"]))")
        let partial = try run(doctor: { d in
            var ts = Self.surface(&d); ts["adds"] = [String: [String]](); d["typeSurface"] = ts
        }, label: "addspartial")
        XCTAssertEqual(partial.rows["viaAdds"]?.inferred, ["Unknown"],
                       "an absent `adds` is not a purity claim; got \(String(describing: partial.rows["viaAdds"]))")
    }

    /// A KIND-ONLY KEY IS A MISS, NEVER AN EMPTY LIST (SPEC §2 ⟨0.40⟩; PART 95 o14, R860's shape). `T2: PA2,
    /// PM2` and `PM2: PQ2`; `PQ2.m2` (Env) is the body that runs. With PM2 cut to its kind, a consumer that
    /// reads the missing `supers` as `[]` settles on PA2's Fs — and because `HolderK` DECLARES `m2`, the
    /// convention's guess HITS silently, so nothing else in this program discloses: the walk's miss is the
    /// only thing that can. The control row is the full key, where the walk answers and nothing is hedged.
    func testAKindOnlyKeyIsAMissNeverAnEmptyList() throws {
        let full = try run(label: "kindfull")
        XCTAssertEqual(full.rows["viaKindOnly"]?.inferred, ["Env", "Fs"],
                       "CONTROL: the complete manifest answers the walk; got \(String(describing: full.rows["viaKindOnly"]))")
        let ko = try run(doctor: { d in
            var ts = Self.surface(&d)
            var types = ts["types"] as? [String: Any] ?? [:]
            types["Dep#PM2"] = ["kind": "protocol"]
            ts["types"] = types; d["typeSurface"] = ts
        }, gates: ["envunk": "deny Env Unknown viaKindOnly\n"], label: "kindonly")
        XCTAssertTrue(ko.rows["viaKindOnly"]?.inferred.contains("Unknown") ?? false,
                      "a kind-only PM2 must end its path as a MISS; got \(String(describing: ko.rows["viaKindOnly"]))")
        XCTAssertEqual(ko.gates["envunk"], 1, "`deny Env Unknown` must fire over the PQ2.m2 that runs")
    }

    /// SOUNDNESS R889 — A PLATFORM PROTOCOL THE DEPENDENCY EXTENDS WITH A MEMBER IS A SUPERTYPE (SPEC §2 ⟨0.40⟩;
    /// PART 95 r17_platform_ext). `e.eqLeak()` with `e: EqT` runs the dependency's `extension Equatable`
    /// default; 0.39.3 and 2a3ddc6 read `[]`. The producer lists `Dep#Equatable` in the supers of every
    /// type that conforms — directly, or through `Hashable`'s refinement — and the walk reaches it. The
    /// control (`Plain`, no conformance, a pure member) gains neither the effect nor a hedge.
    func testAPlatformProtocolTheDependencyExtendsIsASupertype() throws {
        var dep: [String: Any] = [:]
        let g = ["unit": "deny Env viaEq\n", "caller": "deny Env callsEq\n", "refined": "deny Env viaHash\n",
                 "control": "deny Env Unknown viaPlain\n"]
        let r = try run(doctor: { dep = $0 }, gates: g, label: "platext")
        let types = try XCTUnwrap(Self.surface(&dep)["types"] as? [String: [String: Any]])
        XCTAssertEqual(types["Dep#EqT"]?["supers"] as? [String], ["Dep#Equatable"])
        XCTAssertEqual(types["Dep#HashT"]?["supers"] as? [String], ["Dep#Equatable"], "through Hashable: Equatable")
        XCTAssertEqual(types["Dep#Plain"]?["supers"] as? [String], [])
        XCTAssertEqual(r.gates, ["unit": 1, "caller": 1, "refined": 1, "control": 0])
        let off = try run(env: ["CANDOR_R843_OFF": "1"], gates: ["unit": "deny Env viaEq\n"], label: "platextoff")
        XCTAssertEqual(off.gates["unit"], 0, "CANDOR_R843_OFF=1 is 0.39.3's silence")
    }

    /// SOUNDNESS R890 — A `@dynamicMemberLookup` TYPE IS NEVER CLOSED (SPEC §2 ⟨0.40⟩; PART 95 o16_dyn_member).
    /// `w.leakv` forwards through `subscript(dynamicMember:)` to `InnerS.leakv`, which reads the environment;
    /// 0.39.3 and 2a3ddc6 read `[]`. `DynW` is published KIND-ONLY, so the walk's path ends in a structural
    /// miss and the read DISCLOSES — on the unit and on its caller.
    func testADynamicMemberTypeIsNeverClosed() throws {
        var dep: [String: Any] = [:]
        let r = try run(doctor: { dep = $0 },
                        gates: ["unit": "deny Env Unknown viaDyn\n", "caller": "deny Env Unknown callsDyn\n"],
                        label: "dyn")
        let types = try XCTUnwrap(Self.surface(&dep)["types"] as? [String: [String: Any]])
        XCTAssertNotNil(types["Dep#DynW"], "keyed")
        XCTAssertNil(types["Dep#DynW"]?["supers"], "a dynamic-member type carries no `supers`")
        XCTAssertEqual(r.gates, ["unit": 1, "caller": 1])
        XCTAssertTrue(r.rows["viaDyn"]?.inferred.contains("Unknown") ?? false)
    }
}
