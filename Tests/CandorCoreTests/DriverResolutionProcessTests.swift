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
}
