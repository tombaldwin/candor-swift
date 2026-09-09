import XCTest
import Foundation

/// **SOUNDNESS R269 — SIX BINDER FORMS OF A CONTAINER COPY CARRIED NO ELEMENT INDEX, so invoking a
/// callable out of the copy read SILENT-PURE.**
///
/// R215 gave the plain `let ys = xs` copy its element index; R192/R211 made a container of callables a
/// callable source. The other binder forms in the grammar reached none of that machinery: the TUPLE
/// PATTERN, `case let` in a switch, `if case let` / `guard case let`, an `Optional(…)`-wrapped
/// `guard let`, the tuple-ELEMENT read, and every DICTIONARY spelling through a binder (that site asked
/// `elementTypeOf` and never `dictValueOf`). Each reported the enclosing function **ABSENT from
/// `functions[]` — no row, no `Unknown`** — while the direct spelling of the same program is correctly
/// `Unknown callback:`. Measured on a generated 78-cell matrix, every cell compiled and EXECUTED, over a
/// stored field, a function parameter and a local alike; scoped `deny Fs`, `pure`, `deny Unknown` and
/// `deny Fs Unknown` all exited 0 on every one.
///
/// **TWO OF THE ORIGINAL ROW'S THREE CLAIMS DID NOT SURVIVE MEASUREMENT, and the row records that rather
/// than dropping it.** It named an ANNOTATED CLOSURE PARAMETER as the third silent form: **not
/// reproduced in four spellings** — immediately-invoked, a named closure variable, a closure passed to a
/// function, and a closure stored on an object — every one of which discloses `Unknown` at v0.35.0 and
/// at HEAD. Case 4 below pins all four so the claim cannot quietly return. Separately, `for case let z
/// in [cbs]` IS silent, but it is NOT a binder-form gap: the plain `for z in [cbs]` and a fully
/// annotated `let g: [[(String) -> Void]]` are equally silent, so it is a NESTED-CONTAINER gap — filed
/// as its own row, deliberately not fixed here, and pinned as a known-silent case (5) so closing it
/// later has a control.
///
/// FIXED THROUGH ONE HELPER, `bindContainerIndex`, called from every binder site — because R124 already
/// enumerates nine binder forms in this file and this index was read by one of them (§F1.3).
final class ContainerBinderElementIndexProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], code: Int32, out: String) {
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
        var by: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, r.code, r.out + r.err)
    }

    static let head = """
    import Foundation
    func bomb(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

    """

    // ── 1. THE BINDER FORMS, over a STORED FIELD ─────────────────────────────────────────────────
    // `direct` is the discriminator in the same scan: the spelling that was always disclosed, and the
    // answer every other form has to match. EXECUTED — each really deletes its probe file.
    func testEveryBinderFormOfAContainerCopyCarriesItsElementIndex() throws {
        let src = Self.head + """
        class T {
            let cbs: [(String) -> Void] = [bomb]
            let opt: [(String) -> Void]? = [bomb]
            let dic: [String: (String) -> Void] = ["k": bomb]
            func direct(_ p: String)    { for c in cbs { c(p) } }
            func tuplePat(_ p: String)  { let (z, _) = (cbs, 1); for c in z { c(p) } }
            func tupleSelf(_ p: String) { let (z, _) = (self.cbs, 1); for c in z { c(p) } }
            func caseLet(_ p: String)   { switch cbs { case let z: for c in z { c(p) } } }
            func ifCaseLet(_ p: String) { if case let z? = opt { for c in z { c(p) } } }
            func guardWrap(_ p: String) { guard let z = Optional(cbs) else { return }; for c in z { c(p) } }
            func tupleElem(_ p: String) { let t = (cbs, 1); for c in t.0 { c(p) } }
            func dictBind(_ p: String)  { guard let z = Optional(dic) else { return }
                                          for (_, c) in z { c(p) } }
        }
        let t = T()
        t.direct("/tmp/bind-a"); t.tuplePat("/tmp/bind-b"); t.tupleSelf("/tmp/bind-c")
        t.caseLet("/tmp/bind-d"); t.ifCaseLet("/tmp/bind-e"); t.guardWrap("/tmp/bind-f")
        t.tupleElem("/tmp/bind-g"); t.dictBind("/tmp/bind-h")
        """
        let r = try scan(src, name: "BindField", policy: "deny Fs Unknown T.tuplePat\n")
        XCTAssertEqual(r.fns["T.direct"], ["Unknown"],
                       "THE DISCRIMINATOR: the direct spelling was always disclosed: \(r.out)")
        for fn in ["T.tuplePat", "T.tupleSelf", "T.caseLet", "T.ifCaseLet",
                   "T.guardWrap", "T.tupleElem", "T.dictBind"] {
            XCTAssertEqual(r.fns[fn], ["Unknown"],
                           "\(fn): the copy really invokes a closure that deletes the file — it must "
                           + "disclose exactly as the direct spelling does: \(r.out)")
        }
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown T.tuplePat`, SCOPED, must FAIL: \(r.out)")
    }

    // ── 2. THE SAME FORMS over a PARAMETER and a LOCAL ───────────────────────────────────────────
    // The source axis: the matrix found the binder answer identical over all three, so the fix must be
    // about the BINDER and not about where the container came from.
    func testTheBinderFormsAnswerTheSameOverAParameterAndALocal() throws {
        let src = Self.head + """
        class T {
            func viaParam(_ p: String) { helper([bomb], p) }
            func helper(_ src: [(String) -> Void], _ p: String) {
                let (z, _) = (src, 1); for c in z { c(p) }
            }
            func viaLocal(_ p: String) {
                let src: [(String) -> Void] = [bomb]
                switch src { case let z: for c in z { c(p) } }
            }
        }
        T().viaParam("/tmp/bind-i"); T().viaLocal("/tmp/bind-j")
        """
        let r = try scan(src, name: "BindSrc", policy: "deny Fs Unknown T.helper\n")
        XCTAssertEqual(r.fns["T.helper"], ["Unknown"], "tuple pattern over a PARAMETER: \(r.out)")
        XCTAssertEqual(r.fns["T.viaLocal"], ["Unknown"], "`case let` over a LOCAL: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown T.helper` must FAIL: \(r.out)")
    }

    // ── 3. OVER-CHARGE CONTROL: a binder over a NON-container must not gain an element index ─────
    // The direction this fix fails in if `bindContainerIndex` is asked too eagerly: binding a scalar's
    // copy as though it were a container would resolve later calls against a type it does not have.
    func testABinderOverANonContainerIsUnchanged() throws {
        let src = Self.head + """
        class Quiet { func go() { } }
        class Loud { func go() { try? FileManager.default.removeItem(atPath: "/tmp/bind-k") } }
        class T {
            func scalar() { let (q, _) = (Quiet(), 1); q.go() }
            func loud()   { let (l, _) = (Loud(), 1); l.go() }
        }
        T().scalar(); T().loud()
        """
        let r = try scan(src, name: "BindScalar", policy: "deny Fs T.scalar\n")
        XCTAssertNil(r.fns["T.scalar"],
                     "a tuple-pattern copy of a SCALAR must still resolve to its own type and stay "
                     + "pure — the container arm must not claim it: \(r.out)")
        XCTAssertEqual(r.fns["T.loud"], ["Fs"],
                       "REACH INSTRUMENT: the same binder over an effectful scalar in the same scan "
                       + "still resolves, so the assertion above is not an inert scan: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Fs T.scalar` must PASS: \(r.out)")
    }

    // ── 4. THE CLAIM THAT DID NOT REPRODUCE — pinned so it cannot quietly return ─────────────────
    // The original row named an ANNOTATED CLOSURE PARAMETER as a silent form. Four spellings, all
    // disclosed at v0.35.0 and at HEAD. Recorded as measured rather than dropped.
    func testAnAnnotatedClosureParameterWasNeverSilent() throws {
        let src = Self.head + """
        typealias CB = [(String) -> Void]
        func applyIt(_ v: CB, _ f: (CB) -> Void) { f(v) }
        final class Box { var f: ((CB) -> Void)? }
        class T {
            let cbs: CB = [bomb]
            func iife(_ p: String)   { ({ (z: CB) in for c in z { c(p) } })(cbs) }
            func named(_ p: String)  { let g: (CB) -> Void = { (z: CB) in for c in z { c(p) } }; g(cbs) }
            func passed(_ p: String) { applyIt(cbs) { (z: CB) in for c in z { c(p) } } }
            func stored(_ p: String) { let b = Box(); b.f = { (z: CB) in for c in z { c(p) } }; b.f?(cbs) }
        }
        let t = T()
        t.iife("/tmp/bind-l"); t.named("/tmp/bind-m"); t.passed("/tmp/bind-n"); t.stored("/tmp/bind-o")
        """
        let r = try scan(src, name: "BindClosure", policy: "deny Fs Unknown T.iife\n")
        for fn in ["T.iife", "T.passed", "T.stored"] {
            XCTAssertEqual(r.fns[fn], ["Unknown"],
                           "\(fn): an annotated closure parameter carrying the container was ALREADY "
                           + "disclosed — the row's third claim, not reproduced: \(r.out)")
        }
        XCTAssertNil(r.fns["T.named"],
                     "the FOURTH spelling — a closure bound to a local ANNOTATED VARIABLE — is silent "
                     + "here, and NOT for the reason this row is about: see case 6, where the trigger is "
                     + "isolated to the enclosing function HAVING A CALL SITE, not to the binder: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown T.iife` must FAIL: \(r.out)")
    }

    // ── 6. A SEPARATE SILENCE FOUND WHILE PINNING CASE 4, isolated and NOT fixed here ─────────────
    // `let g: ([Cb]) -> Void = { … }; g(cbs)` is disclosed `Unknown` while the enclosing function has NO
    // caller, and goes ABSENT the moment ANY call site exists — including one that passes a plain
    // String, which cannot have re-resolved anything. Two functions, byte-identical bodies, one scan:
    // the ONLY difference is the call site, which is what makes this a measurement rather than a guess.
    // Deliberately left OPEN: it is callback-flow's deferred resolution rather than a binder index, a
    // different vein with a much wider blast radius, and it is filed as its own row. Asserted as SILENT
    // so that closing that row turns this red and names itself.
    func testAnAnnotatedClosureVariableLosesItsDisclosureOnceItsFunctionIsCalled() throws {
        let src = Self.head + """
        class T {
            let cbs: [(String) -> Void] = [bomb]
            func called(_ p: String) {
                let g: ([(String) -> Void]) -> Void = { (z: [(String) -> Void]) in for c in z { c(p) } }
                g(cbs)
            }
            func uncalled(_ p: String) {
                let g: ([(String) -> Void]) -> Void = { (z: [(String) -> Void]) in for c in z { c(p) } }
                g(cbs)
            }
        }
        T().called("/tmp/bind-t")
        """
        let r = try scan(src, name: "BindCalledVsNot", policy: "deny Fs Unknown T.uncalled\n")
        XCTAssertEqual(r.fns["T.uncalled"], ["Unknown"],
                       "THE DISCRIMINATOR: the identical body with NO call site discloses: \(r.out)")
        XCTAssertNil(r.fns["T.called"],
                     "KNOWN-SILENT, filed as its own row: the same body goes ABSENT once a call site "
                     + "exists — the call passes a String and cannot have resolved the closure, so the "
                     + "trigger is the existence of the caller, not its argument: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown T.uncalled` must FAIL: \(r.out)")
    }

    // ── 5. THE NESTED CONTAINER — R278, now CLOSED for every DECLARED spelling ───────────────────
    // This test was written asserting all three were SILENT, with the note "when that row is closed
    // this assertion goes red and names itself". It did exactly that, which is the only reason a pin
    // is worth writing: the `annotated` case now DISCLOSES and the assertion below is inverted.
    //
    // The two ARRAY-LITERAL spellings are still pinned, and the reason is specific rather than "not
    // done yet": `elementTypeOf` has an arm for a literal that answers from the first element
    // EXPRESSION's name, so `[cbs]` yields `"cbs"` — a variable name used as a type name. It resolves
    // to nothing downstream, so it costs nothing today, but it is a WRONG ANSWER rather than a refusal,
    // and because it answers, R278's nested arm (an `else if` after it) never runs. Closing these two
    // means making that arm REFUSE when its element is itself a container, which is a change to a path
    // every array literal takes — deliberately not bundled into this row.
    func testANestedContainerIsStillSilentAndThatIsADifferentRow() throws {
        let src = Self.head + """
        class T {
            let cbs: [(String) -> Void] = [bomb]
            func plainFor(_ p: String)  { for z in [cbs] { for c in z { c(p) } } }
            func caseFor(_ p: String)   { for case let z in [cbs] { for c in z { c(p) } } }
            func annotated(_ p: String) { let g: [[(String) -> Void]] = [cbs]
                                          for z in g { for c in z { c(p) } } }
            func direct(_ p: String)    { for c in cbs { c(p) } }
        }
        let t = T()
        t.plainFor("/tmp/bind-p"); t.caseFor("/tmp/bind-q")
        t.annotated("/tmp/bind-r"); t.direct("/tmp/bind-s")
        """
        let r = try scan(src, name: "BindNested", policy: "deny Fs Unknown T.direct\n")
        XCTAssertEqual(r.fns["T.direct"], ["Unknown"],
                       "REACH INSTRUMENT: one container out, the same scan discloses: \(r.out)")
        XCTAssertEqual(r.fns["T.annotated"], ["Unknown"],
                       "R278 CLOSED for the declared spelling: `let g: [[(String) -> Void]]` now gives "
                       + "its outer binder the INNER element, so the inner loop resolves the closure and "
                       + "the caller discloses. This assertion was `XCTAssertNil` until the row closed, "
                       + "and it went red and named itself, exactly as it was written to: \(r.out)")
        // …and these two closed the same day, which is why the pin is worth writing rather than the
        // silence merely noted. The cause was never the nesting: `elementTypeOf`'s literal arm answers
        // from the first element EXPRESSION's name, so `[cbs]` yielded `"cbs"` — a variable name read as
        // a type name — and because it ANSWERED, the nested arm after it never ran. `nestedElementOf`
        // now has its own literal arm, and the binder asks NESTED FIRST so a genuinely nested literal
        // reaches the resolver that can type it. This assertion has now been inverted TWICE by the row
        // it was written to track.
        for fn in ["T.plainFor", "T.caseFor"] {
            XCTAssertEqual(r.fns[fn], ["Unknown"],
                           "\(fn) must disclose: `for z in [cbs]` is a literal whose element is itself a "
                           + "container, so the binder takes the INNER element and the inner loop "
                           + "resolves the stored closure: \(r.out)")
        }
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown T.direct` must FAIL: \(r.out)")
    }

    // ── 6. R278's ROW — every DECLARED nested-container spelling, and the controls that make the
    //       fix a fix rather than a blanket charge ────────────────────────────────────────────────
    func testEveryDeclaredNestedContainerSpellingReachesItsInnerElement() throws {
        let src = Self.head + """
        class G { func run(_ p: String) { bomb(p) } }
        class C { func run(_ p: String) -> Int { return 7 } }     // SAME member name, no effect
        class H {
            var flat:    [G]            = [G()]
            var nested:  [[G]]          = [[G()]]
            var generic: Array<Array<G>> = [[G()]]
            var pureN:   [[C]]          = [[C()]]
            var ints:    [[Int]]        = [[1]]
            func direct(_ p: String)   { for g in flat { g.run(p) } }
            func nestFor(_ p: String)  { for z in nested { for g in z { g.run(p) } } }
            func nestEach(_ p: String) { nested.forEach { z in z.forEach { $0.run(p) } } }
            func nestGen(_ p: String)  { for z in generic { for g in z { g.run(p) } } }
            func nestLocal(_ p: String) { let n: [[G]] = nested; for z in n { for g in z { g.run(p) } } }
            func nestParam(_ p: String, _ n: [[G]]) { for z in n { for g in z { g.run(p) } } }
            func ctlPure(_ p: String)  { for z in pureN { for c in z { _ = c.run(p) } } }
            func ctlInts()             { for z in ints { for i in z { _ = i + 1 } } }
            func ctlRebind(_ p: String) { let n: [[C]] = pureN; for z in n { for c in z { _ = c.run(p) } } }
        }
        let h = H()
        h.direct("/tmp/r278-a"); h.nestFor("/tmp/r278-b"); h.nestEach("/tmp/r278-c")
        h.nestGen("/tmp/r278-d"); h.nestLocal("/tmp/r278-e"); h.nestParam("/tmp/r278-f", [[G()]])
        h.ctlPure("/tmp/r278-g"); h.ctlInts(); h.ctlRebind("/tmp/r278-h")
        """
        let r = try scan(src, name: "R278Nested", policy: "deny Fs Unknown H.direct\n")

        // `Fs`, not `Unknown`: `G.run` is a LOCAL class calling a local `bomb`, so the element resolves
        // to a concrete effect rather than to a hedge. That is the stronger assertion — it says the
        // binder reached the right TYPE, not merely that something was disclosed about it.
        XCTAssertEqual(r.fns["H.direct"], ["Fs"],
                       "REACH INSTRUMENT: one container out, same scan, must charge Fs: \(r.out)")

        for fn in ["H.nestFor", "H.nestEach", "H.nestGen", "H.nestLocal", "H.nestParam"] {
            XCTAssertEqual(r.fns[fn], ["Fs"],
                           "\(fn) must charge Fs: the outer binder of a container-of-containers takes "
                           + "the INNER element, so the inner loop resolves. ABSENT here is R278's "
                           + "cardinal sin — the body really invokes a closure that deletes a file. "
                           + "`nestGen` is the `Array<Array<G>>` spelling, which is the one where "
                           + "`arrayElementName` ANSWERS (with \"Array\") rather than refusing, and is "
                           + "why the nested question must be asked FIRST: \(r.out)")
        }

        // The controls. An adapter TYPES an element; it must not CHARGE one.
        for fn in ["H.ctlPure", "H.ctlInts", "H.ctlRebind"] {
            XCTAssertNil(r.fns[fn],
                         "\(fn) must stay ABSENT. `ctlPure`/`ctlRebind` iterate a nested container whose "
                         + "element's `run` is PURE and shares its name with the effectful one, so a "
                         + "binder typed from the wrong container shows up here as a fabrication rather "
                         + "than as a silence: \(r.out)")
        }
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown H.direct` must FAIL: \(r.out)")
    }

    // ── 7. R351 — THE TWO ELEMENT INDEXES DESCRIBE ONE BINDING AND MUST MOVE TOGETHER ────────────
    // `setArrayElem`'s own comment has said this since it was written: "arrayElem and opaqueElem
    // describe the same binding and must move together … one writer, so the pair can never drift."
    // R278 added a THIRD map for that same binding and joined it to neither writer. A name could then
    // carry a live FLAT entry and a stale NESTED one at once, and because the `for` binder asks the
    // nested resolver first, the stale one won.
    //
    // `regression` below charged Fs on the PUBLISHED v0.35.0 and went ABSENT at HEAD — a regression
    // against a shipped artifact, not merely against an unreleased commit. `control` differs from it
    // only in the parameter's declared type, which is what pins the cause to the index rather than to
    // the loop, the element or the rebind.
    static let lockstepBody = """
    class G { func run(_ p: String) { bomb(p) } }
    class P { func run(_ p: String) -> Int { return 7 } }
    class T {
      func regression(_ n: [[G]], _ p: [G])  { let n: [G] = p; for z in n { z.run("/tmp/r351-a") } }
      func unannCopy(_ n: [[G]], _ p: [G])   { let n = p; for z in n { z.run("/tmp/r351-b") } }
      func mirror(_ n: [G], _ q: [[G]])      { let n: [[G]] = q
                                               for zs in n { for z in zs { z.run("/tmp/r351-c") } } }
      func control(_ n: Int, _ p: [G])       { let n: [G] = p; for z in n { z.run("/tmp/r351-d") } }
      func ctlPure(_ n: [[P]], _ p: [P])     { let n: [P] = p; for z in n { _ = z.run("/tmp/r351-e") } }
    }
    """

    func testTheFlatAndNestedElementIndexesMoveTogether() throws {
        let r = try scan(Self.head + Self.lockstepBody, name: "R351Lockstep", policy: "deny Fs T.control\n")

        XCTAssertEqual(r.fns["T.control"], ["Fs"],
                       "REACH INSTRUMENT: identical body, the parameter's TYPE is the only "
                       + "difference. If this is absent the fixture is broken, not the engine: \(r.out)")

        XCTAssertEqual(r.fns["T.regression"], ["Fs"],
                       "T.regression is R351: a flat `let` rebind left the parameter's NESTED entry "
                       + "standing, and the `for` binder asks nested FIRST, so the stale entry won and "
                       + "the caller became a purity claim over a body that writes a file. This shape "
                       + "charged on the PUBLISHED v0.35.0 — absence here is a regression against a "
                       + "shipped artifact: \(r.out)")

        for fn in ["T.unannCopy", "T.mirror"] {
            XCTAssertEqual(r.fns[fn], ["Fs"],
                           "\(fn) must disclose. These two were ABSENT on v0.35.0 as well — the "
                           + "lockstep closes them in both directions, which is why the fix is a pair "
                           + "of writers and not a single clear: \(r.out)")
        }

        XCTAssertNil(r.fns["T.ctlPure"],
                     "T.ctlPure must stay ABSENT. It is the same shape over an element whose `run` is "
                     + "PURE, so a binder typed from the wrong container surfaces here as a "
                     + "fabrication rather than as a silence: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown T.control` must FAIL: \(r.out)")
    }

    // ── 8. R358 — BOTH clears of the R351 pair, and the shadow guard they broke ───────────────────
    // R351 added a SECOND writer (`setArrayElemNested`) that clears `arrayElem` + `opaqueElem`. A
    // review found that half had NO TEETH: reducing it to the bare `arrayElemNested[name] = inner`
    // left the suite at 1129/1129 with every row identical. It also found what that untested half
    // did — a name rebound to a nested container stopped appearing in ANY index the
    // `DeclReferenceExprSyntax` shadow guard consults, so it fell through to a module-scope global of
    // the same name and charged that global's initializer effect. A hard charge on a body that
    // reaches nothing.
    //
    // WHAT THIS TEST PINS — measured by stubbing each half in turn against the FULL suite:
    //   · guard reverted (`|| arrayElemNested[n] != nil` removed)  -> 2 failures: shadow, pureNested
    //   · `setArrayElem`'s `arrayElemNested.removeValue` removed   -> 4 failures: staleNested, the
    //        `deny Fs` exit, and R351's own regression + unannCopy rows
    //   · `setArrayElemNested`'s `arrayElem.removeValue` removed   -> 1 failure: staleFlat
    // All three halves have teeth.
    //
    // AN EARLIER VERSION OF THIS COMMENT SAID THE OPPOSITE — that `staleFlat`/`staleNested` did not
    // discriminate, that "neither clear of the R351 pair is pinned by any fixture I could construct",
    // and that therefore "one of them is doing nothing … or that clear should be removed". Every part
    // of that was wrong, and a review caught it. **The recommendation it invited — deleting
    // `setArrayElemNested`'s clear — is measured to cause a SILENT UNDER-REPORT** (`staleFlat` goes
    // ABSENT over a body that writes a file), so the false claim pointed directly at a cardinal sin.
    //
    // The measurement was wrong for a reason worth keeping: the stub was applied with a string
    // `.replace(..., 1)` on `arrayElemNested.removeValue(forKey: name)`, which appears TWICE in
    // `CallCollector.swift` — it landed in `clearBindingTypeOnly`, not in `setArrayElem` — and the
    // run used `swift test --filter`, which excluded the R351 rows that would have failed. Two
    // instruments, both wrong in the direction that produced a comfortable answer. Anchor a stub on
    // the enclosing FUNCTION's body, and run the full suite. SOUNDNESS R351/R358.
    static let pairFixture = """
    class G { func run(_ p: String) { bomb(p) } }
    class Q { func run(_ p: String) -> Int { return 7 } }
    let g: [String] = { bomb("/tmp/r358-glob"); return [] }()
    class T {
      // the NESTED rebind must shadow the effectful global `g` — R358
      func shadow(_ g: [G], _ q: [[G]]) -> Int { let g: [[G]] = q; return g.count }
      func pureNested(_ q: [[G]]) -> Int { let g: [[G]] = q; return g.count }
      // control: the FLAT rebind, which always shadowed correctly
      func shadowFlat(_ g: [G], _ p: [G]) -> Int { let g: [G] = p; return g.count }
      // a stale FLAT entry must not survive a nested rebind — needs setArrayElemNested's clear
      func staleFlat(_ n: [Q], _ q: [[G]]) { let n: [[G]] = q; n.forEach { $0.forEach { $0.run("/tmp/r358-a") } } }
      // a stale NESTED entry must not survive a flat rebind — needs setArrayElem's clear
      func staleNested(_ n: [[Q]], _ p: [G]) { let n: [G] = p; for x in n { x.run("/tmp/r358-b") } }
    }
    """

    func testBothClearsOfThePairAreGuardedAndTheShadowGuardKnowsTheNestedIndex() throws {
        let r = try scan(Self.head + Self.pairFixture, name: "R358Pair",
                         policy: "deny Fs T.staleNested\n")

        for fn in ["T.shadow", "T.pureNested", "T.shadowFlat"] {
            XCTAssertNil(r.fns[fn],
                         "\(fn) must be ABSENT. Its body only reads `g.count`; charging it means the "
                         + "local rebind stopped shadowing the module-scope global `g` and the reference "
                         + "edged to that global's effectful initializer — a hard charge on a function "
                         + "that reaches nothing. R358: the shadow guard must consult `arrayElemNested` "
                         + "alongside `arrayElem`/`dictElem`/`vars`/`fnTyped`: \(r.out)")
        }
        XCTAssertEqual(r.fns["T.staleNested"], ["Fs"],
                       "T.staleNested must charge Fs: `n` is rebound FLAT to [G], so `setArrayElem` has "
                       + "to drop the stale NESTED entry or the nested resolver answers first and the "
                       + "loop resolves against the wrong element: \(r.out)")
        XCTAssertEqual(r.fns["T.staleFlat"], ["Fs"],
                       "T.staleFlat must charge Fs: `n` is rebound NESTED to [[G]], so "
                       + "`setArrayElemNested` has to drop the stale FLAT entry or the flat resolver "
                       + "answers first. Measured: removing that clear makes this row ABSENT — a "
                       + "silent under-report over a body that writes a file: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs T.staleNested` must FAIL: \(r.out)")
    }
}
