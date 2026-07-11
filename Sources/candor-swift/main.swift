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

let engineVersion = "candor-swift-0.8.11"
// The bare release semver (`0.5.0`) — the ONE source of truth for both the envelope's build id above
// and `--version`, derived by stripping the engine prefix so the two can't drift.
let releaseVersion = engineVersion.replacingOccurrences(of: "candor-swift-", with: "")
// The spec contract version this engine speaks — the SAME literal that stamps the §2 envelope's `spec`
// field (see the envelope below), reused so `--version` and the report can never disagree.
let specVersion = "0.8"

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
    let pol = parsePolicy(polText)
    // Deterministic entry order: each list sorted by its serialized JSON (the reference engine's
    // byJson comparator) — the conformance differential normalizes anyway; this keeps raw dumps diffable.
    func sortedByJson(_ xs: [[String: Any]]) -> [[String: Any]] {
        func key(_ d: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return xs.sorted { key($0) < key($1) }
    }
    let polDict: [String: Any] = [
        "deny": sortedByJson(pol.deny.map { ["effects": $0.effects, "scope": $0.scope] }),
        "allow": sortedByJson(pol.allow.map { ["effect": $0.effect, "scope": $0.scope, "values": $0.values] }),
        "forbid": sortedByJson(pol.forbid.map { ["from": $0.from, "to": $0.to] }),
    ]
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

var target = "."
var outPrefix: String? = nil
var wantJson = false
var policyPath: String? = ProcessInfo.processInfo.environment["CANDOR_POLICY"]
var gateJsonPath: String? = nil
var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIter.next() {
    switch a {
    // A value-taking flag with no following value must FAIL, never silently take a nil: a trailing
    // `--policy` (e.g. `--policy $POL` where $POL expanded empty) would otherwise CLOBBER the
    // CANDOR_POLICY env gate with nil and exit 0 — the §6.2 'gateless green' state. exit 2.
    case "--out":
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --out requires a value\n".data(using: .utf8)!); exit(2)
        }
        outPrefix = v
    case "--json":
        // Print the §2 envelope to STDOUT instead of writing the report file(s)/sidecars (matching the
        // candor-scan reference). The §6.2 policy gate below STILL runs and keeps its exit codes —
        // `--json --policy p` prints the report AND exits 1 on a violation.
        wantJson = true
    case "--policy":
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --policy requires a value\n".data(using: .utf8)!); exit(2)
        }
        policyPath = v
    case "--gate-json":
        // The structured gate verdict target (candor-spec §3.3 ⟨0.8⟩). Valueless or flag-shaped fails
        // closed like --policy — but `-` (stream the verdict to stdout, the §3.3 pipe form the other
        // three engines accept) is valid; the old guard rejected it, a cross-engine divergence.
        guard let v = argIter.next(), v == "-" || !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --gate-json requires a value\n".data(using: .utf8)!); exit(2)
        }
        gateJsonPath = v
    case "-h", "--help":
        print("""
        candor-swift \(releaseVersion) — Swift effect scanner (candor-spec \(specVersion))

        USAGE: candor-swift [<dir|file.swift>] [--out <prefix>] [--json] [--policy <file>] [--gate-json <file>] [--agents] [--version]
               candor-swift parsepolicy <policy-file>     # dump the parsed §6.2 policy as canonical JSON (the conformance grammar-diff witness)

          <target>          a dir or a single .swift file to scan (default: .)
          --out <prefix>    write the report to <prefix>.<package>.Swift.json + a .callgraph.json sidecar
          --json            print the report as JSON to stdout (instead of writing files)
          --policy <file>   enforce a policy file (deny/pure/allow/forbid, candor-spec §6.2) — exit 1 on a violation, 2 if unreadable; honours $CANDOR_POLICY when the flag is absent
          --gate-json <f>   write the structured gate verdict { spec, ok, violations } as JSON (candor-spec §3.3)
          --agents          print the agent contract for this build (AGENTS.md)

        CANDOR_BASELINE=<report> (or a .candor/config `baseline` line) enables the AS-EFF-005 regression
        guard: an existing function GAINING an effect vs the saved report fails (exit 1); new functions are
        exempt; a corrupt or cross-build baseline refuses to evaluate (exit 2); an absent file is a note.
          -V, --version     print the build and spec version (offline)
          -h, --help        show this help

        See https://github.com/tombaldwin/candor
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
            exit(2)
        }
        target = a
    }
}

// (the §3.4 config layer lives in Config.swift)
let candorConfig = loadCandorConfig(targetPath: target)
// The --policy flag / CANDOR_POLICY env already populated policyPath; the config is the floor. A bare
// `policy` line ("" value) means configured-with-empty → the unreadable-policy path fails loud.
if policyPath == nil, let p = candorConfig["policy"] { policyPath = p }

let fm = FileManager.default
var isDir: ObjCBool = false
guard fm.fileExists(atPath: target, isDirectory: &isDir) else {
    FileHandle.standardError.write("candor-swift: no such path: \(target)\n".data(using: .utf8)!)
    exit(2)
}
let rootDir = isDir.boolValue ? target : (target as NSString).deletingLastPathComponent

var sourcePaths: [String] = []
if isDir.boolValue {
    if let en = fm.enumerator(atPath: target) {
        for case let rel as String in en {
            if rel.hasSuffix(".swift") && !isHarnessPath(rel) { sourcePaths.append((target as NSString).appendingPathComponent(rel)) }
        }
    }
} else {
    sourcePaths = [target]
}
sourcePaths.sort()
if sourcePaths.isEmpty {
    FileHandle.standardError.write("candor-swift: no Swift sources under \(target)\n".data(using: .utf8)!)
    exit(2)
}

// The package name — the first half of the §2 `hash` join key. Package.swift's name, else the dir.
var pkgName = (rootDir as NSString).lastPathComponent
if let manifest = try? String(contentsOfFile: (rootDir as NSString).appendingPathComponent("Package.swift"), encoding: .utf8),
   let r = manifest.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) {
    let m = String(manifest[r])
    if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
        pkgName = String(m[m.index(after: q1)..<q2])
    }
}

// (Pass A / Pass B collectors live in DeclCollector.swift / CallCollector.swift;
//  the two-pass drive lives in Driver.swift — called here.)

// Report chaining (SPEC §2, Deps.swift): CANDOR_DEPS overrides the config's `deps` key (the same
// env-over-config precedence as `policy`). Fail-closed loading — a bad token/report exits 2 HERE,
// before any analysis could silently read the dep as pure.
let depsSpec = ProcessInfo.processInfo.environment["CANDOR_DEPS"] ?? candorConfig["deps"]
let depsIndex = loadDepReports(spec: depsSpec, engineVersion: engineVersion)

let analysis = analyze(sourcePaths: sourcePaths, rootDir: rootDir, pkgName: pkgName, deps: depsIndex)
let allFns = analysis.allFns
let conformers = analysis.conformers
let importCounts = analysis.importCounts
let internalModules = analysis.internalModules
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

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Report (§2 envelope, spec 0.5) + sidecar (§2.2) + receipt + κ ledger (§7.14)
// ════════════════════════════════════════════════════════════════════════════════════════════════

let prefix = outPrefix ?? (rootDir as NSString).appendingPathComponent(".candor/report")

let accessorQuals = Set(allFns.filter { $0.isAccessor }.map { $0.qual })
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
    var ef = Effector(
        fn: qual, loc: locOf[qual] ?? "",
        inferred: EffectSet(names: inf), direct: EffectSet(names: direct[qual] ?? []),
        unresolved: inf.contains("Unknown"), hash: "\(pkgName)#\(qual)",
        calls: (edges[qual] ?? []).sorted())
    if entryPoints.contains(qual) { ef.entryPoint = true }
    if accessorQuals.contains(qual) { ef.unitKind = "accessor" }
    if let w = whyMap[qual], !w.isEmpty { ef.unknownWhy = w.sorted() }
    if let h = hostsAcc[qual], !h.isEmpty { ef.hosts = h.sorted() }
    if let c = cmdsAcc[qual], !c.isEmpty { ef.cmds = c.sorted() }
    if let p = pathsAcc[qual], !p.isEmpty { ef.paths = p.sorted() }
    if let t = tablesAcc[qual], !t.isEmpty, inf.contains("Db") { ef.tables = t.sorted() }
    if !invisible.isEmpty { ef.invisible = invisible }
    effectors.append(ef)
}
let report = Report(
    provenance: Provenance(version: engineVersion, toolchain: "swiftsyntax", spec: specVersion),
    package: pkgName, effectors: effectors)
let envelope: [String: Any] = report.toJSON()
var cg: [String: [String]] = [:]
for f in allFns { cg[f.qual] = (edges[f.qual] ?? []).sorted() }  // §2.2: EVERY analyzed fn a key

// Family filename shape `<prefix>.<pkg>.Swift.json` — what candor_report::report_files DISCOVERS,
// so the unmodified candor-query binary works on Swift reports (this engine's whole consumption
// story; caught by the first query-interop probe: `show` couldn't find a `<prefix>.json`). The
// pkg segment is dot-sanitized (`GRDB.swift` would otherwise split the <crate>.<kind> parse).
let fileSafePkg = pkgName.replacingOccurrences(of: ".", with: "-")
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
} else {
    // Create `.candor/` (or the --out parent) only on the file-writing path — --json is documented as
    // writing NO files, so it must not leave an empty directory behind as a side effect.
    try? fm.createDirectory(atPath: (prefix as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    writeJson(envelope, reportPath)
    writeJson(cg, "\(prefix).\(fileSafePkg).Swift.callgraph.json")
    // Type-hierarchy sidecar (SPEC §4 / 0.7): each local type -> its declared supertypes/protocols, by
    // INVERTING `conformers` (supertype -> subtypes, from pushType). Lets candor-query's dispatch-frontier
    // (callers --include-unknown) resolve whether a confirmed reacher overrides a `dispatch:` owner. Keyed by
    // the bare type name — matching this engine's `Type.member` fn quals + `dispatch:Type.member` reasons.
    var typeHierarchy: [String: [String]] = [:]
    for (sup, subs) in conformers {
        for sub in subs { typeHierarchy[sub, default: []].append(sup) }
    }
    for k in typeHierarchy.keys { typeHierarchy[k] = Array(Set(typeHierarchy[k]!)).sorted() }
    writeJson(typeHierarchy, "\(prefix).\(fileSafePkg).Swift.hierarchy.json")
    FileHandle.standardError.write(
        "candor-swift: wrote \(effectors.count) effectful functions (\(allFns.count) analyzed, \(sourcePaths.count) files) to \(reportPath)\n".data(using: .utf8)!)
    // Effect breakdown — make the result visible at a glance, not just a count + a file path.
    var counts: [String: Int] = [:]
    for e in effectors { for x in e.inferred.toNames() { counts[x, default: 0] += 1 } }
    let breakdown = ["Net", "Fs", "Db", "Exec", "Ipc", "Env", "Clipboard", "Clock", "Log", "Rand"]
        .filter { counts[$0] != nil }.map { "\($0) \(counts[$0]!)" }.joined(separator: " · ")
    let unknown = counts["Unknown"] ?? 0
    if !breakdown.isEmpty || unknown > 0 {
        let u = unknown > 0 ? "\(breakdown.isEmpty ? "" : "   ·   ")Unknown \(unknown) (disclosed)" : ""
        FileHandle.standardError.write("  \(breakdown)\(u)\n".data(using: .utf8)!)
    }
}

// the κ-coverage ledger: imported modules outside the platform frontier that κ doesn't know —
// INVISIBLE, not Unknown; named per scan (SPEC §7 item 14, canonical marker). A package a chained
// sibling report covers is EXEMPT (SPEC §2 rule 3) — including an all-pure dep's EMPTY report,
// whose silence is its purity claim, so the ledger must not name it a blind spot.
let unlisted = importCounts.filter { !PLATFORM_MODULES.contains($0.key) && !KAPPA_MODULES.contains($0.key) && !internalModules.contains($0.key) && !depsIndex.coveredPkgs.contains($0.key) }
    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
if !unlisted.isEmpty {
    let shown = unlisted.prefix(8).map { "\($0.key) (\($0.value) import\($0.value == 1 ? "" : "s"))" }.joined(separator: ", ")
    let more = unlisted.count > 8 ? " + \(unlisted.count - 8) more" : ""
    FileHandle.standardError.write(
        ("candor-swift: κ doesn't know \(unlisted.count) module\(unlisted.count == 1 ? "" : "s") this code imports — "
         + "effects through \(unlisted.count == 1 ? "it are" : "them are") INVISIBLE (not Unknown): \(shown)\(more)\n").data(using: .utf8)!)
}


// ════════════════════════════════════════════════════════════════════════════════════════════════
// §6.2 policy gate — parser in CandorCore/Policy.swift, execution in Gate.swift; the exit-code
// choreography (2 unreadable / 1 violation / 0 clean) stays here with the other process decisions.
// ════════════════════════════════════════════════════════════════════════════════════════════════

var gateViolations: [GateViolation] = []
// AS-EFF-005 baseline regression guard (SPEC §7 item 5, Baseline.swift) — checked FIRST, matching the
// reference engine's checker order (candor-java runs checkBaseline before checkPolicy). CANDOR_BASELINE
// env over the config `baseline` key (the same env-over-config precedence as `policy`; a relative
// config value was anchored to the config's home dir in Config.swift). May exit 2 (invalid gate input:
// unparseable / versionless / cross-build baseline); an ABSENT file is a note, guard inactive.
var baselinePath: String? = ProcessInfo.processInfo.environment["CANDOR_BASELINE"]
if baselinePath == nil, let b = candorConfig["baseline"] { baselinePath = b }
if let bp = baselinePath {
    gateViolations += checkBaseline(inferred: inferred, path: bp, engineVersion: engineVersion)
}
if let pp = policyPath {
    guard let text = try? String(contentsOfFile: pp, encoding: .utf8) else {
        FileHandle.standardError.write("candor-swift: policy \(pp) could not be read; gate NOT enforced\n".data(using: .utf8)!)
        exit(2)
    }
    gateViolations += evaluateGate(parsePolicy(text), inferred: inferred, hostsAcc: hostsAcc,
                                   cmdsAcc: cmdsAcc, pathsAcc: pathsAcc, tablesAcc: tablesAcc,
                                   incompleteAcc: incompleteAcc, cg: cg)
}
// Violation lines (baseline + policy) are diagnostics, not the report — route them to STDERR so
// `--json --policy p` keeps stdout a single clean JSON document (a violation line on stdout broke `… | jq`).
for v in gateViolations { FileHandle.standardError.write(("[\(v.rule)] \(v.detail)\n").data(using: .utf8)!) }
// --gate-json ⟨0.8⟩: the machine verdict, from the SAME gateViolations that set the exit code — written
// BEFORE the exit below (ok:true,[] when no gate is configured). Unreadable policy already exited 2 above;
// AS-EFF-005 records join the same list, so the verdict and the exit code can never disagree.
if let gp = gateJsonPath { writeGateVerdict(gateViolations, to: gp, spec: specVersion) }
if policyPath != nil || baselinePath != nil {
    if gateViolations.isEmpty {
        if policyPath != nil {
            FileHandle.standardError.write("candor-swift: policy ✓\n".data(using: .utf8)!)
        }
    } else {
        FileHandle.standardError.write("candor-swift: \(gateViolations.count) policy violation(s)\n".data(using: .utf8)!)
        exit(1)
    }
}
