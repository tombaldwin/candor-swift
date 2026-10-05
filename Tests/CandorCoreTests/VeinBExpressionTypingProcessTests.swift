import XCTest
import Foundation
@testable import CandorCore

/// VEIN B — LOCAL EXPRESSION TYPING. Each defect cell below is a member call the release dropped with no key
/// and no `Unknown` because the receiver's TYPE was never established (or was established from the wrong
/// binding), so the enclosing function was ABSENT from `functions[]` and `deny <E>` passed over code that
/// performs the effect. Every cell is now RESOLVED from a declared fact, or (R256, R618/R907) DISCLOSED where
/// the declared fact is ambiguous or the root is a guess; nothing the release answered is withdrawn.
///
/// EXECUTED: this exact source, compiled with `swiftc` and run with a driver
/// (`swiftagent-veinB/fx/vb` + `vb.driver.swift`); every defect cell performed its effect (13 markers written,
/// four env reads returned the set value). v0.39.3 (2111a54) and 113e5b4 read every defect cell 0.
///
/// Rows: R256, R578, R579, R589/R906, R615, R618/R907, R619, R738, R851, R904, R912, R905 (the
/// generic-constructor half). R866 is chained-only and pinned in its own test below.
final class VeinBExpressionTypingProcessTests: XCTestCase {
    static let source = #"""
import Foundation
func mark(_ p: String) { _ = FileManager.default.createFile(atPath: "/tmp/vb_" + p, contents: nil) }
func envOf(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
// ── R256: two same-type requirements on ONE generic parameter
public protocol Wiper256 { func wipe() }
public struct RW256: Wiper256 { public init() {}; public func wipe() { mark("r256n") } }
public struct Gen256<F> { public var f: F; public init(f: F) { self.f = f } }
extension Gen256 where F == (Int) -> Bool { public func fnInvoke() -> Bool { f(1) } }
extension Gen256 where F == Wiper256 { public func nomInvoke() { f.wipe() } }
// ── R578: a requirement read through implicit / explicit self / a local, inside `extension P`
public protocol Body578 { func go() }
public struct NetBody578: Body578 { public init() {}; public func go() { mark("r578") } }
public protocol PA578 { var body: Body578 { get } }
extension PA578 {
  public func paImplicit() { body.go() }
  public func paExplicit() { self.body.go() }
  public func paLocal() { let t = body; t.go() }
}
public struct ImplA578: PA578 { public init() {}; public var body: Body578 { NetBody578() } }
public struct Conc578 { public init() {}; public func go() { mark("r578c") } }
public protocol PB578 { var conc: Conc578 { get } }
extension PB578 {
  public func pbImplicit() { conc.go() }
  public func pbExplicit() { self.conc.go() }
}
public struct ImplB578: PB578 { public init() {}; public var conc: Conc578 { Conc578() } }
// ── R904 / R912: an implicit-self property read used as the BASE of a member access
public protocol Ctx904 { var env904: [String: String] { get } }
extension Ctx904 {
  public func ctxImplicit() -> Int { env904.count }
  public func ctxExplicit() -> Int { self.env904.count }
}
public final class MainCtx904: Ctx904 { public init() {}; public lazy var env904 = ProcessInfo.processInfo.environment }
public final class Own912 {
  public init() {}
  public var comp912: [String: String] { ProcessInfo.processInfo.environment }
  public func ownBaseRead() -> Int { comp912.count }
  public func ownSelfRead() -> Int { self.comp912.count }
  public func ownBareRead() -> [String: String] { comp912 }
}
// ── R579: a String local whose type is spelled nowhere
public func strJoined(_ xs: [String]) throws { let page = xs.map { $0 }.joined(separator: "\n"); try page.write(toFile: "/tmp/vb_r579j", atomically: true, encoding: .utf8) }
public func strLiteral() throws { let page = "hello"; try page.write(toFile: "/tmp/vb_r579l", atomically: true, encoding: .utf8) }
public func strInterp(_ n: Int) throws { let page = "n=\(n)"; try page.write(toFile: "/tmp/vb_r579i", atomically: true, encoding: .utf8) }
public func strAnnotated() throws { let page: String = "hello"; try page.write(toFile: "/tmp/vb_r579a", atomically: true, encoding: .utf8) }
// ── R905: an unannotated stored property initialised from a non-constructor expression
public struct Loud905 { public init() {}; public func go() -> String? { envOf("VB_905") } }
public func makeLoud905() -> Loud905 { Loud905() }
public struct Holder905 {
  public var viaFactory = makeLoud905()
  public var viaCtor = Loud905()
  public init() {}
  public func readFactory() -> String? { viaFactory.go() }
  public func readCtor() -> String? { viaCtor.go() }
}
public final class GenBox905<T> { public init() {}; public func peek() -> String? { envOf("VB_905g") } }
public func genericCtor905() -> String? { let b = GenBox905<Int>(); return b.peek() }
public func genericCtorInline905() -> String? { GenBox905<Int>().peek() }
// ── R589 / R906: differing CLASS roots on a ternary
open class CB906 { public init() {}; open func emitT() {} }
public final class CC906: CB906 { public override func emitT() { mark("r906c") } }
public final class CD906: CB906 { public override func emitT() { mark("r906d") } }
public func ternInline906(_ c: Bool) { (c ? CC906() : CD906()).emitT() }
public func ternBound906(_ c: Bool) { let b = c ? CC906() : CD906(); b.emitT() }
public func ternSame906(_ c: Bool) { (c ? CC906() : CC906()).emitT() }
// ── R615: a metatype read out of a container
public class RB615 { public required init() {}; public class func go() {} }
public class RS615: RB615 { public override class func go() { mark("r615") } }
public func metaLoop615() { let all: [RB615.Type] = [RS615.self]; for t in all { t.go() } }
public func metaFirst615() { let all: [RB615.Type] = [RS615.self]; if let t = all.first { t.go() } }
public func metaSubscript615() { let all: [RB615.Type] = [RS615.self]; all[0].go() }
public func metaDict615() { let d: [String: RB615.Type] = ["a": RS615.self]; if let t = d["a"] { t.go() } }
public func metaFilter615() { let all: [RB615.Type] = [RS615.self]; for t in all.filter({ _ in true }) { t.go() } }
// ── R619 / R738: a metatype field read through an explicit receiver; a protocol metatype
public protocol VP619 { static func validate() }
public struct VS619: VP619 { public static func validate() { mark("r619p") } }
public class VC619 { public class func validate() { mark("r619c") } }
public struct Holder619 { public var t: VC619.Type = VC619.self; public var p: VP619.Type = VS619.self; public init() {}
  public func selfProto619() { self.p.validate() } }
public func fieldInline619(_ b: Holder619) { b.t.validate() }
public func fieldBound738(_ b: Holder619) { let u = b.t; u.validate() }
public func fieldProto619(_ b: Holder619) { b.p.validate() }
public func boundProto619(_ b: Holder619) { let u = b.p; u.validate() }
public func mkP619() -> VP619.Type { VS619.self }
public func retDirect619() { mkP619().validate() }
public func retBound619() { let m = mkP619(); m.validate() }
// ── R618 / R907: a guessed outer-base root walked as a type
public struct Quiet618 { public init() {}; public func go() -> String? { nil } }
public struct Loud618 { public init() {}; public func go() -> String? { envOf("VB_618") } }
public struct Thing618 { public var items: [Loud618] = [Loud618()]; public init() {} }
public struct Outer618 {
  public var dep = [Thing618()].first!
  public var items: [Quiet618] = [Quiet618()]
  public init() {}
}
public func guessFirst618(_ o: Outer618) -> String? { o.dep.items.first?.go() }
public func guessSub618(_ o: Outer618) -> String? { o.dep.items[0].go() }
public func guessFor618(_ o: Outer618) -> String? { let ws = o.dep.items; for w in ws { return w.go() }; return nil }
public func guessAnnot618(_ o: Outer618) -> String? { let t: Thing618 = o.dep; return t.items[0].go() }
// ── R851: the `else` of `if let` / `guard let` reads the OUTER binding
public struct Quiet851 { public init() {}; public func go() -> String? { nil } }
public struct Loud851 { public init() {}; public func go() -> String? { envOf("VB_851") } }
public struct S851 {
  public var x: Loud851 = Loud851()
  public init() {}
  public func elseIfLet851(_ o: Quiet851?) -> String? { if let x = o { return x.go() } else { return x.go() } }
  public func elseGuard851(_ o: Quiet851?) -> String? { guard let x = o else { return x.go() }; return x.go() }
  public func noShadow851(_ o: Quiet851?) -> String? { if let y = o { return y.go() } else { return x.go() } }
  public func thenBranch851(_ o: Quiet851?) -> String? { if let x = o { return x.go() }; return nil }
}
// ── CONTROLS (second fixtures): each must keep the answer the release gave
public struct S851b {                       // the condition binder still types the THEN branch and the code after a guard
  public var x: Quiet851 = Quiet851()
  public init() {}
  public func thenLoud851(_ o: Loud851?) -> String? { if let x = o { return x.go() } else { return nil } }
  public func afterGuardLoud851(_ o: Loud851?) -> String? { guard let x = o else { return nil }; return x.go() }
}
// ── CALLERS: every defect cell is gated on its unit AND on a caller of it
public func callFnInvoke256() -> Bool { Gen256(f: { (i: Int) -> Bool in i > 0 }).fnInvoke() }
public func callPaImplicit578() { ImplA578().paImplicit() }
public func callPbImplicit578() { ImplB578().pbImplicit() }
public func callCtxImplicit904() -> Int { MainCtx904().ctxImplicit() }
public func callStrLiteral579() throws { try strLiteral() }
public func callStrJoined579() throws { try strJoined(["a"]) }
public func callGenericCtor905() -> String? { genericCtor905() }
public func callTernInline906() { ternInline906(true) }
public func callTernBound906() { ternBound906(false) }
public func callMetaFirst615() { metaFirst615() }
public func callMetaDict615() { metaDict615() }
public func callFieldBound738() { fieldBound738(Holder619()) }
public func callFieldProto619() { fieldProto619(Holder619()) }
public func callRetDirect619() { retDirect619() }
public func callGuessSub618() -> String? { guessSub618(Outer618()) }
public func callElseIfLet851() -> String? { S851().elseIfLet851(nil) }
public func callElseGuard851() -> String? { S851().elseGuard851(nil) }
"""#

    /// Every vein-B switch: with all of them set the engine is 113e5b4 on every cell (calibration, §1b).
    static let allOff: [String: String] = Dictionary(uniqueKeysWithValues:
        ["R866", "R615", "R619", "R738", "R579", "R905", "R578", "R256", "R906", "R851", "R618", "R904", "R912"]
            .map { ("CANDOR_\($0)_OFF", "1") })

    private func gate(_ root: URL, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
    }

    /// The defect cells — the unit AND a caller of it (names are not prefixes of each other: R909).
    static let defects: [String] = [
        "deny Unknown Gen256.fnInvoke", "deny Unknown callFnInvoke256",                       // R256 (disclosed)
        "deny Fs PA578.paImplicit", "deny Fs PA578.paExplicit", "deny Fs PA578.paLocal",       // R578
        "deny Fs PB578.pbImplicit", "deny Fs PB578.pbExplicit",
        "deny Fs callPaImplicit578", "deny Fs callPbImplicit578",
        "deny Env Ctx904.ctxImplicit", "deny Env callCtxImplicit904",                         // R904
        "deny Fs strJoined", "deny Fs strLiteral", "deny Fs strInterp",                         // R579
        "deny Fs callStrLiteral579", "deny Fs callStrJoined579",
        "deny Env genericCtor905", "deny Env callGenericCtor905",                             // R905 (ctor)
        "deny Fs ternInline906", "deny Fs ternBound906", "deny Fs callTernInline906", "deny Fs callTernBound906", // R906
        "deny Fs metaFirst615", "deny Fs metaSubscript615", "deny Fs metaDict615", "deny Fs metaFilter615", // R615
        "deny Fs callMetaFirst615", "deny Fs callMetaDict615",
        "deny Fs fieldBound738", "deny Fs callFieldBound738",                                 // R738
        "deny Fs fieldProto619", "deny Fs boundProto619", "deny Fs Holder619.selfProto619",   // R619
        "deny Fs retDirect619", "deny Fs callFieldProto619", "deny Fs callRetDirect619",
        "deny Unknown guessFirst618", "deny Unknown guessSub618", "deny Unknown guessFor618",   // R907 (disclosed)
        "deny Unknown callGuessSub618",
        "deny Env S851.elseIfLet851", "deny Env S851.elseGuard851",                           // R851
        "deny Env callElseIfLet851", "deny Env callElseGuard851",
    ]

    func testDefectCellsFireOnUnitAndCallerAndTheSwitchesRestoreTheRelease() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        for p in Self.defects {
            XCTAssertEqual(try gate(root, p), 1, "`\(p)` must fail: the effect really happens (executed)")
            // §1b — with every vein-B switch set the engine is 113e5b4, and every cell reads 0 there: each cell
            // is shown able to fail. A must-PASS arm is `!= 1` (under `swift test` a non-violating gate may be 2).
            XCTAssertNotEqual(try gate(root, p, env: Self.allOff), 1, "`\(p)` with every vein-B switch set")
        }
    }

    /// THE SECOND FIXTURES: each answer the release gave and this change could have moved.
    func testControlsKeepTheReleaseAnswer() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        // R851 — the condition binder still types the THEN branch and the code after a `guard` (executed: Env).
        for p in ["deny Env S851b.thenLoud851", "deny Env S851b.afterGuardLoud851",
                  "deny Env S851.noShadow851",
                  // R256 — the NOMINAL cell keeps its precise `Fs` (executed) …
                  "deny Fs Gen256.nomInvoke",
                  // R905/R578/R619/R906 — the spellings that already resolved still do.
                  "deny Env Holder905.readFactory", "deny Fs fieldInline619", "deny Fs retBound619",
                  "deny Fs ternSame906", "deny Fs metaLoop615", "deny Env Ctx904.ctxExplicit", "deny Fs strAnnotated",
                  "deny Env guessAnnot618"] {
            XCTAssertEqual(try gate(root, p), 1, "`\(p)` must stay charged")
        }
        // … and is NOT hedged to buy the function-type cell (R256's over-charge control); a non-guessed
        // receiver is not disclosed (R907's); the non-shadowing `else` is not hedged (R851's).
        for p in ["deny Unknown Gen256.nomInvoke", "deny Unknown guessAnnot618", "deny Unknown S851.noShadow851",
                  "deny Unknown PA578.paImplicit", "deny Unknown strLiteral"] {
            XCTAssertNotEqual(try gate(root, p), 1, "`\(p)` must not gain a hedge")
        }
    }

    /// SOUNDNESS R912 — the class-typed implicit-`self` base read reaches the getter, as `self.comp912.count`
    /// always did (a consistency resolution, ON by default); `CANDOR_R912_OFF=1` restores 113e5b4.
    func testR912BaseReadReachesTheGetter() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try gate(root, "deny Env Own912.ownBaseRead"), 1, "the getter reads the environment (executed)")
        XCTAssertNotEqual(try gate(root, "deny Env Own912.ownBaseRead", env: ["CANDOR_R912_OFF": "1"]), 1,
                          "R912 under its switch is 113e5b4")
        XCTAssertEqual(try gate(root, "deny Env Own912.ownSelfRead"), 1, "the explicit `self.` twin was always charged")
    }

    // ── CHAINED: R866 (a composition naming a DEPENDENCY's protocol) and R618 (a guessed root's element) ──

    private func run(_ args: [String], env: [String: String] = [:]) throws -> (out: String, err: String, code: Int32) {
        try ProcessHarness.run(try ProcessHarness.binaryURL(for: Self.self), args, env: env)
    }
    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    /// Scans `dep` standalone, then `app` chained on its report, and gates `policy` on the consumer.
    private func chained(dep: String, app: String, policy: String, env: [String: String] = [:]) throws -> Int32 {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-veinb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = root.appendingPathComponent("iface"), a = root.appendingPathComponent("app")
        try write(d.appendingPathComponent("Package.swift"), """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Iface", products: [.library(name: "Iface", targets: ["Iface"])], targets: [.target(name: "Iface")])
        """)
        try write(d.appendingPathComponent("Sources/Iface/lib.swift"), dep)
        try write(a.appendingPathComponent("Package.swift"), """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../iface")], targets: [.target(name: "App", dependencies: [.product(name: "Iface", package: "iface")])])
        """)
        try write(a.appendingPathComponent("Sources/App/a.swift"), app)
        try FileManager.default.createDirectory(at: a.appendingPathComponent(".build/checkouts"), withIntermediateDirectories: true)
        let out = root.appendingPathComponent("depR")
        XCTAssertEqual(try run([d.path, "--out", out.appendingPathComponent("r").path], env: env).code, 0)
        let rep = out.appendingPathComponent("r.Iface.Swift.json").path
        let pf = root.appendingPathComponent("p.policy")
        try write(pf, policy + "\n")
        var e = env; e["CANDOR_DEPS"] = rep
        return try run([a.path, "--policy", pf.path, "--out", root.appendingPathComponent("s").path], env: e).code
    }

    static let depLib = """
    import Foundation
    public func dEnv() -> String? { ProcessInfo.processInfo.environment["VB_DEP"] }
    public protocol PSubD: Sendable { func go() -> String? }
    public struct DImpl: PSubD { public init() {}; public func go() -> String? { dEnv() } }
    public struct DQuiet { public init() {}; public func go() -> String? { nil } }
    public struct DLoud { public init() {}; public func go() -> String? { dEnv() } }
    """
    static let depApp = """
    import Foundation
    import Iface
    public func compo866(_ t: any PSubD & Sendable) -> String? { t.go() }
    public func plain866(_ t: any PSubD) -> String? { t.go() }
    struct ThingD { var items: [DLoud] = [DLoud()] }
    struct OuterD { var dep = [ThingD()].first!; var items: [DQuiet] = [DQuiet()] }
    func depGuessSub618(_ o: OuterD) -> String? { o.dep.items[0].go() }
    func depDirectSub618(_ o: OuterD) -> String? { o.items[0].go() }
    """

    /// EXECUTED as real SwiftPM packages (`swiftagent-veinB/vfx/ch1/A866`, `fx/ch618`): `compo866` and
    /// `depGuessSub618` read the environment; `depDirectSub618` calls the pure `DQuiet.go`.
    func testChainedCompositionResolvesAndGuessedElementDiscloses() throws {
        XCTAssertEqual(try chained(dep: Self.depLib, app: Self.depApp, policy: "deny Env compo866"), 1, "R866 resolved")
        XCTAssertNotEqual(try chained(dep: Self.depLib, app: Self.depApp, policy: "deny Env compo866",
                                      env: ["CANDOR_R866_OFF": "1"]), 1, "R866 under its switch is 113e5b4")
        XCTAssertEqual(try chained(dep: Self.depLib, app: Self.depApp, policy: "deny Env plain866"), 1, "control")
        XCTAssertEqual(try chained(dep: Self.depLib, app: Self.depApp, policy: "deny Env Unknown depGuessSub618"), 1,
                       "R618 disclosed: the element type was read off a guessed root")
        XCTAssertNotEqual(try chained(dep: Self.depLib, app: Self.depApp, policy: "deny Env Unknown depGuessSub618",
                                      env: ["CANDOR_R618_OFF": "1"]), 1, "R618 under its switch is 113e5b4")
        XCTAssertNotEqual(try chained(dep: Self.depLib, app: Self.depApp, policy: "deny Env Unknown depDirectSub618"), 1,
                          "a non-guessed element is not hedged")
    }
}
