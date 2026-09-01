import XCTest
import Foundation

/// R98 — A BINDER THAT SHADOWS ITS RECEIVER'S NAME LOST THE EFFECT IN ITS OWN INITIALIZER.
///
/// rust R92's class, one language over, found by translating the question rather than by hitting it
/// again (brief §F). The initializer or sequence expression of a binder is a CHILD of the binder's own
/// syntax node, so every visitor that cleared or rebound the name and then returned `.visitChildren`
/// resolved that expression against a receiver it had already destroyed. Holding EVERYTHING constant
/// but the binder's name:
///
///     if    let w = w.kill()   ABSENT        if    let q = w.kill()   ['Fs']
///     guard let w = w.kill()   ABSENT        guard let q = w.kill()   ['Fs']
///     while let w = w.kill()   ABSENT        while let q = w.kill()   ['Fs']
///     for       w in w.many()  ABSENT        for       q in w.many()  ['Fs']
///           let w = w.kill()   ABSENT              let q = w.kill()   ['Fs']
///     if case let w? = w.kill() ABSENT       if case let q? = w.kill() ['Fs']
///
/// GROUND TRUTH EXECUTED: the fixture below was built and run and really deletes its file. Two effect
/// classes (`Fs`, `Env`), because a union over one class cannot distinguish a lost arm from a found one.
///
/// THE FIXTURE'S OWN TRAP, recorded because it nearly produced a wrong reading: the first version bound
/// the worker to a MODULE-SCOPE `let w`, so `rootOf` fell through to `globalTypes["w"]` after the clear
/// and three of the broken arms came back CHARGED. The measurement was of a global rescuing a shadowed
/// local, not of the binder. The top-level binding is named `topLevelWorker` for that reason — a
/// same-named global is a second variable and the comparison had two.
///
/// THE FIX IS ONE RULE APPLIED IN THREE PLACES, not three ordering rules: the expression that produces
/// the value is walked BEFORE the name it binds is touched. `visit(OptionalBindingConditionSyntax)` and
/// `visit(MatchingPatternConditionSyntax)` defer the whole binding to `visitPost` (their initializer is
/// a child and the binder's scope is a SIBLING, so `visitPost` is still in time);
/// `visit(ForStmtSyntax)` and `visit(VariableDeclSyntax)` walk the sequence/initializers explicitly and
/// then `.skipChildren`, because for those the BODY is a child too.
///
/// THE ARMS THAT WERE ALREADY CORRECT ARE ENUMERATED HERE SO THE LIST IS CLOSED, which is the half of
/// rust's `9c4d5be` worth copying — `catch let w` (its `try` expression is not a child of the catch
/// clause) and `switch case let w?` (the subject is a child of the `switch`, not of the case). Both are
/// pinned by `testBindersThatWereAlreadyCorrect`: if a later refactor routes them through the deferral
/// and gets it wrong, that row says so rather than nobody noticing they were never covered.
final class SelfShadowingBinderOrderProcessTests: XCTestCase {

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

    private static let src = """
    import Foundation
    final class W {
        let p: String
        init(_ p: String) { self.p = p }
        func kill() -> String? { try? FileManager.default.removeItem(atPath: p); return p }
        func peek() -> String? { ProcessInfo.processInfo.environment["R98"] }
        func many() -> [String] { try? FileManager.default.removeItem(atPath: p); return [p] }
    }
    func s1(_ w: W)  { if let w = w.kill() { _ = w } }
    func s1c(_ w: W) { if let q = w.kill() { _ = q } }
    func s2(_ w: W)  { guard let w = w.kill() else { return }; _ = w }
    func s2c(_ w: W) { guard let q = w.kill() else { return }; _ = q }
    func s3(_ w: W)  { for w in w.many() { _ = w } }
    func s3c(_ w: W) { for q in w.many() { _ = q } }
    func s4(_ w: W)  { if let w = w.peek() { _ = w } }
    func s4c(_ w: W) { if let q = w.peek() { _ = q } }
    func s5(_ w: W)  { let w = w.kill(); _ = w }
    func s5c(_ w: W) { let q = w.kill(); _ = q }
    func s6(_ w: W)  { do { _ = try s6t(w) } catch let w { _ = w } }
    func s6t(_ w: W) throws -> String? { w.kill() }
    func s7(_ w: W)  { switch w.kill() { case let w?: _ = w; default: break } }
    func s7c(_ w: W) { switch w.kill() { case let q?: _ = q; default: break } }
    func s8(_ w: W)  { var n = 0; while let w = w.kill() { _ = w; n += 1; if n > 0 { break } } }
    func s8c(_ w: W) { var n = 0; while let q = w.kill() { _ = q; n += 1; if n > 0 { break } } }
    func s9(_ w: W)  { if case let w? = w.kill() { _ = w } }
    func s9c(_ w: W) { if case let q? = w.kill() { _ = q } }

    let topLevelWorker = W("/tmp/r98-x")
    s1(topLevelWorker); s1c(topLevelWorker); s2(topLevelWorker); s2c(topLevelWorker)
    s3(topLevelWorker); s3c(topLevelWorker); s4(topLevelWorker); s4c(topLevelWorker)
    s5(topLevelWorker); s5c(topLevelWorker); s6(topLevelWorker); s7(topLevelWorker); s7c(topLevelWorker)
    s8(topLevelWorker); s8c(topLevelWorker); s9(topLevelWorker); s9c(topLevelWorker)
    """

    private func eff(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set((by[fn]?["inferred"] as? [String]) ?? [])
    }

    /// THE ROW. Every one of these was ABSENT from `functions[]` — silent purity over an executed
    /// deletion — and every one has its rename control in `testRenameControlsWereAlwaysCorrect`.
    func testSelfShadowingBindersKeepTheirInitializersEffect() throws {
        let by = try scan(Self.src, "R98")
        for fn in ["s1", "s2", "s3", "s5", "s8", "s9"] {
            XCTAssertEqual(eff(by, fn), ["Fs"], "\(fn): the shadowed receiver's effect is silent")
        }
        XCTAssertEqual(eff(by, "s4"), ["Env"],
                       "s4: a SECOND effect class through the same binder, so Fs cannot be the only thing measured")
    }

    /// THE CONTROL, and it is the only thing that makes the rows above a measurement: the identical
    /// body with the binder RENAMED was already correct, and must not move.
    func testRenameControlsWereAlwaysCorrect() throws {
        let by = try scan(Self.src, "R98")
        for fn in ["s1c", "s2c", "s3c", "s5c", "s8c", "s9c"] {
            XCTAssertEqual(eff(by, fn), ["Fs"], "\(fn): rename control moved — the fix changed more than the ordering")
        }
        XCTAssertEqual(eff(by, "s4c"), ["Env"])
    }

    /// THE CLOSED LIST. These two binder forms shadow the same way and were ALREADY correct, because
    /// their producing expression is not a child of the binder's node. Named so the enumeration is
    /// complete rather than "three fixes and an open question".
    func testBindersThatWereAlreadyCorrect() throws {
        let by = try scan(Self.src, "R98")
        XCTAssertEqual(eff(by, "s6"), ["Fs"], "catch let w — the `try` expression is not a child of the catch clause")
        XCTAssertEqual(eff(by, "s7"), ["Fs"], "switch case let w? — the subject is a child of the switch, not the case")
        XCTAssertEqual(eff(by, "s7c"), ["Fs"])
    }

    /// THE FABRICATION DIRECTION, which is what deferring a clear risks. Once the binder does move, the
    /// OLD type must be gone: a later call on the same name must not resolve against the type the
    /// binding used to have. `after*` is the row; `inside*` is the control that the deferral did not
    /// simply stop clearing.
    func testTheOldTypeIsStillDroppedOnceTheBinderMoves() throws {
        let src = """
        import Foundation
        final class W {
            func kill() -> String? { try? FileManager.default.removeItem(atPath: "/tmp/r98-y"); return nil }
        }
        // `w` is a String? after the binding; a later `w.kill()` must NOT resolve to W.kill
        func afterLet(_ w: W)   { let w = w.kill(); _ = w?.count }
        func afterIfLet(_ w: W) { if let w = w.kill() { _ = w.count } }
        func afterForIn(_ w: W, _ xs: [String]) { for w in xs { _ = w.count } }
        func afterIfCase(_ w: W) { if case let w? = w.kill() { _ = w.count } }
        // …and the binding OUTSIDE the construct is given back
        func restoredAfterIf(_ w: W) { if let x = w.kill() { _ = x }; _ = w.kill() }
        afterLet(W()); afterIfLet(W()); afterForIn(W(), []); afterIfCase(W()); restoredAfterIf(W())
        """
        let by = try scan(src, "R98Stale")
        // each of these performs the deletion EXACTLY ONCE (in the initializer), so exactly Fs and no
        // more; the point is that nothing resolves a second W.kill through the rebound name.
        for fn in ["afterLet", "afterIfLet", "afterIfCase"] {
            XCTAssertEqual(eff(by, fn), ["Fs"], "\(fn): unexpected effect set — a stale receiver type resolved")
        }
        XCTAssertNil(by["afterForIn"],
                     "afterForIn: the loop binder is a String; nothing in it can reach Fs (\(by["afterForIn"] ?? [:]))")
        XCTAssertEqual(eff(by, "restoredAfterIf"), ["Fs"],
                       "the parameter must still be a W after the `if` closes")
    }

    /// THE DEFECT THIS FIX INTRODUCED AND THE CORPUS CAUGHT — kept as a row because a fix that has
    /// already produced one silent under-report is the one most likely to produce another.
    ///
    /// The first version of the `if/guard case` deferral marked every binder of the pattern and cleared
    /// them all in `visitPost`. `typeEnumCaseBinding` TYPES `case .callback(let handler)` from the enum's
    /// associated value during the pattern walk, so the blanket clear wiped it and the payload binder
    /// stopped resolving. Measured on swift-nio: `SelectableEventLoop.cancelScheduledCallback` lost its
    /// edge to `…didCancelScheduledCallback` and the `Env` reach behind it — visible ONLY in the A/B's
    /// narrow `inferred` column; all 1,023 tests were green over it.
    ///
    /// Two guards now: the deferral fires only when the initializer MENTIONS a bound name, and the clear
    /// skips anything `typeEnumCaseBinding` claimed.
    func testEnumPayloadBinderInAGuardCaseStillResolves() throws {
        let src = """
        import Foundation
        protocol Handler { func run() }
        struct RealHandler: Handler { func run() { try? FileManager.default.removeItem(atPath: "/tmp/r98-z") } }
        enum Task { case callback(Handler), none }
        func fire(_ t: Task) {
            guard case .callback(let handler) = t else { return }
            handler.run()
        }
        func fireIf(_ t: Task) {
            if case .callback(let handler) = t { handler.run() }
        }
        fire(.callback(RealHandler())); fireIf(.callback(RealHandler()))
        """
        let by = try scan(src, "R98Enum")
        for fn in ["fire", "fireIf"] {
            XCTAssertEqual(eff(by, fn), ["Fs"],
                           "\(fn): the enum-payload binder lost its type — the deferral clobbered typeEnumCaseBinding")
        }
    }
}
