import XCTest
import Foundation

/// SOUNDNESS R1175 + R1176 — the comparison-witness walk.
///
/// R1175: the walk from an operand's type to the `Equatable`/`Hashable` witnesses it runs stopped after 32 types and
/// visited fields in `Dictionary` order (per-process hash seed), so the report differed between identical runs
/// (wikipedia-ios `isRootTabView`, iina `SidebarController.show`) and a witness past the cap was never reached
/// (`kDeepCmp`, executed: writes a file, the release read `[]`). It also walked a CLASS's stored properties, which no
/// class comparison ever compares (`zClassNs`, `Viewer.zSelfCmp`: fabricated `Noisy.==`); a class's comparison runs a
/// declared `==` in its hierarchy or `NSObject.isEqual(_:)` overrides (`kIsEqualSub`, executed).
/// R1176: five in-package shapes ran a user witness and read `[]` (executed, the R974 lane's `fx2`): `[T] == [T]` in a
/// generic, `Set(xs)`, a synthesized-witness instantiation, a generic TYPE's method, an unannotated `Set<T>()` local.
/// Every `k*` function below runs `Noisy`'s or `LoudObj`'s effectful witness; every `z*` function runs none.
final class R1175R1176WitnessWalkProcessTests: XCTestCase {
    static let source = #"""
import Foundation
// Every effect is a file whose name says which witness ran; ground truth is the file's existence after a run.
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/swv060-\(s).txt", contents: nil) }
struct Noisy: Hashable {
    var v: Int
    static func == (l: Noisy, r: Noisy) -> Bool { mark("eq"); return l.v == r.v }
    func hash(into h: inout Hasher) { mark("hash"); h.combine(v) }
}
struct Quiet: Hashable { var v: Int }
// ── R1175 — a CLASS has no synthesized `==`: comparing two instances never compares their stored properties ──
final class Holder: NSObject { var n = Noisy(v: 1) }                       // NSObject `==` is identity `isEqual`
final class PlainEq: Equatable { var n = Noisy(v: 1); static func == (l: PlainEq, r: PlainEq) -> Bool { l === r } }
class LoudObj: NSObject { var n = Noisy(v: 1); override func isEqual(_ o: Any?) -> Bool { mark("isequal"); return o as AnyObject === self } }
class LoudSub: LoudObj {}
class Viewer: NSObject {
    var n = Noisy(v: 1)
    func zSelfCmp(_ o: Viewer) -> Bool { o == self }                      // CONTROL: Noisy.== never runs
}
func zClassNs() -> Bool { let a = Holder(), b = Holder(); return a == b }  // CONTROL
func zClassEq() -> Bool { let a = PlainEq(), b = PlainEq(); return a == b }// CONTROL
func kIsEqualSub() -> Bool { let a = LoudSub(), b = LoudSub(); return a == b } // runs LoudObj.isEqual
// a synthesized `==` reaching its witness through more than 32 types: the walk must not truncate
struct D0: Equatable { var a = D1(); var b1 = 0 }
struct D1: Equatable { var a = D2() }; struct D2: Equatable { var a = D3() }; struct D3: Equatable { var a = D4() }
struct D4: Equatable { var a = D5() }; struct D5: Equatable { var a = D6() }; struct D6: Equatable { var a = D7() }
struct D7: Equatable { var a = D8() }; struct D8: Equatable { var a = D9() }; struct D9: Equatable { var a = E0() }
struct E0: Equatable { var a = E1() }; struct E1: Equatable { var a = E2() }; struct E2: Equatable { var a = E3() }
struct E3: Equatable { var a = E4() }; struct E4: Equatable { var a = E5() }; struct E5: Equatable { var a = E6() }
struct E6: Equatable { var a = E7() }; struct E7: Equatable { var a = E8() }; struct E8: Equatable { var a = E9() }
struct E9: Equatable { var a = F0() }; struct F0: Equatable { var a = F1() }; struct F1: Equatable { var a = F2() }
struct F2: Equatable { var a = F3() }; struct F3: Equatable { var a = F4() }; struct F4: Equatable { var a = F5() }
struct F5: Equatable { var a = F6() }; struct F6: Equatable { var a = F7() }; struct F7: Equatable { var a = F8() }
struct F8: Equatable { var a = F9() }; struct F9: Equatable { var a = G0() }; struct G0: Equatable { var a = G1() }
struct G1: Equatable { var a = G2() }; struct G2: Equatable { var a = G3() }; struct G3: Equatable { var a = Noisy(v: 0) }
func kDeepCmp() -> Bool { D0() == D0() }
// ── R1176 — the five in-package shapes ──
struct Wrap: Equatable { var n: Noisy }
struct WrapQ: Equatable { var n: Quiet }
struct GBox<T: Equatable> { var items: [T] = []; mutating func add(_ x: T) { if !items.contains(x) { items.append(x) } } }
func eqL<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
func arrL<T: Equatable>(_ a: [T], _ b: [T]) -> Bool { a == b }
func setL<T: Hashable>(_ xs: [T]) -> Int { Set(xs).count }
func kArrGen() -> Bool { arrL([Noisy(v: 1)], [Noisy(v: 1)]) }
func kSetInit() -> Int { setL([Noisy(v: 1), Noisy(v: 2)]) }
func kWrapInst() -> Bool { eqL(Wrap(n: Noisy(v: 1)), Wrap(n: Noisy(v: 1))) }
func kBoxAdd() -> Int { var b = GBox<Noisy>(); b.add(Noisy(v: 1)); b.add(Noisy(v: 1)); return b.items.count }
func kSetLocal() -> Int { var s = Set<Noisy>(); s.insert(Noisy(v: 1)); s.insert(Noisy(v: 2)); return s.count }
func kSetDirect() -> Int { let xs = [Noisy(v: 1), Noisy(v: 2)]; return Set(xs).count }
// forwards inside / between generic types
extension GBox { mutating func addTwice(_ x: T) { add(x); self.add(x) } }
struct Outer<U: Equatable> { var inner = GBox<U>(); mutating func put(_ u: U) { inner.add(u) } }
struct Cmp<T: Equatable> { var v: T; func same(_ o: T) -> Bool { eqL(v, o) } }
func kBoxTwice() -> Int { var b = GBox<Noisy>(); b.addTwice(Noisy(v: 1)); return b.items.count }
func kOuterPut() -> Int { var o = Outer<Noisy>(); o.put(Noisy(v: 1)); o.put(Noisy(v: 1)); return o.inner.items.count }
func kCmpSame() -> Bool { Cmp(v: Noisy(v: 1)).same(Noisy(v: 1)) }
func zOuterInt() -> Int { var o = Outer<Int>(); o.put(1); o.put(1); return o.inner.items.count }
func zCmpQuiet() -> Bool { Cmp(v: Quiet(v: 1)).same(Quiet(v: 1)) }
// CONTROLS for R1176: the same shapes over a type whose witnesses are synthesized and pure
func zArrInt() -> Bool { arrL([1], [1]) }
func zSetQuiet() -> Int { setL([Quiet(v: 1), Quiet(v: 2)]) }
func zWrapQuiet() -> Bool { eqL(WrapQ(n: Quiet(v: 1)), WrapQ(n: Quiet(v: 1))) }
func zBoxInt() -> Int { var b = GBox<Int>(); b.add(1); b.add(1); return b.items.count }
func zSetLocalInt() -> Int { var s = Set<Int>(); s.insert(1); s.insert(2); return s.count }
"""#

    private func rows(env: [String: String] = [:]) throws -> [String: [String]] {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "W")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertGreaterThan(((d["analyzed"] as? [String: Any])?["count"] as? Int) ?? 0, 0)
        var out: [String: [String]] = [:]
        for case let f as [String: Any] in (d["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { out[n] = f["inferred"] as? [String] ?? [] }
        }
        return out
    }

    static let r1176 = ["kArrGen", "kSetInit", "kWrapInst", "kBoxAdd", "kSetLocal", "kSetDirect", "kBoxTwice", "kOuterPut", "kCmpSame"]
    static let controls = ["zClassNs", "Viewer.zSelfCmp", "zClassEq", "zArrInt", "zSetQuiet", "zWrapQuiet", "zBoxInt",
                           "zSetLocalInt", "zOuterInt", "zCmpQuiet"]

    func testInPackageWitnessShapesAreCharged() throws {
        let on = try rows(), off = try rows(env: ["CANDOR_R1176_OFF": "1"])
        for fn in Self.r1176 {
            XCTAssertTrue(on[fn]?.contains("Fs") ?? false, "\(fn): runs Noisy's witness (executed); got \(on[fn] ?? [])")
            XCTAssertFalse(off[fn]?.contains("Fs") ?? false, "\(fn): CANDOR_R1176_OFF=1 must reproduce the release's silence")
        }
    }

    func testTheWalkIsNotTruncated() throws {
        let on = try rows(), off = try rows(env: ["CANDOR_R1175_OFF": "1"])
        XCTAssertTrue(on["kDeepCmp"]?.contains("Fs") ?? false, "a witness 34 types deep is still the comparison's")
        XCTAssertFalse(off["kDeepCmp"]?.contains("Fs") ?? false, "CANDOR_R1175_OFF=1 reproduces the 32-type cap")
    }

    func testAClassComparesThroughItsHierarchyNotItsFields() throws {
        let on = try rows(), off = try rows(env: ["CANDOR_R1175C_OFF": "1"])
        XCTAssertTrue(on["kIsEqualSub"]?.contains("Fs") ?? false, "NSObject == runs LoudObj.isEqual (executed)")
        for fn in ["zClassNs", "Viewer.zSelfCmp"] {
            XCTAssertFalse(on[fn]?.contains("Fs") ?? false, "\(fn): a class == never compares its stored Noisy")
            XCTAssertTrue(off[fn]?.contains("Fs") ?? false, "\(fn): CANDOR_R1175C_OFF=1 reproduces the fabricated walk")
        }
    }

    func testControlsStayFreeOfFs() throws {
        let on = try rows()
        for fn in Self.controls { XCTAssertFalse(on[fn]?.contains("Fs") ?? false, "\(fn): runs no effectful witness (executed)") }
    }
}
