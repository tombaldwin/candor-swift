import XCTest
import Foundation

/// SOUNDNESS R584 — THE **CLASS** HALF OF TYPE-RECEIVER DISPATCH WAS SILENT, AND EVERY PROTOCOL
/// SPELLING OF THE SAME CALL ALREADY RESOLVED.
///
/// [[R563]] closed the protocol half — a generic parameter used as a TYPE receiver reaches the bounded
/// conformer CHA. The class half was never asked (§9: an audit scoped to the shape in hand), and it was
/// silent in every spelling, over a body that executes `URLSession.dataTask`:
///
///     func f<P: EffBase>(_ t: P.Type) { P.make() }         ABSENT   deny Net exit 0   pure exit 0
///     func f<P: EffBase>(_ t: P.Type) { t.make() }         ABSENT   deny Net exit 0   pure exit 0
///     struct Box<P: EffBase> { func go() { P.make() } }    ABSENT   deny Net exit 0   pure exit 0
///     func f(_ t: CBase.Type) { t.validate() }             ABSENT   deny Net exit 0   pure exit 0
///     func f(_ c: Cmd) { type(of: c).validate() }          ABSENT   deny Net exit 0   pure exit 0
///     ── the PROTOCOL twin of each ──                      [Net]    deny Net exit 1   ← the control
///     ── `EffBase.make()`, class named LITERALLY ──        [Net]    deny Net exit 1   ← the control
///
/// **THE TWO CONTROLS ARE WHAT MAKE THIS A DEFECT RATHER THAN A DESIGN.** Held constant: one package,
/// one file, one class hierarchy, one sink, one call spelling per row. The only variable is how the
/// RECEIVER is written — and the literal spelling of the very same call already resolves to the base's
/// own unit plus, through the Driver's `subtypesOf` fan-out, every local subclass override.
///
/// ── THE RULING THIS FIX MAKES, STATED RATHER THAN INHERITED ─────────────────────────────────────
/// A CLASS HIERARCHY IS NOT A PROTOCOL CONFORMER SET, so the two paths are deliberately NOT unified.
/// The generic/metatype spelling resolves to **exactly what the literal spelling resolves to**: the
/// statically-named class's own implementation UNIONED with every local subclass override, with no
/// `chaWithinBound` ≤12 cap and no `Unknown` hedge — because the literal spelling has neither, and
/// introducing one here would make one program answer two ways depending on how its receiver was
/// spelled (§F1.3/§G). ⟨0.35⟩ licenses completing the dispatch OR disclosing it and forbids only
/// silence; this completes it.
///   · `final` needs no case: a final class has no subtypes, so the fan-out is a no-op.
///   · `static` vs `class` needs none either: a `static` member cannot be overridden, so no subclass
///     declares the same unit, and one that shadows it by NAME is unioned — the safe direction.
///   · THE RESIDUAL, stated not hedged: a subclass declared OUTSIDE the scan is not in `subtypesOf` and
///     its override is not charged. That is the pre-existing bounded-CHA contract the literal spelling
///     already carries; this row does not introduce it and does not close it.
///
/// ── §1b CALIBRATION ─────────────────────────────────────────────────────────────────────────────
/// Every positive assertion below FAILS under `CANDOR_R584_OFF=1`, which degrades the resolution to
/// exactly the pre-fix answer (measured byte-identical on the two fixtures). Run
/// `CANDOR_R584_OFF=1 swift test --filter ClassTypeReceiverDispatch` to see the red; the switch exists
/// so the calibration cannot rot into a test that passes with and without the fix (§A).
///
/// Every fixture below `swift build`s AND RUNS (§E3) — the executed programs print `RAN` after driving
/// each arm through `sink`, so `[Net]` is ground truth and not an inference from the engine's own report.
final class ClassTypeReceiverDispatchProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: ClassTypeReceiverDispatchProcessTests.self)
    }

    private func run(_ binary: URL, _ args: [String], env: [String: String] = [:]) throws
        -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT",
                  "CANDOR_WORKSPACE_CHAIN"] {
            environment.removeValue(forKey: k)
        }
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let exited = ProcessHarness.exitLatch(p)
        try p.run()
        let outData = ProcessHarness.drain(outPipe)
        let errData = ProcessHarness.drain(errPipe)
        exited.wait()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self),
                p.terminationStatus)
    }

    private static let SINK = "_ = URLSession.shared.dataTask(with: URL(string: \"http://h\")!)"

    /// Verbatim from `fx-class`, which compiles and runs (`A 1 / B 1 / C 1 / D 1 / E 0 1 / F 1 / RAN`).
    private static var classSource: String {
        """
        import Foundation
        func sink(_ t: String) -> Int { \(SINK); return 1 }
        class EffBase { class func make() -> Int { return 0 } }
        final class EffSub: EffBase { override class func make() -> Int { return sink("EffSub") } }

        protocol Pr { static func make() -> Int }
        struct PurePr: Pr { static func make() -> Int { return 0 } }

        // A — function-level generic bound to a local CLASS, the type parameter IS the receiver
        func fnClassBound<P: EffBase>(_ t: P.Type) -> Int { return P.make() }
        // B — the metatype-parameter spelling of the same call
        func fnClassMeta<P: EffBase>(_ t: P.Type) -> Int { return t.make() }
        // C — the ENCLOSING TYPE's bound is the class (R550's shape, class instead of protocol)
        struct ClassBox<P: EffBase> { init() {}; func go() -> Int { return P.make() } }
        // D — R580's shadowing shape with a CLASS inner bound: the function bound must DISPLACE the
        //     enclosing type's, so this charges EffBase's hierarchy and NOT `Pr`'s conformers.
        struct ProtoBox<P: Pr> {
            init() {}
            func shadowClass<P: EffBase>(_ t: P.Type) -> Int { return P.make() }
        }
        // CONTROL — the concrete spellings, which resolved before this change and must still
        func concreteStatic() -> Int { return EffBase.make() }
        func concreteMeta(_ t: EffBase.Type) -> Int { return t.make() }
        // CONTROL — the PROTOCOL-bound twin of A, which R563 fixed
        protocol EffPrP { static func make() -> Int }
        struct EffPrC: EffPrP { static func make() -> Int { return sink("EffPrC") } }
        func fnProtoBound<P: EffPrP>(_ t: P.Type) -> Int { return P.make() }
        """
    }

    /// Verbatim from `fx-meta`, which compiles and runs (`A 1 / B 1 / C 1 / RAN`).
    private static var metaSource: String {
        """
        import Foundation
        func msink(_ t: String) -> Int { \(SINK); return 1 }
        protocol Cmd { static func validate() -> Int }
        struct EffCmd: Cmd { static func validate() -> Int { return msink("EffCmd") } }
        class CBase { class func validate() -> Int { return 0 } }
        final class CSub: CBase { override class func validate() -> Int { return msink("CSub") } }

        // A — a CONCRETE PROTOCOL metatype parameter (swift-argument-parser's `ParsableCommand.Type`)
        func metaProto(_ t: Cmd.Type) -> Int { return t.validate() }
        // B — a CONCRETE CLASS metatype parameter: the shape R563 never asked
        func metaClass(_ t: CBase.Type) -> Int { return t.validate() }
        // C — generic bound to the protocol, metatype param (R563's covered shape)
        func metaGenericProto<P: Cmd>(_ t: P.Type) -> Int { return t.validate() }
        // D — `type(of:)`, the DYNAMIC-metatype spelling of the same dispatch
        func existentialCall(_ c: Cmd) -> Int { return type(of: c).validate() }
        """
    }

    /// The attack fixture: the six questions this widening could plausibly get wrong. It compiles and
    /// runs; the execution trace is quoted on each arm.
    private static var attackSource: String {
        """
        import Foundation
        func asink(_ t: String) -> Int { \(SINK); return 1 }
        func apure(_ t: String) -> Int { return 0 }

        // 1 — a class bound whose member NOTHING declares: must resolve to nothing, no Unknown flood
        class Empty { }
        func noSuchMember<P: Empty>(_ t: P.Type) -> Int { return apure("noSuchMember") }

        // 2 — a FUNCTION-TYPED `static let`: the LITERAL spelling hedges Unknown, so must this one
        class FnHolder { static let maker: (Int) -> Int = { _ in asink("FnHolder.maker") } }
        func fnTypedLiteral() -> Int { return FnHolder.maker(1) }
        func fnTypedGeneric<P: FnHolder>(_ t: P.Type) -> Int { return P.maker(1) }

        // 3 — a LOCAL BINDING SHADOWS the type-parameter spelling: runs `Holder.go`, which is PURE.
        //     Charging Net here would be a fabrication over a program that never dials.
        class Shadowed { class func go() -> Int { return asink("Shadowed.go") } }
        struct Holder { func go() -> Int { return apure("Holder.go") } }
        func shadowedByLocal<P: Shadowed>(_ t: P.Type) -> Int { let P = Holder(); return P.go() }

        // 4 — a FINAL class: no subtypes, so only its own implementation
        final class FinalEff { class func go() -> Int { return asink("FinalEff.go") } }
        func viaFinal(_ t: FinalEff.Type) -> Int { return t.go() }

        // 5 — a STRUCT metatype parameter (no hierarchy at all)
        struct StructEff { static func go() -> Int { return asink("StructEff.go") } }
        func viaStruct(_ t: StructEff.Type) -> Int { return t.go() }

        // 6 — a metatype of a NON-LOCAL type: nothing local to resolve, must not change
        func viaForeign(_ t: URLSession.Type) -> Int { _ = t.shared; return apure("viaForeign") }

        // 7 — the INIT spelling through a class bound
        class CtorBase { required init() { _ = asink("CtorBase.init") } }
        func viaInit<P: CtorBase>(_ t: P.Type) -> P { return P() }

        // 8 — an OVERRIDABLE `class func`, reached only through the metatype spelling. The BASE is pure
        //     and the SUBCLASS dials, so a fix that resolved only the statically-named class would read
        //     silent-pure over `viaOverridable(OverSub.self)`, which is what the program actually runs.
        class OverBase { class func go() -> Int { return apure("OverBase.go") } }
        final class OverSub: OverBase { override class func go() -> Int { return asink("OverSub.go") } }
        func viaOverridable(_ t: OverBase.Type) -> Int { return t.go() }

        // 9 — `type(of:)` on a CLASS-typed value
        func viaTypeOfClass(_ c: OverBase) -> Int { return type(of: c).go() }
        """
    }

    /// THE FABRICATION CONTROL. This fix WIDENS, so the direction it did not intend is charging an
    /// effect over a hierarchy that performs none. Every member here is pure and the package must gate
    /// clean under a blanket `deny`.
    private static var pureSource: String {
        """
        class QuietBase { class func tick() -> Int { return 1 } }
        final class QuietSub: QuietBase { override class func tick() -> Int { return 2 } }
        class OtherBase { class func tick() -> Int { return 3 } }
        func overQuiet<Q: QuietBase>(_ t: Q.Type) -> Int { return Q.tick() }
        func overQuietMeta(_ t: QuietBase.Type) -> Int { return t.tick() }
        func overOther(_ t: OtherBase.Type) -> Int { return t.tick() }
        """
    }

    /// THE GRDB SHAPE, and it is here because auditing this fix's OWN corpus diff found it. `type(of:)`
    /// on a value whose declared type is a GENERIC PARAMETER must dispatch through the parameter's
    /// BOUND, not through a same-named type that happens to exist in the package. GRDB has exactly this
    /// collision — `DAO<Record: MutablePersistableRecord>` beside `open class Record` — and without the
    /// bound mapping the dispatch landed on the class by NAME (§F1.7, a key two paths spell differently).
    private static var collisionSource: String {
        """
        import Foundation
        func gsink(_ t: String) -> Int { \(SINK); return 1 }
        protocol Named { static func label() -> Int }
        // a real type whose NAME is also used as a generic-parameter name below, and which is PURE
        enum Rec { static func label() -> Int { return 0 } }
        struct RealRec: Named { static func label() -> Int { return gsink("RealRec") } }
        struct Holder2<Rec: Named> {
            let r: Rec
            init(_ r: Rec) { self.r = r }
            func go() -> Int { return type(of: r).label() }
        }
        """
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func render(_ sources: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r584-\(UUID().uuidString)")
        try write(root.appendingPathComponent("Package.swift"), """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Solo", products: [.library(name: "Solo", targets: ["Solo"])],
            targets: [.target(name: "Solo")])
        """)
        for (name, text) in sources {
            try write(root.appendingPathComponent("Sources/Solo/\(name).swift"), text)
        }
        return root
    }

    private func scan(_ sources: [String: String]) throws -> ([String: [String: Any]], URL) {
        let bin = try binaryURL()
        let root = try render(sources)
        let out = root.appendingPathComponent("r")
        let r = try run(bin, [root.path, "--out", out.path])
        XCTAssertEqual(r.code, 0, "scan must succeed; stderr: \(r.err)")
        let doc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.Solo.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (doc?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return (by, root)
    }

    private func eff(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set(by[fn]?["inferred"] as? [String] ?? [])
    }

    private func gate(_ root: URL, _ policy: String) throws -> Int32 {
        let bin = try binaryURL()
        let p = root.appendingPathComponent("p.policy")
        try write(p, policy + "\n")
        return try run(bin, [root.path, "--out", root.appendingPathComponent("g").path,
                             "--policy", p.path]).code
    }

    // ── THE DEFECT ARMS ─────────────────────────────────────────────────────────────────────────

    /// The four class-bound spellings that were ABSENT. `pure <fn>` is asserted BESIDE `deny Net <fn>`
    /// because absence answers both the same way — a function missing from `functions[]` is certified
    /// pure under ⟨0.21⟩, so the two exits are one claim and both were 0.
    func testAClassBoundTypeReceiverCarriesTheHierarchysEffect() throws {
        let (by, root) = try scan(["cl": Self.classSource])
        for fn in ["fnClassBound", "fnClassMeta", "ClassBox.go", "concreteMeta"] {
            XCTAssertNotNil(by[fn], "\(fn) must not be ABSENT — under ⟨0.21⟩ that is a claim of purity")
            XCTAssertEqual(eff(by, fn), ["Net"],
                           "\(fn) runs EffSub.make, which reaches URLSession; got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net \(fn)"), 1, "`deny Net \(fn)` must catch it")
            XCTAssertEqual(try gate(root, "pure \(fn)"), 1, "`pure \(fn)` must catch it")
        }
    }

    /// The concrete CLASS metatype parameter and the `type(of:)` spelling, in the fixture whose protocol
    /// twin (`metaProto`) is the discriminating control.
    func testAConcreteClassMetatypeAndTypeOfBothResolve() throws {
        let (by, root) = try scan(["mt": Self.metaSource])
        for fn in ["metaClass", "existentialCall"] {
            XCTAssertNotNil(by[fn], "\(fn) must not be ABSENT")
            XCTAssertEqual(eff(by, fn), ["Net"], "\(fn) got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net \(fn)"), 1, "`deny Net \(fn)` must catch it")
        }
    }

    /// R580's PRECEDENCE, re-asked with a CLASS inner bound. The function's own bound must DISPLACE the
    /// enclosing type's, so `shadowClass` charges `EffBase`'s hierarchy — and must NOT publish a
    /// `Solo#Pr.make` wire key, which would name a conformer set the call cannot reach.
    func testTheFunctionBoundDisplacesTheEnclosingTypesEvenWhenItIsAClass() throws {
        let (by, root) = try scan(["cl": Self.classSource])
        XCTAssertEqual(eff(by, "ProtoBox.shadowClass"), ["Net"],
                       "got \(eff(by, "ProtoBox.shadowClass"))")
        XCTAssertEqual(try gate(root, "deny Net ProtoBox.shadowClass"), 1)
        let keys = Set(by["ProtoBox.shadowClass"]?["dispatchesOn"] as? [String] ?? [])
        XCTAssertFalse(keys.contains("Solo#Pr.make"),
                       "the displaced enclosing bound must not be published; got \(keys.sorted())")
    }

    /// THE SUBCLASS FAN-OUT, which is the whole reason a class bound cannot be resolved to the named
    /// class alone: `OverBase.go` is PURE and `OverSub.go` dials, and the executed program calls
    /// `viaOverridable(OverSub.self)`. A fix that stopped at the static type would read silent-pure.
    func testAnOverridingSubclassIsReachedThroughTheMetatypeSpelling() throws {
        let (by, root) = try scan(["at": Self.attackSource])
        XCTAssertEqual(eff(by, "viaOverridable"), ["Net"], "got \(eff(by, "viaOverridable"))")
        XCTAssertEqual(eff(by, "viaTypeOfClass"), ["Net"], "got \(eff(by, "viaTypeOfClass"))")
        XCTAssertEqual(try gate(root, "deny Net viaOverridable"), 1)
        XCTAssertEqual(try gate(root, "deny Net viaTypeOfClass"), 1)
    }

    /// The remaining spellings the §9 widening covers: a FINAL class, a STRUCT metatype, and the
    /// INITIALIZER through a class bound. Each executes and reaches `sink`.
    func testTheFinalStructAndInitializerSpellingsResolve() throws {
        let (by, root) = try scan(["at": Self.attackSource])
        for fn in ["viaFinal", "viaStruct", "viaInit"] {
            XCTAssertNotNil(by[fn], "\(fn) must not be ABSENT")
            XCTAssertEqual(eff(by, fn), ["Net"], "\(fn) got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net \(fn)"), 1)
        }
    }

    /// PARITY WITH THE LITERAL SPELLING, and this arm is the reason the resolution lives in `rootOf`
    /// rather than in a dispatch branch of its own. `FnHolder.maker(1)` INVOKES a stored closure; the
    /// engine answers that with the class's own `maker` unit, and the generic spelling must give the
    /// SAME answer rather than a second, more confident one (§F1.3).
    func testTheGenericSpellingAgreesWithTheLiteralOne() throws {
        let (by, _) = try scan(["at": Self.attackSource])
        XCTAssertEqual(eff(by, "fnTypedGeneric"), eff(by, "fnTypedLiteral"),
                       "generic \(eff(by, "fnTypedGeneric")) vs literal \(eff(by, "fnTypedLiteral"))")
        XCTAssertTrue(eff(by, "fnTypedGeneric").contains("Net"),
                      "both spellings reach the stored closure's sink")
    }

    /// `type(of:)` ON A GENERIC-PARAMETER-TYPED VALUE GOES THROUGH THE BOUND, NOT THROUGH A SAME-NAMED
    /// TYPE. The pure `enum Rec` must not claim the call; the `Named` conformer that dials must.
    func testTypeOfDispatchesThroughTheBoundNotANameCollision() throws {
        let (by, root) = try scan(["co": Self.collisionSource])
        XCTAssertEqual(eff(by, "Holder2.go"), ["Net"],
                       "must reach RealRec.label through the `Named` bound; got \(eff(by, "Holder2.go"))")
        XCTAssertEqual(try gate(root, "deny Net Holder2.go"), 1)
        let keys = Set(by["Holder2.go"]?["dispatchesOn"] as? [String] ?? [])
        XCTAssertTrue(keys.contains("Solo#Named.label"),
                      "the wire key must name the BOUND; got \(keys.sorted())")
    }

    // ── THE CONTROLS ────────────────────────────────────────────────────────────────────────────

    /// The PROTOCOL twins and the LITERAL class spelling resolved before this change and must still.
    /// They are what make the rows above a defect rather than a policy: one ruling, two spellings.
    func testTheProtocolAndLiteralSpellingsAreUnchanged() throws {
        let (byC, _) = try scan(["cl": Self.classSource])
        XCTAssertEqual(eff(byC, "fnProtoBound"), ["Net"])
        XCTAssertEqual(eff(byC, "concreteStatic"), ["Net"])
        let (byM, _) = try scan(["mt": Self.metaSource])
        XCTAssertEqual(eff(byM, "metaProto"), ["Net"])
        XCTAssertEqual(eff(byM, "metaGenericProto"), ["Net"])
        XCTAssertTrue(Set(byM["metaProto"]?["dispatchesOn"] as? [String] ?? []).contains("Solo#Cmd.validate"),
                      "R563's wire key must survive")
    }

    /// THE FABRICATION CONTROL — the direction this change did not intend. An all-pure class hierarchy
    /// must stay pure through every new spelling, and a bound naming a DIFFERENT class must not borrow
    /// the first one's members.
    func testAPureHierarchyNeverManufacturesAnEffect() throws {
        let (by, root) = try scan(["pu": Self.pureSource])
        for fn in ["overQuiet", "overQuietMeta", "overOther"] {
            XCTAssertFalse(eff(by, fn).contains("Net"),
                           "\(fn) reaches nothing; got \(eff(by, fn))")
        }
        XCTAssertEqual(try gate(root, "deny Net"), 0, "nothing in this package reaches Net")
        XCTAssertEqual(try gate(root, "deny Unknown"), 0,
                       "a resolvable pure hierarchy must not be hedged either — no Unknown flood")
    }

    /// A MEMBER NO CLASS IN THE BOUND DECLARES, and a metatype of a type this scan does not own. Both
    /// must contribute NOTHING — precise-or-nothing, the same rule the literal spelling follows.
    func testAnUnknownMemberAndAForeignMetatypeContributeNothing() throws {
        let (by, root) = try scan(["at": Self.attackSource])
        XCTAssertFalse(eff(by, "noSuchMember").contains("Net"))
        XCTAssertFalse(eff(by, "noSuchMember").contains("Unknown"),
                       "a member no class declares must not flood Unknown; got \(eff(by, "noSuchMember"))")
        XCTAssertFalse(eff(by, "viaForeign").contains("Net"),
                       "a foreign metatype resolves to nothing local; got \(eff(by, "viaForeign"))")
        XCTAssertEqual(try gate(root, "deny Net noSuchMember"), 0)
    }

    /// A LOCAL BINDING SHADOWING THE TYPE-PARAMETER SPELLING WINS, which is Swift's own lookup order.
    /// `let P = Holder()` makes `P.go()` an INSTANCE call on a PURE value; the executed program prints
    /// `PURE Holder.go` and never dials, so charging `Shadowed`'s hierarchy here would be a fabrication
    /// over a program that provably performs no effect.
    func testALocalBindingShadowsTheTypeParameterSpelling() throws {
        let (by, root) = try scan(["at": Self.attackSource])
        XCTAssertFalse(eff(by, "shadowedByLocal").contains("Net"),
                       "the shadowing local is pure; got \(eff(by, "shadowedByLocal"))")
        XCTAssertEqual(try gate(root, "deny Net shadowedByLocal"), 0)
    }
}
