// candor-swift — the AS-EFF-005 baseline regression guard (SPEC §7 item 5, a per-engine MUST).
// Semantics mirror the reference engine (candor-java Policy.checkBaseline) exactly:
//
//   · ABSENT baseline file → a stderr note, guard inactive (ratchet not adopted), contributes 0.
//   · PRESENT but unparseable → exit 2 WITHOUT evaluating (corrupt report ≠ pure — the §6.2
//     unreadable-policy class; the old java code's fail-open note inverted the severity).
//   · MISSING or MISMATCHED producing version (envelope `candor.version` vs this build) → exit 2
//     WITHOUT evaluating: a baseline is comparable only to its OWN producing build (§2.1) —
//     evaluating a cross-build baseline yields a bogus AS-EFF-005 wave (coverage batches change
//     reports), and silently skipping is an unbounded fail-open window.
//   · Valid + same build → per-fn compare: an EXISTING fn gaining an effect not in the baseline is
//     [AS-EFF-005] (exit 1); a NEW fn is exempt (reviewed as new code, not a regression).
//
// Surfaced by CANDOR_BASELINE (env) and the `.candor/config` `baseline` key (relative value anchored
// to the config's home dir, like `policy`). Violations join the same list as the §6.2 gate's, so the
// console lines, --gate-json verdict and exit code can never disagree.

import Foundation

/// The baseline report's per-fn inferred sets — accepts BOTH the §2 envelope `{candor, functions}`
/// and the legacy v0.1 bare array (readers MUST accept both, SPEC §2). nil = unreadable/unparseable;
/// the caller distinguishes ABSENT via fileExists (mirroring candor-java Policy.loadBaseline).
func loadBaseline(_ path: String) -> [String: Set<String>]? {
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let arr: [Any]?
    if let obj = root as? [String: Any] { arr = obj["functions"] as? [Any] }
    else { arr = root as? [Any] }
    guard let arr else { return nil }
    var m: [String: Set<String>] = [:]
    for case let e as [String: Any] in arr {
        guard let fn = e["fn"] as? String, !fn.isEmpty else { continue }
        var effs: Set<String> = []
        for case let name as String in (e["inferred"] as? [Any]) ?? [] { effs.insert(name) }
        m[fn] = effs
    }
    return m
}

/// The baseline's PRODUCING engine build (the §2.1 envelope `candor.version`) — nil for the legacy
/// bare-array form or an unreadable header (no version comparison is then possible; absent provenance
/// is already the §2.1 "as unverifiable as a mismatch" case).
func baselineVersion(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          let root = try? JSONSerialization.jsonObject(with: data),
          let obj = root as? [String: Any],
          let candor = obj["candor"] as? [String: Any] else { return nil }
    return candor["version"] as? String
}

private func baselineFail(_ msg: String) -> Never {
    FileHandle.standardError.write("candor-swift: \(msg)\n".data(using: .utf8)!)
    exit(2)
}

/// ⟨0.16 staged⟩ The existence oracle for the AS-EFF-005 guard, keyed on the baseline CALLGRAPH sidecar
/// (`<baseline-stem>.callgraph.json` — SPEC §2.2 lists EVERY analyzed fn, pure leaves included, which the
/// report OMITS). Three outcomes, matching the guard's fail modes:
///   · `.absent`        — no sidecar next to the baseline report: the guard degrades to report-only
///                        existence (pre-⟨0.16⟩; a formerly-pure fn still reads as "new" and escapes) —
///                        the caller emits a stderr note and does NOT fail.
///   · `.loaded(nodes)` — the sidecar parsed: `nodes` is every fn in the graph (caller keys ∪ callees).
///                        A fn present here whose report entry is absent had a baseline effect set of ∅,
///                        so ANY current effect is a GAIN (the pure→effectful supply-chain shape).
///   · `.corrupt`       — the sidecar exists but could not be read/parsed: fail CLOSED (exit 2), exactly
///                        like a corrupt baseline report — a broken sidecar must not silently narrow the
///                        guard back to report-only. Absent ≠ corrupt.
/// This is the `gains` verb's `origin` existence rule (FixCLI.swift, ⟨0.12⟩ — base report OR callgraph
/// node ⇒ "existing") applied to the scan-time ratchet: same sidecar, same node-set union, same
/// disclose-don't-guess discipline (there absent/partial → "unknown"; here absent → degrade, corrupt →
/// fail). The one deliberate difference: `gains` scans a PREFIX (sibling `.callgraph.json` files); the
/// guard names an EXACT report file (CANDOR_BASELINE), so the sidecar is the single stem-derived sibling.
enum BaselineSidecar {
    case absent
    case loaded(Set<String>)
    case corrupt
}

/// Derive the sidecar path from a baseline REPORT path and load it. `<stem>.callgraph.json` — the same
/// stem→sidecar rule the writer uses (`<prefix>.<pkg>.Swift.json` → `<prefix>.<pkg>.Swift.callgraph.json`,
/// main.swift) and `loadCallgraphSidecars`'s single-`.json`-file arm.
func loadBaselineCallgraph(reportPath: String) -> BaselineSidecar {
    let sidecar = ((reportPath as NSString).deletingPathExtension) + ".callgraph.json"
    guard FileManager.default.fileExists(atPath: sidecar) else { return .absent }
    guard let data = FileManager.default.contents(atPath: sidecar),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return .corrupt
    }
    var nodes = Set(obj.keys)
    for callees in obj.values {
        for case let callee as String in (callees as? [Any]) ?? [] { nodes.insert(callee) }
    }
    return .loaded(nodes)
}

/// AS-EFF-005: the functions that GAINED an effect versus the saved baseline report, as gate
/// violations (rule/fn/effects/detail — `effects` is the GAINED set, not the fn's full set).
/// Exits 2 on invalid gate input (unparseable / versionless / cross-build baseline, and ⟨0.16 staged⟩
/// a corrupt callgraph sidecar); returns [] with a stderr note when the file is absent (guard not yet
/// adopted). ⟨0.16 staged⟩ Existence is keyed on the baseline callgraph sidecar when present, so a
/// formerly-PURE fn (omitted from the report) turning effectful is caught, not exempted as "new code".
/// ⟨0.16 staged⟩ A fn that gains ONLY Unknown (an unresolved call, no real effect) is ADVISORY, not a
/// violation: Unknown is the §4 trust marker (`pure` policies exclude it) and on version bumps it is
/// dominated by resolution noise — a single stderr note discloses it and the exit code is unchanged.
func checkBaseline(inferred: [String: Set<String>], path: String, engineVersion: String) -> [GateViolation] {
    // A configured-but-EMPTY value (bare `baseline` config line, CANDOR_BASELINE="") is invalid gate
    // input, not an un-adopted guard: the user declared a ratchet and named no file. java/scan/ts all
    // exit 2 here (verified 2026-07-10); swift briefly took the absent-file note path — family-aligned.
    if path.isEmpty {
        baselineFail("the baseline is configured but EMPTY (a bare `baseline` config line or an empty "
            + "CANDOR_BASELINE) — a configured gate source must name a file (exit 2, the "
            + "unreadable-policy class). Name a report path or remove the key.")
    }
    guard let base = loadBaseline(path) else {
        if !FileManager.default.fileExists(atPath: path) {
            FileHandle.standardError.write(("candor-swift: CANDOR_BASELINE \(path) does not exist — the "
                + "regression guard is not active (record one: candor-swift <target> --json > \(path)).\n").data(using: .utf8)!)
            return []
        }
        baselineFail("CANDOR_BASELINE \(path) exists but could not be parsed (corrupt/truncated?) — "
            + "failing (exit 2); the guard must not silently pass on an unreadable baseline (the "
            + "unreadable-policy class, §6.2). Regenerate it: candor-swift <target> --json > \(path)")
    }
    guard let baseVersion = baselineVersion(path) else {
        baselineFail("the baseline \(path) has no provenance header (a legacy/bare-array report) — a "
            + "baseline is comparable only to its producing build (§2.1). Failing (exit 2); regenerate "
            + "it with this build: candor-swift <target> --json > \(path)")
    }
    if baseVersion != engineVersion {
        baselineFail("the baseline \(path) was produced by engine build \(baseVersion) but this is "
            + "build \(engineVersion) — coverage batches change reports, so an engine swap is "
            + "baseline-invalidating and the gate cannot evaluate (exit 2, the unreadable-policy class; "
            + "never a silent skip, never a bogus AS-EFF-005 wave). Regenerate deliberately with this "
            + "build: candor-swift <target> --json > \(path)")
    }
    // ⟨0.16 staged⟩ Existence is keyed on the baseline CALLGRAPH sidecar (SPEC §7 item 5, the ⟨0.16⟩
    // paragraph). The report OMITS pure functions, so keying existence on the report alone lets a
    // formerly-PURE fn that turns effectful read as "new code" and escape the guard — the sharpest
    // supply-chain shape. The sidecar lists pure leaves, so a fn present there (baseline effect set ∅)
    // that now performs ANY effect is a GAIN. See loadBaselineCallgraph for the fail modes.
    let sidecarNodes: Set<String>
    switch loadBaselineCallgraph(reportPath: path) {
    case .loaded(let nodes):
        sidecarNodes = nodes
    case .corrupt:
        baselineFail("the baseline callgraph sidecar next to \(path) exists but could not be parsed "
            + "(corrupt/truncated?) — failing (exit 2), like a corrupt baseline; a broken sidecar must "
            + "not silently narrow the guard to report-only existence (§6.2). Regenerate the baseline "
            + "with this build: candor-swift <target> --out <prefix>")
    case .absent:
        // Pre-⟨0.16⟩ degradation: no sidecar → report-only existence (a formerly-pure fn reads as new
        // and escapes). Still catches an EXISTING fn widening its effect set. DISCLOSED, never silent.
        FileHandle.standardError.write(("candor-swift: note — no baseline callgraph sidecar next to "
            + "\(path); the AS-EFF-005 guard falls back to report-only existence, so a formerly-PURE "
            + "function turning effectful reads as new code and is NOT caught. Record the baseline with "
            + "`candor-swift <target> --out <prefix>` (writes the .callgraph.json sidecar) to close it.\n")
            .data(using: .utf8)!)
        sidecarNodes = []
    }

    var violations: [GateViolation] = []
    var unknownOnly: [String] = []   // ⟨0.16 staged⟩ advisory: fns that gained ONLY Unknown, no real effect
    for qual in inferred.keys.sorted() {
        // ⟨0.16 staged⟩ The baseline effect set: the report entry when present, else ∅ for a fn that is a
        // baseline callgraph node (it existed and was PURE — reports omit pure fns). A fn in NEITHER is
        // genuinely new code (an added function), still exempt.
        let prior: Set<String>
        if let reported = base[qual] { prior = reported }
        else if sidecarNodes.contains(qual) { prior = [] }   // existed at baseline, and was pure
        else { continue }                                    // new function — new code, not a regression
        let gained = (inferred[qual] ?? []).subtracting(prior).sorted()
        if gained.isEmpty { continue }
        // ⟨0.16 staged⟩ The ratchet fires only on gaining a REAL boundary effect. An Unknown-ONLY gain is
        // the §4 trust marker, not an effect (`pure` policies exclude it), and on real dependency bumps it
        // is dominated by resolution noise (SOUNDNESS-LOG 2026-07-16) — DISCLOSE it as advisory, never a
        // CI-breaking regression. A REAL gain (with or without Unknown alongside) is still a violation, and
        // the reported `effects` are the real set only (Unknown filtered from the shown effects).
        let real = gained.filter { $0 != "Unknown" }
        if real.isEmpty {
            unknownOnly.append(qual)
            continue
        }
        violations.append((rule: "AS-EFF-005", fn: qual, effects: real,
            detail: "`\(qual)` gained effect { \(real.joined(separator: ", ")) } not present in the baseline"))
    }
    if !unknownOnly.isEmpty {
        let shown = unknownOnly.prefix(3).joined(separator: ", ")
        let more = unknownOnly.count > 3 ? " (+\(unknownOnly.count - 3) more)" : ""
        FileHandle.standardError.write(("candor-swift: note — \(unknownOnly.count) function(s) gained an "
            + "unresolved call (Unknown) vs the baseline but no real effect — advisory, NOT a regression "
            + "(Unknown is the §4 trust marker, dominated by resolution noise on version bumps): "
            + "\(shown)\(more)\n").data(using: .utf8)!)
    }
    return violations
}
