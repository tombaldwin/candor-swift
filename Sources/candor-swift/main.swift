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

let engineVersion = "candor-swift-0.22.0"
// The bare release semver (`0.5.0`) — the ONE source of truth for both the envelope's build id above
// and `--version`, derived by stripping the engine prefix so the two can't drift.
let releaseVersion = engineVersion.replacingOccurrences(of: "candor-swift-", with: "")
// The spec contract version this engine speaks — the SAME literal that stamps the §2 envelope's `spec`
// field (see the envelope below), reused so `--version` and the report can never disagree.
let specVersion = "0.22"

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
    let pol = parsePolicy(polText, aliases: parseUnknownAliases(discoverConfigText(targetPath: polPath)))
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
        candor-swift — the Swift effect analyzer. SwiftSyntax-based, it scans source without building.

        A scan reads every .swift file, propagates effects through the call graph, and writes the
        report to .candor/. A call the analysis cannot resolve is Unknown, and an imported module
        the classifier doesn't cover is named INVISIBLE, per scan — the report never silently
        claims purity it can't see.

        USAGE
          candor-swift [<dir|file.swift>] [options]            scan Swift sources (default target: .)
          candor-swift <action> [args] [options]               query the discovered report (.candor/, walk-up)
          candor-swift privacy-manifest [--verify <plist>]     generate/verify the Apple privacy manifest
          candor-swift gains <current> <baseline>              effects gained between two reports
          candor-swift --agents                                print the agent contract for this build

        COMMON ACTIONS
          path <fn> <Effect>        the call chain by which a function reaches an effect
          tour [N]                  the N most surprising transitive reaches (default 10)
          gains <current> <base>    what a new version newly reaches — the supply-chain alarm
          fix <fn> <Effect>         the boundary hoist that would clear a violation
          fix-gate                  every policy crossing + its remedy
          unverified                pure/deny scopes that PASS but contain Unknown (--strict: exit 1)
          privacy-manifest          the Info.plist usage keys the sensor reach requires; --verify diffs one

        ALL ACTIONS
          path  tour  gains  fix  fix-gate  unverified  privacy-manifest  parsepolicy

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
if let manifest = try? String(contentsOfFile: (rootDir as NSString).appendingPathComponent("Package.swift"), encoding: .utf8) {
    if let r = manifest.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) {
        let m = String(manifest[r])
        if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
            pkgName = String(m[m.index(after: q1)..<q2])
        }
    }
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
// ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): the target source candor could NOT read/parse — rides the report
// (`unanalyzed`) + drives the fail-closed gate verdict + exit 2 below.
let unanalyzedUnits = analysis.unanalyzed
// ⟨0.20⟩ Net destination-class partners from `.candor/config` — read ONCE here, used by the report's per-fn
// `netClass` field (below) and the gate (deny Net[unknown-host]); the SAME set both surfaces resolve.
let netPartners = parseNetPartners(discoverConfigText(targetPath: target))

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
    if let t = tablesAcc[qual], !t.isEmpty, inf.contains("Db") { ef.tables = t.sorted() }
    if !invisible.isEmpty { ef.invisible = invisible }
    // ⟨0.20⟩ Net destination-class: the classes in this fn's transitive Net surface — exact host-literal
    // match, fail-closed unknown-host on a masked surface (incompleteAcc has Net) OR a Net with no visible host.
    if inf.contains("Net") {
        ef.netClass = netClassesOf(Array(hostsAcc[qual] ?? []),
                                   netIncomplete: incompleteAcc[qual]?.contains("Net") ?? false,
                                   partners: netPartners)
    }
    effectors.append(ef)
}
// the coverage ledger: imported modules outside the platform frontier that the classifier doesn't
// cover — INVISIBLE, not Unknown; named per scan (SPEC §7 item 14, canonical marker `classifier
// doesn't cover`). A package a chained
// sibling report covers is EXEMPT (SPEC §2 rule 3) — including an all-pure dep's EMPTY report,
// whose silence is its purity claim, so the ledger must not name it a blind spot.
// Computed HERE (before the envelope is built) because ⟨0.15 staged⟩ the same list rides the report
// as the `coverage` envelope field — one computation feeds the stderr line (printed below, after the
// receipt, keeping the disclosure order) AND the wire field, so they can never disagree.
let unlisted = importCounts.filter { !PLATFORM_MODULES.contains($0.key) && !KAPPA_MODULES.contains($0.key) && !internalModules.contains($0.key) && !depsIndex.coveredPkgs.contains($0.key) }
    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }

var report = Report(
    provenance: Provenance(version: engineVersion, toolchain: "swiftsyntax", spec: specVersion),
    package: pkgName, effectors: effectors)
report.coverage = unlisted.map { (name: $0.key, calls: $0.value) }   // ⟨0.15 staged⟩ SPEC §2 `coverage`
// ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 1): the analyzed universe = every analyzed fn incl. pure leaves =
// `allFns` (NOT the effectful-only `effectors`). count lets a bare-envelope consumer compute the pure
// count; digest = FNV-1a-64 over the SORTED analyzed quals (same-input re-scan agreement).
let analyzedQuals = allFns.map { $0.qual }.sorted()
report.analyzed = (count: allFns.count, digest: fnv1aHex(analyzedQuals))
report.unanalyzed = unanalyzedUnits   // ⟨0.21⟩ (Gap 2) omitted when empty by toJSON()
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
    let breakdown = ["Net", "Llm", "Fs", "Db", "Exec", "Ipc", "Env", "Clipboard", "Clock", "Log", "Rand",
                     // `privacy/1` SPEC EXTENSION — the Apple privacy-sensor effects (shown after the core set)
                     "Location", "Camera", "Mic", "Contacts", "Photos", "Notify"]
        .filter { counts[$0] != nil }.map { "\($0) \(counts[$0]!)" }.joined(separator: " · ")
    let unknown = counts["Unknown"] ?? 0
    if !breakdown.isEmpty || unknown > 0 {
        let u = unknown > 0 ? "\(breakdown.isEmpty ? "" : "   ·   ")Unknown \(unknown) (disclosed)" : ""
        FileHandle.standardError.write("  \(breakdown)\(u)\n".data(using: .utf8)!)
    }
}

// the coverage ledger's stderr line (the ledger itself is computed above, before the envelope,
// and ALSO rides the report as the ⟨0.15 staged⟩ `coverage` field — same list, same counts).
if !unlisted.isEmpty {
    let shown = unlisted.prefix(8).map { "\($0.key) (\($0.value) import\($0.value == 1 ? "" : "s"))" }.joined(separator: ", ")
    let more = unlisted.count > 8 ? " + \(unlisted.count - 8) more" : ""
    FileHandle.standardError.write(
        ("candor-swift: candor's classifier doesn't cover \(unlisted.count) module\(unlisted.count == 1 ? "" : "s") this code imports — "
         + "their effects are INVISIBLE to the scan (absent from the report, NOT a claim they're pure): \(shown)\(more)\n").data(using: .utf8)!)
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
// AS-EFF-005 baseline regression guard (SPEC §7 item 5, Baseline.swift) — checked FIRST, matching the
// reference engine's checker order (candor-java runs checkBaseline before checkPolicy). CANDOR_BASELINE
// env over the config `baseline` key (the same env-over-config precedence as `policy`; a relative
// config value was anchored to the config's home dir in Config.swift). May exit 2 (invalid gate input:
// unparseable / versionless / cross-build baseline); an ABSENT file is a note, guard inactive.
var baselinePath: String? = ProcessInfo.processInfo.environment["CANDOR_BASELINE"]
if baselinePath == nil, let b = candorConfig["baseline"] { baselinePath = b }
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
    gateViolations += checkBaseline(inferred: inferred, path: bp, engineVersion: engineVersion, unknownRatchet: unknownRatchet)
}
if let pp = policyPath {
    guard let text = try? String(contentsOfFile: pp, encoding: .utf8) else {
        FileHandle.standardError.write("candor-swift: policy \(pp) could not be read; gate NOT enforced\n".data(using: .utf8)!)
        exit(2)
    }
    // Reason-scoped Unknown (REASON-SCOPED-UNKNOWN-DESIGN.md): the Unknown reason CLASS must travel the
    // call graph the same way the Unknown EFFECT does (whyMap is direct-only). Classify each fn's direct
    // reasons to class tokens, then propagate transitively — so `deny E Unknown[reflect]` at a caller
    // inheriting Unknown from a reflect-caused callee still fires (matches java/rust/ts reasonClassAcc).
    var reasonClassDirect: [String: Set<String>] = [:]
    for (fn, whys) in whyMap where !whys.isEmpty {
        reasonClassDirect[fn] = Set(whys.map { reasonClass($0) })
    }
    let reasonClassAcc = propagate(reasonClassDirect, over: edges)
    // ⟨0.19⟩ reason-class aliases (SPEC §6.2) from `.candor/config`, so `Unknown[<alias>]` resolves at the gate.
    let unknownAliases = parseUnknownAliases(discoverConfigText(targetPath: target))
    // ⟨0.20⟩ `net-partner` hosts (NET-DESTINATION-CLASS-DESIGN.md): the SAME set the report netClass used
    // (hoisted above), so `deny Net[unknown-host]` tolerates a declared partner and the verdict classifies it.
    gateViolations += evaluateGate(parsePolicy(text, aliases: unknownAliases), inferred: inferred, hostsAcc: hostsAcc,
                                   cmdsAcc: cmdsAcc, pathsAcc: pathsAcc, tablesAcc: tablesAcc,
                                   incompleteAcc: incompleteAcc, cg: cg, reasonClassAcc: reasonClassAcc,
                                   netPartners: netPartners)
    // Provable-purity DISCLOSURE (advisory — NEVER a violation, so the exit/verdict are untouched): functions
    // in a pure/deny scope that PASS but are Unknown (the Unknown could hide the forbidden effect — a
    // fn/closure-injected port). Surfaces the gap automatically (eval/fixloop/DISPATCH-NOTE.md).
    // Same predicate + upgrade as `candor-swift unverified` (CandorCore.unverifiedHoleRule) — one source of truth.
    let disclosePolicy = parsePolicy(text, aliases: unknownAliases)
    var purityHoles: [(String, String)] = []
    for qual in inferred.keys.sorted() {
        if let r = unverifiedHoleRule(qual, inferred[qual] ?? [], disclosePolicy.deny) {
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
if let gp = gateJsonPath { writeGateVerdict(gateViolations, to: gp, spec: specVersion, analyzedCount: allFns.count, unanalyzed: unanalyzedUnits, coverage: unlisted.map(\.key)) }   // ⟨0.15 staged⟩ advisory, verdict-preserving; ⟨0.21⟩ analyzed + fail-closed unanalyzed
let gateConfigured = policyPath != nil || baselinePath != nil
if gateConfigured {
    if gateViolations.isEmpty {
        if policyPath != nil {
            FileHandle.standardError.write("candor-swift: policy ✓\n".data(using: .utf8)!)
        }
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
