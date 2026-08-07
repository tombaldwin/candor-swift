// SPEC §3.3.1 ⟨0.27⟩ — arming the `--gate-json` sink, and refusing to arm over an input.
//
// Two rules, both learned by getting them wrong:
//
//  * ARM AT THE INSTANT THE SINK IS KNOWN. Registering a sink is not arming — the sink only covers
//    refusals routed through `refuseGateAndExit`, so a crash, a kill, or any un-enumerated `exit(2)`
//    left the PREVIOUS run's green document on disk. Enumerating exits is the approach that keeps
//    missing one; writing the refusal first and letting the verdict replace it does not.
//  * NEVER ARM OVER AN INPUT. The write happens before the run knows its answer, so a sink that names
//    the policy file destroys the policy — and a gate over zero rules is exit 0, `"ok": true`.

import Foundation

/// Learn `--gate-json` and `--policy` from argv with NO side effects.
///
/// Deliberately permissive — it is not the validator, and the real flag loop still owns every
/// diagnostic. It only needs the paths early enough that the collision check and the arming can both
/// precede the first write.
func preScanSinkAndInputs(_ argv: [String]) -> (gate: String?, policy: String?, target: String?) {
    var gate: String? = nil, policy: String? = nil, target: String? = nil
    var i = 1
    while i < argv.count {
        let a = argv[i]
        if a == "--gate-json" || a == "--policy" || a == "--out", i + 1 < argv.count {
            let v = argv[i + 1]
            if v == "-" || !v.hasPrefix("-") {
                if a == "--gate-json" { gate = v } else if a == "--policy" { policy = v }
                i += 2
                continue
            }
        }
        // The scan TARGET, needed to discover the `.candor/config` whose `policy` key may name an input
        // this sink must not overwrite.
        if !a.hasPrefix("-"), target == nil { target = a }
        i += 1
    }
    return (gate, policy, target)
}

/// Every path this run READS, whatever channel it arrived through (SPEC §3.3.1 ⟨0.27⟩).
///
/// THE FIRST VERSION OF THIS GUARD KEYED ON THE FLAG. With the policy declared by `.candor/config` —
/// the checked-in form, i.e. the one a CI job actually has — `--gate-json <that policy>` destroyed it
/// and exited 0 with `"ok": true` in ALL FOUR ENGINES, because the pre-pass only looked at `--policy`
/// and `CANDOR_POLICY`. A policy does not change what it is according to how the operator handed it
/// over. The config is read LENIENTLY here — no exit, no diagnostic — because this runs before the real
/// config load and must not pre-empt its refusal.
func runInputs(_ target: String?, _ policyFlag: String?) -> [(String, String)] {
    var out: [(String, String)] = []
    let env = ProcessInfo.processInfo.environment
    if let p = policyFlag { out.append((p, "--policy")) }
    for (v, label) in [("CANDOR_POLICY", "CANDOR_POLICY"), ("CANDOR_BASELINE", "CANDOR_BASELINE"),
                       ("CANDOR_CONFIG", "CANDOR_CONFIG")] {
        if let x = env[v], !x.isEmpty { out.append((x, label)) }
    }
    // The SEPARATOR SET the dep loader accepts, not just `:` — a space-separated list registered as one
    // unresolvable token, so no dep in it was protected.
    for d in (env["CANDOR_DEPS"] ?? "").split(whereSeparator: { $0 == ":" || $0 == "," || $0 == " " || $0 == "\t" })
        .map(String.init) where !d.isEmpty {
        out.append((d, "a CANDOR_DEPS report"))
    }
    // …AND THE CONFIG'S OWN KEYS, THROUGH THE ENGINE'S OWN DISCOVERY AND ITS OWN LOADER. This used to
    // re-derive both, and a review took it apart: a second parser is a second set of holes, and every
    // place it disagreed with the real one was a file the guard failed to protect.
    guard let cfg = discoverConfigFile(targetPath: target ?? ".") else { return out }
    out.append((cfg, "the discovered .candor/config"))
    let values = loadCandorConfig(targetPath: target ?? ".")
    for key in ["policy", "baseline"] {
        if let v = values[key], !v.isEmpty { out.append((v, "the config's `\(key)`")) }
    }
    for one in (values["deps"] ?? "")
        .split(whereSeparator: { $0 == ":" || $0 == "," || $0 == " " || $0 == "\t" })
        .map(String.init) where !one.isEmpty {
        out.append((one, "the config's `deps`"))
    }
    return out
}

/// Refuse the sink if it names ANY input of this run, whatever channel that input arrived through.
func refuseGateJsonOverAnyInput(_ gate: String, _ target: String?, _ policyFlag: String?) {
    guard gate != "-" else { return }
    for (path, label) in runInputs(target, policyFlag) { refuseGateJsonOverInput(gate, path, label) }
    refuseGateJsonAtConfig(gate)
}

/// Are these two path spellings the SAME ARTIFACT?
///
/// Not a string comparison: `--policy /w/P --gate-json ./P` run from `/w` names one file twice, and the
/// engine that already had this guard compared path components and lost to exactly that spelling.
/// `resolvingSymlinksInPath` plus `standardized` handles `.`, `..` and symlinks; when the sink does not
/// exist yet (the normal case — we are about to create it) its parent directory is resolved instead and
/// the file name appended. Resolve the artifact, not just the string.
func sameArtifact(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b, a != "-", b != "-" else { return false }
    func resolve(_ p: String) -> String? {
        let url = URL(fileURLWithPath: p)
        if FileManager.default.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardized.path
        }
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { return nil }
        return parent.resolvingSymlinksInPath().standardized
            .appendingPathComponent(url.lastPathComponent).path
    }
    guard let x = resolve(a), let y = resolve(b) else { return false }
    return x == y
}

/// Refuse a `--gate-json` sink that names an INPUT of this run, having written nothing (exit 2).
///
/// The one exempt cause in the arming rule, and exempt for a reason that is not a carve-out: the path
/// was never a sink, so there is no verdict at it to go stale, and the alternative is destroying the
/// operator's policy.
func refuseGateJsonOverInput(_ gate: String, _ other: String?, _ flag: String) {
    guard sameArtifact(gate, other) else { return }
    FileHandle.standardError.write(
        ("candor-swift: --gate-json \(gate) names the SAME FILE as \(flag) \(other ?? "") — refusing "
         + "(exit 2). The verdict is armed before the policy is read, so this would overwrite your "
         + "policy and then gate on the wreckage. Nothing was written; give the verdict its own path.\n")
            .data(using: .utf8)!)
    exit(2)
}

/// Write the fail-closed refusal that every later exit inherits unless a real verdict replaces it.
func armGateJsonFailClosed(_ gp: String) {
    let armed = "{\n  \"spec\" : \"\(specVersion)\",\n  \"ok\" : false,\n  \"refused\" : true,\n"
        + "  \"reason\" : \"the gate did not complete — this document was written when the run STARTED "
        + "and was never replaced by a verdict, so the run failed, crashed or was killed before it could "
        + "decide. It is NOT a verdict about the code; see the run's stderr for the cause.\"\n}\n"
    do { try armed.write(toFile: gp, atomically: true, encoding: .utf8) }
    catch {
        FileHandle.standardError.write(("candor-swift: could not arm --gate-json \(gp) fail-closed "
            + "(\(error.localizedDescription)) — if this run does not complete, that path may still hold "
            + "a PREVIOUS run's verdict\n").data(using: .utf8)!)
    }
}

/// `.candor/config` is never a verdict sink, wherever it is (SPEC §3.3.1 ⟨0.27⟩).
///
/// The per-input checks can only name inputs the run was TOLD about; the config is DISCOVERED by
/// walking up from the target, so by the time its path is known the arming has already destroyed it.
/// Measured on this engine: `--gate-json <target>/.candor/config` deleted the config that declared the
/// policy, and the run then exited 0 with no gate at all. A check on the SHAPE needs no discovery, so it
/// runs before the first write and covers a config found anywhere up the tree.
func refuseGateJsonAtConfig(_ gate: String) {
    guard gate != "-" else { return }
    let url = URL(fileURLWithPath: gate).standardizedFileURL
    guard url.lastPathComponent == "config",
          url.deletingLastPathComponent().lastPathComponent == ".candor" else { return }
    FileHandle.standardError.write(
        ("candor-swift: --gate-json \(gate) is a .candor/config — refusing (exit 2). The verdict is armed "
         + "before the config is read, so this would destroy the config that configures this run. Nothing "
         + "was written; give the verdict its own path.\n").data(using: .utf8)!)
    exit(2)
}
