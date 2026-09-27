import XCTest
import Foundation

/// **SOUNDNESS R620 (WIDENED) — A METATYPE BINDER IS INERT *PRECISELY UNDER SHADOWING*, because
/// `metatypeBinders[name]` is a SIDE INDEX and `metatypeBinder`'s first guard is `vars[spelling] == nil`.**
///
/// `vars[name] = …` DISPLACES an enclosing binding of the same name; `metatypeBinders[name] = …` sits
/// beside it. So every binder that records a metatype and does not drop the stale `vars` entry resolves
/// the shadowing name against the OUTER type — and the arm that was added to answer the metatype question
/// never fires. Measured at `1656d0b`, one variable per pair (whether an enclosing parameter shares the
/// binder's name), the outer type carrying a HARMLESS same-named member so the failure is a SILENCE and
/// not a swapped effect:
///
///     func f(_ t: Deleter) { xs.forEach { (t: CBase.Type) in t.validate() } }   ABSENT   b5
///     func f(_ t: Deleter) { xs.forEach { t in t.validate() } }                 ABSENT   b6 closure
///     func f(_ t: Deleter) { let t: CBase.Type = CImpl.self; t.validate() }     ABSENT   b2/b3
///     func f(_ t: Deleter) { let t = mkC(); t.validate() }                      ABSENT   b9
///
/// with `deny Net <fn>` **exit 0** on every one and **exit 1** on its rename control in the same scan.
///
/// **R620 NAMED TWO ARMS AND THERE ARE FOUR.** The row cites the two CLOSURE-parameter sites and calls
/// both "ZERO-HIT / safety-only". The two LOCAL-binder sites — `let t: CBase.Type = …` and `let t = mkC()`
/// — have the identical mechanism and are the worse pair: the metatype is written in the source, or
/// returned by a function declared to return one, and `t.validate()` still resolved against `Deleter`.
/// They were found by grepping ALL SEVEN `metatypeBinders` write sites rather than the two the row handed
/// over (§9 — an audit's boundary must not be drawn around its own trigger). The three that were already
/// safe each say so in their own comment, which is how the boundary is checkable rather than asserted:
/// the `for`-in arm ("the names are already cleared and saved above"), the `case let` payload arm ("after
/// `clearBinding`") and the `if let` unwrap arm ("`clearBinding` runs FIRST"). `forInShadowed` and
/// `caseLetShadowed` below are those two as PASSING controls, so this file measures the boundary in both
/// directions instead of asserting it.
///
/// This is R124's shape one index over, in the same function, one round later — and R124's own fixture
/// could not see it because `vars` was the only map it varied.
final class MetatypeBinderShadowProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], code: Int32) {
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
        var by: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, r.code)
    }

    /// `Deleter.validate()` is HARMLESS and same-named on purpose. An outer type whose member performed a
    /// DIFFERENT effect would make the defect look like a swapped effect, which is easy to spot; the real
    /// shape is a silence, which is not — and it is the shape a project hits, because the outer binding is
    /// usually an ordinary object and the inner one a type being validated.
    static let head = """
    import Foundation
    class CBase { class func validate() { _ = URLSession.shared.dataTask(with: URL(string: "https://c.example")!) } }
    final class CImpl: CBase { override class func validate() { _ = URLSession.shared.dataTask(with: URL(string: "https://d.example")!) } }
    final class Deleter { func validate() { } }
    let xs: [CBase.Type] = [CImpl.self]
    func mkC() -> CBase.Type { CImpl.self }
    enum Box { case one(CBase.Type) }

    """

    /// Every metatype-binder spelling × shadowed/renamed, in ONE scan so the controls and the arms share a
    /// binary, a corpus and a classifier. `_ z: Deleter` is the rename control: same body, same sink, and
    /// the only thing that changes is whether the outer parameter collides with the binder's name.
    static let arms = """
    // b5 — a closure parameter with a METATYPE annotation
    public func b5Shadowed(_ t: Deleter) { xs.forEach { (t: CBase.Type) in t.validate() } }
    public func b5Renamed(_ z: Deleter)  { xs.forEach { (t: CBase.Type) in t.validate() } }
    // b6 (closure element) — an UNANNOTATED closure parameter iterating `[CBase.Type]`
    public func b6Shadowed(_ t: Deleter) { xs.forEach { t in t.validate() } }
    public func b6Renamed(_ z: Deleter)  { xs.forEach { t in t.validate() } }
    // b2/b3 — an ANNOTATED local binder. R620 does not name this one.
    public func annShadowed(_ t: Deleter) { let t: CBase.Type = CImpl.self; t.validate() }
    public func annRenamed(_ z: Deleter)  { let t: CBase.Type = CImpl.self; t.validate() }
    // b9 — an UNANNOTATED local binder off a metatype-returning factory. R620 does not name this one.
    public func factShadowed(_ t: Deleter) { let t = mkC(); t.validate() }
    public func factRenamed(_ z: Deleter)  { let t = mkC(); t.validate() }
    // ALREADY SAFE, and here as the boundary's other direction — both PASS before the fix.
    public func forInShadowed(_ t: Deleter) { for t in xs { t.validate() } }
    public func caseLetShadowed(_ t: Deleter, _ b: Box) { switch b { case .one(let t): t.validate() } }
    """

    func testEveryMetatypeBinderSurvivesAShadowingOuterName() throws {
        let r = try scan(Self.head + Self.arms, name: "Shadow")
        for arm in ["b5", "b6", "ann", "fact"] {
            XCTAssertEqual(r.fns["\(arm)Renamed"], ["Net"],
                           "\(arm)Renamed is THE CONTROL and must charge in the same scan; got "
                           + "\(r.fns["\(arm)Renamed"].map(String.init(describing:)) ?? "ABSENT")")
            XCTAssertEqual(r.fns["\(arm)Shadowed"], ["Net"],
                           "R620: the metatype binder is inert precisely under shadowing, so this arm "
                           + "resolved against the OUTER type and went silent; got "
                           + "\(r.fns["\(arm)Shadowed"].map(String.init(describing:)) ?? "ABSENT")")
        }
        // The boundary's OTHER direction: two write sites that already clear, asserted as passing so a
        // future regression in them is this file's failure too.
        XCTAssertEqual(r.fns["forInShadowed"], ["Net"], "the for-in arm already cleared and must keep doing so")
        XCTAssertEqual(r.fns["caseLetShadowed"], ["Net"], "the case-let arm already cleared and must keep doing so")
    }

    /// A GATE FLIP is the currency. `deny Net` on each shadowed arm against the same rule on its rename
    /// control, in separate runs so one violation cannot stand in for another.
    func testTheGateMovesOnEveryShadowedArm() throws {
        let src = Self.head + Self.arms
        for arm in ["b5", "b6", "ann", "fact"] {
            XCTAssertEqual(try scan(src, name: "G\(arm)C", policy: "deny Net \(arm)Renamed").code, 1,
                           "\(arm)Renamed: the control must already be caught")
            XCTAssertEqual(try scan(src, name: "G\(arm)S", policy: "deny Net \(arm)Shadowed").code, 1,
                           "\(arm)Shadowed: `deny Net` exited 0 over a function that dials out")
        }
    }

    /// THE LOSS DIRECTION, and it is the one a narrow-vs-wide clear decides. The fix drops `vars[name]`
    /// and NOTHING else; these two arms bind a metatype to a name that ALSO has to keep working as an
    /// ordinary value afterwards — the closure parameter must not leak its clear past the closure
    /// (R124's property), and a later rebind of the same name in the same function must type normally.
    /// Both would go silent if the clear were unscoped or too wide.
    func testTheClearDoesNotOutliveTheBindingOrWidenPastVars() throws {
        let src = Self.head + """
        final class Outer { func fire() { _ = ProcessInfo.processInfo.environment["K"] } }
        // the closure's clear must be GIVEN BACK: `t` outside it is still the parameter.
        public func leakPastClosure(_ t: Outer) { xs.forEach { (t: CBase.Type) in t.validate() }; t.fire() }
        // a later rebind of the same name must type as an ordinary value, not stay cleared.
        public func rebindAfterMetatype() { let t: CBase.Type = CImpl.self; t.validate(); let t2 = Outer(); t2.fire() }
        """
        let r = try scan(src, name: "Loss")
        XCTAssertEqual(r.fns["leakPastClosure"], ["Env", "Net"],
                       "the closure's clear must not outlive the closure — `t.fire()` after it is still "
                       + "the PARAMETER, so Env must be there beside the Net; got "
                       + "\(r.fns["leakPastClosure"].map(String.init(describing:)) ?? "ABSENT")")
        XCTAssertEqual(r.fns["rebindAfterMetatype"], ["Env", "Net"],
                       "both the metatype dispatch and the ordinary rebind must resolve; got "
                       + "\(r.fns["rebindAfterMetatype"].map(String.init(describing:)) ?? "ABSENT")")
    }
}
