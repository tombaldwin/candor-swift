import XCTest
import Foundation

/// Process-level pins for the SCAN-BOUNDARY vein: code candor analyses SOUNDLY inside one package,
/// split across a package boundary with the dependency's report chained via `CANDOR_DEPS` — the
/// arrangement candor's own docs recommend — and the effect DISAPPEARS.
/// (candor-spec/SOUNDNESS-VEIN-crossing-the-scan-boundary.md; reproduced in all four engines.)
///
/// Every case here is checked against a ONE-PACKAGE CONTROL holding byte-identical function bodies,
/// so a failure is a boundary effect and never a general limitation. The gate is the point: the
/// under-report is not merely report-level, it flips `deny` from exit 1 (violation, correct) to
/// exit 0 (a false all-clear) on identical source.
final class ScanBoundaryVeinProcessTests: XCTestCase {

    /// See ProcessHarness.binaryURL — the private copy this replaced resolved WRONG on Linux.
    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: ScanBoundaryVeinProcessTests.self)
    }

    private func run(_ binary: URL, _ args: [String], env: [String: String] = [:]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT"] {
            environment.removeValue(forKey: k)
        }
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self), p.terminationStatus)
    }

    /// The dependency's source. `Entry.description` reaches Env, so EVERY implicit stringification of
    /// an `Entry` runs it; `Plain.description` is pure and is the no-fabrication control (a pure
    /// witness is absent from the dep report, so joining must add nothing).
    private static let depSource = """
    import Foundation

    public struct Entry: CustomStringConvertible {
        public init() {}
        public var description: String {
            let v = ProcessInfo.processInfo.environment["ENTRY_FMT"] ?? ""
            return "entry\\(v)"
        }
    }

    public struct Plain: CustomStringConvertible {
        public init() {}
        public var description: String { return "plain" }
    }

    public final class Guardian {
        public init() {}
        deinit { _ = ProcessInfo.processInfo.environment["GUARD_EXIT"] }
    }

    public final class Quiet {
        public init() {}
        deinit { }
    }

    public protocol Speaker { func speak() }

    // A PURE FACTORY returning the protocol. Pure fns are omitted from a report, so no return type ever
    // travels — the consumer cannot type the binding and never forms a key (half 1, row 2).
    public final class LibSpeaker: Speaker {
        public init() {}
        public func speak() { _ = FileManager.default.contents(atPath: "/lib-speak") }
    }
    public func makeSpeaker() -> Speaker { return LibSpeaker() }

    public final class LoudSpeaker: Speaker {
        public init() {}
        public func speak() { _ = FileManager.default.contents(atPath: "/loud") }
    }
    """

    /// The consumer's source, with `IMPORT` replaced by `import DepLib` (split) or nothing (control).
    /// Three stringification forms, all of which resolve through the same operand-type resolver:
    /// a declared-type operand, an inline construction, and a `[Entry]` element bound to `$0`.
    private static let appSource = """
    IMPORT
    public func describeTyped(_ e: Entry) -> String { return "got \\(e)" }
    public func describeInline() -> String { return "got \\(Entry())" }
    public func describeMapped(_ es: [Entry]) -> [String] { return es.map { "\\($0)" } }
    public func describePure(_ p: Plain) -> String { return "got \\(p)" }
    public func scoped() { let g = Guardian(); _ = g }
    public func scopedQuiet() { let q = Quiet(); _ = q }
    public func handOut() -> Guardian { let g = Guardian(); return g }

    // dispatch over an IMPORTED protocol whose conformer is declared HERE
    public final class AppSpeaker: Speaker {
        public init() {}
        public func speak() { _ = ProcessInfo.processInfo.environment["APP_SPEAK"] }
    }
    public func viaFactoryBoundReceiver() { let s = makeSpeaker(); s.speak() }
    public func viaImportedProtocol(_ s: Speaker) { s.speak() }
    public func viaImportedProtocolLocal() { let s: Speaker = AppSpeaker(); s.speak() }

    // ERASURE GUARD for the same rung. `some Speaker` is OPAQUE: the CALLER picks one concrete type, so
    // the conformers visible here are NOT its candidate witnesses and unioning them charges effects this
    // function cannot perform. `any Speaker` is an existential and genuinely may be any of them.
    // `typeName` collapses both spellings to `Speaker`, so without an explicit check `some` inherits the
    // existential's CHA — measured, this function was charged AppSpeaker's Env.
    public func viaOpaqueImported(_ s: some Speaker) { s.speak() }
    public func viaExistentialImported(_ s: any Speaker) { s.speak() }

    // THE SAME QUESTION, FOUR MORE DOORS. `some P` in a parameter is the only spelling whose opacity is
    // visible on the parameter's own type. These reach the CHA with a receiver typed `Speaker` too, and
    // each one is monomorphized just as hard — a `[T]` element under a `<T: Speaker>` bound, its `some`
    // sugar, the `forEach` closure form of both, and a field typed as the enclosing type's generic param.
    // Each was measured charging AppSpeaker's Env; each is called here ONLY with the pure conformer.
    public func viaGenericElement<T: Speaker>(_ xs: [T]) { for x in xs { x.speak() } }
    public func viaOpaqueElement(_ xs: [some Speaker]) { for x in xs { x.speak() } }
    public func viaGenericForEach<T: Speaker>(_ xs: [T]) { xs.forEach { $0.speak() } }
    public struct Relay<T: Speaker> {
        public var inner: T
        public init(inner: T) { self.inner = inner }
        public func run() { inner.speak() }
    }
    // …and the ERASED CONTROLS for the same three shapes. These are the rung itself and must KEEP
    // dispatching — without them a fix that simply stopped resolving container elements would pass.
    public func viaExistentialElement(_ xs: [any Speaker]) { for x in xs { x.speak() } }
    public func viaExistentialForEach(_ xs: [any Speaker]) { xs.forEach { $0.speak() } }
    public struct ErasedRelay {
        public var inner: any Speaker
        public init(inner: any Speaker) { self.inner = inner }
        public func run() { inner.speak() }
    }
    // The single PURE call site for the monomorphized forms, so "cannot perform Env" is a fact about
    // this program and not only an argument about Swift's semantics.
    public final class QuietSpeaker: Speaker {
        public init() {}
        public func speak() { }
    }
    public func callsTheMonomorphizedOnesWithAPureConformer() {
        [QuietSpeaker()].speakAll()
        viaGenericElement([QuietSpeaker()])
        viaOpaqueElement([QuietSpeaker()])
        viaGenericForEach([QuietSpeaker()])
        Relay(inner: QuietSpeaker()).run()
        elemOpacityRestoredAfterShadow([QuietSpeaker()], true)
        nestedFuncOwnOpacity(QuietSpeaker())
        nestedFuncOwnElementOpacity([QuietSpeaker()])
        opaqueAfterNestedFuncShadow(QuietSpeaker())
        ternaryBothOpaque(QuietSpeaker(), QuietSpeaker(), true)
    }
    public func mystery() -> Any { return 0 }

    // SHADOWING, both directions. The opaque set is keyed by NAME, so a binder that REBINDS the name
    // leaves a receiver that is not the opaque parameter at all — suppressing the CHA there makes an
    // effectful call read silent-pure. `shadowed*` must RESOLVE.
    public func shadowedByLoop(_ s: some Speaker, _ all: [Speaker]) { for s in all { s.speak() } }
    public func shadowedByClosure(_ s: some Speaker, _ all: [Speaker]) {
        all.forEach { (s: Speaker) in s.speak() }
    }
    public func shadowedByIfLet(_ s: some Speaker, _ o: Speaker?) { if let s = o { s.speak() } }
    public func shadowedByLet(_ s: some Speaker, _ all: [Speaker]) { let s = all[0]; s.speak() }
    public func shadowedByGuardLet(_ s: some Speaker, _ o: Speaker?) {
        guard let s = o else { return }
        s.speak()
    }
    // …and the OTHER direction: once the shadowing SCOPE closes, `s` is the opaque parameter again and
    // the suppression must be BACK, or clearing it re-opens the fabrication d62dd69 closed.
    public func opaqueAfterLoopShadow(_ s: some Speaker, _ all: [Speaker]) {
        for s in all { _ = s }
        s.speak()
    }
    public func opaqueAfterClosureShadow(_ s: some Speaker, _ all: [Speaker]) {
        all.forEach { (s: Speaker) in _ = s }
        s.speak()
    }
    public func opaqueAfterIfLetShadow(_ s: some Speaker, _ o: Speaker?) {
        if let s = o { _ = s }
        s.speak()
    }
    // MECHANISM CONTROLS: the same bodies with a binder name that does NOT collide with the opaque
    // parameter. These must resolve in BOTH arms — they are what proves a `shadowed*` miss is the
    // name-keyed suppression and not a typing failure.
    public func loopNoShadow(_ x: some Speaker, _ all: [Speaker]) { for s in all { s.speak() } }
    public func closureNoShadow(_ x: some Speaker, _ all: [Speaker]) {
        all.forEach { (s: Speaker) in s.speak() }
    }
    public func ifLetNoShadow(_ x: some Speaker, _ o: Speaker?) { if let s = o { s.speak() } }
    public func letNoShadow(_ x: some Speaker, _ all: [Speaker]) { let s = all[0]; s.speak() }
    public func guardLetNoShadow(_ x: some Speaker, _ o: Speaker?) {
        guard let s = o else { return }
        s.speak()
    }

    // THE CONTAINER FORM OF THE SAME SCOPE QUESTION — the half 02fb0ad shipped without. The element
    // opacity moves in lockstep with the element TYPE, which is the CLEAR half of the discipline (a
    // rebind cannot leave stale opacity behind a fresh type) and says nothing about the RESTORE half.
    // An inner block binding an EXISTING name from a monomorphized source outlived the block, so the
    // ERASED parameter it shadowed spent the rest of the body with the CHA suppressed — silent-pure.
    // `elemOpacityNoShadow` is the mechanism control: byte-identical body, binder renamed.
    public func elemOpacityAfterBlockShadow(_ xs: [some Speaker], _ ys: [any Speaker], _ c: Bool) {
        if c {
            let ys = xs.filter { _ in true }
            _ = ys
        }
        for y in ys { y.speak() }
    }
    public func elemOpacityNoShadow(_ xs: [some Speaker], _ ys: [any Speaker], _ c: Bool) {
        if c {
            let zs = xs.filter { _ in true }
            _ = zs
        }
        for y in ys { y.speak() }
    }
    // A NESTED `func` HAS ITS OWN SIGNATURE, and its calls attribute to this enclosing unit. The
    // opacity set is keyed by NAME, so `inner`'s genuinely ERASED receiver inherited the enclosing
    // parameter's `some` and read silent-pure. `nestedFuncNoShadow` is the mechanism control: the same
    // body with the OUTER parameter spelled `any`, which must resolve in both arms.
    public func nestedFuncOwnParam(_ s: some Speaker) {
        func inner(_ s: any Speaker) { s.speak() }
        inner(QuietSpeaker())
    }
    public func nestedFuncNoShadow(_ s: any Speaker) {
        func inner(_ s: any Speaker) { s.speak() }
        inner(QuietSpeaker())
    }
    // …and the mirror: a shadow ALONE would let a nested `some P` parameter start dispatching over the
    // local conformers inside an ERASED outer, which is the fabrication the erasure gate exists to stop.
    public func nestedFuncOwnOpacity(_ s: any Speaker) {
        func inner(_ s: some Speaker) { s.speak() }
        inner(QuietSpeaker())
    }
    public func nestedFuncOwnElementOpacity(_ xs: [any Speaker]) {
        func inner(_ xs: [some Speaker]) { for x in xs { x.speak() } }
        inner([QuietSpeaker()])
    }
    // …and once the nested `func` CLOSES, the enclosing parameter is opaque again.
    public func opaqueAfterNestedFuncShadow(_ s: some Speaker) {
        func inner(_ s: any Speaker) { _ = s }
        inner(QuietSpeaker())
        s.speak()
    }
    // …and the OTHER direction, which is why this is a SCOPE and not a clear: once the shadowing block
    // closes, `xs` is the monomorphized parameter again and the suppression must be BACK. Dropping the
    // opacity instead re-opens the fabrication 02fb0ad closed.
    public func elemOpacityRestoredAfterShadow(_ xs: [some Speaker], _ c: Bool) {
        if c {
            let xs: [any Speaker] = []
            _ = xs
        }
        for x in xs { x.speak() }
    }

    // BINDER FORMS `patternNames` COULD NOT SEE. It enumerated three of the seven `PatternSyntax`
    // kinds, so `for case let x?` / `for case let x as T` / `for var x` never reached `shadowName` at
    // all and the enclosing signature's flags stayed attached to the loop's own, unrelated binding.
    // Each `…NoShadow` row is the mechanism control (identical body, binder renamed).
    public func forCaseOptionalShadow(_ s: some Speaker, _ all: [Speaker?]) {
        for case let s? in all { s.speak() }
    }
    public func forCaseOptionalNoShadow(_ q: some Speaker, _ all: [Speaker?]) {
        for case let s? in all { s.speak() }
    }
    public func forCaseCastShadow(_ s: some Speaker, _ all: [Any]) {
        for case let s as Speaker in all { s.speak() }
    }
    public func forCaseCastNoShadow(_ q: some Speaker, _ all: [Any]) {
        for case let s as Speaker in all { s.speak() }
    }
    public func forVarShadow(_ s: some Speaker, _ all: [Speaker]) { for var s in all { s.speak() } }
    public func forVarNoShadow(_ q: some Speaker, _ all: [Speaker]) { for var s in all { s.speak() } }

    // THE CATCH-ALL's own row, and it is a FABRICATION rather than a miss. `case let .quiet(s)` writes
    // the `let` OUTSIDE the case pattern, so the argument is a bare `patternExpr > identifierPattern`
    // with no `ValueBindingPattern` for `typeEnumCaseBinding` to match — it claims nothing and types
    // nothing. The binder then kept the enclosing parameter's `AppSpeaker` type and `s.speak()`
    // resolved to a body this case cannot reach. `visit(IdentifierPatternSyntax)` clears any binder no
    // specific visitor claimed, which is why an unenumerated form is now safe by default.
    public enum Payload { case quiet(QuietSpeaker) }
    public func caseLetOutsideBindsItsOwnValue(_ s: AppSpeaker, _ p: Payload) {
        switch p { case let .quiet(s): s.speak() }
    }

    // A LOOP BINDER'S TYPE DOES NOT OUTLIVE THE LOOP. `vars` is function-wide by design, so the loop's
    // concrete `QuietSpeaker` used to survive past the loop and answer for the ERASED parameter it
    // shadowed — `s.speak()` resolved to the pure conformer's own body and the existential's dispatch
    // was lost. The `…NoShadow` control keeps the parameter's own name free of the loop.
    public func loopTypeDoesNotOutliveTheLoop(_ s: any Speaker, _ all: [QuietSpeaker]) {
        for s in all { _ = s }
        s.speak()
    }
    public func loopTypeNoShadow(_ s: any Speaker, _ all: [QuietSpeaker]) {
        for q in all { _ = q }
        s.speak()
    }

    // The MIRROR of the same missed binder, on half 1's provenance set: a `for case let c?` binder is a
    // purely local value, so it must NOT inherit the factory's provenance and disclose `Unknown`…
    public func provenanceNotOntoOptionalBinder(_ xs: [Any?]) {
        let c = makeSpeaker()
        for case let c? in xs { _ = c.notAThing() }
        _ = c
    }
    // …and once that loop CLOSES, `c` is the factory-bound receiver again and must disclose.
    public func provenanceRestoredAfterOptionalBinder(_ xs: [Any?]) {
        let c = makeSpeaker()
        for case let c? in xs { _ = c }
        c.speak()
    }

    // OPACITY ACROSS A TERNARY. `(c ? m : e).speak()` has TWO receivers, and `rootOf` composed their
    // opacity with `||` — so one monomorphized arm certified an ERASED sibling and the CHA was skipped
    // for both. All three compositions are asserted, because each single row is satisfiable by a wrong
    // fix: MIXED must dispatch (the erased arm's witnesses ARE the local conformers), ERASED/ERASED
    // must dispatch (a fix that simply stopped resolving ternaries would satisfy the first row), and
    // MONO/MONO must stay suppressed (dropping the claim entirely re-opens d62dd69's fabrication).
    public func ternaryMixedOpacity(_ m: some Speaker, _ e: any Speaker, _ c: Bool) { (c ? m : e).speak() }
    public func ternaryBothErased(_ a: any Speaker, _ b: any Speaker, _ c: Bool) { (c ? a : b).speak() }
    public func ternaryBothOpaque(_ a: some Speaker, _ b: some Speaker, _ c: Bool) { (c ? a : b).speak() }

    // The SAME scope question for half 1's dependency-provenance set. An UNTYPED sequence, so the
    // shadowing binder leaves no stale type behind in `vars` (which is function-wide by design) —
    // otherwise the stale type makes the receiver look resolved and never reaches the marker at all.
    public func factoryThenLoopShadow() {
        let c = makeSpeaker()
        for c in mystery() { _ = c }
        c.speak()
    }
    public func factoryThenClosureShadow() {
        let c = makeSpeaker()
        mystery().forEach { c in _ = c }
        c.speak()
    }
    public func shadowMustNotInheritProvenance() {
        let c = makeSpeaker()
        _ = c
        for c in mystery() { _ = c.notAThing() }
    }

    // HALF-1 CARVE-OUT (`PURE_STDLIB_FREE_FNS`). An entry may only be carved out of the provenance
    // trigger if the binding's type is fixed by the ARGUMENTS' types (or is Void). These four are not:
    // the first two return the TRAILING CLOSURE's result, `unsafeDowncast` returns the caller-named
    // `to:` type, and `sequence(state:next:)`'s element type is the closure's. A dependency value
    // enters through each, so the receiver must DISCLOSE.
    public func viaWithoutActuallyEscaping(_ mk: @escaping () -> Int) {
        let s = withoutActuallyEscaping(mk) { _ in makeSpeaker() }
        s.speak()
    }
    public func viaWithUnsafePointer(_ n: Int) {
        let s = withUnsafePointer(to: n) { _ in makeSpeaker() }
        s.speak()
    }
    public func viaUnsafeDowncast(_ o: AnyObject) {
        let s = unsafeDowncast(o, to: LoudSpeaker.self)
        s.speak()
    }
    public func viaSequence() {
        let s = sequence(state: 0) { (i: inout Int) -> Speaker? in
            i += 1
            return i < 2 ? makeSpeaker() : nil
        }
        _ = s.makeIterator()
    }
    // FALSE-UNCERTAINTY controls — the RETAINED entries must not start disclosing. Each is a live
    // probe: emptying the carve-out flips all of these (except `viaSwap`, whose Void result has no
    // member to call — which is also why `swap` can never trigger it).
    public func viaMax(_ a: Int, _ b: Int) { let m = max(a, b); _ = m.advanced(by: 1) }
    public func viaMin(_ a: Int, _ b: Int) { let m = min(a, b); _ = m.advanced(by: 1) }
    public func viaAbs(_ a: Int) { let m = abs(a); _ = m.advanced(by: 1) }
    public func viaSwap(_ a: inout Int, _ b: inout Int) { let v = swap(&a, &b); _ = v }
    public func viaZip(_ a: [Int], _ b: [Int]) { let z = zip(a, b); _ = z.makeIterator() }
    public func viaStride() { let t = stride(from: 0, to: 10, by: 1); _ = t.makeIterator() }
    public func viaRepeatElement() { let r = repeatElement(1, count: 3); _ = r.makeIterator() }

    // FABRICATION GUARD for the same rung: `enum Rank: String` puts `String` in the inheritance
    // clause, so String LOOKS like a supertype with `Rank` as its conformer. A call on a plain
    // String-typed value must NOT dispatch into `Rank.lowercased`.
    public enum Rank: String {
        case high, low
        public func lowercased() -> String {
            _ = ProcessInfo.processInfo.environment["RANK"]
            return "x"
        }
    }
    public func plainString(_ s: String) -> String { return s.lowercased() }

    // The FIFTH door, and the only one whose bound is on `self` rather than on a binding: inside
    // `extension Array where Element: P` the element is a generic parameter of the ARRAY THE CALLER
    // HOLDS, so it is monomorphized there and never erased.
    extension Array where Element: Speaker {
        public func speakAll() { forEach { $0.speak() } }
    }
    """

    /// (root, depDir, appDir, ctlDir) — the split pair plus the one-package control.
    private func makeFixture() throws -> (root: URL, dep: URL, app: URL, ctl: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-vein-\(UUID().uuidString)")
        let dep = root.appendingPathComponent("deplib")
        let app = root.appendingPathComponent("app")
        let ctl = root.appendingPathComponent("ctl")
        let fm = FileManager.default
        try fm.createDirectory(at: dep.appendingPathComponent("Sources/DepLib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: ctl.appendingPathComponent("Sources/Ctl"), withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "DepLib", targets: [.target(name: "DepLib")])
        """.write(to: dep.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.write(to: dep.appendingPathComponent("Sources/DepLib/Lib.swift"),
                                 atomically: true, encoding: .utf8)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [.package(path: "../deplib")],
            targets: [.target(name: "App", dependencies: [.product(name: "DepLib", package: "deplib")])]
        )
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "import DepLib")
            .write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)

        // the CONTROL: the same two sources in ONE package, so the analysis is fully in-scan
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Ctl", targets: [.target(name: "Ctl")])
        """.write(to: ctl.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try Self.depSource.write(to: ctl.appendingPathComponent("Sources/Ctl/Lib.swift"),
                                 atomically: true, encoding: .utf8)
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "")
            .write(to: ctl.appendingPathComponent("Sources/Ctl/App.swift"), atomically: true, encoding: .utf8)
        return (root, dep, app, ctl)
    }

    private func scanDep(_ bin: URL, _ dep: URL, root: URL) throws -> URL {
        let r = try run(bin, [dep.path, "--out", root.appendingPathComponent("dep-r").path])
        XCTAssertEqual(r.code, 0, "dep scan must succeed; stderr: \(r.err)")
        return root.appendingPathComponent("dep-r.DepLib.Swift.json")
    }

    private func fns(ofReport url: URL) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let name = f["fn"] as? String { out[name] = f }
        }
        return out
    }

    private func policy(_ root: URL, _ lines: [String]) throws -> URL {
        let p = root.appendingPathComponent("candor.policy")
        try lines.joined(separator: "\n").appending("\n").write(to: p, atomically: true, encoding: .utf8)
        return p
    }

    // ── IMPLICIT STRINGIFICATION of a DEPENDENCY type ─────────────────────────────────────────────
    // `"\(e)"` where `e: DepLib.Entry` runs `Entry.description`, which reaches Env. The dep's report
    // records that accessor under `DepLib#Entry.description` — the join key this engine already
    // derives elsewhere — but both stringification rungs were LOCAL-only (`localTypes` for the
    // concrete witness, `localProtocols`/`conformers` for the CHA one), so the site recorded NOTHING,
    // not even Unknown, and the consumer certified clean.
    func testDependencyStringificationReachesItsWitness() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        // the one-package CONTROL gets all three forms right — that is what the split must match
        XCTAssertEqual(try run(bin, [ctl.path, "--out", root.appendingPathComponent("ctl-r").path]).code, 0)
        let ctlFns = try fns(ofReport: root.appendingPathComponent("ctl-r.Ctl.Swift.json"))
        for fn in ["describeTyped", "describeInline", "describeMapped"] {
            XCTAssertEqual(ctlFns[fn]?["inferred"] as? [String], ["Env"],
                           "CONTROL: \(fn) must reach Env in one package; got \(ctlFns[fn] ?? [:])")
        }

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0, "chained app scan must succeed; stderr: \(r.err)")
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        for fn in ["describeTyped", "describeInline", "describeMapped"] {
            XCTAssertEqual(by[fn]?["inferred"] as? [String], ["Env"],
                           "\(fn) must reach the dep's `description` across the scan boundary; got \(by[fn] ?? [:])")
        }
    }

    // NO FABRICATION: a dep type whose `description` is PURE is omitted from the dep report (silence
    // is the purity claim, §2 rule 3), so the same join must add exactly nothing.
    func testPureDependencyWitnessStaysPure() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertNil(by["describePure"],
                     "interpolating a dep type with a PURE description must stay pure; got \(by["describePure"] ?? [:])")
    }

    // The join is gated on the FILE's imports and on a package a loaded report COVERS: an app that
    // does not import the dep resolves to nothing, exactly as before — the joins-never-guess rule.
    func testStringificationJoinRequiresTheImport() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        // drop the import: the same source, now naming a type from no covered package in scope
        try Self.appSource.replacingOccurrences(of: "IMPORT", with: "")
            .write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertNil(by["describeTyped"], "no import of the covered package → no join; got \(by["describeTyped"] ?? [:])")
    }

    // THE GATE — the consequential form. `deny Env` on the three stringifying functions must fail
    // the SAME way in both arrangements; before the fix the chained scan PASSED (a false all-clear).
    func testDenyGateDoesNotFlipAcrossTheBoundary() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let pol = try policy(root, ["deny Env Unknown describeTyped",
                                    "deny Env Unknown describeInline",
                                    "deny Env Unknown describeMapped"])

        let control = try run(bin, [ctl.path, "--policy", pol.path,
                                    "--out", root.appendingPathComponent("ctl-g").path])
        XCTAssertEqual(control.code, 1, "CONTROL: one package must fail the deny gate; stderr: \(control.err)")

        let split = try run(bin, [app.path, "--policy", pol.path,
                                  "--out", root.appendingPathComponent("app-g").path],
                            env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(split.code, 1,
                       "split + chained must fail the SAME gate — exit 0 here is the false all-clear; stderr: \(split.err)")
    }

    // ── DEINIT GLUE over a DEPENDENCY class (the R33 mechanism across the boundary) ───────────────
    // `let g = Guardian()` runs `Guardian.deinit` at scope exit — deterministic under ARC for a
    // non-escaping local, and modeled inside the scan since R33. The edge was gated on
    // `localTypes.contains(t)`, so a dep class whose `deinit` is effectful read silent-pure with the
    // dep's report chained, even though that report records `DepLib#Guardian.deinit`.
    func testDependencyDeinitGlueChargesTheScope() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        XCTAssertEqual(try run(bin, [ctl.path, "--out", root.appendingPathComponent("ctl-r").path]).code, 0)
        let ctlFns = try fns(ofReport: root.appendingPathComponent("ctl-r.Ctl.Swift.json"))
        XCTAssertEqual(ctlFns["scoped"]?["inferred"] as? [String], ["Env"],
                       "CONTROL: the deinit glue must charge the scope in one package; got \(ctlFns["scoped"] ?? [:])")

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0, "chained app scan must succeed; stderr: \(r.err)")
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertEqual(by["scoped"]?["inferred"] as? [String], ["Env"],
                       "a dep class's effectful deinit must charge its holder; got \(by["scoped"] ?? [:])")
        // the two no-fabrication controls, both carried over from the in-scan rung:
        XCTAssertNil(by["scopedQuiet"], "a dep class with a PURE deinit has no report entry — nothing joins")
        XCTAssertNil(by["handOut"], "a RETURNED (escaping) value is not charged to the constructing scope")
    }

    func testDeinitGateDoesNotFlipAcrossTheBoundary() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let pol = try policy(root, ["deny Env Unknown scoped"])
        let control = try run(bin, [ctl.path, "--policy", pol.path,
                                    "--out", root.appendingPathComponent("ctl-g").path])
        XCTAssertEqual(control.code, 1, "CONTROL: one package must fail the deny gate; stderr: \(control.err)")
        let split = try run(bin, [app.path, "--policy", pol.path,
                                  "--out", root.appendingPathComponent("app-g").path],
                            env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(split.code, 1,
                       "split + chained must fail the SAME gate — exit 0 here is the false all-clear; stderr: \(split.err)")
    }

    // ── DISPATCH OVER AN IMPORTED PROTOCOL WHOSE CONFORMER IS LOCAL ───────────────────────────────
    // `s.speak()` where `s: DepLib.Speaker` and `final class AppSpeaker: Speaker` is declared HERE.
    // `protocolMethods`/`protoParams` are local-only, so `s` was never seen as protocol-typed and NO
    // dispatch was recorded — the call read silent-pure even though the witness that runs is a project
    // unit candor analysed correctly. This half needs no dep report: the conformance declaration is
    // ours, and `conformers` already records it.
    func testImportedProtocolDispatchesOverLocalConformers() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)

        // CONTROL: in ONE package both conformers are visible, so the dispatch unions Env (the app's)
        // and Fs (the dep's).
        XCTAssertEqual(try run(bin, [ctl.path, "--out", root.appendingPathComponent("ctl-r").path]).code, 0)
        let ctlFns = try fns(ofReport: root.appendingPathComponent("ctl-r.Ctl.Swift.json"))
        XCTAssertEqual(Set(ctlFns["viaImportedProtocol"]?["inferred"] as? [String] ?? []), ["Env", "Fs"],
                       "CONTROL: one package unions both conformers; got \(ctlFns["viaImportedProtocol"] ?? [:])")

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        for fn in ["viaImportedProtocol", "viaImportedProtocolLocal"] {
            XCTAssertTrue(Set(by[fn]?["inferred"] as? [String] ?? []).contains("Env"),
                          "\(fn) must reach the LOCAL conformer's witness; got \(by[fn] ?? [:])")
        }
        // RESIDUAL, pinned not repaired: the DEPENDENCY's own conformer (`LoudSpeaker`, Fs) is not
        // reachable from a plain dep report — it needs the protocol-CHA union entries a `--workspace`
        // child scan emits. The local half is recovered; the dep half stays out.
        XCTAssertFalse(Set(by["viaImportedProtocol"]?["inferred"] as? [String] ?? []).contains("Fs"),
                       "a plain dep report carries no conformer hierarchy — nothing may be invented for it")

        // ERASURE. `any Speaker` keeps the recovery; `some Speaker` must NOT get it — the caller
        // monomorphizes it, so charging every conformer's effect is a fabrication, not a conservative
        // over-approximation. Both are spelled `Speaker` after type-name resolution, which is exactly why
        // this needs asserting rather than assuming.
        // COULD-NOT-FORM-A-KEY (half 1, row 2). `makeSpeaker` is pure, so it is omitted from the dep's
        // report and no return type travels; the binding is untyped and NO key is formed. The report's
        // silence answers a question that was never asked, so this must DISCLOSE, not read pure.
        XCTAssertTrue(Set(by["viaFactoryBoundReceiver"]?["inferred"] as? [String] ?? []).contains("Unknown"),
                      "an untyped receiver from a CHAINED package must disclose; got \(by["viaFactoryBoundReceiver"] ?? [:])")

        XCTAssertTrue(Set(by["viaExistentialImported"]?["inferred"] as? [String] ?? []).contains("Env"),
                      "an EXISTENTIAL `any P` receiver keeps the dispatch; got \(by["viaExistentialImported"] ?? [:])")
        XCTAssertFalse(Set(by["viaOpaqueImported"]?["inferred"] as? [String] ?? []).contains("Env"),
                       "an OPAQUE `some P` receiver is monomorphized BY THE CALLER — dispatching it over "
                       + "local conformers FABRICATES; got \(by["viaOpaqueImported"] ?? [:])")
    }

    /// ERASURE, THE SPELLINGS `some P` DOES NOT COVER. d62dd69 keyed the gate on the PARAMETER's own
    /// type, which answers the question for `func f(_ s: some P)` and for nothing else: a `[T]` element
    /// under a `<T: P>` bound, its `[some P]` sugar, the `forEach` closure form of either, a field typed
    /// as the enclosing type's generic parameter, and `extension Array where Element: P` all resolve to
    /// the bound `P` too, and all of them are monomorphized by whoever supplies the concrete type. Each
    /// was measured charging `AppSpeaker.speak`'s Env to a function whose only call site passes the pure
    /// conformer — a fabrication, and the mirror of the miss the rung exists to close.
    ///
    /// The `viaExistential*` rows are not decoration: they are the same three shapes written `any P`,
    /// where the local conformers really are the candidate witnesses. A fix that stopped resolving
    /// container elements or generic fields at all would satisfy the first list and break these.
    /// (candor-rust reached the identical conclusion from the other side — see `isOpaqueParam`.)
    func testMonomorphizedElementsAndFieldsDoNotDispatchOverLocalConformers() throws {
        let bin = try binaryURL()
        let (root, _, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // chaining-independent, exactly like the rung it guards: the conformance is declared in the app.
        XCTAssertEqual(try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path]).code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        func eff(_ n: String) -> Set<String> { Set(by[n]?["inferred"] as? [String] ?? []) }

        for erased in ["viaExistentialElement", "viaExistentialForEach", "ErasedRelay.run"] {
            XCTAssertTrue(eff(erased).contains("Env"),
                          "CONTROL \(erased): an `any Speaker` element/field IS erased, so the local "
                          + "conformers are its witnesses and the dispatch must hold — without this the "
                          + "rows below are satisfied by simply not resolving; got \(by[erased] ?? [:])")
        }
        for mono in ["viaGenericElement", "viaOpaqueElement", "viaGenericForEach", "Relay.run",
                     "Array.speakAll"] {
            XCTAssertFalse(eff(mono).contains("Env"),
                           "\(mono): the element/field type is monomorphized by the CALLER — the only "
                           + "call site passes QuietSpeaker, so charging AppSpeaker's Env is an effect "
                           + "this function cannot perform; got \(by[mono] ?? [:])")
        }
        // and the caller inherits nothing it cannot reach either — the fabrication propagates.
        XCTAssertFalse(eff("callsTheMonomorphizedOnesWithAPureConformer").contains("Env"),
                       "the pure-conformer call site must stay pure; got "
                       + "\(by["callsTheMonomorphizedOnesWithAPureConformer"] ?? [:])")
    }

    /// The opaque-receiver suppression (d62dd69) is keyed by the parameter's NAME, and a name can be
    /// REBOUND. Both directions are asserted here, because each one alone is satisfiable by a wrong fix:
    ///
    ///   - inside a shadowing binder the receiver is NOT the opaque parameter, so suppressing the CHA
    ///     there drops a real witness and the caller reads silent-pure — the cardinal sin;
    ///   - once the shadowing SCOPE closes the name is the opaque parameter again, so clearing the flag
    ///     instead of scoping it re-opens the fabrication d62dd69 closed.
    ///
    /// The `…NoShadow` row of each pair is the mechanism control: the same body with a non-colliding
    /// binder name. It resolves in both arms, which is what makes a `shadowed*` miss attributable to the
    /// name-keyed suppression rather than to a typing failure.
    func testOpaqueParamSuppressionIsScopedToTheName() throws {
        let bin = try binaryURL()
        let (root, _, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // chaining-independent: the conformance (AppSpeaker: Speaker) is declared in the app
        XCTAssertEqual(try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path]).code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        func eff(_ n: String) -> Set<String> { Set(by[n]?["inferred"] as? [String] ?? []) }

        for (shadowed, control) in [("shadowedByLoop", "loopNoShadow"),
                                    ("shadowedByClosure", "closureNoShadow"),
                                    ("shadowedByIfLet", "ifLetNoShadow"),
                                    ("shadowedByLet", "letNoShadow"),
                                    ("shadowedByGuardLet", "guardLetNoShadow")] {
            XCTAssertTrue(eff(control).contains("Env"),
                          "CONTROL \(control): the non-colliding binder must resolve, else \(shadowed) "
                          + "proves nothing; got \(by[control] ?? [:])")
            XCTAssertTrue(eff(shadowed).contains("Env"),
                          "\(shadowed): the REBOUND name is not the opaque parameter — suppressing the "
                          + "local-conformer CHA there makes an Env-performing call read silent-pure; "
                          + "got \(by[shadowed] ?? [:])")
        }
        for after in ["opaqueAfterLoopShadow", "opaqueAfterClosureShadow", "opaqueAfterIfLetShadow"] {
            XCTAssertFalse(eff(after).contains("Env"),
                           "\(after): the shadow's scope has CLOSED, so `s` is the `some Speaker` "
                           + "parameter again and the CHA must be suppressed as d62dd69 requires; "
                           + "got \(by[after] ?? [:])")
        }
        XCTAssertFalse(eff("viaOpaqueImported").contains("Env"), "the unshadowed opaque case is untouched")
    }

    /// THE CONTAINER FORM OF THE SAME SCOPE QUESTION, which 02fb0ad shipped without. That commit made
    /// `enterShadowScope` save unconditionally because a `for x in xs` binder can now ADD to `monoNames`
    /// — and introduced a SECOND set, `opaqueElem`, that was never added to the save at all. Its
    /// lockstep-with-`arrayElem` invariant is the CLEAR half of the discipline (a rebind cannot leave a
    /// stale opacity behind a fresh element type) and is silent about the RESTORE half.
    ///
    /// So an inner block that binds an EXISTING name from a monomorphized source (`let ys = xs.filter`,
    /// `xs: [some Speaker]`) marked `ys` opaque for the rest of the FUNCTION, and the erased
    /// `ys: [any Speaker]` parameter it shadowed lost its dispatch — a silent under-report manufactured
    /// by a fabrication fix, which is standing-bar item 0 in its exact shape. Invisible in a corpus A/B,
    /// because it needs a name collision that no measured target happens to contain.
    ///
    /// Both directions, as with `monoNames`: `elemOpacityNoShadow` is the mechanism control (identical
    /// body, binder renamed — it must resolve in both arms, which is what makes the miss attributable to
    /// the leaked flag rather than to a typing failure), and `elemOpacityRestoredAfterShadow` proves the
    /// fix is a SCOPE and not a clear.
    func testElementOpacityIsScopedToItsBlock() throws {
        let bin = try binaryURL()
        let (root, _, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path]).code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        func eff(_ n: String) -> Set<String> { Set(by[n]?["inferred"] as? [String] ?? []) }

        XCTAssertTrue(eff("elemOpacityNoShadow").contains("Env"),
                      "CONTROL elemOpacityNoShadow: the non-colliding binder must resolve, else the row "
                      + "below proves nothing; got \(by["elemOpacityNoShadow"] ?? [:])")
        XCTAssertTrue(eff("elemOpacityAfterBlockShadow").contains("Env"),
                      "elemOpacityAfterBlockShadow: the inner block's monomorphized `ys` does not outlive "
                      + "the block — the parameter it shadowed is `[any Speaker]`, so the CHA must fire "
                      + "and this Env-performing function must not read pure; got "
                      + "\(by["elemOpacityAfterBlockShadow"] ?? [:])")
        XCTAssertFalse(eff("elemOpacityRestoredAfterShadow").contains("Env"),
                       "elemOpacityRestoredAfterShadow: the shadow's scope has CLOSED, so `xs` is the "
                       + "`[some Speaker]` parameter again and its opacity must be RESTORED, not dropped "
                       + "— else the fix trades one sin for the other; got "
                       + "\(by["elemOpacityRestoredAfterShadow"] ?? [:])")
    }

    /// THE BINDER FORMS NOBODY ENUMERATED — the fourth instance of one failure, and the reason this one
    /// was fixed structurally instead of by a fourth `if`.
    ///
    /// `patternNames` listed three of the seven `PatternSyntax` kinds and returned `[]` for the rest, so
    /// `for case let x?`, `for case .some(let x)` and `for case let x as T` never reached `shadowName`:
    /// the enclosing signature's `monoNames`/`depBoundLocals` entry stayed attached to the loop's own,
    /// genuinely unrelated binding. It is now a walk for every `IdentifierPatternSyntax` in the subtree
    /// — which is where the grammar puts every binder and nowhere else — plus a catch-all
    /// `visit(IdentifierPatternSyntax)` that CLEARS any binder no specific visitor claimed, so an
    /// unenumerated form defaults to dropping a stale binding rather than to keeping one.
    ///
    /// Four things are asserted, because the first alone is satisfiable by three wrong fixes:
    ///   - the shadowed rows dispatch (the leak is gone) AND their `…NoShadow` controls do too, which is
    ///     what makes the shadowed miss attributable to the leak rather than to a typing failure. Note
    ///     both controls FAILED before this change: these binders were never typed at all, so scoping
    ///     the flag alone would have left the same silent-pure answer by another route;
    ///   - `loopTypeDoesNotOutliveTheLoop` — typing a `for case` binder made `vars`' documented outward
    ///     leak bite, so the pattern's names now have their type restored at the loop's end. Measured
    ///     live on the corpus: 258 restores across 13 targets actually change a binding;
    ///   - `provenanceNotOntoOptionalBinder` — the MIRROR. Half 1's provenance riding onto the loop's
    ///     own binder disclosed `Unknown[dispatch:…]` for a purely local value, which flips
    ///     `deny E Unknown[dispatch]` to exit 1 on clean code;
    ///   - `provenanceRestoredAfterOptionalBinder` — …and it must come BACK, or the fix trades a false
    ///     disclosure for a silent purity claim on a genuinely factory-bound receiver.
    func testEveryPatternBinderIsAScope() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0, "chained app scan must succeed; stderr: \(r.err)")
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        func eff(_ n: String) -> Set<String> { Set(by[n]?["inferred"] as? [String] ?? []) }

        for (shadowed, control) in [("forCaseOptionalShadow", "forCaseOptionalNoShadow"),
                                    ("forCaseCastShadow", "forCaseCastNoShadow"),
                                    ("forVarShadow", "forVarNoShadow")] {
            XCTAssertTrue(eff(control).contains("Env"),
                          "CONTROL \(control): this binder must be TYPED, else \(shadowed) reads pure "
                          + "for a second reason and the row proves nothing; got \(by[control] ?? [:])")
            XCTAssertTrue(eff(shadowed).contains("Env"),
                          "\(shadowed): the loop's binder is not the `some Speaker` parameter — leaving "
                          + "the parameter's opacity on it makes an Env-performing call read silent-pure; "
                          + "got \(by[shadowed] ?? [:])")
        }
        XCTAssertTrue(eff("loopTypeNoShadow").contains("Env"),
                      "CONTROL loopTypeNoShadow: the erased parameter dispatches when no loop shadows it; "
                      + "got \(by["loopTypeNoShadow"] ?? [:])")
        XCTAssertTrue(eff("loopTypeDoesNotOutliveTheLoop").contains("Env"),
                      "loopTypeDoesNotOutliveTheLoop: the loop's concrete `QuietSpeaker` must not survive "
                      + "the loop and answer for the `any Speaker` parameter it shadowed; got "
                      + "\(by["loopTypeDoesNotOutliveTheLoop"] ?? [:])")

        XCTAssertFalse(eff("caseLetOutsideBindsItsOwnValue").contains("Env"),
                       "caseLetOutsideBindsItsOwnValue: `case let .quiet(s)` binds a QuietSpeaker — "
                       + "keeping the enclosing AppSpeaker parameter's type for the name charges an "
                       + "effect this case cannot reach; got \(by["caseLetOutsideBindsItsOwnValue"] ?? [:])")
        XCTAssertNil(by["provenanceNotOntoOptionalBinder"],
                     "the loop's own binder is a purely LOCAL value — disclosing the factory's provenance "
                     + "for it is false uncertainty that flips `deny E Unknown[dispatch]` on clean code; "
                     + "got \(by["provenanceNotOntoOptionalBinder"] ?? [:])")
        XCTAssertTrue(eff("provenanceRestoredAfterOptionalBinder").contains("Unknown"),
                      "…and once the loop CLOSES `c` is the factory-bound receiver again and must "
                      + "disclose, or the mirror fix manufactures a silent purity claim; got "
                      + "\(by["provenanceRestoredAfterOptionalBinder"] ?? [:])")
    }

    /// OPACITY IS NOT A PROPERTY OF ONE ARM OF A JOIN. `rootOf` types `(c ? a : b)` from the arms'
    /// shared root and composed their `mono` flags with `||`, so a receiver monomorphized on one branch
    /// and ERASED on the other was treated as fully monomorphized: the guard `ra == b.root` passes
    /// (`some Speaker` and `any Speaker` both resolve to `Speaker`), `opaqueRecv` goes true, the
    /// local-conformer CHA is skipped for the erased arm too, and the function is ABSENT from the report
    /// — a positive purity claim, under ⟨0.21⟩, about a body that performs Env whenever `c` is false.
    ///
    /// Opacity licenses SUPPRESSION, so it composes by CONJUNCTION: the claim may be made of the
    /// expression only if it holds of every arm. All three rows are asserted because each alone is
    /// satisfiable by a wrong fix — dropping the flag on any ternary passes the first two and re-opens
    /// d62dd69's fabrication on the third; refusing to resolve ternaries at all passes the first and
    /// third and loses the second.
    ///
    /// Measured (standing bar item 8): instrumented over 14 real Swift targets this join fires 12 times
    /// and every firing is ERASED/ERASED, so a corpus A/B cannot distinguish `&&` from `||` here — the
    /// corpus is the fabrication control and these fixtures are the evidence.
    func testTernaryOpacityComposesByConjunction() throws {
        let bin = try binaryURL()
        let (root, _, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path]).code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        func eff(_ n: String) -> Set<String> { Set(by[n]?["inferred"] as? [String] ?? []) }

        XCTAssertTrue(eff("ternaryBothErased").contains("Env"),
                      "CONTROL ternaryBothErased: two `any Speaker` arms are erased, so the local "
                      + "conformers ARE the witnesses and the dispatch must hold — without this row a "
                      + "fix that stopped resolving ternaries would pass; got \(by["ternaryBothErased"] ?? [:])")
        XCTAssertTrue(eff("ternaryMixedOpacity").contains("Env"),
                      "ternaryMixedOpacity: the `any Speaker` arm is genuinely erased, so suppressing the "
                      + "CHA for the whole expression makes an Env-performing function read silent-pure; "
                      + "got \(by["ternaryMixedOpacity"] ?? [:])")
        XCTAssertFalse(eff("ternaryBothOpaque").contains("Env"),
                       "ternaryBothOpaque: BOTH arms are caller-monomorphized and the only call site "
                       + "passes QuietSpeaker, so charging AppSpeaker's Env is the fabrication mirror; "
                       + "got \(by["ternaryBothOpaque"] ?? [:])")
    }

    /// A NESTED `func` has its OWN signature, and its calls attribute to the enclosing unit — so the
    /// name-keyed opacity set has to treat its parameters as a shadowing scope. It did not: an outer
    /// `some Speaker` parameter suppressed the CHA on a nested function's genuinely ERASED receiver of
    /// the same name, and an Env-performing body read silent-pure. This is the swift form of the
    /// nested-item leak candor-rust's R4 needed a third carve-out for.
    ///
    /// All three directions, because each is satisfiable by a wrong fix:
    ///   - `nestedFuncNoShadow` is the mechanism CONTROL (outer spelled `any`) and resolves in both arms;
    ///   - `nestedFuncOwnOpacity` / `nestedFuncOwnElementOpacity` are the MIRROR — shadowing alone would
    ///     let a nested `some P` parameter dispatch over the local conformers inside an erased outer;
    ///   - `opaqueAfterNestedFuncShadow` proves it is a SCOPE: after the nested `func` closes, the
    ///     enclosing parameter is opaque again.
    func testNestedFuncParametersAreTheirOwnScope() throws {
        let bin = try binaryURL()
        let (root, _, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path]).code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        func eff(_ n: String) -> Set<String> { Set(by[n]?["inferred"] as? [String] ?? []) }

        XCTAssertTrue(eff("nestedFuncNoShadow").contains("Env"),
                      "CONTROL nestedFuncNoShadow: the nested erased receiver must resolve when the "
                      + "OUTER parameter is erased too, else the row below proves nothing; got "
                      + "\(by["nestedFuncNoShadow"] ?? [:])")
        XCTAssertTrue(eff("nestedFuncOwnParam").contains("Env"),
                      "nestedFuncOwnParam: `inner`'s `s` is `any Speaker` — its own signature, not the "
                      + "enclosing `some Speaker` — so the local-conformer CHA must fire and this "
                      + "Env-performing body must not read pure; got \(by["nestedFuncOwnParam"] ?? [:])")
        for mono in ["nestedFuncOwnOpacity", "nestedFuncOwnElementOpacity", "opaqueAfterNestedFuncShadow"] {
            XCTAssertFalse(eff(mono).contains("Env"),
                           "\(mono): shadowing the enclosing flag must not DROP the nested signature's "
                           + "own opacity (nor the enclosing one once the nested func closes) — that is "
                           + "the fabrication mirror; got \(by[mono] ?? [:])")
        }
    }

    /// The same scope question for half 1's dependency-PROVENANCE set. 81a9dc3 made a rebind clear the
    /// provenance (right — a shadowing binder's value is local, and disclosing it is false uncertainty)
    /// and left it cleared for the rest of the function (wrong — below the shadow the name is the
    /// factory-bound receiver again, and it went back to reading silent-pure).
    func testDepProvenanceSurvivesAShadowingBinder() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let out = root.appendingPathComponent("app-r")
        XCTAssertEqual(try run(bin, [app.path, "--out", out.path],
                               env: ["CANDOR_DEPS": depReport.path]).code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        func why(_ n: String) -> Set<String> { Set(by[n]?["unknownWhy"] as? [String] ?? []) }
        let marker = "dispatch:untyped cross-package receiver"

        XCTAssertTrue(why("viaFactoryBoundReceiver").contains(marker),
                      "BASELINE for the rung — without this the two assertions below are vacuous")
        for fn in ["factoryThenLoopShadow", "factoryThenClosureShadow"] {
            XCTAssertTrue(why(fn).contains(marker),
                          "\(fn): the shadow is confined to the binder; the call BELOW it is the "
                          + "factory-bound receiver and must still disclose; got \(by[fn] ?? [:])")
        }
        XCTAssertFalse(why("shadowMustNotInheritProvenance").contains(marker),
                       "the receiver INSIDE the shadow is a purely local value that merely reuses the "
                       + "name — the over-disclosure 81a9dc3 closed must stay closed; "
                       + "got \(by["shadowMustNotInheritProvenance"] ?? [:])")
    }

    /// `PURE_STDLIB_FREE_FNS` is a DENYLIST of PROVEN-safe cases, and the proof is the same for every
    /// entry: the binding's type is fixed by the ARGUMENTS' types, or is Void, so no dependency-chosen
    /// type can enter the function through the call. Four entries did not satisfy it — they return the
    /// trailing closure's result, the caller-named `to:` type, or a closure-chosen element type — and
    /// each was a silent under-report of a dependency reach.
    ///
    /// The controls matter as much: this test WIDENS disclosure, so the risk it carries is false
    /// uncertainty, and the retained entries must not start firing. They are live probes — emptying the
    /// carve-out makes six of the seven disclose (`swap` alone cannot, its result being Void).
    func testStdlibCarveOutOnlyHoldsProvenSafeCalls() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        XCTAssertEqual(try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                               env: ["CANDOR_DEPS": depReport.path]).code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        func why(_ n: String) -> Set<String> { Set(by[n]?["unknownWhy"] as? [String] ?? []) }
        let marker = "dispatch:untyped cross-package receiver"

        XCTAssertTrue(why("viaFactoryBoundReceiver").contains(marker),
                      "BASELINE for the rung — without this every row below is vacuous")
        for fn in ["viaWithoutActuallyEscaping", "viaWithUnsafePointer", "viaUnsafeDowncast",
                   "viaSequence"] {
            XCTAssertTrue(why(fn).contains(marker),
                          "\(fn): the result's type is chosen by the CLOSURE or by the CALLER, not by "
                          + "the arguments, so a dependency value enters here and the receiver must "
                          + "disclose rather than read pure; got \(by[fn] ?? [:])")
        }
        for fn in ["viaMax", "viaMin", "viaAbs", "viaSwap", "viaZip", "viaStride", "viaRepeatElement"] {
            XCTAssertFalse(why(fn).contains(marker),
                           "\(fn): the binding's type is fixed by the arguments (or is Void) — "
                           + "disclosing it is false uncertainty; got \(by[fn] ?? [:])")
        }
    }

    // The recovery is chaining-INDEPENDENT: the conformance is declared in the app, so it holds with
    // no dep report at all.
    func testImportedProtocolDispatchNeedsNoDepReport() throws {
        let bin = try binaryURL()
        let (root, _, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        XCTAssertTrue(Set(by["viaImportedProtocol"]?["inferred"] as? [String] ?? []).contains("Env"),
                      "unchained too; got \(by["viaImportedProtocol"] ?? [:])")
    }

    // THE FABRICATION MIRROR for that rung. Swift's inheritance clause is overloaded: `enum Rank: String`
    // records `String` as a supertype with `Rank` as its conformer, so an unguarded CHA would send every
    // call on a String-typed value into `Rank`'s methods. `plainString` must stay pure in EVERY mode.
    //
    // NOT SUBSUMED by the erasure gate, measured rather than assumed: they answer different questions.
    // Erasure is about the receiver's SPELLING — `some P`/`<T: P>` is monomorphized, `any P` is not.
    // A plain `s: String` parameter is a CONCRETE type that nobody monomorphizes, so the erasure gate
    // has nothing to say about it. With `RAW_VALUE_BASE_TYPES` removed and the erasure gate in place,
    // `plainString` reads `['Env']` via `Rank.lowercased`. Both guards stay.
    func testRawValueBaseDoesNotDispatchIntoItsEnums() throws {
        let bin = try binaryURL()
        let (root, dep, app, ctl) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        for (label, args, env) in [
            ("control", [ctl.path, "--out", root.appendingPathComponent("ctl-r").path], [String: String]()),
            ("unchained", [app.path, "--out", root.appendingPathComponent("app-u").path], [:]),
            ("chained", [app.path, "--out", root.appendingPathComponent("app-c").path],
             ["CANDOR_DEPS": depReport.path]),
        ] {
            XCTAssertEqual(try run(bin, args, env: env).code, 0, "\(label) scan must succeed")
            let out = args[2]
            let suffix = label == "control" ? ".Ctl.Swift.json" : ".App.Swift.json"
            let by = try fns(ofReport: URL(fileURLWithPath: out + suffix))
            XCTAssertNil(by["plainString"],
                         "\(label): `s.lowercased()` on a String must not dispatch into `enum Rank: String`; got \(by["plainString"] ?? [:])")
        }
    }

    // A STALE dep report is not trusted at this join either (§2.1): the witness reads Unknown with
    // its origin named, never a stale effect claim — and `deny Env Unknown` still fails closed.
    func testStaleDepMakesTheWitnessUnknownNotPure() throws {
        let bin = try binaryURL()
        let (root, dep, app, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let depReport = try scanDep(bin, dep, root: root)
        let stale = root.appendingPathComponent("dep-stale.json")
        var d = try JSONSerialization.jsonObject(with: Data(contentsOf: depReport)) as! [String: Any]
        var candor = d["candor"] as! [String: Any]
        candor["version"] = "candor-doctored-0.0.0"
        d["candor"] = candor
        try JSONSerialization.data(withJSONObject: d).write(to: stale)

        let r = try run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                        env: ["CANDOR_DEPS": stale.path])
        XCTAssertEqual(r.code, 0)
        let by = try fns(ofReport: root.appendingPathComponent("app-r.App.Swift.json"))
        let inferred = Set(by["describeTyped"]?["inferred"] as? [String] ?? [])
        XCTAssertTrue(inferred.contains("Unknown"), "a stale dep's witness must read Unknown; got \(inferred)")
        XCTAssertFalse(inferred.contains("Env"), "never a stale effect claim")
        XCTAssertEqual(by["describeTyped"]?["unknownWhy"] as? [String], ["dep-stale:DepLib"],
                       "the Unknown must name its origin (spec 0.6 unknownWhy)")
    }
}
