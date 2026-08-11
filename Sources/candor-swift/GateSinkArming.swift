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

/// SPEC §3.3.1 ⟨0.28⟩ — the `--out <prefix>` this argv names, side-effect free, learned early enough that
/// the armer below can run BEFORE the flag loop's own `unknown flag` exit — the exit this rung is most
/// often reached through. Mirrors `preScanSinkAndInputs`, which already skips over `--out`'s value without
/// keeping it, and is deliberately a second tiny reader rather than a fourth tuple member: the `gate
/// --report` verb calls that one and has no `--out`.
/// LAST WINS, because the flag loop's `outPrefix = v` does: on `--out a --out b` the run writes its report
/// under `b`, so `b` is the set that would otherwise be read as current after this run fails. Arming `a`
/// instead would arm a set nothing was going to replace and leave the real hazard untouched.
func preScanOutPrefix(_ argv: [String]) -> String? {
    var out: String? = nil
    var i = 1
    while i < argv.count {
        if argv[i] == "--out", i + 1 < argv.count, !argv[i + 1].hasPrefix("-") { out = argv[i + 1]; i += 2; continue }
        i += 1
    }
    return out
}

/// `(path, the bytes that were there before)` for every report this run armed under an `--out` prefix.
/// The previous bytes are the whole reason this is a list and not a count — see `disarmUnwrittenOutReports`.
nonisolated(unsafe) var armedOutReports: [(path: String, previous: Data)] = []
/// The exact placeholder bytes this run wrote, so `disarm` can tell "still armed" from "this run
/// rewrote it with a real report".
nonisolated(unsafe) var armedOutDocument: String? = nil

/// SPEC §3.3.1 ⟨0.28⟩ (1) — **ARM THE `--out <prefix>` REPORT SET.**
///
/// The verdict sink arms by writing a placeholder to a path the run is about to own. A report PREFIX
/// cannot do that: at parse time the run does not yet know which package it will write (the filename is
/// `<prefix>.<pkg>.Swift.json`, and `<pkg>` comes from a `Package.swift` that has not been read yet, or
/// from an `.xcodeproj` that has not been resolved yet). The set the run DOES know at parse time is the
/// one the PREVIOUS run left on disk — and that is exactly the set at risk of being read as current after
/// this run fails.
///
/// MEASURED on this engine 2026-08-11: `<target> --out p --zzz-not-a-flag` exited 2 with
/// `p.Fx.Swift.json` byte-identical to the previous good run (same md5). A downstream `gate --report`
/// then reads a green report the failed run never produced.
///
/// So arming rewrites every `<prefix>.*.json` to the ⟨0.21⟩ Row-1 manifest-carrying empty, and the scan
/// overwrites its own with a real report a moment later.
///
/// SIDECARS ARE NOT TOUCHED, deliberately — whether `.callgraph`/`.hierarchy`/`.locs` must arm alongside
/// their report is an OPEN question against §2.2 ⟨0.26⟩'s own manifest rules (a sidecar's KEY SET is its
/// manifest, which is a different fail-closed shape from a report's), and answering it here would put a
/// second answer in the tree.
///
/// THE INPUT EXEMPTION FROM ⟨0.27⟩ (2) APPLIES TO THIS WRITER TOO. Arming happens before the run knows its
/// answer, so a prefix whose expansion collides with something this run READS would destroy it — the same
/// hazard that made `--policy P --gate-json P` a machine-readable all-clear. A policy or a chained dep
/// report can perfectly well be named `<prefix>.something.json`. One resolver, `sameArtifact`, over the
/// one input list, `runInputs` — not a second copy that later disagrees with it.
///
/// **AND WHAT THIS RUN TURNS OUT NOT TO OWN IS HANDED BACK — see `disarmUnwrittenOutReports`.** The
/// reference engine's first version of this armer (candor-rust, undone in `f439dea`) left every
/// un-overwritten file holding the placeholder and described it as closing the orphaned-report defect for
/// free. It did not: a placeholder's non-empty `unanalyzed` is the ⟨0.21⟩ incomplete-analysis trigger, so
/// a COMPLETE scan began refusing with exit 2 and went on refusing until someone deleted the leftover by
/// hand. Claiming an incompleteness the run never experienced is the mirror of the staleness this rung
/// closes.
func armOutPrefixReports(_ prefix: String, target: String?, policyFlag: String?) {
    guard !prefix.isEmpty else { return }
    let ns = prefix as NSString
    let stem = ns.lastPathComponent
    guard !stem.isEmpty else { return }
    let dirPart = ns.deletingLastPathComponent
    let dir = dirPart.isEmpty ? "." : dirPart
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
    guard let doc = failClosedReportDocument(reason:
        "armed: this report was written when the run STARTED and was never replaced, so the run failed "
        + "before it could describe this package — or the package is no longer part of the scan and this "
        + "file is a leftover. Either way it is NOT a claim about any code.") else { return }
    var inputs: [(String, String)]? = nil
    for name in names.sorted() {
        // `<stem>.….json`, minus the §2.2 reserved sidecar segments.
        guard name.hasPrefix(stem + "."), name.hasSuffix(".json") else { continue }
        if name.hasSuffix(".callgraph.json") || name.hasSuffix(".hierarchy.json")
            || name.hasSuffix(".locs.json") { continue }
        let full = (dir as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
        if inputs == nil { inputs = runInputs(target, policyFlag) }
        if let hit = inputs!.first(where: { sameArtifact(full, $0.0) }) {
            FileHandle.standardError.write(
                ("candor-swift: --out \(prefix) would arm over \(full), which this run READS (\(hit.1)) — "
                 + "leaving it untouched, so nothing this run depends on is destroyed. If that file is "
                 + "meant to be a report of this scan, give the report set its own prefix.\n")
                    .data(using: .utf8)!)
            continue
        }
        // Remember the bytes BEFORE overwriting, so a run that completes can hand back anything it turned
        // out not to own. A file we cannot read is not armed either — we could not put it back.
        guard let prev = FileManager.default.contents(atPath: full) else { continue }
        do {
            try writeSinkAtomically(doc, to: full)
            armedOutReports.append((full, prev))
            armedOutDocument = doc
        } catch {
            FileHandle.standardError.write(
                ("candor-swift: could not arm the report \(full) fail-closed "
                 + "(\(error.localizedDescription)) — if this run does not complete, that path may still "
                 + "hold a PREVIOUS run's report\n").data(using: .utf8)!)
        }
    }
}

/// SPEC §3.3.1 ⟨0.28⟩ — **HAND BACK WHAT THIS RUN TURNED OUT NOT TO OWN.**
///
/// Arming cannot know at parse time which report file the run will write, so it arms the whole previous
/// set. Once the run has finished writing, a file STILL holding the placeholder is one the run never
/// claimed — a leftover from a package that is no longer scanned under this prefix. That is NOT an
/// incomplete analysis, and leaving the ⟨0.21⟩ placeholder there asserts one: measured on the reference
/// engine, it turned a complete scan into a permanent exit-2 refusal that only manual deletion cleared.
///
/// So the previous bytes go back, and **the orphan is left exactly as this run found it.** The orphan
/// remains an OPEN defect — a report for a package no longer in the scan still describes code that may be
/// gone, and still reaches a gate over the prefix — and that is deliberate: it is PRE-EXISTING, it has its
/// own wire question (delete it? mark it not-in-scan? a prefix can legitimately be shared between two
/// scans), and resolving it inside a staleness fix would be deciding it by accident.
///
/// Deleting the placeholder rather than restoring it is rejected for §3.3.1's own reason: a consumer that
/// treats a missing file as "nothing to report" fails open by a different route.
func disarmUnwrittenOutReports() {
    guard let doc = armedOutDocument, let want = doc.data(using: .utf8) else { return }
    for (path, prev) in armedOutReports {
        // Only files this run left untouched since arming — anything it rewrote is a real report.
        guard FileManager.default.contents(atPath: path) == want else { continue }
        do { try writeSinkAtomically(prev, to: path) }
        catch {
            FileHandle.standardError.write(
                ("candor-swift: could not restore \(path), which this run armed but did not write "
                 + "(\(error.localizedDescription)) — it is holding the fail-closed placeholder, which "
                 + "reads as `analyzed nothing`, not as a report\n").data(using: .utf8)!)
        }
    }
    armedOutReports = []
}

/// SPEC §3.3.1 ⟨0.28⟩ — every `--gate-json` this argv names, duplicates kept.
///
/// `preScanSinkAndInputs` keeps only the last. That is the behaviour this rung refuses: measured across
/// four engines, three wrote the verdict to the LAST path and this one refused — and all four left the
/// FIRST path exactly as they found it, so a previous run's `{"ok": true}` survived a gate that fired.
func allGateSinks(_ argv: [String]) -> [String] {
    var out: [String] = []
    var i = 1
    while i < argv.count {
        if argv[i] == "--gate-json", i + 1 < argv.count {
            let v = argv[i + 1]
            if v == "-" || !v.hasPrefix("-") { out.append(v); i += 2; continue }
        }
        i += 1
    }
    return out
}

/// ⟨0.28⟩ Is this sink an input? Non-exiting, so the duplicate path can ask without taking the run down.
func gateJsonIsInput(_ gate: String, _ target: String?, _ policy: String?) -> Bool {
    if gate == "-" { return false }
    if isGateJsonAtConfig(gate) { return true }
    for other in runInputs(target, policy) where sameArtifact(gate, other.0) { return true }
    return false
}

/// Two spellings of one path are ONE sink (the §3.3.1 artifact rule); two artifacts are the ambiguity.
func distinctGateSinks(_ all: [String]) -> [String] {
    var out: [String] = []
    for s in all where !out.contains(where: { $0 == s || ($0 != "-" && s != "-" && sameArtifact($0, s)) }) {
        out.append(s)
    }
    return out
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
    // THE SAME SET THE LOADER USES — `isDepSeparator`. This comment claimed that while spelling a
    // DIFFERENT set: it omitted `\n` and `\r`, so a newline-separated `CANDOR_DEPS` was ONE
    // unresolvable token here and two real paths in the loader. A `--gate-json` naming one of those
    // reports was then unguarded — arming overwrote it and the run exited 0 with `ok: true` written
    // over the operator's own dep report. Measured live in three engines; java was the intact control.
    for d in (env["CANDOR_DEPS"] ?? "").split(whereSeparator: isDepSeparator)
        .map(String.init) where !d.isEmpty {
        out.append((d, "a CANDOR_DEPS report"))
        // A DIRECTORY DEP IS EVERY REPORT INSIDE IT — the loader walks it, so registering only the
        // DIRECTORY left those files unnamed and `--gate-json <depdir>/lib.json` destroyed the
        // operator's report at exit 0. Expanded HERE rather than in `sameArtifact`: the scan TARGET is
        // an input too, and a verdict written into the scanned tree is ordinary usage — the general
        // rule refused it and took 33 tests with it. Only a dep directory has its CONTENTS read.
        for f in depReportFiles(d) where f != d {
            out.append((f, "a CANDOR_DEPS report"))
        }
    }
    // …AND THE CONFIG'S OWN KEYS, THROUGH THE ENGINE'S OWN DISCOVERY AND ITS OWN LOADER. This used to
    // re-derive both, and a review took it apart: a second parser is a second set of holes, and every
    // place it disagreed with the real one was a file the guard failed to protect.
    guard let cfg = discoverConfigFile(targetPath: target ?? ".") else { return out }
    out.append((cfg, "the discovered .candor/config"))
    let values = loadCandorConfig(targetPath: target ?? ".", lenient: true)
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

/// ⟨0.28⟩ Resolve a sink to the artifact it finally names, following a chain of symlinks and working for
/// a DANGLING one (the target need not exist yet, which is why `resolvingSymlinksInPath` is not enough).
func resolveSinkArtifact(_ p: String) -> String {
    var cur = p
    for _ in 0..<32 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cur),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
              let t = try? FileManager.default.destinationOfSymbolicLink(atPath: cur) else { return cur }
        cur = (t as NSString).isAbsolutePath
            ? t
            : (URL(fileURLWithPath: cur).deletingLastPathComponent().appendingPathComponent(t)).path
    }
    return cur
}

/// ⟨0.28⟩ WRITE WHERE THE OPERATOR POINTS. `write(…atomically: true)` writes a temp file and RENAMES it,
/// which replaces a symlink instead of following it — so an `artifacts/verdict.json` linked into a shared
/// directory kept a previous run's `{"ok": true}` while this run's document landed on the link. A stale
/// green with a single `--gate-json`. Rename also gives the destination a NEW inode, stranding a hard
/// link's other name with the previous document; there the write goes in place, which costs the atomicity
/// window and is the right trade — that reader is not racing this write, they are reading a file this
/// write was meant to update.
func writeSinkAtomically(_ text: String, to path: String) throws {
    try writeSinkAtomically(Data(text.utf8), to: path)
}

/// The BYTES form, because ⟨0.28⟩'s `--out` disarm hands back a file's PREVIOUS content and a report this
/// engine did not write need not be UTF-8 — round-tripping it through `String` would silently rewrite the
/// operator's file rather than restore it. The String form above is this one over `Data(text.utf8)`.
func writeSinkAtomically(_ data: Data, to path: String) throws {
    let target = resolveSinkArtifact(path)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: target),
       let links = attrs[.referenceCount] as? Int, links > 1 {
        try data.write(to: URL(fileURLWithPath: target), options: [])
        return
    }
    try data.write(to: URL(fileURLWithPath: target), options: .atomic)
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
    // ⟨0.28⟩ DEVICE+INODE FIRST. Path equality alone called two HARDLINKS to one inode two sinks and
    // refused a legal command — the mirror of the stale green. And a DANGLING symlink still names its
    // target, which `resolvingSymlinksInPath` cannot reach.
    if let fa = try? FileManager.default.attributesOfItem(atPath: a),
       let fb = try? FileManager.default.attributesOfItem(atPath: b),
       let da = fa[.systemNumber] as? Int, let db = fb[.systemNumber] as? Int,
       let ia = fa[.systemFileNumber] as? Int, let ib = fb[.systemFileNumber] as? Int,
       da == db, ia == ib {
        return true
    }
    let (ra, rb) = (resolveSinkArtifact(a), resolveSinkArtifact(b))
    if ra != a || rb != b {
        if URL(fileURLWithPath: ra).standardized.path == URL(fileURLWithPath: rb).standardized.path {
            return true
        }
    }
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
    let why = "candor-swift: --gate-json \(gate) names the SAME FILE as \(flag) \(other ?? "") — refusing "
        + "(exit 2). The verdict is armed before the policy is read, so this would overwrite your "
        + "policy and then gate on the wreckage. Nothing was written; give the verdict its own path."
    FileHandle.standardError.write((why + "\n").data(using: .utf8)!)
    // ⟨0.28⟩ REPORT STREAM on exit-2: if `--json` (stream) was requested, write the fail-closed report as
    // stdout's only content — the report sink is one hop upstream from the verdict sink this refusal is
    // about, and it is not exempt from §3.3.1's every-machine-path rule.
    writeReportStreamFailClosed(reasonKey: "refused", why: why)
    exit(2)
}

/// Write the fail-closed refusal that every later exit inherits unless a real verdict replaces it.
func armGateJsonFailClosed(_ gp: String) {
    let armed = "{\n  \"spec\" : \"\(specVersion)\",\n  \"ok\" : false,\n  \"refused\" : true,\n"
        + "  \"reason\" : \"the gate did not complete — this document was written when the run STARTED "
        + "and was never replaced by a verdict, so the run failed, crashed or was killed before it could "
        + "decide. It is NOT a verdict about the code; see the run's stderr for the cause.\"\n}\n"
    do { try writeSinkAtomically(armed, to: gp) }
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
/// The SHAPE test alone, so the refusing and the probing forms share one copy.
func isGateJsonAtConfig(_ gate: String) -> Bool {
    guard gate != "-" else { return false }
    let url = URL(fileURLWithPath: gate).standardizedFileURL
    return url.lastPathComponent == "config"
        && url.deletingLastPathComponent().lastPathComponent == ".candor"
}

func refuseGateJsonAtConfig(_ gate: String) {
    guard isGateJsonAtConfig(gate) else { return }
    let why = "candor-swift: --gate-json \(gate) is a .candor/config — refusing (exit 2). The verdict is armed "
        + "before the config is read, so this would destroy the config that configures this run. Nothing "
        + "was written; give the verdict its own path."
    FileHandle.standardError.write((why + "\n").data(using: .utf8)!)
    // ⟨0.28⟩ REPORT STREAM on exit-2 — see refuseGateJsonOverInput above.
    writeReportStreamFailClosed(reasonKey: "refused", why: why)
    exit(2)
}
