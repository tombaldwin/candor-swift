import XCTest
import Foundation

/// SOUNDNESS R1480 — an IMPLICIT MEMBER in a position R999 did not read the contextual type of.
///
/// R999 resolved `.now()` only where it IS the argument / initializer / return value. Every shape below EXECUTES the
/// clock read (`swiftagent-ab/fx/A1`, `swift run`: each `sNN` returns a value > 1e9 that only `Date()` produces) and
/// every one but the plain-argument / optional / static-var four was ABSENT on 0.41.3 and lane/swift-r1472 8bad2b8,
/// while the spelled `Deadline.now()` twin was charged. `s01` is swift-nio's
/// `SelectableEventLoop.scheduleTask(in:)` — `scheduleTask(deadline: .now() + in, task)`. `s13` (a closure's
/// return) stays DISCLOSED (`callback:f` Unknown), not resolved: no position here writes the closure's type.
/// `c01`-`c03` are the controls: the same positions over a PURE static member (executed: small values).
final class ImplicitMemberPositionAndOwnBoundProcessTests: XCTestCase {
    static let implicitSource = #"""
import Foundation
struct Deadline: Comparable {
  let t: Double
  static func now() -> Deadline { Deadline(t: Date().timeIntervalSince1970) }
  static var current: Deadline { Deadline(t: Date().timeIntervalSince1970) }
  static let zero = Deadline(t: 0)
  static func pure() -> Deadline { Deadline(t: 1) }
  static func + (l: Deadline, r: Double) -> Deadline { Deadline(t: l.t + r) }
  static func - (l: Deadline, r: Deadline) -> Double { l.t - r.t }
  static func < (l: Deadline, r: Deadline) -> Bool { l.t < r.t }
  func advanced(by d: Double) -> Deadline { Deadline(t: t + d) }
}
func schedule(deadline: Deadline) -> Double { deadline.t }
func scheduleOpt(deadline: Deadline?) -> Double { deadline?.t ?? 0 }
func schedDefault(deadline: Deadline = .now()) -> Double { deadline.t }
func takeClosure(_ f: () -> Deadline) -> Double { f().t }
final class Loop { func schedule(deadline: Deadline) -> Double { deadline.t } }
let L = Loop()
var gd = Deadline(t: 0)
func s01(_ d: Double) -> Double { schedule(deadline: .now() + d) }               // operand in arg
func s02(_ d: Double) -> Double { let x: Deadline = .now() + d; return x.t }       // operand in annotated binding
func s03(_ d: Double) -> Deadline { return .now() + d }                            // operand in return
func s04() -> Double { schedule(deadline: .now()) }                                // plain arg (R999)
func s05() -> Double { schedDefault() }                                            // default argument
func s06(_ c: Bool) -> Double { schedule(deadline: c ? .now() : .zero) }           // ternary
func s07() -> Double { let x: Deadline? = .now(); return x?.t ?? 0 }               // optional annotation
func s08() -> Double { schedule(deadline: .now().advanced(by: 1)) }                // implicit member chain
func s09() -> Double { let xs: [Deadline] = [.now()]; return xs[0].t }             // array literal
func s10(_ d: Double) -> Double { gd = .now() + d; return gd.t }                   // assignment operand
func s11(_ x: Deadline) -> Bool { x < .now() }                                     // comparison operand
func s12(_ x: Deadline?) -> Double { (x ?? .now()).t }                             // ?? operand
func s13() -> Double { takeClosure { .now() } }                                    // closure return
func s14(_ d: Double) -> Double { L.schedule(deadline: .now() + d) }               // member callee
func s15() -> Double { scheduleOpt(deadline: .now()) }                             // optional param
func s16() -> Double { schedule(deadline: .current) }                              // static var
func s17(_ x: Deadline) -> Double { x - .now() }                                   // rhs operand, heterogeneous result
func s18() -> Double { (.now() as Deadline).t }                                    // as-cast
func s19(_ d: Double) -> Double { schedule(deadline: (.now() + d)) }               // parenthesised operand
func s20() -> Double { schedule(deadline: .current + 1) }                          // static var operand
// controls: pure
func c01(_ d: Double) -> Double { schedule(deadline: .pure() + d) }
func c02(_ d: Double) -> Double { schedule(deadline: .zero + d) }
func c03(_ x: Deadline) -> Bool { x < .pure() }
"""#
    static let charged = (1...20).filter { $0 != 13 }.map { String(format: "s%02d", $0) }
    static let r999Already = ["s04", "s07", "s15", "s16"]
    static let pureControls = ["c01", "c02", "c03"]

    /// SOUNDNESS R1481 — a field typed by the type's generic parameter, read inside a CONSTRAINED extension, took
    /// whichever extension's `where Base:` clause was merged LAST. `swiftagent-ab/fx/B1`, executed: `cdNoParam` and
    /// `otherCD` write `/tmp/r1481-rx`; both were ABSENT on 0.41.3 / 8bad2b8 because `base` read as `NumberFormatter`
    /// (the last extension's bound). `cdValue` was charged only through a FALSE `Reactive.value` edge (the closure
    /// parameter named `value`, R1472 defect C) and is pinned here for the real edge. `pickerPure`, `otherPure` and
    /// `plainPure` are the controls (executed: no file).
    static let rxSource = #"""
import Foundation
public struct Reactive<Base> { public let base: Base; public init(_ b: Base) { base = b } }
public protocol ReactiveCompatible: AnyObject {}
extension ReactiveCompatible { public var rx: Reactive<Self> { Reactive(self) } }
extension Reactive where Base: AnyObject {
  func controlPropertyDefault<T>(editingEvents: Int = 0, getter: @escaping (Base) -> T, setter: @escaping (Base, T) -> Void) -> Int {
    FileManager.default.createFile(atPath: "/tmp/r1481-rx", contents: nil); return 0
  }
  func pureHelper() -> Int { 7 }
}
public final class Picker: ReactiveCompatible { public var d = 0.0; public init() {} }
public final class Other: ReactiveCompatible { public var d = 0.0; public init() {} }   // a non-NSObject ReactiveCompatible
extension Reactive {
  public var plainPure: Int { 3 }                                                   // CONTROL: no clause on Base
}
extension Reactive where Base: Other {
  public var otherCD: Int { base.rx.controlPropertyDefault(getter: { p in p.d }, setter: { p, v in p.d = v }) }
  public var otherPure: Int { base.rx.pureHelper() }                                // CONTROL: `.rx` member, pure
}
extension Reactive where Base: Picker {
  // the RxSwift `countDownDuration` shape: the effect is behind `base.rx.<member>(…)` on a generic `Base`
  public var cdValue: Int { base.rx.controlPropertyDefault(getter: { p in p.d }, setter: { p, value in p.d = value }) }
  public var cdNoParam: Int { base.rx.controlPropertyDefault(getter: { p in p.d }, setter: { p, v in p.d = v }) }
  public var pickerPure: Int { base.rx.pureHelper() }                               // CONTROL: `.rx` member, pure
}
extension Reactive where Base: Picker {
  public var value: Int { FileManager.default.createFile(atPath: "/tmp/r1481-rx-value", contents: nil); return 1 }
}
extension NSObject: ReactiveCompatible {}
extension Reactive where Base: NumberFormatter {
  // Base constrained to a PLATFORM class (RxSwift: `Base: UIDatePicker`) — the LAST writer of the merged bound
  public var cdPlatform: Int { base.rx.controlPropertyDefault(getter: { p in p.zeroSymbol ?? "" }, setter: { p, value in p.zeroSymbol = value }) }
}
"""#

    private func rows(_ src: String, env: [String: String] = [:]) throws -> ([String: [String]], [String: Any]) {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": src], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        var out: [String: [String]] = [:]
        for case let f as [String: Any] in (d["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { out[n] = f["inferred"] as? [String] ?? [] }
        }
        return (out, d)
    }

    func testEveryImplicitMemberPositionIsCharged() throws {
        let (on, _) = try rows(Self.implicitSource)
        for fn in Self.charged { XCTAssertEqual(on[fn], ["Clock"], "\(fn): executes the clock read — got \(on[fn] ?? [])") }
        XCTAssertEqual(on["schedDefault"], ["Clock"], "a default `= .now()` is charged where a spelled default is")
        for fn in Self.pureControls { XCTAssertNil(on[fn], "\(fn): a PURE implicit member must stay uncharged") }
        XCTAssertEqual(on["s13"], ["Unknown"], "the closure-return position stays disclosed")
    }

    /// The kill switch reproduces the release's silences — the fixture reaches the code it pins.
    func testR1480KillSwitchReproducesTheSilences() throws {
        let (off, _) = try rows(Self.implicitSource, env: ["CANDOR_R1480_OFF": "1"])
        for fn in Self.charged where !Self.r999Already.contains(fn) { XCTAssertNil(off[fn], "\(fn): silent with R1480 off") }
        for fn in Self.r999Already { XCTAssertEqual(off[fn], ["Clock"], "\(fn): R999 already charged it") }
    }

    func testAGenericFieldTakesItsOwnExtensionsBound() throws {
        let (on, _) = try rows(Self.rxSource)
        for fn in ["Reactive.cdNoParam", "Reactive.otherCD", "Reactive.cdValue"] {
            XCTAssertEqual(on[fn], ["Fs"], "\(fn): writes the file (executed) — got \(on[fn] ?? [])")
        }
        for fn in ["Reactive.pickerPure", "Reactive.otherPure", "Reactive.plainPure"] {
            XCTAssertNil(on[fn], "\(fn): pure (executed) — must stay uncharged")
        }
        // R1485 OFF as well: with R1481 off `base` reads the merged bound `NumberFormatter`, a platform class, and R1485
        // then reaches the same `.rx` helper through it — right answer, wrong reason, which would hide R1481's own row.
        let (off, _) = try rows(Self.rxSource, env: ["CANDOR_R1481_OFF": "1", "CANDOR_R1485_OFF": "1"])
        for fn in ["Reactive.cdNoParam", "Reactive.otherCD"] { XCTAssertNil(off[fn], "\(fn): silent with R1481 off") }
    }

    /// An implicit `.init()` in a position only R1480 reads is a CONSTRUCTOR call: it must not edge a subclass's `init`
    /// (executed `swiftagent-ab/fx/E`: `useDefault()` runs `Obs.init` only; `Del.init` never runs). The R999 return
    /// position keeps the release's `Obs.init()` walk (`implicitInit`, charged on 0.41.3 — a pre-existing over-charge).
    func testAnImplicitInitInAnR1480PositionIsTheConstructorCall() throws {
        let src = #"""
import Foundation
class Obs { init() {} ; init(x: Int) {} }
final class Del: Obs { override init() { _ = Date(); super.init() } }
func implicitInit() -> Obs { .init() }
func takeObs(_ o: Obs = .init()) -> Int { 0 }
func useDefault() -> Int { takeObs() }
"""#
        let (on, _) = try rows(src)
        XCTAssertNil(on["useDefault"], "the default `.init()` runs Obs.init only")
        XCTAssertNil(on["takeObs"], "the default `.init()` runs Obs.init only")
        XCTAssertEqual(on["implicitInit"], ["Clock"], "R999's own position keeps the release's reading")
    }

    /// A field the DECLARATION's own bound types keeps that typing: `Att<Node: SP>` read in `where Node == NS` stays an
    /// `SP` read, which reaches `SP.parent` (a concrete `NS: NP, NP: SP` receiver does not climb to an inherited
    /// protocol's extension property — measured on swift-syntax `Attached.localNameDescription` in this lane's A/B).
    func testADeclarationBoundFieldIsNotNarrowed() throws {
        let src = #"""
import Foundation
public protocol SP { }
extension SP { public var parent: Int? { FileManager.default.createFile(atPath: "/tmp/r1481-c", contents: nil); return nil } }
public protocol NP: SP {}
public struct NS: NP, Hashable { public var name: String { "n" } }
public struct Att<Node: SP> { let node: Node }
extension Att where Node == NS {
  var desc: Int? { var a = node.parent; a = nil; return a }
}
"""#
        let (on, _) = try rows(src)
        XCTAssertEqual(on["Att.desc"], ["Fs"], "the declaration-bound read must keep reaching SP.parent")
    }
}
