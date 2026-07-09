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
}
