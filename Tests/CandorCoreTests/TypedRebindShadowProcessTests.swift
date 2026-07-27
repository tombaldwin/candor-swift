import XCTest
import Foundation

/// A BINDER THAT **CAN** TYPE THE NEW BINDING STILL HAS TO INVALIDATE THE OLD ONE.
///
/// `CallCollector` splits the per-binding state in two: `shadowName` drops the four name-keyed FLAGS
/// (`monoNames`, `depBoundLocals`, `localConstStrings`, `fnValueAlias`) and `clearBindingTypeOnly` drops
/// the TYPE indexes (`vars`, `protoTyped`, `arrayElem`/`opaqueElem`, `dictElem`, `tupleElem`).
/// `clearBinding` is both. Every binder that CANNOT type its new binding goes through `clearBinding`;
/// the branches that CAN type it called `shadowName` alone and wrote `vars` over the top, leaving
/// `protoTyped` — and the rest — describing the binding that is no longer there.
///
/// That is a FABRICATION, and `protoTyped` is the sharp end of it: the member-dispatch site consults it
/// BEFORE the `vars` type, so a fresh type on the shadowing binding does not mask the stale protocol.
/// A payload/`if let`/closure/tuple/nested-func binding named after a protocol-typed parameter
/// dispatched over that protocol's conformers and charged their effects to a function that cannot
/// reach them.
///
/// EVERY ROW HAS ITS RENAME CONTROL — the identical body with the binding renamed. Without it "this
/// reads Fs" says nothing about whether the name collision is what caused it. (Standing bar: a rename
/// control run in ONE direction is half a control, so the second-direction rows are first in this file
/// and were written first.)
final class TypedRebindShadowProcessTests: XCTestCase {

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

    /// `RealJob.run` performs Fs and is the ONLY Fs in the fixture, so an `Fs` on any of the functions
    /// below is the local-protocol CHA firing — there is no other way for it to get there.
    private static let src = """
    import Foundation
    protocol Job { func run() }
    struct RealJob: Job {
        func run() { try? "x".write(toFile: "/tmp/candor-rebind.txt", atomically: true, encoding: .utf8) }
    }
    struct Ctx { func go() { _ = ProcessInfo.processInfo.environment["X"] } }
    enum E { case active(Ctx) }

    // ── the second direction, written first ────────────────────────────────────────────────────────
    // (a) the payload's OWN type must survive the clear, or the fix has traded a fabrication for a miss
    func typedPayload(_ e: E) { switch e { case .active(let c): c.go() } }
    // (b) a protocol-typed parameter the case does NOT shadow keeps dispatching
    func unshadowed(_ j: Job, _ e: E) { switch e { case .active(let c): _ = c }; j.run() }
    // (c) …and one it DOES shadow gets it back when the case closes: the clear is SCOPED
    func shadowRestored(_ j: Job, _ e: E) { switch e { case .active(let j): _ = j }; j.run() }

    // ── the fabrication ────────────────────────────────────────────────────────────────────────────
    func payloadShadow(_ j: Job, _ e: E) { switch e { case .active(let j): j.run() } }
    func payloadShadowRenamed(_ j: Job, _ e: E) { switch e { case .active(let q): q.run() } }
    """

    // ── the second direction ───────────────────────────────────────────────────────────────────────

    func testTheConformerIsEffectfulOrEveryRowHereIsVacuous() throws {
        let by = try scan(Self.src, "Rebind")
        XCTAssertEqual(by["RealJob.run"]?["inferred"] as? [String], ["Fs"],
                       "the only Fs in the fixture is the conformer's — if it is gone the fabrication "
                       + "rows below cannot fail and assert nothing")
        XCTAssertEqual(by["Ctx.go"]?["inferred"] as? [String], ["Env"],
                       "…and the payload type's own method must be effectful, or row (a) is vacuous")
    }

    func testTheEnumPayloadsOwnTypeStillResolves() throws {
        let by = try scan(Self.src, "Rebind")
        XCTAssertEqual(by["typedPayload"]?["inferred"] as? [String] ?? [], ["Env"],
                       "`case .active(let c)` types `c` from the case's associated value, and clearing "
                       + "the OTHER indexes first must not cost that — this is the reach the fabrication "
                       + "fix is most likely to close with it")
    }

    func testAProtocolParamTheCaseDoesNotShadowStillDispatches() throws {
        let by = try scan(Self.src, "Rebind")
        XCTAssertEqual(by["unshadowed"]?["inferred"] as? [String] ?? [], ["Fs"],
                       "the clear is per-NAME; a payload binding called something else says nothing "
                       + "about the parameter")
    }

    func testAProtocolParamTheCaseDOESShadowGetsItBackWhenTheCaseCloses() throws {
        let by = try scan(Self.src, "Rebind")
        XCTAssertEqual(by["shadowRestored"]?["inferred"] as? [String] ?? [], ["Fs"],
                       "`protoTyped` is in `ShadowSave` and `SwitchCaseSyntax` is a shadow scope, so the "
                       + "genuine parameter's dispatch BELOW the case is untouched. Clearing without the "
                       + "scope would send this to silent-pure — the mirror sin, and the direction a "
                       + "fabrication fix walks into (standing bar item 0).")
    }

    // ── the fabrication ────────────────────────────────────────────────────────────────────────────

    /// THE DEFECT. `typeEnumCaseBinding`'s TYPED branch called `shadowName` only, so the payload binding
    /// shadowing `j: Job` left `protoTyped["j"]` in place and `j.run()` dispatched over `RealJob`.
    func testAnEnumPayloadBindingDoesNotInheritTheShadowedParamsProtocol() throws {
        let by = try scan(Self.src, "Rebind")
        XCTAssertEqual(by["payloadShadow"]?["inferred"] as? [String] ?? [],
                       by["payloadShadowRenamed"]?["inferred"] as? [String] ?? [],
                       "the rename control: the same body with the binding named `q` — the ONLY "
                       + "difference is the name collision, so any effect the collision adds is fabricated")
        XCTAssertNil(by["payloadShadow"],
                     "`case .active(let j)` binds a Ctx; `j.run()` is not the protocol parameter's "
                     + "dispatch and must not be charged `RealJob.run`'s Fs")
        XCTAssertNil(by["payloadShadowRenamed"], "…and neither is the control, which never was")
    }

    // ── THE OTHER FOUR SITES ───────────────────────────────────────────────────────────────────────
    //
    // The enum-payload defect was found by review; the rename control that reproduced it was then run
    // over every other binder that TYPES its new binding, and four more answered. One mechanism, five
    // doors — a nested `func` parameter, an `if let`, an annotated closure parameter and a tuple
    // destructure, each shadowing a protocol-typed parameter and each dispatching over its conformers.
    //
    // TWO OF THE SECOND-DIRECTION ROWS ARE RECOVERIES, which is the part worth keeping: the stale
    // `protoTyped` was not only fabricating, it was MASKING the shadowing binding's real type. Removing
    // it makes `if let j = o { j.go() }` and the closure form resolve `Ctx.go` for the first time.

    /// `RealConv.asURL` is Net, `Ctx.go` is Env and `RealJob.run` is Fs — three distinct effects, so
    /// every row below names which reach it is about.
    private static let sites = """
    import Foundation
    protocol Job { func run() }
    struct RealJob: Job {
        func run() { try? "x".write(toFile: "/tmp/candor-rebind.txt", atomically: true, encoding: .utf8) }
    }
    struct Ctx { func go() { _ = ProcessInfo.processInfo.environment["X"] } }
    protocol Conv { func asURL() -> Ctx? }
    struct RealConv: Conv {
        func asURL() -> Ctx? {
            URLSession.shared.dataTask(with: "http://conv.internal/x") { _, _, _ in }.resume()
            return nil
        }
    }

    // ── the second direction, written first ────────────────────────────────────────────────────────
    // (a) THE CARVE-OUT. SwiftSyntax walks the PATTERN before the INITIALIZER, so a self-referential
    //     rebind resolves THROUGH the binding being replaced — Alamofire's `URLRequest.init(url: any
    //     URLConvertible)` is `if let u = u.asURL()`, and clearing unconditionally loses its Net.
    func selfRebindKeepsItsReach(_ u: Conv) { if let u = u.asURL() { u.go() } }
    // (b,c,d) the scoped maps must be GIVEN BACK when the block/closure/nested func closes
    func optBindRestored(_ j: Job, _ o: Ctx?) { if let j = o { j.go() }; j.run() }
    func closureRestored(_ j: Job, _ xs: [Ctx]) { xs.forEach { (j: Ctx) in j.go() }; j.run() }
    func nestedRestored(_ j: Job) { func inner(_ j: Ctx) { j.go() }; inner(Ctx()); j.run() }
    // (e) a tuple binding nothing shadows is untouched
    func tupleUnshadowed(_ j: Job) { let (q, _) = (Ctx(), 1); q.go(); j.run() }

    // ── the fabrications, each with its rename control ─────────────────────────────────────────────
    func optBindShadow(_ j: Job, _ o: Ctx?) { if let j = o { j.run() } }
    func optBindShadowRenamed(_ j: Job, _ o: Ctx?) { if let q = o { q.run() } }
    func closureShadow(_ j: Job, _ xs: [Ctx]) { xs.forEach { (j: Ctx) in j.run() } }
    func closureShadowRenamed(_ j: Job, _ xs: [Ctx]) { xs.forEach { (q: Ctx) in q.run() } }
    func tupleShadow(_ j: Job) { let (j, _) = (Ctx(), 1); j.run() }
    func tupleShadowRenamed(_ j: Job) { let (q, _) = (Ctx(), 1); q.run() }
    func nestedFuncShadow(_ j: Job) { func inner(_ j: Ctx) { j.run() }; inner(Ctx()) }
    func nestedFuncShadowRenamed(_ j: Job) { func inner(_ q: Ctx) { q.run() }; inner(Ctx()) }
    """

    func testTheThreeConformersAreEffectfulOrEveryRowBelowIsVacuous() throws {
        let by = try scan(Self.sites, "Sites")
        XCTAssertEqual(by["RealJob.run"]?["inferred"] as? [String], ["Fs"])
        XCTAssertEqual(by["Ctx.go"]?["inferred"] as? [String], ["Env"])
        XCTAssertEqual(by["RealConv.asURL"]?["inferred"] as? [String], ["Net"])
    }

    // ── the second direction ───────────────────────────────────────────────────────────────────────

    func testASelfReferentialRebindStillResolvesThroughTheBindingItReplaces() throws {
        let by = try scan(Self.sites, "Sites")
        XCTAssertTrue(Set(by["selfRebindKeepsItsReach"]?["inferred"] as? [String] ?? []).contains("Net"),
                      "`if let u = u.asURL()` resolves through the entry the rebind is about to clear. "
                      + "Clearing unconditionally is the mirror of the fabrication — a real cross-package "
                      + "reach dropped by a fix aimed at the opposite defect (standing bar item 0).")
    }

    func testTheScopedMapsAreGivenBackWhenTheBlockClosureOrNestedFuncCloses() throws {
        let by = try scan(Self.sites, "Sites")
        for fn in ["optBindRestored", "closureRestored", "nestedRestored"] {
            XCTAssertTrue(Set(by[fn]?["inferred"] as? [String] ?? []).contains("Fs"),
                          "\(fn): `protoTyped` is in `ShadowSave`, so the parameter's dispatch AFTER the "
                          + "shadowing scope is untouched. Clearing without the scope sends it to "
                          + "silent-pure.")
        }
        XCTAssertEqual(Set(by["tupleUnshadowed"]?["inferred"] as? [String] ?? []), ["Env", "Fs"],
                       "a tuple binding nothing shadows keeps both reaches")
    }

    /// THE CLEAR IS ALSO A RECOVERY, and this is the row that says so. The stale `protoTyped` did not
    /// only fabricate — it MASKED the shadowing binding's own type, because the member-dispatch site
    /// consults it before the `vars` root. With it gone, `j` is the `Ctx` it always was.
    func testRemovingTheStaleProtocolRecoversTheShadowingBindingsOwnType() throws {
        let by = try scan(Self.sites, "Sites")
        for fn in ["optBindRestored", "closureRestored"] {
            XCTAssertEqual(Set(by[fn]?["inferred"] as? [String] ?? []), ["Env", "Fs"],
                           "\(fn): the Env is `Ctx.go` on the shadowing binding, which the stale entry "
                           + "was hiding; the Fs is the parameter's own dispatch after the scope")
        }
    }

    // ── the fabrications ───────────────────────────────────────────────────────────────────────────

    func testNoTypedBinderInheritsTheShadowedParamsProtocol() throws {
        let by = try scan(Self.sites, "Sites")
        for site in ["optBind", "closure", "tuple", "nestedFunc"] {
            XCTAssertNil(by["\(site)Shadow"],
                         "\(site): the binding is a `Ctx`; `j.run()` is not the protocol parameter's "
                         + "dispatch and must not be charged `RealJob.run`'s Fs")
            XCTAssertEqual(by["\(site)Shadow"]?["inferred"] as? [String] ?? [],
                           by["\(site)ShadowRenamed"]?["inferred"] as? [String] ?? [],
                           "\(site): the rename control — the only difference is the name collision")
        }
    }
}
