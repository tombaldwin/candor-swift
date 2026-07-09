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

public let EFFECTS: Set<String> = ["Net", "Fs", "Db", "Exec", "Env", "Clock", "Ipc", "Log", "Rand", "Clipboard"]
public let ALLOW_EFFECTS: Set<String> = ["Net", "Exec", "Fs", "Db"]

public struct DenyRule { public var effects: [String]; public var scope: String; public var raw: String }
public struct AllowRule { public var effect: String; public var scope: String; public var values: [String]; public var raw: String }
public struct ForbidRule { public var from: String; public var to: String; public var raw: String }

func warnRule(_ why: String, _ line: String) {
    FileHandle.standardError.write("candor: ignoring policy rule (\(why)): \(line)\n".data(using: .utf8)!)
}

public func parsePolicy(_ text: String) -> (deny: [DenyRule], allow: [AllowRule], forbid: [ForbidRule]) {
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
            for tok in t.dropFirst() {
                if EFFECTS.contains(tok) || tok == "Unknown" { effects.append(tok) } else { scope = tok; break }
            }
            if effects.isEmpty { warnRule("deny names no known effect", line); continue }
            // Duplicate effect tokens dedup to a SET (`deny Net Net` ≡ `deny Net`) — the reference
            // parser's EffectSet semantics; without it the parsepolicy dump (conformance PART 4)
            // diverges on the battery's duplicate-token case. Gate verdicts were already unaffected.
            deny.append(DenyRule(effects: Array(Set(effects)).sorted(), scope: scope, raw: line))
        case "pure":
            deny.append(DenyRule(effects: [], scope: t.count > 1 ? t[1] : "", raw: line))
        case "allow":
            guard t.count >= 3 else { warnRule("allow names no values", line); continue }
            guard ALLOW_EFFECTS.contains(t[1]) else {
                warnRule("allow supports only Net hosts / Exec commands / Fs paths / Db tables", line); continue
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
    case "Net": return values.contains { hostPart($0) == hostPart(reached) }
    case "Exec": return values.contains { cmdBase($0) == cmdBase(reached) }
    case "Fs": return values.contains { pathCovered($0, reached) }
    case "Db": return values.contains { dbTableCovered($0, reached) }
    default: return false
    }
}
