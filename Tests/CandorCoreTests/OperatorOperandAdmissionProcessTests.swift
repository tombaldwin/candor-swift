import XCTest
import Foundation

/// SOUNDNESS R1081 — an operator call was matched to a project overload by NAME. With `extension Int: Shadow` and
/// `extension Shadow { static func + (a: Self, b: String) -> Self }` (effectful), `(x + 1) * 2 - x / 3` on an `Int` was
/// charged `Fs` — an integer literal cannot bind a `String` parameter (executed: no write). The overload is now refused
/// only on PROOF per operand (a literal kind the parameter's concrete type cannot take, or a concretely-typed operand
/// that is neither the parameter's type nor a recorded subtype). REMOVAL direction, so the arms that must KEEP their
/// charge were written first, every one EXECUTED (`swiftagent-v044/fx/op`): `x + "s"`, `x + s` (`s: String`),
/// `x + g()` (operand untyped: undecidable, keeps the edge), and `5 + "s"` — both operands literals of DIFFERENT kinds, which the
/// release never recorded at all (ABSENT over a write) and which now take their default literal types.
/// Harness note (R706): a must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class OperatorOperandAdmissionProcessTests: XCTestCase {
    private static let FS = "try? FileManager.default.removeItem(atPath: \"/nonexistent/candor-v044\")"
    static let src = """
    import Foundation
    protocol Shadow {}
    extension Shadow { static func + (a: Self, b: String) -> Self { \(FS); return a } }
    extension Int: Shadow {}
    func viaStrLit(_ x: Int) -> Int { x + "s" }
    func viaStrTyped(_ x: Int, _ s: String) -> Int { x + s }
    func viaUntyped(_ x: Int, _ g: () -> String) -> Int { x + g() }
    func viaBothLit() -> Int { 5 + "s" }
    func ctlArith(_ x: Int) -> Int { (x + 1) * 2 - x / 3 }
    func ctlTyped(_ x: Int, _ y: Int) -> Int { x + y }
    """
    private func inf(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["inferred"] as? [String] ?? []).sorted()
    }

    func testAnOperatorOverloadIsAdmittedOnlyWhereItsOperandsCouldBind() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.src)
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
        for f in ["viaStrLit", "viaStrTyped", "viaUntyped", "viaBothLit"] {
            XCTAssertTrue(inf(by, f).contains("Fs"), "R1081: \(f) runs Shadow.+; got \(by[f] ?? [:])")
        }
        for f in ["ctlArith", "ctlTyped"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, f), "R1081: \(f) is stdlib arithmetic; got \(by[f] ?? [:])")
        }
        XCTAssertNotEqual(try gate("deny Fs ctlArith"), 1, "R1081: the fabricated charge is gone")
        XCTAssertEqual(try gate("deny Fs viaBothLit"), 1, "R1081: the both-literal call is no longer silent")
        let off = try scan(["CANDOR_R1081_OFF": "1"])
        XCTAssertTrue(inf(off, "ctlArith").contains("Fs"), "kill switch restores the release's charge")
    }

    func testTheFixtureTypechecks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v044-tc1081-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = root.appendingPathComponent("ops.swift")
        try Self.src.write(to: f, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(URL(fileURLWithPath: "/usr/bin/env"), ["swiftc", "-typecheck", f.path])
        if r.code != 0, r.err.contains("env: swiftc") { throw XCTSkip("no swiftc on this host") }
        XCTAssertEqual(r.code, 0, "FIXTURE MUST COMPILE (§E3); stderr:\n\(r.err)")
    }
}
