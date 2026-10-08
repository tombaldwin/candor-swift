import XCTest
import Foundation

/// SOUNDNESS R1048 residual and R1044 residual — two places a caller's INSTANTIATION decides which body runs, and
/// the engine read the instantiation only in its simplest spelling.
///
/// - R1048 / R951 / R974 (c): a caller-witness requirement `<idx>:<req>` names the callee's PARAMETER index, and
///   was answered from the call's ARGUMENT position — which agree only on a fully positional call. A labelled
///   argument (`iterL(seq: Loud())`, `eqL(lhs: a, rhs: b)`), a skipped defaulted parameter and an `inout`
///   argument (`iterIO(&l)`) answered nothing.
/// - R1044: a member of a local generic type declared as one of the type's own generic parameters
///   (`Box<V>.get() -> V`, `Box<V>.v: V`) typed the value as nothing, so `Box(v: E()).get().go()` was ABSENT.
///
/// Every positive arm was EXECUTED before it was written down (`swiftagent-v043/fx/b`, `fx/d`): the program
/// deleted the victim file through it; every control arm kept its file (`fx/c`, `fx/e`). Each fix has a §1b
/// kill switch whose arm restores the release reading.
///
/// Harness note (R706): under `swift test` the manifest peek can leave a non-violating gate at exit 2, so a
/// must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class GenericInstantiationProcessTests: XCTestCase {
    private static let FS = "try? FileManager.default.removeItem(atPath: \"/nonexistent/candor-v043\")"

    private func scan(_ src: String, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        return try ProcessHarness.fns(ofJson: r.out)
    }
    private func gate(_ src: String, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let pf = root.appendingPathComponent("p.policy")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
    }
    private func inf(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["inferred"] as? [String] ?? []).sorted()
    }

    // ── R1048 residual — the caller-witness argument is aligned by LABEL, not by position ───────────────
    static let witness = """
    import Foundation
    struct Loud: Sequence, IteratorProtocol {
        var n = 1
        mutating func next() -> Int? { if n == 0 { return nil }; n = 0; \(FS); return 1 }
    }
    struct Noisy: Equatable { var v: Int; static func == (a: Noisy, b: Noisy) -> Bool { \(FS); return a.v == b.v } }
    func iterU<S: Sequence>(_ s: S) { for _ in s {} }
    func iterL<S: Sequence>(seq s: S) { for _ in s {} }
    func iterD<S: Sequence>(n: Int = 0, seq s: S) { for _ in s {} }
    func iterIO<S: Sequence>(_ s: inout S) { for _ in s {} }
    func iterLIO<S: Sequence>(seq s: inout S) { for _ in s {} }
    func eqL<T: Equatable>(lhs a: T, rhs b: T) -> Bool { a == b }
    func fwdL<S: Sequence>(seq s: S) { iterL(seq: s) }
    func fwdLU<S: Sequence>(seq s: S) { iterU(s) }
    struct H { func iterM<S: Sequence>(seq s: S) { for _ in s {} } }
    func viaGeneric() { iterU(Loud()) }
    func viaLabelled() { iterL(seq: Loud()) }
    func viaDefaulted() { iterD(seq: Loud()) }
    func viaInout() { var l = Loud(); iterIO(&l) }
    func viaLabelInout() { var l = Loud(); iterLIO(seq: &l) }
    func viaEqLabelled() { _ = eqL(lhs: Noisy(v: 1), rhs: Noisy(v: 1)) }
    func viaFwdLabelled() { fwdL(seq: Loud()) }
    func viaFwdMixed() { fwdLU(seq: Loud()) }
    func viaMemberLabelled() { H().iterM(seq: Loud()) }
    // CONTROLS: the effectful value goes to a parameter that is NOT iterated / compared; overloads that place
    // the iterated parameter differently are told apart by their labels.
    func keepL<S: Sequence>(hold h: Loud, seq s: S) { _ = h; for _ in s {} }
    func keepT<S: Sequence, T>(seq s: S, other o: T) { for _ in s {}; _ = o }
    func eqL2<T: Equatable, U>(lhs a: T, rhs b: T, x: U) -> Bool { _ = x; return a == b }
    func ov<S: Sequence>(a s: S, b: Loud) { _ = b; for _ in s {} }
    func ov<S: Sequence>(b: Loud, a s: S) { _ = b; for _ in s {} }
    func ctlKeepL() { keepL(hold: Loud(), seq: [1, 2]) }
    func ctlKeepT() { keepT(seq: [1], other: Loud()) }
    func ctlEq2() { _ = eqL2(lhs: 1, rhs: 2, x: Noisy(v: 1)) }
    func ctlOv() { ov(b: Loud(), a: [1]) }
    """
    func testACallerWitnessIsAlignedByLabel() throws {
        let by = try scan(Self.witness)
        for f in ["viaGeneric", "viaLabelled", "viaDefaulted", "viaInout", "viaLabelInout", "viaEqLabelled",
                  "viaFwdLabelled", "viaFwdMixed", "viaMemberLabelled"] {
            XCTAssertEqual(inf(by, f), ["Fs"], "R1048 residual: \(f) runs the witness; got \(by[f] ?? [:])")
        }
        for f in ["ctlKeepL", "ctlKeepT", "ctlEq2", "ctlOv"] {
            XCTAssertFalse(inf(by, f).contains("Fs"), "R1048 residual: \(f) runs no effectful witness; got \(by[f] ?? [:])")
        }
        XCTAssertEqual(try gate(Self.witness, "deny Fs viaLabelled"), 1, "the gate must flip")
        XCTAssertEqual(try gate(Self.witness, "deny Fs viaEqLabelled"), 1, "the gate must flip")
        let off = try scan(Self.witness, env: ["CANDOR_R1048L_OFF": "1"])
        XCTAssertNil(ProcessHarness.chargedNothing(off, "viaLabelled"), "kill switch restores the release silence")
        XCTAssertEqual(inf(off, "viaGeneric"), ["Fs"], "the positional floor is not behind the kill switch")
    }

    // ── R1044 residual — a member typed by its owner's generic parameter is the RECEIVER's argument ─────
    static let receiver = """
    import Foundation
    struct E { func go() { \(FS) } }
    struct P { func go() { print("pure") } }
    struct T { func go() { \(FS) } }
    struct Box<V> { let v: V; func get() -> V { v }; func getOpt() -> V? { v } }
    final class Cell<V> { var v: V; init(_ v: V) { self.v = v }; func get() -> V { v } }
    struct Pair<A, B> { let a: A; let b: B; func second() -> B { b }; func first() -> A { a } }
    struct Multi<V> { var v: V; init(v: V) { self.v = v }; init(count: Int, fill: V) { self.v = fill } }
    struct Named<T> { let v: T }
    func mkBox() -> Box<E> { Box(v: E()) }
    func viaBoxGet() { Box(v: E()).get().go() }
    func viaBoxField() { Box(v: E()).v.go() }
    func viaBoxLet() { let b = Box(v: E()); b.get().go() }
    func viaBoxExplicit() { Box<E>(v: E()).get().go() }
    func viaBoxAnnot() { let b: Box<E> = Box(v: E()); b.get().go() }
    func viaBoxOpt() { Box(v: E()).getOpt()?.go() }
    func viaCellInit() { Cell(E()).get().go() }
    func viaPair() { Pair(a: 1, b: E()).second().go() }
    func viaFactory() { mkBox().get().go() }
    func viaParam(_ b: Box<E>) { b.get().go() }
    func viaLetGet() { let e = Box(v: E()).get(); e.go() }
    struct Holder { let b: Box<E>; func run() { b.get().go() } }
    final class K { var b: Box<E>; init() { b = Box(v: E()) }; func run() { self.b.get().go() } }
    struct HolderP { let b: Box<P>; func run() { b.get().go() } }
    func viaHolder() { Holder(b: Box(v: E())).run() }
    func viaK() { K().run() }
    func ctlHolderP() { HolderP(b: Box(v: P())).run() }
    // CONTROLS: the pure instantiation, a second binding of another instantiation, the other position, the
    // other init, and a field typed `T` beside a local type NAMED `T` (the release charged `T.go` there).
    func ctlPure() { Box(v: P()).get().go() }
    func ctlTwo() { let a = Box(v: E()); let b = Box(v: P()); _ = a; b.get().go() }
    func ctlPairFirst() { Pair(a: P(), b: E()).first().go() }
    func ctlMultiFill() { Multi(count: 1, fill: P()).v.go() }
    func ctlNamedT() { Named(v: P()).v.go() }
    // A generic argument spelled with the DECLARATION's parameter (`-> Wrap<Item>` inside `Maker<Item>`) names no
    // type at the use site; without the non-type-name filter this charged the local `Item.go` (measured mutant).
    struct Item { func go() { \(FS) } }
    struct Wrap<W> { let w: W; func get() -> W { w } }
    struct Maker<Item> { func make(_ x: Item) -> Wrap<Item> { Wrap(w: x) } }
    func ctlMaker(_ m: Maker<P>, _ p: P) { m.make(p).get().go() }
    """
    func testAReceiversGenericArgumentTypesItsMember() throws {
        let by = try scan(Self.receiver)
        for f in ["viaBoxGet", "viaBoxField", "viaBoxLet", "viaBoxExplicit", "viaBoxAnnot", "viaBoxOpt", "viaCellInit",
                  "viaPair", "viaFactory", "viaParam", "viaLetGet", "viaHolder", "viaK"] {
            XCTAssertEqual(inf(by, f), ["Fs"], "R1044 residual: \(f) runs E.go; got \(by[f] ?? [:])")
        }
        for f in ["ctlPure", "ctlTwo", "ctlPairFirst", "ctlMultiFill", "ctlNamedT", "ctlMaker", "ctlHolderP"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, f), "R1044 residual: \(f) runs only P.go; got \(by[f] ?? [:])")
        }
        XCTAssertEqual(try gate(Self.receiver, "deny Fs viaBoxGet"), 1, "the gate must flip")
        XCTAssertNotEqual(try gate(Self.receiver, "deny Fs ctlPure"), 1, "the pure instantiation passes")
        let off = try scan(Self.receiver, env: ["CANDOR_R1044B_OFF": "1"])
        XCTAssertNil(ProcessHarness.chargedNothing(off, "viaBoxGet"), "kill switch restores the release silence")
    }

    // ── §E3 — every fixture compiles ────────────────────────────────────────────────────────────────────
    func testEveryFixtureTypechecks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v043-tc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, src) in [("witness", Self.witness), ("receiver", Self.receiver)] {
            let f = root.appendingPathComponent("\(name).swift")
            try src.write(to: f, atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(URL(fileURLWithPath: "/usr/bin/env"), ["swiftc", "-typecheck", f.path])
            if r.code != 0, r.err.contains("env: swiftc") { throw XCTSkip("no swiftc on this host") }
            XCTAssertEqual(r.code, 0, "FIXTURE \(name) MUST COMPILE (§E3); stderr:\n\(r.err)")
        }
    }
}
