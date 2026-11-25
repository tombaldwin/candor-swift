import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1868(iii), R1879, and the Q1 floor of SPEC §2 ⟨0.43⟩ (curated-routing stage S3a): a κ answer for a
/// THIRD-PARTY entity is a FLOOR ("a curated entry claims the call performs E, not that it performs nothing else"), so a
/// unit on which κ answered a third-party entity, with no chained report covering the module, names the module in
/// `invisible`. Three shapes were silent unchained over an executed write:
///
///     typed floor    `r.get(p)` on an `HTTPClient`, the body also writes a file     ['Net']    (Fs silent, no ledger entry)
///     F5             `hcFree(p)` / `AsyncHTTPClient.hcFree(p)`, a free function     absent     (the ledger skips κ modules)
///     R1879          `connect(3, at: p, 0)` binding an unchained readable dep's     ['Net']    (κ platform name answered,
///                    own `connect`, whose body writes a file                                    the dependency never named)
///
/// ADDITIVE: it adds `invisible` and removes nothing, so every assertion about the pre-existing `inferred` is unchanged
/// and the GATE assertions pin that `invisible` arms no policy form (R133). Platform entries (`authority: complete`)
/// never gain it, and a chained report that covers the module is the answer, so chained scans are unchanged.
/// Bodies are the L0 matrix's, executed there.
final class KappaFloorInvisibleProcessTests: XCTestCase {

    private static let deps: [String: String] = [
        "AsyncHTTPClient": """
        import Foundation
        func hcWrite(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
        open class HTTPClient {
            public init() {}
            open func get(_ p: String) -> Int { hcWrite(p); return 1 }
            open func delete(_ p: String) -> Int { return p.count }
        }
        public func hcFree(_ p: String) -> Int { hcWrite(p); return 1 }
        public func hcFreeQuiet(_ p: String) -> Int { return p.count }
        """,
        "ShellOut": """
        import Foundation
        @discardableResult
        public func shellOut(to command: String, at p: String) -> String {
            let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/bin/touch"); pr.arguments = [p + ".x"]
            try? pr.run(); pr.waitUntilExit(); FileManager.default.createFile(atPath: p, contents: nil); return command
        }
        """,
        "Files": """
        import Foundation
        public final class File {
            public let path: String
            public init(path p: String) throws {
                let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/bin/touch"); pr.arguments = [p + ".i"]
                try? pr.run(); pr.waitUntilExit(); self.path = p
            }
        }
        """,
        // R1879: a free `connect` whose labels bind `connect(3, at: p, 0)`; the body writes a file and opens no socket.
        "ConnC": """
        import Foundation
        @discardableResult
        public func connect(_ fd: Int32, at tag: String, _ len: Int32) -> Int32 { FileManager.default.createFile(atPath: tag, contents: nil); return 0 }
        """,
        // the control: its `connect(host:)` cannot bind POSIX `connect(fd, sa, len)`.
        "ConnF": """
        import Foundation
        public func connect(host p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 }
        """,
    ]

    private static let apps: [String: String] = [
        "AsyncHTTPClient": """
        import Foundation
        import AsyncHTTPClient
        public func a_param_kv_w(_ r: HTTPClient, _ p: String) -> Int { r.get(p) }
        public func a_param_kv_p(_ r: HTTPClient, _ p: String) -> Int { r.delete(p) }
        public func a_generic_kv_w<C: HTTPClient>(_ c: C, _ p: String) -> Int { c.get(p) }
        public func a_mref_kv_w(_ r: HTTPClient, _ p: String) -> Int { let g = r.get; return g(p) }
        public func a_free_w(_ p: String) -> Int { hcFree(p) }
        public func a_modq_w(_ p: String) -> Int { AsyncHTTPClient.hcFree(p) }
        public func plat_w(_ p: String) -> Bool { FileManager.default.createFile(atPath: p, contents: nil) }
        """,
        "ShellOut": """
        import ShellOut
        public func s_free_kx(_ p: String) -> String { shellOut(to: "echo", at: p) }
        public func s_modq_kx(_ p: String) -> String { ShellOut.shellOut(to: "echo", at: p) }
        """,
        "Files": """
        import Files
        public func f_ctor(_ p: String) throws -> String { try File(path: p).path }
        """,
        "ConnC": """
        import ConnC
        public func b_connc_w(_ p: String) -> Int32 { connect(3, at: p, 0) }
        """,
        "ConnF": """
        import Darwin
        import ConnF
        public func posixF(_ fd: Int32, _ sa: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, sa, len) }
        """,
        // the consumer DECLARES the type: the project's own `HTTPClient` shadows κ, so no κ answer, no floor.
        "Local": """
        import Foundation
        import AsyncHTTPClient
        public final class Mine { public func get(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil) ? 1 : 0 } }
        public func l_get_w(_ r: Mine, _ p: String) -> Int { r.get(p) }
        """,
    ]

    private struct Fixture { let root: URL; let bin: URL; let dep: String
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") } }

    private func make(_ app: String, dep: String? = nil) throws -> Fixture {
        let dep = dep ?? app
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-q1-\(app)-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("\(dep)/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "\(dep)", products: [.library(name: "\(dep)", targets: ["\(dep)"])],
            targets: [.target(name: "\(dep)")])
        """)
        try write("\(dep)/Sources/\(dep)/lib.swift", Self.deps[dep]!)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../\(dep)")],
            targets: [.target(name: "App", dependencies: [.product(name: "\(dep)", package: "\(dep)")])])
        """)
        try write("app/Sources/App/app.swift", Self.apps[app]!)
        let fx = Fixture(root: root, bin: bin, dep: dep)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent(dep).path, "--out", fx.depDir.appendingPathComponent("r\(dep)").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        for extra in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path) where extra != "r\(dep).\(dep).Swift.json" {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(extra))
        }
        return fx
    }

    private struct Row { var inferred: Set<String>; var invisible: Set<String> }
    private struct Scan { var rows: [String: Row]; var uncovered: Set<String> }

    private func scan(_ fx: Fixture, chained: Bool) throws -> Scan {
        var env: [String: String] = [:]
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let tag = "o-\(UUID().uuidString)"
        let r = try ProcessHarness.run(fx.bin, [fx.appDir.path, "--out", fx.root.appendingPathComponent(tag).path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: fx.root.appendingPathComponent("\(tag).App.Swift.json"))) as? [String: Any]
        var rows: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = Row(inferred: Set((f["inferred"] as? [String]) ?? []),
                                                    invisible: Set((f["invisible"] as? [String]) ?? []))
        }
        let unc = ((d?["coverage"] as? [String: Any])?["uncovered"] as? [[String: Any]]) ?? []
        return Scan(rows: rows, uncovered: Set(unc.compactMap { $0["name"] as? String }))
    }

    private func gate(_ fx: Fixture, chained: Bool, _ deny: String) throws -> Int32 {
        var env: [String: String] = [:]
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let pol = fx.root.appendingPathComponent("p-\(UUID().uuidString).policy")
        try "\(deny)\n".write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(fx.bin, [fx.appDir.path, "--policy", pol.path,
                                               "--out", fx.root.appendingPathComponent("g-\(UUID().uuidString)").path], env: env).code
    }

    // ── the typed floor ──

    func testATypedKappaAnswerNamesTheThirdPartyModuleAndOnlyThatUnchained() throws {
        let fx = try make("AsyncHTTPClient"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false)
        for c in ["a_param_kv_w", "a_param_kv_p"] {
            XCTAssertEqual(nc.rows[c]?.inferred, ["Net"], "\(c): κ's verb is unchanged (additive)")
            XCTAssertEqual(nc.rows[c]?.invisible, ["AsyncHTTPClient"],
                           "\(c): κ is a FLOOR for a third-party entity; no report covers AsyncHTTPClient, so the unit says so. "
                           + "Before S3a this row carried no `invisible` over an executed `Fs`")
        }
        for c in ["a_generic_kv_w", "a_mref_kv_w"] {   // the S2c spellings (generic bound, method reference) answer through κ too
            XCTAssertEqual(nc.rows[c]?.invisible, ["AsyncHTTPClient"], "\(c): κ's verb through a bound / a reference is a floor as well")
        }
        XCTAssertTrue(nc.uncovered.contains("AsyncHTTPClient"),
                      "the coverage ledger is the scan-level image of the per-unit `invisible` (SPEC §2)")
        XCTAssertEqual(try gate(fx, chained: false, "deny Fs a_param_kv_w"), 0,
                       "R133: `invisible` arms nothing, so no gate moves — the floor is a disclosure, not a verdict")
        XCTAssertEqual(try gate(fx, chained: false, "deny Fs a_param_kv_p"), 0)
    }

    func testPlatformKappaIsAnAuthorityAndNeverGainsInvisible() throws {
        let fx = try make("AsyncHTTPClient"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false)
        XCTAssertEqual(nc.rows["plat_w"]?.inferred, ["Fs"])
        XCTAssertEqual(nc.rows["plat_w"]?.invisible, [],
                       "`FileManager` is the platform's: κ's table is the whole answer (`authority: complete`), in a file "
                       + "that also imports an open third-party module")
    }

    func testAChainedReportThatCoversTheModuleIsTheAnswerSoChainingChangesNothing() throws {
        let fx = try make("AsyncHTTPClient"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let ch = try scan(fx, chained: true)
        XCTAssertEqual(ch.rows["a_param_kv_w"]?.inferred, ["Fs", "Net"], "the join adds the row's Fs beside κ's Net")
        XCTAssertEqual(ch.rows["a_param_kv_w"]?.invisible, [], "AsyncHTTPClient is covered: nothing to disclose")
        XCTAssertFalse(ch.uncovered.contains("AsyncHTTPClient"))
    }

    func testAConsumerThatDeclaresTheTypeShadowsKappaAndGetsNoFloor() throws {
        let fx = try make("Local", dep: "AsyncHTTPClient"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false)
        XCTAssertEqual(nc.rows["l_get_w"]?.invisible.contains("AsyncHTTPClient") ?? false, false,
                       "CONTROL: `Mine` is the project's own type; no κ entity was answered")
    }

    // ── F5: a free function of a κ-dependency module ──

    func testAFreeFunctionOfAKappaDependencyModuleIsDisclosed() throws {
        let fx = try make("AsyncHTTPClient"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false), ch = try scan(fx, chained: true)
        for c in ["a_free_w", "a_modq_w"] {
            XCTAssertEqual(nc.rows[c]?.invisible, ["AsyncHTTPClient"],
                           "\(c): `blindModules` excludes κ modules and R1866 covers members only, so this executed write "
                           + "was ABSENT from `functions[]`")
            XCTAssertEqual(ch.rows[c]?.inferred, ["Fs"], "\(c) chained: the row answers, unchanged")
            XCTAssertEqual(ch.rows[c]?.invisible, [])
        }
        XCTAssertEqual(try gate(fx, chained: false, "deny Fs a_free_w"), 0, "R133: no gate moves")
    }

    // ── a ledgerNamed package (it is already a blind module; the floor names it where κ answered alone) ──

    func testKappaFreeNameAndCtorOfALedgerNamedPackageName() throws {
        let sh = try make("ShellOut"); defer { try? FileManager.default.removeItem(at: sh.root) }
        let a = try scan(sh, chained: false)
        XCTAssertEqual(a.rows["s_free_kx"]?.inferred, ["Exec"])
        XCTAssertEqual(a.rows["s_free_kx"]?.invisible, ["ShellOut"], "κ's Exec is a floor under a body that also writes")
        XCTAssertEqual(a.rows["s_modq_kx"]?.invisible, ["ShellOut"])
        let fl = try make("Files"); defer { try? FileManager.default.removeItem(at: fl.root) }
        let b = try scan(fl, chained: false)
        XCTAssertEqual(b.rows["f_ctor"]?.inferred, ["Fs"])
        XCTAssertEqual(b.rows["f_ctor"]?.invisible, ["Files"])
        XCTAssertEqual(try scan(fl, chained: true).rows["f_ctor"]?.invisible, [], "chained: Files' report is the answer")
    }

    // ── R1879: the dependency's own declaration of a platform κ name ──

    func testAnUnchainedReadableDependencyFreeFunctionThatBindsAPlatformNameIsNamed() throws {
        let fx = try make("ConnC"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false), ch = try scan(fx, chained: true)
        XCTAssertEqual(nc.rows["b_connc_w"]?.inferred, ["Net"], "κ's platform answer is kept (the over-charge direction)")
        XCTAssertEqual(nc.rows["b_connc_w"]?.invisible, ["ConnC"],
                       "the call binds ConnC's `connect(_:at:_:)`, whose body writes a file: the module that declares the "
                       + "callee is named. Before: `Net` and NO ledger entry (contrast a non-binding declaration)")
        XCTAssertEqual(ch.rows["b_connc_w"]?.invisible, [], "chained: the join (R649/R1876) answers")
    }

    func testAControlADeclarationWhoseLabelsCannotBindIsNotNamedAndPosixConnectKeepsItsAuthority() throws {
        let fx = try make("ConnF"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let nc = try scan(fx, chained: false)
        XCTAssertEqual(nc.rows["posixF"]?.inferred, ["Net"])
        XCTAssertEqual(nc.rows["posixF"]?.invisible, [],
                       "`connect(fd, sa, len)` cannot bind `connect(host:)`: it is POSIX connect(2), and the platform entry is "
                       + "an authority — naming ConnF here would be the platform entry gaining `invisible`")
    }
}
