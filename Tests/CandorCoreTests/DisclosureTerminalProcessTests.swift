import XCTest
import Foundation
@testable import CandorCore

/// Curated-routing stage S3 (lane L8): ONE disclosure terminal.
///
/// Part 1 — THE FOLD. Six arms decided "does an unanswered call into a dependency say so?" each at its own site: R1866's
/// untyped and typed halves (with R836/R1066's standalone evidence beside the first), and the `invisible` ledger's free-call,
/// protocol-spelling (R706), module-qualified, source-declared (R1066/R1071) and unreadable (R1104) arms. They are one
/// decision now (`terminalDecision`), and the fold is NON-ADDITIVE in code, so it must be INERT in output:
/// `CANDOR_S3_FOLD_OFF=1` runs the old arms where they stood, and every report must be byte-identical (bar the envelope's
/// `switches`). The tokens are per cause and are pinned here, because PART 110's OWN-HEDGE seed and SPEC's reason table
/// read them.
///
/// Part 2 — THE C12 HEDGE (SOUNDNESS R1455 residue, R1875's corrected mechanism). An explicit member call whose receiver no
/// stage-1 rule typed was dropped with no edge and no `Unknown`; where a dependency could be what it reaches, it now
/// reads `Unknown {dispatch:<untyped>.<m>}`. Bodies follow the L0 matrix's Guess package, executed there.
final class DisclosureTerminalProcessTests: XCTestCase {

    private static let deps: [String: String] = [
        "AsyncHTTPClient": """
        import Foundation
        func hcWrite(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
        open class HTTPClient {
            public init() {}
            open func get(_ p: String) -> Int { hcWrite(p); return 1 }
            open func tally(_ p: String) -> Int { hcWrite(p); return 1 }
        }
        public func makeClient() -> HTTPClient { HTTPClient() }
        public func makeClients() -> [HTTPClient] { [HTTPClient()] }
        """,
        "Guess": """
        import Foundation
        public final class Node {
            public init() {}
            public func touch(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 }
            public func rest(_ p: String) -> Int { return p.count }
        }
        public protocol Pinger { func ping(_ p: String) -> Int }
        public func makeNode() -> Node { Node() }
        public func makeNodes() -> [Node] { [Node()] }
        public func guessFree(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 }
        extension String { public func slurp(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 } }
        """,
    ]

    private static let app = """
    import Foundation
    import AsyncHTTPClient
    import Guess
    // part 1: one cell per folded arm
    public func t_untyped(_ p: String) -> Int { let r = makeClient(); return r.tally(p) }        // R1866 untyped (D5)
    public func t_typed(_ r: HTTPClient, _ p: String) -> Int { r.tally(p) }                       // R1866 typed (D8)
    public func t_free(_ p: String) -> Int { guessFree(p) }                                         // ledger: free call
    public func t_modq(_ p: String) -> Int { Guess.guessFree(p) }                                   // ledger: module-qualified
    public func t_srcdecl(_ n: Node, _ p: String) -> Int { n.touch(p) }                            // ledger: R1066
    public func t_proto(_ q: any Pinger, _ p: String) -> Int { q.ping(p) }                          // ledger: R706
    public func t_ext(_ p: String) -> Int { "x".slurp(p) }                                          // ledger: R1071
    // part 2: the C12 drop (receivers no stage-1 rule types)
    public func c12_shorthand_w(_ p: String) -> Int { var n = 0; makeNodes().forEach { n += $0.touch(p) }; return n }
    public func c12_localcall_w(_ p: String) -> Int { let c = makeNodes().first!; return c.touch(p) }
    public func c12_kappaelem_w(_ p: String) -> Int { makeClients().first!.get(p) }
    // controls: a leaf only the platform declares (labels bind `hasPrefix(_:)`), and a leaf only THIS package declares
    public func c12_platform_p(_ p: String) -> Bool { makeNodes().map { _ in p }.first!.hasPrefix(p) }
    public final class Mine { public init() {}; public func mineOnly(_ p: String) -> Int { p.count } }
    public func c12_localonly_p(_ p: String) -> Int { var n = 0; [Mine()].forEach { n += $0.mineOnly(p) }; return n }
    """

    private struct Fixture { let root: URL; let bin: URL
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") } }

    private func make() throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-s3-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        for (dep, src) in Self.deps {
            try write("\(dep)/Package.swift", """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "\(dep)", products: [.library(name: "\(dep)", targets: ["\(dep)"])],
                targets: [.target(name: "\(dep)")])
            """)
            try write("\(dep)/Sources/\(dep)/lib.swift", src)
        }
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../AsyncHTTPClient"), .package(path: "../Guess")],
            targets: [.target(name: "App", dependencies: [.product(name: "AsyncHTTPClient", package: "AsyncHTTPClient"),
                                                          .product(name: "Guess", package: "Guess")])])
        """)
        try write("app/Sources/App/app.swift", Self.app)
        let fx = Fixture(root: root, bin: bin)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        for dep in Self.deps.keys {
            let rd = try ProcessHarness.run(bin, [root.appendingPathComponent(dep).path, "--out", fx.depDir.appendingPathComponent("r\(dep)").path])
            XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        }
        for extra in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path)
            where !(extra.hasSuffix(".Swift.json") && !extra.contains("callgraph") && !extra.contains("hierarchy")) {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(extra))
        }
        return fx
    }

    private struct Row: Equatable { var inferred: Set<String>; var why: Set<String>; var invisible: Set<String> }

    /// The report's `functions`, as raw JSON objects keyed by `fn` (for byte comparison) and as rows (for assertions).
    private func scan(_ fx: Fixture, chained: Bool, env extra: [String: String] = [:]) throws -> (raw: [String: NSDictionary], rows: [String: Row]) {
        var env = extra
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let tag = "o-\(UUID().uuidString)"
        let r = try ProcessHarness.run(fx.bin, [fx.appDir.path, "--out", fx.root.appendingPathComponent(tag).path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: fx.root.appendingPathComponent("\(tag).App.Swift.json"))) as? [String: Any]
        var raw: [String: NSDictionary] = [:], rows: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            let fn = (f["fn"] as? String) ?? "?"
            raw[fn] = f as NSDictionary
            rows[fn] = Row(inferred: Set((f["inferred"] as? [String]) ?? []), why: Set((f["unknownWhy"] as? [String]) ?? []),
                           invisible: Set((f["invisible"] as? [String]) ?? []))
        }
        return (raw, rows)
    }

    private func gate(_ fx: Fixture, chained: Bool, _ deny: String) throws -> Int32 {
        var env: [String: String] = [:]
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let pol = fx.root.appendingPathComponent("p-\(UUID().uuidString).policy")
        try "\(deny)\n".write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(fx.bin, [fx.appDir.path, "--policy", pol.path,
                                               "--out", fx.root.appendingPathComponent("g-\(UUID().uuidString)").path], env: env).code
    }

    // ── part 1: the fold ──

    func testTheFoldIsInertAndKeepsEveryArmsTokenUnchainedAndChained() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        for chained in [false, true] {
            let folded = try scan(fx, chained: chained), old = try scan(fx, chained: chained, env: ["CANDOR_S3_FOLD_OFF": "1"])
            XCTAssertEqual(Set(folded.raw.keys), Set(old.raw.keys), "chained=\(chained): the fold must not add or remove a row")
            for (fn, o) in old.raw { XCTAssertEqual(folded.raw[fn], o, "chained=\(chained) \(fn): the fold moved a byte") }
        }
        let nc = try scan(fx, chained: false).rows
        // the posture table, per cause — an `Unknown` never becomes an `invisible`
        XCTAssertEqual(nc["t_untyped"]?.why, ["dispatch:untyped cross-package receiver"], "R1866 untyped: receiver not typed")
        XCTAssertEqual(nc["t_typed"]?.why, ["dispatch:HTTPClient.tally"], "R1866 typed: owner known, member unread")
        XCTAssertEqual(nc["t_free"]?.invisible, ["AsyncHTTPClient", "Guess"],
                       "free call: file-granular, every uncovered import (R548/R827; F5 names the κ-dependency module too)")
        for c in ["t_free", "t_modq", "t_srcdecl", "t_proto", "t_ext"] {
            XCTAssertTrue(nc[c]?.invisible.contains("Guess") ?? false, "\(c): the ledger names the uncovered package")
            XCTAssertFalse(nc[c]?.inferred.contains("Unknown") ?? true, "\(c): `invisible` only (non-gating, R133)")
        }
    }

    func testTheInertnessCheckCanFailWhenOneOldArmIsOff() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        let folded = try scan(fx, chained: false)
        let seeded = try scan(fx, chained: false, env: ["CANDOR_S3_FOLD_OFF": "1", "CANDOR_R1066_OFF": "1"])
        XCTAssertNotEqual(folded.raw["t_srcdecl"], seeded.raw["t_srcdecl"],
                          "with ONE old arm (R1066) off the two arms must differ, or the byte comparison above proves nothing")
    }

    // ── part 2: the C12 hedge ──

    func testAnUnidentifiedMemberCallADependencyCouldAnswerIsDisclosed() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        for chained in [false, true] {
            let rows = try scan(fx, chained: chained).rows
            for c in ["c12_shorthand_w", "c12_localcall_w"] {
                XCTAssertTrue(rows[c]?.why.contains("dispatch:<untyped>.touch") ?? false,
                              "chained=\(chained) \(c): Guess declares `touch`; the drop must disclose (was ABSENT over an executed write)")
            }
            XCTAssertTrue(rows["c12_kappaelem_w"]?.why.contains("dispatch:<untyped>.get") ?? false,
                          "chained=\(chained): an element of a κ-dependency factory, `get` reached through no identity")
            XCTAssertNil(rows["c12_localonly_p"], "chained=\(chained): a leaf only this package declares is the named residue")
            XCTAssertFalse(rows["c12_platform_p"]?.why.contains("dispatch:<untyped>.hasPrefix") ?? false,
                           "chained=\(chained): a leaf the platform declares with labels that bind the call is not hedged")
            XCTAssertEqual(try gate(fx, chained: chained, "deny Fs Unknown c12_localcall_w"), 1,
                           "chained=\(chained): the gate a user writes now fires over the executed write")
        }
        let off = try scan(fx, chained: true, env: ["CANDOR_C12_OFF": "1"]).rows
        XCTAssertFalse(off["c12_localcall_w"]?.why.contains("dispatch:<untyped>.touch") ?? false,
                       "`CANDOR_C12_OFF=1` restores the drop (the switch reaches the marker)")
    }
}
