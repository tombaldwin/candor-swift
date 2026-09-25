import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R567(b) — **AN OVERLOADED DEPENDENCY METHOD WAS UNREACHABLE BY THE CONSUMER'S §2 KEY.**
///
/// This engine suffixes a unit's name with its param types as soon as that name has more than one
/// signature (`EmbeddedChannel.finish()` / `.finish(Bool)`), and that is load-bearing rather than
/// cosmetic: two overloads sharing one node UNION their bodies, which fabricated `Clock` onto SwiftDate's
/// pure `compare(toDate:granularity:)` and ~13 callers. The wire `hash` is that unit name, exactly as
/// SPEC §2 rule 1 requires. **A Swift call site carries no signature**, so a consumer can only ever form
/// the bare `pkg#Type.member` — and matched neither spelling.
///
/// The free-function half of this was closed in 0.33.0 (`shellOut` → `shellOut(String)`), and its comment
/// declined the METHOD case on the reasoning that "an overloaded METHOD's tail2/full keys are already
/// reached through its OWNER type". That conflates two things: naming the owner decides WHICH TYPE the
/// member belongs to, and the suffix is on the LEAF. The owner is present and correct in all three keys
/// and the join still misses.
///
/// ONE VARIABLE between the two rows below — whether the dependency declares a SECOND overload of the
/// member. Same consumer text, same dependency file, same binary, both members `Env`:
///
///     dep `Chan.once`   (one signature)    consumer `c.once()`     inferred ['Env']
///     dep `Chan.finish` + `.finish(Bool)`  consumer `c.finish()`   inferred []       ← the defect
///
/// §1b: every assertion here FAILS under `CANDOR_R567B_OFF=1`, which restores the free-function-only
/// restriction. The single-signature CONTROL passes in BOTH.
final class OverloadedDepMemberKeyProcessTests: XCTestCase {

    private func runPair(depSource: String, appSource: String, label: String)
        throws -> (rows: [String: Set<String>], depFns: [String: [String]], denyEnv: Int32) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r567b-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "RatesDep",
            products: [.library(name: "RatesCore", targets: ["RatesCore"])],
            targets: [.target(name: "RatesCore")])
        """)
        try write("dep/Sources/RatesCore/lib.swift", depSource)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [.product(name: "RatesCore", package: "dep")])])
        """)
        try write("app/Sources/App/app.swift", appSource)
        try write("deny.policy", "deny Env\n")

        let depDir = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path,
                                              "--out", depDir.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        let report = depDir.appendingPathComponent("r.RatesDep.Swift.json")
        let depDoc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        var depFns: [String: [String]] = [:]
        for f in (depDoc?["functions"] as? [[String: Any]]) ?? [] {
            depFns[(f["fn"] as? String) ?? "?"] = ((f["inferred"] as? [String]) ?? []).sorted()
        }
        for extra in try FileManager.default.contentsOfDirectory(atPath: depDir.path)
        where extra != report.lastPathComponent {
            try FileManager.default.removeItem(at: depDir.appendingPathComponent(extra))
        }

        let out = root.appendingPathComponent("ch")
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", out.path],
                                       env: ["CANDOR_DEPS": depDir.path])
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Set<String>] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = Set((f["inferred"] as? [String]) ?? [])
        }
        let g = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                             "--policy", root.appendingPathComponent("deny.policy").path,
                                             "--out", root.appendingPathComponent("g").path],
                                       env: ["CANDOR_DEPS": depDir.path])
        return (rows, depFns, g.code)
    }

    func testAnOverloadedDependencyMethodIsReachableByTheConsumersBareKey() throws {
        let r = try runPair(depSource: """
        import Foundation
        public final class Chan {
            public init() {}
            public func finish() { _ = ProcessInfo.processInfo.environment["A"] }
            public func finish(_ b: Bool) { _ = ProcessInfo.processInfo.environment["B"] }
            public func once() { _ = ProcessInfo.processInfo.environment["C"] }
        }
        """, appSource: """
        import RatesCore
        public func overloaded(_ c: Chan) { c.finish() }
        public func controlSingle(_ c: Chan) { c.once() }
        """, label: "method")

        // §E3 — the producer really does spell the two overloads apart, and really does carry the effect.
        XCTAssertEqual(r.depFns["Chan.finish()"], ["Env"],
                       "the producer's overload disambiguator is the premise of this row; dep: \(r.depFns)")
        XCTAssertEqual(r.depFns["Chan.finish(Bool)"], ["Env"], "dep: \(r.depFns)")
        XCTAssertEqual(r.depFns["Chan.once"], ["Env"],
                       "…and the CONTROL member is NOT suffixed — a name with one signature stays bare, "
                       + "which is what makes it a control rather than a second copy; dep: \(r.depFns)")

        XCTAssertEqual(r.rows["overloaded"], ["Env"],
                       "`c.finish()` reaches a dependency method that reads the environment. The consumer "
                       + "can only spell `RatesDep#Chan.finish`; the index held `…finish()` and "
                       + "`…finish(Bool)` and answered neither, so the row read pure — a silent "
                       + "under-report keyed on nothing but the callee having a sibling overload")
        XCTAssertEqual(r.rows["controlSingle"], ["Env"],
                       "CONTROL: the byte-identical call to a NON-overloaded member of the same type on "
                       + "the same receiver. It passed before this fix and must still pass, or the "
                       + "change is widening something other than the overload spelling")
        XCTAssertEqual(r.denyEnv, 1, "GATE LEVEL — `deny Env` over code that reads the environment")
    }

    /// The free-function half, asserted here because this change touches its key list: 0.33.0's
    /// `shellOut` fix must not regress, and the two halves now run through ONE widening rather than a
    /// method-shaped copy of a free-function-shaped rule.
    func testTheFreeFunctionHalfStillJoins() throws {
        let r = try runPair(depSource: """
        import Foundation
        public func shellOut(to s: String) { _ = ProcessInfo.processInfo.environment[s] }
        public func shellOut(to n: Int) { _ = ProcessInfo.processInfo.environment["n"] }
        public func onlyOne() { _ = ProcessInfo.processInfo.environment["one"] }
        """, appSource: """
        import RatesCore
        public func viaOverloadedFree() { shellOut(to: "PATH") }
        public func viaSingleFree() { onlyOne() }
        """, label: "free")
        XCTAssertEqual(r.rows["viaOverloadedFree"], ["Env"],
                       "the 0.33.0 free-function half; dep: \(r.depFns)")
        XCTAssertEqual(r.rows["viaSingleFree"], ["Env"], "dep: \(r.depFns)")
        XCTAssertEqual(r.denyEnv, 1)
    }

    /// **THE OVER-CHARGE IS DECLARED, not discovered later.** The wire key records param TYPES and
    /// nothing else — not defaults, not labels — so `write(Bool)` is the genuine callee of a
    /// zero-argument `write()` call whenever that parameter has a default value, and narrowing the union
    /// by the call's arity would DROP the real callee. The cost of refusing to narrow is that a call to
    /// the PURE overload inherits its effectful sibling's effects. That is the direction `matchOverloads`
    /// already takes in-tree when arg types cannot select one candidate, and it is the safe one: an
    /// over-charge discloses, a lost overload is silent.
    func testTheUnionOverchargesAPureOverloadAndThatIsTheDeclaredTrade() throws {
        let r = try runPair(depSource: """
        import Foundation
        public final class Sink {
            public init() {}
            public func emit() {}
            public func emit(_ b: Bool) { _ = ProcessInfo.processInfo.environment["B"] }
        }
        """, appSource: """
        import RatesCore
        public func callsThePureOverload(_ s: Sink) { s.emit() }
        """, label: "over")
        XCTAssertEqual(r.rows["callsThePureOverload"], ["Env"],
                       "STATED COST: `emit()` is pure and `emit(Bool)` is not; the consumer's key names "
                       + "neither signature, so the union charges both. Arity cannot be used to narrow "
                       + "because the wire key does not record DEFAULTS — `emit(Bool)` with a default "
                       + "argument is a legal callee of `emit()` — and dropping the real callee is the "
                       + "silent direction. If this ever reds because the union was narrowed, re-read "
                       + "the default-argument case before believing the narrowing is safe")
    }
}
