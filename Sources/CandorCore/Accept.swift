// SPEC §6.2 ⟨0.41⟩ — `accept <fn> [<Effect>…] for <rule tokens…> because <reason…>`: a KNOWN violation,
// written down where a reviewer reads it. The parse and the matching are PURE and live here, in the
// library, so they get direct unit tests (an executable target cannot be `@testable import`ed); the two
// routes that evaluate a policy (`scan --policy`, `gate --report`) and the advisory verbs reach them
// through ONE seam in the executable (Gate.swift `settleGateAccepts`).
//
// THE CARDINAL DIRECTION HERE IS ACCEPTING A VIOLATION THAT IS NEW. Every decision below is made so that
// doubt leaves the row RED: a line this file cannot read exactly is ignored (and listed in `ignored`), a key
// it cannot trust (a positional one) is refused, a twin it cannot tell apart accepts neither, an `Unknown`
// it cannot classify is not covered. A bug in this file may therefore cost a false red; it must not cost a
// false green.

import Foundation

/// One `accept` line held until every rule line has been read.
struct PendingAccept {
    let lineNo: Int
    /// the source line verbatim (what `ignored[].text` carries)
    let text: String
    /// comment removed, ASCII-trimmed
    let line: String
    /// the raw lexed tokens; `tokens[0] == "accept"`
    let tokens: [String]
}

/// One valid `accept` line. `classes` is nil when the entry does not list `Unknown`; otherwise the explicit
/// reason classes it covers.
public struct AcceptEntry {
    /// 1-based line of the `accept` line in the policy file.
    public let line: Int
    /// the source line verbatim
    public let text: String
    /// ONE token, compared by exact string equality with a verdict row's `fn`.
    public let fn: String
    /// §1 effect names listed, plus `Unknown` when a class filter was given. Sorted. Empty for a `forbid` entry.
    public let effects: [String]
    public let classes: [String]?
    /// `acceptRuleKey` of the `deny`/`pure`/`forbid` line it names (= the verdict item's `policyRule`).
    public let ruleKey: String
    public let forbid: Bool
    /// the operator's justification: its tokens joined by single spaces.
    public let because: String
    /// the code the named rule charges: AS-EFF-009 for `forbid`, AS-EFF-006 for `deny`/`pure`.
    public var code: String { forbid ? "AS-EFF-009" : "AS-EFF-006" }
}

/// A rule line's KEY: its RAW lexed tokens (comment removed, ASCII-whitespace runs collapsed) joined by single
/// spaces — the text an `accept` entry's `for … because` span must equal token for token, and the `policyRule` a
/// verdict item carries. The RAW tokens, not the tokens the rule kind consumed: `deny Fs dao extra` parses as
/// `deny Fs dao`, and only `for deny Fs dao extra` names it. `raw` is already comment-stripped and trimmed by the
/// parser; it is re-lexed with the parser's own separator so `deny   Fs\tdao` and `deny Fs dao` are one key and a
/// NBSP is not a separator.
public func acceptRuleKey(_ raw: String) -> String {
    raw.split(whereSeparator: { $0.isASCII && $0.isWhitespace }).joined(separator: " ")
}

/// IS THIS `fn` A POSITIONAL KEY — one this engine assigns by ordinal position rather than by a declared name
/// (SPEC §6.2 ⟨0.41⟩: "a property it checks, not a pattern the document lists")? Measured on this engine's own
/// spellings (Driver.swift): the `#<n>` suffix a same-typed overload, a duplicate file-scope global, or a second
/// module's top-level code (`<main>#1`) gets in file order, and BARE `<main>`, which in a multi-module scan is the
/// alphabetically-first module's top-level code and so names different code the day an earlier module is added.
/// Inserting an unrelated declaration renumbers a `#<n>` key, and an entry on one would silently accept DIFFERENT
/// code. Over-matching errs RED: the line is ignored and the violation stays.
///
/// NOTE ON REACH: a `#` begins a comment (§6.2), so a `#<n>` key can never survive the line lexer — the line
/// loses everything from the `#` on and is ignored for lacking `for`. This predicate is the check the clause asks
/// for all the same, because the lexer is not where the property should live: it is also what a future change to
/// the comment rule would otherwise leave unguarded.
public func isAcceptPositionalKey(_ fn: String) -> Bool {
    if fn == "<main>" { return true }
    var prevHash = false
    for ch in fn {
        if prevHash, ch.isASCII, ch.isNumber { return true }
        prevHash = ch == "#"
    }
    return false
}

/// Turn each held `accept` line into an `AcceptEntry`, a NON-FATAL ignored line, or a FATAL policy error.
/// Called AFTER the rule loop: the named rule may come later in the file, and "a `deny`, `pure` or `forbid`
/// line that PARSED as a rule" is only decidable once every line has been read.
///
/// ORDER OF THE CHECKS matches the family (candor-java `Accept.resolve`, candor-rust `resolve_accepts`): the
/// structural checks — names a function, has `for`, has `because <reason>` — come BEFORE the effect list, so a
/// line that is malformed in structure AND carries a typo'd effect is IGNORED, not fatal; the typo is only
/// read once the line is otherwise well-formed.
func resolveAccepts(_ pending: [PendingAccept], deny: [DenyRule], allow: [AllowRule], forbid: [ForbidRule],
                    only: [OnlyRule], aliases: [String: Set<String>],
                    errors: inout [PolicyError], ignored: inout [IgnoredLine]) -> [AcceptEntry] {
    let denyKeys = Set(deny.map { acceptRuleKey($0.raw) })
    let forbidKeys = Set(forbid.map { acceptRuleKey($0.raw) })
    let otherKeys = Set(allow.map { acceptRuleKey($0.raw) } + only.map { acceptRuleKey($0.raw) })
    let shape = "accept <fn> [<Effect>…] for <rule tokens…> because <reason>"
    var out: [AcceptEntry] = []
    for p in pending {
        let t = p.tokens
        func ignore(_ why: String) {
            errors.append(warnRule("`accept` line not honoured — \(why)", p.line, kind: "rule-form",
                                   token: "accept", accepted: [shape]))
            ignored.append(IgnoredLine(line: p.lineNo, text: p.text, reason: "accept not honoured — \(why)"))
        }
        if t.count < 2 { ignore("it names no function (want `\(shape)`)"); continue }
        let fn = t[1]
        guard let forAt = (2..<max(t.count, 2)).first(where: { t[$0] == "for" }) else {
            ignore("it lacks the literal `for` between the effects and the rule it names"); continue
        }
        guard let becAt = ((forAt + 1)..<max(t.count, forAt + 1)).first(where: { t[$0] == "because" }),
              becAt + 1 < t.count else {
            ignore("it carries no reason — write `because <why>` (a `#` begins a comment, so `because #123` is empty: write `ticket-123`)")
            continue
        }
        let key = t[(forAt + 1)..<becAt].joined(separator: " ")
        let because = t[(becAt + 1)...].joined(separator: " ")
        // ---- the effect list ----------------------------------------------------------------------------
        var names = Set<String>()
        var classes: Set<String>? = nil
        var malformed: String? = nil
        var fatal = false
        for e in t[2..<forAt] {
            if e == "Unknown" {
                if malformed == nil { malformed = "bare `Unknown` is not accepted here — write an explicit class list, `Unknown[dispatch]`" }
            } else if e.hasPrefix("Unknown["), e.hasSuffix("]") {
                let inner = String(e.dropFirst("Unknown[".count).dropLast())
                var any = false
                for rawCn in inner.split(separator: ",", omittingEmptySubsequences: false) {
                    let cn = rawCn.trimmingCharacters(in: .whitespaces)
                    if cn.isEmpty {
                        if malformed == nil { malformed = "empty class in `\(e)`" }
                    } else if cn == "*" || cn == "dynamic" || aliases[cn] != nil {
                        if malformed == nil { malformed = "`\(cn)` is an alias, not a reason class — list the classes by name" }
                    } else if REASON_CLASSES.contains(cn) {
                        classes = (classes ?? []).union([cn])
                        any = true
                    } else {
                        // The policy error the unrecognised-token rule already makes it: dropping the token would
                        // silently NARROW what the entry covers (or widen it, were it the only one).
                        errors.append(policyClassTokenPolicyError(cn, p.line))
                        fatal = true
                    }
                }
                if any { names.insert("Unknown") }
            } else if e.contains("[") {
                if malformed == nil { malformed = "`\(e)`: only `Unknown` takes a bracketed filter on an `accept` line" }
            } else if EFFECTS.contains(e) {
                names.insert(e)
            } else {
                errors.append(PolicyError(
                    kind: "effect-name", token: e, accepted: EFFECTS.sorted(), rule: p.line,
                    message: "unknown effect-name `\(e)` in an `accept` line (known: \(EFFECTS.sorted().joined(separator: ", ")))",
                    gateReason: policyEffectNameError(
                        e, p.line, accepted: EFFECTS.sorted(),
                        why: "An `accept` line's effect list is a policy value list, so a token outside the §1 "
                           + "vocabulary cannot be honoured as written.")))
                fatal = true
            }
        }
        if fatal { continue }                       // the whole policy is refused; nothing else to say about this line
        if let why = malformed { ignore(why); continue }
        // ---- the rule it names ----------------------------------------------------------------------------
        let isDeny = denyKeys.contains(key), isForbid = forbidKeys.contains(key)
        if otherKeys.contains(key), !isDeny, !isForbid {
            ignore("it cannot name an `allow` or `only` rule — its verdict row does not say which value or scope was reached, so an entry would silently accept a NEW one")
            continue
        }
        if !isDeny, !isForbid {
            ignore("it names no `deny`/`pure`/`forbid` line of this file — the tokens between `for` and `because` must equal a rule line's tokens, token for token")
            continue
        }
        if isDeny, names.isEmpty { ignore("an entry for a `deny`/`pure` rule must list at least one effect"); continue }
        if isForbid, !names.isEmpty { ignore("an entry for a `forbid` rule takes no effects"); continue }
        if isAcceptPositionalKey(fn) {
            ignore("`\(fn)` is a POSITIONAL key (numbered by order): an unrelated edit renumbers it and the entry would accept DIFFERENT code. Accept the enclosing function instead")
            continue
        }
        out.append(AcceptEntry(line: p.lineNo, text: p.text, fn: fn, effects: names.sorted(),
                               classes: classes?.sorted(), ruleKey: key, forbid: isForbid && !isDeny,
                               because: because))
    }
    return out
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// matching
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// One row a rule line produced, BEFORE any de-duplication: matching is per producing LINE.
public struct AcceptRow {
    public let ruleKey: String
    public let code: String
    public let name: String
    public let hash: String
    public let effects: [String]
    public let classes: [String]
    public init(ruleKey: String, code: String, name: String, hash: String, effects: [String], classes: [String]) {
        self.ruleKey = ruleKey; self.code = code; self.name = name; self.hash = hash
        self.effects = effects; self.classes = classes
    }
}

/// One element of the `accepted` verdict key (SPEC §6.2 ⟨0.41⟩).
public struct AcceptItem {
    public let rule: String, fn: String, hash: String, effects: [String]
    public let line: Int, policyRule: String, because: String, status: String
    public var json: [String: Any] {
        var m: [String: Any] = ["rule": rule, "fn": fn, "effects": effects, "line": line,
                                "policyRule": policyRule, "because": because, "status": status]
        if !hash.isEmpty { m["hash"] = hash }
        return m
    }
}

public struct AcceptSettlement {
    /// indices into the `rows` handed in that an entry took out of `violations`.
    public var acceptedRows: Set<Int> = []
    /// the `accepted` list, sorted by `line`, then `fn` and `hash` by code point.
    public var items: [AcceptItem] = []
    /// entries whose rule was evaluated and which accepted nothing, covered nothing and are not ambiguous.
    public var stale: [AcceptEntry] = []
    /// one human sentence per entry that did not accept anything, each naming the remedy.
    public var notes: [String] = []
}

private func byCodePoint(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

/// Does `e` cover every effect of row `r`? A concrete effect must be listed; an `Unknown` is covered only by an
/// `Unknown[F]` whose class list contains EVERY class of the row's `reasonClass`. A row whose classes are not
/// determinable is covered by no filter (fail closed).
func acceptCovers(_ e: AcceptEntry, _ r: AcceptRow) -> Bool {
    for x in r.effects {
        if x == "Unknown" {
            guard e.effects.contains("Unknown"), let cl = e.classes else { return false }
            if r.classes.isEmpty || !Set(cl).isSuperset(of: r.classes) { return false }
        } else if !e.effects.contains(x) {
            return false
        }
    }
    return true
}

/// SPEC §6.2 ⟨0.41⟩ *Matching*. `rows` are the rows each producing rule line made; `unevaluated` holds the KEYS
/// (`acceptRuleKey`) of the rules this route could not evaluate; `twinNames` the names borne by two units of
/// this run with different identities.
///
/// Entries are INDEPENDENT: a row is accepted if any usable entry covers it, nothing is unioned across entries,
/// and each entry is judged stale or not on its own. `who` prefixes the human sentences.
public func settleAccepts(_ entries: [AcceptEntry], rows: [AcceptRow], unevaluated: Set<String>,
                          twinNames: Set<String>, who: String) -> AcceptSettlement {
    var s = AcceptSettlement()
    if entries.isEmpty { return s }
    func usable(_ e: AcceptEntry) -> Bool { !unevaluated.contains(e.ruleKey) && !twinNames.contains(e.fn) }
    var direct: [Int: [Int]] = [:]            // entry line -> accepted row indices
    for (i, r) in rows.enumerated() {
        for e in entries where usable(e) && e.ruleKey == r.ruleKey && e.fn == r.name && acceptCovers(e, r) {
            s.acceptedRows.insert(i)
            direct[e.line, default: []].append(i)
        }
    }
    var items: [AcceptItem] = []
    for e in entries {
        if unevaluated.contains(e.ruleKey) {
            items.append(AcceptItem(rule: e.code, fn: e.fn, hash: "", effects: e.effects, line: e.line,
                                    policyRule: e.ruleKey, because: e.because, status: "unjudged"))
            s.notes.append("\(who): policy line \(e.line) (`\(e.text.trimmingCharacters(in: .whitespaces))`) is UNJUDGED — its rule "
                           + "`\(e.ruleKey)` could not be evaluated on this route, so nothing was accepted by it. Gate at scan time "
                           + "(`\(who) <dir> --policy …`) to judge it.")
            continue
        }
        if twinNames.contains(e.fn) {
            items.append(AcceptItem(rule: e.code, fn: e.fn, hash: "", effects: e.effects, line: e.line,
                                    policyRule: e.ruleKey, because: e.because, status: "ambiguous"))
            s.notes.append("\(who): policy line \(e.line) (`\(e.text.trimmingCharacters(in: .whitespaces))`) is AMBIGUOUS — two units in this run "
                           + "are named `\(e.fn)` with different identities, so it accepts NEITHER. Gate the modules separately "
                           + "(one policy file per separately-gated module) so each name is one unit.")
            continue
        }
        if let first = direct[e.line]?.first {
            let r = rows[first]
            items.append(AcceptItem(rule: r.code, fn: r.name, hash: r.hash, effects: r.effects.sorted(by: byCodePoint),
                                    line: e.line, policyRule: e.ruleKey, because: e.because, status: "accepted"))
            continue
        }
        if let i = rows.indices.first(where: { !s.acceptedRows.contains($0) && rows[$0].ruleKey == e.ruleKey && rows[$0].name == e.fn }) {
            items.append(AcceptItem(rule: e.code, fn: e.fn, hash: "", effects: e.effects, line: e.line,
                                    policyRule: e.ruleKey, because: e.because, status: "exceeded"))
            s.notes.append("\(who): policy line \(e.line) (`\(e.text.trimmingCharacters(in: .whitespaces))`) no longer covers `\(e.fn)`: it now performs "
                           + "{ \(rows[i].effects.joined(separator: ", ")) } under `\(e.ruleKey)`, more than the "
                           + "{ \(e.effects.joined(separator: ", ")) } accepted. The violation stays red. Review the new behaviour; "
                           + "if it is intended, widen the entry to list it, otherwise fix the code.")
            continue
        }
        s.stale.append(e)
    }
    s.items = items.sorted {
        if $0.line != $1.line { return $0.line < $1.line }
        if $0.fn != $1.fn { return byCodePoint($0.fn, $1.fn) }
        return byCodePoint($0.hash, $1.hash)
    }
    return s
}

/// The AS-EFF-012 sentence for a stale entry: names the policy line and says deleting it is the remedy.
public func staleAcceptDetail(_ e: AcceptEntry) -> String {
    "`\(e.fn)` has a STALE acceptance — policy line \(e.line) (`\(e.text.trimmingCharacters(in: .whitespaces))`) matched no violation of "
    + "`\(e.ruleKey)`. Delete line \(e.line): left in place it would accept whatever a later edit puts under that key"
}
