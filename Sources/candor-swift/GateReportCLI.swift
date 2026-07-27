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

private func gateDie(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

// ── the report, read as data ─────────────────────────────────────────────────────────────────────────

/// One §2 report entry, as far as the ⟨0.24⟩ gate is concerned. Every field is read VERBATIM off the
/// wire: this is `S` and `D` as the producer wrote them, not a re-derivation.
private struct GateReportEntry {
    let fn: String
    let inferred: Set<String>
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
}

/// Parse ONE report file into `env`. Returns false (loudly) on a file that is not a well-formed §2
/// report — SPEC §3.1's found-but-corrupt rule: a report with no `functions` key is corrupt input, not
/// an effect-free package, and gating an empty `map` over it would pass. The caller exits 2.
private func mergeGateReport(_ full: String, into env: inout GateReportEnvelope) -> Bool {
    guard let data = FileManager.default.contents(atPath: full),
          let root = try? JSONSerialization.jsonObject(with: data),
          let obj = root as? [String: Any],
          let fns = obj["functions"] as? [[String: Any]] else {
        FileHandle.standardError.write(
            "candor-swift gate: report `\(full)` is not a well-formed §2 report (no `functions` array) — refusing to gate over it\n"
                .data(using: .utf8)!)
        return false
    }
    func strs(_ k: String, _ e: [String: Any]) -> [String] {
        (e[k] as? [Any])?.compactMap { $0 as? String } ?? []
    }
    for e in fns {
        guard let fn = e["fn"] as? String, !fn.isEmpty else { continue }
        env.entries.append(GateReportEntry(
            fn: fn,
            inferred: Set(strs("inferred", e)),
            calls: strs("calls", e),
            hosts: Set(strs("hosts", e)), cmds: Set(strs("cmds", e)),
            paths: Set(strs("paths", e)), tables: Set(strs("tables", e)),
            netClass: strs("netClass", e),
            unknownWhy: strs("unknownWhy", e)))
    }
    // ⟨0.21⟩ the completeness manifest, and ⟨0.15⟩ the κ ledger — the wire fields the scan's own verdict
    // was written from, so the two documents carry the same three facts (Gate.swift's writeGateVerdict).
    if let a = obj["analyzed"] as? [String: Any], let c = a["count"] as? Int { env.analyzedCount += c }
    for u in (obj["unanalyzed"] as? [[String: Any]]) ?? [] {
        env.unanalyzed.append((path: u["path"] as? String ?? "", reason: u["reason"] as? String ?? ""))
    }
    if let cov = obj["coverage"] as? [String: Any], let unc = cov["uncovered"] as? [[String: Any]] {
        for entry in unc { if let name = entry["name"] as? String { env.coverageModules.insert(name) } }
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
private func unanswerableScopedFilter(_ deny: [DenyRule], _ gi: GateInput) -> String? {
    for r in deny {
        for fn in gi.inferred.keys.sorted() where scopeMatches(fn, r.scope) {
            let inf = gi.inferred[fn] ?? []
            if !r.netClasses.isEmpty, inf.contains("Net"), (gi.netClasses[fn] ?? []).isEmpty {
                return "`\(r.raw)` narrows on the Net DESTINATION CLASS, but `\(fn)` carries Net with no "
                    + "`netClass` in this report — the field the filter reads is absent, so the narrowing "
                    + "would succeed for lack of evidence and drop a Net the bare `deny Net` catches. "
                    + "Refusing (exit 2) rather than passing: an absent optional field must not relax a "
                    + "fail-closed gate. Use the bare `deny Net`, or gate at scan time."
            }
            if !r.unknownClasses.isEmpty, inf.contains("Unknown"), (gi.reasonClasses[fn] ?? []).isEmpty {
                return "`\(r.raw)` narrows on the Unknown REASON CLASS, but `\(fn)` carries Unknown with no "
                    + "reason reachable in this report — neither its own `unknownWhy` nor a `calls` edge to "
                    + "one. §6.2 resolves the class set TRANSITIVELY over the gate's reach; with the channel "
                    + "missing, every narrowed filter silently tolerates while only the bare `deny Unknown` "
                    + "fires. Refusing (exit 2). Use the bare `deny Unknown`, or gate at scan time."
            }
        }
    }
    return nil
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
    let pol = parsePolicy(policyText, aliases: parseUnknownAliases(discoverConfigText(targetPath: policyPath)))

    // THE POLICY-LEVEL REFUSALS. Whole-policy, not per-rule: enforcing the answerable half and exiting 0
    // is gateless-green — the user believes a rule is enforced that never ran.
    if !pol.forbid.isEmpty {
        gateDie("candor-swift gate: this policy has \(pol.forbid.count) `forbid` rule(s), which "
                + "`gate --report` cannot evaluate — a report carries an entry only for a function with an "
                + "EFFECT, so a wholly pure unit has no entry and no edges at all, while `forbid` matches "
                + "on NAME. The rule would read green over a crossing a scan fails on. Gate layering at "
                + "scan time: candor-swift <dir> --policy \(policyPath)")
    }
    if !pol.allow.isEmpty {
        let effects = Set(pol.allow.map { $0.effect }).sorted()
        gateDie("candor-swift gate: this policy has `allow \(effects.joined(separator: "`/`"))` rule(s), "
                + "which `gate --report` cannot evaluate — the AS-EFF-008 surface-completeness marker does "
                + "not ride the report wire, so a benign visible literal beside a runtime-computed endpoint "
                + "would be CERTIFIED here and flagged by a scan. (`netClass: unknown-host` is NOT that "
                + "marker — it also names a merely unrecognised host.) Gate allowlists at scan time: "
                + "candor-swift <dir> --policy \(policyPath)")
    }

    let locator = reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()
    guard let prefix = locator else {
        gateDie("candor-swift gate: no report — pass --report <locator> or run from a repo with a .candor/ "
                + "dir (scan: candor-swift <dir>)")
    }
    guard let env = loadGateReport(prefix: prefix) else {
        gateDie("candor-swift gate: no readable report at `\(prefix)` — nothing to gate (scan: candor-swift <dir>)")
    }
    let gi = gateInputFromReport(env)

    // The third refusal, and the only one that depends on the REPORT rather than on the policy alone.
    if let why = unanswerableScopedFilter(pol.deny, gi) {
        gateDie("candor-swift gate: \(why)")
    }

    let violations = evaluateGate(pol, gi)
    // Diagnostics go to STDERR exactly as the scan routes them, so `gate … --json | jq` sees pure JSON.
    for v in violations { FileHandle.standardError.write(("[\(v.rule)] \(v.detail)\n").data(using: .utf8)!) }
    // `--json` IS `--gate-json -`: the same document, from the same writer the scan uses, so a consumer
    // cannot tell a scanned verdict from a report-gated one.
    if wantJson { writeGateVerdict(violations, to: "-", spec: specVersion, analyzedCount: env.analyzedCount,
                                   unanalyzed: env.unanalyzed, coverage: Array(env.coverageModules)) }
    if let gp = gateJsonPath { writeGateVerdict(violations, to: gp, spec: specVersion, analyzedCount: env.analyzedCount,
                                                unanalyzed: env.unanalyzed, coverage: Array(env.coverageModules)) }
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
