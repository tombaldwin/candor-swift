import XCTest
import Foundation

/// A NAME-KEYED FACT MUST NOT OUTLIVE THE BINDING THAT SET IT — the fifth instance of swift's own
/// recurring shape (`71de627`, `83cd607`, `42093b6`), found by auditing the maps the catch-all binder
/// does NOT cover rather than by waiting for a report to be wrong.
///
/// `clearBinding` covered `vars`/`arrayElem`/`opaqueElem`/`dictElem`/`tupleElem` and `shadowName` covered
/// `monoNames`/`depBoundLocals`. Two more name-keyed maps were covered by neither, and both leaked in the
/// FABRICATION direction — the one the other flags do not produce:
///
///   `protoTyped`        the LOCAL-protocol CHA. `func f(_ j: Job, _ xs: [String]) { for j in xs { j.run() } }`
///                       charged the conformer's Env to a call on a String.
///   `localConstStrings` the const-anchored literal surfaces. A shadowed `let u = "https://…"` attributed
///                       that host to a `dataTask` whose address is a runtime value — and `hosts` is what
///                       an `allow`/`forbid` host rule matches on.
///
/// EVERY ROW HAS ITS RENAME CONTROL. Identical bodies with the binder renamed is the only thing that
/// separates "the flag leaked" from "this binder was never typed anyway" — the distinction `42093b6`
/// recorded after a scoping fix that changed nothing.
final class BinderShadowProcessTests: XCTestCase {

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

    private static let protoSrc = """
    import Foundation
    protocol Job { func run() }
    protocol Conv { func asThing() -> Int }
    struct RealJob: Job { func run() { print(ProcessInfo.processInfo.environment["X"] ?? "") } }
    struct S1: Conv { func asThing() -> Int { print(ProcessInfo.processInfo.environment["X"] ?? ""); return 1 } }

    // the fabrication, and its rename control
    func loopShadow(_ j: Job, _ xs: [String]) { for j in xs { j.run() } }
    func loopNoShadow(_ j: Job, _ xs: [String]) { for t in xs { t.run() } }
    // the genuine parameter must still dispatch — before AND after a shadowing block
    func control(_ j: Job) { j.run() }
    func restoredAfterBlock(_ j: Job, _ xs: [String]) {
        for j in xs { _ = j }
        j.run()
    }
    // THE ORDERING ROW: the dispatch lives in the INITIALIZER of a binding that rebinds the same name,
    // so the old binding is still live while the initializer is walked. Alamofire's
    // `URLRequest.init(url: any URLConvertible …)` is `let url = try url.asURL()`, exactly this.
    func selfRebind(_ u: Conv) {
        let u = u.asThing()
        _ = u
    }
    func selfRebindControl(_ u: Conv) { _ = u.asThing() }
    // …and a rebind that does NOT mention the name must still invalidate the protocol type
    func typedRebind(_ u: Conv, _ s: String) {
        let u = s
        _ = u.asThing()
    }
    func typedRebindNoShadow(_ u: Conv, _ s: String) {
        let t = s
        _ = t.asThing()
    }
    """

    func testALoopBinderDoesNotInheritTheProtocolTypeOfTheParameterItShadows() throws {
        let by = try scan(Self.protoSrc, "Proto")
        XCTAssertEqual(by["control"]?["inferred"] as? [String], ["Env"],
                       "the trigger must be live, or every row below is vacuous")
        XCTAssertNil(by["loopShadow"],
                     "the loop binder is a String — charging the conformer's Env to `j.run()` is a fabrication")
        XCTAssertNil(by["loopNoShadow"], "the rename control: same body, different binder name")
        XCTAssertEqual(by["typedRebind"]?["inferred"] as? [String] ?? [], [],
                       "a typed rebind also stops the protocol type applying")
        XCTAssertNil(by["typedRebindNoShadow"])
    }

    /// THE SECOND FIXTURE, and it is the one that decided where the clear lives. Putting `protoTyped`
    /// in `shadowName` closes the fabrication above and sends this row from `['Env']` to ABSENT — the
    /// cardinal sin, traded in for its mirror. Measured on Alamofire as a real lost disclosure.
    func testTheReachInARebindingInitializerSurvives() throws {
        let by = try scan(Self.protoSrc, "Proto")
        XCTAssertEqual(by["selfRebindControl"]?["inferred"] as? [String], ["Env"])
        XCTAssertEqual(by["selfRebind"]?["inferred"] as? [String], ["Env"],
                       "`let u = u.asThing()` resolves through the binding it replaces — clearing before "
                       + "the initializer is walked loses a real reach (Alamofire URLRequest.init)")
        XCTAssertEqual(by["restoredAfterBlock"]?["inferred"] as? [String], ["Env"],
                       "the enclosing scope restores the protocol type past the shadowing block")
    }

    private static let constSrc = """
    import Foundation
    func hostLiteral() {
        let t = URLSession.shared.dataTask(with: "https://telemetry.example.com/beacon") { _, _, _ in }
        t.resume()
    }
    func hostConst() {
        let u = "https://telemetry.example.com/beacon"
        let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
        t.resume()
    }
    func hostConstShadowed(_ xs: [String]) {
        let u = "https://telemetry.example.com/beacon"
        _ = u
        for u in xs {
            let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
            t.resume()
        }
    }
    func hostConstNotShadowed(_ xs: [String]) {
        let u = "https://telemetry.example.com/beacon"
        _ = u
        for v in xs {
            let t = URLSession.shared.dataTask(with: v) { _, _, _ in }
            t.resume()
        }
    }
    func hostConstRestoredAfterLoop(_ xs: [String]) {
        let u = "https://telemetry.example.com/beacon"
        for u in xs { _ = u }
        let t = URLSession.shared.dataTask(with: u) { _, _, _ in }
        t.resume()
    }
    """

    func testAShadowedConstStringDoesNotAnchorALiteralHost() throws {
        let by = try scan(Self.constSrc, "Const")
        let host = ["telemetry.example.com"]
        // the trigger, both directly and through the const — or the row below asserts nothing
        XCTAssertEqual(by["hostLiteral"]?["hosts"] as? [String], host)
        XCTAssertEqual(by["hostConst"]?["hosts"] as? [String], host)
        // the fabrication and its rename control
        XCTAssertNil(by["hostConstShadowed"]?["hosts"],
                     "the loop binder's URL is a runtime value — a literal endpoint here is fabricated")
        XCTAssertNil(by["hostConstNotShadowed"]?["hosts"], "the rename control")
        for fn in ["hostConstShadowed", "hostConstNotShadowed"] {
            XCTAssertEqual(by[fn]?["inferred"] as? [String], ["Net"], "\(fn): the Net effect itself stands")
        }
        // the second direction: the const must survive the shadowing loop and still anchor below it
        XCTAssertEqual(by["hostConstRestoredAfterLoop"]?["hosts"] as? [String], host,
                       "the enclosing scope restores the const past the loop")
    }

    // ── `fnValueAlias` — the FIFTH map, and the widest of them ──────────────────────────────────────
    //
    // The four above are TYPE indexes: leaking one resolves a receiver against a type it does not have,
    // and what gets charged is whatever that type's member happens to do. `fnValueAlias` resolves a bare
    // `g()` to a NAMED LOCAL FUNCTION, so leaking it charges that function's entire transitive effect
    // set to an invocation of an unrelated value.
    //
    // It escaped the catch-all binder (`42093b6`) because the catch-all clears a LIST of maps, and it
    // escaped the audit that found `protoTyped`/`localConstStrings` because that audit probed it in one
    // direction only — "an aliased fn value called after a shadowing loop still resolves" is the LOSS
    // direction, and the FABRICATION direction was never run.
    private static let aliasSrc = """
    import Foundation
    func eff() { try? FileManager.default.removeItem(atPath: "/tmp/candor-alias-probe") }

    // (1) THE SECOND FIXTURE, written first: the alias itself must keep resolving, or the fix is
    //     indistinguishable from deleting the rung — `let g = eff; g()` read SILENT-PURE before the
    //     alias existed, which is the README §4 contract this map was added to honour.
    func aliasResolves() {
        let g = eff
        g()
    }
    // (2) …and it must survive a shadowing block, or the clear has traded the fabrication for a loss.
    func aliasRestoredAfterBlock(_ c: Bool) {
        let g = eff
        if c {
            let g = { }
            g()
        }
        g()
    }
    // (3) …and a SELF-REFERENTIAL rebind resolves THROUGH the binding it replaces: `shadowName` runs
    //     before the initializer is walked (the Alamofire `let url = try url.asURL()` ordering, one map
    //     over), and the re-aliasing branch cannot restore it because the RHS is a shadowed local.
    func aliasSelfRebind(_ c: Bool) {
        let g = eff
        if c {
            let g = g
            g()
        }
    }

    // (4) THE FABRICATION: a loop binder rebinds the aliased name. The elements are not `eff`.
    func aliasLoopShadow(_ jobs: [() -> Void]) {
        let g = eff
        _ = g
        for g in jobs { g() }
    }
    func aliasLoopNoShadow(_ jobs: [() -> Void]) {
        let g = eff
        _ = g
        for h in jobs { h() }
    }
    // (5) …and an INNER binding of the same name to a visibly-pure closure. This one does not go
    //     through `clearBinding` at all — a `let` that DOES type never reaches it — so it is the row
    //     that decides the clear lives in `shadowName` rather than in `clearBindingTypeOnly`.
    func aliasInnerShadow(_ c: Bool) {
        let g = eff
        _ = g
        if c {
            let g = { }
            g()
        }
    }
    func aliasInnerNoShadow(_ c: Bool) {
        let g = eff
        _ = g
        if c {
            let h = { }
            h()
        }
    }
    """

    func testAnAliasedFunctionValueDoesNotAnswerForALaterBindingOfTheName() throws {
        let by = try scan(Self.aliasSrc, "Alias")
        // the trigger must be live, or every row below is vacuous
        XCTAssertEqual(by["eff"]?["inferred"] as? [String], ["Fs"])
        XCTAssertEqual(by["aliasResolves"]?["inferred"] as? [String], ["Fs"],
                       "the alias rung itself: `let g = eff; g()` edges to the real unit")
        // the fabrication and its rename control
        XCTAssertNil(by["aliasLoopShadow"],
                     "the loop binder is one of `jobs`, not `eff` — charging eff's Fs here is a fabrication")
        XCTAssertNil(by["aliasLoopNoShadow"], "the rename control: same body, different binder name")
        XCTAssertNil(by["aliasInnerShadow"],
                     "the inner `let g = { }` is a pure closure — it must not inherit eff's body")
        XCTAssertNil(by["aliasInnerNoShadow"], "the rename control")
    }

    /// THE SECOND DIRECTION. Clearing without the scope, or clearing before a self-referential
    /// initializer is walked, sends each of these from `['Fs']` to ABSENT — the cardinal sin traded in
    /// for its mirror, which is how four of the five fixes in this family went wrong.
    func testTheAliasSurvivesAShadowingScopeAndASelfReferentialRebind() throws {
        let by = try scan(Self.aliasSrc, "Alias")
        XCTAssertEqual(by["aliasRestoredAfterBlock"]?["inferred"] as? [String], ["Fs"],
                       "the enclosing block restores the alias past the shadow")
        XCTAssertEqual(by["aliasSelfRebind"]?["inferred"] as? [String], ["Fs"],
                       "`let g = g` resolves through the binding it replaces — clearing before the "
                       + "initializer is walked loses a real reach")
    }
}
