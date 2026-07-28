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
    for e in env.entries {
        // UNION on a repeated `fn` rather than overwrite: a duplicate key is malformed input, and the
        // union is the direction that cannot turn a violation into a pass.
        inferred[e.fn, default: []].formUnion(e.inferred)
        edgeSets[e.fn, default: []].formUnion(e.calls)
        if !e.hosts.isEmpty { hosts[e.fn, default: []].formUnion(e.hosts) }
        if !e.cmds.isEmpty { cmds[e.fn, default: []].formUnion(e.cmds) }
        if !e.paths.isEmpty { paths[e.fn, default: []].formUnion(e.paths) }
        if !e.tables.isEmpty { tables[e.fn, default: []].formUnion(e.tables) }
        if !e.netClass.isEmpty {
            netClasses[e.fn] = Array(Set(netClasses[e.fn] ?? []).union(e.netClass)).sorted()
        }
        for why in e.unknownWhy { whyDirect[e.fn, default: []].insert(reasonClass(why)) }
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
            whyDirect[e.fn, default: []].insert("unresolved")
        }
    }
    for (fn, cs) in edgeSets { edges[fn] = cs.sorted() }
    return GateInput(inferred: inferred,
                     reasonClasses: propagate(whyDirect, over: edgeSets),
                     netClasses: netClasses,
                     hosts: hosts, cmds: cmds, paths: paths, tables: tables,
                     surfaceIncomplete: [:],
                     edges: edges)
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
private func unanswerableScopedFilters(_ deny: [DenyRule], _ gi: GateInput) -> [String] {
    var out: [String] = []
    for r in deny {
        for fn in gi.inferred.keys.sorted() where scopeMatches(fn, r.scope) {
            let inf = gi.inferred[fn] ?? []
            if !r.netClasses.isEmpty, inf.contains("Net"), (gi.netClasses[fn] ?? []).isEmpty {
                out.append("`\(r.raw)` narrows on the Net DESTINATION CLASS, but `\(fn)` carries Net with no "
                    + "`netClass` in this report — the field the filter reads is absent, so the narrowing "
                    + "would succeed for lack of evidence and drop a Net the bare `deny Net` catches. "
                    + "Refusing (exit 2) rather than passing: an absent optional field must not relax a "
                    + "fail-closed gate. Use the bare `deny Net`, or gate at scan time.")
                break
            }
            if !r.unknownClasses.isEmpty, inf.contains("Unknown"), (gi.reasonClasses[fn] ?? []).isEmpty {
                out.append("`\(r.raw)` narrows on the Unknown REASON CLASS, but `\(fn)` carries Unknown with no "
                    + "reason reachable in this report — neither its own `unknownWhy` nor a `calls` edge to "
                    + "one. §6.2 resolves the class set TRANSITIVELY over the gate's reach; with the channel "
                    + "missing, every narrowed filter silently tolerates while only the bare `deny Unknown` "
                    + "fires. Refusing (exit 2). Use the bare `deny Unknown`, or gate at scan time.")
                break
            }
        }
    }
    return out
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
func runGateReportCLI(_ args: [String]) -> Never {
    let usage = "usage: candor-swift gate --report <locator> --policy <file> [--json] [--gate-json <file>]"
    var reportFlag: String?, policyFlag: String?, gateJsonPath: String?
    var wantJson = false
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": wantJson = true
        case "--report":
            guard let v = it.next() else { gateDie("candor-swift: --report requires a value (\(usage))") }
            reportFlag = v
        case "--policy":
            guard let v = it.next() else { gateDie("candor-swift: --policy requires a value (\(usage))") }
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
    let policyVocabulary: (config: String, aliases: [String])? =
        pol.usedAliases.isEmpty ? nil : vocabConfig.map { (config: $0.path, aliases: pol.usedAliases) }
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
    let policyErrors = aliasErrors.refusing.map(\.message) + pol.errors
    if !policyErrors.isEmpty { gateDie(policyErrors.joined(separator: "\n")) }

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
    var policyRefusals: [String] = []
    if !pol.forbid.isEmpty {
        policyRefusals.append("this policy has \(pol.forbid.count) `forbid` rule(s), which "
                   + "`gate --report` cannot evaluate — a report carries an entry only for a function with an "
                   + "EFFECT, so a wholly pure unit has no entry and no edges at all, while `forbid` matches "
                   + "on NAME. The rule would read green over a crossing a scan fails on. Gate layering at "
                   + "scan time: candor-swift <dir> --policy \(policyPath)")
    }
    if !pol.allow.isEmpty {
        let effects = Set(pol.allow.map { $0.effect }).sorted()
        policyRefusals.append("this policy has `allow \(effects.joined(separator: "`/`"))` rule(s), "
                   + "which `gate --report` cannot evaluate — the AS-EFF-008 surface-completeness marker does "
                   + "not ride the report wire, so a benign visible literal beside a runtime-computed endpoint "
                   + "would be CERTIFIED here and flagged by a scan. (`netClass: unknown-host` is NOT that "
                   + "marker — it also names a merely unrecognised host.) Gate allowlists at scan time: "
                   + "candor-swift <dir> --policy \(policyPath)")
    }
    let denyOnly = ParsedPolicy(deny: pol.deny, allow: [], forbid: [])

    let locator = reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()
    guard let prefix = locator else {
        gateDie("candor-swift gate: no report — pass --report <locator> or run from a repo with a .candor/ "
                + "dir (scan: candor-swift <dir>)")
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
    let violations = evaluateGate(denyOnly, gi)
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
        // machine channel carry the SAME disclosure rather than two drifting statements of it.
        refuseGateAndExit("candor-swift gate: " + refused.joined(separator: "\n    "))
    }
    if !refused.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift gate: NOTE — \(refused.count) policy rule(s) could not be evaluated over this "
             + "report and are NOT answered by the verdict below. The verdict stands anyway: a rule FIRED "
             + "on evidence this report carries, and no resolution of an unanswered rule can un-reject a "
             + "rejected policy (SPEC §3.1, PAPER3 Lemma 2). Unanswered:\n").data(using: .utf8)!)
        for why in refused { FileHandle.standardError.write("    \(why)\n".data(using: .utf8)!) }
    }
    // Diagnostics go to STDERR exactly as the scan routes them, so `gate … --json | jq` sees pure JSON.
    for v in violations { FileHandle.standardError.write(("[\(v.rule)] \(v.detail)\n").data(using: .utf8)!) }
    // `--json` IS `--gate-json -`: the same document, from the same writer the scan uses, so a consumer
    // cannot tell a scanned verdict from a report-gated one.
    if wantJson { writeGateVerdict(violations, to: "-", spec: specVersion, analyzedCount: env.analyzedCount,
                                   unanalyzed: env.unanalyzed, coverage: Array(env.coverageModules),
                                   policyVocabulary: policyVocabulary) }
    if let gp = gateJsonPath { writeGateVerdict(violations, to: gp, spec: specVersion, analyzedCount: env.analyzedCount,
                                                unanalyzed: env.unanalyzed, coverage: Array(env.coverageModules),
                                                policyVocabulary: policyVocabulary) }
    if violations.isEmpty {
        FileHandle.standardError.write("candor-swift: policy ✓\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("candor-swift: \(violations.count) policy violation(s)\n".data(using: .utf8)!)
        FileHandle.standardError.write("→ candor-swift fix-gate names the remedy for each\n".data(using: .utf8)!)
        exit(1)   // a real violation dominates
    }
    // ⟨0.21⟩ COMPLETENESS MANIFEST: a gate cannot be green over code candor never analyzed. The scan path
    // exits 2 on its own `unanalyzed`; here the same manifest travels ON the report, so the same verdict
    // follows from it. A real violation (exit 1, above) dominates, as it does there.
    if !env.unanalyzed.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift gate: NOT certified — the report declares \(env.unanalyzed.count) unit(s) candor "
             + "could not analyze; a gate cannot be green over unanalyzed code\n").data(using: .utf8)!)
        exit(2)
    }
    exit(0)
}
