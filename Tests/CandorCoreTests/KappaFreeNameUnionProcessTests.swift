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
        // S1 merge review D1 — a FACADE: re-publishes Files' type by typealias, declares nothing of its own.
        "FilesFacade": """
        import Files
        public typealias File = Files.File
        """,
        // D2 — re-exports ShellOut AND adds a pure same-named overload with labels the ShellOut call cannot bind.
        "ShellWrap": """
        @_exported import ShellOut
        @discardableResult
        public func shellOut(cmd: String) -> String { return cmd }
        """,
        // D3 — a free `connect` whose middle label is a keyword, so it is declared with backticks.
        "ConnB": """
        import Foundation
        @discardableResult
        public func connect(_ fd: Int32, `in` tag: String, _ len: Int32) -> Int32 { FileManager.default.createFile(atPath: tag, contents: nil); return 0 }
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
        "FilesFacade": """
        import FilesFacade
        public func t_ctor_w(_ p: String) throws -> String { try File(path: p).path }
        public func t_ctorq_w(_ p: String) throws -> String { try FilesFacade.File(path: p).path }
        """,
        "ShellWrap": """
        import ShellWrap
        public func w_free_kx(_ p: String) -> String { shellOut(to: "echo", at: p) }
        public func w_over_p(_ p: String) -> String { shellOut(cmd: p) }
        """,
        "ConnB": """
        import ConnB
        public func b_conn_w(_ p: String) -> Int32 { connect(3, in: p, 0) }
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

    /// Which other fixture packages a dependency itself depends on (the facade and the wrapper re-publish another).
    private static let depDeps: [String: [String]] = ["FilesFacade": ["Files"], "ShellWrap": ["ShellOut"]]

    private func make(_ dep: String) throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-s1-\(dep)-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        let all = (Self.depDeps[dep] ?? []) + [dep]
        for d in all {
            let dd = Self.depDeps[d] ?? []
            try write("\(d)/Package.swift", """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "\(d)", products: [.library(name: "\(d)", targets: ["\(d)"])],
                dependencies: [\(dd.map { ".package(path: \"../\($0)\")" }.joined(separator: ", "))],
                targets: [.target(name: "\(d)", dependencies: [\(dd.map { ".product(name: \"\($0)\", package: \"\($0)\")" }.joined(separator: ", "))])])
            """)
            try write("\(d)/Sources/\(d)/lib.swift", Self.deps[d]!)
        }
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [\(all.map { ".package(path: \"../\($0)\")" }.joined(separator: ", "))],
            targets: [.target(name: "App", dependencies: [\(all.map { ".product(name: \"\($0)\", package: \"\($0)\")" }.joined(separator: ", "))])])
        """)
        try write("app/Sources/App/app.swift", Self.apps[dep]!)
        let fx = Fixture(root: root, bin: bin, dep: dep)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        var keep: Set<String> = []
        for d in all {
            let rd = try ProcessHarness.run(bin, [root.appendingPathComponent(d).path, "--out", fx.depDir.appendingPathComponent("r\(d)").path])
            XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
            keep.insert("r\(d).\(d).Swift.json")
        }
        for extra in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path) where !keep.contains(extra) {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(extra))
        }
        return fx
    }

    /// Rewrite the producer report so `fn`'s row loses `drop` — an under-reporting producer (R1867's shape).
    private func doctor(_ fx: Fixture, fn: String, drop: String) throws {
        let u = fx.depDir.appendingPathComponent("r\(fx.dep).\(fx.dep).Swift.json")
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

    private func gate(_ fx: Fixture, chained: Bool, _ deny: String, env extra: [String: String] = [:]) throws -> Int32 {
        var env = extra
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

    // ── S1 merge review: the proof is about the CALLEE, not the name (D1–D3), each pinned beside its pure twin ──
    // Bodies are the review fixture's, executed there (`fableagent-l2review/exec/truth.tsv`): Files' `File.init` spawns
    // (`.i`) and writes (`.f0`); ShellOut's `shellOut(to:at:)` spawns and writes; ShellWrap's `shellOut(cmd:)` is pure;
    // ConnB's `connect(_:in:_:)` writes a file and opens no socket.

    func testD1AFacadeTypealiasIsTheEntityNotADifferentOne() throws {
        let fx = try make("FilesFacade"); defer { try? FileManager.default.removeItem(at: fx.root) }
        for chained in [false, true] {
            let rows = try scan(fx, chained: chained)
            for c in ["t_ctor_w", "t_ctorq_w"] {
                XCTAssertTrue(rows[c]?.inferred.contains("Fs") ?? false,
                              "\(c) chained=\(chained): `typealias File = Files.File` declares no type of its own; the call "
                              + "reaches Files' `File.init`, so κ's Fs stays (0.43.0's reading). The lane's first cut read "
                              + "`[] inv:FilesFacade` here — a withdrawal from the κ entity itself")
            }
            XCTAssertEqual(try gate(fx, chained: chained, "deny Fs t_ctor_w"), 1)
        }
    }

    func testD2AReexportOfTheEntityKeepsKappaAndTheBindingOverloadIsItsOwn() throws {
        let fx = try make("ShellWrap"); defer { try? FileManager.default.removeItem(at: fx.root) }
        for chained in [false, true] {
            let rows = try scan(fx, chained: chained)
            XCTAssertTrue(rows["w_free_kx"]?.inferred.contains("Exec") ?? false,
                          "chained=\(chained): `shellOut(to:at:)` cannot bind ShellWrap's `shellOut(cmd:)` and reaches ShellOut's "
                          + "through `@_exported import`; κ's Exec stays. The first cut read ABSENT chained — silent")
            XCTAssertFalse(rows["w_over_p"]?.inferred.contains("Exec") ?? false,
                           "PURE TWIN chained=\(chained): `shellOut(cmd:)` binds ShellWrap's own pure overload, and ShellOut's "
                           + "readable `shellOut(to:at:)` cannot bind it, so κ must not charge it")
            XCTAssertEqual(try gate(fx, chained: chained, "deny Exec w_free_kx"), 1)
        }
    }

    func testD3ABacktickedLabelBindsAndStillShadowsPosixConnect() throws {
        let fx = try make("ConnB"); defer { try? FileManager.default.removeItem(at: fx.root) }
        XCTAssertEqual(try scan(fx, chained: true)["b_conn_w"]?.inferred, ["Fs"],
                       "`connect(3, in: p, 0)` binds ConnB's backticked `in` label; R649's shadow applies and the row's Fs "
                       + "answers. The first cut compared the label with its backticks and read ['Net'] — Fs silent")
        XCTAssertEqual(try gate(fx, chained: true, "deny Fs b_conn_w"), 1)
    }

    func testR1876KillSwitchRestoresTheBaseNameShadow() throws {
        let fx = try make("ConnF"); defer { try? FileManager.default.removeItem(at: fx.root) }
        XCTAssertEqual(try scan(fx, chained: true, env: ["CANDOR_R1876_OFF": "1"])["posixF"]?.inferred, ["Fs"],
                       "§1b: `CANDOR_R1876_OFF=1` restores pre-S1 R649 — the dependency's `connect` shadows by base name")
    }

    func testBacktickedNamesAreUnescaped() {
        let r = topLevelCalleeDeclarations(source: "public func f(_ a: Int, `in` t: String) {}\npublic typealias File = X.File\npublic struct S {}")
        XCTAssertEqual(r.fns["f"]?.first?.labels, [nil, "in"])
        XCTAssertNil(r.nominal["File"], "a typealias is not a nominal declaration")
        XCTAssertEqual(r.nominal["S"], true)
    }
}
