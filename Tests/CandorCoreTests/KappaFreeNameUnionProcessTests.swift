import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1867, R1870, R1871, R1876 — stage S1 of the swift curated-routing design: a κ FREE NAME, a κ
/// CONSTRUCTOR and a MODULE-QUALIFIED κ name read the κ registry to decide whether a chained (or readable) dependency
/// declaration is the SAME entity κ describes (SPEC §2 ⟨0.43⟩: union) or a DIFFERENT one (name resolution: κ does not
/// apply). Before S1 the three spellings applied three precedences by spelling alone:
///
///     R1867  `shellOut(…)`, ShellOut chained, its row lacking Exec        ['Fs']        (row-wins: κ Exec withdrawn)
///     R1870  `File(path:)`, Files chained, `File.init` runs a process     ['Fs']        (curated-wins: row never read)
///     R1871  `ShellOut.shellOut(…)` chained                               ['Exec']      (curated-wins: row Fs lost)
///            `ShellKit.shellOut(…)`, a VENDORED copy (body Fs, no process) ['Exec']     (κ on a different entity)
///     R1876  POSIX `connect(fd, a, len)`, a dep declares `connect(host:)`  ['Fs']        (shadowed by base name)
///
/// Every dependency below is executed-shape (the L0 attack matrix ran these bodies: `shellOut` and `File.init` really
/// spawn `/usr/bin/touch`; the vendored `shellOut` and `connect(host:)` only write a file). One consumer text per
/// dependency, one binary; the arms vary ONLY `CANDOR_DEPS` (and, for R1867, the producer report's doctored row).
final class KappaFreeNameUnionProcessTests: XCTestCase {

    private static let deps: [String: String] = [
        "ShellOut": """
        import Foundation
        @discardableResult
        public func shellOut(to command: String, at p: String) -> String {
            let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/usr/bin/touch"); pr.arguments = [p + ".x"]
            try? pr.run(); pr.waitUntilExit(); FileManager.default.createFile(atPath: p, contents: nil); return command
        }
        """,
        "ShellKit": """
        import Foundation
        @discardableResult
        public func shellOut(to command: String, at p: String) -> String { FileManager.default.createFile(atPath: p, contents: nil); return command }
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
        "ConnF": """
        import Foundation
        public func connect(host p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 }
        """,
        "ConnG": """
        import Foundation
        public func connect(_ a: Int32, _ b: UnsafePointer<sockaddr>, _ c: socklen_t) -> Int32 { FileManager.default.createFile(atPath: "/tmp/g", contents: nil); return 0 }
        """,
    ]

    private static let apps: [String: String] = [
        "ShellOut": """
        import ShellOut
        public func s_free_kx(_ p: String) -> String { shellOut(to: "echo", at: p) }
        public func s_modq_kx(_ p: String) -> String { ShellOut.shellOut(to: "echo", at: p) }
        """,
        "ShellKit": """
        import ShellKit
        public func v_free_kx(_ p: String) -> String { shellOut(to: "echo", at: p) }
        public func v_modq_kx(_ p: String) -> String { ShellKit.shellOut(to: "echo", at: p) }
        """,
        "Files": """
        import Files
        public func f_ctor(_ p: String) throws -> String { try File(path: p).path }
        public func f_ctorq(_ p: String) throws -> String { try Files.File(path: p).path }
        """,
        "ConnF": """
        import Darwin
        import ConnF
        public func posixF(_ fd: Int32, _ sa: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, sa, len) }
        public func depF(_ p: String) -> Int { connect(host: p) }
        """,
        "ConnG": """
        import Darwin
        import ConnG
        public func posixG(_ fd: Int32, _ sa: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, sa, len) }
        """,
    ]

    private struct Fixture { let root: URL; let bin: URL; let dep: String
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") } }

    private func make(_ dep: String) throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-s1-\(dep)-\(UUID().uuidString)")
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
        try write("app/Sources/App/app.swift", Self.apps[dep]!)
        let fx = Fixture(root: root, bin: bin, dep: dep)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent(dep).path, "--out", fx.depDir.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        for extra in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path) where extra != "r.\(dep).Swift.json" {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(extra))
        }
        return fx
    }

    /// Rewrite the producer report so `fn`'s row loses `drop` — an under-reporting producer (R1867's shape).
    private func doctor(_ fx: Fixture, fn: String, drop: String) throws {
        let u = fx.depDir.appendingPathComponent("r.\(fx.dep).Swift.json")
        var d = try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as! [String: Any]
        var n = 0
        d["functions"] = ((d["functions"] as? [[String: Any]]) ?? []).map { f -> [String: Any] in
            guard (f["fn"] as? String) == fn else { return f }
            var g = f; g["inferred"] = ((f["inferred"] as? [String]) ?? []).filter { $0 != drop }; n += 1; return g
        }
        XCTAssertEqual(n, 1, "§E3 premise: the producer publishes exactly one `\(fn)` row to doctor")
        try JSONSerialization.data(withJSONObject: d).write(to: u)
    }

    private struct Row { var inferred: Set<String>; var invisible: Set<String> }

    private func scan(_ fx: Fixture, chained: Bool, env extra: [String: String] = [:]) throws -> [String: Row] {
        var env = extra
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
        return rows
    }

    private func gate(_ fx: Fixture, chained: Bool, _ deny: String) throws -> Int32 {
        var env: [String: String] = [:]
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let pol = fx.root.appendingPathComponent("p-\(UUID().uuidString).policy")
        try "\(deny)\n".write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(fx.bin, [fx.appDir.path, "--policy", pol.path,
                                               "--out", fx.root.appendingPathComponent("g-\(UUID().uuidString)").path], env: env).code
    }

    // ── R1867: row-wins withdrew κ ──

    func testR1867AChainedRowThatUnderReportsKappaNoLongerWithdrawsIt() throws {
        let fx = try make("ShellOut"); defer { try? FileManager.default.removeItem(at: fx.root) }
        try doctor(fx, fn: "shellOut", drop: "Exec")
        let ch = try scan(fx, chained: true)
        XCTAssertEqual(ch["s_free_kx"]?.inferred, ["Exec", "Fs"],
                       "the dependency IS ShellOut (the κ registry): κ's Exec and the row's Fs are UNIONED. Before S1 the "
                       + "row shadowed κ and this read ['Fs'] over a body that spawns a process")
        XCTAssertEqual(try gate(fx, chained: true, "deny Exec s_free_kx"), 1, "GATE: `deny Exec` was exit 0 chained")
    }

    func testR1867ControlTheRealRowStillJoins() throws {
        let fx = try make("ShellOut"); defer { try? FileManager.default.removeItem(at: fx.root) }
        XCTAssertEqual(try scan(fx, chained: true)["s_free_kx"]?.inferred, ["Exec", "Fs"])
        XCTAssertEqual(try scan(fx, chained: false)["s_free_kx"]?.inferred, ["Exec"],
                       "unchained, κ alone answers the entity it describes (the floor; S3's `invisible` is a later stage)")
    }

    // ── R1871: module-qualified ──

    func testR1871TheModuleQualifiedSpellingUnionsWithTheRow() throws {
        let fx = try make("ShellOut"); defer { try? FileManager.default.removeItem(at: fx.root) }
        XCTAssertEqual(try scan(fx, chained: true)["s_modq_kx"]?.inferred, ["Exec", "Fs"],
                       "`ShellOut.shellOut(…)` is the bare call's spelling; before S1 κ answered before the join and the "
                       + "row's Fs was lost (`deny Fs` 0 over an executed write)")
        XCTAssertEqual(try gate(fx, chained: true, "deny Fs s_modq_kx"), 1)
    }

    func testR1871AVendoredCopyIsADifferentEntity() throws {
        let fx = try make("ShellKit"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let ch = try scan(fx, chained: true), nc = try scan(fx, chained: false)
        for (cell, row) in [("v_free_kx ch", ch["v_free_kx"]), ("v_modq_kx ch", ch["v_modq_kx"])] {
            XCTAssertEqual(row?.inferred, ["Fs"], "\(cell): ShellKit's own `shellOut` writes a file and runs no process; "
                           + "κ describes ShellOut's, a different entity — Exec here is a fabrication, Fs the real effect")
        }
        XCTAssertFalse(nc["v_free_kx"]?.inferred.contains("Exec") ?? false,
                       "unchained with ShellKit's sources READABLE, the module provably declares its own `shellOut`")
        XCTAssertTrue(nc["v_free_kx"]?.invisible.contains("ShellKit") ?? false,
                      "…and the call is disclosed by the ledger rather than read pure (never silently pure)")
        XCTAssertFalse(nc["v_modq_kx"]?.inferred.contains("Exec") ?? false)
        XCTAssertTrue(nc["v_modq_kx"]?.invisible.contains("ShellKit") ?? false)
        XCTAssertEqual(try gate(fx, chained: true, "deny Fs v_modq_kx"), 1, "GATE: the vendored write, chained")
    }

    func testR1871KillSwitchRestoresKappaOnTheVendoredCopy() throws {
        let fx = try make("ShellKit"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let off = try scan(fx, chained: false, env: ["CANDOR_R1871V_OFF": "1"])
        XCTAssertEqual(off["v_free_kx"]?.inferred, ["Exec"], "§1b: the switch restores the pre-S1 route (κ fires)")
    }

    // ── R1870: κ ctor ──

    func testR1870AKappaCtorUnionsWithTheChainedInitRow() throws {
        let fx = try make("Files"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let ch = try scan(fx, chained: true)
        XCTAssertEqual(ch["f_ctor"]?.inferred, ["Exec", "Fs"],
                       "κ's Fs (the floor) and Files' own `File.init` row (Exec) — before S1 the row was never read")
        XCTAssertEqual(ch["f_ctorq"]?.inferred, ["Exec", "Fs"], "the module-qualified ctor, the same union")
        XCTAssertEqual(try gate(fx, chained: true, "deny Exec f_ctor"), 1)
        XCTAssertEqual(try scan(fx, chained: false)["f_ctor"]?.inferred, ["Fs"], "unchained: κ alone, unchanged")
    }

    // ── R1876: shadowed by base name ──

    func testR1876ADependencyFreeFunctionWhoseLabelsCannotBindDoesNotShadowPosixConnect() throws {
        let fx = try make("ConnF"); defer { try? FileManager.default.removeItem(at: fx.root) }
        let ch = try scan(fx, chained: true)
        XCTAssertEqual(ch["posixF"]?.inferred, ["Net"],
                       "`connect(fd, sa, len)` cannot bind ConnF's `connect(host:)`; it is POSIX connect(2). Before S1 it "
                       + "read ['Fs'] — the dependency's row charged to a call that never reaches it, Net silent")
        XCTAssertEqual(ch["depF"]?.inferred, ["Fs"], "CONTROL: the call that DOES bind ConnF's function still joins its row")
        XCTAssertEqual(try gate(fx, chained: true, "deny Net posixF"), 1)
    }

    func testR1876ControlADeclarationWhoseLabelsBindStillShadows() throws {
        let fx = try make("ConnG"); defer { try? FileManager.default.removeItem(at: fx.root) }
        XCTAssertEqual(try scan(fx, chained: true)["posixG"]?.inferred, ["Fs"],
                       "R649's rule kept: a chained free function whose labels bind the call is the callee it names")
    }

    // ── the signature matcher ──

    func testFreeFnSignatureMatcher() {
        let host = FreeFnSignature(labels: ["host"], defaults: [false], variadic: [false], visible: true)
        XCTAssertFalse(host.couldAccept(callLabels: [nil, nil, nil], trailingClosures: 0))
        XCTAssertTrue(host.couldAccept(callLabels: ["host"], trailingClosures: 0))
        let posix = FreeFnSignature(labels: [nil, nil, nil], defaults: [false, false, false], variadic: [false, false, false], visible: true)
        XCTAssertTrue(posix.couldAccept(callLabels: [nil, nil, nil], trailingClosures: 0))
        XCTAssertFalse(posix.couldAccept(callLabels: [nil, nil], trailingClosures: 0))
        let defs = FreeFnSignature(labels: ["to", "arguments", "at"], defaults: [false, true, true], variadic: [false, false, false], visible: true)
        XCTAssertTrue(defs.couldAccept(callLabels: ["to", "at"], trailingClosures: 0))
        XCTAssertTrue(defs.couldAccept(callLabels: ["to"], trailingClosures: 0))
        XCTAssertFalse(defs.couldAccept(callLabels: ["at"], trailingClosures: 0))
        XCTAssertTrue(host.couldAccept(callLabels: [], trailingClosures: 1), "a trailing closure is not modelled: COULD")
    }

    func testKappaRelationReadsTheRegistry() {
        XCTAssertEqual(kappaRelation(name: "shellOut", module: "ShellOut"), .same)
        XCTAssertEqual(kappaRelation(name: "shellOut", module: "ShellKit"), .different)
        XCTAssertEqual(kappaRelation(name: "File", module: "Files"), .same)
        XCTAssertEqual(kappaRelation(name: "connect", module: "ConnF"), .different)
        XCTAssertEqual(kappaRelation(name: "LLM", module: "LangChain"), .unknown,
                       "an unverified module list forms no identity either way")
        XCTAssertNil(kappaRelation(name: "notKappa", module: "X"))
    }
}
