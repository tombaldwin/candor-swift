import XCTest
import Foundation
@testable import CandorCore

/// STAGE S2c — RECEIVER TYPING. SOUNDNESS R1872 (unchained half), R1873, R1455 T4 (element of a factory literal).
///
/// Three spellings into a dependency formed no receiver identity, so no source was asked and the caller read ABSENT
/// unchained over a body that writes a file (executed in the swift attack matrix, `~/candor-handoff/swift-L0/matrix`):
///   - a generic parameter bounded by the dependency's class or protocol: `func f<C: HTTPClient>(_ c: C) { c.get(p) }`;
///   - a function or method reference: `let f = shellOut; f(…)`, `let g = r.get; g(p)`, `[p].map(r.tally)`;
///   - the element parameter over a literal of dependency-factory results: `[makeClient()].map { c in c.tally(p) }`.
/// Each now reads as its plain twin reads (`c: HTTPClient`, `shellOut(…)`, `r.get(p)`, `let c = makeClient()`).
///
/// One consumer text, one binary; the arms vary ONLY `CANDOR_DEPS` and the §1b switch. Every pure twin is uniquely named.
final class ReceiverTypingS2cProcessTests: XCTestCase {

    private static let ahc = """
    import Foundation
    open class HTTPClient {
        public init() {}
        public var label: String { "x" }
        open func get(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
        open func delete(_ p: String) -> Int { return p.count }
        open func patch(_ p: String) -> Int { return p.count }   // a pure κ verb no subclass overrides
        open func tally(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
        open func quiet(_ p: String) -> Int { return p.count }
    }
    public protocol Fetching { func fetchW(_ p: String) -> Int }
    public struct FetchImpl: Fetching {
        public init() {}
        public func fetchW(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
    }
    public func makeClient() -> HTTPClient { HTTPClient() }
    extension HTTPClient {
        public static func spawn(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
    }
    public final class LoudClient: HTTPClient {
        public override func delete(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return p.count }
    }
    public struct Box { public init() {}; public func map(_ s: String) -> Int { s.count } }
    """

    private static let shell = """
    import Foundation
    @discardableResult public func shellOut(_ c: String, _ p: String) -> String {
        let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/bin/touch"); pr.arguments = [p + ".x"]
        try? pr.run(); pr.waitUntilExit(); FileManager.default.createFile(atPath: p, contents: nil); return c
    }
    """

    /// The cells file. `twoImports` adds `import ShellOut` to it: a consumer file importing a κ-dependency module AND a
    /// blind third-party module (the ordinary file), on which the release hedges a generic-bound member call.
    private static func app(twoImports: Bool) -> String { """
    import Foundation
    import AsyncHTTPClient
    \(twoImports ? "import ShellOut" : "")
    open class LocalBase { public init() {}; open func get(_ p: String) -> Int { return p.count } }
    // R1872 — generic bounds
    public func genGet<C: HTTPClient>(_ c: C, _ p: String) -> Int { c.get(p) }
    public func genPatchPure<C: HTTPClient>(_ c: C, _ p: String) -> Int { c.patch(p) }
    public func genTally<C: HTTPClient>(_ c: C, _ p: String) -> Int { c.tally(p) }
    public func genProto<F: Fetching>(_ f: F, _ p: String) -> Int { f.fetchW(p) }
    public func genLocalBound<C: LocalBase>(_ c: C, _ p: String) -> Int { c.get(p) }
    // R1873 — references
    public func mrefGet(_ r: HTTPClient, _ p: String) -> Int { let g = r.get; return g(p) }
    public func mrefTally(_ r: HTTPClient, _ p: String) -> Int { let g = r.tally; return g(p) }
    public func argrefTally(_ r: HTTPClient, _ p: String) -> Int { [p].map(r.tally).first ?? 0 }
    public func argValueControl(_ r: HTTPClient, _ p: String) -> Bool { [p].contains(r.label) }
    public func genDeleteOverride<C: HTTPClient>(_ c: C, _ p: String) -> Int { c.delete(p) }   // run with LoudClient(): writes
    public func staticRef(_ p: String) -> Int { [p].map(HTTPClient.spawn).first ?? 0 }
    public func unappliedRefKappa(_ p: String) -> Int { let c = makeClient(); return [c].map(HTTPClient.get).count }
    public func unappliedRefQuiet(_ p: String) -> Int { let c = makeClient(); return [c].map(HTTPClient.quiet).count }
    public func depMapValue(_ r: HTTPClient) -> Int { Box().map(r.label) }
    // R1455 T4 — element of a factory literal
    public func closTally(_ p: String) -> Int { [makeClient()].map { c in c.tally(p) }.first ?? 0 }
    public func closGet(_ p: String) -> Int { [makeClient()].map { c in c.get(p) }.first ?? 0 }
    public func closShorthand(_ p: String) -> Int { [makeClient()].map { $0.tally(p) }.first ?? 0 }
    public func closIntControl(_ p: String) -> Int { [p.count].map { c in c.signum() }.first ?? 0 }
    """ }

    private static let shellCells = """
    import Foundation
    import ShellOut
    public func frefShell(_ p: String) -> String { let f = shellOut; return f("echo", p) }
    public func frefNeverCalled(_ p: String) -> Int { let f = shellOut; _ = f; return p.count }
    public func frefParamControl(_ shellOut: (String, String) -> String, _ p: String) -> Int { let f = shellOut; return f("e", p).count }
    """

    private struct Row { var inferred: Set<String>; var why: Set<String>; var invisible: Set<String> }

    private struct Fixture {
        let root: URL
        let bin: URL
        var depDir: URL { root.appendingPathComponent("deps") }
        var appDir: URL { root.appendingPathComponent("app") }
    }

    private func make(_ label: String, twoImports: Bool = false) throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-s2c-\(label)-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        for (pkg, src) in [("AsyncHTTPClient", Self.ahc), ("ShellOut", Self.shell)] {
            try write("\(pkg)/Package.swift", """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "\(pkg)", products: [.library(name: "\(pkg)", targets: ["\(pkg)"])],
                targets: [.target(name: "\(pkg)")])
            """)
            try write("\(pkg)/Sources/\(pkg)/lib.swift", src)
        }
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../AsyncHTTPClient"), .package(path: "../ShellOut")],
            targets: [.target(name: "App", dependencies: [.product(name: "AsyncHTTPClient", package: "AsyncHTTPClient"),
                                                          .product(name: "ShellOut", package: "ShellOut")])])
        """)
        try write("app/Sources/App/app.swift", Self.app(twoImports: twoImports))
        try write("app/Sources/App/shell.swift", Self.shellCells)
        let fx = Fixture(root: root, bin: bin)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        for pkg in ["AsyncHTTPClient", "ShellOut"] {
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent(pkg).path,
                                                 "--out", fx.depDir.appendingPathComponent("d\(pkg)").path])
            XCTAssertEqual(r.code, 0, "dependency scan must succeed — stderr: \(r.err)")
        }
        for f in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path)
        where !(f.hasSuffix(".Swift.json") && !f.contains(".callgraph.") && !f.contains(".hierarchy.")) {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(f))
        }
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

    private func gate(_ fx: Fixture, chained: Bool, _ deny: String, env extra: [String: String] = [:]) throws -> Int32 {
        var env = extra
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let pol = fx.root.appendingPathComponent("p-\(UUID().uuidString).policy")
        try "\(deny)\n".write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(fx.bin, [fx.appDir.path, "--policy", pol.path,
                                               "--out", fx.root.appendingPathComponent("g-\(UUID().uuidString)").path],
                                      env: env).code
    }

    // ── R1872 — the generic bound ──

    func testAGenericParameterBoundedByADependencyClassReadsAsItsBound() throws {
        let fx = try make("gen"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false, "nc")
        XCTAssertEqual(nc["genGet"]?.inferred, ["Net"], "κ's verb on the bound, as on `c: HTTPClient`. Was ABSENT")
        XCTAssertEqual(nc["genTally"]?.inferred, ["Unknown"], "a non-κ member of a κ root: R1866's typed hedge. Was ABSENT")
        XCTAssertEqual(nc["genTally"]?.why, ["dispatch:HTTPClient.tally"], "the bound names the member, not `C`")
        XCTAssertEqual(nc["genProto"]?.why, ["dispatch:Fetching.fetchW"], "a protocol bound reads as `any Fetching`. Was ABSENT")
        XCTAssertEqual(try gate(fx, chained: false, "deny Fs Unknown genTally"), 1, "GATE — was exit 0 over a write")
        // CONTROL — a bound this package DECLARES is local resolution's: its pure body, never κ's `Net`.
        XCTAssertNil(nc["genLocalBound"], "a declared bound shadows κ (the GRDB `bind` lesson)")
        let ch = try scan(fx, chained: true, "ch")
        XCTAssertEqual(ch["genGet"]?.inferred, ["Fs", "Net"], "chained: κ ∪ the row (R1865's union), as on `c: HTTPClient`")
        XCTAssertEqual(ch["genTally"]?.inferred, ["Fs"], "chained: the row")
        XCTAssertEqual(ch["genPatchPure"]?.inferred, ["Net", "Unknown"], "TWIN: κ's permitted over-charge on a pure verb BESIDE the release's walk-miss hedge (a union: nothing removed), never Fs")
        XCTAssertEqual(nc["genDeleteOverride"]?.inferred, ["Net"], "one import: κ's floor, as `c: HTTPClient` (was ABSENT)")
    }

    /// FABLE L5 MERGE REVIEW D1 — THE TWO-IMPORT LAYOUT. On a cells file importing the κ-dependency module AND a blind
    /// third-party module, the release hedged the generic-bound member call (`Unknown {dispatch:HTTPClient.<m>}`), which
    /// is what discloses an override that writes. κ's verb is a UNION beside that hedge, never a replacement: the first
    /// cut replaced it and `deny Fs Unknown` went 1→0 over an executed override write.
    func testOnATwoImportFileTheGenericBoundKeepsTheReleaseHedgeBesideKappa() throws {
        let fx = try make("gen2", twoImports: true); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false, "nc")
        for fn in ["genGet", "genDeleteOverride"] {
            XCTAssertEqual(nc[fn]?.inferred.isSuperset(of: ["Net", "Unknown"]), true, "\(fn): κ AND the release's hedge — \(String(describing: nc[fn]))")
        }
        XCTAssertEqual(try gate(fx, chained: false, "deny Fs Unknown genDeleteOverride"), 1,
                       "GATE — an override that writes stays disclosed (the first cut read exit 0)")
        let ch = try scan(fx, chained: true, "ch")
        XCTAssertEqual(ch["genDeleteOverride"]?.inferred.contains("Fs"), true, "chained: the dependency's override row joins")
    }

    // ── R1873 — a TYPE-base reference handed to a higher-order function (FABLE L5 MERGE REVIEW D2/D3) ──

    func testATypeBaseReferenceIsACallOnlyWhenTheMemberIsStatic() throws {
        let fx = try make("tbase"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false, "nc")
        XCTAssertEqual(nc["staticRef"]?.why, ["dispatch:HTTPClient.spawn"],
                       "`[p].map(HTTPClient.spawn)` runs the static `spawn` per element: disclosed (was ABSENT)")
        XCTAssertEqual(try gate(fx, chained: false, "deny Fs Unknown staticRef"), 1, "GATE — over an executed write")
        // TWINS — an unapplied INSTANCE method yields closures and invokes nothing.
        XCTAssertNil(nc["unappliedRefKappa"], "`[c].map(HTTPClient.get)` performs nothing: no κ `Net`")
        XCTAssertNil(nc["unappliedRefQuiet"], "`[c].map(HTTPClient.quiet)` performs nothing: no hedge")
        // D3 — a dependency's own `map(_ s: String)` takes a VALUE: no member call is formed on the argument.
        XCTAssertFalse(nc["depMapValue"]?.why.contains("dispatch:HTTPClient.label") ?? false,
                       "`Box().map(r.label)`: `r.label` is a value, not a reference anything invokes")
    }

    // ── R1873 — references ──

    func testAMethodReferenceIsAnsweredAsTheMemberCall() throws {
        let fx = try make("mref"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false, "nc")
        XCTAssertEqual(nc["mrefGet"]?.inferred, ["Net"], "`let g = r.get; g(p)` reads as `r.get(p)`. Was ABSENT")
        XCTAssertEqual(nc["mrefTally"]?.why, ["dispatch:HTTPClient.tally"], "a non-κ member: the typed hedge. Was ABSENT")
        XCTAssertEqual(nc["argrefTally"]?.why, ["dispatch:HTTPClient.tally"], "`[p].map(r.tally)`. Was ABSENT")
        XCTAssertEqual(try gate(fx, chained: false, "deny Fs Unknown argrefTally"), 1, "GATE — was exit 0 over a write")
        // CONTROL — a property VALUE handed to `contains(_:)` is not a reference anything invokes.
        XCTAssertNil(nc["argValueControl"], "`[p].contains(r.label)`: a value position, no member call is formed")
        let ch = try scan(fx, chained: true, "ch")
        XCTAssertEqual(ch["mrefGet"]?.inferred, ["Fs", "Net"], "chained: κ ∪ the row")
        XCTAssertEqual(ch["mrefTally"]?.inferred, ["Fs"], "chained: the row")
        let off = try scan(fx, chained: false, env: ["CANDOR_R1873_OFF": "1"], "off")
        XCTAssertNil(off["mrefGet"], "§1b — the silence, reproduced")
    }

    func testAFreeFunctionReferenceIsAnsweredAsTheCall() throws {
        let fx = try make("fref"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false, "nc")
        XCTAssertEqual(nc["frefShell"]?.inferred.contains("Exec"), true, "`let f = shellOut; f(…)` reads as `shellOut(…)`. Was ABSENT")
        XCTAssertEqual(try gate(fx, chained: false, "deny Exec frefShell"), 1, "GATE — was exit 0 over a process run")
        // CONTROLS — the reference is answered where it is INVOKED, and a PARAMETER of the same name is a value.
        XCTAssertNotEqual(nc["frefNeverCalled"]?.inferred.contains("Exec"), true, "never invoked: nothing charged unchained")
        XCTAssertNotEqual(nc["frefParamControl"]?.inferred.contains("Exec"), true,
                          "`shellOut` here is the PARAMETER, not ShellOut's function")
        let ch = try scan(fx, chained: true, "ch")
        XCTAssertEqual(ch["frefShell"]?.inferred.isSuperset(of: ["Exec", "Fs"]), true, "chained: κ ∪ the row")
    }

    // ── R1455 T4 — the element of a factory literal ──

    func testTheElementParameterOfAFactoryLiteralCarriesTheFactorysProvenance() throws {
        let fx = try make("clos"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false, "nc")
        for fn in ["closTally", "closGet", "closShorthand"] {
            XCTAssertEqual(nc[fn]?.why, ["dispatch:untyped cross-package receiver"],
                           "\(fn): as `let c = makeClient(); c.m(p)` reads unchained. Was ABSENT")
        }
        XCTAssertNil(nc["closIntControl"], "CONTROL — an element that is no factory result gains nothing")
        let ch = try scan(fx, chained: true, "ch")
        XCTAssertEqual(ch["closTally"]?.inferred.contains("Fs"), true, "chained: `typeSurface.returns` types the element")
        XCTAssertEqual(ch["closGet"]?.inferred.contains("Fs"), true, "chained")
        XCTAssertEqual(try gate(fx, chained: true, "deny Fs closTally"), 1, "GATE — was exit 0 over a write")
        let off = try scan(fx, chained: true, env: ["CANDOR_R1455T4E_OFF": "1"], "off")
        XCTAssertNil(off["closTally"], "§1b — the drop, reproduced")
    }
}
