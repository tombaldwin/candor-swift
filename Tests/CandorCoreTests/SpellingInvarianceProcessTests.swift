import XCTest
import Foundation

/// TWO CHAINED-BOUNDARY DEFECTS FOUND BY conformance PART 24 (split-invariance), and ONE reason both
/// survived PARTs 18–22: **every hand-written fixture picked ONE SPELLING** of the program it tested.
/// (candor-spec `SCAN-BOUNDARY-WORK-QUEUE.md` §3c.)
///
/// DEFECT 1 — a chained dependency type's PROPERTY ACCESSOR read was silent-pure. The dep's report
/// carries `L.v ['Fs'] unitKind:accessor` under exactly the key the consumer needs; every reader-side
/// branch in the property-read path was gated on `localTypes`/`localProtocols`, so the read fell off the
/// end of the chain and was never recorded at all. PART 19's swift fixture reads a module-level GLOBAL,
/// which IS modelled — so the accessor spelling had simply never been asked.
///
/// DEFECT 2 — the UNBOUND FACTORY. `let c = build(); c.fetch()` resolved and `let t = getDyn(); t.run()`
/// disclosed `Unknown`, while `build().fetch()` and `getDyn().run()` — the same programs with no
/// intermediate binding — were both ABSENT. That is a hole in a SHIPPED guard, not an unattempted
/// precision gap: PART 21's ruling is that a key which could not be formed must not read pure, and
/// PART 21's fixture binds the factory result.
///
/// THE FILE IS ORGANISED AROUND SPELLINGS, not around defects. Each subject appears in every spelling
/// the language offers — accessor: lazy / computed / static, factory: bound / unbound — because a single
/// spelling is exactly what let both of these ship. Under ⟨0.21⟩ an absent-but-analysed function is a
/// positive purity CLAIM, so "absent" below is an assertion about what candor SAYS, not a gap.
///
/// EVERY ROW HAS A SINGLE-PACKAGE CONTROL. The one-package arm is the oracle for the chained arm (the
/// PART 24 self-differential): without it, a chained row proves nothing about whether the boundary is
/// what broke.
///
/// AND EVERY FIX HAS ITS MIRROR CONTROL, because the measured way a silent-under-report fix goes wrong
/// in this project is by over-firing into a fabrication:
///   * `shadowAcc` — a LOCAL type whose accessor is genuinely pure, sharing its NAME with a dependency
///     type whose same-named accessor is `Fs`. It must stay pure. (Mutation: let the local-type branch
///     also write `propertyExternal` and this row fabricates `Fs`.)
///   * `pureAcc` / `storedAcc` — a dependency accessor the dep report shows as pure, and a dependency
///     STORED property, which has no accessor unit at all. Both must stay pure.
///   * `unboundStdlib` / `unboundNested` — `max(a,b).advanced(by:)` and a call on a NESTED local
///     `func`'s result. Neither is a dependency reach and neither may acquire a hedge. (Mutation: drop
///     the `localFreeFns`/`enclosingMembers`/`localFuncs`/`PURE_STDLIB_FREE_FNS` carve-outs from
///     `depFactoryCallee` and both rows acquire `Unknown`.)
final class SpellingInvarianceProcessTests: XCTestCase {

    /// The dep half. `SHADOW` is substituted out of the single-package arm: the collision control only
    /// exists ACROSS the boundary, and declaring both `Shadow`s in one target would make the control
    /// arm test a different program.
    private static let depSource = """
    import Foundation

    // ── DEFECT 1 subjects: an accessor unit, in all three spellings ────────────────────────────────
    public struct L {
        public init() {}
        public lazy var v: Int = { _ = FileManager.default.contents(atPath: "/dep-lazy"); return 1 }()
    }
    public struct C {
        public init() {}
        public var w: Int { _ = ProcessInfo.processInfo.environment["DEP_COMPUTED"]; return 2 }
    }
    public enum SC {
        public static var s: Int { _ = ProcessInfo.processInfo.environment["DEP_STATIC"]; return 3 }
    }

    // ── DEFECT 1 mirror controls: a dependency accessor that is genuinely PURE, and a STORED
    //    property, which has no accessor unit at all. Neither has an entry in the dep report, so the
    //    join self-filters — that is the property being pinned, not an accident of the fixture.
    public struct P {
        public init() {}
        public var pure: Int { return 4 }
    }
    public struct SP {
        public init() {}
        public var stored: Int = 5
    }

    SHADOW

    // ── METATYPE control: a dependency `extension String` with an EFFECTFUL initializer, which is
    //    exactly the shape the real-code A/B caught (swift-syntax publishes `SwiftSyntax#String.init`).
    //    A consumer writing `.map(String.init)` means the STDLIB's initializer, and `.init` is not a
    //    property accessor in any case, so no accessor unit may answer it.
    public extension String {
        init(tagged v: Int) {
            _ = FileManager.default.contents(atPath: "/dep-string-init")
            self.init(v)
        }
    }

    // ── DEFECT 2 subjects ──────────────────────────────────────────────────────────────────────────
    public protocol Tsk { func run() }
    public struct T0: Tsk {
        public init() {}
        public func run() { _ = FileManager.default.contents(atPath: "/dep-run") }
    }
    // NO `typeSurface.returns` entry: an existential is not a plain nominal return, so the consumer
    // cannot determine the receiver and must fall to the PART 21 disclosure.
    public func getDyn() -> any Tsk { return T0() }

    public struct Cl {
        public init() {}
        public func fetch() { _ = FileManager.default.contents(atPath: "/dep-fetch") }
    }
    // A plain nominal return, so this one IS determined through `typeSurface.returns`.
    public func build() -> Cl { return Cl() }
    """

    /// The dependency type that COLLIDES with a local one. Present only in the chained arm.
    private static let shadowDecl = """
    public struct Shadow {
        public init() {}
        public var val: Int { _ = FileManager.default.contents(atPath: "/dep-shadow"); return 6 }
    }
    """

    private static let appSource = """
    IMPORT
    // A LOCAL `Shadow` whose accessor is PURE, sharing its name with the dependency's effectful one.
    struct Shadow { var val: Int { return 0 } }
    // A LOCAL type with a genuinely effectful accessor — the row that must keep working.
    struct LocalEff { var e: Int { _ = FileManager.default.contents(atPath: "/app-local"); return 1 } }

    // ── DEFECT 1: the same read, three spellings ───────────────────────────────────────────────────
    public func lazyAcc(_ l: inout L) -> Int { return l.v }
    public func computedAcc(_ c: C) -> Int { return c.w }
    public func staticAcc() -> Int { return SC.s }

    // ── DEFECT 1 mirror controls ───────────────────────────────────────────────────────────────────
    public func pureAcc(_ p: P) -> Int { return p.pure }
    public func storedAcc(_ s: SP) -> Int { return s.stored }
    public func shadowAcc(_ s: Shadow) -> Int { return s.val }
    public func localEffAcc(_ x: LocalEff) -> Int { return x.e }
    public func stringInitRef(_ xs: [Substring]) -> [String] { return xs.map(String.init) }

    // ── DEFECT 2: the same call, bound and unbound ─────────────────────────────────────────────────
    public func boundFactory() { let c = build(); c.fetch() }
    public func unboundFactory() { build().fetch() }
    public func boundDyn() { let t = getDyn(); t.run() }
    public func unboundDyn() { getDyn().run() }

    // ── DEFECT 2 mirror controls: neither receiver is a dependency reach ───────────────────────────
    public func unboundStdlib(_ a: Int, _ b: Int) -> Int { return max(a, b).advanced(by: 1) }
    public func unboundNested() -> Int {
        func mkNested() -> Int { return 7 }
        return mkNested().advanced(by: 1)
    }
    """

    /// (root, dep, app, ctl) — the split pair plus the ONE-PACKAGE control arm that is the oracle.
    private func makeFixture() throws -> (root: URL, dep: URL, app: URL, ctl: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-spelling-\(UUID().uuidString)")
        let dep = root.appendingPathComponent("deplib")
        let app = root.appendingPathComponent("app")
        let ctl = root.appendingPathComponent("ctl")
        let fm = FileManager.default
        for (d, t) in [(dep, "DepLib"), (app, "App"), (ctl, "Ctl")] {
            try fm.createDirectory(at: d.appendingPathComponent("Sources/\(t)"), withIntermediateDirectories: true)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "DepLib", targets: [.target(name: "DepLib")])
        """.write(to: dep.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.replacingOccurrences(of: "SHADOW", with: Self.shadowDecl)
            .write(to: dep.appendingPathComponent("Sources/DepLib/Lib.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [.package(path: "../deplib")],
            targets: [.target(name: "App", dependencies: [.product(name: "DepLib", package: "deplib")])]
        )
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "import Foundation\nimport DepLib")
            .write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Ctl", targets: [.target(name: "Ctl")])
        """.write(to: ctl.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.replacingOccurrences(of: "SHADOW", with: "")
            .write(to: ctl.appendingPathComponent("Sources/Ctl/Lib.swift"), atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "import Foundation")
            .write(to: ctl.appendingPathComponent("Sources/Ctl/App.swift"), atomically: true, encoding: .utf8)
        return (root, dep, app, ctl)
    }

    private func fns(_ url: URL) throws -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        let obj = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        for case let f as [String: Any] in (obj["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { out[n] = f }
        }
        return out
    }

    /// Both arms, each written to a FRESH output path that is deleted first — a stale artifact from a
    /// crashed run otherwise reads as a flattering result (standing bar item 7).
    private func scanBothArms() throws -> (dep: [String: [String: Any]],
                                           chained: [String: [String: Any]],
                                           control: [String: [String: Any]],
                                           root: URL) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let (root, dep, app, ctl) = try makeFixture()
        let fm = FileManager.default

        let depOut = root.appendingPathComponent("dep-r.DepLib.Swift.json")
        try? fm.removeItem(at: depOut)
        XCTAssertEqual(try ProcessHarness.run(bin, [dep.path, "--out", root.appendingPathComponent("dep-r").path]).code, 0)

        let appOut = root.appendingPathComponent("app-r.App.Swift.json")
        try? fm.removeItem(at: appOut)
        XCTAssertEqual(try ProcessHarness.run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                                             env: ["CANDOR_DEPS": depOut.path]).code, 0)

        let ctlOut = root.appendingPathComponent("ctl-r.Ctl.Swift.json")
        try? fm.removeItem(at: ctlOut)
        XCTAssertEqual(try ProcessHarness.run(bin, [ctl.path, "--out", root.appendingPathComponent("ctl-r").path]).code, 0)

        return (try fns(depOut), try fns(appOut), try fns(ctlOut), root)
    }

    private func eff(_ m: [String: [String: Any]], _ n: String) -> Set<String> {
        Set(m[n]?["inferred"] as? [String] ?? [])
    }

    // ── DEFECT 1 ───────────────────────────────────────────────────────────────────────────────────

    /// The producer half, asserted separately so a consumer failure cannot be misread as a missing
    /// witness: the key the consumer needs is already on the wire, and has been all along.
    func testDepReportAlreadyCarriesTheAccessorUnits() throws {
        let (dep, _, _, root) = try scanBothArms()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(dep["L.v"]?["unitKind"] as? String, "accessor")
        XCTAssertEqual(dep["C.w"]?["unitKind"] as? String, "accessor")
        XCTAssertEqual(dep["SC.s"]?["unitKind"] as? String, "accessor")
        XCTAssertTrue(eff(dep, "L.v").contains("Fs"), "got \(dep["L.v"] ?? [:])")
        XCTAssertTrue(eff(dep, "C.w").contains("Env"), "got \(dep["C.w"] ?? [:])")
        XCTAssertTrue(eff(dep, "SC.s").contains("Env"), "got \(dep["SC.s"] ?? [:])")
        XCTAssertNil(dep["P.pure"], "a PURE accessor is absent from the report (§2 rule 3) — which is "
                     + "why the consumer-side join self-filters rather than needing a purity check")
        XCTAssertNil(dep["SP.stored"], "a STORED property has no accessor unit at all")
    }

    /// ALL THREE SPELLINGS of the accessor read, chained, each against its one-package control.
    func testDependencyAccessorReadChargesTheReaderInEverySpelling() throws {
        let (_, chained, control, root) = try scanBothArms()
        defer { try? FileManager.default.removeItem(at: root) }
        for (fn, effect, spelling) in [("lazyAcc", "Fs", "a `lazy var`"),
                                       ("computedAcc", "Env", "a plain computed `var`"),
                                       ("staticAcc", "Env", "a `static var` read off the type name")] {
            XCTAssertTrue(eff(control, fn).contains(effect),
                          "CONTROL (one package): \(spelling) read is \(effect). Without this the "
                          + "chained row proves nothing; got \(control[fn] ?? [:])")
            XCTAssertTrue(eff(chained, fn).contains(effect),
                          "\(fn): \(spelling) accessor on a CHAINED dependency type must match its "
                          + "one-package control. The dep report carries the unit under the same key "
                          + "the consumer forms; got \(chained[fn] ?? [:])")
        }
    }

    /// THE MIRROR. The new join must not charge anything it cannot reach.
    func testAccessorJoinDoesNotFireWhereItMustNot() throws {
        let (_, chained, control, root) = try scanBothArms()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(chained["shadowAcc"] == nil,
                      "shadowAcc reads a LOCAL `Shadow` whose `val` is PURE. The dependency declares a "
                      + "`Shadow.val` that is Fs, and the local type must resolve to its OWN unit — "
                      + "this is why the candidate set is separate from `propertyEdges` rather than "
                      + "the local branch also writing it; got \(chained["shadowAcc"] ?? [:])")
        XCTAssertTrue(chained["pureAcc"] == nil,
                      "pureAcc reads a dependency accessor the dep report shows as pure (absent), so "
                      + "the join must add nothing; got \(chained["pureAcc"] ?? [:])")
        XCTAssertTrue(chained["storedAcc"] == nil,
                      "storedAcc reads a dependency STORED property — there is no accessor unit to "
                      + "inherit; got \(chained["storedAcc"] ?? [:])")
        XCTAssertTrue(chained["stringInitRef"] == nil,
                      "`xs.map(String.init)` names the STDLIB initializer, and `.init` is a metatype "
                      + "spelling that no accessor unit can answer. The dependency's own "
                      + "`extension String { init(tagged:) }` is Fs, and this row is the one the "
                      + "real-code A/B caught against swift-syntax; got \(chained["stringInitRef"] ?? [:])")
        XCTAssertTrue(eff(control, "localEffAcc").contains("Fs"))
        XCTAssertEqual(eff(chained, "localEffAcc"), eff(control, "localEffAcc"),
                       "a LOCAL effectful accessor is unaffected by the boundary")
    }

    // ── DEFECT 2 ───────────────────────────────────────────────────────────────────────────────────

    /// BOUND AND UNBOUND MUST AGREE, and the assertion is written as an EQUALITY between the two
    /// spellings rather than as two independent expectations — that is the invariant that broke, and
    /// stating it directly is what stops a future change from fixing one spelling and not the other.
    func testFactoryCallAgreesBoundAndUnbound() throws {
        let (_, chained, control, root) = try scanBothArms()
        defer { try? FileManager.default.removeItem(at: root) }

        // DETERMINED: `build` publishes a plain nominal return, so both spellings resolve to `Cl.fetch`.
        XCTAssertTrue(eff(control, "unboundFactory").contains("Fs"),
                      "CONTROL (one package): `build().fetch()` is Fs; got \(control["unboundFactory"] ?? [:])")
        XCTAssertTrue(eff(chained, "unboundFactory").contains("Fs"),
                      "`build().fetch()` must resolve through `typeSurface.returns` exactly as "
                      + "`let c = build(); c.fetch()` does; got \(chained["unboundFactory"] ?? [:])")
        XCTAssertEqual(eff(chained, "unboundFactory"), eff(chained, "boundFactory"),
                       "the intermediate binding is not part of the program's meaning")

        // DISCLOSED: `getDyn` returns an existential, so no key can be formed and PART 21's ruling
        // applies to BOTH spellings — a hedge, never silence.
        XCTAssertTrue(eff(control, "unboundDyn").contains("Fs"),
                      "CONTROL (one package): `getDyn().run()` reaches T0.run; got \(control["unboundDyn"] ?? [:])")
        XCTAssertTrue(eff(chained, "unboundDyn").contains("Unknown"),
                      "`getDyn().run()` could not form a key, so it must DISCLOSE — being absent is a "
                      + "⟨0.21⟩ purity claim about a function that performs Fs; got \(chained["unboundDyn"] ?? [:])")
        XCTAssertEqual(eff(chained, "unboundDyn"), eff(chained, "boundDyn"),
                       "the bound spelling has disclosed since PART 21; the unbound one must match")
        XCTAssertEqual(Set((chained["unboundDyn"]?["unknownWhy"] as? [String]) ?? []),
                       Set((chained["boundDyn"]?["unknownWhy"] as? [String]) ?? []),
                       "…including the REASON, so a `deny E Unknown[<class>]` gate treats the two "
                       + "spellings identically")
    }

    /// THE MIRROR. A receiver that is not a dependency reach must not acquire a hedge — the guard that
    /// stops it is shared with the bound spelling (`depFactoryCallee`), which is the point.
    func testUnboundReceiverGuardDoesNotFireOnLocalOrStdlibCalls() throws {
        let (_, chained, _, root) = try scanBothArms()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(chained["unboundStdlib"] == nil,
                      "`max(a, b).advanced(by: 1)` is a PROVEN-PURE stdlib value call, not a "
                      + "dependency factory. A hedge that is wrong every time teaches a consumer to "
                      + "ignore the channel; got \(chained["unboundStdlib"] ?? [:])")
        XCTAssertTrue(chained["unboundNested"] == nil,
                      "the receiver is a NESTED local `func`'s result — `localFuncs` is the conjunct "
                      + "that excludes it; got \(chained["unboundNested"] ?? [:])")
    }
}
