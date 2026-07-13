import CandorCore
import Foundation

// The `fix` / `fix-gate` subcommands (integrations/FIX-SPEC.md). candor-swift is scan-first, but these are a
// read-only query over what a scan already wrote — they load the §2 report + its §2.2 callgraph sidecar from
// a prefix and compute the boundary remedy (the pure algorithm lives in CandorCore/Fix.swift). JSON output,
// like the rest of candor-swift's machine surface; a policy is required (the fix is defined relative to the
// boundary it crosses), fail-loud (exit 2) on an unreadable/absent policy or a missing report — never a
// silently-empty answer.

private func fixDie(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

private func emitJSON(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: data, encoding: .utf8) else {
        fixDie("candor-swift: could not serialize the fix result")
    }
    print(s)
}

// Parse one `functions`-envelope report file into `byName`. Returns false (with a stderr note) on an
// unparseable / non-report file — the caller FAILS LOUD, never reads it as an empty "no crossings".
private func mergeFixReport(_ full: String, into byName: inout [String: FixFn], who: String) -> Bool {
    let fm = FileManager.default
    guard let data = fm.contents(atPath: full),
          let root = try? JSONSerialization.jsonObject(with: data),
          let obj = root as? [String: Any],
          let fns = obj["functions"] as? [[String: Any]] else {
        FileHandle.standardError.write("candor-swift \(who): report `\(full)` could not be parsed — OMITTED.\n".data(using: .utf8)!)
        return false
    }
    for e in fns {
        guard let fn = e["fn"] as? String, !fn.isEmpty else { continue }
        let inferred = Set((e["inferred"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let direct = Set((e["direct"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let calls = (e["calls"] as? [Any])?.compactMap { $0 as? String } ?? []
        let loc = e["loc"] as? String ?? ""
        byName[fn] = FixFn(inferred: inferred, direct: direct, calls: calls, loc: loc)
    }
    return true
}

// Merge one `.callgraph.json` sidecar into `cg`. A PRESENT but corrupt/unreadable sidecar silently
// shrinks the call graph — so tour/fix under-report reaches whose edges lived in the dropped file, and a
// gate can go false-GREEN. Mirror Rust's `load_callgraph`: disclose on stderr when a sidecar that EXISTS
// fails to read or parse (a genuinely MISSING sidecar is NOT passed here — that silent fallback is fine).
private func mergeCallgraph(_ full: String, into cg: inout [String: [String]]) {
    guard let data = FileManager.default.contents(atPath: full) else {
        FileHandle.standardError.write(
            "candor-swift: callgraph `\(full)` could not be read — its edges are OMITTED, so the call graph may be incomplete (tour/fix under-report)\n"
                .data(using: .utf8)!)
        return
    }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        FileHandle.standardError.write(
            "candor-swift: callgraph `\(full)` failed to parse — its edges are OMITTED, so the call graph may be incomplete (corrupt or mid-write); re-run the scan\n"
                .data(using: .utf8)!)
        return
    }
    for (k, v) in obj { cg[k] = (v as? [Any])?.compactMap { $0 as? String } ?? [] }
}

// Load every `<prefix>*.Swift.json` report (merging siblings) + the `.callgraph.json` sidecars for the graph.
// Returns nil if no report file is found for the prefix (the caller fails loud).
//
// A `prefix` that is ITSELF an existing regular `.json` file is loaded DIRECTLY as that one report (§3.3.1:
// "a path ending .json → that single report file loaded directly, any .json file, whatever its internal
// dot-segments") — so one engine can query another engine's report by its exact path, even when the filename
// does not fit the `<prefix>.<pkg>.Swift.json` family shape. A matching `.callgraph.json` sibling (same stem)
// is still picked up for the graph if present.
private func loadFixModel(prefix: String) -> (byName: [String: FixFn], cg: [String: [String]])? {
    let fm = FileManager.default
    var byName: [String: FixFn] = [:]
    var cg: [String: [String]] = [:]
    var foundReport = false

    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        // Direct single-file load (any `.json` filename).
        foundReport = mergeFixReport(prefix, into: &byName, who: "fix")
        let stem = (prefix as NSString).deletingPathExtension
        let sidecar = stem + ".callgraph.json"
        if fm.fileExists(atPath: sidecar) { mergeCallgraph(sidecar, into: &cg) }
        guard foundReport else { return nil }
        if cg.isEmpty { for (fn, f) in byName { cg[fn] = f.calls } }
        return (byName, cg)
    }

    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

    for name in entries.sorted() where name.hasPrefix(base + ".") {
        let full = dir + "/" + name
        if name.hasSuffix(".Swift.callgraph.json") {
            mergeCallgraph(full, into: &cg)
        } else if name.hasSuffix(".Swift.json") {
            // A report file present but unparseable (truncated / mid-write / not a report) FAILS LOUD;
            // `foundReport` flips true only after a successful parse, so a lone corrupt report leaves it
            // false → loadFixModel returns nil → exit 2.
            if mergeFixReport(full, into: &byName, who: "fix") { foundReport = true }
        }
    }
    guard foundReport else { return nil }
    // The callgraph sidecar is the graph of record; if it is absent (an older/`--json`-only report), fall
    // back to the report's own inline `calls` so a prefix that has only the envelope still answers.
    if cg.isEmpty { for (fn, f) in byName { cg[fn] = f.calls } }
    return (byName, cg)
}

private func loadDenyOrDie(_ policyPath: String, who: String) -> [DenyRule] {
    guard let text = try? String(contentsOfFile: policyPath, encoding: .utf8) else {
        fixDie("candor-swift \(who): policy `\(policyPath)` could not be read — no fix computed")
    }
    return parsePolicy(text).deny
}

// ── §3.3.1 canonical query grammar (0.10) ──────────────────────────────────────────────────────────
// The three exposed query verbs (fix / fix-gate / unverified) are driven the canonical way: the report
// is DISCOVERED by default, `--report <locator>` overrides with the one 3-way locator rule, `--policy`
// is a flag (never a positional), `--json` selects JSON, `--strict` guards `unverified`. The prior
// positional forms (a leading report prefix, a positional policy) stay accepted as DEPRECATED aliases
// with a one-line stderr note — the conformance suite still drives them positionally. Shared here so all
// three verbs resolve the report + policy identically.

// Emit the one-line deprecation note to STDERR (stdout stays pure JSON). Called at most once per
// invocation from parseQueryArgs, which passes the combined "what" so it is genuinely one line.
private func noteDeprecated(_ what: String) {
    FileHandle.standardError.write(
        ("candor-swift: note — \(what) is a DEPRECATED positional form; use the flag grammar "
         + "(--report <locator> --policy <file>). The positional form is removed at the next breaking bump.\n")
            .data(using: .utf8)!)
}

// Resolve a `--report <locator>` value to the PREFIX the report loaders consume, by the ONE shared rule
// (§3.3.1): a directory → `<dir>/.candor/report`; a path ending `.json` → that full report path (reduced
// to its prefix — see below); otherwise a bare prefix. The Swift loaders index sibling reports by a
// prefix (`<prefix>.<pkg>.Swift[.<sidecar>].json`), so a full `.json` path is normalized back to the
// `<prefix>` by stripping the trailing `.<pkg>.Swift.json` (or `.callgraph.json`/`.hierarchy.json`).
private func resolveReportLocator(_ locator: String) -> String {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: locator, isDirectory: &isDir), isDir.boolValue {
        return (locator as NSString).appendingPathComponent(".candor/report")
    }
    if locator.hasSuffix(".json") {
        // Strip a known report/sidecar suffix to recover the prefix the loaders scan for. The family
        // filename shape is `<prefix>.<pkg>.Swift.json` (+ `.callgraph`/`.hierarchy` sidecars); drop the
        // `.<pkg>.Swift.json` tail (three trailing dot-segments, four for a sidecar). Fall back to the
        // raw value if it does not match the shape (a plain prefix that happens to end `.json`).
        var s = locator as NSString
        for sidecar in [".callgraph", ".hierarchy"] where (s as String).hasSuffix("\(sidecar).json") {
            s = (s as String).replacingOccurrences(of: "\(sidecar).json", with: ".json") as NSString
        }
        if (s as String).hasSuffix(".Swift.json") {
            // <prefix>.<pkg>.Swift.json → drop `.<pkg>.Swift.json` = 3 path extensions.
            var p = s.deletingPathExtension            // drop .json  → <prefix>.<pkg>.Swift
            p = (p as NSString).deletingPathExtension   // drop .Swift → <prefix>.<pkg>
            p = (p as NSString).deletingPathExtension   // drop .<pkg> → <prefix>
            return p
        }
        return locator
    }
    return locator
}

// Does `tok` resolve to an EXISTING report (a `.json` file, or a dir/prefix with a matching sibling
// report)? Used ONLY to tell the DEPRECATED leading-positional report apart from a canonical first
// positional (fix's <fn>): `fix <report.json> <fn> <Effect> <policy>` (old) vs `fix <fn> <Effect> <policy>`
// (canonical, report discovered). A QUIET probe — it must not emit the not-found chatter, so a canonical
// first positional (a fn substring) simply reads as "not a report". Mirrors candor-java's `looksLikeReport`
// so the surplus-1 trailing-policy case (`fix doNet Net policy.txt`) parses identically in both engines.
private func looksLikeReport(_ tok: String) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if tok.hasSuffix(".json") {
        return fm.fileExists(atPath: tok, isDirectory: &isDir) && !isDir.boolValue
    }
    if fm.fileExists(atPath: tok, isDirectory: &isDir), isDir.boolValue {
        return quietPrefixMatches((tok as NSString).appendingPathComponent(".candor/report"))
    }
    return quietPrefixMatches(tok)
}

// True iff a `<prefix>.<pkg>.Swift.json` sibling report exists, WITHOUT the loader's stderr chatter.
private func quietPrefixMatches(_ prefix: String) -> Bool {
    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
    return entries.contains { n in
        n.hasPrefix(base + ".") && n.hasSuffix(".Swift.json")
            && !n.hasSuffix(".callgraph.json") && !n.hasSuffix(".hierarchy.json")
    }
}

// Discover the report prefix when no --report is given: CANDOR_REPORT overrides; otherwise walk UP from
// the CWD for a `.candor/` directory and use `<that>/.candor/report` as the prefix (§3.4 discovery,
// mirroring Config.swift's ancestor walk). Returns nil if neither is found (the caller fails loud).
private func discoverReportPrefix() -> String? {
    if let env = ProcessInfo.processInfo.environment["CANDOR_REPORT"], !env.isEmpty {
        return resolveReportLocator(env)
    }
    var dir = (URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path as NSString).standardizingPath
    for _ in 0..<64 {
        let cand = (dir as NSString).appendingPathComponent(".candor")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cand, isDirectory: &isDir), isDir.boolValue {
            return (cand as NSString).appendingPathComponent("report")
        }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir || parent.isEmpty { break }
        dir = parent
    }
    return nil
}

// Policy fallback when --policy is absent (mirrors the scan surface): CANDOR_POLICY env, then the
// discovered .candor/config `policy` key (CWD-anchored — the query has no scan target). Returns nil if
// neither is set (the caller fails loud, as fix requires a policy to define the boundary it crosses).
private func discoverPolicy() -> String? {
    if let env = ProcessInfo.processInfo.environment["CANDOR_POLICY"], !env.isEmpty { return env }
    let cfg = loadCandorConfig(targetPath: ".")
    if let p = cfg["policy"], !p.isEmpty { return p }
    return nil
}

// The parsed canonical invocation shared by all three verbs. `verbArgs` are the leading positionals
// (fix's <fn> <Effect>); report/policy are resolved (flag → discovery); strict/json are the flags.
private struct QueryArgs {
    var verbArgs: [String] = []
    var report: String?   // resolved report prefix/path (nil ⇒ discovery failed, caller fails loud)
    var policy: String?   // resolved policy path (nil ⇒ none configured)
    var strict = false
    var json = false
}

// Parse the canonical grammar for a query verb, accepting the deprecated positional aliases.
//   canonical:  <verb> <verbArgs…> [--report <loc>] [--policy <file>] [--json] [--strict]
//   deprecated: <verb> <prefix> <verbArgs…> <policy> [--strict]   (leading-positional report + positional policy)
// `expectedVerbArgs` is how many leading positionals the verb takes AFTER the report (fix: 2, else 0).
// Extra trailing positionals map to the deprecated leading-report then positional-policy, in that order.
private func parseQueryArgs(_ args: [String], expectedVerbArgs: Int) -> QueryArgs {
    var q = QueryArgs()
    var reportFlag: String?
    var policyFlag: String?
    var positionals: [String] = []
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": q.json = true
        case "--strict": q.strict = true
        case "--report":
            // Consume the NEXT token as the value unconditionally (mirrors candor-java) so a file whose
            // name begins with `-` (e.g. `-p.json`) can be passed. Only a genuinely absent value (the flag
            // is the last token) is the exit-2 error — never a silent fall-back to discovery (§3.3.1).
            guard let v = it.next() else { fixDie("candor-swift: --report requires a value") }
            reportFlag = v
        case "--policy":
            guard let v = it.next() else { fixDie("candor-swift: --policy requires a value") }
            policyFlag = v
        default:
            if a.hasPrefix("-") { fixDie("candor-swift: unknown flag \(a)") }
            positionals.append(a)
        }
    }

    // The verb's own positional args (fix's <fn> <Effect>) always come FIRST when supplied via flags.
    // In the deprecated form a leading report positional precedes them; the trailing positional is a policy.
    // Layout of `positionals` in the deprecated form: [<report>] <verbArgs…> [<policy>].
    //
    // ARITY-GATED, CONTENT-GATED peel (§3.3.1, aligned with candor-java):
    //   • The FIRST positional is claimed as the deprecated leading report ONLY when it actually resolves
    //     to a report (a dir, a `.json` file, or a prefix with sibling reports) — never a bare probe on
    //     count. So `fix <report.json> <fn> <Effect> <policy>` peels the report; `fix doNet Net policy.txt`
    //     leaves `doNet` as the fn and DISCOVERS the report. Ambiguity resolves toward the canonical
    //     (discovering) reading, never toward a silent misparse.
    //   • After that peel, any positional BEYOND the verb's canonical arity is the deprecated trailing
    //     policy. This is the surplus that distinguishes `fix doNet Net policy.txt` (surplus 1 → policy)
    //     from `fix doNet Net` (no surplus → discovered policy).
    var pos = positionals
    var deprecatedReport: String?
    var deprecatedPolicy: String?

    if reportFlag == nil, let first = pos.first, looksLikeReport(first) {
        // A leading positional that resolves to a report ⇒ deprecated leading-report. Consume it.
        deprecatedReport = pos.removeFirst()
    }
    // Take the verb's positional args off the front.
    if pos.count >= expectedVerbArgs {
        q.verbArgs = Array(pos.prefix(expectedVerbArgs))
        pos.removeFirst(expectedVerbArgs)
    } else {
        q.verbArgs = pos
        pos = []
    }
    // Any remaining trailing positional (a surplus beyond the verb's arity) is the deprecated policy.
    if policyFlag == nil, let last = pos.first { deprecatedPolicy = last }

    switch (deprecatedReport != nil, deprecatedPolicy != nil) {
    case (true, true):  noteDeprecated("a leading report prefix and a positional policy file")
    case (true, false): noteDeprecated("a leading report prefix")
    case (false, true): noteDeprecated("a positional policy file")
    case (false, false): break
    }

    // Resolve the report: --report flag → deprecated leading positional → discovery.
    if let r = reportFlag {
        q.report = resolveReportLocator(r)
    } else if let r = deprecatedReport {
        q.report = resolveReportLocator(r)
    } else {
        q.report = discoverReportPrefix()
    }
    // Resolve the policy: --policy flag → deprecated positional → CANDOR_POLICY / .candor/config.
    if let p = policyFlag {
        q.policy = p
    } else if let p = deprecatedPolicy {
        q.policy = p
    } else {
        q.policy = discoverPolicy()
    }
    return q
}

// Parse one `functions`-envelope report file into `out` for the `unverified` check. Returns false (with a
// stderr note) on an unparseable / non-report file — the caller fails loud, never an empty "no holes".
private func mergeUnverifiedReport(_ full: String, into out: inout [UnverifiedFn]) -> Bool {
    guard let data = FileManager.default.contents(atPath: full),
          let root = try? JSONSerialization.jsonObject(with: data),
          let obj = root as? [String: Any],
          let fns = obj["functions"] as? [[String: Any]] else {
        FileHandle.standardError.write("candor-swift unverified: report `\(full)` could not be parsed — OMITTED.\n".data(using: .utf8)!)
        return false
    }
    for e in fns {
        guard let fn = e["fn"] as? String, !fn.isEmpty else { continue }
        let inferred = Set((e["inferred"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let why = (e["unknownWhy"] as? [Any])?.compactMap { $0 as? String } ?? []
        out.append(UnverifiedFn(fn: fn, inferred: inferred, unknownWhy: why))
    }
    return true
}

// Load (fn, inferred, unknownWhy) from every `<prefix>*.Swift.json` report for the `unverified` check. As in
// loadFixModel, a `prefix` that is itself an existing regular `.json` file is loaded DIRECTLY (§3.3.1).
private func loadUnverifiedFns(prefix: String) -> [UnverifiedFn]? {
    let fm = FileManager.default
    var out: [UnverifiedFn] = []
    var found = false

    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        found = mergeUnverifiedReport(prefix, into: &out)
        return found ? out : nil
    }

    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    for name in entries.sorted() where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.json") {
        if mergeUnverifiedReport(dir + "/" + name, into: &out) { found = true }
    }
    return found ? out : nil
}

// Dispatched from main.swift when argv[1] is `unverified`. §3.3.1 canonical grammar:
//   candor-swift unverified [--report <loc>] [--policy <file>] [--json] [--strict]
// (deprecated: `unverified <prefix> <policy> [--strict]`). JSON-only surface; `--strict` → exit 1 on a hole.
func runUnverifiedCLI(_ args: [String]) -> Never {
    let q = parseQueryArgs(args, expectedVerbArgs: 0)
    guard let policy = q.policy else {
        fixDie("usage: candor-swift unverified [--report <locator>] --policy <file> [--json] [--strict]")
    }
    guard let prefix = q.report else {
        fixDie("candor-swift unverified: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
    }
    let deny = loadDenyOrDie(policy, who: "unverified")
    guard let fns = loadUnverifiedFns(prefix: prefix) else {
        fixDie("candor-swift unverified: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
    }
    let (ok, holes) = unverified(fns, deny)
    emitJSON(["ok": ok, "unverified": holes.map { $0.toJSON() }])
    exit(q.strict && !ok ? 1 : 0)
}

// Dispatched from main.swift when argv[1] is `tour` (before the scan flag loop). §3.3.1 canonical grammar,
// like fix-gate but with an OPTIONAL positional integer N (default 10):
//   candor-swift tour [<N>] [--report <locator>] [--json]
// Read-only: lists the N most SURPRISING transitive reaches in an existing report — NO re-scan. Delegates to
// the SHARED CandorCore.bestFinds (the same heuristic the scan-note uses, so the ranking can't drift),
// reading the §2 report + its §2.2 callgraph sidecar the scan already wrote. Fails LOUD (exit 2) if no
// report resolves. Matches the Rust reference `candor-query tour` byte-for-byte (a conformance PART pins
// this four-way).
// The parsed `tour` invocation. Unlike the fix/fix-gate/unverified grammar (parseQueryArgs), `tour` has
// NO deprecated leading-report positional and NO policy: the single optional positional is N, and the
// report comes ONLY from --report/discovery. Kept separate so `tour <report.json>` can never be silently
// mis-read as a leading report with N defaulting to 10 — it is a non-integer positional → exit 2.
private struct TourArgs {
    var positional: String?   // the raw first positional (validated as N by the caller)
    var report: String?       // resolved report prefix/path (nil ⇒ discovery failed, caller fails loud)
    var json = false
}

// Parse `tour [<N>] [--report <locator>] [--json]`. Every positional is N (the caller validates it as a
// positive integer). A second positional, or `--policy`/`--strict`, is a usage error (exit 2) — `tour`
// takes neither. Mirrors the Rust reference: report from --report/discovery, N is the lone positional.
private func parseTourArgs(_ args: [String]) -> TourArgs {
    var t = TourArgs()
    var reportFlag: String?
    var positionals: [String] = []
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": t.json = true
        case "--report":
            guard let v = it.next() else { fixDie("candor-swift: --report requires a value") }
            reportFlag = v
        default:
            if a.hasPrefix("-") { fixDie("candor-swift: unknown flag \(a)") }
            positionals.append(a)
        }
    }
    // At most ONE positional (N). A surplus positional is a usage error — never peeled as a report.
    if positionals.count > 1 {
        fixDie("usage: candor-swift tour [<N>] [--report <locator>] [--json]   (N is a positive integer ≥ 1)")
    }
    t.positional = positionals.first
    // Resolve the report: --report flag → discovery. NO positional report (tour's grammar divergence).
    t.report = reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()
    return t
}

// The report's `package` name (the §2 envelope field), or nil if absent/unreadable — the tour header
// prefers it (meaningful, locator-independent) over the prefix basename. Mirrors Rust's `report_package`:
// read the FIRST matching report for the prefix and return its non-empty `package`. A `packages` PLURAL
// envelope (the JVM shape, SPEC §2) is honoured too: one entry names it verbatim; several name their
// longest common dotted prefix (`com.a.x` + `com.a.y` → `com.a`); none shared → nil (basename fallback).
// Accepts a direct `.json` locator or a `<prefix>.<pkg>.Swift.json` family prefix.
private func reportPackage(prefix: String) -> String? {
    let fm = FileManager.default
    func packageOf(_ path: String) -> String? {
        guard let data = fm.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let pkg = obj["package"] as? String, !pkg.isEmpty { return pkg }
        if let pkgs = obj["packages"] as? [Any] {
            return packagesLabel(pkgs.compactMap { $0 as? String }.filter { !$0.isEmpty })
        }
        return nil
    }
    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        return packageOf(prefix)
    }
    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    for name in entries.sorted()
    where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.json")
        && !name.hasSuffix(".callgraph.json") && !name.hasSuffix(".hierarchy.json") {
        if let pkg = packageOf(dir + "/" + name) { return pkg }
    }
    return nil
}

// The longest common dot-separated prefix of a plural `packages` list — whole segments only (`com.ab` +
// `com.ac` share `com`, not `com.a`); nil when nothing is shared. Mirrors Rust's packages_label (tour.rs).
private func packagesLabel(_ pkgs: [String]) -> String? {
    guard let head = pkgs.first else { return nil }
    if pkgs.count == 1 { return head }
    let first = head.split(separator: ".", omittingEmptySubsequences: false)
    var n = first.count
    for p in pkgs.dropFirst() {
        let segs = p.split(separator: ".", omittingEmptySubsequences: false)
        var i = 0
        while i < min(n, segs.count) && segs[i] == first[i] { i += 1 }
        n = i
        if n == 0 { return nil } // nothing shared — the basename fallback is more honest
    }
    return first[0..<n].joined(separator: ".")
}

func runTourCLI(_ args: [String]) -> Never {
    // §3.3.1 grammar for `tour`: the single optional positional is N (how many to list), and EVERY
    // positional is treated as N — there is NO deprecated leading-report positional (that is `tour`'s
    // grammar divergence from fix/fix-gate). A non-integer positional (INCLUDING a report path) or N < 1
    // is a usage error (exit 2). N must be a positive integer ≥ 1: `tour 0` would otherwise print a false
    // "nothing hidden" all-clear over an effectful crate (the §4 cardinal sin). The report comes ONLY from
    // `--report`/discovery. Matches the Rust reference `candor-query tour` byte-for-byte.
    let t = parseTourArgs(args)
    var n = 10
    if let first = t.positional {
        guard let v = Int(first), v >= 1 else {
            fixDie("usage: candor-swift tour [<N>] [--report <locator>] [--json]   (N is a positive integer ≥ 1)")
        }
        n = v
    }
    guard let prefix = t.report else {
        fixDie("candor-swift tour: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
    }
    // Load the report + callgraph the same way fix/fix-gate do (fail loud on a missing/typo'd report).
    guard let model = loadFixModel(prefix: prefix) else {
        fixDie("candor-swift tour: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
    }

    // Build the maps the heuristic wants from the report entries + the callgraph sidecar. `inferred`/`direct`/
    // `loc` come from the report; `calls` prefers the callgraph sidecar (loadFixModel already falls back to the
    // report's inline `calls` when the sidecar is absent), which records EVERY edge like the scan held in memory.
    var inferred: [String: Set<String>] = [:]
    var direct: [String: Set<String>] = [:]
    var loc: [String: String] = [:]
    for (fn, f) in model.byName {
        inferred[fn] = f.inferred
        if !f.direct.isEmpty { direct[fn] = f.direct }
        if !f.loc.isEmpty { loc[fn] = f.loc }
    }
    var calls: [String: Set<String>] = [:]
    for (k, v) in model.cg { calls[k] = Set(v) }

    let finds = bestFinds(inferred: inferred, direct: direct, calls: calls, loc: loc, n: n)

    // The header names the report's PACKAGE (the §2 envelope field) — meaningful and locator-independent,
    // so every engine and every --report form print the same crate (Rust: `report_package(pre)`). Falls
    // back to the prefix basename (Rust: `prefix_base(pre)`) — e.g. `.candor/report` → `report`.
    let crateName = reportPackage(prefix: prefix) ?? (prefix as NSString).lastPathComponent

    if t.json {
        // Pure JSON to stdout: {"reaches":[{"fn","effect","hops","source","loc","score"}, …]}.
        let reaches: [[String: Any]] = finds.map { f in
            ["fn": f.func_, "effect": f.effect, "hops": f.hops,
             "source": f.source, "loc": f.sourceLoc, "score": f.score]
        }
        emitTourJSON(["reaches": reaches])
        exit(0)
    }

    if finds.isEmpty {
        // Effectful-but-nothing-surprising vs genuinely-pure both land here; either way the honest line is
        // the useful answer (never a manufactured surprise) — mirrors the scan-note fallback.
        print("candor: nothing hidden — every effect sits where its name says it should.")
        exit(0)
    }
    let reachWord = finds.count == 1 ? "reach" : "reaches"
    print("candor tour — the \(finds.count) most surprising \(reachWord) in \(crateName):")
    for (i, f) in finds.enumerated() {
        let hopWord = f.hops == 1 ? "hop" : "hops"
        let whereS = f.sourceLoc.isEmpty ? "" : " (\(f.sourceLoc))"
        print("  \(i + 1). `\(f.func_)` performs \(f.effect), \(f.hops) \(hopWord) away via `\(f.source)`\(whereS)")
        print("     →  candor path \(f.func_) \(f.effect)")
    }
    exit(0)
}

// Serialize the tour `--json` payload to STDOUT as COMPACT JSON (one line), matching the Rust reference's
// `serde_json::to_string(&json!({ "reaches": … }))` BYTE-FOR-BYTE. The reference wraps the reaches in a
// `serde_json::Value`, whose object is a sorted map, so each reach's keys come out ALPHABETICALLY sorted:
// effect, fn, hops, loc, score, source. Built by hand (JSONSerialization neither guarantees key order nor a
// compact form), so this is emitted explicitly rather than via JSONSerialization.
private func emitTourJSON(_ obj: [String: Any]) {
    guard let reaches = obj["reaches"] as? [[String: Any]] else { fixDie("candor-swift tour: internal serialize error") }
    func jstr(_ s: String) -> String {
        // Minimal JSON string escaping (the fields are qualified names / effects / file:line — no control
        // chars in practice, but escape the JSON-significant characters for correctness).
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }
    var parts: [String] = []
    for r in reaches {
        let fn = r["fn"] as? String ?? ""
        let effect = r["effect"] as? String ?? ""
        let hops = r["hops"] as? Int ?? 0
        let source = r["source"] as? String ?? ""
        let loc = r["loc"] as? String ?? ""
        let score = r["score"] as? Int ?? 0
        // Keys ALPHABETICAL to match serde_json::Value's sorted-map output: effect, fn, hops, loc, score, source.
        parts.append("{\"effect\":\(jstr(effect)),\"fn\":\(jstr(fn)),\"hops\":\(hops),\"loc\":\(jstr(loc)),\"score\":\(score),\"source\":\(jstr(source))}")
    }
    print("{\"reaches\":[\(parts.joined(separator: ","))]}")
}

// Dispatched from main.swift when argv[1] is `fix` or `fix-gate` (before the scan flag loop). §3.3.1:
//   candor-swift fix <fn> <Effect> [--report <loc>] [--policy <file>] [--json]
//   candor-swift fix-gate          [--report <loc>] [--policy <file>] [--json]
// (deprecated: `fix <prefix> <fn> <Effect> <policy>`, `fix-gate <prefix> <policy>`).
func runFixCLI(_ args: [String]) -> Never {
    let cmd = args[1]
    if cmd == "fix" {
        let q = parseQueryArgs(args, expectedVerbArgs: 2)
        guard q.verbArgs.count == 2 else {
            fixDie("usage: candor-swift fix <fn> <Effect> [--report <locator>] --policy <file> [--json]")
        }
        let (target, effect) = (q.verbArgs[0], q.verbArgs[1])
        guard let policy = q.policy else {
            fixDie("usage: candor-swift fix <fn> <Effect> [--report <locator>] --policy <file> [--json]")
        }
        guard let prefix = q.report else {
            fixDie("candor-swift fix: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
        }
        let deny = loadDenyOrDie(policy, who: "fix")
        guard let model = loadFixModel(prefix: prefix) else {
            fixDie("candor-swift fix: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
        }
        switch fix(target: target, effect: effect, byName: model.byName, cg: model.cg, deny: deny) {
        case .noSuchFn:
            fixDie("candor-swift fix: no function matching `\(target)`")
        case let .notACrossing(fn, eff, reason):
            emitJSON(["fn": fn, "effect": eff, "crossing": false, "reason": reason])
            exit(0)
        case let .remedy(r):
            var out = r.toJSON()
            out["crossing"] = true
            emitJSON(out)
            exit(0)
        }
    } else { // fix-gate
        let q = parseQueryArgs(args, expectedVerbArgs: 0)
        guard let policy = q.policy else {
            fixDie("usage: candor-swift fix-gate [--report <locator>] --policy <file> [--json]")
        }
        guard let prefix = q.report else {
            fixDie("candor-swift fix-gate: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
        }
        let deny = loadDenyOrDie(policy, who: "fix-gate")
        guard let model = loadFixModel(prefix: prefix) else {
            fixDie("candor-swift fix-gate: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
        }
        let (ok, remedies) = fixGate(byName: model.byName, cg: model.cg, deny: deny)
        emitJSON(["ok": ok, "remedies": remedies.map { $0.toJSON() }])
        exit(0)
    }
}

// ── `path <fn> <Effect>` (SPEC §3.1) ────────────────────────────────────────────────────────────────
// The read-only query the scan-note / `tour` opener names as its ready-to-run follow-up: trace the call
// chain by which `<fn>` comes to perform `<Effect>`, from the function down to the nearest DIRECT source.
// NO policy — it is a pure structural read over the report graph. Report from --report/discovery, `--json`
// for the §3.1 pinned shape. Byte-for-byte the Rust reference `candor-query path` (callers.rs::cmd_path),
// which conformance PART 5 pins four-way. Fails LOUD (exit 2) on a missing report / an unmatched fn.

// The parsed `path` invocation: two leading positionals (<fn> <Effect>), a report from --report/discovery,
// `--json`. Like `tour`, there is NO deprecated leading-report positional and NO policy — the report comes
// ONLY from --report/discovery, so a report path can never be silently mis-read as the <fn> positional.
private struct PathArgs {
    var positionals: [String] = []   // [<fn>, <Effect>]
    var report: String?              // resolved report prefix/path (nil ⇒ discovery failed, caller fails loud)
    var json = false
}

// Parse `path <fn> <Effect> [--report <locator>] [--json]`. Exactly TWO positionals are required; a
// surplus positional, or `--policy`/`--strict`, is a usage error (exit 2). Mirrors the Rust reference's
// `Shape { verb_args: 2, has_policy: false }`: report from --report/discovery, the two positionals are
// <fn> and <Effect>.
private func parsePathArgs(_ args: [String]) -> PathArgs {
    var p = PathArgs()
    var reportFlag: String?
    var positionals: [String] = []
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": p.json = true
        case "--report":
            guard let v = it.next() else { fixDie("candor-swift: --report requires a value") }
            reportFlag = v
        default:
            if a.hasPrefix("-") { fixDie("candor-swift: unknown flag \(a)") }
            positionals.append(a)
        }
    }
    p.positionals = positionals
    // Resolve the report: --report flag → discovery. NO positional report (like `tour`).
    p.report = reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()
    return p
}

// Dispatched from main.swift when argv[1] is `path`. Loads the report + callgraph the same way fix/tour do,
// resolves `<fn>` by exact-then-substring match (like the Rust reference), then BFS through the effect-
// carrying call graph to the nearest DIRECT source, recording the chain.
func runPathCLI(_ args: [String]) -> Never {
    let p = parsePathArgs(args)
    guard p.positionals.count == 2 else {
        fixDie("usage: candor-swift path <fn-substring> <Effect> [--report <locator>] [--json]")
    }
    let (fnArg, effect) = (p.positionals[0], p.positionals[1])
    guard let prefix = p.report else {
        fixDie("candor-swift path: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
    }
    guard let model = loadFixModel(prefix: prefix) else {
        fixDie("candor-swift path: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
    }
    let byName = model.byName
    let cg = model.cg

    // Resolve <fn>: EXACT name first, else the first (deterministic) fn whose qual CONTAINS the substring —
    // mirrors the Rust reference (`find(func == arg).or_else(find(func.contains(arg)))`). Sorted so the
    // substring fallback is stable across dictionary orderings.
    let names = byName.keys.sorted()
    let startName = names.first { $0 == fnArg } ?? names.first { $0.contains(fnArg) }
    guard let start = startName else {
        // Fail loud (exit 2) on an unmatched fn — never a silently-empty answer (matches the family).
        fixDie("candor-swift path: no function matching '\(fnArg)'")
    }
    let startFn = byName[start]!

    // The honest empty answer (NOT an error): the fn does not carry the effect at all. In --json mode emit
    // the pinned {effect,fn,path:[]} object (a `jq` consumer would choke on human text on stdout); in human
    // mode name it, matching the Rust wording, including the sorted inferred set for context.
    if !startFn.inferred.contains(effect) {
        if p.json {
            emitJSON(["fn": start, "effect": effect, "path": [[String: Any]]()])
        } else {
            let inf = "[" + startFn.inferred.sorted().map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            print("\(start) does not perform \(effect)  (inferred: \(inf))")
        }
        exit(0)
    }

    // BFS through effect-carrying callees to the FIRST fn with the effect in its DIRECT set (the nearest
    // local source). Traverse only through callees that transitively carry the effect (inferred), so the
    // frontier stays on-effect — matches the scan-note's `nearestSource` and the Rust reference.
    // `prev[x]` = the predecessor on the BFS tree; the start maps to "" (no predecessor — reconstruction
    // stops there). A key's PRESENCE marks "visited", so the start is seeded before the walk.
    var prev: [String: String] = [start: ""]
    var queue: [String] = [start]
    var head = 0
    var source: String?
    while head < queue.count {
        let cur = queue[head]; head += 1
        guard let f = byName[cur] else { continue }
        if f.direct.contains(effect) { source = cur; break }
        // Deterministic frontier order (sorted) so BFS-distance ties resolve identically across engines.
        for c in (cg[cur] ?? []).sorted() where prev[c] == nil {
            if let cf = byName[c], cf.inferred.contains(effect) {
                prev[c] = cur
                queue.append(c)
            }
        }
    }

    guard let src = source else {
        // Reached via a cross-package call / Unknown — the honest empty-path answer (§3.1), not an error.
        if p.json {
            emitJSON(["fn": start, "effect": effect, "path": [[String: Any]]()])
        } else {
            print("\(start) performs \(effect) but its source is not a local function "
                + "(cross-crate, or via Unknown) — not statically traceable.")
        }
        exit(0)
    }

    // Reconstruct the chain start → … → source.
    var chain: [String] = []
    var n = src
    while !n.isEmpty {
        chain.append(n)
        n = prev[n] ?? ""
    }
    chain.reverse()

    if p.json {
        let steps: [[String: Any]] = chain.enumerated().map { (i, name) in
            ["fn": name, "loc": byName[name]?.loc ?? "", "source": i == chain.count - 1]
        }
        emitJSON(["fn": start, "effect": effect, "path": steps])
        exit(0)
    }

    // HUMAN: header, then the chain — each step indented one deeper (2 spaces per level, from level 1), the
    // source step tagged `[<Effect> source @ file:line]` (or `[<Effect> source]` when loc is absent).
    print("candor path — how `\(start)` comes to perform \(effect):\n")
    for (i, name) in chain.enumerated() {
        let indent = String(repeating: "  ", count: i + 1)
        let arrow = i == 0 ? "" : "→ "
        var tag = ""
        if i == chain.count - 1 {
            let loc = byName[name]?.loc ?? ""
            tag = loc.isEmpty ? "   [\(effect) source]" : "   [\(effect) source @ \(loc)]"
        }
        print("\(indent)\(arrow)\(name)\(tag)")
    }
    exit(0)
}

// ── `gains <current> <baseline> [--json]` (SPEC §5.1) ──────────────────────────────────────────────
// The package-level SUPPLY-CHAIN alarm: every `<fn>\t<effect>` the surface GAINED between two reports
// (current `inferred` minus baseline `inferred`, per fn), sorted. The two-positional comparative verb
// (the family's §3.3.1 exception, like `diff`): both positionals ARE report locators, each resolved by
// the shared 3-way rule — NO discovery, NO --report, NO policy. Read-only over reports scans already
// wrote. Mirrors the Rust reference `candor-query gains` (diff.rs::cmd_gains): the default output is the
// `fn\teffect` TSV, `--json` the {byFunction, gained} machine form a CI gate can alarm on when a
// dependency update quietly gains a capability.

// Parse one `functions`-envelope report into `inferredByFn`, UNIONING on a name collision — two sibling
// reports can render a function with the same printed name, and an overwrite would drop one sibling's
// effects, so a newly-gained Net could silently VANISH from `gains` (a supply-chain miss; mirrors the
// Rust reference load_fninfo's union-not-overwrite rule). Returns false (with a stderr note) on an
// unparseable / non-report file — the caller fails loud, never a silently-empty "no gains".
private func mergeInferredReport(_ full: String, into inferredByFn: inout [String: Set<String>]) -> Bool {
    guard let data = FileManager.default.contents(atPath: full),
          let root = try? JSONSerialization.jsonObject(with: data),
          let obj = root as? [String: Any],
          let fns = obj["functions"] as? [[String: Any]] else {
        FileHandle.standardError.write("candor-swift gains: report `\(full)` could not be parsed — OMITTED.\n".data(using: .utf8)!)
        return false
    }
    for e in fns {
        guard let fn = e["fn"] as? String, !fn.isEmpty else { continue }
        let inferred = Set((e["inferred"] as? [Any])?.compactMap { $0 as? String } ?? [])
        inferredByFn[fn, default: []].formUnion(inferred)
    }
    return true
}

// Load fn → inferred effects for every `<prefix>*.Swift.json` report (merging siblings). As in
// loadFixModel, a `prefix` that is itself an existing regular `.json` file is loaded DIRECTLY (§3.3.1).
// Returns nil when no report file is found — or when every found file failed to parse (the loadFixModel
// house rule, stricter than the Rust reference's tolerant merge: a corrupt-only CURRENT locator must
// never read as "zero gains", the false all-clear a gate built on this output would silently PASS on).
private func loadInferredByFn(prefix: String) -> [String: Set<String>]? {
    let fm = FileManager.default
    var out: [String: Set<String>] = [:]
    var found = false

    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        return mergeInferredReport(prefix, into: &out) ? out : nil
    }

    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    for name in entries.sorted() where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.json") {
        if mergeInferredReport(dir + "/" + name, into: &out) { found = true }
    }
    return found ? out : nil
}

// The BASELINE callgraph for `origin` — SIDECAR-ONLY, deliberately NOT loadFixModel's inline-`calls`
// fallback: `origin` keys "did this fn exist at the baseline" on the baseline GRAPH, and the inline
// calls of the (effectful-only) report entries are an INCOMPLETE graph — a baseline-PURE fn is absent
// from it, so the fallback would mark an EXISTING fn "new" and downgrade the supply-chain alarm to a
// feature (a silent under-report). An absent sidecar stays an EMPTY graph → "unknown" (the JSON itself
// discloses); a present-but-corrupt sidecar keeps mergeCallgraph's stderr disclosure. Mirrors the Rust
// reference load_callgraph (sidecars only).
private func loadCallgraphSidecars(prefix: String) -> [String: [String]] {
    let fm = FileManager.default
    var cg: [String: [String]] = [:]

    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        let sidecar = ((prefix as NSString).deletingPathExtension) + ".callgraph.json"
        if fm.fileExists(atPath: sidecar) { mergeCallgraph(sidecar, into: &cg) }
        return cg
    }

    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return cg }
    for name in entries.sorted() where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.callgraph.json") {
        mergeCallgraph(dir + "/" + name, into: &cg)
    }
    return cg
}

// Dispatched from main.swift when argv[1] is `gains`.
func runGainsCLI(_ args: [String]) -> Never {
    var wantJson = false
    var positionals: [String] = []
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": wantJson = true
        default:
            if a.hasPrefix("-") { fixDie("candor-swift: unknown flag \(a)") }
            positionals.append(a)
        }
    }
    // Exactly TWO positionals (<current> <baseline>); a surplus is a usage error — never silently ignored.
    guard positionals.count == 2 else {
        fixDie("usage: candor-swift gains <current> <baseline> [--json]")
    }
    let curPre = resolveReportLocator(positionals[0])
    let basePre = resolveReportLocator(positionals[1])
    // A locator with no loadable report fails LOUD for BOTH sides (the family's diff/gains rule, and for
    // the same reason): a typo'd CURRENT prefix shows zero gains (a gate built on this silently PASSES);
    // a typo'd BASELINE shows every effect as newly gained.
    guard let cur = loadInferredByFn(prefix: curPre) else {
        fixDie("candor-swift gains: no report files at current prefix `\(curPre)` — check the path.")
    }
    guard let base = loadInferredByFn(prefix: basePre) else {
        fixDie("candor-swift gains: no report files at baseline prefix `\(basePre)` — check the path.")
    }

    var out: [(fn: String, effect: String)] = []
    for (fn, inf) in cur {
        for e in inf.subtracting(base[fn] ?? []) { out.append((fn: fn, effect: e)) }
    }
    out.sort { $0.fn == $1.fn ? $0.effect < $1.effect : $0.fn < $1.fn }

    if wantJson {
        // The supply-chain alarm (SPEC §5.1): `gained` is the UNION of effects the surface gained between
        // the two reports — a dependency that grew a Net/Exec reach between releases — with the
        // per-function detail under `byFunction`.
        //
        // ⟨spec 0.12 staged⟩ each byFunction entry carries `origin` — the candor-gains prototype's key
        // finding promoted into the open query. A gain on a fn that EXISTED at the baseline (shipped
        // pure, now does Net — the supply-chain attack signal) is a different alarm from a NEW fn that
        // does Net (a feature). Reports OMIT pure functions (SPEC §2), so existence is keyed on the
        // baseline CALLGRAPH sidecar (a baseline-pure fn is a graph node with no report entry):
        //   "existing" — in the baseline report, or a baseline-callgraph node (caller key or callee);
        //   "new"      — a baseline callgraph WAS loaded and the fn is in neither (the fn did not
        //                exist at the baseline);
        //   "unknown"  — absent from the baseline report AND no baseline callgraph sidecar was found
        //                (empty graph): existence is undecidable — DISCLOSED, never guessed (§4).
        // JSON-only: the human `fn\teffect` TSV is a pinned consumer surface across the family
        // (line-matched seen-file dedup) and stays byte-stable. Mirrors candor-rust cmd_gains.
        let baseCg = loadCallgraphSidecars(prefix: basePre)
        var baseCgNodes = Set(baseCg.keys)
        for callees in baseCg.values { baseCgNodes.formUnion(callees) }
        func originOf(_ fn: String) -> String {
            if base[fn] != nil { return "existing" }
            if baseCg.isEmpty { return "unknown" }
            return baseCgNodes.contains(fn) ? "existing" : "new"
        }
        let gained = Set(out.map { $0.effect }).sorted()
        let byFunction: [[String: Any]] = out.map {
            // Keys ALPHABETICAL within each entry (emitJSON's .sortedKeys): effect, fn, origin.
            ["effect": $0.effect, "fn": $0.fn, "origin": originOf($0.fn)]
        }
        emitJSON(["byFunction": byFunction, "gained": gained])
        exit(0)
    }
    for p in out { print("\(p.fn)\t\(p.effect)") }
    exit(0)
}
