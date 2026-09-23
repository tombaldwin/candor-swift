import XCTest
import Foundation

/// SOUNDNESS R563 — A GENERIC PARAMETER USED AS A **TYPE** RECEIVER OVER A LOCAL PROTOCOL LOST THE
/// EFFECT ENTIRELY, AND FIVE SPELLINGS WERE SILENT.
///
/// Every other protocol-dispatch path in this engine keys on a VALUE whose type is a protocol:
/// `protoParams` for a parameter, `localProtocols` for a field or local. When the type parameter is
/// itself the RECEIVER the spelling is `P`, which is in NEITHER index, so every branch missed and the
/// call was DROPPED — and under ⟨0.21⟩ absence from `functions[]` is a positive claim of purity.
///
/// MEASURED before the fix on the fixture below, which `swift build`s and RUNS (§E3 — the seven
/// spellings all execute and reach `sink`, printing `RAN 1 2 4 5 6 7 EffPrim`). One variable: how the
/// receiver is spelled. The conformer, the sink and the protocol are identical in every row.
///
///     func instFnLevel<P: Prim>(_ p: P, _ v: Int) { p.inst(v) }      [Net]    deny Net exit 1
///     func existentialInst(_ p: Prim, _ v: Int)   { p.inst(v) }      [Net]    deny Net exit 1
///     func staticFnLevel<P: Prim>(_ t: P.Type, …) { P.make(v) }      ABSENT   deny Net exit 0
///     struct Box<P: Prim> { func f(…) { P.make(v) } }                ABSENT   deny Net exit 0
///     func ctorFnLevel<P: Prim>(…) -> P           { P(sink: v) }     ABSENT   deny Net exit 0
///     func staticVarFnLevel<P: Prim>(…)           { P.maker(v) }     ABSENT   deny Net exit 0
///     func metatypeParam<P: Prim>(_ t: P.Type, …) { t.make(v) }      ABSENT   deny Net exit 0
///
/// THE TWO INSTANCE ROWS ARE THE CONTROL and they are why this is a defect rather than a design: the
/// engine's own ruling for a LOCAL protocol is to union the conformers, and it applies that ruling
/// through one spelling of the receiver and not the other (§F1.3 — two implementations of one question).
///
/// THE FIX SPANS THREE SYNTACTIC PATHS AND ALL THREE ARE PINNED HERE, because a fix for one draws the
/// audit boundary around its own trigger (§9): the STATIC MEMBER (`P.make`, and the metatype parameter
/// `t.make` that is a second spelling of it), the INITIALIZER (`P(sink:)` — which also needed
/// `DeclCollector` to learn that an `init` REQUIREMENT is a requirement), and the FUNCTION-TYPED
/// requirement (`P.maker(v)`, which INVOKES a stored closure and therefore hedges rather than
/// dispatches — the answer the CONCRETE spelling already gives).
///
/// REAL-WORLD REACH, so this is not a fixture-only shape: swift-nio's `Pool<Element: PoolElement>.get()`
/// is `return Element()` over `protocol PoolElement { init() }` and was ABSENT from `functions[]`;
/// swift-nio's `AtomicPrimitive`/`NIOAtomicPrimitive` are eight function-typed `static var` requirements
/// each, called as `T.atomic_load(…)`; swift-argument-parser's `RawRepresentable where Self:
/// ExpressibleByArgument` initializer calls `RawValue(argument:)`.
final class GenericTypeReceiverDispatchProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: GenericTypeReceiverDispatchProcessTests.self)
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

    /// The fixture, verbatim from the compiled-and-executed package (§E3).
    private static var soloSource: String {
        """
        import Foundation

        public protocol Prim {
            static func make(_ v: Int) -> Int
            static var maker: (Int) -> Int { get }
            init(sink: Int)
            func inst(_ v: Int) -> Int
        }

        func sink(_ v: Int) -> Int { \(SINK); return v }

        public struct EffPrim: Prim {
            public init() {}
            public init(sink v: Int) { _ = sink(v) }
            public static func make(_ v: Int) -> Int { return sink(v) }
            public static let maker: (Int) -> Int = sink
            public func inst(_ v: Int) -> Int { return sink(v) }
        }

        public func instFnLevel<P: Prim>(_ p: P, _ v: Int) -> Int { return p.inst(v) }
        public func existentialInst(_ p: Prim, _ v: Int) -> Int { return p.inst(v) }
        public func staticFnLevel<P: Prim>(_ t: P.Type, _ v: Int) -> Int { return P.make(v) }
        public struct Box<P: Prim> {
            public init() {}
            public func staticTypeLevel(_ v: Int) -> Int { return P.make(v) }
        }
        public func ctorFnLevel<P: Prim>(_ t: P.Type, _ v: Int) -> P { return P(sink: v) }
        public func staticVarFnLevel<P: Prim>(_ t: P.Type, _ v: Int) -> Int { return P.maker(v) }
        public func metatypeParam<P: Prim>(_ t: P.Type, _ v: Int) -> Int { return t.make(v) }
        """
    }

    /// THE FABRICATION CONTROL, and it is the direction this change could plausibly go wrong in: the fix
    /// WIDENS a protocol CHA, so a bound whose conformers are all PURE must stay pure, and a bound naming
    /// a DIFFERENT protocol must not pick up this one's conformers.
    private static var pureSource: String {
        """
        public protocol Calm { static func tick(_ v: Int) -> Int }
        public protocol Loud { static func tick(_ v: Int) -> Int }
        public struct PureCalm: Calm { public static func tick(_ v: Int) -> Int { return v + 1 } }
        public func overCalm<C: Calm>(_ t: C.Type, _ v: Int) -> Int { return C.tick(v) }
        public func overLoud<L: Loud>(_ t: L.Type, _ v: Int) -> Int { return L.tick(v) }
        """
    }

    /// The CONCRETE spellings of the same two calls — no generics, no protocol. They fix what "the right
    /// answer" is for `P.maker(v)`: the engine already says `Unknown` for `EffPrim.maker(v)`, so the
    /// generic spelling must say `Unknown` too rather than invent a more confident one.
    private static var concreteSource: String {
        """
        import Foundation
        func csink(_ v: Int) -> Int { \(SINK); return v }
        public struct CEff {
            public static let maker: (Int) -> Int = csink
            public static func make(_ v: Int) -> Int { return csink(v) }
        }
        public func concreteStaticVar(_ v: Int) -> Int { return CEff.maker(v) }
        public func concreteStaticFn(_ v: Int) -> Int { return CEff.make(v) }
        """
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func render(_ sources: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r563-\(UUID().uuidString)")
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

    /// The three spellings that must carry the EFFECT, because the conformer's witness is a real local
    /// unit the CHA can name: the static member on a function-level bound, the same on the ENCLOSING
    /// TYPE's bound (R550's shape one level over), and the metatype parameter.
    func testAGenericTypeReceiverCarriesItsConformersEffect() throws {
        let (by, root) = try scan(["solo": Self.soloSource])
        for fn in ["staticFnLevel", "Box.staticTypeLevel", "metatypeParam"] {
            XCTAssertEqual(eff(by, fn), ["Net"],
                           "\(fn) dispatches `Prim` over a conformer reaching URLSession — got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net \(fn)"), 1, "`deny Net \(fn)` must catch it")
        }
    }

    /// The two spellings whose witness the engine cannot NAME must still say so out loud. An `init`
    /// requirement resolves to overloaded conformer initializers the CHA cannot pin, and a
    /// function-typed requirement is INVOKED rather than dispatched — both are `Unknown`, never silence.
    /// **A row that is absent and a row that is pure are the same claim**, so both halves are asserted:
    /// present in `functions[]` AND carrying the disclosure.
    func testAnUnnameableWitnessDisclosesRatherThanVanishing() throws {
        let (by, root) = try scan(["solo": Self.soloSource])
        for fn in ["ctorFnLevel", "staticVarFnLevel"] {
            XCTAssertNotNil(by[fn], "\(fn) must not be ABSENT — under ⟨0.21⟩ that is a claim of purity")
            XCTAssertTrue(eff(by, fn).contains("Unknown"), "\(fn) must disclose; got \(eff(by, fn))")
            XCTAssertEqual(try gate(root, "deny Net Unknown \(fn)"), 1,
                           "`deny Net Unknown \(fn)` must catch the disclosed dispatch")
        }
    }

    /// ⟨0.39⟩ OBLIGATION 1 SURVIVES THE HEDGE, and this arm exists because the first cut of the fix
    /// BROKE it: emitting only the `Unknown` for a function-typed requirement, instead of emitting it
    /// BESIDE the dispatch, removed 15 keys / 33 occurrences of `swift-nio#AtomicPrimitive.*` from
    /// `dispatchesOn` in the corpus A/B — a consumer's only join point for its own implementors.
    func testTheWireKeyIsPublishedForEveryGenericTypeReceiver() throws {
        let (by, _) = try scan(["solo": Self.soloSource])
        let expected = ["staticFnLevel": "Solo#Prim.make", "Box.staticTypeLevel": "Solo#Prim.make",
                        "metatypeParam": "Solo#Prim.make", "ctorFnLevel": "Solo#Prim.init",
                        "staticVarFnLevel": "Solo#Prim.maker"]
        for (fn, key) in expected {
            let keys = Set(by[fn]?["dispatchesOn"] as? [String] ?? [])
            XCTAssertTrue(keys.contains(key), "\(fn) must publish \(key); got \(keys.sorted())")
        }
    }

    // ── THE CONTROLS ────────────────────────────────────────────────────────────────────────────

    /// The INSTANCE receiver and the existential resolved before this change and must still. They are
    /// what makes the rows above a defect rather than a policy: one ruling, two spellings.
    func testTheInstanceSpellingsAreUnchanged() throws {
        let (by, _) = try scan(["solo": Self.soloSource])
        XCTAssertEqual(eff(by, "instFnLevel"), ["Net"])
        XCTAssertEqual(eff(by, "existentialInst"), ["Net"])
    }

    /// THE FABRICATION CONTROL. Widening a CHA is where this family has turned a silence into a
    /// fabrication before, so: an all-PURE conformer set must leave the caller pure, and a bound naming
    /// a protocol with NO conformer must not borrow the same-named member of a DIFFERENT protocol.
    func testAPureOrEmptyConformerSetNeverManufacturesAnEffect() throws {
        let (by, root) = try scan(["pure": Self.pureSource])
        XCTAssertFalse(eff(by, "overCalm").contains("Net"),
                       "an all-pure conformer set must not gain an effect; got \(eff(by, "overCalm"))")
        XCTAssertEqual(try gate(root, "deny Net"), 0, "nothing in this package reaches Net")
        XCTAssertFalse(eff(by, "overLoud").contains("Net"),
                       "`Loud` has no conformer — `Calm`'s must not be charged to it")
    }

    /// PARITY WITH THE CONCRETE SPELLING (§F1.3). The generic and the non-generic spelling of one call
    /// must not give two different answers, and the concrete one is the authority because it predates
    /// this change: `CEff.maker(v)` is `Unknown` and `CEff.make(v)` is `Net`.
    func testTheConcreteSpellingsFixWhatTheGenericOnesMustSay() throws {
        let (by, _) = try scan(["concrete": Self.concreteSource])
        XCTAssertTrue(eff(by, "concreteStaticVar").contains("Unknown"),
                      "the concrete static-closure invocation is the parity anchor; got \(eff(by, "concreteStaticVar"))")
        XCTAssertEqual(eff(by, "concreteStaticFn"), ["Net"])
    }
}
