import XCTest
import Foundation

/// Deterministic pins for Driver.swift resolution paths that were exercised ONLY by fuzz.py forms
/// (overload_subtype / proto / callback_recv). TESTING.md §7: probes complement deterministic pins,
/// they don't replace them — a probe reaches these paths per-seed-choice, so a regression could ride
/// a green fuzz run whose seeds happened not to draw the form. Three standing gates:
///   1. PARAM-TYPE OVERLOAD edge insertion — an overload-resolved local call carries ONLY the
///      matched overload's effect (never the same-name sibling's).
///   2. `conformers.isEmpty` protocol dispatch — a local protocol with NO conformer in scope reads
///      honest Unknown (`dispatch:<P>.<m>`), never silent-pure.
///   3. Deferred closure-arg resolution — a fn-typed param invoked resolves to a NAMED local fn
///      across the call sites (edge, no Unknown), but a CLOSURE literal arg stays opaque (the §4
///      Unknown stands; the fuzzer caught the looser reading red-handed).
final class DriverResolutionProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: DriverResolutionProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    // ── 0. MODULE-QUALIFIED free call (`Core.shared()`) ───────────────────────────────────────────
    // Swift lets a call name its declaring module to disambiguate, and that is how a wrapper delegates to a
    // same-named implementation elsewhere (swift-syntax's `SwiftSyntaxMacrosTestSupport` →
    // `SwiftSyntaxMacrosGenericTestSupport.assertMacroExpansion`). Such a call is neither `typed` (its base
    // names a module, not a type) nor `unqualified`, so it reached NO resolution branch and the caller came
    // back SILENT-PURE — the cardinal sin (candor-spec SOUNDNESS-VEIN-global-unit-identity.md). The base is
    // kept on the call as `extOwner`; resolving through it is exact, and must charge ONLY that module's
    // function — never the same-named one next door.
    func testModuleQualifiedFreeCallResolvesToThatModulesFunction() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("candor-modqual-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Core"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Util"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "Core"), .target(name: "Util", dependencies: ["Core"])])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public func shared() -> String { (try? String(contentsOfFile: "/etc/core")) ?? "" }
        let cfg = (try? String(contentsOfFile: "/etc/core")) ?? ""
        func coreReads() -> String { cfg }
        """.write(to: root.appendingPathComponent("Sources/Core/Core.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import Core
        func shared() -> String { ProcessInfo.processInfo.environment["U"] ?? "" }
        func delegates() -> String { Core.shared() }
        func localCall() -> String { shared() }
        let cfg = ProcessInfo.processInfo.environment["U"] ?? ""
        func utilReads() -> String { cfg }
        """.write(to: root.appendingPathComponent("Sources/Util/Util.swift"), atomically: true, encoding: .utf8)

        let bin = try ProcessHarness.binaryURL(for: DriverResolutionProcessTests.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let by = try ProcessHarness.fns(ofJson: r.out)
        XCTAssertEqual(ProcessHarness.inferred(by, "delegates"), ["Fs"],
                       "a module-qualified call must charge ONLY Core's Fs — it read silent-pure before, and "
                       + "must not pick up Util's same-named Env either: \(by)")
        // The UNQUALIFIED sibling. Two modules' same-named free functions are grouped as overloads of one
        // another, so every signature matched and each caller edged to BOTH — charging a caller of its own
        // module's function with the other module's effect. A free call resolves lexically, so candidates in
        // the caller's own module win. This is sound only BECAUSE the qualified form above now resolves:
        // measured before that fix, the same preference dropped a real `Unknown` on swift-syntax, where the
        // delegation it was stealing is written module-qualified.
        XCTAssertEqual(ProcessHarness.inferred(by, "localCall"), ["Env"],
                       "an unqualified call resolves in its OWN module — not the same-named Fs next door: \(by)")
        // The GLOBAL sibling. File-scope globals are accessor units and sat outside the overload pass, so two
        // modules' `let cfg` collapsed into ONE unit carrying the union of both initializers' effects — and a
        // reader of either was charged both. They now get the same positional disambiguation functions get,
        // and a bare read resolves in the reader's own module.
        XCTAssertEqual(ProcessHarness.inferred(by, "coreReads"), ["Fs"],
                       "a reader of Core's `cfg` carries only Core's Fs: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "utilReads"), ["Env"],
                       "and a reader of Util's same-named `cfg` only Env — not the union of both: \(by)")
    }

    // ── 0b. `super.m()` — the SUPERCLASS's implementation ─────────────────────────────────────────
    // `super` is a SuperExprSyntax, not a DeclReference, so the receiver resolver fell through and the call
    // was DROPPED: an override calling `super.load()` and a method calling `super.other()` both read
    // silent-pure while the base's effect sat two lines up. Resolving `super` to the ENCLOSING type would be
    // wrong for the override form — the edge would point at the overriding method itself and add nothing —
    // so it is marked and resolved on the SUPERTYPE chain, skipping the enclosing type.
    func testSuperCallReachesTheSuperclassImplementation() throws {
        let by = try scan("""
        import Foundation
        class Base {
            func load()  { _ = ProcessInfo.processInfo.environment["A"] }
            func other() { _ = ProcessInfo.processInfo.environment["B"] }
        }
        class Sub1: Base { override func load() { super.load() } }
        class Sub2: Base { func run() { super.other() } }
        class Sub3: Base { func run2() { self.load() } }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Sub1.load"), ["Env"],
                       "an override calling super.load() carries the base's effect: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "Sub2.run"), ["Env"],
                       "a different-name super call resolves too: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "Sub3.run2"), ["Env"],
                       "and the self-dispatch control is unaffected: \(by)")
    }

    // ── 1. overload-matched edge insertion (same name, same arity, different param TYPE) ───────────
    func testOverloadResolvedCallCarriesOnlyTheMatchedOverloadsEffect() throws {
        let by = try scan("""
        import Foundation
        struct AA {}
        struct BB {}
        func handle(_ x: AA) -> Int { 0 }                                                // PURE
        func handle(_ x: BB) -> Int { _ = FileManager.default.contents(atPath: "/x"); return 1 }  // Fs
        func callsPure() -> Int { let a = AA(); return handle(a) }
        func callsEff() -> Int { let b = BB(); return handle(b) }
        """)
        // the effectful overload's node exists and the typed call routes to it
        XCTAssertEqual(ProcessHarness.inferred(by, "callsEff"), ["Fs"],
                       "the BB-typed call must edge to the Fs overload")
        // the pure-sibling caller must NOT inherit the union of both bodies (the SwiftDate compare bug)
        XCTAssertNil(by["callsPure"],
                     "the AA-typed call resolves to the pure overload — inheriting the sibling's Fs is a fabrication")
        // the per-signature node naming: only the Fs overload appears, under its typed suffix
        XCTAssertEqual(ProcessHarness.inferred(by, "handle(BB)"), ["Fs"], "overload nodes are keyed per-signature")
        XCTAssertNil(by["handle(AA)"], "the pure overload node stays out of the report")
    }

    // an overload call whose arg is a known SUBTYPE/conformer must match the base-typed overload
    // (the subtype-blind `!=` would drop the edge → silent-pure, the cardinal direction).
    func testOverloadSubtypeArgMatchesBaseTypedOverload() throws {
        let by = try scan("""
        import Foundation
        class Animal {}
        class Dog: Animal {}
        struct Toy {}
        func handle(_ x: Animal) { _ = FileManager.default.contents(atPath: "/x") }   // Fs
        func handle(_ x: Toy) {}                                                       // PURE
        func walk() { let d = Dog(); handle(d) }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "walk"), ["Fs"],
                       "a Dog arg is a known subtype of Animal — the edge must not be dropped silent-pure")
    }

    // ── 2. a local protocol with NO conformer in scope → honest Unknown, never silent-pure ─────────
    func testProtocolWithNoConformerReadsUnknown() throws {
        let by = try scan("""
        protocol Emitter { func emit() }
        func useEmitter(_ e: Emitter) { e.emit() }
        """)
        let inf = ProcessHarness.inferred(by, "useEmitter")
        XCTAssertEqual(inf, ["Unknown"],
                       "dispatch on a conformer-less protocol cannot resolve — it must read Unknown, got \(inf ?? [])")
        XCTAssertEqual(by["useEmitter"]?["unknownWhy"] as? [String], ["dispatch:Emitter.emit"],
                       "the Unknown names its dispatch origin (spec 0.6 unknownWhy)")
    }

    // the green twin: the SAME dispatch with one conformer in scope resolves precisely (no Unknown) —
    // proving the isEmpty arm (not some blanket Unknown) is what fired above.
    func testProtocolWithOneConformerResolvesPrecisely() throws {
        let by = try scan("""
        import Foundation
        protocol Emitter { func emit() }
        struct FileEmitter: Emitter { func emit() { _ = FileManager.default.contents(atPath: "/x") } }
        func useEmitter(_ e: Emitter) { e.emit() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "useEmitter"), ["Fs"],
                       "bounded CHA over one conformer resolves the dispatch — no Unknown")
    }

    // ── 3. deferred closure-arg resolution ─────────────────────────────────────────────────────────
    // ⟨0.34⟩ PER-CALLER, not per-target (BACKLOG "a shared HOF's effects are charged to EVERY caller"):
    // the resolution used to land on the shared HOF's OWN node (`runner`), which every caller inherited
    // via the ordinary call edge — fine with exactly one caller, but a fabrication with two (see
    // `testTwoCallersOfOneHOFResolveIndependently` below). The edge/Unknown now lands on the CALLER that
    // made the resolvable/unresolvable call, so `runner` itself carries no effect of its own here.
    func testFnTypedParamResolvesNamedLocalAcrossCallSites() throws {
        let by = try scan("""
        import Foundation
        func runner(_ job: () -> Void) { job() }
        func namedJob() { _ = FileManager.default.contents(atPath: "/y") }
        func passesNamed() { runner(namedJob) }
        """)
        // the NAMED local fn at the call site resolves the deferral for THIS caller: an edge straight
        // to `namedJob`, landing on `passesNamed` — `runner` has no direct effect of its own, so it
        // drops out of the report (pure in isolation).
        XCTAssertNil(by["runner"],
                     "runner carries no effect of its own — resolution is per-CALLER now, got \(by["runner"] ?? [:])")
        XCTAssertEqual(ProcessHarness.inferred(by, "passesNamed"), ["Fs"],
                       "the caller that named the callback inherits its target's effect directly")
    }

    // the fabrication this fix closes: TWO callers of ONE HOF, passing two DIFFERENT named callbacks.
    // The old per-target design pooled every call site into `hof` and unioned every resolved target onto
    // `hof`'s own node, which BOTH callers then inherited via the ordinary call edge — `callerB` (a pure
    // callback) fabricated `callerA`'s Fs, and `hof`'s own scan-note diagnostic named a path (`via
    // sinkA`) `callerB` never takes. Each caller must see ONLY the effect of the callback IT passed.
    func testTwoCallersOfOneHOFResolveIndependently() throws {
        let by = try scan("""
        import Foundation
        func hof(_ cb: () -> Void) { cb() }
        func sinkA() { _ = FileManager.default.contents(atPath: "/a") }
        func sinkB() { }
        func callerA() { hof(sinkA) }
        func callerB() { hof(sinkB) }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "callerA"), ["Fs"],
                       "callerA passed the Fs callback — the under-report guard: it must still carry it")
        XCTAssertNil(by["callerB"],
                     "callerB passed a PURE callback through the SAME hof callerA uses — inheriting Fs "
                     + "here is the exact fabrication this fix closes, got \(by["callerB"] ?? [:])")
        XCTAssertNil(by["hof"], "the shared HOF carries no effect of its own — it belongs to its callers")
    }

    // NON-DISCRIMINATING COMPANION — kept because its assertions are true, but its name used to claim
    // coverage it doesn't provide. Both callers here reach `hof` through an UNTRACKED sibling call, so
    // `callsiteArgs[fq]` is empty for BOTH and the per-fq loop's `byCaller` is empty too — which takes
    // the OLD whole-target fallback (`direct[fq]` gets Unknown, inherited by every caller through the
    // ordinary call edge) REGARDLESS of whether `callersOf`'s back-fill exists. Deleting the `callersOf`
    // guard leaves this test green: verified directly, `swift test` still reports 0 failures with the
    // guard removed. It still pins a real, narrower invariant — an untracked call site is not silently
    // skipped WHEN NO OTHER caller of the same HOF is tracked — so it stays as a companion, renamed so
    // it no longer reads as proof the back-fill works. `testUntrackedCallerOfAHOFWithATrackedSiblingStillGetsJudged`
    // below is the test that actually discriminates the back-fill from its absence.
    func testAllUntrackedSiblingCallersOfAHOFEachReadUnknown() throws {
        let by = try scan("""
        import Foundation
        struct Box {
            func hof(_ body: () -> Void) { body() }
            func callerA() { hof { _ = FileManager.default.contents(atPath: "/a") } }
            func callerB() { hof { } }
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "Box.callerA"), ["Fs", "Unknown"],
                       "the closure body charges the passer directly, and the deferred call stays Unknown too")
        XCTAssertEqual(ProcessHarness.inferred(by, "Box.callerB"), ["Unknown"],
                       "an untracked (sibling-call) caller must still be judged — dropping its Unknown "
                       + "silently is the false all-clear this guards against")
    }

    // THE DISCRIMINATING TEST for the `callersOf` back-fill. The companion above cannot tell this fix
    // from its absence because BOTH its callers are untracked, so the pre-existing whole-target fallback
    // (Unknown on `fq` itself, inherited by every caller via the ordinary call edge) produces the same
    // answer with or without `callersOf`. The back-fill only matters once `byCaller` is non-empty for a
    // reason OTHER than the untracked caller — i.e. some OTHER caller into the same HOF resolved through
    // a TRACKED call site — because then the per-fq loop skips the whole-target fallback and iterates
    // only `byCaller`'s keys directly. WITH `callersOf`, the untracked sibling is back-filled into
    // `byCaller` (with no recorded sites, so it still reads Unknown). WITHOUT it, that caller is never
    // added to `byCaller` at all: the loop never visits it, `fq` itself carries no effect of its own, and
    // the caller inherits nothing through the ordinary edge — it VANISHES FROM THE REPORT ENTIRELY
    // (silent-pure), not merely a changed effect value.
    //
    // `callerA` reaches `hof` through an EXPLICIT RECEIVER (`box.hof(sinkA)`, a typed call site —
    // TRACKED by `callsiteArgs`), which is what makes `byCaller` non-empty for a reason independent of
    // `callerB`. `callerB` reaches the SAME `hof` through an UNQUALIFIED SIBLING call from inside `Box`
    // (untracked — the companion test's shape) passing a PURE callback, so if it silently drops instead
    // of reading Unknown it disappears from `by` rather than merely changing value — asserted directly
    // below, not just through a value comparison that a `nil` would also fail.
    func testUntrackedCallerOfAHOFWithATrackedSiblingStillGetsJudged() throws {
        let by = try scan("""
        import Foundation
        func sinkA() { _ = FileManager.default.contents(atPath: "/a") }
        func sinkB() { }
        struct Box {
            func hof(_ cb: () -> Void) { cb() }
            func callerB() { hof(sinkB) }
        }
        func callerA(_ box: Box) { box.hof(sinkA) }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "callerA"), ["Fs"],
                       "the tracked caller resolves the named callback and inherits its Fs")
        XCTAssertNotNil(by["Box.callerB"],
                        "the untracked sibling caller must still appear in the report AT ALL — its "
                        + "disappearance, not merely a wrong effect value, is the bug callersOf guards against")
        XCTAssertEqual(ProcessHarness.inferred(by, "Box.callerB"), ["Unknown"],
                       "an untracked caller reaching a HOF that ALSO has a tracked caller must still read "
                       + "Unknown, not silently vanish from the report")
    }

    func testClosureLiteralArgStaysOpaque() throws {
        let by = try scan("""
        import Foundation
        func runner(_ job: () -> Void) { job() }
        func passesClosure() { runner { _ = FileManager.default.contents(atPath: "/z") } }
        """)
        // a CLOSURE arg stays opaque for the deferral: the §4 Unknown stands even though the closure
        // body is charged to the passer lexically. It attributes to the CALLER (`passesClosure`) —
        // AND, since R125, to `runner` itself as well.
        //
        // THIS ASSERTION WAS INVERTED UNTIL R125, and the old wording ("runner carries no effect of its
        // own — the Unknown belongs to its caller") is the reason the hole survived a release: `runner`
        // invokes a value it cannot address on every execution, so `deny Unknown runner` exited 0 over it.
        // The Unknown belongs to the caller AND to `runner`; those are not alternatives. Costs nothing
        // here because the caller already carries the identical Unknown (see the R125 note in Driver.swift).
        XCTAssertEqual(ProcessHarness.inferred(by, "runner"), ["Unknown"],
                       "the HOF whose every caller passed an unresolvable closure must carry its OWN "
                       + "Unknown — a scoped `deny Unknown runner` reads this row and nothing else")
        XCTAssertEqual(by["runner"]?["unknownWhy"] as? [String], ["callback:job"],
                       "and it names the param it cannot address")
        // the passer carries the closure body's Fs (lexical charge) AND its own callback-flow Unknown.
        XCTAssertEqual(ProcessHarness.inferred(by, "passesClosure"), ["Fs", "Unknown"],
                       "the closure body charges the passer; the deferred callback's Unknown attributes here too")
        XCTAssertEqual(by["passesClosure"]?["unknownWhy"] as? [String], ["callback:job"],
                       "the Unknown names the invoked fn-typed param, now on the caller that supplied it")
    }

    // a fn-typed param with NO visible call site keeps the §4 Unknown (nothing to resolve against).
    func testFnTypedParamWithNoCallSiteKeepsUnknown() throws {
        let by = try scan("""
        public func runner(_ job: () -> Void) { job() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "runner"), ["Unknown"],
                       "no visible call site — the fn-typed invocation must stay Unknown")
    }

    // ── R125: a HOF's OWN row when every caller leaves the deferral unresolved ─────────────────────
    // The source below is VERBATIM the fixture that was `swift build`-ed and RUN (§E3): it creates the
    // probe file, calls `passer`, and prints `probe still exists after passer() == false` — the closure
    // handed to `hofWithCaller` really does delete a file, through a value `hofWithCaller` cannot address.
    //
    // `hofWithCaller` and `hofNoCaller` have BYTE-IDENTICAL bodies. The only variable is whether anything
    // in the scan calls them. On the PUBLISHED 0.34.0 binary (`819fac6`) and every commit of the unpushed
    // wave, `hofNoCaller` read `Unknown`/`callback:body` and `hofWithCaller` was ABSENT FROM THE REPORT —
    // so `deny Unknown Store.hofWithCaller` exited 0 while `deny Unknown Store.hofNoCaller` exited 1.
    // Introduced by `7a89dbc` (⟨0.34⟩ per-caller callback flow), not by the wave.
    private static let r125Fixture = """
    import Foundation

    let probe = NSTemporaryDirectory() + "r125probe.txt"

    struct Store {
        let items: [Int] = [1]
        // A HOF that invokes an OPAQUE, caller-supplied callback. It HAS a visible caller below.
        func hofWithCaller(_ body: (Int) throws -> Void) rethrows {
            try body(items[0])
        }
        // Byte-identical body. The ONLY difference: nothing in this scan calls it.
        func hofNoCaller(_ body: (Int) throws -> Void) rethrows {
            try body(items[0])
        }
    }

    func passer() {
        try? Store().hofWithCaller { _ in try? FileManager.default.removeItem(atPath: probe) }
    }

    FileManager.default.createFile(atPath: probe, contents: Data("x".utf8))
    passer()
    print("probe still exists after passer() == \\(FileManager.default.fileExists(atPath: probe))")
    """

    func testHOFWhoseOnlyCallerPassedAClosureKeepsItsOwnUnknown() throws {
        let by = try scan(DriverResolutionProcessTests.r125Fixture)
        XCTAssertEqual(ProcessHarness.inferred(by, "Store.hofWithCaller"), ["Unknown"],
                       "having a caller must not DELETE the callee's own disclosure — it invokes an "
                       + "unaddressable value whether or not anything in this scan happens to call it")
        XCTAssertEqual(by["Store.hofWithCaller"]?["unknownWhy"] as? [String], ["callback:body"],
                       "and the reason names the param, exactly as the caller-less twin's does")
        // THE CONTROL, unchanged by the fix and unchanged since 819fac6: the twin with no caller.
        XCTAssertEqual(ProcessHarness.inferred(by, "Store.hofNoCaller"), ["Unknown"],
                       "the caller-less twin was always correct — it is the arm that made the loss visible")
        // THE OVER-CHARGE CONTROL: the passer's own row must not move. It carried the closure body's Fs
        // (lexical) and its own callback-flow Unknown before the fix and must carry exactly those after —
        // this is the assertion that would catch the fix leaking a second Unknown up the call graph.
        XCTAssertEqual(ProcessHarness.inferred(by, "passer"), ["Fs", "Unknown"],
                       "the passer is unchanged: the callee's copy of the Unknown reaches no caller that "
                       + "did not already have it")
    }

    /// Scan `src` under a one-line policy and return the process exit code (0 clean / 1 violation /
    /// 2 could-not-evaluate). Runs the SCAN+`--policy` form, which is the form a repo gates with;
    /// `gate --report` over a report scanned WITHOUT a policy fails closed for an unrelated reason
    /// (the manifest was never read) and so cannot discriminate this defect.
    private func policyExit(_ src: String, _ rule: String) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: DriverResolutionProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let pol = root.appendingPathComponent("p.policy")
        try (rule + "\n").write(to: pol, atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("out")
        let r = try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", out.path])
        return r.code
    }

    func testScopedDenyUnknownAtTheHOFItselfFires() throws {
        let src = DriverResolutionProcessTests.r125Fixture
        // THE DEFECT, at the exit code a repo actually gates on. 0 before the fix, 1 after.
        XCTAssertEqual(try policyExit(src, "deny Unknown Store.hofWithCaller"), 1,
                       "a scoped `deny Unknown` on the HOF must fire — it exited 0 on the published binary")
        // The discriminating control: the byte-identical twin, which always fired.
        XCTAssertEqual(try policyExit(src, "deny Unknown Store.hofNoCaller"), 1,
                       "the caller-less twin fired before and after — it is what proves the rule form works")
        // The OVER-CHARGE control, and it is the one that says what the fix does NOT claim: the Fs is
        // the passer's closure, not the HOF's, and `deny Fs` scoped at the HOF must still exit 0.
        XCTAssertEqual(try policyExit(src, "deny Fs Store.hofWithCaller"), 0,
                       "the fix adds the honest Unknown, NOT the caller's concrete effect — fabricating "
                       + "Fs onto the HOF is the mirror sin and must not happen")
    }

    // R126 — the ENUMERATION, not the instance. The row that prompted this claimed the loss needed a
    // conjunction of "nested func + closure + instance-property receiver", inferred from four arms. It
    // did not: those four arms differed in TWO variables, because only the property-receiver arm was ever
    // CALLED, and having a caller is the whole effect (R125 above). Held constant here: every arm below is
    // called exactly once by `driver`, so the receiver kind and the nesting are the only variables left.
    //
    // The full 20-arm sweep — instance `let`/`var`, `static`, computed, subscript, tuple element, local
    // copy, nested-func parameter, nested-type property, literal; direct / one closure / two closures /
    // nested func / nested func in a closure / closure in two nested funcs / `defer` / a stored local
    // closure / a by-reference pass to a sync invoker — was built as an SPM package and RUN (§E3: it
    // prints `arms whose callback did NOT run: none`, so every arm's callback really executes and really
    // deletes its own probe file). ALL TWENTY were ABSENT at the published `819fac6` and at `4f12099`,
    // and all twenty read `Unknown`/`callback:body` after the fix. There is no position-specific hole.
    // Six representatives are pinned here, one per distinct formation site in CallCollector (a direct
    // fn-typed invocation, a by-reference pass to a SYNC_CALLBACK_INVOKER, and an opaque local fn value).
    func testTheCallbackDisclosureSurvivesEveryNestingAndReceiverKind() throws {
        let by = try scan("""
        import Foundation
        struct Store {
            let items: [Int] = [1]
            var computed: [Int] { [1] }
            func direct(_ body: (Int) throws -> Void) rethrows { try body(1) }
            func viaClosureOverProperty(_ body: (Int) throws -> Void) rethrows {
                try items.forEach { i in try body(i) }
            }
            func viaNestedFuncAndClosure(_ body: (Int) throws -> Void) rethrows {
                func loop(_ xs: [Int]) throws { try xs.forEach { i in try body(i) } }
                try loop(items)
            }
            func viaComputedReceiver(_ body: (Int) throws -> Void) rethrows {
                try computed.forEach { i in try body(i) }
            }
            func viaByReferencePass(_ body: (Int) throws -> Void) rethrows { try items.forEach(body) }
            func viaStoredLocalClosure(_ body: @escaping (Int) throws -> Void) {
                let c = { (i: Int) in try? body(i) }; c(1)
            }
        }
        func driver(_ s: Store) {
            try? s.direct { _ in }
            try? s.viaClosureOverProperty { _ in }
            try? s.viaNestedFuncAndClosure { _ in }
            try? s.viaComputedReceiver { _ in }
            try? s.viaByReferencePass { _ in }
            s.viaStoredLocalClosure { _ in }
        }
        """)
        for arm in ["direct", "viaClosureOverProperty", "viaNestedFuncAndClosure",
                    "viaComputedReceiver", "viaByReferencePass", "viaStoredLocalClosure"] {
            XCTAssertEqual(ProcessHarness.inferred(by, "Store.\(arm)"), ["Unknown"],
                           "Store.\(arm) invokes an unaddressable value and must say so — every one of "
                           + "these was ABSENT on the published 0.34.0 binary purely because `driver` calls it")
            XCTAssertEqual(by["Store.\(arm)"]?["unknownWhy"] as? [String], ["callback:body"],
                           "Store.\(arm) must name the param it cannot address")
        }
    }

    // KNOWN RESIDUAL, PINNED SO IT CANNOT DRIFT SILENTLY. When SOME caller resolves the deferral and
    // another does not, `fq` is STILL left silent: `callerA` passes a named fn (resolved) and `Box.callerB`
    // passes an unresolvable one, and `Box.hof` carries nothing of its own. Marking it would propagate
    // `Unknown` over the ordinary call edge into `callerA`, which resolved precisely — undoing the
    // ⟨0.34⟩ per-caller precision this file's `testTwoCallersOfOneHOFResolveIndependently` guards.
    // Closing it needs a per-caller node, not a flag. Asserted in its CURRENT (wrong) shape deliberately:
    // if someone closes it, this test goes red and the reader is sent here rather than to a silent diff.
    func testMixedResolutionLeavesTheHOFsOwnRowSilent() throws {
        let by = try scan("""
        import Foundation
        func sinkA() { _ = FileManager.default.contents(atPath: "/a") }
        struct Box {
            func hof(_ cb: () -> Void) { cb() }
            func callerB() { hof { } }
        }
        func callerA(_ box: Box) { box.hof(sinkA) }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "callerA"), ["Fs"],
                       "the resolved caller keeps its precise answer and gains no Unknown")
        XCTAssertEqual(ProcessHarness.inferred(by, "Box.callerB"), ["Unknown"],
                       "the unresolved caller carries the disclosure")
        XCTAssertNil(by["Box.hof"],
                     "RESIDUAL: one resolved caller is enough to leave the HOF's own row silent, so "
                     + "`deny Unknown Box.hof` still exits 0 here. Not fixed; see the R125 note in "
                     + "Driver.swift. Got \(by["Box.hof"] ?? [:])")
    }

    // ── INHERITED PROPERTY ACCESSORS (soundness round 2026-07-10, R22) ─────────────────────────────
    // An effectful computed property / didSet observer / subscript whose BODY lives on a SUPERCLASS read
    // SILENT-PURE when accessed through a subclass: property-edge resolution matched only the OWN type's
    // `Type.member` unit and — unlike the method-call path — did NOT climb `supertypesOf`. Methods climbed,
    // property accessors did not. Fixed in Driver by mirroring the method climb for property edges.
    func testInheritedPropertyAccessorEffectsClimbTheHierarchy() throws {
        let by = try scan("""
        import Foundation
        class Base { var payload: Data { (try? Data(contentsOf: URL(fileURLWithPath: "/etc/hostname"))) ?? Data() } }  // Fs
        class Derived: Base {}
        class Mid: Base {}; class Leaf: Mid {}
        class Tracked { var name: String = "" { didSet { try? name.write(toFile: "/tmp/a", atomically: true, encoding: .utf8) } } }  // Fs
        class SubTracked: Tracked {}
        class BaseM { func fetch() -> Data { (try? Data(contentsOf: URL(fileURLWithPath: "/etc/hostname"))) ?? Data() } }  // Fs
        class DerivedM: BaseM {}
        // a pure inherited property — the control that must NOT be fabricated onto its reader
        class PureBase { var label: String { "x" } }
        class PureDerived: PureBase {}
        func viaInherited(_ d: Derived) -> Data { d.payload }        // was SILENT → Fs
        func viaTwoLevel(_ l: Leaf) -> Data { l.payload }           // was SILENT → Fs (transitive climb)
        func viaInheritedDidSet(_ s: SubTracked) { s.name = "y" }   // was SILENT → Fs (observer on write)
        func viaInheritedMethod(_ d: DerivedM) -> Data { d.fetch() } // control: methods already climbed
        func viaPure(_ p: PureDerived) -> String { p.label }        // control: must stay pure/omitted
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaInherited"), ["Fs"],
                       "an inherited computed property's effect must reach the subclass reader (was silent-pure)")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaTwoLevel"), ["Fs"],
                       "a two-level-inherited computed property must climb transitively")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaInheritedDidSet"), ["Fs"],
                       "an inherited didSet observer runs on the subclass assignment")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaInheritedMethod"), ["Fs"],
                       "control: an inherited method already climbed")
        XCTAssertNil(by["viaPure"],
                     "a PURE inherited property must not fabricate an effect onto its reader")
    }

    // ── SETTER `newValue` typing (soundness round 2026-07-10, R23) ─────────────────────────────────
    // An effect reached THROUGH a setter's implicit value param (`set { newValue.write(toFile:) }`) read
    // SILENT-PURE: `newValue` was never typed, so a member call on it didn't resolve. Hit computed-property
    // setters, subscript setters, `willSet`, and named setter params. Fixed by seeding the accessor unit's
    // `newValue`/named param with the property/subscript element type. Effects reached via an effectful
    // free-fn/method call that merely takes newValue as an ARG already worked (this is the receiver case).
    func testSetterNewValueIsTypedSoEffectsThroughItResolve() throws {
        let by = try scan("""
        import Foundation
        class Cache { subscript(_ k: String) -> String {
            get { "" }
            set { try? newValue.write(toFile: "/tmp/s", atomically: true, encoding: .utf8) } } }  // Fs via newValue
        class Prop { var slot: String {
            get { "" }
            set { try? newValue.write(toFile: "/tmp/p", atomically: true, encoding: .utf8) } } }
        class Named { var slot: String {
            get { "" }
            set(v) { try? v.write(toFile: "/tmp/n", atomically: true, encoding: .utf8) } } }        // renamed param
        class Will { var slot: String = "" {
            willSet { try? newValue.write(toFile: "/tmp/w", atomically: true, encoding: .utf8) } } }
        class PureSet { var x: String { get { "" } set { _ = newValue } } }                          // pure control
        func viaSubscriptSet(_ c: Cache) { var c = c; c["k"] = "v" }    // was SILENT → Fs
        func viaPropSet(_ p: Prop) { var p = p; p.slot = "v" }         // was SILENT → Fs
        func viaNamedSet(_ n: Named) { var n = n; n.slot = "v" }       // named param typed too → Fs
        func viaWillSet(_ w: Will) { var w = w; w.slot = "v" }         // observer via newValue → Fs
        func viaPureSet(_ p: PureSet) { var p = p; p.x = "v" }         // control: must stay pure/omitted
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaSubscriptSet"), ["Fs"],
                       "a subscript setter's effect reached through newValue must charge (was silent-pure)")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaPropSet"), ["Fs"],
                       "a computed-property setter's effect through newValue must charge")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaNamedSet"), ["Fs"],
                       "a renamed setter param (set(v)) is typed too")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaWillSet"), ["Fs"],
                       "a willSet observer's effect through newValue must charge")
        XCTAssertNil(by["viaPureSet"],
                     "a pure setter must not fabricate an effect onto its writer")
    }

    // ── property-wrapper `$` projection + keypath application (soundness round 2026-07-10, R24 + R25) ──
    // Two more accessor access-paths where the effectful accessor unit exists but the ACCESS SITE didn't
    // edge to it: `m.$name` (the wrapper's projectedValue) and `h[keyPath: \.data]` (a keypath applied via
    // subscript — root is the receiver's OWN type). Both read silent-pure. The element-map keypath
    // (`xs.map(\.p)`) already worked and must stay working; a pure member via keypath must stay pure.
    func testProjectedValueAndKeyPathAccessorEffectsCharge() throws {
        let by = try scan("""
        import Foundation
        @propertyWrapper struct Tracker {
            var wrappedValue: String
            var projectedValue: String { try? wrappedValue.write(toFile: "/tmp/p", atomically: true, encoding: .utf8); return "" }  // Fs
        }
        class Model { @Tracker var name: String = "" }
        class Holder { var data: String { (try? String(contentsOfFile: "/etc/hostname", encoding: .utf8)) ?? "" } }  // Fs
        class Pure { var label: String { "x" } }
        func viaProjected(_ m: Model) -> String { m.$name }              // R24: was silent → Fs
        func viaKeyPath(_ h: Holder) -> String { h[keyPath: \\.data] }   // R25: was silent → Fs
        func viaMapKeyPath(_ hs: [Holder]) -> [String] { hs.map(\\.data) } // pre-existing element case, still Fs
        func viaKeyPathPure(_ p: Pure) -> String { p[keyPath: \\.label] } // control: pure via keypath stays pure
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaProjected"), ["Fs"],
                       "a property-wrapper projectedValue reached via $-access must charge (was silent)")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaKeyPath"), ["Fs"],
                       "an effectful computed property read via h[keyPath: \\.p] must charge (was silent)")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaMapKeyPath"), ["Fs"],
                       "the element-map keypath case must still charge (no regression)")
        XCTAssertNil(by["viaKeyPathPure"],
                     "a pure computed property read via keypath must not fabricate an effect")
    }

    // ── generic-constrained dispatch: where-clause + type-level bounds (soundness 2026-07-10, R26 + R27) ──
    // The inline `<T: P>` bound already dispatched `x.method()` to P's conformers. Two forms were missed:
    // the `where T: P` clause (R26) and a TYPE-level bound `struct Box<T: P> { let x: T }` reaching
    // `x.method()` (R27 — the field typed `T` wasn't resolved to its bound). Both silent-pure.
    func testGenericConstrainedDispatchWhereClauseAndTypeLevelBounds() throws {
        let by = try scan("""
        import Foundation
        protocol Saver { func save() }
        struct DiskSaver: Saver { func save() { try? "x".write(toFile: "/tmp/s", atomically: true, encoding: .utf8) } }  // Fs
        func viaWhere<T>(_ x: T) where T: Saver { x.save() }             // R26: was silent → Fs
        struct Pipe<T: Saver> { let item: T; func run() { item.save() } }
        func viaTypeLevel(_ p: Pipe<DiskSaver>) { p.run() }              // R27: Pipe.run was silent → Fs
        func viaInline<T: Saver>(_ x: T) { x.save() }                    // control: inline bound already worked
        func viaUnconstrained<T>(_ x: T) -> T { x }                      // control: no dispatch → no effect
        struct Plain<T> { let item: T }                                  // unconstrained type-level generic
        func viaPlainField(_ p: Plain<DiskSaver>) -> DiskSaver { p.item } // control: no method call → pure
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaWhere"), ["Fs"],
                       "a `where T: P` generic bound must dispatch like the inline `<T: P>` bound (was silent)")
        XCTAssertEqual(ProcessHarness.inferred(by, "Pipe.run"), ["Fs"],
                       "a stored field typed as the type's bounded generic param must dispatch (was silent)")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaInline"), ["Fs"],
                       "control: the inline `<T: P>` bound still dispatches")
        XCTAssertNil(by["viaUnconstrained"],
                     "an unconstrained generic with no dispatched call must stay pure (no fabrication)")
        XCTAssertNil(by["viaPlainField"],
                     "reading an unconstrained-generic field (no method call) must not fabricate an effect")
    }

    // ── @resultBuilder transform (soundness round 2026-07-10, R29) ─────────────────────────────────
    // A func annotated `@SomeBuilder` has its body compiler-transformed into `SomeBuilder.buildBlock(...)`
    // etc — so an effectful builder RUNS when the func is called. That transform is implicit (no call site),
    // so an effectful buildBlock read silent-pure. Now the annotated func edges to the builder's build*
    // units. A PURE builder adds nothing (no fabrication).
    func testResultBuilderTransformChargesBuilderEffects() throws {
        let by = try scan("""
        import Foundation
        @resultBuilder struct EffB { static func buildBlock(_ xs: Int...) -> Int { try? "x".write(toFile: "/tmp/e", atomically: true, encoding: .utf8); return 0 } }  // Fs
        @resultBuilder struct PureB { static func buildBlock(_ xs: Int...) -> Int { 0 } }
        @EffB func effBuilt() -> Int { 1 }
        @PureB func pureBuilt() -> Int { 1 }
        func viaEffBuilder() { _ = effBuilt() }     // was silent → Fs
        func viaPureBuilder() { _ = pureBuilt() }   // control: pure builder must not fabricate
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaEffBuilder"), ["Fs"],
                       "an effectful @resultBuilder buildBlock must charge when the annotated func is called")
        XCTAssertNil(by["viaPureBuilder"],
                     "a pure @resultBuilder must not fabricate an effect onto its annotated func")
    }

    /// R29's build-method list has EIGHT members and only `buildBlock` was ever driven by a fixture.
    ///
    /// GUARD-DELETION MEASURED 2026-08-30: cutting `Driver.swift`'s list to `["buildBlock"]` — deleting
    /// seven eighths of the transform — left all 958 tests GREEN, in both this suite and
    /// `MacroDisclosureProcessTests`, the only two places that mention `@resultBuilder` at all. This is
    /// the sidecar-segment shape one layer over: a hand-maintained list whose members are individually
    /// load-bearing and collectively pinned by one of them.
    ///
    /// It is not a hypothetical remainder either. `buildExpression` is what SwiftUI's `ViewBuilder`
    /// applies to every leaf, `buildPartialBlock` is the 5.9+ spelling that replaced variadic
    /// `buildBlock` overloads, and `buildOptional`/`buildEither` are what `if`/`else` in a builder body
    /// lower to — a builder that does its work in any of them and defines no `buildBlock` reads
    /// SILENT-PURE at every annotated func, which is the exact defect R29 exists to close.
    ///
    /// ONE DISTINGUISHABLE EFFECT PER METHOD, deliberately (AGENT-CORPUS-BRIEF §4): a shared effect
    /// label would let one working method mask six broken ones.
    func testResultBuilderTransformCoversEveryBuildMethodNotJustBuildBlock() throws {
        let by = try scan("""
        import Foundation
        @resultBuilder struct ExprB { static func buildExpression(_ x: Int) -> Int { try? "x".write(toFile: "/tmp/e", atomically: true, encoding: .utf8); return x } }
        @resultBuilder struct OptB { static func buildOptional(_ x: Int?) -> Int { _ = getenv("HOME"); return 0 } }
        @resultBuilder struct EitherB { static func buildEither(first x: Int) -> Int { _ = Date(); return x } }
        @resultBuilder struct ArrayB { static func buildArray(_ xs: [Int]) -> Int { _ = Process(); return 0 } }
        @resultBuilder struct FinalB { static func buildFinalResult(_ x: Int) -> Int { NSLog("x"); return x } }
        @resultBuilder struct PartialB { static func buildPartialBlock(first x: Int) -> Int { _ = Pipe(); return x } }
        @resultBuilder struct AvailB { static func buildLimitedAvailability(_ x: Int) -> Int { _ = sqlite3_exec(nil, nil, nil, nil, nil); return x } }
        @ExprB func viaExpr() -> Int { 1 }
        @OptB func viaOpt() -> Int { 1 }
        @EitherB func viaEither() -> Int { 1 }
        @ArrayB func viaArray() -> Int { 1 }
        @FinalB func viaFinal() -> Int { 1 }
        @PartialB func viaPartial() -> Int { 1 }
        @AvailB func viaAvail() -> Int { 1 }
        func callExpr() { _ = viaExpr() }
        func callOpt() { _ = viaOpt() }
        func callEither() { _ = viaEither() }
        func callArray() { _ = viaArray() }
        func callFinal() { _ = viaFinal() }
        func callPartial() { _ = viaPartial() }
        func callAvail() { _ = viaAvail() }
        """)
        for (caller, effect, method) in [("callExpr", "Fs", "buildExpression"),
                                         ("callOpt", "Env", "buildOptional"),
                                         ("callEither", "Clock", "buildEither"),
                                         ("callArray", "Exec", "buildArray"),
                                         ("callFinal", "Log", "buildFinalResult"),
                                         ("callPartial", "Ipc", "buildPartialBlock"),
                                         ("callAvail", "Db", "buildLimitedAvailability")] {
            XCTAssertEqual(ProcessHarness.inferred(by, caller), [effect],
                           "`\(method)` runs when the annotated func is called, exactly as `buildBlock` "
                           + "does — a builder doing its work there must not read silent-pure")
        }
    }

    // ── conditional conformance on a stdlib collection (soundness round 2026-07-11, R28) ───────────
    // `extension Array: Saveable where Element: Saveable` reached via `xs.persist()` read silent-pure —
    // two gaps: the array-receiver → `Array.persist` edge, AND the bare `forEach { $0.persist() }` over
    // self (whose element is the bound `Saveable`) not dispatching. Both fixed. A PURE conditional
    // conformance, and a std array method with a local Array extension present, must not fabricate.
    func testConditionalConformanceOnArrayCollectionDispatches() throws {
        let by = try scan("""
        import Foundation
        protocol Saveable { func persist() }
        struct Item: Saveable { func persist() { try? "x".write(toFile: "/tmp/i", atomically: true, encoding: .utf8) } }  // Fs
        extension Array: Saveable where Element: Saveable { func persist() { forEach { $0.persist() } } }
        func viaConditional(_ xs: [Item]) { xs.persist() }             // R28 chain → Fs
        // control: a PURE conditional-conformance extension must stay pure (no fabrication)
        protocol Named { func label() -> String }
        struct Tag: Named { func label() -> String { "t" } }           // pure
        extension Array where Element: Named { func labels() -> [String] { map { $0.label() } } }
        func viaPureConditional(_ xs: [Tag]) -> [String] { xs.labels() }  // must stay pure
        // control: a std array method (forEach) with a local Array extension present must not disclose Unknown
        func viaStdArrayMethod(_ xs: [Item]) { xs.forEach { $0.persist() } }  // Fs, and NOT Unknown
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaConditional"), ["Fs"],
                       "the conditional-conformance chain xs.persist() → Array.persist → Item.persist must charge")
        XCTAssertNil(by["viaPureConditional"],
                     "a pure conditional conformance must not fabricate an effect")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaStdArrayMethod"), ["Fs"],
                       "a std array method with a local Array extension present must charge Fs and NOT disclose a spurious Unknown")
    }

    // R32 — an UNQUALIFIED requirement call inside a PROTOCOL EXTENSION (`extension Sink { func provided()
    // { req() } }`) dispatches to each conformer's WITNESS. A custom effectful witness reached only via the
    // extension-provided method read silent-pure (the protocol-witness sibling of the concrete-receiver
    // default dispatch). Every conformer form carries; a pure witness / a bare FREE fn inside an extension
    // (resolved by name, not a requirement) must stay correct.
    func testUnqualifiedRequirementCallInProtocolExtensionDispatchesToWitness() throws {
        let by = try scan("""
        import Foundation
        protocol Sink { func req() }
        extension Sink { func provided() { req() } }
        struct S: Sink { func req() { try? Data("x".utf8).write(to: URL(fileURLWithPath: "/tmp/x")) } }  // Fs
        func viaProvided(_ s: S) { s.provided() }                       // → Sink.provided → S.req (Fs)
        // PURE control: an extension provided method calling a pure requirement must stay pure
        protocol PureSink { func handle() }
        extension PureSink { func run() { handle() } }
        struct PS: PureSink { func handle() {} }
        func viaPure(_ p: PS) { p.run() }
        // FREE-FN control: a bare free fn inside a protocol extension is NOT a requirement — it must still
        // resolve by name (never lost, never fabricated as a phantom dispatch)
        func freeHelper() { try? Data("y".utf8).write(to: URL(fileURLWithPath: "/tmp/y")) }  // Fs
        protocol HasHelper { func x() }
        extension HasHelper { func callsFree() { freeHelper() } }
        struct HH: HasHelper { func x() {} }
        func viaFree(_ h: HH) { h.callsFree() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaProvided"), ["Fs"],
                       "s.provided() → the extension's req() must dispatch to the S.req witness (Fs)")
        XCTAssertNil(by["viaPure"],
                     "a pure witness reached via an extension provided method must stay pure (no over-fire)")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaFree"), ["Fs"],
                       "a bare free fn inside a protocol extension must still resolve by name (not filtered away)")
    }

    // R33 — deinit-glue: a `let`/`var` LOCAL bound to a fresh CONSTRUCTION of a type with an effectful
    // `deinit` runs that deinit at scope exit (deterministic under ARC for a non-escaping local), which
    // read silent-pure (the deinit unit has no syntactic caller). Charge the constructing scope — but NOT
    // an escaping value (factory-return / field-store / alias), mirroring rust Drop-glue's let-bound rule.
    func testDeinitGlueChargesNonEscapingLocalConstruction() throws {
        let by = try scan("""
        import Foundation
        class Resource { deinit { try? Data("x".utf8).write(to: URL(fileURLWithPath: "/tmp/x")) } }  // Fs
        func makesLocal() { let r = Resource(); _ = r }                 // Fs — deinit at scope exit
        func makesVar() { var r = Resource(); _ = r }                   // Fs
        func factory() -> Resource { return Resource() }               // PURE — escapes (no binding)
        class Holder { var r: Resource?; func stash() { self.r = Resource() } }  // PURE — stored, deferred
        func aliases(_ existing: Resource) { let r = existing; _ = r }  // PURE — alias, not a construction
        class Plain { deinit {} }
        func makesPlain() { let p = Plain(); _ = p }                    // PURE — pure deinit
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "makesLocal"), ["Fs"],
                       "a non-escaping local of an effectful-deinit type must charge the deinit at scope exit")
        XCTAssertEqual(ProcessHarness.inferred(by, "makesVar"), ["Fs"], "a var binding charges too")
        XCTAssertNil(by["factory"], "a factory that RETURNS its product does not run the deinit here (no over-charge)")
        XCTAssertNil(by["Holder.stash"], "storing the value in a field defers the deinit — the constructor scope is pure")
        XCTAssertNil(by["aliases"], "aliasing an existing value is not a fresh construction — never charged")
        XCTAssertNil(by["makesPlain"], "a pure deinit contributes nothing")
    }

    // R34 — a GENERIC/protocol-typed operator: `a + b` where `a: T: P` and `P` declares the operator
    // dispatches to `P`'s conformers' operator witnesses (bounded CHA), the operator analog of the
    // generic-method path. An effectful `static func +` witness reached only through a generic bound read
    // silent-pure. A pure conformer / a std `Numeric` bound / plain `Int + Int` must stay pure.
    func testGenericOperatorDispatchesToConformerWitness() throws {
        let by = try scan("""
        import Foundation
        func sink() { try? Data().write(to: URL(fileURLWithPath: "/tmp/x")) }  // Fs
        protocol EAdd { static func + (a: Self, b: Self) -> Self }
        struct Eff: EAdd { static func + (a: Eff, b: Eff) -> Eff { sink(); return a } }  // Fs witness
        func genEff<T: EAdd>(_ a: T, _ b: T) -> T { a + b }        // Fs via bounded CHA
        func concrete(_ a: Eff, _ b: Eff) -> Eff { a + b }         // Fs (concrete operand)
        protocol PAdd { static func + (a: Self, b: Self) -> Self }
        struct Pure: PAdd { static func + (a: Pure, b: Pure) -> Pure { a } }  // pure
        func genPure<T: PAdd>(_ a: T, _ b: T) -> T { a + b }       // PURE — no over-fire
        func genNumeric<T: Numeric>(_ a: T, _ b: T) -> T { a + b } // PURE — std bound, no local witness
        func stdInt() -> Int { 1 + 2 }                             // PURE
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "genEff"), ["Fs"],
                       "a generic operator `a+b` on a `T: EAdd` bound must dispatch to the effectful witness")
        XCTAssertEqual(ProcessHarness.inferred(by, "concrete"), ["Fs"], "the concrete-operand path still carries")
        XCTAssertNil(by["genPure"], "a pure operator witness must stay pure (no over-fire)")
        XCTAssertNil(by["genNumeric"], "a std Numeric bound has no local witness — must not fabricate")
        XCTAssertNil(by["stdInt"], "plain Int + Int is the stdlib operator — pure")
    }

    // R35 — a `@dynamicCallable` value: `c(1, 2)` desugars to `c.dynamicallyCall(withArguments:)`, whose
    // effectful body read silent-pure (the desugar was invisible). Edge to the witness; a pure witness
    // stays pure, and `callAsFunction` (the other value-call desugar) is unaffected.
    func testDynamicCallableDispatchesToWitness() throws {
        let by = try scan("""
        import Foundation
        func sink() { try? Data().write(to: URL(fileURLWithPath: "/tmp/x")) }  // Fs
        @dynamicCallable struct Caller { func dynamicallyCall(withArguments a: [Int]) -> Int { sink(); return 0 } }
        func viaDynCall(c: Caller) { _ = c(1, 2) }                 // Fs
        @dynamicCallable struct PureCaller { func dynamicallyCall(withArguments a: [Int]) -> Int { 0 } }
        func viaPure(c: PureCaller) { _ = c(1) }                   // PURE
        struct CallF { func callAsFunction() { sink() } }
        func viaCallAsFn(c: CallF) { c() }                         // Fs — callAsFunction still works
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaDynCall"), ["Fs"],
                       "c(args) on a @dynamicCallable type must dispatch to dynamicallyCall")
        XCTAssertNil(by["viaPure"], "a pure dynamicallyCall witness stays pure")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaCallAsFn"), ["Fs"], "callAsFunction dispatch is unaffected")
    }

    // A GENERIC-element array `[T]` where `<T: Doer>` iterates + dispatches over the bound, exactly like an
    // existential `[any Doer]` element (which already worked). The generic element resolved to the bare "T"
    // (not the protocol), so `for it in items { it.go() }` read silent-pure.
    func testGenericArrayElementDispatchesOverBound() throws {
        let by = try scan("""
        import Foundation
        func sink() { try? Data().write(to: URL(fileURLWithPath: "/tmp/x")) }
        protocol Doer { func go() }
        struct Impl: Doer { func go() { sink() } }
        func viaGeneric<T: Doer>(_ items: [T]) { for it in items { it.go() } }      // Fs
        func viaExistential(_ items: [any Doer]) { for it in items { it.go() } }    // Fs (control)
        protocol Quiet { func run() }
        struct Q: Quiet { func run() {} }
        func viaPure<T: Quiet>(_ items: [T]) { for it in items { it.run() } }       // PURE
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaGeneric"), ["Fs"],
                       "a generic `[T: Doer]` array element must dispatch over the bound")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaExistential"), ["Fs"], "the existential control still carries")
        XCTAssertNil(by["viaPure"], "a pure-protocol bound must stay pure (no over-fire)")
    }

    // Dispatching a method on a PROTOCOL-typed value reached through a CONTAINER/OPTIONAL — the sibling
    // of the array-element existential path (which already worked). Three veins read silent-pure because
    // the value landed untyped instead of on the protoDispatch path:
    //   1. dict VALUE iteration  `for v in m.values { v.go() }`  over `[K: any Doer]`
    //   2. optional if-let unwrap `if let d = o { d.go() }`      over `(any Doer)?`
    //   3. optional `.map`       `o.map { $0.go() }`             over `(any Doer)?`
    // Each must dispatch over `Doer`'s conformers (here `Impl.go` → Fs). Over-fire controls: a CONCRETE
    // pure value type, a PURE-protocol conformer, and a plain `[String: Int]` must all stay pure.
    func testProtocolValueViaContainerOrOptionalDispatches() throws {
        let by = try scan("""
        import Foundation
        func sink() { try? Data().write(to: URL(fileURLWithPath: "/tmp/x")) }
        protocol Doer { func go() }
        struct Impl: Doer { func go() { sink() } }
        func viaDictValues(_ m: [String: any Doer]) { for v in m.values { v.go() } }   // Fs
        func viaOptional(_ o: (any Doer)?) { if let d = o { d.go() } }                 // Fs
        func viaOptMap(_ o: (any Doer)?) { o.map { $0.go() } }                         // Fs
        // over-fire controls
        struct PureVal { func go() {} }
        func ctrlDictConcretePure(_ m: [String: PureVal]) { for v in m.values { v.go() } }  // PURE
        protocol Quiet { func run() }
        struct Q: Quiet { func run() {} }
        func ctrlOptPureProto(_ o: (any Quiet)?) { if let d = o { d.run() } }               // PURE
        func ctrlOptMapPureProto(_ o: (any Quiet)?) { o.map { $0.run() } }                  // PURE
        func ctrlPlainDict(_ m: [String: Int]) { for v in m.values { _ = v + 1 } }          // PURE
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaDictValues"), ["Fs"],
                       "a dict VALUE dispatch over `[K: any Doer]` must carry the conformer's Fs")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaOptional"), ["Fs"],
                       "an if-let-unwrapped `(any Doer)?` must dispatch over the protocol")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaOptMap"), ["Fs"],
                       "an Optional.map closure over `(any Doer)?` must dispatch over the protocol")
        XCTAssertNil(by["ctrlDictConcretePure"], "a concrete pure-method dict value stays pure (no over-fire)")
        XCTAssertNil(by["ctrlOptPureProto"], "a pure-protocol optional stays pure (no over-fire)")
        XCTAssertNil(by["ctrlOptMapPureProto"], "a pure-protocol optional map stays pure (no over-fire)")
        XCTAssertNil(by["ctrlPlainDict"], "a plain `[String: Int]` stays pure (no fabrication)")
    }

    // A SUPER-PROTOCOL method dispatched via a Sub bound / `any Sub`. `protocol Sub: Sup`, `base ∈ Sup`,
    // `s.base()` where `s: any Sub` (or `t: T: Sub`) read SILENT-PURE: two gates each rejected an
    // INHERITED member — (a) `visit(ProtocolDeclSyntax)` never recorded the `: Sup` inheritance, so
    // `supertypesOf[Sub]` didn't contain `Sup`; (b) the dispatch gate checked only `protocolMethods[Sub]`.
    // A Sup method IS callable on a Sub receiver and Sub's conformers provide the witness (`Impl.base`).
    // Over-fire controls: the sub's OWN pure method stays pure; a super method with a PURE conformer impl
    // stays pure; an UNRELATED same-named protocol must not hijack a Sub receiver; a conformer-less super
    // chain reads honest Unknown (never fabricated pure).
    func testSuperProtocolMethodDispatchesViaSubBound() throws {
        let by = try scan("""
        import Foundation
        func sink() { try? Data().write(to: URL(fileURLWithPath: "/tmp/x")) }
        protocol Sup { func base() }
        protocol Sub: Sup { func extra() }
        struct Impl: Sub { func base() { sink() }; func extra() {} }   // base does Fs
        func viaProto(_ s: any Sub) { s.base() }                       // Fs (inherited method, any Sub)
        func viaGeneric<T: Sub>(_ t: T) { t.base() }                   // Fs (inherited method, T: Sub)
        func ownPure(_ s: any Sub) { s.extra() }                       // PURE (sub's own pure method)
        // a super method whose conformer impl is PURE stays pure
        protocol PSup { func p() }
        protocol PSub: PSup { func q() }
        struct PImpl: PSub { func p() {}; func q() {} }
        func superPure(_ s: any PSub) { s.p() }                        // PURE
        // an UNRELATED same-named `base` must not hijack a Sub receiver
        protocol Other { func base() }
        struct OtherImpl: Other { func base() { sink() } }
        func noHijack<T: Sub>(_ t: T) { t.extra() }                    // PURE (Other.base must not leak)
        // a conformer-less super chain reads honest Unknown, never fabricated pure
        protocol LSup { func lm() }
        protocol LSub: LSup {}
        func viaNoConf(_ s: any LSub) { s.lm() }                       // Unknown
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaProto"), ["Fs"],
                       "an inherited (super-protocol) method via `any Sub` must dispatch to the conformer's Fs")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaGeneric"), ["Fs"],
                       "an inherited (super-protocol) method via a `T: Sub` bound must dispatch to the conformer's Fs")
        XCTAssertNil(by["ownPure"], "the sub's OWN pure method stays pure (no over-fire)")
        XCTAssertNil(by["superPure"], "a super method with a pure conformer impl stays pure (no over-fire)")
        XCTAssertNil(by["noHijack"], "an unrelated same-named protocol must not hijack a Sub receiver")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaNoConf"), ["Unknown"],
                       "a conformer-less super chain reads honest Unknown, never fabricated pure")
    }

    // ── SYNC callback-invoker: an OPAQUE closure param passed to forEach&friends is CALLED here ─────
    // (the Swift arm of the four-way sync-callback parity fix — candor-java). `xs.forEach(cb)` runs
    // `cb` synchronously, the exact sibling of the direct `cb()`, yet the param used to be DROPPED →
    // silent-pure (the cardinal sin). It must read Unknown; INLINE closures and RESOLVABLE named fns
    // must NOT regress (no over-disclosure, no fabrication).
    func testOpaqueClosureParamToForEachReadsUnknown() throws {
        let by = try scan("""
        func opaqueForEach(_ cb: (Int) -> Void) { [1, 2, 3].forEach(cb) }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "opaqueForEach"), ["Unknown"],
                       "an opaque closure param synchronously invoked by forEach must read Unknown, not silent-pure")
        XCTAssertEqual(by["opaqueForEach"]?["unknownWhy"] as? [String], ["callback:cb"],
                       "the Unknown names the invoked opaque callback param")
    }

    // the opaque param passed to the OTHER sync invokers (map/filter/reduce) — all invoke synchronously.
    func testOpaqueClosureParamToMapFilterReduceReadsUnknown() throws {
        let by = try scan("""
        func viaMap(_ t: (Int) -> Int) -> [Int] { return [1, 2, 3].map(t) }
        func viaFilter(_ p: (Int) -> Bool) -> [Int] { return [1, 2, 3].filter(p) }
        func viaReduce(_ c: (Int, Int) -> Int) -> Int { return [1, 2, 3].reduce(0, c) }
        """)
        for fn in ["viaMap", "viaFilter", "viaReduce"] {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Unknown"],
                           "\(fn): an opaque closure param synchronously invoked must read Unknown")
        }
    }

    // NO-REGRESSION: an INLINE closure literal keeps its analyzed effect (charged lexically to the
    // passer) — the sync-invoker guard fires only on OPAQUE refs, never on inline closures.
    func testInlineEffectfulClosureToForEachStillReportsItsEffect() throws {
        let by = try scan("""
        import Foundation
        func inlineEffect() { [1, 2, 3].forEach { _ in FileManager.default.createFile(atPath: "/tmp/y", contents: nil) } }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "inlineEffect"), ["Fs"],
                       "an inline effectful forEach closure keeps its Fs — must NOT be masked or turned Unknown")
    }

    // NO-OVER-DISCLOSURE: a PURE inline forEach stays pure — the guard must not flood common inline code.
    func testPureInlineForEachStaysPure() throws {
        let by = try scan("""
        func pureInline() { [1, 2, 3].forEach { _ = $0 + 1 } }
        func pureInlineMap() -> [Int] { return [1, 2, 3].map { $0 + 1 } }
        """)
        XCTAssertNil(by["pureInline"], "a pure inline forEach must stay pure — no over-disclosure")
        XCTAssertNil(by["pureInlineMap"], "a pure inline map must stay pure — no over-disclosure")
    }

    // NO-REGRESSION: a RESOLVABLE named callable passed to forEach keeps its RESOLVED effect (precise
    // edge), never a blanket Unknown — the fn-ref path resolves it; only OPAQUE args disclose.
    func testNamedCallableToForEachKeepsResolvedEffect() throws {
        let by = try scan("""
        import Foundation
        func namedEffect(_ x: Int) { FileManager.default.createFile(atPath: "/tmp/z", contents: nil) }
        func passNamedEffect() { [1, 2, 3].forEach(namedEffect) }
        func namedPure(_ x: Int) { _ = x + 1 }
        func passNamedPure() { [1, 2, 3].forEach(namedPure) }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "passNamedEffect"), ["Fs"],
                       "a resolvable named effectful callable resolves to its effect (edge), never Unknown")
        XCTAssertNil(by["passNamedPure"], "a resolvable named pure callable stays pure — no fabrication")
    }

    /// THE REPORT MUST BE REPRODUCIBLE. `supertypesOf` is a `[String: Set<String>]`, and Swift seeds Set
    /// hashing PER PROCESS — so picking the disclosure's supertype with `.first` gave a different
    /// `unknownWhy` on different runs of the same binary over the same input. Measured on a real project:
    /// 14 functions churned between `dispatch:CodingKey.self` and `dispatch:String.self`, and the per-function
    /// reason SET changed size when two call sites picked differently. Effect sets were stable throughout,
    /// which is exactly why it went unnoticed.
    ///
    /// This is asserted as a PROPERTY (the alphabetically-first external supertype wins) rather than by
    /// scanning twice: two scans inside one test process share a hash seed, so a double-scan could pass
    /// while the defect was live. A property is checkable in one run and cannot pass by luck.
    ///
    /// It matters beyond tidiness: A/B diffing reports on real code is this project's primary evidence, and
    /// a report that differs from ITSELF injects noise into every diff — it cost a false datapoint before
    /// anyone thought to diff a report against itself. It also makes `gains` noisy on identical inputs.
    func testDisclosureReasonIsDeterministicAcrossRuns() throws {
        let by = try scan("""
        protocol ZZeta { }
        protocol AAlpha { }
        final class Thing: ZZeta, AAlpha { func go() { self.unresolvedMember() } }
        """)
        let why = (by["Thing.go"]?["unknownWhy"] as? [String]) ?? []
        XCTAssertTrue(why.contains("dispatch:AAlpha.unresolvedMember"),
                      "the disclosure must name a STABLE supertype — the alphabetically-first — so the "
                      + "report is byte-reproducible run to run; got \(why)")
    }

    // ── PROTOCOL-TYPED RECEIVERS: ONE MEMBER SPACE, NOT TWO HALVES ────────────────────────────────
    // A protocol's members come in two kinds — REQUIREMENTS (the witness that runs belongs to a
    // conformer) and EXTENSION-PROVIDED (`extension P { func provided() {…} }`, a real `P.provided`
    // body). Two lookup paths used to cover one kind each, and WHICH path a call took was decided by
    // something orthogonal to the question: `visit(ExtensionDeclSyntax)` calls `pushType` on whatever
    // it extends, so declaring ANY extension on `P` put `P` into `localTypes`, and a `P`-typed
    // field/local then resolved through the concrete-type path — which answers extension-provided
    // members and DROPS requirements, because a requirement has no body to name. A parameter receiver
    // took the CHA path, which is the mirror image: requirements resolve, extension-provided members
    // were dropped by a requirement-only gate.
    //
    // So a DI seam — `protocol Deployer`, `final class LiveDeployer` running `Process()`, a service
    // holding `let deployer: Deployer` — certified `service.deploy(tag)` PURE, and a `deny Exec` gate
    // scoped at that service exited 0. The whole point of a protocol is that the receiver is typed as
    // the protocol; every protocol-extension fixture in this suite typed its receiver as the CONCRETE
    // conforming type, which is why the suite was green over it.
    //
    // Both halves are answered from one member space now. The controls are the load-bearing half of
    // this test: widening CHA is exactly where fabrication gets introduced.
    func testProtocolTypedReceiverAnswersRequirementsAndExtensionProvidedMembersAlike() throws {
        let by = try scan("""
        import Foundation
        func shell(_ c: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: c); try? p.run() }
        protocol Deployer { func deploy(_ tag: String) }
        extension Deployer { func deployLatest() { deploy("latest") } }
        struct LiveDeployer: Deployer { func deploy(_ tag: String) { shell("/usr/bin/env") } }   // Exec
        struct DryRunDeployer: Deployer { func deploy(_ tag: String) { _ = tag } }               // pure
        func viaParamRequirement(_ d: Deployer) { d.deploy("v1") }
        func viaParamProvided(_ d: Deployer) { d.deployLatest() }
        final class ReleaseService {
            let deployer: Deployer
            init(deployer: Deployer) { self.deployer = deployer }
            func run() { deployer.deploy("v2") }              // FIELD receiver, REQUIREMENT
            func runProvided() { deployer.deployLatest() }    // FIELD receiver, extension-PROVIDED
        }
        func viaLocal() { let d: Deployer = LiveDeployer(); d.deploy("v3") }
        func viaConcrete(_ d: LiveDeployer) { d.deployLatest() }
        // OVER-CHARGE CONTROL 1 — an ALL-PURE protocol family, extension present, must stay pure.
        protocol Fmt2 { func fmt(_ s: String) -> String }
        extension Fmt2 { func fmtAll(_ xs: [String]) -> [String] { xs.map { fmt($0) } } }
        struct Upper: Fmt2 { func fmt(_ s: String) -> String { s.uppercased() } }
        struct Lower: Fmt2 { func fmt(_ s: String) -> String { s.lowercased() } }
        final class Fmt { let f: Fmt2; init(f: Fmt2) { self.f = f }
                          func one(_ s: String) -> String { f.fmt(s) } }
        // OVER-CHARGE CONTROL 2 — a SAME-NAMED member on an UNRELATED protocol must not cross over.
        protocol Cache { func flush() }
        extension Cache { func flushAll() { flush() } }
        struct MemCache: Cache { func flush() {} }
        protocol Disk { func flush() }
        struct DiskStore: Disk { func flush() { shell("/bin/sync") } }
        func viaCache(_ c: Cache) { c.flush() }
        func viaCacheProvided(_ c: Cache) { c.flushAll() }
        """)
        for fn in ["viaParamRequirement", "viaParamProvided", "ReleaseService.run",
                   "ReleaseService.runProvided", "viaLocal", "viaConcrete"] {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Exec"],
                           "\(fn) reaches LiveDeployer.deploy through a Deployer seam — a protocol-typed "
                           + "receiver must answer BOTH member kinds, whatever binder the receiver came from")
        }
        XCTAssertNil(by["Fmt.one"],
                     "an all-pure protocol family must stay pure — the CHA must not fabricate")
        XCTAssertNil(by["viaCache"],
                     "a same-named requirement on an UNRELATED protocol must not inherit DiskStore's Exec")
        XCTAssertNil(by["viaCacheProvided"],
                     "…and neither must its extension-provided member")
    }

    // The corpus A/B caught this and nothing else did: the typed-call path routes an OVERLOADED base
    // through `matchOverloads`, and the first version of the fix above answered the extension-provided
    // half with a bare `resolveQual`, which cannot name an overloaded base. Every sibling-overload edge
    // at such a site was dropped — swift-syntax's `TokenConsumer.consume(_)` lost 5 edges, swift-protobuf's
    // `Message.init(String,ExtensionMap)` lost 10. A fabrication fix producing a silent under-report is the
    // documented failure mode of fabrication fixes; this pins the direction it failed in.
    func testOverloadedExtensionProvidedMemberStillResolvesThroughAProtocolReceiver() throws {
        let by = try scan("""
        import Foundation
        func shell(_ c: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: c); try? p.run() }
        protocol Emit { func mark() }
        extension Emit {
            func send(_ s: String) { shell("/bin/echo") }      // Exec — the overload the call selects
            func send(_ n: Int) { _ = n }                      // pure sibling overload
            func relay(_ s: String) { send(s) }
        }
        struct E: Emit { func mark() {} }
        func viaProtoReceiver(_ e: Emit) { e.send("x") }
        func viaProtoField() { let e: Emit = E(); e.relay("x") }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaProtoReceiver"), ["Exec"],
                       "an OVERLOADED extension-provided member must resolve through a protocol-typed "
                       + "receiver exactly as it does through a concrete one — never dropped for being overloaded")
        XCTAssertEqual(ProcessHarness.inferred(by, "viaProtoField"), ["Exec"],
                       "…including one reached through a chain of provided members")
    }

    // THE SIBLING DEFECT to the test above, on the OTHER half of the SAME branch: a CONCRETE receiver
    // (`s: S`, not a protocol-typed one) reaching a protocol's extension-PROVIDED member through
    // `supertypesOf` (Driver.swift's "PROTOCOL-EXTENSION DEFAULT via a CONCRETE receiver" comment).
    // That arm called plain `resolveQual(base)` with no `overloadedBases` check at all — unlike the
    // sibling arm above and the ordinary typed-call arm (`call.typed` a few lines up), both of which
    // already route an overloaded base through `matchOverloads`. A protocol extension declaring a
    // second, UNRELATED overload of the provided member's name (`run()` beside `run(times:)`) made
    // `qualBySimple[base].count == 2`, so `resolveQual` returned nil and the call's ONLY edge —
    // `useS`'s sole reach to `Runner.run(times:)` — was dropped with no `Unknown`, no `incomplete`,
    // nothing: `deny Exec` exited 0 over code that plainly performs it. Corpus A/B, held constant to
    // ONE variable (the sibling overload's mere presence): candor-swift SOUNDNESS-VEIN write-up filed
    // 2026-08-27.
    func testOverloadedExtensionProvidedMemberStillResolvesThroughAConcreteReceiver() throws {
        let by = try scan("""
        import Foundation
        protocol Runner {}
        extension Runner {
            func run() { print("pure") }                 // unrelated sibling overload — the trigger
            func run(times: Int) {
                for _ in 0..<times {
                    let p = Process()
                    p.launchPath = "/bin/echo"
                    try? p.run()
                }
            }
        }
        struct S: Runner {}
        func useS() {
            let s = S()
            s.run(times: 3)
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "useS"), ["Exec"],
                       "an overloaded extension-provided member must resolve through a CONCRETE "
                       + "receiver exactly as through a protocol-typed one — the edge must never vanish "
                       + "for being overloaded: \(by)")
    }

    // OVER-CHARGE CONTROL for the fix above: a genuine LOCAL override on the concrete conformer must
    // still win over BOTH provided overloads (the ordinary `resolveQual(call.path)` / `overloadedBases`
    // check earlier in the `call.typed` arm is untouched by this fix and must still fire first).
    func testLocalOverrideStillWinsOverBothProvidedOverloadsOnAConcreteReceiver() throws {
        let by = try scan("""
        import Foundation
        protocol Runner {}
        extension Runner {
            func run() { print("pure") }
            func run(times: Int) {
                let p = Process()
                p.launchPath = "/bin/echo"
                try? p.run()
            }
        }
        struct S: Runner {
            func run(times: Int) { print("pure override") }   // must win — no Exec
        }
        func useS() {
            let s = S()
            s.run(times: 3)
        }
        """)
        XCTAssertNil(by["useS"],
                     "a genuine local override must win over the provided default — useS must stay "
                     + "pure: \(by)")
    }

    // OVER-CHARGE CONTROL: a genuinely AMBIGUOUS call (argument count/type cannot discriminate) must
    // get the SOUND UNION, never a guess and never a drop — mirroring `matchOverloads`'s own fallback.
    func testGenuinelyAmbiguousOverloadOnAConcreteReceiverUnionsRatherThanGuesses() throws {
        let by = try scan("""
        import Foundation
        protocol Runner {}
        extension Runner {
            func run(_ x: Int) { print("pure", x) }              // same arity, can't discriminate
            func run(y: Int) {
                let p = Process()
                p.launchPath = "/bin/echo"
                try? p.run()
            }
        }
        struct S: Runner {}
        func useS(_ n: Int) {
            let s = S()
            s.run(y: n)
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "useS"), ["Exec"],
                       "the call's own label (`y:`) is real Swift disambiguation this engine doesn't "
                       + "model — the sound union must include the Exec-performing sibling rather than "
                       + "dropping it: \(by)")
    }

    // A BASE-CLASS receiver dispatches over subclass OVERRIDES. The hierarchy is recorded (`conformers`
    // holds class inheritance beside protocol conformance, and the `.hierarchy.json` sidecar publishes
    // it) but the typed-call site never consulted it, so `a.run()` on an `ABase`-typed receiver charged
    // only `ABase.run` and an effectful `override func run()` read silent-pure. No protocol and no
    // extension needed — and AGENTS.md states the bounded-CHA contract for PROTOCOLS only, which is what
    // made the class half easy to miss. The imported-owner arm already did exactly this query for a base
    // declared in a DEPENDENCY; this is the same question for a base declared here.
    func testBaseClassReceiverUnionsSubclassOverrides() throws {
        let by = try scan("""
        import Foundation
        func shell(_ c: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: c); try? p.run() }
        class ABase { func run() {} }
        final class AImpl: ABase { override func run() { shell("/bin/ls") } }    // Exec
        final class APure: ABase { override func run() {} }
        func viaBase(_ a: ABase) { a.run() }
        // OVER-CHARGE CONTROL — a SIBLING's effect must not attach to another leaf's static type,
        // and a type with no subtypes at all must gain nothing.
        func viaPureLeaf(_ a: APure) { a.run() }
        final class Solo { func tick() {} }
        func viaSolo(_ s: Solo) { s.tick() }
        // OVER-CHARGE CONTROL — a RAW-VALUE enum records `String` as a supertype; a String-typed
        // receiver must never dispatch into it.
        enum Suit: String { case hearts; func uppercased() { shell("/bin/echo") } }
        func viaString(_ s: String) -> String { s.uppercased() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "viaBase"), ["Exec"],
                       "a base-class-typed receiver must union the subclass overrides — the override is "
                       + "what runs, and the hierarchy that names it is already recorded")
        XCTAssertNil(by["viaPureLeaf"],
                     "a sibling subclass's effect must not attach to another leaf's static type")
        XCTAssertNil(by["viaSolo"], "a type with no subtypes must gain nothing")
        XCTAssertNil(by["viaString"],
                     "a raw-value enum must not make a String-typed receiver dispatch into it")
    }
}
