// SPEC §6.2 ⟨0.41⟩ — `candor-swift accepts [--report <locator>] [--policy <file>] [--json] [--adopt --because <reason>]`:
// refreshing (or adopting) `accept` lines as a PROPOSED policy.
//
// THE CARDINAL DIRECTION IS ACCEPTING A VIOLATION THAT IS NEW, AND THIS VERB CAN ONLY ACCEPT LESS. It therefore
// decides nothing itself: every fact it uses — which entry is stale, accepted, exceeded, ambiguous or unjudged,
// which rows a rule line produced, which entries the gate ignored — is read from `gateCore`, the SAME function
// `gate --report` prints its verdict from, run over the same bytes. The proposed text is then handed to `gateCore`
// again to report `after`. An entry whose state the gate did not name is KEPT, never deleted.
//
// It writes no file, and it never exits through `refuseGateAndExit`, which writes a refusal marker.

import Foundation
import CandorCore

private let acceptsUsage = "candor-swift accepts [--report <locator>] [--policy <file>] [--json] [--adopt --because <reason>]"
private let acceptsMark = "# candor-accepts:"
private let acceptsReplace = " — REPLACE the line above with: "
private let acceptsRuleKinds: Set<String> = ["deny", "pure", "forbid", "allow", "only"]

private func acceptsErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// One input line: its bytes and its terminator, both verbatim, and the text the gate reads.
private struct InLine {
    var body: [UInt8]
    var term: [UInt8]
    var text: String
    var bom: Bool
}

/// Split at LF, CRLF or a lone CR — the terminators `parsePolicy` splits at, so the gate's `line` numbers are this
/// verb's line numbers. Every byte lands in exactly one body or terminator.
private func acceptsSplit(_ b: [UInt8]) -> [InLine] {
    var out: [InLine] = []
    var start = 0, i = 0
    let n = b.count
    func mk(_ body: [UInt8], _ term: [UInt8]) {
        var text = String(decoding: body, as: UTF8.self)
        var bom = false
        if out.isEmpty, body.starts(with: [0xEF, 0xBB, 0xBF]) { text = String(decoding: body.dropFirst(3), as: UTF8.self); bom = true }
        out.append(InLine(body: body, term: term, text: text, bom: bom))
    }
    while i < n {
        let c = b[i]
        if c == 0x0A || c == 0x0D {
            let tl = (c == 0x0D && i + 1 < n && b[i + 1] == 0x0A) ? 2 : 1
            mk(Array(b[start..<i]), Array(b[i..<(i + tl)]))
            i += tl
            start = i
        } else {
            i += 1
        }
    }
    if start < n { mk(Array(b[start..<n]), []) }
    return out
}

private func acceptsIsAsciiWs(_ ch: Character) -> Bool { ch.isASCII && ch.isWhitespace }

/// The line's tokens: the comment removed, ASCII-whitespace separated — the parser's own lexing.
private func acceptsLex(_ text: String) -> [String] {
    let head = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    return head.split(whereSeparator: acceptsIsAsciiWs).map(String.init)
}

private func acceptsIsMark(_ text: String) -> Bool {
    let lead = text.prefix(while: { $0 == " " || $0 == "\t" })
    return text.dropFirst(lead.count).hasPrefix(acceptsMark)
}

private func acceptsCommentOf(_ text: String) -> String {
    guard let i = text.firstIndex(of: "#") else { return "" }
    return " " + text[i...]
}

private func byCP(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

/// Effect tokens in code-point order, an `Unknown` written as `Unknown[<its classes, sorted>]`.
private func acceptsCanon(_ concrete: Set<String>, _ classes: Set<String>?) -> [String] {
    var t = Array(concrete)
    if let c = classes { t.append("Unknown[" + c.sorted(by: byCP).joined(separator: ",") + "]") }
    return t.sorted(by: byCP)
}

/// (concrete effects, any Unknown, the classes the rows carry) over a set of rows.
private func acceptsUnion(_ rows: [AcceptRow]) -> (conc: Set<String>, unk: Bool, cls: Set<String>) {
    var conc = Set<String>(), cls = Set<String>()
    var unk = false
    for r in rows {
        for x in r.effects { if x == "Unknown" { unk = true } else { conc.insert(x) } }
        cls.formUnion(r.classes)
    }
    return (conc, unk, cls)
}

/// §6.2: `--because` is ONE argument lexed by ASCII whitespace; at least one token; no `#`. nil after a usage error.
private func acceptsReason(_ raw: String) -> String? {
    let toks = raw.split(whereSeparator: acceptsIsAsciiWs).map(String.init)
    if toks.isEmpty { acceptsErr("candor-swift accepts: --because needs a reason — a value with at least one token."); return nil }
    if raw.contains("#") {
        acceptsErr("candor-swift accepts: --because must not contain `#` — a `#` begins a comment on a policy line, so it would cut "
                   + "the reason you wrote short. Reword it (the issue number without the hash, say).")
        return nil
    }
    return toks.joined(separator: " ")
}

private func acceptsItem(_ line: Int, _ fn: String, _ rule: String, _ because: String?) -> [String: Any] {
    var m: [String: Any] = ["line": line, "fn": fn, "policyRule": rule]
    if let b = because { m["because"] = b }
    return m
}

/// Does `accepts` have a report to read with no `--report`? `CANDOR_REPORT` counts as named (the operator chose it; the gate's
/// own wording stays for a locator that matches nothing), and so does a recorded REFUSAL over the discovered prefix (the gate
/// says that one). Otherwise the discovered prefix must name at least one report.
private func acceptsReportDiscoverable() -> Bool {
    if let env = ProcessInfo.processInfo.environment["CANDOR_REPORT"], !env.isEmpty { return true }
    guard let prefix = discoverReportPrefix() else { return false }
    return refusalMarkerFor(prefix) != nil || looksLikeReport(prefix)
}

/// ⟨0.41.1⟩ `accepts` with no report named and none discovered. The refusal says which report each choice would judge and prints
/// commands that run. It does not fall back to the config's `baseline`: that is the PREVIOUS recorded scan, and a refresh against
/// it would delete the entries of code written since and adopt only what the baseline held — a proposal the CI gate, which judges
/// the CURRENT scan, would then contradict. The policy is discovered as the gate discovers it, so it is not the missing piece.
private func acceptsNoReportMessage() -> String {
    var base = ProcessInfo.processInfo.environment["CANDOR_BASELINE"].flatMap { $0.isEmpty ? nil : $0 }
    if base == nil, let b = loadCandorConfig(targetPath: ".", lenient: true)["baseline"], !b.isEmpty { base = b }
    let cur = ".candor/report"
    var m = "candor-swift accepts: no report to judge — no report files found (and no --report / CANDOR_REPORT).\n"
        + "  `accepts` reads a REPORT; it does not scan. The report that matches what CI gates is the CURRENT scan:\n"
        + "      candor-swift . --out \(cur)     # exits 1 when the policy has violations, but the report is still written (`|| true` under `set -e`)\n"
        + "      candor-swift accepts --report \(cur) --adopt --because <reason>\n"
    if let b = base {
        m += "  The config's baseline `\(b)` is the PREVIOUS recorded scan, so it is not used unasked (a refresh against it deletes "
            + "entries for code written since). To judge it on purpose: candor-swift accepts --report \(b) ...\n"
    }
    return m
}

/// ⟨0.41.1⟩ Every violation the proposal leaves red because NO line could be written for it, with the reason and the remedy, so
/// "after the proposal the gate exits 1 with N violation(s)" is never a number with no cause. Human channel only: the plan is
/// unchanged. Up to five names per reason, then a count.
private let acceptsRefusedWhy: [(key: String, why: String, remedy: String)] = [
    ("positional", "keyed by POSITION (`<main>`, or a `#<n>` ordinal), which an `accept` line cannot name — an unrelated edit would re-point it at a different unit",
     "give it a NAME (move the top-level code into a named function), re-scan, and run `accepts` again; or fix the violation"),
    ("twin", "a (hash, fn) TWIN — two units with this name and different hashes, so no line could name one of them",
     "rename one of the two, or gate the modules separately; or fix the violation"),
    ("unwritable", "named with a `#` or whitespace, which cannot be written on a policy line", "rename it, or fix the violation"),
    ("noclass", "carries an `Unknown` whose reason class this report does not carry, so no `Unknown[…]` line would cover it",
     "re-scan with the current engine so the report carries its reason classes, then run `accepts` again; or fix the violation"),
]

func runAcceptsCLI(_ args: [String]) -> Never {
    // ---- the flags, validated FIRST: a usage error costs nothing and writes nothing ----------------------------
    var reportFlag: String?, policyFlag: String?
    var json = false, adopt = false
    var rawBecause: String?
    let rest = Array(args.dropFirst(2))
    var i = 0
    while i < rest.count {
        let a = rest[i]
        switch a {
        case "--json": json = true
        case "--adopt": adopt = true
        case "--report", "--policy", "--because":
            guard i + 1 < rest.count, a == "--because" || rest[i + 1] == "-" || !rest[i + 1].hasPrefix("-") else {
                acceptsErr("candor-swift accepts: \(a) was given no value (usage: \(acceptsUsage))")
                exit(2)
            }
            switch a {
            case "--report": reportFlag = rest[i + 1]
            case "--policy": policyFlag = rest[i + 1]
            default: rawBecause = rest[i + 1]
            }
            i += 1
        default:
            acceptsErr("candor-swift accepts: " + (a.hasPrefix("-") ? "unknown flag " : "unexpected argument ") + a
                       + " (usage: \(acceptsUsage))"
                       + (a == "--strict" ? " — `accepts` is advisory and has no --strict: it exits 0 whatever it found; the gate is the CI check." : ""))
            exit(2)
        }
        i += 1
    }
    if rawBecause != nil, !adopt {
        acceptsErr("candor-swift accepts: --because is only meaningful with --adopt — a refresh never writes an accept line for a "
                   + "row no entry names, so a reason would have nothing to attach to (usage: \(acceptsUsage))")
        exit(2)
    }
    if adopt, rawBecause == nil {
        acceptsErr("candor-swift accepts: --adopt needs --because <reason> — the reason on a created line is yours to write, "
                   + "never one the engine composes (usage: \(acceptsUsage))")
        exit(2)
    }
    var because = ""
    if adopt {
        guard let r = acceptsReason(rawBecause!) else { exit(2) }
        because = r
    }
    // ---- no report named and none discovered: still a refusal, but one that names the commands that work -------------
    if reportFlag == nil, !acceptsReportDiscoverable() {
        acceptsErr(acceptsNoReportMessage().trimmingCharacters(in: .newlines))
        exit(2)
    }
    guard let policyPath = policyFlag ?? discoverPolicy() else {
        acceptsErr("candor-swift accepts: a policy is required — pass `--policy <file>`, set CANDOR_POLICY, or add a `policy` key to "
                   + ".candor/config. There is no policy to refresh.")
        exit(2)
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: policyPath)), String(data: data, encoding: .utf8) != nil else {
        acceptsErr("candor-swift accepts: cannot read policy \(policyPath) (unreadable, or not valid UTF-8) — no proposal.")
        exit(2)
    }
    let inLines = acceptsSplit([UInt8](data))
    let n = inLines.count
    let policyText = String(decoding: data, as: UTF8.self)
    let anyRule = inLines.contains { l in acceptsLex(l.text).first.map { acceptsRuleKinds.contains($0) } ?? false }
    func redirectNote() {
        if !anyRule {
            acceptsErr("candor-swift accepts: this policy holds no rules. If it was empty because you ran "
                       + "`candor-swift accepts > \(policyPath)`, a shell redirect onto the policy EMPTIES it before the verb "
                       + "reads it — the policy file is now empty; restore it (e.g. `git checkout -- \(policyPath)`) and write the "
                       + "proposal to ANOTHER path, then diff.")
        }
    }

    // ---- 1. the gate over the input bytes ---------------------------------------------------------------------------
    let core: GateCore
    switch gateCore(policyPath: policyPath, policyText: policyText, reportFlag: reportFlag, announce: false) {
    case .refusal(let why, _, _):
        acceptsErr(why)
        acceptsErr("candor-swift accepts: the gate over this policy and report refuses (exit 2) — no proposal. The policy was not changed.")
        redirectNote()
        exit(2)
    case .answered(let c):
        core = c
    }
    if core.incomplete {
        acceptsErr("candor-swift accepts: the gate over this policy and report is INCOMPLETE (a unit it did not read makes its entries "
                   + "look stale, and pruning them would delete the reasons for code that still exists) — no proposal. The policy was not changed.")
        redirectNote()
        exit(2)
    }

    // ---- 2. what each entry is ---------------------------------------------------------------------------------------
    let entries = core.pol.accepts
    let settlement = core.outcome.settlement
    let rows = core.outcome.rows
    var status: [Int: String] = [:]
    for it in settlement?.items ?? [] { status[it.line] = it.status }
    let staleLines = Set((settlement?.stale ?? []).map(\.line))
    var ignoredLines = Set<Int>()
    for ig in core.pol.ignored where ig.line >= 1 && ig.line <= n && acceptsLex(inLines[ig.line - 1].text).first == "accept" {
        ignoredLines.insert(ig.line)
    }
    var ruleLine: [String: Int] = [:]                          // rule key -> first line carrying it
    for ln in 1...max(n, 1) where ln <= n {
        let k = acceptsLex(inLines[ln - 1].text)
        if let f = k.first, acceptsRuleKinds.contains(f) { let key = k.joined(separator: " "); if ruleLine[key] == nil { ruleLine[key] = ln } }
    }
    let acceptedRowSet = settlement?.acceptedRows ?? []

    // ---- 3. the changes -----------------------------------------------------------------------------------------------
    var removed: [Int: [String: Any]] = [:], narrowed: [Int: [String: Any]] = [:], proposals: [Int: [String: Any]] = [:]
    var unjudged: [[String: Any]] = []
    var newText: [Int: String] = [:], proposalComment: [Int: String] = [:]
    for e in entries.sorted(by: { $0.line < $1.line }) {
        let L = e.line
        let st = status[L] ?? (staleLines.contains(L) ? "stale" : "kept")
        switch st {
        case "stale":
            removed[L] = acceptsItem(L, e.fn, e.ruleKey, e.because)
        case "accepted":
            guard let idxs = settlement?.directRows[L], !idxs.isEmpty else { continue }
            let u = acceptsUnion(idxs.map { rows[$0] })
            let cls = (u.unk && u.cls.isEmpty) ? Set(e.classes ?? []) : u.cls
            let to = acceptsCanon(u.conc, u.unk ? cls : nil)
            let fromConc = Set(e.effects.filter { $0 != "Unknown" })
            let from = acceptsCanon(fromConc, e.classes.map { Set($0) })
            if Set(to) != Set(from) {
                let text = "accept \(e.fn) \(to.joined(separator: " ")) for \(e.ruleKey) because \(e.because)"
                    + acceptsCommentOf(inLines[L - 1].text)
                var m = acceptsItem(L, e.fn, e.ruleKey, e.because)
                m["from"] = from; m["to"] = to; m["text"] = text
                narrowed[L] = m
                newText[L] = text
            }
        case "exceeded":
            let mine = rows.indices.filter { !acceptedRowSet.contains($0) && rows[$0].ruleKey == e.ruleKey && rows[$0].name == e.fn }
                .map { rows[$0] }
            let u = acceptsUnion(mine)
            if u.unk && u.cls.isEmpty {
                // The row's classes are not determinable: no `Unknown[...]` line could name them, so no wider line is proposed.
                acceptsErr("candor-swift accepts: line \(L) (`\(e.fn)`) is EXCEEDED by an `Unknown` whose reason classes this report does "
                           + "not carry — no wider line can be written for it; kept as is, and the row stays red. Remedy: re-scan with the current engine so "
                           + "the report carries its reason classes, then run `accepts` again; or fix the violation.")
                continue
            }
            let prop = acceptsCanon(u.conc, u.unk ? u.cls : nil)
            var adds = u.conc.filter { !e.effects.contains($0) }
            if u.unk {
                var extra = u.cls
                if let have = e.classes { extra.subtract(have) }
                if !extra.isEmpty { adds.insert("Unknown[" + extra.sorted(by: byCP).joined(separator: ",") + "]") }
            }
            let addList = adds.sorted(by: byCP)
            let text = "accept \(e.fn) \(prop.joined(separator: " ")) for \(e.ruleKey) because \(e.because)"
                + acceptsCommentOf(inLines[L - 1].text)
            var m = acceptsItem(L, e.fn, e.ruleKey, e.because)
            m["adds"] = addList; m["text"] = text
            proposals[L] = m
            proposalComment[L] = acceptsMark + " exceeded (adds " + addList.joined(separator: " ") + ")" + acceptsReplace + text
        case "unjudged":
            unjudged.append(acceptsItem(L, e.fn, e.ruleKey, nil))
        case "ambiguous":
            // kept byte for byte — and said, so the row it leaves red has a cause
            acceptsErr("candor-swift accepts: line \(L) (`\(e.fn)`) is AMBIGUOUS — two units share that name with different hashes, so the "
                       + "entry accepts NEITHER; kept as written. Remedy: rename one of the two, or gate the modules separately.")
        default:
            break           // a state the gate did not name: kept byte for byte
        }
    }

    // ---- adoption candidates: the rows no entry names (computed in both modes: `unnamed`) ---------------------------------
    struct Cand { var line: Int; var fn: String; var hash: String; var rule: String; var effects: [String] }
    var cands: [Cand] = []
    var seen = Set<String>()
    var refused: [String: Set<String>] = [:]      // reason key -> the fns no entry could be written for
    for r in rows {
        guard let line = ruleLine[r.ruleKey] else { continue }
        if entries.contains(where: { $0.fn == r.name && $0.ruleKey == r.ruleKey }) { continue }
        if !seen.insert(r.ruleKey + "\u{0}" + r.name).inserted { continue }
        if core.outcome.twins.contains(r.name) { refused["twin", default: []].insert(r.name); continue }
        if isAcceptPositionalKey(r.name) { refused["positional", default: []].insert(r.name); continue }
        if r.name.unicodeScalars.contains(where: { $0 == "#" || " \t\n\r\u{0C}\u{0B}".unicodeScalars.contains($0) }) {
            refused["unwritable", default: []].insert(r.name); continue
        }
        var conc = Set(r.effects)
        let unk = conc.remove("Unknown") != nil
        if unk && r.classes.isEmpty { refused["noclass", default: []].insert(r.name); continue }
        cands.append(Cand(line: line, fn: r.name, hash: r.hash, rule: r.ruleKey,
                          effects: acceptsCanon(conc, unk ? Set(r.classes) : nil)))
    }
    cands.sort { $0.line != $1.line ? $0.line < $1.line : byCP($0.fn, $1.fn) }
    var unnamed: [[String: Any]] = [], created: [[String: Any]] = [], createdText: [String] = []
    for c in cands {
        var m: [String: Any] = ["fn": c.fn, "policyRule": c.rule, "effects": c.effects]
        if !c.hash.isEmpty { m["hash"] = c.hash }
        unnamed.append(m)
        if adopt {
            let text = "accept \(c.fn) \(c.effects.joined(separator: " ")) for \(c.rule) because \(because)"
            var cm: [String: Any] = ["fn": c.fn, "policyRule": c.rule, "because": because, "effects": c.effects, "text": text]
            if !c.hash.isEmpty { cm["hash"] = c.hash }
            created.append(cm)
            createdText.append(text)
        }
    }

    // ---- 4. the proposed text -------------------------------------------------------------------------------------------------
    var body: [UInt8] = []
    for ln in 1...max(n, 1) where ln <= n {
        let l = inLines[ln - 1]
        if acceptsIsMark(l.text) || removed[ln] != nil { continue }
        if let t = newText[ln] {
            if l.bom { body += [0xEF, 0xBB, 0xBF] }
            body += Array(t.utf8) + l.term
        } else {
            body += l.body + l.term
        }
        if let c = proposalComment[ln] {
            if l.term.isEmpty { body += Array("\n".utf8) }
            body += Array(c.utf8)
            if !l.term.isEmpty { body += l.term }
        }
    }
    if !createdText.isEmpty {
        if let last = body.last, last != 0x0A, last != 0x0D { body += Array("\n".utf8) }
        for t in createdText { body += Array((t + "\n").utf8) }
    }
    let text = String(decoding: body, as: UTF8.self)

    // ---- 5. `after`: the gate's verdict over the proposal ------------------------------------------------------------------------------
    var afterExit: Int32 = 2, afterViolations = 0, afterAccepted = 0
    if case .answered(let g1) = gateCore(policyPath: policyPath, policyText: text, reportFlag: reportFlag, announce: false) {
        afterExit = g1.exitCode
        afterViolations = g1.violations.count
        afterAccepted = (g1.outcome.settlement?.items ?? []).filter { $0.status == "accepted" }.count
    }

    // ---- 6. output ----------------------------------------------------------------------------------------------------------------------
    func sorted(_ d: [Int: [String: Any]]) -> [[String: Any]] { d.keys.sorted().map { d[$0]! } }
    if json {
        var plan: [String: Any] = [
            "mode": adopt ? "adopt" : "refresh", "text": text,
            "removed": sorted(removed), "narrowed": sorted(narrowed), "proposals": sorted(proposals),
            "unnamed": unnamed, "unjudged": unjudged,
            "ignored": ignoredLines.sorted().map { ["line": $0] },
            "after": ["exit": Int(afterExit), "violations": afterViolations, "accepted": afterAccepted],
        ]
        if adopt { plan["created"] = created }
        guard let pj = try? JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]) else {
            acceptsErr("candor-swift accepts: could not serialize the plan — no proposal.")
            exit(2)
        }
        FileHandle.standardOutput.write(pj + Data("\n".utf8))
    } else {
        FileHandle.standardOutput.write(Data(body))
    }
    acceptsErr("candor-swift accepts (\(adopt ? "adopt" : "refresh")): \(removed.count) stale line(s) removed, \(narrowed.count) narrowed, "
               + "\(proposals.count) exceeded (proposed in a comment, NOT accepted), \(created.count) created; "
               + "\(unnamed.count) violation(s) no entry names; after the proposal the gate exits \(afterExit) with "
               + "\(afterViolations) violation(s), \(afterAccepted) accepted.")
    for u in unjudged {
        acceptsErr("candor-swift accepts: line \(u["line"]!) (`\(u["fn"]!)` under `\(u["policyRule"]!)`) kept UNJUDGED — this route cannot "
                   + "evaluate that rule, so nothing is known about the entry. Gate at scan time.")
    }
    for w in acceptsRefusedWhy {
        let fns = (refused[w.key] ?? []).sorted(by: byCP)
        if fns.isEmpty { continue }
        let shown = fns.prefix(5).map { "`\($0)`" }
        acceptsErr("candor-swift accepts: \(fns.count) violation(s) get NO accept line — \(w.why): \(shown.joined(separator: ", "))"
                   + (fns.count > shown.count ? ", … and \(fns.count - shown.count) more" : "") + ". Remedy: \(w.remedy).")
    }
    for ln in ignoredLines.sorted() {
        acceptsErr("candor-swift accepts: line \(ln) is IGNORED by the gate and kept as written — repairing it is yours.")
    }
    if adopt, !created.isEmpty {
        acceptsErr("candor-swift accepts: --adopt wrote \(created.count) line(s) keyed by function name alone. Across runs no key component "
                   + "distinguishes one module's unit from another's, so gate each module under its own policy file; a shared file "
                   + "accepts a same-named unit elsewhere on this reason.")
    }
    acceptsErr("candor-swift accepts: nothing was written. To take the proposal: write it to ANOTHER path (not onto the policy — "
               + "a shell redirect onto it empties it first), then `diff \(policyPath) <that path>` and commit.")
    exit(0)
}
