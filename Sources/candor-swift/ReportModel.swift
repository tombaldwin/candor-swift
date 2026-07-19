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
    case fs = "Fs", ipc = "Ipc", llm = "Llm", log = "Log", net = "Net", rand = "Rand", unknown = "Unknown"
    // `privacy/1` SPEC EXTENSION (SPEC-EXTENSION-privacy.md) — Apple privacy-sensor effects. Each is an
    // outside-world surface (a sensor / personal-data store / the user's attention) on the same footing as
    // Clipboard (main-spec §6.1): a boundary effect, high-salience, NOT allowlistable via a literal (there is
    // no host/path to certify — `deny Location`/containment yes, `allow Location <x>` no). The extension is
    // DISCLOSED in the envelope's `extensions` array when any of these appears (Report.privacyActive).
    case location = "Location", camera = "Camera", mic = "Mic", contacts = "Contacts", photos = "Photos", notify = "Notify"
    var specName: String { rawValue }
    static func from(_ name: String) -> Effect? { Effect(rawValue: name) }
}
// The `privacy/1` extension's effect NAMES (the six SPEC-EXTENSION-privacy.md effects). Used to detect
// whether the extension is active (any effector reaches one) so the envelope discloses `extensions`.
let PRIVACY_EFFECTS: Set<String> = ["Location", "Camera", "Mic", "Contacts", "Photos", "Notify"]
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
    var netClass: [String]? = nil    // ⟨0.20⟩ Net destination classes present in the fn's transitive Net surface
    var interfaceUnion = false       // ⟨workspace-chain⟩ synthetic protocol-CHA union entry (not an analyzed unit)
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
        if let n = netClass, !n.isEmpty { e["netClass"] = n }   // ⟨0.20⟩ Net destination-class (SPEC §1)
        if interfaceUnion { e["interfaceUnion"] = true }        // ⟨workspace-chain⟩ synthetic union entry
        return e
    }
}
// The §2 envelope: provenance + the package + the effectors (+ the ⟨0.15 staged⟩ coverage ledger).
struct Report {
    let provenance: Provenance, package: String, effectors: [Effector]
    // ⟨0.15 staged⟩ the κ-coverage ledger as DATA (SPEC §2 `coverage`): the same uncovered-module
    // list + import counts the stderr disclosure prints (§7 item 14), in the same order (count desc,
    // name asc), so "what the scan couldn't see" travels WITH the report instead of evaporating on
    // stderr. OMITTED entirely when empty — a fully-covered scan's report is byte-identical to a
    // pre-⟨0.15⟩ one (the `extensions`-field precedent). Swift counts IMPORTS; the wire field name
    // stays `calls` per the spec ("call/import count as the engine counts it").
    var coverage: [(name: String, calls: Int)] = []
    // ⟨0.21⟩ COMPLETENESS MANIFEST (COMPLETENESS-MANIFEST-DESIGN.md Gap 1): the analyzed-universe summary.
    // `count` = the total analyzed-fn set (every analyzed fn incl. pure leaves = allFns.count, NOT the
    // effectful-only `effectors` array), so a bare-envelope consumer computes `count − |functions|` = the
    // pure count and distinguishes analyzed-pure from never-seen. `digest` = an FNV-1a-64 fingerprint of the
    // sorted analyzed quals (same-engine re-scan agreement). ALWAYS emitted (the engine always enumerates
    // its analyzed set). Set in main.swift from `analysis.allFns`.
    var analyzed: (count: Int, digest: String)? = nil
    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): the target's own source candor could NOT read/parse — its effects
    // are absent because never seen, not because pure. OMITTED when empty (a complete scan is byte-identical
    // to a pre-rung report). Set in main.swift from `analysis.unanalyzed`.
    var unanalyzed: [(path: String, reason: String)] = []
    // Is the `privacy/1` extension ACTIVE — does any effector reach one of its six sensor effects (in its
    // inferred OR direct set)? Computed from the effectors so the envelope discloses the extension exactly
    // when one of its effects appears (SPEC-EXTENSION-privacy.md "Wire disclosure").
    var privacyActive: Bool {
        effectors.contains { ef in
            !ef.inferred.effects.isDisjoint(with: PRIVACY_EFFECTS_ENUM)
                || !ef.direct.effects.isDisjoint(with: PRIVACY_EFFECTS_ENUM)
        }
    }
    func toJSON() -> [String: Any] {
        var env: [String: Any] = ["candor": provenance.toJSON(), "package": package,
                                  "functions": effectors.map { $0.toJSON() }]
        // `privacy/1` wire disclosure (REQUIRED when active): a top-level `extensions` array. OMITTED when
        // no extension effect is active, so a plain report is byte-unchanged (SPEC-EXTENSION-privacy.md).
        if privacyActive { env["extensions"] = ["privacy/1"] }
        // ⟨0.15 staged⟩ `coverage` envelope field — omitted when nothing is uncovered (see above).
        if !coverage.isEmpty {
            env["coverage"] = ["uncovered": coverage.map { ["name": $0.name, "calls": $0.calls] as [String: Any] }]
        }
        // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 1): the analyzed-universe summary — ALWAYS present, so a consumer
        // of the bare envelope tells analyzed-pure from never-seen (pure count = analyzed.count − |functions|).
        if let a = analyzed {
            env["analyzed"] = ["count": a.count, "digest": a.digest] as [String: Any]
        }
        // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): the source candor could NOT analyze — OMITTED when empty (a
        // complete scan stays byte-identical), so a MACHINE reading --json sees the incompleteness a green
        // report used to hide on stderr alone.
        if !unanalyzed.isEmpty {
            env["unanalyzed"] = unanalyzed.map { ["path": $0.path, "reason": $0.reason] as [String: Any] }
        }
        return env
    }
}
// The `privacy/1` effects as `Effect` values — for the disjoint-set membership test in `privacyActive`
// (EffectSet stores `Set<Effect>`, so the test is against the enum, not the string names).
private let PRIVACY_EFFECTS_ENUM: Set<Effect> = Set(PRIVACY_EFFECTS.compactMap(Effect.from))

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
