import XCTest
import Foundation

/// SOUNDNESS R1498 — a tuple-valued expression typed nothing unless it was an annotated local or a parameter, so a call
/// on one of its elements was DROPPED: `let t = (A(), 1); t.0.eff()`, labelled slots, a tuple-typed field (`l.tup.0`,
/// `self.tup.0`, bare `tup.0`), a tuple-returning call (`mkPair().0`, `let p = mkPair()`), a copy (`let t = l.tup`) and a
/// destructuring of any of them (`let (x, _) = l.tup`). EXECUTED: every `t…` caller writes the marker; the `k…` controls
/// call the same method on the OTHER (pure) slot and write nothing. Residual, not fixed: `for (a, _) in xs` over
/// `xs: [(Loud, Int)]` (`tForIn`, a container of tuples).
final class TupleSlotProcessTests: XCTestCase {
    static let src = """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1498-" + s, contents: nil) }
struct Loud { func eff() { mark("x") } }
struct Quiet { func eff() { } }
final class L {
    var tup: (Loud, Int) = (Loud(), 1)
    var tl: (a: Loud, n: Int) = (a: Loud(), n: 1)
    var mixed: (Quiet, Loud) = (Quiet(), Loud())
    func selfTup() { self.tup.0.eff() }
    func bareTup() { tup.0.eff() }
}
func mkPair() -> (Loud, Quiet) { (Loud(), Quiet()) }
func mkLabelled() -> (a: Loud, b: Quiet) { (a: Loud(), b: Quiet()) }
func tLit() { let t = (Loud(), 1); t.0.eff() }
func tLitLab() { let t = (a: Loud(), n: 1); t.a.eff() }
func tField(_ l: L) { l.tup.0.eff() }
func tFieldLab(_ l: L) { l.tl.a.eff() }
func tFieldLab0(_ l: L) { l.tl.0.eff() }
func tDestr() { let (a, _) = (Loud(), Quiet()); a.eff() }
func tDestrField(_ l: L) { let (x, _) = l.tup; x.eff() }
func tDestrRet() { let (x, _) = mkPair(); x.eff() }
func tRetIdx() { mkPair().0.eff() }
func tRetLab() { mkLabelled().a.eff() }
func tRetBind() { let p = mkPair(); p.0.eff() }
func tVarDestr() { var (a, b) = (Loud(), 2); b += 1; a.eff() }
func tCopy(_ l: L) { let t = l.tup; t.0.eff() }
func tParam(_ t: (Loud, Int)) { t.0.eff() }
func tParamLab(_ t: (a: Loud, n: Int)) { t.a.eff() }
func tForIn(_ xs: [(Loud, Int)]) { for (a, _) in xs { a.eff() } }
func tSelf(_ l: L) { l.selfTup() }
func tBare(_ l: L) { l.bareTup() }
func tMixed1(_ l: L) { l.mixed.1.eff() }
// CONTROLS (pure: the element at that index is Quiet)
func kMixed0(_ l: L) { l.mixed.0.eff() }
func kLit1() { let t = (Loud(), Quiet()); t.1.eff() }
func kDestr() { let (_, b) = (Loud(), Quiet()); b.eff() }
func kRet1() { mkPair().1.eff() }
func kRetLabB() { mkLabelled().b.eff() }
let l = L()
func seen() -> Bool { let r = FileManager.default.fileExists(atPath: "/tmp/r1498-x"); try? FileManager.default.removeItem(atPath: "/tmp/r1498-x"); return r }
_ = seen()
let cases: [(String, () -> Void)] = [("tLit", tLit), ("tLitLab", tLitLab), ("tField", { tField(l) }), ("tFieldLab", { tFieldLab(l) }),
  ("tFieldLab0", { tFieldLab0(l) }), ("tDestr", tDestr), ("tDestrField", { tDestrField(l) }), ("tDestrRet", tDestrRet),
  ("tRetIdx", tRetIdx), ("tRetLab", tRetLab), ("tRetBind", tRetBind), ("tVarDestr", tVarDestr), ("tCopy", { tCopy(l) }),
  ("tParam", { tParam((Loud(), 1)) }), ("tParamLab", { tParamLab((a: Loud(), n: 1)) }), ("tForIn", { tForIn([(Loud(), 1)]) }),
  ("tSelf", { tSelf(l) }), ("tBare", { tBare(l) }), ("tMixed1", { tMixed1(l) }),
  ("kMixed0", { kMixed0(l) }), ("kLit1", kLit1), ("kDestr", kDestr), ("kRet1", kRet1), ("kRetLabB", kRetLabB)]
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

    func testATupleSlotCarriesItsElementType() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        let charged = ["tLit", "tLitLab", "tField", "tFieldLab", "tFieldLab0", "tDestr", "tDestrField", "tDestrRet", "tRetIdx",
                       "tRetLab", "tRetBind", "tVarDestr", "tCopy", "tParam", "tParamLab", "tSelf", "tBare", "tMixed1"]
        for fn in charged {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes the marker (executed) — \(by[fn] ?? [:])")
        }
        for fn in ["kMixed0", "kLit1", "kDestr", "kRet1", "kRetLabB"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, fn), "\(fn) calls the pure slot (executed: no marker)")
        }
        let off = try scan(root, env: ["CANDOR_R1498_OFF": "1"])
        for fn in ["tLit", "tField", "tRetIdx", "tDestrField", "tCopy"] {
            XCTAssertNil(ProcessHarness.inferred(off, fn), "the release was silent: \(fn) \(off[fn] ?? [:])")
        }
        XCTAssertEqual(try gate(root, "deny Fs tField\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs tField\n", env: ["CANDOR_R1498_OFF": "1"]), 0)
        XCTAssertEqual(try gate(root, "deny Fs kMixed0\n"), 0)
    }
}
