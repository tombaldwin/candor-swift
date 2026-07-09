// candor-swift — the candor domain model (candor-spec/MODEL.md) + the atomic JSON writer.
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation

// ── The candor domain model (candor-spec/MODEL.md) — candor-swift's named realization of the shared
// vocabulary. Independently derived (NO shared code across engines — that independence is what the
// conformance differential proves); mirrors candor-java's `io.poly.candor.model` and Rust's candor-report
// structs. These types OWN the §2 wire serialization, so the entry/envelope shape lives in one place.
enum Effect: String, CaseIterable {
    case clipboard = "Clipboard", clock = "Clock", db = "Db", env = "Env", exec = "Exec"
    case fs = "Fs", ipc = "Ipc", log = "Log", net = "Net", rand = "Rand", unknown = "Unknown"
    var specName: String { rawValue }
    static func from(_ name: String) -> Effect? { Effect(rawValue: name) }
}
// A set of effects (SEMANTICS §1). Wire form = spec-name-sorted names — which, for this vocabulary, is the
// same lexicographic order a `Set<String>.sorted()` produced, so adoption is byte-identical.
struct EffectSet {
    private(set) var effects: Set<Effect>
    init(names: some Sequence<String>) { self.effects = Set(names.compactMap(Effect.from)) }
    func toNames() -> [String] { effects.map { $0.specName }.sorted() }
}
// Which engine produced a report and which contract it conforms to (§2.1).
struct Provenance {
    let version: String, toolchain: String, spec: String
    func toJSON() -> [String: Any] { ["version": version, "toolchain": toolchain, "spec": spec] }
}
// The per-unit report entry (§2). candor-swift is analyze-only, so declared/undeclared/overdeclared are
// always empty (no DI-conformance pass) — kept in the wire shape for cross-engine schema parity.
struct Effector {
    let fn: String, loc: String
    let inferred: EffectSet, direct: EffectSet
    let unresolved: Bool, hash: String, calls: [String]
    var entryPoint = false
    var unitKind: String? = nil
    var unknownWhy: [String]? = nil
    var hosts: [String]? = nil, cmds: [String]? = nil, paths: [String]? = nil, tables: [String]? = nil
    var invisible: [String]? = nil   // per-fn blind-spot disclosure: κ-unknown modules reached (qualifies `inferred`)
    func toJSON() -> [String: Any] {
        var e: [String: Any] = [
            "fn": fn, "loc": loc,
            "inferred": inferred.toNames(), "direct": direct.toNames(),
            "declared": [String](), "undeclared": [String](), "overdeclared": [String](),
            "unresolved": unresolved,
            "hash": hash,                       // 0.5 MUST: every report is chainable
            "calls": calls,
        ]
        if entryPoint { e["entryPoint"] = true }
        if let k = unitKind { e["unitKind"] = k }   // spec 0.5 draft, informative
        if let w = unknownWhy, !w.isEmpty { e["unknownWhy"] = w }
        if let h = hosts, !h.isEmpty { e["hosts"] = h }
        if let c = cmds, !c.isEmpty { e["cmds"] = c }
        if let p = paths, !p.isEmpty { e["paths"] = p }
        if let t = tables, !t.isEmpty { e["tables"] = t }
        if let v = invisible, !v.isEmpty { e["invisible"] = v }
        return e
    }
}
// The §2 envelope: provenance + the package + the effectors.
struct Report {
    let provenance: Provenance, package: String, effectors: [Effector]
    func toJSON() -> [String: Any] {
        ["candor": provenance.toJSON(), "package": package, "functions": effectors.map { $0.toJSON() }]
    }
}

func writeJson(_ obj: Any, _ path: String) {
    // A write failure (read-only FS, no space, a non-existent --out dir, EACCES) used to `try!`-TRAP
    // here — AFTER the whole scan completed — exiting with SIGILL and no message. Fail LOUD instead:
    // name the path and the cause, exit 1, so CI sees a real error rather than a crash signal.
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    } catch {
        // DEFENSIVE, deliberately uncovered (TESTING.md §6): the envelope is built in-process from
        // String/Bool/[String] values only, which always serialize — this arm exists so a future
        // non-plist value fails loud instead of trapping, and no test can reach it without mocks.
        FileHandle.standardError.write("candor-swift: could not serialize report for \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    // `.atomic`: Foundation writes to an auxiliary file and renames into place, so a concurrent reader
    // (a cross-engine candor-query / candor-ts merging this report as a sibling) never observes a
    // half-written file — the same write invariant the Rust and TS backends now hold (write_atomic).
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        FileHandle.standardError.write("candor-swift: could not write report to \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
