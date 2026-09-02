import XCTest
import Foundation

/// R124 — `vars` IS NOT IN `ShadowSave`, SO EVERY RAW `vars[…] =` INSIDE A SCOPED VISITOR LEAKS.
///
/// `ShadowSave` holds seven name-keyed FLAG maps and `leaveShadowScope` gives them back. The TYPE
/// indexes are given back through a different channel — `typeScopes`, written only by
/// `scopeBindingType` — and until R124 exactly two of the eight sites that write `vars` used it
/// (`visit(ForStmtSyntax)`'s own save, and `typeCastBinder`). The other six wrote the map raw, so the
/// binder's type outlived the construct that bound it, function-wide.
///
/// That is wrong in BOTH directions and both are measured below, which is the part worth carrying:
///   * OUTWARD-LOSS — the shadowing binder's INERT type outlives it, and the effectful outer binding
///     goes silent-pure. A cardinal sin: `func f(_ fm: FileManager) { if let fm = o { }; fm.removeItem(…) }`
///     was ABSENT from the report over a real file deletion.
///   * OUTWARD-FABRICATION — the mirror. The shadowing binder's EFFECTFUL type outlives it and the
///     inert outer binding is charged `Fs` for a call that provably does nothing (`fab*` below).
/// A previous audit of this same mechanism (see `enterShadowScope`) probed only the loss direction and
/// filed two clean verdicts that were wrong. A rename control run in one direction is half a control.
///
/// TWO OF THE NINE ARMS ARE REGRESSIONS INTRODUCED BY `c2bcfe6`, seven are pre-existing at the
/// published `819fac6`, and the audit found the seven only because it was widened past the two it was
/// handed (§9 — an audit's boundary must not be drawn around its own trigger):
///
///     arm                  site                                    introduced by
///     closureAnnotated     visit(ClosureExprSyntax)                c2bcfe6   (comment asserted it could not leak)
///     attrLocal            visit(VariableDeclSyntax) .skipChildren c2bcfe6   (node.attributes dropped)
///     callArgAnnotated     typeClosureParams, annotated arm        pre-existing
///     callArgElement       typeClosureParams, element arm          pre-existing
///     casePayload          typeEnumCaseBinding                     pre-existing
///     optionalBinding      visitPost(OptionalBindingConditionSyntax) pre-existing
///     nestedLet            visit(VariableDeclSyntax), plain binder pre-existing
///
/// GROUND TRUTH EXECUTED. `Self.src` below is the EXACT source of an SPM package that was built and
/// RUN: each of the seventeen effectful arms creates its probe file and is observed to delete it, and
/// each of the three `fab*` controls is observed NOT to. This matters because most of these assertions
/// are about an ABSENCE (§E3), and an omitted pure function and an omitted effectful one are the same
/// bytes — a fixture that did not run would prove nothing in either direction.
///
/// EVERY ARM IS REVERT-TESTED: each of the eight fixed sites was removed in turn and this suite
/// went red for it. The last two arms exist BECAUSE of that test — `caseLetOutside` and
/// `tupleShadow` were written after the first revert pass showed those two sites unprotected,
/// i.e. fixed with no fixture that could tell the fix from its absence (§A).
///
/// A/B, five real corpora, 7,876 common rows, keyed on EVERY field: ADDED 0, REMOVED 0, CHANGED 16,
/// `inferred` changes 0. See the commit message for the per-site attribution.
final class BinderTypeScopeProcessTests: XCTestCase {

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

    /// One unit per arm and one PROBE PATH per arm, so no arm's answer can be supplied by another's.
    /// `Inert.removeItem` is deliberately a no-op with the same selector as `FileManager`'s, so the
    /// two directions are distinguishable: charging it is a fabrication, not a conservative guess.
    private static let src = """
    import Foundation

    struct Inert { func removeItem(atPath: String) {} }
    enum Box { case inert(Inert) }
    func take(_ f: (Inert) -> Void) {}
    @propertyWrapper struct Tagged {
        var wrappedValue: Int
        init(wrappedValue: Int, _ tag: String) { self.wrappedValue = wrappedValue }
    }
    func effTag() -> String { try? FileManager.default.removeItem(atPath: "/tmp/r99-attr"); return "t" }

    // ── LEAK ARMS: an inner binder SHADOWS `fm`, and `fm` is used AFTER the construct ──
    func closureAnnotated(_ fm: FileManager) {
        let c: (Inert) -> Void = { (fm: Inert) in _ = fm }
        _ = c
        try? fm.removeItem(atPath: "/tmp/r99-a1")
    }
    func callArgAnnotated(_ fm: FileManager) {
        take { (fm: Inert) in _ = fm }
        try? fm.removeItem(atPath: "/tmp/r99-a2")
    }
    func callArgElement(_ fm: FileManager) {
        let xs: [Inert] = []
        xs.forEach { fm in _ = fm }
        try? fm.removeItem(atPath: "/tmp/r99-a3")
    }
    func casePayload(_ fm: FileManager, _ b: Box) {
        switch b { case .inert(let fm): _ = fm }
        try? fm.removeItem(atPath: "/tmp/r99-a4")
    }
    func optionalBinding(_ fm: FileManager, _ o: Inert?) {
        if let fm = o { _ = fm }
        try? fm.removeItem(atPath: "/tmp/r99-a5")
    }
    func nestedLet(_ fm: FileManager, _ c: Bool) {
        if c { let fm = Inert(); _ = fm }
        try? fm.removeItem(atPath: "/tmp/r99-a6")
    }
    func attrLocal() { @Tagged(effTag()) var n: Int = 1; _ = n }
    // `case let .inert(fm)` — the `let` OUTSIDE the parens. This arm CLEARS rather than types, so its
    // leak is the LOSS direction: without the restore the outer receiver stays cleared for the rest
    // of the body. Written as a sibling of `casePayload` (§A.2), then MEASURED — it is a real arm.
    func caseLetOutside(_ fm: FileManager, _ b: Box) {
        switch b { case let .inert(fm): _ = fm }
        try? fm.removeItem(atPath: "/tmp/r99-b1")
    }
    // A TUPLE-destructured `let` in a nested block — the sibling of `nestedLet` one pattern over.
    func tupleShadow(_ fm: FileManager, _ c: Bool) {
        if c { let (fm, _) = (Inert(), 1); _ = fm }
        try? fm.removeItem(atPath: "/tmp/r99-b3")
    }

    // ── RENAME CONTROLS: identical bodies, the inner binder renamed so it cannot collide ──
    func closureAnnotatedC(_ fm: FileManager) {
        let c: (Inert) -> Void = { (zz: Inert) in _ = zz }
        _ = c
        try? fm.removeItem(atPath: "/tmp/r99-c1")
    }
    func callArgAnnotatedC(_ fm: FileManager) {
        take { (zz: Inert) in _ = zz }
        try? fm.removeItem(atPath: "/tmp/r99-c2")
    }
    func callArgElementC(_ fm: FileManager) {
        let xs: [Inert] = []
        xs.forEach { zz in _ = zz }
        try? fm.removeItem(atPath: "/tmp/r99-c3")
    }
    func casePayloadC(_ fm: FileManager, _ b: Box) {
        switch b { case .inert(let zz): _ = zz }
        try? fm.removeItem(atPath: "/tmp/r99-c4")
    }
    func optionalBindingC(_ fm: FileManager, _ o: Inert?) {
        if let zz = o { _ = zz }
        try? fm.removeItem(atPath: "/tmp/r99-c5")
    }
    func nestedLetC(_ fm: FileManager, _ c: Bool) {
        if c { let zz = Inert(); _ = zz }
        try? fm.removeItem(atPath: "/tmp/r99-c6")
    }
    func attrInitializerC() { let s = effTag(); _ = s }
    func caseLetOutsideC(_ fm: FileManager, _ b: Box) {
        switch b { case let .inert(zz): _ = zz }
        try? fm.removeItem(atPath: "/tmp/r99-b2")
    }
    func tupleShadowC(_ fm: FileManager, _ c: Bool) {
        if c { let (zz, _) = (Inert(), 1); _ = zz }
        try? fm.removeItem(atPath: "/tmp/r99-b4")
    }

    // ── FABRICATION CONTROLS: the inner binder is the EFFECTFUL type, the outer is inert.
    // The restore must give the INERT type back; charging Fs here is a fabrication, and pre-R124 all
    // three were charged. `Inert.removeItem` is a no-op, verified by execution.
    func fabClosure(_ fm: Inert) {
        let c: (FileManager) -> Void = { (fm: FileManager) in _ = fm }
        _ = c
        fm.removeItem(atPath: "/tmp/r99-f1")
    }
    func fabOptional(_ fm: Inert, _ o: FileManager?) {
        if let fm = o { _ = fm }
        fm.removeItem(atPath: "/tmp/r99-f2")
    }
    func fabNestedLet(_ fm: Inert, _ c: Bool) {
        if c { let fm = FileManager.default; _ = fm }
        fm.removeItem(atPath: "/tmp/r99-f3")
    }

    // EXECUTED — every arm ran and its probe was observed (§E3). Kept in the fixture so the source
    // this suite scans is byte-identical to the source that was run.
    let fmg = FileManager.default
    func arm(_ p: String, _ run: () -> Void) {
        fmg.createFile(atPath: p, contents: Data("x".utf8))
        run()
        print("\\(p) deleted == \\(!fmg.fileExists(atPath: p))")
    }
    arm("/tmp/r99-a1") { closureAnnotated(fmg) }
    arm("/tmp/r99-a2") { callArgAnnotated(fmg) }
    arm("/tmp/r99-a3") { callArgElement(fmg) }
    arm("/tmp/r99-a4") { casePayload(fmg, .inert(Inert())) }
    arm("/tmp/r99-a5") { optionalBinding(fmg, nil) }
    arm("/tmp/r99-a6") { nestedLet(fmg, true) }
    arm("/tmp/r99-attr") { attrLocal() }
    arm("/tmp/r99-b1") { caseLetOutside(fmg, .inert(Inert())) }
    arm("/tmp/r99-b2") { caseLetOutsideC(fmg, .inert(Inert())) }
    arm("/tmp/r99-b3") { tupleShadow(fmg, true) }
    arm("/tmp/r99-b4") { tupleShadowC(fmg, true) }
    arm("/tmp/r99-c1") { closureAnnotatedC(fmg) }
    arm("/tmp/r99-c2") { callArgAnnotatedC(fmg) }
    arm("/tmp/r99-c3") { callArgElementC(fmg) }
    arm("/tmp/r99-c4") { casePayloadC(fmg, .inert(Inert())) }
    arm("/tmp/r99-c5") { optionalBindingC(fmg, nil) }
    arm("/tmp/r99-c6") { nestedLetC(fmg, true) }
    arm("/tmp/r99-f1") { fabClosure(Inert()) }
    arm("/tmp/r99-f2") { fabOptional(Inert(), nil) }
    arm("/tmp/r99-f3") { fabNestedLet(Inert(), true) }
    """

    /// THE SEVEN LEAK ARMS. Each was ABSENT from the report — a silent under-report over a deletion
    /// this fixture is observed to perform — and each is named individually so a regression says WHICH
    /// binder form came back, not "a count moved".
    func testNoBinderTypeOutlivesTheConstructThatBoundIt() throws {
        let by = try scan(Self.src, "R124")
        for a in ["closureAnnotated", "callArgAnnotated", "callArgElement",
                  "casePayload", "caseLetOutside", "optionalBinding", "nestedLet", "tupleShadow"] {
            XCTAssertEqual((by[a]?["inferred"] as? [String]).map(Set.init), ["Fs"],
                           "\(a): the shadowing binder's type outlived its scope, so the outer "
                           + "FileManager receiver read silent-pure over a real deletion")
        }
    }

    /// The `.skipChildren` arm, which is a different mechanism reaching the same silence:
    /// `visit(VariableDeclSyntax)` hand-enumerates what to walk and `node.attributes` was not on the
    /// list, so a property-wrapper ATTRIBUTE ARGUMENT was never visited at all.
    func testAPropertyWrapperAttributeArgumentIsWalked() throws {
        let by = try scan(Self.src, "R124")
        XCTAssertEqual((by["attrLocal"]?["inferred"] as? [String]).map(Set.init), ["Fs"],
                       "attrLocal: `@Tagged(effTag()) var n` — the attribute argument was not walked, "
                       + "so the deletion inside effTag() was invisible to the enclosing unit")
    }

    /// THE RENAME CONTROLS. Every one was ALREADY correct before R124 and must stay correct — a change
    /// here would mean the fix resolved something other than the name collision.
    func testRenameControlsAreUnchanged() throws {
        let by = try scan(Self.src, "R124")
        for a in ["closureAnnotatedC", "callArgAnnotatedC", "callArgElementC", "casePayloadC",
                  "caseLetOutsideC", "optionalBindingC", "nestedLetC", "tupleShadowC",
                  "attrInitializerC"] {
            XCTAssertEqual((by[a]?["inferred"] as? [String]).map(Set.init), ["Fs"], "\(a): control moved")
        }
    }

    /// THE FABRICATION MIRROR, and the direction the previous audit of this mechanism never probed.
    /// `Inert.removeItem` is a no-op — verified by running the fixture, where these three probe files
    /// survive — so charging `Fs` here is a fabrication, and all three were charged before R124.
    func testAShadowingBindersEffectfulTypeDoesNotOutliveItEither() throws {
        let by = try scan(Self.src, "R124")
        for a in ["fabClosure", "fabOptional", "fabNestedLet"] {
            XCTAssertNil(by[a], "\(a): the shadowing binder's FileManager type outlived its scope and "
                         + "charged Fs to a call on an inert receiver that provably deletes nothing")
        }
    }
}
