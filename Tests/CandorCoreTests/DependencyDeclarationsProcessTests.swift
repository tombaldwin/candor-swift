import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1868 (a)(b)(c)(e), R1877, R1878 — **WHAT THE DEPENDENCY DECLARES, as far as the consumer can see.**
///
/// The dependency's declaration record kept top-level names only, so a call whose receiver or callee was a type NESTED in a
/// κ dependency type, a member the dependency adds by EXTENSION to a platform type, a dependency `typealias`, a re-exported
/// module's name, or (sources unreadable) any non-root type of a κ dependency module, resolved to nothing and nothing said so.
///
/// Every fixture has a PURE twin with its own name and a CONTROL that must not move (a consumer type of the alias's name
/// shadows it). The effect is EXECUTED by the Runner in `fx2` of the lane report; these tests pin the report's reading.
final class DependencyDeclarationsProcessTests: XCTestCase {

    private static let ahc = """
    import Foundation
    func hcWrite(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
    open class HTTPClient {
        public init() {}
        open func get(_ p: String) -> Int { hcWrite(p); return 1 }
        open func delete(_ p: String) -> Int { p.count }
        open func tally(_ p: String) -> Int { hcWrite(p); return 1 }
        open func quiet(_ p: String) -> Int { p.count }
        public struct Inner { public init() {}
            public func go(_ p: String) -> Int { hcWrite(p); return 1 }
            public func calm(_ p: String) -> Int { p.count } }
    }
    public typealias Client = HTTPClient
    public typealias Shadowed = HTTPClient
    public struct HTTPClientRequest { public init() {}
        public func send(_ p: String) -> Int { hcWrite(p); return 1 }
        public func idle(_ p: String) -> Int { p.count } }
    public func makeClient() -> HTTPClient { HTTPClient() }
    extension String {
        public func slurp(_ p: String) -> Int { hcWrite(p); return 1 }
        public func sip(_ p: String) -> Int { p.count }
    }
    """

    private static let app = """
    import Foundation
    import AsyncHTTPClient
    public struct Shadowed { public init() {}; public func get(_ p: String) -> Int { p.count } }
    public func aliasTally(_ p: String) -> Int { let r: Client = makeClient(); return r.tally(p) }
    public func aliasQuiet(_ p: String) -> Int { let r: Client = makeClient(); return r.quiet(p) }
    public func aliasGet(_ p: String) -> Int { let r: Client = makeClient(); return r.get(p) }
    public func nestParamGo(_ i: HTTPClient.Inner, _ p: String) -> Int { i.go(p) }
    public func nestParamCalm(_ i: HTTPClient.Inner, _ p: String) -> Int { i.calm(p) }
    public func reqSend(_ p: String) -> Int { let q: HTTPClientRequest = makeRequest(); return q.send(p) }
    public func reqIdle(_ p: String) -> Int { let q: HTTPClientRequest = makeRequest(); return q.idle(p) }
    public func strSlurp(_ p: String) -> Int { p.slurp(p) }
    public func strSip(_ p: String) -> Int { p.sip(p) }
    public func shadowControl(_ p: String) -> Int { Shadowed().get(p) }
    func makeRequest() -> HTTPClientRequest { HTTPClientRequest() }
    """

    private typealias Rows = [String: (inf: Set<String>, why: Set<String>)]

    /// `layout`: nc (readable, unchained), ch (readable, chained), nr (url dependency, no checkout).
    private func scan(layout: String) throws -> Rows {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1868-\(layout)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "AsyncHTTPClient",
            products: [.library(name: "AsyncHTTPClient", targets: ["AsyncHTTPClient"])],
            targets: [.target(name: "AsyncHTTPClient")])
        """)
        try write("dep/Sources/AsyncHTTPClient/lib.swift", Self.ahc)
        let depSpec = layout == "nr"
            ? ".package(url: \"https://github.com/swift-server/async-http-client.git\", from: \"1.0.0\")"
            : ".package(path: \"../dep\")"
        let prodPkg = layout == "nr" ? "async-http-client" : "dep"
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [\(depSpec)],
            targets: [.target(name: "App", dependencies: [.product(name: "AsyncHTTPClient", package: "\(prodPkg)")])])
        """)
        try write("app/Sources/App/cells.swift", Self.app)
        var env: [String: String] = [:]
        if layout == "ch" {
            let depDir = root.appendingPathComponent("depR")
            try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
            let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path, "--out", depDir.appendingPathComponent("r").path])
            XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
            let report = depDir.appendingPathComponent("r.AsyncHTTPClient.Swift.json")
            for extra in try FileManager.default.contentsOfDirectory(atPath: depDir.path) where extra != report.lastPathComponent {
                try FileManager.default.removeItem(at: depDir.appendingPathComponent(extra))
            }
            env["CANDOR_DEPS"] = depDir.path
        }
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", root.appendingPathComponent("o").path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("o.App.Swift.json"))) as? [String: Any]
        var rows: Rows = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = (Set((f["inferred"] as? [String]) ?? []), Set((f["unknownWhy"] as? [String]) ?? []))
        }
        return rows
    }

    func testReadableUnchained() throws {
        let r = try scan(layout: "nc")
        // (e) the dependency alias resolves: the κ verb is charged, the non-κ member hedges under the TARGET's name.
        XCTAssertEqual(r["aliasGet"]?.inf, ["Net"], "alias of a κ root: κ's verb charge, not the alias-named hedge")
        XCTAssertTrue(r["aliasTally"]?.inf.contains("Unknown") ?? false)
        XCTAssertEqual(r["aliasTally"]?.why, ["dispatch:HTTPClient.tally"])
        // (a) a nested type of a dependency type is hedged under its full path.
        XCTAssertEqual(r["nestParamGo"]?.why, ["dispatch:HTTPClient.Inner.go"])
        // (b) an extension member of a platform type the dependency declares.
        XCTAssertEqual(r["strSlurp"]?.why, ["dispatch:String.slurp"])
        // twins: only disclosure, never a concrete effect the body does not perform.
        for t in ["aliasQuiet", "nestParamCalm", "strSip", "reqIdle"] {
            XCTAssertFalse(r[t]?.inf.contains("Fs") ?? false, "pure twin \(t) must not read Fs")
        }
        // CONTROL: a type of the alias's own name that the CONSUMER declares shadows it — no κ `Net` fabricated.
        XCTAssertNil(r["shadowControl"], "a consumer type shadows the dependency alias: the call is the consumer's pure `get`")
    }

    func testReadableChainedReadsTheRow() throws {
        let r = try scan(layout: "ch")
        XCTAssertEqual(r["aliasTally"]?.inf, ["Fs"], "the alias resolves to HTTPClient, so the chained row joins")
        XCTAssertEqual(r["aliasGet"]?.inf, ["Fs", "Net"], "κ verb through the alias is unioned with the row (R1865's rule)")
        XCTAssertNil(r["aliasQuiet"], "pure twin: nothing to add")
        XCTAssertNil(r["shadowControl"])
    }

    func testUnreadableSourcesDiscloseNonRootTypes() throws {
        let r = try scan(layout: "nr")
        XCTAssertEqual(r["aliasTally"]?.why, ["dispatch:Client.tally"], "an alias whose sources are unread: the type is unknown, so disclose")
        XCTAssertEqual(r["nestParamGo"]?.why, ["dispatch:HTTPClient.Inner.go"], "a nested type of a κ root is known without sources")
        XCTAssertEqual(r["reqSend"]?.why, ["dispatch:HTTPClientRequest.send"], "a non-root type of an unread κ dependency module")
        XCTAssertNil(r["shadowControl"], "the consumer's own `Shadowed` is not a dependency type, readable or not")
    }
}

final class DependencyAliasWalkerTests: XCTestCase {
    func testWalkerRecordsVisibleSimpleAliasesAndRefusesTheRest() {
        let r = topLevelTypeAliases(source: """
        public typealias Client = HTTPClient
        typealias Hidden = HTTPClient
        private typealias Priv = HTTPClient
        public typealias Q = Files.File
        public typealias Gen<T> = Array<T>
        public typealias Fn = (Int) -> Void
        #if os(macOS)
        public typealias Arm = A
        #else
        public typealias Arm = B
        #endif
        """)
        XCTAssertEqual(r.aliases["Client"]?.target, "HTTPClient"); XCTAssertEqual(r.aliases["Client"]?.visible, true)
        XCTAssertEqual(r.aliases["Hidden"]?.visible, false)
        XCTAssertNil(r.aliases["Priv"])
        XCTAssertEqual(r.aliases["Q"]?.target, "Files.File")
        XCTAssertTrue(r.conflicting.contains("Gen"), "a generic alias is not resolved")
        XCTAssertTrue(r.conflicting.contains("Fn"), "a function-typed alias names no type")
        XCTAssertTrue(r.conflicting.contains("Arm"), "an alias under #if with two targets is not resolved")
    }
}

/// SOUNDNESS R1877 / R1878 — a re-exported module and an alias target's module are asked by the §2 join; a re-exporting
/// wrapper's own pure overload is NOT charged with the re-exported function's effects (the arity-blind wire key).
final class ReexportAndFacadeJoinProcessTests: XCTestCase {
    private func pkg(_ name: String, deps: [String], src: String) -> [(String, String)] {
        let dl = deps.map { ".package(path: \"../\($0)\")" }.joined(separator: ", ")
        let pl = deps.map { ".product(name: \"\($0)\", package: \"\($0)\")" }.joined(separator: ", ")
        return [("\(name)/Package.swift", """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
                dependencies: [\(dl)], targets: [.target(name: "\(name)", dependencies: [\(pl)])])
            """), ("\(name)/Sources/\(name)/lib.swift", src)]
    }

    func testReexportedAndAliasedPackagesAreJoined() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1877-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [(String, String)] = []
        files += pkg("Core", deps: [], src: """
            import Foundation
            func w(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
            public func loudCore(to c: String, at p: String) -> String { w(p); return c }
            public struct Gadget { public init() {}
                public func spin(_ p: String) -> Int { w(p); return 1 }
                public func calm(_ p: String) -> Int { p.count } }
            """)
        files += pkg("Wrap", deps: ["Core"], src: """
            @_exported import Core
            public func loudCore(cmd: String) -> String { cmd }
            """)
        files += pkg("Facade", deps: ["Core"], src: "import Core\npublic typealias Gadget = Core.Gadget\n")
        let app = """
        import Wrap
        public func reLoud(_ p: String) -> String { loudCore(to: "x", at: p) }
        public func wrapOwn(_ p: String) -> String { loudCore(cmd: p) }
        """
        let app2 = """
        import Facade
        public func viaAliasSpin(_ g: Gadget, _ p: String) -> Int { g.spin(p) }
        public func viaAliasCalm(_ g: Gadget, _ p: String) -> Int { g.calm(p) }
        """
        for (rel, text) in files {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        func consumer(_ name: String, dep: String, text: String) throws {
            for (rel, t) in pkg(name, deps: [dep], src: text) {
                let u = root.appendingPathComponent(rel); try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try t.write(to: u, atomically: true, encoding: .utf8)
            }
        }
        try consumer("App", dep: "Wrap", text: app)
        try consumer("App2", dep: "Facade", text: app2)
        let reports = root.appendingPathComponent("reports"); try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        for m in ["Core", "Wrap", "Facade"] {
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent(m).path, "--out", reports.appendingPathComponent("r").path])
            XCTAssertEqual(r.code, 0, r.err)
        }
        func rows(_ name: String) throws -> [String: Set<String>] {
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent(name).path, "--out", root.appendingPathComponent("o\(name)").path],
                                           env: ["CANDOR_DEPS": reports.path])
            XCTAssertEqual(r.code, 0, r.err)
            let d = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("o\(name).\(name).Swift.json"))) as? [String: Any]
            var out: [String: Set<String>] = [:]
            for f in (d?["functions"] as? [[String: Any]]) ?? [] { out[(f["fn"] as? String) ?? "?"] = Set((f["inferred"] as? [String]) ?? []) }
            return out
        }
        let a = try rows("App"), b = try rows("App2")
        XCTAssertEqual(a["reLoud"], ["Fs"], "the re-exported Core's row is read through the wrapper's import")
        XCTAssertFalse(a["wrapOwn"]?.contains("Fs") ?? false, "the wrapper's own pure overload is not charged with Core's write")
        XCTAssertEqual(b["viaAliasSpin"], ["Fs"], "the alias target's package is asked")
        XCTAssertFalse(b["viaAliasCalm"]?.contains("Fs") ?? false, "pure twin")
    }
}
