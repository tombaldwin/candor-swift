import XCTest
import Foundation

/// **SOUNDNESS R537 — AN ELEMENT ACCESSOR WAS NOT A TYPED RECEIVER, so `hs.first?.emitN()` over a
/// `[PN]` of protocol existentials read SILENT-PURE while `hs[0].emitN()`, `for g in hs`, `d["k"]?` and
/// `hs.map { … }` all charged.**
///
/// `ELEMENT_ACCESSORS` has NAMED `first`/`last`/`popLast`/`removeFirst`/`randomElement`/… since R192, and
/// `rootOf`'s subscript arm has typed `cs[0]` since long before that. The two were never the same
/// question: R192 wired the set to `callableValue` ("is this expression a closure?") and nothing wired
/// it to the resolver ("what TYPE is this receiver?"). Two implementations of one fact, only the one in
/// front of the last author wired — §F1.3, and the family's most-repeated shape.
///
/// MEASURED at v0.39.0 on a 38-arm fixture in which **every arm compiles and really deletes its own probe
/// file** (§E3: an absence assertion over a program that cannot run is asserting something about
/// nothing). 30 arms were ABSENT — no row, no `Unknown` — against 4 charged controls in the same scan.
///
/// THE FIX'S OWN FAILURE DIRECTION, and it fired. Typing a receiver that was previously untyped makes
/// `matchOverloads` see a CONCRETE argument type where it saw none, and that filter excluded every
/// overload whose parameter type is a TYPE PARAMETER (`Self`, `Element`, a bare generic) because no
/// `subtypesOf` entry can exist for a name that is not a type. The candidate set went to ZERO, the edge
/// was dropped, and `ovlSelfFromFirst` below went from `Fs` to ABSENT — a silent under-report
/// INTRODUCED by this fix. Closed in `Driver.narrowByArgTypes`: the type filter may narrow the
/// candidate set, never empty it. The subscript spelling of that same shape (`ovlSelfFromSub`) was
/// already silent at v0.39.0 and this closes it too.
final class ElementAccessorReceiverProcessTests: XCTestCase {

    /// The protocol lives in its OWN FILE, so no same-file shortcut can explain a charge.
    private static let protoFile = """
    import Foundation

    public protocol PN { func emitN() }

    public struct Sink: PN, Hashable {
        public let id: Int
        public init(id: Int = 0) { self.id = id }
        public func emitN() { try? FileManager.default.removeItem(atPath: "/tmp/r537-\\(id)") }
    }

    public protocol Quiet { func hush() }
    public struct Q: Quiet, Hashable { public init() {}; public func hush() {} }
    """

    private func scan(_ use: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makeFilesPackage(["proto.swift": Self.protoFile, "use.swift": use])
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        _ = try ProcessHarness.run(bin, [root.path, "--out", out.path])
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.App.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return by
    }

    private func charges(_ by: [String: [String: Any]], _ fn: String) -> Bool {
        ((by[fn]?["inferred"] as? [String]) ?? []).contains("Fs")
    }

    // ── 1. EVERY ELEMENT-ACCESSOR SPELLING, against the four controls in the SAME scan ───────────
    //
    // The controls are the discriminator: they charged at v0.39.0 and must keep charging, so a change
    // that made everything charge (or nothing) cannot pass this. Each arm is one of the 38 that were
    // compiled and EXECUTED in the R537 fixture.
    func testEveryElementAccessorTypesItsReceiver() throws {
        let by = try scan("""
        import Foundation

        // CONTROLS — charged at v0.39.0, before this fix existed.
        func ctlSubscript(_ hs: [PN]) { hs[0].emitN() }
        func ctlForIn(_ hs: [PN]) { for g in hs { g.emitN() } }
        func ctlDictSub(_ d: [String: PN]) { d["k"]?.emitN() }
        func ctlMap(_ hs: [PN]) { _ = hs.map { $0.emitN() } }

        // THE PROPERTY SPELLINGS
        func accFirst(_ hs: [PN]) { hs.first?.emitN() }
        func accLast(_ hs: [PN]) { hs.last?.emitN() }
        func accBang(_ hs: [PN]) { hs.first!.emitN() }
        func accDictValues(_ d: [String: PN]) { d.values.first?.emitN() }
        func accField(_ b: Box) { b.items.first?.emitN() }
        func accSet(_ s: Set<Sink>) { s.first?.emitN() }

        // THE CALL SPELLINGS
        func accPopLast(_ v: inout [PN]) { v.popLast()?.emitN() }
        func accRemoveFirst(_ v: inout [PN]) { v.removeFirst().emitN() }
        func accRemoveLast(_ v: inout [PN]) { v.removeLast().emitN() }
        func accRandom(_ hs: [PN]) { hs.randomElement()?.emitN() }
        func accFirstWhere(_ hs: [PN]) { hs.first(where: { _ in true })?.emitN() }
        func accLastWhere(_ hs: [PN]) { hs.last(where: { _ in true })?.emitN() }
        func accMinBy(_ hs: [PN]) { hs.min(by: { _, _ in true })?.emitN() }
        func accMaxBy(_ hs: [PN]) { hs.max(by: { _, _ in true })?.emitN() }
        func accDictPopFirst(_ d: inout [String: PN]) { d.popFirst()?.value.emitN() }
        func accDictFirstValue(_ d: [String: PN]) { d.first?.value.emitN() }
        func accDictValuesRandom(_ d: [String: PN]) { d.values.randomElement()?.emitN() }

        // THROUGH A BINDER — `rootOf`'s answer is what these read.
        func accIfLet(_ hs: [PN]) { if let g = hs.first { g.emitN() } }
        func accGuardLet(_ hs: [PN]) { guard let g = hs.first else { return }; g.emitN() }

        // THROUGH Optional.map — the CLOSURE-PARAMETER consumer of the same fact.
        func accOptionalMap(_ hs: [PN]) { _ = hs.first.map { $0.emitN() } }

        // OVER AN ELEMENT-PRESERVING TRANSFORM, then an accessor.
        func accDropFirst(_ hs: [PN]) { hs.dropFirst().first?.emitN() }
        func accDropLast(_ hs: [PN]) { hs.dropLast().last?.emitN() }
        func accSorted(_ hs: [PN]) { hs.sorted(by: { _, _ in true }).first?.emitN() }
        func accReversed(_ hs: [PN]) { hs.reversed().first?.emitN() }
        func accPrefix(_ hs: [PN]) { hs.prefix(2).first?.emitN() }
        func accSuffix(_ hs: [PN]) { hs.suffix(2).last?.emitN() }
        func accFilter(_ hs: [PN]) { hs.filter { _ in true }.first?.emitN() }
        func accShuffled(_ hs: [PN]) { hs.shuffled().first?.emitN() }
        func accLazy(_ hs: [PN]) { hs.lazy.first?.emitN() }

        // A CONTAINER OF CONTAINERS, reached by an accessor rather than a loop.
        func accNested(_ n: [[PN]]) { n.first?.first?.emitN() }

        struct Box { var items: [PN] }
        """)
        for ctl in ["ctlSubscript", "ctlForIn", "ctlDictSub", "ctlMap"] {
            XCTAssertTrue(charges(by, ctl), "CONTROL \(ctl) must charge Fs — it did at v0.39.0")
        }
        let arms = ["accFirst", "accLast", "accBang", "accDictValues", "accField", "accSet",
                    "accPopLast", "accRemoveFirst", "accRemoveLast", "accRandom", "accFirstWhere",
                    "accLastWhere", "accMinBy", "accMaxBy", "accDictPopFirst", "accDictFirstValue",
                    "accDictValuesRandom", "accIfLet", "accGuardLet", "accOptionalMap",
                    "accDropFirst", "accDropLast", "accSorted", "accReversed", "accPrefix",
                    "accSuffix", "accFilter", "accShuffled", "accLazy", "accNested"]
        for a in arms {
            XCTAssertTrue(charges(by, a), "R537: \(a) must charge Fs — ABSENT is the purity claim this row is about")
        }
    }

    // ── 2. THE SIBLINGS OF THE TWO ALLOWLISTS ────────────────────────────────────────────────────
    //
    // The allowlist-chain rule: when one name on a list is wrong, the WHOLE family goes into one
    // fixture. `drop(while:)` is the element-preserving adapter that list never named — silent even in
    // the `for`-in form, with `dropFirst` one character away charging. The container CONVERSIONS
    // (`Array(…)`) and `joined()` are the same question one spelling out.
    func testElementPreservingSiblingsCarryTheElementToo() throws {
        let by = try scan("""
        import Foundation
        func sibReversedFor(_ hs: [PN]) { for g in hs.reversed() { g.emitN() } }
        func sibDropWhileFor(_ hs: [PN]) { for g in hs.drop(while: { _ in false }) { g.emitN() } }
        func sibDropWhileFirst(_ hs: [PN]) { hs.drop(while: { _ in false }).first?.emitN() }
        func sibArrayCtorFor(_ hs: [PN]) { for g in Array(hs) { g.emitN() } }
        func sibArrayCtorFirst(_ hs: [PN]) { Array(hs).first?.emitN() }
        func sibDictValuesArrayFirst(_ d: [String: PN]) { Array(d.values).first?.emitN() }
        func sibJoinedFor(_ n: [[PN]]) { for g in n.joined() { g.emitN() } }
        """)
        // `reversed` was already on the list — the control that says the list itself still works.
        XCTAssertTrue(charges(by, "sibReversedFor"), "CONTROL: `reversed()` charged at v0.39.0")
        for a in ["sibDropWhileFor", "sibDropWhileFirst", "sibArrayCtorFor", "sibArrayCtorFirst",
                  "sibDictValuesArrayFirst", "sibJoinedFor"] {
            XCTAssertTrue(charges(by, a), "R537 sibling: \(a) must charge Fs")
        }
    }

    // ── 3. THE OVER-CHARGE CONTROL — the direction this fix did NOT intend ───────────────────────
    //
    // Widening a receiver's typing is how an effect gets FABRICATED. Every spelling above, over a
    // container whose element does NOTHING, must charge nothing. ⟨0.39⟩ emits a row for a function that
    // DISPATCHES even when it is otherwise pure, so this asserts "no effect, no hedge, no blind spot"
    // rather than absence.
    func testPureElementsAreNotCharged() throws {
        let by = try scan("""
        import Foundation
        func ovrFirst(_ qs: [Quiet]) { qs.first?.hush() }
        func ovrPopLast(_ v: inout [Quiet]) { v.popLast()?.hush() }
        func ovrRandom(_ qs: [Quiet]) { qs.randomElement()?.hush() }
        func ovrDropWhile(_ qs: [Quiet]) { for q in qs.drop(while: { _ in false }) { q.hush() } }
        func ovrArrayCtor(_ qs: [Quiet]) { Array(qs).first?.hush() }
        func ovrSet(_ s: Set<Q>) { s.first?.hush() }
        // The COUNT-taking overloads return Void. Nothing can be called on them, so no compiling
        // program can read a type wrongly recorded here — these record the absence, they do not pin
        // the arity guard, and `accessorArityYieldsElement` says so in its own doc comment.
        func ovrRemoveFirstCount(_ v: inout [PN]) { v.removeFirst(2) }
        func ovrRemoveLastCount(_ v: inout [PN]) { v.removeLast(2) }
        """)
        for a in ["ovrFirst", "ovrPopLast", "ovrRandom", "ovrDropWhile", "ovrArrayCtor", "ovrSet",
                  "ovrRemoveFirstCount", "ovrRemoveLastCount"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, a),
                         "R537 over-charge: \(a) touches nothing effectful and must carry no effect/hedge")
        }
    }

    // ── 4. WHAT THIS ROW DELIBERATELY DOES NOT CLOSE ─────────────────────────────────────────────
    //
    // Pinned as known-silent so closing either later has a control, and so neither is mistaken for
    // coverage. `compactMap`/`map` are not element-PRESERVING — typing through them would be a guess
    // about a closure's return, which is the rule this resolver is built on. `.keys` needs a KEY-type
    // index; the collector records only the VALUE (`dictElem`), so there is nothing to answer from.
    func testKnownSilentTransformAndKeyPaths() throws {
        let by = try scan("""
        import Foundation
        func silCompactMapFirst(_ hs: [PN?]) { hs.compactMap { $0 }.first?.emitN() }
        func silDictKeysFirst(_ d: [Sink: Int]) { d.keys.first?.emitN() }
        func ctlForIn(_ hs: [PN]) { for g in hs { g.emitN() } }
        """)
        XCTAssertTrue(charges(by, "ctlForIn"), "CONTROL: the scan is working at all")
        XCTAssertFalse(charges(by, "silCompactMapFirst"),
                       "still silent BY DESIGN — a transform's element is a guess. If this starts charging, "
                       + "the boundary moved and the row's stated scope is stale, not wrong.")
        XCTAssertFalse(charges(by, "silDictKeysFirst"),
                       "still silent — no key-type index exists. Same note as above.")
    }

    // ── 5. THE FIX'S OWN FAILURE DIRECTION: the overload filter must never empty the set ─────────
    //
    // `Bag.add(_ other: Self)` is the swift-collections `Rope.prepend(_ other: Self)` shape, and
    // `EventLoopPromise.succeed() { succeed(Void()) }` in swift-nio is the same defect over a generic
    // `Value` — measured, that public API read PURE at v0.39.0 and charges `Env`/`Unknown` after this.
    //
    // `ovlSelfFromFirst` is the arm R537's first cut BROKE (Fs -> ABSENT). `ovlSelfFromSub` reaches it
    // through the SUBSCRIPT, which this fix does not touch: it was already silent at v0.39.0, which is
    // why the fixture carries both — §A.2, write the fixture for the sibling you were not handed.
    func testOverloadTypeFilterNeverEmptiesTheCandidateSet() throws {
        let by = try scan("""
        import Foundation
        struct Bag {
            mutating func add(_ other: Self) { try? FileManager.default.removeItem(atPath: "/tmp/r537-self") }
            mutating func add(_ n: Int) { _ = n }
        }
        struct Box<T> {
            func take(_ v: T) {}
            func take(_ b: Bag) { try? FileManager.default.removeItem(atPath: "/tmp/r537-generic") }
        }
        func ovlSelfFromFirst(_ bags: [Bag]) { var b = Bag(); if let t = bags.first { b.add(t) } }
        func ovlSelfFromSub(_ bags: [Bag])   { var b = Bag(); b.add(bags[0]) }
        func ovlSelfUntyped(_ bags: [Bag], _ t: Bag) { var b = Bag(); b.add(t) }
        func ovlConcreteStillNarrows(_ bx: Box<Int>, _ bags: [Bag]) { if let t = bags.first { bx.take(t) } }
        """)
        for a in ["ovlSelfFromFirst", "ovlSelfFromSub", "ovlSelfUntyped"] {
            XCTAssertTrue(charges(by, a),
                          "R537: \(a) reaches `add(_: Self)`; an emptied overload set is a silent under-report")
        }
        // The precision the filter DOES buy is untouched: a concrete match still wins, so `take(T)` is
        // still excluded and only `take(Bag)` is edged. Asserted through the effect so it cannot be
        // read as "everything unions now".
        XCTAssertTrue(charges(by, "ovlConcreteStillNarrows"))
        let calls = (by["ovlConcreteStillNarrows"]?["calls"] as? [String]) ?? []
        XCTAssertFalse(calls.contains("Box.take(T)"),
                       "the never-zero rule must not widen a set that already had a hit: \(calls)")
    }
}
