import XCTest
import Foundation
import CandorCore

/// SOUNDNESS R1463 and R1455 (ladder classes T0 and T1) — a member call whose receiver's type the SOURCE spells, on a
/// receiver `rootOf` did not type, was dropped: no edge, no `Unknown` (R1455's `droppedMember`).
///
/// Every effectful arm below was EXECUTED before it was written down (`swiftagent-r1463/fx/exec`): each function
/// deleted its own victim file, and `deny Fs <fn>` exited 0 on the published v0.40.18 binary and 1 on this change.
/// The kill switches (`CANDOR_R1463_OFF`, `CANDOR_R1455_SHADOW_OFF`) restore the release reading, so each test also
/// shows the change is what moved the row.
///
/// The WRONG-MEMBER arms give every provider a different effect, so a resolution to the wrong type shows up as the
/// wrong effect rather than as a coincidentally right one.
///
/// Harness note (R706): under `swift test` the manifest peek can leave a non-violating gate at exit 2, so a
/// must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class SpelledReceiverProcessTests: XCTestCase {
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
    private func calls(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["calls"] as? [String] ?? []).sorted()
    }

    // The executed fixture, one function per receiver shape (each deletes its own file when run).
    static let shapes = """
    import Foundation
    func del(_ n: String) { try? FileManager.default.removeItem(atPath: "/nonexistent/candor-r1463/" + n) }
    extension String { func wipe() { del("strlit") }; func wipeI() { del("strinterp") } }
    extension Int { func wipe() { del("intlit") } }
    extension Double { func wipe() { del("floatlit") } }
    extension Bool { func wipe() { del("boollit") } }
    extension Array { func wipe() { del("arr") } }
    extension Dictionary { func wipe() { del("dict") } }
    extension Set { func wipe() { del("set") } }
    struct Box<T> { static func make() { del("genericstatic") } }
    struct Ser { mutating func node(_ f: (inout Ser) -> Void) { del("shadow"); var s = Ser(); f(&s) } }
    struct Holder { var names: [Character] = ["a"]; var tags: [Int8: Int] = [1: 1]
      func implicitField() { names.wipe() }
      func selfField() { self.tags.wipe() } }
    func e_strlit() { "x".wipe() }
    func e_strinterp() { "x\\(1)".wipeI() }
    func e_intlit() { 7.wipe() }
    func e_floatlit() { 1.5.wipe() }
    func e_boollit() { true.wipe() }
    func e_arrlit() { [UInt8(1)].wipe() }
    func e_dictlit() { [UInt16(1): 2].wipe() }
    func e_generic() { Box<Int>.make() }
    func e_dictparam(d: [Int64: Int]) { d.wipe() }
    func e_dictlocal() { let d: [UInt64: Int] = [1: 1]; d.wipe() }
    func e_variadic(_ t: (Int, Int)...) { t.wipe() }
    func e_shadow(c: inout Ser) { c.node { c in _ = c } }
    """
    static let r1463Fns = ["e_strlit", "e_strinterp", "e_intlit", "e_floatlit", "e_boollit", "e_arrlit", "e_dictlit",
                           "e_generic", "e_dictparam", "e_dictlocal", "e_variadic",
                           "Holder.implicitField", "Holder.selfField"]

    func testSpelledReceiverResolvesAndTheGateFlips() throws {
        let by = try scan(Self.shapes)
        let off = try scan(Self.shapes, env: ["CANDOR_R1463_OFF": "1"])
        for f in Self.r1463Fns {
            XCTAssertEqual(inf(by, f), ["Fs"], "R1463: \(f)'s receiver type is spelled; its callee deletes a file; got \(by[f] ?? [:])")
            XCTAssertNil(off[f], "kill switch: \(f) is ABSENT on the release reading (the row this pins); got \(off[f] ?? [:])")
        }
        // THE GATE, on the R1463 row's own spelling.
        XCTAssertEqual(try gate(Self.shapes, "deny Fs e_strlit"), 1)
        XCTAssertNotEqual(try gate(Self.shapes, "deny Fs e_strlit", env: ["CANDOR_R1463_OFF": "1"]), 1)
    }

    func testAClosureParameterNamedLikeTheReceiverDoesNotScopeOverIt() throws {
        let by = try scan(Self.shapes)
        // `Ser.node` also invokes its closure argument, so the row carries that callback's `Unknown` beside `Fs`.
        XCTAssertTrue(inf(by, "e_shadow").contains("Fs"), "the receiver `c` is the outer parameter; got \(by["e_shadow"] ?? [:])")
        let off = try scan(Self.shapes, env: ["CANDOR_R1455_SHADOW_OFF": "1"])
        XCTAssertNil(off["e_shadow"], "kill switch restores the release's drop; got \(off["e_shadow"] ?? [:])")
        XCTAssertEqual(try gate(Self.shapes, "deny Fs e_shadow"), 1)
    }

    // ── WRONG MEMBER — each provider has its own effect, so a wrong resolution is a wrong effect ─────────────────
    static let wrong = """
    import Foundation
    extension String { func zap() { try? FileManager.default.removeItem(atPath: "/nonexistent/x") } }
    extension Array { func zap() { _ = URLSession.shared.dataTask(with: URL(string: "https://e.example")!) } }
    extension Dictionary { func zap() { _ = ProcessInfo.processInfo.environment["X"] } }
    extension Set { func zap() { _ = Date.now } }
    extension Collection { func colOnly() { _ = Date.now } }
    extension StringProtocol { func spOnly() { _ = ProcessInfo.processInfo.environment["Y"] } }
    final class Foo { func zap() { let p = Process(); try? p.run() }
                      func colOnly() { let p = Process(); try? p.run() }
                      func spOnly() { let p = Process(); try? p.run() } }
    struct G<T> { static func mk() { } }
    struct H<T> { static func mk() { try? FileManager.default.removeItem(atPath: "/nonexistent/y") } }
    struct Ser { func node(_ f: (Other) -> Void) { f(Other()) }; func leaf() { let p = Process(); try? p.run() } }
    struct Other { func leaf() { } }
    func w_str() { "a".zap() }
    func w_arr() { [1].zap() }
    func w_dict() { ["k": 1].zap() }
    func w_setp(s: Set<Int>) { s.zap() }
    func w_colLit() { [1].colOnly() }
    func w_spLit() { "a".spOnly() }
    func w_generic() { G<Int>.mk() }
    func w_shadowInner(s: Ser) { s.node { s in s.leaf() } }
    """

    func testTheSpelledTypeIsTheDispatchTargetOrNothingIsClaimed() throws {
        let by = try scan(Self.wrong)
        XCTAssertEqual(inf(by, "w_str"), ["Fs"], "String.zap, not Array/Dictionary/Foo; got \(by["w_str"] ?? [:])")
        XCTAssertEqual(inf(by, "w_arr"), ["Net"], "Array.zap only; got \(by["w_arr"] ?? [:])")
        XCTAssertEqual(inf(by, "w_dict"), ["Env"], "Dictionary.zap only; got \(by["w_dict"] ?? [:])")
        // A Set receiver resolves to Set's own member. The release's `extension Array` edge for a Set receiver
        // (`arrayElem` holds a Set's element) is kept as the floor — it is pre-existing, not introduced here.
        XCTAssertTrue(inf(by, "w_setp").contains("Clock"), "Set.zap; got \(by["w_setp"] ?? [:])")
        XCTAssertTrue(calls(by, "w_setp").contains("Set.zap"))
        // A protocol extension member on a literal: the protocol's body, never a same-named member of a local class.
        XCTAssertEqual(calls(by, "w_colLit"), ["Collection.colOnly"], "got \(by["w_colLit"] ?? [:])")
        XCTAssertEqual(inf(by, "w_colLit"), ["Clock"])
        XCTAssertEqual(calls(by, "w_spLit"), ["StringProtocol.spOnly"], "got \(by["w_spLit"] ?? [:])")
        for f in ["w_str", "w_arr", "w_dict", "w_setp", "w_colLit", "w_spLit"] {
            XCTAssertFalse(inf(by, f).contains("Exec"), "\(f): a local class's same-named member is not the callee")
        }
        // A specialised type reference is THAT type: G's pure `mk`, never H's.
        XCTAssertNil(by["w_generic"], "G<Int>.mk() is G.mk (pure); got \(by["w_generic"] ?? [:])")
        // Inside the closure `s` is the closure's own `Other`: the outer `Ser.leaf` (Exec) must not be charged.
        XCTAssertFalse(inf(by, "w_shadowInner").contains("Exec"), "got \(by["w_shadowInner"] ?? [:])")
    }
}
