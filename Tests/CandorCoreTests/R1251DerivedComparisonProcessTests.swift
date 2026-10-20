import XCTest
import Foundation

/// SOUNDNESS R1251 — a DERIVED comparison spelling (`!=`, `>`, `<=`, `>=`, `..<`, `...`) over a type that DECLARES
/// `==`/`<` runs that declared witness, through the stdlib's protocol-extension default.
///
/// EXECUTED (`swiftagent-a/r1251`, `swiftc -O`, one run per function): every `charged` function below wrote a file
/// through the declared witness; every `control` wrote none. The release edged the operator AS SPELLED (`Eqo.!=`,
/// `Cmp.>` — units that do not exist) and R951's witness edge skipped the operand's type because it declared the
/// witness, so the whole `charged` list read pure. `hasher.combine(x)` took the same skip (its direct edge is
/// `Hasher.combine`). The controls are the over-charge side: a type with its OWN operator by the spelled name runs
/// that one (Swift prefers it to the default), whether it is a member, inherited from a superclass, or a free
/// overload — and `subNeq` was a FABRICATION before this change (`Base.==` charged; executed: never runs).
final class R1251DerivedComparisonProcessTests: XCTestCase {
    static let source = #"""
import Foundation
func touch(_ t: String) { FileManager.default.createFile(atPath: "/tmp/r1251-" + t, contents: nil) }
struct Eqo: Equatable { let v: Int; static func == (a: Eqo, b: Eqo) -> Bool { touch("e"); return a.v == b.v } }
struct Cmp: Comparable { let v: Int
  static func < (a: Cmp, b: Cmp) -> Bool { touch("l"); return a.v < b.v }
  static func == (a: Cmp, b: Cmp) -> Bool { a.v == b.v } }
final class EqC: Equatable { let v: Int; init(_ v: Int) { self.v = v }
  static func == (a: EqC, b: EqC) -> Bool { touch("c"); return a.v == b.v } }
struct Hs: Hashable { let v: Int; func hash(into h: inout Hasher) { touch("h"); h.combine(v) } }
struct NeqOwn: Equatable { let v: Int
  static func == (a: NeqOwn, b: NeqOwn) -> Bool { touch("n"); return a.v == b.v }
  static func != (a: NeqOwn, b: NeqOwn) -> Bool { a.v != b.v } }
struct GtOwn: Comparable { let v: Int
  static func < (a: GtOwn, b: GtOwn) -> Bool { touch("g"); return a.v < b.v }
  static func > (a: GtOwn, b: GtOwn) -> Bool { a.v > b.v } }
struct FreeGt: Comparable { let v: Int
  static func < (a: FreeGt, b: FreeGt) -> Bool { touch("f"); return a.v < b.v } }
func > (a: FreeGt, b: FreeGt) -> Bool { a.v > b.v }
class Base: Equatable { let v: Int; init(_ v: Int) { self.v = v }
  static func == (a: Base, b: Base) -> Bool { touch("b"); return a.v == b.v }
  static func != (a: Base, b: Base) -> Bool { a.v != b.v } }
final class Sub: Base {}
struct RngOwn: Comparable { let v: Int
  static func < (a: RngOwn, b: RngOwn) -> Bool { touch("r"); return a.v < b.v }
  static func ..< (a: RngOwn, b: RngOwn) -> Range<RngOwn> { Range(uncheckedBounds: (a, b)) } }
func neq(_ a: Eqo, _ b: Eqo) -> Bool { a != b }
func neqLit(_ a: Eqo) -> Bool { a != Eqo(v: 3) }
func gt(_ a: Cmp, _ b: Cmp) -> Bool { a > b }
func le(_ a: Cmp, _ b: Cmp) -> Bool { a <= b }
func ge(_ a: Cmp, _ b: Cmp) -> Bool { a >= b }
func halfOpen(_ a: Cmp, _ b: Cmp) -> Range<Cmp> { a..<b }
func closed(_ a: Cmp, _ b: Cmp) -> ClosedRange<Cmp> { a...b }
func neqClass(_ a: EqC, _ b: EqC) -> Bool { a != b }
func combine(_ x: Hs) -> Int { var h = Hasher(); h.combine(x); return h.finalize() }
func freeLe(_ a: FreeGt, _ b: FreeGt) -> Bool { a <= b }
func rngOwnClosed(_ a: RngOwn, _ b: RngOwn) -> ClosedRange<RngOwn> { a...b }
struct Holder { let e: Eqo; let c: Cmp
  func mNeq(_ o: Holder) -> Bool { e != o.e }
  func mGt(_ o: Holder) -> Bool { self.c > o.c } }
// CONTROLS — executed: no witness runs
func neqNil(_ a: Eqo?) -> Bool { a != nil }
func ownNeq(_ a: NeqOwn, _ b: NeqOwn) -> Bool { a != b }
func ownGt(_ a: GtOwn, _ b: GtOwn) -> Bool { a > b }
func freeGt(_ a: FreeGt, _ b: FreeGt) -> Bool { a > b }
func subNeq(_ a: Sub, _ b: Sub) -> Bool { a != b }
func rngOwn(_ a: RngOwn, _ b: RngOwn) -> Range<RngOwn> { a..<b }
func intRange(_ n: Int) -> Int { var s = 0; for i in 0..<n { s += i }; return s }
"""#

    static let charged = ["neq", "neqLit", "gt", "le", "ge", "halfOpen", "closed", "neqClass", "combine", "freeLe",
                          "rngOwnClosed", "Holder.mNeq", "Holder.mGt"]
    static let controls = ["neqNil", "ownNeq", "ownGt", "freeGt", "subNeq", "rngOwn", "intRange"]

    private func rows(env: [String: String] = [:]) throws -> [String: [String]] {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
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

    func testDerivedSpellingsReachTheDeclaredWitness() throws {
        let on = try rows(), off = try rows(env: ["CANDOR_R1251_OFF": "1"])
        for fn in Self.charged {
            XCTAssertEqual(on[fn], ["Fs"], "\(fn): runs the declared witness (executed)")
            XCTAssertNil(off[fn], "\(fn): CANDOR_R1251_OFF=1 must reproduce the release's silent row")
        }
    }

    func testAnOperatorOfTheTypesOwnIsNotTheWitness() throws {
        let on = try rows(), off = try rows(env: ["CANDOR_R1251_OFF": "1"])
        for fn in Self.controls { XCTAssertNil(on[fn], "\(fn): no witness runs (executed) — got \(on[fn] ?? [])") }
        // the fabrication this change removes — proves the control can fail
        XCTAssertEqual(off["subNeq"], ["Fs"], "the release charged Sub != Sub with Base.== (executed: Base.!= runs)")
    }
}
