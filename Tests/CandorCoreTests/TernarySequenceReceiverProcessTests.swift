import XCTest
import Foundation

/// **SOUNDNESS R589 — A TERNARY-VALUED RECEIVER IS SILENTLY PURE, AND THE ROW'S STATED DISCRIMINATOR
/// ("the two arms resolve to different things") IS NOT THE MECHANISM.**
///
/// `rootOf`'s ternary arm reads an UNFOLDED SwiftParser `SequenceExpr` and required `elems.count == 3`.
/// SwiftParser does not nest a ternary's condition or its else-arm — every operator in the whole
/// expression is flattened into ONE element list — so `x > 1 ? A() : A()` arrives as FIVE elements
/// (`x`, `>`, `1`, UnresolvedTernary, `A()`) and the arm was never entered. `rootOf` then returned no
/// root at all and the receiver's member call was dropped ENTIRELY: no edge, no `Unknown`, no row.
///
/// THE ONE-CHARACTER CONTROL THAT SETTLES IT, both arms with the SAME two branches and the same sink:
///
///     (x > 1 ? CT() : CT()).emitT()      ABSENT   — `pure`/`deny Net` exit 0
///     ((x > 1) ? CT() : CT()).emitT()    ['Net']  — `deny Net` exit 1
///
/// Parenthesising the condition removes it from the ternary's own sequence and the count falls back to
/// 3. Nothing about the two branches changed, so "the arms resolve differently" cannot be the cause —
/// the SHAPE OF THE ENCLOSING SEQUENCE is. The row's own two repro arms are both of this kind
/// (`c ? CT() as PT : DT() as PT` flattens the else-arm's `as`; `h != nil ? h! : CT()` flattens the
/// condition's `!=`), which is why its "controls" — all three-element ternaries — could not separate
/// the two hypotheses.
///
/// WHAT THIS FIX DOES AND DOES NOT CLOSE. It locates the `UnresolvedTernaryExpr` at ANY index, treats
/// everything before it as the condition (irrelevant to the value's type) and everything after it as
/// the ELSE sub-expression, and then applies the arm's existing agreement test unchanged: both arms
/// must resolve, `isVar`, and to the SAME root. So the second, independent cause — a three-element
/// ternary whose arms resolve to DIFFERENT roots (`c ? CT() : DT()`) — is still silent, deliberately:
/// that one is a control-flow MERGE and needs a union or a hedge, which is a separate decision with a
/// separate over-charge control. `differingRootsStaysSilent` asserts it AS IT IS so this file cannot
/// read as covering it.
///
/// `mono` still composes by CONJUNCTION and `opaqueHop` by DISJUNCTION, for the reasons `rootOf`'s own
/// comment gives; `monoBothErasedControl` is the regression pin that a wider arm does not re-open the
/// fabrication those two joins exist to prevent.
final class TernarySequenceReceiverProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], why: [String: [String]], code: Int32, out: String) {
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
        var by: [String: [String]] = [:], why: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
            why[n] = ((f["unknownWhy"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, why, r.code, r.out + r.err)
    }

    /// TWO conformers with DIFFERENT effects so a one-arm answer is distinguishable from a union, and
    /// `emitT` on the protocol so the bounded-conformer CHA has something to reach.
    static let head = """
    import Foundation
    protocol PT { func emitT() }
    final class CT: PT {
        func emitT() { _ = URLSession.shared.dataTask(with: URL(string: "https://a.example")!) }
    }
    final class DT: PT {
        func emitT() { _ = ProcessInfo.processInfo.environment["Y"] }
    }

    """

    // ── 1. THE COUNT, ISOLATED BY ONE CHARACTER ───────────────────────────────────────────────────
    // Both arms hold the SAME two branches (`CT()` twice) and the same condition; the only difference
    // is whether the condition is parenthesised out of the ternary's own unfolded sequence. This is
    // the discriminator the row did not have, and it is what names the mechanism.
    func testAParenthesisedConditionIsNotWhatDecidesTheAnswer() throws {
        let src = Self.head + """
        public func bareCond(_ x: Int)  { (x > 1 ? CT() : CT()).emitT() }
        public func parenCond(_ x: Int) { ((x > 1) ? CT() : CT()).emitT() }
        """
        let r = try scan(src, name: "Count")
        XCTAssertEqual(r.fns["parenCond"], ["Net"],
                       "THE CONTROL — a three-element ternary has always resolved; got "
                       + "\(r.fns["parenCond"].map(String.init(describing:)) ?? "ABSENT")")
        XCTAssertEqual(r.fns["bareCond"], ["Net"],
                       "R589: an operator in the CONDITION flattens into the ternary's own sequence and "
                       + "the receiver was dropped entirely — no edge and no Unknown; got "
                       + "\(r.fns["bareCond"].map(String.init(describing:)) ?? "ABSENT from functions[]")")
    }

    // ── 2. EVERY PLACE AN OPERATOR CAN SIT IN THE SAME SEQUENCE ───────────────────────────────────
    // Condition, then-arm and else-arm each in turn, plus the row's own two named repro spellings. All
    // five resolve to ONE root, so the arm's agreement test licenses them; the enclosing sequence is
    // the only thing that varies.
    func testAnOperatorAnywhereInTheSequenceStillResolves() throws {
        let src = Self.head + """
        public func opInCondition(_ x: Int)  { (x > 1 ? CT() : CT()).emitT() }
        public func opInElseArm(_ c: Bool, _ h: CT?) { (c ? CT() : h ?? CT()).emitT() }
        public func castsOnBothArms(_ c: Bool) { (c ? CT() as PT : CT() as PT).emitT() }
        public func rowArmOne(_ c: Bool) { (c ? CT() as PT : DT() as PT).emitT() }
        public func plainControl(_ c: Bool) { (c ? CT() : CT()).emitT() }
        """
        let r = try scan(src, name: "Spellings")
        XCTAssertEqual(r.fns["plainControl"], ["Net"], "THE CONTROL must keep resolving")
        XCTAssertEqual(r.fns["opInCondition"], ["Net"],
                       "got \(r.fns["opInCondition"].map(String.init(describing:)) ?? "ABSENT")")
        // Both arms cast to `PT`, so the root is the PROTOCOL and the bounded CHA unions BOTH conformers
        // — `Net` from `CT` and `Env` from `DT`. Written as the union rather than as `["Net"]`: the
        // first draft of this assertion said `["Net"]` and was WRONG about candor rather than about the
        // fix, which is the failure mode an expectation copied from the concrete-arm case invites.
        XCTAssertEqual(r.fns["castsOnBothArms"], ["Env", "Net"],
                       "both arms cast to the same protocol — the CHA reaches both conformers; got "
                       + "\(r.fns["castsOnBothArms"].map(String.init(describing:)) ?? "ABSENT")")
        // The row's FIRST named arm: both branches cast to `PT`, so the roots AGREE and the bounded CHA
        // unions BOTH conformers. `Env` from `DT` and `Net` from `CT` — a single-witness answer would
        // carry only one of them, which is why the two conformers differ.
        XCTAssertEqual(r.fns["rowArmOne"], ["Env", "Net"],
                       "R589's first repro arm: both arms are `as PT`, so the roots agree and the CHA "
                       + "must reach BOTH conformers; got "
                       + "\(r.fns["rowArmOne"].map(String.init(describing:)) ?? "ABSENT")")
        // `h ?? CT()` is an OPERATOR sequence in the else position. It was already disclosed (`Unknown`
        // + `dispatch:PT.??`) rather than silent, so the requirement here is only that it does not get
        // WORSE — the `??` reading must survive.
        XCTAssertFalse((r.fns["opInElseArm"] ?? []).isEmpty,
                       "an operator in the ELSE arm must not become silent; got "
                       + "\(r.fns["opInElseArm"].map(String.init(describing:)) ?? "ABSENT")")
    }

    // ── 3. THE GATE, WHICH IS THE CURRENCY ────────────────────────────────────────────────────────
    // `pure` on the silent arm was an AFFIRMATIVE purity certification over a function that dials out,
    // not merely an absence. The three-element sibling exiting 1 in the SAME scan is the calibration.
    func testTheGateFlipsOnTheSilentSpellingAndNotOnItsControl() throws {
        let src = Self.head + """
        public func bareCond(_ x: Int)  { (x > 1 ? CT() : CT()).emitT() }
        """
        XCTAssertEqual(try scan(src, name: "GateA", policy: "deny Net bareCond").code, 1,
                       "`deny Net` must catch the ternary receiver's reach")
        XCTAssertEqual(try scan(src, name: "GateB", policy: "pure bareCond").code, 1,
                       "`pure` must not certify a function whose ternary receiver dials out")
    }

    // ── 4. THE SECOND CAUSE, ASSERTED AS IT IS — NOT COVERED HERE ─────────────────────────────────
    // A three-element ternary whose two arms resolve to DIFFERENT roots is R589's *stated* mechanism,
    // and it is a genuine control-flow MERGE: answering it needs a union of both roots or a hedge, and
    // either is a charge this fix has no over-charge control for. Pinned so it cannot change unnoticed.
    func testDifferingRootsStaysSilentAndIsNotClosedByThisFix() throws {
        let src = Self.head + """
        public func differingRoots(_ c: Bool) { (c ? CT() : DT()).emitT() }
        """
        let r = try scan(src, name: "Merge")
        XCTAssertNil(r.fns["differingRoots"],
                     "R589 RESIDUAL (OPEN): a three-element ternary whose arms resolve to different "
                     + "roots is still dropped. If this ever gains a row, that residual is CLOSED and "
                     + "this assertion is the thing to update; got "
                     + "\(r.fns["differingRoots"].map(String.init(describing:)) ?? "ABSENT")")
    }

    // ── 5. THE JOINS THE WIDER ARM MUST NOT CHANGE ────────────────────────────────────────────────
    // `mono` composes by CONJUNCTION and `opaqueHop` by DISJUNCTION, and what a longer sequence must
    // NOT do is give either join a different answer. Asserted as a DIFFERENTIAL against the
    // three-element twin in the same scan rather than as an absolute value, and that is deliberate:
    // whether the local-conformer CHA is suppressed at all depends on whether the protocol is declared
    // HERE or in a dependency, so an absolute expectation in this (local-protocol) fixture would pin
    // the wrong thing — the first draft asserted `[]` and was wrong about candor, not about the fix.
    // The absolute mono/erasure behaviour is pinned where it belongs, on a dependency-declared
    // abstraction, by `ScanBoundaryVeinProcessTests.ternaryBothOpaque`/`ternaryMixedOpacity`; this
    // file's obligation is the one this fix could break — that lengthening the sequence changes
    // nothing. Pre-fix the five-element arms are ABSENT and their twins are not, so it can fail.
    func testALongerSequenceGivesTheSameAnswerAsItsThreeElementTwin() throws {
        let src = Self.head + """
        public func bothOpaque3(_ a: some PT, _ b: some PT, _ c: Bool) { (c ? a : b).emitT() }
        public func bothOpaque5(_ a: some PT, _ b: some PT, _ x: Int)  { (x > 1 ? a : b).emitT() }
        public func mixed3(_ m: some PT, _ e: any PT, _ c: Bool) { (c ? m : e).emitT() }
        public func mixed5(_ m: some PT, _ e: any PT, _ x: Int)  { (x > 1 ? m : e).emitT() }
        """
        let r = try scan(src, name: "Opacity")
        XCTAssertNotNil(r.fns["bothOpaque3"], "the three-element twin must be present to compare against")
        XCTAssertEqual(r.fns["bothOpaque5"], r.fns["bothOpaque3"],
                       "ALL-monomorphized: the sequence length must not change the opacity verdict; got "
                       + "\(r.fns["bothOpaque5"].map(String.init(describing:)) ?? "ABSENT") vs "
                       + "\(r.fns["bothOpaque3"].map(String.init(describing:)) ?? "ABSENT")")
        XCTAssertEqual(r.fns["mixed5"], r.fns["mixed3"],
                       "MIXED opacity: same; got "
                       + "\(r.fns["mixed5"].map(String.init(describing:)) ?? "ABSENT") vs "
                       + "\(r.fns["mixed3"].map(String.init(describing:)) ?? "ABSENT")")
    }
}
