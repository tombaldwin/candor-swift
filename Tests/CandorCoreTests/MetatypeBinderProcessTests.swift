import XCTest
import Foundation

/// SOUNDNESS R585 — **EVERY BINDER OF A METATYPE EXCEPT THE PARAMETER CLAUSE WAS SILENT**, and the
/// parameter spelling of the identical call already resolved.
///
/// [[R563]] closed the PROTOCOL half of a type-position receiver and [[R584]] the CLASS half, both for
/// one binder: a function PARAMETER. `CandorCore.typeName` has no `MetatypeTypeSyntax` case, so `.Type`
/// survived in exactly one index — `FnInfo.metatypeParams`, written from the parameter clause alone —
/// and every other way of binding the same value resolved to NOTHING. Measured over a body that
/// executes `URLSession.dataTask`, nine binders × the class and protocol halves, eighteen arms:
///
///     ctlP/ctlC  the type named LITERALLY          ['Net'] ['Net']   ← control
///     b1         a function PARAMETER              ['Net'] ['Net']   ← control (R563/R584)
///     b2         a local `let`, `X.Type` annotated  ABSENT  ABSENT
///     b3         a local `var`, `X.Type` annotated  ABSENT  ABSENT
///     b4         a stored/computed PROPERTY         ABSENT  ABSENT
///     b5         a CLOSURE parameter                ABSENT  ABSENT
///     b6         a for-in over `[X.Type]`           ABSENT  ABSENT
///     b7         a module-level GLOBAL              ABSENT  ABSENT
///     b8         an OPTIONAL metatype + `if let`    ABSENT  ABSENT
///     b9         a function RETURN into a local     ABSENT  ABSENT
///     b10        an enum payload via `case let`     ABSENT  ABSENT
///
/// **WHAT THE CONTROLS HOLD CONSTANT.** One package, one file, one hierarchy, one sink, one call
/// spelling per row. The only variable is how the receiver's NAME comes to hold the metatype — and
/// two rows of the same table already resolved: the literal `CBase.validate()` and the parameter
/// `_ t: CBase.Type`. So this is a binder gap, not a dispatch design.
///
/// ── THIS IS A WIDENING, SO THE OVER-CHARGE CONTROL IS THE DELIVERABLE ───────────────────────────
/// `testAPureHierarchyThroughEveryBinderGainsNothing` drives the identical nine binders over a
/// hierarchy that performs nothing; `testTheEffectfulNeighboursInertMemberIsNotCharged` drives them
/// over a type that DOES reach the network and calls only its inert member, so a fix that charged the
/// TYPE rather than the CALL would light up; `testARebindDropsTheMetatypeBinding` rebinds the same
/// NAME to an ordinary value whose same-named member is pure, so a metatype entry outliving its
/// binding would charge Net over a call that never dials. All three fixtures compile and RUN (§E3) —
/// `rebound` really returns `Calm.fire`'s 0 while `reallyFires` really dials.
///
/// ── §1b CALIBRATION ─────────────────────────────────────────────────────────────────────────────
/// The switch restores the pre-fix answer exactly — measured against a binary built at `8067f4a`, both
/// say 4 of the 22 arms resolve and the same four. **`CANDOR_R585_OFF` is deliberately NOT stripped
/// from the child environment** (every other candor variable is), so running
/// `CANDOR_R585_OFF=1 swift test --filter MetatypeBinder` really does red this file: **measured 4 of 7
/// cases FAIL, 69 assertions.** The three that stay green are exactly the three whose assertions are
/// ABSENCE-shaped and so are green under any degradation — the two over-charge controls, and
/// `testTheKillSwitchRestoresTheSilence`, which sets the switch itself. Naming which is the point of
/// §J: "analysed and found clean" and "attacked and survived" must not share a list. The calibration
/// therefore cannot rot into a test that passes with and without the fix (§A).
final class MetatypeBinderProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: MetatypeBinderProcessTests.self)
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

    /// THE NINE BINDERS, both halves. Verbatim from the executable fixture, which builds clean.
    private static var binderSource: String {
        """
        import Foundation
        func sink() { \(SINK) }

        protocol EffP { static func make() }
        struct Impl: EffP { static func make() { sink() } }
        class CBase { class func validate() { sink() } }
        final class CSub: CBase { override class func validate() { sink() } }

        enum Holder { case p(EffP.Type), c(CBase.Type) }
        struct BoxP { let t: EffP.Type; func go() { t.make() } }
        struct BoxC { let t: CBase.Type; func go() { t.validate() } }

        let gP: EffP.Type = Impl.self
        let gC: CBase.Type = CSub.self

        func mkP() -> EffP.Type { return Impl.self }
        func mkC() -> CBase.Type { return CSub.self }

        // 1 — CONTROL: the function parameter (R563/R584 closed this)
        func b1p(_ t: EffP.Type) { t.make() }
        func b1c(_ t: CBase.Type) { t.validate() }
        // 2 — a local `let` with an explicit metatype annotation
        func b2p() { let t: EffP.Type = Impl.self; t.make() }
        func b2c() { let t: CBase.Type = CSub.self; t.validate() }
        // 3 — a local `var` with an explicit metatype annotation
        func b3p() { var t: EffP.Type = Impl.self; t = Impl.self; t.make() }
        func b3c() { var t: CBase.Type = CSub.self; t = CSub.self; t.validate() }
        // 4 — a stored PROPERTY of metatype type, read through implicit self
        func b4p(_ b: BoxP) { b.go() }
        func b4c(_ b: BoxC) { b.go() }
        // 5 — a CLOSURE parameter
        func b5p(_ ts: [EffP.Type]) { ts.forEach { (t: EffP.Type) in t.make() } }
        func b5c(_ ts: [CBase.Type]) { ts.forEach { (t: CBase.Type) in t.validate() } }
        // 6 — a for-in LOOP variable over an array of metatypes
        func b6p(_ ts: [EffP.Type]) { for t in ts { t.make() } }
        func b6c(_ ts: [CBase.Type]) { for t in ts { t.validate() } }
        // 7 — a module-level GLOBAL of metatype type
        func b7p() { gP.make() }
        func b7c() { gC.validate() }
        // 8 — an OPTIONAL metatype parameter, unwrapped
        func b8p(_ t: EffP.Type?) { if let t = t { t.make() } }
        func b8c(_ t: CBase.Type?) { if let t = t { t.validate() } }
        // 9 — a function RETURN bound to an unannotated local
        func b9p() { let t = mkP(); t.make() }
        func b9c() { let t = mkC(); t.validate() }
        // 10 — an enum PAYLOAD bound by `case let`
        func b10p(_ h: Holder) { if case .p(let t) = h { t.make() } }
        func b10c(_ h: Holder) { if case .c(let t) = h { t.validate() } }
        // CONTROLS — the literal spellings, which must already work
        func ctlP() { Impl.make() }
        func ctlC() { CBase.validate() }
        """
    }

    /// THE OVER-CHARGE CONTROL. Compiles and RUNS: prints `1 3 1 3 …` then `6 6 6 6 6 6` then `RAN`.
    /// `o*` drive a PURE hierarchy through all nine binders; `m*` drive an EFFECTFUL type's INERT
    /// member through the same binders, so charging the type rather than the call would show.
    private static var overChargeSource: String {
        """
        import Foundation
        protocol PureP { static func make() -> Int }
        struct PureImpl: PureP { static func make() -> Int { return 1 } }
        class PBase { class func validate() -> Int { return 2 } }
        final class PSub: PBase { override class func validate() -> Int { return 3 } }

        class NBase {
            class func inert() -> Int { return 4 }
            class func reaches() -> Int { \(SINK); return 5 }
        }
        final class NSub: NBase { override class func inert() -> Int { return 6 } }

        enum PHold { case p(PureP.Type), c(PBase.Type), n(NBase.Type) }
        struct PBoxP { let t: PureP.Type; func go() -> Int { return t.make() } }
        struct PBoxC { let t: PBase.Type; func go() -> Int { return t.validate() } }
        struct NBoxC { let t: NBase.Type; func go() -> Int { return t.inert() } }

        let gPP: PureP.Type = PureImpl.self
        let gPC: PBase.Type = PSub.self
        let gNC: NBase.Type = NSub.self

        func mkPP() -> PureP.Type { return PureImpl.self }
        func mkPC() -> PBase.Type { return PSub.self }
        func mkNC() -> NBase.Type { return NSub.self }

        func o1p(_ t: PureP.Type) -> Int { return t.make() }
        func o1c(_ t: PBase.Type) -> Int { return t.validate() }
        func o2p() -> Int { let t: PureP.Type = PureImpl.self; return t.make() }
        func o2c() -> Int { let t: PBase.Type = PSub.self; return t.validate() }
        func o3p() -> Int { var t: PureP.Type = PureImpl.self; t = PureImpl.self; return t.make() }
        func o3c() -> Int { var t: PBase.Type = PSub.self; t = PSub.self; return t.validate() }
        func o4p(_ b: PBoxP) -> Int { return b.go() }
        func o4c(_ b: PBoxC) -> Int { return b.go() }
        func o5p(_ ts: [PureP.Type]) -> Int { var n = 0; ts.forEach { (t: PureP.Type) in n += t.make() }; return n }
        func o5c(_ ts: [PBase.Type]) -> Int { var n = 0; ts.forEach { (t: PBase.Type) in n += t.validate() }; return n }
        func o6p(_ ts: [PureP.Type]) -> Int { var n = 0; for t in ts { n += t.make() }; return n }
        func o6c(_ ts: [PBase.Type]) -> Int { var n = 0; for t in ts { n += t.validate() }; return n }
        func o7p() -> Int { return gPP.make() }
        func o7c() -> Int { return gPC.validate() }
        func o8p(_ t: PureP.Type?) -> Int { if let t = t { return t.make() }; return 0 }
        func o8c(_ t: PBase.Type?) -> Int { if let t = t { return t.validate() }; return 0 }
        func o9p() -> Int { let t = mkPP(); return t.make() }
        func o9c() -> Int { let t = mkPC(); return t.validate() }
        func o10p(_ h: PHold) -> Int { if case .p(let t) = h { return t.make() }; return 0 }
        func o10c(_ h: PHold) -> Int { if case .c(let t) = h { return t.validate() }; return 0 }

        func m2c() -> Int { let t: NBase.Type = NSub.self; return t.inert() }
        func m4c(_ b: NBoxC) -> Int { return b.go() }
        func m6c(_ ts: [NBase.Type]) -> Int { var n = 0; for t in ts { n += t.inert() }; return n }
        func m7c() -> Int { return gNC.inert() }
        func m9c() -> Int { let t = mkNC(); return t.inert() }
        func m10c(_ h: PHold) -> Int { if case .n(let t) = h { return t.inert() }; return 0 }
        """
    }

    /// THE REBIND CONTROL AND THE ITERATOR-ELEMENT ARM. Compiles and RUNS: prints `0 0 1 1 1 3` then
    /// `RAN`, so `rebound` really executes `Calm.fire` (0) while `reallyFires` really dials.
    private static var shadowSource: String {
        """
        import Foundation
        func hsink() -> Int { \(SINK); return 1 }
        class Boom { class func inert() -> Int { return 0 }; class func fire() -> Int { return hsink() } }
        struct Calm { func fire() -> Int { return 0 } }
        func rebound(_ q: Calm) -> Int {
            var n = 0
            do { let t: Boom.Type = Boom.self; n += t.inert() }
            let t = q
            return n + t.fire()
        }
        func reboundControl(_ q: Calm) -> Int { let t = q; return t.fire() }
        func reallyFires() -> Int { let t: Boom.Type = Boom.self; return t.fire() }

        protocol Val { static func validate() -> Int }
        struct V1: Val { static func validate() -> Int { return hsink() } }
        struct V2: Val { static func validate() -> Int { return 0 } }
        func viaClosureElem() -> Int {
            let validators: [Val.Type] = [V1.self, V2.self]
            return validators.map { v in v.validate() }.reduce(0, +)
        }
        func viaShorthandElem() -> Int {
            let validators: [Val.Type] = [V1.self, V2.self]
            return validators.map { $0.validate() }.reduce(0, +)
        }
        protocol QVal { static func validate() -> Int }
        struct Q1: QVal { static func validate() -> Int { return 3 } }
        func quietClosureElem() -> Int {
            let vs: [QVal.Type] = [Q1.self]
            return vs.map { v in v.validate() }.reduce(0, +)
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
            .appendingPathComponent("candor-r585-\(UUID().uuidString)")
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

    private func scan(_ sources: [String: String], env: [String: String] = [:]) throws
        -> ([String: [String: Any]], URL) {
        let bin = try binaryURL()
        let root = try render(sources)
        let out = root.appendingPathComponent("r")
        let r = try run(bin, [root.path, "--out", out.path], env: env)
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

    private static let classArms = ["b2c", "b3c", "b4c", "b5c", "b6c", "b7c", "b8c", "b9c", "b10c"]
    private static let protoArms = ["b2p", "b3p", "b4p", "b5p", "b6p", "b7p", "b8p", "b9p", "b10p"]

    // ── THE DEFECT ARMS ─────────────────────────────────────────────────────────────────────────

    /// The nine binders, CLASS half. `pure <fn>` is asserted beside `deny Net <fn>` because absence
    /// answers both the same way: a function missing from `functions[]` is certified pure under ⟨0.21⟩,
    /// so the two exits were one claim and both were 0.
    func testEveryClassMetatypeBinderCarriesTheHierarchysEffect() throws {
        let (by, root) = try scan(["b": Self.binderSource])
        for fn in Self.classArms + ["b1c", "ctlC"] {
            XCTAssertNotNil(by[fn], "\(fn) must not be ABSENT — under ⟨0.21⟩ that is a claim of purity")
            XCTAssertEqual(eff(by, fn), ["Net"],
                           "\(fn) runs CBase/CSub.validate, which reaches URLSession; got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net \(fn)"), 1, "`deny Net \(fn)` must catch it")
            XCTAssertEqual(try gate(root, "pure \(fn)"), 1, "`pure \(fn)` must catch it")
        }
    }

    /// The same nine binders, PROTOCOL half — R563's question asked of every binder rather than of the
    /// parameter clause alone.
    func testEveryProtocolMetatypeBinderReachesTheConformerCHA() throws {
        let (by, root) = try scan(["b": Self.binderSource])
        for fn in Self.protoArms + ["b1p", "ctlP"] {
            XCTAssertNotNil(by[fn], "\(fn) must not be ABSENT")
            XCTAssertEqual(eff(by, fn), ["Net"], "\(fn) got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net \(fn)"), 1, "`deny Net \(fn)` must catch it")
        }
    }

    /// §1b. The kill switch restores the pre-fix answer EXACTLY: the two controls keep resolving and
    /// all eighteen binder arms go back to ABSENT. This is what proves the assertions above can fail.
    func testTheKillSwitchRestoresTheSilence() throws {
        let (by, _) = try scan(["b": Self.binderSource], env: ["CANDOR_R585_OFF": "1"])
        for fn in ["ctlP", "ctlC", "b1p", "b1c"] {
            XCTAssertEqual(eff(by, fn), ["Net"], "\(fn) is a CONTROL and must resolve either way")
        }
        for fn in Self.classArms + Self.protoArms {
            XCTAssertNil(by[fn], "with R585 off, \(fn) must be ABSENT again — got \(eff(by, fn))")
        }
    }

    // ── THE OVER-CHARGE CONTROLS ────────────────────────────────────────────────────────────────

    /// THE DIRECTION THIS FIX DID NOT INTEND. The same nine binders over a hierarchy that performs
    /// nothing must gain nothing — and a blanket `deny` over each arm must exit 0. The instrument is
    /// calibrated on the same bytes: `NBase.reaches` IS caught, so a policy that passes here is a
    /// policy that could have failed (`candor-oracle-disclosure-recall`).
    func testAPureHierarchyThroughEveryBinderGainsNothing() throws {
        let (by, root) = try scan(["o": Self.overChargeSource])
        XCTAssertEqual(eff(by, "NBase.reaches"), ["Net"],
                       "the instrument must be able to fail; got \(eff(by, "NBase.reaches"))")
        XCTAssertEqual(try gate(root, "deny Net Fs Env NBase.reaches"), 1,
                       "the gate must be able to fail on these same bytes")
        for n in 1...10 {
            for half in ["p", "c"] {
                let fn = "o\(n)\(half)"
                XCTAssertTrue(eff(by, fn).isEmpty,
                              "\(fn) drives a PURE hierarchy and must gain nothing; got \(eff(by, fn))")
                XCTAssertEqual(try gate(root, "deny Net Fs Env \(fn)"), 0,
                               "`deny Net Fs Env \(fn)` must stay clean")
            }
        }
    }

    /// THE MEMBER CONTROL. `NBase` DOES reach the network, through `reaches()`. Every arm here binds
    /// `NBase.Type` through a different binder and calls only `inert()`. A fix that charged the TYPE
    /// rather than the CALL would charge every one of them.
    func testTheEffectfulNeighboursInertMemberIsNotCharged() throws {
        let (by, root) = try scan(["o": Self.overChargeSource])
        for fn in ["m2c", "m4c", "m6c", "m7c", "m9c", "m10c"] {
            XCTAssertTrue(eff(by, fn).isEmpty,
                          "\(fn) calls NBase.inert, not NBase.reaches; got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net \(fn)"), 0, "`deny Net \(fn)` must stay clean")
        }
    }

    /// THE REBIND CONTROL. `metatypeBinders` is a per-BINDING fact, so it must die with the binding.
    /// `rebound` binds `t` to `Boom.Type` in an inner scope and then to a `Calm` VALUE; the call after
    /// the rebind runs `Calm.fire`, which is pure. A leaked entry resolves `Boom.fire` and charges Net.
    /// `reallyFires` is the discriminating control — the same metatype binder, the same member, and it
    /// IS charged, so absence above is a fact about the rebind and not about the fixture.
    func testARebindDropsTheMetatypeBinding() throws {
        let (by, root) = try scan(["s": Self.shadowSource])
        XCTAssertEqual(eff(by, "reallyFires"), ["Net"],
                       "control: the metatype binder must charge when it is NOT rebound")
        XCTAssertTrue(eff(by, "rebound").isEmpty,
                      "the metatype binding must not outlive its scope; got \(eff(by, "rebound"))")
        XCTAssertTrue(eff(by, "reboundControl").isEmpty,
                      "rename control: the same body with no metatype binder at all")
        XCTAssertEqual(try gate(root, "deny Net rebound"), 0)
        XCTAssertEqual(try gate(root, "deny Net reallyFires"), 1)
    }

    /// THE ITERATOR-ELEMENT ARM, measured rather than anticipated: swift-argument-parser's
    /// `let validators: [X.Type] = […]` + `validators.map { v in v.validate() }` is the idiom, and the
    /// for-in binder does not reach it. Both the NAMED and the `$0` spellings, plus the pure twin.
    func testAnIteratorElementOfAMetatypeArrayResolves() throws {
        let (by, root) = try scan(["s": Self.shadowSource])
        for fn in ["viaClosureElem", "viaShorthandElem"] {
            XCTAssertEqual(eff(by, fn), ["Net"], "\(fn) runs V1.validate; got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net \(fn)"), 1)
        }
        XCTAssertTrue(eff(by, "quietClosureElem").isEmpty,
                      "the PURE twin of the same spelling must gain nothing; got \(eff(by, "quietClosureElem"))")
        XCTAssertEqual(try gate(root, "deny Net quietClosureElem"), 0)
    }
}
