import XCTest
import Foundation

/// SOUNDNESS R1514 — A PARAMETER OR BINDER THE TYPED LOCAL INDEXES DO NOT RECORD READ A SAME-NAMED GLOBAL. The lazy-global
/// read edge skipped a bare name only when `vars`, a container map or `literalLocals` held it, so a parameter typed
/// `X.Type` / `P & Q` / `Any.Type`, a `for` loop variable, a `while let` binder and a `catch let` binder each edged to a
/// file-scope `let t = …` and inherited its initializer's effects. The program below was EXECUTED: every `s…` function
/// wrote nothing; every `g…` function forced its global's initializer (markers: gv t u).
final class GlobalReadShadowProcessTests: XCTestCase {

    static let files: [String: String] = [
        "Globals.swift": """
import Foundation
// Not main.swift: these globals are LAZY, so the initializer runs at first read — the effect under test.
func mark(_ s: String) -> Int { FileManager.default.createFile(atPath: "/tmp/r1514-" + s, contents: nil); return 1 }
let t: Int = mark("t")
let gv: Int = mark("gv")
let u: Int = mark("u")
""",
        "Cases.swift": """
protocol PP {}
protocol QQ {}
struct Quiet: PP, QQ {}
struct Err: Error {}
func thr() throws { throw Err() }
// shadows: each `t` is a parameter or binder
func sParamMeta(_ t: Quiet.Type) { _ = t }
func sParamComp(_ t: PP & QQ) { _ = t }
func sParamAnyType(_ t: Any.Type) { _ = t }
func sParamMetaGeneric<T>(_ t: T.Type) { _ = t }
func sFor() { for t in [1, 2] { _ = t } }
func sWhileLet(_ a: [Int]) { var it = a.makeIterator(); while let t = it.next() { _ = t } }
func sCatch() { do { try thr() } catch let t { _ = t } }
// real reads of a global: each must keep its edge
func gRead() { _ = gv }
func gOtherGlobalAlongsideParam(_ t: Quiet.Type) { _ = t; _ = gv }
func gClosureAlongsideParam(_ t: Quiet.Type) { let c = { _ = gv }; c(); _ = t }
func gUParamT(_ t: Quiet.Type) { _ = u; _ = t }
func gAfterFor() { for t in [1] { _ = t }; _ = t }
func gAfterBlock(_ c: Bool) { if c { let gv = 1; _ = gv }; _ = gv }
func gAfterClosureParam() { [1].forEach { t in _ = t }; _ = t }
func gAfterLocalFunc() { func g(_ t: Quiet.Type) { _ = t }; g(Quiet.self); _ = t }
func gAfterCatch() { do { try thr() } catch let t { _ = t }; _ = t }
""",
        "main.swift": """
sParamMeta(Quiet.self); sParamComp(Quiet()); sParamAnyType(Int.self); sParamMetaGeneric(Int.self)
sFor(); sWhileLet([1]); sCatch()
gRead(); gOtherGlobalAlongsideParam(Quiet.self); gClosureAlongsideParam(Quiet.self); gUParamT(Quiet.self)
gAfterFor(); gAfterBlock(true); gAfterClosureParam(); gAfterLocalFunc(); gAfterCatch()
"""
    ]
    static let shadows = ["sParamMeta", "sParamComp", "sParamAnyType", "sParamMetaGeneric", "sFor", "sWhileLet", "sCatch"]
    static let reads = ["gRead", "gOtherGlobalAlongsideParam", "gClosureAlongsideParam", "gUParamT", "gAfterFor",
                        "gAfterBlock", "gAfterClosureParam", "gAfterLocalFunc", "gAfterCatch"]

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

    func testAParameterOrBinderInScopeIsNeverASameNamedGlobal() throws {
        let root = try ProcessHarness.makeFilesPackage(Self.files)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in Self.shadows {
            XCTAssertNil(ProcessHarness.chargedNothing(by, fn), "\(fn) reads its own binding (executed: no marker)")
        }
        for fn in Self.reads {
            XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) forces a global's initializer (executed) — \(by[fn] ?? [:])")
        }
        let off = try scan(root, env: ["CANDOR_R1514_OFF": "1"])
        for fn in Self.shadows {
            XCTAssertEqual(ProcessHarness.inferred(off, fn), ["Fs"], "the release fabricated the global onto \(fn)")
        }
        XCTAssertEqual(try gate(root, "deny Fs sFor\n"), 0)
        XCTAssertEqual(try gate(root, "deny Fs sFor\n", env: ["CANDOR_R1514_OFF": "1"]), 1)
        XCTAssertEqual(try gate(root, "deny Fs gAfterFor\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs gClosureAlongsideParam\n"), 1)
    }
}
