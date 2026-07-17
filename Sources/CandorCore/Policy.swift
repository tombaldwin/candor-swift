// The PURE §6.2 policy-DSL parser + literal-surface matchers, factored out of the executable so they
// get DIRECT unit tests (an executable target cannot be `@testable import`ed): the CRLF/bare-\r line
// splitting, the ASCII-only whitespace tokenizer (NBSP stays in its token), the IPv6-aware host part,
// the `..`-rejecting path cover and the schema-qualified table cover all carry cross-engine gate-verdict
// semantics that deserve pins at the function boundary, not just through the process-level exit-code
// matrix (GateProcessTests / smoke.sh, which stay as the end-to-end layer).

import Foundation

/// SwiftSyntax segment text is SOURCE-ACCURATE: `"a\nb"` arrives with a literal backslash-n.
/// The four-way conformance differential caught this on the engine's FIRST wiring (the Java
/// space-escape bug's twin: multi-line SQL glued, quoted identifiers kept their backslashes).
public func decodeEscapes(_ raw: String) -> String {
    var out = ""
    var it = raw.makeIterator()
    while let c = it.next() {
        guard c == "\\", let n = it.next() else { out.append(c); continue }
        switch n {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "0": out.append("\0")
        case "\\": out.append("\\")
        case "\"": out.append("\"")
        case "'": out.append("'")
        default: out.append(c); out.append(n) // unknown escape (\u{…} etc.): keep raw, never guess
        }
    }
    return out
}

/// The hostname part of a `host[:port]` literal — scheme and path stripped, then the trailing `:port`
/// dropped so `allow Net api.stripe.com` covers a reached `api.stripe.com:443` (SPEC §6.2: a Net host
/// matches by hostname with the port ignored). IPv6-aware, mirroring Rust's `host_part`: a bracketed
/// `[host]:port` yields the bracketed host, and a BARE IPv6 literal (>1 colon, no brackets) has no port
/// to strip and is returned whole — a naive first-colon split would collapse every `2001:db8::*` to
/// `2001`, accepting any address in that block. A hostname/IPv4 `host`/`host:port` (≤1 colon) splits at
/// the colon. Was a live cross-engine gate-verdict divergence: Swift kept the port, Rust/Java/TS didn't.
// The §2 host SURFACE value: scheme + path stripped, but the statically-known PORT KEPT
// (`https://api.example.com:8080/x` → `api.example.com:8080`) — the conformance suite's [4e] pins that
// the port is part of the surface, so it must NOT be dropped here.
public func hostPort(_ s: String) -> String {
    var h = s
    for scheme in ["https://", "http://", "wss://", "ws://", "tcp://"] where h.hasPrefix(scheme) {
        h = String(h.dropFirst(scheme.count))
    }
    if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
    return h
}

// `hostPort` with the :port ALSO stripped — for port-INSENSITIVE policy matching (spec §6.2: a Net host
// matches by hostname with the port ignored, `api.stripe.com` allows `api.stripe.com:443`). Used only at
// match time (both the allow value and the reached surface are stripped), never on the stored surface.
public func hostPart(_ s: String) -> String {
    let h = hostPort(s)
    if h.hasPrefix("[") {
        // `[ipv6]` or `[ipv6]:port` — the host is between the brackets.
        let inner = String(h.dropFirst())
        if let close = inner.firstIndex(of: "]") { return String(inner[..<close]) }
        return inner
    }
    if h.filter({ $0 == ":" }).count > 1 { return h }  // bare IPv6 literal — no port suffix to strip
    if let colon = h.firstIndex(of: ":") { return String(h[..<colon]) }
    return h
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// §6.2 policy DSL (deny / pure / allow / forbid) — token-for-token with the family parsers
// ════════════════════════════════════════════════════════════════════════════════════════════════

// SPEC §1 ⟨0.13⟩ `Llm` joins the vocabulary — a boundary effect (§6.1) refining Net the way Db does.
// `privacy/1` SPEC EXTENSION (SPEC-EXTENSION-privacy.md) adds the six Apple privacy-sensor effects —
// boundary effects (§6.1) like Clipboard, gate-able through the normal §6.2 grammar (`deny Location ui`).
// They are NOT in ALLOW_EFFECTS: a sensor read has no host/path/command literal to certify, so
// `deny Location`/containment applies but `allow Location <x>` is not a thing (same as Ipc/Clipboard).
public let EFFECTS: Set<String> = ["Net", "Fs", "Db", "Exec", "Env", "Clock", "Ipc", "Log", "Rand", "Clipboard", "Llm",
    "Location", "Camera", "Mic", "Contacts", "Photos", "Notify"]
// `Llm` ⟨0.13⟩ takes an `allow Llm <host…>` allowlist — it rides Net's host literal (a model host WAS
// captured as a Net host), so it is allowlistable exactly like Net (matched by hostname; the gate keys
// its incompleteness off Net's — a runtime/masked host fails `allow Llm` closed too).
public let ALLOW_EFFECTS: Set<String> = ["Net", "Exec", "Fs", "Db", "Llm"]

// Reason-scoped Unknown (REASON-SCOPED-UNKNOWN-DESIGN.md): the CLOSED, cross-engine reason-class set a
// `deny E Unknown[class…]` rule quantifies over. Must be IDENTICAL to candor-java's ReasonClass and the
// rust/ts ports — `reasonClass(_:)` mirrors java's prefix-based ReasonClass.classify(String).
public let REASON_CLASSES = ["reflect", "dispatch", "indirect", "native", "unresolved", "setup"]
// `dynamic` = every GENUINE blind-spot class (excludes `setup`), incl. `unresolved` so it never under-gates.
let DYNAMIC_CLASSES = ["reflect", "dispatch", "indirect", "native", "unresolved"]
/// ⟨0.19⟩ Parse `unknown-alias <name> = <class,…>` lines from `.candor/config` TEXT (SPEC §6.2) into a
/// name→classes map. A name that shadows a built-in (`*`/`dynamic`/a class token) is warned-and-skipped (a
/// config alias may not redefine a built-in), as is a definition naming no valid class. Byte-shape with the
/// java `Config.addAlias` / rust `parse_unknown_aliases`.
public func parseUnknownAliases(_ configText: String?) -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    guard let configText else { return out }
    for raw in configText.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.first?.lowercased() == "unknown-alias", parts.count > 1 else { continue }
        let val = parts[1].trimmingCharacters(in: .whitespaces)
        guard let eq = val.firstIndex(of: "=") else {
            FileHandle.standardError.write("candor: ignoring `unknown-alias` (want `unknown-alias <name> = <class,…>`): \(val)\n".data(using: .utf8)!)
            continue
        }
        let name = val[val.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "*" || name == "dynamic" || REASON_CLASSES.contains(name) {
            FileHandle.standardError.write("candor: ignoring `unknown-alias` with reserved/empty name `\(name)` (may not shadow `*`/`dynamic`/a class token)\n".data(using: .utf8)!)
            continue
        }
        var classes = Set<String>()
        for rawCn in val[val.index(after: eq)...].split(separator: ",", omittingEmptySubsequences: false) {
            let cn = rawCn.trimmingCharacters(in: .whitespaces)
            if cn.isEmpty { continue }
            if cn == "dynamic" { DYNAMIC_CLASSES.forEach { classes.insert($0) } }
            else if REASON_CLASSES.contains(cn) { classes.insert(cn) }
            else { FileHandle.standardError.write("candor: `unknown-alias \(name)` names unknown reason-class `\(cn)` — skipped\n".data(using: .utf8)!) }
        }
        if classes.isEmpty { FileHandle.standardError.write("candor: ignoring `unknown-alias \(name)` — no valid reason-class\n".data(using: .utf8)!) }
        else { out[name] = classes }
    }
    return out
}

/// Map a raw `unknownWhy` token (e.g. `reflect:eval`, `callback:fetch`) to its normative reason class.
public func reasonClass(_ why: String) -> String {
    let w = why.trimmingCharacters(in: .whitespaces).lowercased()
    if w.hasPrefix("reflect") || w == "dynamicmemberlookup" { return "reflect" }
    if w.hasPrefix("native") { return "native" }
    if w.hasPrefix("callback") || w.hasPrefix("closure") || w.hasPrefix("task-handoff") { return "indirect" }
    if w.hasPrefix("dispatch") || w.hasPrefix("indy") || w.hasPrefix("ambiguous") { return "dispatch" }
    if w.hasPrefix("missing-config") || w.hasPrefix("no-tsconfig") || w.hasPrefix("no-node_modules") { return "setup" }
    return "unresolved" // conservative catch-all
}

/// ⟨0.20⟩ Parse a `--class <c,…>` filter into reason classes: the six tokens, `dynamic` (every genuine
/// class), or `*` (all). nil spec ⇒ nil (no filter); an unknown token warns; an all-unknown spec ⇒ an
/// empty set that matches nothing. Shared shape with the java/rust/ts `parseClassFilter`.
public func parseClassFilter(_ spec: String?) -> Set<String>? {
    guard let spec else { return nil }
    var out = Set<String>()
    for rawT in spec.split(separator: ",", omittingEmptySubsequences: false) {
        let t = rawT.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        if t == "*" { return Set(REASON_CLASSES) }
        if t == "dynamic" { DYNAMIC_CLASSES.forEach { out.insert($0) } }
        else if REASON_CLASSES.contains(t) { out.insert(t) }
        else { FileHandle.standardError.write("candor-swift: --class ignores unknown reason-class `\(t)` (known: \(REASON_CLASSES.joined(separator: ",")); aliases: dynamic,*)\n".data(using: .utf8)!) }
    }
    return out
}

public struct DenyRule { public var effects: [String]; public var scope: String; public var unknownClasses: [String]; public var raw: String }
public struct AllowRule { public var effect: String; public var scope: String; public var values: [String]; public var raw: String }
public struct ForbidRule { public var from: String; public var to: String; public var raw: String }

func warnRule(_ why: String, _ line: String) {
    FileHandle.standardError.write("candor: ignoring policy rule (\(why)): \(line)\n".data(using: .utf8)!)
}

public func parsePolicy(_ text: String, aliases: [String: Set<String>] = [:]) -> (deny: [DenyRule], allow: [AllowRule], forbid: [ForbidRule]) {
    var deny: [DenyRule] = [], allow: [AllowRule] = [], forbid: [ForbidRule] = []
    // Split LINES on \n / \r\n / bare \r — the three forms Java's Files.readAllLines (the reference parser)
    // breaks on. Splitting on \n ONLY let a classic-Mac (bare-\r) file collapse to ONE line: \r is also an
    // in-line ASCII-ws token separator (§6.2), so every rule after the first was glued into the first rule's
    // tokens and dropped — a gateless-green divergence (sweep [16]/[17]). Normalize first; \v/\f stay in-line
    // token separators (Java's readLine does not break on them either).
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
        // The §6.2 token separator is ASCII whitespace ONLY. `.whitespaces`/`Character.isWhitespace` are
        // Unicode — they'd split a NBSP/ideographic space that Java drops (a gateless-green divergence;
        // adversarial DSL review). `isASCII && isWhitespace` keeps space/tab/CR/LF/VT/FF and excludes the
        // non-ASCII spaces, so a NBSP stays part of its token → the rule is malformed and dropped.
        let asciiWS = CharacterSet(charactersIn: " \t\n\u{0B}\u{0C}\r")
        let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: asciiWS)
        if line.isEmpty { continue }
        let t = line.split(whereSeparator: { $0.isASCII && $0.isWhitespace }).map(String.init)
        switch t[0] {
        case "deny":
            var effects: [String] = []; var scope = ""
            // Reason-class filter on an `Unknown` membership: empty ⇒ `Unknown[*]` (any reason — the bare
            // form); non-empty ⇒ only those classes. `*` = all; `dynamic` = every genuine class.
            var unknownClasses = Set<String>(); var unknownStar = false
            for tok in t.dropFirst() {
                if tok.hasPrefix("Unknown["), tok.hasSuffix("]") {
                    effects.append("Unknown")
                    let inner = String(tok.dropFirst("Unknown[".count).dropLast())
                    for rawCn in inner.split(separator: ",", omittingEmptySubsequences: false) {
                        let cn = rawCn.trimmingCharacters(in: .whitespaces)
                        if cn.isEmpty { continue }
                        if cn == "*" { unknownStar = true }
                        else if cn == "dynamic" { DYNAMIC_CLASSES.forEach { unknownClasses.insert($0) } }
                        else if REASON_CLASSES.contains(cn) { unknownClasses.insert(cn) }
                        else if let a = aliases[cn] { unknownClasses.formUnion(a) }  // ⟨0.19⟩ config unknown-alias
                        else { warnRule("unknown reason-class/alias `\(cn)` (known: \(REASON_CLASSES.joined(separator: ",")); aliases: dynamic,*, or a config `unknown-alias`)", line) }
                    }
                    continue
                }
                if EFFECTS.contains(tok) || tok == "Unknown" {
                    effects.append(tok)
                    if tok == "Unknown" { unknownStar = true } // bare Unknown ⇒ all classes
                } else { scope = tok; break }
            }
            if effects.isEmpty { warnRule("deny names no known effect", line); continue }
            // `*` (or bare Unknown) means all classes ⇒ empty filter (matches any Unknown).
            let uc = unknownStar ? [] : unknownClasses.sorted()
            // A2 under-gating lint: a narrowed scope omitting `unresolved` (the catch-all for holes the
            // engine couldn't classify) may silently tolerate exactly those — flag it (advisory). NOT via
            // warnRule: the rule is KEPT (it still gates), so "ignoring policy rule" would be wrong wording.
            if !uc.isEmpty, !uc.contains("unresolved") {
                FileHandle.standardError.write("candor: policy rule narrows `Unknown[…]` but omits `unresolved` — may UNDER-gate on holes the engine couldn't classify; add `unresolved` (or use `dynamic`): \(line)\n".data(using: .utf8)!)
            }
            // Duplicate effect tokens dedup to a SET (`deny Net Net` ≡ `deny Net`) — the reference
            // parser's EffectSet semantics; without it the parsepolicy dump (conformance PART 4)
            // diverges on the battery's duplicate-token case. Gate verdicts were already unaffected.
            deny.append(DenyRule(effects: Array(Set(effects)).sorted(), scope: scope, unknownClasses: uc, raw: line))
        case "pure":
            deny.append(DenyRule(effects: [], scope: t.count > 1 ? t[1] : "", unknownClasses: [], raw: line))
        case "allow":
            guard t.count >= 3 else { warnRule("allow names no values", line); continue }
            guard ALLOW_EFFECTS.contains(t[1]) else {
                warnRule("allow supports only Net hosts / Llm hosts / Exec commands / Fs paths / Db tables", line); continue
            }
            var scope = ""; var vi = 2
            if t[2] == "in" { scope = t.count > 3 ? t[3] : ""; vi = 4 }
            let values = Array(t.dropFirst(vi))
            if values.isEmpty { warnRule("allow names no values", line); continue }
            // Duplicate values dedup (the reference parser's TreeSet) — same PART 4 parity as deny.
            allow.append(AllowRule(effect: t[1], scope: scope, values: Array(Set(values)).sorted(), raw: line))
        case "forbid":
            let a = t.count > 1 ? t[1] : "", arrow = t.count > 2 ? t[2] : "", b = t.count > 3 ? t[3] : ""
            if a.isEmpty || arrow != "->" || b.isEmpty { warnRule("want `forbid <scope> -> <scope>`", line); continue }
            forbid.append(ForbidRule(from: a, to: b, raw: line))
        default:
            warnRule("unknown rule kind", line)
        }
    }
    return (deny, allow, forbid)
}

/// §6.2 scope match: segment run, last segment a prefix. Segments split on BOTH `.` and `::` (empty
/// parts filtered), mirroring Rust/Java's `name_segments` — so a shared `::`-scoped policy (Rust/Swift
/// path syntax) matches Swift names too, not just dotted ones. Splitting on `:` is safe: a `:` only ever
/// appears in a `::` separator in these names, so it never over-segments (no spurious match).
public func scopeMatches(_ name: String, _ scope: String) -> Bool {
    if scope.isEmpty { return true }
    let segs = name.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
    let parts = scope.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
    if parts.isEmpty || parts.count > segs.count { return false }
    let last = parts[parts.count - 1], initParts = parts.dropLast()
    outer: for i in 0...(segs.count - parts.count) {
        for (k, ip) in initParts.enumerated() where segs[i + k] != ip { continue outer }
        if segs[i + parts.count - 1].hasPrefix(last) { return true }
    }
    return false
}

public func cmdBase(_ c: String) -> String { c.split(separator: "/").last.map(String.init) ?? c }
public func pathCovered(_ allowed: String, _ reached: String) -> Bool {
    if reached.contains("..") { return false }
    if allowed == reached { return true }
    let a = allowed.hasSuffix("/") ? allowed : allowed + "/"
    return reached.hasPrefix(a)
}
public func dbTableCovered(_ allowed: String, _ reached: String) -> Bool {
    let a = allowed.lowercased(), r = reached.lowercased()
    if a.hasSuffix(".*") { return r.hasPrefix(String(a.dropLast(2)) + ".") }
    return a == r
}
public func literalAllowed(_ effect: String, _ reached: String, _ values: [String]) -> Bool {
    switch effect {
    // `Llm` ⟨0.13⟩ rides Net's host literal — matched by hostname exactly like Net (SPEC §1).
    case "Net", "Llm": return values.contains { hostPart($0) == hostPart(reached) }
    case "Exec": return values.contains { cmdBase($0) == cmdBase(reached) }
    case "Fs": return values.contains { pathCovered($0, reached) }
    case "Db": return values.contains { dbTableCovered($0, reached) }
    default: return false
    }
}
