import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1865 and R1866 — a call into `AsyncHTTPClient`, a dependency package the curated classifier also knows
/// (`HTTPClient.get/post/put/…` → `Net`, and the module is in `KAPPA_MODULES`).
///
/// **R1865 (SPEC §2 ⟨0.43⟩, conformance PART 110).** The classifier's typed-member branch charged `Net` and emitted no
/// call, so a chained report's row for the SAME member was never read: `r.get(p)` on `r: HTTPClient`, whose body writes a
/// file, read `['Env', 'Net']` chained — `deny Fs` and `deny Fs Unknown` exit 0 over an executed write — while the
/// untyped spelling of the same call, which the join does reach, read `Fs`. The fix asks the §2 key beside the charge and
/// unions what it answers. `CANDOR_R1865_OFF=1` restores curated-wins.
///
/// **R1866.** Unchained, a receiver this engine cannot type (`let r = makeClient(); r.get(p)`) into that κ module read
/// `['Env']`, `unresolved: false`, no `invisible` — the κ ledger treats the module as covered, the classifier cannot key an
/// untyped receiver, and no report is chained. It now discloses with the chained arm's own token. `CANDOR_R1866_OFF=1`
/// restores the silence.
///
/// One dependency, one consumer text, one binary; the arms vary ONLY `CANDOR_DEPS` (and the §1b switch). The dependency's
/// members: `get` writes the file it is given (executed in PART 110's evidence), `put` is pure under a curated verb,
/// `tally` is pure under no curated verb — the two pure twins, uniquely named, that must never gain `Fs`.
final class ChainedCuratedUnionProcessTests: XCTestCase {

    private static let dep = """
    import Foundation
    public struct HTTPClient {
        public init() {}
        public func get(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
        public func put(_ p: String) -> Int { return p.count }
        public func tally(_ p: String) -> Int { return p.count }
    }
    public func makeClient() -> HTTPClient { HTTPClient() }
    """

    private static let app = """
    import Foundation
    import AsyncHTTPClient
    public func typedGet(_ r: HTTPClient, _ p: String) -> Int { return r.get(p) }
    public func typedPut(_ r: HTTPClient, _ p: String) -> Int { return r.put(p) }
    public func typedTally(_ r: HTTPClient, _ p: String) -> Int { return r.tally(p) }
    public func untypedGet(_ p: String) -> Int { let r = makeClient(); return r.get(p) }
    public func returnedGet(_ p: String) -> Int { return makeClient().get(p) }
    public func plainLocal(_ p: String) -> Int { let n = p.count; return n + 1 }
    """

    private struct Row { var inferred: Set<String>; var why: Set<String> }

    private struct Fixture {
        let root: URL
        let bin: URL
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") }
    }

    private func make(_ label: String, dep: String = ChainedCuratedUnionProcessTests.dep,
                      app: String = ChainedCuratedUnionProcessTests.app) throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r1865-\(label)-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("AsyncHTTPClient/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "AsyncHTTPClient",
            products: [.library(name: "AsyncHTTPClient", targets: ["AsyncHTTPClient"])],
            targets: [.target(name: "AsyncHTTPClient")])
        """)
        try write("AsyncHTTPClient/Sources/AsyncHTTPClient/lib.swift", dep)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../AsyncHTTPClient")],
            targets: [.target(name: "App", dependencies: [.product(name: "AsyncHTTPClient", package: "AsyncHTTPClient")])])
        """)
        try write("app/Sources/App/app.swift", app)
        let fx = Fixture(root: root, bin: bin)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("AsyncHTTPClient").path,
                                              "--out", fx.depDir.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        for extra in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path)
        where extra != "r.AsyncHTTPClient.Swift.json" {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(extra))
        }
        return fx
    }

    private func scan(_ fx: Fixture, chained: Bool, env extra: [String: String] = [:], _ tag: String) throws -> [String: Row] {
        var env = extra
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let out = fx.root.appendingPathComponent(tag)
        let r = try ProcessHarness.run(fx.bin, [fx.appDir.path, "--out", out.path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fx.root.appendingPathComponent("\(tag).App.Swift.json"))) as? [String: Any]
        var rows: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = Row(inferred: Set((f["inferred"] as? [String]) ?? []),
                                                    why: Set((f["unknownWhy"] as? [String]) ?? []))
        }
        return rows
    }

    private func gate(_ fx: Fixture, chained: Bool, _ deny: String, env extra: [String: String] = [:]) throws -> Int32 {
        var env = extra
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let pol = fx.root.appendingPathComponent("p-\(UUID().uuidString).policy")
        try "\(deny)\n".write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(fx.bin, [fx.appDir.path, "--policy", pol.path,
                                               "--out", fx.root.appendingPathComponent("g-\(UUID().uuidString)").path],
                                      env: env).code
    }

    // ── R1865 ──

    func testAChainedRowAndTheCuratedEntryAreUnionedOnATypedCall() throws {
        let fx = try make("union"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let ch = try scan(fx, chained: true, "ch")
        XCTAssertEqual(ch["untypedGet"]?.inferred.contains("Fs"), true,
                       "PREMISE (the join is live): the untyped spelling reaches the chained row's Fs")
        XCTAssertEqual(ch["typedGet"]?.inferred, ["Fs", "Net"],
                       "the curated Net AND the chained row's Fs. Before R1865 this read ['Net']: the classifier "
                       + "answered and the row for the same member was never read")
        XCTAssertEqual(try gate(fx, chained: true, "deny Fs typedGet"), 1,
                       "GATE LEVEL — `deny Fs` over a member that writes a file. Was exit 0")
        // FABRICATION CONTROLS — the pure twins publish no row, so the union adds nothing to them.
        XCTAssertEqual(ch["typedPut"]?.inferred, ["Net"], "a pure curated member: the classifier's charge, no Fs")
        XCTAssertNil(ch["typedTally"], "a pure member under no curated verb: still absent (pure)")
        // UNCHAINED: nothing to join; the classifier's answer is the whole answer, as before.
        let nc = try scan(fx, chained: false, "nc")
        XCTAssertEqual(nc["typedGet"]?.inferred, ["Net"], "unchained, the marker joins nothing and adds nothing")
    }

    func testTheKillSwitchRestoresCuratedWins() throws {
        let fx = try make("off"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let off = try scan(fx, chained: true, env: ["CANDOR_R1865_OFF": "1"], "off")
        XCTAssertEqual(off["typedGet"]?.inferred, ["Net"], "§1b — the defect row, reproduced with the fix switched off")
        XCTAssertEqual(try gate(fx, chained: true, "deny Fs typedGet", env: ["CANDOR_R1865_OFF": "1"]), 0,
                       "§1b — the false all-clear the fix closes")
    }

    // ── R1866 ──

    func testAnUntypedReceiverIntoAnUnchainedKappaModuleDiscloses() throws {
        let fx = try make("nc"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false, "nc")
        for fn in ["untypedGet", "returnedGet"] {
            XCTAssertEqual(nc[fn]?.inferred, ["Unknown"], "\(fn): was ABSENT (`[]` — a purity claim over a file write)")
            XCTAssertEqual(nc[fn]?.why, ["dispatch:untyped cross-package receiver"],
                           "\(fn): the chained arm's own token, so the two arms say one thing")
        }
        XCTAssertEqual(try gate(fx, chained: false, "deny Fs Unknown untypedGet"), 1,
                       "GATE LEVEL — `deny Fs Unknown` over an executed write. Was exit 0")
        XCTAssertNil(nc["plainLocal"], "BOUND — a function with no dependency receiver gains nothing")
        XCTAssertEqual(nc["typedGet"]?.inferred, ["Net"], "BOUND — a TYPED call is answered by the classifier, not hedged")
        let off = try scan(fx, chained: false, env: ["CANDOR_R1866_OFF": "1"], "off")
        XCTAssertNil(off["untypedGet"], "§1b — the silence, reproduced with the fix switched off")
    }

    // ── R1865, the spellings PART 110 does not measure (Fable R1865 merge review) ──
    //
    // The κ verb reached three more ways, each with a non-κ TWIN that the ordinary member join already answered. Before
    // the rework each κ spelling read ['Net'] chained over an executed write (`deny Fs` and `deny Fs Unknown` exit 0)
    // while its twin read ['Env', 'Fs']: (a) a verb INHERITED from a dependency base class and (b) a PROTOCOL-EXTENSION
    // default — the marker asked only the owner's own key, the ordinary join walks on a miss; (c) implicit self inside the
    // consumer's `extension HTTPClient` — a second κ arm that charged and emitted no call. Plus (d) a conditional typealias
    // whose arms are the κ type and a local declaration: the alias arm charged κ the same way.

    private static let depShapes = """
    import Foundation
    open class HTTPClientBase {
        public init() {}
        public func get(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
        public func tallyA(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
    }
    public protocol Fetching {}
    extension Fetching {
        public func post(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
        public func tallyB(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
    }
    public final class HTTPClient: HTTPClientBase, Fetching {
        public override init() { super.init() }
        public func put(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
        public func delete(_ p: String) -> Int { return p.count }
    }
    """

    private static let appShapes = """
    import Foundation
    import AsyncHTTPClient
    public func inhGet(_ r: HTTPClient, _ p: String) -> Int { return r.get(p) }
    public func inhTwin(_ r: HTTPClient, _ p: String) -> Int { return r.tallyA(p) }
    public func protoPost(_ r: HTTPClient, _ p: String) -> Int { return r.post(p) }
    public func protoTwin(_ r: HTTPClient, _ p: String) -> Int { return r.tallyB(p) }
    public func pureDelete(_ r: HTTPClient, _ p: String) -> Int { return r.delete(p) }
    extension HTTPClient {
        public func extImplicit(_ p: String) -> Int { return put(p) }
        public func extImplicitInh(_ p: String) -> Int { return get(p) }
    }
    public struct LocalClient { public init() {}; public func get(_ p: String) -> Int { return p.count } }
    #if os(macOS)
    public typealias Either = HTTPClient
    #else
    public typealias Either = LocalClient
    #endif
    public func aliasGet(_ r: Either, _ p: String) -> Int { return r.get(p) }
    """

    func testTheMarkerReachesInheritedProtocolDefaultImplicitSelfAndAliasSpellings() throws {
        let fx = try make("shapes", dep: Self.depShapes, app: Self.appShapes)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let ch = try scan(fx, chained: true, "ch")
        XCTAssertEqual(ch["inhTwin"]?.inferred, ["Fs"], "PREMISE: the ordinary join walks to the inherited body")
        XCTAssertEqual(ch["protoTwin"]?.inferred, ["Fs"], "PREMISE: …and to the protocol-extension default")
        for fn in ["inhGet", "protoPost", "HTTPClient.extImplicit", "HTTPClient.extImplicitInh"] {
            XCTAssertEqual(ch[fn]?.inferred, ["Fs", "Net"],
                           "\(fn): the curated Net AND the body that runs. Before the rework this read ['Net']")
        }
        XCTAssertEqual(ch["aliasGet"]?.inferred.contains("Fs"), true,
                       "the conditional-typealias κ arm joins the chained row too")
        XCTAssertEqual(ch["pureDelete"]?.inferred, ["Net"],
                       "a κ verb whose body is pure: the walk reaches no body, and a miss adds NOTHING (no Unknown)")
        for fn in ["inhGet", "protoPost", "HTTPClient.extImplicit"] {
            XCTAssertEqual(try gate(fx, chained: true, "deny Fs \(fn)"), 1, "GATE LEVEL — \(fn). Was exit 0")
        }
        let off = try scan(fx, chained: true, env: ["CANDOR_R1865_OFF": "1"], "off")
        XCTAssertEqual(off["inhGet"]?.inferred, ["Net"], "§1b — the defect, with the fix switched off")
        XCTAssertEqual(off["HTTPClient.extImplicit"]?.inferred, ["Net"], "§1b — the implicit-self arm")
    }

    // ── R1866: the list the disclosure keys on must not drift from the one that silences ──

    /// The silence exists because `blindModules()` treats every `KAPPA_MODULES` member as covered. A module added there and
    /// not to `KAPPA_DEPENDENCY_MODULES` re-opens R1866 for it; this pins the partition: every κ module is either a
    /// dependency module (disclosed) or one of the named OS frameworks, which have no dependency factory to untype a
    /// receiver. Adding a κ module forces a decision here.
    func testKappaDependencyModulesPartitionKappaModules() {
        let osFrameworks: Set<String> = ["Network", "SQLite3", "CoreData"]
        XCTAssertTrue(KAPPA_DEPENDENCY_MODULES.isSubset(of: KAPPA_MODULES),
                      "a disclosure keyed on a module κ does not cover discloses nothing new — and misleads the reader")
        XCTAssertEqual(KAPPA_MODULES.subtracting(KAPPA_DEPENDENCY_MODULES), osFrameworks,
                       "R1866 DRIFT: a κ module that is neither a dependency module nor a named OS framework is "
                       + "treated as covered by `blindModules()` and NOT disclosed by R1866 — an untyped receiver into "
                       + "it reads pure. Add it to KAPPA_DEPENDENCY_MODULES, or name it here as an OS framework")
        XCTAssertTrue(KAPPA_DEPENDENCY_MODULES.isDisjoint(with: PLATFORM_MODULES))
    }
}
