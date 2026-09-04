import XCTest
import Foundation

/// R192 — A CLOSURE READ OUT OF A **CONTAINER** WAS NOT A CALLABLE SOURCE, SO THE INVOKING FUNCTION WAS
/// ABSENT FROM `functions[]` WHILE THE OPTIONAL-CHAINED TWIN DISCLOSED ONE LINE AWAY.
///
/// A published cardinal sin, re-measured on the shipped `candor-swift 0.35.0 (spec 0.35)` binary with
/// ground truth EXECUTED: `if let h = handlers["k"] { h() }` over a `[String: Cb]` field, the plainly
/// spelled `[String: () -> Void]` twin, `if let c = list.first`, and the tuple element `pair.0` were all
/// ABSENT, while `handlers["k"]?()` was correctly `['Unknown'] callback:computed`. `deny Unknown
/// H.fireDictIfLet` exited **0** with *"policy rule matched NO function"* for every silent shape and 1
/// for the control — the signature of this class, because the caller was never judged at all.
///
/// IT IS R178'S DEFECT ONE LEVEL OF NESTING OUT, IN BOTH HALVES, AND THAT IS WHY THE FIX HAS TWO PARTS.
///
/// *The expression half.* `callableValue` — the single authority R178 introduced for *"is this value
/// CALLED, not merely read?"* — answered only for a `DeclReference`, a `MemberAccess`, `??` and a
/// ternary. A SUBSCRIPT, an element accessor (`first`/`last`/`randomElement()`) and a TUPLE ELEMENT
/// reached no arm, so all fourteen R178 binder spellings went silent again the moment the closure came
/// out of a container. Extending that one predicate fixes every binder at once, which is the whole
/// point of there being one.
///
/// *The type half, and it is the wider defect.* `typeName` answers `(name: nil, isFunction: true)` for a
/// function type, so every container index that projects an element through `typeName(…).name` —
/// `arrayElem`, `dictElem`, `tupleElem`, `fieldArrayElem`, `fieldDictValue`, and the param/global twins
/// — DROPPED a `[() -> Void]` / `[K: () -> Void]` / `(() -> Void, Int)` element entirely. That is the
/// same projection bug R178 found for `typealias Cb = () -> Void`, which is exactly why the alias
/// spelling was half-recognisable (the index records the NAME `Cb`) and the plain spelling was not.
/// The indexes are now COMPLETED with a reserved `FUNCTION_TYPE_ELEMENT` spelling rather than shadowed
/// by a parallel `isFunction` map — §G, and R178's own move.
///
/// GROUND TRUTH IS EXECUTED, NOT ASSUMED (§E3). `containerFixture` compiles and runs as a program:
/// every `fire*` really invokes the closure and every `ctl*` really does not, verified by a counter
/// bumped inside the closure body. ABSENCE is what a broken engine and a genuinely pure function both
/// produce, so an absence control over a fixture that cannot run asserts nothing.
///
/// THE OVER-CHARGE CONTROLS ARE THE OTHER HALF OF THE ROW, and they are the direction this change can
/// go wrong in: a predicate that answered "callable" for any subscript or any `.first` would put a
/// spurious `Unknown` on a large fraction of ordinary Swift. `ctlNumSubscript` (a `[String: Int]`),
/// `ctlStoreFirst` (a `[Store]`), `ctlNumFirst` (an `[Int]`) and `ctlTupleNum` (an `(Int, Int)`) read
/// out of containers whose element is NOT callable and must stay absent; `ctlBoundNeverCalled` and
/// `ctlDictRead` do hold a real closure and never invoke it, and must stay absent too — the charge is
/// owed by the INVOCATION, not by the read.
final class ContainerCallableSourceTests: XCTestCase {

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

    private func effects(_ f: [String: Any]?) -> Set<String> { Set((f?["inferred"] as? [String]) ?? []) }
    private func why(_ f: [String: Any]?) -> Set<String> { Set((f?["unknownWhy"] as? [String]) ?? []) }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // The fixture. It COMPILES AND RUNS — see `testFixtureGroundTruthExecutes`.
    // ────────────────────────────────────────────────────────────────────────────────────────────────
    static let containerFixture = """
    import Foundation

    typealias Cb = () -> Void

    struct Store { func write() { try? "x".write(toFile: "/tmp/r192-store.txt", atomically: true, encoding: .utf8) } }

    final class H {
      var cb: Cb? = nil
      var handlers: [String: Cb] = [:]                // alias-spelled dictionary of closures
      var plainHandlers: [String: () -> Void] = [:]   // plainly-spelled dictionary of closures
      var list: [Cb?] = []                            // array of OPTIONAL closures
      var plainList: [() -> Void] = []                // array of closures
      var nums: [String: Int] = [:]                   // NOT callable  (over-charge control)
      var numList: [Int] = []                         // NOT callable  (over-charge control)
      var stores: [Store] = []                        // NOT callable  (over-charge control)
      var unused: Cb? = nil                           // callable, NEVER invoked  (control)

      func install() {
        cb            = { _ = try? String(contentsOfFile: "/tmp/r192-a.txt") }
        handlers["k"] = { _ = try? String(contentsOfFile: "/tmp/r192-b.txt") }
        plainHandlers["k"] = { _ = try? String(contentsOfFile: "/tmp/r192-c.txt") }
        list          = [{ _ = try? String(contentsOfFile: "/tmp/r192-d.txt") }]
        plainList     = [{ _ = try? String(contentsOfFile: "/tmp/r192-e.txt") }]
        unused        = { _ = try? String(contentsOfFile: "/tmp/r192-f.txt") }
        nums["k"] = 1; numList = [1]; stores = [Store()]
      }

      // the honest baselines the row is measured against — already `callback:computed` pre-fix
      func fireDictChain()      { handlers["k"]?() }
      func fireDictDirect()     { handlers["k"]!() }
      func fireListIdx()        { plainList[0]() }

      // ── SUBSCRIPT as the callable source, across the R178 binder spellings
      func fireDictIfLet()      { if let h = handlers["k"] { h() } }
      func fireDictPlainIfLet() { if let h = plainHandlers["k"] { h() } }
      func fireDictGuard()      { guard let h = handlers["k"] else { return }; h() }
      func fireDictMap()        { _ = handlers["k"].map { $0() } }
      func fireDictSwitch()     { switch handlers["k"] { case .some(let h): h(); case .none: break } }
      func fireDictCaseQ()      { if case let h? = handlers["k"] { h() } }
      func fireDictCoalesce()   { let h = handlers["k"] ?? {}; h() }
      func fireDictUnannLet()   { let h = handlers["k"]; h?() }

      // ── ELEMENT ACCESSOR as the callable source
      func fireListFirst()      { if let c = list.first, let cc = c { cc() } }
      func fireListFirstPlain() { if let c = plainList.first { c() } }
      func fireListLast()       { if let c = plainList.last { c() } }
      func fireListRandom()     { if let c = plainList.randomElement() { c() } }

      // ── TUPLE ELEMENT as the callable source
      func fireTupleLet()       { let pair: (Cb?, Int) = (cb, 1); if let c = pair.0 { c() } }
      func fireTupleLabel()     { let p: (cb: Cb?, n: Int) = (cb, 1); if let c = p.cb { c() } }

      // ── OVER-CHARGE CONTROLS — every one of these must stay ABSENT
      func ctlNumSubscript()    { if let n = nums["k"] { _ = n + 1 } }
      func ctlNumFirst()        { if let n = numList.first { _ = n + 1 } }
      func ctlStoreFirst()      { if let s = stores.first { _ = s } }
      func ctlTupleNum()        { let p: (Int, Int) = (1, 2); _ = p.0 + p.1 }
      func ctlBoundNeverCalled(){ if let c = unused { _ = c } }
      func ctlDictRead()        { _ = handlers["k"] }
      func ctlPure()            { _ = 1 + 1 }

      // ── the R178 shadow controls, re-asked through a SUBSCRIPT source. A binder mark is name-keyed
      //    and deliberately NOT scoped, so a same-named concrete local either side of the unwrap must
      //    still resolve: both of these must keep `Fs` AND gain `Unknown`.
      func shadowAfter()        { if let c = handlers["k"] { c() }; let c = Store(); c.write() }
      func shadowBefore()       { let c = Store(); c.write(); if let c = handlers["k"] { c() } }
    }
    """

    /// Every shape whose caller was ABSENT on the shipped 0.35.0 binary and must now disclose.
    static let mustDisclose = [
        "H.fireDictIfLet", "H.fireDictPlainIfLet", "H.fireDictGuard", "H.fireDictMap",
        "H.fireDictSwitch", "H.fireDictCaseQ", "H.fireDictCoalesce", "H.fireDictUnannLet",
        "H.fireListFirst", "H.fireListFirstPlain", "H.fireListLast", "H.fireListRandom",
        "H.fireTupleLet", "H.fireTupleLabel",
    ]

    /// Must stay ABSENT: the element read out of the container is not callable, or it is never invoked.
    static let mustStayAbsent = [
        "H.ctlNumSubscript", "H.ctlNumFirst", "H.ctlStoreFirst", "H.ctlTupleNum",
        "H.ctlBoundNeverCalled", "H.ctlDictRead", "H.ctlPure",
    ]

    /// THE ROW. Absence is the cardinal sin's signature, so this asserts PRESENCE with a §4 reason —
    /// not merely that something changed.
    func testAClosureReadOutOfAContainerDisclosesAtItsInvoker() throws {
        let by = try scan(Self.containerFixture, "R192")
        for fn in Self.mustDisclose {
            let f = by[fn]
            XCTAssertNotNil(f, "\(fn) is ABSENT from functions[] — the R192 cardinal sin. It really "
                             + "invokes the closure (see testFixtureGroundTruthExecutes).")
            XCTAssertTrue(effects(f).contains("Unknown"),
                          "\(fn) must carry Unknown in `inferred` — SPEC §4 binds the obligation to the "
                          + "effect set, not to `unresolved`, which no `deny` route reads. got \(effects(f))")
            XCTAssertEqual(f?["unresolved"] as? Bool, true, "\(fn) must set unresolved: true")
            XCTAssertTrue(why(f).contains { $0.hasPrefix("callback:") || $0.hasPrefix("dispatch:") },
                          "\(fn)'s reason must be a §4 `callback:`/`dispatch:` kind — an Unknown with no "
                          + "reason is the R180 shape. got \(why(f))")
        }
    }

    /// The direction the fix can go wrong in. Widening a SOURCE predicate can only add disclosures, so
    /// over-charge is the only failure mode available to it — and a subscript or a `.first` that is not
    /// over a container of closures is overwhelmingly the common case in real Swift.
    func testANonCallableContainerElementIsNotCharged() throws {
        let by = try scan(Self.containerFixture, "R192ctl")
        for fn in Self.mustStayAbsent {
            XCTAssertNil(by[fn], "\(fn) reads a NON-callable element (or never invokes what it read) and "
                               + "must stay absent — it performs nothing at runtime (see "
                               + "testFixtureGroundTruthExecutes). got \(effects(by[fn]))")
        }
    }

    /// The already-honest baselines must not move. `handlers["k"]?()` was `callback:computed` before the
    /// fix and is the answer the binder spellings are being brought into line WITH; a fix that changed
    /// this row would have replaced the reference point rather than matched it.
    func testTheOptionalChainedBaselineIsUnchanged() throws {
        let by = try scan(Self.containerFixture, "R192base")
        for fn in ["H.fireDictChain", "H.fireDictDirect", "H.fireListIdx"] {
            XCTAssertEqual(effects(by[fn]), ["Unknown"], "\(fn) must stay exactly `['Unknown']`")
            XCTAssertEqual(why(by[fn]), ["callback:computed"], "\(fn) must stay `callback:computed`")
        }
    }

    /// A container element has NO owner to name. `H.handlers` owns the DICTIONARY, not the closure —
    /// SPEC §4 ⟨0.7⟩'s `dispatch:owner.member` is normative about the CALLABLE's owner, and answering
    /// `dispatch:H.handlers` would publish a wrong normative detail, which is worse than none. So every
    /// container source must say `callback:`, matching the optional-chained twin's `callback:computed`.
    func testAContainerElementClaimsNoOwner() throws {
        let by = try scan(Self.containerFixture, "R192own")
        for fn in Self.mustDisclose {
            // NON-EMPTY FIRST. `allSatisfy` over an ABSENT function's empty reason set is vacuously
            // true, so without this line the whole test passed on the reverted engine — a control that
            // cannot discriminate the fix from its absence reads as coverage and is worse than none (§A).
            XCTAssertFalse(why(by[fn]).isEmpty, "\(fn) must carry a §4 reason")
            XCTAssertTrue(why(by[fn]).allSatisfy { $0.hasPrefix("callback:") },
                          "\(fn) reads its callable out of a CONTAINER and has no owner to name — got "
                          + "\(why(by[fn]))")
        }
    }

    /// The binder mark is name-keyed and NOT scoped (`markOpaqueCallableBinding`, R178). A same-named
    /// concrete local either side of the unwrap must still resolve, so these keep `Fs` from `Store.write`
    /// AND gain the `Unknown` the invocation owes. Losing the `Fs` here would be a silent under-report
    /// introduced BY this fix — the shape §feedback-fabrication-fixes-cause-misses is about.
    func testASameNamedConcreteLocalStillResolvesEitherSideOfTheUnwrap() throws {
        let by = try scan(Self.containerFixture, "R192shadow")
        for fn in ["H.shadowAfter", "H.shadowBefore"] {
            XCTAssertEqual(effects(by[fn]), ["Fs", "Unknown"],
                           "\(fn) really does both at runtime — it writes through Store AND invokes the "
                           + "stored closure. got \(effects(by[fn]))")
        }
    }

    /// THE SECOND-ORDER EFFECT OF COMPLETING THE ELEMENT INDEXES, measured rather than asserted. Two
    /// arms in the collector key on an element index being NON-NIL rather than on what it says, and the
    /// first draft of the Classifier comment claimed the reserved spelling "types nothing and can
    /// fabricate nothing". That was false: the local-`extension Array` dispatch arm now resolves for a
    /// `[() -> Void]` receiver, exactly as it already did for the nominal `[Int]` twin. It is recall the
    /// arm was written for and could not reach — the soft edge still resolves only against a unit the
    /// project really declares, so the PURE extension method stays absent — but it is a behaviour
    /// change outside R192's own shape and it is pinned here rather than left to be rediscovered.
    func testALocalArrayExtensionResolvesOverAFunctionElement() throws {
        let src = """
        import Foundation
        extension Array {
          func runAll() { }
          func touchAll() { try? "z".write(toFile: "/tmp/r192-arrext.txt", atomically: true, encoding: .utf8) }
        }
        func viaArrayExtEff(_ xs: [() -> Void]) { xs.touchAll() }
        func viaArrayExtPure(_ xs: [() -> Void]) { xs.runAll() }
        func viaArrayExtNominal(_ xs: [Int]) { xs.touchAll() }
        """
        let by = try scan(src, "R192arr")
        XCTAssertEqual(effects(by["viaArrayExtEff"]), ["Fs"],
                       "a `[() -> Void]` receiver must resolve the project's own Array extension, as the "
                       + "nominal twin already does")
        XCTAssertEqual(effects(by["viaArrayExtNominal"]), ["Fs"],
                       "the one-variable control: same call, nominal element — this was already `['Fs']` "
                       + "before the change and is what makes the row above recall rather than a guess")
        XCTAssertNil(by["viaArrayExtPure"],
                     "the PURE extension method must stay absent — the soft edge resolves against a real "
                     + "unit, it does not charge the receiver for being an Array")
    }

    /// §E3 — the fixture must COMPILE AND RUN, and every claim above must match what it actually does.
    /// Without this the absence controls assert something about nothing.
    func testFixtureGroundTruthExecutes() throws {
        #if os(macOS) || os(Linux)
        let env = URL(fileURLWithPath: "/usr/bin/env")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r192-gt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let instrumented = Self.containerFixture
            .replacingOccurrences(of: "import Foundation", with: "import Foundation\nvar FIRES = 0")
            .replacingOccurrences(of: "= { _ = try?", with: "= { FIRES += 1; _ = try?")
            .replacingOccurrences(of: "= [{ _ = try?", with: "= [{ FIRES += 1; _ = try?")
            + """

            let h = H(); h.install()
            var log: [String: Bool] = [:]
            func chk(_ n: String, _ body: () -> Void) { let b = FIRES; body(); log[n] = FIRES > b }
            chk("fireDictChain", h.fireDictChain); chk("fireDictDirect", h.fireDictDirect)
            chk("fireListIdx", h.fireListIdx)
            chk("fireDictIfLet", h.fireDictIfLet); chk("fireDictPlainIfLet", h.fireDictPlainIfLet)
            chk("fireDictGuard", h.fireDictGuard); chk("fireDictMap", h.fireDictMap)
            chk("fireDictSwitch", h.fireDictSwitch); chk("fireDictCaseQ", h.fireDictCaseQ)
            chk("fireDictCoalesce", h.fireDictCoalesce); chk("fireDictUnannLet", h.fireDictUnannLet)
            chk("fireListFirst", h.fireListFirst); chk("fireListFirstPlain", h.fireListFirstPlain)
            chk("fireListLast", h.fireListLast); chk("fireListRandom", h.fireListRandom)
            chk("fireTupleLet", h.fireTupleLet); chk("fireTupleLabel", h.fireTupleLabel)
            chk("ctlNumSubscript", h.ctlNumSubscript); chk("ctlNumFirst", h.ctlNumFirst)
            chk("ctlStoreFirst", h.ctlStoreFirst); chk("ctlTupleNum", h.ctlTupleNum)
            chk("ctlBoundNeverCalled", h.ctlBoundNeverCalled); chk("ctlDictRead", h.ctlDictRead)
            chk("ctlPure", h.ctlPure)
            for (k, v) in log.sorted(by: { $0.key < $1.key }) { print("\\(v ? "FIRES" : "quiet") \\(k)") }
            """
        let srcFile = dir.appendingPathComponent("gt.swift")
        try instrumented.write(to: srcFile, atomically: true, encoding: .utf8)
        let exe = dir.appendingPathComponent("gt")
        let build = try ProcessHarness.run(env, ["swiftc", "-o", exe.path, srcFile.path])
        XCTAssertEqual(build.code, 0, "the fixture must COMPILE — an unrunnable control is no control:\n"
                                    + build.err)
        let run = try ProcessHarness.run(exe, [])
        XCTAssertEqual(run.code, 0, run.err)
        var fired: Set<String> = [], quiet: Set<String> = []
        for line in run.out.split(separator: "\n") {
            let p = line.split(separator: " ")
            guard p.count == 2 else { continue }
            if p[0] == "FIRES" { fired.insert(String(p[1])) } else { quiet.insert(String(p[1])) }
        }
        for fn in Self.mustDisclose {
            let leaf = fn.split(separator: ".").last.map(String.init) ?? fn
            XCTAssertTrue(fired.contains(leaf), "\(leaf) must actually invoke the closure at runtime — "
                                              + "the disclosure claim depends on it")
        }
        for fn in Self.mustStayAbsent {
            let leaf = fn.split(separator: ".").last.map(String.init) ?? fn
            XCTAssertTrue(quiet.contains(leaf), "\(leaf) must NOT invoke any closure at runtime — the "
                                              + "absence control depends on it")
        }
        #else
        throw XCTSkip("no swiftc on this host")
        #endif
    }
}
