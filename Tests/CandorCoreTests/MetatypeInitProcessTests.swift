import XCTest
import Foundation

/// SOUNDNESS R1506 — `<metatype value>.init(…)` typed nothing, so a call on the constructed value was DROPPED:
/// `meta.init().eff()` for `var meta: Loud.Type`, and every other way a metatype value reaches `init` — a local
/// (annotated or `= Loud.self`), a global, a parameter, an array element, a factory's return, `type(of: x)`, `X.self`,
/// a generic `T.Type` / `T` bound to a protocol, `any P.Type`, `Self.init()`, a `Base.Type` holding a subclass — plus a
/// `-> Self` static member (`Loud.mkSelf().eff()`) and an UNANNOTATED stored property / global (`var meta = Loud.self`),
/// which recorded no metatype at all. The `init` call itself already resolved; only the value it returns was untyped.
/// EXECUTED (`~/candor-handoff/swift-r1506/fx/M`): every `p…` caller writes the marker; every `k…` control runs the same
/// shape over a type whose `eff()` is pure and writes nothing. Residual, not fixed (a separate defect, all field facts):
/// a method in the BODY of a nested type that shares its simple name with another nested type (`NA.NT` / `NZ.NT`).
final class MetatypeInitProcessTests: XCTestCase {
    static let src = """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1506-" + s, contents: nil) }
protocol Mk { init(); func eff() }
struct Loud: Mk { init() {}; func eff() { mark("x") }; static func mkSelf() -> Self { Self() } }
struct Quiet: Mk { init() {}; func eff() { }; static func mkSelf() -> Self { Self() } }
class Base { required init() {}; func eff() {} }
class Sub: Base { required init() {}; override func eff() { mark("x") } }
class QBase { required init() {}; func eff() {} }
struct H {
    var meta: Loud.Type = Loud.self
    var qmeta: Quiet.Type = Quiet.self
    var inf = Loud.self
    var bmeta: Base.Type = Sub.self
    var pmeta: Mk.Type = Loud.self
    func pField() { meta.init().eff() }
    func pFieldSelf() { self.meta.init().eff() }
    func pFieldBind() { let x = meta.init(); x.eff() }
    func pFieldInf() { inf.init().eff() }
    func pFieldBase() { bmeta.init().eff() }
    func pFieldProto() { pmeta.init().eff() }
    func kField() { qmeta.init().eff() }
}
struct TopT { var meta: Loud.Type = Loud.self }
extension TopT { func pTopExt() { meta.init().eff() } }
let gMeta = Loud.self
let gQMeta = Quiet.self
func pGlobal() { gMeta.init().eff() }
func kGlobal() { gQMeta.init().eff() }
func pLocal() { let m = Loud.self; m.init().eff() }
func kLocal() { let m = Quiet.self; m.init().eff() }
func pSelfExpr() { Loud.self.init().eff() }
func pTypeOf() { let x = Loud(); type(of: x).init().eff() }
func kTypeOf() { let x = Quiet(); type(of: x).init().eff() }
func pParam(_ t: Loud.Type) { t.init().eff() }
func kParam(_ t: Quiet.Type) { t.init().eff() }
func pGeneric<T: Mk>(_ t: T.Type) { t.init().eff() }
func pGenericT<T: Mk>(_ t: T.Type) { T.init().eff() }
func pGenCtor<T: Mk>(_ t: T.Type) { T().eff() }
func pAnyMeta(_ t: any Mk.Type) { t.init().eff() }
func mkMeta() -> Loud.Type { Loud.self }
func pReturn() { mkMeta().init().eff() }
func pBaseParam(_ b: Base.Type) { b.init().eff() }
func kQBase() { let q: QBase.Type = QBase.self; q.init().eff() }
func pArrElem() { let ms: [Loud.Type] = [Loud.self]; for m in ms { m.init().eff() } }
func pLitMkSelf() { Loud.mkSelf().eff() }
func kLitMkSelf() { Quiet.mkSelf().eff() }
extension Loud { static func pSelfInit() { Self.init().eff() } }
let h = H()
func seen() -> Bool { let r = FileManager.default.fileExists(atPath: "/tmp/r1506-x"); try? FileManager.default.removeItem(atPath: "/tmp/r1506-x"); return r }
_ = seen()
let cases: [(String, () -> Void)] = [("pField", h.pField), ("pFieldSelf", h.pFieldSelf), ("pFieldBind", h.pFieldBind),
  ("pFieldInf", h.pFieldInf), ("pFieldBase", h.pFieldBase), ("pFieldProto", h.pFieldProto), ("kField", h.kField),
  ("pTopExt", { TopT().pTopExt() }), ("pGlobal", pGlobal), ("kGlobal", kGlobal), ("pLocal", pLocal), ("kLocal", kLocal),
  ("pSelfExpr", pSelfExpr), ("pTypeOf", pTypeOf), ("kTypeOf", kTypeOf), ("pParam", { pParam(Loud.self) }),
  ("kParam", { kParam(Quiet.self) }), ("pGeneric", { pGeneric(Loud.self) }), ("pGenericT", { pGenericT(Loud.self) }),
  ("pGenCtor", { pGenCtor(Loud.self) }), ("pAnyMeta", { pAnyMeta(Loud.self) }), ("pReturn", pReturn),
  ("pBaseParam", { pBaseParam(Sub.self) }), ("kQBase", kQBase), ("pArrElem", pArrElem), ("pLitMkSelf", pLitMkSelf),
  ("kLitMkSelf", kLitMkSelf), ("pSelfInit", { Loud.pSelfInit() })]
for (n, f) in cases { f(); print(n, seen()) }
"""

    private func scan(_ root: URL, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }
    private func gate(_ root: URL, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = root.appendingPathComponent("policy.candor")
        try policy.write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", root.appendingPathComponent("g").path],
                                      env: env).code
    }

    func testAMetatypeValueInitTypesTheConstructedValue() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        let charged = ["H.pField", "H.pFieldSelf", "H.pFieldBind", "H.pFieldInf", "H.pFieldBase", "H.pFieldProto", "TopT.pTopExt",
                       "pGlobal", "pLocal", "pSelfExpr", "pTypeOf", "pParam", "pGeneric", "pGenericT", "pGenCtor", "pAnyMeta",
                       "pReturn", "pBaseParam", "pArrElem", "pLitMkSelf", "Loud.pSelfInit"]
        for fn in charged {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes the marker (executed) — \(by[fn] ?? [:])")
        }
        // CONTROLS: the same shape over a type whose `eff()` (and `init`) is pure must not gain a charge.
        for fn in ["H.kField", "kGlobal", "kLocal", "kTypeOf", "kParam", "kQBase", "kLitMkSelf"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, fn), "\(fn) runs only pure bodies (executed: no marker)")
        }
        let off = try scan(root, env: ["CANDOR_R1506_OFF": "1"])
        for fn in ["H.pField", "TopT.pTopExt", "pLocal", "pParam", "pGeneric", "pAnyMeta", "pLitMkSelf", "H.pFieldInf"] {
            XCTAssertNil(ProcessHarness.chargedNothing(off, fn), "the release was silent: \(fn) \(off[fn] ?? [:])")
        }
        XCTAssertEqual(try gate(root, "deny Fs TopT.pTopExt\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs TopT.pTopExt\n", env: ["CANDOR_R1506_OFF": "1"]), 0)
        XCTAssertEqual(try gate(root, "deny Fs H.kField\n"), 0)
    }
}
