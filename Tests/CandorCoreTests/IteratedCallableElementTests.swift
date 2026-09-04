import XCTest
import Foundation

/// R211 — A CLOSURE INVOKED WHILE **ITERATING** A CONTAINER WAS SILENT, AND THIS IS THE SPELLING REAL
/// CODE ACTUALLY USES.
///
/// The iteration sibling of R192, and it survived R192's fix: measured on BOTH arms of `020f976`,
/// `for f in handlers { f() }` reported the invoking function ABSENT from `functions[]` — no effects,
/// no `Unknown`, no row — while `handlers.first` one source shape over disclosed correctly. Nineteen
/// spellings were silent on the R192 build, not the five the row named, and the wider sweep is what
/// found the last four of them: an annotated loop binder (`for f: Cb in fs`), an annotated closure
/// parameter (`{ (f: Cb) in f() }`, and its bare `(f: () -> Void)` twin, which read as UNANNOTATED and
/// was cleared), and the `(k, v)` dictionary pair form. EIGHTEEN of the nineteen are closed here; the
/// nineteenth is named below and deliberately left open.
///
/// WHAT THIS DOES NOT CLOSE, MEASURED AND STATED RATHER THAN LEFT TO BE REDISCOVERED. Iterating a
/// container of TUPLES that hold a closure — `for p in pairs { p.cb() }` over `[(cb: () -> Void, n: Int)]`
/// — is still ABSENT, and it really invokes. It is not this predicate's shape: it needs the loop binder
/// to carry a TUPLE ELEMENT index (`tupleElem`) rather than a type name, which no element binder does
/// today, and bolting it on here would be the parallel-path move §G exists to prevent. Filed, not fixed.
///
/// WHY IT SURVIVED R192, WHICH IS THE WHOLE MECHANISM. R192 completed the container element INDEXES
/// (so a `[() -> Void]` element has a recorded spelling at last) and gave `callableValue` — the
/// EXPRESSION half — subscript, element-accessor and tuple-element arms. Iteration binds its element
/// through neither: a `for` pattern binding or a closure parameter records a type NAME in `vars`, and
/// the invocation site for a bare `f()` reads `opaqueFnLocals`/`fnTyped` and never `vars`. So the
/// binder held the reserved function-element spelling, `f()` resolved against no unit at all, and the
/// enclosing function vanished. `bindCallableElement` is the missing half: one authority for all four
/// element binders, routing a CALLABLE spelling to R178's `markOpaqueCallableBinding` instead of to
/// `vars`. It extends R192's own `isCallableTypeName` rather than adding a predicate beside it (§G).
///
/// PREVALENCE IS THE REASON THIS MATTERS MORE THAN R192 DID. `finishHandlers.forEach { $0() }`
/// (Alamofire), `for callout in errorCallouts` (swift-nio), `blocks.forEach { $0() }` (Kingfisher) —
/// but in all three the enclosing function already carries `Unknown` from an unrelated mechanism, so
/// NO CORPUS ROW MOVES and an A/B over those libraries is a fabrication control with no recall claim.
/// The recall evidence is elsewhere; see the commit message.
///
/// GROUND TRUTH IS EXECUTED, NOT ASSUMED (§E3). `iterationFixture` compiles and runs as a program:
/// every `fire*` really invokes the closure and every `ctl*` really does not, verified by a counter
/// bumped inside the closure body. Absence is what a broken engine and a genuinely pure function both
/// produce, so an absence control over a fixture that cannot run asserts nothing.
///
/// THE FAILURE DIRECTION IS OVER-CHARGE AND PRECISION DISPLACEMENT, and both halves are pinned.
/// Extending a source predicate can only ADD disclosures, so a spurious `Unknown` on the overwhelmingly
/// common `for x in xs` is one risk (`ctlIntField`/`ctlIntForEach`/`ctlStorePure`, and the two
/// read-but-never-invoked controls). The second is subtler and is the one that bit R192's fix:
/// `markOpaqueCallableBinding` REMOVES `vars[name]`, so a binder wrongly claimed as callable would stop
/// resolving its members — a silent under-report introduced BY this fix. `keepStoreEff` and
/// `keepStoreForEach` iterate a `[Store]` and must keep the concrete `Store.eff` edge and its `Fs`.
final class IteratedCallableElementTests: XCTestCase {

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
    private func calls(_ f: [String: Any]?) -> Set<String> { Set((f?["calls"] as? [String]) ?? []) }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // The fixture. It COMPILES AND RUNS — see `testFixtureGroundTruthExecutes`.
    // ────────────────────────────────────────────────────────────────────────────────────────────────
    static let iterationFixture = """
    import Foundation

    typealias Cb = () -> Void

    struct Store { func eff() { try? "x".write(toFile: "/tmp/r211-store.txt", atomically: true, encoding: .utf8) } }

    let globalCbs: [() -> Void] = [{ _ = try? String(contentsOfFile: "/tmp/r211-g.txt") }]

    final class H {
      var alias: [Cb] = []                            // alias-spelled array of closures
      var plain: [() -> Void] = []                    // plainly-spelled array of closures
      var dict: [String: () -> Void] = [:]            // plainly-spelled dictionary of closures
      var aliasDict: [String: Cb] = [:]               // alias-spelled dictionary of closures
      var optArr: [(() -> Void)?] = []                // array of OPTIONAL closures
      var ints: [Int] = []                            // NOT callable  (over-charge control)
      var stores: [Store] = []                        // NOT callable  (precision control)

      func install() {
        alias     = [{ _ = try? String(contentsOfFile: "/tmp/r211-a.txt") }]
        plain     = [{ _ = try? String(contentsOfFile: "/tmp/r211-b.txt") }]
        dict["k"] = { _ = try? String(contentsOfFile: "/tmp/r211-c.txt") }
        aliasDict["k"] = { _ = try? String(contentsOfFile: "/tmp/r211-d.txt") }
        optArr    = [{ _ = try? String(contentsOfFile: "/tmp/r211-e.txt") }]
        ints = [1]; stores = [Store()]
      }

      // the honest baselines the row is measured against — R192 and earlier already answer these
      func honestOptChain()     { dict["k"]?() }
      func honestSubscript()    { plain[0]() }
      func honestFirst()        { if let f = plain.first { f() } }

      // ── the `for`-in LOOP BINDER as the callable source
      func fireForAlias()       { for f in alias { f() } }
      func fireForPlain()       { for f in plain { f() } }
      func fireForDictVals()    { for f in dict.values { f() } }
      func fireForAliasVals()   { for f in aliasDict.values { f() } }
      func fireForPair()        { for (_, f) in dict { f() } }
      func fireForVar()         { for var f in plain { f() } }
      func fireForAnnotated()   { for f: Cb in alias { f() } }
      func fireForReversed()    { for f in plain.reversed() { f() } }
      func fireForLocal()       { let ls: [() -> Void] = plain; for f in ls { f() } }
      func fireForParam(_ fs: [() -> Void]) { for f in fs { f() } }
      func fireForOptCase()     { for case let f? in optArr { f() } }

      // ── the ELEMENT CLOSURE PARAMETER as the callable source
      func fireForEach()        { plain.forEach { $0() } }
      func fireForEachNamed()   { plain.forEach { f in f() } }
      func fireForEachParam(_ fs: [() -> Void]) { fs.forEach { $0() } }
      func fireMap()            { _ = plain.map { $0() } }
      func fireFilter()         { _ = plain.filter { $0(); return true } }
      func fireForEachAnnAlias(){ plain.forEach { (f: Cb) in f() } }
      func fireForEachAnnFn()   { plain.forEach { (f: () -> Void) in f() } }

      // ── OVER-CHARGE CONTROLS — every one must stay ABSENT
      func ctlIntLiteral()      { for x in [1, 2] { _ = x + 1 } }
      func ctlIntField()        { for x in ints { _ = x + 1 } }
      func ctlIntForEach()      { ints.forEach { _ = $0 + 1 } }
      func ctlReadNotCalled()   { for f in plain { _ = f } }
      func ctlForEachNotCalled(){ plain.forEach { _ = $0 } }
      func ctlAnnNotCalled()    { plain.forEach { (f: Cb) in _ = f } }
      func ctlAnnInt()          { ints.forEach { (x: Int) in _ = x + 1 } }
      func ctlDictKeyOnly()     { for (k, _) in dict { _ = k } }
      func ctlStorePure()       { for s in stores { _ = s } }

      // ── PRECISION CONTROLS — a concrete element must still resolve its methods
      func keepStoreEff()       { for s in stores { s.eff() } }
      func keepStoreForEach()   { stores.forEach { $0.eff() } }

      // ── the measured second-order effect: a `let` global array of VISIBLE closures
      func fireForGlobal()      { for f in globalCbs { f() } }

      // ── R178's shadow controls, re-asked through an ITERATION source. The binder mark is name-keyed
      //    and deliberately NOT scoped, so a same-named CONCRETE local either side of the loop must
      //    still resolve: both must keep `Fs` and the `Store.eff` edge AND gain the loop's Unknown.
      func shadowAfter()        { for f in plain { f() }; let f = Store(); f.eff() }
      func shadowBefore()       { let f = Store(); f.eff(); for f in plain { f() } }
    }
    """

    /// Every shape whose caller was ABSENT on the R192 build (`020f976`) and must now disclose.
    static let mustDisclose = [
        "H.fireForAlias", "H.fireForPlain", "H.fireForDictVals", "H.fireForAliasVals",
        "H.fireForPair", "H.fireForVar", "H.fireForAnnotated", "H.fireForReversed",
        "H.fireForLocal", "H.fireForParam", "H.fireForOptCase",
        "H.fireForEach", "H.fireForEachNamed", "H.fireForEachParam", "H.fireMap", "H.fireFilter",
        "H.fireForEachAnnAlias", "H.fireForEachAnnFn",
    ]

    /// Must stay ABSENT: the iterated element is not callable, or it is read and never invoked.
    static let mustStayAbsent = [
        "H.ctlIntLiteral", "H.ctlIntField", "H.ctlIntForEach", "H.ctlReadNotCalled",
        "H.ctlForEachNotCalled", "H.ctlAnnNotCalled", "H.ctlAnnInt", "H.ctlDictKeyOnly",
        "H.ctlStorePure",
    ]

    /// THE ROW. Absence is the cardinal sin's signature, so this asserts PRESENCE with a §4 reason —
    /// not merely that something changed.
    func testAClosureInvokedWhileIteratingDisclosesAtItsInvoker() throws {
        let by = try scan(Self.iterationFixture, "R211")
        for fn in Self.mustDisclose {
            let f = by[fn]
            XCTAssertNotNil(f, "\(fn) is ABSENT from functions[] — the R211 cardinal sin. It really "
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

    /// The first failure direction. Extending a source predicate can only add disclosures, and
    /// `for x in xs` / `xs.forEach { … }` over something that is NOT a container of closures is
    /// overwhelmingly the common case in real Swift — a predicate that answered "callable" for any
    /// iterated element would put a spurious `Unknown` on most of a codebase.
    func testANonCallableIteratedElementIsNotCharged() throws {
        let by = try scan(Self.iterationFixture, "R211ctl")
        for fn in Self.mustStayAbsent {
            XCTAssertNil(by[fn], "\(fn) iterates a NON-callable element (or never invokes what it read) "
                               + "and must stay absent — it performs nothing at runtime (see "
                               + "testFixtureGroundTruthExecutes). got \(effects(by[fn]))")
        }
    }

    /// THE SECOND FAILURE DIRECTION, AND IT IS THE ONE THAT BIT R192's FIX: widening one arm displaced
    /// concrete typing elsewhere. `bindCallableElement` routes a claimed name to
    /// `markOpaqueCallableBinding`, which REMOVES `vars[name]` — so a loop binder wrongly claimed as
    /// callable would stop resolving its members and the row would LOSE an effect. That is a silent
    /// under-report introduced by the fix, which is worse than the hole it closes. These two iterate a
    /// `[Store]`, really write a file through `Store.eff`, and must keep both the `Fs` and the edge.
    func testAConcreteIteratedElementStillResolvesItsMethods() throws {
        let by = try scan(Self.iterationFixture, "R211prec")
        for fn in ["H.keepStoreEff", "H.keepStoreForEach"] {
            XCTAssertEqual(effects(by[fn]), ["Fs"],
                           "\(fn) iterates a `[Store]` and really performs Fs — a lost effect here is a "
                           + "silent under-report introduced by this fix. got \(effects(by[fn]))")
            XCTAssertTrue(calls(by[fn]).contains("Store.eff"),
                          "\(fn) must keep the CONCRETE `Store.eff` edge, not merely the effect — losing "
                          + "the edge loses `candor path`. got \(calls(by[fn]))")
        }
    }

    /// The already-honest spellings must not move. They are the answer the iteration binders are being
    /// brought into line WITH; a fix that changed these would have replaced the reference point rather
    /// than matched it.
    func testTheAlreadyHonestSpellingsAreUnchanged() throws {
        let by = try scan(Self.iterationFixture, "R211base")
        for fn in ["H.honestOptChain", "H.honestSubscript"] {
            XCTAssertEqual(effects(by[fn]), ["Unknown"], "\(fn) must stay exactly `['Unknown']`")
            XCTAssertEqual(why(by[fn]), ["callback:computed"], "\(fn) must stay `callback:computed`")
        }
        XCTAssertEqual(effects(by["H.honestFirst"]), ["Unknown"], "R192's own spelling must not move")
        XCTAssertEqual(why(by["H.honestFirst"]), ["callback:f"], "R192's own reason must not move")
    }

    /// AN ITERATED ELEMENT HAS NO OWNER TO NAME. `H.plain` owns the ARRAY, not the closure, and SPEC §4
    /// ⟨0.7⟩'s `dispatch:owner.member` is normative about the CALLABLE's owner — answering
    /// `dispatch:H.plain` would publish a wrong normative detail, which is worse than none. So every
    /// iterated source says `callback:<binder>`, matching what R192 gives `xs.first`.
    func testAnIteratedElementClaimsNoOwner() throws {
        let by = try scan(Self.iterationFixture, "R211own")
        for fn in Self.mustDisclose {
            // NON-EMPTY FIRST. `allSatisfy` over an ABSENT row's empty reason set is vacuously true, so
            // without this line the whole test passes on the reverted engine — a control that cannot
            // discriminate the fix from its absence reads as coverage and is worse than none (§A).
            XCTAssertFalse(why(by[fn]).isEmpty, "\(fn) must carry a §4 reason")
            XCTAssertTrue(why(by[fn]).allSatisfy { $0.hasPrefix("callback:") },
                          "\(fn) invokes its callable through an ITERATION binder and has no owner to "
                          + "name — got \(why(by[fn]))")
        }
    }

    /// THE GATE ROUTE, which is where the sin was actually cashed out. A caller that is absent from
    /// `functions[]` is not merely undisclosed — `deny Unknown H.fireForEach` matched NO function and
    /// exited **0** on the R192 build, so a policy naming the exact function passed. The control is the
    /// same policy against a non-callable iteration, which must still evaluate to a clean 0.
    func testDenyUnknownFiresOnAnIteratedInvoker() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.iterationFixture, name: "R211deny")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("p.candor")
        try "deny Unknown H.fireForEach\n".write(to: policy, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path,
                                             "--policy", policy.path])
        XCTAssertEqual(r.code, 1, "`deny Unknown H.fireForEach` must be a VIOLATION — it exited 0 with "
                                + "'matched NO function' on the R192 build:\n\(r.out)\n\(r.err)")

        let clean = root.appendingPathComponent("q.candor")
        try "deny Unknown H.ctlIntForEach\n".write(to: clean, atomically: true, encoding: .utf8)
        let r2 = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r2").path,
                                              "--policy", clean.path])
        XCTAssertNotEqual(r2.code, 1, "a `[Int]` forEach must not become a violation — that is the "
                                    + "over-charge direction reaching the exit code:\n\(r2.out)")
    }

    /// `markOpaqueCallableBinding` is name-keyed and NOT scoped (R178's stated disposition), so the
    /// name stays claimed past the loop that claimed it. A same-named CONCRETE local either side must
    /// therefore still resolve its methods — losing the `Fs` here would be this fix introducing the
    /// class it closes, which is 4-in-5 the way fixes in this family have gone wrong. Measured: both
    /// keep `['Fs']` and the `Store.eff` edge and add the loop's honest `Unknown`.
    func testASameNamedConcreteLocalStillResolvesEitherSideOfTheLoop() throws {
        let by = try scan(Self.iterationFixture, "R211shadow")
        for fn in ["H.shadowAfter", "H.shadowBefore"] {
            XCTAssertEqual(effects(by[fn]), ["Fs", "Unknown"],
                           "\(fn) really does both — it writes through Store AND invokes the iterated "
                           + "closures. got \(effects(by[fn]))")
            XCTAssertTrue(calls(by[fn]).contains("Store.eff"),
                          "the concrete edge must survive the loop's binder mark. got \(calls(by[fn]))")
        }
    }

    /// A SECOND-ORDER EFFECT, MEASURED RATHER THAN ASSERTED (§K). A `let` global array of VISIBLE
    /// closure literals already resolved exactly — `for f in globalCbs { f() }` was `['Fs']` with an
    /// edge to the global's own unit — and it now carries the `Unknown` hedge as well. That is
    /// OVER-DISCLOSURE, not a loss: the edge and the `Fs` both survive, and the union is the direction
    /// that cannot go silent. It is not narrowed away, for R192's reason one container level in: which
    /// elements a container holds at the moment of iteration is not a property this scan can prove, and
    /// narrowing a sound over-approximation on an unprovable property is how a hole gets reopened
    /// (§F1.5). Pinned here so the next reader finds it measured rather than rediscovers it.
    func testALetGlobalArrayOfVisibleClosuresGainsTheHedgeAndKeepsTheEdge() throws {
        let by = try scan(Self.iterationFixture, "R211glob")
        XCTAssertEqual(effects(by["H.fireForGlobal"]), ["Fs", "Unknown"],
                       "the resolved `Fs` must SURVIVE alongside the new hedge — losing it would be this "
                       + "fix introducing the class it closes. got \(effects(by["H.fireForGlobal"]))")
        XCTAssertTrue(calls(by["H.fireForGlobal"]).contains("globalCbs"),
                      "the exact edge to the global's own unit must survive too. "
                      + "got \(calls(by["H.fireForGlobal"]))")
    }

    /// §E3 — the fixture must COMPILE AND RUN, and every claim above must match what it actually does.
    /// Without this the absence controls assert something about nothing: an omitted pure function and
    /// an omitted effectful one are the same bytes.
    func testFixtureGroundTruthExecutes() throws {
        #if os(macOS) || os(Linux)
        let env = URL(fileURLWithPath: "/usr/bin/env")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r211-gt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let instrumented = Self.iterationFixture
            .replacingOccurrences(of: "import Foundation", with: "import Foundation\nvar FIRES = 0")
            .replacingOccurrences(of: "= { _ = try?", with: "= { FIRES += 1; _ = try?")
            .replacingOccurrences(of: "= [{ _ = try?", with: "= [{ FIRES += 1; _ = try?")
            .replacingOccurrences(of: "[{ _ = try? String(contentsOfFile: \"/tmp/r211-g.txt\") }]",
                                  with: "[{ FIRES += 1; _ = try? String(contentsOfFile: \"/tmp/r211-g.txt\") }]")
            .replacingOccurrences(of: "func eff() { try?", with: "func eff() { FIRES += 1; try?")
            + """

            let h = H(); h.install()
            var log: [String: Bool] = [:]
            func chk(_ n: String, _ body: () -> Void) { let b = FIRES; body(); log[n] = FIRES > b }
            chk("honestOptChain", h.honestOptChain); chk("honestSubscript", h.honestSubscript)
            chk("honestFirst", h.honestFirst)
            chk("fireForAlias", h.fireForAlias); chk("fireForPlain", h.fireForPlain)
            chk("fireForDictVals", h.fireForDictVals); chk("fireForAliasVals", h.fireForAliasVals)
            chk("fireForPair", h.fireForPair); chk("fireForVar", h.fireForVar)
            chk("fireForAnnotated", h.fireForAnnotated); chk("fireForReversed", h.fireForReversed)
            chk("fireForLocal", h.fireForLocal); chk("fireForParam", { h.fireForParam(h.plain) })
            chk("fireForOptCase", h.fireForOptCase)
            chk("fireForEach", h.fireForEach); chk("fireForEachNamed", h.fireForEachNamed)
            chk("fireForEachParam", { h.fireForEachParam(h.plain) })
            chk("fireMap", h.fireMap); chk("fireFilter", h.fireFilter)
            chk("fireForEachAnnAlias", h.fireForEachAnnAlias); chk("fireForEachAnnFn", h.fireForEachAnnFn)
            chk("fireForGlobal", h.fireForGlobal)
            chk("shadowAfter", h.shadowAfter); chk("shadowBefore", h.shadowBefore)
            chk("keepStoreEff", h.keepStoreEff); chk("keepStoreForEach", h.keepStoreForEach)
            chk("ctlIntLiteral", h.ctlIntLiteral); chk("ctlIntField", h.ctlIntField)
            chk("ctlIntForEach", h.ctlIntForEach); chk("ctlReadNotCalled", h.ctlReadNotCalled)
            chk("ctlForEachNotCalled", h.ctlForEachNotCalled); chk("ctlAnnNotCalled", h.ctlAnnNotCalled)
            chk("ctlAnnInt", h.ctlAnnInt); chk("ctlDictKeyOnly", h.ctlDictKeyOnly)
            chk("ctlStorePure", h.ctlStorePure)
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
        for fn in Self.mustDisclose + ["H.fireForGlobal", "H.keepStoreEff", "H.keepStoreForEach",
                                       "H.shadowAfter", "H.shadowBefore"] {
            let leaf = fn.split(separator: ".").last.map(String.init) ?? fn
            XCTAssertTrue(fired.contains(leaf), "\(leaf) must actually invoke the closure at runtime — "
                                              + "the disclosure claim depends on it")
        }
        for fn in Self.mustStayAbsent {
            let leaf = fn.split(separator: ".").last.map(String.init) ?? fn
            XCTAssertTrue(quiet.contains(leaf), "\(leaf) must NOT invoke anything at runtime — the "
                                              + "absence control depends on it")
        }
        #else
        throw XCTSkip("no swiftc on this host")
        #endif
    }
}
