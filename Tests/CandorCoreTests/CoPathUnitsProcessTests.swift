import XCTest
import Foundation
@testable import CandorCore

/// SPEC §2 ⟨0.42⟩ CO-PATH UNITS and §6.2 Scope matching ⟨0.42⟩ — SOUNDNESS R1549, R1550, R1551, R1560.
///
/// A co-path unit's `fn` ends in a DISAMBIGUATOR (`Box.act(Models.Inner.Rec)`, `Box.act(Int)#1`), and the
/// group's content carries the path separators. Every reader that split the WHOLE name on `.`/`:` made
/// `Inner` a path segment of a function that lives in `Box`:
///
///   R1549  `deny Fs Inner` fired on a function that merely TAKES the type (fail-closed);
///   R1550  `only callEff -> Inner` was SATISFIED by that callee (a false green on a permission list);
///   R1551  the chained key derivation's leaf was `Rec)`, so no bare-path key existed and a consumer's
///          `Box.act(r)` joined NOTHING — `[]`, no `Unknown`, no `invisible`, `deny Fs` exit 0;
///   R1560  the producer's ⟨0.39⟩ union index read `Impl.run(Models.Rec)` as owner `Impl.run(Models`, so
///          no `Runner.run` union entry was published for an overloaded implementor.
///
/// §1b: each process assertion below FAILS under its own kill switch (`CANDOR_R1549_OFF`,
/// `CANDOR_R1550_OFF`, `CANDOR_R1551_OFF`, `CANDOR_R1560_OFF`); the controls pass under all of them.
final class CoPathUnitsProcessTests: XCTestCase {

    // ── the segmentation rule itself ──────────────────────────────────────────────────────────────────

    func testADisambiguatorStaysInsideTheLastSegment() {
        XCTAssertEqual(nameSegments("Box.act(Models.Inner.Rec)"), ["Box", "act(Models.Inner.Rec)"])
        XCTAssertEqual(nameSegments("bank.Bank.pay(ua.user.User)"), ["bank", "Bank", "pay(ua.user.User)"])
        XCTAssertEqual(nameSegments("m::S::act(tm::Tr)"), ["m", "S", "act(tm::Tr)"])
        XCTAssertEqual(nameSegments("Box.act(Models.Rec)#1"), ["Box", "act(Models.Rec)#1"])
        XCTAssertEqual(nameSegments("Box4.act([String: Models.Rec])"), ["Box4", "act([String: Models.Rec])"])
        XCTAssertEqual(nameSegments("Box.act((Models.Rec) -> Void)"), ["Box", "act((Models.Rec) -> Void)"])
        XCTAssertEqual(nameSegments("plain.name.here"), ["plain", "name", "here"], "no disambiguator: unchanged")
        // A group that BEGINS a segment is a path segment (candor-scan's tuple self type), not a disambiguator.
        XCTAssertEqual(nameSegments("row::convert::(T1,T2)::from_row_opt"),
                       ["row", "convert", "(T1,T2)", "from_row_opt"])
        XCTAssertEqual(nameSegments("row::(a::T1,b::T2)"), legacySegments("row::(a::T1,b::T2)"),
                       "a trailing group opened after a SEPARATOR is not a disambiguator")
        XCTAssertEqual(barePath("Box.act(Models.Inner.Rec)"), "Box.act")
        XCTAssertEqual(barePath("Box.act(Int)#1"), "Box.act")
        XCTAssertEqual(barePath("cfg#1"), "cfg")
        XCTAssertEqual(barePath("Box.act"), "Box.act")
        XCTAssertEqual(barePath("Dep#Box.make(Models.Rec)"), "Dep#Box.make", "a `pkg#` prefix is not a `#<N>`")
    }

    func testScopeMatchingNeverSplitsInsideTheDisambiguator() {
        let f = "Box.act(Models.Inner.Rec)"
        XCTAssertTrue(scopeMatches(f, "Box.act"), "the bare path binds every member (last-segment prefix)")
        XCTAssertTrue(scopeMatches(f, "Box"))
        XCTAssertTrue(scopeMatches(f, "Box.act(Models.Inner.Rec)"), "an exact disambiguated scope binds it")
        XCTAssertFalse(scopeMatches("Box.act(Int,Int)", "Box.act(Models.Inner.Rec)"))
        XCTAssertFalse(scopeMatches(f, "Inner"), "R1549: a token inside the disambiguator binds nothing")
        XCTAssertFalse(scopeMatches(f, "Rec"))
        XCTAssertFalse(scopeMatches(f, "Models"))
        XCTAssertFalse(scopeMatches("bank.Bank.pay(ua.user.User)", "user"))
        XCTAssertFalse(scopeMatches("m::S::act(tm::Tr)", "Tr"))
        XCTAssertFalse(scopeMatchesPermitted(f, "Inner"),
                       "R1550: a permitted scope satisfied through a parameter type is a FALSE GREEN")
        XCTAssertTrue(scopeMatchesPermitted(f, "Box"), "the real owner still permits")
    }

    // ── the process half ─────────────────────────────────────────────────────────────────────────────

    private struct Fixture {
        let root: URL
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
    }

    private static let depSource = """
    import Foundation
    public enum Models {
        public struct Rec { public init() {} }
        public enum Inner { public struct Rec { public init() {} } }
        public struct G<T> { public init() {} }
    }
    public struct Rec { public init() {} }
    func mark() { _ = FileManager.default.contents(atPath: "/tmp/candor-copath") }
    public enum Box0 { public static func act(_ r: Rec) -> Int { mark(); return 1 }
                       public static func act(_ n: Int) -> Int { return n } }
    public enum Box1 { public static func act(_ r: Models.Rec) -> Int { mark(); return 1 }
                       public static func act(_ n: Int) -> Int { return n } }
    public enum Box2 { public static func act(_ r: Models.Inner.Rec) -> Int { mark(); return 1 }
                       public static func act(_ n: Int) -> Int { return n } }
    public enum Box3 { public static func act(_ r: Models.G<Models.Inner.Rec>) -> Int { mark(); return 1 }
                       public static func act(_ n: Int) -> Int { return n } }
    public enum Box5 { public static func act(a r: Models.Rec) -> Int { return 0 }
                       public static func act(b r: Models.Rec) -> Int { mark(); return 1 } }
    public struct Box7 { public init() {}
                         public func act(_ r: Models.Inner.Rec) -> Int { mark(); return 1 }
                         public func act(_ n: Int) -> Int { return n } }
    public enum Box8 { public static func act(_ r: Models.Inner.Rec) -> Int { return 0 }
                       public static func act(_ n: Int) -> Int { return n } }
    public func fshell(_ r: Models.Inner.Rec) -> Int { mark(); return 1 }
    public func fshell(_ n: Int) -> Int { return n }
    public protocol Runner { func run(_ r: Models.Rec) -> Int }
    public struct Impl: Runner { public init() {}
                                 public func run(_ r: Models.Rec) -> Int { mark(); return 1 }
                                 public func run(_ n: Int) -> Int { return n } }
    """

    private static let appSource = """
    import Dep
    public func u0Eff() -> Int { Box0.act(Rec()) }
    public func q1Eff() -> Int { Box1.act(Models.Rec()) }
    public func q2Eff() -> Int { Box2.act(Models.Inner.Rec()) }
    public func q3Eff() -> Int { Box3.act(Models.G<Models.Inner.Rec>()) }
    public func q5Eff() -> Int { Box5.act(b: Models.Rec()) }
    public func q7Eff() -> Int { Box7().act(Models.Inner.Rec()) }
    public func f1Eff() -> Int { fshell(Models.Inner.Rec()) }
    public func p1Eff(_ x: any Runner) -> Int { x.run(Models.Rec()) }
    public func c2Pure() -> Int { Box8.act(Models.Inner.Rec()) + Box8.act(3) }
    """

    /// Scans the dependency alone, then the consumer chained on it; returns the consumer's rows, the
    /// dependency's `fn`s, and `deny Fs <fn>`'s exit per consumer function.
    private func chained(env extra: [String: String] = [:]) throws
        -> (rows: [String: [String]], depFns: Set<String>, deny: [String: Int32]) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fx = Fixture(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-copath-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try fx.write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Dep", products: [.library(name: "Dep", targets: ["Dep"])],
            targets: [.target(name: "Dep")])
        """)
        try fx.write("dep/Sources/Dep/lib.swift", Self.depSource)
        try fx.write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [.product(name: "Dep", package: "dep")])])
        """)
        try fx.write("app/Sources/App/app.swift", Self.appSource)
        let depDir = fx.root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [fx.root.appendingPathComponent("dep").path,
                                              "--out", depDir.appendingPathComponent("r").path], env: extra)
        XCTAssertEqual(rd.code, 0, "dependency scan: \(rd.err)")
        let report = depDir.appendingPathComponent("r.Dep.Swift.json")
        let depDoc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        let depFns = Set(((depDoc?["functions"] as? [[String: Any]]) ?? []).compactMap { $0["fn"] as? String })
        var env = extra
        env["CANDOR_DEPS"] = report.path
        let r = try ProcessHarness.run(bin, [fx.root.appendingPathComponent("app").path,
                                             "--out", fx.root.appendingPathComponent("ch").path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fx.root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: [String]] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = ((f["inferred"] as? [String]) ?? []).sorted()
        }
        var deny: [String: Int32] = [:]
        for fn in ["u0Eff", "q1Eff", "q2Eff", "q3Eff", "q5Eff", "q7Eff", "f1Eff", "p1Eff", "c2Pure"] {
            let pol = fx.root.appendingPathComponent("\(fn).policy")
            try "deny Fs \(fn)\n".write(to: pol, atomically: true, encoding: .utf8)
            let g = try ProcessHarness.run(bin, [fx.root.appendingPathComponent("app").path, "--policy", pol.path,
                                                 "--out", fx.root.appendingPathComponent("g-\(fn)").path], env: env)
            deny[fn] = g.code
        }
        return (rows, depFns, deny)
    }

    /// R1551 + R1560 — every spelling of a qualified parameter type joins, and `deny Fs` fires.
    func testAChainedCallToAnOverloadWithAQualifiedParameterTypeJoins() throws {
        let r = try chained()
        // §E3 — the producer really spells the overloads with a separator inside the group.
        // (this engine erases a generic's arguments in the disambiguator: `Box3.act(Models.G)`)
        for f in ["Box1.act(Models.Rec)", "Box2.act(Models.Inner.Rec)", "Box3.act(Models.G)",
                  "Box5.act(Models.Rec)#1", "Box7.act(Models.Inner.Rec)", "fshell(Models.Inner.Rec)",
                  "Impl.run(Models.Rec)"] {
            XCTAssertTrue(r.depFns.contains(f), "producer spelling \(f) is the premise; dep: \(r.depFns.sorted())")
        }
        XCTAssertTrue(r.depFns.contains("Runner.run(Models.Rec)"),
                      "R1560: the ⟨0.39⟩ union entry for `Runner.run` must be published; dep: \(r.depFns.sorted())")
        XCTAssertEqual(r.rows["u0Eff"], ["Fs"], "CONTROL (R567(b), unqualified parameter type)")
        XCTAssertEqual(r.deny["u0Eff"], 1)
        for fn in ["q1Eff", "q2Eff", "q3Eff", "q5Eff", "q7Eff", "f1Eff", "p1Eff"] {
            XCTAssertEqual(r.rows[fn], ["Fs"], "\(fn) calls a dependency member that reads a file")
            XCTAssertEqual(r.deny[fn], 1, "GATE: `deny Fs \(fn)` over code that reads a file")
        }
        XCTAssertEqual(r.rows["c2Pure"] ?? [], [], "CONTROL: a union of PURE members stays pure (no fabrication)")
        XCTAssertEqual(r.deny["c2Pure"], 0)
    }

    /// §1b — the kill switches restore the silence they close, so the assertions above can fail.
    func testTheKillSwitchesRestoreTheSilence() throws {
        let r = try chained(env: ["CANDOR_R1551_OFF": "1", "CANDOR_R1560_OFF": "1"])
        XCTAssertEqual(r.rows["u0Eff"], ["Fs"], "the control does not depend on either fix")
        for fn in ["q1Eff", "q2Eff", "q7Eff", "f1Eff"] {
            XCTAssertEqual(r.deny[fn], 0, "\(fn): with R1551 off the join misses and the gate is silent")
        }
        XCTAssertFalse(r.depFns.contains("Runner.run(Models.Rec)"), "with R1560 off no union entry is published")
    }

    /// R1549 / R1550 on the scan route, one tree: a token inside the disambiguator neither binds `deny`
    /// nor satisfies `only`.
    func testScanRouteMatchersDoNotSplitTheDisambiguator() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fx = Fixture(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-copath-one-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try fx.write("one/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "One", targets: [.target(name: "One")])
        """)
        try fx.write("one/Sources/One/lib.swift", """
        import Foundation
        public enum Models { public enum Inner { public struct Rec { public init() {} } } }
        public enum Box {
            public static func act(_ r: Models.Inner.Rec) -> Int { _ = FileManager.default.contents(atPath: "/x"); return 1 }
            public static func act(_ a: Int, _ b: Int) -> Int { return a + b }
        }
        public func callEff(_ r: Models.Inner.Rec) -> Int { Box.act(r) }
        """)
        func gate(_ policy: String, _ env: [String: String] = [:]) throws -> Int32 {
            let pol = fx.root.appendingPathComponent("p-\(UUID().uuidString).policy")
            try (policy + "\n").write(to: pol, atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [fx.root.appendingPathComponent("one").path, "--policy", pol.path,
                                                "--out", fx.root.appendingPathComponent("g").path], env: env).code
        }
        XCTAssertEqual(try gate("deny Fs Box.act"), 1, "the bare path binds the effectful member")
        XCTAssertEqual(try gate("deny Fs Inner"), 0, "R1549: `Inner` is a parameter type, not a path segment")
        XCTAssertEqual(try gate("only callEff -> Inner"), 1, "R1550: `Inner` does not permit a call into `Box`")
        XCTAssertEqual(try gate("only callEff -> Box"), 0, "CONTROL: the real owner permits it")
        XCTAssertEqual(try gate("deny Fs Inner", ["CANDOR_R1549_OFF": "1"]), 1, "§1b: R1549's switch restores the split")
        XCTAssertEqual(try gate("only callEff -> Inner", ["CANDOR_R1550_OFF": "1"]), 0,
                       "§1b: R1550's switch restores the false green")
    }
}
