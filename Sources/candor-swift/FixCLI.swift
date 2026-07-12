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

// Load every `<prefix>*.Swift.json` report (merging siblings) + the `.callgraph.json` sidecars for the graph.
// Returns nil if no report file is found for the prefix (the caller fails loud).
private func loadFixModel(prefix: String) -> (byName: [String: FixFn], cg: [String: [String]])? {
    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

    var byName: [String: FixFn] = [:]
    var cg: [String: [String]] = [:]
    var foundReport = false
    for name in entries.sorted() where name.hasPrefix(base + ".") {
        let full = dir + "/" + name
        if name.hasSuffix(".Swift.callgraph.json") {
            if let data = fm.contents(atPath: full),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in obj { cg[k] = (v as? [Any])?.compactMap { $0 as? String } ?? [] }
            }
        } else if name.hasSuffix(".Swift.json") {
            // A report file is present but unparseable (truncated / mid-write / not a report) — FAIL LOUD,
            // never read it as a silently-empty "no crossings". `foundReport` is set only AFTER a successful
            // parse, so a lone corrupt report leaves it false → loadFixModel returns nil → exit 2.
            // (/code-review — was `foundReport = true` before the guard.)
            guard let data = fm.contents(atPath: full),
                  let root = try? JSONSerialization.jsonObject(with: data),
                  let obj = root as? [String: Any],
                  let fns = obj["functions"] as? [[String: Any]] else {
                FileHandle.standardError.write("candor-swift fix: report `\(full)` could not be parsed — OMITTED.\n".data(using: .utf8)!)
                continue
            }
            foundReport = true
            for e in fns {
                guard let fn = e["fn"] as? String, !fn.isEmpty else { continue }
                let inferred = Set((e["inferred"] as? [Any])?.compactMap { $0 as? String } ?? [])
                let direct = Set((e["direct"] as? [Any])?.compactMap { $0 as? String } ?? [])
                let calls = (e["calls"] as? [Any])?.compactMap { $0 as? String } ?? []
                byName[fn] = FixFn(inferred: inferred, direct: direct, calls: calls)
            }
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
            guard let v = it.next(), !v.hasPrefix("-") else {
                fixDie("candor-swift: --report requires a value")
            }
            reportFlag = v
        case "--policy":
            guard let v = it.next(), !v.hasPrefix("-") else {
                fixDie("candor-swift: --policy requires a value")
            }
            policyFlag = v
        default:
            if a.hasPrefix("-") { fixDie("candor-swift: unknown flag \(a)") }
            positionals.append(a)
        }
    }

    // The verb's own positional args (fix's <fn> <Effect>) always come FIRST when supplied via flags.
    // In the deprecated form a leading report positional precedes them; disambiguate by count.
    // Layout of `positionals` in the deprecated form: [<report>] <verbArgs…> [<policy>].
    var pos = positionals
    var deprecatedReport: String?
    var deprecatedPolicy: String?

    if reportFlag == nil, pos.count > expectedVerbArgs {
        // A leading positional beyond the verb's own args ⇒ deprecated leading-report.
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
    // Any remaining trailing positional is the deprecated positional policy (fix/fix-gate/unverified).
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

// Load (fn, inferred, unknownWhy) from every `<prefix>*.Swift.json` report for the `unverified` check.
private func loadUnverifiedFns(prefix: String) -> [UnverifiedFn]? {
    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    var out: [UnverifiedFn] = []
    var found = false
    for name in entries.sorted() where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.json") {
        guard let data = fm.contents(atPath: dir + "/" + name),
              let root = try? JSONSerialization.jsonObject(with: data),
              let obj = root as? [String: Any],
              let fns = obj["functions"] as? [[String: Any]] else {
            FileHandle.standardError.write("candor-swift unverified: report `\(dir)/\(name)` could not be parsed — OMITTED.\n".data(using: .utf8)!)
            continue
        }
        found = true
        for e in fns {
            guard let fn = e["fn"] as? String, !fn.isEmpty else { continue }
            let inferred = Set((e["inferred"] as? [Any])?.compactMap { $0 as? String } ?? [])
            let why = (e["unknownWhy"] as? [Any])?.compactMap { $0 as? String } ?? []
            out.append(UnverifiedFn(fn: fn, inferred: inferred, unknownWhy: why))
        }
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
