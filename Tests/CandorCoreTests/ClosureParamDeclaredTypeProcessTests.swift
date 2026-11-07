import XCTest
import Foundation
import CandorCore

/// SOUNDNESS R1455 (ladder class T4, the closure-parameter and shorthand sub-tiers) — a closure parameter with no
/// annotation, passed to a callee this scan declares, was untyped, so every member call on it was R1455's
/// `droppedMember`: no edge, no `Unknown`. The callee's declared function type now types it exactly as the annotated
/// twin `{ (p: T) in … }` is typed.
///
/// The fixture is the one EXECUTED in `swiftagent-t4/fx/cp` (copy: `~/candor-handoff/tracka-r1/swift-t4/fixtures`):
/// every `t4*` function deleted its victim file and `deny Fs <fn>` exited 0 on the published v0.41.3 binary and 1 on
/// this change; every `a*` function is a shape where a naive inference names the WRONG type — the pure `Quiet.wipe`
/// runs (executed: the file survives) while an effectful same-named member sits on the type the naive reading picks.
/// `CANDOR_R1455T4_OFF` restores the release reading.
///
/// Harness note (R706): a must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class ClosureParamDeclaredTypeProcessTests: XCTestCase {
    private func scan(_ src: String, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        return try ProcessHarness.fns(ofJson: r.out)
    }
    private func gate(_ src: String, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let pf = root.appendingPathComponent("p.policy")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
    }
    private func inf(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["inferred"] as? [String] ?? []).sorted()
    }

    static let fixture = """
import Foundation

// ── the effectful and the pure same-named members ───────────────────────────────────────────────
struct Printer { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
struct Quiet { func wipe(_ p: String) { _ = p.count } }

// ── POSITIVE shapes: the callee declares the closure parameter's type ──────────────────────────
struct Host { func with(_ body: (Printer) -> Void) { body(Printer()) } }
func t4param(_ path: String) { Host().with { p in p.wipe(path) } }
func t4short(_ path: String) { Host().with { $0.wipe(path) } }
struct Host2 { mutating func withIndent(body: (inout Printer) -> Void) { var p = Printer(); body(&p) } }
func t4inout(_ path: String) { var h = Host2(); h.withIndent { p in p.wipe(path) } }
enum Maker { static func make(_ n: Int, _ f: (Printer) -> Void) { f(Printer()) } }
func t4static(_ path: String) { Maker.make(1) { p in p.wipe(path) } }
final class Box { init(_ f: (Printer) -> Void) { f(Printer()) } }
func t4init(_ path: String) { _ = Box { p in p.wipe(path) } }
final class Svc {
    func run(_ f: (Printer) -> Void) { f(Printer()) }
    func t4self(_ path: String) { run { p in p.wipe(path) } }
}
func around(_ f: (Printer) -> Void) { f(Printer()) }
func t4free(_ path: String) { around { p in p.wipe(path) } }
struct Host3 { func go(name: String, then: (Printer) -> Void) { then(Printer()) } }
func t4labeled(_ path: String) { Host3().go(name: "x", then: { p in p.wipe(path) }) }
struct Host4 { func pair(_ f: (Int, Printer) -> Void) { f(1, Printer()) } }
func t4second(_ path: String) { Host4().pair { _, p in p.wipe(path) } }
func t4secondShort(_ path: String) { Host4().pair { $1.wipe(path) } }
struct Host5 { func maybe(_ f: ((Printer) -> Void)?) { f?(Printer()) } }
func t4optional(_ path: String) { Host5().maybe { p in p.wipe(path) } }
struct Host8 { func esc(_ f: @escaping @Sendable (Printer) -> Void) { f(Printer()) } }
func t4escaping(_ path: String) { Host8().esc { p in p.wipe(path) } }

// ── ADVERSARIAL shapes: a naive inference picks the WRONG type ─────────────────────────────────
// A2 shadowing: the closure parameter shares an OUTER typed local's name; the callee types it Quiet.
struct Host6 { func withQuiet(_ f: (Quiet) -> Void) { f(Quiet()) } }
func a2shadow(_ path: String) { let p = Printer(); _ = p; Host6().withQuiet { p in p.wipe(path) } }
// A3 generic context: the written type is the type's generic parameter, and a local type has that name.
struct Element { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
struct Wrap<Element> { let e: Element; func use(_ f: (Element) -> Void) { f(e) } }
func a3generic(_ path: String) { Wrap(e: Quiet()).use { p in p.wipe(path) } }
struct T { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
func gen<T>(_ x: T, _ f: (T) -> Void) { f(x) }
func a3fngeneric(_ path: String) { gen(Quiet()) { p in p.wipe(path) } }
// A4 associated type: the protocol requirement writes `Item`, a local type is named `Item`.
struct Item { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
protocol Src { associatedtype Item; func read(_ f: (Item) -> Void) }
struct QSrc: Src { func read(_ f: (Quiet) -> Void) { f(Quiet()) } }
func a4assoc(_ path: String) { QSrc().read { p in p.wipe(path) } }
// A6 member typealias in the declaring type, and a top-level type of the alias's name.
struct Ctx { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
struct Host7 { typealias Ctx = Quiet; func with(_ f: (Ctx) -> Void) { f(Quiet()) } }
func a6alias(_ path: String) { Host7().with { c in c.wipe(path) } }
// A8 a LOCAL closure shadows the free function `around` (which declares Printer).
func a8localShadow(_ path: String) {
    let around: ((Quiet) -> Void) -> Void = { f in f(Quiet()) }
    around { p in p.wipe(path) }
}
// A9 a NESTED type named like a top-level one: inside Outer, `Ctx2` is Outer.Ctx2.
struct Ctx2 { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
struct Outer { struct Ctx2 { func wipe(_ p: String) { _ = p.count } }; func with(_ f: (Ctx2) -> Void) { f(Ctx2()) } }
func a9nested(_ path: String) { Outer().with { c in c.wipe(path) } }
// A9b the reverse: the TOP-LEVEL type is the one the callee names (pure), a nested same-named type deletes.
struct Ctx3 { func wipe(_ p: String) { _ = p.count } }
struct Outer2 { struct Ctx3 { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } } }
func withCtx3(_ f: (Ctx3) -> Void) { f(Ctx3()) }
func a9bnested(_ path: String) { withCtx3 { c in c.wipe(path) } }
// P9 the positive twin of A9: the NESTED type is the effectful one and the callee names it from inside.
struct Outer3 { struct Ctx4 { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }; func with(_ f: (Ctx4) -> Void) { f(Ctx4()) } }
func t4nested(_ path: String) { Outer3().with { c in c.wipe(path) } }
// A1 overloads that differ in the closure type: the trailing closure is unlabelled in both.
struct Ov {
    func each(_ f: (Quiet) -> Void) { f(Quiet()) }
    func each(n: Int = 0, _ f: (Printer) -> Int) { _ = f(Printer()) }
}
func a1overload(_ path: String) { Ov().each { p in p.wipe(path) } }
// A10 a subclass override cannot change the closure type, but the STATIC receiver type decides: a base-typed
// receiver holding a subclass still binds the declared type (same type) — control that agreement holds.
class BaseH { func with(_ f: (Printer) -> Void) { f(Printer()) } }
final class SubH: BaseH { override func with(_ f: (Printer) -> Void) { f(Printer()) } }
func a10override(_ path: String) { let h: BaseH = SubH(); h.with { p in p.wipe(path) } }
// A11 a closure-typed STORED PROPERTY called with a closure: not a method declaration.
struct Holder { let with: ((Quiet) -> Void) -> Void = { f in f(Quiet()) }; func other(_ f: (Printer) -> Void) {} }
func a11field(_ path: String) { Holder().with { p in p.wipe(path) } }

"""
    static let positives = ["t4param", "t4short", "t4inout", "t4static", "t4init", "Svc.t4self", "t4free", "t4labeled",
                            "t4second", "t4secondShort", "t4optional", "t4escaping", "t4nested", "a10override"]
    static let wrongType = ["a2shadow", "a3generic", "a3fngeneric", "a4assoc", "a6alias", "a8localShadow", "a9nested",
                            "a9bnested", "a1overload", "a11field"]

    func testDeclaredClosureParamTypeResolvesAndTheKillSwitchRestoresTheRelease() throws {
        let by = try scan(Self.fixture)
        let off = try scan(Self.fixture, env: ["CANDOR_R1455T4_OFF": "1"])
        for f in Self.positives {
            // each callee also invokes its closure argument, so the row carries that callback's `Unknown` beside `Fs`
            XCTAssertTrue(inf(by, f).contains("Fs"), "R1455 T4: \(f)'s closure parameter is typed by its callee; got \(by[f] ?? [:])")
            XCTAssertFalse(inf(off, f).contains("Fs"), "kill switch: \(f) reads no Fs on the release reading; got \(off[f] ?? [:])")
        }
    }

    func testTheWrongTypeIsNeverCharged() throws {
        let by = try scan(Self.fixture)
        for f in Self.wrongType {
            XCTAssertFalse(inf(by, f).contains("Fs"), "R1455 T4: \(f) runs the PURE member (executed); got \(by[f] ?? [:])")
        }
    }

    func testGateFlips() throws {
        for f in ["t4param", "t4short", "t4init", "Svc.t4self", "t4free"] {
            XCTAssertEqual(try gate(Self.fixture, "deny Fs \(f)"), 1, "deny Fs \(f) must fail: the callee deletes a file")
            XCTAssertNotEqual(try gate(Self.fixture, "deny Fs \(f)", env: ["CANDOR_R1455T4_OFF": "1"]), 1,
                              "kill switch: deny Fs \(f) passes on the release reading (the silence this closes)")
        }
        for f in ["a2shadow", "a9nested", "a1overload"] {
            XCTAssertNotEqual(try gate(Self.fixture, "deny Fs \(f)"), 1, "deny Fs \(f) must pass: the pure member runs")
        }
    }
}
