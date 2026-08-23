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
    // ⟨0.29⟩ THE SCOPE — what this scan chose NOT to open, by class (candor-spec/FILE-SET-DESIGN.md).
    // `analyzed.count` is a NUMERATOR; the file selection that produced it appeared nowhere, so a consumer
    // could not tell whether the answer was to the question they asked. Every exclusion this engine makes
    // is deliberate (`isHarnessPath`, `isTestSource`, a `--target` closure) — and being deliberate is
    // precisely why none of them was measured: a limitation written as a comment reads as CONSIDERED.
    //
    // CLASSES WITH COUNTS, never file lists: `.build/` is unbounded, and a gate that prints thousands of
    // paths is one people scroll past. ALWAYS emitted, `[]` included — ⟨0.27⟩ makes a zero-match a positive
    // statement, and ⟨0.26⟩ makes an ABSENT key mean "this producer cannot answer", which is a different
    // claim from "nothing was excluded". Set in main.swift from the walk itself.
    //
    // `peeked` is the load-bearing half of the pair with `outOfScope`. An empty `outOfScope` says "I read
    // the excluded files and none held an effect this policy denies" — a claim it may make only about the
    // classes it actually read. This engine does NOT read `.build/`, and candor-java cannot read a `.java`
    // that was never compiled; without the flag both would be certifying files nobody opened, which is the
    // ⟨0.26⟩ partial-manifest failure exactly — a partial answer worse than an absent one.
    // ⟨0.32⟩ `judgedElsewhere` — the files of this class are COPIES of code this same scan already
    // judged, so the class hides nothing and does not make the verdict INCOMPLETE. `build-output` is
    // the case that forces it here: `.build/` is held out of the PEEK as well as the scan
    // (`PEEKED_CLASSES`), so without this flag every SPM project with a build directory would refuse
    // on contact. Producer-set on purpose — a consumer cannot infer it from the class token, which is
    // engine-chosen (the same concept is `build-output-archive` in candor-java), and the distinction
    // is not cosmetic: rust's `build-script` is code that RUNS and must fail closed.
    var excluded: [(cls: String, count: Int, peeked: Bool, judgedElsewhere: Bool, reason: String)] = []
    // ⟨0.29⟩ what the PEEK found in those files: an effect the policy DENIES, in a file the gate did not
    // judge. NIL (key omitted) when no policy was configured — nothing was asked, so `[]` would be a claim.
    // EMPTY when a policy was configured and the excluded files were clean under it.
    //
    // NEVER A `violation`. Folding these into the gate would move verdicts and make an exit code depend on
    // a file the gate declined to judge — the opposite of what this rung promises.
    var outOfScope: [OutOfScopeFinding]? = nil
    // ⟨0.31⟩ the ambient `net-partner` declaration that MOVED a `netClass` — the config file that declared
    // it, and the declared hosts that actually PARTICIPATED. `hosts` is what participated, not what was
    // declared: a config listing twenty partners of which one matched discloses the one, because a list of
    // everything written down buries the line that moved the verdict. NIL (key omitted) when nothing
    // participated, so a project declaring no partners — or declaring some that never matched — is
    // byte-identical to a pre-rung report. Recorded by the PRODUCER because `gate --report` has no target
    // to anchor `net-partner` at, and re-classifying through the consumer's own config is the
    // re-derivation ⟨0.24⟩ forbids; both routes copy this one record.
    var netPartners: (config: String, hosts: [String])? = nil
    // ⟨scope travels⟩ What `--target` resolved, when it resolved against an `.xcodeproj`. The report is
    // read LATER by `privacy-manifest --verify`, which has only a report and a plist — so everything the
    // scan learned about which binary this is has to be IN the artifact or it is lost. Today the verify
    // re-discovers `.entitlements` by walking the plist's directory and refuses to guess among several,
    // leaving entitlement-sourced keys unchecked on exactly the multi-target repos `--target` exists for.
    // OMITTED when empty, so an unscoped report and every other engine's are byte-unchanged.
    var scope: (target: String, project: String, entitlements: String?)?
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
        // ⟨0.29⟩ `incomplete` joins the list — an optional per-function refinement surface whose absence
        // is overloaded exactly the way `fs`'s was. This engine computes it, so it declares it.
        env["resolves"] = ["fs", "incomplete"]
        // ⟨scope travels⟩ see `scope` above. `entitlements` is present only when the target's
        // `CODE_SIGN_ENTITLEMENTS` named a file that EXISTS — absent means "not determined", never
        // "this target has none", which is the distinction a consumer has to be able to make.
        if let sc = scope {
            var d: [String: Any] = ["target": sc.target, "project": sc.project]
            if let e = sc.entitlements { d["entitlements"] = e }
            env["scope"] = d
        }
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
        // ⟨0.29⟩ THE SCOPE — ALWAYS emitted, `[]` included (see `excluded`). The one field in this
        // envelope whose EMPTY form is load-bearing: it says "I looked, and excluded nothing".
        env["excluded"] = excluded.map {
            {
                var m: [String: Any] = ["class": $0.cls, "count": $0.count, "peeked": $0.peeked,
                                        "reason": $0.reason]
                // Emitted only when TRUE: false is the default, and an always-present key would make
                // every pre-rung report differ over a fact that changes nothing.
                if $0.judgedElsewhere { m["judgedElsewhere"] = true }
                return m
            }($0) as [String: Any]
        }
        // ⟨0.29⟩ …and what the peek found in them. Omitted when nil — no policy, so no question was asked.
        if let oos = outOfScope { env["outOfScope"] = oos.map { $0.toJSON() } }
        // ⟨0.31⟩ after `outOfScope`, before `functions` — the position ts, rust and java also use, so key
        // order does not depend on which engine produced the report.
        if let np = netPartners { env["netPartners"] = ["config": np.config, "hosts": np.hosts] }
        return env
    }
}
// ⟨0.29⟩ AN EFFECT FOUND IN A FILE THE GATE DID NOT JUDGE (candor-spec/FILE-SET-DESIGN.md §5.2).
//
// Its own kind, beside `functions` and never inside it: the verdict does not move, so a reader can tell a
// warning about unjudged code from a violation in judged code. `class` is the exclusion class it came from
// (`harness-target`, `manifest`, …) so the reason for the exclusion and the finding travel together.
struct OutOfScopeFinding {
    let fn: String, path: String, effects: [String], cls: String, reason: String
    func toJSON() -> [String: Any] {
        ["fn": fn, "path": path, "effects": effects, "class": cls, "reason": reason]
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
