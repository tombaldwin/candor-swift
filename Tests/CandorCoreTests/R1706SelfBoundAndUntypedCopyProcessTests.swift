import XCTest
import Foundation

/// SOUNDNESS R1706 — TWO UNITS THAT READ `[]` OVER A CALLER-CHOSEN TYPE'S EFFECT, both found by the 0.42 release bar against the
/// published 0.41.3 (executed: swiftc, a `Wrap` module and an `App` module, `~/…/swiftagent-r1706/exec`; every `…L` function runs the
/// loud body and writes its marker, every `…P`/`…Q` control runs none).
///
/// (1) `extension P where Self: Q { static func pn() { Self.q… } }` — `Self`'s only name is `P`, which does not declare `q`, so the
///     dispatch gate (`protoOrSuperDeclares(P, q)`) dropped the read with no edge and no `Unknown`: `Msg.protoName` (swift-protobuf's
///     `Message where Self: _ProtoNameProviding`) read pure ONE TREE and chained, and every caller with it. A `where Self: Q` is a
///     bound of `self`; the read/call now dispatches over `Q`'s conformers and publishes `Q`'s `dispatchesOn` key (SPEC §4 ⟨0.39⟩
///     obligation 1), which the consumer joins. Switch `CANDOR_R1706_OFF`.
/// (2) `func f(_ i: G<L>.Iterator) { var j = i; _ = j.next() }` (and `var i = i`, `var j = h.it`, `let a = i; var b = a`) — an UNTYPED
///     copy was not written, so R1523 never iterated `L`. A binding has its initializer's static type; `j` is written as `i` is.
final class R1706SelfBoundAndUntypedCopyProcessTests: XCTestCase {

    static let oneTree = """
    import Foundation
    func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1706t-" + s, contents: nil) }
    protocol Msg1706 { init() }
    protocol Name1706 { static var nameMap: [Int: String] { get }; static func hook(); func inst() }
    extension Msg1706 where Self: Name1706 {
        static func pn(_ n: Int) -> String? { Self.nameMap[n] }
        static func ph() { Self.hook() }
        func pi() { self.inst() }
        func pi2() { inst() }
        var pv: String? { Self.nameMap[1] }
    }
    extension Msg1706 {
        static func plain(_ n: Int) -> Int { n }
    }
    struct LoudA: Msg1706, Name1706 { init() {}; static var nameMap: [Int: String] { mark("a"); return [:] }; static func hook() { mark("h") }; func inst() { mark("i") } }
    func viaGen<M: Msg1706 & Name1706>(_ t: M.Type) { _ = M.pn(1) }
    func hookGen<M: Msg1706 & Name1706>(_ t: M.Type) { M.ph() }
    func viaParam(_ t: LoudA.Type) { _ = t.pn(1) }
    func viaInst(_ m: LoudA) { m.pi() }
    func viaProp(_ m: LoudA) { _ = m.pv }
    func viaPlain<M: Msg1706 & Name1706>(_ t: M.Type) { _ = M.plain(1) }
    """
    static let oneTreePure = """
    import Foundation
    protocol Msg1706q { init() }
    protocol Name1706q { static var nameMap: [Int: String] { get }; static func hook(); func inst() }
    extension Msg1706q where Self: Name1706q {
        static func pn(_ n: Int) -> String? { Self.nameMap[n] }
        static func ph() { Self.hook() }
        func pi() { self.inst() }
        var pv: String? { Self.nameMap[1] }
    }
    struct QuietA: Msg1706q, Name1706q { init() {}; static var nameMap: [Int: String] { [1: "q"] }; static func hook() { }; func inst() { } }
    func qGen<M: Msg1706q & Name1706q>(_ t: M.Type) { _ = M.pn(1) }
    func qGenHook<M: Msg1706q & Name1706q>(_ t: M.Type) { M.ph() }
    func qInst(_ m: QuietA) { m.pi() }
    func qProp(_ m: QuietA) { _ = m.pv }
    """

    private func scan(_ src: String, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }
    private func gate(_ src: String, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = root.appendingPathComponent("policy.candor")
        try policy.write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", root.appendingPathComponent("g").path], env: env).code
    }

    func testOneTreeSelfWhereBoundDispatchesOverTheRequiredProtocol() throws {
        let on = try scan(Self.oneTree)
        // `Msg1706.ph` / `hookGen` are the CONTROL: a STATIC call through `Self.` already dispatched on the release (charged on every
        // arm, so they say nothing about this change). The property read, the instance calls and the computed property were silent.
        for fn in ["Msg1706.pn", "Msg1706.pi", "Msg1706.pi2", "Msg1706.pv", "Msg1706.ph", "viaGen", "hookGen", "viaParam", "viaInst", "viaProp"] {
            XCTAssertEqual(ProcessHarness.inferred(on, fn), ["Fs"], "\(fn) runs LoudA's body (executed) — \(on[fn] ?? [:])")
        }
        XCTAssertNil(ProcessHarness.chargedNothing(on, "viaPlain"), "an extension member with no Self requirement reads no Q member")
        let off = try scan(Self.oneTree, env: ["CANDOR_R1706_OFF": "1"])
        for fn in ["Msg1706.pn", "Msg1706.pi", "Msg1706.pi2", "Msg1706.pv", "viaGen", "viaParam", "viaInst", "viaProp"] {
            XCTAssertNil(ProcessHarness.inferred(off, fn)?.first, "the release was silent: \(fn) \(off[fn] ?? [:])")
        }
        XCTAssertEqual(ProcessHarness.inferred(off, "Msg1706.ph"), ["Fs"], "the static `Self.hook()` control charged on the release too")
        XCTAssertEqual(try gate(Self.oneTree, "deny Fs viaGen\n"), 1)
        XCTAssertEqual(try gate(Self.oneTree, "deny Fs viaGen\n", env: ["CANDOR_R1706_OFF": "1"]), 0)
        XCTAssertEqual(try gate(Self.oneTree, "deny Fs viaParam\n"), 1)
        XCTAssertEqual(try gate(Self.oneTree, "deny Fs viaProp\n"), 1)
        XCTAssertEqual(try gate(Self.oneTree, "deny Fs viaProp\n", env: ["CANDOR_R1706_OFF": "1"]), 0)
    }

    func testAPureConformerOnlyStaysPure() throws {
        let by = try scan(Self.oneTreePure)
        for fn in ["Msg1706q.pn", "Msg1706q.ph", "Msg1706q.pi", "Msg1706q.pv", "qGen", "qGenHook", "qInst", "qProp"] {
            XCTAssertNil(ProcessHarness.inferred(by, fn)?.first, "no loud conformer anywhere: \(fn) \(by[fn] ?? [:])")
        }
        XCTAssertEqual(try gate(Self.oneTreePure, "deny Fs qGen\n"), 0)
        XCTAssertEqual(try gate(Self.oneTreePure, "deny Unknown qGen\n"), 0)
    }

    // ── chained ────────────────────────────────────────────────────────────────────────────────────────────────────
    static let wrap = """
    public struct Ws<Base: Sequence>: Sequence {
        var base: Base
        public init(_ b: Base) { base = b }
        public func makeIterator() -> Iterator { Iterator(iterator: base.makeIterator()) }
        public struct Iterator: IteratorProtocol {
            var iterator: Base.Iterator
            public init(iterator: Base.Iterator) { self.iterator = iterator }
            public mutating func next() -> Base.Element? { iterator.next() }
        }
    }
    public protocol Msg { init() }
    public protocol NameProv { static var nameMap: [Int: String] { get } }
    extension Msg where Self: NameProv {
        fileprivate static func protoName(for n: Int) -> String? { Self.nameMap[n] }
    }
    public struct MaskBox {
        public var paths: [String] = []
        public init<M: Msg & NameProv>(numbers: [Int], of t: M.Type) throws {
            var ps: [String] = []
            for n in numbers { guard let nm = M.protoName(for: n) else { throw NSErr.bad }; ps.append(nm) }
            paths = ps
        }
    }
    public enum NSErr: Error { case bad }
    public struct Dur: Msg, NameProv { public init() {}; public static var nameMap: [Int: String] { [1: "d"] } }
    public struct Dur2: Msg, NameProv { public init() {}; public static var nameMap: [Int: String] { [2: "d2"] } }
    """
    static let pureApp = """
    import Foundation
    import Wrap
    public struct PureIt: IteratorProtocol { var n = 0; public mutating func next() -> Int? { n += 1; return n > 1 ? nil : n } }
    public struct PureSq: Sequence { public init() {}; public func makeIterator() -> PureIt { PureIt() } }
    public struct HoldP { public var it: Ws<PureSq>.Iterator }
    func typePosP(_ i: Ws<PureSq>.Iterator) { var j = i; _ = j.next() }
    func shadowP(_ i: Ws<PureSq>.Iterator) { var i = i; _ = i.next() }
    func copyFieldP(_ h: HoldP) { var j = h.it; _ = j.next() }
    func chainP(_ i: Ws<PureSq>.Iterator) { let a = i; var b = a; _ = b.next() }
    func optBindP(_ o: Ws<PureSq>.Iterator?) { if var j = o { _ = j.next() } }
    func guardBindP(_ o: Ws<PureSq>.Iterator?) { guard var j = o else { return }; _ = j.next() }
    func arrElemP(_ a: [Ws<PureSq>.Iterator]) { for var it in a { _ = it.next() } }
    func parenCopyP(_ i: Ws<PureSq>.Iterator) { var j = (i); _ = j.next() }
    func forceUnwrapP(_ o: Ws<PureSq>.Iterator?) { var j = o!; _ = j.next() }
    public struct QuietMsg: Msg, NameProv { public init() {}; public static var nameMap: [Int: String] { [1: "q"] } }
    func gen<M: Msg & NameProv>(_ t: M.Type) throws -> MaskBox { try MaskBox(numbers: [1], of: t) }
    func mGenCallQ() throws { _ = try gen(QuietMsg.self) }
    func mParamQ(_ t: QuietMsg.Type) throws { _ = try MaskBox(numbers: [1], of: t) }
    """
    static let loudApp = pureApp + """
    func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1706c-" + s, contents: nil) }
    public struct LoudIt: IteratorProtocol { var n = 0; public mutating func next() -> Int? { mark("it"); n += 1; return n > 1 ? nil : n } }
    public struct LoudSq: Sequence { public init() {}; public func makeIterator() -> LoudIt { LoudIt() } }
    public struct HoldL { public var it: Ws<LoudSq>.Iterator }
    func typePosL(_ i: Ws<LoudSq>.Iterator) { var j = i; _ = j.next() }
    func shadowL(_ i: Ws<LoudSq>.Iterator) { var i = i; _ = i.next() }
    func copyFieldL(_ h: HoldL) { var j = h.it; _ = j.next() }
    func chainL(_ i: Ws<LoudSq>.Iterator) { let a = i; var b = a; _ = b.next() }
    func annotL(_ i: Ws<LoudSq>.Iterator) { var j: Ws<LoudSq>.Iterator = i; _ = j.next() }
    func optBindL(_ o: Ws<LoudSq>.Iterator?) { if var j = o { _ = j.next() } }
    func guardBindL(_ o: Ws<LoudSq>.Iterator?) { guard var j = o else { return }; _ = j.next() }
    func arrElemL(_ a: [Ws<LoudSq>.Iterator]) { for var it in a { _ = it.next() } }
    func parenCopyL(_ i: Ws<LoudSq>.Iterator) { var j = (i); _ = j.next() }
    func forceUnwrapL(_ o: Ws<LoudSq>.Iterator?) { var j = o!; _ = j.next() }
    public struct LoudMsg: Msg, NameProv { public init() {}; public static var nameMap: [Int: String] { mark("nm"); return [1: "l"] } }
    func mGenCallL() throws { _ = try gen(LoudMsg.self) }
    func mParamL(_ t: LoudMsg.Type) throws { _ = try MaskBox(numbers: [1], of: t) }
    func mVarL() throws { let t: LoudMsg.Type = LoudMsg.self; _ = try MaskBox(numbers: [1], of: t) }
    """

    static func pkg(_ name: String, deps: String = "", targetDeps: String) -> String {
        """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
            dependencies: [\(deps)], targets: [\(targetDeps)])
        """
    }

    /// `Wrap` scanned standalone, then `app` chained on its report. Rows: fn -> inferred.
    func chained(_ app: String, env: [String: String] = [:]) throws -> [String: Set<String>] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1706-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "deps/Wrap/Package.swift": Self.pkg("Wrap", targetDeps: #".target(name: "Wrap")"#),
            "deps/Wrap/Sources/Wrap/W.swift": Self.wrap,
            "app/Package.swift": Self.pkg("App", deps: #".package(path: "../deps/Wrap")"#,
                                          targetDeps: #".target(name: "App", dependencies: [.product(name: "Wrap", package: "Wrap")])"#),
            "app/Sources/App/app.swift": app,
        ]
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let depR = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depR, withIntermediateDirectories: true)
        let d = try ProcessHarness.run(bin, [root.appendingPathComponent("deps/Wrap").path, "--out", depR.appendingPathComponent("w").path], env: env)
        XCTAssertEqual(d.code, 0, "dep: \(d.err)")
        for f in try FileManager.default.contentsOfDirectory(atPath: depR.path)
        where f.hasSuffix(".callgraph.json") || f.hasSuffix(".hierarchy.json") {
            try FileManager.default.removeItem(at: depR.appendingPathComponent(f))
        }
        var e = env; e["CANDOR_DEPS"] = depR.path
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", root.appendingPathComponent("ch").path], env: e)
        XCTAssertEqual(r.code, 0, "app: \(r.err)")
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Set<String>] = [:]
        for f in (j?["functions"] as? [[String: Any]]) ?? [] { rows[(f["fn"] as? String) ?? "?"] = Set((f["inferred"] as? [String]) ?? []) }
        // the chain is LIVE: the dependency's own rows are joined (a missed join would leave `invisible`)
        XCTAssertNil((j?["functions"] as? [[String: Any]])?.first { (($0["invisible"] as? [String]) ?? []).contains("Wrap") },
                     "the Wrap join must be live")
        return rows
    }

    static let untypedCopyL = ["typePosL", "shadowL", "copyFieldL", "chainL", "annotL", "optBindL", "guardBindL", "arrElemL", "parenCopyL", "forceUnwrapL"]
    static let untypedCopyP = ["typePosP", "shadowP", "copyFieldP", "chainP", "optBindP", "guardBindP", "arrElemP", "parenCopyP", "forceUnwrapP"]
    static let selfBoundL = ["gen", "mGenCallL", "mParamL", "mVarL"]

    func testChainedUntypedCopyOfATypedParameterIsWrittenAsItsSource() throws {
        let on = try chained(Self.loudApp)
        for fn in Self.untypedCopyL { XCTAssertTrue(on[fn]?.contains("Fs") == true, "\(fn) runs LoudIt.next (executed) — \(on[fn] ?? [])") }
        let off = try chained(Self.loudApp, env: ["CANDOR_R1706_OFF": "1"])
        for fn in ["typePosL", "shadowL", "copyFieldL", "chainL", "optBindL", "guardBindL", "arrElemL", "parenCopyL"] {
            XCTAssertFalse(off[fn]?.contains("Fs") == true, "\(fn) under R1706_OFF reads as the release did — \(off[fn] ?? [])")
        }
        XCTAssertTrue(off["annotL"]?.contains("Fs") == true, "the annotated copy always charged")
        // the pure twins live in a consumer WITHOUT a loud type, so the iterator-fan-out cannot charge them
        let pure = try chained(Self.pureApp)
        for fn in Self.untypedCopyP { XCTAssertTrue((pure[fn] ?? []).isEmpty, "\(fn) iterates a pure sequence — \(pure[fn] ?? [])") }
    }

    func testChainedSelfWhereBoundPublishesItsKeyAndTheConsumerJoinsIt() throws {
        let on = try chained(Self.loudApp)
        for fn in Self.selfBoundL { XCTAssertTrue(on[fn]?.contains("Fs") == true, "\(fn) runs LoudMsg.nameMap (executed) — \(on[fn] ?? [])") }
        let off = try chained(Self.loudApp, env: ["CANDOR_R1706_OFF": "1"])
        for fn in ["gen", "mParamL", "mVarL"] { XCTAssertFalse(off[fn]?.contains("Fs") == true, "\(fn) under R1706_OFF reads as the release did — \(off[fn] ?? [])") }
        let pure = try chained(Self.pureApp)
        for fn in ["gen", "mParamQ"] { XCTAssertTrue((pure[fn] ?? []).isEmpty, "\(fn) reads a pure nameMap — \(pure[fn] ?? [])") }
    }
}
