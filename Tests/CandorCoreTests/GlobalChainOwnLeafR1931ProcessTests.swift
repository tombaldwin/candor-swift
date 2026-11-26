import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1931 — two halves of R1455's own-leaf C12 residue (a call on a receiver no stage-1 rule typed, whose leaf only THIS
/// package declares), every cell EXECUTED first under swiftc (each function either creates the marker file or does not), read
/// standalone AND chained to a real producer report (the join is live: `G.g_live` charges `Fs` only chained).
///   resolution  a module-scope global initialised by a MEMBER-CALL CHAIN (`let gLib = loader.open("x")`, `Lib.make()`,
///               `Loader().open("y")`, `Builder().opt(1).opt(2).build()`) is typed hop by hop from the receiver's own declared return,
///               so the call on it binds the real member. A hop answered only by a protocol extension, an uppercase FREE function head,
///               and a private name two files declare with different types stay untyped (and hedged, below).
///   hedge       an untyped receiver whose leaf this package declares discloses `Unknown {dispatch:<untyped>.<m>}` when some same-named
///               member has an effect (decided after the graph); a leaf whose every declaration is pure costs nothing (pure twins).
/// Main read the resolved cells `-+U` standalone and ABSENT chained (the dependency also declares `wipeLib`, so the source arm hedged
/// standalone, and the chained report, which publishes no body for the pure `wipeLib`, withdrew it), and the hedge cells ABSENT on both.
final class GlobalChainOwnLeafR1931ProcessTests: XCTestCase {

    private static let dep = #"""
import Foundation
public final class Lib { public init() {}
    public func wipeLib(_ p: String) -> Int { p.count } }        // a dependency type sharing App's `Lib` name: PURE
public func depWrite(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
"""#
    private static let globals = #"""
import Foundation
import Guess
public final class Lib { public init() {}
    public func wipeLib(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
    public static func make() -> Lib { Lib() } }
public final class Loader { public init() {}
    public func open(_ n: String) -> Lib { Lib() }
    public func calmOpen(_ n: String) -> CalmLib { CalmLib() } }
public final class CalmLib { public init() {}
    public func hushLib(_ p: String) -> Int { p.count } }
public final class Builder { public init() {}
    public func opt(_ i: Int) -> Self { self }
    public func build() -> Lib { Lib() } }
public protocol Opener {}
extension Opener { public func viaExt() -> Lib { Lib() } }
public final class ExtOpener: Opener { public init() {} }
public func Mk() -> Lib { Lib() }
public final class GenLoader<T> { public init() {}
    public func open() -> Lib { Lib() }
    public func echo(_ t: T) -> T { t } }
let gGen = GenLoader<Int>().open()             // generic-specialised constructor head: refused
let gEcho = GenLoader<Lib>().echo(Lib())       // a hop returning the type's generic parameter: refused
let loader = Loader()
let gLib = loader.open("x")                    // head global, one hop
let gStatic = Lib.make()                       // static factory on a local type
let gCtor = Loader().open("y")                 // constructor head
let gSelf = Builder().opt(1).opt(2).build()    // `-> Self` hops then a typed hop
let gCalm = loader.calmOpen("z")               // pure twin
let gExt = ExtOpener().viaExt()                // hop declared in a protocol extension: not answered
let gMk = Mk().open2()                         // uppercase FREE FUNCTION head: not a constructor
extension Lib { public func open2() -> Lib { self } }
private let gPriv = loader.open("p")           // declared in two files with DIFFERENT types (see other.swift)
public struct G {
    public init() {}
    public func g_lib(_ p: String) { gLib.wipeLib(p) }
    public func g_static(_ p: String) { gStatic.wipeLib(p) }
    public func g_ctor(_ p: String) { gCtor.wipeLib(p) }
    public func g_self(_ p: String) { gSelf.wipeLib(p) }
    public func g_calm(_ p: String) -> Int { gCalm.hushLib(p) }
    public func g_ext(_ p: String) { gExt.wipeLib(p) }
    public func g_mk(_ p: String) { gMk.wipeLib(p) }
    public func g_priv(_ p: String) { gPriv.wipeLib(p) }
    public func g_shadow(_ p: String) -> Int { let gLib = CalmLib(); return gLib.hushLib(p) }
    public func g_shadow_param(_ gLib: CalmLib, _ p: String) -> Int { gLib.hushLib(p) }
    public func g_gen(_ p: String) { gGen.wipeLib(p) }
    public func g_echo(_ p: String) { gEcho.wipeLib(p) }
    public func g_live(_ p: String) { depWrite(p) }   // the chained-join liveness control (Guess's write)
}
"""#
    private static let other = #"""
import Foundation
private let gPriv = loader.calmOpen("q")       // same name, other type: the module-wide name must stay untyped
public struct G2 { public init() {}
    public func g_priv2(_ p: String) -> Int { gPriv.hushLib(p) } }
"""#
    private static let noimport = #"""
// no `import Guess` here: App's own `Lib` is the only one in scope, and the global is App's
public struct G3 { public init() {}
    public func g_noimport(_ p: String) { gLib.wipeLib(p) } }
"""#
    private static let residue = #"""
import Foundation
public final class Vault { public init() {}
    public func wipeVault(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class Calm { public init() {}
    public func hushCalm(_ p: String) -> Int { p.count } }
public final class Relay { public init() {}
    public func relayVault(_ v: Vault, _ p: String) { v.wipeVault(p) } }     // effect two hops away
public enum Slot { case v(Vault), c(Calm) }
public struct R {
    public init() {}
    public func r_lifetime(_ p: String) { withExtendedLifetime(Vault()) { $0.wipeVault(p) } }
    public func r_lifetime_pure(_ p: String) -> Int { withExtendedLifetime(Calm()) { $0.hushCalm(p) } }
    public func r_unmanaged(_ p: String) { let u = Unmanaged.passRetained(Vault()); let v = u.takeRetainedValue(); v.wipeVault(p) }
    public func r_unmanaged_pure(_ p: String) -> Int { let u = Unmanaged.passRetained(Calm()); let v = u.takeRetainedValue(); return v.hushCalm(p) }
    public func r_closure_local(_ p: String) { let mk = { Vault() }; mk().wipeVault(p) }
    public func r_closure_local_pure(_ p: String) -> Int { let mk = { Calm() }; return mk().hushCalm(p) }
    public func r_generic<T>(_ t: T, _ f: (T) -> Vault, _ p: String) { let v = f(t); v.wipeVault(p) }
    public func r_generic_pure<T>(_ t: T, _ f: (T) -> Calm, _ p: String) -> Int { let c = f(t); return c.hushCalm(p) }
    public func r_twohop(_ p: String) { withExtendedLifetime(Relay()) { $0.relayVault(Vault(), p) } }
    public func r_mapped(_ p: String) { [1].map { _ in Vault() }.forEach { $0.wipeVault(p) } }
    public func r_mapped_pure(_ p: String) -> Int { [1].map { _ in Calm() }.map { $0.hushCalm(p) }.reduce(0, +) }
}
"""#

    private struct Fixture { let root: URL; let bin: URL
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") } }

    private func make() throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1931-\(UUID().uuidString)")
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
        try write("app/Sources/App/globals.swift", Self.globals)
        try write("app/Sources/App/other.swift", Self.other)
        try write("app/Sources/App/noimport.swift", Self.noimport)
        try write("app/Sources/App/residue.swift", Self.residue)
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

    private struct Row { var effects: Set<String>; var why: Set<String> }

    private func rows(_ fx: Fixture, chained: Bool, env extra: [String: String] = [:]) throws -> [String: Row] {
        var env = extra
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let tag = "o-\(UUID().uuidString)"
        let r = try ProcessHarness.run(fx.bin, [fx.appDir.path, "--out", fx.root.appendingPathComponent(tag).path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: fx.root.appendingPathComponent("\(tag).App.Swift.json"))) as? [String: Any]
        var out: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            let fn = ((f["fn"] as? String) ?? "?").split(separator: "(").first.map(String.init) ?? "?"
            out[fn] = Row(effects: Set((f["inferred"] as? [String]) ?? []), why: Set((f["unknownWhy"] as? [String]) ?? []))
        }
        return out
    }

    func testMemberChainGlobalIsTypedAndOwnLeafResidueDiscloses() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        // EXECUTED WRITES, resolved: charged `Fs` in both arms
        let resolved = ["G.g_lib", "G.g_static", "G.g_ctor", "G.g_self", "G3.g_noimport"]
        // EXECUTED WRITES, not typed (protocol-extension hop, uppercase free-function head, private name with two types): hedged
        let hedged: [(String, String)] = [("G.g_ext", "wipeLib"), ("G.g_mk", "wipeLib"), ("G.g_priv", "wipeLib"),
                                          ("G.g_gen", "wipeLib"), ("G.g_echo", "wipeLib"),
                                          ("R.r_lifetime", "wipeVault"), ("R.r_unmanaged", "wipeVault"), ("R.r_mapped", "wipeVault"),
                                          ("R.r_twohop", "relayVault")]
        // EXECUTED pure twins (unique leaves whose every declaration is pure): no charge, no hedge
        let pure = ["G.g_calm", "G2.g_priv2", "G.g_shadow", "G.g_shadow_param", "R.r_lifetime_pure", "R.r_unmanaged_pure", "R.r_mapped_pure"]
        for chained in [true, false] {
            let r = try rows(fx, chained: chained)
            for c in resolved {
                XCTAssertTrue(r[c]?.effects.contains("Fs") ?? false, "chained=\(chained) \(c): the global's member writes a file — rows: \(r)")
            }
            for (c, leaf) in hedged {
                XCTAssertTrue(r[c]?.why.contains("dispatch:<untyped>.\(leaf)") ?? false, "chained=\(chained) \(c): must disclose — rows: \(r)")
            }
            for c in pure {
                XCTAssertNil(r[c], "chained=\(chained) \(c): a pure twin must read pure — rows: \(r)")
            }
            XCTAssertEqual(r["G.g_live"]?.effects.contains("Fs") ?? false, chained, "the chained join must be live")
        }
        // the resolution's switch restores the untyped global, so the assertion above can fail
        let off = try rows(fx, chained: true, env: ["CANDOR_R1931_GLOBAL_OFF": "1"])
        XCTAssertFalse(off["G.g_lib"]?.effects.contains("Fs") ?? false, "CANDOR_R1931_GLOBAL_OFF must restore the untyped global")
    }
}
