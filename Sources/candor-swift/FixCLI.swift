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

// Dispatched from main.swift when argv[1] is `fix` or `fix-gate` (before the scan flag loop).
func runFixCLI(_ args: [String]) -> Never {
    let cmd = args[1]
    if cmd == "fix" {
        guard args.count >= 6 else {
            fixDie("usage: candor-swift fix <report-prefix> <fn> <Effect> <policy-file>")
        }
        let (prefix, target, effect, policy) = (args[2], args[3], args[4], args[5])
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
        guard args.count >= 4 else {
            fixDie("usage: candor-swift fix-gate <report-prefix> <policy-file>")
        }
        let (prefix, policy) = (args[2], args[3])
        let deny = loadDenyOrDie(policy, who: "fix-gate")
        guard let model = loadFixModel(prefix: prefix) else {
            fixDie("candor-swift fix-gate: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
        }
        let (ok, remedies) = fixGate(byName: model.byName, cg: model.cg, deny: deny)
        emitJSON(["ok": ok, "remedies": remedies.map { $0.toJSON() }])
        exit(0)
    }
}
