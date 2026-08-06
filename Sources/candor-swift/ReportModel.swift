// candor-swift — the candor domain model (candor-spec/MODEL.md) + the atomic JSON writer.
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation
import CandorCore

// The domain model's EFFECT VOCABULARY (the `Effect` enum + `EffectSet`) now lives in
// CandorCore/EffectVocabulary.swift so a unit test can reach it; see that file for why.

// Which engine produced a report and which contract it conforms to (§2.1).
struct Provenance {
    let version: String, toolchain: String, spec: String
    func toJSON() -> [String: Any] { ["version": version, "toolchain": toolchain, "spec": spec] }
}
// The per-unit report entry (§2). candor-swift is ANALYZE-ONLY: it runs §1–§4 (what effects a function
// performs) and NOT §5 (whether the signature declares them, via a capability parameter). So it never
// computes `declared`/`undeclared`/`overdeclared`, and per SPEC §2 ⟨0.26⟩ it must OMIT them.
//
// It used to emit all three as `[]` "for cross-engine schema parity". That is a positive claim: an empty
// `undeclared` reads as "this function performs no undeclared effect" — an AS-EFF-001 all-clear from a
// pass that never ran, which is ⟨0.21⟩'s absence-is-a-claim rule one layer up. The old comment named the
// cause honestly and then did it anyway, and the cause was a SCHEMA-PARITY CHECK: requiring an OPTIONAL
// field buys agreement on shape with a claim nobody computed. The spec rule now forbids both halves.
struct Effector {
    let fn: String, loc: String
    let inferred: EffectSet, direct: EffectSet
    let unresolved: Bool, hash: String, calls: [String]
    var entryPoint = false
    var unitKind: String? = nil
    var unknownWhy: [String]? = nil
    var hosts: [String]? = nil, cmds: [String]? = nil, paths: [String]? = nil, tables: [String]? = nil
    /// The effects whose LOCATOR this function could not determine, DIRECTLY — its own file write whose
    /// path is a parameter, its own exec whose command is computed. Omitted when empty, so a scan that
    /// determined everything stays byte-identical to one from before the field existed.
    ///
    /// Distinct from `paths`, which is PROPAGATED: a function inherits its callees' paths, so `paths`
    /// being non-empty says only that something downstream named a literal. A privacy verify asking
    /// "could this function's own destination be a protected folder" was answering with the transitive
    /// view and could be masked to silence by one logger anywhere in the call graph.
    var incomplete: [String]? = nil
    /// SPEC §2 `fs` — the read/write kinds of THIS function's own Fs calls, when their verbs said.
    /// Optional and omitted when empty, which is the spec's rule and not an optimisation: an empty or
    /// partial `fs` reads as "reads but never writes", a positive claim in the forbidden direction.
    var fs: [String]? = nil
    /// `privacy/2` — per privacy effect, the read/write directions this function's own calls revealed.
    /// Extension-scoped (the envelope discloses `privacy/2`), omitted when empty on the same rule as `fs`:
    /// an absent direction means undetermined, never "reads but never writes".
    var privacy: [String: [String]]? = nil
    var invisible: [String]? = nil   // per-fn blind-spot disclosure: κ-unknown modules reached (qualifies `inferred`)
    var netClass: [String]? = nil    // ⟨0.20⟩ Net destination classes present in the fn's transitive Net surface
    var interfaceUnion = false       // ⟨workspace-chain⟩ synthetic protocol-CHA union entry (not an analyzed unit)
    func toJSON() -> [String: Any] {
        var e: [String: Any] = [
            "fn": fn, "loc": loc,
            "inferred": inferred.toNames(), "direct": direct.toNames(),
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
        if let i = incomplete, !i.isEmpty { e["incomplete"] = i }
        if let t = tables, !t.isEmpty { e["tables"] = t }
        if let k = fs, !k.isEmpty { e["fs"] = k }
        if let pk = privacy, !pk.isEmpty { e["privacy"] = pk }
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
    // ⟨0.23⟩ `typeSurface.returns` (SPEC §2, `DEP-RECEIVER-TYPING-DESIGN.md`): `<pkg>#<fn qual>` ->
    // `<pkg>#<type qual>`, both FULLY QUALIFIED in this package's own namespace — the same namespace the
    // entry hashes use, so a consumer forms `<pkg>#<type qual>.<method>` and asks the ordinary chained
    // lookup. OMITTED when empty, so a report with nothing to say is byte-identical to a pre-rung one and
    // a 0.22 consumer is unaffected. Set in main.swift from `analysis.typeSurfaceReturns`.
    var typeSurfaceReturns: [String: String] = [:]
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
        // privacy/2: the vocabulary GREW (six sensors → eighteen), so the version moves with it. A
        // consumer that understands `privacy/1` expects exactly six effect names; emitting `Health` under
        // that label would make the extension's own positive declaration inaccurate — the same
        // absence-is-a-claim failure the sidecar manifest rung closed at ⟨0.26⟩.
        if privacyActive { env["extensions"] = [PRIVACY_EXTENSION_ID] }
        // ⟨0.27⟩ SPEC §2.1 `resolves`: the OPTIONAL refinement surfaces this producer computes. Without it
        // an absent `fs` is overloaded between "does not compute kinds" and "computed and could not
        // determine one", and a consumer cannot read the omission. A producer MUST NOT list a surface it
        // does not compute — that turns "unimplemented" into a false "undetermined".
        env["resolves"] = ["fs"]
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
        // ⟨0.23⟩ the factory-bound receiver's type surface — omitted when empty (see above).
        if !typeSurfaceReturns.isEmpty { env["typeSurface"] = ["returns": typeSurfaceReturns] }
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
