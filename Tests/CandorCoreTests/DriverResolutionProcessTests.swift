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
    func testFnTypedParamResolvesNamedLocalAcrossCallSites() throws {
        let by = try scan("""
        import Foundation
        func runner(_ job: () -> Void) { job() }
        func namedJob() { _ = FileManager.default.contents(atPath: "/y") }
        func passesNamed() { runner(namedJob) }
        """)
        // every visible call site passes a NAMED local fn → the deferral resolves: edge, no Unknown
        XCTAssertEqual(ProcessHarness.inferred(by, "runner"), ["Fs"],
                       "all-named call sites must resolve the callback (edge to namedJob, Unknown dropped)")
        XCTAssertEqual(ProcessHarness.inferred(by, "passesNamed"), ["Fs"])
    }

    func testClosureLiteralArgStaysOpaque() throws {
        let by = try scan("""
        import Foundation
        func runner(_ job: () -> Void) { job() }
        func passesClosure() { runner { _ = FileManager.default.contents(atPath: "/z") } }
        """)
        // a CLOSURE arg stays opaque for the deferral: the receiver's §4 Unknown stands even though
        // the closure body is charged to the passer lexically.
        let inf = ProcessHarness.inferred(by, "runner")
        XCTAssertEqual(inf, ["Unknown"], "a closure-literal call site must keep the receiver Unknown, got \(inf ?? [])")
        XCTAssertEqual(by["runner"]?["unknownWhy"] as? [String], ["callback:job"],
                       "the Unknown names the invoked fn-typed param")
        // the passer carries the closure body's Fs (lexical charge) AND inherits the callee's Unknown.
        XCTAssertEqual(ProcessHarness.inferred(by, "passesClosure"), ["Fs", "Unknown"],
                       "the closure body charges the passer; the receiver's Unknown propagates back")
    }

    // a fn-typed param with NO visible call site keeps the §4 Unknown (nothing to resolve against).
    func testFnTypedParamWithNoCallSiteKeepsUnknown() throws {
        let by = try scan("""
        public func runner(_ job: () -> Void) { job() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "runner"), ["Unknown"],
                       "no visible call site — the fn-typed invocation must stay Unknown")
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
}
