import XCTest
import Foundation

/// R97 — 22 OF 23 BINDER ARMS DROPPED THE TYPE, AND THE ONE THAT DID NOT IS WHY.
///
/// `rootOf` resolved a typealias in exactly two of its arms; `dealias` was then spelled by hand at
/// whichever binder site had happened to need it — ONE of the 23 sites that write `vars[…]`, the
/// `for case let x as T` arm. Every other spelling of "give this name a type" lost
/// `typealias FM = FileManager` outright, so thirteen binder forms certified a real file deletion PURE
/// while their plain-spelled twins one line away were charged `Fs`. That is this engine's signature
/// failure for the THIRD time (R33, R73), and §G's answer is not 22 more calls that can drift again.
///
/// THE FIXES ARE THREE AUTHORITIES, NOT TWENTY-TWO CALL SITES:
///   * `rootOf` dealiases its ANSWER once, in a wrapper. Every map the resolver reads — `vars`,
///     `fields`, `globalTypes`, `returns`, `tupleElem` — becomes alias-transparent by construction,
///     including producers not yet written. The two arms that used to spell `dealias` no longer do.
///   * `typeCastBinder` is the one routine that types a `case let x as T` binder, for all THREE
///     grammars that spell it (`for case`, a switch `case`, `if/guard case`). Two of them typed it
///     nowhere at all — plain-spelled, no alias needed.
///   * `leaveShadowScope` performs the TYPE restore for every scope, so a binder can be typed without
///     each statement kind having to own a save; `visit(ForStmtSyntax)` owning that alone is the
///     reason the other binders were left untyped rather than scoped.
///
/// GROUND TRUTH EXECUTED, EVERY ARM. The fixture below was written to an SPM package, `swift build`,
/// and RUN: a file was created for each arm beforehand and every single one was gone afterwards. This
/// matters more than usual here because the claim is an ABSENCE (§E3) — an omitted pure function and
/// an omitted effectful one are the same bytes, so a fixture that did not run would prove nothing.
///
/// EVERY ARM CARRIES ITS PLAIN-SPELLED TWIN, and the twins are the control that matters: they were
/// already correct, and a "fix" that changed them would be resolving MORE than the alias.
///
/// MEASURED RESIDUAL, not a claim of completeness: an UNANNOTATED closure parameter whose type comes
/// only from the closure VARIABLE's own function-type annotation (`let c: (FileManager) -> Void = { fm
/// in … }`) is still silent. It is in `testKnownResidualUnannotatedClosureParamIsStillSilent` as a
/// FAILING-BY-DESIGN expectation so the day it starts working, this file says so.
final class BinderTypeAuthorityProcessTests: XCTestCase {

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

    /// One unit per arm, so a UNION over the file can never hide a single arm's loss — the §E3 trap a
    /// previous fixture in this repo fell into by charging one effect class for both halves of a pair.
    private static let src = """
    import Foundation
    typealias FM = FileManager
    typealias FM2 = FM
    typealias PI = ProcessInfo
    typealias FMQ = Foundation.FileManager

    struct Holder { let fm: FM; let plain: FileManager }
    var g: FM = FM.default
    var gp: FileManager = FileManager.default
    func makeFM() -> FM { FM.default }
    func makeFMPlain() -> FileManager { FileManager.default }

    func a1(_ fm: FM)           { try? fm.removeItem(atPath: "/tmp/r97-a1") }
    func a1c(_ fm: FileManager) { try? fm.removeItem(atPath: "/tmp/r97-a1c") }
    func a2()  { let fm: FM = FM.default; try? fm.removeItem(atPath: "/tmp/r97-a2") }
    func a2c() { let fm: FileManager = FileManager.default; try? fm.removeItem(atPath: "/tmp/r97-a2c") }
    func a3()  { let fm = FM.default; try? fm.removeItem(atPath: "/tmp/r97-a3") }
    func a3c() { let fm = FileManager.default; try? fm.removeItem(atPath: "/tmp/r97-a3c") }
    func a4(_ xs: [FM]) { for fm: FM in xs { try? fm.removeItem(atPath: "/tmp/r97-a4") } }
    func a4c(_ xs: [FileManager]) { for fm: FileManager in xs { try? fm.removeItem(atPath: "/tmp/r97-a4c") } }
    func a5(_ o: FM?) { if let fm = o { try? fm.removeItem(atPath: "/tmp/r97-a5") } }
    func a5c(_ o: FileManager?) { if let fm = o { try? fm.removeItem(atPath: "/tmp/r97-a5c") } }
    func a6(_ o: FM?) { guard let fm = o else { return }; try? fm.removeItem(atPath: "/tmp/r97-a6") }
    func a6c(_ o: FileManager?) { guard let fm = o else { return }; try? fm.removeItem(atPath: "/tmp/r97-a6c") }
    func a7(_ any: Any)  { let fm = any as! FM; try? fm.removeItem(atPath: "/tmp/r97-a7") }
    func a7c(_ any: Any) { let fm = any as! FileManager; try? fm.removeItem(atPath: "/tmp/r97-a7c") }
    func a8()  { let fm = makeFM(); try? fm.removeItem(atPath: "/tmp/r97-a8") }
    func a8c() { let fm = makeFMPlain(); try? fm.removeItem(atPath: "/tmp/r97-a8c") }
    func a9(_ h: Holder)  { try? h.fm.removeItem(atPath: "/tmp/r97-a9") }
    func a9c(_ h: Holder) { try? h.plain.removeItem(atPath: "/tmp/r97-a9c") }
    func a10()  { try? g.removeItem(atPath: "/tmp/r97-a10") }
    func a10c() { try? gp.removeItem(atPath: "/tmp/r97-a10c") }
    func a11(_ fm: FM2) { try? fm.removeItem(atPath: "/tmp/r97-a11") }
    func a12(_ fm: FMQ) { try? fm.removeItem(atPath: "/tmp/r97-a12") }
    func a13(_ xs: [Any]) { for case let fm as FM in xs { try? fm.removeItem(atPath: "/tmp/r97-a13") } }
    func a14(_ x: Any)  { switch x { case let fm as FM: try? fm.removeItem(atPath: "/tmp/r97-a14"); default: break } }
    func a14c(_ x: Any) { switch x { case let fm as FileManager: try? fm.removeItem(atPath: "/tmp/r97-a14c"); default: break } }
    func a15(_ x: Any)  { if case let fm as FM = x { try? fm.removeItem(atPath: "/tmp/r97-a15") } }
    func a15c(_ x: Any) { if case let fm as FileManager = x { try? fm.removeItem(atPath: "/tmp/r97-a15c") } }
    func a16(_ x: Any)  { if let fm = x as? FM { try? fm.removeItem(atPath: "/tmp/r97-a16") } }
    func a16c(_ x: Any) { if let fm = x as? FileManager { try? fm.removeItem(atPath: "/tmp/r97-a16c") } }
    func a17()  { let c: (FM) -> Void = { (fm: FM) in try? fm.removeItem(atPath: "/tmp/r97-a17") }; c(FM.default) }
    func a17c() { let c: (FileManager) -> Void = { (fm: FileManager) in try? fm.removeItem(atPath: "/tmp/r97-a17c") }; c(FileManager.default) }
    func a17d() { let fm = FileManager.default; let c: () -> Void = { try? fm.removeItem(atPath: "/tmp/r97-a17d") }; c() }
    func a18()  { for fm in [FileManager.default] { try? fm.removeItem(atPath: "/tmp/r97-a18") } }
    func a18c() { let fms: [FileManager] = [FileManager.default]; for fm in fms { try? fm.removeItem(atPath: "/tmp/r97-a18c") } }
    func a19(_ pi: PI) { _ = pi.environment["R97"] }
    func a19c(_ pi: ProcessInfo) { _ = pi.environment["R97"] }

    let h = Holder(fm: FM.default, plain: FileManager.default)
    a1(FM.default); a1c(FileManager.default); a2(); a2c(); a3(); a3c()
    a4([FM.default]); a4c([FileManager.default]); a5(FM.default); a5c(FileManager.default)
    a6(FM.default); a6c(FileManager.default); a7(FM.default); a7c(FileManager.default)
    a8(); a8c(); a9(h); a9c(h); a10(); a10c(); a11(FM.default); a12(FileManager.default)
    a13([FM.default]); a14(FM.default); a14c(FileManager.default); a15(FM.default); a15c(FileManager.default)
    a16(FM.default); a16c(FileManager.default); a17(); a17c(); a17d(); a18(); a18c()
    a19(ProcessInfo.processInfo); a19c(ProcessInfo.processInfo)
    """

    /// THE ALIAS ARMS — every one was ABSENT before the `rootOf` wrapper landed. Listed by NAME so a
    /// failure says which spelling regressed, not "a count changed".
    func testEveryAliasedBinderSpellingResolves() throws {
        let by = try scan(Self.src, "R97")
        let fsArms = ["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "a10",
                      "a11", "a12", "a13", "a14", "a15", "a16", "a17", "a18"]
        for a in fsArms {
            XCTAssertEqual((by[a]?["inferred"] as? [String]).map(Set.init), ["Fs"],
                           "\(a): aliased binder lost its type — the deletion it performs is silent")
        }
        XCTAssertEqual((by["a19"]?["inferred"] as? [String]).map(Set.init), ["Env"],
                       "a19: a SECOND effect class through the same mechanism, so `Fs` cannot be the only thing measured")
    }

    /// THE CONTROLS. Every plain-spelled twin was ALREADY correct, and must be untouched — a change
    /// here means the fix resolved something other than the alias.
    func testPlainSpelledTwinsAreUnchanged() throws {
        let by = try scan(Self.src, "R97")
        for a in ["a1c", "a2c", "a3c", "a4c", "a5c", "a6c", "a7c", "a8c", "a9c", "a10c",
                  "a16c", "a17d", "a18c"] {
            XCTAssertEqual((by[a]?["inferred"] as? [String]).map(Set.init), ["Fs"], "\(a): control moved")
        }
        XCTAssertEqual((by["a19c"]?["inferred"] as? [String]).map(Set.init), ["Env"], "a19c: control moved")
    }

    /// The three siblings that were broken WITHOUT any alias — the row's point that this is a binder
    /// class, not an alias bug. Each has a working spelling one line away (`a13`, `a16c`, `a17d`,
    /// `a18c`) that is pinned above.
    func testPlainSpelledSiblingsThatNeverHadATypeAtAll() throws {
        let by = try scan(Self.src, "R97")
        for a in ["a14c", "a15c", "a17c"] {
            XCTAssertEqual((by[a]?["inferred"] as? [String]).map(Set.init), ["Fs"],
                           "\(a): plain-spelled and silent — no typealias is involved in this arm")
        }
    }

    /// A TYPE MUST NOT LEAK PAST THE CONSTRUCT THAT BOUND IT. The new binders write `vars`, which is
    /// function-wide, so the scoping is the whole safety argument for them — and this is the direction
    /// (fabrication) that the previous audit of this file measured in only one direction and got wrong.
    /// `after*` reuses the binder's name on an unrelated value; charging it would be a fabrication.
    func testCastBinderTypeDoesNotLeakPastItsScope() throws {
        // The binder's body must be INERT. The first draft of this control used
        // `_ = fm.currentDirectoryPath`, which is itself an `Fs` READ on a correctly-typed
        // `FileManager` — so all three rows failed, the fixture was wrong, and reading the failure as
        // a leak would have produced a "finding" about working code. `direct: ["Fs"], fs: ["read"]`
        // in the raw report is what said so.
        let src = """
        import Foundation
        struct Inert { func removeItem(atPath: String) {} }
        func afterSwitch(_ x: Any, _ later: Inert) {
            switch x { case let fm as FileManager: _ = fm; default: break }
            later.removeItem(atPath: "/tmp/leak-a")
        }
        func afterIfCase(_ x: Any, _ later: Inert) {
            if case let fm as FileManager = x { _ = fm }
            later.removeItem(atPath: "/tmp/leak-b")
        }
        func afterForCase(_ xs: [Any], _ later: Inert) {
            for case let fm as FileManager in xs { _ = fm }
            later.removeItem(atPath: "/tmp/leak-c")
        }
        // the hardest one: the case binder SHADOWS a parameter, and the parameter is used after
        func shadowSwitch(_ x: Any, _ fm: Inert) {
            switch x { case let fm as FileManager: _ = fm; default: break }
            fm.removeItem(atPath: "/tmp/leak-d")
        }
        // the CHARGED control: the same name, still in scope, really is a FileManager
        func insideStillWorks(_ x: Any) {
            if case let fm as FileManager = x { try? fm.removeItem(atPath: "/tmp/leak-e") }
        }
        afterSwitch(1, Inert()); afterIfCase(1, Inert()); afterForCase([1], Inert())
        shadowSwitch(1, Inert()); insideStillWorks(1)
        """
        let by = try scan(src, "R97Leak")
        for a in ["afterSwitch", "afterIfCase", "afterForCase", "shadowSwitch"] {
            XCTAssertNil(by[a],
                         "\(a): the case binder's type leaked onto a later value — fabrication (\(by[a] ?? [:]))")
        }
        XCTAssertEqual((by["insideStillWorks"]?["inferred"] as? [String]).map(Set.init), ["Fs"],
                       "the scoping must not cost the binding INSIDE its own scope")
    }

    /// An inline array literal only yields an element type when EVERY element agrees. A heterogeneous
    /// literal must stay untyped rather than pick one — the never-guess direction.
    func testHeterogeneousArrayLiteralStaysUntyped() throws {
        let src = """
        import Foundation
        struct Inert { func removeItem(atPath: String) {} }
        func mixed(_ i: Inert) { for x in [FileManager.default, i] { x.removeItem(atPath: "/tmp/het") } }
        func uniform() { for x in [FileManager.default] { try? x.removeItem(atPath: "/tmp/uni") } }
        func emptyLit() { for x in [] as [Any] { _ = x } }
        mixed(Inert()); uniform(); emptyLit()
        """
        let by = try scan(src, "R97Arr")
        XCTAssertFalse(((by["mixed"]?["inferred"] as? [String]) ?? []).contains("Fs"),
                       "a heterogeneous literal must not be typed from one of its elements")
        XCTAssertEqual((by["uniform"]?["inferred"] as? [String]).map(Set.init), ["Fs"])
    }

    /// ATTACKING THIS COMMIT'S OWN ASSERTION, which is what `assert-audit` flags those lines for.
    /// "Alias-transparent by construction" is a claim about everything reached THROUGH `rootOf`; the
    /// container maps (`arrayElem`, `dictElem`, `fieldArrayElem`, `tupleElem`) reach it via the binder
    /// they type, so they are covered — measured here rather than reasoned. `callAsFunction` was the one
    /// reader that consults a type map WITHOUT going through `rootOf`, and it was silent on an aliased
    /// local type until this row was written. Ground truth EXECUTED for all seven.
    func testAliasThroughContainerMapsResolves() throws {
        let src = """
        import Foundation
        typealias FM = FileManager
        struct H { let xs: [FM]; let m: [String: FM]; let t: (a: FM, b: Int) }
        func b1(_ xs: [FM])           { for fm in xs { try? fm.removeItem(atPath: "/tmp/b1") } }
        func b2(_ m: [String: FM])    { for (_, fm) in m { try? fm.removeItem(atPath: "/tmp/b2") } }
        func b3(_ h: H)               { for fm in h.xs { try? fm.removeItem(atPath: "/tmp/b3") } }
        func b4(_ t: (a: FM, b: Int)) { try? t.a.removeItem(atPath: "/tmp/b4") }
        func b5() { let xs: [FM] = [FM.default]; for fm in xs { try? fm.removeItem(atPath: "/tmp/b5") } }
        struct Caller { func callAsFunction() { try? FileManager.default.removeItem(atPath: "/tmp/b6") } }
        typealias C = Caller
        func b6(_ c: C) { c() }
        func b6c(_ c: Caller) { c() }
        b1([FM.default]); b2(["k": FM.default]); b3(H(xs: [FM.default], m: [:], t: (FM.default, 1)))
        b4((FM.default, 1)); b5(); b6(Caller()); b6c(Caller())
        """
        let by = try scan(src, "R97Cont")
        for a in ["b1", "b2", "b3", "b4", "b5", "b6", "b6c"] {
            XCTAssertEqual((by[a]?["inferred"] as? [String]).map(Set.init), ["Fs"],
                           "\(a): a type map's alias was not resolved")
        }
    }

    /// A MEASURED RESIDUAL, stated as a residual. `{ fm in … }` with the type only on the closure
    /// VARIABLE is still silent — executed ground truth, so it is a real under-report and not a
    /// theoretical one. Written as an expectation so that closing it turns this row red and forces the
    /// note to be updated, instead of the gap quietly outliving its own comment.
    func testKnownResidualUnannotatedClosureParamIsStillSilent() throws {
        let src = """
        import Foundation
        func r() { let c: (FileManager) -> Void = { fm in try? fm.removeItem(atPath: "/tmp/r97-a17e") }; c(FileManager.default) }
        r()
        """
        let by = try scan(src, "R97Res")
        XCTAssertNil(by["r"], """
            RESIDUAL CLOSED — `let c: (FileManager) -> Void = { fm in … }` now resolves. \
            Good news: delete this test, and update the note in this file's doc comment and SOUNDNESS R97.
            """)
    }
}
