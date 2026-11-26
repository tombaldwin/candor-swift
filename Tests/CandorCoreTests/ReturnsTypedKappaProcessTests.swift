import XCTest
import Foundation
@testable import CandorCore

/// Stage S2e of the curated-routing design (D4; Fable review Q3, N8) and SOUNDNESS R1875.
///
/// **S2e.** `let r = makeClient(); r.get(p)`, `makeClient().get(p)` and `HTTPClient.make().get(p)` reach the same member as
/// `r: HTTPClient; r.get(p)`, but the receiver's type is known only in the Driver, after the producer's `typeSurface.returns`
/// named it. The chained join read the row and never asked κ, so a row that under-reports what κ knows answered alone. κ's
/// term is now unioned there, keyed on IDENTITY: only when the returned type is the entity the κ registry describes
/// (`kappaRelation == .same` for the producing package's module). A different package's type that merely shares the κ
/// root's NAME is not charged.
///
/// **R1875.** `let c = makeNodes().first!; c.touch(p)` (and `makeNodes()[0].touch(p)`, `makeNodes().first!.touch(p)`):
/// the receiver is an ELEMENT of a dependency factory's result, so no identity was formed and the member call was dropped.
/// Unchained the factory call's own `invisible` named the module; chained, the factory's (pure) row was read and nothing
/// was left: `deny Fs` and `deny Fs Unknown` 0 over an executed write. The chained arm now discloses with the untyped
/// marker's token. Unchained is unchanged.
///
/// The dependency bodies are one line each and write exactly the file they are given (`_w`) or touch nothing (`_p`).
/// Arms vary only `CANDOR_DEPS`.
final class ReturnsTypedKappaProcessTests: XCTestCase {

    private static let deps: [(String, String)] = [
        ("AsyncHTTPClient", """
        import Foundation
        public final class HTTPClient {
            public init() {}
            public func get(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 }
            public func put(_ p: String) -> Int { return p.count }
            public static func make() -> HTTPClient { HTTPClient() }
        }
        public func makeClient() -> HTTPClient { HTTPClient() }
        """),
        ("Imposter", """
        import Foundation
        public final class HTTPClient {
            public init() {}
            public func get(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 }
        }
        public func makeImposter() -> HTTPClient { HTTPClient() }
        public func names() -> [String] { ["a"] }
        """),
        ("Nodes", """
        import Foundation
        public final class Node {
            public init() {}
            public func touch(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 }
            public func rest(_ p: String) -> Int { return p.count }
        }
        public func makeNodes() -> [Node] { [Node()] }
        """),
    ]

    private static let appFiles: [(String, String)] = [
        ("ahc.swift", """
        import Foundation
        import AsyncHTTPClient
        public func s2eBound(_ p: String) -> Int { let r = makeClient(); return r.get(p) }
        public func s2eReturned(_ p: String) -> Int { return makeClient().get(p) }
        public func s2eStatic(_ p: String) -> Int { return HTTPClient.make().get(p) }
        public func s2ePureVerb(_ p: String) -> Int { return makeClient().put(p) }
        """),
        ("imp.swift", """
        import Foundation
        import Imposter
        public func impReturned(_ p: String) -> Int { return makeImposter().get(p) }
        public func platformLeafElement(_ p: String) -> Int { return names().first!.uppercased().count + p.count }
        """),
        ("nodes.swift", """
        import Foundation
        import Nodes
        public func elemBound(_ p: String) -> Int { let c = makeNodes().first!; return c.touch(p) }
        public func elemUnbound(_ p: String) -> Int { return makeNodes().first!.touch(p) }
        public func elemSubscript(_ p: String) -> Int { return makeNodes()[0].touch(p) }
        public func elemPureTwin(_ p: String) -> Int { let c = makeNodes().first!; return c.rest(p) }
        """),
    ]

    private struct Row { var inferred: Set<String>; var why: Set<String>; var invisible: Set<String> }
    private struct Fixture { let root: URL; let bin: URL
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") } }

    private func make() throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-s2e-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let fx = Fixture(root: root, bin: bin)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        for (m, src) in Self.deps {
            try write("\(m)/Package.swift", """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "\(m)", products: [.library(name: "\(m)", targets: ["\(m)"])],
                targets: [.target(name: "\(m)")])
            """)
            try write("\(m)/Sources/\(m)/lib.swift", src)
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent(m).path,
                                                 "--out", fx.depDir.appendingPathComponent("d").path])
            XCTAssertEqual(r.code, 0, "dependency scan must succeed — stderr: \(r.err)")
        }
        for f in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path)
        where f.hasSuffix(".callgraph.json") || f.hasSuffix(".hierarchy.json") {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(f))
        }
        let pkgs = Self.deps.map { ".package(path: \"../\($0.0)\")" }.joined(separator: ", ")
        let prods = Self.deps.map { ".product(name: \"\($0.0)\", package: \"\($0.0)\")" }.joined(separator: ", ")
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [\(pkgs)], targets: [.target(name: "App", dependencies: [\(prods)])])
        """)
        for (n, src) in Self.appFiles { try write("app/Sources/App/\(n)", src) }
        return fx
    }

    private func scan(_ fx: Fixture, chained: Bool, env extra: [String: String] = [:], _ tag: String) throws -> [String: Row] {
        var env = extra
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let r = try ProcessHarness.run(fx.bin, [fx.appDir.path, "--out", fx.root.appendingPathComponent(tag).path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fx.root.appendingPathComponent("\(tag).App.Swift.json"))) as? [String: Any]
        var rows: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = Row(inferred: Set((f["inferred"] as? [String]) ?? []),
                                                    why: Set((f["unknownWhy"] as? [String]) ?? []),
                                                    invisible: Set((f["invisible"] as? [String]) ?? []))
        }
        return rows
    }

    private func gate(_ fx: Fixture, chained: Bool, _ deny: String) throws -> Int32 {
        var env: [String: String] = [:]
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let pol = fx.root.appendingPathComponent("p-\(UUID().uuidString).policy")
        try "\(deny)\n".write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(fx.bin, [fx.appDir.path, "--policy", pol.path,
                                               "--out", fx.root.appendingPathComponent("g-\(UUID().uuidString)").path],
                                      env: env).code
    }

    func testAReturnsTypedReceiverUnionsTheKappaTerm() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        let ch = try scan(fx, chained: true, "ch")
        for fn in ["s2eBound", "s2eReturned", "s2eStatic"] {
            XCTAssertEqual(ch[fn]?.inferred.isSuperset(of: ["Fs", "Net"]), true,
                           "\(fn): the chained row (Fs) AND κ's verb (Net) answer the same member — got \(String(describing: ch[fn]))")
            XCTAssertEqual(try gate(fx, chained: true, "deny Net \(fn)"), 1, "\(fn): the κ term must reach the gate")
        }
        // κ's over-approximation on a pure κ verb is the permitted direction (SPEC §2); `Fs` on it would be a fabrication.
        XCTAssertEqual(ch["s2ePureVerb"]?.inferred.contains("Net"), true)
        XCTAssertEqual(ch["s2ePureVerb"]?.inferred.contains("Fs"), false)
        // Unchained the receiver is not typed (no `returns`), so the release's disclosure stands and nothing is added.
        let nc = try scan(fx, chained: false, "nc")
        for fn in ["s2eBound", "s2eReturned"] {
            XCTAssertEqual(nc[fn]?.inferred, ["Unknown"], "\(fn) unchained must stay the release's hedge")
        }
    }

    func testAProducerTypeThatOnlySharesTheKappaRootNameIsNotCharged() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        let ch = try scan(fx, chained: true, "ch")
        XCTAssertEqual(ch["impReturned"]?.inferred, ["Fs"],
                       "Imposter#HTTPClient is not the entity κ's `HTTPClient` describes: its row answers, κ must not")
        XCTAssertNotEqual(try gate(fx, chained: true, "deny Net impReturned"), 1, "no Net may be fabricated")
    }

    func testAnElementOfADependencyFactoryResultDisclosesChained() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        let ch = try scan(fx, chained: true, "ch")
        for fn in ["elemBound", "elemUnbound", "elemSubscript"] {
            XCTAssertEqual(ch[fn]?.inferred.contains("Unknown"), true,
                           "\(fn): a chained miss must not read pure — got \(String(describing: ch[fn]))")
            XCTAssertEqual(ch[fn]?.why.contains("dispatch:untyped cross-package receiver"), true)
            XCTAssertEqual(try gate(fx, chained: true, "deny Fs Unknown \(fn)"), 1)
        }
        XCTAssertNil(ch["elemPureTwin"], "a leaf no chained package publishes (pure `rest`) is not hedged")
        XCTAssertNil(ch["platformLeafElement"], "a platform-only leaf (`uppercased`) is not hedged")
        // Unchained: the factory call's own `invisible` still names the module, and — since curated-routing S3 (lane L8,
        // the C12 hedge) — the dropped member call itself discloses, because `Nodes`' readable sources declare the member.
        // The pure twin is hedged too: nothing unchained can tell `rest` from `touch`.
        let nc = try scan(fx, chained: false, "nc")
        for (fn, m) in [("elemBound", "touch"), ("elemUnbound", "touch"), ("elemSubscript", "touch"), ("elemPureTwin", "rest")] {
            XCTAssertEqual(nc[fn]?.inferred, ["Unknown"], "\(fn) unchained (L8: was `[]`, `invisible` only)")
            XCTAssertEqual(nc[fn]?.why, ["dispatch:<untyped>.\(m)"], "\(fn) unchained")
            XCTAssertEqual(nc[fn]?.invisible, ["Nodes"], "\(fn) unchained")
        }
        let ncOff = try scan(fx, chained: false, env: ["CANDOR_C12_OFF": "1"], "ncoff")
        for fn in ["elemBound", "elemUnbound", "elemSubscript", "elemPureTwin"] {
            XCTAssertEqual(ncOff[fn]?.inferred, [], "\(fn) unchained with the C12 hedge off: the release's reading")
        }
    }
}
