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
/// ⟨0.24⟩ Returns the alias map AND the tokens it could not honour. An unrecognised class token inside a
/// DEFINITION is the sharpest form of the §6.2 rule (candor-spec `be0b9a9`): the typo is in the vocabulary
/// the policy is written AGAINST rather than in the policy itself, so `unknown-alias corp = dispatch,nativ`
/// silently defines `corp` as `{dispatch}` and the gate goes green on a native hole that
/// `= dispatch,native` catches. Same treatment as a policy-side token — the GATE routes refuse, the
/// advisory readers are unchanged.
public func parseUnknownAliases(_ configText: String?) -> (aliases: [String: Set<String>], errors: [String]) {
    var out: [String: Set<String>] = [:]
    var errors: [String] = []
    guard let configText else { return (out, errors) }
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
            else { errors.append(policyClassTokenError(cn, "unknown-alias \(name) = …")) }
        }
        if classes.isEmpty { FileHandle.standardError.write("candor: ignoring `unknown-alias \(name)` — no valid reason-class\n".data(using: .utf8)!) }
        else { out[name] = classes }
    }
    return (out, errors)
}

/// ⟨0.20⟩ Parse `net-partner <host>` lines (NET-DESTINATION-CLASS-DESIGN.md) into a set of host-normalized
/// partner hosts — the per-project `known-partner` set for the Net destination-class classifier. Multi-value
/// (repeatable key); the value's `:port` is stripped + lowercased like `MODEL_HOSTS`. Case-insensitive key,
/// mirroring `parseUnknownAliases` + the java/rust/ts config loaders. A partner is per-project — never universal.
public func parseNetPartners(_ configText: String?) -> Set<String> {
    var out = Set<String>()
    guard let configText else { return out }
    for raw in configText.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.first?.lowercased() == "net-partner", parts.count > 1 else { continue }
        let val = parts[1].trimmingCharacters(in: .whitespaces)
        if !val.isEmpty { out.insert(hostPart(val).lowercased()) }
    }
    return out
}

/// Map a raw `unknownWhy` token (e.g. `reflect:eval`, `callback:fetch`) to its normative reason class.
public func reasonClass(_ why: String) -> String {
    let w = why.trimmingCharacters(in: .whitespaces).lowercased()
    // PREFIX, not equality, on the second arm. SPEC §6.2's table is titled "raw `unknownWhy` PREFIXES it
    // projects" and lists `dynamicMemberLookup` under `reflect`; the equality test could never match what
    // this engine EMITS, because every reason is `kind:detail` and the only reflect-class producer in
    // candor-swift writes `dynamicMemberLookup:<root>.<prop>`. So `Unknown[reflect]` was SILENTLY
    // UNSATISFIABLE here — a policy author narrowing the ⟨0.19⟩ gate to reflection holes got exit 0 on a
    // report that discloses one, while bare `Unknown` fired and `Unknown[unresolved]` fired, so the hole
    // was invisible unless you compared the arms. The same equality test is in candor-ts `policy.mjs` and
    // candor-java `model/ReasonClass.java`; neither engine EMITS the token (swift is the only one with
    // `@dynamicMemberLookup`), so it is latent there and live here.
    if w.hasPrefix("reflect") || w.hasPrefix("dynamicmemberlookup") { return "reflect" }
    if w.hasPrefix("native") { return "native" }
    if w.hasPrefix("callback") || w.hasPrefix("closure") || w.hasPrefix("task-handoff") { return "indirect" }
    if w.hasPrefix("dispatch") || w.hasPrefix("indy") || w.hasPrefix("ambiguous") { return "dispatch" }
    if w.hasPrefix("missing-config") || w.hasPrefix("no-tsconfig") || w.hasPrefix("no-node_modules") { return "setup" }
    return "unresolved" // conservative catch-all
}

/// The accepted `--class` token set, spelled ONCE (SPEC §6.2 ⟨0.24⟩ THE FLAG'S VALUE GRAMMAR): the six
/// reason classes plus the two aliases. `dynamic` is in the set because §6.2's own normative diagnostic
/// (`--class dynamic` == unfiltered minus the setup-only entries) is stated in terms of it — an engine
/// that rejected it as unrecognised would fail the standing test every engine carries.
public let CLASS_FILTER_TOKENS = "reflect, dispatch, indirect, native, unresolved, setup (aliases: dynamic, *)"

/// An unrecognised `--class` token. It carries the FINISHED diagnostic rather than just the token, so the
/// CLI cannot re-word the message into a second, drifting statement of the same rule.
public struct ClassFilterUsageError: Error {
    public let token: String
    public init(token: String) { self.token = token }
    public var message: String {
        "candor-swift: --class: unrecognised reason-class `\(token)`\n"
        + "  accepted: \(CLASS_FILTER_TOKENS)\n"
        + "  a --class value that cannot be honoured is refused, not dropped: dropping it would narrow "
        + "the filter and answer a question you did not ask, with a smaller number (SPEC §6.2 ⟨0.24⟩)"
    }
}

/// ⟨0.20⟩ Parse a `--class <c,…>` filter into reason classes; value grammar pinned normative at §6.2
/// ⟨0.24⟩: ONE comma-separated list of the six tokens, `dynamic` (every GENUINE class — all six MINUS
/// `setup`), or `*` (all six). nil spec ⇒ nil (no filter).
///
/// AN UNRECOGNISED TOKEN THROWS, and the caller turns that into exit 2. This is deliberately NOT the
/// policy side's drop-with-a-warning, and the asymmetry reads as an inconsistency until it is written
/// down: a token dropped out of `deny E Unknown[reflect,dyanmic]` leaves the WIDER rule standing, so the
/// mistake is loud — the gate over-fires and somebody comes to look. The same token dropped out of
/// `--class` leaves a NARROWER filter, and a narrower filter on `unverified` comes back as a SMALLER
/// NUMBER, which is indistinguishable from a real all-clear in the one verb whose whole job is to say
/// "green, but not provably so". That is precisely the fail-open §6.2 exists to close. A query flag that
/// cannot be honoured is refused, not approximated.
public func parseClassFilter(_ spec: String?) throws -> Set<String>? {
    guard let spec else { return nil }
    var out = Set<String>()
    var star = false
    for rawT in spec.split(separator: ",", omittingEmptySubsequences: false) {
        let t = rawT.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        if t == "*" { star = true }
        else if t == "dynamic" { DYNAMIC_CLASSES.forEach { out.insert($0) } }
        else if REASON_CLASSES.contains(t) { out.insert(t) }
        else { throw ClassFilterUsageError(token: t) }
    }
    // `*` is honoured only after the WHOLE list is walked, so `--class *,dyanmic` still reports the typo
    // instead of short-circuiting past it: the refusal must not depend on token order.
    if star { return Set(REASON_CLASSES) }
    return out
}

public struct DenyRule { public var effects: [String]; public var scope: String; public var unknownClasses: [String]; public var netClasses: [String]; public var raw: String }
public struct AllowRule { public var effect: String; public var scope: String; public var values: [String]; public var raw: String }
public struct ForbidRule { public var from: String; public var to: String; public var raw: String }

/// A parsed §6.2 policy. The three rule lists are what they always were; `errors` is ⟨0.24⟩.
///
/// **`errors` IS NOT A PARSE FAILURE — the rules are still built, and the ADVISORY readers
/// (`parsepolicy`, `unverified`, `fix`, `fix-gate`) are unchanged.** It is the GATE routes that must
/// refuse on it: `scan --policy` and `gate --report`, before any verdict is derived. Keeping the parse
/// intact is deliberate — `parsepolicy` is the conformance suite's grammar witness (PART 4), and its
/// battery deliberately contains a rule with an unrecognised token; a parser that refused would delete
/// the witness rather than fix the gate.
public struct ParsedPolicy {
    public var deny: [DenyRule]
    public var allow: [AllowRule]
    public var forbid: [ForbidRule]
    /// ⟨0.24⟩ Finished diagnostics for tokens that could not be honoured AS WRITTEN (SPEC §6.2,
    /// candor-spec `382a7e0`). See `parsePolicy` for the measurement.
    public var errors: [String]
    /// ⟨0.24⟩ The `unknown-alias` names this policy actually CONSUMED — sorted, deduped, and empty unless
    /// a config alias was used to expand a token. It is the trigger for SPEC §3.1's ambience disclosure:
    /// the verdict names the config file only when that file's vocabulary PARTICIPATED, never merely
    /// because a config exists. A config that defines ten aliases and is asked for none is not an input
    /// to this verdict and naming it would be noise.
    public var usedAliases: [String]
    public init(deny: [DenyRule], allow: [AllowRule], forbid: [ForbidRule], errors: [String] = [],
                usedAliases: [String] = []) {
        self.deny = deny; self.allow = allow; self.forbid = forbid
        self.errors = errors; self.usedAliases = usedAliases
    }
}

func warnRule(_ why: String, _ line: String) {
    FileHandle.standardError.write("candor: ignoring policy rule (\(why)): \(line)\n".data(using: .utf8)!)
}

/// ⟨0.24⟩ **AN UNRECOGNISED REASON-CLASS TOKEN IN A POLICY IS A POLICY ERROR** (SPEC §6.2, candor-spec
/// `382a7e0`, which WITHDRAWS its own asymmetry argument). The clause used to justify the query/policy
/// asymmetry by asserting that dropping an unrecognised class token on the policy side can only WIDEN a
/// rule, so the failure is loud. Measured four-way, it does both, and the common case is the fail-open one:
///
///     deny Unknown[corp]              sole unrecognised token — the filter empties and the rule WIDENS to
///                                     a bare `deny Unknown`, while the engine prints "ignoring policy
///                                     rule" and then KEEPS and re-scopes it. A FALSE DISCLOSURE, the
///                                     `net-partner` class PART 13b exists for.
///     deny Unknown[dispatch,nativ]    a typo BESIDE valid tokens — silently dropped, the rule NARROWS to
///                                     `[dispatch]`, and it no longer gates native-caused holes at all
///                                     while the operator reads a gate that looks armed. FAIL-OPEN, and a
///                                     typo lands beside correct tokens far more often than alone.
///
/// MEASURED on this engine, `gate --report` over a one-entry report whose only hole is `native:` —
/// `[dispatch,nativ]` exited **0** and `[corp]` exited 1 with the false "ignoring" line. A policy that
/// cannot be honoured as written is not silently rewritten into a different policy.
public let POLICY_CLASS_TOKENS = "reflect, dispatch, indirect, native, unresolved, setup "
    + "(aliases: dynamic, *, or a `.candor/config` `unknown-alias`)"
/// The `Net[<dest…>]` sibling. ⟨0.24⟩ candor-spec `be0b9a9` widened the ruling from "reason-class" to
/// EVERY policy value list the implementation cannot honour as written: the clause's argument never
/// mentioned which vocabulary the token belonged to, and every place the rule stayed narrow was a place
/// the same fail-open survived under a different key.
func policyDestClassTokenError(_ token: String, _ line: String) -> String {
    "candor: policy error — unrecognised Net destination-class `\(token)` in: \(line)\n"
    + "  accepted: \(NET_DEST_CLASSES.sorted().joined(separator: ", ")) (alias: *)\n"
    + "  a policy that cannot be honoured AS WRITTEN is not silently rewritten into a different policy: "
    + "dropping the token beside valid ones NARROWS the rule (it stops gating the destinations you meant, "
    + "while the gate still looks armed), and dropping the only token WIDENS it. Refusing (exit 2) — "
    + "SPEC §6.2 ⟨0.24⟩"
}
func policyClassTokenError(_ token: String, _ line: String) -> String {
    "candor: policy error — unrecognised reason-class/alias `\(token)` in: \(line)\n"
    + "  accepted: \(POLICY_CLASS_TOKENS)\n"
    + "  a policy that cannot be honoured AS WRITTEN is not silently rewritten into a different policy: "
    + "dropping the token beside valid ones NARROWS the rule (it stops gating the class you meant, while "
    + "the gate still looks armed), and dropping the only token WIDENS it. Refusing (exit 2) — SPEC §6.2 ⟨0.24⟩"
}

public func parsePolicy(_ text: String, aliases: [String: Set<String>] = [:]) -> ParsedPolicy {
    var deny: [DenyRule] = [], allow: [AllowRule] = [], forbid: [ForbidRule] = []
    var errors: [String] = []
    var usedAliases = Set<String>()
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
            // Destination-class filter on a `Net` membership (NET-DESTINATION-CLASS-DESIGN.md): empty ⇒
            // `Net[*]` (any destination — the bare form); non-empty ⇒ only those classes. `*` = all.
            var netClasses = Set<String>(); var netStar = false
            for tok in t.dropFirst() {
                if tok.hasPrefix("Net["), tok.hasSuffix("]") {
                    effects.append("Net")
                    let inner = String(tok.dropFirst("Net[".count).dropLast())
                    for rawCn in inner.split(separator: ",", omittingEmptySubsequences: false) {
                        let cn = rawCn.trimmingCharacters(in: .whitespaces)
                        if cn.isEmpty { continue }
                        if cn == "*" { netStar = true }
                        else if NET_DEST_CLASSES.contains(cn) { netClasses.insert(cn) }
                        // ⟨0.24⟩ Same rule as the reason-class token (candor-spec `be0b9a9`): measured,
                        // `deny Net[known-telemetry,unknown-hosst]` exits 0 where the correctly-spelled
                        // rule exits 1. The clause was never about reason-classes — it is about a policy
                        // value list the implementation cannot honour as written.
                        else { errors.append(policyDestClassTokenError(cn, line)) }
                    }
                    continue
                }
                if tok.hasPrefix("Unknown["), tok.hasSuffix("]") {
                    effects.append("Unknown")
                    let inner = String(tok.dropFirst("Unknown[".count).dropLast())
                    for rawCn in inner.split(separator: ",", omittingEmptySubsequences: false) {
                        let cn = rawCn.trimmingCharacters(in: .whitespaces)
                        if cn.isEmpty { continue }
                        if cn == "*" { unknownStar = true }
                        else if cn == "dynamic" { DYNAMIC_CLASSES.forEach { unknownClasses.insert($0) } }
                        else if REASON_CLASSES.contains(cn) { unknownClasses.insert(cn) }
                        // ⟨0.19⟩ config unknown-alias — RECORDED as used, because ⟨0.24⟩ SPEC §3.1 makes
                        // the verdict name the config file whose vocabulary participated in it.
                        else if let a = aliases[cn] { unknownClasses.formUnion(a); usedAliases.insert(cn) }
                        // ⟨0.24⟩ RECORDED, not warned-and-dropped. The old line said "ignoring policy
                        // rule" and then KEPT the rule — a false disclosure — or dropped the token and
                        // silently NARROWED the rule. See `policyClassTokenError`. The rule is still
                        // BUILT (the advisory readers are unchanged); the gate routes refuse on `errors`.
                        else { errors.append(policyClassTokenError(cn, line)) }
                    }
                    continue
                }
                if EFFECTS.contains(tok) || tok == "Unknown" {
                    effects.append(tok)
                    if tok == "Unknown" { unknownStar = true } // bare Unknown ⇒ all classes
                    if tok == "Net" { netStar = true }         // bare Net ⇒ all destinations
                } else { scope = tok; break }
            }
            if effects.isEmpty { warnRule("deny names no known effect", line); continue }
            // `*` (or bare Unknown) means all classes ⇒ empty filter (matches any Unknown).
            let uc = unknownStar ? [] : unknownClasses.sorted()
            // `*` (or bare Net) means all destinations ⇒ empty filter (matches any Net).
            let nc = netStar ? [] : netClasses.sorted()
            // A2 under-gating lint: a narrowed scope omitting `unresolved` (the catch-all for holes the
            // engine couldn't classify) may silently tolerate exactly those — flag it (advisory). NOT via
            // warnRule: the rule is KEPT (it still gates), so "ignoring policy rule" would be wrong wording.
            if !uc.isEmpty, !uc.contains("unresolved") {
                FileHandle.standardError.write("candor: policy rule narrows `Unknown[…]` but omits `unresolved` — may UNDER-gate on holes the engine couldn't classify; add `unresolved` (or use `dynamic`): \(line)\n".data(using: .utf8)!)
            }
            // Duplicate effect tokens dedup to a SET (`deny Net Net` ≡ `deny Net`) — the reference
            // parser's EffectSet semantics; without it the parsepolicy dump (conformance PART 4)
            // diverges on the battery's duplicate-token case. Gate verdicts were already unaffected.
            deny.append(DenyRule(effects: Array(Set(effects)).sorted(), scope: scope, unknownClasses: uc, netClasses: nc, raw: line))
        case "pure":
            deny.append(DenyRule(effects: [], scope: t.count > 1 ? t[1] : "", unknownClasses: [], netClasses: [], raw: line))
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
    return ParsedPolicy(deny: deny, allow: allow, forbid: forbid, errors: errors,
                        usedAliases: usedAliases.sorted())
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
