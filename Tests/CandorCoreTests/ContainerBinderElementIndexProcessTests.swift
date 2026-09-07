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

    private static let head = """
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

    // ── 5. THE REMAINING SILENCE, PINNED AS KNOWN — a NESTED CONTAINER, not a binder ─────────────
    // `for case let z in [cbs]` is silent, and so are its plain-`for` and fully-annotated twins, which
    // is what proves the axis is the nested container rather than the `case let`. Filed as its own row.
    // Asserted as SILENT deliberately: when that row is closed this test goes red and names itself.
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
        for fn in ["T.plainFor", "T.caseFor", "T.annotated"] {
            XCTAssertNil(r.fns[fn],
                         "\(fn) is KNOWN-SILENT: a container of containers loses the inner element "
                         + "index in EVERY binder, including the plain `for` and the fully annotated "
                         + "local — a nested-container row, not a binder-form one. When that row is "
                         + "closed this assertion goes red and names itself: \(r.out)")
        }
        XCTAssertEqual(r.code, 1, "`deny Fs Unknown T.direct` must FAIL: \(r.out)")
    }
}
