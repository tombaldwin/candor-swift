import XCTest
import Foundation

/// SOUNDNESS R1073 — a LOCAL protocol that `Int` is extended to is not an external base. `extension Int: AtomicPrimitive`
/// over swift-nio's own protocol put that protocol among `Int`'s "external" supertypes (`localTypes` holds a protocol
/// only once something extends it), so every stdlib operator on a typed `Int` was hedged `dispatch:AtomicPrimitive.<op>`.
///
/// This REMOVES `Unknown`, so the fixture that must NOT lose anything was written first, and every arm was EXECUTED
/// (`swiftagent-v044/fx/op`, `fx/ext`):
///   · a user-declared, effectful operator witness on `Int` for the local protocol keeps its charge;
///   · an operator dispatched on a value typed by the protocol keeps its charge, and a dispatch the CHA cannot bound
///     (zero conformers) keeps its hedge;
///   · a protocol-extension operator reached through the concrete `Int` (`x + "s"`) keeps its charge;
///   · a local protocol that INHERITS a protocol this scan does not declare still hedges, naming the external
///     ancestor — its extension may supply the operator.
/// NARROW: only an operator, only on a type the scan does not declare, only a local protocol that neither requires
/// nor provides it. A first cut without those fences moved 1,176 corpus rows over unrelated protocols.
/// Harness note (R706): a must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class LocalProtocolOperatorHedgeProcessTests: XCTestCase {
    private static let FS = "try? FileManager.default.removeItem(atPath: \"/nonexistent/candor-v044\")"
    static let ops = """
    import Foundation
    infix operator %%%: MultiplicationPrecedence
    infix operator <+>: AdditionPrecedence
    protocol Prim { static func %%% (a: Self, b: Self) -> Self; func bump() -> Self }
    extension Int: Prim {
        static func %%% (a: Int, b: Int) -> Int { \(FS); return a &+ b }
        func bump() -> Int { \(FS); return self + 1 }
    }
    protocol Shadow {}
    extension Shadow { static func + (a: Self, b: String) -> Self { \(FS); return a } }
    extension Int: Shadow {}
    protocol Prim0 { static func <+> (a: Self, b: Self) -> Self }
    func viaUserOp(_ x: Int, _ y: Int) -> Int { x %%% y }
    func viaUserMember(_ x: Int) -> Int { x.bump() }
    func viaProtoOp<T: Prim>(_ a: T, _ b: T) -> T { a %%% b }
    func viaShadowOp(_ x: Int) -> Int { x + "s" }
    func viaZero<T: Prim0>(_ a: T, _ b: T) -> T { a <+> b }
    func ctlMod(_ x: Int, _ y: Int) -> Int { x % y }
    func ctlCmp(_ x: Int, _ y: Int) -> Bool { x == y || x < y }
    func ctlWrap(_ x: Int) -> Int { x &+ 1 }
    """
    private func inf(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["inferred"] as? [String] ?? []).sorted()
    }

    func testStdlibOperatorsOnIntAreNotHedgedByALocalProtocol() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.ops)
        defer { try? FileManager.default.removeItem(at: root) }
        func scan(_ env: [String: String] = [:]) throws -> [String: [String: Any]] {
            try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"], env: env).out)
        }
        func gate(_ policy: String) throws -> Int32 {
            let pf = root.appendingPathComponent("p.policy")
            try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"]).code
        }
        let by = try scan()
        for f in ["viaUserOp", "viaUserMember", "viaProtoOp", "viaShadowOp"] {
            XCTAssertTrue(inf(by, f).contains("Fs"), "R1073: \(f) keeps its charge; got \(by[f] ?? [:])")
        }
        XCTAssertEqual(inf(by, "viaZero"), ["Unknown"], "an unbounded protocol dispatch keeps its hedge")
        for f in ["ctlMod", "ctlCmp", "ctlWrap"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, f), "R1073: \(f) is stdlib arithmetic on Int; got \(by[f] ?? [:])")
        }
        XCTAssertNotEqual(try gate("deny Unknown ctlMod"), 1, "R1073: the gate no longer trips on `x % y`")
        XCTAssertEqual(try gate("deny Fs viaUserOp"), 1, "the user-declared witness is still charged")
        XCTAssertEqual(try gate("deny Unknown viaZero"), 1, "the unbounded dispatch still trips")
        let off = try scan(["CANDOR_R1073_OFF": "1"])
        XCTAssertEqual(inf(off, "ctlMod"), ["Unknown"], "kill switch restores the release hedge")
    }

    func testALocalProtocolInheritingAnExternalOneStillHedges() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v044-r1073-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for d in ["Iface/Sources/Iface", "Mid/Sources/Mid"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try """
        // swift-tools-version:5.7
        import PackageDescription
        let package = Package(name: "Iface", products: [.library(name: "Iface", targets: ["Iface"])], targets: [.target(name: "Iface")])
        """.write(to: root.appendingPathComponent("Iface/Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public protocol Ext {}
        extension Ext { public func extPoke() { \(Self.FS) } }
        infix operator <*>: MultiplicationPrecedence
        extension Int { public static func <*> (a: Int, b: Int) -> Int { \(Self.FS); return a } }
        """.write(to: root.appendingPathComponent("Iface/Sources/Iface/Iface.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version:5.7
        import PackageDescription
        let package = Package(name: "Mid", dependencies: [.package(path: "../Iface")],
            targets: [.target(name: "Mid", dependencies: ["Iface"])])
        """.write(to: root.appendingPathComponent("Mid/Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import Iface
        protocol LocalExt: Ext {}
        extension Int: LocalExt {}
        func midInherit(_ x: Int) { x.extPoke() }
        func midIntMod(_ x: Int) -> Int { x % 3 }
        func midDepOp(_ x: Int) -> Int { x <*> 2 }
        """.write(to: root.appendingPathComponent("Mid/Sources/Mid/Mid.swift"), atomically: true, encoding: .utf8)
        let by = try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.appendingPathComponent("Mid").path, "--json"]).out)
        XCTAssertEqual(inf(by, "midInherit"), ["Unknown"], "R1073: the external ancestor still hedges; got \(by["midInherit"] ?? [:])")
        XCTAssertEqual(by["midInherit"]?["unknownWhy"] as? [String], ["dispatch:LocalExt.extPoke"],
                       "a non-operator member is outside R1073 and keeps the release reading")
        // An OPERATOR on Int through a local protocol that inherits an external one: the external ancestor's
        // extension may supply it, so the hedge stays, naming that ancestor.
        XCTAssertEqual(by["midIntMod"]?["unknownWhy"] as? [String], ["dispatch:Ext.%"], "the external ancestor still hedges")
        // A DEPENDENCY's operator on `Int` (`extension Int { public static func <*> }`, executed: it writes) keeps the hedge.
        XCTAssertEqual(inf(by, "midDepOp"), ["Unknown"], "R1073: a dependency's operator extension keeps its hedge; got \(by["midDepOp"] ?? [:])")
    }

    /// The `droppedMember` fence, as a one-variable fixture (it was evidenced by the swift-nio A/B alone). The two
    /// functions differ only in a member call the collector DROPS (an untypeable receiver, `{ Writer() }()`). Executed
    /// (`swiftagent-v045/fx/r1073`): `w.scribble()` writes. In `droppedMod` the operator hedge is the row's ONLY
    /// disclosure, so the hedge stays; measured with the fence deleted, `droppedMod` went ABSENT over the write.
    func testTheDroppedCallFenceKeepsTheHedgeThatIsTheRowsOnlyDisclosure() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        protocol Prim {}
        extension Int: Prim {}
        struct Writer { func scribble() { \(Self.FS) } }
        func ctlMod(_ x: Int, _ y: Int) -> Int { x % y }
        func droppedMod(_ x: Int, _ y: Int) -> Int { let w = { Writer() }(); w.scribble(); return x % y }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"]).out)
        XCTAssertNil(ProcessHarness.chargedNothing(by, "ctlMod"), "R1073: stdlib `%` on Int; got \(by["ctlMod"] ?? [:])")
        XCTAssertEqual(inf(by, "droppedMod"), ["Unknown"], "the fence keeps the hedge; got \(by["droppedMod"] ?? [:])")
        XCTAssertEqual(by["droppedMod"]?["unknownWhy"] as? [String], ["dispatch:Prim.%"])
        let pf = root.appendingPathComponent("p.policy")
        try "deny Unknown droppedMod\n".write(to: pf, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"]).code, 1, "the unit is not silent")
    }

    func testTheOperatorFixtureTypechecks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v044-tc1073-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = root.appendingPathComponent("ops.swift")
        try Self.ops.write(to: f, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(URL(fileURLWithPath: "/usr/bin/env"), ["swiftc", "-typecheck", f.path])
        if r.code != 0, r.err.contains("env: swiftc") { throw XCTSkip("no swiftc on this host") }
        XCTAssertEqual(r.code, 0, "FIXTURE MUST COMPILE (§E3); stderr:\n\(r.err)")
    }
}
