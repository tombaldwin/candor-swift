import XCTest
import Foundation

/// R215 — AN UNANNOTATED `let`/`var` COPY OF AN ALREADY-TYPED VALUE WAS TYPED NOWHERE, SO THE COPY'S
/// ELEMENT INDEX (AND ITS SCALAR TYPE) WERE DROPPED AND THE ENCLOSING FUNCTION VANISHED.
///
/// `stores.forEach { $0.eff() }` charges `Fs`. `let ys: [Store] = stores; ys.forEach { $0.eff() }`
/// charges `Fs`. `let ys = stores; ys.forEach { $0.eff() }` — the same program with the annotation
/// removed — reported the enclosing function ABSENT from `functions[]`: no effects, no `Unknown`, no
/// row. NOMINAL element types, not only callable ones, which is why R192 and R211 (both about
/// callables) left it standing. It is also why Kingfisher scored ZERO instrumented branch hits for
/// R211: its real `let blocks = pendingBlocks; blocks.forEach { $0() }` is an instance of THIS.
///
/// THE MECHANISM. Every other initializer shape in `visit(VariableDeclSyntax)`'s unannotated chain
/// reaches a resolver — a ctor/factory call and a cast/ternary/subscript both go to `rootOf`, an array
/// literal to its own elements — and a plain COPY reached none of them: the DeclReference arm answers
/// only a `localFreeFns` NAME and the MemberAccess arm only a singleton accessor. So `arrayElem`,
/// `dictElem` and `vars` were all dropped. The fix consults the three resolvers that already hold the
/// answer, in the order the ANNOTATED binder asks them (container before scalar).
///
/// GROUND TRUTH IS EXECUTED, NOT ASSUMED (§E3). `copyFixture` compiles and runs as a program: every
/// `copy*`/`direct*` really performs the effect and every `ctl*` really does not, verified by a counter
/// bumped inside the effectful body. Absence is what a broken engine and a genuinely pure function both
/// produce, so an absence control over a fixture that cannot run asserts nothing.
///
/// THE FAILURE DIRECTION IS OVER-CHARGE. Extending type inference can only ADD resolutions, so a
/// spurious effect on the overwhelmingly common `let ys = xs` is the risk: `ctlPureColl`,
/// `ctlNeverIterated` and `ctlShadow` are effect-free programs that must stay absent. The second risk —
/// the one that bit R192's fix — is precision displacement, a copy resolving WORSE than its source:
/// every `copy*` cell is paired with the direct spelling it must match, and `testCopyMatchesDirect`
/// asserts the pairing rather than a hard-coded effect set.
///
/// TWO SHAPES DELIBERATELY LEFT OPEN, named rather than left to be rediscovered:
/// - `ctlCallReturn` — `let ys = makeStores(); ys.forEach { $0.eff() }` REALLY performs Fs and stays
///   ABSENT. `elementTypeOf` declines to guess an element type from a call return (Alamofire's
///   `finishHandlers` is the real instance) and this fix does not change that. It is an accepted
///   under-report pinned at its boundary, NOT evidence of no over-charge.
/// - `ctlMemberScalar` — a MEMBER-ACCESS copy gets its container element type here but not its scalar
///   one, because `rootOf`'s member arm falls through to the BASE's type for a member it cannot place.
final class CopiedContainerBinderTests: XCTestCase {

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

    private func effects(_ f: [String: Any]?) -> Set<String> { Set((f?["inferred"] as? [String]) ?? []) }
    private func why(_ f: [String: Any]?) -> Set<String> { Set((f?["unknownWhy"] as? [String]) ?? []) }
    private func calls(_ f: [String: Any]?) -> Set<String> { Set((f?["calls"] as? [String]) ?? []) }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // The fixture. It COMPILES AND RUNS — see `testFixtureGroundTruthExecutes`.
    // ────────────────────────────────────────────────────────────────────────────────────────────────
    static let copyFixture = """
    import Foundation

    struct Store { func eff() { try? "x".write(toFile: "/tmp/r215-store.txt", atomically: true, encoding: .utf8) } }
    struct Calc  { let n: Int; func calc() -> Int { n + 1 } }

    struct Inner { func run() { } }                                  // PURE
    struct Outer { let inner = Inner()                               // …beside an EFFECTFUL same-named method
                   func run() { try? "x".write(toFile: "/tmp/r215-outer.txt", atomically: true, encoding: .utf8) } }

    func makeStores() -> [Store] { [Store()] }

    let globalStores: [Store] = [Store()]

    final class H {
      var one: Store = Store()
      var stores: [Store] = []
      var blocks: [() -> Void] = []
      var byKey: [String: Store] = [:]
      var calcs: [Calc] = []
      var box: Outer = Outer()

      func install() {
        stores = [Store()]
        blocks = [{ _ = try? String(contentsOfFile: "/tmp/r215-b.txt") }]
        byKey["k"] = Store()
        calcs = [Calc(n: 1)]
      }

      // the direct spellings each copy must MATCH — these already resolved before this fix
      func directForEach()   { stores.forEach { $0.eff() } }
      func directFor()       { for s in stores { s.eff() } }
      func directDictPair()  { for (_, v) in byKey { v.eff() } }
      func directDictValues(){ byKey.values.forEach { $0.eff() } }
      func directScalar()    { one.eff() }
      func directGlobal()    { globalStores.forEach { $0.eff() } }
      func directClosures()  { blocks.forEach { $0() } }
      func annotatedCopy()   { let ys: [Store] = stores; ys.forEach { $0.eff() } }

      // R215 — every one of these was ABSENT on the shipped 0.35.0 binary
      func copyForEach()         { let ys = stores; ys.forEach { $0.eff() } }
      func copyFor()             { let ys = stores; for y in ys { y.eff() } }
      func copyParam(_ s: [Store]) { let ys = s; ys.forEach { $0.eff() } }
      func copyOfLocal()         { let a: [Store] = stores; let ys = a; ys.forEach { $0.eff() } }
      func copyOfSelfField()     { let ys = self.stores; ys.forEach { $0.eff() } }
      func copyGlobal()          { let ys = globalStores; ys.forEach { $0.eff() } }
      func copyDictPair()        { let m = byKey; for (_, v) in m { v.eff() } }
      func copyDictValues()      { let m = byKey; m.values.forEach { $0.eff() } }
      func copyChain()           { let a = stores; let b = a; b.forEach { $0.eff() } }
      func copyVar()             { var ys = stores; ys.forEach { $0.eff() }; ys = [] }
      func copyClosures()        { let ys = blocks; ys.forEach { $0() } }
      func copyScalarField()     { let s = one; s.eff() }
      func copyScalarParam(_ p: Store) { let s = p; s.eff() }

      // must stay ABSENT — effect-free programs, the over-charge controls
      func ctlPureColl() -> Int    { let ys = calcs; var t = 0; for y in ys { t += y.calc() }; return t }
      func ctlNeverIterated() -> Int { let ys = stores; return ys.count }
      func ctlShadow() -> Int      { let ys = stores; let zs = calcs; _ = ys.count
                                     var t = 0; for z in zs { t += z.calc() }; return t }
      // must stay ABSENT — a KNOWN LIMIT, not an over-charge control: this one really performs Fs
      func ctlCallReturn()         { let ys = makeStores(); ys.forEach { $0.eff() } }
      // must stay ABSENT — a member-access copy gets no SCALAR type (see the type doc); really pure here
      func ctlMemberScalar()       { let x = box.inner; x.run() }
    }
    """

    /// The row's own cells: ABSENT before, charged now, and each one really performs the effect.
    func testAnUnannotatedCopyOfAContainerResolvesItsElements() throws {
        let by = try scan(Self.copyFixture, "Copy")
        for fn in ["H.copyForEach", "H.copyFor", "H.copyParam", "H.copyOfLocal", "H.copyOfSelfField",
                   "H.copyGlobal", "H.copyDictPair", "H.copyDictValues", "H.copyChain", "H.copyVar",
                   "H.copyScalarField", "H.copyScalarParam"] {
            let f = by[fn]
            XCTAssertNotNil(f, "\(fn) must be reported — it really writes a file "
                            + "(see testFixtureGroundTruthExecutes). ABSENT is the cardinal sin.")
            XCTAssertTrue(effects(f).contains("Fs"),
                          "\(fn) must carry Fs — the copy holds the same Stores its source does. got \(effects(f))")
            XCTAssertTrue(calls(f).contains("Store.eff"),
                          "\(fn) must keep the CONCRETE edge, not settle for a hedge. got \(calls(f))")
        }
    }

    /// The callable element travels through the copy too — R211's answer, reached through R215's binder.
    func testAnUnannotatedCopyOfAContainerOfClosuresIsDisclosed() throws {
        let by = try scan(Self.copyFixture, "Copy")
        let f = by["H.copyClosures"]
        XCTAssertNotNil(f, "H.copyClosures must be reported — it invokes a caller-supplied closure")
        XCTAssertTrue(effects(f).contains("Unknown"), "got \(effects(f))")
        XCTAssertTrue(why(f).contains { $0.hasPrefix("callback:") || $0.hasPrefix("dispatch:") },
                      "an Unknown with no reason is the R180 shape. got \(why(f))")
    }

    /// PRECISION DISPLACEMENT — the risk that bit R192's fix. A copy must answer exactly what the
    /// direct spelling answers; asserted as a PAIRING so it cannot drift to a stale hard-coded set.
    func testCopyMatchesDirect() throws {
        let by = try scan(Self.copyFixture, "Copy")
        for (copy, direct) in [("H.copyForEach", "H.directForEach"), ("H.copyFor", "H.directFor"),
                               ("H.copyDictPair", "H.directDictPair"),
                               ("H.copyDictValues", "H.directDictValues"),
                               ("H.copyScalarField", "H.directScalar"),
                               ("H.copyGlobal", "H.directGlobal"),
                               ("H.copyClosures", "H.directClosures"),
                               ("H.copyForEach", "H.annotatedCopy")] {
            XCTAssertEqual(effects(by[copy]), effects(by[direct]),
                           "\(copy) must answer what \(direct) answers — the same program, one spelling apart")
            XCTAssertEqual(calls(by[copy]), calls(by[direct]),
                           "\(copy) must keep \(direct)'s call edges")
        }
    }

    /// THE OVER-CHARGE CONTROLS. These programs really perform nothing (executed), so a row here is a
    /// fabrication — the direction extending type inference fails in.
    func testEffectFreeCopiesStayAbsent() throws {
        let by = try scan(Self.copyFixture, "Copy")
        for fn in ["H.ctlPureColl", "H.ctlNeverIterated", "H.ctlShadow", "H.ctlMemberScalar"] {
            XCTAssertNil(by[fn], "\(fn) performs nothing when executed — a row is a fabrication. "
                         + "got \(String(describing: by[fn]?["inferred"]))")
        }
    }

    /// THE STATED LIMIT, pinned at its boundary. `ctlCallReturn` DOES write a file; it stays absent
    /// because `elementTypeOf` will not guess an element type from a call return, which is what keeps
    /// Alamofire's `finishHandlers` from being guessed at. If this ever starts passing, the fix has
    /// grown past the boundary this row drew and the guess needs its own evidence.
    func testAnElementTypeIsNotGuessedFromACallReturn() throws {
        let by = try scan(Self.copyFixture, "Copy")
        XCTAssertNil(by["H.ctlCallReturn"],
                     "a call return must not be given an element type; this is an ACCEPTED under-report, "
                     + "not a claim of purity — see the type doc")
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // R215's NEIGHBOUR — a bare argument identifier resolved against a same-named FREE FUNCTION.
    // ────────────────────────────────────────────────────────────────────────────────────────────────

    /// PRE-EXISTING, and measured as such on the shipped `969effa` with an ordinary ctor-typed receiver
    /// — R215's fix multiplies its reach rather than causing it. `argKinds` recorded every bare
    /// identifier argument as `.named(n)`, and the Driver's callback-flow discharges a deferred callback
    /// parameter by looking `n` up in `freeFnByName`. So a LOCAL `combine` forwarded to a HOF resolved
    /// against an unrelated `private func combine` elsewhere in the tree: the HOF — which really does
    /// invoke a caller-supplied closure — went from `['Unknown'] callback:combine` to ABSENT. GRDB's
    /// `OrderedDictionary.merge(_:uniquingKeysWith:)` is the real-code instance.
    static let collisionFixture = """
    import Foundation

    struct Expr { }
    private func combine(_ a: Expr, _ b: Expr, with op: (Expr, Expr) -> Expr) -> Expr { op(a, b) }

    func realWork() { try? "x".write(toFile: "/tmp/r215-free.txt", atomically: true, encoding: .utf8) }

    struct Bag {
      var d: [String: Int] = [:]
      mutating func merge(_ other: [(String, Int)], uniquingKeysWith combine: (Int, Int) -> Int) {
        for (k, v) in other { if let cur = d[k] { d[k] = combine(cur, v) } else { d[k] = v } }
      }
      func merging(_ other: [(String, Int)], uniquingKeysWith combine: (Int, Int) -> Int) -> Bag {
        var result = self
        result.merge(other, uniquingKeysWith: combine)
        return result
      }
    }

    struct Hof { func run(_ cb: () -> Void) { cb() } }
    func passesAFreeFunction() { Hof().run(realWork) }
    """

    func testALocalForwardedToAHofIsNotResolvedAgainstASameNamedFreeFunction() throws {
        let by = try scan(Self.collisionFixture, "Collide")
        let merge = by["Bag.merge"]
        XCTAssertNotNil(merge, "Bag.merge invokes a caller-supplied closure — ABSENT certifies it pure")
        XCTAssertTrue(effects(merge).contains("Unknown"), "got \(effects(merge))")
        XCTAssertTrue(why(merge).contains("callback:combine"),
                      "the reason must name the parameter, not the unrelated free function. got \(why(merge))")
        let merging = by["Bag.merging"]
        XCTAssertNotNil(merging, "Bag.merging forwards the callback and must disclose it too")
        XCTAssertTrue(why(merging).contains("callback:combine"),
                      "a reasonless Unknown here is the R180 shape. got \(why(merging))")
    }

    /// THE PRECISION CONTROL FOR THAT GUARD — it refuses only names it can place as LOCAL. A genuine
    /// free-function reference passed to a HOF must still resolve to the real unit, or the guard has
    /// traded a fabrication for a lost effect.
    func testAGenuineFreeFunctionReferenceStillResolves() throws {
        let by = try scan(Self.collisionFixture, "Collide")
        let f = by["passesAFreeFunction"]
        XCTAssertNotNil(f, "passesAFreeFunction reaches realWork's Fs through the HOF")
        XCTAssertTrue(effects(f).contains("Fs"),
                      "the named free function must still be resolved through callback-flow. got \(effects(f))")
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────────
    // EXECUTED GROUND TRUTH (§E3) — the fixture is a real program and the cells really do what the
    // assertions above say they do. An absence assertion over an unreachable fixture asserts nothing.
    // ────────────────────────────────────────────────────────────────────────────────────────────────
    func testFixtureGroundTruthExecutes() throws {
        #if os(macOS) || os(Linux)
        let env = URL(fileURLWithPath: "/usr/bin/env")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r215-gt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let instrumented = Self.copyFixture
            .replacingOccurrences(of: "import Foundation", with: "import Foundation\nvar FIRES = 0")
            .replacingOccurrences(of: "func eff() { try?", with: "func eff() { FIRES += 1; try?")
            .replacingOccurrences(of: "func run() { try?", with: "func run() { FIRES += 1; try?")
            .replacingOccurrences(of: "{ _ = try? String(contentsOfFile: \"/tmp/r215-b.txt\") }",
                                  with: "{ FIRES += 1; _ = try? String(contentsOfFile: \"/tmp/r215-b.txt\") }")
            + """

            let h = H(); h.install()
            var log: [String: Bool] = [:]
            func chk(_ n: String, _ body: () -> Void) { let b = FIRES; body(); log[n] = FIRES > b }
            chk("directForEach", h.directForEach); chk("directFor", h.directFor)
            chk("directDictPair", h.directDictPair); chk("directDictValues", h.directDictValues)
            chk("directScalar", h.directScalar); chk("directGlobal", h.directGlobal)
            chk("directClosures", h.directClosures); chk("annotatedCopy", h.annotatedCopy)
            chk("copyForEach", h.copyForEach); chk("copyFor", h.copyFor)
            chk("copyParam", { h.copyParam(h.stores) }); chk("copyOfLocal", h.copyOfLocal)
            chk("copyOfSelfField", h.copyOfSelfField); chk("copyGlobal", h.copyGlobal)
            chk("copyDictPair", h.copyDictPair); chk("copyDictValues", h.copyDictValues)
            chk("copyChain", h.copyChain); chk("copyVar", h.copyVar)
            chk("copyClosures", h.copyClosures)
            chk("copyScalarField", h.copyScalarField)
            chk("copyScalarParam", { h.copyScalarParam(Store()) })
            chk("ctlPureColl", { _ = h.ctlPureColl() })
            chk("ctlNeverIterated", { _ = h.ctlNeverIterated() })
            chk("ctlShadow", { _ = h.ctlShadow() })
            chk("ctlCallReturn", h.ctlCallReturn)
            chk("ctlMemberScalar", h.ctlMemberScalar)
            for (k, v) in log.sorted(by: { $0.key < $1.key }) { print("\\(v ? "FIRES" : "quiet") \\(k)") }
            """

        let src = dir.appendingPathComponent("gt.swift")
        try instrumented.write(to: src, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(env, ["swift", src.path], cwd: dir)
        XCTAssertEqual(r.code, 0, "the fixture must COMPILE AND RUN — an absence control over a program "
                       + "that cannot run asserts nothing (§E3).\n\(r.err)")
        var fired: Set<String> = [], quiet: Set<String> = []
        for line in r.out.split(separator: "\n") {
            let p = line.split(separator: " ")
            guard p.count == 2 else { continue }
            if p[0] == "FIRES" { fired.insert(String(p[1])) } else { quiet.insert(String(p[1])) }
        }
        for n in ["directForEach", "directFor", "directDictPair", "directDictValues", "directScalar",
                  "directGlobal", "directClosures", "annotatedCopy", "copyForEach", "copyFor",
                  "copyParam", "copyOfLocal", "copyOfSelfField", "copyGlobal", "copyDictPair",
                  "copyDictValues", "copyChain", "copyVar", "copyClosures", "copyScalarField",
                  "copyScalarParam", "ctlCallReturn"] {
            XCTAssertTrue(fired.contains(n), "\(n) must really perform the effect. out:\n\(r.out)")
        }
        for n in ["ctlPureColl", "ctlNeverIterated", "ctlShadow", "ctlMemberScalar"] {
            XCTAssertTrue(quiet.contains(n), "\(n) must really perform NOTHING. out:\n\(r.out)")
        }
        #endif
    }
}
