import XCTest
import Foundation

/// SOUNDNESS R1938 (type-identity lanes L0 + L1) — the shared harness for the type-identity attack matrix.
///
/// The matrix lives in `Tests/Fixtures/TypeIdentity/` as real SwiftPM packages: a consumer package, the dependency it names
/// (`fx/Guess`), and a `Run*` executable that CALLS every cell, so each cell's truth is EXECUTED, not argued
/// (`tools/identity-exec.sh` runs them under swiftc and writes the `exec-ground-truth.txt` each fixture carries; the
/// env-gated `TypeIdentityExecutionTests` re-runs it and diffs). Each process test stages the fixture tree in a temp dir, scans
/// the consumer standalone (`un`), chained to the arm's own dependency report (`ch`) and, where the cell is a dependency-truth
/// cell, standalone with the dependency's sources NOT located (`unr`: the manifest names it by an ABSOLUTE `.package(path:)`,
/// which the engine does not locate — SOUNDNESS R1896 round 2), and compares the readings to a cell table.
///
/// A cell row pins TWO readings:
///   * `main` — what the engine reads TODAY. Asserted unless the cell's lane is in `TypeIdentityTarget.expect`.
///   * `target` — what the design (DESIGN.md §5, swift-type-identity-design) says the lane that owns the cell must produce.
///     Asserted INSTEAD of `main` once that lane is in `TypeIdentityTarget.expect`. A lane flips its own flag in the same
///     commit as its fix; the neighbour lanes' cells keep asserting main, which is how "must not move" is enforced.
/// A cell with no `target` is a control: it asserts `main` always.
///
/// This lane changes NO engine behaviour, so every `main` reading here is a measurement of the branch point, and
/// `TypeIdentityTargetCalibrationTests` proves the `target` column is not vacuous (it fails when a lane's flag is forced on).

enum TypeIdentityLane: String, CaseIterable { case ls, l2, l3, l4, l5 }

enum TypeIdentityTarget {
    /// The lanes whose target readings are asserted. EMPTY at L0: no lane has landed. A later lane adds itself HERE, in the commit
    /// that lands its fix (LS has). `CANDOR_IDENT_EXPECT_TARGET=ls,l2,…` (or `all`) forces lanes on; `main` forces every lane off for a calibration run, which must
    /// FAIL on a branch that has not landed them.
    static var expect: Set<TypeIdentityLane> {
        // LS landed (SOUNDNESS R1938 lane LS, the narrow platform-name shadow): its target column is the assertion now.
        // L2 landed (SOUNDNESS R1938 lane L2, the use-unit guard; R1947, R1950): likewise.
        var s: Set<TypeIdentityLane> = [.ls, .l2]
        let env = ProcessInfo.processInfo.environment
        if let e = env["CANDOR_IDENT_EXPECT_TARGET"] {
            if e == "all" { s = Set(TypeIdentityLane.allCases) }
            // `main` asserts the main column for EVERY cell, landed lanes included: the kill-switch arm (a landed lane's switch
            // set must read main's column again)
            else if e == "main" { s = [] }
            else { for p in e.split(separator: ",") { if let l = TypeIdentityLane(rawValue: String(p)) { s.insert(l) } } }
        }
        // A landed lane's KILL SWITCH takes its flag down with it, so `CANDOR_TYPE_ID_L2_OFF=1 swift test` is the switch-off arm
        // (every L2 cell must read main again, every other lane's as before).
        if env["CANDOR_TYPE_ID_L2_OFF"] == "1" { s.remove(.l2) }
        if env["CANDOR_TYPE_ID_SHADOW_OFF"] == "1" { s.remove(.ls) }
        return s
    }
}

/// One function's row, reduced to what the matrix reads.
struct IdentityRow {
    var effects: Set<String>          // `inferred` minus `Unknown`
    var unknown: Bool                 // `Unknown` in `inferred`
    var unknownWhy: [String]
    var invisible: [String]
    var incomplete: Bool
    var dispatchesOn: [String]

    /// The matrix notation: `ABSENT` (no row), `-` (a row with nothing charged), `Fs`, `-+U` (only the Unknown hedge),
    /// `Fs+inc` (a charge with `incomplete`), `-+inv` (only `invisible`), `-+U+inv`, …
    static func reading(_ r: IdentityRow?) -> String {
        guard let r else { return "ABSENT" }
        var s = r.effects.sorted().joined(separator: "+")
        if s.isEmpty { s = "-" }
        if r.unknown { s += "+U" }
        if !r.invisible.isEmpty { s += "+inv" }
        if r.incomplete { s += "+inc" }
        return s
    }
}

/// A report plus its call-graph sidecar (edges per unit), keyed by the unit's `fn` up to its parameter list.
struct IdentityScan {
    var rows: [String: IdentityRow]
    var edges: [String: [String]]
    func reading(_ fn: String) -> String { IdentityRow.reading(rows[fn]) }
}

enum TypeIdentityHarness {

    /// `Tests/Fixtures/TypeIdentity`, found from THIS file (the fixtures are not a test-target resource on purpose: SwiftPM would
    /// copy or warn about them, and they must stay ordinary packages a developer can `swift run`).
    static let fixturesRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/TypeIdentity")

    /// A staged copy of the fixture tree, so a test can rewrite a manifest and scan without touching the checkout.
    struct Stage { let root: URL; let bin: URL
        func dir(_ rel: String) -> URL { root.appendingPathComponent(rel) }
        func cleanup() { try? FileManager.default.removeItem(at: root) } }

    static func stage(_ testClass: AnyClass) throws -> Stage {
        let bin = try ProcessHarness.binaryURL(for: testClass)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-ident-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fm = FileManager.default
        for e in try fm.contentsOfDirectory(atPath: fixturesRoot.path) {
            try fm.copyItem(at: fixturesRoot.appendingPathComponent(e), to: root.appendingPathComponent(e))
        }
        return Stage(root: root, bin: bin)
    }

    /// Scan `pkg` (a dir under the stage) and read the consumer's report. `chainedTo` is a dependency-report directory
    /// (CANDOR_DEPS). `env` adds switches. The report is `<tag>.<pkgName>.Swift.json`; the package name is the report's, so the
    /// caller does not pass it.
    static func scan(_ st: Stage, _ pkg: String, chainedTo dep: URL? = nil, env extra: [String: String] = [:],
                     file: StaticString = #filePath, line: UInt = #line) throws -> IdentityScan {
        var env = extra
        if let dep { env["CANDOR_DEPS"] = dep.path }
        let tag = "o-\(UUID().uuidString)"
        let out = st.root.appendingPathComponent(tag)
        let r = try ProcessHarness.run(st.bin, [st.dir(pkg).path, "--out", out.path], env: env)
        XCTAssertEqual(r.code, 0, "scan of \(pkg) must succeed — stderr: \(r.err)", file: file, line: line)
        let names = try FileManager.default.contentsOfDirectory(atPath: st.root.path).filter { $0.hasPrefix(tag + ".") }
        guard let rep = names.first(where: { $0.hasSuffix(".Swift.json") && !$0.contains("callgraph") && !$0.contains("hierarchy") && !$0.contains("locs") })
        else { XCTFail("no report for \(pkg): \(names)", file: file, line: line); return IdentityScan(rows: [:], edges: [:]) }
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: st.root.appendingPathComponent(rep))) as? [String: Any]
        var rows: [String: IdentityRow] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            let fn = ((f["fn"] as? String) ?? "?").split(separator: "(").first.map(String.init) ?? "?"
            let inf = (f["inferred"] as? [String]) ?? []
            rows[fn] = IdentityRow(effects: Set(inf).subtracting(["Unknown"]), unknown: inf.contains("Unknown"),
                                   unknownWhy: (f["unknownWhy"] as? [String]) ?? [], invisible: (f["invisible"] as? [String]) ?? [],
                                   incomplete: !(((f["incomplete"] as? [Any]) ?? []).isEmpty) || ((f["incomplete"] as? Bool) ?? false),
                                   dispatchesOn: (f["dispatchesOn"] as? [String]) ?? [])
        }
        var edges: [String: [String]] = [:]
        if let cg = names.first(where: { $0.hasSuffix(".callgraph.json") }),
           let g = try JSONSerialization.jsonObject(with: Data(contentsOf: st.root.appendingPathComponent(cg))) as? [String: Any] {
            // the sidecar: unit -> the callees the engine resolved for it (it holds every unit, the pure ones included)
            for (k, v) in g { if let calls = v as? [String] { edges[k.split(separator: "(").first.map(String.init) ?? k] = calls } }
        }
        return IdentityScan(rows: rows, edges: edges)
    }

    /// Scan a dependency package and keep ONLY its report in a fresh directory (the chained consumer reads `CANDOR_DEPS` as a
    /// directory of reports, and a call-graph or hierarchy sidecar in it is not one).
    static func depReport(_ st: Stage, _ pkgs: [String]) throws -> URL {
        let dir = st.root.appendingPathComponent("dep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, pkg) in pkgs.enumerated() {
            let r = try ProcessHarness.run(st.bin, [st.dir(pkg).path, "--out", dir.appendingPathComponent("rDep\(i)").path])
            XCTAssertEqual(r.code, 0, "dependency scan of \(pkg) must succeed — stderr: \(r.err)")
        }
        for extra in try FileManager.default.contentsOfDirectory(atPath: dir.path)
            where !(extra.hasSuffix(".Swift.json") && !extra.contains("callgraph") && !extra.contains("hierarchy") && !extra.contains("locs")) {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(extra))
        }
        return dir
    }

    /// The `unr` arm: a copy of `pkg` whose manifest names the dependency by an ABSOLUTE path (`from` is the relative spelling
    /// in the manifest). The engine does not locate an absolute `.package(path:)`, so the dependency's sources are unread.
    static func unreadableCopy(_ st: Stage, _ pkg: String, replacing from: String, with depDir: URL) throws -> String {
        let copy = pkg + "-unr"
        try FileManager.default.copyItem(at: st.dir(pkg), to: st.dir(copy))
        let m = st.dir(copy).appendingPathComponent("Package.swift")
        let text = try String(contentsOf: m, encoding: .utf8)
        XCTAssertTrue(text.contains(from), "manifest of \(pkg) must name its dependency as \(from)")
        try text.replacingOccurrences(of: from, with: depDir.path).write(to: m, atomically: true, encoding: .utf8)
        return copy
    }

    // MARK: cell tables

    struct Reads { var un: String; var ch: String; var unr: String?
        init(_ s: String) {
            let p = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            un = p[0]; ch = p.count > 1 ? p[1] : p[0]; unr = p.count > 2 && p[2] != "~" ? p[2] : nil
        }
    }
    struct Cell { let fn: String; let truth: String; let main: Reads; let lane: TypeIdentityLane?; let target: Reads?; let note: String
        /// `^lane un|ch[|unr]`: the reading once `lane` has landed and the cell's OWN lane has not — a NEIGHBOUR the landed lane moved
        /// (asserted exactly, like `main`). Lane L2, e.g.: a global's own initializer `Lib()` is a use-unit spelling, so the global's
        /// callers gain the initializer's `invisible` while the global's BINDING (L3's) is unchanged.
        var after: [(TypeIdentityLane, Reads)] = [] }

    /// A table is one cell per line:  `fn  truth  un|ch[|unr]  [lane  un|ch[|unr]]  [^lane un|ch[|unr]]…  [# note]`. `truth` is the
    /// EXECUTED reading (`WRITES`, `pure`, `LOGS`). A `~` in the `unr` position means the cell has no unreadable-dependency arm.
    static func cells(_ table: String) -> [Cell] {
        var out: [Cell] = []
        for raw in table.split(separator: "\n") {
            var line = String(raw)
            var note = ""
            if let h = line.range(of: " # ") { note = String(line[h.upperBound...]); line = String(line[..<h.lowerBound]) }
            var f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if f.isEmpty || f[0].hasPrefix("#") { continue }
            var after: [(TypeIdentityLane, Reads)] = []
            while f.count >= 2, f[f.count - 2].hasPrefix("^") {
                guard let l = TypeIdentityLane(rawValue: String(f[f.count - 2].dropFirst())) else { preconditionFailure("bad ^lane in: \(raw)") }
                after.insert((l, Reads(f[f.count - 1])), at: 0)
                f.removeLast(2)
            }
            precondition(f.count == 3 || f.count == 5, "bad cell row: \(raw)")
            let lane: TypeIdentityLane? = f.count == 5 ? TypeIdentityLane(rawValue: f[3]) : nil
            if f.count == 5 { precondition(lane != nil, "bad lane in: \(raw)") }
            out.append(Cell(fn: f[0], truth: f[1], main: Reads(f[2]), lane: lane, target: f.count == 5 ? Reads(f[4]) : nil, note: note, after: after))
        }
        return out
    }

    /// Does `got` satisfy `want`? (`want` may list ALTERNATIVES separated by `/`; the caller splits them.) A PURE want (`ABSENT` or `-`) is exact. A CHARGED want names the effect set exactly and
    /// requires each listed flag (`+U`, `+inv`, `+inc`); a flag it does not list may still be present (a hedge beside a charge).
    static func satisfies(_ got: String, _ want: String) -> Bool {
        if want == "ABSENT" || want == "-" { return got == want }
        func parts(_ s: String) -> (effects: Set<String>, flags: Set<String>) {
            var eff: Set<String> = [], fl: Set<String> = []
            for (i, p) in s.split(separator: "+", omittingEmptySubsequences: true).map(String.init).enumerated() {
                if p == "U" || p == "inv" || p == "inc" { fl.insert(p) } else if !(i == 0 && p == "-") { eff.insert(p) }
            }
            return (eff, fl)
        }
        if got == "ABSENT" { return false }
        let g = parts(got), w = parts(want)
        return g.effects == w.effects && w.flags.isSubset(of: g.flags)
    }

    /// Assert `cells` against `scans` (un / ch / unr). `truthFile` is the fixture's `exec-ground-truth.txt`.
    static func check(_ table: String, un: IdentityScan, ch: IdentityScan, unr: IdentityScan?, truth: [String: String],
                      label: String, file: StaticString = #filePath, line: UInt = #line) {
        for c in cells(table) {
            XCTAssertEqual(truth[c.fn], c.truth, "\(label) \(c.fn): the table's truth must be the EXECUTED one", file: file, line: line)
            let useTarget = c.lane.map { TypeIdentityTarget.expect.contains($0) } ?? false
            // the LAST landed neighbour lane that moved this cell (a later lane's `^` reading supersedes an earlier one's)
            let moved = useTarget ? nil : c.after.last { TypeIdentityTarget.expect.contains($0.0) }
            let want = useTarget ? c.target! : (moved?.1 ?? c.main)
            let tag = useTarget ? "TARGET[\(c.lane!.rawValue)]" : (moved.map { "after[\($0.0.rawValue)]" } ?? "main")
            func one(_ arm: String, _ got: String, _ w: String) {
                let ok = useTarget ? w.split(separator: "/").contains { satisfies(got, String($0)) } : (got == w)
                XCTAssertTrue(ok, "\(label) \(c.fn) \(arm): reads \(got), \(tag) says \(w)\(c.note.isEmpty ? "" : " — \(c.note)")", file: file, line: line)
            }
            one("un", un.reading(c.fn), want.un)
            one("ch", ch.reading(c.fn), want.ch)
            if let w = want.unr { if let unr { one("unr", unr.reading(c.fn), w) } else { XCTFail("\(label) \(c.fn): unr arm not run", file: file, line: line) } }
        }
    }

    /// The live-join proof every chained fixture carries: the chained arm must charge MORE concrete rows than the standalone arm.
    /// A chained matrix whose join is dead reads identically to the standalone one and proves nothing.
    static func assertLiveJoin(un: IdentityScan, ch: IdentityScan, liveCells: [String], label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        func fsCount(_ s: IdentityScan) -> Int { s.rows.values.filter { !$0.effects.isEmpty }.count }
        XCTAssertGreaterThan(fsCount(ch), fsCount(un), "\(label): the chained join is DEAD (no concrete row differs between arms)", file: file, line: line)
        for c in liveCells {
            XCTAssertTrue(ch.rows[c]?.effects.contains("Fs") ?? false, "\(label) \(c): the liveness control must charge Fs chained", file: file, line: line)
            XCTAssertFalse(un.rows[c]?.effects.contains("Fs") ?? false, "\(label) \(c): the liveness control must NOT charge Fs standalone", file: file, line: line)
        }
    }

    // MARK: a fixture, end to end

    /// One consumer package of the matrix. `deps` are the dependency packages it names (scanned, in this order, into ONE report
    /// directory for the chained arm), `spelling` is how the consumer's manifest writes its first dependency (the `unr` arm replaces
    /// it by an absolute path), `live` are the cells that call the dependency's own free function: they must charge `Fs` chained
    /// and NOT standalone, which is the proof the chained join is live.
    struct Fixture {
        let app: String; let truthFile: String; let deps: [String]; let spelling: String?; let unr: Bool; let live: [String]; let table: String
    }

    struct Arms { var un: IdentityScan; var ch: IdentityScan; var unr: IdentityScan? }

    static func truth(file rel: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for l in try String(contentsOf: fixturesRoot.appendingPathComponent(rel), encoding: .utf8).split(separator: "\n") {
            let p = l.split(separator: " ").map(String.init)
            if p.count == 2 { out[p[0]] = p[1] }
        }
        return out
    }

    /// Stage, scan every arm, assert the cell table. Returns the arms so a test can assert more (edges, rows).
    @discardableResult
    static func run(_ f: Fixture, in st: Stage, label: String, file: StaticString = #filePath, line: UInt = #line) throws -> Arms {
        let un = try scan(st, f.app, file: file, line: line)
        var ch = un
        if !f.deps.isEmpty {
            let dep = try depReport(st, f.deps)
            ch = try scan(st, f.app, chainedTo: dep, file: file, line: line)
        }
        var unr: IdentityScan? = nil
        if f.unr, let sp = f.spelling, let d0 = f.deps.first {
            let copy = try unreadableCopy(st, f.app, replacing: sp, with: st.dir(d0))
            unr = try scan(st, copy, file: file, line: line)
        }
        if !f.deps.isEmpty && !f.live.isEmpty { assertLiveJoin(un: un, ch: ch, liveCells: f.live, label: label, file: file, line: line) }
        check(f.table, un: un, ch: ch, unr: unr, truth: try truth(file: f.truthFile), label: label, file: file, line: line)
        return Arms(un: un, ch: ch, unr: unr)
    }

    // MARK: pinned sidecar edges (DESIGN §5.4)

    /// A pure control that reads ABSENT proves nothing unless the call-graph sidecar shows WHICH type it bound. `main` pins today's
    /// edges; `target` (asserted once `lane` has landed) pins the edges the design wants.
    struct EdgePin { let fn: String; let mainHas: [String]; let mainHasNot: [String]
        let lane: TypeIdentityLane?; let targetHas: [String]; let targetHasNot: [String]
        init(_ fn: String, has: [String] = [], hasNot: [String] = [], lane: TypeIdentityLane? = nil, targetHas: [String] = [], targetHasNot: [String] = []) {
            self.fn = fn; mainHas = has; mainHasNot = hasNot; self.lane = lane; self.targetHas = targetHas; self.targetHasNot = targetHasNot } }

    static func checkEdges(_ pins: [EdgePin], _ scan: IdentityScan, label: String, file: StaticString = #filePath, line: UInt = #line) {
        for p in pins {
            let useTarget = p.lane.map { TypeIdentityTarget.expect.contains($0) } ?? false
            let has = useTarget ? p.targetHas : p.mainHas, hasNot = useTarget ? p.targetHasNot : p.mainHasNot
            let got = scan.edges[p.fn]
            XCTAssertNotNil(got, "\(label) \(p.fn): no sidecar entry", file: file, line: line)
            for e in has { XCTAssertTrue(got?.contains(e) ?? false, "\(label) \(p.fn): edge \(e) must be present (\(useTarget ? "target" : "main")) — edges: \(got ?? [])", file: file, line: line) }
            for e in hasNot { XCTAssertFalse(got?.contains(e) ?? false, "\(label) \(p.fn): edge \(e) must be absent (\(useTarget ? "target" : "main")) — edges: \(got ?? [])", file: file, line: line) }
        }
    }
}
