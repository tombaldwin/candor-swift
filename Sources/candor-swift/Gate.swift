// candor-swift — §6.2 gate EXECUTION (report → violations) + the §3.3 structured verdict.
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation
import CandorCore

// ════════════════════════════════════════════════════════════════════════════════════════════════
// §6.2 policy gate (deny / pure / allow / forbid)
// The PURE parser + literal matchers (parsePolicy / scopeMatches / hostPart / pathCovered /
// dbTableCovered / literalAllowed) live in CandorCore/Policy.swift — token-for-token with the family
// parsers, directly unit-tested there; this file keeps only the gate EXECUTION (report → violations).
// ════════════════════════════════════════════════════════════════════════════════════════════════


// A structured gate violation (candor-spec §3.3 ⟨0.8⟩): `effects` is the specific effect set the violation
// concerns — the denied set (006), the allowed effect (008), or [] (009 layer-flow); `detail` is the message
// BODY (no `[AS-EFF-00x]` prefix — the rule carries the code). The console prints `[rule] detail`; --gate-json
// serializes the records verbatim. Written from the SAME list that sets the exit code, so it can't disagree.
// ⟨0.19⟩ `reasonClass`: on an AS-EFF-006 violation whose `effects` include `Unknown`, all reason classes
// present (transitively) on the fn — every reason the strict gate bit (SPEC §6.2). Empty otherwise.
// ⟨0.20⟩ `netClass`: on an AS-EFF-006 violation whose `effects` include `Net`, all destination classes
// present (transitively) on the fn — which class the security gate bit (NET-DESTINATION-CLASS-DESIGN.md).
typealias GateViolation = (rule: String, fn: String, effects: [String], detail: String, reasonClass: [String], netClass: [String])
func writeGateVerdict(_ violations: [GateViolation], to path: String, spec: String,
                      analyzedCount: Int,
                      unanalyzed: [(path: String, reason: String)] = [],
                      coverage uncoveredModules: [String] = [],
                      policyVocabulary: (config: String, aliases: [String])? = nil) {
    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): a gate over source candor could NOT analyze must NOT read green —
    // its effects are invisible, so a `deny`/`allow` that "passes" over it is a false-pure. `ok` requires
    // BOTH no violation AND a complete analysis (the caller exits 2 on this incomplete-but-clean path).
    let incomplete = !unanalyzed.isEmpty
    var dict: [String: Any] = [
        "spec": spec,
        "ok": violations.isEmpty && !incomplete,
        // ⟨0.21⟩ (Gap 1) the analyzed-universe count, so a --gate-json consumer sees the scan's scope from the
        // verdict alone (mirrors the report envelope's `analyzed`). ALWAYS present.
        "analyzed": ["count": analyzedCount] as [String: Any],
        "violations": violations.map { v -> [String: Any] in
            var m: [String: Any] = ["rule": v.rule, "fn": v.fn, "effects": v.effects, "detail": v.detail]
            if !v.reasonClass.isEmpty { m["reasonClass"] = v.reasonClass }  // omitted when empty (byte-compat)
            if !v.netClass.isEmpty { m["netClass"] = v.netClass }           // ⟨0.20⟩ omitted when empty
            return m
        },
    ]
    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): the machine-legible incompleteness — the units candor couldn't
    // analyze, so a CI/agent reading the JSON learns WHY the gate can't certify (the stderr line alone hid
    // this from a machine). `incomplete:true` + the list; the caller exits 2 (could-not-fully-evaluate).
    if incomplete {
        dict["incomplete"] = true
        dict["unanalyzed"] = unanalyzed.map { ["path": $0.path, "reason": $0.reason] as [String: Any] }
    }
    // ⟨0.15 staged⟩ advisory coverage note (SPEC §2 `coverage` re-disclosure): when the scan's κ ledger
    // is non-empty, the verdict names the uncovered modules — VERDICT-PRESERVING (the ⟨0.9⟩ provable-purity
    // auto-disclosure precedent): ok/violations/exit are computed exactly as before, this field only ADDS.
    // A gate does NOT fail on uncovered deps (nearly every real scan has some); the policy author decides.
    // ⟨0.24⟩ SPEC §3.1 pins the VERDICT's coverage block as `{ "uncovered": <n>, "packages": [ … ] }`, and
    // until 2026-07-28 this document never said so. §2 defines the REPORT's ledger — `coverage.uncovered`
    // as an ARRAY of `{name, calls}` — which is a DIFFERENT shape from the verdict's (a count plus a name
    // list), so the verdict shape was never pinned and the engines diverged unobserved: rust and ts emit
    // `packages`, this engine emitted `modules`, and the single prose mention in §3.1 said `modules` too,
    // because it was written describing THIS engine's output. `packages` is correct, and NOT because it is
    // three-to-one: the §2 envelope names the very same objects `package`/`packages`, so a verdict that
    // renames them mid-document is drift, and `module` already means a different thing in two of the four
    // implementation languages (a compilation unit, which is not what is being counted).
    if !uncoveredModules.isEmpty {
        dict["coverage"] = ["uncovered": uncoveredModules.count, "packages": uncoveredModules.sorted()] as [String: Any]
    }
    // ⟨0.24⟩ THE AMBIENCE IS DISCLOSED (SPEC §3.1): if a config file supplied VOCABULARY that participated
    // in this verdict — today `unknown-alias`, the only key that expands a policy token — the document
    // NAMES that file AND the aliases it supplied. Config discovery walks parent directories, so an alias
    // file anywhere above the policy participates; a verdict changed by a file the operator cannot see
    // named in the output is the ambient-input failure this format exists to refuse. Present only when the
    // vocabulary was actually CONSUMED: a config that defines aliases nobody asked for is not an input to
    // this verdict, and naming it unconditionally is noise a reader learns to ignore.
    //
    // KEY AND SHAPE ARE FOUR-WAY, not this engine's choice. It shipped here for one commit as a
    // `configSources` string list; conformance PART 27 R9's key-parity arm — added the same day, because
    // WITHIN-engine byte-equality is structurally blind to a key every route of one engine spells the same
    // wrong way — measured java and ts on `policyVocabulary: {config, aliases}`, rust on `vocabulary`, and
    // swift on `configSources`. Three names for one field, and none of them wrong on its own.
    if let pv = policyVocabulary, !pv.aliases.isEmpty {
        dict["policyVocabulary"] = ["config": pv.config, "aliases": pv.aliases.sorted()] as [String: Any]
    }
    if path == "-" {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) { print(s) }
    } else {
        // The verdict is a SURFACING side-output and MUST NOT change the gate's exit code — writeJson's
        // failure path exits 1, which turned a PASSING gate into a red check when the path was unwritable
        // (max-review find). One stderr line instead; the process keeps the gate's true exit.
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            FileHandle.standardError.write("candor-swift: could not write --gate-json \(path): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
}

/// ⟨0.24⟩ THE REFUSAL DOCUMENT (SPEC §3.1) — what `--gate-json` gets when the gate REFUSES.
///
/// **THE STALE-VERDICT HAZARD.** A refusal used to write nothing at all, so the canonical CI wrapper
/// (`candor-swift gate … --gate-json v.json || true` then `jq .ok v.json`) re-read **the PREVIOUS run's
/// document as current** — a green file from yesterday's clean run, still on disk, is how a refusal
/// becomes an all-clear. Deleting the path is not the fix either: a consumer that treats a missing file
/// as "nothing to report" fails open by a different route. The only safe answer is a document whose
/// NAIVE read is the fail-closed one, because the naive read is the one that ships.
///
/// `ok: false` so a consumer keying only on `ok` lands on FAIL; `refused: true` + `reason` so one keying
/// on `refused` learns why. **NO `violations` KEY, and that absence is load-bearing**: the gate is making
/// no claim about violations here, and `[]` is precisely the claim it cannot make — every consumer in
/// existence reads an empty array as "we looked and found none". ABSENT, not empty.
///
/// A failure to WRITE is not escalated: the exit is already 2 and already fail-closed, and a second exit
/// code would be a lie about which refusal happened. It is disclosed on stderr naming the stale-read
/// consequence, because that is the one thing the operator can act on.
/// ⟨0.24⟩ Where a refusal document goes, set by whichever CLI parsed `--gate-json` / `--json`. Module-wide
/// because THE REFUSAL DOCUMENT HAS NO EXEMPT CAUSE (SPEC §3.1, candor-spec `1503368`): an unreadable
/// policy, a broken `.candor/config` and an invalid baseline all leave the same stale document on disk as
/// an answerability refusal does, and a stale green does not care why this run declined to overwrite it.
/// Those causes are raised in files that never see the gate's own choreography, so the sink travels
/// instead of the plumbing. EMPTY until a CLI sets it, which is what keeps a pre-flag usage error (where
/// `--gate-json`'s value is not yet known, or is the thing being rejected) from writing anywhere.
///
/// `nonisolated(unsafe)` because this is a single-threaded CLI process: the value is written once, by the
/// verb's flag loop, before any work begins, and read only on the way out.
nonisolated(unsafe) var gateVerdictSinks: [String] = []

/// Print the reason, write the refusal document to every requested sink, exit 2.
func refuseGateAndExit(_ reason: String) -> Never {
    FileHandle.standardError.write((reason + "\n").data(using: .utf8)!)
    for t in gateVerdictSinks { writeGateRefusal(reason, to: t, spec: specVersion) }
    exit(2)
}

func writeGateRefusal(_ reason: String, to path: String, spec: String) {
    let dict: [String: Any] = ["spec": spec, "ok": false, "refused": true, "reason": reason]
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write("candor-swift: could not serialize the refusal document\n".data(using: .utf8)!)
        return
    }
    if path == "-" { print(text); return }
    do {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        FileHandle.standardError.write(
            ("candor-swift: could not write the refusal document to --gate-json \(path): "
             + "\(error.localizedDescription) — a consumer reading that path will see the PREVIOUS run's "
             + "verdict, which is stale. Delete it, or treat exit 2 as a failure.\n").data(using: .utf8)!)
    }
}

/// ⟨0.24⟩ THE GATE'S INPUT — the seam between "what produced the signature" and "what §6.2 does with it".
/// Every field is ALREADY ACCUMULATED (transitive): the gate runs no fixpoint and reads no scan state, so
/// the same matching code serves both routes in.
///
/// `gateInputFromScan` builds it from the classifier's live maps (the reason-class fixpoint and the
/// per-fn `netClassesOf` derivation that used to sit inline in the gate); `gateInputFromReport`
/// (GateReportCLI.swift) builds it from a WRITTEN report and nothing else. That split is the point of
/// SPEC §3.1 ⟨0.24⟩: until it existed the gate was reachable only THROUGH the classifier, so a defect in
/// the gate and a defect in the classifier were indistinguishable from any test this repo could write.
/// Do NOT re-implement the §6.2 matching on the report side — the clause exists about exactly that
/// mistake (an open-coded second copy of a classification rule drifting from the gate's, silently,
/// because nothing compared them).
struct GateInput {
    /// per fn, the TRANSITIVE effect set — the model's `S`, with candor's `Unknown` marker carried as a
    /// member (this family's encoding of `D ≠ ∅`).
    let inferred: [String: Set<String>]
    /// per fn, the TRANSITIVE reason-class tokens — the model's `D` (SPEC §6.2 ⟨0.19⟩).
    let reasonClasses: [String: Set<String>]
    /// per Net-bearing fn, its ⟨0.20⟩ destination classes, ALREADY derived (scan: `netClassesOf`;
    /// report: the wire's `netClass`, verbatim).
    let netClasses: [String: [String]]
    /// per fn, the TRANSITIVE literal surface AS-EFF-008 certifies.
    let hosts: [String: Set<String>], cmds: [String: Set<String>]
    let paths: [String: Set<String>], tables: [String: Set<String>]
    /// per fn, the effects whose literal surface is structurally incomplete — the AS-EFF-008 fail-closed
    /// marker. It does NOT ride the ⟨0.24⟩ wire, which is why `gate --report` refuses every `allow` rule.
    let surfaceIncomplete: [String: Set<String>]
    /// the call graph AS-EFF-009 walks.
    let edges: [String: [String]]
}

/// The SCAN route into the gate: the classifier's live maps, plus the two derivations the gate used to
/// run inline. Behaviour-preserving — `netClassesOf` was only ever asked for a fn that HAS `Net` (it is
/// the `deny` membership that triggers it), so materializing exactly those is the same set of answers.
func gateInputFromScan(inferred: [String: Set<String>],
                       whyMap: [String: Set<String>],
                       direct: [String: Set<String>],
                       edges: [String: Set<String>], cg: [String: [String]],
                       hostsAcc: [String: Set<String>], cmdsAcc: [String: Set<String>],
                       pathsAcc: [String: Set<String>], tablesAcc: [String: Set<String>],
                       incompleteAcc: [String: Set<String>],
                       netPartners: Set<String>) -> GateInput {
    // Reason-scoped Unknown (REASON-SCOPED-UNKNOWN-DESIGN.md): the Unknown reason CLASS must travel the
    // call graph the same way the Unknown EFFECT does (whyMap is direct-only). Classify each fn's direct
    // reasons to class tokens, then propagate transitively — so `deny E Unknown[reflect]` at a caller
    // inheriting Unknown from a reflect-caused callee still fires (matches java/rust/ts reasonClassAcc).
    var reasonClassDirect: [String: Set<String>] = [:]
    for (fn, whys) in whyMap where !whys.isEmpty {
        reasonClassDirect[fn] = Set(whys.map { reasonClass($0) })
    }
    // ⟨0.24⟩ §6.2's CONTRIBUTION, applied HERE rather than in the matcher (SPEC §3.1, candor-spec
    // `5a8cf48`). A function that raises `Unknown` DIRECTLY and names no reason for it contributes
    // `unresolved` — at the ENTRY, BEFORE the fixpoint, which is what makes it COMPOSE and is exactly what
    // `gateInputFromReport` does on the other route. The floor used to live in `evaluateGate` instead
    // (`fnClasses = classes.isEmpty ? ["unresolved"] : …`), and that is the wrong place for it: a
    // fail-closed default is not portable between a predicate that GUARDS and one that CHARGES. As a
    // guard it made the matcher conservative; as grounds to EMIT a violation it asserted a reason nobody
    // recorded. Same shape as `netClassesOf` below, which has always floored at `unknown-host` in the
    // INPUT rather than in the match.
    //
    // Gated on a DIRECT `Unknown` the function did not name, never on the reason set being empty:
    // emptiness is also what an INHERITED `Unknown` looks like, and marking those is the mirror
    // fabrication. On this route the guard is belt-and-braces — over 14 real targets / 12 004 entries,
    // 0 carry a direct `Unknown` without an `unknownWhy` (§4's invariant, pinned by
    // UnknownMarkerInvariantProcessTests) — but it is what lets the matcher stop flooring at all.
    for (fn, d) in direct where d.contains("Unknown") && (whyMap[fn]?.isEmpty ?? true) {
        reasonClassDirect[fn, default: []].insert("unresolved")
    }
    var netClasses: [String: [String]] = [:]
    for (qual, inf) in inferred where inf.contains("Net") {
        netClasses[qual] = netClassesOf(Array(hostsAcc[qual] ?? []),
                                        netIncomplete: incompleteAcc[qual]?.contains("Net") ?? false,
                                        partners: netPartners)
    }
    return GateInput(inferred: inferred,
                     reasonClasses: propagate(reasonClassDirect, over: edges),
                     netClasses: netClasses,
                     hosts: hostsAcc, cmds: cmdsAcc, paths: pathsAcc, tables: tablesAcc,
                     surfaceIncomplete: incompleteAcc, edges: cg)
}

/// Evaluate a parsed §6.2 policy against an ALREADY-ACCUMULATED signature — the SAME violation list
/// drives the console lines, --gate-json and the exit code, so they can never disagree. THE ONLY §6.2
/// matching code in this engine: `scan --policy` and `gate --report` both land here, which makes "the
/// same verdict from the same signature" a property of the code rather than of two consistent authors.
func evaluateGate(_ pol: ParsedPolicy, _ gi: GateInput) -> [GateViolation] {
    let inferred = gi.inferred
    let hostsAcc = gi.hosts, cmdsAcc = gi.cmds, pathsAcc = gi.paths, tablesAcc = gi.tables
    let incompleteAcc = gi.surfaceIncomplete, cg = gi.edges, reasonClassAcc = gi.reasonClasses
    var gateViolations: [GateViolation] = []
        for qual in inferred.keys.sorted() {
            let inf = inferred[qual] ?? []
            if inf.isEmpty { continue }
            for r in pol.deny where scopeMatches(qual, r.scope) {
                // `pure` (empty forbidden set) forbids every EFFECT — not `Unknown`, the §4 trust
                // marker (AS-EFF-003's concern; `deny Unknown <scope>` is the explicit knob). The
                // reference engine, the rust engines and candor-ts exclude it identically; this
                // engine wrongly counted an Unknown-only fn as a `pure` violation until 2026-07-09.
                var hits = r.effects.isEmpty ? inf.sorted().filter { $0 != "Unknown" }
                                             : inf.sorted().filter { r.effects.contains($0) }
                // Reason-scoped Unknown: a `deny E Unknown[classes]` keeps its Unknown hit only for a fn
                // whose TRANSITIVE reason classes include one of those.
                //
                // ⟨0.24⟩ **NO FLOOR HERE — THE MATCHER MUST NOT CHARGE ON A DEFAULT** (SPEC §3.1,
                // candor-spec `5a8cf48`). This line used to read
                // `reasonClassAcc[qual].map { $0.isEmpty ? ["unresolved"] : … } ?? ["unresolved"]`, and
                // while the answerability refusal SHORT-CIRCUITED before the gate ran, the floor was
                // unreachable on the one route where an empty set is possible. Removing that
                // short-circuit (the precedence fix) made it reachable, and MEASURED it FABRICATED: a
                // scoped `deny Unknown[unresolved]` over an entry whose `Unknown` is INHERITED and
                // reasonless emitted an actual violation RECORD naming that function — in the same run
                // whose stderr said the rule could not be evaluated over it. A self-contradicting
                // document, and a soundness fix was what made it reachable.
                //
                // A fail-closed default is not portable between a predicate that GUARDS and one that
                // CHARGES. The `unresolved` default is still applied — at the ENTRY, in
                // `gateInputFromScan` / `gateInputFromReport`, gated on a DIRECT `Unknown` the function
                // did not name — where it composes and where it is evidenced. An EMPTY set here means the
                // match is not evidenced by this function's own entry, so the rule is WITHHELD on this
                // (rule, function) pair and disclosed by the caller. Withholding is per (rule, function),
                // never whole-policy: the same rule may fire on one function and be withheld on another.
                if hits.contains("Unknown"), !r.unknownClasses.isEmpty {
                    let fnClasses = reasonClassAcc[qual] ?? []
                    if !fnClasses.contains(where: { r.unknownClasses.contains($0) }) {
                        hits.removeAll { $0 == "Unknown" }
                    }
                }
                // Net destination-class: a `deny Net[dest…]` keeps its Net hit only for a fn reaching one of
                // those destination classes; else tolerate (only asserted-safe destinations). Fail-closed: a
                // masked surface / a Net with no visible host is unknown-host. ⟨0.24⟩ the class set is
                // ALREADY DERIVED in `gi.netClasses` — from the transitive hostsAcc + incompleteAcc on the
                // scan route, and read verbatim off the wire's `netClass` on the `gate --report` route.
                // An EMPTY set here cannot mean "no destinations": `netClassesOf` floors at unknown-host, and
                // the report route refuses a scoped rule over an entry whose field is absent (GateReportCLI).
                if hits.contains("Net"), !r.netClasses.isEmpty {
                    let fnNet = gi.netClasses[qual] ?? []
                    if !fnNet.contains(where: { r.netClasses.contains($0) }) {
                        hits.removeAll { $0 == "Net" }
                    }
                }
                if !hits.isEmpty {
                    // When Unknown is denied, report ALL reason classes on the fn (transitive) — every reason bit.
                    let rc = hits.contains("Unknown") ? (reasonClassAcc[qual].map { $0.sorted() } ?? []) : []
                    // ⟨0.20⟩ when Net is denied, report ALL of the fn's destination classes (transitive).
                    let nc = hits.contains("Net") ? (gi.netClasses[qual] ?? []) : []
                    gateViolations.append((rule: "AS-EFF-006", fn: qual, effects: hits,
                        detail: "`\(qual)` performs { \(hits.joined(separator: ", ")) }, forbidden by policy: `\(r.raw)`",
                        reasonClass: rc, netClass: nc))
                }
            }
            for r in pol.allow where scopeMatches(qual, r.scope) && inf.contains(r.effect) {
                let surface: Set<String>
                switch r.effect {
                // `Llm` ⟨0.13⟩ rides Net's host literal (SPEC §1) — `allow Llm <host…>` restricts which MODEL
                // hosts a scope may reach, matched by hostname like Net. The reached surface is the SAME
                // captured Net hosts (a model host WAS captured as a Net host literal).
                case "Net", "Llm": surface = hostsAcc[qual] ?? []
                case "Exec": surface = cmdsAcc[qual] ?? []
                case "Db": surface = tablesAcc[qual] ?? []
                default: surface = pathsAcc[qual] ?? []
                }
                // An INCOMPLETE surface — a host-establishing Net call with a structurally-invisible host —
                // can't be certified even when visible hosts cover the allowlist, else the benign literal MASKS
                // the invisible forbidden endpoint (the masking gate-evasion; candor-java 0.5.29 / rust / ts).
                // `Llm`'s incompleteness keys off "Net" (its surface IS the Net host surface): a runtime/masked
                // host marks Net incomplete → `allow Llm` fails closed too, so a benign visible model host can't
                // mask a runtime model host (candor-java's `incompleteAsLlm`; parity decision #3).
                let incompleteKey = r.effect == "Llm" ? "Net" : r.effect
                let surfaceIncomplete = incompleteAcc[qual]?.contains(incompleteKey) ?? false
                if surface.isEmpty || surfaceIncomplete {
                    // Two distinct failures share AS-EFF-008: no literal AT ALL, vs the MASKING case where a
                    // visible literal exists but coexists with a structurally-invisible endpoint it can't cover for.
                    let why = surface.isEmpty
                        ? "performs \(r.effect) with no visible literal — the surface cannot be certified"
                        : "reaches a structurally-invisible \(r.effect) endpoint a visible literal cannot mask"
                    gateViolations.append((rule: "AS-EFF-008", fn: qual, effects: [r.effect], detail: "`\(qual)` \(why): `\(r.raw)`", reasonClass: [], netClass: []))
                } else {
                    let bad = surface.filter { !literalAllowed(r.effect, $0, r.values) }.sorted()
                    if !bad.isEmpty {
                        gateViolations.append((rule: "AS-EFF-008", fn: qual, effects: [r.effect],
                            detail: "`\(qual)` reaches { \(bad.joined(separator: ", ")) } outside the allowlist: `\(r.raw)`", reasonClass: [], netClass: []))
                    }
                }
            }
        }
        for r in pol.forbid {
            for fn in cg.keys.sorted() where scopeMatches(fn, r.from) {
                var seen: Set<String> = [fn], stack = cg[fn] ?? []
                while let cur = stack.popLast() {
                    if !seen.insert(cur).inserted { continue }
                    if scopeMatches(cur, r.to) {
                        gateViolations.append((rule: "AS-EFF-009", fn: fn, effects: [],
                            detail: "`\(fn)` (scope `\(r.from)`) transitively reaches `\(cur)` in forbidden scope `\(r.to)`: `\(r.raw)`",
                            reasonClass: [], netClass: []))
                        break
                    }
                    stack.append(contentsOf: cg[cur] ?? [])
                }
            }
        }
    return gateViolations
}
