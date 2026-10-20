import XCTest
import Foundation

/// SOUNDNESS R1270 / R1251 (residual) / R1259 / R1272 — WHICH operator a derived comparison runs.
///
/// R1251 skips the operand's witness when the type has an operator OF ITS OWN by the spelled name, because Swift
/// then runs that operator instead of the stdlib default. Its first cut recorded an owner from the operator's NAME
/// alone, so an operator with a DIFFERENT right-hand type — `static func != (lhs: S, rhs: Int)`, a free
/// `func != (S, String)`, a generic `!= <T: BinaryInteger>(S, T)`, a superclass's `!= (Base, Int)` — made the type an
/// "owner" of `!=`. None of them can answer `S != S`, so the default runs, i.e. the declared or synthesized `==`.
///
/// EXECUTED (`swiftab-a/fx/a`, `fx/b`, `swiftc -O`, one run per function; the bodies that ran are the truth):
///   · `charged` — each wrote a file through the witness (`Eqo.==`, `Cmp.<`, `BaseH.==`). v0.40.13 charged the
///     R1270 five (`hetMember`, `hetFree`, `hetGeneric`, `hetSuper`, `hetField`); 3cc78e7 read them pure.
///     `cmpHet`/`eqHet` are R1251's residual (silent in both). `enumHet`/`plainLt`/`plainEq` are R1272: an enum's
///     synthesized witness compares its PAYLOADS, which the walk never visited (silent in both, with or without a
///     foreign operator). `heq*` are the witness side of R1270: a declared `== (S, Int)` was taken for `S`'s
///     witness, so the synthesized field `==` was never walked (silent in both).
///   · `controls` — no witness runs. `pgt`/`qne` are R1259: an operator in a PROTOCOL EXTENSION the type conforms
///     to runs instead of the default (3cc78e7 over-charged the type's own witness). `optFree` is a free
///     `(S?, S?)` overload, which Swift does choose for `S != S`.
final class R1270HeterogeneousOperatorProcessTests: XCTestCase {
    static let source = #"""
import Foundation
func touch(_ t: String) { FileManager.default.createFile(atPath: "/tmp/r1270-" + t, contents: nil) }
struct Eqo: Equatable { let v: Int; static func == (a: Eqo, b: Eqo) -> Bool { touch("e"); return a.v == b.v } }
struct Cmp: Comparable { let v: Int
  static func < (a: Cmp, b: Cmp) -> Bool { touch("l"); return a.v < b.v }
  static func == (a: Cmp, b: Cmp) -> Bool { a.v == b.v } }
// R1270 — synthesized Equatable plus a `!=` whose right-hand type is not Self
struct SynA: Equatable { let e: Eqo
  static func != (lhs: SynA, rhs: Int) -> Bool { lhs.e.v != rhs } }
struct SynB: Equatable { let e: Eqo }
func != (lhs: SynB, rhs: String) -> Bool { "\(lhs.e.v)" != rhs }
struct SynF: Equatable { let e: Eqo
  static func != <T: BinaryInteger>(lhs: SynF, rhs: T) -> Bool { Int(rhs) != lhs.e.v } }
class BaseH: Equatable { let v: Int; init(_ v: Int) { self.v = v }
  static func == (a: BaseH, b: BaseH) -> Bool { touch("b"); return a.v == b.v }
  static func != (a: BaseH, b: Int) -> Bool { a.v != b } }
final class SubH: BaseH {}
struct SynA2: Equatable { let e: Eqo
  static func != (lhs: SynA2, rhs: Int) -> Bool { lhs.e.v != rhs } }
struct Outer2: Equatable { let a: SynA2 }
// R1251 residual — the type DECLARES the witness and a different-right-hand operator by the spelled name
struct CmpH: Comparable { let v: Int
  static func < (a: CmpH, b: CmpH) -> Bool { touch("ch"); return a.v < b.v }
  static func > (a: CmpH, b: Int) -> Bool { a.v > b } }
struct EqH: Equatable { let v: Int
  static func == (a: EqH, b: EqH) -> Bool { touch("eh"); return a.v == b.v }
  static func != (a: EqH, b: String) -> Bool { "\(a.v)" != b } }
// R1272 — enum, synthesized Comparable (case order, then the payload's `<`), plus a different-right-hand `>`
enum SynE: Comparable { case one(Cmp), two
  static func > (lhs: SynE, rhs: Int) -> Bool { rhs < 0 } }
// R1270 witness side — the type's only DECLARED `==` takes a foreign operand, so its witness is still synthesized
struct HEq: Equatable { let e: Eqo
  static func == (l: HEq, r: Int) -> Bool { l.e.v == r } }
struct HHolder: Equatable { let h: HEq }
// R1272 — the same payload walk with no foreign operator at all
enum PlainE: Comparable { case one(Cmp), two }
enum PlainQ: Equatable { case one(Eqo), two }
// R1259 — an operator in a protocol extension the type conforms to
protocol PGt: Comparable { var key: Int { get } }
extension PGt { static func > (a: Self, b: Self) -> Bool { a.key > b.key } }
struct TP: PGt { let key: Int
  static func < (a: TP, b: TP) -> Bool { touch("tp"); return a.key < b.key } }
protocol QNe: Equatable { var key: Int { get } }
extension QNe { static func != (a: Self, b: Self) -> Bool { a.key != b.key } }
struct TQ: QNe { let key: Int
  static func == (a: TQ, b: TQ) -> Bool { touch("tq"); return a.key == b.key } }
// the free optional overload Swift DOES choose for `SynD != SynD`
struct SynD: Equatable { let e: Eqo }
func != (a: SynD?, b: SynD?) -> Bool { a?.e.v != b?.e.v }
func hetMember(_ a: SynA, _ b: SynA) -> Bool { a != b }
func hetFree(_ a: SynB, _ b: SynB) -> Bool { a != b }
func hetGeneric(_ a: SynF, _ b: SynF) -> Bool { a != b }
func hetSuper(_ a: SubH, _ b: SubH) -> Bool { a != b }
func hetField(_ a: Outer2, _ b: Outer2) -> Bool { a.a != b.a }
func cmpHet(_ a: CmpH, _ b: CmpH) -> Bool { a > b }
func eqHet(_ a: EqH, _ b: EqH) -> Bool { a != b }
func enumHet(_ a: SynE, _ b: SynE) -> Bool { a > b }
func heqEq(_ a: HEq, _ b: HEq) -> Bool { a == b }
func heqNe(_ a: HEq, _ b: HEq) -> Bool { a != b }
func heqArr(_ a: [HEq], _ b: [HEq]) -> Bool { a == b }
func heqHold(_ a: HHolder, _ b: HHolder) -> Bool { a == b }
func plainLt(_ a: PlainE, _ b: PlainE) -> Bool { a < b }
func plainEq(_ a: PlainQ, _ b: PlainQ) -> Bool { a == b }
func pgt(_ a: TP, _ b: TP) -> Bool { a > b }
func qne(_ a: TQ, _ b: TQ) -> Bool { a != b }
func optFree(_ a: SynD, _ b: SynD) -> Bool { a != b }
"""#

    /// v0.40.13 charged these — 3cc78e7 lost them (R1270). A must-not-lose list.
    static let releaseCharged = ["hetMember", "hetFree", "hetGeneric", "hetSuper", "hetField"]
    /// silent in v0.40.13 and 3cc78e7; executed Fs.
    static let residual = ["cmpHet", "eqHet", "enumHet", "heqEq", "heqNe", "heqArr", "heqHold", "plainLt", "plainEq"]
    static let controls = ["pgt", "qne", "optFree"]

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

    func testADifferentRightHandOperatorDoesNotAnswerSelfComparedWithSelf() throws {
        let on = try rows()
        for fn in Self.releaseCharged + Self.residual {
            XCTAssertEqual(on[fn], ["Fs"], "\(fn): the witness runs (executed) — got \(on[fn] ?? [])")
        }
    }

    /// The kill switches reproduce the silences — the fixture reaches the code it pins.
    func testTheKillSwitchesReproduceTheSilences() throws {
        let r1270 = try rows(env: ["CANDOR_R1270_OFF": "1"]), r1272 = try rows(env: ["CANDOR_R1272_OFF": "1"])
        for fn in Self.releaseCharged + ["cmpHet", "eqHet", "heqEq", "heqHold"] {
            XCTAssertNil(r1270[fn], "\(fn): CANDOR_R1270_OFF=1 must reproduce 3cc78e7's silent row")
        }
        XCTAssertEqual(r1270["pgt"], ["Fs"], "CANDOR_R1270_OFF=1 must reproduce the R1259 over-charge")
        for fn in ["enumHet", "plainLt", "plainEq"] { XCTAssertNil(r1272[fn], "\(fn): CANDOR_R1272_OFF=1 is silent") }
    }

    func testAProtocolExtensionOperatorAnswersInsteadOfTheWitness() throws {
        let on = try rows()
        for fn in Self.controls { XCTAssertNil(on[fn], "\(fn): no witness runs (executed) — got \(on[fn] ?? [])") }
    }
}
