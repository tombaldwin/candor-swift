import XCTest
import Foundation

/// SOUNDNESS R1523 — A WRAPPER INSTANTIATED IN ITS TYPE SPELLING OVER A LOCAL ITERABLE RUNS THAT ITERABLE'S ITERATOR.
/// `func f(_ i: inout InterspersedSequence<LoudSeq>.Iterator) { _ = i.next() }` with swift-algorithms CHAINED wrote
/// LoudSeq's marker (executed) and read `[]` — the published 0.41.3 covered it only with a wrong-reason same-name `Unknown`
/// that R1513 removed, so `deny Unknown` flipped 1→0 (`~/candor-handoff/swift-r1523fix/`). Three routes, each its own switch:
///   (T) `CANDOR_R1523T_OFF` — a value whose WRITTEN type instantiates a generic the scan does not declare (`Ws<L>`,
///       `Ws<L>.Iterator`: a parameter, an annotated local, a field) iterates each local iterable argument when it is
///       iterated, an iterating member is called on it, or it is handed to foreign code (R1048's value rule, by type);
///   (P) `CANDOR_R1523P_OFF` — in one tree, a PARAMETER written `G<L>.Iterator` is an instance of `G<L>` for R1515;
///   (S) `CANDOR_R1523S_OFF` — in one tree, `L().gs()` returning `Gs<Self>` is a `Gs<L>`.
/// Element-generic platform types (`[L]`, `AnySequence<L>`) are not wrappers: iterating them never runs `L`'s iterator.
final class TypePositionWrapperIterationProcessTests: XCTestCase {

    static let seqs = """
    import Foundation
    func mark() { FileManager.default.createFile(atPath: "/tmp/r1523-it", contents: nil) }
    struct TpLoud: Sequence { struct TpLoudIt: IteratorProtocol { var n = 0; mutating func next() -> Int? { mark(); n += 1; return n > 2 ? nil : n } }; func makeIterator() -> TpLoudIt { TpLoudIt() } }
    struct TpPure: Sequence { struct TpPureIt: IteratorProtocol { var n = 0; mutating func next() -> Int? { n += 1; return n > 2 ? nil : n } }; func makeIterator() -> TpPureIt { TpPureIt() } }
    """
    static let wrap = """
    public struct Ws<Base: Sequence>: Sequence {
        var base: Base
        public init(_ b: Base) { base = b }
        public func makeIterator() -> Iterator { Iterator(iterator: base.makeIterator()) }
        public struct Iterator: IteratorProtocol {
            var iterator: Base.Iterator
            public mutating func next() -> Base.Element? { iterator.next() }
        }
    }
    """
    static let app = seqs + """
    import Wrap
    struct HoldL { var s: Ws<TpLoud> }
    struct HoldP { var s: Ws<TpPure> }
    func itrL(_ i: inout Ws<TpLoud>.Iterator) { _ = i.next() }
    func itrP(_ i: inout Ws<TpPure>.Iterator) { _ = i.next() }
    func parL(_ s: Ws<TpLoud>) { for _ in s { } }
    func parP(_ s: Ws<TpPure>) { for _ in s { } }
    func fldL(_ h: HoldL) { for _ in h.s { } }
    func fldP(_ h: HoldP) { for _ in h.s { } }
    func locL(_ s: inout Ws<TpLoud>.Iterator) { var it: Ws<TpLoud>.Iterator = s; _ = it.next() }
    func locP(_ s: inout Ws<TpPure>.Iterator) { var it: Ws<TpPure>.Iterator = s; _ = it.next() }
    func mapL(_ s: Ws<TpLoud>) { _ = s.map { $0 } }
    func mapP(_ s: Ws<TpPure>) { _ = s.map { $0 } }
    func arrC(_ a: [TpLoud]) { for _ in a { } }
    func anyC(_ a: AnySequence<TpLoud>) { for _ in a { } }
    """
    static let chainedL = ["itrL", "parL", "fldL", "locL", "mapL"]
    static let chainedControls = ["itrP", "parP", "fldP", "locP", "mapP", "arrC", "anyC"]

    static func pkg(_ name: String, deps: String = "", targetDeps: String) -> String {
        """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
            dependencies: [\(deps)], targets: [\(targetDeps)])
        """
    }

    /// deps/Wrap scanned standalone, then `app` chained on its report. Rows: fn -> inferred.
    func chained(env: [String: String] = [:]) throws -> [String: Set<String>] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1523-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "deps/Wrap/Package.swift": Self.pkg("Wrap", targetDeps: #".target(name: "Wrap")"#),
            "deps/Wrap/Sources/Wrap/W.swift": Self.wrap,
            "app/Package.swift": Self.pkg("App", deps: #".package(path: "../deps/Wrap")"#,
                                          targetDeps: #".target(name: "App", dependencies: [.product(name: "Wrap", package: "Wrap")])"#),
            "app/Sources/App/app.swift": Self.app,
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
        // the chain is LIVE: the dependency's own `Ws.Iterator.next` is joined (a wrong join would leave `invisible`)
        XCTAssertNil((j?["functions"] as? [[String: Any]])?.first { (($0["invisible"] as? [String]) ?? []).contains("Wrap") },
                     "the Wrap join must be live")
        return rows
    }

    func testChainedTypePositionWrapperIteratesTheLocalArgument() throws {
        let on = try chained()
        for fn in Self.chainedL { XCTAssertTrue(on[fn]?.contains("Fs") == true, "\(fn) runs TpLoud's iterator — \(on[fn] ?? [])") }
        for fn in Self.chainedControls { XCTAssertFalse(on[fn]?.contains("Fs") == true, "\(fn) runs no loud iterator") }
        let off = try chained(env: ["CANDOR_R1523T_OFF": "1"])
        for fn in Self.chainedL { XCTAssertFalse(off[fn]?.contains("Fs") == true, "\(fn) under R1523T_OFF reads as the release did") }
    }

    static let oneTree = seqs + """
    struct Gs<Base: Sequence>: Sequence {
        var base: Base
        init(_ b: Base) { base = b }
        func makeIterator() -> Iterator { Iterator(iterator: base.makeIterator()) }
        struct Iterator: IteratorProtocol { var iterator: Base.Iterator; mutating func next() -> Base.Element? { iterator.next() } }
    }
    extension Sequence { func gs() -> Gs<Self> { Gs(self) } }
    func oItrL(_ i: inout Gs<TpLoud>.Iterator) { _ = i.next() }
    func oItrP(_ i: inout Gs<TpPure>.Iterator) { _ = i.next() }
    func oSelfL() { var i = (TpLoud().gs()).makeIterator(); _ = i.next() }
    func oSelfP() { var i = (TpPure().gs()).makeIterator(); _ = i.next() }
    """

    private func scan(_ root: URL, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    func testOneTreeParameterAndSelfInstantiation() throws {
        let root = try ProcessHarness.makePackage(Self.oneTree)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in ["oItrL", "oSelfL"] { XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) — \(by[fn] ?? [:])") }
        for fn in ["oItrP", "oSelfP"] { XCTAssertFalse(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) is pure") }
        let offP = try scan(root, env: ["CANDOR_R1523P_OFF": "1"])
        XCTAssertFalse(ProcessHarness.inferred(offP, "oItrL")?.contains("Fs") == true, "oItrL under R1523P_OFF")
        let offS = try scan(root, env: ["CANDOR_R1523S_OFF": "1"])
        XCTAssertFalse(ProcessHarness.inferred(offS, "oSelfL")?.contains("Fs") == true, "oSelfL under R1523S_OFF")
    }
}
