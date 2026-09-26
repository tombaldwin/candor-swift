import XCTest
import Foundation

/// SOUNDNESS R704 / R705 / R706 — **THE DEP-DECLARED/LOCAL AXIS OF "WHAT DOES THIS RECEIVER SPELLING
/// DENOTE", measured as ONE TREE vs SPLIT on the same bytes.**
///
/// Every arm below is the [[R692]] control: the SPLIT arm is two SPM packages with the consumer chained
/// onto the dependency's report via `CANDOR_DEPS`; the TREE arm is ONE package with the same two source
/// sets as two targets. **The only variable is where the dependency's sources sit**, so a difference is a
/// defect in the join and not a fact about the program — and the TREE arm is the reference answer rather
/// than a hand-written expectation, which is what stops these assertions going stale the way a literal
/// `["Env"]` would.
///
/// ── R705: AN ERASED DISPATCH OVER A DEP-DECLARED ABSTRACTION IS A POSITIVE PURITY CLAIM ─────────
/// A dependency declares the abstraction; the consumer declares its ONLY implementor and calls through
/// the bound. Measured at `709311c`, one variable (the spelling), everything else identical:
///
///     _ t: Sink        (existential)   split ['Env']   tree ['Env']   deny Env viaX  1 / 1   ← control
///     any Sink                          split ['Env']   tree ['Env']                  1 / 1   ← control
///     <T: Sink>(_ t: T)                 split  []       tree ['Env']   `unresolved: false`
///     _ t: some Sink                    split ABSENT    tree ['Env']
///
/// **THE OBVIOUS READING OF THAT TABLE IS WRONG, AND IT WAS MEASURED WRONG RATHER THAN ARGUED.** Making
/// the erased spellings union the local conformers like the existential one reverses `d62dd69` and reds
/// SIXTEEN assertions in `ScanBoundaryVeinProcessTests`, which pins that union as a FABRICATION with call
/// sites that pass only the PURE conformer: `some P` / `<T: P>` is monomorphized BY THE CALLER, so this
/// package's conformers are not this receiver's witnesses (candor-rust reached the same conclusion from
/// the other side — see `isOpaqueParam`). The union was implemented; those sixteen went red; the erasure
/// carve-out stays. `testTheErasureCarveOutIsStillInForce` is that boundary, asserted here so the two
/// rows cannot be "fixed" apart.
///
/// WHAT IS WRONG IS THE OTHER CONJUNCT — the rust [[R693]] shape, two locally-correct decisions whose
/// INTERSECTION is silent. The carve-out withholds the edge (right); the arm is PRECISE-OR-NOTHING with
/// **no disclose-on-miss** (wrong); so the row reads `inferred: []`, `unresolved: false` — an affirmative
/// claim that the call reaches nothing — while the LOCAL protocol-CHA loop answers the identical question
/// with `Unknown` + `dispatch:<P>.<member>`. The fix is that disclosure, and nothing else.
///
/// **SO THE PROPERTY THIS FILE ASSERTS FOR THE ERASED SPELLINGS IS DISCLOSURE, NOT EQUALITY WITH THE TREE
/// ARM.** `deny Env Unknown viaX` goes 0 → 1 and agrees across the arms; a bare `deny Env viaX` still
/// passes, and that is correct rather than a shortfall — the scan does not know WHICH effect the caller's
/// monomorphization performs, and naming one is the fabrication the carve-out exists to prevent. The cost
/// is a flip in the OTHER direction, stated rather than hidden: `deny Unknown` is now 1 on the split arm
/// and 0 on the one-tree arm, which is fail-closed.
///
/// ── R704: THE METATYPE BINDERS, DEP-DECLARED ────────────────────────────────────────────────────
/// [[R585]] enumerated NINE metatype binders and closed all nine — for LOCALLY-declared types. The
/// dep-declared/local axis was never a column in that enumeration, and it defeats **all ten binders,
/// both halves, twenty arms** — including `b1`, the function PARAMETER, which R585's own table lists as
/// a passing CONTROL (R563/R584). The literal spellings `Impl.make()` / `CBase.validate()` resolve in
/// both arms, which is what makes the receiver spelling the only variable.
///
/// ── R706: THE HEDGE IS LOST TOO, AND THE EXISTENTIAL IS NOT IMMUNE TO THAT HALF ──────────────────
/// `testNoImplementorAnywhereIsNotAPurityClaim` is the brief's must-still-pass control and it FAILS on
/// the split arm in all three spellings, `any P` included: with zero implementors anywhere the TREE arm
/// discloses `Unknown` + `unknownWhy: ["dispatch:Sink.emit"]` and the SPLIT arm reads `inferred: []`,
/// `unresolved: false`. The foreign-abstraction arm in `Driver` is PRECISE-OR-NOTHING with no
/// disclose-on-miss, where the local protocol-CHA loop beside it has one. **That half is FILED AND NOT
/// FIXED here** (it needs "did the §2 join answer", which is decided downstream of that arm — hedging
/// without it would put a false `Unknown` on every resolved dependency method), so this test asserts the
/// direction the fix must not break: the split arm must gain no EFFECT it cannot justify, and the tree
/// arm's disclosure must survive. It is labelled so a reader cannot mistake it for coverage of R706.
///
/// ── THE OVER-CHARGE CONTROLS ARE THE DELIVERABLE ────────────────────────────────────────────────
/// Both fixes WIDEN. `testAPureLocalImplementorGainsNothing` drives the identical shapes over an
/// implementor that performs nothing; `testTheNeighbourAbstractionIsNotCharged` gives the consumer a
/// second, unrelated dep protocol with an EFFECTFUL local implementor and dispatches only over the FIRST,
/// so a fix that unioned by package rather than by abstraction would light up; `testStdPureBoundsGainNothing`
/// keeps `Equatable`/`Hashable` inert (nearly every type conforms, so a CHA there is a fabrication);
/// `testAMetatypeRebindDropsTheBinding` is R585's rebind control with a DEP-declared hierarchy.
///
/// ── §E3 ────────────────────────────────────────────────────────────────────────────────────────
/// `testEveryFixtureTypechecks` runs `swiftc -typecheck` over each arm's two source sets concatenated, so
/// no assertion below is made about a program that does not exist. The same source text was additionally
/// `swift build`-ed in BOTH arms (two packages, then one package with two targets, exit 0 for each) by the
/// harness this row was measured with — see the commit message.
final class DepDeclaredAbstractionProcessTests: XCTestCase {

    // ── FIXTURE SOURCES ─────────────────────────────────────────────────────────────────────────
    private static let ENV = #"_ = ProcessInfo.processInfo.environment["A"]"#
    private static let FS = #"_ = FileManager.default.contents(atPath: "/tmp/x")"#

    /// The dependency: the abstraction ONLY. No body, so nothing it publishes can answer the key — the
    /// witness has to come from the consumer's implementor or from nowhere.
    private static let depProtoOnly = "public protocol Sink { func emit() }\n"
    /// …and a second, unrelated abstraction, for the neighbour control.
    private static let depTwoProtos = depProtoOnly + "public protocol Other { func run() }\n"
    /// The dep-declared metatype hierarchy: a protocol with a static requirement and a class hierarchy.
    private static let depHierarchy = """
    import Foundation
    public func sink() { \(ENV) }
    public protocol EffP { static func make() }
    public struct Impl: EffP { public init() {}; public static func make() { sink() } }
    open class CBase { public init() {}; open class func validate() { sink() } }
    public final class CSub: CBase { public override class func validate() { sink() } }
    """
    /// The PURE twin of the hierarchy above, for the metatype over-charge control. `inert()` exists so
    /// the "charges the CALL, not the TYPE" question has a reachable input: `NBase` DOES perform Fs, and
    /// every binder below calls only its inert member.
    private static let depPureHierarchy = """
    import Foundation
    public protocol PureP { static func make() }
    public struct PureImpl: PureP { public init() {}; public static func make() { } }
    open class PBase { public init() {}; open class func validate() { } }
    public final class PSub: PBase { public override class func validate() { } }
    open class NBase {
        public init() {}
        open class func inert() { }
        open class func reaches() { \(FS) }
    }
    """

    private static let localImplementor = """
    import Foundation
    import Iface
    public struct Mine: Sink {
        public init() {}
        public func emit() { \(ENV) }
    }
    """

    /// The four receiver spellings of ONE dispatch. `viaX` is the same NAME in every arm so the policy
    /// line and the row lookup are literally shared.
    private static let spellings: [(name: String, decl: String)] = [
        ("existential", "public func viaX(_ t: Sink) { t.emit() }"),
        ("any Sink",    "public func viaX(_ t: any Sink) { t.emit() }"),
        ("<T: Sink>",   "public func viaX<T: Sink>(_ t: T) { t.emit() }"),
        ("some Sink",   "public func viaX(_ t: some Sink) { t.emit() }"),
    ]

    /// THE NINE BINDERS + THE LITERAL CONTROLS, over a DEP-DECLARED hierarchy. Verbatim the arms R585
    /// enumerated; the ONLY change is that `EffP`/`Impl`/`CBase`/`CSub` are declared in the dependency.
    private static let metatypeConsumer = """
    import Foundation
    import Iface

    public enum Holder { case p(EffP.Type), c(CBase.Type) }
    public struct BoxP { public let t: EffP.Type; public init(_ t: EffP.Type) { self.t = t }; public func go() { t.make() } }
    public struct BoxC { public let t: CBase.Type; public init(_ t: CBase.Type) { self.t = t }; public func go() { t.validate() } }
    let gP: EffP.Type = Impl.self
    let gC: CBase.Type = CSub.self
    public func mkP() -> EffP.Type { return Impl.self }
    public func mkC() -> CBase.Type { return CSub.self }
    public func b1p(_ t: EffP.Type) { t.make() }
    public func b1c(_ t: CBase.Type) { t.validate() }
    public func b2p() { let t: EffP.Type = Impl.self; t.make() }
    public func b2c() { let t: CBase.Type = CSub.self; t.validate() }
    public func b3p() { var t: EffP.Type = Impl.self; t = Impl.self; t.make() }
    public func b3c() { var t: CBase.Type = CSub.self; t = CSub.self; t.validate() }
    public func b4p(_ b: BoxP) { b.go() }
    public func b4c(_ b: BoxC) { b.go() }
    public func b5p(_ ts: [EffP.Type]) { ts.forEach { (t: EffP.Type) in t.make() } }
    public func b5c(_ ts: [CBase.Type]) { ts.forEach { (t: CBase.Type) in t.validate() } }
    public func b6p(_ ts: [EffP.Type]) { for t in ts { t.make() } }
    public func b6c(_ ts: [CBase.Type]) { for t in ts { t.validate() } }
    public func b7p() { gP.make() }
    public func b7c() { gC.validate() }
    public func b8p(_ t: EffP.Type?) { if let t = t { t.make() } }
    public func b8c(_ t: CBase.Type?) { if let t = t { t.validate() } }
    public func b9p() { let t = mkP(); t.make() }
    public func b9c() { let t = mkC(); t.validate() }
    public func b10p(_ h: Holder) { if case .p(let t) = h { t.make() } }
    public func b10c(_ h: Holder) { if case .c(let t) = h { t.validate() } }
    public func b11p() { let t = Impl.self; t.make() }
    public func b11c() { let t = CSub.self; t.validate() }
    public func ctlP() { Impl.make() }
    public func ctlC() { CBase.validate() }
    """

    /// The metatype OVER-CHARGE consumer: the same twelve binder spellings over a PURE hierarchy, plus
    /// `m*`, which binds the type that DOES reach the filesystem and calls only its INERT member.
    private static let metatypePureConsumer = """
    import Foundation
    import Iface

    public enum PHolder { case p(PureP.Type), c(PBase.Type), n(NBase.Type) }
    public struct PBoxP { public let t: PureP.Type; public init(_ t: PureP.Type) { self.t = t }; public func go() { t.make() } }
    public struct NBoxC { public let t: NBase.Type; public init(_ t: NBase.Type) { self.t = t }; public func go() { t.inert() } }
    let pG: PureP.Type = PureImpl.self
    let nG: NBase.Type = NBase.self
    public func mkPure() -> PureP.Type { return PureImpl.self }
    public func mkN() -> NBase.Type { return NBase.self }
    public func o1p(_ t: PureP.Type) { t.make() }
    public func o1c(_ t: PBase.Type) { t.validate() }
    public func o2p() { let t: PureP.Type = PureImpl.self; t.make() }
    public func o2c() { let t: PBase.Type = PSub.self; t.validate() }
    public func o3c() { var t: PBase.Type = PSub.self; t = PSub.self; t.validate() }
    public func o4p(_ b: PBoxP) { b.go() }
    public func o6c(_ ts: [PBase.Type]) { for t in ts { t.validate() } }
    public func o7p() { pG.make() }
    public func o9p() { let t = mkPure(); t.make() }
    public func o10c(_ h: PHolder) { if case .c(let t) = h { t.validate() } }
    public func m1(_ t: NBase.Type) { t.inert() }
    public func m2() { let t: NBase.Type = NBase.self; t.inert() }
    public func m4(_ b: NBoxC) { b.go() }
    public func m6(_ ts: [NBase.Type]) { for t in ts { t.inert() } }
    public func m7() { nG.inert() }
    public func m9() { let t = mkN(); t.inert() }
    public func m10(_ h: PHolder) { if case .n(let t) = h { t.inert() } }
    // THE DISCRIMINATING CONTROL — the same binder, the EFFECTFUL member. If this is not charged the
    // two assertions above are vacuous.
    public func reallyReaches() { let t: NBase.Type = NBase.self; t.reaches() }
    """

    // ── HARNESS ─────────────────────────────────────────────────────────────────────────────────
    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: DepDeclaredAbstractionProcessTests.self)
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

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func manifest(_ name: String, deps: [String]) -> String {
        let d = deps.map { ".package(path: \"../\($0.lowercased()))\"" }.joined(separator: ", ")
        let p = deps.map { ".product(name: \"\($0)\", package: \"\($0.lowercased())\")" }.joined(separator: ", ")
        return """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
            dependencies: [\(d)], targets: [.target(name: "\(name)", dependencies: [\(p)])])
        """
    }

    /// ONE package, TWO targets, the SAME bytes — the reference arm. `Iface` is a project module here, so
    /// `import Iface` in the consumer text is unchanged between arms.
    private static let treeManifest = """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
        targets: [.target(name: "Iface"), .target(name: "App", dependencies: ["Iface"])])
    """

    private struct Arms {
        var split: [String: [String: Any]]
        var tree: [String: [String: Any]]
        var root: URL
    }

    private func rows(_ url: URL) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let name = f["fn"] as? String { out[name] = f }
        }
        return out
    }

    /// Renders and scans both arms. `deny` (when given) is also gated on both, and the exit codes are
    /// returned so a gate FLIP is asserted on rather than inferred from the rows.
    ///
    /// **WHAT MAY AND MAY NOT BE ASSERTED ABOUT A GATE EXIT FROM INSIDE `swift test`, measured.** The
    /// ⟨0.32⟩ third exit-2 cause — *"this scan did not READ manifest"* — fires whenever the manifest PEEK
    /// could not run, and the peek shells out to `swift package dump-package`. Run standalone these
    /// fixtures peek fine and the gates are 0/1; run under `swift test` the peek does not complete and
    /// every non-violating arm is **2**, i.e. fail-closed INCOMPLETE. That is the engine behaving
    /// correctly (§H: a check that cannot run DOES reach the exit code), and it means only two forms are
    /// assertable here: a must-FAIL arm is `== 1` (a real violation DOMINATES both exit-2 arms), and a
    /// must-PASS arm is `!= 1`. The SPLIT-vs-TREE equality — the R692 control itself — is assertable
    /// either way, because the peek fails identically in both arms.
    private func arms(dep: String, app: String, deny: String? = nil) throws
        -> (rows: Arms, gate: (split: Int32, tree: Int32)) {
        let bin = try binaryURL()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r704-\(UUID().uuidString)")
        // SPLIT
        let depPkg = root.appendingPathComponent("iface"), appPkg = root.appendingPathComponent("app")
        try write(depPkg.appendingPathComponent("Package.swift"), Self.manifest("Iface", deps: []))
        try write(depPkg.appendingPathComponent("Sources/Iface/lib.swift"), dep)
        try write(appPkg.appendingPathComponent("Package.swift"), Self.manifest("App", deps: ["Iface"]))
        try write(appPkg.appendingPathComponent("Sources/App/a.swift"), app)
        // SOUNDNESS R700 — **AN UNRESOLVED CONSUMER TREE MAKES EVERY ARM BELOW MEANINGLESS**, and it does
        // it in the direction that looks safe: with `.build/checkouts` absent the engine prints its SETUP
        // notice, the dependency stays in the κ ledger, and the ⟨0.30⟩ INCOMPLETE verdict turns every gate
        // exit into 2 — so a scoped `deny` that really does pass silently (the cardinal sin under test)
        // is indistinguishable from one that fail-closed. `swift build` on a package whose only
        // dependency is a `.package(path:)` creates this directory and leaves it EMPTY (measured — a path
        // dependency is never checked out), so creating it empty is byte-equivalent to the resolved state
        // rather than a stand-in for it. The same fixtures were additionally `swift build`-ed for real in
        // both arms; see the commit message.
        try FileManager.default.createDirectory(at: appPkg.appendingPathComponent(".build/checkouts"),
                                               withIntermediateDirectories: true)
        // TREE — same two source sets, one package
        let treePkg = root.appendingPathComponent("tree")
        try write(treePkg.appendingPathComponent("Package.swift"), Self.treeManifest)
        try write(treePkg.appendingPathComponent("Sources/Iface/lib.swift"), dep)
        try write(treePkg.appendingPathComponent("Sources/App/a.swift"), app)

        let depOut = root.appendingPathComponent("depR")
        let rd = try run(bin, [depPkg.path, "--out", depOut.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed; stderr: \(rd.err)")
        // Only the dependency's MAIN report may sit on CANDOR_DEPS — a stray sidecar in that directory
        // would be a second, unexplained input to the arm under test.
        for f in (try? FileManager.default.contentsOfDirectory(atPath: depOut.path)) ?? []
        where f != "r.Iface.Swift.json" {
            try? FileManager.default.removeItem(at: depOut.appendingPathComponent(f))
        }
        let depReport = depOut.appendingPathComponent("r.Iface.Swift.json").path
        let rs = try run(bin, [appPkg.path, "--out", root.appendingPathComponent("s").path],
                         env: ["CANDOR_DEPS": depReport])
        XCTAssertEqual(rs.code, 0, "chained consumer scan must succeed; stderr: \(rs.err)")
        let rt = try run(bin, [treePkg.path, "--out", root.appendingPathComponent("t").path])
        XCTAssertEqual(rt.code, 0, "one-tree scan must succeed; stderr: \(rt.err)")

        var gate: (split: Int32, tree: Int32) = (0, 0)
        if let deny = deny {
            let pol = root.appendingPathComponent("p.policy")
            try write(pol, deny + "\n")
            gate.split = try run(bin, [appPkg.path, "--policy", pol.path,
                                       "--out", root.appendingPathComponent("gs").path],
                                 env: ["CANDOR_DEPS": depReport]).code
            gate.tree = try run(bin, [treePkg.path, "--policy", pol.path,
                                      "--out", root.appendingPathComponent("gt").path]).code
        }
        return (Arms(split: try rows(root.appendingPathComponent("s.App.Swift.json")),
                     tree: try rows(root.appendingPathComponent("t.App.Swift.json")),
                     root: root),
                gate)
    }

    private func eff(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set(by[fn]?["inferred"] as? [String] ?? [])
    }
    private func why(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set(by[fn]?["unknownWhy"] as? [String] ?? [])
    }

    // ── R705: THE DEFECT ARMS AND THEIR CONTROLS, IN ONE TABLE ──────────────────────────────────
    //
    // The ERASED spellings must DISCLOSE; the EXISTENTIAL ones must keep the effect they already carry.
    // Both halves in one loop over one table, because a fix that silenced the existential arm to make the
    // erased ones agree would otherwise satisfy half the file.
    func testAnErasedDispatchOverADepAbstractionIsNotAPurityClaim() throws {
        var seen: [String: String] = [:]
        for (name, decl) in Self.spellings {
            let app = Self.localImplementor + "\n" + decl + "\n"
            let (r, g) = try arms(dep: Self.depProtoOnly, app: app, deny: "deny Env Unknown viaX")
            defer { try? FileManager.default.removeItem(at: r.root) }
            let s = eff(r.split, "viaX"), t = eff(r.tree, "viaX")
            // THE REFERENCE ARM MUST BE NON-VACUOUS: if the one-tree answer ever stops carrying the
            // effect, every assertion below would pass over two silences (§E3 — absence is also what a
            // broken engine produces).
            XCTAssertEqual(t, ["Env"], "\(name): the ONE-TREE reference arm is vacuous")
            seen[name] = "\(s.sorted()) unresolved=\(String(describing: r.split["viaX"]?["unresolved"]))"

            if name == "existential" || name == "any Sink" {
                // CONTROL — an existential receiver's witnesses really are every conformer, so the local
                // one is charged and must stay charged. This is the arm a fix aimed at the erased
                // spellings is most likely to break.
                XCTAssertEqual(s, t, "\(name): the EXISTENTIAL spelling must keep the local conformer's "
                               + "effect across the boundary; split=\(s) tree=\(t)")
            } else {
                // THE DEFECT ARMS. NOT `s == t`: unioning the conformers here is the fabrication
                // `ScanBoundaryVeinProcessTests` pins (`d62dd69`, sixteen assertions, call sites that pass
                // only the pure conformer). What must not stand is the POSITIVE claim.
                XCTAssertTrue(s.contains("Unknown"),
                              "\(name): an erased dispatch over a DEP-DECLARED abstraction whose witness "
                              + "nothing published must DISCLOSE, not read pure. `inferred: []` with "
                              + "`unresolved: false` is a ⟨0.21⟩ positive claim over a call that really "
                              + "reaches `Mine.emit`; got \(s)")
                XCTAssertEqual(why(r.split, "viaX"), ["dispatch:Sink.emit"],
                               "\(name): …and the reason must NAME the unanswered member, as the local "
                               + "protocol-CHA loop's does; got \(why(r.split, "viaX"))")
                XCTAssertEqual(r.split["viaX"]?["unresolved"] as? Bool, true,
                               "\(name): `unresolved` must be true — that field is what a consumer reads "
                               + "to know the answer is a lower bound")
                XCTAssertFalse(s.contains("Env"),
                               "\(name): the erasure carve-out must still withhold the EDGE — charging "
                               + "the local conformer's concrete effect is the fabrication `d62dd69` "
                               + "measured; got \(s)")
            }
            // THE HEDGED GATE IS THE CONSEQUENTIAL FORM, and it must agree across the arms in EVERY
            // spelling — that is what makes the disclosure worth having rather than a field nobody reads.
            XCTAssertEqual(g.tree, 1, "\(name): `deny Env Unknown viaX` must FAIL on the one-tree arm")
            XCTAssertEqual(g.split, g.tree,
                           "\(name): `deny Env Unknown viaX` must agree across the arms — "
                           + "split=\(g.split) tree=\(g.tree). At 709311c the erased spellings were 0 here.")
        }
        // The two erased spellings must agree WITH EACH OTHER: `isOpaqueParam`'s own doc says they are one
        // thing under two spellings, so a fix that reached one is §F1.3 waiting to happen.
        XCTAssertEqual(seen["<T: Sink>"], seen["some Sink"], "one erasure, two spellings, one answer: \(seen)")
    }

    /// THE BOUNDARY THIS FIX MUST NOT CROSS, asserted HERE so R704/R705 and `d62dd69` cannot be "fixed"
    /// apart. An erased receiver must not be charged the local conformer's CONCRETE effect — only the
    /// `Unknown` that says nobody published the witness. `ScanBoundaryVeinProcessTests` owns the full
    /// sixteen assertions over an imported protocol; this is the two-line version in this file's own
    /// harness, because a reader of THIS file needs to know the union was tried and rejected.
    func testTheErasureCarveOutIsStillInForce() throws {
        let app = """
        import Foundation
        import Iface
        public struct Loud: Sink { public init() {}; public func emit() { \(Self.ENV) } }
        public struct Quiet: Sink { public init() {}; public func emit() { } }
        public func viaOpaque(_ t: some Sink) { t.emit() }
        public func viaGeneric<T: Sink>(_ t: T) { t.emit() }
        public func onlyQuiet() { viaOpaque(Quiet()); viaGeneric(Quiet()) }
        """
        let (r, _) = try arms(dep: Self.depProtoOnly, app: app)
        defer { try? FileManager.default.removeItem(at: r.root) }
        for fn in ["viaOpaque", "viaGeneric"] {
            XCTAssertFalse(eff(r.split, fn).contains("Env"),
                           "\(fn): the CALLER monomorphizes — `onlyQuiet` passes `Quiet`, so charging "
                           + "`Loud.emit`'s Env is an effect this function cannot perform (d62dd69); "
                           + "got \(eff(r.split, fn))")
            XCTAssertTrue(eff(r.split, fn).contains("Unknown"),
                          "\(fn): …and the honest answer in its place is the disclosure; got "
                          + "\(eff(r.split, fn))")
        }
    }

    /// THE DISCRIMINATOR. Over a LOCAL protocol the engine already unions the conformers for the
    /// IDENTICAL `some P` / `<T: P>` spelling, so "monomorphized, therefore not our witnesses" is not the
    /// family's rule for these spellings — it is which path answered. Held constant: the consumer text,
    /// the implementor, the binary; varied: whether `protocol Sink` is in the dependency or in the app.
    func testTheSameSpellingOverALocalProtocolAlreadyUnionsTheConformers() throws {
        for (name, decl) in Self.spellings {
            let app = "import Foundation\nimport Iface\n" + Self.depProtoOnly + """
            public struct Mine: Sink {
                public init() {}
                public func emit() { \(Self.ENV) }
            }
            """ + "\n" + decl + "\n"
            let (r, g) = try arms(dep: "public struct Unused { public init() {} }\n", app: app,
                                  deny: "deny Env viaX")
            defer { try? FileManager.default.removeItem(at: r.root) }
            XCTAssertEqual(eff(r.split, "viaX"), ["Env"],
                           "\(name) over a LOCAL protocol must union the local conformers (it does, and "
                           + "that is the discriminator)")
            XCTAssertEqual(g.split, 1, "\(name): `deny Env viaX` must FAIL over a local protocol")
        }
    }

    // ── R704: THE TWELVE METATYPE BINDERS, DEP-DECLARED ─────────────────────────────────────────
    func testEveryMetatypeBinderOverADepDeclaredTypeResolvesAsTheLiteralDoes() throws {
        let (r, _) = try arms(dep: Self.depHierarchy, app: Self.metatypeConsumer)
        defer { try? FileManager.default.removeItem(at: r.root) }
        // THE CONTROLS FIRST — the literal spellings, which resolve in BOTH arms at every commit. They
        // are what make the receiver's BINDER the only variable.
        for ctl in ["ctlP", "ctlC"] {
            XCTAssertEqual(eff(r.split, ctl), ["Env"],
                           "CONTROL \(ctl): the type named LITERALLY must resolve across the boundary")
        }
        var silent: [String] = []
        for b in (1...11).flatMap({ ["b\($0)p", "b\($0)c"] }) {
            let s = eff(r.split, b), t = eff(r.tree, b)
            XCTAssertEqual(t, ["Env"], "the ONE-TREE reference arm for \(b) is vacuous")
            if s != t { silent.append("\(b) split=\(s.sorted()) tree=\(t.sorted())") }
        }
        XCTAssertEqual(silent, [], "A METATYPE BINDER OVER A DEP-DECLARED TYPE MUST GET THE ANSWER THE "
                       + "TYPE NAMED LITERALLY GETS. R585 closed all nine binders for LOCAL types and the "
                       + "dep-declared/local axis was never a column in that enumeration — b1, the "
                       + "PARAMETER, is listed there as a passing control and is silent here:\n  "
                       + silent.joined(separator: "\n  "))
    }

    func testTheScopedGateAgreesAcrossTheArmsForEveryMetatypeBinder() throws {
        for b in ["b1c", "b2c", "b4c", "b7c", "b10c", "b11c", "b1p", "b9p"] {
            let (r, g) = try arms(dep: Self.depHierarchy, app: Self.metatypeConsumer,
                                  deny: "deny Env \(b)")
            defer { try? FileManager.default.removeItem(at: r.root) }
            XCTAssertEqual(g.tree, 1, "`deny Env \(b)` must FAIL on the one-tree arm (reference)")
            XCTAssertEqual(g.split, g.tree,
                           "`deny Env \(b)`: split=\(g.split) tree=\(g.tree) — a 0/1 split is the "
                           + "cardinal sin, and neither the blanket nor the hedged form catches it "
                           + "(measured `deny Env` 0→1 and `deny Env Unknown` 0→1 on b2c at 709311c)")
        }
    }

    // ── THE OVER-CHARGE CONTROLS ────────────────────────────────────────────────────────────────
    func testAPureLocalImplementorGainsNothing() throws {
        let pureImpl = """
        import Foundation
        import Iface
        public struct Mine: Sink {
            public init() {}
            public func emit() { }
        }
        """
        for (name, decl) in Self.spellings {
            let (r, g) = try arms(dep: Self.depProtoOnly, app: pureImpl + "\n" + decl + "\n",
                                  deny: "deny Env Fs Net")
            defer { try? FileManager.default.removeItem(at: r.root) }
            // THE PROPERTY IS "NO CONCRETE EFFECT", NOT "NOTHING AT ALL", and the difference is R705's
            // PRICE, stated here rather than discovered in a corpus: an erased dispatch the chain cannot
            // answer discloses `Unknown` even where the only implementor in sight is pure, because the
            // caller monomorphizes and a downstream one may pass something else. A concrete effect here
            // would be the fabrication; the `Unknown` is the disclosure this row exists to add.
            XCTAssertEqual(eff(r.split, "viaX").subtracting(["Unknown"]),
                           eff(r.tree, "viaX").subtracting(["Unknown"]),
                           "\(name): a PURE implementor must yield the same CONCRETE effects in both arms")
            XCTAssertTrue(eff(r.split, "viaX").subtracting(["Unknown"]).isEmpty,
                          "\(name): a PURE implementor must be charged no concrete effect; got "
                          + "\(eff(r.split, "viaX"))")
            XCTAssertNotEqual(g.split, 1, "\(name): a blanket `deny Env Fs Net` must not FLAG a pure "
                              + "implementor — got \(g.split)")
        }
    }

    /// THE FIX MUST UNION BY ABSTRACTION, NOT BY PACKAGE. The consumer conforms to TWO of the
    /// dependency's protocols; `Other`'s implementor is effectful and `Sink`'s is pure, and the dispatch
    /// is over `Sink`. `Fs` appearing on `viaX` would mean the union was keyed on provenance.
    func testTheNeighbourAbstractionIsNotCharged() throws {
        let app = """
        import Foundation
        import Iface
        public struct Mine: Sink { public init() {}; public func emit() { } }
        public struct Loud: Other { public init() {}; public func run() { \(Self.FS) } }
        """
        for (name, decl) in Self.spellings {
            let (r, g) = try arms(dep: Self.depTwoProtos, app: app + "\n" + decl + "\n",
                                  deny: "deny Fs viaX")
            defer { try? FileManager.default.removeItem(at: r.root) }
            XCTAssertFalse(eff(r.split, "viaX").contains("Fs"),
                           "\(name): the NEIGHBOUR abstraction's effectful implementor must not be "
                           + "charged to a dispatch over `Sink`; got \(eff(r.split, "viaX"))")
            // …and the neighbour really is effectful, so the assertion above is not vacuous.
            XCTAssertEqual(eff(r.split, "Loud.run"), ["Fs"], "\(name): control is vacuous — `Loud.run` "
                           + "must itself be charged Fs")
            XCTAssertNotEqual(g.split, 1, "\(name): `deny Fs viaX` must not FLAG; got \(g.split)")
        }
    }

    /// Nearly every type conforms to `Equatable`/`Hashable`/`Codable`, so a CHA over their conformers is a
    /// pure fabrication. `STD_PURE_PROTOCOLS` is that carve-out and neither fix may relax it.
    func testStdPureBoundsGainNothing() throws {
        let app = """
        import Foundation
        import Iface
        public struct Mine: Sink, Equatable, Hashable {
            public init() {}
            public func emit() { \(Self.ENV) }
        }
        public func viaEq<T: Equatable>(_ t: T) -> Bool { return t == t }
        public func viaHash<T: Hashable>(_ t: T) -> Int { return t.hashValue }
        """
        let (r, g) = try arms(dep: Self.depProtoOnly, app: app, deny: "deny Env viaEq")
        defer { try? FileManager.default.removeItem(at: r.root) }
        for fn in ["viaEq", "viaHash"] {
            XCTAssertTrue(eff(r.split, fn).isEmpty,
                          "\(fn): a std-pure bound must charge nothing; got \(eff(r.split, fn))")
            XCTAssertNil(r.split[fn]?["dispatchesOn"],
                         "\(fn): a std-pure bound must publish NO dispatch key; got "
                         + "\(String(describing: r.split[fn]?["dispatchesOn"]))")
        }
        XCTAssertNotEqual(g.split, 1, "`deny Env viaEq` must not FLAG; got \(g.split)")
    }

    func testAMetatypeBinderOverAPureDepHierarchyGainsNothing() throws {
        let (r, g) = try arms(dep: Self.depPureHierarchy, app: Self.metatypePureConsumer,
                              deny: "deny Env Fs Net")
        defer { try? FileManager.default.removeItem(at: r.root) }
        for fn in ["o1p", "o1c", "o2p", "o2c", "o3c", "o4p", "o6c", "o7p", "o9p", "o10c"] {
            XCTAssertTrue(eff(r.split, fn).isEmpty,
                          "\(fn): a PURE hierarchy through a metatype binder must gain nothing; got "
                          + "\(eff(r.split, fn))")
        }
        // …and the EFFECTFUL neighbour's INERT member is not charged: the fix charges the CALL, not the
        // TYPE. `NBase.reaches` really does perform Fs, which is what makes this discriminating.
        for fn in ["m1", "m2", "m4", "m6", "m7", "m9", "m10"] {
            XCTAssertFalse(eff(r.split, fn).contains("Fs"),
                           "\(fn): binding an EFFECTFUL type and calling only its INERT member must not "
                           + "charge the type's other effects; got \(eff(r.split, fn))")
        }
        XCTAssertEqual(eff(r.split, "reallyReaches"), ["Fs"],
                       "THE DISCRIMINATING CONTROL: the same binder over the EFFECTFUL member must be "
                       + "charged, or every assertion above is vacuous. got \(eff(r.split, "reallyReaches"))")
        XCTAssertEqual(g.split, 1, "`deny Env Fs Net` must FAIL — `reallyReaches` is in this package")
    }

    /// R585's rebind control, with the hierarchy DEP-declared. A metatype entry that outlived its binding
    /// would charge the dependency's hierarchy over a call that cannot reach it.
    func testAMetatypeRebindDropsTheBinding() throws {
        let app = """
        import Foundation
        import Iface
        public struct Calm { public init() {}; public func validate() { } }
        public func rebound() { var t: CBase.Type = CSub.self; _ = t; let u = Calm(); u.validate() }
        public func reallyFires() { let t: CBase.Type = CSub.self; t.validate() }
        """
        let (r, _) = try arms(dep: Self.depHierarchy, app: app)
        defer { try? FileManager.default.removeItem(at: r.root) }
        XCTAssertTrue(eff(r.split, "rebound").isEmpty,
                      "a rebound name must not keep the metatype binding; got \(eff(r.split, "rebound"))")
        XCTAssertEqual(eff(r.split, "reallyFires"), ["Env"],
                       "THE DISCRIMINATING CONTROL for the arm above; got \(eff(r.split, "reallyFires"))")
    }

    // ── R706 — FILED, NOT FIXED. LABELLED SO IT CANNOT READ AS COVERAGE ─────────────────────────
    //
    // With ZERO implementors anywhere the TREE arm discloses `Unknown` + `dispatch:Sink.emit` in all three
    // spellings. After R705 the SPLIT arm does too — **except for the EXISTENTIAL one**, which still reads
    // `inferred: []` with `unresolved: false` while publishing `Iface#Sink.emit`, a key whose owner has no
    // body to answer it (a protocol requirement). That corrects R698's "the existential spelling is
    // verifiably immune": it is immune to the LOCAL-IMPLEMENTOR half and not to this one.
    //
    // NOT FIXED HERE, and the reason is the reason R705 IS fixable: R705's population is fenced by
    // ERASURE, which is a property of the receiver's spelling and therefore cheap and tight. The
    // existential spelling has no such fence — `any P` is the same shape as an ordinary dependency-typed
    // receiver (`_ c: DepClient`), where the §2 join answers and a hedge would be a false `Unknown` on
    // every resolved dependency method call. Telling those apart needs "does any implementor of this
    // abstraction exist in ANY report", which this arm does not have. `deny Unknown viaAny` is 0 / 1.
    func testNoImplementorAnywhereIsNotAPurityClaim() throws {
        for (name, decl) in Self.spellings {
            let app = "import Foundation\nimport Iface\n" + decl + "\n"
            let (r, _) = try arms(dep: Self.depProtoOnly, app: app)
            defer { try? FileManager.default.removeItem(at: r.root) }
            XCTAssertFalse(eff(r.split, "viaX").contains("Env"),
                           "\(name): with NO implementor anywhere no EFFECT may be invented; got "
                           + "\(eff(r.split, "viaX"))")
            XCTAssertEqual(eff(r.tree, "viaX"), ["Unknown"],
                           "\(name): the ONE-TREE arm must keep disclosing Unknown")
            XCTAssertEqual(why(r.tree, "viaX"), ["dispatch:Sink.emit"],
                           "\(name): …with the reason that names the unanswered member")
            if name == "<T: Sink>" || name == "some Sink" {
                XCTAssertEqual(eff(r.split, "viaX"), ["Unknown"],
                               "\(name): R705 — the erased spellings disclose across the boundary too; "
                               + "got \(eff(r.split, "viaX"))")
            } else {
                // R706, OPEN. Asserted as it IS so the row cannot silently change under us, and named so
                // nobody reads this file as covering it.
                XCTAssertTrue(eff(r.split, "viaX").isEmpty,
                              "R706 (OPEN): the existential spelling still reads pure across the boundary "
                              + "with zero implementors. If this ever gains Unknown, R706 is CLOSED and "
                              + "this branch is the thing to update; got \(eff(r.split, "viaX"))")
            }
        }
    }

    // ── §E3 ─────────────────────────────────────────────────────────────────────────────────────
    func testEveryFixtureTypechecks() throws {
        // `import Iface` is stripped and the two source sets concatenated, so ONE `swiftc -typecheck`
        // answers for the pair. A fixture that cannot compile is not weak evidence, it is none.
        let pairs: [(String, String, String)] = [
            ("spellings", Self.depProtoOnly,
             Self.localImplementor + "\n" + Self.spellings.map(\.decl).enumerated()
                .map { "public func viaX\($0.offset)" + $0.element.dropFirst("public func viaX".count) }
                .joined(separator: "\n")),
            ("metatype", Self.depHierarchy, Self.metatypeConsumer),
            ("metatype-pure", Self.depPureHierarchy, Self.metatypePureConsumer),
            ("two-protos", Self.depTwoProtos,
             "import Foundation\nimport Iface\npublic struct Mine: Sink { public init() {}; public func emit() { } }\n"
             + "public struct Loud: Other { public init() {}; public func run() { \(Self.FS) } }\n"),
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r704-tc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, dep, app) in pairs {
            let merged = (dep + "\n" + app)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.trimmingCharacters(in: .whitespaces) != "import Iface" }
                .joined(separator: "\n")
            let f = root.appendingPathComponent("\(name).swift")
            try write(f, "import Foundation\n" + merged + "\n")
            let r = try ProcessHarness.run(URL(fileURLWithPath: "/usr/bin/env"),
                                           ["swiftc", "-typecheck", f.path])
            if r.code != 0, r.err.contains("env: swiftc") { throw XCTSkip("no swiftc on this host") }
            XCTAssertEqual(r.code, 0, "FIXTURE \(name) MUST COMPILE (§E3); stderr:\n\(r.err)")
        }
    }
}
