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
typealias GateViolation = (rule: String, fn: String, effects: [String], detail: String)
func writeGateVerdict(_ violations: [GateViolation], to path: String, spec: String,
                      coverage uncoveredModules: [String] = []) {
    var dict: [String: Any] = [
        "spec": spec,
        "ok": violations.isEmpty,
        "violations": violations.map { ["rule": $0.rule, "fn": $0.fn, "effects": $0.effects, "detail": $0.detail] as [String: Any] },
    ]
    // ⟨0.15 staged⟩ advisory coverage note (SPEC §2 `coverage` re-disclosure): when the scan's κ ledger
    // is non-empty, the verdict names the uncovered modules — VERDICT-PRESERVING (the ⟨0.9⟩ provable-purity
    // auto-disclosure precedent): ok/violations/exit are computed exactly as before, this field only ADDS.
    // A gate does NOT fail on uncovered deps (nearly every real scan has some); the policy author decides.
    if !uncoveredModules.isEmpty {
        dict["coverage"] = ["uncovered": uncoveredModules.count, "modules": uncoveredModules.sorted()] as [String: Any]
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

/// Evaluate a parsed §6.2 policy against the analysis maps — the SAME violation list drives the
/// console lines, --gate-json and the exit code, so they can never disagree.
func evaluateGate(_ pol: (deny: [DenyRule], allow: [AllowRule], forbid: [ForbidRule]),
                  inferred: [String: Set<String>],
                  hostsAcc: [String: Set<String>], cmdsAcc: [String: Set<String>],
                  pathsAcc: [String: Set<String>], tablesAcc: [String: Set<String>],
                  incompleteAcc: [String: Set<String>], cg: [String: [String]],
                  reasonClassAcc: [String: Set<String>] = [:]) -> [GateViolation] {
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
                // whose TRANSITIVE reason classes include one of those; no recorded reason ⇒ `unresolved`.
                if hits.contains("Unknown"), !r.unknownClasses.isEmpty {
                    let fnClasses = reasonClassAcc[qual].map { $0.isEmpty ? ["unresolved"] : Array($0) } ?? ["unresolved"]
                    if !fnClasses.contains(where: { r.unknownClasses.contains($0) }) {
                        hits.removeAll { $0 == "Unknown" }
                    }
                }
                if !hits.isEmpty {
                    gateViolations.append((rule: "AS-EFF-006", fn: qual, effects: hits,
                        detail: "`\(qual)` performs { \(hits.joined(separator: ", ")) }, forbidden by policy: `\(r.raw)`"))
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
                    gateViolations.append((rule: "AS-EFF-008", fn: qual, effects: [r.effect], detail: "`\(qual)` \(why): `\(r.raw)`"))
                } else {
                    let bad = surface.filter { !literalAllowed(r.effect, $0, r.values) }.sorted()
                    if !bad.isEmpty {
                        gateViolations.append((rule: "AS-EFF-008", fn: qual, effects: [r.effect],
                            detail: "`\(qual)` reaches { \(bad.joined(separator: ", ")) } outside the allowlist: `\(r.raw)`"))
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
                            detail: "`\(fn)` (scope `\(r.from)`) transitively reaches `\(cur)` in forbidden scope `\(r.to)`: `\(r.raw)`"))
                        break
                    }
                    stack.append(contentsOf: cg[cur] ?? [])
                }
            }
        }
    return gateViolations
}
