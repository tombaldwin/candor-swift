import XCTest
import Foundation

/// R178 — A STORED OPTIONAL CLOSURE INVOKED THROUGH AN **UNWRAP BINDER** WAS ABSENT FROM `functions[]`,
/// IN FOURTEEN SPELLINGS, WHILE `cb?()` DISCLOSED ONE LINE AWAY.
///
/// A published cardinal sin: byte-identical on the true v0.34.0 build (`candor-swift 0.34.0 (spec 0.34)`)
/// and on 0.35.0-staged HEAD. `pure`, `deny Fs` and `deny Unknown` over `Holder.fireIfLet` all exited 0
/// with *"policy rule matched NO function"* — the signature of this class, because the caller was never
/// judged at all — while the same three rules over `Holder.fireOptChain` behaved.
///
/// GROUND TRUTH IS EXECUTED, NOT ASSUMED (§E3). `binderFixture` below compiles and runs as a program:
/// every `fire*` really invokes the closure and every `ctl*` really does not, verified by a counter
/// bumped inside the closure body. That matters more here than usual, because ABSENCE is what both a
/// broken engine and a genuinely pure function produce, so a control asserting absence over a fixture
/// that cannot run is asserting something about nothing.
///
/// THE FOURTEEN SPELLINGS DID NOT SHARE A BRANCH — that is why the fix is not shaped like `if let`.
/// `if let`/`guard let` land in `visitPost(OptionalBindingConditionSyntax)`, the shorthand `if let cb`
/// in the same visitor with no initializer at all, `case .some(let c)` in `typeEnumCaseBinding` via a
/// switch item, `if case let c? =` in `MatchingPatternConditionSyntax`, `cb.map { $0() }` in
/// `typeClosureParams`, and `let c = cb ?? {}` in `visit(VariableDeclSyntax)`. What they share is
/// upstream: nothing in the collector could answer *"the value being unwrapped is a FUNCTION"*. So one
/// predicate (`callableValue`) answers it and each binder position calls it — §G, one authority.
///
/// THE TYPEALIAS HALF IS A SEPARATE, WIDER DEFECT and it is pinned here too. `typeName` returns
/// `(name: nil, isFunction: true)` for a function type, so `typealias Cb = () -> Void` was recorded in
/// NO alias table and every callable spelled through it read as a plain nominal type. Measured with the
/// plainly-spelled twin as the control in each row, on v0.34.0 and pre-fix HEAD: an alias-typed FIELD
/// (`Box.fireA`), an alias-typed PARAM (`directAliasParam`) and an alias-typed LOCAL (`localAlias`) were
/// all ABSENT while `Box.fireP` / `directPlainParam` / `localPlain` disclosed `Unknown`.
///
/// REAL-CODE RECALL, and it is the alias half that produced it: **Alamofire's `Adapter.adapt` (both
/// overloads) and `Retrier.retry`** — the public entry points of its closure-based `RequestInterceptor`s,
/// whose bodies do nothing but invoke a caller-supplied `AdaptHandler`/`RetryHandler` — were ABSENT on
/// the published v0.34.0 build and are `['Unknown'] dispatch:Adapter.adaptHandler` here.
/// `deny Unknown Adapter.adapt` moved from "bound nothing" to a violation.
///
/// THE OVER-CHARGE CONTROLS ARE THE OTHER HALF OF THE ROW. A predicate that answered "callable" too
/// eagerly would put a spurious `Unknown` on every `if let` in a real codebase, so `ctlNumIfLet`,
/// `ctlNumMap` and `ctlStoreIfLet` bind NON-callable optionals and must stay absent, and `ctlBindNoCall`
/// / `ctlMapNoCall` bind a genuine closure and never call it and must stay absent too — the charge is
/// owed by the INVOCATION, not by the binding.
///
/// A/B over five real corpora (swift-nio, swift-collections, swift-algorithms, swift-argument-parser,
/// Alamofire; 15,861 analyzed units), wide-keyed on every disclosure channel rather than on `inferred`:
/// ADDED 3, REMOVED 0, zero rows lost an effect, zero lost a call edge. The changed branch was
/// instrumented and counted first — nio 36 hits, Alamofire 50, argument-parser 5, collections and
/// algorithms **0**, so those last two arms are safety-only and say nothing either way.
final class OptionalCallableBinderProcessTests: XCTestCase {

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
    static let binderFixture = """
    import Foundation

    typealias Cb = () -> Void

    struct Store { func write() { try? "x".write(toFile: "/tmp/r178-store.txt", atomically: true, encoding: .utf8) } }

    final class Holder {
      var cb: Cb? = nil                 // typealias-spelled optional closure field
      var plain: (() -> Void)? = nil    // plainly-spelled optional closure field
      var num: Int? = nil               // NON-closure optional  (over-charge control)
      var store: Store? = nil           // NON-closure optional of a local type (control)

      func install() {
        cb    = { _ = try? String(contentsOfFile: "/tmp/r178-a.txt") }
        plain = { _ = try? String(contentsOfFile: "/tmp/r178-b.txt") }
        num = 1
        store = Store()
      }

      // the honest baseline the row is measured against
      func fireOptChain()      { cb?() }
      func firePlainOptChain() { plain?() }

      // unwrap binders, typealias-spelled field
      func fireIfLet()        { if let c = cb { c() } }
      func fireIfLetSelf()    { if let c = self.cb { c() } }
      func fireGuardLet()     { guard let c = cb else { return }; c() }
      func fireShorthand()    { if let cb { cb() } }
      func fireMap()          { _ = cb.map { $0() } }
      func fireMapNamed()     { _ = cb.map { f in f() } }
      func fireSwitchSome()   { switch cb { case .some(let c): c(); case .none: break } }
      func fireIfCaseSome()   { if case let .some(c) = cb { c() } }
      func fireIfCaseQ()      { if case let c? = cb { c() } }
      func fireCoalesceLet()  { let c = cb ?? {}; c() }
      func fireCoalesceCall() { (cb ?? {})() }
      func fireForce()        { cb!() }

      // the same binders over the plainly-spelled field
      func firePlainIfLet()    { if let c = plain { c() } }
      func firePlainGuardLet() { guard let c = plain else { return }; c() }
      func firePlainMap()      { _ = plain.map { $0() } }
      func firePlainSwitch()   { switch plain { case .some(let c): c(); case .none: break } }

      // CONTROLS — the direction the fix did not intend
      func ctlBindNoCall()   { if let c = cb { _ = c } }
      func ctlMapNoCall()    { _ = cb.map { _ = $0 } }
      func ctlNumIfLet()     { if let v = num { _ = v + 1 } }
      func ctlNumMap()       { _ = num.map { $0 + 1 } }
      func ctlStoreIfLet()   { if let s = store { _ = s } }
      func ctlStoreCall()    { if let s = store { s.write() } }
    }

    func fireParamIfLet(_ o: Cb?) { if let c = o { c() } }
    func fireLocalIfLet(_ h: Holder) { let l: Cb? = h.cb; if let c = l { c() } }
    """

    /// The fourteen spellings that were ABSENT, plus the four that were already honest. EVERY one must
    /// disclose `Unknown` with `unresolved: true` and a §4 reason — the obligation SPEC §4 binds to the
    /// EFFECT SET, not to a flag.
    private static let mustDisclose = [
        "Holder.fireOptChain", "Holder.firePlainOptChain", "Holder.fireCoalesceCall", "Holder.fireForce",
        "Holder.fireIfLet", "Holder.fireIfLetSelf", "Holder.fireGuardLet", "Holder.fireShorthand",
        "Holder.fireMap", "Holder.fireMapNamed", "Holder.fireSwitchSome", "Holder.fireIfCaseSome",
        "Holder.fireIfCaseQ", "Holder.fireCoalesceLet",
        "Holder.firePlainIfLet", "Holder.firePlainGuardLet", "Holder.firePlainMap", "Holder.firePlainSwitch",
        "fireParamIfLet", "fireLocalIfLet",
    ]

    func testEveryUnwrapBinderDisclosesTheInvocation() throws {
        let by = try scan(Self.binderFixture, "R178")
        for fn in Self.mustDisclose {
            let f = by[fn]
            XCTAssertNotNil(f, "\(fn) is ABSENT from functions[] — the cardinal sin's signature. "
                             + "It really invokes the closure (see testFixtureGroundTruthExecutes).")
            XCTAssertTrue(effects(f).contains("Unknown"),
                          "\(fn) must carry Unknown in `inferred` — SPEC §4 binds the obligation to the "
                          + "effect set, not to `unresolved` (a flag no `deny` route reads). got \(effects(f))")
            XCTAssertEqual(f?["unresolved"] as? Bool, true, "\(fn) must set unresolved: true")
            XCTAssertFalse(why(f).isEmpty, "\(fn) must carry an unknownWhy — an Unknown with no reason is "
                                         + "the R180 shape")
            XCTAssertTrue(why(f).contains { $0.hasPrefix("callback:") || $0.hasPrefix("dispatch:") },
                          "\(fn)'s reason must be a §4 `callback:`/`dispatch:` kind, got \(why(f))")
        }
    }

    /// The unwrapped value's OWNER is the one normative detail in the reason vocabulary (SPEC §4 ⟨0.7⟩:
    /// `dispatch:` is "a resolvable owner whose target is not"). A field unwrap knows its owner and must
    /// say so; a param/local unwrap genuinely has none and must say `callback:`.
    func testAFieldUnwrapNamesItsOwnerAndAParamUnwrapDoesNot() throws {
        let by = try scan(Self.binderFixture, "R178own")
        for fn in ["Holder.fireIfLet", "Holder.fireGuardLet", "Holder.fireMap", "Holder.fireSwitchSome",
                   "Holder.fireIfCaseQ", "Holder.fireCoalesceLet", "Holder.fireShorthand"] {
            XCTAssertTrue(why(by[fn]).contains("dispatch:Holder.cb"),
                          "\(fn) unwraps `Holder.cb` and must name that owner, got \(why(by[fn]))")
        }
        for fn in ["Holder.firePlainIfLet", "Holder.firePlainMap", "Holder.firePlainSwitch"] {
            XCTAssertTrue(why(by[fn]).contains("dispatch:Holder.plain"),
                          "\(fn) unwraps `Holder.plain`, got \(why(by[fn]))")
        }
        // no owner exists for these two — `callback:` is the correct kind, not a degraded one
        XCTAssertTrue(why(by["fireParamIfLet"]).contains("callback:c"), "\(why(by["fireParamIfLet"]))")
        XCTAssertTrue(why(by["fireLocalIfLet"]).contains("callback:c"), "\(why(by["fireLocalIfLet"]))")
    }

    /// THE OVER-CHARGE CONTROL. Binding an optional is not invoking one, and a non-callable optional is
    /// not callable however it is bound. Each of these RUNS and performs nothing (`quiet` in the ground
    /// truth), so absence here is a claim the fixture can actually support.
    func testBindingWithoutInvokingAndNonCallableOptionalsStayUncharged() throws {
        let by = try scan(Self.binderFixture, "R178ctl")
        for fn in ["Holder.ctlBindNoCall", "Holder.ctlMapNoCall",
                   "Holder.ctlNumIfLet", "Holder.ctlNumMap", "Holder.ctlStoreIfLet"] {
            XCTAssertNil(by[fn], "\(fn) binds but never invokes (or binds a non-callable) — it must stay "
                               + "absent; charging it is the fabrication direction. got \(String(describing: by[fn]))")
        }
        // …and the calibration that proves the instrument can charge this shape at all: the same binder,
        // over the same non-callable optional, with a real effect behind the call.
        XCTAssertEqual(effects(by["Holder.ctlStoreCall"]), ["Fs"],
                       "the `if let s = store { s.write() }` calibration must still charge Fs")
        XCTAssertEqual(effects(by["Holder.install"]), ["Fs"], "the closure bodies must still charge Fs")
    }

    /// §E3 — PROVE THE PROGRAM EXISTS BEFORE TRUSTING WHAT THE ENGINE SAYS ABOUT IT. Compiles the exact
    /// fixture with a counter in each closure body and asserts, per method, that the `fire*` spellings
    /// invoke and the `ctl*` spellings do not. Without this the absence controls above are asserting
    /// something about nothing.
    func testFixtureGroundTruthExecutes() throws {
        #if os(macOS) || os(Linux)
        let env = URL(fileURLWithPath: "/usr/bin/env")   // the spelling every other suite here uses
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r178-gt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let instrumented = Self.binderFixture
            .replacingOccurrences(of: "import Foundation", with: "import Foundation\nvar FIRES = 0")
            .replacingOccurrences(of: "cb    = {", with: "cb    = { FIRES += 1;")
            .replacingOccurrences(of: "plain = {", with: "plain = { FIRES += 1;")
            + """

            let h = Holder(); h.install()
            var log: [String: Bool] = [:]
            func chk(_ n: String, _ body: () -> Void) { let b = FIRES; body(); log[n] = FIRES > b }
            chk("fireOptChain", h.fireOptChain); chk("fireIfLet", h.fireIfLet)
            chk("fireIfLetSelf", h.fireIfLetSelf); chk("fireGuardLet", h.fireGuardLet)
            chk("fireShorthand", h.fireShorthand); chk("fireMap", h.fireMap)
            chk("fireMapNamed", h.fireMapNamed); chk("fireSwitchSome", h.fireSwitchSome)
            chk("fireIfCaseSome", h.fireIfCaseSome); chk("fireIfCaseQ", h.fireIfCaseQ)
            chk("fireCoalesceLet", h.fireCoalesceLet); chk("fireCoalesceCall", h.fireCoalesceCall)
            chk("fireForce", h.fireForce)
            chk("firePlainOptChain", h.firePlainOptChain); chk("firePlainIfLet", h.firePlainIfLet)
            chk("firePlainGuardLet", h.firePlainGuardLet); chk("firePlainMap", h.firePlainMap)
            chk("firePlainSwitch", h.firePlainSwitch)
            chk("fireParamIfLet", { fireParamIfLet(h.cb) }); chk("fireLocalIfLet", { fireLocalIfLet(h) })
            chk("ctlBindNoCall", h.ctlBindNoCall); chk("ctlMapNoCall", h.ctlMapNoCall)
            chk("ctlNumIfLet", h.ctlNumIfLet); chk("ctlNumMap", h.ctlNumMap)
            chk("ctlStoreIfLet", h.ctlStoreIfLet); chk("ctlStoreCall", h.ctlStoreCall)
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
            XCTAssertTrue(fired.contains(leaf), "\(leaf) must actually invoke the closure at runtime")
        }
        for leaf in ["ctlBindNoCall", "ctlMapNoCall", "ctlNumIfLet", "ctlNumMap", "ctlStoreIfLet"] {
            XCTAssertTrue(quiet.contains(leaf), "\(leaf) must NOT invoke the closure at runtime — the "
                                              + "absence control depends on it")
        }
        #else
        throw XCTSkip("no swiftc on this host")
        #endif
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // The typealias half — every row paired with its plainly-spelled twin as the control.
    // ────────────────────────────────────────────────────────────────────────────────────────────────
    private static let aliasFixture = """
    import Foundation
    typealias Cb = () -> Void
    typealias Cb2 = Cb

    final class Box {
      var cbA: Cb
      var cbP: () -> Void
      var cbC: Cb2
      init(_ f: @escaping Cb) { cbA = f; cbP = f; cbC = f }
      func fireA() { cbA() }
      func fireP() { cbP() }
      func fireC() { cbC() }
    }
    func directAliasParam(_ c: Cb)   { c() }
    func directChainParam(_ c: Cb2)  { c() }
    func directPlainParam(_ c: () -> Void) { c() }
    func localAlias(_ f: @escaping Cb) { let l: Cb = f; l() }
    func localPlain(_ f: @escaping () -> Void) { let l: () -> Void = f; l() }
    """

    func testAnAliasSpelledCallableAnswersLikeItsPlainlySpelledTwin() throws {
        let by = try scan(Self.aliasFixture, "R178alias")
        // FIELD: the alias spellings must reach the same `dispatch:<Type>.<field>` the plain one does.
        for (alias, plain) in [("Box.fireA", "cbA"), ("Box.fireC", "cbC"), ("Box.fireP", "cbP")] {
            XCTAssertTrue(effects(by[alias]).contains("Unknown"),
                          "\(alias) invokes a function-typed field and must disclose; got \(effects(by[alias]))")
            XCTAssertTrue(why(by[alias]).contains("dispatch:Box.\(plain)"), "\(why(by[alias]))")
        }
        // PARAM: the alias spellings must reach the same answer as the plainly-spelled param.
        for fn in ["directAliasParam", "directChainParam", "directPlainParam"] {
            XCTAssertTrue(effects(by[fn]).contains("Unknown"),
                          "\(fn) invokes a function-typed parameter and must disclose; got \(effects(by[fn]))")
        }
        // LOCAL: `let l: Cb = f` is as callable as `let l: () -> Void = f`.
        for fn in ["localAlias", "localPlain"] {
            XCTAssertTrue(why(by[fn]).contains("callback:l"), "\(fn): \(why(by[fn]))")
        }
    }

    /// AN UNWRAPPED CALLABLE IS NOT ALWAYS OPAQUE, and the first draft of this fix asserted it was.
    ///
    /// `assert-audit.sh` flagged the comment ("opaque BY CONSTRUCTION") as a safety claim; measured
    /// rather than argued, it was false. `let cb: Cb? = { … }` has a visible closure initializer, so
    /// `closureFields` holds a real `<Type>.cb` unit and the answer is EXACT — Swift forbids assigning a
    /// `let` that already has one, which is the precision R96 documents and R85's recall depends on.
    /// Hedging it to `Unknown` would have made the BINDER spelling of a program strictly less precise
    /// than the `obj.cb()` spelling of the same program. So the invocation site asks
    /// `closurePropertyInvocation`, the single authority the other four sites already ask.
    ///
    /// The `var` row is the other half and it is not symmetric: any holder of the object may store a
    /// different closure, from this scan or from a module it will never see, so the honest answer is the
    /// UNION — the visible default's effects AND the §4 Unknown. That is R96, unchanged.
    func testAVisibleClosurePropertyResolvesThroughTheBinderJustAsThroughTheReceiver() throws {
        let src = """
        import Foundation
        typealias Cb = () -> Void
        final class H {
          let cbLet: Cb? = { try? "x".write(toFile: "/tmp/r178v1.txt", atomically: true, encoding: .utf8) }
          var cbVar: Cb? = { try? "x".write(toFile: "/tmp/r178v2.txt", atomically: true, encoding: .utf8) }
          let plainLet: Cb = { try? "x".write(toFile: "/tmp/r178v3.txt", atomically: true, encoding: .utf8) }
          func viaIfLet()    { if let c = cbLet { c() } }
          func viaIfLetVar() { if let c = cbVar { c() } }
          func viaDirect()   { plainLet() }
        }
        """
        let by = try scan(src, "R178vis")
        XCTAssertEqual(effects(by["H.viaDirect"]), ["Fs"], "the receiver spelling: exact, unchanged")
        XCTAssertEqual(effects(by["H.viaIfLet"]), ["Fs"],
                       "a `let` closure property unwrapped by a binder is EXACT — hedging it would make "
                       + "the binder spelling less precise than `plainLet()` one line up. "
                       + "got \(effects(by["H.viaIfLet"])) why=\(why(by["H.viaIfLet"]))")
        XCTAssertTrue(why(by["H.viaIfLet"]).isEmpty, "…and it owes no reason at all")
        XCTAssertEqual(effects(by["H.viaIfLetVar"]), ["Fs", "Unknown"],
                       "a `var` closure property is the R96 UNION — the visible default AND Unknown")
        XCTAssertEqual(why(by["H.viaIfLetVar"]), ["dispatch:H.cbVar"])
    }

    /// A NAME THAT IS BOTH A CALLABLE FIELD AND A METHOD ON THE SAME TYPE KEEPS ITS METHOD EDGE.
    ///
    /// Written from a regression the corpus A/B caught rather than from caution: swift-nio's
    /// `ClientBootstrap` declares `private var channelInitializer: ChannelInitializerCallback` AND
    /// `public func channelInitializer(_:) -> Self`, and completing the alias-typed field made the
    /// member-call arm read `bootstrap.channelInitializer { … }` — the BUILDER METHOD — as an
    /// invocation of the field. Three callers lost a real call edge; their effect sets happened not to
    /// move, which is exactly why the wide-key diff is the one to audit. This completion may add a
    /// disclosure, never take an edge away.
    func testACallableFieldSharingAMethodNameDoesNotSwallowTheMethodCall() throws {
        let src = """
        import Foundation
        typealias Init = (Int) -> Void
        final class Bootstrap {
          private var handler: Init = { _ in }
          // a BUILDER METHOD whose name collides with the stored callable above
          func handler(_ h: @escaping Init) -> Bootstrap { self.handler = h; _ = try? String(contentsOfFile: "/tmp/r178-b.txt"); return self }
        }
        func build(_ b: Bootstrap) { _ = b.handler { _ in } }
        """
        let by = try scan(src, "R178clash")
        XCTAssertEqual(effects(by["build"]), ["Fs"],
                       "`b.handler { … }` calls the BUILDER METHOD, whose body reads a file. Reading it as "
                       + "an invocation of the same-named callable field replaces a real edge with a hedge. "
                       + "got \(effects(by["build"])) why=\(why(by["build"]))")
    }
}
