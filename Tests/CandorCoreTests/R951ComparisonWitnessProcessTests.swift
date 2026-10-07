import XCTest
import Foundation

/// SOUNDNESS R951 — a generic or synthesized comparison that reaches a USER-DEFINED witness.
///
/// EXECUTED (`swiftagent-verify/genA`/`genB`/`genC`, re-run in `swiftagent-r910/r951`): every comparison
/// below writes a file through `Noisy.==`. The release charged none of them (`compareStorage` in genB only
/// through the alias-table coincidence vein A(i)'s N-d removed). They now resolve to the witness of the type
/// actually compared — its generic arguments, a synthesized type's stored properties, or the caller's
/// instantiation of a generic parameter — and nothing is unioned over the package's witnesses.
final class R951ComparisonWitnessProcessTests: XCTestCase {
    static let source = #"""
import Foundation
public struct Tiny<Element> {
    enum Storage { case one(Element); case many([Element]) }
    var storage: Storage
}
extension Tiny: Equatable where Element: Equatable {}
extension Tiny.Storage: Equatable where Element: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.one(let l), .one(let r)): return l == r
        case (.many(let l), .many(let r)): return l == r
        default: return false
        }
    }
}
struct Noisy: Equatable {
    var v: Int
    static func == (lhs: Noisy, rhs: Noisy) -> Bool {
        FileManager.default.createFile(atPath: "/tmp/r951-\(lhs.v)", contents: nil)
        return lhs.v == rhs.v
    }
}
struct Quiet: Equatable { var v: Int; static func == (a: Quiet, b: Quiet) -> Bool { a.v == b.v } }
struct Pair: Equatable { var n: Noisy; var k: Int }
func compareTyped(_ a: Tiny<Noisy>, _ b: Tiny<Noisy>) -> Bool { a == b }
func compareStorage(_ a: Tiny<Noisy>.Storage, _ b: Tiny<Noisy>.Storage) -> Bool { a == b }
func eq<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
func callEq() -> Bool { eq(Noisy(v: 3), Noisy(v: 3)) }
func arrEq(_ a: [Noisy], _ b: [Noisy]) -> Bool { a == b }
func optNe(_ a: Noisy?, _ b: Noisy?) -> Bool { a != b }
func pairEq(_ a: Pair, _ b: Pair) -> Bool { a == b }
func localArr() -> Bool { let a: [Noisy] = [Noisy(v: 5)]; let b: [Noisy] = [Noisy(v: 5)]; return a == b }
// CONTROLS — must stay pure
func quietTiny(_ a: Tiny<Quiet>, _ b: Tiny<Quiet>) -> Bool { a == b }
func callEqQuiet() -> Bool { eq(Quiet(v: 1), Quiet(v: 1)) }
func ints(_ a: [Int], _ b: [Int]) -> Bool { a == b }
// the N-d shape: an unrelated alias named like a generic parameter must not supply a witness
struct Loud: Equatable { static func == (a: Loud, b: Loud) -> Bool { _ = FileManager.default.createFile(atPath: "/tmp/r951-loud", contents: nil); return true } }
struct Holder { typealias Element = Loud }
public struct Box<Element: Equatable> { var x: Element; func same(_ y: Element) -> Bool { x == y } }
func boxQuiet() -> Bool { Box(x: Quiet(v: 1)).same(Quiet(v: 1)) }
"""#

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

    func testComparisonsReachTheComparedTypesWitness() throws {
        let on = try rows(), off = try rows(env: ["CANDOR_R951_OFF": "1"])
        for fn in ["compareTyped", "compareStorage", "callEq", "arrEq", "optNe", "pairEq", "localArr"] {
            XCTAssertEqual(on[fn], ["Fs"], "\(fn): runs Noisy.== (executed)")
            XCTAssertNil(off[fn], "\(fn): CANDOR_R951_OFF=1 must reproduce the silent row (§1b)")
        }
    }

    func testNothingIsUnionedOverThePackagesWitnesses() throws {
        let on = try rows()
        for fn in ["quietTiny", "callEqQuiet", "ints", "boxQuiet", "eq", "Box.same"] {
            XCTAssertNil(on[fn], "\(fn): no comparison here reaches an effectful witness")
        }
    }
}
