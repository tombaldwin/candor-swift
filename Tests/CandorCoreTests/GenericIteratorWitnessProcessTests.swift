import XCTest
import Foundation

/// SOUNDNESS R1515 — A GENERIC ITERATOR WRAPPER RUNS ITS CALLER'S ITERATOR. `struct W1<Base: Sequence> { struct It1 { var
/// iterator: Base.Iterator; mutating func next() { iterator.next() } } }` and `W1<LoudSeq>.It1(…).next()`: the program ran
/// `LoudSeq.It.next` and nothing was charged. Three routes, each its own kill switch:
///   (A) `CANDOR_R1515A_OFF` — iterating a local sequence whose iterator is a NESTED type sharing its simple name with
///       another type's (`LoudSeq.It` beside `PureSeq.It`) edged the ambiguous `It.next` and resolved nothing;
///   (B) `CANDOR_R1515B_OFF` — a stored (or local) `Base.Iterator`, `Base.Iterator?` or `[Base.Iterator]` records the
///       caller-witness requirement `s<k>^Iterator@<Owner>`, answered at each call site whose receiver is an instance of
///       `Owner` with known arguments, including an implicit iteration and a nested `Sq<Sq<LoudSeq>>`;
///   (T) `CANDOR_R1515T_OFF` — `W1<LoudSeq>.It1(…)` constructs the nested `W1.It1` (it was untyped, the call dropped).
/// EXECUTED (`~/candor-handoff/swift-r1515/fx/V`): every `…L` function wrote the marker, every `…P` control wrote nothing.
final class GenericIteratorWitnessProcessTests: XCTestCase {

    static let main = """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1515-" + s, contents: nil) }
struct LoudSeq: Sequence { struct It: IteratorProtocol { var n = 0; mutating func next() -> Int? { mark("it"); n += 1; return n > 2 ? nil : n } }; func makeIterator() -> It { It() } }
struct PureSeq: Sequence { struct It: IteratorProtocol { var n = 0; mutating func next() -> Int? { n += 1; return n > 2 ? nil : n } }; func makeIterator() -> It { It() } }
struct W1<Base: Sequence> { struct It1: IteratorProtocol { var iterator: Base.Iterator; mutating func next() -> Base.Element? { iterator.next() } } }
struct It1b<Base: Sequence>: IteratorProtocol { var iterator: Base.Iterator; mutating func next() -> Base.Element? { iterator.next() } }
struct Sq<Base: Sequence>: Sequence { var base: Base; func makeIterator() -> Iterator { Iterator(iterator: base.makeIterator()) }
  struct Iterator: IteratorProtocol { var iterator: Base.Iterator; mutating func next() -> Base.Element? { iterator.next() } } }
struct W2<Base: Sequence> { var base: Base; func f() { var it = base.makeIterator(); _ = it.next() } }
struct It6<Base: Sequence>: IteratorProtocol { var iterator: Base.Iterator?; mutating func next() -> Base.Element? { iterator?.next() } }
struct It7<Base: Sequence>: IteratorProtocol { var its: [Base.Iterator]; mutating func next() -> Base.Element? { its[0].next() } }
struct W11<Base: Sequence> { var base: Base; func f() { var it: Base.Iterator = base.makeIterator(); _ = it.next() } }
enum NS { struct Seq: Sequence { struct It: IteratorProtocol { mutating func next() -> Int? { mark("ns"); return nil } }; var xs: [Int]; init(_ xs: [Int]) { self.xs = xs }; init() { self.init([]) }; func makeIterator() -> It { It() } } }
func nsForL() { for _ in NS.Seq() { } }
func forL() { for _ in LoudSeq() { } }
func forP() { for _ in PureSeq() { } }
func arrL() { _ = Array(LoudSeq()) }
func arrP() { _ = Array(PureSeq()) }
func w1L() { var i = W1<LoudSeq>.It1(iterator: LoudSeq().makeIterator()); _ = i.next() }
func w1P() { var i = W1<PureSeq>.It1(iterator: PureSeq().makeIterator()); _ = i.next() }
func w1annL() { var i: W1<LoudSeq>.It1 = W1<LoudSeq>.It1(iterator: LoudSeq().makeIterator()); _ = i.next() }
func w1annP() { var i: W1<PureSeq>.It1 = W1<PureSeq>.It1(iterator: PureSeq().makeIterator()); _ = i.next() }
func it1bL() { var i = It1b<LoudSeq>(iterator: LoudSeq().makeIterator()); _ = i.next() }
func it1bP() { var i = It1b<PureSeq>(iterator: PureSeq().makeIterator()); _ = i.next() }
func sqForL() { for _ in Sq(base: LoudSeq()) { } }
func sqForP() { for _ in Sq(base: PureSeq()) { } }
func sqItL() { var i = Sq(base: LoudSeq()).makeIterator(); _ = i.next() }
func sqItP() { var i = Sq(base: PureSeq()).makeIterator(); _ = i.next() }
func sqSqL() { for _ in Sq(base: Sq(base: LoudSeq())) { } }
func sqSqP() { for _ in Sq(base: Sq(base: PureSeq())) { } }
func w2L() { W2(base: LoudSeq()).f() }
func w2P() { W2(base: PureSeq()).f() }
func it6L() { var i = It6<LoudSeq>(iterator: LoudSeq().makeIterator()); _ = i.next() }
func it6P() { var i = It6<PureSeq>(iterator: PureSeq().makeIterator()); _ = i.next() }
func it7L() { var i = It7<LoudSeq>(its: [LoudSeq().makeIterator()]); _ = i.next() }
func it7P() { var i = It7<PureSeq>(its: [PureSeq().makeIterator()]); _ = i.next() }
func w11L() { W11(base: LoudSeq()).f() }
func w11P() { W11(base: PureSeq()).f() }
nsForL(); forL(); forP(); arrL(); arrP(); w1L(); w1P(); w1annL(); w1annP(); it1bL(); it1bP(); sqForL(); sqForP(); sqItL(); sqItP()
sqSqL(); sqSqP(); w2L(); w2P(); it6L(); it6P(); it7L(); it7P(); w11L(); w11P()
"""
    static let viaA = ["forL", "arrL", "nsForL"]
    static let viaB = ["w1annL", "it1bL", "sqForL", "sqItL", "sqSqL", "w2L", "it6L", "it7L", "w11L"]
    static let viaT = ["w1L"]
    static let controls = ["forP", "arrP", "w1P", "w1annP", "it1bP", "sqForP", "sqItP", "sqSqP", "w2P", "it6P", "it7P", "w11P"]

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

    func testAGenericIteratorWrapperRunsItsCallersIterator() throws {
        let root = try ProcessHarness.makePackage(Self.main)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in Self.viaA + Self.viaB + Self.viaT {
            XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) runs LoudSeq.It.next (executed) — \(by[fn] ?? [:])")
        }
        for fn in Self.controls {
            XCTAssertFalse(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) iterates a pure sequence (executed: no marker)")
        }
        // `self.init([])` inside a NESTED sequence delegates to its own init: it does not iterate `self` (executed)
        XCTAssertNil(by.keys.first { $0.hasPrefix("NS.Seq.init") && ProcessHarness.inferred(by, $0)?.isEmpty == false })
        // each route is its own: off, its cells read as the release did
        let offA = try scan(root, env: ["CANDOR_R1515A_OFF": "1"])
        for fn in Self.viaA { XCTAssertFalse(ProcessHarness.inferred(offA, fn)?.contains("Fs") == true, "\(fn) under R1515A_OFF") }
        let offB = try scan(root, env: ["CANDOR_R1515B_OFF": "1"])
        for fn in Self.viaB { XCTAssertFalse(ProcessHarness.inferred(offB, fn)?.contains("Fs") == true, "\(fn) under R1515B_OFF") }
        let offT = try scan(root, env: ["CANDOR_R1515T_OFF": "1"])
        for fn in Self.viaT { XCTAssertFalse(ProcessHarness.inferred(offT, fn)?.contains("Fs") == true, "\(fn) under R1515T_OFF") }
        XCTAssertEqual(try gate(root, "deny Fs w1L\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs w1L\n", env: ["CANDOR_R1515_OFF": "1"]), 0)
        XCTAssertEqual(try gate(root, "deny Fs sqForL\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs sqForP\n"), 0)
    }
}
