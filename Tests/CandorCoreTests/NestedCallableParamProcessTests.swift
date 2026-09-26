import XCTest
import Foundation

/// **SOUNDNESS R725 — A FN-TYPED PARAMETER OF A NESTED `func`, AND ONE OF A CLOSURE, REACHED NO
/// INVOCATION-SITE AUTHORITY AT ALL, so invoking it read SILENT-PURE.** Plus the third arm the R721
/// audit named and did not probe: the UNANNOTATED `var` twin of a visible closure literal.
///
/// Three spellings of ONE program disagreed at HEAD `ecdff3b`, measured with the enclosing body held
/// byte-identical and only the binder shape varying:
///
///     func encl(_ cb: (String)->Void) { func inner(_ f: (String)->Void) { f("x") }; inner(cb) }  ABSENT
///     func encl(_ cb: (String)->Void) { let g = { (f: (String)->Void) in f("x") }; g(cb) }       ABSENT
///     func encl(_ cb: (String)->Void) { let g: ((String)->Void)->Void = {…}; g(cb) }             Unknown
///
/// and unlike [[R280]]/[[R720]] the silence is NOT call-site dependent — it is identical with and
/// without a caller, because nothing ever reached `callbackInvoked`.
///
/// **THE TWO ARMS HAVE DIFFERENT MECHANISMS, and R721's row states only the first.** Measured by
/// copying the parameter into a local (`let h = f; h("x")`), which DISCLOSES `callback:h` for the
/// CLOSURE arm and stays ABSENT for the nested-func arm:
///   · a nested func's function-typed parameter is in **no index** — `parameterTypeNameForShadow`
///     returns nil for a function type and `visit(FunctionDeclSyntax)` `removeValue`s the name;
///   · a closure's function-typed parameter **is** in `vars`, under the reserved
///     `FUNCTION_TYPE_ELEMENT` spelling, and it is the BARE-INVOCATION arm that never asked. The
///     ALIAS spelling of the nested arm (`func inner(_ f: Cb)`) is the same story — `vars["f"] = "Cb"`
///     was recorded and never read.
///
/// So the fix is `callableName`'s own third clause, asked at the invocation site (§G — one authority),
/// plus the ONE index write the nested arm was missing. `fnTyped` is deliberately NOT touched: R721
/// priced an `fnTyped.insert` and correctly found it needs a scope, but the scope it proposed —
/// `ShadowSave` — would reclassify a map whose `NameKeyedStateTests` entry says it is a HEDGE that
/// must never be scoped. `vars` is already scoped for exactly this binder by R534's
/// `nestedFuncSavedVars`, so the narrow fix needs no new map and no new disposition.
///
/// CASE 3 IS THE LOSS DIRECTION AND IT IS THE REASON THIS FILE EXISTS BEFORE THE FIX: a nested
/// parameter named after a real FREE function must not silence that free function once the nested
/// scope closes — in either the bare-call or the argument position. It is written with a
/// DISTINGUISHABLE effect (`Env` from the free function, `Unknown` from the parameter) so a loss is
/// visible as a missing effect rather than as an unchanged row.
final class NestedCallableParamProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], why: [String: [String]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--out", root.appendingPathComponent("r").path]
        if let policy {
            let p = root.appendingPathComponent("pol.txt")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        let d = try? JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String]] = [:], why: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
            why[n] = ((f["unknownWhy"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
            blind[n] = ((f["invisible"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, why, r.code, r.out + r.err)
    }

    /// Per-row `invisible`, filled by the same `scan` call. A separate dictionary rather than a wider
    /// tuple because exactly one test reads it.
    private var blind: [String: [String]] = [:]

    static let head = """
    import Foundation
    typealias Cb = (String) -> Void
    func envFree(_ s: String) { _ = ProcessInfo.processInfo.environment[s] }
    func bomb(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    """

    // ── 1. THE BINDER SHAPES OF ONE PROGRAM ──────────────────────────────────────────────────────
    // `annotatedBinder` is the discriminator IN THE SAME SCAN: the spelling that has been honest since
    // R720, and the answer the other three have to match. EXECUTED separately — each of these really
    // deletes its probe file when `cb` is `bomb` (see PROVE-IT note in the commit message).
    func testEveryCallableParameterShapeDisclosesItsInvocation() throws {
        let src = Self.head + """
        struct T {
            func nestedFunc(_ cb: (String) -> Void)  { func inner(_ f: (String) -> Void) { f("x") }; inner(cb) }
            func nestedAlias(_ cb: Cb)               { func inner(_ f: Cb) { f("x") }; inner(cb) }
            func closureParam(_ cb: (String) -> Void) { let g = { (f: (String) -> Void) in f("x") }; g(cb) }
            func annotatedBinder(_ cb: (String) -> Void) {
                let g: ((String) -> Void) -> Void = { (f: (String) -> Void) in f("x") }
                g(cb)
            }
        }
        """
        let r = try scan(src, name: "Shapes")
        for arm in ["T.nestedFunc", "T.nestedAlias", "T.closureParam", "T.annotatedBinder"] {
            XCTAssertEqual(r.fns[arm], ["Unknown"],
                           "\(arm) must disclose the invocation of a callable it cannot see — got "
                           + "\(r.fns[arm].map(String.init(describing:)) ?? "ABSENT from functions[]")")
        }
    }

    // …AND THE SILENCE IS NOT CALL-SITE DEPENDENT, which is what separates this row from R280/R720.
    // Both arms of this scan are byte-identical bodies; only the presence of a caller differs.
    func testTheDisclosureDoesNotDependOnACallSite() throws {
        let src = Self.head + """
        struct T {
            func noCaller(_ cb: (String) -> Void)  { func inner(_ f: (String) -> Void) { f("x") }; inner(cb) }
            func hasCaller(_ cb: (String) -> Void) { func inner(_ f: (String) -> Void) { f("x") }; inner(cb) }
            func drive() { hasCaller({ s in _ = s }) }
        }
        """
        let r = try scan(src, name: "CallSite")
        XCTAssertEqual(r.fns["T.noCaller"], ["Unknown"])
        XCTAssertEqual(r.fns["T.hasCaller"], ["Unknown"])
    }

    // ── 2. THE `var` ARM R721 NAMED AND DID NOT PROBE ────────────────────────────────────────────
    // `var g = { … }; g = x; g()` — an unannotated binder over a VISIBLE closure literal, then
    // REASSIGNED from a caller-supplied value. The annotated twin one character away is honest, and is
    // the discriminator in the same scan.
    func testAReassignedUnannotatedClosureVarDisclosesLikeItsAnnotatedTwin() throws {
        let src = Self.head + """
        struct T {
            func varUnannotated(_ x: @escaping (String) -> Void) { var g = { (_: String) in }; g = x; g("p") }
            func varAnnotated(_ x: @escaping (String) -> Void)   { var g: (String) -> Void = { _ in }; g = x; g("p") }
        }
        """
        let r = try scan(src, name: "VarArm")
        XCTAssertEqual(r.fns["T.varAnnotated"], ["Unknown"], "the annotated twin is the control and was honest before this fix")
        XCTAssertEqual(r.fns["T.varUnannotated"], ["Unknown"],
                       "a reassignable closure var invoked is Unknown — got "
                       + "\(r.fns["T.varUnannotated"].map(String.init(describing:)) ?? "ABSENT from functions[]")")
    }

    // ── 3. THE LOSS DIRECTION — a same-named FREE function must not be silenced ──────────────────
    // THE REGRESSION THE OBVIOUS FIX CAUSES. A nested parameter named `envFree` shadows the free
    // `envFree` INSIDE the nested func and nowhere else. If the index write leaks past
    // `visitPost(FunctionDeclSyntax)` — which is exactly what an unscoped `fnTyped.insert` does — the
    // two free calls below stop resolving and `Env` DISAPPEARS from the row while `Unknown` stays, so
    // the row still looks disclosed. `baseline` holds the free calls alone.
    func testASameNamedFreeFunctionSurvivesTheNestedParameterThatShadowedIt() throws {
        let src = Self.head + """
        struct T {
            func baseBare() { envFree("PATH") }
            func baseArg()  { ["A"].forEach(envFree) }
            func shadowedBare(_ cb: (String) -> Void) {
                func inner(_ envFree: (String) -> Void) { envFree("x") }
                inner(cb)
                envFree("PATH")
            }
            func shadowedArg(_ cb: (String) -> Void) {
                func inner(_ envFree: (String) -> Void) { envFree("x") }
                inner(cb)
                ["A"].forEach(envFree)
            }
        }
        """
        let r = try scan(src, name: "LossCtl")
        XCTAssertEqual(r.fns["T.baseBare"], ["Env"], "the free function's own effect, with no nested func in sight")
        XCTAssertEqual(r.fns["T.baseArg"], ["Env"], "…and through the argument position")
        // ONE POSITION PER UNIT, and that is not tidiness — it is the reason this fixture has teeth.
        // Written as ONE unit containing BOTH positions it was VACUOUS against the leak it exists for:
        // the bare call keeps resolving through the default arm's edge, so its `Env` masked the
        // argument position losing its own. MEASURED — dropping `nestedFuncSavedVars`' restore left the
        // combined form GREEN and left 1350/1350 of this repo's suite green with it. Split, the
        // argument arm alone goes red, because `namesAFreeFunctionReference` reads `vars[name] == nil`
        // and a leaked callable spelling refuses the free-function edge.
        XCTAssertEqual(r.fns["T.shadowedBare"], ["Env", "Unknown"],
                       "Env from the free `envFree` after the nested scope closed, Unknown from the parameter")
        XCTAssertEqual(r.fns["T.shadowedArg"], ["Env", "Unknown"],
                       "…and through the argument position, which reads a different predicate")
    }

    /// …AND THE SCOPE ITSELF, PINNED FROM THE OVER-DISCLOSURE SIDE, WHICH IS THE SIDE THIS FIX CAN
    /// ACTUALLY FAIL ON.
    ///
    /// R534 saves and restores `vars` per nested-func id in `nestedFuncSavedVars`, and this fix's
    /// soundness argument rests on that restore — so the restore needs a test, and it did not have one:
    /// **deleting it left all 1350 tests in this repo green**, R534's own `nestedFuncShadow` included,
    /// because that test was written for the INWARD direction (the enclosing type leaking into the
    /// nested body) and the restore is the OUTWARD one. Filed as SOUNDNESS R726.
    ///
    /// The discriminator has to be a unit where the nested parameter itself contributes NO `Unknown` —
    /// it is bound and never invoked — so the only thing that can disclose is a LEAKED spelling on the
    /// free call below. Every arm of the fixture above carries a legitimate `Unknown`, which is exactly
    /// why none of them can see this.
    ///
    /// NOTE THE DIRECTION, because it is the whole argument for `vars` over `fnTyped`: a leak here is a
    /// SPURIOUS disclosure on a row that is otherwise honest — it costs precision. The `fnTyped` design
    /// R721 priced fails the other way, and the arm above measures it: with an unscoped `fnTyped.insert`
    /// the free function's `Env` DISAPPEARS.
    func testTheNestedParameterSpellingDoesNotOutliveTheNestedFunc() throws {
        let src = Self.head + """
        struct T {
            func leakCtl() {
                func inner(_ envFree: (String) -> Void) { _ = envFree }
                inner({ _ in })
                envFree("PATH")
            }
        }
        """
        let r = try scan(src, name: "LeakCtl")
        XCTAssertEqual(r.fns["T.leakCtl"], ["Env"],
                       "the nested parameter is never invoked, so the only reachable answer is the free "
                       + "function's Env — an added Unknown here means the callable spelling leaked past "
                       + "`visitPost(FunctionDeclSyntax)`")
        XCTAssertNil(r.why["T.leakCtl"]?.first, "…and no `callback:` reason, for the same reason")
    }

    // ── 4. PRECISION CONTROLS — the direction the fix did not intend ─────────────────────────────
    // A nested func whose parameter is NOT callable gains nothing; a `let` bound to a visible closure
    // literal keeps its exact lexical charge, because a `let` cannot be reassigned.
    func testANonCallableNestedParameterAndAClosedLetGainNothing() throws {
        let src = Self.head + """
        struct T {
            func nestedNonCallable(_ p: String) {
                func inner(_ s: String) { _ = ProcessInfo.processInfo.environment[s] }
                inner(p)
            }
            func letVisibleClosure() {
                let g = { (s: String) in _ = ProcessInfo.processInfo.environment[s] }
                g("p")
            }
        }
        """
        let r = try scan(src, name: "Precision")
        XCTAssertEqual(r.fns["T.nestedNonCallable"], ["Env"], "a String parameter is not a callable")
        XCTAssertEqual(r.fns["T.letVisibleClosure"], ["Env"], "a `let` closure literal is closed — no hedge")
    }

    // …AND THE PRICE THAT WAS SHIPPED RATHER THAN EXEMPTED. A `var` bound to a visible closure literal
    // and never reassigned gains a hedge whose honest answer is none. It is here so the cost is a
    // pinned measurement rather than a surprise, and it is exactly what the ANNOTATED twin has already
    // charged since before this row — the two spellings now agree, which is the point.
    func testAnUnreassignedClosureVarPaysTheSameHedgeItsAnnotatedTwinAlreadyPaid() throws {
        let src = Self.head + """
        struct T {
            func varUn()  { var g = { (s: String) in _ = ProcessInfo.processInfo.environment[s] }; _ = g; g("p") }
            func varAnn() { var g: (String) -> Void = { s in _ = ProcessInfo.processInfo.environment[s] }; _ = g; g("p") }
        }
        """
        let r = try scan(src, name: "VarPrice")
        XCTAssertEqual(r.fns["T.varAnn"], ["Env", "Unknown"], "the annotated twin's standing price")
        XCTAssertEqual(r.fns["T.varUn"], ["Env", "Unknown"], "and the unannotated twin now matches it")
    }

    // ── 4b. THE ORDERING, WHICH IS THE ASSERTION THIS FIX MAKES ABOUT ITSELF ─────────────────────
    /// **THE DISCLOSURE IS ADDED BESIDE THE CALL EDGE, NOT INSTEAD OF IT — and the first cut of this fix
    /// did it the other way and was caught by a 25-package A/B, not by a test. This is that test.**
    ///
    /// Written as an `else if` above the bare-call chain's default arm, the new disclosure preempted that
    /// arm's `calls.append`, and the unresolved edge is what attributes the file's BLIND MODULES to the
    /// row. swift-nio's `EmbeddedChannelCore.addToBuffer` therefore gained `callback:consume` and **LOST
    /// `DequeModule` from `invisible`** — on that row and on four more by propagation. A row that keeps
    /// its `Unknown` and loses the name of the module the scan could not see still READS disclosed, which
    /// is why only a differential found it.
    ///
    /// `MysteryKit` is a module no classifier covers and nothing needs to exist for it: the engine is a
    /// syntactic scan, so the import alone puts it in this file's blind set. If the arm is ever hoisted
    /// back above `calls.append`, `invisible` goes empty here and this goes red.
    func testTheDisclosureIsAddedBesideTheCallEdgeAndNotInsteadOfIt() throws {
        let src = """
        import Foundation
        import MysteryKit
        struct T {
            func viaNested(_ cb: (String) -> Void) {
                func inner(_ g: (String) -> Void) { g("x") }
                inner(cb)
            }
        }
        """
        let r = try scan(src, name: "Additive")
        XCTAssertEqual(r.fns["T.viaNested"], ["Unknown"], "the disclosure")
        XCTAssertEqual(r.why["T.viaNested"], ["callback:g"], "…and its reason")
        XCTAssertEqual(blind["T.viaNested"], ["MysteryKit"],
                       "…AND the blind-module attribution the unresolved edge carries. Losing this while "
                       + "keeping the Unknown is the regression the A/B caught in the first cut.")
    }

    // ── 5. THE GATE ─────────────────────────────────────────────────────────────────────────────
    func testDenyUnknownFailsOnEveryShape() throws {
        for (arm, body) in [
            ("nested",  "func inner(_ f: (String) -> Void) { f(\"x\") }; inner(cb)"),
            ("closure", "let g = { (f: (String) -> Void) in f(\"x\") }; g(cb)"),
        ] {
            let src = Self.head + """
            func encl(_ cb: (String) -> Void) { \(body) }
            """
            let r = try scan(src, name: "Gate", policy: "deny Unknown encl\n")
            XCTAssertEqual(r.code, 1, "`deny Unknown encl` must FAIL on the \(arm) shape; got exit \(r.code)")
        }
    }
}
