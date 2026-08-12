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
///
/// ⟨0.28⟩ AND IT WALKS ARGV WITH THE FLAG LOOP'S OWN VALUE RULES, because SPEC (1)'s precondition is
/// "`--out` has been parsed and ACCEPTED" and the first version of this reader matched the token
/// wherever it stood. On `--policy --out X` the loop refuses at `--policy` — `--out` there is the
/// (rejected) VALUE position, never a flag — but this reader armed X anyway, and the guaranteed exit-2
/// skips `disarmUnwrittenOutReports`, so X's previous reports became PERMANENT placeholders on an argv
/// the parse never accepts. Measured 2026-08-12: `--policy --out X` left `X.app.Swift.json` holding the
/// fail-closed empty. So a value-taking flag whose value the loop would refuse ENDS the walk (the loop
/// exits there; nothing after it is ever parsed), keeping any `--out` accepted BEFORE that point — on
/// `--out p --policy` the loop accepts p first and the failed run's placeholder is this rung working.
/// The informational tokens (`-h`/`--help`/`-V`/`--version`/`--agents`) return nil outright: the loop
/// exits 0 at them without scanning, so there is no failed run for staleness to survive — measured,
/// `--out X --help` printed the help and left X's reports as permanent placeholders behind an exit-0.
/// Unknown flags and positionals are deliberately STEPPED OVER, not refused: the loop's unknown-flag
/// exit is the exit this rung most often serves, and mirroring the full flag vocabulary here would be a
/// second parser that drifts the first time the loop grows a flag.
func preScanOutPrefix(_ argv: [String]) -> String? {
    var out: String? = nil
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "--out", "--policy", "--target":
            // The loop's rule for these three: the next token must exist and must not be flag-shaped,
            // else `requires a value` → exit 2 right here.
            guard i + 1 < argv.count, !argv[i + 1].hasPrefix("-") else { return out }
            if argv[i] == "--out" { out = argv[i + 1] }
            i += 2
        case "--gate-json":
            // Same rule, except `-` (stream to stdout) is the one dash-shaped value the loop accepts.
            guard i + 1 < argv.count, argv[i + 1] == "-" || !argv[i + 1].hasPrefix("-") else { return out }
            i += 2
        case "-h", "--help", "--version", "-V", "--agents":
            return nil
        default:
            i += 1
        }
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
/// So arming rewrites every `<prefix>.*.json` THAT IT CAN POSITIVELY IDENTIFY AS ITS OWN §2 REPORT to the
/// ⟨0.21⟩ Row-1 manifest-carrying empty, and the scan overwrites its own with a real report a moment
/// later. Identification is by CONTENT, never by a name denylist — see the loop below for the measurement
/// that settled it (a suffix denylist destroyed four sidecars, one of them a gate VERDICT).
///
/// NO SIDECAR IS EVER *ARMED* — none of them carries a `candor` envelope beside `functions`, so the
/// identification test below cannot reach one. That is the property that stopped this armer writing a
/// report-shaped placeholder over a gate VERDICT. ⟨0.28⟩ then settles the question that left open, and it
/// settles it the other way round: an armed report's OWN sidecars are **DELETED** with it — see
/// `removeArmedReportSidecars`. Arming and removing are ONE act, which is why the removal is called from
/// inside this loop rather than beside the call site: an armed report with a live sidecar is the pair the
/// rung exists to prevent, and a second call site is a second chance to forget.
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
        guard name.hasPrefix(stem + "."), name.hasSuffix(".json") else { continue }
        let full = (dir as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
        // ONLY FILES POSITIVELY IDENTIFIED AS §2 REPORTS — never a name denylist.
        //
        // The first version of this armer excluded `.callgraph`/`.hierarchy`/`.locs` by SUFFIX and armed
        // everything else under the prefix. SPEC §2.2 ⟨0.24⟩ (the "reserved set, family-wide" paragraph)
        // lists SEVEN reserved trailing segments — `callgraph`, `hierarchy`, `calibrated`, `layerreach`,
        // `locs`, `gate`, and the `encountered-*` family — and records that the engines were already
        // drifting on it, one carving out six and another two. This carved out three. Measured on the
        // reference engine: the armer overwrote `<prefix>.calibrated.json`, `.layerreach.json`,
        // `.encountered-hosts.json` and — worst — `<prefix>.gate.json`, a GATE VERDICT, each replaced by a
        // report-shaped placeholder. A run whose REPORT sink is armed was silently destroying the VERDICT
        // sink's document beside it.
        //
        // THE MECHANISM WAS WRONG, NOT JUST THE LIST. This project's standing rule is
        // denylist-over-allowlist, but that rule is about CLASSIFYING, where over-approximating is the
        // safe direction. FOR A WRITER IT INVERTS: over-approximating destroys a file. §2.2 can call an
        // incomplete denylist "loud" because there an unregistered suffix merely falls back into a
        // candidate set and prints a disclosure; in an armer it is silent and destructive.
        //
        // So this writes only what it positively recognises as its OWN §2 report: a JSON object carrying
        // both a `candor` envelope and `functions`. That cannot drift as the reserved family grows, it
        // needs no list, and on this engine it is a strict improvement over any name rule — the report
        // name embeds the package and the language (`<prefix>.<pkg>.Swift.json`), which no sidecar
        // convention constrains. Anything that does not parse, or lacks either key, is not ours to write.
        //
        // THE INPUT EXEMPTION IS ASKED FIRST, THOUGH, and that order is deliberate. A `--policy` naming
        // `<prefix>.policy.json` is not JSON at all, so the identification test alone would skip it
        // SILENTLY — and the operator whose policy sits inside their own report prefix is exactly the one
        // who needs telling, because the next reserved-looking name they choose may not be so lucky. The
        // exemption also has to outrank identification for the case where a collision IS a valid report:
        // a chained dep report under `CANDOR_DEPS` parses as one, and it is still an input.
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
        // out not to own. A file we cannot read is not armed either — we could not put it back; and the
        // same read is what identifies it, so an unreadable file never reaches the write below.
        guard let prev = FileManager.default.contents(atPath: full),
              let obj = try? JSONSerialization.jsonObject(with: prev),
              let map = obj as? [String: Any],
              map["candor"] != nil, map["functions"] != nil else { continue }
        do {
            try writeSinkAtomically(doc, to: full)
            armedOutReports.append((full, prev))
            armedOutDocument = doc
        } catch {
            // THE SIDECARS FOLLOW ONLY IF THE REPORT ACTUALLY ARMED, so this arm returns without touching
            // them. The rule is "no live sidecar beside an ARMED report"; a write that FAILED leaves the
            // PREVIOUS run's report at this path, and removing its callgraph there would make a
            // stale-report/no-callgraph pair no run has ever written — strictly worse than the pre-rung
            // state the failure left, because the half that survives is the one a `gate --report` reads
            // while the half that made `path`/`fix` answerable is gone. A pair degrades together or not at
            // all. (candor-rust's first version of this rung ignored its write result and deleted anyway;
            // candor-java raised it and rust corrected in `ff8cc09`.)
            FileHandle.standardError.write(
                ("candor-swift: could not arm the report \(full) fail-closed "
                 + "(\(error.localizedDescription)) — leaving it and its §2.2 sidecars exactly as they are; "
                 + "if this run does not complete, that path may still hold a PREVIOUS run's report\n")
                    .data(using: .utf8)!)
            continue
        }
        removeArmedReportSidecars(full, inputs: inputs!)
    }
}

/// `(the report it belongs to, its path, the bytes that were there)` for every §2.2 sidecar this run
/// DELETED while arming. Restored by `disarmUnwrittenOutReports` when the run turns out not to have owned
/// that report after all — an orphan's sidecar is as much not-ours as the orphan itself.
nonisolated(unsafe) var armedOutSidecars: [(report: String, path: String, previous: Data)] = []

/// SPEC §2.2 — the reserved trailing segments that name **a report's own sidecars**: the set
/// `removeArmedReportSidecars` deletes when it arms that report.
///
/// This engine writes two of them (`.callgraph.json`, `.hierarchy.json`, from the `--out` writer in
/// `main.swift`). The other three are here because a sidecar is a sidecar whoever wrote it, and because
/// the family's other two implementations name the same five — extending or trimming the list unilaterally
/// is precisely the drift §2.2 ⟨0.24⟩ records ("one carving out six and another two").
///
/// **`gate` is excluded, and that exclusion is the whole content of this function.** The five above are
/// DERIVED FROM the report and carry no provenance of their own, which is why §2.2 says to read them
/// together with it and why arming the report has to take them along. A `<stem>.gate.json` is not that: it
/// is the VERDICT SINK's document, with its own operator-named flag, its own ⟨0.27⟩ arming and its own
/// fail-closed shape. Deleting it from the report sink is exactly the cross-sink harm §3.3.1 records as
/// MEASURED — and it would fail OPEN in the way `armGateJsonFailClosed` refuses to, because a CI wrapper
/// that reads a missing verdict as "nothing to report" goes green. The deletion argument for the five
/// turns on NO consumer treating their absence as a claim; for a VERDICT, absence is precisely the claim
/// that gets misread.
///
/// The `encountered-*` family is reserved by §2.2 but is not taken either: this engine does not emit it,
/// so a file by that name under a report's stem was written by something else, and the miss direction is
/// the cheap one here (see `removeArmedReportSidecars`).
func reportSidecarSegments() -> [String] {
    ["calibrated", "callgraph", "hierarchy", "layerreach", "locs"]   // sorted, so stderr is stable
}

/// SPEC §3.3.1 ⟨0.28⟩ — **THE §2.2 SIDECARS GO WITH THE ARMED REPORT, DELETED NOT EMPTIED.**
///
/// An armed report beside a LIVE sidecar is a PAIR THAT CONTRADICTS ITSELF, and §2.2 gives the sidecar no
/// provenance of its own to arbitrate with. Not decorative: on this engine `path`, `tour`, `fix` and
/// `fix-gate` all take their call graph from `<stem>.callgraph.json` (`loadFixModel` merges it), because a
/// currently-pure function is absent from the report by §2 rule 3 and only the sidecar records it. So the
/// half the report rung had not touched keeps answering — confidently, from the previous version of the
/// code. Measured on candor-rust before its fix: `callers f` returned exit 0, "reached by 1 function(s)
/// (the blast radius if it gained an effect): g", while `h` called `f` too. An agent reads that as
/// safe-to-edit. That is the cardinal sin, arriving through the other half of the pair.
///
/// **Deleted rather than `{}`**, and NOT by reading the report's own anti-deletion rule across: §3.3.1
/// forbids deleting a REPORT because a consumer that reads a missing file as "nothing to report" fails
/// open, and no sidecar consumer has that failure mode — §2.2 makes the sidecar OPTIONAL, so every
/// consumer was forced to define an absence arm from the start and every specified arm is safe
/// (`loadBaselineCallgraph` says so on stderr and over-lists; `loadFixModel` falls back to the report's
/// inline `calls`). ⟨0.24⟩ has already ruled an empty, an absent and an unparseable HIERARCHY sidecar to
/// be the same input, and the one cell that rule does not cover — an empty-but-valid baseline CALLGRAPH —
/// was measured four-way to answer `origin: "unknown"`. `{}` buys nothing deletion does not, and absence
/// is the state the consumers were built for.
///
/// **THE GUESS RUNS THE OPPOSITE WAY FROM THE ARMER'S, on purpose.** The armer identifies POSITIVELY by
/// content, because there a miss leaves a stale report and an over-reach destroys a file. Here a miss
/// merely leaves a sidecar behind — the pre-rung state, caught consumer-side by ⟨0.28⟩'s pairing rule —
/// while an over-reach would delete something that is not ours. So this goes by the §2.2 reserved segment
/// NAMES, **scoped to this one report's stem**: on this engine a report is `<prefix>.<pkg>.Swift.json`, so
/// the stem carries the package and the language and a prefix-level `<prefix>.locs.json` is NOT a sidecar
/// of it and is left alone. Both directions are chosen so the WRONG guess costs the least.
///
/// **The input exemption applies here too**, over the same `runInputs`/`sameArtifact` the armer and the
/// two sink guards use — one resolver, never a second copy that later disagrees. *Do not touch what this
/// run reads* outranks the pairing invariant, so a sidecar that is also a `CANDOR_DEPS` report, a
/// `--policy` or the discovered config is left in place and the operator is told why.
func removeArmedReportSidecars(_ reportPath: String, inputs: [(String, String)]) {
    let stem = (reportPath as NSString).deletingPathExtension
    for seg in reportSidecarSegments() {
        let side = stem + "." + seg + ".json"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: side, isDirectory: &isDir), !isDir.boolValue else { continue }
        if let hit = inputs.first(where: { sameArtifact(side, $0.0) }) {
            FileHandle.standardError.write(
                ("candor-swift: \(side) is a §2.2 sidecar of the armed report \(reportPath) AND names "
                 + "\(hit.1) \(hit.0), which this run READS — leaving it in place. Read it together with "
                 + "that report: an armed report makes its sidecar unanswerable, whatever the sidecar "
                 + "says.\n").data(using: .utf8)!)
            continue
        }
        // A SYMLINKED SIDECAR IS LEFT, AND SAID SO. Removing the link would take away a name the operator
        // built deliberately, and `disarm` hands sidecars back by WRITING BYTES — which would turn the
        // link into a regular file, a third state neither the pre-run nor the armed tree ever had. This is
        // the direction the guess is allowed to be wrong in: a sidecar left behind is the pre-rung state,
        // and the ⟨0.28⟩ pairing rule catches it consumer-side.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: side),
           (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            FileHandle.standardError.write(
                ("candor-swift: \(side) is a §2.2 sidecar of the armed report \(reportPath) but it is a "
                 + "SYMLINK — leaving it, because this run could not put the link back afterwards. It now "
                 + "describes a PREVIOUS run; a sidecar whose report is a manifest-carrying empty is "
                 + "unanswerable input, whatever it says.\n").data(using: .utf8)!)
            continue
        }
        // Read BEFORE removing: a sidecar we cannot read is one we could not hand back with a restored
        // orphan, and the same read is what makes the restore byte-identical.
        guard let prev = FileManager.default.contents(atPath: side) else {
            FileHandle.standardError.write(
                ("candor-swift: could not read \(side), the §2.2 sidecar of the armed report "
                 + "\(reportPath) — leaving it in place rather than deleting what this run could not hand "
                 + "back. It now describes a PREVIOUS run.\n").data(using: .utf8)!)
            continue
        }
        do {
            try FileManager.default.removeItem(atPath: side)
            armedOutSidecars.append((reportPath, side, prev))
        } catch {
            FileHandle.standardError.write(
                ("candor-swift: could not remove \(side), the §2.2 sidecar of the armed report "
                 + "\(reportPath) (\(error.localizedDescription)) — it now sits beside a fail-closed "
                 + "report and describes a PREVIOUS run. Delete it, or ignore it: a sidecar whose report "
                 + "is a manifest-carrying empty is unanswerable input.\n").data(using: .utf8)!)
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
///
/// ⟨0.28⟩ **AND THE ORPHAN'S §2.2 SIDECARS COME BACK WITH IT.** Handing back the report while leaving the
/// sidecars this run deleted beside it would be a THIRD state neither the pre-run tree nor the armed tree
/// ever had — a live report whose call graph has silently vanished — and it would degrade every
/// `path`/`fix`/`gains` answer over that package to the absence arm with nothing saying why. "Left exactly
/// as this run found it" has to mean the pair.
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
            continue
        }
        for (report, side, sprev) in armedOutSidecars where report == path {
            // Not over a file that exists: if the run wrote a real sidecar there it is this run's, and
            // restoring the previous bytes over it would put back exactly the staleness this rung closes.
            guard !FileManager.default.fileExists(atPath: side) else { continue }
            do { try writeSinkAtomically(sprev, to: side) }
            catch {
                FileHandle.standardError.write(
                    ("candor-swift: could not restore \(side), the §2.2 sidecar this run removed beside "
                     + "\(path) — a report the run turned out not to own (\(error.localizedDescription)). "
                     + "The report is back and its call graph is not, so `path`/`fix` over that package "
                     + "will answer from the report's inline calls alone until the next clean scan.\n")
                        .data(using: .utf8)!)
            }
        }
    }
    armedOutReports = []
    armedOutSidecars = []
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
    // ⟨0.28⟩ THE TARGET ITSELF. SPEC §3.3.1 (3) OPENS its input list with "the target's own source
    // tree", and this registry carried every channel EXCEPT that one — policy, env, deps, config, all
    // ways of telling the run what to read ABOUT the target, and never the target. MEASURED live on
    // this engine 2026-08-12, through both arms that consult this list: `app.swift --policy P
    // --gate-json app.swift` replaced the operator's SOURCE FILE with the armed verdict document (the
    // single-file route — main.swift's `sourcePaths = [target]` — so "swift targets are directories"
    // was never a shield, only the common case), and `p.app.json --out p --zzz-not-a-flag` left a
    // report-shaped target holding the fail-closed placeholder past the exit-2 that skips disarm.
    //
    // ONE EXACT ARTIFACT, NEVER A CONTAINMENT RULE. A verdict or report written INTO the scanned tree
    // (`.candor/`, the pattern this project ships in CI) is ordinary usage; `sameArtifact` already
    // separates "inside the target" from "IS the target", and the dep-dir expansion below stays the
    // one place a directory's CONTENTS are enumerated — widening this entry to containment is the
    // mistake that took 33 tests down when it was tried on the dep side. Defaults to "." exactly as
    // the config discovery below anchors there: the tree the run reads when no positional names one.
    out.append((target ?? ".", "the scan target"))
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
    // "that input", not "your policy": since ⟨0.28⟩ this guard also covers the scan target, and a
    // refusal that misnames what it just protected teaches the reader the message is boilerplate.
    let why = "candor-swift: --gate-json \(gate) names the SAME FILE as \(flag) \(other ?? "") — refusing "
        + "(exit 2). The verdict is armed before the run reads its inputs, so this would overwrite "
        + "that input and then gate on the wreckage. Nothing was written; give the verdict its own path."
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
