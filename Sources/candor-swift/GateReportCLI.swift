import CandorCore
import Foundation

// ⟨0.24⟩ `gate --report <locator> --policy <file>` (SPEC §3.1) — apply a policy to an EXISTING report,
// with NO scan. Exit codes and verdict shape are exactly `scan --policy`'s; the only difference is where
// `S` and `D` come from.
//
// WHY IT IS A MUST AND NOT A CONVENIENCE. `scan --policy` recomputes `S` from source, so the classifier
// is always in the loop; `whatif` reports only what a hypothetical INTRODUCES. The gate was therefore
// never reachable as a function of a GIVEN signature, and a defect in the gate was indistinguishable
// from a defect in the classifier by any test that could be written here. With this verb, conformance
// can hand the engine a signature `candor-spec/reference/policy_model.py` has already judged and compare
// verdicts directly. It is also the supply-chain verb: gating a dependency's PUBLISHED report is the
// operation an adopter wants and could not previously express without re-analysing code they do not have.
//
// THE MATCHING LIVES IN Gate.swift. This file only builds a `GateInput` and owns the CLI/exit
// choreography — see `gateInputFromReport` below and the `GateInput` doc comment for why there is
// deliberately no second copy of the §6.2 rules on this side.

/// ⟨0.24⟩ Every exit-2 cause on this verb, and they ALL write the refusal document now (SPEC §3.1,
/// candor-spec `1503368` — the carve-out is gone). `gateVerdictSinks` is empty until the flag loop has
/// resolved `--gate-json`/`--json`, so a usage error inside that loop still writes nothing, which is the
/// one case where there is no sink to write to.
private func gateDie(_ msg: String) -> Never { refuseGateAndExit(msg) }


// ── the report, read as data ─────────────────────────────────────────────────────────────────────────

/// One §2 report entry, as far as the ⟨0.24⟩ gate is concerned. Every field is read VERBATIM off the
/// wire: this is `S` and `D` as the producer wrote them, not a re-derivation.
private struct GateReportEntry {
    let fn: String
    /// ⟨0.32⟩ the §2.2 JOIN KEY. Empty when the report carries none — a hand-authored report, or one from
    /// a producer older than the key — in which case the name is all there is and `entryKey` falls back
    /// to it. Absence is the pre-⟨0.32⟩ behaviour, not a new hazard; PRESENCE is what fixes it.
    let hash: String
    let inferred: Set<String>
    /// ⟨0.24⟩ The §2 `direct` set — the effects raised in this function's OWN body, as distinct from the
    /// transitive `inferred`. Read for exactly one purpose: to tell a DIRECT `Unknown` the entry named no
    /// reason for (which CONTRIBUTES `unresolved`, §6.2) from an INHERITED one whose reason lives in a
    /// callee (which does not, and whose absence is a real hole). See `gateInputFromReport`.
    let direct: Set<String>
    let calls: [String]
    let hosts: Set<String>, cmds: Set<String>, paths: Set<String>, tables: Set<String>
    let netClass: [String]
    let unknownWhy: [String]
}

/// The §2 ENVELOPE facts the gate VERDICT carries, none of which live in the `functions` array: the
/// ⟨0.21⟩ completeness manifest (`analyzed.count`, `unanalyzed`) and the ⟨0.15⟩ κ-coverage ledger.
/// Read from the SAME file(s) as the entries, in one pass — no sidecar, no second locator.
private struct GateReportEnvelope {
    var analyzedCount = 0
    var unanalyzed: [(path: String, reason: String)] = []
    /// ⟨0.30⟩ the peek's findings, carried BY the report — this route cannot peek (it has no target, only
    /// a document), which is exactly why the field rides the report and why §3.1 byte-equality holds here.
    var outOfScope: [OutOfScopeFinding] = []
    // ⟨0.31⟩ the PRODUCER's ambient-partner provenance, read verbatim. This route has no target to anchor
    // `net-partner` at, and re-classifying through the consumer's own config is the re-derivation ⟨0.24⟩
    // forbids — it would make the verdict depend on the reader's working directory.
    var netPartners: [(config: String, hosts: [String])] = []
    /// ⟨0.32⟩ THE EXCLUSION CLASSES THE PRODUCING SCAN DID NOT READ — the third cause of an INCOMPLETE
    /// verdict, read OFF THE DOCUMENT. `excluded[].peeked == false` without `judgedElsewhere` is the
    /// producer stating it never opened those files: their effects are absent because nothing looked, not
    /// because there are none, and the ⟨0.30⟩ `outOfScope` arm cannot see it (a peek that could not open a
    /// file FINDS nothing, which is byte-identical to finding it clean).
    ///
    /// Reachable identically on both routes precisely because `excluded` rides the REPORT: this route
    /// needs no target to re-derive anything from, which is what defeated the ⟨0.31⟩ `net-partner`
    /// disclosure and broke §3.1 route-equality there. Populated per FILE (see `mergeGateReport`), so a
    /// multi-report locator unions its members' unread classes the way it unions their manifests.
    var unpeeked: [String] = []
    /// ⟨0.33⟩ THE QUESTION EACH PEEKING REPORT'S PRODUCER WAS PUT (SPEC §2 ⟨0.33⟩) — one element per
    /// REPORT FILE that carries at least one `excluded` entry with `peeked: true` and no
    /// `judgedElsewhere`, never a union across files (`scannedUnder` is a fact about ONE producing scan).
    /// A file peeking nothing contributes no element: analysed code's effect sets are policy-independent,
    /// so only the peek was ever bounded, and refusing over a report that excluded nothing peeked would be
    /// a pure over-charge. The element is the EMPTY SET when the file peeked something but carries no
    /// `scannedUnder` (a pre-⟨0.33⟩ producer, which fails closed) or an explicit empty deny set (a policy
    /// that stood and denied nothing).
    ///
    /// ⟨0.34⟩ …carried beside that report's own declared `candor.spec` (verbatim, `""` for a pre-spec-field
    /// producer) — read once, here, rather than re-parsed from the file once the missing rules are known.
    var scannedUnderOfPeeked: [(deny: Set<String>, spec: String)] = []
    var coverageModules: Set<String> = []
    var entries: [GateReportEntry] = []
    /// ⟨0.24⟩ Does every report at this locator say it JUDGED NOTHING? (SPEC §2's three-row table, bound
    /// to this verb by §3.1.) ANDed across the multi-report siblings: the union has judged something as
    /// soon as one member has. Starts `true` and is falsified per file, so a locator that resolved to no
    /// file at all never reaches the advisory — `loadGateReport` returns nil there and the caller exits 2.
    var judgedNothing = true
}

/// Parse ONE report file into `env`. Returns false (loudly) on a file that is not a well-formed §2
/// report — SPEC §3.1's found-but-corrupt rule: a report with no `functions` key is corrupt input, not
/// an effect-free package, and gating an empty `map` over it would pass. The caller exits 2.
///
/// ⟨0.24⟩ **A KEY THAT IS PRESENT BUT UNPARSEABLE IS CORRUPT INPUT, AND IS NEVER COERCED TO ITS EMPTY
/// VALUE** (SPEC §2, candor-spec `38ba3e2`). The shape that generalises the count-0 and missing-`functions`
/// rungs is *a reader that recovers from a type mismatch by substituting the default* — and on every key in
/// this format the default is the PERMISSIVE value (`0`, `[]`, absent), so the coercion converts corrupt
/// input into a claim and the claim is always the safe-looking one. `?? []`, `unwrap_or_default` and
/// `optional().orElse()` are the idiom to grep for; on a §2 key, finding one is a defect until proven
/// otherwise. MEASURED on this engine before the fix, `deny Net` over a one-entry report:
///
///     entry with NO `fn` key, `inferred: ["Net"]`   rust 2   ts 2   java 2   swift 0   ← dropped silently
///     entry with `inferred: [1]`                    rust 2   ts 0   java 0   swift 0   ← three fail open
///
/// The first is the cardinal-sin shape under ⟨0.21⟩ exactly: a CORRUPT entry silently became an ABSENT
/// one, and absent means pure. So `fn` must be a non-empty string, every list-valued entry key that is
/// PRESENT must be a list OF STRINGS, and the envelope's `unanalyzed`/`coverage` must parse — each a
/// refusal naming the key, never a drop. An ABSENT key still takes its documented default: that is the
/// distinction the rule turns on, and conflating the two would refuse every legitimate report.
/// A §2 boolean flag as an ANSWER: `false` for an ABSENT key (the documented, fail-closed default),
/// the value for a real boolean, and `nil` for present-but-not-a-boolean, which the caller refuses.
///
/// **`as? Bool` IS NOT THAT TEST, and this engine has already shipped one live defect through the same
/// bridge.** Foundation bridges a JSON `true` to `__NSCFBoolean`, and `NSNumber(1) as? Bool` SUCCEEDS
/// with `true` — so `"peeked": 1` would read as "the peek opened those files" and `"judgedElsewhere": 1`
/// would grant the carve-out that suppresses the refusal, both from a value no producer in this family
/// writes. The identical bridge made `analyzed: {count: true}` read as JUDGED (see
/// `readableAnalyzedCount` in Deps.swift, which rejects on the number's own type tag for the same
/// reason and in the same words).
///
/// The tag test, not a value test: `objCType` is `"c"` for a boolean on Darwin Foundation AND on
/// swift-corelibs-foundation (`Bool` is stored as `kCFNumberCharType`), while a JSON integer is
/// `"q"`/`"l"`/`"i"` and a JSON float `"d"`. `true` and `1` are the same NUMBER, so only the tag can
/// separate them.
func readableFlag(_ v: Any?) -> Bool? {
    guard let v else { return false }                        // ABSENT → the documented default
    // A JSON `null` is a PRESENT key, so it is corrupt rather than absent — the ⟨0.26⟩ distinction, and
    // the reading candor-ts takes (`"k" in e && typeof e.k !== "boolean"`) and candor-rust gets from
    // serde (which rejects `null` for a `bool` even under `#[serde(default)]`). Both readings fail
    // CLOSED here, so this is about the family answering one wire the same way, not about soundness.
    guard !(v is NSNull) else { return nil }
    guard let n = v as? NSNumber else { return nil }         // a string, a list, an object
    let tag = String(cString: n.objCType)
    guard tag == "c" || tag == "C" || tag == "B" else { return nil }   // a NUMBER is not a flag
    return n.boolValue
}

private func mergeGateReport(_ full: String, into env: inout GateReportEnvelope) -> Bool {
    func corrupt(_ what: String) -> Bool {
        FileHandle.standardError.write(
            ("candor-swift gate: report `\(full)` is corrupt — \(what). Refusing to gate over it (exit 2): "
             + "a key that is PRESENT but unparseable is not an empty one, and reading it as empty would "
             + "turn a corrupt entry into a ⟨0.21⟩ purity claim. Re-run the scan.\n").data(using: .utf8)!)
        return false
    }
    guard let data = FileManager.default.contents(atPath: full),
          let root = try? JSONSerialization.jsonObject(with: data),
          let obj = root as? [String: Any],
          let fns = obj["functions"] as? [[String: Any]] else {
        FileHandle.standardError.write(
            "candor-swift gate: report `\(full)` is not a well-formed §2 report (no `functions` array) — refusing to gate over it\n"
                .data(using: .utf8)!)
        return false
    }
    /// The string list under `k`, or `nil` when the key is PRESENT and is not a list of strings. An ABSENT
    /// key is `[]` — the documented default, and the whole point of returning an optional is that the
    /// caller can tell the two apart.
    func strs(_ k: String, _ e: [String: Any]) -> [String]? {
        guard let raw = e[k] else { return [] }                     // absent → the documented default
        guard let arr = raw as? [Any] else { return nil }           // present, not a list
        let out = arr.compactMap { $0 as? String }
        return out.count == arr.count ? out : nil                   // a non-string member is corrupt
    }
    for e in fns {
        guard let fn = e["fn"] as? String, !fn.isEmpty else {
            // NOT `continue`. A report entry with no readable `fn` cannot be matched by any scope or named
            // in any violation, so dropping it deletes whatever effect it carried — and under ⟨0.21⟩ the
            // resulting absence is a positive purity claim about a function this report was trying to tell
            // you about. Measured: `{"inferred":["Net"]}` with no `fn` exited 0 under `deny Net`.
            return corrupt("a `functions` entry has no readable `fn` (a non-empty string is §2-required); "
                           + "an entry that cannot be NAMED cannot be gated, and dropping it would make it "
                           + "read as pure")
        }
        // Every list-valued entry key, checked BEFORE any of them is used — `inferred` is the effect set
        // the whole verdict is computed from, and `calls` is the graph the ⟨0.19⟩ reason classes resolve
        // over, so a silently-dropped member of either narrows the gate for lack of evidence.
        guard let inferred = strs("inferred", e), let direct = strs("direct", e),
              let calls = strs("calls", e), let hosts = strs("hosts", e), let cmds = strs("cmds", e),
              let paths = strs("paths", e), let tables = strs("tables", e),
              let netClass = strs("netClass", e), let unknownWhy = strs("unknownWhy", e) else {
            return corrupt("the entry `\(fn)` carries a §2 list key that is not a list of strings "
                           + "(`inferred`, `direct`, `calls`, `hosts`, `cmds`, `paths`, `tables`, "
                           + "`netClass`, `unknownWhy`)")
        }
        env.entries.append(GateReportEntry(
            fn: fn,
            hash: e["hash"] as? String ?? "",
            inferred: Set(inferred),
            direct: Set(direct),
            calls: calls,
            hosts: Set(hosts), cmds: Set(cmds),
            paths: Set(paths), tables: Set(tables),
            netClass: netClass,
            unknownWhy: unknownWhy))
    }
    // ⟨0.21⟩ the completeness manifest, and ⟨0.15⟩ the κ ledger — the wire fields the scan's own verdict
    // was written from, so the two documents carry the same three facts (Gate.swift's writeGateVerdict).
    // ⟨0.24⟩ THE COUNT IS READ ONCE, THROUGH THE SHARED READER (Deps.swift). A `count` that is boolean,
    // fractional, negative or non-numeric is present-but-UNREADABLE and contributes NOTHING to the sum —
    // it must never put a number in the machine-readable verdict that the wire did not carry.
    if let c = readableAnalyzedCount(obj["analyzed"]) { env.analyzedCount += c }
    // …and the same predicate decides the ⟨0.24⟩ judged-nothing advisory, so the chained-dep route and
    // this one cannot drift into two readings of one integer.
    if !claimsToHaveJudgedNothing(analyzed: obj["analyzed"], entryCount: fns.count) { env.judgedNothing = false }
    // ⟨0.24⟩ `unanalyzed` IS THE SHARPEST CASE OF THE PRESENT-BUT-UNPARSEABLE RULE, because its
    // NON-EMPTINESS is the fail-closed trigger (the `NOT certified` exit 2 at the bottom of this file). The
    // old spelling — `as? [[String: Any]] ?? []` — read a bare string list (`["src/broken.swift"]`) or a
    // right-shaped/wrong-named list (`[{"unit":…,"why":…}]`) as an EMPTY one, so a report DECLARING it
    // could not read some of its own source gated `policy ✓`. candor-spec `38ba3e2` measured all four
    // engines dropping the bare string list and exiting 0.
    if let rawU = obj["unanalyzed"] {
        guard let arr = rawU as? [Any] else { return corrupt("`unanalyzed` is present and is not a list") }
        for u in arr {
            guard let m = u as? [String: Any], let p = m["path"] as? String else {
                return corrupt("an `unanalyzed` member is not a `{path, reason}` object — a completeness "
                               + "declaration that cannot be read is still a declaration, and reading it as "
                               + "an empty list is how `NOT certified` becomes `policy ✓`")
            }
            env.unanalyzed.append((path: p, reason: m["reason"] as? String ?? ""))
        }
    }
    // ⟨0.30⟩ THE PEEK'S FINDINGS, read as strictly as `unanalyzed` above and for the identical reason:
    // non-emptiness IS a fail-closed trigger, so a present-but-garbled key read as an empty list becomes
    // the claim "I looked and nothing was there" — the safe-LOOKING value. ABSENT STAYS ABSENT (⟨0.26⟩
    // cannot-answer): a report produced with no policy was never asked, so it must not exit 2 on contact.
    // ⟨0.31⟩ `netPartners` — read as written and shape-checked like every other §2 key: a present key
    // that cannot be read impeaches the document rather than being quietly dropped.
    if let rawNP = obj["netPartners"] {
        guard let m = rawNP as? [String: Any],
              let cfg = m["config"] as? String,
              let hosts = m["hosts"] as? [String] else {
            return corrupt("`netPartners` is present and is not a `{config, hosts}` object — a SIGNATURE "
                           + "key that cannot be read impeaches the whole document (§2)")
        }
        env.netPartners.append((config: cfg, hosts: hosts))
    }
    if let rawO = obj["outOfScope"] {
        guard let arr = rawO as? [Any] else { return corrupt("`outOfScope` is present and is not a list") }
        for f in arr {
            guard let m = f as? [String: Any], let fn = m["fn"] as? String else {
                return corrupt("an `outOfScope` member is not a `{fn, path, effects, class, reason}` object "
                               + "— reading it as an empty list is how `NOT certified` becomes `policy ✓`")
            }
            env.outOfScope.append(OutOfScopeFinding(
                fn: fn,
                path: m["path"] as? String ?? "",
                effects: m["effects"] as? [String] ?? [],
                cls: m["class"] as? String ?? "",
                reason: m["reason"] as? String ?? ""))
        }
    }
    // ⟨0.32⟩ THE THIRD CAUSE OF AN INCOMPLETE VERDICT — the exclusion classes this scan did NOT READ.
    //
    // **THE RULE, stated once and applied on both routes: a class the producing scan did not READ
    // licenses nothing, and whether that matters is decided by the policy in force NOW — not by the
    // producer's history.** The condition on THIS run's policy is applied once, to the value, in
    // `runGateReportCLI`; the read here is unconditional.
    //
    // THIS BLOCK'S FIRST VERSION ALSO REQUIRED `outOfScope` TO BE PRESENT, and that was a VERIFIED
    // FAIL-OPEN (measured 2026-08-24 on an ordinary SPM tree whose test helper spawns `/bin/sh`).
    // ⟨0.29⟩ omits `outOfScope` when the producing scan carried no policy, so a report written by a bare
    // `candor-swift <dir> --out N` — which marks every class `peeked: false`, nothing having been asked —
    // skipped this whole rule and gated `deny Exec` at exit 0, `ok: true`, `policy ✓`, while
    // `candor-swift <dir> --policy 'deny Exec'` over the SAME tree exited 2 naming the helper. The
    // producer's silence about the QUESTION was being read as an answer about the CODE.
    //
    // `peeked: false` does have two causes — the peek OPENED those files and could not read them, or no
    // peek ran at all — but FROM A REPORT they are indistinguishable, because they leave the identical
    // hole: that code's effects are absent from `functions` because nothing looked, and ⟨0.21⟩ licenses a
    // purity claim only over units the scan JUDGED. `excluded` is MANDATORY from ⟨0.29⟩ (SPEC §2.2), so a
    // ⟨0.29⟩-era no-policy report over a tree with exclusions is a current producer stating it never
    // opened those files — not an old format that cannot answer. The ⟨0.26⟩ absent-vs-empty rule still
    // does its work one level down: an ABSENT `excluded` (a pre-⟨0.29⟩ producer) names nothing and
    // refuses nothing.
    //
    // Strict for the same reason `unanalyzed` and `outOfScope` are: non-emptiness is a FAIL-CLOSED
    // trigger, so a present-but-garbled key coerced to `[]` becomes the claim "nothing went unread" —
    // the safe-LOOKING value, which is how `NOT certified` becomes `policy ✓`.
    // ⟨0.33⟩ does THIS FILE carry any `excluded` entry that was peeked (and not `judgedElsewhere`)? THE
    // PRECONDITION of the cross-policy refusal below — see `scannedUnderOfPeeked`.
    var filePeekedAny = false
    if let rawX = obj["excluded"] {
        guard let arr = rawX as? [Any] else { return corrupt("`excluded` is present and is not a list") }
        for x in arr {
            guard let m = x as? [String: Any], let cls = m["class"] as? String, !cls.isEmpty else {
                return corrupt("an `excluded` member is not a `{class, count, peeked, reason}` object "
                               + "with a readable `class` — an exclusion class that cannot be NAMED "
                               + "cannot be reported, and dropping it would read as `peeked`")
            }
            // ABSENT `peeked` counts as NOT peeked. A producer that does not carry the key cannot be
            // read as having opened the files: that is the fail-OPEN reading of a missing disclosure,
            // which is the failure this key exists to prevent. PRESENT-AND-NOT-A-BOOLEAN is neither —
            // it is corrupt input, and `readableFlag` is why it cannot be quietly read as `true`.
            guard let peeked = readableFlag(m["peeked"]) else {
                return corrupt("an `excluded` member's `peeked` is present and is not a boolean — a flag "
                               + "that cannot be READ is not a flag that says `false`, and `\(cls)` would "
                               + "then read as opened")
            }
            // ⟨0.32⟩ the PRODUCER's own carve-out for a DERIVED copy of code the same scan already
            // judged (`.build/`). Read off the FLAG, never off the class token: the same concept is
            // `build-output-archive` in candor-java and `build-script` in candor-rust, and rust's is
            // code that RUNS and must fail closed — keying on the name would gate another engine's
            // report differently from the engine that wrote it.
            guard let judgedElsewhere = readableFlag(m["judgedElsewhere"]) else {
                return corrupt("an `excluded` member's `judgedElsewhere` is present and is not a boolean "
                               + "— this is the flag that SUPPRESSES the unread-class refusal, so a "
                               + "value nobody can read must never be honoured as the carve-out")
            }
            if !peeked && !judgedElsewhere { env.unpeeked.append(cls) }
            if peeked && !judgedElsewhere { filePeekedAny = true }
        }
    }
    // ⟨0.33⟩ THE QUESTION THIS FILE'S PEEK WAS PUT (SPEC §2 ⟨0.33⟩) — read as STRICTLY as `outOfScope`
    // above and for the identical reason: the fail-open direction here is the MIRROR of `peeked`'s. There
    // the safe-looking coercion was "no exclusions"; here it would be "the producer held these rules" —
    // reading a garbled value that way would MANUFACTURE coverage the producer never claimed.
    var scannedUnderThisFile: Set<String>? = nil
    if let rawSU = obj["scannedUnder"] {
        guard let m = rawSU as? [String: Any], let denyRaw = m["deny"] as? [Any] else {
            return corrupt("`scannedUnder` is present and is not a `{deny: [string, …]}` object — it names "
                           + "the deny set this report's peek was bounded by, and a gate cannot tell what "
                           + "went unasked without it (§2)")
        }
        let denyStrs = denyRaw.compactMap { $0 as? String }
        guard denyStrs.count == denyRaw.count else {
            return corrupt("`scannedUnder.deny` is present and contains a non-string member")
        }
        scannedUnderThisFile = Set(denyStrs)
    }
    // ⟨0.33⟩ ONLY WHEN THIS FILE PEEKED SOMETHING does its `scannedUnder` become a fact worth comparing —
    // the over-charge control this rung's design names first (analysed code's effect sets are
    // policy-independent, so a report peeking nothing contributes no element here). An ABSENT
    // `scannedUnder` beside a peeked class is the EMPTY SET for the subset test (SPEC §2 ⟨0.33⟩), never a
    // licence — a pre-⟨0.33⟩ producer fails closed exactly as ⟨0.32⟩'s absent `outOfScope` case does.
    //
    // ⟨0.34⟩ …paired with this file's own declared `candor.spec`, read here rather than re-parsed later —
    // see the field doc on `GateReportEnvelope.scannedUnderOfPeeked`.
    if filePeekedAny {
        let fileSpec = (obj["candor"] as? [String: Any])?["spec"] as? String ?? ""
        env.scannedUnderOfPeeked.append((deny: scannedUnderThisFile ?? [], spec: fileSpec))
    }
    // ⟨0.15⟩ the κ ledger. Same rule: it rides the verdict as `coverage.modules`, so a present-but-garbled
    // `coverage` silently deletes the one channel that tells a MACHINE consumer of a green gate which
    // packages were never judged.
    if let rawC = obj["coverage"] {
        guard let cov = rawC as? [String: Any] else { return corrupt("`coverage` is present and is not an object") }
        if let rawUnc = cov["uncovered"] {
            guard let unc = rawUnc as? [Any] else { return corrupt("`coverage.uncovered` is present and is not a list") }
            for entry in unc {
                guard let m = entry as? [String: Any], let name = m["name"] as? String else {
                    return corrupt("a `coverage.uncovered` member has no readable `name`")
                }
                env.coverageModules.insert(name)
            }
        }
    }
    return true
}

/// ⟨0.32⟩ The refusal marker for a locator, if one is present — SPEC §3.3.1 ⟨0.32⟩.
///
/// All three locator forms. The DIRECT-FILE case is why the marker carries its own `prefix`: that form
/// accepts any `.json` name whatever its dot-segments, so the prefix cannot come from the filename — the
/// marker is found by scanning the file's directory and asking which recorded prefix covers it.
struct RefusalMarker { let prefix: String; let target: String; let reason: String }

func refusalMarkerFor(_ locator: String) -> RefusalMarker? {
    func read(_ path: String) -> RefusalMarker? {
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              o["refused"] as? Bool == true,
              let pfx = o["prefix"] as? String else { return nil }
        return RefusalMarker(prefix: pfx,
                             target: o["target"] as? String ?? "",
                             reason: o["reason"] as? String ?? "")
    }
    var isDir: ObjCBool = false
    if locator.hasSuffix(".json"),
       FileManager.default.fileExists(atPath: locator, isDirectory: &isDir), !isDir.boolValue {
        let dir = (locator as NSString).deletingLastPathComponent
        let me = URL(fileURLWithPath: locator).standardizedFileURL.path
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.isEmpty ? "." : dir)) ?? [] {
            guard n.hasSuffix(".refused.json") else { continue }
            if let m = read((dir.isEmpty ? "." : dir) + "/" + n),
               me.hasPrefix(URL(fileURLWithPath: m.prefix).standardizedFileURL.path) { return m }
        }
        return nil
    }
    return read(locator + ".refused.json")
}

/// Load the report(s) at `prefix` and NOTHING ELSE. Returns nil when no report is found or one is
/// corrupt (the caller exits 2 — never a silently-empty "no violations").
///
/// **THE MUST NOT LIVES HERE.** SPEC §3.1 ⟨0.24⟩: "An engine MUST NOT re-derive, widen, or re-classify
/// anything while serving this verb … In particular a report entry that is ABSENT is absent — the ⟨0.21⟩
/// purity claim — and MUST NOT be back-filled from a callgraph sidecar or a chained dep." Each of the
/// following is something this codebase's OTHER loaders do and this function does not:
///   • no `.callgraph.json` sidecar — `loadFixModel` (fix/fix-gate/tour) merges it, so a fn absent from
///     `functions` still gets edges there. Here it is not opened, and an absent fn has no entry at all;
///   • no `.hierarchy.json`, no protocol CHA;
///   • no dep chaining — `loadDepReports` (Deps.swift) joins CANDOR_DEPS / the `.candor/config` `deps`
///     key into the effect sets during a SCAN. It is not called on this path, so a chained dep cannot
///     give an absent entry its effects;
///   • no re-classification — `hosts`/`cmds`/`paths`/`tables`/`netClass` are taken verbatim. They are
///     already transitive on the wire (main.swift writes the fixpointed accumulators), so no literal is
///     re-matched and no host is re-mapped through THIS machine's `net-partner` config.
/// ⟨0.28⟩ The report FILES a `gate --report` locator names — the SAME three-way rule and the same
/// sibling walk as `loadGateReport` below, kept adjacent so the guard and the loader cannot drift about
/// what this verb reads. Exists for the input-collision guard in `runGateReportCLI`: the guard used to
/// compare the sink against the raw LOCATOR only, and the locator is a prefix — so a `--gate-json`
/// naming one of the expanded siblings armed over the very report the gate was asked to judge. Quiet
/// and side-effect free (it runs in the pre-parse, before any diagnostic is owed).
///
/// ⟨0.28⟩ AND THE §2.2 SIDECARS OF EACH REPORT (the same clause's second consequence: a report locator
/// names the PAIR). The first version of this list carved the sidecars OUT — the gate opens none, so
/// they read as not-inputs — and the family measurement the same day showed why that half matters:
/// `gate --report r --gate-json r.<Unit>.Swift.callgraph.json` armed over the sidecar, the report then
/// loaded FINE, and a REAL verdict landed where the graph belongs at exit 1 — a success, with the pair
/// destroyed one half at a time. `withGateReportSidecars` appends the reserved-segment family of each
/// report (existing files only — the guard protects data). `gate` is deliberately NOT in the walk:
/// `<stem>.gate.json` is the verdict sink's own beside-the-report layout — the exact spelling
/// `--gate-json` exists for — and the regression test pins that it still gates with a real verdict.
func gateReportInputFiles(_ prefix: String?) -> [String] {
    guard let prefix else { return [] }
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        return withGateReportSidecars([prefix])
    }
    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    return withGateReportSidecars(names.sorted()
        .filter { $0.hasPrefix(base + ".") && $0.hasSuffix(".Swift.json")
                    && !$0.hasSuffix(".callgraph.json") && !$0.hasSuffix(".hierarchy.json") }
        .map { dir + "/" + $0 })
}

/// The §2.2 reserved-segment sidecars paired to each report path, appended to the report list — the
/// five data segments the family writes (`callgraph`/`hierarchy` here; `locs`/`calibrated`/`layerreach`
/// from the sibling engines, walked too because `gate --report <a foreign .json>` is supported and its
/// pair deserves the same guard). Existing files only; see `gateReportInputFiles` for why `gate` and
/// `encountered-*` are not in the walk.
private func withGateReportSidecars(_ reports: [String]) -> [String] {
    let fm = FileManager.default
    var out: [String] = []
    for r in reports {
        if r.hasSuffix(".json") {
            let stem = String(r.dropLast(".json".count))
            for seg in ["calibrated", "callgraph", "hierarchy", "layerreach", "locs"] {
                let side = "\(stem).\(seg).json"
                if fm.fileExists(atPath: side) { out.append(side) }
            }
        }
        out.append(r)
    }
    return out
}

private func loadGateReport(prefix: String) -> GateReportEnvelope? {
    let fm = FileManager.default
    var env = GateReportEnvelope()
    var found = false

    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        // §3.3.1: a path ending `.json` is that single report file, whatever its internal dot-segments —
        // so this engine can gate a report another engine wrote, by its exact path.
        return mergeGateReport(prefix, into: &env) ? env : nil
    }

    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    for name in names.sorted() where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.json") {
        // The sidecars share the prefix and the `.json` tail; they are NOT reports and are never read.
        if name.hasSuffix(".callgraph.json") || name.hasSuffix(".hierarchy.json") { continue }
        if !mergeGateReport(dir + "/" + name, into: &env) { return nil }
        found = true
    }
    return found ? env : nil
}

/// ⟨0.24⟩ THE REPORT ROUTE INTO THE GATE — a signature read from a written report, with no scan and no
/// classifier. The counterpart of `gateInputFromScan`; both feed the one `evaluateGate`.
///
/// `surfaceIncomplete` is left EMPTY, and that is why the caller REFUSES every AS-EFF-008 `allow` rule:
/// the marker does not ride the ⟨0.24⟩ wire in any form, and leaving the map empty would fail OPEN (a
/// masked command beside a benign literal would be CERTIFIED). Reconstructing it from
/// `netClass ∋ unknown-host` is NOT available either — `netDestClass` returns that token for any host it
/// does not recognise, so it also names a merely unrecognised, fully-visible host (measured on the
/// reference engine, where the reconstruction flagged 2 functions the scan passes).
///
/// The one thing computed here is the TRANSITIVE closure of the reason classes, because `unknownWhy` is
/// direct-only by contract (SPEC §4) while §6.2 resolves the class set over the gate's own reach. It runs
/// the SHARED `propagate` over the REPORT's own `calls` edges: report data in, report data out, and the
/// same fixpoint the scan route uses, so the two cannot drift.
private func gateInputFromReport(_ env: GateReportEnvelope) -> GateInput {
    var inferred: [String: Set<String>] = [:]
    var edges: [String: [String]] = [:]
    var edgeSets: [String: Set<String>] = [:]
    var whyDirect: [String: Set<String>] = [:]
    var netClasses: [String: [String]] = [:]
    var hosts: [String: Set<String>] = [:], cmds: [String: Set<String>] = [:]
    var paths: [String: Set<String>] = [:], tables: [String: Set<String>] = [:]
    // ⟨0.32⟩ KEY BY `hash`, NEVER BY BARE `fn` — SPEC §2.2, and the reason it is a MUST. MEASURED on the
    // family's other engines: `gate --report` over one member REFUSED a scoped rule at exit 2, and the
    // SAME member gated beside an unrelated sibling exited 0 with `policy ✓`. Adding a report — strictly
    // more information — turned a red verdict green, because two same-named functions in different
    // packages merged into one node.
    //
    // WHY UNION IS NOT THE SAFE DIRECTION HERE. Union is safe for EFFECTS: adding effects only adds
    // violations. It is NOT safe for REASON CLASSES, because a reason set is what makes an `Unknown`
    // ANSWERABLE — an `Unknown` with no reachable reason is unanswerable and the gate REFUSES, so
    // borrowing a reason from an unrelated same-named function converts that refusal into an answer.
    // Union turns "I cannot say" into "I checked, it's fine".
    var display: [String: String] = [:]
    // ⟨0.32⟩ KEY -> the producer's OWN `hash`, VERBATIM off the wire, for the verdict row's §2 identity.
    // Never re-derived here from `package` + `fn`: the scan route builds its copy from the package it
    // scanned, and §3.1 makes the two documents byte-equal — two derivations of one string is how they
    // would drift. An entry carrying no `hash` contributes no mapping, and its row omits the field.
    var hash: [String: String] = [:]
    // THE EDGES NEED RESOLVING TOO, which is what makes this more than a key swap: `calls` names callees
    // by BARE `fn`, so hash-keying the NODES alone leaves the call graph joining by name one layer down —
    // the same defect, harder to see because the node table looks right. A callee resolves only when
    // exactly ONE unit in the set declares that name; an ambiguous one contributes NO EDGE and instead
    // CONTRIBUTES `dispatch`, because dropping it silently is how the caller keeps a reason of its own,
    // stays answerable, and passes.
    var byName: [String: Set<String>] = [:]
    for e in env.entries { byName[e.fn, default: []].insert(entryKey(e)) }

    for e in env.entries {
        let k = entryKey(e)
        // The KEY is what every accumulator is keyed by; the NAME is what a policy scope matches and what
        // the verdict prints. Keeping both is the whole point — see GateInput.display.
        display[k] = e.fn
        if !e.hash.isEmpty { hash[k] = e.hash }
        // UNION on a repeated KEY: two entries sharing a hash are ONE unit by construction, so here the
        // union is this engine's own unit semantics rather than a guess about two functions.
        inferred[k, default: []].formUnion(e.inferred)
        var ambiguous = false
        for c in e.calls {
            guard let cands = byName[c] else { continue }
            if cands.count == 1 { edgeSets[k, default: []].insert(cands.first!) }
            else { ambiguous = true }
        }
        // …the ambiguity CONTRIBUTED as evidence at this entry, before the fixpoint. `dispatch` is the
        // right class by the vocabulary's own definition ("unresolved virtual/dynamic dispatch, SAME-NAME
        // AMBIGUITY"), and it is evidence the MERGE holds — it saw two declarers — never a class borrowed
        // from another function's body, so it cannot make some other fn's `Unknown` answerable.
        if ambiguous {
            inferred[k, default: []].insert("Unknown")
            whyDirect[k, default: []].insert("dispatch")
        }
        if !e.hosts.isEmpty { hosts[k, default: []].formUnion(e.hosts) }
        if !e.cmds.isEmpty { cmds[k, default: []].formUnion(e.cmds) }
        if !e.paths.isEmpty { paths[k, default: []].formUnion(e.paths) }
        if !e.tables.isEmpty { tables[k, default: []].formUnion(e.tables) }
        if !e.netClass.isEmpty {
            netClasses[k] = Array(Set(netClasses[k] ?? []).union(e.netClass)).sorted()
        }
        for why in e.unknownWhy { whyDirect[k, default: []].insert(reasonClass(why)) }
        // ⟨0.24⟩ SPEC §6.2's CONTRIBUTION, on the one route where the producer-side repair cannot reach.
        // A report is DATA: this engine's scan already records an `unknownWhy` beside every `Unknown` it
        // raises (the §4 invariant, pinned by UnknownMarkerInvariantProcessTests), but that says nothing
        // about a hand-authored or foreign report. An entry that raises `Unknown` DIRECTLY and names no
        // reason for it CONTRIBUTES `unresolved` — here, at the ENTRY, BEFORE the fixpoint, which is what
        // makes it COMPOSE: a caller of one reasonless entry and one `dispatch:` entry accumulates
        // {unresolved, dispatch} and is caught by both filters. Contributing at the JOIN instead (an
        // empty-set default, which `evaluateGate` still carries as a fail-closed backstop) cannot do that
        // — by then the two sets are unioned and the caller of both is byte-identical to the caller of the
        // reasoned one alone, the §6.2 counterexample in which ADDING a call turned a red verdict green.
        //
        // GATED ON A DIRECT `Unknown` IT DID NOT NAME, never on the reason set being empty, because
        // emptiness is ALSO what an INHERITED `Unknown` looks like and marking those is the mirror
        // fabrication — it would claim `unresolved` for a function whose hole is real, unmeasurable and
        // exactly what the refusal below exists to disclose. An ABSENT `direct` key reads as an empty set
        // and contributes NOTHING: that is a report which did not carry the channel, not a claim of a
        // direct `Unknown`. Same shape as candor-rust `gate.rs` and candor-java `Loader`.
        if e.direct.contains("Unknown"), e.unknownWhy.isEmpty {
            whyDirect[k, default: []].insert("unresolved")
        }
    }
    for (fn, cs) in edgeSets { edges[fn] = cs.sorted() }
    return GateInput(inferred: inferred,
                     reasonClasses: propagate(whyDirect, over: edgeSets),
                     netClasses: netClasses,
                     hosts: hosts, cmds: cmds, paths: paths, tables: tables,
                     surfaceIncomplete: [:],
                     edges: edges,
                     display: display,
                     hash: hash)
}

// ── answerability (SPEC §3.1 ⟨0.24⟩) ────────────────────────────────────────────────────────────────

/// THE THIRD ANSWERABILITY CASE — a class-scoped `deny` filter over a report that cannot answer it.
/// Returns the refusal message, or nil when every scoped filter is answerable.
///
/// A bare `deny Net` / `deny Unknown` asks a question the effect set alone answers. A SCOPED one —
/// `deny Net[unknown-host]`, `deny Unknown[dispatch]` — asks a second question ("…and is the destination
/// / the reason class one of THESE?") and NARROWS the gate on the answer. When the report does not carry
/// the evidence for that second question the fields it reads are simply absent, the matcher sees an
/// empty set, nothing matches, and the effect is DROPPED from the violation. **The narrowing succeeds
/// because the evidence is missing** — an absence-keyed relaxation of a fail-closed security gate, and a
/// silent one, because the scoped rule is exactly the one a hardening team reaches for.
///
/// MEASURED on this engine with this check disabled, one function per hand-built report (the two
/// signatures are the fixtures of `GateReportVerbProcessTests.testScopedDenyOverAnAbsentScopingFieldIs\
/// Refused` and `…testScopedUnknownDenyWithNoReachableReasonIsRefused`, which assert the BARE arms too —
/// that is what makes the scoped exit 0 a relaxation rather than a signature that simply does not violate):
///
///     report                                     deny Net[unknown-host]   deny Net
///     Net-bearing entry, netClass ABSENT         exit 0  ← green          exit 1
///
///     report                                     deny Unknown[dispatch]   deny Unknown
///     Unknown, no `unknownWhy`, no `calls` edge  exit 0  ← green          exit 1
///
/// (`deny Unknown[unresolved]` DOES fire on the second row, via §6.2's reasonless-Unknown default in
/// `evaluateGate` — so the fail-open there is class-dependent, which makes it harder to notice, not less
/// real: `dispatch`, `reflect`, `native`, `indirect` and `setup` all read green.)
///
/// ⟨0.24⟩ **THE REFUSAL IS MINIMAL, AND MONOTONE DENIAL IS WHAT MAKES THAT SAFE** (SPEC §3.1). A
/// class-scoped `deny` is not unanswerable merely because some evidence is missing: the class set only
/// ever GROWS (§6.2 — a reason is CONTRIBUTED, never retracted) and `Reject` is upward-closed in it
/// (PAPER3 Lemma 2). So when the classes determinable FROM THE ENTRY ALONE are non-empty the rule is
/// ANSWERED — it fires or it does not, and no further evidence could change which. Only an EMPTY
/// determinable set leaves the question open, and that is the only state refused here.
///
/// This engine refused one case it could answer, and SPEC §3.1 records the over-broad refusal by name:
/// a reasonless DIRECT `Unknown` under `deny Unknown[unresolved]`. MEASURED on a one-entry report
/// (`app.direct`, `inferred: [Unknown]`, `direct: [Unknown]`, no `unknownWhy`, no `calls`):
///
///     deny Unknown[unresolved]              rust 1   ts 1   java 1   swift 2   ← over-broad
///     deny Unknown[unresolved] app.direct   rust 1   ts 1   java 1   swift 2   ← and with a scope
///
/// Exit 2 there is not wrong in the fail-closed sense; it is a WORSE answer than the correct one, and a
/// verb whose value is being a pure function of its input should not decline questions it can answer. The
/// repair is in `gateInputFromReport`, not here — `unresolved` is CONTRIBUTED at the entry, so the set is
/// no longer empty and this predicate simply stops firing on it. Nothing in this function changed.
///
/// Refusing costs nothing on a report THIS engine wrote, which is what keeps the equivalence obligation
/// satisfiable: `netClass` is emitted for every `Net`-bearing entry and is floored at `unknown-host`
/// (`netClassesOf` inserts it whenever no host is visible), so an empty set on a `Net` entry means "this
/// producer did not carry the field", never "this function reaches nothing"; and an `Unknown` that is
/// INHERITED comes from a callee carrying `Unknown`, which is therefore effectful and present in `calls`
/// by construction, while a DIRECT `Unknown` records its `unknownWhy` at the site (pinned by
/// UnknownMarkerInvariantProcessTests).
///
/// Per (rule, function), NOT per policy: a scoped rule whose matched functions all carry their evidence
/// evaluates normally, and only the rule that would have been silently narrowed is refused.
///
/// ⟨0.24⟩ RETURNS EVERY UNANSWERABLE RULE, not the first. SPEC §3.1: *"The refusal message MUST still
/// disclose which rules could not be evaluated — exit 1 reports the violation it is sure of, it does not
/// conceal the part it could not read."* Now that a refusal can be OVERRULED by a certain violation (the
/// precedence correction below), this list is a DISCLOSURE that has to travel ALONGSIDE a verdict rather
/// than being the whole output, and one rule out of three is a partial disclosure. At most one message
/// per RULE — the first function that defeats it is the example; naming every match would bury the rule.
///
/// ⟨0.24⟩ Each entry carries the RAW policy line separately from the prose, because `fc4b5f6` pins
/// `unevaluated[].rule` to the verbatim line: a `why` that MENTIONS the rule is not a field a consumer
/// can read it out of.
///
/// ⟨0.24⟩ **THE PREDICATE ITSELF NOW LIVES IN `CandorCore.unanswerableCells`**, and this is an adapter.
/// SPEC §3.2 makes the advisory verbs' confidence a COMPARISON against this one — `unverified` must name
/// what the gate could not judge, `fix-gate` must not plan around it — and a comparison checked from two
/// implementations of the thing being compared is not checked at all. The prose, the iteration order and
/// the one-entry-per-rule granularity are unchanged, so this verb's bytes are the bytes it emitted
/// before (R6 pins that four-way).
private func unanswerableScopedFilters(_ deny: [DenyRule], _ gi: GateInput) -> [Unevaluated] {
    let cells = unanswerableCells(inferred: gi.inferred,
                                  reasonClasses: gi.reasonClasses,
                                  netClasses: gi.netClasses.mapValues(Set.init),
                                  deny: deny,
                                  display: gi.display)
    return unansweredDisclosure(cells).map { Unevaluated(rule: $0.rule, why: $0.why) }
}

// ── the CLI ─────────────────────────────────────────────────────────────────────────────────────────

/// `candor-swift gate --report <locator> --policy <file> [--json] [--gate-json <file>]`
///
/// A QUERY verb, not a scan flag, so it inherits §3.3.1's grammar unchanged: the same `--report` locator
/// rules and discovery fallback (`resolveReportLocator`/`discoverReportPrefix`), the same `--policy`
/// fallback (`discoverPolicy` — CANDOR_POLICY, then the config `policy` key), the same loud exit 2 on an
/// unreadable policy, and NO positionals — `gate` has no argument of its own, and a swallowed token is
/// how a gate runs green.
///
/// `--json` IS `--gate-json -`, deliberately: on a scan `--json` emits the REPORT, and there is no report
/// to emit here, so the verb's machine output is the verdict. A second meaning for `--json` would be the
/// one place a consumer could tell the two routes apart.
/// ⟨0.29⟩ THE TWO WHOLE-POLICY UNANSWERABLE KINDS, as a function so every report route shares one.
///
/// `forbid` and `allow` cannot be answered from a §2 report (SPEC §3.1 ⟨0.24⟩ ANSWERABILITY). This lived
/// INLINE in `gate --report` and only there, so the advisory verbs reading the same report never saw it:
/// MEASURED, `unverified` and `fix-gate` over a `forbid`-only policy both emitted `{"ok": true, …}` at
/// exit 0 — a certification relative to a gate that never evaluated the policy's only rule. candor-java,
/// the reference engine, disclosed and withheld `ok` on both; rust, ts and swift did not. Extracted
/// rather than copied, because copying is how the gate and its siblings diverged in the first place.
func wholePolicyRefusals(_ pol: ParsedPolicy, _ policyPath: String) -> [Unevaluated] {
    var policyRefusals: [Unevaluated] = []
    for r in pol.forbid {
        // ⟨0.29⟩ NAME THE RULE, not a count of its kind. MEASURED across the family on one fixture: rust
        // and java open with the rule text, and candor-ts opens with it too — this engine was the ONLY
        // one that did not, printing "this policy has 1 `forbid` rule(s)" instead. An operator handed a
        // COUNT has to go and diff the policy to learn which line stopped their gate, and with two rules
        // every entry said "this policy has 2 rule(s)" — a fact about the file, attached to a row that
        // is about one line of it. The `rule` field always carried the text for a MACHINE; the human
        // channel was the half answering a different question.
        policyRefusals.append(Unevaluated(rule: r.raw, why:
            "`\(r.raw.trimmingCharacters(in: .whitespaces))` is a `forbid` rule, which "
                   + "`gate --report` cannot evaluate — a report carries an entry only for a function with an "
                   + "EFFECT, so a wholly pure unit has no entry and no edges at all, while `forbid` matches "
                   + "on NAME. The rule would read green over a crossing a scan fails on. Gate layering at "
                   + "scan time: candor-swift <dir> --policy \(policyPath)"))
    }
    // ⟨0.29⟩ `only` IS AS UNANSWERABLE AS `forbid`, and for a STRICTER reason. Both match on NAME, which a
    // report's effect-relevant wire cannot settle — but `forbid` asks whether ONE named crossing is
    // present, while `only` asks whether EVERYTHING reached is on a list. A report that omits a crossing
    // makes `forbid` read green; it makes `only` read green as a claim of COMPLETENESS.
    for r in pol.only {
        policyRefusals.append(Unevaluated(rule: r.raw, why:
            "`\(r.raw.trimmingCharacters(in: .whitespaces))` is an `only` rule, which `gate --report` "
               + "cannot evaluate — it asks whether EVERYTHING a scope reaches is on a list, and a report "
               + "carries an effect-relevant call surface rather than the complete dependency graph a "
               + "NAME-matching rule needs. Answering it here would certify completeness from evidence "
               + "that is not complete. Gate permissions at scan time: candor-swift <dir> --policy "
               + "\(policyPath)"))
    }
    if !pol.allow.isEmpty {
        for r in pol.allow {
            // …AND ITS SIBLING, in the same change. `allow` is the kind no conformance row anywhere
            // writes into a `.pol` file, so it had nothing watching it at all — closing one spelling of
            // a channel while its sibling stays open is how the defects in this file got in.
            policyRefusals.append(Unevaluated(rule: r.raw, why:
                "`\(r.raw.trimmingCharacters(in: .whitespaces))` is an `allow` rule, "
                   + "which `gate --report` cannot evaluate — the AS-EFF-008 surface-completeness marker WAS said "
                   + "not to ride the report wire; ⟨0.29⟩ made it ride, but only when the producing "
                   + "report declares `incomplete` in `resolves`. This verb refuses UNIFORMLY rather "
                   + "than answering per-report, because an engine that evaluated where its siblings "
                   + "refuse would SPLIT THE VERB — a benign visible literal beside a runtime-computed "
                   + "endpoint would be CERTIFIED here and flagged by a scan. (`netClass: unknown-host` "
                   + "is NOT that marker — it also names a merely unrecognised host.) Gate allowlists at scan time: "
                   + "candor-swift <dir> --policy \(policyPath)"))
        }
    }
    return policyRefusals
}

func runGateReportCLI(_ args: [String]) -> Never {
    let usage = "usage: candor-swift gate --report <locator> --policy <file> [--json] [--gate-json <file>]"
    // ── SPEC §3.3.1 ⟨0.27⟩ ARM FIRST, AND NEVER OVER AN INPUT.
    //
    // REGISTERING A SINK IS NOT ARMING. The sink list below only covers refusals routed through
    // `gateDie`, and main.swift's own comment says exactly this about the scan path — a crash, an OOM, a
    // CI timeout or a `kill -9` all leave the PREVIOUS run's green document on disk. Enumerating exits
    // is the approach that keeps missing one. It also ran AFTER the flag loop, so an unknown flag exited
    // with the stale document untouched while the same mistake spelled the other way round refused,
    // which made the contract depend on argv ORDER.
    //
    // And arming WRITES, so a sink naming the policy destroys it: measured on this engine's scan path as
    // a red gate exiting 0 with `"ok": true` over a policy that no longer existed.
    let pre = preScanSinkAndInputs(["gate"] + args)
    if let gp = pre.gate {
        // §3.3.1 names "a report being read (`gate --report`)" as an input: writing the verdict there
        // destroys the very report the gate was asked to judge.
        var reportFlag: String? = nil
        for (i, a) in args.enumerated() where a == "--report" && i + 1 < args.count {
            if !args[i + 1].hasPrefix("-") { reportFlag = args[i + 1] }
        }
        refuseGateJsonOverInput(gp, reportFlag, "--report")
        // ⟨0.28⟩ …AND THE FILES THE LOCATOR EXPANDS TO, because the raw flag value is not what this verb
        // READS. A locator is a PREFIX (or a discovery), and the loader below walks its
        // `<prefix>.*.Swift.json` siblings — so `--gate-json <one of those siblings>` named an input by
        // any honest reading and the guard compared only the unexpanded string. MEASURED on this engine
        // 2026-08-12: `gate --report r --gate-json r.B.Swift.json` armed over the operator's own report,
        // the load then failed on the wreckage, and the refusal document was written over it AGAIN at
        // exit 2 — the same scan-target class the ⟨0.28⟩ review caught family-wide, one verb over. The
        // discovery case is covered too: with no `--report` at all, the reports this gate is about to
        // read from the discovered `.candor/` are inputs just the same. Exact artifacts, enumerated by
        // the same three-way rule the loader applies — the dep-dir precedent in `runInputs`, not a
        // containment rule.
        for f in gateReportInputFiles(reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()) {
            refuseGateJsonOverInput(gp, f, "a report this gate reads —")
        }
        // The gate verb's policy fallback is CWD-anchored (CANDOR_POLICY, then the config discovered
        // from the CWD), so the config channel must be enumerated from "." — anchoring it at the REPORT
        // asked a different directory's question and left a config-declared policy unguarded.
        refuseGateJsonOverAnyInput(gp, ".", pre.policy)
        // ⟨0.28⟩ THE RUNG BINDS EVERY ROUTE, and it shipped on the scan CLI only — so this verb kept
        // last-wins and a gate that FIRED left the first named sink holding a previous run's
        // `{"ok": true}`. Every named sink gets the input checks too; the input exemption covers THAT
        // PATH, not the run.
        let namedSinks = distinctGateSinks(allGateSinks(args))
        if namedSinks.count > 1 {
            for sNamed in namedSinks where sNamed != "-" {
                refuseGateJsonOverInput(sNamed, reportFlag, "--report")
                // ⟨0.28⟩ the expanded report set, exactly as the single-sink path asks it above.
                for f in gateReportInputFiles(reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()) {
                    refuseGateJsonOverInput(sNamed, f, "a report this gate reads —")
                }
                refuseGateJsonOverAnyInput(sNamed, ".", pre.policy)
            }
            let list = namedSinks.joined(separator: ", ")
            FileHandle.standardError.write(
                ("candor-swift gate: --gate-json given more than once (\(list)) — refusing (exit 2). A gate "
                 + "publishes ONE verdict. Naming two sinks says where it goes twice, and the reader of the "
                 + "path that loses cannot tell it lost.\n").data(using: .utf8)!)
            gateVerdictSinks = namedSinks
            refuseGateAndExit("candor-swift gate: --gate-json was given more than once (\(list)) — a run "
                              + "publishes one verdict to one sink")
        }
        if gp != "-" { armGateJsonFailClosed(gp) }
        // …AND THE STREAM SINK MUST BE REGISTERED HERE, which it was not. `armGateJsonFailClosed`
        // writes a fail-closed placeholder to a FILE; a stream cannot hold one, so the stream's analog
        // is being in `gateVerdictSinks` before anything can exit — `refuseGateAndExit` already knows
        // how to write "-" to stdout, it just had an empty sink list to write to.
        //
        // The SCAN path registers it (main.swift). This verb did not, so an exit-2 during argument
        // parsing left stdout EMPTY while the very same verb, refusing later from inside `gate()`,
        // streamed the document. Measured across the family at the 0.27 go/no-go: java, ts and swift
        // all had this hole on the gate verb, and PART 36's stream rows never caught it because every
        // one of them runs the scan route.
        else if !gateVerdictSinks.contains("-") { gateVerdictSinks.append("-") }
    }
    var reportFlag: String?, policyFlag: String?, gateJsonPath: String?
    var wantJson = false
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": wantJson = true
        // SPEC §3.2 ⟨0.28⟩: "given no value" MEANS the next token is flag-shaped — consuming it as a
        // filename made this very diagnostic unreachable (no argv could produce it) and reinterpreted
        // the command line: `--policy --gate-json -` read *policy = the file named `--gate-json`* and
        // diagnosed the displaced `-` as an unknown flag, the operator's sink token as an "unexpected
        // argument". Measured on this verb 2026-08-12 (both sink spellings stayed fail-closed — the
        // pre-pass leaves a flag-shaped token live, so the sink after the broken flag was
        // registered/armed before this refusal — but the CAUSE was the §6.2 silent reinterpretation
        // one position over). A bare `-` stays a value and fails loud as an unreadable file a moment
        // later; `./--weird` spells a file genuinely named like a flag. `gateDie` routes through
        // `refuseGateAndExit`, so the refusal document reaches every registered sink.
        case "--report":
            guard let v = it.next() else { gateDie("candor-swift: --report requires a value (\(usage))") }
            guard v == "-" || !v.hasPrefix("-") else {
                gateDie("candor-swift: --report was given no value — the next token `\(v)` is a flag, "
                        + "not a locator (a path really named that is spelled ./\(v))")
            }
            reportFlag = v
        case "--policy":
            guard let v = it.next() else { gateDie("candor-swift: --policy requires a value (\(usage))") }
            guard v == "-" || !v.hasPrefix("-") else {
                gateDie("candor-swift: --policy was given no value — the next token `\(v)` is a flag, "
                        + "not a path (a file really named that is spelled ./\(v))")
            }
            policyFlag = v
        case "--gate-json":
            // The scan path's own dash-check, so `--gate-json --policy p` cannot swallow `--policy` and
            // run gateless-green. `-` (stream the verdict to stdout) is the one dash-shaped value allowed.
            guard let v = it.next(), v == "-" || !v.hasPrefix("-") else {
                gateDie("candor-swift: --gate-json requires a value (a path, or `-` for stdout)")
            }
            gateJsonPath = v
        case "--text", "--human": continue   // candor-ts output-mode flags (#8); swift prose is the default
        default:
            // A stray positional is a USAGE error, never ignored: `gate` takes none, so a swallowed token
            // (a mistyped locator, say) would otherwise gate a discovered report and read green.
            gateDie(a.hasPrefix("-") ? "candor-swift: unknown flag \(a) (\(usage))"
                                     : "candor-swift gate: unexpected argument `\(a)` (\(usage))")
        }
    }
    // ⟨0.24⟩ From here on EVERY exit-2 cause writes the refusal document (SPEC §3.1, candor-spec
    // `1503368`): a stale green on disk does not care why this run declined to overwrite it, so the
    // argument that required a document for an answerability refusal is exactly as true for an unreadable
    // policy or a report that never loaded AS one. `--json` IS `--gate-json -` here, on this path too.
    if wantJson { gateVerdictSinks.append("-") }
    if let p = gateJsonPath, !(wantJson && p == "-") { gateVerdictSinks.append(p) }

    guard let policyPath = policyFlag ?? discoverPolicy() else {
        gateDie("candor-swift gate: a policy is required — pass `--policy <file>`, set CANDOR_POLICY, or "
                + "add a `policy` key to .candor/config. `gate` applies a policy to an existing report; "
                + "with no policy there is no verdict to give.")
    }
    guard let policyText = try? String(contentsOfFile: policyPath, encoding: .utf8) else {
        gateDie("candor-swift gate: policy \(policyPath) could not be read — failing (exit 2), policy NOT evaluated")
    }
    // ⟨0.19⟩ `unknown-alias` expansion for an `Unknown[<alias>]` filter, anchored to the POLICY file
    // exactly as `parsepolicy` anchors it — an alias is part of the policy's own vocabulary, not of the
    // report. The ⟨0.20⟩ `net-partner` list is deliberately NOT loaded: `netClass` is read verbatim from
    // the report, so re-classifying its hosts through THIS machine's config would be the re-derivation
    // §3.1 ⟨0.24⟩ forbids (and would make the verdict depend on the consumer's CWD).
    let vocabConfig = discoverConfig(targetPath: policyPath)
    let parsedAliases = parseUnknownAliases(vocabConfig?.text)
    let pol = parsePolicy(policyText, aliases: parsedAliases.aliases)
    // ⟨0.24⟩ SPEC §3.1: the config file is named in the verdict only when its vocabulary PARTICIPATED.
    // ⟨0.24⟩ …and `aliases` maps each consumed alias to the CLASSES it expanded to — see
    // `consumedAliasVocabulary`, shared with the scan route so the two documents cannot disagree.
    let policyVocabulary: (config: String, aliases: [String: [String]])? =
        pol.usedAliases.isEmpty ? nil
        : vocabConfig.map { (config: $0.path,
                             aliases: consumedAliasVocabulary(pol, parsedAliases.aliases)) }
    // ⟨0.24⟩ AN UNRECOGNISED REASON-CLASS TOKEN IS A POLICY ERROR (SPEC §6.2) — the UNREADABLE-POLICY
    // posture, so exit 2 with NO verdict document, before the report is even opened. Not a refusal in the
    // §3.1 answerability sense: nothing about THIS report is at issue, the policy could not be read as
    // written at all, and §3.1's byte-equality then holds on a broken policy by there being nothing to
    // disagree about. See `policyClassTokenError` (Policy.swift) for the two measured harms.
    // ⟨0.24⟩ the ALIAS DEFINITION's own tokens take the same rule (candor-spec `be0b9a9`): a typo in the
    // vocabulary the policy is written AGAINST fails open identically, and more quietly.
    // ⟨0.24⟩ …and ONLY when a rule of THIS policy consumed the definition — the same gate the scan route
    // applies, from the same function, because a definition no token expands cannot change a verdict and
    // config discovery walks PARENTS (one bad token above the repo would otherwise red-refuse the whole
    // subtree). See `partitionAliasErrors`.
    let aliasErrors = partitionAliasErrors(parsedAliases.errors, consumedBy: pol)
    discloseUnconsumedAliasErrors(aliasErrors.disclosed)
    let policyErrors = aliasErrors.refusing.map(\.message) + pol.gateRefusals
    if !policyErrors.isEmpty { gateDie(policyErrors.joined(separator: "\n")) }
    // ⟨0.28⟩ A CONFIGURED POLICY THAT YIELDED ZERO RULES (SPEC §6.2) — THE SIBLING OF THE SCAN CLI'S CHECK,
    // and one predicate serves both (`zeroRulePolicyRefusal`, Gate.swift, where the measurement and the
    // every-rule-vector argument are recorded). §6.2 states the defect was measured on this verb too and
    // that "a route is not covered by its sibling": the scan CLI got the rung in `5552a36` and THIS route
    // kept exiting 0 with `{"ok":true,"violations":[]}` over a README — measured on this engine
    // 2026-08-11, for all three input forms (every line ignored / empty file / comments only).
    //
    // It matters MORE here than on the scan route. `gate --report` is the supply-chain surface: the verb an
    // adopter points at a report someone else produced, in the CI step whose whole job is to decide whether
    // that dependency may land. A mistyped `--policy` path there gates nothing and says `ok: true`.
    //
    // AN OUTRIGHT REFUSAL, not `refuseUnlessAViolationStands`'s dominance dance, because on this route no
    // certain violation can stand beside it: the only findings this verb produces come from `evaluateGate`
    // over `denyOnly`, which has nothing to evaluate when there are zero rules, and there is no AS-EFF-005
    // baseline on the report wire. So this takes the posture of the two branches it sits between (an
    // unreadable policy, an unhonourable token): exit 2 with the refusal document, before the report is
    // even opened — nothing about the REPORT is at issue.
    //
    // The two rows this could have got wrong were MEASURED against a rebuild of the pre-change tree rather
    // than assumed: an `allow`-only and a `forbid`-only policy ALREADY refuse on this route (exit 2), one
    // branch below, for their own unrelated and specific reasons — the AS-EFF-008 surface-completeness
    // marker does not ride the report wire, and a report carries no entry for a pure function so `forbid`
    // cannot match on NAME. Both name their own cause in the `reason`, not this one, and they must keep
    // doing so: reading the deny vector alone here would relabel every allowlist gate as an absent one.
    if let zr = zeroRulePolicyRefusal(pol, at: policyPath, who: "candor-swift gate") {
        refuseGateAndExit(zr.why, unevaluated: zr.unevaluated)
    }

    // THE POLICY-LEVEL REFUSALS. Whole-policy, not per-rule: enforcing the answerable half and exiting 0
    // is gateless-green — the user believes a rule is enforced that never ran.
    //
    // ⟨0.24⟩ **COLLECTED, NOT EXITED ON** (SPEC §3.1, candor-spec `1503368`, which removes this carve-out).
    // These used to return 2 here, before the report was even opened, so a firing `deny Fs` standing beside
    // a `forbid` rule exited 2 with the certain violation absent from the document — the same harm the
    // precedence fix closed one rung up, surviving under a different rule kind. Lemma 2 does not care WHICH
    // kind of refusal stands beside the firing rule. The whole-policy granularity governs which rules go
    // UNEVALUATED; it was never a licence to suppress a violation that was evaluated and certain.
    //
    // The `allow`/`forbid` rules themselves are still never evaluated: `denyOnly` below hands
    // `evaluateGate` the deny rules alone, so no AS-EFF-008 can be certified off a wire that does not carry
    // the surface-completeness marker.
    //
    // ⟨0.24⟩ **ONE ENTRY PER RULE, KEYED ON THE RAW LINE** (SPEC §3.1, candor-spec `fc4b5f6`). The refusal
    // is still decided whole-policy — every `forbid` is unanswerable for the same reason — but the
    // DISCLOSURE is per rule, because the operator's question is *which* and an aggregate answers *how
    // many*. candor-java emits `"forbid (× 2)"` and loses which two; that satisfies a naive reading of
    // "disclose which rules" while answering the other one.
    let policyRefusals = wholePolicyRefusals(pol, policyPath)
    // ⟨0.29⟩ `only: []` STATED, not left to the default. The refused kinds are REMOVED here, not merely
    // disclosed beside the verdict — a kind left in the object is a kind the evaluator walks, and the
    // disclosure would then stand next to the very evaluation it says did not happen. The java arm of
    // this port shipped exactly that defect for one build because its removal site was fifty lines from
    // where the kind was added; relying on a default parameter to be right is the same bet.
    let denyOnly = ParsedPolicy(deny: pol.deny, allow: [], forbid: [], only: [])

    let locator = reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()
    guard let prefix = locator else {
        gateDie("candor-swift gate: no report — pass --report <locator> or run from a repo with a .candor/ "
                + "dir (scan: candor-swift <dir>)")
    }
    // ⟨0.32⟩ SPEC §3.3.1 — did the most recent attempt over these reports REFUSE?
    //
    // Checked BEFORE they are read, because the answer does not depend on them: they may parse perfectly
    // and describe real code, and still be the output of a scan whose successor refused. This verb cannot
    // compute that — the hazard is an EVENT witnessed only by the refusing run — so the refusing run
    // writes it down and this reads it.
    if let m = refusalMarkerFor(prefix) {
        gateDie("candor-swift gate: the most recent scan over `\(m.prefix)` REFUSED — these reports are "
                + "from an earlier run and this verb will not certify them. Cause: \(m.reason). "
                + "Re-scan \(m.target.isEmpty ? "the target" : m.target); a completing run clears the marker.")
    }
    guard let env = loadGateReport(prefix: prefix) else {
        gateDie("candor-swift gate: no readable report at `\(prefix)` — nothing to gate (scan: candor-swift <dir>)")
    }
    // ⟨0.24⟩ A REPORT THAT JUDGED NOTHING IS NOT AN ALL-CLEAR (SPEC §2's three-row table, bound to this
    // verb by §3.1: "a report presented DIRECTLY to the gate with `analyzed.count: 0` makes the same claim
    // as a chained one, and must be read the same way … the obligation is on the reading, not on the route
    // by which the report arrived"). The chained half of this rule lives in Deps.swift, on the COVERAGE
    // decision; here there is no coverage decision to hang it on — the report IS the whole input — so what
    // the rule buys is the DISCLOSURE beside the verdict.
    //
    // NOT THE EXIT CODE AND NOT THE VERDICT DOCUMENT, and the spec is explicit about both after the first
    // spelling of this clause contradicted itself (SPEC §3.1 ⟨0.24⟩, corrected 2026-07-28). §3.1 makes
    // byte-equality with `scan --policy`'s `--gate-json` the acceptance test, and a scan of an empty facade
    // package exits 0 with a clean verdict — so diverging here would SPLIT THE VERB this rung exists to
    // keep single. And §3.3 enumerates exactly two exit-2 causes (a broken gate CONFIG; an INCOMPLETE
    // analysis of the target's OWN code); a judged-nothing DEPENDENCY is neither, so refusing would mint a
    // third. Beyond conformance, a verdict is an ASSERTION: the consumer has no evidence of any effect
    // here, so manufacturing one would be the fabrication mirror of the silent under-report.
    //
    // MEASURED before this landed, on a count-0 report with `deny Net`: exit 0 printing
    // `candor-swift: policy ✓` and NOTHING ELSE — a human reading "no violations" had nothing telling them
    // the gate had judged nothing at all. The machine channel was already right: `analyzed.count: 0` rides
    // the verdict document, which is what ⟨0.21⟩ put it there for. What was missing was the human one.
    if env.judgedNothing {
        FileHandle.standardError.write(
            ("candor-swift gate: the report at `\(prefix)` judged NOTHING (⟨0.24⟩ `analyzed.count` is 0, "
             + "absent with no entries, or unreadable) — a report with no judgment in it is not an "
             + "all-clear, so a green verdict below certifies NOTHING: absence from `functions` licenses "
             + "no purity claim about any unit. Re-scan the sources you meant to gate "
             + "(candor-swift <src> --out \(prefix)), or gate the report of the package that has them.\n")
                .data(using: .utf8)!)
    }
    let gi = gateInputFromReport(env)

    // ⟨0.24⟩ THE PRECEDENCE: **violation (1) > refusal (2) > incomplete (2)** (SPEC §3.1), and the first
    // rung is FORCED by Lemma 2 rather than chosen.
    //
    // The third refusal — the only one that depends on the REPORT rather than on the policy alone — is
    // COMPUTED here and ACTED ON below, AFTER the gate has run. It used to exit 2 on this line, before
    // `evaluateGate` was ever called, so a policy carrying a firing `deny Fs` PLUS one unanswerable
    // scoped rule exited 2 and wrote NO document: **the certain violation was deleted from the
    // machine-consumer channel by a rule it had nothing to do with.** MEASURED 2026-07-28 on
    // `deny Fs` + `deny Net[unknown-host] app` over a two-entry report — exit 2, no `--gate-json` file,
    // the `Fs` finding gone from every machine channel. Byte-identical in harm to the ⟨0.21⟩
    // incomplete-analysis path one rung down, and it takes the same fix: compute the verdict FIRST,
    // decide the exit FROM it.
    //
    // WHY THE VIOLATION IS SAFE TO REPORT even though a rule went unanswered: if one rule FIRES on
    // evidence the report carries, the policy is REJECTED, and `Reject` is upward-closed (PAPER3 Lemma
    // 2) — however the unanswerable rule would have resolved CANNOT UN-REJECT IT. Exit 1 is therefore not
    // merely fail-closed here, it is CERTAIN, and it is strictly more informative than exit 2 because it
    // NAMES the violation. All four engines had this backwards, and the spec clause pinning
    // "refusal > violation" was corrected within the hour of being written (candor-spec `7271c69`) —
    // uniform engine agreement was the evidence for the wrong ruling.
    //
    // The refusal is NOT swallowed: when a violation dominates, every unanswerable rule is still
    // disclosed on stderr below. Exit 1 reports the violation it is sure of; it does not conceal the part
    // it could not read.
    let refused = policyRefusals + unanswerableScopedFilters(pol.deny, gi)
    let (violations, gateZeroMatchRules) = evaluateGate(denyOnly, gi)
    // ⟨0.24⟩ §3.1 — an unanswerable condition is DISCLOSED, never scored as a satisfied one. A rule whose
    // scope binds nothing was silently green: `deny Net ordrs` (one character wrong) passed where
    // `deny Net orders` failed, and `unverified` then reported the layer as PROVABLY clean.
    for raw in gateZeroMatchRules {
        FileHandle.standardError.write(
            ("candor: policy rule matched NO function — `\(raw)`. It was evaluated and bound nothing, so it "
             + "cannot have caught anything. Legitimate when one policy is shared across repos; a typo'd "
             + "layer name otherwise.\n").data(using: .utf8)!)
    }
    if violations.isEmpty, !refused.isEmpty {
        // SOLE refusal: nothing certain to report, so the gate genuinely could not be evaluated as
        // written. Exit 2 — and ⟨0.24⟩ the refusal DOCUMENT, so a CI wrapper reading `--gate-json`
        // unconditionally cannot re-read the previous run's green verdict as today's.
        if !env.unanalyzed.isEmpty {
            // Refusal (2) outranks incomplete (2) — the same exit, and the refusal is the reason no
            // verdict exists. The manifest still gets said, on the human channel.
            FileHandle.standardError.write(
                ("candor-swift gate: (the report ALSO declares \(env.unanalyzed.count) unanalyzed unit(s) — "
                 + "that alone would have been exit 2)\n").data(using: .utf8)!)
        }
        // Every unanswerable rule, joined — the message is the document's `reason`, so the human and the
        // machine channel carry the SAME disclosure rather than two drifting statements of it. ⟨0.24⟩ and
        // the SAME rules ride the refusal document as `unevaluated`, per rule and keyed on the raw line:
        // a prose `reason` is not a field a consumer can read a rule list out of.
        refuseGateAndExit("candor-swift gate: " + refused.map(\.why).joined(separator: "\n    "),
                          unevaluated: refused)
    }
    if !refused.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift gate: NOTE — \(refused.count) policy rule(s) could not be evaluated over this "
             + "report and are NOT answered by the verdict below. The verdict stands anyway: a rule FIRED "
             + "on evidence this report carries, and no resolution of an unanswered rule can un-reject a "
             + "rejected policy (SPEC §3.1, PAPER3 Lemma 2). Unanswered:\n").data(using: .utf8)!)
        for u in refused { FileHandle.standardError.write("    \(u.why)\n".data(using: .utf8)!) }
    }
    // Diagnostics go to STDERR exactly as the scan routes them, so `gate … --json | jq` sees pure JSON.
    for v in violations { FileHandle.standardError.write(("[\(v.rule)] \(v.detail)\n").data(using: .utf8)!) }
    // `--json` IS `--gate-json -`: the same document, from the same writer the scan uses, so a consumer
    // cannot tell a scanned verdict from a report-gated one.
    // DEDUPED, like the refusal path. `--json` IS `--gate-json -`, so naming both wrote the SAME
    // document twice onto one stream — two concatenated JSON objects, which parse as neither. The
    // round-2 dedupe went into `refuseGateAndExit` and covered only the REFUSAL; these verdict writes
    // kept their per-flag shape, so exit 0 and exit 1 still double-wrote while exit 2 was clean. That
    // asymmetry is why PART 36 (b6) passed: it poses the refusal path only.
    // ⟨0.32⟩ THE UNREAD CLASSES, DECIDED ONCE — the verdict document below and the exit arm at the bottom
    // read this SAME value, so they cannot disagree about a run. That split is not hypothetical: the
    // sibling port measured a document saying `ok: false` while the process exited 0, and the ⟨0.28⟩
    // REPORT-sink rung shipped its own version of it.
    //
    // **DOES THIS POLICY'S ANSWER DEPEND ON THE CODE THE PRODUCER LEFT UNREAD?** — the ONE place that
    // question is asked on this route, and now the ONLY carve-out the rule has. `mergeGateReport` used to
    // start a second one off the producer's history (`outOfScope` present ⇒ that scan was asked), and
    // that was the verified fail-open: see the note there. What survives is the condition about the
    // QUESTION rather than about the producer — only a `deny`/`pure` rule's answer depends on code
    // outside the scan's scope, which is the same short-circuit the producer's own peek applies
    // (`peekRules` in main.swift is its DENY list), so keying on it here is what makes the two routes
    // answer the same way.
    //
    // `pol.deny` IS THE RIGHT LIST AND `pure` IS IN IT — the parser appends a `pure` line as a DenyRule
    // with an EMPTY effect list (Policy.swift), so the strictest policy the grammar has arms this rule
    // like any other. Reading the question off a flattened set of effect NAMES instead would find `pure`
    // contributing nothing and silently disarm it; that is not hypothetical, it is what this engine's own
    // peek did until ⟨0.30⟩ measured `pure` passing where `deny Exec` exited 2 on the same tree.
    //
    // MEASURED AS DEFENSIVE rather than load-bearing on this engine, 2026-08-24: a policy with no deny
    // rule cannot reach this line today, because every shape that produces one exits 2 earlier and for an
    // unrelated reason (an empty/comment-only file, a `forbid`/`only` line and a valueless `allow` all
    // trip the yielded-NO-RULES refusal; a well-formed `allow` trips this verb's uniform allow-refusal).
    // Written out anyway, because a guard that states its own condition survives the removal of a refusal
    // three screens up that exists for something else.
    //
    // APPLIED TO THE VALUE, ONCE, and never repeated at the exit arm: `unpeeked` feeds BOTH the verdict
    // DOCUMENT written below and the exit arm at the bottom, so a condition stated at only one of them
    // lets the two disagree about a run — a document reading `ok: false, incomplete: true` beside exit 0.
    // candor-rust had exactly that drift on its scan route, and the ⟨0.28⟩ REPORT-sink rung shipped its
    // own version of it.
    let unpeeked = pol.deny.isEmpty ? [] : env.unpeeked
    // ⟨0.33⟩ THE FOURTH CAUSE, computed ONCE through the SAME helper `ReportCompleteness` arms for
    // `unverified`/`fix-gate` (`CandorCore.unaskedCrossPolicyRules`, FixCLI.swift's `armingUnread`), so
    // this route and its advisory siblings cannot drift into two readings of the condition (⟨0.24⟩; PART
    // 67 is the standing example of what a second computation costs). Fed to BOTH the exit arm below and
    // the verdict document, so the two cannot disagree about a run — the same discipline `unpeeked` above
    // states in its own comment.
    // ⟨0.34⟩ ONE CALL, BOTH FACTS — `crossPolicy` feeds the exit arm and the verdict document exactly as
    // before; `crossPolicyPredates033` rides beside it from the SAME computation, so the two cannot
    // disagree about which reports contributed the gap.
    let crossPolicyResult = unaskedCrossPolicyRules(pol.deny, against: env.scannedUnderOfPeeked)
    let crossPolicy = crossPolicyResult.rules
    let crossPolicyPredates033 = crossPolicyResult.oldCaused
    var verdictSinks: [String] = []
    if wantJson { verdictSinks.append("-") }
    if let gp = gateJsonPath, !verdictSinks.contains(gp) { verdictSinks.append(gp) }
    for sink in verdictSinks {
        writeGateVerdict(violations, to: sink, spec: specVersion, analyzedCount: env.analyzedCount,
                         unanalyzed: env.unanalyzed, coverage: Array(env.coverageModules),
                         policyVocabulary: policyVocabulary, netPartners: env.netPartners,
                         unevaluated: refused,
                         // ⟨0.28⟩ §6.2 `ignored` — measured on THIS route too; a route is not covered
                         // by its sibling.
                         ignored: pol.ignored,
                         // ⟨0.30⟩ the peek's findings, off the REPORT — same bytes as the scan route's,
                         // which is what makes §3.1 byte-equality hold on a route that cannot peek.
                         outOfScope: env.outOfScope,
                         // ⟨0.32⟩ …and the classes it could not READ, off the same document and for the
                         // same reason. Omitting it here is what made this route certify `ok: true` where
                         // `scan --policy` wrote `ok: false, incomplete: true` over one report.
                         unpeeked: unpeeked,
                         // ⟨0.33⟩ …and the rules a peeked report's producer was never asked about. `[]`
                         // on `scan --policy` by construction (P ⊆ P); this route is the one that can be
                         // non-empty, and it is the whole reason the key exists.
                         crossPolicy: crossPolicy)
    }
    if !violations.isEmpty {
        FileHandle.standardError.write("candor-swift: \(violations.count) policy violation(s)\n".data(using: .utf8)!)
        FileHandle.standardError.write("→ candor-swift fix-gate names the remedy for each\n".data(using: .utf8)!)
        exit(1)   // a real violation dominates
    }
    // `policy ✓` USED TO BE PRINTED HERE, above the three exit-2 arms below, so every incomplete verdict
    // on this route led with a green tick and then contradicted itself one line later — an operator
    // scanning CI output reads the tick and stops. The scan route moved its own tick below its arms when
    // ⟨0.30⟩ landed ("only NOW is the gate green"); this route kept the old position, and adding the
    // ⟨0.32⟩ arm below would have put a third cause under it. The tick is now the LAST thing this verb
    // can say, and it says it only when every arm has been passed.
    // ⟨0.21⟩ COMPLETENESS MANIFEST: a gate cannot be green over code candor never analyzed. The scan path
    // exits 2 on its own `unanalyzed`; here the same manifest travels ON the report, so the same verdict
    // follows from it. A real violation (exit 1, above) dominates, as it does there.
    if !env.unanalyzed.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift gate: NOT certified — the report declares \(env.unanalyzed.count) unit(s) candor "
             + "could not analyze; a gate cannot be green over unanalyzed code\n").data(using: .utf8)!)
        exit(2)
    }
    // ⟨0.30⟩ the SCOPE half of the same posture, and the same exit. Named separately from the `unanalyzed`
    // arm because the repairs differ: that one wants a scan that can read a file, this one wants a scan
    // whose selector reaches the code the policy is about.
    if !env.outOfScope.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift gate: NOT certified — the report names \(env.outOfScope.count) function(s) OUTSIDE "
             + "the scan's scope performing an effect this policy denies; the gate did not judge them, so "
             + "the verdict is incomplete rather than a pass\n").data(using: .utf8)!)
        exit(2)
    }
    // ⟨0.32⟩ THE THIRD CAUSE, on this route, from the DOCUMENT. `excluded[].peeked == false` is the
    // producing scan stating it never opened those files. AFTER the two arms above and in the SAME ORDER
    // the scan route uses, so a target tripping more than one cause reports the same one on both routes:
    // a CONCRETE denied effect outside the scan is a better message than "something went unread", and a
    // real violation dominates both.
    //
    // AND IT NAMES THE REPAIR, because the common cause of this arm is now a report whose producer was
    // never ASKED — the shape a CI produces when it scans in one job and gates the artifact in another.
    // "Something went unread" with no next step is a dead end, and the next step is one flag.
    if !unpeeked.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift gate: NOT certified — the report says the scan did not READ "
             + "\(unpeeked.joined(separator: ", ")). Their effects are absent because nothing looked, not "
             + "because there are none, so the verdict is INCOMPLETE rather than a pass.\n"
             + "→ re-scan the sources WITH this policy (candor-swift <dir> --policy <p> --out <locator>): "
             + "a scan that was never asked cannot certify what it never opened.\n")
                .data(using: .utf8)!)
        exit(2)
    }
    // ⟨0.33⟩ THE FOURTH CAUSE — THE REPORT'S PEEK ANSWERED A DIFFERENT QUESTION. The arm above is about
    // classes the producer never OPENED; this one is about classes it opened and read WITH A DIFFERENT
    // DENY SET IN HAND. ⟨0.29⟩ bounds the peek to effects the producer's policy denies, so a class read
    // under `deny Net` says nothing about `Exec` in those same files — and the document said nothing
    // about the difference until `scannedUnder` existed to record it (SPEC §2 ⟨0.33⟩).
    //
    // LAST of the four, deliberately: `unanalyzed`, `outOfScope` and `unpeeked` each name a MORE concrete
    // gap, and an operator reading one sentence should get the most specific one their report supports.
    //
    // ⟨0.34⟩ TWO SENTENCES, ONE CAUSE, SAME VERDICT AND EXIT — `crossPolicyPredates033` (computed once,
    // above, beside `crossPolicy`) picks the wording. When every contributing report predates ⟨0.33⟩ the
    // "does not cover" framing names the wrong culprit: it reads as "a producer chose a different policy",
    // and the true statement is "no producer here could yet WRITE the policy it peeked under" — such a
    // producer never had a `scannedUnder` key to hold ANY deny set in. A single ≥⟨0.33⟩ contributor is
    // enough to fall to the `else`, which is character-for-character the pre-⟨0.34⟩ text — the control
    // this rung ships with. Neither arm changes `ok`, the exit code, or any `--gate-json` field: the
    // verdict document was already written above, from `crossPolicy`'s emptiness alone.
    if !crossPolicy.isEmpty {
        if crossPolicyPredates033 {
            FileHandle.standardError.write(
                ("candor-swift gate: NOT certified — this report was produced before ⟨0.33⟩, when a "
                 + "producing scan did not yet record the deny set its peek ran under (`scannedUnder`), "
                 + "so it cannot say whether \(crossPolicy.count) rule(s) of this policy were ever asked: "
                 + "\(crossPolicy.joined(separator: ", ")). The excluded files it reports as read may have "
                 + "been searched for OTHER effects, or for none at all — there is no way to tell from a "
                 + "report this old — so the verdict is INCOMPLETE rather than a pass.\n"
                 + "→ re-scan with a 0.33+ engine under THE SAME policy this gate is applying "
                 + "(candor-swift <dir> --policy <file> --json <report>) — not merely under a policy.\n")
                    .data(using: .utf8)!)
        } else {
            FileHandle.standardError.write(
                ("candor-swift gate: NOT certified — this report's peek was bounded by the deny set its "
                 + "producing scan held, and that set does not cover \(crossPolicy.count) rule(s) of this "
                 + "policy: \(crossPolicy.joined(separator: ", ")). The excluded files it reports as read were "
                 + "searched for OTHER effects, so an empty finding there is not an answer to this question, "
                 + "and the verdict is INCOMPLETE rather than a pass.\n"
                 // THE REMEDY SAYS **THE SAME** POLICY, NOT *A* POLICY, and that wording is part of the rung
                 // rather than prose (SPEC §2 ⟨0.33⟩): the operator DID scan with a policy, and got a report
                 // whose peek answered a different question — the loose reading is what PRODUCES this hole.
                 + "→ re-run the producing scan under THE SAME policy this gate is applying "
                 + "(candor-swift <dir> --policy <file> --json <report>) — not merely under a policy.\n")
                    .data(using: .utf8)!)
        }
        exit(2)
    }
    // …and only NOW is the gate green: every exit-2 arm above has been passed, so `policy ✓` is a claim
    // this run can support. See the note at the violation branch for what printing it earlier said.
    FileHandle.standardError.write("candor-swift: policy ✓\n".data(using: .utf8)!)
    exit(0)
}

/// ⟨0.32⟩ SPEC §2.2's join key: the report's `hash` when it carries one, the bare name when it does not.
/// A name-keyed lookup into a hash-keyed map does not error — it returns nil, and nil reads as "nothing
/// to report" rather than as a break — so every consumer of these accumulators must key the same way.
private func entryKey(_ e: GateReportEntry) -> String { e.hash.isEmpty ? e.fn : e.hash }
