import XCTest
import Foundation

/// R96 — A `var` CLOSURE FIELD IS NOT CLOSED, AND THE README ALREADY PROMISED IT WOULD NOT BE.
///
/// `README.md:44` states: *"A function-typed value invoked (`let f: () -> Void` param, a closure-typed
/// field `d.f()`) reads `Unknown` — never silent purity."* The engine kept that promise only for a field
/// with NO visible closure initializer. A field WITH one was resolved to the closure the scan happened to
/// read in the declaration — and the discriminator was exactly that ("is there a closure literal here?"),
/// never `var` vs `let`. So `public var f: () -> Void = { }`, reassigned by anyone holding the object,
/// certified PURE.
///
/// GROUND TRUTH EXECUTED, not reasoned: the pre-fix fixture below was written to an SPM package,
/// `swift build`, and run. `/tmp/r96-sin.txt` was created before the run and was genuinely gone after it,
/// while `VarPure.fire` was ABSENT from `functions[]` — no `Unknown`, no `unknownWhy`, no `incomplete`.
/// Measured on the same binary: `deny Unknown VarPure.fire` — README's own named strictness knob, scoped
/// to the offending unit — exited 0, and so did BLANKET `deny Unknown`.
///
/// THE FIX CONSULTS REASSIGNABILITY; IT DOES NOT WIDEN THE HEDGE. Swift forbids assigning a `let` stored
/// property that already has an initializer, so a `let` closure field is genuinely closed and STAYS fully
/// resolved with no `Unknown` — `letEnvKeepsItsEffectAndNoUnknown` and `letPureStaysPure` are that
/// control, and they are the ones that go red if a later "just hedge everything" simplification lands.
/// A `var` gets the UNION, not a replacement: the visible default's effects are still genuinely reachable
/// (nothing may ever write the field), so `varWithEffectfulDefaultKeepsRecallAndGainsUnknown` pins that
/// `deny Net` still catches an effectful default. Replacing would have traded one silent under-report for
/// a different loss.
///
/// `pure VarPure.fire` still exits 0 after the fix, and that is the FAMILY CONTRACT, not a residual of
/// this row: README.md:47 — *"a `pure` policy rule forbids every effect, not `Unknown` … `deny Unknown
/// <scope>` is the explicit strictness knob"* (SPEC §4 / AS-EFF-003). `unverifiedNamesTheHedgedScope`
/// pins the channel that does answer for a `pure` scope containing `Unknown`, with the exact upgrade.
final class ClosureFieldReassignabilityProcessTests: XCTestCase {

    private func scan(_ src: String, _ name: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return by
    }

    /// EXACTLY the program that was compiled and run for ground truth. Four effect classes are kept
    /// DISTINCT on purpose (`Fs` for the sin, `Net` for the recall control, `Env` for the precision
    /// control, nothing for the pure control) so a union cannot hide a loss in any one of them — the
    /// §E3 failure a previous fixture in this repo made by charging `Fs` on both halves.
    private static let src = """
    import Foundation

    // THE SIN: a `var` closure field with a PURE default, reassigned externally.
    public final class VarPure {
        public var f: () -> Void = { }
        public func fire() { f() }
    }

    // RECALL CONTROL: the `var`'s visible default is effectful (Net) — the effect must SURVIVE.
    public final class VarEff {
        public var f: () -> Void = { _ = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:9/x")!) }
        public func fire() { f() }
    }

    // PRECISION CONTROL: a `let` closure field is closed. Resolved to Env, and NO Unknown.
    public final class LetEnv {
        public let f: () -> Void = { _ = ProcessInfo.processInfo.environment["R96_LET"] }
        public func fire() { f() }
    }

    // PRECISION CONTROL 2: a closed `let` that is pure stays pure — no hedge flood.
    public final class LetPure {
        public let f: () -> Void = { }
        public func fire() { f() }
    }

    let a = VarPure()
    a.f = { try? FileManager.default.removeItem(atPath: "/tmp/r96-sin.txt") }
    a.fire()

    let b = VarEff(); b.fire()
    let c = LetEnv();  c.fire()
    let d = LetPure(); d.fire()
    """

    private func effects(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set((by[fn]?["inferred"] as? [String]) ?? [])
    }

    /// THE ROW. Pre-fix this unit was absent from `functions[]` entirely.
    func testVarWithPureDefaultReadsUnknownNotSilentPurity() throws {
        let by = try scan(Self.src, "R96")
        XCTAssertNotNil(by["VarPure.fire"],
                        "VarPure.fire absent from functions[] — silent purity over an executed file deletion")
        XCTAssertTrue(effects(by, "VarPure.fire").contains("Unknown"),
                      "VarPure.fire = \(effects(by, "VarPure.fire")) — README.md:44 promises Unknown here")
        XCTAssertEqual(by["VarPure.fire"]?["unresolved"] as? Bool, true)
        XCTAssertTrue(((by["VarPure.fire"]?["unknownWhy"] as? [String]) ?? []).contains("dispatch:VarPure.f"),
                      "the Unknown must NAME its origin — unknownWhy is the disclosure, not the flag")
    }

    /// The direction the fix did not intend: a `var` whose visible default IS effectful must keep that
    /// effect. A hedge that REPLACED the resolved answer would make `deny Net` stop catching it.
    func testVarWithEffectfulDefaultKeepsRecallAndGainsUnknown() throws {
        let by = try scan(Self.src, "R96")
        XCTAssertEqual(effects(by, "VarEff.fire"), ["Net", "Unknown"],
                       "the union is the claim: the visible default is still reachable AND the field is open")
    }

    /// PRECISION. A `let` field bound to a visible default is closed; hedging it would destroy the
    /// vein R79/R85 made valuable and would flood every callback property in real code.
    func testLetEnvKeepsItsEffectAndNoUnknown() throws {
        let by = try scan(Self.src, "R96")
        XCTAssertEqual(effects(by, "LetEnv.fire"), ["Env"],
                       "a `let` closure field must stay exactly resolved — no Unknown")
    }

    /// PRECISION 2 — the absence half. A closed pure `let` contributes nothing, so it stays out of
    /// `functions[]`; this is the row that a blanket "closure fields are Unknown" fix turns red.
    func testLetPureStaysPure() throws {
        let by = try scan(Self.src, "R96")
        XCTAssertNil(by["LetPure.fire"],
                     "a closed pure `let` closure field must not be hedged into the report")
    }

    /// The GATE consequence, end to end — `deny Unknown <scope>` is the knob README names, and it was
    /// exiting 0 over the deletion. Also pins the blanket form, which was exiting 0 here too.
    func testDenyUnknownScopedNowCatchesTheReassignableField() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.src, name: "R96")
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("p.txt")

        for rule in ["deny Unknown VarPure.fire", "deny Unknown"] {
            try rule.write(to: pol, atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(bin, [root.path, "--policy", pol.path,
                                                 "--out", root.appendingPathComponent("r").path])
            XCTAssertEqual(r.code, 1, "`\(rule)` must FAIL over a reassignable closure field\n\(r.out)\(r.err)")
        }

        // …and must NOT fire on the closed `let` scopes. Same binary, same tree: the only thing that
        // differs between these two loops is the binding specifier of the field.
        for rule in ["deny Unknown LetEnv.fire", "deny Unknown LetPure.fire"] {
            try rule.write(to: pol, atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(bin, [root.path, "--policy", pol.path,
                                                 "--out", root.appendingPathComponent("r").path])
            XCTAssertEqual(r.code, 0, "`\(rule)` must PASS — a `let` field is closed\n\(r.out)\(r.err)")
        }
    }

    /// `pure <scope>` deliberately tolerates `Unknown` (README.md:47). The verb that answers for that
    /// case must NAME the scope and hand back the upgrade — pre-fix it had nothing to say, because the
    /// unit was not in the report at all.
    func testUnverifiedNamesTheHedgedScope() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.src, name: "R96")
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("p.txt")
        try "pure VarPure.fire".write(to: pol, atomically: true, encoding: .utf8)
        let rep = root.appendingPathComponent("r")
        _ = try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", rep.path])
        let u = try ProcessHarness.run(bin, ["unverified", "--report", rep.path + ".R96.Swift.json",
                                             "--policy", pol.path, "--strict"])
        XCTAssertEqual(u.code, 1, "unverified --strict must flag a `pure` scope that passes on Unknown\n\(u.out)")
        XCTAssertTrue(u.out.contains("VarPure.fire") && u.out.contains("deny Unknown VarPure.fire"),
                      "the remedy must be named, not just the failure: \(u.out)")
    }

    /// The FIELD-REF spellings share one authority with the bare-invocation one (`closurePropertyInvocation`).
    /// Pre-fix each of the four sites spelled the rule itself; §G says a fact computed in four places
    /// drifts, and R97 in this same engine is the third instance. All four must answer identically.
    func testEveryInvocationSpellingAgrees() throws {
        let src = """
        import Foundation
        final class Box {
            var openF: () -> Void = { _ = ProcessInfo.processInfo.environment["A"] }
            let closedF: () -> Void = { _ = ProcessInfo.processInfo.environment["B"] }
            // bare `f()` — implicit self
            func bareOpen() { openF() }
            func bareClosed() { closedF() }
            // `map(f)` — implicit-self fn-ref passed to a sync invoker
            func refOpen() { [1].forEach { _ in openF() } }
        }
        func memberOpen(_ b: Box) { b.openF() }        // `obj.f()`
        func memberClosed(_ b: Box) { b.closedF() }
        let b = Box()
        b.bareOpen(); b.bareClosed(); b.refOpen(); memberOpen(b); memberClosed(b)
        """
        let by = try scan(src, "R96b")
        for open in ["Box.bareOpen", "Box.refOpen", "memberOpen"] {
            XCTAssertTrue(effects(by, open).contains("Unknown"), "\(open) = \(effects(by, open)) — expected Unknown")
            XCTAssertTrue(effects(by, open).contains("Env"), "\(open) = \(effects(by, open)) — default must survive")
        }
        for closed in ["Box.bareClosed", "memberClosed"] {
            XCTAssertEqual(effects(by, closed), ["Env"], "\(closed) is a `let` — exactly resolved, no hedge")
        }
    }
}
