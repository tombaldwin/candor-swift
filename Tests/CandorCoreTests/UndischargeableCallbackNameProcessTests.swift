import XCTest
import Foundation

/// SOUNDNESS R720 — A DEFERRED CALLBACK NAME THAT CALL-SITE FLOW CAN NEVER DISCHARGE.
///
/// Callback-flow (Driver.swift, the R125/R126/R127 lineage) drops a deferred invocation's `Unknown`
/// iff every visible call site of the enclosing function passes something resolvable AT THE
/// PARAMETER POSITION the invoked name occupies. The judgment is therefore written as a loop over
/// `info.indexes`, the fn-typed PARAM positions of the names in `callbackInvoked`.
///
/// `callbackInvoked` can hold a name that has NO parameter position at all:
///   · an ANNOTATED fn-typed LOCAL (`let g: ([(String) -> Void]) -> Void = { … }`) — `CallCollector`
///     inserts an annotated fn-typed binder into `fnTyped`, and the invocation site's
///     `fnTyped.contains(name)` arm cannot tell a local from a param. (The UNANNOTATED twin removes
///     the name from `fnTyped` at the binder, which is why only the annotated spelling was affected.)
///   · a fn-typed parameter of a NESTED function or closure — collected into the ENCLOSING unit,
///     whose `fnTypedParamIndex` has never heard of that name.
///
/// For such a name `info.indexes` gains nothing, so `for idx in info.indexes` iterates ZERO times and
/// `resolved` keeps its initial `!argLists.isEmpty`. **The discharge test is VACUOUSLY TRUE the moment
/// any caller exists**: `allCallersResolved` stays true, the `Unknown` is written to neither the caller
/// nor the enclosing function, and a function that provably invokes an unaddressable value drops out
/// of `functions` entirely — which under ⟨0.21⟩ is an affirmative purity claim.
///
/// With NO caller the `byCaller.isEmpty` fallback still marks the row, which is why the symptom is
/// "the disclosure vanishes the moment the enclosing function has a call site" and why two
/// BYTE-IDENTICAL bodies in one scan disagree. That differential is the measurement R280 was filed on
/// (2026-09-07) and it still reproduced at `796700a` (2026-09-26).
///
/// THE FIXTURE BELOW WAS `swift build`-ED AND RUN (§E3): it creates the probe file, calls
/// `runAllWithCaller`, and prints `probe still exists after runAllWithCaller() == false` — the closure
/// in the array really does delete a file, through a value `runAllWithCaller` cannot address. On
/// `796700a` `runAllWithCaller` was ABSENT from `functions` and `deny Unknown runAllWithCaller` exited
/// **0**, while `deny Unknown runAllNoCaller` exited 1.
final class UndischargeableCallbackNameProcessTests: XCTestCase {

    private func scan(_ src: String, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: UndischargeableCallbackNameProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    /// Scan `src` under a one-line policy, return the exit code (0 clean / 1 violation / 2 unevaluable).
    /// The SCAN+`--policy` form, which is the form a repo gates with.
    private func policyExit(_ src: String, _ rule: String) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: UndischargeableCallbackNameProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("p.policy")
        try (rule + "\n").write(to: pol, atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("out")
        let r = try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", out.path])
        return r.code
    }

    /// VERBATIM the program that was built and run. `p` is a plain `String` param, deliberately: it
    /// keeps the enclosing rows free of any effect of their own, so ABSENCE is unambiguous rather than
    /// masked by an incidental `Fs` from reading a global probe path.
    private static let r720Fixture = """
    import Foundation

    // A locally-bound ANNOTATED closure variable. Its body invokes an element of the array it is
    // handed — a value `runAllWithCaller` cannot address. It HAS a visible caller below.
    func runAllWithCaller(_ p: String, _ cbs: [(String) -> Void]) {
        let g: ([(String) -> Void]) -> Void = { list in for c in list { c(p) } }
        g(cbs)
    }
    // BYTE-IDENTICAL body. The only difference: nothing in this scan calls it.
    func runAllNoCaller(_ p: String, _ cbs: [(String) -> Void]) {
        let g: ([(String) -> Void]) -> Void = { list in for c in list { c(p) } }
        g(cbs)
    }

    let probe = NSTemporaryDirectory() + "r720probe.txt"
    FileManager.default.createFile(atPath: probe, contents: Data("x".utf8))
    runAllWithCaller(probe, [{ q in try? FileManager.default.removeItem(atPath: q) }])
    print("probe still exists == \\(FileManager.default.fileExists(atPath: probe))")
    """

    func testAnnotatedClosureLocalKeepsItsDisclosureWhenTheEnclosingFunctionHasACaller() throws {
        let by = try scan(UndischargeableCallbackNameProcessTests.r720Fixture)
        XCTAssertEqual(ProcessHarness.inferred(by, "runAllWithCaller"), ["Unknown"],
                       "THE DEFECT: having a caller must not delete the disclosure. This row was "
                       + "ABSENT — a ⟨0.21⟩ purity claim over a function that provably invokes a "
                       + "caller-supplied closure; got \(by["runAllWithCaller"] ?? [:])")
        XCTAssertEqual(by["runAllWithCaller"]?["unknownWhy"] as? [String], ["callback:g"],
                       "…naming the binder it cannot address, exactly as the caller-less twin does")
        // THE DISCRIMINATING CONTROL, correct before and after: the byte-identical twin with no caller.
        // It is the arm that made the loss visible, and it must not move.
        XCTAssertEqual(ProcessHarness.inferred(by, "runAllNoCaller"), ["Unknown"],
                       "the caller-less twin was always correct — held constant across the fix")
        XCTAssertEqual(by["runAllNoCaller"]?["unknownWhy"] as? [String], ["callback:g"],
                       "…and its reason is unchanged")
    }

    func testScopedDenyUnknownFiresOnTheArmThatHasACaller() throws {
        let src = UndischargeableCallbackNameProcessTests.r720Fixture
        // THE DEFECT at the exit code a repo gates on: 0 before the fix, 1 after.
        XCTAssertEqual(try policyExit(src, "deny Unknown runAllWithCaller"), 1,
                       "a scoped `deny Unknown` on the caller-having arm must fire")
        // The control that proves the rule FORM works at all.
        XCTAssertEqual(try policyExit(src, "deny Unknown runAllNoCaller"), 1,
                       "the caller-less twin fired before and after")
        // THE OVER-CHARGE CONTROL, and it says what the fix does NOT claim: the `Fs` belongs to the
        // closure the top level passed, not to the callee. Fabricating it here is the mirror sin.
        XCTAssertEqual(try policyExit(src, "deny Fs runAllWithCaller"), 0,
                       "the fix adds the honest Unknown, never the caller's concrete effect")
    }

    /// ROUTE 2 — a fn-typed parameter of a NESTED FUNCTION or a CLOSURE is the OTHER way a non-param
    /// name reaches `callbackInvoked`, and only the spelling that goes through an ANNOTATED BINDER is
    /// this fix's. `let g: ((String) -> Void) -> Void = { f in f("x") }` puts `g` (the binder) in
    /// `fnTyped` with no parameter position, so the vacuity applied to it exactly as above; the
    /// disclosure names the BINDER, not the closure parameter, and `g` is what the caller can see.
    ///
    /// The sibling spellings where the binder itself is NOT in `fnTyped` — a nested `func inner(_ f:
    /// (String) -> Void) { f("x") }`, and `let g = { (f: (String) -> Void) in f("x") }` — are silent
    /// for a DIFFERENT reason (the nested/closure parameter is in no index of the enclosing collector at
    /// all, so nothing ever reaches `callbackInvoked`) and are NOT call-site dependent: they are ABSENT
    /// with and without a caller. That is SOUNDNESS R721, filed separately with its own executed ground
    /// truth, and deliberately not pinned here — this suite must keep measuring one thing.
    func testAnnotatedBinderOverAClosureWithAnFnTypedParameterDisclosesTheBinder() throws {
        let by = try scan("""
        import Foundation
        func viaClosureSig(_ cb: @escaping (String) -> Void) {
            let g: ((String) -> Void) -> Void = { f in f("x") }
            g(cb)
        }
        func driver(_ x: @escaping (String) -> Void) { viaClosureSig(x) }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaClosureSig"), ["Unknown"],
                       "the binder has no parameter position, so call-site flow can never discharge it "
                       + "— got \(by["viaClosureSig"] ?? [:])")
        XCTAssertEqual(by["viaClosureSig"]?["unknownWhy"] as? [String], ["callback:g"],
                       "…and it names the binder, which is the name a reader of this function can see")
    }

    /// ROUTE 3 — THE MIXED DEFERRAL, which is why the fix cannot be "skip the judgment when the index
    /// set is empty". `mixed` invokes BOTH a real fn-typed param (`p`, index 0) and an annotated local
    /// (`g`, no index). The one call site passes a NAMED function, so `p`'s deferral discharges
    /// correctly — and on `796700a` that discharged `g`'s along with it, because the two shared one
    /// verdict. The names have to be judged separately.
    func testAResolvedParamDeferralDoesNotDischargeANonParamName() throws {
        let by = try scan("""
        import Foundation
        func namedSink() { try? Data().write(to: URL(fileURLWithPath: "/tmp/r720")) }
        func mixed(_ p: () -> Void, _ cbs: [(String) -> Void]) {
            let g: ([(String) -> Void]) -> Void = { list in for c in list { c("x") } }
            p()
            g(cbs)
        }
        func driver() { mixed(namedSink, []) }
        """)
        XCTAssertEqual(by["mixed"]?["unknownWhy"] as? [String], ["callback:g"],
                       "`p` resolved to namedSink (an edge, no Unknown) and `g` did not — a name with "
                       + "no parameter position can never be discharged by call-site flow, and sharing "
                       + "one verdict with `p` is what discharged it; got \(by["mixed"] ?? [:])")
        XCTAssertEqual(ProcessHarness.inferred(by, "mixed"), ["Unknown"],
                       "…and ONLY the Unknown: the resolved target is edged to the CALLER, never onto "
                       + "`mixed` (the ⟨0.34⟩ per-caller rule). Fabricating Fs here is the mirror sin")
        // THE PRECISION CONTROL for the half that still resolves: `driver` keeps namedSink's Fs, reached
        // by the edge `p`'s discharge added. Losing it would be the mirror under-report.
        XCTAssertEqual(ProcessHarness.inferred(by, "driver"), ["Fs", "Unknown"],
                       "the caller keeps the PRECISELY resolved Fs and inherits `mixed`'s new Unknown")
    }

    // ── MUST-STILL-PASS ───────────────────────────────────────────────────────────────────────────

    /// The UNANNOTATED binding of the same program. `CallCollector` removes it from `fnTyped` at the
    /// binder ("visible local closure: body walks lexically; calling it adds nothing"), so it never
    /// enters `callbackInvoked` and this fix cannot reach it. Pinned so the fix is measured to leave
    /// the spelling it is NOT about exactly where it was — which, with SOUNDNESS R993 switched off, is
    /// still ABSENT.
    ///
    /// SOUNDNESS R993 then CLOSED that absence by a different route: the closure parameter `list` is
    /// annotated `[(String) -> Void]`, a container of callables, and the closure-parameter binder now
    /// records its element, so `c("x")` is the honest `Unknown callback:` the direct spelling already
    /// gives. ABSENT was a silent under-report — a caller passing `[wipe]` deletes a file through it.
    func testTheUnannotatedTwinIsUnchanged() throws {
        let src = """
        import Foundation
        func unannotated(_ cbs: [(String) -> Void]) {
            let g = { (list: [(String) -> Void]) in for c in list { c("x") } }
            g(cbs)
        }
        func driver() { unannotated([]) }
        """
        let off = try scan(src, env: ["CANDOR_R993_OFF": "1"])
        XCTAssertNil(off["unannotated"], "the unannotated spelling is unchanged by this fix "
                     + "(ABSENT before and after) — got \(off["unannotated"] ?? [:])")
        let by = try scan(src)
        XCTAssertEqual(ProcessHarness.inferred(by, "unannotated"), ["Unknown"],
                       "R993 — the container-annotated closure parameter discloses its callable elements; "
                       + "got \(by["unannotated"] ?? [:])")
    }

    /// THE CONTROL FOR THE DIRECTION THIS FIX MUST NOT FAIL IN, and the only one written from a fix that
    /// was actually wrong rather than from an imagined failure.
    ///
    /// `callsiteArgs` is not a complete map of `fq`'s callers: several edge-adding branches (an
    /// unqualified sibling-method call, an overload/init resolution, a CHA/protocol union edge) add a
    /// plain call edge and record no site. Such a caller reaches the per-caller judgment through
    /// `callersOf` with an EMPTY `argLists`, takes `resolved = !argLists.isEmpty` = FALSE, and receives
    /// `Unknown` + `callback:<n>` DIRECTLY — the honest Unknown R125 designed for it.
    ///
    /// THE FIRST VERSION OF THIS FIX TOOK THE UNDISCHARGEABLE NAMES OUT OF `info.names`, which silently
    /// took that reason away from exactly those callers. Measured over 16 real Swift packages, 4 rows lost
    /// their whole `unknownWhy` — `EventLoopFuture._wait`, `ErrorMessageGenerator.makeErrorMessage` and two
    /// `DetailViewController` members — while keeping `inferred: Unknown` by propagation, so no gate
    /// flipped and nothing in the suite noticed. CALIBRATED: re-applying that version makes the two
    /// assertions below read `unknownWhy: nil` on both arms while `Box.owner`/`Impl.run` stay correct.
    ///
    /// Both arms here are untracked by construction — the R127 probe prints `anyResolved=false` for both
    /// owners, which is what says `callsiteArgs` never saw these callers.
    func testAnUntrackedCallerKeepsTheReasonItAlreadyReceived() throws {
        let by = try scan("""
        import Foundation
        struct Box {
            func owner(_ p: String) {
                let g: ([(String) -> Void]) -> Void = { list in for c in list { c(p) } }
                g([])
            }
            func siblingCaller() { owner("/tmp/r720u") }
        }
        protocol P { func run(_ p: String) }
        struct Impl: P {
            func run(_ p: String) {
                let h: ([(String) -> Void]) -> Void = { list in for c in list { c(p) } }
                h([])
            }
        }
        func viaProto(_ x: P) { x.run("/tmp/r720v") }
        func driver(_ b: Box) { b.siblingCaller(); viaProto(Impl()) }
        """)
        XCTAssertEqual(by["Box.siblingCaller"]?["unknownWhy"] as? [String], ["callback:g"],
                       "an UNQUALIFIED SIBLING-METHOD caller records no callsiteArgs site, so it received "
                       + "the reason directly and must keep it: \(by["Box.siblingCaller"] ?? [:])")
        XCTAssertEqual(by["viaProto"]?["unknownWhy"] as? [String], ["callback:h"],
                       "…and so does a caller that reaches the owner through a CHA/protocol union edge: "
                       + "\(by["viaProto"] ?? [:])")
        // The owners, so a failure above cannot be read as "the whole mechanism stopped firing".
        XCTAssertEqual(by["Box.owner"]?["unknownWhy"] as? [String], ["callback:g"], "owner unchanged")
        XCTAssertEqual(by["Impl.run"]?["unknownWhy"] as? [String], ["callback:h"], "owner unchanged")
    }

    /// THE R127-STYLE CONTROL: an annotated local closure whose body reaches an effect this engine CAN
    /// see keeps that effect. The fix adds a disclosure; it must never displace a concrete one.
    func testAnnotatedLocalClosureKeepsTheLexicalEffectOfItsBody() throws {
        let by = try scan("""
        import Foundation
        func writes(_ p: String) {
            let g: (String) -> Void = { s in try? Data().write(to: URL(fileURLWithPath: s)) }
            g(p)
        }
        func driver() { writes("/tmp/r720b") }
        """)
        XCTAssertTrue((ProcessHarness.inferred(by, "writes") ?? []).contains("Fs"),
                      "the closure body walks lexically and its Fs is charged here — the disclosure "
                      + "this fix adds must sit BESIDE it, never instead of it; got "
                      + "\(by["writes"] ?? [:])")
    }

    /// THE PRICE, asserted rather than tolerated — the same posture R127 took. A `let` bound to a
    /// VISIBLE closure literal cannot be reassigned and its body is charged lexically, so the honest
    /// answer for a PURE body is no hedge at all; the fix gives it one, because `callbackInvoked` does
    /// not record which of the two an entry came from and a fail-closed hedge on a visible closure is
    /// the cheap direction against the silent under-report above.
    ///
    /// ITS SIZE IS MEASURED, NOT ASSUMED — see the A/B in the commit message. This assertion exists so
    /// that a later precision fix has to come here and say it changed the answer.
    func testAPureAnnotatedLocalClosureGainsTheHedge() throws {
        let by = try scan("""
        func inert() { }
        func pureBody() {
            let g: () -> Void = { inert() }
            g()
        }
        func driver() { pureBody() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "pureBody"), ["Unknown"],
                       "THE PRICE: a genuinely pure annotated local closure now carries the hedge "
                       + "(ABSENT before). Over-disclosure, in the direction the family accepts; got "
                       + "\(by["pureBody"] ?? [:])")
    }
}
