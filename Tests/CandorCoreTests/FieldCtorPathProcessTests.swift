import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1896 — an UNANNOTATED stored property initialised by a PATH-QUALIFIED constructor (`var f = Guess.DepStore()`,
/// `var n = Outer.Inner()`, `var o = App.OwnStore()`) is typed, so an implicit-self `f.m()` / `self.f.m()` binds the real member
/// instead of being R1455's dropped member call (no edge, no `Unknown`). Every cell below was EXECUTED first (the fixture ran under
/// swiftc: each function either creates the marker file or does not), and the scan is read standalone and chained to a REAL
/// producer report (the join is live: the chained arm charges `Fs` on the dependency-typed cells).
///   resolved   a type this scan declares (nested path; own-module-qualified) or a two-segment `Dep.Type()` of an imported module
///   unchanged  `Dep.Kind.Node(1)` (an enum case), `Dep.NS.Make()` (a static factory), `Dep.makeStore()`, `Dep.Gen<Int>()` stay
///              dropped, so the C12 hedge keeps its say — typing a field from one would replace that hedge with a receiver that
///              binds nothing (the first draft of this change did exactly that, chained: executed WRITES, row `-`)
final class FieldCtorPathProcessTests: XCTestCase {

    private static let dep = #"""
import Foundation
public final class DepStore { public init() {}
    public func wipeDep(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class DepPure { public init() {}
    public func calmDep(_ p: String) -> Int { p.count } }
public final class DepGen<T> { public init() {}
    public func wipeGen(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public func makeStore() -> DepStore { DepStore() }
open class DepBase { public init() {}
    public var inhDep = DepStore() }
public enum DepKind { case Node(Int)
    public func wipeKindDep(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public enum DepNS { public static func Make() -> DepStore { DepStore() } }
public final class Teller { public init() {}
    public func settleUp(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public func Maker() -> DepStore { DepStore() }
"""#

    private static let app = #"""
import Foundation
import Guess
public final class OwnStore { public init() {}
    public func wipeOwn(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class OwnPure { public init() {}
    public func calmOwn(_ p: String) -> Int { p.count } }
public enum Outer { public final class Inner { public init() {}
    public func wipeNest(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } } }
public enum Kind { case Node(Int)
    public func wipeKind(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class Teller { public init() {}
    public func settleUp(_ p: String) -> Int { p.count } }
public struct Msg {
    public var tc = Guess.Teller()
    public var mkr = Guess.Maker()
    public var fDep = Guess.DepStore()
    public let lDep = Guess.DepStore()
    public var pDep = Guess.DepPure()
    public var fOwn = App.OwnStore()
    public var pOwn = App.OwnPure()
    public var nest = Outer.Inner()
    public var viaInit = Guess.DepStore.init()
    public var gen = Guess.DepGen<Int>()
    public var opt: Guess.DepStore? = Guess.DepStore()
    public var comp: Guess.DepStore { Guess.DepStore() }
    public var fac = Guess.makeStore()
    public var kd = Kind.Node(1)
    public var dk = Guess.DepKind.Node(1)
    public var mk = Guess.DepNS.Make()
    public var iuoOwn: OwnStore!
    public var iuoPure: OwnPure!
    public init() { iuoOwn = OwnStore(); iuoPure = OwnPure() }
    public func s_iuo(_ p: String) { iuoOwn.wipeOwn(p) }
    public func s_iuo_self(_ p: String) { self.iuoOwn.wipeOwn(p) }
    public func s_iuo_pure(_ p: String) -> Int { iuoPure.calmOwn(p) }
    public func s_b1(_ p: String) { tc.settleUp(p) }
    public func s_b2(_ p: String) { mkr.wipeDep(p) }
    public func s_dkind(_ p: String) { dk.wipeKindDep(p) }
    public func s_mk(_ p: String) { mk.wipeDep(p) }
    public func s_bare(_ p: String) { fDep.wipeDep(p) }
    public func s_self(_ p: String) { self.fDep.wipeDep(p) }
    public func s_let(_ p: String) { lDep.wipeDep(p) }
    public func s_pure(_ p: String) -> Int { pDep.calmDep(p) }
    public func s_own(_ p: String) { fOwn.wipeOwn(p) }
    public func s_ownpure(_ p: String) -> Int { pOwn.calmOwn(p) }
    public func s_nest(_ p: String) { nest.wipeNest(p) }
    public func s_init(_ p: String) { viaInit.wipeDep(p) }
    public func s_gen(_ p: String) { gen.wipeGen(p) }
    public func s_opt(_ p: String) { opt?.wipeDep(p) }
    public func s_comp(_ p: String) { comp.wipeDep(p) }
    public func s_fac(_ p: String) { fac.wipeDep(p) }
    public func s_kind(_ p: String) { kd.wipeKind(p) }
    public func s_shadow_local(_ p: String) -> Int { let fDep = Guess.DepPure(); return fDep.calmDep(p) }
    public func s_shadow_param(_ fDep: Guess.DepPure, _ p: String) -> Int { fDep.calmDep(p) }
    public func s_closure(_ p: String) { [1].forEach { _ in fDep.wipeDep(p) } }
}
extension Msg { public func s_ext(_ p: String) { fDep.wipeDep(p) } }
open class Base { public var inh = Guess.DepStore(); public init() {} }
public final class Derived: Base { public func s_inherit(_ p: String) { inh.wipeDep(p) } }
public final class DerivedDep: Guess.DepBase { public func s_inheritdep(_ p: String) { inhDep.wipeDep(p) } }
public struct GenOwner<T> { var g = Guess.DepStore(); public init() {}
    public func s_genowner(_ p: String) { g.wipeDep(p) } }
open class OBase { public var oi = OwnStore(); public var ai: Guess.DepStore = Guess.DepStore(); public var qi = App.OwnStore(); public init() {} }
public final class ODerived: OBase {
    public func s_oinh(_ p: String) { oi.wipeOwn(p) }
    public func s_ainh(_ p: String) { ai.wipeDep(p) }
    public func s_qinh(_ p: String) { qi.wipeOwn(p) }
    public func s_qinh_self(_ p: String) { self.qi.wipeOwn(p) } }
"""#

    private static let ext = #"""
// no `import Guess` here (legal: member visibility crosses files)
extension Msg {
    public func s_b3(_ p: String) { fDep.wipeDep(p) }
    public func s_b3_tc(_ p: String) { tc.settleUp(p) }
}
"""#

    private struct Fixture { let root: URL; let bin: URL
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") } }

    private func make() throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1896-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("Guess/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Guess", products: [.library(name: "Guess", targets: ["Guess"])], targets: [.target(name: "Guess")])
        """)
        try write("Guess/Sources/Guess/lib.swift", Self.dep)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../Guess")],
            targets: [.target(name: "App", dependencies: [.product(name: "Guess", package: "Guess")])])
        """)
        try write("app/Sources/App/app.swift", Self.app)
        try write("app/Sources/App/ext.swift", Self.ext)
        let fx = Fixture(root: root, bin: bin)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("Guess").path, "--out", fx.depDir.appendingPathComponent("rGuess").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        for extra in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path)
            where !(extra.hasSuffix(".Swift.json") && !extra.contains("callgraph") && !extra.contains("hierarchy")) {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(extra))
        }
        return fx
    }

    private struct Row { var effects: Set<String>; var why: Set<String>; var invisible: Set<String> }

    private func rows(_ fx: Fixture, chained: Bool) throws -> [String: Row] {
        var env: [String: String] = [:]
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let tag = "o-\(UUID().uuidString)"
        let r = try ProcessHarness.run(fx.bin, [fx.appDir.path, "--out", fx.root.appendingPathComponent(tag).path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: fx.root.appendingPathComponent("\(tag).App.Swift.json"))) as? [String: Any]
        var out: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            out[(f["fn"] as? String) ?? "?"] = Row(effects: Set((f["inferred"] as? [String]) ?? []),
                                                    why: Set((f["unknownWhy"] as? [String]) ?? []),
                                                    invisible: Set((f["invisible"] as? [String]) ?? []))
        }
        return out
    }

    func testAPathQualifiedConstructorFieldIsTypedOrStaysHedged() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        // EXECUTED WRITES, a type THIS scan declares: charged standalone AND chained
        let own = ["Msg.s_own", "Msg.s_nest", "ODerived.s_qinh", "ODerived.s_qinh_self"]
        // EXECUTED WRITES, `Guess.DepStore()` (a two-segment path of an imported module): chained it binds the dependency's body;
        // standalone the dependency cannot be read, so the typed call is disclosed `invisible`, as the local binder's is
        // SOUNDNESS R1938 (lane L3) — identity recorded at the declaration: `Guess.Teller()` beside the scan's own `Teller` (B1) is the
        // dependency's type, and a use file with no `import Guess` (B3) reads it as its declaring file does. Executed WRITES; under
        // `CANDOR_TYPE_ID_L3_OFF` they read main's C12 hedge again.
        let env = ProcessInfo.processInfo.environment
        let l3 = env["CANDOR_TYPE_ID_L3_OFF"] != "1" && env["CANDOR_TYPE_ID_L2_OFF"] != "1"
        let l3Moved = ["Msg.s_b1", "Msg.s_b3", "Msg.s_b3_tc"]
        var dep = ["Msg.s_bare", "Msg.s_self", "Msg.s_let", "Msg.s_ext", "Msg.s_init", "Msg.s_closure", "GenOwner.s_genowner"]
        // EXECUTED WRITES, field not typed by this change: the C12 hedge must remain, with its own token, in both arms
        var hedged: [(String, String)] = [("Msg.s_dkind", "wipeKindDep"), ("Msg.s_mk", "wipeDep"), ("Msg.s_fac", "wipeDep"),
                                          ("Msg.s_gen", "wipeGen"),
                                          // an `T!` stored field nothing types: hedged on the call (a pure twin is hedged too — the reason is the untyped receiver)
                                          ("Msg.s_iuo", "wipeOwn"), ("Msg.s_iuo_pure", "calmOwn"),
                                          // Fable B1/B2: the scan also declares `Teller`; `Maker` is a free FUNCTION of the dependency (executed WRITES)
                                          ("Msg.s_b1", "settleUp"), ("Msg.s_b2", "wipeDep")]
        // EXECUTED pure twins
        if l3 { dep += l3Moved; hedged.removeAll { l3Moved.contains($0.0) } }
        let pure = ["Msg.s_pure", "Msg.s_ownpure", "Msg.s_shadow_local", "Msg.s_shadow_param", "Msg.s_iuo_pure"]
        for chained in [true, false] {
            let r = try rows(fx, chained: chained)
            for c in own {
                XCTAssertTrue(r[c]?.effects.contains("Fs") ?? false, "chained=\(chained) \(c): the scan's own member writes a file — rows: \(r)")
            }
            for c in dep {
                if chained {
                    XCTAssertTrue(r[c]?.effects.contains("Fs") ?? false, "chained=\(chained) \(c): the dependency's body writes a file — rows: \(r)")
                } else {
                    let disclosed = !(r[c]?.invisible.isEmpty ?? true) || !(r[c]?.why.isEmpty ?? true) || (r[c]?.effects.contains("Fs") ?? false)
                    XCTAssertTrue(disclosed, "standalone \(c): must not read silent — rows: \(r)")
                }
            }
            for (c, leaf) in hedged {
                XCTAssertTrue(r[c]?.why.contains("dispatch:<untyped>.\(leaf)") ?? false, "chained=\(chained) \(c): the C12 hedge must stay — rows: \(r)")
            }
            // B3 (executed WRITES): the call is in a file that does not import `Guess`; main hedged it chained, standalone it is silent on every arm
            if chained, !l3 {
                for (c, leaf) in [("Msg.s_b3", "wipeDep"), ("Msg.s_b3_tc", "settleUp")] {
                    XCTAssertTrue(r[c]?.why.contains("dispatch:<untyped>.\(leaf)") ?? false, "chained \(c): the C12 hedge must stay in a file that does not import the module — rows: \(r)")
                }
            }
            for c in pure {
                XCTAssertFalse(r[c]?.effects.contains("Fs") ?? false, "chained=\(chained) \(c): pure twin must not be charged")
            }
        }
    }
}
