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

/// AS-EFF-005: the functions that GAINED an effect versus the saved baseline report, as gate
/// violations (rule/fn/effects/detail — `effects` is the GAINED set, not the fn's full set).
/// Exits 2 on invalid gate input (unparseable / versionless / cross-build baseline); returns []
/// with a stderr note when the file is absent (guard not yet adopted).
func checkBaseline(inferred: [String: Set<String>], path: String, engineVersion: String) -> [GateViolation] {
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
    var violations: [GateViolation] = []
    for qual in inferred.keys.sorted() {
        guard let prior = base[qual] else { continue }   // new function — new code, not a regression
        let gained = (inferred[qual] ?? []).subtracting(prior).sorted()
        if !gained.isEmpty {
            violations.append((rule: "AS-EFF-005", fn: qual, effects: gained,
                detail: "`\(qual)` gained effect { \(gained.joined(separator: ", ")) } not present in the baseline"))
        }
    }
    return violations
}
