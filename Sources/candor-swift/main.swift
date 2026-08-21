// candor-swift — the Swift implementation of candor-spec (the declared contract is `specVersion` below;
// smoke.sh gates AGENTS.md/README spec strings against it so prose can't silently go stale again).
//
// Architecture mirrors candor-scan (the syntactic reference engine): pass A indexes declarations
// (units, field types, protocols + conformers, imports), pass B collects each function's calls
// with light local type inference (params, typed lets, constructor bindings), propagates effects
// to the least fixpoint, and emits the §2 envelope + §2.2 call-graph sidecar. The §4 trust
// contract is the core: a call through a function-typed value, an unresolvable member, or a local
// protocol's dispatch with no visible conformer contributes Unknown — never silent purity.
// Spec 0.5 MUSTs carried from day one: universal `hash` emission (pkg#qual), the §7.14 κ-coverage
// ledger (imports the classifier doesn't know, named per scan), and literal surfaces
// (hosts/cmds/paths/tables) because the §6.2 policy gate enforces `allow` rules.
//
// Known v0 honesty notes (item 7): the κ table covers the platform frontier (Foundation/Network/
// Dispatch/os + sqlite3) — third-party packages are INVISIBLE and the ledger names them, UNLESS a
// chained sibling report covers them: CANDOR_DEPS / the config `deps` key (SPEC §2, Deps.swift) joins
// an unresolved call into a covered package to that dep fn's recorded effects + literal surfaces
// (stale producers downgrade to Unknown; an empty report is a purity claim); nested named functions
// attribute lexically to their enclosing unit (over-approximation, the sound direction).

import Foundation
import SwiftParser
import SwiftSyntax
import CandorCore

// ════════════════════════════════════════════════════════════════════════════════════════════════
// CLI
// ════════════════════════════════════════════════════════════════════════════════════════════════

let engineVersion = "candor-swift-0.31.0"
// The bare release semver (`0.5.0`) — the ONE source of truth for both the envelope's build id above
// and `--version`, derived by stripping the engine prefix so the two can't drift.
let releaseVersion = engineVersion.replacingOccurrences(of: "candor-swift-", with: "")
// The spec contract version this engine speaks — the SAME literal that stamps the §2 envelope's `spec`
// field (see the envelope below), reused so `--version` and the report can never disagree.
let specVersion = "0.31"

// `parsepolicy <file>` — dump the parsed §6.2 policy as canonical JSON, the SAME shape candor-java's
// Query.policyJson / candor-query / candor-ts emit: {"deny":[{effects,scope}], "allow":[{effect,scope,
// values}], "forbid":[{from,to}]}. Not a user workflow; it exists so the cross-impl conformance suite
// (PART 4) can diff this engine's grammar parse against the family and prove SPEC §6.2 means the same
// thing in every engine — candor-swift was PART 4's loud skip until this landed. Handled before the
// flag loop (a subcommand, like the reference engine's args[0] dispatch — never a scan target).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "parsepolicy" {
    guard CommandLine.arguments.count >= 3 else {
        FileHandle.standardError.write("usage: candor-swift parsepolicy <policy-file>\n".data(using: .utf8)!)
        exit(2)
    }
    let polPath = CommandLine.arguments[2]
    guard let polText = try? String(contentsOfFile: polPath, encoding: .utf8) else {
        FileHandle.standardError.write("candor-swift: cannot read policy \(polPath)\n".data(using: .utf8)!)
        exit(2)
    }
    // ⟨0.19⟩ config-aware: resolve `Unknown[<alias>]` via a checked-in `unknown-alias`, anchored to the
    // policy file (or CANDOR_CONFIG) — the dump reflects real gate resolution + pins the four-way expansion.
    let polAliases = parseUnknownAliases(discoverConfigText(targetPath: polPath))
    let pol = parsePolicy(polText, aliases: polAliases.aliases)
    // Deterministic entry order: each list sorted by its serialized JSON (the reference engine's
    // byJson comparator) — the conformance differential normalizes anyway; this keeps raw dumps diffable.
    func sortedByJson(_ xs: [[String: Any]]) -> [[String: Any]] {
        func key(_ d: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return xs.sorted { key($0) < key($1) }
    }
    var polDict: [String: Any] = [
        "deny": sortedByJson(pol.deny.map { r -> [String: Any] in
            // Emit sorted `unknownClasses`/`netClasses` ONLY when the rule narrows Unknown/Net — a bare deny
            // dump stays byte-identical to pre-feature, and the four-way parsepolicy differential pins the
            // reason-class + destination-class parsing across engines (matches candor-java/rust/ts).
            var m: [String: Any] = ["effects": r.effects, "scope": r.scope]
            if !r.unknownClasses.isEmpty { m["unknownClasses"] = r.unknownClasses }
            if !r.netClasses.isEmpty { m["netClasses"] = r.netClasses }
            return m
        }),
        "allow": sortedByJson(pol.allow.map { ["effect": $0.effect, "scope": $0.scope, "values": $0.values] }),
        "forbid": sortedByJson(pol.forbid.map { ["from": $0.from, "to": $0.to] }),
        // ⟨0.29⟩ the PERMISSION form rides the witness too — this verb exists so the conformance suite can
        // diff what each engine made of one policy, so a rule kind missing here is a kind the differential
        // cannot see. It was omitted while candor-java emitted it, and PART 4 read three keys and stopped.
        "only": sortedByJson(pol.only.map { ["from": $0.from, "to": $0.to] }),
    ]
    // ⟨0.24⟩ `errors` — EVERY LINE THE ENGINE DID NOT HONOUR AS WRITTEN (SPEC §3.1, candor-spec
    // `195d45a` + `901f14d`). MEASURED 2026-07-28 on the conformance battery: java 10, ts 2, rust 0,
    // **swift 0** — this engine emitted no `errors` key at all while its stderr listed nine dropped
    // lines and two unrecognised tokens. A dropped rule is the LIMIT CASE of "silently rewritten into a
    // different policy": the rewritten policy is the one without that line, a bigger rewrite than a
    // narrowed filter rather than a smaller one. And it mattered more here than in the engine that
    // prompted the clause, because this engine's GATE already refuses some of these lines — so the parse
    // was narrowing silently while the gate refused, two answers to one question, and the witness was
    // giving the quieter one.
    //
    // ORDER IS THE POLICY'S OWN (never sortedByJson): these are per-LINE diagnostics and a reader
    // matching them against the file needs them in file order. The alias-definition errors come first —
    // the vocabulary is read before the policy that uses it.
    //
    // OMITTED WHEN EMPTY, so a clean parse stays byte-identical and the four-way deny/allow/forbid
    // comparison (conformance PART 4) is untouched.
    let allErrors = polAliases.errors.map(\.policyError) + pol.errors
    if !allErrors.isEmpty { polDict["errors"] = allErrors.map(\.json) }
    // DEFENSIVE, deliberately uncovered (TESTING.md §6): the dict holds only strings/arrays — the
    // same cannot-fire arm as writeJson's.
    guard let polData = try? JSONSerialization.data(withJSONObject: polDict, options: [.prettyPrinted, .sortedKeys]),
          let polJson = String(data: polData, encoding: .utf8) else {
        FileHandle.standardError.write("candor-swift: could not serialize the policy dump\n".data(using: .utf8)!)
        exit(2)
    }
    print(polJson)
    exit(0)
}

// `fix` / `fix-gate` (integrations/FIX-SPEC.md) — the boundary remedy, a read-only query over a report a
// scan already wrote (the remedial inverse of the gate). Handled here as a subcommand, like `parsepolicy`,
// before the scan flag loop — never a scan target. The heavy lifting is in FixCLI.swift + CandorCore/Fix.swift.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "fix" || CommandLine.arguments[1] == "fix-gate" {
    runFixCLI(CommandLine.arguments)
}
// `unverified` (integrations/FIX-SPEC.md) — the provable-purity disclosure: pure/deny layers that PASS but
// contain Unknown. A read-only query over a report a scan wrote; a subcommand, before the scan flag loop.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "unverified" {
    runUnverifiedCLI(CommandLine.arguments)
}
// `tour [<N>]` (SURFACE-BEST-FIND-DESIGN.md, P2) — the on-demand, top-N version of the cold-repo opener:
// the N most surprising transitive reaches in an existing report, NO re-scan. A read-only query over a
// report a scan wrote; a subcommand, before the scan flag loop. Delegates to CandorCore.bestFinds.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "tour" {
    runTourCLI(CommandLine.arguments)
}
// `path <fn> <Effect>` (§3.1) — the read-only query the scan-note / `tour` opener points at: trace the
// call chain by which a fn comes to perform an effect, down to the nearest DIRECT source. Report from
// --report/discovery, NO policy; a subcommand, before the scan flag loop. Byte-for-byte the Rust
// reference `candor-query path` (conformance PART 5 pins the shape four-way).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "path" {
    runPathCLI(CommandLine.arguments)
}
// `gains <current> <baseline>` (SPEC §5.1) — the supply-chain alarm: every effect a fn GAINED between
// two reports (current minus baseline). The two-positional comparative verb (§3.3.1 exception: NO
// discovery — both positionals ARE report locators); read-only over reports scans already wrote; a
// subcommand, before the scan flag loop. Mirrors the Rust reference `candor-query gains`.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "gains" {
    runGainsCLI(CommandLine.arguments)
}
// `privacy-manifest` (SPEC-EXTENSION-privacy.md, "Product surface") — the code-level truth behind an app's
// Apple privacy declaration: GENERATE the required Info.plist usage-description keys from the report's
// privacy-effect reach, or VERIFY an Info.plist against it (an under-declaration → exit 1). A read-only
// query over a report a scan wrote (privacy/1 extension); a subcommand, before the scan flag loop.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "privacy-manifest" {
    runPrivacyManifestCLI(CommandLine.arguments)
}
// ⟨0.24⟩ `gate --report <locator> --policy <file>` (SPEC §3.1) — apply a policy to an EXISTING report,
// with no scan: the supply-chain gate, and the one route that reaches §6.2 as a function of a GIVEN
// signature rather than through the classifier. A subcommand, before the scan flag loop (GateReportCLI.swift).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "gate" {
    runGateReportCLI(CommandLine.arguments)
}

var target = "."
var sawPositional = false
var outPrefix: String? = nil
var wantJson = false
var policyPath: String? = ProcessInfo.processInfo.environment["CANDOR_POLICY"]
var gateJsonPath: String? = nil
var wantWorkspace = false
var scopeTarget: String? = nil
// ⟨0.29⟩ THE PEEK, CHILD SIDE — an INTERNAL flag, set only by this binary on itself. It names a file of
// newline-separated absolute paths, and a run given it analyses EXACTLY those and skips the walk. It is
// deliberately absent from `--help`: it is not a way to scan a file list (a positional path already is),
// it is the process-boundary spelling of candor-rust's `ScanOpts.peek_excluded`, which that engine can
// hold in a struct because its scan is a callable function and this engine's is top-level code.
var peekListPath: String? = nil
// ⟨scope travels⟩ what the `.xcodeproj` resolver learned, for the report envelope. See
// `ReportModel.scope`: the verify that reads this report later has only a report and a plist, so
// anything the scan knew about WHICH binary this is must be in the artifact or it is lost.
var resolvedXcodeScope: (target: String, project: String, entitlements: String?)? = nil
// ⟨0.27⟩ The local packages the `.xcodeproj` closure resolved. An Xcode target has no `Package.swift`,
// so this is the ONLY record of what its files may import — and it is a dependency closure the resolver
// already walked, not a fresh guess from directory shape.
/// Absolute source file -> the local package PRODUCTS the Xcode target(s) compiling it may import.
/// Per file, because a file's importable set is its target's link list, not the closure's union.
var resolvedXcodeLinksByFile: [String: [LocalProductRef]] = [:]
/// …and the Xcode-target MODULES each file's target(s) may import. Separate map, same keys, because a
/// target can link no local package and still import a sibling framework target.
var resolvedXcodeModulesByFile: [String: [String]] = [:]
// A VALUELESS GATE-ADJACENT FLAG IS AN EXIT-2 CAUSE LIKE ANY OTHER. These three exited raw, so
// `--gate-json -` got nothing — the only cause left doing that after every other one had been routed,
// and found by sweeping the causes a user can actually trigger rather than by reading exit sites. rust
// and ts both answered it already. `refuseGateAndExit` reaches the stream because the pre-pass below
// has already registered it; on a run with no sink it degrades to the same stderr line and exit 2.
// ⟨0.28⟩ SPEC §3.3.1 (4) — REGISTER THE REPORT STREAM BEFORE ANY EXIT-2 CAN FIRE. `--json` takes no value
// on this engine (a following non-flag token is a second positional, refused later), so a bare `contains`
// check is exact. The pre-pass below can exit-2 on argv-shape refusals; `refuseGateAndExit` and every
// direct exit-2 in this file consult `wantJsonStream` to decide whether to write the fail-closed report
// to stdout as the stream's only content. Measured 2026-08-10 on all four engines: an unknown flag beside
// `--json` gave stdout 0 bytes on every one, which threw JSON consumers back to scraping stderr — the
// distinction that made the incomplete-analysis defect a defect. Only the SCAN CLI sets this; subcommands
// above have already exited before reaching here.
wantJsonStream = CommandLine.arguments.dropFirst().contains("--json")
// ── SPEC §3.3.1 ⟨0.27⟩ ARM FIRST, AND NEVER OVER AN INPUT.
//
// A pre-pass that learns the sink and this run's inputs with NO side effects, before the flag loop. It
// exists for two things the loop cannot do:
//
//  (1) the loop's own usage exits run before the arming below, so `--frobnicate --gate-json G` left the
//      PREVIOUS run's green document at G. The old comment on the arming site said "flag-loop usage
//      errors are already past, and they had no sink" — but they DID have a sink whenever --gate-json
//      came first, which made the contract depend on argv ORDER. §3.3 names an unknown flag as a
//      broken-gate-config exit-2 cause, which must leave a refusal.
//  (2) arming WRITES, so a sink naming the policy DESTROYS it. Measured on this engine — the arming
//      commit introduced it, since before that the sink was only written on refusal: `--policy P
//      --gate-json P` on violating code exited 0 with `ok: true` and stderr claiming "nothing hidden",
//      because the armed JSON replaced P and the gate then ran over zero rules. Same mechanism aimed at
//      `<target>/.candor/config` destroyed the config that declared the policy.
let preScanned = preScanSinkAndInputs(CommandLine.arguments)
if let gp = preScanned.gate {
    // ⟨0.28⟩ `--json` BESIDE `--gate-json -`: a report and a verdict cannot share one stream. Decided in
    // the pre-pass so the refusal is stdout's ONLY content — refusing after the report has gone out is the
    // defect rather than the fix. `--json <file>` writes the report elsewhere and is not this case.
    if gp == "-" {
        // `--json` takes no value on this engine — it always means stdout.
        if CommandLine.arguments.dropFirst().contains("--json") {
            FileHandle.standardError.write(
                ("candor-swift: --json and --gate-json - both name STDOUT — refusing (exit 2). `--json` "
                 + "writes the REPORT there and `--gate-json -` the VERDICT, so this would put two JSON "
                 + "documents on one stream and a consumer parsing it gets neither. Send one to a file, "
                 + "or run the scan twice.\n").data(using: .utf8)!)
            if !gateVerdictSinks.contains("-") { gateVerdictSinks.append("-") }
            refuseGateAndExit("candor-swift: --json and --gate-json - both name stdout — a report and a "
                              + "verdict cannot share one stream")
        }
    }
    // ⟨0.28⟩ The DUPLICATE case is decided FIRST: the single-sink guard below acts on `gp` alone — the
    // LAST sink — so `--gate-json - --gate-json <the policy>` exited on the policy before the STREAM was
    // told anything. And the input exemption covers the offending PATH, not the run: the other named
    // sinks still have readers waiting for a verdict.
    // ⟨0.28⟩ A REPEATED `--gate-json` IS REFUSED, AND EVERY PATH NAMED GETS THE REFUSAL. This engine
    // already exited 2 on the shape — it was the only one that did — but it left the FIRST path exactly
    // as it found it, so a previous run's `{"ok": true}` survived a gate that fired. Refusing without
    // telling the losing sink is most of the defect: its reader has no way to learn that it lost.
    //
    // Placed after the input-collision guard and before arming: a sink that is an INPUT is refused
    // having written nothing, and that exemption outranks this one.
    let namedSinks = distinctGateSinks(allGateSinks(CommandLine.arguments))
    if namedSinks.count > 1 {
        let list = namedSinks.joined(separator: ", ")
        // ⟨0.28⟩ a sink that IS a source the walk will parse takes the input exemption too — nothing is
        // written there, and the other named paths still get the refusal (the exemption covers the PATH,
        // not the run). Same predicate as the single-sink route below, so the two cannot drift.
        let offending = namedSinks.filter { gateJsonIsInput($0, preScanned.target, preScanned.policy)
                                            || sinkIsParsedSourceUnderTarget($0, target: preScanned.target) }
        if offending.count == namedSinks.count {
            refuseGateJsonOverAnyInput(namedSinks[0], preScanned.target, preScanned.policy)
            refuseSinkUnderTargetWithParsedExtension(namedSinks[0], target: preScanned.target,
                                                     flag: "--gate-json")
            exit(2)
        }
        for s in offending {
            FileHandle.standardError.write(
                ("candor-swift: --gate-json \(s) names an INPUT of this run — refusing (exit 2), and "
                 + "nothing was written there.\n").data(using: .utf8)!)
        }
        FileHandle.standardError.write(
            ("candor-swift: --gate-json given more than once (\(list)) — refusing (exit 2). A gate "
             + "publishes ONE verdict. Naming two sinks says where it goes twice, and the reader of the "
             + "path that loses cannot tell it lost. Name one, or run the gate twice.\n").data(using: .utf8)!)
        gateVerdictSinks = namedSinks.filter { !offending.contains($0) }
        refuseGateAndExit("candor-swift: --gate-json was given more than once (\(list)) — a run "
                          + "publishes one verdict to one sink")
    }
    // Exactly one sink: the ordinary guard, which exits having written nothing.
    refuseGateJsonOverAnyInput(gp, preScanned.target, preScanned.policy)
    // ⟨0.28⟩ …and the SCAN TARGET'S EXPANSION: a sink under the target bearing the extension this
    // engine parses names a file the walk is about to read — refused before arming, having written
    // nothing. `<target>/.candor/…` is not a parsed source and stays permitted (the control).
    refuseSinkUnderTargetWithParsedExtension(gp, target: preScanned.target, flag: "--gate-json")
    if gp != "-" { armGateJsonFailClosed(gp) }
    // A `-` SINK CANNOT BE PRE-ARMED — there is no file to replace, and emitting a refusal now would put
    // two documents on the same stream. Register it instead, so the exits below route their refusal to
    // stdout rather than emitting NOTHING: measured, an unknown flag and a nonexistent target each gave
    // a `--gate-json -` consumer zero bytes while an unreadable policy on the same sink gave a proper
    // refusal. Same run, same sink, three different answers.
    else { gateVerdictSinks.append("-") }
}
// ⟨0.28⟩ …AND ARM THE REPORT SET, for the same reason and at the same moment (SPEC §3.3.1 (1)). The
// verdict sink above arms a path this run is about to OWN; a report PREFIX cannot, because the filename
// is `<prefix>.<pkg>.Swift.json` and `<pkg>` is not known until a `Package.swift` has been read. The set
// the run knows NOW is the one the PREVIOUS run left, which is exactly the set at risk of being read as
// current after this run fails — measured, `--out p --zzz-not-a-flag` exited 2 leaving `p.Fx.Swift.json`
// byte-identical to the previous good run. Placed HERE, above the flag loop, because that loop's own
// unknown-flag exit is the exit this rung is most often reached through.
//
// **ONLY AN EXPLICITLY NAMED `--out`, NEVER THE DEFAULT PREFIX.** The first version of this armer took
// the default `<target>/.candor/report` too, on the reasoning that an operator who passes no `--out`
// still has yesterday's reports there to go stale. That reasoning is right about STALENESS and wrong
// about OWNERSHIP, and the difference destroys data: measured, `candor-swift . --zzz-not-a-flag`
// overwrote a `.candor/report.<pkg>.Swift.json` with the placeholder, and committed reports and
// baselines are the pattern this project recommends and ships in CI. A run that dies in argv parsing was
// never going to write there, and had not been told it owned that path. Destroying a version-controlled
// artifact is a worse outcome than the staleness the rung closes.
//
// ⟨0.27⟩'s arming rule never had to face this because `--gate-json` has NO DEFAULT: every verdict sink is
// named. So "arm at the instant the sink is known" presumes a sink the operator NAMED, and that
// presumption is explicit here. With `--out p` the operator has declared that p is this run's output, so
// arming is correct even when p is checked in; with no flag there is no such declaration.
//
// See `armOutPrefixReports` / `disarmUnwrittenOutReports` for the rest of the shape, including why what
// this run turns out NOT to write is handed back rather than left holding the placeholder.
//
// ⟨0.28⟩ **AND A REPEATED `--out` IS REFUSED, WITH THE FAIL-CLOSED REPORT AT EVERY PREFIX NAMED** (SPEC
// §3.3.1 — "a repeated --out is the same rule" as the repeated verdict sink, filed as an open question
// by the rung that settled the verdict half, on no stated ground except which sink was in front of the
// author). `--out A --out B` says where the reports go twice; this engine took the LAST, so A kept a
// previous run's whole report set, readable as current — and a `gate --report A` over it answers from a
// scan that never ran. So: every distinct prefix named is ARMED (its previous §2 reports rewritten to
// the ⟨0.21⟩ fail-closed empty — the report-sink spelling of "every path named gets the refusal", and
// the input exemption inside the armer still covers any file this run reads), then exit 2 through
// `refuseGateAndExit` so a verdict sink and the `--json` stream get their refusal documents too. The
// exit skips `disarmUnwrittenOutReports` by construction — these placeholders are the point, not a
// leftover. Two spellings of one prefix are ONE sink (`distinctOutPrefixes`) and are not refused.
let namedOutPrefixes = distinctOutPrefixes(allOutPrefixes(CommandLine.arguments))
if namedOutPrefixes.count > 1 {
    for p in namedOutPrefixes {
        armOutPrefixReports(p, target: preScanned.target, policyFlag: preScanned.policy)
    }
    let list = namedOutPrefixes.joined(separator: ", ")
    FileHandle.standardError.write(
        ("candor-swift: --out given more than once (\(list)) — refusing (exit 2). A run writes ONE "
         + "report set to ONE prefix. Naming two says where the reports go twice, and the reader of the "
         + "prefix that loses cannot tell it lost — every prefix named now holds the fail-closed empty "
         + "in place of any previous run's reports. Name one, or run the scan twice.\n").data(using: .utf8)!)
    refuseGateAndExit("candor-swift: --out was given more than once (\(list)) — a run writes one "
                      + "report set to one prefix")
}
if let prePrefix = namedOutPrefixes.first {
    armOutPrefixReports(prePrefix, target: preScanned.target, policyFlag: preScanned.policy)
}
var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIter.next() {
    switch a {
    // A value-taking flag with no following value must FAIL, never silently take a nil: a trailing
    // `--policy` (e.g. `--policy $POL` where $POL expanded empty) would otherwise CLOBBER the
    // CANDOR_POLICY env gate with nil and exit 0 — the §6.2 'gateless green' state. exit 2.
    case "--out":
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --out requires a value\n".data(using: .utf8)!)
            refuseGateAndExit("candor-swift: --out requires a value")
        }
        outPrefix = v
        noteRefusalPrefix(v)   // ⟨0.32⟩
    case "--json":
        // Print the §2 envelope to STDOUT instead of writing the report file(s)/sidecars (matching the
        // candor-scan reference). The §6.2 policy gate below STILL runs and keeps its exit codes —
        // `--json --policy p` prints the report AND exits 1 on a violation.
        wantJson = true
    case "--policy":
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --policy requires a value\n".data(using: .utf8)!)
            refuseGateAndExit("candor-swift: --policy requires a value")
        }
        policyPath = v
    case "--gate-json":
        // The structured gate verdict target (candor-spec §3.3 ⟨0.8⟩). Valueless or flag-shaped fails
        // closed like --policy — but `-` (stream the verdict to stdout, the §3.3 pipe form the other
        // three engines accept) is valid; the old guard rejected it, a cross-engine divergence.
        guard let v = argIter.next(), v == "-" || !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --gate-json requires a value\n".data(using: .utf8)!)
            refuseGateAndExit("candor-swift: --gate-json requires a value")
        }
        gateJsonPath = v
    case "--target":
        // Scope the scan to ONE target of a multi-target package and its in-package dependency closure.
        // Valueless or flag-shaped fails closed: a `--target` that silently became "scan everything"
        // would answer a different question than the one asked, and the answer LOOKS the same.
        //
        // The refusal routes through `refuseGateAndExit` like its --out/--policy/--gate-json neighbours
        // — NOT a bare exit(2). This arm had the bare form (it wrote the report stream, then exited),
        // and the difference is invisible until a sink is watching: measured 2026-08-12 (the P8
        // sink-surface matrix), `--target --gate-json -` exited 2 with NOTHING on the stream, while the
        // FILE spelling passed only because the pre-pass leaves an armed placeholder on disk. A `-`
        // sink has no placeholder to fall back on — its refusal document exists only if this exit emits
        // it. Same class as the bare exit(2) candor-scan repaired in 3560681, one flag over from the
        // --policy/--out the hand sweep checked. (`refuseGateAndExit` also writes the fail-closed
        // report stream, so the writeReportStreamFailClosed this arm used to call is covered.)
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --target requires a target name\n".data(using: .utf8)!)
            refuseGateAndExit("candor-swift: --target requires a target name")
        }
        scopeTarget = v
    case "--peek-excluded":
        // ⟨0.29⟩ INTERNAL (see `peekListPath`). Valueless fails closed like its neighbours — a peek that
        // silently became a whole-tree scan would report the project's own effects as out-of-scope
        // findings, which is a false statement about which files the gate judged.
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            // `refuseGateAndExit` writes `reason` to stderr as its first action, so the manual write this
            // arm used to do printed the identical line twice. Every neighbouring flag calls it alone.
            refuseGateAndExit("candor-swift: --peek-excluded requires a value")
        }
        peekListPath = v
    case "--workspace", "--deps":
        // Auto-discover the target's LOCAL PATH dependencies (`.package(path:)` in Package.swift), scan
        // each into .candor/deps/ with protocol-CHA union entries, and chain them — so a cross-package
        // protocol call discloses the sibling's effect instead of reading pure (the candor-ts `--workspace`
        // analog; swift's local deps are path-declared, not node_modules symlinks).
        wantWorkspace = true
    case "-h", "--help":
        print("""
        candor-swift — the Swift effect analyzer. SwiftSyntax-based, it scans source without building.

        A scan reads every .swift file, propagates effects through the call graph, and writes the
        report to .candor/. A call the analysis cannot resolve is Unknown, and an imported module
        the classifier doesn't cover is named INVISIBLE, per scan — the report never silently
        claims purity it can't see.

        USAGE
          candor-swift [<dir|file.swift>] [options]            scan Swift sources (default target: .)
          candor-swift <dir> --target <name>                   scan ONE target + its closure (SwiftPM or .xcodeproj)
          candor-swift <action> [args] [options]               query the discovered report (.candor/, walk-up)
          candor-swift privacy-manifest [--verify <plist>]     generate/verify the Apple privacy manifest
          candor-swift gains <current> <baseline>              effects gained between two reports
          candor-swift gate --report <loc> --policy <file>     apply a policy to an EXISTING report, no scan
          candor-swift --agents                                print the agent contract for this build

        COMMON ACTIONS
          path <fn> <Effect>        the call chain by which a function reaches an effect
          tour [N]                  the N most surprising transitive reaches (default 10)
          gains <current> <base>    what a new version newly reaches — the supply-chain alarm
          fix <fn> <Effect>         the boundary hoist that would clear a violation
          fix-gate                  every policy crossing + its remedy
          unverified                pure/deny scopes that PASS but contain Unknown (--strict: exit 1)
          privacy-manifest          the Info.plist usage keys the sensor reach requires; --verify diffs one
          gate --policy <file>      apply a policy to an EXISTING report, with NO scan — the supply-chain
                                    gate. Same exit codes and same verdict shape as a scan's --policy
                                    (0 clean / 1 violation / 2 could-not-evaluate); the only difference is
                                    that the effect set is READ from the report rather than recomputed.
                                    `--json` is `--gate-json -`. `forbid` and `allow` rules are REFUSED
                                    (exit 2): the report wire does not carry the evidence they need.

        ALL ACTIONS
          path  tour  gains  fix  fix-gate  unverified  privacy-manifest  gate  parsepolicy

          Query actions follow the same grammar as every candor engine: the report is DISCOVERED
          by default (walk up from CWD for a .candor/ dir; CANDOR_REPORT overrides). --report <locator>
          overrides both — a dir → <dir>/.candor/report, a *.json path → that report, else a prefix.
          --policy is a flag (honours CANDOR_POLICY then .candor/config). The old positional forms
          (a leading report prefix, a positional policy) stay accepted as deprecated aliases (stderr
          note). `gains` takes no discovery: both positionals ARE report locators. `parsepolicy
          <file>` dumps a parsed policy as canonical JSON (the conformance grammar-diff witness).

        OPTIONS
          --out <prefix>       write the report to <prefix>.<package>.Swift.json + a .callgraph.json sidecar
          --json               print the report as JSON to stdout (a scan then writes no files)
          --policy <file>      enforce a policy (deny/pure/allow/forbid) — exit 1 on a violation, 2 if unreadable
          --gate-json <file>   write the machine-readable gate verdict as JSON (`-` = stdout)
          --target <name>     scope the scan to ONE target plus its dependency closure — one scan per
                              SHIPPED BINARY. Resolves against Package.swift first, and falls back to
                              the repo's .xcodeproj project file(s) when the manifest is absent or does
                              not declare the name (stating which resolver answered). The Xcode closure
                              includes the target's LOCAL Swift packages, transitively; REMOTE packages
                              stay outside, counted and disclosed as uncovered. Without it a repo with
                              several products charges each one with every other one's effects, and a
                              privacy-manifest verify against one product's Info.plist answers about
                              code that product never compiles. Refuses (exit 2) on an unknown target
                              (listing the names that exist), an unparseable project, a missing source
                              dir/folder, or a local package it cannot read soundly — never silently
                              scanning less than the target compiles.
          --workspace (--deps) auto-discover the target's local `.package(path:)` deps, scan each into
                               .candor/deps/, and chain them so a cross-package call discloses the sibling's effect
          --report <locator>   (query actions) use this report instead of discovering .candor/
          --verify <plist>     (privacy-manifest) verify an Info.plist against the sensor reach — an under-declaration exits 1
          --strict             (unverified) exit 1 when PASS-but-Unknown holes exist
          --agents             print the agent contract for this build (AGENTS.md)
          -V, --version        print the installed build and the contract it speaks (offline)
          -h, --help           show this help

        ENVIRONMENT
          CANDOR_POLICY=<file>      the policy gate when --policy is absent; .candor/config `policy` is the floor
          CANDOR_BASELINE=<report>  the baseline regression guard (or a .candor/config `baseline` line):
                                    an existing function GAINING an effect vs the saved report fails (exit 1);
                                    new functions are exempt; a corrupt or cross-build baseline refuses to
                                    evaluate (exit 2); an absent file is a note

        EXAMPLES
          candor-swift .
          candor-swift path PhotoUploader.sync Net
          candor-swift privacy-manifest --verify App/Info.plist
          candor-swift . --policy candor.policy --gate-json verdict.json
          candor-swift gains new/.candor/report old/.candor/report

        Docs: candor.poly.io   ·   Verify an install: candor doctor
        """)
        exit(0)
    case "--version", "-V":
        // Two lines, fully OFFLINE: the installed build + the spec contract it speaks, then the
        // upgrade incantation. Both fields reuse the single sources of truth (releaseVersion /
        // specVersion) so this can never drift from the report envelope.
        print("candor-swift \(releaseVersion) (spec \(specVersion))")
        // Release-tag upgrades only (the family's deliberate-release rule — umbrella AGENTS §2a):
        // a bare `git pull` of main would build an untagged, unreleased HEAD.
        print("upgrade: git fetch --tags && git checkout <latest vX.Y.Z> && swift build -c release")
        exit(0)
    case "--agents":
        // The agent contract for THE INSTALLED BUILD, EMBEDDED at compile time (AgentsDoc.swift,
        // generated from AGENTS.md) — doc and engine cannot drift (the spec §2.1 version-trust
        // rule applied to documentation), and unlike a Bundle.module resource it survives a binary
        // copied out of .build (the documented `cp .build/release/candor-swift …` install flow,
        // where the resource bundle is absent and Bundle.module would fatalError before any guard).
        // Canonical header shape `candor-<engine> <version>` (consistent across the family); the
        // envelope keeps the hyphenated `engineVersion` as its build id.
        print("<!-- \(engineVersion.replacingOccurrences(of: "candor-swift-", with: "candor-swift ")) · the agent contract for this installed version -->")
        // default terminator re-adds the single trailing newline a Swift multiline raw string strips
        // before its closing delimiter, so the served body matches AGENTS.md byte-for-byte.
        print(AGENTS_MD)
        exit(0)
    default:
        // An unknown flag must FAIL, not become the scan path (a stale binary handed a newer
        // doc's flag would scan a directory literally named after it; a typo'd --policy would
        // silently drop the gate).
        if a.hasPrefix("-") {
            FileHandle.standardError.write("candor-swift: unknown flag \(a) (see --help)\n".data(using: .utf8)!)
            // …and if a verdict sink was requested, it gets the refusal too (SPEC §3.3 names an unknown
            // flag as a broken-gate-config exit-2 cause). For a FILE sink the armed document already
            // says this; this covers the `-` stream, which cannot be armed in advance.
            if !gateVerdictSinks.isEmpty { refuseGateAndExit("candor-swift: unknown flag \(a)") }
            // ⟨0.28⟩ …and the REPORT stream on exit-2 for the `--json` case with no verdict sink at all
            // (the trigger PART 37 (b) probes: `--json --zzz-not-a-flag`). Empty on other runs.
            writeReportStreamFailClosed(reasonKey: "unknown-flag", why: "candor-swift: unknown flag \(a)")
            // ⟨0.32⟩ …and the REFUSAL MARKER, which this path needs precisely BECAUSE it does not go
            // through `refuseGateAndExit`: that call above is guarded on a verdict sink existing, so the
            // commonest shape of all — an unknown flag with no `--gate-json` — exits here. Measured: the
            // first version of this port wrote the marker only in the funnel and produced none for
            // `candor-swift . --policy p --zzz-not-a-flag`, the exact case the rung exists for.
            writeRefusalMarker("candor-swift: unknown flag \(a)")
            exit(2)
        }
        // A SECOND POSITIONAL IS A USAGE ERROR, NOT A SILENT REPLACEMENT. `candor-swift a b` scanned `b`
        // and said nothing about `a` — so `candor-swift . rep.json`, a plausible misreading of the flag
        // grammar, scanned a path that did not exist and the operator had no way to see which target the
        // run had chosen. The scan takes exactly one.
        if sawPositional {
            let why = "candor-swift: unexpected extra argument `\(a)` — the scan takes ONE target "
                    + "(got `\(target)` and `\(a)`). Did you mean a flag? See --help."
            FileHandle.standardError.write((why + "\n").data(using: .utf8)!)
            // Same sink obligation as the unknown-flag arm directly above, and it was missing here. This
            // is the SECOND SPELLING of one usage error, and closing one spelling of a channel while its
            // sibling stays open is how the sink defects in this file got in. Found by the argv
            // COMBINATION sweep in candor/bin/probe-causes.sh rather than by the hand-written cause list:
            // an extra positional was not a cause anyone had enumerated. Differential when found —
            // candor-swift wrote ZERO bytes to `--gate-json -` while diagnosing it on stderr. (An earlier
            // note here cited candor-scan's refusal as the reference; it had none for this argv at the
            // time — it silently scanned the wrong tree, fixed minutes earlier the same day.)
            if !gateVerdictSinks.isEmpty { refuseGateAndExit(why) }
            // ⟨0.28⟩ REPORT STREAM on exit-2 — same reasoning as the unknown-flag arm above.
            writeReportStreamFailClosed(reasonKey: "unknown-flag", why: why)
            exit(2)
        }
        sawPositional = true
        target = a
        // ⟨0.32⟩ LATCH THE DEFAULT PREFIX DURING PARSING, not where `prefix` is finally resolved.
        // A refusal DURING parsing (an unknown flag is the everyday case) never reaches that
        // resolution, so latching later leaves the marker absent on exactly the case it exists for —
        // measured in candor-rust and candor-ts, both of which made that mistake first.
        noteRefusalTarget(a)
        noteRefusalPrefix(a + "/.candor/report")
    }
}

// ⟨0.24⟩ THE REFUSAL DOCUMENT HAS NO EXEMPT CAUSE (SPEC §3.1, candor-spec `1503368`). Set the sink
// BEFORE the config layer, which is itself an exit-2 cause: a CI wrapper that reads `--gate-json`
// unconditionally re-reads the PREVIOUS run's document as current, and a stale green does not care why
// this run declined to overwrite it. Flag-loop usage errors are already past, and they had no sink.
// `contains` guard: the pre-pass above already registers a `-` sink (a stream cannot be pre-armed, so it
// is registered instead), and appending it twice put TWO refusal documents on one stdout — a consumer
// parsing it gets "extra data" and no verdict at all, which is a worse answer than the zero bytes this
// registration was added to fix.
if let gp = gateJsonPath, !gateVerdictSinks.contains(gp) { gateVerdictSinks.append(gp) }
// (armed by the pre-pass above the flag loop — SPEC §3.3.1 ⟨0.27⟩, GateSinkArming.swift. Arming HERE
// was still after the loop's usage exits, so the contract depended on argv order.)

// (the §3.4 config layer lives in Config.swift)
let candorConfig = loadCandorConfig(targetPath: target)
// The --policy flag / CANDOR_POLICY env already populated policyPath; the config is the floor. A bare
// `policy` line ("" value) means configured-with-empty → the unreadable-policy path fails loud.
if policyPath == nil, let p = candorConfig["policy"] { policyPath = p }
// ⟨0.29⟩ A PEEK NEVER PEEKS, AND NEVER GATES. The child is spawned with no `--policy`, but a policy also
// arrives from `CANDOR_POLICY` (inherited) and from `.candor/config` (rediscovered from the same target),
// so refusing the flag alone would leave two doors open — and either one would make the child gate a file
// set the gate never judged, then spawn a peek of its own. Cleared HERE, where every source has already
// been applied, rather than at each source: that is the one place the answer cannot be routed around.
if peekListPath != nil { policyPath = nil }

let fm = FileManager.default
var isDir: ObjCBool = false
guard fm.fileExists(atPath: target, isDirectory: &isDir) else {
    FileHandle.standardError.write("candor-swift: no such path: \(target)\n".data(using: .utf8)!)
    // A file sink already holds the armed refusal; this is for the `-` stream, which cannot be armed in
    // advance and was giving a piping consumer ZERO BYTES on this exit.
    if !gateVerdictSinks.isEmpty { refuseGateAndExit("candor-swift: no such path: \(target)") }
    // ⟨0.28⟩ REPORT STREAM on exit-2 — the `--json` case with no verdict sink.
    writeReportStreamFailClosed(reasonKey: "target-missing",
                                why: "candor-swift: no such path: \(target)")
    exit(2)
}
let rootDir = isDir.boolValue ? target : (target as NSString).deletingLastPathComponent

var sourcePaths: [String] = []
// ⟨0.29⟩ THE SCOPE (candor-spec/FILE-SET-DESIGN.md §5): every file this walk skips, and WHY. Recorded
// AT THE SKIP rather than derived afterwards — a second walk could disagree with this one, and the
// disclosure would then describe an exclusion that did not happen, which is a different and worse kind
// of wrong than saying nothing. `.build/` is separated from the rest because it is UNBOUNDED and is the
// one class the peek must not read: a checkout tree holds other people's tests, and the noise floor
// "everything you vendored" is how a warning becomes something people scroll past.
var excludedFiles: [(path: String, cls: String)] = []
if let listFile = peekListPath {
    // ⟨0.29⟩ THE PEEK, CHILD SIDE. The parent hands us the EXACT set it disclosed as excluded, and we
    // analyse that and nothing else — same binary, same walk-free entry into `analyze`, same classifier.
    // See the parent half below for why this is a child process at all: candor-rust recurses into
    // `scan_one`, and this engine's scan is top-level code rather than a callable function, so the same
    // "one classifier, two file sets" guarantee has to come from the same BINARY.
    //
    // The list is the parent's, not a re-derivation: `--target` prunes sources far below this point, so a
    // child re-running the exclusion rules would peek at a different set from the one the report declares.
    guard let text = try? String(contentsOfFile: listFile, encoding: .utf8) else {
        FileHandle.standardError.write("candor-swift: --peek-excluded: cannot read \(listFile)\n".data(using: .utf8)!)
        exit(2)
    }
    sourcePaths = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
} else if isDir.boolValue {
    if let en = fm.enumerator(atPath: target) {
        for case let rel as String in en {
            guard rel.hasSuffix(".swift") else { continue }
            if isHarnessPath(rel) {
                excludedFiles.append((rel, rel.split(separator: "/").contains(".build") ? "build-output"
                                         : (rel as NSString).lastPathComponent == "Package.swift" ? "manifest"
                                         : "harness-target"))
                continue
            }
            let abs = (target as NSString).appendingPathComponent(rel)
            // …and a file that IMPORTS XCTest is a test wherever it sits. See `isTestSource`: an app
            // whose tests live beside their sources had them analysed as production, and a capture in a
            // test `setUp()` became the evidence that a shipping app's manifest was wrong.
            if let text = try? String(contentsOfFile: abs, encoding: .utf8), isTestSource(text) {
                excludedFiles.append((rel, "test-source"))
                continue
            }
            sourcePaths.append(abs)
        }
    }
} else {
    sourcePaths = [target]
}
sourcePaths.sort()
// ⟨0.30⟩ NO ANALYZABLE SOURCE IS STILL A REASON TO LOOK AT WHAT WAS EXCLUDED. Measured 2026-08-20 on
// published 0.30.0, in candor-ts first and then here: a package whose only Swift lives in a TEST target
// answered "no Swift sources", exit 2, and named nothing — while candor-rust, over the analogous shape
// (no `.rs` sources, a `build.rs` running `curl`), reached its peek and named `build::main performs
// Exec`. All three fail closed, so no gate goes green; but naming the function IS this rung's premise.
//
// When a policy is configured and there IS something excluded to read, the run continues to the peek.
// The refusal does not move — it becomes the NO_SOURCES arm beside the other exit-2 causes at the end.
// THAT BACKSTOP IS THE CARE POINT: in candor-ts the same change WITHOUT it made a clean-sibling tree —
// zero files analyzed, nothing wrong in the excluded sources — answer `policy ✓` at EXIT 0. A green over
// a tree the engine never read is the cardinal sin, arriving inside a disclosure fix.
let noSources = sourcePaths.isEmpty
if noSources && !(policyPath != nil && !excludedFiles.isEmpty) {
    // An EMPTY SCAN is an exit-2 cause like any other, and §3.1 exempts none: a consumer reading the
    // stream after it must not get nothing. Easy to hit in CI when a path moves, and the last cause in
    // this engine still exiting raw — found by probing causes a user can trigger rather than by reading
    // exit sites.
    // §3.3(d) MUST — the refusal names what a target of this engine's kind looks like. Carried INSIDE
    // the refusal string rather than printed beside it, so the `--gate-json` document's `reason` gets
    // the remedy too: a machine consumer reading only that document is exactly the reader who cannot
    // go and look at stderr. candor-rust's reads the same way.
    refuseGateAndExit("candor-swift: no Swift sources under \(target) — candor-swift reads `.swift` "
        + "files; point it at a SwiftPM package, an .xcodeproj, or a directory containing them. "
        + "Exit 2 (unevaluable): a target this engine cannot read is not a clean scan.")
}
if noSources {
    FileHandle.standardError.write(
        ("candor-swift: no Swift sources under \(target) — reading what this scan excluded, because a "
         + "policy is configured and there are excluded files to look at\n").data(using: .utf8)!)
}

// ⟨--target⟩ RESTRICT the scan to one shipped binary. A package with several products sharing a core
// otherwise charges each one with every other one's effects — measured on a real app, where a whole-repo
// scan verified against the macOS Info.plist reported a Mic under-declaration for a sensor only the iOS
// target can reach. Every failure below REFUSES: this feature makes a scan see LESS, and under ⟨0.21⟩
// absence from `functions` is a positive purity claim, so "resolve less than asked, quietly" is the
// cardinal sin wearing a convenience flag.
// ⟨--target on .xcodeproj⟩ The SPM resolution above this needs a `Package.swift`, and the audience the
// privacy-manifest verb is promoted to — iOS developers — overwhelmingly has an `.xcodeproj` instead.
// The old behaviour was an exit-2 dead end on exactly those repos, which left their scans whole-repo:
// NetNewsWire's iOS plist charged NSAppleEventsUsageDescription from Mac-only code, Focus's plist
// charged Speech from firefox's QuickAnswers code (both measured, both false). This resolves the target
// in the project file(s) instead: PBXNativeTarget -> Sources phase file refs through the group tree,
// plus Xcode 16 synchronized folders with their per-target membership exceptions, plus the in-project
// dependency closure. Same refusal contract as the SPM path — every failure exits 2, because a
// half-resolved scope is a purity claim over the files it silently dropped.
/// The filesystem the Xcode resolver reads through — ONE construction, used by the `--target`
/// path and the whole-repo pass. It was inline in the first and would have been copied into the
/// second; a second copy of a filesystem stub is a second set of answers about the same disk.
func makeXcodeScopeFS() -> XcodeScopeFS {
    let fm = FileManager.default
    func isDirectory(_ p: String) -> Bool {
        var isD: ObjCBool = false
        return fm.fileExists(atPath: p, isDirectory: &isD) && isD.boolValue
    }
    return XcodeScopeFS(
            swiftFilesUnder: { dir in
                guard isDirectory(dir), let en = fm.enumerator(atPath: dir) else { return nil }
                var out: [String] = []
                for case let sub as String in en where sub.hasSuffix(".swift") {
                    out.append((dir as NSString).appendingPathComponent(sub))
                }
                return out
            },
            readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
            subdirectories: { dir in
                ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                    .map { (dir as NSString).appendingPathComponent($0) }
                    .filter(isDirectory)
            },
            directoryExists: isDirectory,
            dumpPackage: { dir in
                // `swift package dump-package`: SwiftPM itself reading a manifest the structural
                // parser proved it cannot (targets built by helper functions over hoisted arrays —
                // WordPress's Modules). This EXECUTES the manifest, which is why it is a last resort,
                // is disclosed in the scope note, and is never reached for a manifest the structural
                // parse fully reads. No toolchain ⇒ nil ⇒ the resolution refuses loudly downstream.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["swift", "package", "dump-package", "--package-path", dir]
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                guard (try? p.run()) != nil else { return nil }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                _ = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { return nil }
                return String(data: data, encoding: .utf8)
            })
}

/// Fold resolved Xcode scopes into the two PER-FILE maps the driver consults: which local package
/// products, and which sibling Xcode-target modules, each source file may import.
///
/// ONE IMPLEMENTATION, called by both the `--target` path and the whole-repo path. The whole-repo path
/// arrived second, and writing a second copy of this is precisely the mistake this file has now made
/// four times under different names — two manifest readers, two xcconfig readers, two path
/// normalizers, a dead twin of a live function. The subtle parts below are why it matters.
///
/// A file compiled by SEVERAL targets takes the UNION of their evidence: it must build in every one of
/// them, so anything it imports is on all their import paths.
///
/// KEYED BY THE DISK'S SPELLING. The membership join is case-INSENSITIVE because a `PBXFileReference`
/// whose case drifted from disk still builds in Xcode, while the driver looks this map up with the path
/// it walked off disk. But only where the lowercased form picks out exactly ONE file on each side — on
/// a case-sensitive volume `A.swift` and `a.swift` are two files, and letting them share a key would
/// hand one the other's claims, which trades a false disclosure for a purity claim. Ambiguity yields no
/// entry, so it discloses.
func mergePerFileXcodeEvidence(scopes: [XcodeTargetScope], sourcePaths: [String],
                               links: inout [String: [LocalProductRef]],
                               modules: inout [String: [String]]) {
    var linksByLowerKey: [String: [LocalProductRef]] = [:]
    var modulesByLowerKey: [String: [String]] = [:]
    // WHICH MODULES DID THIS RUN ACTUALLY READ.
    //
    // `xcodeModulesByTarget` is derived from `filesByTarget`, which is what the PROJECT FILE lists — not
    // what the scan read. A group whose path escapes the scan root (`path = "../Shared"`, the shape
    // `candorAbsolutePath` exists to support) lists files discovery never walks, so a target could be
    // claimed as an analyzed module on the strength of sources this run never opened. Measured: a
    // framework target named `Shared` whose only file sits outside the scan root took `appEntry` to
    // `functions: []` — a purity claim over a URLSession upload — while renaming that target to
    // `SharedX`, changing nothing else, disclosed it. A release-introduced silence, caught by the
    // go/no-go panel.
    //
    // The check belongs HERE because this is where the read set exists. Same shape as the guard the
    // `LocalProductRef` channel already had, which is why that channel was never exposed.
    let readKeys = Set(sourcePaths.map { candorAbsolutePath($0).lowercased() })
    // PER SCOPE, AND KEYED BY TARGET. The first version of this gate collected read MODULE NAMES into
    // one set across every scope, which let a target that WAS read vouch for a different, unread target
    // producing the same module name — the platform-variant layout (`Kit-iOS`/`Kit-macOS` both
    // producing `Kit`) makes that ordinary, and in whole-repo mode the set also spanned separate
    // `.xcodeproj`s. Measured: `functions: []` over an unread URLSession upload, flipping to full
    // disclosure when only the READ target's module name changed. A name-keyed guard against a
    // name-collision defect.
    var readTargetsByScope: [Int: Set<String>] = [:]
    for (i, scope) in scopes.enumerated() {
        var read = Set<String>()
        for (tname, tfiles) in scope.filesByTarget
        where tfiles.contains(where: { readKeys.contains(candorAbsolutePath($0).lowercased()) }) {
            read.insert(tname)
        }
        readTargetsByScope[i] = read
    }
    for (i, scope) in scopes.enumerated() {
        for (tname, tfiles) in scope.filesByTarget {
            let prods = scope.localProductsByTarget[tname] ?? []
            // Resolve producing TARGET -> module name only for targets read IN THIS SCOPE.
            let mods = (scope.xcodeModuleTargetsByTarget[tname] ?? [])
                .filter { readTargetsByScope[i]?.contains($0) == true }
                .compactMap { scope.moduleNameByTarget[$0] }
            if prods.isEmpty && mods.isEmpty { continue }
            for f in tfiles {
                let key = candorAbsolutePath(f).lowercased()
                if !prods.isEmpty {
                    var have = linksByLowerKey[key] ?? []
                    for d in prods where !have.contains(d) { have.append(d) }
                    linksByLowerKey[key] = have
                }
                if !mods.isEmpty {
                    var have = modulesByLowerKey[key] ?? []
                    for m in mods where !have.contains(m) { have.append(m) }
                    modulesByLowerKey[key] = have
                }
            }
        }
    }
    var seenLower = Set<String>(), ambiguous = Set<String>()
    for raw in sourcePaths {
        let key = candorAbsolutePath(raw).lowercased()
        if !seenLower.insert(key).inserted { ambiguous.insert(key) }
    }
    for raw in sourcePaths {
        let abs = candorAbsolutePath(raw), key = abs.lowercased()
        guard !ambiguous.contains(key) else { continue }
        if let prods = linksByLowerKey[key] { links[abs] = prods }
        if let mods = modulesByLowerKey[key] { modules[abs] = mods }
    }
}

func scopeToXcodeTarget(_ want: String, rootDir: String, sourcePaths: inout [String],
                        resolved: inout (target: String, project: String, entitlements: String?)?,
                        resolvedLinksByFile: inout [String: [LocalProductRef]],
                        resolvedModulesByFile: inout [String: [String]],
                        packageSwiftExists: Bool = false, alsoDeclaredInPackageSwift: [String] = []) {
    let fm = FileManager.default
    let projects = findXcodeProjects(under: rootDir)
    guard !projects.isEmpty else {
        // A REFUSAL THAT NAMES THE REMEDY. Measured on bitwarden/ios, which GENERATES its project:
        // a fresh clone has no `.xcodeproj` at all, and the bare message above told a user with a
        // perfectly ordinary repo only that something was missing — a dead end, which is the one thing
        // this project's failures are not allowed to be. If a generator's manifest is sitting right
        // there, say so and say what to run; the file is the evidence, so this cannot mis-advise a repo
        // that simply has no project.
        let generators: [(file: String, run: String)] = [
            ("project.yml", "xcodegen generate"), ("Project.swift", "tuist generate"),
            ("Tuist.swift", "tuist generate"), ("workspace.yml", "xcodegen generate"),
        ]
        var found: [(String, String)] = []
        for g in generators where fm.fileExists(atPath: (rootDir as NSString).appendingPathComponent(g.file)) {
            found.append((g.file, g.run))
        }
        // XcodeGen's split-spec convention: `project-<name>.yml` with no plain `project.yml`.
        // NAME THEM ALL rather than pick one — bitwarden/ios has five (`project-bwa`, `-bwk`, `-bwth`,
        // `-common`, `-pm`) and the alphabetically-first is the Authenticator, not the app. Suggesting
        // one command that generates the wrong product is the same guess this resolver refuses to make
        // everywhere else; a list the reader can choose from is not.
        var splitSpecs: [String] = []
        if found.isEmpty, let names = try? fm.contentsOfDirectory(atPath: rootDir) {
            splitSpecs = names.filter { $0.hasPrefix("project") && $0.hasSuffix(".yml") }.sorted()
        }
        var msg = "candor-swift: --target needs a Package.swift or an .xcodeproj to resolve against; "
            + "neither found under \(rootDir)\n"
        if let g = found.first {
            msg += "  This repo GENERATES its project (\(g.0) is here), so there is nothing to read "
                + "until you generate it:\n      \(g.1)\n"
        } else if !splitSpecs.isEmpty {
            msg += "  This repo GENERATES its project — \(splitSpecs.count) XcodeGen spec(s) are here "
                + "and which one builds the product you mean is yours to say:\n"
            for spec in splitSpecs { msg += "      xcodegen generate --spec \(spec)\n" }
        }
        if found.first != nil || !splitSpecs.isEmpty {
            msg += "  Then re-run the same --target. Without a target the scan is whole-repo, which is "
                + "sound but answers about every product at once.\n"
        }
        FileHandle.standardError.write(msg.data(using: .utf8)!)
        // ⟨0.28⟩ REPORT STREAM on exit-2 — see writeReportStreamFailClosed.
        writeReportStreamFailClosed(reasonKey: "target-missing", why: "--target \(want): no Package.swift or .xcodeproj to resolve against")
        exit(2)
    }
    do {
        // Parse EVERY project before matching. A repo like firefox-ios carries several (`Client`,
        // `Blockzilla`, sample apps); matching against the first parseable one would resolve a name
        // that another project also defines — or miss the one the user meant entirely.
        var parsed: [(path: String, model: PbxprojModel)] = []
        for proj in projects {
            let pbx = (proj as NSString).appendingPathComponent("project.pbxproj")
            guard let text = try? String(contentsOfFile: pbx, encoding: .utf8) else {
                throw XcodeScopeError.unparseable(file: pbx, reason: "unreadable")
            }
            parsed.append((proj, try parsePbxproj(text: text, file: pbx)))
        }
        let hits = parsed.filter { pbxprojTargets($0.model).contains(where: { $0.name == want }) }
        if hits.count > 1 {
            FileHandle.standardError.write(("candor-swift: --target \(want) — \(hits.count) projects "
                + "define a target of that name (\(hits.map { rel($0.path, to: rootDir) }.joined(separator: ", "))). "
                + "Refusing to pick one: they are different products. Point the scan at one project's "
                + "directory instead.\n").data(using: .utf8)!)
            writeReportStreamFailClosed(reasonKey: "target-missing", why: "--target \(want) is ambiguous across projects")
            exit(2)
        }
        guard let hit = hits.first else {
            // The vocabulary refusal, across every project found: a user who mistypes needs the real
            // names, shipped products first, test bundles labelled as what they are.
            var msg = "candor-swift: --target \(want) — no project here defines that target.\n"
            for (proj, model) in parsed {
                let ts = pbxprojTargets(model)
                guard !ts.isEmpty else { continue }
                msg += "  \(rel(proj, to: rootDir)) declares:\n"
                for t in ts { msg += "    \(t.name)  (\(t.kindLabel))\n" }
            }
            if !alsoDeclaredInPackageSwift.isEmpty {
                msg += "  Package.swift declares: \(alsoDeclaredInPackageSwift.joined(separator: ", "))\n"
            }
            FileHandle.standardError.write(msg.data(using: .utf8)!)
            writeReportStreamFailClosed(reasonKey: "target-missing", why: "--target \(want) not declared by any project here")
            exit(2)
        }
        let projectDir = (hit.path as NSString).deletingLastPathComponent
        func isDirectory(_ p: String) -> Bool {
            var isD: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &isD) && isD.boolValue
        }
        let scope = try xcodeTargetScope(model: hit.model, projectDir: projectDir, targetName: want,
                                         fs: makeXcodeScopeFS())
        // CASE-INSENSITIVE membership. macOS filesystems are; a pbxproj path whose case drifted from
        // the disk's still builds in Xcode, and an exact-case compare would silently drop that file
        // from the scope — the miss-shaped failure. Two repo files differing only by case would
        // over-include, which merely keeps a file the unscoped scan already had.
        let member = Set(scope.files.map { $0.lowercased() })
        // The SAME normalizer the resolver used — the two sides of this membership test must agree
        // byte for byte, and `candorAbsolutePath` is the only spelling that is right for both an
        // absolute and a relative scan root. See its doc comment for what each half alone got wrong.
        func std(_ p: String) -> String { candorAbsolutePath(p).lowercased() }
        let before = sourcePaths.count
        sourcePaths = sourcePaths.filter { member.contains(std($0)) }
        if sourcePaths.isEmpty {
            FileHandle.standardError.write(("candor-swift: --target \(want) resolved to "
                + "\(scope.closure.map(\.name).joined(separator: ", ")) but none of its \(scope.files.count) "
                + "Swift file(s) are under the scanned tree — refusing to report an empty scan as a clean one\n")
                .data(using: .utf8)!)
            writeReportStreamFailClosed(reasonKey: "target-missing", why: "--target \(want) resolved but no sources under the scanned tree")
            exit(2)
        }
        // DISCLOSED, not silent — and it says WHICH resolver answered: an Xcode target and an SPM
        // target are different structures, and the SPM form is what this flag means on a Package.swift
        // repo. The κ boundary is stated in the same breath so a conditional verify has its referent.
        // Say WHY the Xcode resolver answered, truthfully: "no Package.swift" when there is none, and
        // "Package.swift does not declare it" when one exists but the name is only a project target —
        // the first draft printed "(no Package.swift)" beside firefox-ios's Danger manifest, a false
        // statement in the one line whose whole job is provenance.
        let why = packageSwiftExists ? "Package.swift declares no target of this name"
                                     : "no Package.swift"
        var note = "candor-swift: --target \(want) — resolved via \(rel(hit.path, to: rootDir)) "
            + "(\(why)): scanning \(scope.closure.count) target(s) "
            + "[\(scope.closure.map(\.name).joined(separator: ", "))]"
        if !scope.localPackages.isEmpty {
            note += " + \(scope.localPackages.count) local Swift package(s) "
                + "[\(scope.localPackages.joined(separator: ", "))]"
        }
        if !scope.packagesReadViaDump.isEmpty {
            // Manifest code was EXECUTED for these (SwiftPM's own reader) — that is a different trust
            // statement from a structural parse, and the reader gets to know it happened.
            note += " (\(scope.packagesReadViaDump.joined(separator: ", ")) read via "
                + "`swift package dump-package` — manifest too dynamic for the structural parser)"
        }
        note += ", \(sourcePaths.count) of \(before) source file(s)."
        if let p = scope.platform, scope.platformExcludedCount > 0 {
            // The platform prune is a MEMBERSHIP statement and it is disclosed like one: these files
            // are in the target's packages but compile to nothing on its platform (`#if os(…)`).
            note += " \(scope.platformExcludedCount) file(s) excluded as compiling to nothing on \(p)."
        }
        note += " This verdict covers that closure ONLY."
        if scope.remoteProductCount > 0 || scope.crossProjectDependencyCount > 0 {
            var outside: [String] = []
            if scope.remoteProductCount > 0 { outside.append("\(scope.remoteProductCount) REMOTE package product(s)") }
            if scope.crossProjectDependencyCount > 0 { outside.append("\(scope.crossProjectDependencyCount) cross-project dependenc(ies)") }
            note += " Depends on \(outside.joined(separator: " and ")) NOT in the closure — calls into "
                + "them are disclosed as uncovered, never silently pure."
        }
        if let ent = scope.entitlements {
            // The reader is told WHICH file, because "we found your entitlements" is only useful if you
            // can check it is the one you meant.
            note += " Entitlements: \(rel(ent, to: rootDir)) (from this target's CODE_SIGN_ENTITLEMENTS)."
        }
        note += "\n"
        FileHandle.standardError.write(note.data(using: .utf8)!)
        resolved = (target: want, project: rel(hit.path, to: rootDir),
                    entitlements: scope.entitlements)
        // Invert files-by-target × links-by-target into the per-file answer the driver needs. A file
        // compiled by two targets takes the UNION of their links — it must build in both, so both link
        // whatever it imports. A file no target claims gets no entry and therefore claims nothing.
        //
        // KEYED BY THE DISK'S SPELLING, not the pbxproj's. The membership filter above matches
        // case-INSENSITIVELY on purpose (a pbxproj path whose case drifted from disk still builds in
        // Xcode, and dropping that file would be the miss-shaped failure), while the driver looks this
        // map up with the path it walked off disk. Keying it the resolver's way meant one character of
        // case in one `PBXFileReference` silently reverted this whole rung for that file: it stayed in
        // scope, missed its links, and every module it imports was named a blind spot.
        //
        // The two spellings are joined through the lowercased form — but ONLY where that form picks out
        // exactly one file on each side. On a case-sensitive volume `A.swift` and `a.swift` are two
        // files; letting them share a key would hand one the other's links, which trades this false
        // disclosure for a purity claim. Ambiguity here yields no entry, so it discloses.
        mergePerFileXcodeEvidence(scopes: [scope], sourcePaths: sourcePaths,
                                  links: &resolvedLinksByFile, modules: &resolvedModulesByFile)
        // A test bundle is selectable by name — but its verdict is about test code, and saying so is
        // the difference between a feature and a trap for whoever scoped to `MyAppTests` by accident.
        if scope.target.isTest {
            FileHandle.standardError.write(("candor-swift: note — `\(want)` is a \(scope.target.kindLabel) "
                + "target, not a shipped binary; its manifest verdict is about test code.\n").data(using: .utf8)!)
        }
    } catch let e as XcodeScopeError {
        FileHandle.standardError.write("candor-swift: --target \(want): \(e)\n".data(using: .utf8)!)
        writeReportStreamFailClosed(reasonKey: "target-missing", why: "--target \(want): \(e)")
        exit(2)
    } catch {
        FileHandle.standardError.write("candor-swift: --target \(want): \(error)\n".data(using: .utf8)!)
        writeReportStreamFailClosed(reasonKey: "target-missing", why: "--target \(want): \(error)")
        exit(2)
    }
}

/// `path` relative to `root`, for messages — an absolute pbxproj path in a refusal is noise.
func rel(_ path: String, to root: String) -> String {
    let p = candorAbsolutePath(path)
    let r = candorAbsolutePath(root)
    return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
}

// ⟨0.29⟩ The `--target` prune below removes files from `sourcePaths`, and those are excluded exactly like
// the walk's skips: same-language source under the scan root that this run did not judge. Captured as a
// DIFF of the selector's own two states rather than by re-deriving the closure — a second derivation could
// disagree with the one that actually ran, and the disclosure would then describe a prune that did not
// happen. Empty when `--target` is absent, since nothing is removed.
let sourcePathsBeforeScoping = sourcePaths
if let want = scopeTarget {
    let manifestPath = (rootDir as NSString).appendingPathComponent("Package.swift")
    // A repo with BOTH a Package.swift and an .xcodeproj resolves via SwiftPM, unchanged — the Xcode
    // path is a FALLBACK, and which resolver answered is stated in each disclosure line, because the
    // two resolve different structures and a verdict's reader needs to know which it is about.
    let manifestSrc = try? String(contentsOfFile: manifestPath, encoding: .utf8)
    let declaredSPM = manifestSrc.map(parsePackageTargets(manifestSource:)) ?? []
    // The SPM resolution keeps priority for every name it CAN resolve — its behaviour is unchanged.
    // The Xcode path runs when there is no Package.swift at all, OR when the manifest does not declare
    // the name and a `.xcodeproj` might: a repo whose root Package.swift is tooling-only (firefox-ios
    // ships a Danger manifest beside two products' project files) otherwise dead-ends with
    // "declares: DangerDependencies" while the target the user named sits right there in a project
    // file. A name BOTH declare resolves via SwiftPM, exactly as before.
    let spmHasTarget = declaredSPM.contains { $0.name == want }
    let xcodeProjects = (manifestSrc == nil || !spmHasTarget) ? findXcodeProjects(under: rootDir) : []
    if manifestSrc == nil || (!spmHasTarget && !xcodeProjects.isEmpty) {
        // Exits 2 on any failure, so reaching the code after this `if` means sourcePaths IS the
        // target's file list, whichever resolver ran.
        scopeToXcodeTarget(want, rootDir: rootDir, sourcePaths: &sourcePaths,
                           resolved: &resolvedXcodeScope,
                           resolvedLinksByFile: &resolvedXcodeLinksByFile,
                           resolvedModulesByFile: &resolvedXcodeModulesByFile,
                           packageSwiftExists: manifestSrc != nil,
                           alsoDeclaredInPackageSwift: declaredSPM.map(\.name).sorted())
    }
    if manifestSrc != nil && (spmHasTarget || xcodeProjects.isEmpty) {
    let declared = declaredSPM
    do {
        let closure = try targetClosure(want, in: declared)
        let dirs = try targetSourceDirs(closure, packageRoot: rootDir, exists: { p in
            var d: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        })
        // STANDARDIZE BOTH SIDES before comparing. `path: "."` is legal SwiftPM (a single-target package
        // rooted at the manifest) and `appendingPathComponent(".")` yields `./.`, which prefix-matches
        // nothing — so the scan refused with "no Swift sources are under ./.", naming a remedy that could
        // not work while the sources sat right there. Compare on the standardized forms; `sourcePaths`
        // itself is left alone, since the report's `loc:` is written from it.
        // Compare ABSOLUTE, standardized paths on both sides. Two forms defeated the naive prefix match:
        // `path: "."` is legal SwiftPM and `appendingPathComponent(".")` yields `./.`, and
        // `standardizingPath` alone does not help — it strips a leading `./` from the FILES while leaving
        // `.` as `.`, so the two sides still never line up. The symptom was a scan refusing with
        // "no Swift sources are under ./." while the sources sat right there: a dead end whose stated
        // remedy could not work. `sourcePaths` itself is left alone, since the report's `loc:` uses it.
        func abs(_ p: String) -> String { candorAbsolutePath(p) }
        let prefixes = dirs.map { d -> String in
            let n = abs(d)
            return n.hasSuffix("/") ? n : n + "/"
        }
        let before = sourcePaths.count
        sourcePaths = sourcePaths.filter { p in prefixes.contains(where: { abs(p).hasPrefix($0) }) }
        if sourcePaths.isEmpty {
            FileHandle.standardError.write(("candor-swift: --target \(want) resolved to "
                + "\(closure.map(\.name).joined(separator: ", ")) but no Swift sources are under "
                + "\(dirs.joined(separator: ", ")) — refusing to report an empty scan as a clean one\n").data(using: .utf8)!)
            writeReportStreamFailClosed(reasonKey: "target-missing", why: "--target \(want): no sources under resolved dirs")
            exit(2)
        }
        // DISCLOSED, not silent. The reader must be able to tell a scoped scan from a whole-tree one:
        // a clean verdict here is a claim about ONE binary, and the same tree scanned whole may differ.
        FileHandle.standardError.write(("candor-swift: --target \(want) — resolved via Package.swift: "
            + "scanning \(closure.count) target(s) "
            + "[\(closure.map(\.name).joined(separator: ", "))], \(sourcePaths.count) of \(before) source file(s). "
            + "This verdict covers that closure ONLY.\n").data(using: .utf8)!)
    } catch let e as TargetScopeError {
        FileHandle.standardError.write("candor-swift: \(e)\n".data(using: .utf8)!)
        writeReportStreamFailClosed(reasonKey: "target-missing", why: "\(e)")
        exit(2)
    } catch {
        FileHandle.standardError.write("candor-swift: --target \(want): \(error)\n".data(using: .utf8)!)
        writeReportStreamFailClosed(reasonKey: "target-missing", why: "--target \(want): \(error)")
        exit(2)
    }
    }
} else {
    // ── WHOLE-REPO IDENTITY FOR AN `.xcodeproj` TREE ─────────────────────────────────────────────
    //
    // Without `--target`, an app-level file had no owning `Package.swift` and no resolved scope, so it
    // claimed NOTHING and every module it imports was named a blind spot — including local packages and
    // sibling framework targets this very run had analyzed. Measured on NetNewsWire: 32 uncovered
    // modules, 14 of them local packages whose sources are in the same report.
    //
    // The answer is the same evidence `--target` uses, gathered for EVERY target instead of one. A file
    // compiled by several targets takes the union of their evidence, which is sound because it must
    // build in all of them.
    //
    // NOT A UNION OVER TARGETS' CLOSURES. That shortcut is one line and re-opens the class that produced
    // ten silent under-reports: a file in the Widget Extension would be claimed on the app's links. The
    // merge is per FILE, from each target's own file list.
    //
    // A target that REFUSES is skipped, not fatal. Whole-repo is not the scoped promise — the scan
    // proceeds over every file either way, and a skipped target simply contributes no claims, so its
    // files keep disclosing. Refusing the whole run because one auxiliary target is unresolvable would
    // turn a disclosure improvement into a dead end.
    let projects = findXcodeProjects(under: rootDir)
    if !projects.isEmpty {
        var scopes: [XcodeTargetScope] = []
        var refused = 0
        let scopeFS = makeXcodeScopeFS()
        for projPath in projects {
            let pbx = (projPath as NSString).appendingPathComponent("project.pbxproj")
            guard let text = try? String(contentsOfFile: pbx, encoding: .utf8),
                  let model = try? parsePbxproj(text: text, file: pbx) else { continue }
            let projectDir = (projPath as NSString).deletingLastPathComponent
            for info in pbxprojTargets(model) {
                if let scope = try? xcodeTargetScope(model: model, projectDir: projectDir,
                                                     targetName: info.name, fs: scopeFS) {
                    scopes.append(scope)
                } else {
                    refused += 1
                }
            }
        }
        mergePerFileXcodeEvidence(scopes: scopes, sourcePaths: sourcePaths,
                                  links: &resolvedXcodeLinksByFile,
                                  modules: &resolvedXcodeModulesByFile)
        // DISCLOSE THE SKIPS. A target this could not resolve is a set of files answering with less
        // than the rest, and a reader comparing a whole-repo ledger against a scoped one deserves to
        // know why they differ.
        if refused > 0 {
            FileHandle.standardError.write(("candor-swift: note — \(refused) Xcode target(s) could not be "
                + "resolved for module identity; files only they compile keep disclosing every module "
                + "they import. Scan with `--target <name>` to see why one of them refuses.\n")
                .data(using: .utf8)!)
        }
    }
}
// ⟨0.29⟩ …and the prune's own record. `--target` is the sharpest of this engine's exclusions: the files it
// removes are production source, in the scanned tree, that a whole-repo scan WOULD have judged — so a
// verdict read without knowing the prune happened is a verdict about a different question.
if scopeTarget != nil, sourcePaths.count < sourcePathsBeforeScoping.count {
    let kept = Set(sourcePaths)
    for p in sourcePathsBeforeScoping where !kept.contains(p) {
        excludedFiles.append((rel(p, to: rootDir), "outside-the-target-closure"))
    }
}

/// THE package-name parse — the WRITER's, and the only one. `<dir>/Package.swift`'s first `name: "…"`.
///
/// THERE WERE TWO OF THESE AND THEY WERE NOT THE SAME. `--workspace`'s sweep carried its own copy,
/// anchored AFTER `Package(`, under a comment claiming it used "the same three sources the writer uses,
/// in the same order". The writer is UNANCHORED and takes the first `name:` in the whole manifest, so
/// any manifest that mentions one before the `Package(` call — a hoisted `let targets: [Target] =
/// [.target(name: "…")]`, a hoisted dependency array, both ordinary Swift manifest idioms — makes the
/// two disagree. The sweep then works on a name the writer never used: it SPARES the stale report it
/// exists to remove (`43a0eaa`'s false all-clear, back — measured, the consumer's `use0` goes ABSENT
/// from `functions` over a dependency that writes a file), and DELETES whatever happens to sit under
/// the name it invented instead.
///
/// SO THE POINT IS NOT THAT THIS PARSE IS GOOD. It is not — the first `name:` in a manifest is very
/// often a target's, and this is the same field in the same two roles as the open package-vs-module
/// keying row. The point is that there is ONE of it, so improving it moves the writer and the sweep
/// together. Two parses that agree by inspection stop agreeing the moment somebody edits one, and a
/// comment asserting they agree is exactly the shape that survives review while being false.
func manifestPackageName(atDir dir: String) -> String? {
    guard let manifest = try? String(contentsOfFile: (dir as NSString).appendingPathComponent("Package.swift"),
                                     encoding: .utf8),
          let r = manifest.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) else { return nil }
    let m = String(manifest[r])
    guard let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 else { return nil }
    return String(m[m.index(after: q1)..<q2])
}

// The package name — the first half of the §2 `hash` join key. Package.swift's name, else the dir.
var pkgName = (rootDir as NSString).lastPathComponent
if let n = manifestPackageName(atDir: rootDir) { pkgName = n }
// ⟨--target⟩ A SCOPED REPORT IS NOT AN ANSWER ABOUT THE PACKAGE, and the join key must say so.
//
// `pkgName` is the §2 `hash` prefix (`"<pkg>#<qualified>"`) and the report filename. Leaving it alone
// made a scoped report byte-indistinguishable from a whole-package one to a MACHINE consumer: same
// `package`, same key namespace, just fewer functions. The stderr scope note is transient and is not in
// the artifact anyone chains. Under ⟨0.21⟩ absence from `functions` is a POSITIVE purity claim, so a
// consumer chaining this as `MultiTarget` reads every function in the targets it never scanned as pure —
// the cardinal sin, introduced by a convenience flag.
//
// Qualifying the key fixes it WITHOUT a format change, and fails in the safe direction: a consumer
// looking for `MultiTarget#foo` simply does not match `MultiTarget/MacApp#foo`, so the call resolves to
// DISCLOSED (unresolved / invisible) rather than to a silent purity claim. It also stops two targets of
// one package overwriting each other's report file, which they otherwise did.
if let want = scopeTarget { pkgName = "\(pkgName)/\(want)" }
if let manifest = try? String(contentsOfFile: (rootDir as NSString).appendingPathComponent("Package.swift"), encoding: .utf8) {
    // ⟨0.19⟩ SETUP warning (SPEC §6.2 §3, the setup/genuine split): a manifest that declares dependencies but
    // whose `.build/checkouts` is absent hasn't fetched them — the analog of a missing node_modules. Calls into
    // those packages resolve to the κ coverage ledger as `invisible` (never silently pure), but a fuller
    // analysis needs the deps present. A SCAN-LEVEL remediation only (no per-fn `setup` tag: SwiftSyntax does
    // no cross-module resolution, so attributing a specific call to an unfetched dep can't be done SAFELY — a
    // wrong `setup` tag would make a genuine dynamic hole tolerable by `Unknown[dynamic]`, an under-gate).
    var declaredDeps = 0
    var scan = manifest[...]
    while let r = scan.range(of: #"\.package\(\s*(url|name|path):"#, options: .regularExpression) {
        declaredDeps += 1
        scan = scan[r.upperBound...]
    }
    let checkouts = (rootDir as NSString).appendingPathComponent(".build/checkouts")
    var isDir: ObjCBool = false
    let fetched = FileManager.default.fileExists(atPath: checkouts, isDirectory: &isDir) && isDir.boolValue
    if declaredDeps > 0 && !fetched {
        FileHandle.standardError.write(("candor-swift: SETUP — Package.swift declares \(declaredDeps) dependenc\(declaredDeps == 1 ? "y" : "ies") "
            + "but .build/checkouts is absent (deps not fetched); calls into those packages resolve to the κ coverage "
            + "ledger as `invisible`, not fully analyzed. Run `swift build` (or `swift package resolve`) first, then re-scan.\n").data(using: .utf8)!)
    }
}

// (Pass A / Pass B collectors live in DeclCollector.swift / CallCollector.swift;
//  the two-pass drive lives in Driver.swift — called here.)

// ⟨workspace chain⟩ --workspace: discover the target's LOCAL PATH deps from Package.swift
// (`.package(path: "../X")`), scan each into .candor/deps/ with CANDOR_WORKSPACE_CHAIN (protocol-CHA union
// entries), transitively to a fixpoint, and prepend that dir to the CANDOR_DEPS spec below. The child scan
// is spawned WITHOUT --workspace (no re-discovery recursion). The candor-ts `--workspace` analog.
var workspaceDepsDir: String? = nil
if wantWorkspace {
    let selfPath = CommandLine.arguments[0]
    let depsDir = (rootDir as NSString).appendingPathComponent(".candor/deps")
    try? fm.createDirectory(atPath: depsDir, withIntermediateDirectories: true)
    // Local path-deps, through the SAME parser everything else uses. What stood here was a line regex
    // requiring `.package(` and `path:` on ONE line, with no comment handling — so a commented-out
    // `.package(path: "../Old")` was discovered and CHAINED, putting a package the root does not depend
    // on into `deps.coveredPkgs`, where its silence reads as a purity claim. It also missed every
    // multi-line declaration, which is merely a scope loss.
    //
    // `parsePackageLocalDependencies` was written for this and wired only into the driver; its own doc
    // comment described this reader in the PAST TENSE while it was still running. That is the fourth
    // hand-rolled manifest reader in this codebase and the last one.
    var depPaths: [String] = []
    if let manifest = try? String(contentsOfFile: (rootDir as NSString).appendingPathComponent("Package.swift"), encoding: .utf8) {
        for rel in parsePackageLocalDependencies(manifestSource: manifest) ?? [] {
            let abs = candorAbsolutePath((rootDir as NSString).appendingPathComponent(rel))
            if fm.fileExists(atPath: (abs as NSString).appendingPathComponent("Package.swift")) { depPaths.append(abs) }
        }
    }
    var names: Set<String> = []
    // The report files a scan SUCCEEDED at this run, and the dep paths that failed. `.candor/deps` is a
    // DISK CACHE that outlives the run, so a dep whose child scan fails leaves the PREVIOUS run's report
    // behind — and `loadDepReports` walks the whole directory, so that report is chained as though it
    // were this run's answer, with §2 rule 3 turning its silence into a purity claim. Reproduced:
    //
    //   run 1  dep pure, scans clean            -> .candor/deps/DepLib.json written
    //   dep then performs Fs AND gains a `.candor/config` naming a policy path the consumer cannot
    //   resolve, so its child scan exits 2
    //   run 2  WARM (run 1's file on disk)      -> `useDep` ABSENT from `functions` — a ⟨0.21⟩ purity
    //                                              claim about a call that writes /tmp/leak.txt
    //   run 2  COLD (same code, cache deleted)  -> `useDep` -> invisible: ['DepLib'], ledger names it
    //
    // Two arms of identical source differing only in whether a previous run's artefact was on disk: the
    // candor-rust `39bbc8b` shape (a fail-closed abort cached as a false all-clear), reached through a
    // different door. FAIL CLOSED: a report no successful scan produced THIS run is swept, so the
    // package falls back to the κ ledger's `invisible` hedge instead of standing in for an answer
    // nobody computed.
    //
    // …AND THE SWEEP MAY ONLY EVER TOUCH A FILE THIS RUN OWNS. `.candor/deps` is a directory the USER
    // also writes to: SPEC §2 makes it the ordinary place to drop a report for a BINARY dependency, a
    // hand-produced report, or another engine's report in a polyglot repo. The first version of this
    // sweep removed every `*.json` no path-dep scan had produced this run, which deletes exactly those
    // files — unrecoverably, and for a reason that has nothing to do with them. candor's whole contract
    // is that it does not destroy information; a file it did not write must never be a deletion
    // candidate, however stale the thing it is standing beside.
    //
    // OWNERSHIP IS DERIVED FROM `Package.swift`, not from a marker file. The run already knows the set
    // of local path deps it is responsible for; a report belongs to it when its name is the report name
    // of one of those deps. `ownedReportFile` answers that for a dep whose scan FAILED too (which is the
    // only case that matters, since a success rewrites the file anyway): the package name recorded by an
    // earlier round, else the dep's own `Package.swift` `name:`, else the directory basename — the same
    // three sources the writer uses, in the same order (ONE parse, shared with the writer — see
    // `manifestPackageName`). A file matching none of them is disclosed and left alone.
    //
    // …AND OWNERSHIP IS NOT ENOUGH, BECAUSE TWO PATH DEPS CAN DERIVE THE SAME REPORT NAME. The report
    // file is named after the PACKAGE, and a workspace can hold the same package twice — a vendored
    // fork beside the upstream checkout is the ordinary shape. If one of those scans and the other
    // fails, the failed dep "owns" the exact file the healthy one has just written, and the sweep
    // deleted a report this run had produced seconds earlier. Then, because a non-empty sweep triggers
    // the second fixpoint round, the retry rewrote it and THE SECOND SWEEP DELETED IT AGAIN. Measured on
    // the two-package fixture: the consumer went from `['Fs']` to `invisible: ['Shared']`, and the file
    // was gone from the cache afterwards.
    //
    // `b4f6cbc` fixed the sibling of this one door over (a file the USER put there), and the guard it
    // needed is the same guard one step stronger: NEVER DELETE A FILE THIS RUN WROTE. `confirmed` is
    // already the set of report files a successful scan produced this run — including the ones whose
    // bytes were unchanged, which is why it is `confirmed` and not `rewritten` — so the sweep subtracts
    // it. A candidate skipped for that reason is DISCLOSED, because the alternative is the run saying
    // it removed a report it did not remove, and a false disclosure is worse than a missing one.
    var confirmed: Set<String> = []
    var succeededPaths: Set<String> = []
    var reportNameOf: [String: String] = [:]    // dep path -> the package name its report is filed under
    var failures: [String: String] = [:]        // dep path -> the last reason its scan did not produce one
    func runRounds() {
        let maxRounds = 6
        for _ in 0..<maxRounds {
            var changed = false
            for dp in depPaths {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: selfPath)
                proc.arguments = [dp, "--json"]
                var env = ProcessInfo.processInfo.environment
                env["CANDOR_WORKSPACE_CHAIN"] = "1"; env["CANDOR_DEPS"] = depsDir
                proc.environment = env
                let pipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = pipe; proc.standardError = errPipe
                // NOT `proc.waitUntilExit()`. On swift-corelibs-foundation it blocks FOREVER once the
                // child has already finished — which is exactly the state the read-to-EOF below
                // guarantees by the time we want the status. Measured in docker swift:6.1 (the image the
                // linux CI leg runs), spawning /bin/cat on an 850-byte file and reading both pipes first:
                //
                //     waitUntilExit()                         HUNG 10 of 10
                //     background-drain + waitUntilExit first   HUNG 10 of 10
                //     terminationHandler + DispatchSemaphore      0 of 10
                //
                // At the hang the child is gone, both pipes gave EOF, and `isRunning` is still true: the
                // exit is never observed and the run loop `waitUntilExit` spins has nothing left to wake
                // it. The middle arm rules out read ordering — the primitive itself is broken, so the
                // pipe-buffer guard below is still required and still not sufficient. The handler is
                // delivered by the reaper directly rather than through a run loop.
                //
                // It MUST be installed before `run()`; installing it on an already-exited process races
                // with the delivery it exists to catch.
                //
                // This made `candor-swift --workspace` hang forever on Linux: measured on a one-dep
                // workspace, macOS exited 0 with a 630-byte report while Linux had to be killed at 60s
                // having written nothing. An AVAILABILITY defect, not the cardinal sin — it hangs rather
                // than reporting a false all-clear, so no silent under-report was ever emitted.
                let exited = DispatchSemaphore(value: 0)
                proc.terminationHandler = { _ in exited.signal() }
                guard (try? proc.run()) != nil else { failures[dp] = "could not be spawned"; continue }
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                let errOut = errPipe.fileHandleForReading.readDataToEndOfFile()
                exited.wait()
                guard proc.terminationStatus == 0 else {
                    // the child's own last stderr line is the diagnosis (a bad `.candor/config`, an
                    // unreadable tree); relaying it is what turns "silently skipped" into actionable.
                    let tail = String(decoding: errOut, as: UTF8.self)
                        .split(separator: "\n").last.map(String.init) ?? ""
                    failures[dp] = "exited \(proc.terminationStatus)\(tail.isEmpty ? "" : " — " + tail)"
                    continue
                }
                guard !out.isEmpty else { failures[dp] = "produced no report"; continue }
                let name = ((try? JSONSerialization.jsonObject(with: out)) as? [String: Any])?["package"] as? String ?? (dp as NSString).lastPathComponent
                names.insert(name)
                succeededPaths.insert(dp)
                failures.removeValue(forKey: dp)   // it failed on an earlier ROUND and has since converged
                reportNameOf[dp] = name
                let file = reportFile(forPackage: name)
                confirmed.insert(file)             // …including when the bytes are unchanged: confirmed ≠ rewritten
                let prev = try? Data(contentsOf: URL(fileURLWithPath: file))
                if prev != out { try? out.write(to: URL(fileURLWithPath: file)); changed = true }
            }
            if !changed { break }
        }
    }
    /// The cache path a package's report is written to. THE writer's transform, called by the writer —
    /// so `ownedReportFile` below cannot drift from it on the second half of the derivation either.
    func reportFile(forPackage name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "@", with: "_")
        return (depsDir as NSString).appendingPathComponent(safe + ".json")
    }
    /// The report file `--workspace` OWNS for a local path dependency — the one IT writes when that
    /// dep scans. Three sources in the writer's own order, so the name a failed dep would have been
    /// filed under is the name it WAS filed under.
    ///
    /// AND "THE SAME" IS NOW SHARED CODE RATHER THAN A CLAIM. Both halves of the derivation are the
    /// writer's own: `manifestPackageName` is the function the writer names its report with (this
    /// copy was anchored after `Package(` while the writer's is not — see that function for the two
    /// directions that cost), and `reportFile` is the transform the writer files it under. A comment
    /// asserting two parses agree is an assertion; one parse is a fact.
    ///
    /// `recorded` is PASSED, not captured. A nested func closing over a top-level `var` that a sibling
    /// closure also writes is a Swift-6 `sending` diagnostic under whole-module optimization, and it
    /// surfaces ONLY in the release build — `swift build` and the whole suite are green over the
    /// capturing form (standing bar item 7c: check the artifact, not the command's exit).
    func ownedReportFile(_ dp: String, _ recorded: [String: String]) -> String {
        let name = recorded[dp] ?? manifestPackageName(atDir: dp) ?? (dp as NSString).lastPathComponent
        return reportFile(forPackage: name)
    }
    /// Remove the cached report of every local path dep whose scan did NOT succeed this run. Returns
    /// the file names actually removed, and the ones a HEALTHY sibling had already written this run.
    ///
    /// SCOPED TO WHAT THIS RUN OWNS. The candidates are the discovered path deps, never the directory
    /// listing: a report the USER put here for a binary dependency, produced by hand, or written by
    /// another engine is not this run's to delete, and deleting it is unrecoverable. The cost of the
    /// narrower rule is that a report for a package that USED to be a path dep and no longer is will
    /// linger — information kept rather than destroyed, and disclosed by `unownedReports` below.
    ///
    /// …AND NEVER A FILE THIS RUN WROTE. Ownership is by NAME, and two path deps can derive the same
    /// name (the same package vendored twice), so a failed dep's "owned" file can be the report a
    /// healthy sibling produced moments ago. `wroteThisRun` is `confirmed` — the files a successful
    /// scan produced this round, unchanged bytes included — and it is PASSED rather than captured for
    /// the reason `recorded` is (see `ownedReportFile`).
    func sweepStale(_ recorded: [String: String], _ wroteThisRun: Set<String>) -> (removed: [String], keptForSibling: [String]) {
        var removed: [String] = [], kept: [String] = []
        for dp in depPaths.sorted() where !succeededPaths.contains(dp) {
            let full = ownedReportFile(dp, recorded)
            guard fm.fileExists(atPath: full) else { continue }
            guard !wroteThisRun.contains(full) else {
                kept.append((full as NSString).lastPathComponent)   // a sibling's fresh answer, not a stale one
                continue
            }
            try? fm.removeItem(atPath: full)
            removed.append((full as NSString).lastPathComponent)
        }
        return (removed, kept)
    }
    /// Reports in the cache that this run neither produced nor owns — chained by `loadDepReports` all
    /// the same. Named on stderr rather than removed: §2.1's staleness check is what decides whether to
    /// TRUST one, and that is a decision about the report, not about who wrote it.
    func unownedReports(_ recorded: [String: String]) -> [String] {
        let owned = Set(depPaths.map { ownedReportFile($0, recorded) })
        return ((try? fm.contentsOfDirectory(atPath: depsDir)) ?? []).sorted()
            .filter { $0.hasSuffix(".json") }
            .filter { !owned.contains((depsDir as NSString).appendingPathComponent($0)) }
    }
    runRounds()
    var sweep = sweepStale(reportNameOf, confirmed)
    var swept = sweep.removed, keptForSibling = sweep.keptForSibling
    if !swept.isEmpty {
        // The children were spawned with CANDOR_DEPS pointing at this same directory, so a sibling that
        // DID scan cleanly may have chained the stale report we have just removed — and its report feeds
        // the parent, so sweeping afterwards alone would leave the contamination one hop away. Re-run the
        // fixpoint once with the cache clean. One extra cycle is enough: a file only ever appears from a
        // success, so a second sweep can find nothing the first did not.
        confirmed.removeAll()
        runRounds()
        sweep = sweepStale(reportNameOf, confirmed)
        swept += sweep.removed; keptForSibling += sweep.keptForSibling
    }
    workspaceDepsDir = depsDir
    let failed = depPaths.filter { !succeededPaths.contains($0) }
    if !failed.isEmpty {
        // LOUD, and it names what it cost. Previously the child's stderr went to /dev/null and the skip
        // was silent, so the one thing a reader could see — the count line below — said "no local path
        // deps found" while a path dep sat there unscanned.
        //
        // AND IT MUST NOT CLAIM A REMOVAL THAT DID NOT HAPPEN. When the failed dep's report name is the
        // one a healthy sibling just wrote, nothing was removed and the cache holds the SIBLING's answer
        // under that name — a materially different situation, and telling the reader the package fell
        // back to the κ ledger when it did not is the false-disclosure failure this project treats as
        // worse than silence.
        let keptNames = Set(keptForSibling)
        for dp in failed.sorted() {
            let file = (ownedReportFile(dp, reportNameOf) as NSString).lastPathComponent
            let fate = keptNames.contains(file)
                ? "its report name (\(file)) is one ANOTHER local path dep produced this run, so nothing "
                  + "was removed and that file is the OTHER package's answer — two path deps deriving one "
                  + "report name is a workspace this cache cannot represent"
                : "any report this cache held for it has been removed so the package falls back to the κ ledger"
            FileHandle.standardError.write(
                ("candor-swift: --workspace could NOT scan the local path dependency \(dp) "
                 + "(\(failures[dp] ?? "no report")) — its effects are UNSEEN, not pure; \(fate)\n").data(using: .utf8)!)
        }
    }
    if !swept.isEmpty {
        let uniq = Set(swept).sorted()
        FileHandle.standardError.write(
            ("candor-swift: --workspace removed \(uniq.count) stale report(s) from \(depsDir) — this run "
             + "owns them (they are the reports it writes for local path deps) and no scan produced them "
             + "this run: \(uniq.joined(separator: ", "))\n").data(using: .utf8)!)
    }
    let unowned = unownedReports(reportNameOf)
    if !unowned.isEmpty {
        // A report `--workspace` did not write. It is still CHAINED (§2.1 decides whether to trust it),
        // and it is NOT swept — a binary dep's report, a hand-produced one, or another engine's report in
        // a polyglot repo is the user's file and this run has nothing to say about its freshness.
        FileHandle.standardError.write(
            ("candor-swift: --workspace found \(unowned.count) report(s) in \(depsDir) it does not produce "
             + "(no local path dep is filed under that name) — chained, and LEFT IN PLACE; their freshness "
             + "is §2.1's call, not the sweep's: \(unowned.joined(separator: ", "))\n").data(using: .utf8)!)
    }
    let tail = names.isEmpty
        ? (depPaths.isEmpty ? " (no local path deps found)" : " (every local path dep failed to scan — see above)")
        : ": " + names.sorted().joined(separator: ", ")
    FileHandle.standardError.write("candor-swift: --workspace chained \(names.count) workspace dep report(s), transitive\(tail)\n".data(using: .utf8)!)
}
// Report chaining (SPEC §2, Deps.swift): CANDOR_DEPS overrides the config's `deps` key (the same
// env-over-config precedence as `policy`). Fail-closed loading — a bad token/report exits 2 HERE,
// before any analysis could silently read the dep as pure. --workspace's auto-scanned dir prepends.
let envOrConfigDeps = ProcessInfo.processInfo.environment["CANDOR_DEPS"] ?? candorConfig["deps"]
let depsSpec = [workspaceDepsDir, envOrConfigDeps].compactMap { $0 }.joined(separator: ":").isEmpty
    ? nil : [workspaceDepsDir, envOrConfigDeps].compactMap { $0 }.joined(separator: ":")
let depsIndex = loadDepReports(spec: depsSpec, engineVersion: engineVersion)

let analysis = analyze(sourcePaths: sourcePaths, rootDir: rootDir, pkgName: pkgName, deps: depsIndex,
                       xcodeLinksByFile: resolvedXcodeLinksByFile,
                       xcodeModulesByFile: resolvedXcodeModulesByFile)
let allFns = analysis.allFns
let conformers = analysis.conformers
let declaredTypes = analysis.declaredTypes
let protocolSupers = analysis.protocolSupers
let protocolNames = analysis.protocolNames
let importCounts = analysis.importCounts
let direct = analysis.direct
let edges = analysis.edges
let whyMap = analysis.whyMap
let locOf = analysis.locOf
let entryPoints = analysis.entryPoints
let inferred = analysis.inferred
let hostsAcc = analysis.hostsAcc, cmdsAcc = analysis.cmdsAcc
let pathsAcc = analysis.pathsAcc, tablesAcc = analysis.tablesAcc
let incompleteAcc = analysis.incompleteAcc
let invisibleAcc = analysis.invisibleAcc
// ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): the target source candor could NOT read/parse — rides the report
// (`unanalyzed`) + drives the fail-closed gate verdict + exit 2 below.
let unanalyzedUnits = analysis.unanalyzed
// ⟨0.20⟩ Net destination-class partners from `.candor/config` — read ONCE here, used by the report's per-fn
// `netClass` field (below) and the gate (deny Net[unknown-host]); the SAME set both surfaces resolve.
// ⟨0.27⟩ §3.4 — the engine pin, checked before the report is written: a wrong engine costs a
// message rather than an analysis followed by a refusal.
enforceEnginePin(targetPath: target, running: releaseVersion)

let netPartners = parseNetPartners(discoverConfigText(targetPath: target))
// ⟨0.31⟩ the declared partners that actually MOVED a classification in this run — see the envelope key.
var netPartnersUsed: Set<String> = []

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Report (§2 envelope, spec 0.5) + sidecar (§2.2) + receipt + κ ledger (§7.14)
// ════════════════════════════════════════════════════════════════════════════════════════════════

let prefix = outPrefix ?? (rootDir as NSString).appendingPathComponent(".candor/report")

let accessorQuals = Set(allFns.filter { $0.isAccessor }.map { $0.qual })
// the synthetic `<main>` top-level-statement unit(s): unitKind "initializer" (the top level runs once,
// like a static/class initializer — the JVM engine's `<clinit>` uses the same kind).
let topLevelQuals = Set(allFns.filter { $0.isTopLevel }.map { $0.qual })
// (the domain model — Effect/EffectSet/Provenance/Effector/Report — and the atomic writeJson
//  live in ReportModel.swift)

var effectors: [Effector] = []
// A pure fn that reaches a blind module is NOT in `inferred` (no effect seeds it), but it must still
// appear — carrying `invisible` — so `inferred: []` is never an unqualified pure claim. Union the keys.
let reportQuals = Set(inferred.keys).union(invisibleAcc.keys)
for qual in reportQuals.sorted() {
    let inf = inferred[qual] ?? []
    let invisible = (invisibleAcc[qual] ?? []).sorted()
    if inf.isEmpty && invisible.isEmpty { continue }
    // `unresolved` IS DERIVED FROM THE EFFECT SET, HERE, and that is the whole of this engine's answer to
    // candor-ts `e66f29e` (an entry inherited `Unknown` while its `unresolved` marker stayed absent, so a
    // TIER-1 consumer read `false` on an entry that genuinely carries Unknown). A marker maintained in
    // parallel with the thing it describes can drift from it; one computed from that thing cannot. Both
    // Effector construction sites in this file derive it — this one and the protocol-union one below — so
    // there is no path that can set the effect and forget the marker. A side set that recorded the same
    // fact independently DID exist here (`unresolvedSet` in Driver, written at seven Unknown sources and
    // read at none); it was removed rather than wired up, because its only possible future is to disagree
    // with this line. Measured over 14 real targets / 12 004 entries: 10 539 carry Unknown, 0 fail the
    // marker, and 0 carry a DIRECT Unknown without an `unknownWhy` (spec §4's other required disclosure).
    var ef = Effector(
        fn: qual, loc: locOf[qual] ?? "",
        inferred: EffectSet(names: inf), direct: EffectSet(names: direct[qual] ?? []),
        unresolved: inf.contains("Unknown"), hash: "\(pkgName)#\(qual)",
        calls: (edges[qual] ?? []).sorted())
    if entryPoints.contains(qual) { ef.entryPoint = true }
    if topLevelQuals.contains(qual) { ef.unitKind = "initializer" }
    else if accessorQuals.contains(qual) { ef.unitKind = "accessor" }
    if let w = whyMap[qual], !w.isEmpty { ef.unknownWhy = w.sorted() }
    if let h = hostsAcc[qual], !h.isEmpty { ef.hosts = h.sorted() }
    if let c = cmdsAcc[qual], !c.isEmpty { ef.cmds = c.sorted() }
    if let p = pathsAcc[qual], !p.isEmpty { ef.paths = p.sorted() }
    // TRANSITIVE, and it used to be DIRECT. The old comment here read "DIRECT, deliberately … the signal a
    // consumer needs to tell 'this function's own destination was undetermined' from 'something it calls
    // named a literal'." That distinction is real, but it is `incompleteDirect`'s job — which still exists,
    // still carries it, and is still what the privacy verify reads (see Analysis.incompleteDirect). It was
    // the wrong view for THIS field, the one a consumer branches on to decide whether to trust an effect
    // surface at all.
    //
    // MEASURED on Alamofire 5.9.1 (2026-08-13 corpus round), by `conformance/check_honesty.py` run
    // unmodified over the corpus: `WebSocketRequest.socket` calls `WebSocketRequest.task`, which carries
    // `incomplete`, and `socket` carried nothing — so it read CERTAIN off an uncertain callee. That breaks
    // the invariant the suite already gates on: for every call edge f -> g, uncertain(g) => uncertain(f).
    //
    // rust is the control, and it is not a vacuous one — the corpus gave it 34 callers OF an incomplete
    // function and it propagated 34/34, where swift propagated 0/8. Same key, same spec, opposite answers.
    //
    // SPEC §2 states the rule over the chained-dependency join: it "applies EVERY surface … (`hosts`/
    // `cmds`/`paths`/`tables`/`invisible`/`incomplete`), not just the effects — a join that carries the
    // effect and drops `incomplete` lets a benign literal in the consumer certify what the dependency
    // declared uncertifiable." The harm it names is not a property of the PACKAGE edge; `socket`
    // certifying what `task` declared uncertifiable is the same sentence one boundary in. The clause is
    // written over the instance rather than the condition, which is a SPEC repair filed separately.
    if let i = incompleteAcc[qual], !i.isEmpty { ef.incomplete = i.sorted() }
    if let t = tablesAcc[qual], !t.isEmpty, inf.contains("Db") { ef.tables = t.sorted() }
    // SPEC §2 `fs` — gated on `inferred` carrying Fs (the spec: "applies only when `inferred` contains
    // `Fs`"), and omitted when empty. Direct-only, so a function that merely REACHES a writer carries none.
    // Present "?" ⇒ some contributing Fs had no determined kind ⇒ suppress the WHOLE field, because
    // ["write"] there would claim "writes but never reads" about a function that may do both (§2).
    if let k = analysis.fsD[qual], !k.isEmpty, !k.contains("?"), inf.contains("Fs") { ef.fs = k.sorted() }
    // `privacy/2` direction — only for effects this fn actually carries, and only where a verb said.
    if let pk = analysis.privKindD[qual] {
        let kept = pk.filter { !$0.value.isEmpty && inf.contains($0.key) }
        if !kept.isEmpty { ef.privacy = kept.mapValues { $0.sorted() } }
    }
    if !invisible.isEmpty { ef.invisible = invisible }
    // ⟨0.20⟩ Net destination-class: the classes in this fn's transitive Net surface — exact host-literal
    // match, fail-closed unknown-host on a masked surface (incompleteAcc has Net) OR a Net with no visible host.
    if inf.contains("Net") {
        // ⟨0.31⟩ record WHICH declared partner participated, at the point the class is decided.
        // `partnerFor` is the function `netDestClass` itself asks, so the disclosure and the decision
        // cannot use different rules — the reverted first attempt re-matched and came back silently empty.
        for h in hostsAcc[qual] ?? [] {
            if let pm = partnerFor(h, netPartners) { netPartnersUsed.insert(pm) }
        }
        ef.netClass = netClassesOf(Array(hostsAcc[qual] ?? []),
                                   netIncomplete: incompleteAcc[qual]?.contains("Net") ?? false,
                                   partners: netPartners)
    }
    effectors.append(ef)
}
// ⟨workspace-chain, opt-in via CANDOR_WORKSPACE_CHAIN⟩ PROTOCOL-CHA union entries — the candor-ts
// `interfaceUnion` analog. A CONSUMER of this package that calls a protocol method on a `P`-typed value
// imported from here resolves the call to the protocol REQUIREMENT (no body → no entry → the chain reads
// it pure). Emit a synthetic `pkg#P.method` entry = the UNION over every local conformer of that method's
// effects (inferred + invisible), reusing the `conformers` CHA universe in-package dispatch already uses.
// Sound over-approximation; a `P.m` a consumer never resolves (not a real requirement) is harmless data.
// GATED so a default scan stays byte-identical (four-way conformance unaffected until the rung is pinned).
// For swift this is a PRECISION upgrade — an unresolved cross-package protocol call already discloses
// `Unknown` (never silent-pure, Driver.swift), so the union only sharpens `Unknown` → the precise effect.
if ProcessInfo.processInfo.environment["CANDOR_WORKSPACE_CHAIN"] != nil {
    // index: bare owner-type -> the (method, qual) pairs it owns (built once from the report quals);
    // ownersByTail tracks the DISTINCT full owner paths per bare tail, for the ambiguity guard below.
    var ownerMethods: [String: [(method: String, qual: String)]] = [:]
    var ownersByTail: [String: Set<String>] = [:]
    for qual in reportQuals {
        guard let dot = qual.lastIndex(of: ".") else { continue }
        let owner = String(qual[qual.startIndex..<dot])
        let method = String(qual[qual.index(after: dot)...])
        let tail = owner.lastIndex(of: ".").map { String(owner[owner.index(after: $0)...]) } ?? owner
        ownerMethods[tail, default: []].append((method, qual))
        ownersByTail[tail, default: []].insert(owner)
    }
    let emitted = Set(effectors.map { $0.hash })
    // COLLECTED, THEN SORTED BY HASH — never appended straight into `effectors`. `conformers` is a
    // `[String: [String]]` and `byMethod` a `[String: …]`, and Swift seeds Dictionary hashing PER
    // PROCESS, so appending inside those two loops made the emission ORDER of the union entries differ
    // between runs of the same binary on the same input. Measured before the fix: five runs of the
    // release binary over Alamofire under `CANDOR_WORKSPACE_CHAIN=1` gave FIVE different report hashes,
    // with the same 879 union entries in five different orders.
    //
    // This is `23eafc2` surviving in the code path added after it. That commit's argument applies
    // unchanged and is the reason this outranks its blast radius: A/B on real code is this project's
    // primary evidence, and a report that differs from ITSELF injects noise into every diff — it cost an
    // agent a false datapoint before anyone thought to run a report against itself. It also makes
    // `gains`, the supply-chain effect-diff, noisy between identical inputs, which is product-facing.
    // The path it survived in is the CROSS-PACKAGE PUBLISHING path: these are exactly the bytes a
    // chained consumer reads.
    //
    // Sorting the RESULT rather than the two loops is deliberate: it makes the loops' order irrelevant
    // (including `reportQuals`, a Set, feeding `ownerMethods`' arrays) instead of relying on three
    // iteration orders staying sorted, and it is directly assertable in one process — two scans inside
    // one test process share a hash seed, so a double-scan test could pass while the defect was live.
    // The hash is a total order here: it is `pkg#proto.method` and (proto, method) is a key pair.
    var unionEntries: [Effector] = []
    for (proto, conformerTypes) in conformers {
        var byMethod: [String: (inf: Set<String>, inv: Set<String>)] = [:]
        for t in Set(conformerTypes) {
            // AMBIGUOUS bare type name: two DISTINCT types share tail `t` (e.g. `A.Foo` and `B.Foo`), so
            // `ownerMethods[t]` merges both — the union would pull an unrelated same-named type's method (a
            // fabrication). `conformers` holds only the bare name, so we cannot tell which `Foo` conforms;
            // the family's never-guess rule (Driver.swift) says SKIP it rather than guess.
            if (ownersByTail[t]?.count ?? 0) > 1 { continue }
            for (method, qual) in ownerMethods[t] ?? [] {
                var cur = byMethod[method] ?? (inf: [], inv: [])
                cur.inf.formUnion(inferred[qual] ?? [])
                cur.inv.formUnion(invisibleAcc[qual] ?? [])
                byMethod[method] = cur
            }
        }
        for (method, eff) in byMethod {
            if eff.inf.isEmpty && eff.inv.isEmpty { continue }   // pure across all conformers — silence = purity
            let hash = "\(pkgName)#\(proto).\(method)"
            if emitted.contains(hash) { continue }               // a real entry already claims this hash
            var ef = Effector(fn: "\(proto).\(method)", loc: "",
                inferred: EffectSet(names: eff.inf), direct: EffectSet(names: [String]()),
                unresolved: eff.inf.contains("Unknown"), hash: hash, calls: [String]())
            if !eff.inv.isEmpty { ef.invisible = eff.inv.sorted() }
            ef.interfaceUnion = true
            unionEntries.append(ef)
        }
    }
    unionEntries.sort { $0.hash < $1.hash }
    effectors.append(contentsOf: unionEntries)
    if !unionEntries.isEmpty {
        FileHandle.standardError.write("candor-swift: emitted \(unionEntries.count) protocol-CHA union entries (workspace chain)\n".data(using: .utf8)!)
    }
}
// the coverage ledger: imported modules outside the platform frontier that the classifier doesn't
// cover — INVISIBLE, not Unknown; named per scan (SPEC §7 item 14, canonical marker `classifier
// doesn't cover`). A package a chained
// sibling report covers is EXEMPT (SPEC §2 rule 3) — including an all-pure dep's EMPTY report,
// whose silence is its purity claim, so the ledger must not name it a blind spot. `coveredPkgs` and not
// `isChained`: a report §2.1 refused to trust makes no claim over its package, so the ledger keeps naming
// it — the same asymmetry the per-fn `invisible` set uses (Driver.swift, Deps.swift rule 3).
// Computed HERE (before the envelope is built) because ⟨0.15 staged⟩ the same list rides the report
// as the `coverage` envelope field — one computation feeds the stderr line (printed below, after the
// receipt, keeping the disclosure order) AND the wire field, so they can never disagree.
// ⟨0.27⟩ COMPUTED IN THE DRIVER, where the per-FILE answer lives. This used to filter a scan-global
// `importCounts` by a scan-global `internalModules` — a set that could not express "internal for THIS
// file", which is the question both disclosure channels actually ask. See `analyze`.
let unlisted = analysis.uncoveredCounts
    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }

// ⟨0.27⟩ CHAINED COVERAGE NOBODY DECLARED. SPEC §2 rule 3 makes coverage name-keyed and scan-global,
// and this engine obeys it — a package a loaded report covers is accounted for, full stop. That rule is
// also the one place a NAME alone can delete a disclosure, and when the name is wrong the failure is
// silent: an unresolved call into a same-named module the report is not actually about reads pure.
//
// Disclosed, not changed. Gating the claim on this would be a spec rung across four engines, and it
// would cost real reach — a module re-exported through a dependency is legitimately imported by code
// whose own manifest never names it. A note costs nothing and turns a silent trap into a visible one.
if !analysis.coverageNotDeclared.isEmpty {
    let rows = analysis.coverageNotDeclared.sorted { $0.key < $1.key }
    var msg = "candor-swift: note — \(rows.count) chained report(s) cover a package that the importing "
        + "code's own target never names as a dependency, so their silence is being read as a purity "
        + "claim on the strength of a NAME:\n"
    for (mod, files) in rows.prefix(8) {
        let example = files.sorted().first ?? "?"
        msg += "  \(mod) — imported by \(files.count) file(s), e.g. \(example)\n"
    }
    if rows.count > 8 { msg += "  … and \(rows.count - 8) more\n" }
    msg += "  If that is the package you meant, nothing is wrong. If your code imports a DIFFERENT "
        + "module of that name, its effects are being taken from the wrong report.\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
}

var report = Report(
    provenance: Provenance(version: engineVersion, toolchain: "swiftsyntax", spec: specVersion),
    package: pkgName, effectors: effectors)
report.coverage = unlisted.map { (name: $0.key, calls: $0.value) }   // ⟨0.15 staged⟩ SPEC §2 `coverage`
// ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 1): the analyzed universe = every analyzed fn incl. pure leaves =
// `allFns` (NOT the effectful-only `effectors`). count lets a bare-envelope consumer compute the pure
// count; digest = FNV-1a-64 over the SORTED analyzed quals (same-input re-scan agreement).
let analyzedQuals = allFns.map { $0.qual }.sorted()
report.analyzed = (count: allFns.count, digest: fnv1aHex(analyzedQuals))
// ⟨0.31⟩ the ambient `net-partner` provenance, from the SAME discovery walk the partners were read
// through — so the disclosure cannot name a different file from the one that supplied the vocabulary.
// Omitted when nothing participated: a declaration that changed nothing is not provenance.
if !netPartnersUsed.isEmpty, let cfg = discoverConfig(targetPath: target)?.path {
    report.netPartners = (config: cfg, hosts: netPartnersUsed.sorted())
}
report.unanalyzed = unanalyzedUnits   // ⟨0.21⟩ (Gap 2) omitted when empty by toJSON()
report.scope = resolvedXcodeScope     // ⟨scope travels⟩ omitted when nil by toJSON()
// ⟨0.23⟩ `typeSurface.returns` — PREFIXED here with this report's package, so both ends land in the same
// namespace the entry hashes use and a consumer forms `<pkg>#<type>.<method>` with no extra convention.
if !analysis.typeSurfaceReturns.isEmpty {
    var ts: [String: String] = [:]
    for (fn, ty) in analysis.typeSurfaceReturns { ts["\(pkgName)#\(fn)"] = "\(pkgName)#\(ty)" }
    report.typeSurfaceReturns = ts
}
// ── ⟨0.29⟩ THE SCOPE, AND THE PEEK ────────────────────────────────────────────────────────────────
// The reason strings say WHY and what the exclusion COSTS, because a consumer reads them to decide
// whether the exclusion matches the question they are asking. Paraphrasing the engine's own rationale
// into something vaguer would defeat the block — conformance asserts on this VALUE, not on the key.
let EXCLUDED_REASON: [String: String] = [
    "manifest": "Package.swift is BUILD CONFIGURATION — SwiftPM compiles and runs it to describe the "
        + "package, so it does not run when your library is called and this scan did not judge it. It "
        + "DOES run on every `swift build` (the `build.rs` analog).",
    "harness-target": "SPM's Tests/Plugins/Benchmarks/Examples/Snippets directories describe what the "
        + "HARNESS does, not what the package does — but they still run in CI.",
    "test-source": "a file importing XCTest or Testing is test code wherever it sits, so its effects are "
        + "the harness's rather than the package's.",
    "outside-the-target-closure": "`--target` was given, so this verdict covers that target's closure "
        + "ONLY — these are production sources in the scanned tree that an unscoped scan WOULD have judged.",
    "build-output": "`.build/` holds the toolchain's artifacts and checked-out dependency sources, not "
        + "this package's own code. Counted, and deliberately NOT read by the peek: a checkout tree is "
        + "unbounded, and other people's tests are not a finding about your project.",
]
// WHICH CLASSES THE PEEK READS — declared once, read by both the disclosure and the peek's own filter.
// `.build/` is the one this engine holds back: a checkout tree is unbounded, and other people's tests are
// not a finding about your project. The report says so per class rather than leaving `outOfScope: []` to
// be read as "and I checked those too".
/// ⟨0.29⟩ thrown when the peek child misses its deadline — caught by the peek's own catch,
/// which leaves the findings as far as they got and the classes marked unpeeked.
struct PeekTimedOut: Error {}
let PEEKED_CLASSES: Set<String> = ["manifest", "harness-target", "test-source", "outside-the-target-closure"]
// THE PEEK. Read the files this scan deliberately did NOT judge, and say so when they hold an effect the
// policy DENIES. ⟨0.30⟩ THE VERDICT DOES MOVE (a non-empty block is `ok:false, incomplete:true`, exit 2);
// `outOfScope` is still its own kind, never a violation, because a
// file the gate declined to judge must not decide an exit code.
//
// A CHILD `candor-swift`, not a second analysis path. candor-rust buys the same guarantee by recursing
// into `scan_one`; this engine's scan is TOP-LEVEL CODE rather than a callable function, so "same
// classifier, different file set" has to come from the same BINARY. That identity is the design
// constraint and not an implementation convenience: a bespoke pass over Tests/ would be a SECOND OPINION,
// and a drifted second opinion reported as a warning is worse than no warning, because the reader cannot
// tell a real finding from two code paths disagreeing.
//
// PLACED ABOVE the envelope serialization on purpose. The gate runs after the report is written, so
// computing this there would put the finding on stderr and leave it out of the artifact — the split
// ⟨0.26⟩ calls worse than saying nothing.
//
// POLICY-SCOPED AND POLICY-BOUNDED, which is the whole reason it stays quiet. No policy ⇒ the key is
// ABSENT, because nothing was asked and `[]` would be a claim. With a policy, only effects that policy
// DENIES are reported — otherwise the noise floor is "everything you excluded".
// ⟨0.29⟩ see `peekRead` at the assignment below: `excluded[].peeked` is an OUTCOME, so the scope block
// cannot be built until the peek has run — it is assembled after this block, not before it.
var peekRead = false
// ⟨0.29⟩ the classes the peek RAN over and could not read — see the `unanalyzed` loop below. Parse
// failures are per file, so the completeness claim is withdrawn per class rather than wholesale.
var peekUnread: Set<String> = []
var peekUnattributed = false
if peekListPath == nil, let pp = policyPath {
    // ⟨0.29⟩ A REFUSED POLICY LEAVES THE KEY ABSENT (SPEC §2). The peek is a producer reading the policy,
    // so §3.1 binds it exactly as it binds the gate: over a policy no route will honour, `outOfScope: []`
    // claims a look taken against rules that never stood — and the `denied` set it would look for is the
    // parser's SALVAGE of an unhonourable file, which is the rewriting `gateRefusals` exists to refuse.
    // candor-java already withheld here; this engine, candor-rust and candor-ts did not.
    let parsedForPeek = (try? String(contentsOfFile: pp, encoding: .utf8))
        .map { parsePolicy($0, aliases: [:]) }
    // ⟨0.30⟩ THE RULES, not a flat set of effect NAMES. §6.2 already requires the gate and the disclosure
    // to apply the SAME rule, and the name set was wrong in BOTH directions once ⟨0.30⟩ made this block
    // verdict-bearing — both MEASURED four-way in review:
    //
    //   UNDER-REPORT: `pure` is a deny rule with an EMPTY effect list meaning "every effect except
    //   Unknown" (see Gate.swift's AS-EFF-006 loop). Flattened it contributed NOTHING, so the set was
    //   empty, the peek never ran, and the STRICTEST policy passed at exit 0 while the weaker
    //   `deny Exec` exited 2 on the identical tree. A four-way false all-clear.
    //
    //   OVER-CHARGE: `deny Net[known-partner]` denies one destination class; the name set held bare
    //   `Net`, so a peeked fn reaching an unknown host — which that rule does not deny — turned the
    //   verdict red while the same code in scope passed. Rule SCOPES were dropped identically.
    let peekRules = (parsedForPeek?.gateRefusals.isEmpty ?? false) ? (parsedForPeek?.deny ?? []) : []
    // `.build/` is held out of the peek, not just out of the scan — see `PEEKED_CLASSES`, which the
    // `excluded` block above reads too, so the disclosure and this filter cannot disagree.
    let peekable = excludedFiles.filter { PEEKED_CLASSES.contains($0.cls) }
    if !peekRules.isEmpty && !peekable.isEmpty {
        // A policy WAS configured, so the key is now a real answer: `[]` says "we looked and found
        // nothing", which is what ⟨0.27⟩ asks a zero-match to say out loud.
        var found: [OutOfScopeFinding] = []
        let peekDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-peek-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: peekDir) }
        try? fm.createDirectory(at: peekDir, withIntermediateDirectories: true)
        let listURL = peekDir.appendingPathComponent("files.txt")
        let absOf: (String) -> String = { (rootDir as NSString).appendingPathComponent($0) }
        do {
            try peekable.map { absOf($0.path) }.joined(separator: "\n")
                .write(to: listURL, atomically: true, encoding: .utf8)
            let child = Process()
            // `Bundle.main.executablePath` FIRST, argv[0] only as the fallback. argv[0] is what the
            // `--workspace` spawn beside this uses, and it is a relative name (`candor-swift`, no slash)
            // for every PATH-invoked run — which is how the tool is actually installed. That spawn fails
            // loudly per dep; a peek failing there would go quiet, so it takes the absolute answer where
            // one exists.
            child.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            child.arguments = [target, "--peek-excluded", listURL.path, "--json"]
            let pipe = Pipe()
            child.standardOutput = pipe
            // The child's own stderr is DISCARDED. It is a second scan of the same tree and its
            // κ/coverage notes are about a file set the operator never asked about — printing them
            // twice, once per set, is how an advisory becomes noise.
            child.standardError = FileHandle.nullDevice
            child.standardInput = FileHandle.nullDevice
            // NOT `waitUntilExit()` — on swift-corelibs-foundation it blocks FOREVER once the child has
            // already finished, which is exactly the state draining to EOF guarantees. See the
            // `--workspace` spawn above for the 10-of-10 measurement; this is the same primitive and the
            // same fix, and using the broken one here would hang every Linux scan that has a policy.
            let exited = DispatchSemaphore(value: 0)
            child.terminationHandler = { _ in exited.signal() }
            try child.run()
            // Drain BEFORE waiting: a report larger than the pipe buffer blocks the child on write while
            // the parent blocks on exit, and the two wait for each other forever.
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()
            // ⟨0.29⟩ A DEADLINE, because the peek re-parses exactly the files this engine has never
            // parsed — vendored trees, generated code, a manifest nobody analyses — i.e. the inputs least
            // likely to have been exercised. An unbounded wait turns a parser that hangs on one of them
            // into a hung SCAN and a hung CI job, which contradicts this feature's own stated rule that a
            // peek that cannot run must not fail the gate: hanging is the one failure that stops the gate
            // completing at all. On timeout the child is killed and the peek reports nothing, which the
            // `peeked: false` below then states plainly.
            if exited.wait(timeout: .now() + 120) == .timedOut {
                child.terminate()
                FileHandle.standardError.write(("candor-swift: the peek did not finish within 120s and was "
                    + "stopped — `excluded` marks its classes NOT peeked, so nothing here claims they were "
                    + "read. The gate below is unaffected.\n").data(using: .utf8)!)
                throw PeekTimedOut()
            }
            let doc = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:]
            // ⟨0.29⟩ THE PEEK READ SOMETHING. `peeked` was a constant of the exclusion CLASS, so a child
            // that crashed, could not be spawned, or returned nothing still published `peeked: true`
            // beside `outOfScope: []` — byte-identical to a clean peek, and the ⟨0.26⟩ partial-manifest
            // failure inside the rung built to prevent it. Set only where a report actually parsed.
            peekRead = !doc.isEmpty
            // ⟨0.29⟩ …AND DID IT READ THEM ALL? A child report the parent could PARSE is a different fact
            // from every peeked file having been opened. The child publishes its own ⟨0.21⟩ `unanalyzed`
            // manifest and this code read only `functions`, so a peeked file that FAILED TO PARSE inside
            // the child produced `peeked: true` beside `outOfScope: []` — the same overclaim one comment
            // up, one level down. `peeked` is per CLASS, so the answer is too: a class is peeked only when
            // no file of that class went unread. The join goes through `candorAbsolutePath` for the same
            // reason the `functions` loop below does — a raw string compare misses every time.
            for u in (doc["unanalyzed"] as? [[String: Any]] ?? []) {
                let unreadPath = u["path"] as? String ?? ""
                if unreadPath.isEmpty { peekUnattributed = true; continue }
                let abs = candorAbsolutePath(unreadPath.hasPrefix("/") ? unreadPath
                                             : (rootDir as NSString).appendingPathComponent(unreadPath))
                // The child walks ONLY the list it was handed, so an unread path matching nothing on that
                // list is one this code cannot attribute — fail closed across every class rather than let
                // one unattributable file leave all of them claiming completeness.
                if let hit = peekable.first(where: { candorAbsolutePath(absOf($0.path)) == abs }) {
                    peekUnread.insert(hit.cls)
                } else {
                    peekUnattributed = true
                }
            }
            for f in (doc["functions"] as? [[String: Any]] ?? []) {
                // ⟨0.30⟩ the gate's own firing decision, per (rule, function): scope test, then `pure`
                // means every effect except Unknown and a named rule means the intersection.
                let inf = f["inferred"] as? [String] ?? []
                let qual = f["fn"] as? String ?? ""
                // ⟨0.30⟩ …AND THE RULE'S CLASS FILTERS, exactly as Gate.swift applies them. Without these
                // the peek charged `Net` for a rule that denies only ONE destination class: MEASURED,
                // `deny Net[unknown-host]` reddened a DECLARED partner, and `deny Net[known-partner]`
                // reddened with no partners configured at all — while the identical code IN SCOPE passed
                // both. This is the over-charge the review round before last closed in ts and rust; the
                // hand-port missed it here, which is what the generated policy matrix now exists to catch.
                //
                // The child report carries `netClass`/`unknownWhy` per entry, which is the same derived
                // set the gate reads off the wire on its `gate --report` route.
                let fnNet = f["netClass"] as? [String] ?? []
                let fnWhy = f["unknownWhy"] as? [String] ?? []
                var hitSet = Set<String>()
                for r in peekRules where scopeMatches(qual, r.scope) {
                    var h = Set(r.effects.isEmpty ? inf.filter { $0 != "Unknown" }
                                                  : inf.filter { r.effects.contains($0) })
                    if h.contains("Unknown"), !r.unknownClasses.isEmpty,
                       !fnWhy.contains(where: { r.unknownClasses.contains($0) }) {
                        h.remove("Unknown")
                    }
                    if h.contains("Net"), !r.netClasses.isEmpty,
                       !fnNet.contains(where: { r.netClasses.contains($0) }) {
                        h.remove("Net")
                    }
                    hitSet.formUnion(h)
                }
                let hits = hitSet.sorted()
                if hits.isEmpty { continue }
                // NAME THE FILE FROM THE PARENT'S OWN LIST. The child's `loc:` is written from the
                // absolute path it was handed, and the path the operator can act on is the one this run
                // already disclosed as excluded — so the finding and the `excluded` entry it belongs to
                // are spelled the same way, and its class comes from the same record rather than a
                // second classification of the path.
                // Both sides normalized to an ABSOLUTE path before comparing. The child writes `loc:`
                // relative to the root it was handed — the same root as this run's — so a match on the
                // raw strings compared a relative path against the absolute one from the list and MISSED
                // every time, silently falling back to the class `excluded`: the finding survived and the
                // reason string that explains it went generic. A join through `candorAbsolutePath` is the
                // only spelling right for both an absolute and a relative scan root.
                let childLoc = String((f["loc"] as? String ?? "").split(separator: ":").first ?? "")
                let childAbs = candorAbsolutePath(childLoc.hasPrefix("/") ? childLoc
                                                  : (rootDir as NSString).appendingPathComponent(childLoc))
                let hit = peekable.first { candorAbsolutePath(absOf($0.path)) == childAbs }
                let cls = hit?.cls ?? "excluded"
                found.append(OutOfScopeFinding(
                    fn: f["fn"] as? String ?? "", path: hit?.path ?? childLoc,
                    effects: hits.sorted(), cls: cls,
                    reason: "OUTSIDE this scan's scope (\(cls)) — the gate did NOT judge it. "
                          + "candor's ANALYSIS of that file reaches this effect; the gate did not "
                          + "judge it, so the verdict is INCOMPLETE rather than a pass. (An analysis "
                          + "result, not a claim about what the code does at runtime.)"))
            }
            found.sort { ($0.path, $0.fn) < ($1.path, $1.fn) }
        } catch {
            // A PEEK THAT CANNOT RUN MUST NOT FAIL THE GATE. It is advisory by construction, and turning
            // a child-process failure into a red gate would make adding a policy — the safest thing an
            // operator can do — the thing that breaks their build. `found` stays as far as it got.
        }
        report.outOfScope = found
        // ⟨0.30⟩ NOTHING ANALYZABLE, AND THE PEEK FOUND NOTHING EITHER: REFUSE — AND REFUSE BEFORE AN
        // ENVELOPE EXISTS. The peek is the whole reason this run got past the early refusal; if it named
        // something, the ⟨0.30⟩ arm at the end reports it and exits 2 with `outOfScope` IN the report, so
        // `gate --report` over that report reaches the same 2 and §3.1 holds. If it named nothing, there
        // is nothing to report and the run must go back to being a refusal.
        //
        // WHY HERE AND NOT AT THE END, measured: the first version let the clean case fall through to a
        // normal ending and exit 2 from an arm after the verdict was written — the process exited 2 while
        // `--gate-json` said `ok: true`. The exit code was right and the DOCUMENT was green, and a machine
        // consumer reads the document. §3.1's byte-equality is quantified over "any report a scan
        // produced", so the only safe refusal is one that produces no report: once an envelope exists, the
        // scan route owns the gate route's answer.
        if noSources && found.isEmpty {
            refuseGateAndExit("candor-swift: gate NOT certified — no analyzable Swift source under "
                + "\(target), and the files this scan excluded perform no effect this policy denies; "
                + "a gate cannot be green over a tree it did not read")
        }
        // SAY IT ON STDERR TOO, and above the verdict. The report block is for machines; an operator
        // reading `policy ✓` needs to know in the same breath that a file this scan did not judge holds
        // the effect they denied. A caveat printed below a green tick is a caveat nobody reaches.
        for f in found {
            FileHandle.standardError.write(("candor-swift: ⚠ \(f.fn) performs \(f.effects.joined(separator: "+"))"
                + " — OUTSIDE this scan's scope (\(f.cls)), so the gate did NOT judge it.\n"
                + "             \(f.path)\n").data(using: .utf8)!)
        }
        if !found.isEmpty {
            FileHandle.standardError.write(("             The verdict below is INCOMPLETE because of "
                + (found.count == 1 ? "it." : "these \(found.count).") + "\n").data(using: .utf8)!)
        }
    }
}
// ⟨0.29⟩ THE SCOPE, BUILT AFTER THE PEEK. `peeked` is an outcome, so this cannot be assembled before the
// peek runs — it was, and read a flag nothing had set yet: a field whose whole job is to say whether a
// read happened, computed before the read. `PEEKED_CLASSES` still decides which classes the peek is
// WILLING to read; `peekRead` decides whether it actually did.
var excludedByClass: [String: Int] = [:]
for e in excludedFiles { excludedByClass[e.cls, default: 0] += 1 }
report.excluded = excludedByClass.keys.sorted().map {
    (cls: $0, count: excludedByClass[$0]!,
     peeked: peekRead && PEEKED_CLASSES.contains($0) && !peekUnattributed && !peekUnread.contains($0),
     reason: EXCLUDED_REASON[$0] ?? "excluded (\($0))")
}
let envelope: [String: Any] = report.toJSON()
var cg: [String: [String]] = [:]
for f in allFns { cg[f.qual] = (edges[f.qual] ?? []).sorted() }  // §2.2: EVERY analyzed fn a key

// Family filename shape `<prefix>.<pkg>.Swift.json` — what candor_report::report_files DISCOVERS,
// so the unmodified candor-query binary works on Swift reports (this engine's whole consumption
// story; caught by the first query-interop probe: `show` couldn't find a `<prefix>.json`). The
// pkg segment is dot-sanitized (`GRDB.swift` would otherwise split the <crate>.<kind> parse).
// THE FILENAME KEEPS THE UNSCOPED PACKAGE NAME, deliberately, and this was measured the other way first.
//
// Encoding the target in the filename let a package's scoped reports COEXIST, which sounds like a
// feature until discovery has to choose between them: after `--target MacApp`, `privacy-manifest`
// reported the microphone — IosApp's sensor — because three report files sat in `.candor/` and it picked
// one. A silently wrong answer is worse than the overwrite it replaced. So a scan writes ONE current
// report, exactly as before; `--out` is how you keep several. The scope lives in the `package` field and
// the hash keys, where a machine consumer reads it, not in the filename, where discovery trips over it.
let fileSafePkg = (manifestPackageName(atDir: rootDir) ?? (rootDir as NSString).lastPathComponent)
    .replacingOccurrences(of: ".", with: "-")
let reportPath = "\(prefix).\(fileSafePkg).Swift.json"
if wantJson {
    // --json: emit the §2 envelope to STDOUT and write NO report file(s)/sidecars (the candor-scan
    // reference behaviour). The κ-coverage ledger and the §6.2 policy gate below STILL run (the gate
    // keeps its exit codes), so `--json --policy p` prints the report AND exits 1 on a violation.
    // Serialize exactly as writeJson does (pretty + sorted keys) so the stdout document is byte-for-byte
    // the report file's content.
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    } catch {
        // DEFENSIVE, deliberately uncovered (TESTING.md §6): same arm as writeJson's — the envelope
        // holds only plist-serializable values, so this cannot fire without an internal type bug.
        FileHandle.standardError.write("candor-swift: could not serialize report: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    // ⟨0.28⟩ LATCH: a successful report went to stdout, so a later `exit(2)` (the gate-completeness arm
    // below, or any un-enumerated path) MUST NOT also write a fail-closed placeholder there. Two
    // documents on one stream is the shape the two-stream-refusal clause exists to prevent, arriving
    // through a different door.
    reportStreamWritten = true
} else {
    // Create `.candor/` (or the --out parent) only on the file-writing path — --json is documented as
    // writing NO files, so it must not leave an empty directory behind as a side effect.
    try? fm.createDirectory(atPath: (prefix as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    // ⟨0.32⟩ the write phase finished, so the marker's claim is no longer true. Cleared against the
    // RESOLVED prefix as well as the latched one: the latch is made from the raw target during parsing
    // and `prefix` may differ once resolved.
    clearRefusalMarker(prefix)
    writeJson(envelope, reportPath)
    writeJson(cg, "\(prefix).\(fileSafePkg).Swift.callgraph.json")
    // Type-hierarchy sidecar (SPEC §4 / 0.7): each local type -> its declared supertypes/protocols, by
    // INVERTING `conformers` (supertype -> subtypes, from pushType). Lets candor-query's dispatch-frontier
    // (callers --include-unknown) resolve whether a confirmed reacher overrides a `dispatch:` owner. Keyed by
    // the bare type name — matching this engine's `Type.member` fn quals + `dispatch:Type.member` reasons.
    //
    // ⟨0.26⟩ The KEY SET is the MANIFEST (SPEC §2.2). Inverting `conformers` alone gives a key only to
    // types that HAVE a supertype, so a consumer walking up from `S: P` into a supertypeless `P` fell off
    // the indexed set — and read that absence as "P has no supertypes", a positive claim about a type it
    // had never been told about. Every type this pass INDEXED now carries a key, `[]` included, so absence
    // means "never analysed" and nothing else. Seeded from `declaredTypes` (types with a REAL local
    // definition), NOT `localTypes`: the latter also holds extension-only platform types (`extension
    // Process`), and this pass cannot see a platform type's supertypes, so `[]` there would be the false
    // claim the rung exists to remove. A local type whose supertype is non-local (`class C: NSObject`)
    // still keys `["NSObject"]` while `NSObject` itself stays absent — which is exactly right: the chain
    // beyond it is unanswerable, and a consumer must over-list rather than rule it out.
    //
    // THE KEY SET IS EXACTLY WHAT THIS PASS DECLARED, and the filter on the append loops is the whole
    // point rather than tidiness. `conformers` also records conformances spelled in an EXTENSION of a type
    // this package never declared — `extension Process: Marker {}` puts `Process` in it. Seeding alone
    // therefore did not stop `Process` acquiring the key `["Marker"]`, and under ⟨0.26⟩ a key ASSERTS that
    // the array is the complete supertype list. It is not: this pass cannot see a platform type's own
    // supertypes, so a consumer would answer NO to "is Process a subtype of <some platform type>?" where
    // the truth is UNANSWERABLE — and drop a reacher from a disclosure on the strength of it. That is the
    // rung's own premise violated by the engine implementing it. MEASURED: a package whose only content is
    // `extension Process: Marker {}` emitted `{"Process": ["Marker"], ...}`.
    //
    // So a non-declared type gets NO key at all, which reads as unanswerable — the safe direction. It
    // costs the ability to answer YES for `Process <: Marker`, turning a resolvable row into an over-list;
    // that is the trade the family always takes over a false negative. (An ALLOWLIST here is safe for once
    // precisely because omission widens: the usual denylist rule exists because an allowlist's omissions
    // normally go SILENT, and here they go LOUD.)
    let indexedTypes = declaredTypes.union(protocolNames)
    var typeHierarchy: [String: [String]] = [:]
    for t in indexedTypes { typeHierarchy[t] = [] }
    for (sup, subs) in conformers {
        for sub in subs where indexedTypes.contains(sub) { typeHierarchy[sub, default: []].append(sup) }
    }
    // SUPER-PROTOCOL edges (`protocol Mid: Base`). Protocols are held out of `conformers` by design, so
    // this map was the only record of them and the sidecar never saw it: a chain `Impl: Mid`, `Mid: Base`
    // dead-ended at `Mid` with no key, and a consumer asking "is Impl a Base?" got a walk that ran off the
    // indexed set. Under the rung that is now correctly UNANSWERABLE rather than a silent NO — but
    // unanswerable for a relation this pass actually KNOWS is a disclosure that need not be made. MEASURED
    // on the two-protocol fixture: before, neither `Base` nor `Mid` appeared in the sidecar at all.
    for (sub, sups) in protocolSupers where indexedTypes.contains(sub) {
        for sup in sups { typeHierarchy[sub, default: []].append(sup) }
    }
    for k in typeHierarchy.keys { typeHierarchy[k] = Array(Set(typeHierarchy[k]!)).sorted() }
    writeJson(typeHierarchy, "\(prefix).\(fileSafePkg).Swift.hierarchy.json")
    FileHandle.standardError.write(
        "candor-swift: wrote \(effectors.count) effectful functions (\(allFns.count) analyzed, \(sourcePaths.count) files) to \(reportPath)\n".data(using: .utf8)!)
    // Effect breakdown — make the result visible at a glance, not just a count + a file path.
    var counts: [String: Int] = [:]
    for e in effectors { for x in e.inferred.toNames() { counts[x, default: 0] += 1 } }
    // DERIVED from the one ordered source. This was a hardcoded copy of the sensor vocabulary, and
    // because the line is a `.filter { counts[$0] != nil }` over it, an effect NOT in the list was
    // computed, counted, written to the report — and silently dropped from the summary the user reads
    // first. Measured: a scan reaching NFC and HealthKit printed "Health 1" and said nothing about NFC,
    // while the report carried both. The artifact was right and the terminal was quieter than it, which
    // is the same shape of gap even when nothing is technically wrong.
    let breakdown = (["Net", "Llm", "Fs", "Db", "Exec", "Ipc", "Env", "Clipboard", "Clock", "Log", "Rand"]
                     + PRIVACY_EFFECTS_ORDER)
        .filter { counts[$0] != nil }.map { "\($0) \(counts[$0]!)" }.joined(separator: " · ")
    let unknown = counts["Unknown"] ?? 0
    if !breakdown.isEmpty || unknown > 0 {
        let u = unknown > 0 ? "\(breakdown.isEmpty ? "" : "   ·   ")Unknown \(unknown) (disclosed)" : ""
        FileHandle.standardError.write("  \(breakdown)\(u)\n".data(using: .utf8)!)
    }
}
// ⟨0.28⟩ THE RUN HAS FINISHED WRITING REPORTS: hand back any file the ⟨0.28⟩ armer above turned out not to
// own. Everything below this line is the GATE, which writes a verdict, never a report — so a file still
// holding the placeholder here is a leftover this scan never claimed, and leaving it armed would assert an
// incompleteness the run never experienced (the ⟨0.21⟩ trigger; see `disarmUnwrittenOutReports`, and the
// reference engine's undone first version in candor-rust `f439dea`). Reached only on the paths that
// completed the analysis — every exit-2 above this point leaves the placeholders in place, which is the
// whole point of arming. `--json` writes no report file, so it restores the whole armed set.
disarmUnwrittenOutReports()

// the coverage ledger's stderr line (the ledger itself is computed above, before the envelope,
// and ALSO rides the report as the ⟨0.15 staged⟩ `coverage` field — same list, same counts).
if !unlisted.isEmpty {
    let shown = unlisted.prefix(8).map { "\($0.key) (\($0.value) import\($0.value == 1 ? "" : "s"))" }.joined(separator: ", ")
    let more = unlisted.count > 8 ? " + \(unlisted.count - 8) more" : ""
    FileHandle.standardError.write(
        ("candor-swift: candor's classifier doesn't cover \(unlisted.count) module\(unlisted.count == 1 ? "" : "s") this code imports — "
         + "their effects are INVISIBLE to the scan (absent from the report, NOT a claim they're pure): \(shown)\(more)\n").data(using: .utf8)!)

    // SCAN-COMPLETENESS NUDGE (the candor-java port, commit 8b5d0b0). A scan that sees your sources but
    // not the packages they depend on cannot see those packages' effects — a MISSING INPUT, not a
    // precision defect, and the ledger line above states the gap without saying what to DO about it.
    // Measured on the JVM side: a real 18.7k-fn webapp scanned app-only could PROVE Net on 465 functions;
    // re-scanned as the deployed artifact (app + its 222 dependency jars) the same gate proved Net on
    // 5,865 — the library reaches became DETERMINED effects instead of nothing. The nudge deliberately
    // promises VISIBILITY only: chaining a dep's report does not resolve a dispatch over your OWN broad
    // protocol hierarchy, so it must never be sold as a precision fix.
    //
    // Triggered on VOLUME, not on the module COUNT: count is the wrong metric — a small app touching five
    // tiny util modules once each would be nudged for nothing, while one SDK pulled into sixty files (the
    // textbook "you pointed candor at sources whose deps were never scanned" case) would be missed by any
    // count threshold. UNIT DEVIATION from the reference engine: candor-java sums CALLS into uncovered
    // packages (bytecode gives it call sites into named packages); this engine's ledger counts IMPORT
    // DECLARATIONS per module (one per `import M` per file — see Driver's `importCounts`, and the wire
    // field that stays `calls` per SPEC §2), because a syntactic Swift scan cannot attribute an
    // unresolved call to a specific module. So the swift trigger is import volume, the closest quantity
    // this engine actually measures: it still separates "one dependency, imported everywhere" from
    // "a handful of modules touched once".
    //
    // Advisory ONLY — stderr, after the ledger line; it never touches the report, the verdict, the exit
    // code, or stdout (stdout stays pure JSON under --json, pinned by ScanCompletenessNudgeProcessTests).
    //
    // SCOPED TO SCANNABLE MODULES, which is what makes this port honest. Unlike a jar, most of a Swift
    // ledger is Apple frameworks with NO SOURCE TO SCAN: a 2.9k-fn SwiftUI app measured 22 uncovered
    // modules / 49 imports, almost all MapKit/Metal/WidgetKit-class. Volume alone would therefore nudge
    // that user toward a remedy they cannot act on — a dead end, which this project's UX rule forbids
    // ("failures carry remedies"). So the trigger counts ONLY imports of modules that are demonstrably
    // scannable: a module directory under a fetched SwiftPM checkout (`.build/checkouts/*/Sources/<M>`,
    // the SwiftPM layout convention). A framework never appears there, so it never contributes; a real
    // dependency does, and for it the remedy is exactly right — which is why the message can now state
    // it unconditionally instead of hedging.
    //
    // Deliberately silent when `.build/checkouts` is absent: nothing is provably scannable, so the honest
    // volume is zero. That case is ALREADY covered upstream by the ⟨0.19⟩ SETUP warning ("deps not
    // fetched … run swift build first"), so staying quiet here avoids a duplicate — and fail-quiet is the
    // right default for an advisory whose only cost of firing is noise.
    let uncoveredImportsNudgeMin = 50   // ledger-volume bar; parity with candor-java's UNCOVERED_CALLS_NUDGE_MIN
    var scannableModules: Set<String> = []
    let checkoutsDir = (rootDir as NSString).appendingPathComponent(".build/checkouts")
    for checkout in ((try? fm.contentsOfDirectory(atPath: checkoutsDir)) ?? []) {
        let srcDir = ((checkoutsDir as NSString).appendingPathComponent(checkout) as NSString)
            .appendingPathComponent("Sources")
        for module in ((try? fm.contentsOfDirectory(atPath: srcDir)) ?? []) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: (srcDir as NSString).appendingPathComponent(module), isDirectory: &isDir),
               isDir.boolValue { scannableModules.insert(module) }
        }
    }
    let scannable = unlisted.filter { scannableModules.contains($0.key) }
    let uncoveredImports = scannable.reduce(0) { $0 + $1.value }
    if uncoveredImports >= uncoveredImportsNudgeMin {
        // The count is >= the bar, so `imports` is always plural here; only the module count needs agreement.
        let m = scannable.count
        FileHandle.standardError.write(
            ("candor-swift: hint — \(uncoveredImports) imports pull in \(m) dependency module\(m == 1 ? "" : "s") that "
             + "\(m == 1 ? "is" : "are") not scanned, so their effects are invisible here. Scan them too and chain "
             + "their reports (`--workspace` for local path deps, or CANDOR_DEPS=<dir>): those reaches then resolve "
             + "to DETERMINED effects instead of being absent.\n").data(using: .utf8)!)
    }
}

// The cold-repo hook (SURFACE-BEST-FIND-DESIGN.md, phase P3): ONE more stderr line naming the single
// most surprising transitive reach + a ready-to-run `candor path` command — or an honest "nothing
// hidden" fallback. Emitted right after the coverage ledger, from the same in-memory maps the report
// was built from (inferred/direct effect sets + the `edges` call graph + locOf). Prefix is `candor:`
// (brand voice) and the command is `candor path …` — identical on every engine (CandorCore/Surface.swift).
emitSurface(inferred: inferred, direct: direct, calls: edges, loc: locOf)


// ════════════════════════════════════════════════════════════════════════════════════════════════
// §6.2 policy gate — parser in CandorCore/Policy.swift, execution in Gate.swift; the exit-code
// choreography (2 unreadable / 1 violation / 0 clean) stays here with the other process decisions.
// ════════════════════════════════════════════════════════════════════════════════════════════════

var gateViolations: [GateViolation] = []
/// ⟨0.24⟩ the `.candor/config` whose VOCABULARY participated in this verdict, and which aliases it
/// supplied (SPEC §3.1) — nil unless a config `unknown-alias` was actually consumed by a policy token.
var gatePolicyVocabulary: (config: String, aliases: [String: [String]])? = nil
// ⟨0.28⟩ the lines the policy parse DROPPED — set beside `gatePolicyVocabulary` where the policy is
// parsed, read by the one verdict write below (SPEC §6.2 `ignored`; see `IgnoredLine`).
var gatePolicyIgnored: [IgnoredLine] = []
// AS-EFF-005 baseline regression guard (SPEC §7 item 5, Baseline.swift) — checked FIRST, matching the
// reference engine's checker order (candor-java runs checkBaseline before checkPolicy). CANDOR_BASELINE
// env over the config `baseline` key (the same env-over-config precedence as `policy`; a relative
// config value was anchored to the config's home dir in Config.swift). May exit 2 (invalid gate input:
// unparseable / versionless / cross-build baseline); an ABSENT file is a note, guard inactive.
var baselinePath: String? = ProcessInfo.processInfo.environment["CANDOR_BASELINE"]
// WHICH SOURCE supplied it decides what a MISSING file means (see checkBaseline): `CANDOR_BASELINE` is
// set unconditionally by the adopt workflow, so an absent path there is "the ratchet is not adopted
// yet"; a checked-in `baseline` line DECLARES that this repo has one, so an absent path there was
// deleted or never committed — and passing green over it is a gate that silently stopped gating.
var baselineFromConfig = false
if baselinePath == nil, let b = candorConfig["baseline"] { baselinePath = b; baselineFromConfig = true }
// ⟨0.29⟩ A PEEK RUNS NO GATE OF ANY KIND, AND THE POLICY CLEAR ABOVE WAS ONLY HALF OF THAT. `baselinePath`
// arrives by the IDENTICAL env-over-config ladder (`CANDOR_BASELINE`, inherited by the child, then the
// config's `baseline` key, rediscovered from the same target), and nothing cleared it — so a peek child on
// any baselined project ran the AS-EFF-005 ratchet independently over an arbitrary excluded-file subset.
// REPRODUCED on the exact argv the parent hands the child: exit 1, `[AS-EFF-005] helper gained effect
// { Exec } not present in the baseline`, a comparison meaningless over that scope that can legitimately
// fire. Silent only because the parent never inspected the child's exit status — so the obvious hardening
// (which the `--workspace` sibling already models) would have started losing every peek finding on a
// baselined project. Cleared HERE for the same reason policy is cleared where it is: after every source
// has been applied is the one place the answer cannot be routed around.
if peekListPath != nil { baselinePath = nil }
// ⟨unknown-ratchet⟩ OPT-IN (default OFF): env CANDOR_UNKNOWN_RATCHET over config `unknown-ratchet`, the
// same env-over-config precedence + truthiness as candor-java's Config.flag — env PRESENT (any value,
// even empty) is true; else the config key present with an empty / true / 1 / yes value. When ON an
// Unknown-only gain vs the baseline FAILS (AS-EFF-005) instead of being advisory.
let unknownRatchet: Bool = {
    if ProcessInfo.processInfo.environment["CANDOR_UNKNOWN_RATCHET"] != nil { return true }
    guard let v = candorConfig["unknown-ratchet"] else { return false }
    let lc = v.lowercased()
    return v.isEmpty || lc == "true" || v == "1" || lc == "yes"
}()
if let bp = baselinePath {
    gateViolations += checkBaseline(inferred: inferred, path: bp, engineVersion: engineVersion,
                                    unknownRatchet: unknownRatchet, declaredInConfig: baselineFromConfig)
}
// ⟨0.24⟩ **PRECEDENCE BINDS THE VERDICT, NOT THE POLICY GATE** (SPEC §3.1, candor-spec `4c79958`).
//
// MEASURED 2026-07-28 — a pure function gains an `Fs` call, scanned against a frozen baseline:
//
//     control (no policy)         exit 1, violations: ["AS-EFF-005"]
//     + a policy with a bad token exit 2, NO `violations` key — THE REGRESSION IS DELETED
//
// So a typo in a policy token downgraded "your change added an effect" to "could not evaluate", and the
// regression vanished from the machine channel. On THIS engine it did not even survive on stderr: the
// violation lines are printed below the policy block, so `refuseGateAndExit` ran before them and the
// finding was lost on BOTH channels.
//
// Three individually-correct decisions composed into it: the baseline guard runs first BY DESIGN, the
// earlier precedence repair was scoped to the policy gate's own violation list, and "a refusal document
// carries no `violations` key" was justified by every exit-2 site running before anything could be
// recorded — **a claim about ORDERING that reads as a claim about SHAPE**, and it stopped being true
// once a producer's evidence sat upstream of the refusal.
//
// THE RULE IS OVER THE VERDICT. Any violation this run has already established on carried evidence —
// whatever subsystem produced it — dominates a refusal and MUST appear in the document. So the refusal
// arm is keyed on `gateViolations.isEmpty` (did this run evaluate NOTHING?) and never on "did this run
// end refused", which is exactly the conflation the clause forbids. The policy itself is still NOT
// evaluated: `break policyBlock` skips `evaluateGate` entirely, so the rule that could not be honoured
// as written never runs — only what was already certain is reported.
//
// WHY EXIT 1 IS SAFE HERE and not merely fail-closed: the baseline record is CERTAIN on evidence this
// run carries, `Reject` is upward-closed (PAPER3 Lemma 2), and no resolution of the unreadable policy
// could un-reject it. Exit 1 is also strictly more informative than exit 2, because it NAMES the finding.
policyBlock: if let pp = policyPath {
    /// Refuse — UNLESS a violation is already established, in which case it dominates and the run falls
    /// through to the common verdict tail (document + exit 1) with the refusal disclosed beside it.
    /// Returns true when the caller must `break policyBlock`; it never returns on the sole-refusal path.
    /// ⟨0.27⟩ SPEC §3.1's composed-document clause: on a WHOLE-POLICY refusal that a certain violation
    /// dominates, the document lists EVERY rule of the refused policy under `unevaluated`, raw line
    /// verbatim — the unhonourable one(s) with their specific cause, the rest with a `why` naming the
    /// whole-policy refusal. Not only the offending line: a consumer that finds `deny Fs` ABSENT from the
    /// list on an exit-1 document reads it as enforced-and-passed, a per-rule false all-clear arriving
    /// through the disclosure channel. Where there are no lines to name (the file itself unreadable), the
    /// list carries one entry for the whole policy — an exit-1 document with `violations` and no
    /// `unevaluated` claims the policy ran and passed.
    func refusedPolicyRules(_ policyText: String?, at path: String, causes: [String]) -> [Unevaluated] {
        let whole = "NOT evaluated — this policy was refused as a whole (the run's verdict does not "
            + "answer it); a violation established elsewhere is what set the exit code"
        guard let policyText else {
            return [Unevaluated(rule: "(entire policy \(path) — unreadable, no rules parsed)", why: whole)]
        }
        let lines = policyText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                     .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return [Unevaluated(rule: "(entire policy \(path) — no rules parsed)", why: whole)]
        }
        return lines.map { line in
            // A cause message names the line it is about, verbatim, at its end — the family's wording.
            let mine = causes.filter { $0.hasSuffix(line) }
            return Unevaluated(rule: line, why: mine.isEmpty ? whole : mine.joined(separator: "; "))
        }
    }
    func refuseUnlessAViolationStands(_ reason: String, unevaluated: [Unevaluated]) -> Bool {
        if gateViolations.isEmpty { refuseGateAndExit(reason, unevaluated: unevaluated) }
        FileHandle.standardError.write(
            (reason + "\n"
             + "candor-swift: the policy above was NOT evaluated — but \(gateViolations.count) violation(s) "
             + "were already established on evidence this run carries, and a certain violation DOMINATES a "
             + "refusal (SPEC §3.1, PAPER3 Lemma 2: no resolution of an unevaluated rule can un-reject a "
             + "rejected verdict). Reporting them below; the verdict does NOT answer the policy.\n")
                .data(using: .utf8)!)
        gateUnevaluated = unevaluated
        return true
    }
    guard let text = try? String(contentsOfFile: pp, encoding: .utf8) else {
        if refuseUnlessAViolationStands("candor-swift: policy \(pp) could not be read; gate NOT enforced",
                                        unevaluated: refusedPolicyRules(nil, at: pp, causes: [])) {
            break policyBlock
        }
        // unreachable — `refuseUnlessAViolationStands` exits when nothing stands. `guard` needs an exit.
        exit(2)
    }
    // ⟨0.19⟩ reason-class aliases (SPEC §6.2) from `.candor/config`, so `Unknown[<alias>]` resolves at the
    // gate — ⟨0.24⟩ ANCHORED AT THE POLICY FILE, not at the scan target (SPEC §3.1, candor-spec `99eb4e9`).
    //
    // §3.1 names three channels an effect must never enter a gate through; review found a FOURTH that no
    // engine tested: `.candor/config`'s `unknown-alias`. The two routes anchored DIFFERENTLY — every gate
    // verb at the policy file's directory, every scan route at the target — so with the policy filed
    // OUTSIDE the scan target the same rule expanded differently and §3.1's byte-equality MUST was
    // breakable by a file that is neither the report nor the policy. MEASURED on this engine before the
    // fix, one report + one policy `deny Unknown[corp]`, with `unknown-alias corp = reflect` beside the
    // POLICY and the target's only hole in the `indirect` class:
    //
    //     gate --report R --policy P   exit 0   (alias found: the rule narrows to [reflect], no match)
    //     scan TARGET   --policy P     exit 1   (alias NOT found: the rule widened to a bare deny Unknown)
    //
    // RULING: vocabulary travels with the POLICY that uses it. Target-scoped keys (`deps`, `net-partner`,
    // scan settings) keep anchoring at the target because they describe the thing being SCANNED — see
    // `netPartners` above, deliberately unchanged. Byte-equality then holds by construction rather than by
    // the two routes happening to be pointed at the same directory.
    //
    // ANCHORED AT THE RESOLVED POLICY PATH, which is broader than the ruling's literal "when `--policy` is
    // given explicitly": `gate --report` anchors at whatever `--policy`/`CANDOR_POLICY`/the config `policy`
    // key resolved to, in every case. Restricting this side to the explicit flag would leave the
    // CANDOR_POLICY case anchoring at two different directories — the exact defect the ruling is closing.
    let vocabConfig = discoverConfig(targetPath: pp)
    let parsedAliases = parseUnknownAliases(vocabConfig?.text)
    let unknownAliases = parsedAliases.aliases
    // Parsed ONCE and shared with the purity-hole disclosure below — two `parsePolicy` calls over the same
    // text were two chances for the ⟨0.24⟩ policy-error check to be applied to only one of them.
    let scanPolicy = parsePolicy(text, aliases: unknownAliases)
    // ⟨0.28⟩ SPEC §6.2 — the dropped lines ride the verdict as `ignored` (stashed for the write below).
    gatePolicyIgnored = scanPolicy.ignored
    // ⟨0.24⟩ SPEC §3.1: the config file is named in the verdict only when its vocabulary PARTICIPATED.
    // ⟨0.24⟩ …and `aliases` maps each consumed alias to the CLASSES it expanded to — see
    // `consumedAliasVocabulary`, shared with the `gate --report` route so the two cannot disagree.
    gatePolicyVocabulary = scanPolicy.usedAliases.isEmpty ? nil
        : vocabConfig.map { (config: $0.path,
                             aliases: consumedAliasVocabulary(scanPolicy, unknownAliases)) }
    // ⟨0.24⟩ AN UNRECOGNISED REASON-CLASS TOKEN IS A POLICY ERROR (SPEC §6.2, candor-spec `382a7e0`) —
    // exit 2, the unreadable-policy posture, BEFORE any verdict is derived and before `--gate-json` is
    // written. Measured on this engine: `deny Unknown[dispatch,nativ]` silently NARROWED to `[dispatch]`
    // and exited 0 over a report whose only hole is `native:` (fail-open, and the common case — a typo
    // lands beside correct tokens far more often than alone), while `deny Unknown[corp]` printed
    // "ignoring policy rule" and then KEPT and WIDENED it. Same check on `gate --report`, so the two
    // routes refuse the same policies.
    // ⟨0.24⟩ the ALIAS DEFINITION's own tokens are checked FIRST and on the same rule (candor-spec
    // `be0b9a9`) — a typo in the vocabulary the policy is written AGAINST fails open identically, and
    // more quietly, because the policy line reads perfectly well.
    //
    // ⟨0.24⟩ **BUT ONLY WHEN THE POLICY CONSUMED THE DEFINITION.** Measured 2026-07-28 on `deny Fs` (no
    // bracket to expand) beside an unused `unknown-alias corp = dispatch,nativ`: swift exit 2 with the
    // `Fs` violation DELETED, rust exit 1 with it charged, on the identical triple. An alias no rule
    // references expands no token, so it cannot change any verdict — and a thing that cannot change a
    // verdict cannot make one unanswerable. Because config discovery walks parent directories, the
    // un-gated form let ONE bad token in a parent config red-refuse every gate in the subtree. See
    // `partitionAliasErrors` for why an alias that lost ALL its tokens is still refused (the referring
    // policy token errors on its own line).
    let aliasErrors = partitionAliasErrors(parsedAliases.errors, consumedBy: scanPolicy)
    discloseUnconsumedAliasErrors(aliasErrors.disclosed)
    let policyErrors = aliasErrors.refusing.map(\.message) + scanPolicy.gateRefusals
    if !policyErrors.isEmpty,
       refuseUnlessAViolationStands(policyErrors.joined(separator: "\n"),
                                    unevaluated: refusedPolicyRules(text, at: pp, causes: policyErrors)) {
        break policyBlock
    }
    // ⟨0.28⟩ A CONFIGURED POLICY THAT YIELDED ZERO RULES IS A BROKEN GATE CONFIG (SPEC §6.2) — the same
    // refusal posture as the two branches above (unreadable file, unhonourable token). The predicate and
    // the wording live in `zeroRulePolicyRefusal` (Gate.swift), shared with the `gate --report` route so
    // that the emptiness test — which MUST read every rule vector — exists once; see its doc comment for
    // the measurement, the control, and why keying on `deny` alone would refuse every allowlist gate.
    //
    // Routed through `refuseUnlessAViolationStands` for the SAME precedence as both branches above: a
    // certain violation dominates a refusal (§3.1, `Reject` is upward-closed). No POLICY violation can
    // exist with zero rules, but an AS-EFF-005 baseline regression is a finding from evidence this run
    // carries and it outranks. (The `gate --report` route has no such finding available, so it refuses
    // outright there — the same posture its neighbouring branches take.)
    //
    // THE CONTROL: reaching here at all means a policy was CONFIGURED (`policyBlock` is entered on
    // `policyPath != nil`), so a run that configured no gate never asks the question and stays exit 0.
    if let zr = zeroRulePolicyRefusal(scanPolicy, at: pp, who: "candor-swift"),
       refuseUnlessAViolationStands(zr.why, unevaluated: zr.unevaluated) {
        break policyBlock
    }
    // ⟨0.24⟩ the SCAN route into the shared gate seam (Gate.swift): the reason-class fixpoint and the
    // per-fn `netClassesOf` derivation moved into `gateInputFromScan`, so `gate --report` can hand
    // `evaluateGate` the same record built from a WRITTEN report instead of from the classifier.
    // ⟨0.20⟩ `net-partner` (NET-DESTINATION-CLASS-DESIGN.md) is the SAME set the report's `netClass` used
    // (hoisted above), so `deny Net[unknown-host]` tolerates a declared partner and the verdict classifies it.
    let scanGateInput = gateInputFromScan(inferred: inferred, whyMap: whyMap, direct: direct, edges: edges, cg: cg,
                                          hostsAcc: hostsAcc, cmdsAcc: cmdsAcc,
                                          pathsAcc: pathsAcc, tablesAcc: tablesAcc,
                                          incompleteAcc: incompleteAcc, netPartners: netPartners)
    let scanGateResult = evaluateGate(scanPolicy, scanGateInput)
    gateViolations += scanGateResult.violations
    let gateZeroMatchRules = scanGateResult.zeroMatch
    // ⟨0.29⟩ THE NAME RULES STOP AT THE SCAN BOUNDARY, AND NOW SAY SO. `forbid A -> B` and
    // `only A -> B …` match over the call graph; a chained dependency contributes EFFECTS, not EDGES, so a
    // function calling into a dep has an EMPTY adjacency and the crossing is invisible to them. MEASURED
    // in candor-ts and candor-rust with a dep chained: `only model -> util` answered `policy ✓` over a call
    // into the dependency while a LOCAL unpermitted scope in the same run fired AS-EFF-011 — the rule was
    // armed; the boundary was the gap.
    //
    // WORSE FOR `only`: `forbid` asks whether ONE named crossing is present, so a missed dep crossing
    // under-reports one prohibition; `only` asserts A reaches the listed scopes AND NOTHING ELSE — a
    // COMPLETENESS claim — and exists because `forbid` fails open. A package that calls a third-party
    // library is not a leaf, and without this the gate called it one.
    //
    // DISCLOSURE, NOT A VERDICT CHANGE — the ⟨0.29⟩ `outOfScope` posture: say what was not judged, leave
    // the exit code alone. Keyed on a report having been READ (`reportsRead`), not on an entry being
    // JOINED (`byKey`): a dependency whose reached function is PURE yields no entry at all. This comment
    // said exactly that while the code beside it read `byKey` — the claim was true of the design and
    // false of the line under it, which is the stale-comment class this rung has now hit three times.
    // Found in review, MEASURED: with an all-pure dep, rust and ts warned and java and swift did not.
    let namedRuleCount = scanPolicy.forbid.count + scanPolicy.only.count
    if namedRuleCount > 0 && depsIndex.reportsRead > 0 {
        FileHandle.standardError.write(
            ("candor-swift: ⚠ \(namedRuleCount) name-matching rule(s) (`forbid`/`only`) were matched over "
             + "THIS scan's call graph only — a chained dependency contributes effects, not call edges, so "
             + "a crossing INTO a dependency is invisible to them. `deny`/`allow` still cross (effects "
             + "propagate); an `only` rule cannot certify that a package is a leaf when it calls into one "
             + "of its dependencies.\n").data(using: .utf8)!)
    }
    // ⟨0.24⟩ §3.1 — see GateReportCLI. A rule that bound nothing is disclosed, never scored as satisfied.
    for raw in gateZeroMatchRules {
        FileHandle.standardError.write(
            ("candor: policy rule matched NO function — `\(raw)`. It was evaluated and bound nothing, so it "
             + "cannot have caught anything. Legitimate when one policy is shared across repos; a typo'd "
             + "layer name otherwise.\n").data(using: .utf8)!)
    }
    // A SPLIT NARROWS EVERY POLICY THAT NAMED THE PARENT, AND DOES IT SILENTLY. `MotionRaw` was split
    // out of `Motion` because Apple requires no usage key for the raw CoreMotion stream — correct, and
    // it means an existing `deny Motion` written to mean "no CoreMotion here" now PASSES a
    // CMMotionManager reach while still binding, still evaluating, and still reporting nothing. That is
    // a guard the operator believes is on, which is the zero-match shape one level up, so it gets the
    // same remedy: disclosed, never scored, verdict untouched.
    do {
        let denied = Set(scanPolicy.deny.flatMap { $0.effects })
        for (child, parent) in EFFECT_SPLIT_PARENT.sorted(by: { $0.key < $1.key })
        where denied.contains(parent) && !denied.contains(child) {
            let reaching = inferred.filter { $0.value.contains(child) }.keys.sorted()
            guard !reaching.isEmpty else { continue }
            FileHandle.standardError.write(
                ("candor: `deny \(parent)` does NOT cover \(child), which \(reaching.count) function(s) "
                 + "reach (\(reaching.prefix(3).joined(separator: ", "))\(reaching.count > 3 ? ", …" : "")). "
                 + "\(child) was split out of \(parent) because Apple requires no usage-description key "
                 + "for it — so this rule is narrower than it was. Add `deny \(child)` if you meant the "
                 + "sensor rather than the manifest requirement.\n").data(using: .utf8)!)
        }
    }
    // Provable-purity DISCLOSURE (advisory — NEVER a violation, so the exit/verdict are untouched): functions
    // in a pure/deny scope that PASS but are Unknown (the Unknown could hide the forbidden effect — a
    // fn/closure-injected port). Surfaces the gap automatically (eval/fixloop/DISPATCH-NOTE.md).
    // Same predicate + upgrade as `candor-swift unverified` (CandorCore.unverifiedHoleRule) — one source of truth.
    //
    // ⟨0.19⟩ It is handed the reason classes — and ⟨0.20⟩ the Net destination classes — from the VERY
    // GateInput `evaluateGate` was just given, not a second derivation of them, which is what makes "the
    // note names the functions the gate passed" a property of the code. A `deny Unknown[<class>…]` or a
    // `deny Net[<dest>…]` this run did NOT charge leaves the function passing while it still carries an
    // `Unknown`, and that is exactly a hole this note must name.
    let disclosePolicy = scanPolicy
    var purityHoles: [(String, String)] = []
    for qual in inferred.keys.sorted() {
        if let r = unverifiedHoleRule(qual, inferred[qual] ?? [], disclosePolicy.deny,
                                      scanGateInput.reasonClasses[qual] ?? [],
                                      Set(scanGateInput.netClasses[qual] ?? [])) {
            purityHoles.append((qual, ruleUpgrade(r).upgrade))
        }
    }
    if !purityHoles.isEmpty {
        FileHandle.standardError.write("candor-swift: note — \(purityHoles.count) function(s) PASS the policy but are Unknown (purity NOT verified — the Unknown could hide a forbidden effect):\n".data(using: .utf8)!)
        for (fn, up) in purityHoles {
            FileHandle.standardError.write("    `\(fn)`  → add  `\(up)`\n".data(using: .utf8)!)
        }
        FileHandle.standardError.write("  (advisory; add the upgrade(s) to REQUIRE provable purity, or run `candor-swift unverified` for detail — the gate verdict is unchanged)\n".data(using: .utf8)!)
    }
}
// Violation lines (baseline + policy) are diagnostics, not the report — route them to STDERR so
// `--json --policy p` keeps stdout a single clean JSON document (a violation line on stdout broke `… | jq`).
for v in gateViolations { FileHandle.standardError.write(("[\(v.rule)] \(v.detail)\n").data(using: .utf8)!) }
// --gate-json ⟨0.8⟩: the machine verdict, from the SAME gateViolations that set the exit code — written
// BEFORE the exit below (ok:true,[] when no gate is configured). Unreadable policy already exited 2 above;
// AS-EFF-005 records join the same list, so the verdict and the exit code can never disagree.
if let gp = gateJsonPath { writeGateVerdict(gateViolations, to: gp, spec: specVersion, analyzedCount: allFns.count, unanalyzed: unanalyzedUnits, coverage: unlisted.map(\.key), policyVocabulary: gatePolicyVocabulary, netPartners: report.netPartners.map { [$0] } ?? [], unevaluated: gateUnevaluated, ignored: gatePolicyIgnored, outOfScope: report.outOfScope ?? []) }   // ⟨0.15 staged⟩ advisory, verdict-preserving; ⟨0.21⟩ analyzed + fail-closed unanalyzed; ⟨0.24⟩ the config vocabulary that participated
let gateConfigured = policyPath != nil || baselinePath != nil
if gateConfigured {
    if gateViolations.isEmpty {
        // THE GREEN LINE IS PRINTED BELOW, AFTER THE EXIT-2 ARMS — not here. Measured 2026-08-19: this
        // wrote `candor-swift: policy ✓` and the very next line was `gate NOT certified … incomplete
        // rather than a pass`, exit 2. The exit code and the verdict document were right; the human
        // channel said pass. An operator or a log grep keyed on ✓ reads a NOT-certified run as green,
        // which is the cardinal sin in the one channel people actually read. rust and ts reach their
        // ✓ only after the same two arms have returned, so this was also a four-way divergence.
        // Both exit-2 causes, not just ⟨0.30⟩'s: the ⟨0.21⟩ unanalyzed arm had the same shape.
    } else {
        FileHandle.standardError.write("candor-swift: \(gateViolations.count) policy violation(s)\n".data(using: .utf8)!)
        // Remedy pointer (FAILURE path only — a clean gate stays byte-identical): the engine carries its
        // own remedy verb; name it so the reader doesn't have to know. Append-only, after the pinned
        // summary line, same stream (stderr); exit code and --gate-json untouched.
        FileHandle.standardError.write("→ candor-swift fix-gate names the remedy for each\n".data(using: .utf8)!)
        exit(1)   // a real violation dominates
    }
}
// ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): a CONFIGURED gate over source candor could NOT analyze (unreadable
// files) cannot certify — exit 2 (could-not-evaluate), the fail-closed posture. A real violation (exit 1,
// above) dominates. A BARE scan with NO gate does not exit 2 — it discloses `unanalyzed` in the report and
// stays exit 0. (Mirrors candor-java's gate fail-closed.)
if gateConfigured && !unanalyzedUnits.isEmpty {
    FileHandle.standardError.write(
        "candor-swift: gate NOT certified — \(unanalyzedUnits.count) source file(s) could not be analyzed (see above); a gate cannot be green over unanalyzed code\n"
            .data(using: .utf8)!)
    exit(2)
}
// ⟨0.30⟩ THE SCOPE HALF OF THE SAME POSTURE, and the same exit. EXIT 2, NOT 1: these functions are not in
// `violations` and not in `functions`, because the gate did not judge them — exit 1 would claim "I judged
// your code and it breaks the policy", false in the other direction. The violation exit above dominates.
if gateConfigured, let oos = report.outOfScope, !oos.isEmpty {
    FileHandle.standardError.write(
        ("candor-swift: gate NOT certified — \(oos.count) function(s) OUTSIDE this scan's scope perform an "
         + "effect this policy denies (named above); the gate did not judge them, so the verdict is "
         + "incomplete rather than a pass\n").data(using: .utf8)!)
    exit(2)
}
// …and only NOW is the gate green: every exit-2 arm above has been passed, so `policy ✓` is a claim the
// run can support. See the note at the violation branch for what printing it earlier said.
if gateConfigured && gateViolations.isEmpty && policyPath != nil {
    FileHandle.standardError.write("candor-swift: policy ✓\n".data(using: .utf8)!)
}

