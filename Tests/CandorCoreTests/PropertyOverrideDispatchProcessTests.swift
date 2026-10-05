import XCTest
import Foundation
@testable import CandorCore

/// VEIN C — SOUNDNESS R903 and R876: a property or subscript READ through a class- or protocol-typed
/// receiver now reaches a SUBCLASS's override, as a method call already did (R867's in-scan twin, one
/// member kind over).
///
/// `b.pv` with `b: BaseP` runs `SubP.pv` when the value is a `SubP`; the accessor edge loop climbed UP
/// `supertypesOf` only, so the read was ABSENT (`deny Fs` 0) while `b.m()` — the method twin — was charged.
/// And `h.qv` with `h: HasQ` edged the DIRECT conformer `BaseQ.qv` alone, missing `SubQ: BaseQ`'s override
/// (R876, settled SILENT by execution). Both are PRECISE-OR-NOTHING and ADDITIVE: only real ACCESSOR units
/// are edged — never a subclass METHOD sharing the name, never a method's default-argument unit (which
/// carries the method's qual) — and nothing the release edged is removed.
///
/// EXECUTED: this exact source, compiled with `swiftc` and run (`swiftagent-veinsDC/fxC/T`): every override
/// below wrote its marker; `readSuperP` (a `super.` read) and `callUseHelperN` (an extension-only member)
/// did not. v0.39.3 (2111a54) and 344b57b read every defect cell 0.
final class PropertyOverrideDispatchProcessTests: XCTestCase {
    static let source = #"""
import Foundation
func mark(_ p: String) { _ = FileManager.default.createFile(atPath: "/tmp/vc_" + p, contents: nil) }
// N1 / R903 — class computed property, subclass override
open class BaseP { public init() {}; open var pv: Int { 0 } }
public final class SubP: BaseP { public override var pv: Int { mark("pv"); return 1 } }
public func readBaseP(_ b: BaseP) -> Int { b.pv }
public func callReadP() -> Int { readBaseP(SubP()) }
// subscript twin
open class BaseS { public init() {}; open subscript(i: Int) -> Int { 0 } }
public final class SubS: BaseS { public override subscript(i: Int) -> Int { mark("sub"); return 1 } }
public func readBaseS(_ b: BaseS) -> Int { b[0] }
public func callReadS() -> Int { readBaseS(SubS()) }
// R876 — protocol property, the direct conformer pure, its SUBCLASS overrides
public protocol HasQ { var qv: Int { get } }
open class BaseQ: HasQ { public init() {}; open var qv: Int { 0 } }
public final class SubQ: BaseQ { public override var qv: Int { mark("qv"); return 1 } }
public func readHasQ(_ h: HasQ) -> Int { h.qv }
public func callReadQ() -> Int { readHasQ(SubQ()) }
public protocol HasR { subscript(i: Int) -> Int { get } }
open class BaseR: HasR { public init() {}; open subscript(i: Int) -> Int { 0 } }
public final class SubR: BaseR { public override subscript(i: Int) -> Int { mark("rsub"); return 1 } }
public func readHasR(_ h: HasR) -> Int { h[0] }
public func callReadR() -> Int { readHasR(SubR()) }
// N2 — implicit-self read of a requirement inside the protocol's extension
public protocol CtxN { var envN: [String: String] { get } }
extension CtxN { public func ddfN() -> Int { envN.count } }
public final class MainCtxN: CtxN { public init() {}; public lazy var envN = ProcessInfo.processInfo.environment }
public func callDdfN() -> Int { MainCtxN().ddfN() }
// CONTROLS — must stay uncharged
public final class SibP: BaseP {}                                   // does not override
public func readSibP(_ b: SibP) -> Int { b.pv }                     // static type has no overriding subtype
open class SuperP: BaseP { public override var pv: Int { super.pv + 2 } }   // super. is static dispatch
public func readSuperP(_ b: SuperP) -> Int { b.pv }
public protocol PlainN { var plainN: Int { get } }
extension PlainN { public var helperN: Int { 3 } }
public final class ConfN: PlainN { public init() {}; public var plainN: Int { 0 }; public var helperN: Int { mark("helper"); return 9 } }
extension PlainN { public func useHelperN() -> Int { helperN } }   // extension member: static, ConfN.helperN never runs
public func callUseHelperN() -> Int { ConfN().useHelperN() }
// CONTROL — a subclass METHOD sharing the property's base name never runs on a property read (Alamofire's
// `var task` beside `override func task(for:using:)`)
open class BaseM { public init() {}; open var tk: Int { 0 } }
public final class SubM: BaseM { public func tk(_ x: Int) -> Int { mark("tkm"); return x } }
public func readBaseM(_ b: BaseM) -> Int { b.tk }
"""#

    private func gate(_ root: URL, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
    }

    func testOverridesAreReachedAndControlsStayClean() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        // The defect cells — the unit AND its caller (names are not prefixes of each other: R909).
        for p in ["deny Fs readBaseP", "deny Fs callReadP", "deny Fs readBaseS", "deny Fs callReadS",
                  "deny Fs readHasQ", "deny Fs callReadQ", "deny Fs readHasR", "deny Fs callReadR"] {
            XCTAssertEqual(try gate(root, p), 1, "`\(p)` must fail: the override really runs (executed)")
            // §1b — the kill switch restores 344b57b, so each cell is shown able to fail.
            XCTAssertNotEqual(try gate(root, p, env: ["CANDOR_VEINC_OFF": "1"]), 1, "`\(p)` under CANDOR_VEINC_OFF")
        }
        // The controls — each executed and NOT performing the effect. A must-PASS arm is `!= 1` (R706's
        // harness note: under `swift test` a non-violating gate may exit 2).
        for p in ["deny Fs readSibP",        // static type has no overriding subtype
                  "deny Fs readSuperP",      // `super.pv` is static dispatch
                  "deny Fs SuperP.pv",
                  "deny Fs readBaseM",       // a subclass METHOD `tk(_:)` beside `var tk` never runs on a read
                  "deny Fs callUseHelperN", "deny Fs PlainN.useHelperN"] {   // extension-only: static
            XCTAssertNotEqual(try gate(root, p), 1, "`\(p)` must stay clean — the effect never executes")
        }
        // RECORDED, NOT CHANGED HERE (a different mechanism, priced separately): an implicit-self read of a
        // requirement inside `extension CtxN`, used as the BASE of a member access, still reaches no
        // conformer. Asserted as it is so a change is seen.
        XCTAssertNotEqual(try gate(root, "deny Env CtxN.ddfN"), 1, "N2 is out of this change's scope")
    }
}
