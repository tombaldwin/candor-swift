import XCTest
import Foundation

/// SOUNDNESS R1044 (nested residual) — the instantiation a value was MADE with, one level further than the residual
/// fix read it. `Box(v: Box(v: E())).get().get().go()` was ABSENT (executed, `swiftagent-v044/fx/nest`: the program
/// ran `E.go`). The residual fix typed the inner `Box(v: E())` by its bare name, so the first `.get()` was a `Box`
/// with no arguments and the second answered nothing. Each generic argument now carries its own arguments.
///
/// Harness note (R706): a must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class NestedInstantiationProcessTests: XCTestCase {
    private static let FS = "try? FileManager.default.removeItem(atPath: \"/nonexistent/candor-v044\")"

    private func inf(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["inferred"] as? [String] ?? []).sorted()
    }

    // ── R1044 nested ────────────────────────────────────────────────────────────────────────────────────
    static let nested = """
    import Foundation
    struct E { func go() { \(FS) } }
    struct P { func go() { print("pure") } }
    struct Box<V> { let v: V; func get() -> V { v } }
    struct Pair<A, B> { let a: A; let b: B; func first() -> A { a }; func second() -> B { b } }
    func viaGG() { Box(v: Box(v: E())).get().get().go() }
    func viaFV() { Box(v: Box(v: E())).v.v.go() }
    func viaMix() { Box(v: Box(v: E())).get().v.go() }
    func viaLet() { let b = Box(v: Box(v: E())); b.get().get().go() }
    func viaAnn() { let b: Box<Box<E>> = Box(v: Box(v: E())); b.get().get().go() }
    func viaSpec() { Box<Box<E>>(v: Box(v: E())).get().get().go() }
    func viaParam(_ b: Box<Box<E>>) { b.get().get().go() }
    func viaPair() { Pair(a: P(), b: Box(v: E())).second().get().go() }
    func viaTriple() { Box(v: Box(v: Box(v: E()))).get().get().get().go() }
    func viaInnerLet() { let i = Box(v: E()); Box(v: i).get().get().go() }
    // CONTROLS: the pure instantiation nested, the other position of a pair, and a nested argument spelled with a
    // GENERIC PARAMETER that shares its name with a local type (`X`), which must answer nothing.
    struct X { func go() { \(FS) } }
    protocol Goer { func go() }
    extension P: Goer {}
    func ctlPure() { Box(v: Box(v: P())).get().get().go() }
    func ctlFirst() { Pair(a: P(), b: Box(v: E())).first().go() }
    func ctlGen<X: Goer>(_ x: X) { Box(v: Box(v: x)).get().get().go() }
    """
    func testANestedInstantiationTypesEachLevel() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.nested)
        defer { try? FileManager.default.removeItem(at: root) }
        func scan(_ env: [String: String] = [:]) throws -> [String: [String: Any]] {
            try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"], env: env).out)
        }
        func gate(_ policy: String, _ env: [String: String] = [:]) throws -> Int32 {
            let pf = root.appendingPathComponent("p.policy")
            try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
        }
        let by = try scan()
        for f in ["viaGG", "viaFV", "viaMix", "viaLet", "viaAnn", "viaSpec", "viaParam", "viaPair", "viaTriple", "viaInnerLet"] {
            XCTAssertEqual(inf(by, f), ["Fs"], "R1044 nested: \(f) runs E.go; got \(by[f] ?? [:])")
        }
        for f in ["ctlPure", "ctlFirst", "ctlGen"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, f), "R1044 nested: \(f) must charge nothing; got \(by[f] ?? [:])")
        }
        XCTAssertEqual(try gate("deny Fs viaGG"), 1, "the gate must flip")
        XCTAssertNotEqual(try gate("deny Fs ctlPure"), 1, "the pure nested instantiation passes")
        let off = try scan(["CANDOR_R1044N_OFF": "1"])
        XCTAssertNil(ProcessHarness.chargedNothing(off, "viaGG"), "kill switch restores the residual fix's silence")
        XCTAssertEqual(inf(off, "viaFV").isEmpty, true, "kill switch restores the residual fix's silence (field)")
    }

    // ── §E3 — every fixture compiles ────────────────────────────────────────────────────────────────────
    func testTheNestedFixtureTypechecks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v044-tc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = root.appendingPathComponent("nested.swift")
        try Self.nested.write(to: f, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(URL(fileURLWithPath: "/usr/bin/env"), ["swiftc", "-typecheck", f.path])
        if r.code != 0, r.err.contains("env: swiftc") { throw XCTSkip("no swiftc on this host") }
        XCTAssertEqual(r.code, 0, "FIXTURE MUST COMPILE (§E3); stderr:\n\(r.err)")
    }
}
