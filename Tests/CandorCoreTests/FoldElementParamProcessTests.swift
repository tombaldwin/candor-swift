import XCTest
import Foundation

/// SOUNDNESS R349 (swift half) — **A CORRECT EXCLUSION FOR PARAMETER 0 READ AS A DECISION ABOUT THE
/// METHOD, AND `reduce` WAS NEVER TYPED AT ALL.**
///
/// `ELEMENT_PAIR_ITERATORS`' comment said *"reduce is deliberately ABSENT: its closure is
/// `(Acc, Element)` — the first param is the accumulator, so element-typing it would mistype the fold
/// state."* Every word true, and it settled parameter 0 so completely that **parameter 1 — which IS the
/// element — was never typed by anything.** MEASURED at 0.38.2 over a `[Guard]` whose `run()` writes a
/// file, with `v.forEach { _ = $0.run() }` charging `Fs` as the held-constant control: all three
/// spellings of `reduce` ABSENT, which under SPEC ⟨0.21⟩ is an affirmative purity claim over a file
/// write. `reduce` is one of the commonest HOFs in Swift.
///
/// Three more fell out of the same sweep, and one of them is the discriminator that proves the axis:
/// `v.enumerated().forEach { _ = $0.1.run() }` ABSENT and `zip(v, w)` ABSENT, **while
/// `for (_, g) in v.enumerated()` CHARGES** — so `enumerated` itself is understood, and what was not is
/// the TUPLE-yielding adapter reaching a CLOSURE parameter rather than a `for` binder.
///
/// **THE OVER-CHARGE CONTROLS ARE WRITTEN FIRST AND THEY DISCRIMINATE**, which the row's own repro
/// could not: with everything absent before the fix, a pure-element control proved nothing. Each control
/// here fails if the fix reaches ONE slot too far — the accumulator, zip's other side, or the offset.
///
/// CORPUS (15 real Swift packages, 3,575 `.swift` files, `bin/corpus-ab.py`, one variable — the engine
/// binary): **ADDED 3 / REMOVED 1 / CHANGED 2 over 12,989→12,991 rows, with REACH 25 hits across 10 of
/// the 15 entries** — measured, not inferred, because an empty diff is indistinguishable from a change
/// nothing reached. All three ADDED rows are purity claims WITHDRAWN at a real `reduce`: swift-log's
/// `MetadataProvider.multiplex` (`provider.get()` invokes a user-supplied closure), swift-collections'
/// `Sequence._sum`, Kingfisher's `setProcessors`. The single REMOVED row is RxSwift's
/// `countTotalItemsInSections`, whose `Unknown` came from a fabricated `Bag.count` edge and a
/// `dispatch:IdentifiableType.+` hedge over an operator that **does not exist anywhere in that tree**;
/// its caller's disclosure is unchanged in both arms.
final class FoldElementParamProcessTests: XCTestCase {

    private func scan(_ body: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32, out: String) {
        let src = """
        import Foundation
        struct Guard { func run() -> Int { try? "x".write(toFile: "/tmp/g.txt", atomically: true, encoding: .utf8); return 1 } }
        struct Calm { func run() -> Int { return 1 } }
        struct Tally { func run() -> Tally { return self } }
        \(body)
        """
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--json"]
        if let policy {
            let p = root.appendingPathComponent("p.pol")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        return (try ProcessHarness.fns(ofJson: r.out), r.code, r.out + r.err)
    }

    /// THE ROW'S MEASUREMENT, with its control in the same scan so the comparison holds everything but
    /// the HOF constant. All five spellings of the fold reach the same file write.
    func testR349ReduceTypesItsElementParameter() throws {
        let r = try scan("""
        public func ctl_forEach(_ v: [Guard]) { v.forEach { _ = $0.run() } }
        public func f1_named(_ v: [Guard]) -> Int { v.reduce(0) { a, x in a + x.run() } }
        public func f2_shorthand(_ v: [Guard]) -> Int { v.reduce(0) { $0 + $1.run() } }
        public func f3_into(_ v: [Guard]) { v.reduce(into: 0) { a, x in a += x.run() } }
        public func f4_intoShorthand(_ v: [Guard]) { v.reduce(into: 0) { $0 += $1.run() } }
        """, name: "R349Reduce")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "ctl_forEach"), ["Fs"],
                       "the CONTROL must charge, or nothing below is a comparison: \(r.out)")
        for fn in ["f1_named", "f2_shorthand", "f3_into", "f4_intoShorthand"] {
            XCTAssertTrue((ProcessHarness.inferred(r.fns, fn) ?? []).contains("Fs"),
                          "R349: \(fn) folds over a Guard that writes a file — absence here is a "
                          + "purity claim under ⟨0.21⟩: \(r.out)")
        }
    }

    /// **THE SHORTHAND SPELLING IS THE ONE THAT PROVES THE INDEX, and it is why this fix is not "type
    /// the LAST parameter" as the row prescribed.** `closureParamNames` cannot see the arity of
    /// `{ $0 + $1.run() }` — it returns `$0`/`$1`/`$2` — so "last" is `$2`, a name the closure does not
    /// bind, and the commonest spelling of `reduce` would have stayed silent while the named one closed.
    /// Asserted as its own case rather than folded into the loop above, because a fix that got this
    /// wrong would still pass every OTHER assertion in this file.
    func testR349ShorthandFoldIsNotTypedByArityGuessing() throws {
        let r = try scan("""
        public func short(_ v: [Guard]) -> Int { v.reduce(0) { $0 + $1.run() } }
        """, name: "R349Short")
        XCTAssertTrue((ProcessHarness.inferred(r.fns, "short") ?? []).contains("Fs"), r.out)
    }

    /// THE TUPLE-ADAPTER HALF, with the discriminator the row identified: the `for` binder over
    /// `enumerated()` already charged, so the axis is the tuple reaching a CLOSURE parameter.
    func testR349TupleAdaptersReachingAClosureParameter() throws {
        let r = try scan("""
        public func ctl_forBinder(_ v: [Guard]) { for (_, g) in v.enumerated() { _ = g.run() } }
        public func t1_enumShorthand(_ v: [Guard]) { v.enumerated().forEach { _ = $0.1.run() } }
        public func t2_enumNamed(_ v: [Guard]) { v.enumerated().forEach { p in _ = p.1.run() } }
        public func t3_enumMap(_ v: [Guard]) { _ = v.enumerated().map { $0.1.run() } }
        public func t4_zipClosure(_ v: [Guard]) { zip(v, [1]).forEach { _ = $0.0.run() } }
        public func t5_zipForBinder(_ v: [Guard]) { for (g, _) in zip(v, [1]) { _ = g.run() } }
        """, name: "R349Tuple")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "ctl_forBinder"), ["Fs"],
                       "the CONTROL must charge — it is what makes this an axis and not a name: \(r.out)")
        for fn in ["t1_enumShorthand", "t2_enumNamed", "t3_enumMap", "t4_zipClosure", "t5_zipForBinder"] {
            XCTAssertTrue((ProcessHarness.inferred(r.fns, fn) ?? []).contains("Fs"),
                          "R349: \(fn) reaches the element through a tuple slot: \(r.out)")
        }
    }

    /// **THE OVER-CHARGE CONTROLS. Every one of these FAILS if the fix reaches one slot too far**, and
    /// each names the slot:
    ///   * `c1` — reduce's parameter 0 is the ACCUMULATOR. Typed from the element, `a.run()` would
    ///     resolve to `Guard.run` and charge `Fs`; the correct resolution is `Tally.run`, pure. This is
    ///     the exact mistype the comment that caused R349 was right to refuse, so the fix must keep
    ///     refusing it. `reduce(into:)`'s accumulator is additionally `inout`.
    ///   * `c2`/`c3` — zip's two sides have DIFFERENT element types, so a union rather than a slot map
    ///     would charge the pure side.
    ///   * `c4` — `enumerated()`'s slot 0 is the Int OFFSET, not the element.
    ///   * `c5` — a pure element through every fold spelling stays absent (the plain fabrication check).
    /// `p1`/`p2` are the POSITIVE twins of `c2`/`c3`: same call, other slot, so the controls cannot be
    /// passing because the whole construct went silent again.
    func testR349OverChargeControlsEachNameTheSlotTheyGuard() throws {
        let r = try scan("""
        public func c1_accIsNotElement(_ v: [Guard]) -> Tally { v.reduce(Tally()) { a, _ in a.run() } }
        public func c2_zipSlot0Pure(_ g: [Guard], _ c: [Calm]) { zip(c, g).forEach { _ = $0.0.run() } }
        public func p1_zipSlot1(_ g: [Guard], _ c: [Calm]) { zip(c, g).forEach { _ = $0.1.run() } }
        public func c3_zipBinderSlot0(_ g: [Guard], _ c: [Calm]) { for (x, _) in zip(c, g) { _ = x.run() } }
        public func p2_zipBinderSlot1(_ g: [Guard], _ c: [Calm]) { for (_, y) in zip(c, g) { _ = y.run() } }
        public func c4_enumSlot0(_ v: [Guard]) { v.enumerated().forEach { _ = $0.0.run() } }
        public func c5_pureElement(_ v: [Calm]) -> Int { v.reduce(0) { $0 + $1.run() } }
        """, name: "R349Ctl")
        for fn in ["c1_accIsNotElement", "c2_zipSlot0Pure", "c3_zipBinderSlot0", "c4_enumSlot0", "c5_pureElement"] {
            XCTAssertFalse((ProcessHarness.inferred(r.fns, fn) ?? []).contains("Fs"),
                           "R349 over-charge: \(fn) reaches no file write — charging it means the fix "
                           + "typed a slot that is not the element: \(r.out)")
        }
        for fn in ["p1_zipSlot1", "p2_zipBinderSlot1"] {
            XCTAssertTrue((ProcessHarness.inferred(r.fns, fn) ?? []).contains("Fs"),
                          "\(fn) is the POSITIVE twin of its control — without it the controls above "
                          + "would pass on a fix that had gone silent again: \(r.out)")
        }
    }

    /// A CLOSURE'S TUPLE BINDING MUST NOT OUTLIVE THE CLOSURE. `tupleElem` is function-wide state, and
    /// this file's own history (R124, R351) is that a binding written for a closure parameter and not
    /// given back either fabricates on a later same-named receiver or destroys its type. Here the
    /// enclosing parameter `g` is the EFFECTFUL one and the closure shadows its name: if the closure's
    /// clear were not restored, `g.run()` after the loop would resolve against nothing and the function
    /// would lose a real `Fs` — the silent direction.
    func testR349AClosureTupleBindingIsGivenBack() throws {
        let r = try scan("""
        public func leak(_ v: [Calm], _ g: Guard) {
            v.enumerated().forEach { g in _ = g.1.run() }
            _ = g.run()
        }
        """, name: "R349Leak")
        XCTAssertTrue((ProcessHarness.inferred(r.fns, "leak") ?? []).contains("Fs"),
                      "the enclosing `g: Guard` must survive a closure that shadowed its name: \(r.out)")
    }

    /// SHADOW DISCIPLINE. A project that declares its own `zip` gets ITS `zip`, and typing slots from
    /// that one's arguments would FABRICATE — this file's `zipElementSlots` refuses there, and this is
    /// the assertion that the refusal is reached rather than merely written.
    func testR349ALocalZipIsNotTheStdlibZip() throws {
        let r = try scan("""
        func zip(_ a: [Guard], _ b: [Int]) -> [Calm] { return [] }
        public func local(_ v: [Guard]) { zip(v, [1]).forEach { _ = $0.0.run() } }
        """, name: "R349Shadow")
        XCTAssertFalse((ProcessHarness.inferred(r.fns, "local") ?? []).contains("Fs"),
                       "a locally declared `zip` shadows the stdlib one; its result is [Calm] and the "
                       + "tuple slots do not apply: \(r.out)")
    }
}
