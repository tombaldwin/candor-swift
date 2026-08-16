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
public let EFFECTS: Set<String> = Set(["Net", "Fs", "Db", "Exec", "Env", "Clock", "Ipc", "Log", "Rand", "Clipboard", "Llm"])
    .union(PRIVACY_EFFECTS_ALL)   // derived — a policy must accept every sensor the engine can EMIT, or
                                  // `deny Health` errors while the extension spec says it gates.
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
///
/// ⟨0.24⟩ **EACH ERROR CARRIES THE ALIAS IT WAS DEFINING, because the gate may only refuse on a
/// definition the POLICY ACTUALLY CONSUMED** (SPEC §6.2 ⟨0.24⟩ + §3.1's precedence rule). Measured
/// 2026-07-28 on `deny Fs` (no bracket to expand) beside an unused `unknown-alias corp = dispatch,nativ`:
/// this engine exited 2 and DELETED the `Fs` violation, where candor-rust exited 1 and charged it. An
/// alias no rule references expands no token, so it cannot change any verdict — and a thing that cannot
/// change a verdict cannot make one unanswerable. It is at most a DISCLOSURE. Config discovery is an
/// ANCESTOR WALK, so the un-gated form let one bad token in a parent `.candor/config` red-refuse every
/// gate in the whole subtree, including gates whose policies never mention reason classes at all.
public struct AliasTokenError {
    /// the alias being DEFINED — the key the gate matches against `ParsedPolicy.usedAliases`.
    public let alias: String
    /// the token that is not a reason class.
    public let token: String
    /// the definition line, as `parsePolicy`'s `raw` would spell it.
    public let rule: String
    /// the full §6.2 refusal text (used verbatim when the definition IS consumed).
    public let message: String
    /// ⟨0.24⟩ The same record in `parsepolicy`'s `errors` shape. `gateReason` is deliberately nil: whether
    /// this definition refuses is a property of the POLICY that did or did not consume it, decided by
    /// `partitionAliasErrors`, not of the definition line on its own.
    public var policyError: PolicyError {
        PolicyError(kind: "reason-class/alias", token: token, accepted: POLICY_CLASS_TOKEN_LIST, rule: rule,
                    message: "config line NOT HONOURED AS WRITTEN — `\(token)` is not a reason class, so "
                           + "the alias `\(alias)` is defined without it")
    }
}
public func parseUnknownAliases(_ configText: String?) -> (aliases: [String: Set<String>], errors: [AliasTokenError]) {
    var out: [String: Set<String>] = [:]
    var errors: [AliasTokenError] = []
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
            else {
                errors.append(AliasTokenError(alias: name, token: cn, rule: "unknown-alias \(name) = …",
                                              message: policyClassTokenError(cn, "unknown-alias \(name) = …")))
            }
        }
        if classes.isEmpty { FileHandle.standardError.write("candor: ignoring `unknown-alias \(name)` — no valid reason-class\n".data(using: .utf8)!) }
        else { out[name] = classes }
    }
    return (out, errors)
}

/// ⟨0.24⟩ Split alias-definition token errors by whether THIS policy could have been changed by them.
/// A definition the policy CONSUMED (its name is in `ParsedPolicy.usedAliases`) expanded a token that a
/// rule reads, so a typo in it silently narrows a live rule — that is a policy error and the gate routes
/// refuse. A definition nothing consumed expanded nothing: no rule's meaning depends on it, so it cannot
/// make the verdict unanswerable, and per SPEC §3.1 a certain violation dominates a refusal anyway.
///
/// AN UNRESOLVED ALIAS IS STILL COVERED: if a definition loses ALL its tokens to typos the alias is never
/// entered in the map, so the referring `Unknown[<alias>]` token itself becomes a policy error inside
/// `parsePolicy` — the refusal happens there, on the line that actually reads it.
public func partitionAliasErrors(_ errs: [AliasTokenError], consumedBy pol: ParsedPolicy)
    -> (refusing: [AliasTokenError], disclosed: [AliasTokenError]) {
    let used = Set(pol.usedAliases)
    return (errs.filter { used.contains($0.alias) }, errs.filter { !used.contains($0.alias) })
}

/// ⟨0.24⟩ The `policyVocabulary.aliases` VALUE (SPEC §3.1, candor-spec `7f5b5ba`): each alias this policy
/// CONSUMED, mapped to the reason classes it expanded to. An OBJECT, not the array this engine first
/// shipped — `corp = reflect` and `corp = reflect,native` gate differently under one unchanged policy
/// line, so naming the alias without its content tells the reader they were affected and not how, which
/// is the same test §3.1 already applies one level up to reject `configSources: [path]`.
///
/// SHARED BY BOTH GATE ROUTES on purpose: §3.1's byte-equality between `scan --policy` and
/// `gate --report` is a MUST, and two independent constructions of the same disclosure is exactly how a
/// key gets spelled two ways (this field's own history — see Gate.swift).
///
/// An alias in `usedAliases` is by construction present in `aliases` (it is only recorded when the lookup
/// hits), so the `?? []` is unreachable rather than a silent drop; it stays because an empty class list is
/// still a truthful "this alias expanded to nothing here" and inventing a class would be worse.
public func consumedAliasVocabulary(_ pol: ParsedPolicy, _ aliases: [String: Set<String>]) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for name in pol.usedAliases { out[name] = (aliases[name].map { Array($0) } ?? []).sorted() }
    return out
}

/// The DISCLOSURE half of `partitionAliasErrors` — one stderr line per unconsumed definition error, so a
/// broken alias in an ancestor `.candor/config` is still visible without refusing a gate it cannot reach.
public func discloseUnconsumedAliasErrors(_ errs: [AliasTokenError]) {
    for e in errs {
        FileHandle.standardError.write(
            ("candor: NOTE — `\(e.rule)` names `\(e.token)`, which is not a reason class "
             + "(accepted: \(POLICY_CLASS_TOKENS)). No rule in this policy CONSUMED the alias `\(e.alias)`, "
             + "so the definition expanded no token and did not participate in this verdict — DISCLOSED, "
             + "not refused (SPEC §6.2 ⟨0.24⟩). Fix it before a rule starts referring to it.\n")
                .data(using: .utf8)!)
    }
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

/// ⟨0.24⟩ **ONE POLICY LINE THE ENGINE DID NOT HONOUR AS WRITTEN** (SPEC §3.1, candor-spec `195d45a` +
/// `901f14d`). The `parsepolicy` witness emits these as its `errors` array.
///
/// MEASURED 2026-07-28 on `candor-spec/conformance/policydsl/policy.txt`:
/// **java 10, ts 2, rust 0, swift 0** — this engine emitted no `errors` key AT ALL, while its stderr
/// listed nine policy lines dropped entirely (an unknown effect name, an `allow` on an effect with no
/// literal surface, two malformed `forbid`s, two `allow`s with no values, two unknown rule kinds) plus
/// two unrecognised tokens. **None of it reached the machine output.** A dropped rule is the limit case
/// of "silently rewritten into a different policy": the rewritten policy is the one WITHOUT that line,
/// which is a bigger rewrite than a narrowed filter, not a smaller one.
///
/// It matters more here than in the engine that prompted the clause, because THIS engine's gate already
/// REFUSES some of these lines: the parse was narrowing silently while the gate refused — two answers to
/// one question, and the witness gave the quieter one.
///
/// SHAPE IS PINNED AND NOT THIS ENGINE'S CHOICE (`901f14d`): `accepted` is an ARRAY OF TOKENS, never a
/// prose string — candor-ts emits prose, which is unparseable by the consumer the field exists for — and
/// `kind` is drawn from a CLOSED FOUR-TOKEN SET. `message` is the human sentence; `rule` is the source
/// line verbatim.
public struct PolicyError {
    /// CLOSED SET: `reason-class/alias`, `Net destination-class`, `effect-name`, `rule-kind`,
    /// `rule-form`. The trailing ellipsis the first draft left on this vocabulary was four future guesses
    /// in one ellipsis.
    ///
    /// ⟨0.24⟩ `rule-form` was added by candor-spec `f735b16` hours after the set was pinned at four: a
    /// rule whose KIND is recognised (`forbid`, `allow`) but whose FORM is malformed is described by none
    /// of the other values, and folding it into `rule-kind` — which this engine did on its first wiring —
    /// is a true statement about a set that was itself incomplete. **A closed set is only a constraint if
    /// it is closed over the DOMAIN rather than over the author's sample.** `rule-kind` now means only
    /// what it says: the leading keyword is not one of the four.
    public let kind: String
    /// the thing not recognised.
    public let token: String
    /// the admissible set, as TOKENS.
    public let accepted: [String]
    /// the source line, verbatim.
    public let rule: String
    /// the human sentence.
    public let message: String
    /// ⟨0.24⟩ The §6.2 refusal text when this error makes the GATE refuse (exit 2), nil when it is
    /// REPORTED ONLY. The distinction is the one the spec draws deliberately: an unrecognised value
    /// token, and (⟨0.24⟩ `1e1748a`) the two unambiguous effect-name cases, cannot be told from a typo,
    /// so refusing loses nothing; the genuinely ambiguous middle stays permissive and is reported either
    /// way. Keeping both in ONE list is what stops the witness and the gate answering differently.
    public let gateReason: String?
    public init(kind: String, token: String, accepted: [String], rule: String, message: String,
                gateReason: String? = nil) {
        self.kind = kind; self.token = token; self.accepted = accepted
        self.rule = rule; self.message = message; self.gateReason = gateReason
    }
    /// The wire shape, for `parsepolicy`'s `errors`.
    public var json: [String: Any] {
        ["kind": kind, "token": token, "accepted": accepted, "rule": rule, "message": message]
    }
}

/// ⟨0.28⟩ **ONE POLICY LINE THE PARSE DROPPED — text that never became a rule at all** (SPEC §6.2). The
/// zero-rule refusal fires only at ZERO survivors, so a policy where nine of ten lines were dropped
/// still answered `{"ok": true, "violations": []}` with the verdict document saying nothing about the
/// nine gates that were never asked — a 90%-gateless green, arriving at every fraction below 100%. All
/// four engines warn per ignored line on stderr, which is not the machine channel: that is the same
/// distinction that made the incomplete-analysis defect a defect.
///
/// Refusal would break the forward-compatibility leniency §6.2 defends (an engine meeting a rule kind
/// from a newer rung must not refuse the whole file), so DISCLOSURE is the remedy — the ⟨0.15⟩
/// `coverage` move. Distinct from `unevaluated`, and the distinction is load-bearing: `unevaluated`
/// carries rules that PARSED and could not be answered; this carries text that never became a rule. A
/// consumer that sees neither is entitled to believe the policy on disk is the policy that ran.
///
/// NOT the exit-2 policy errors: a typo'd effect token (`deny Nett app`, `allow Nett …`) is a policy
/// ERROR that refuses the gate (⟨0.24⟩), so it can never coexist with a verdict — this list carries only
/// the residue the leniency deliberately keeps (an unknown rule kind, a malformed `forbid`, an `allow`
/// with no values). `text` is the source line verbatim; `line` is 1-based over the §6.2 line splitting.
public struct IgnoredLine {
    public let line: Int
    public let text: String
    public let reason: String
    public var json: [String: Any] { ["line": line, "text": text, "reason": reason] }
}

/// ⟨0.29⟩ One `only <A> -> <B> [<C> …]` PERMISSION rule (AS-EFF-011): a function in scope `from` may
/// reach `from` itself and the scopes in `to`, and NOTHING else.
///
/// **`ForbidRule` FAILS OPEN; this FAILS SAFE, and that is the whole reason it exists.** A dependency you
/// forgot to prohibit is silently permitted, so "this package is a leaf" can only be spelled by
/// enumerating what it must not reach — a list that does not cover a package added tomorrow, and nothing
/// says so. That is the allowlist hazard candor refuses everywhere in the analysis, living in the POLICY
/// LANGUAGE instead.
public struct OnlyRule {
    public var from: String
    /// At least one. `only A ->` with nothing after the arrow is DROPPED as malformed.
    public var to: [String]
    public var raw: String
    public init(from: String, to: [String], raw: String) { self.from = from; self.to = to; self.raw = raw }
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
    /// ⟨0.29⟩ the `only <A> -> <B> …` PERMISSION rules — see `OnlyRule`. Their own list, not folded into
    /// `forbid`, because the two read OPPOSITE ways: a `forbid` names what must not happen, an `only`
    /// names the complete set of what may, so a route handling one as the other INVERTS the verdict
    /// rather than approximating it.
    public var only: [OnlyRule]
    /// ⟨0.24⟩ EVERY LINE THE ENGINE DID NOT HONOUR AS WRITTEN — unrecognised tokens AND dropped rules
    /// (SPEC §3.1, candor-spec `195d45a`). A subset of these also make the GATE refuse (`gateReason`);
    /// the rest are reported by the witness and stay permissive. See `PolicyError`.
    public var errors: [PolicyError]
    /// ⟨0.24⟩ The `unknown-alias` names this policy actually CONSUMED — sorted, deduped, and empty unless
    /// a config alias was used to expand a token. It is the trigger for SPEC §3.1's ambience disclosure:
    /// the verdict names the config file only when that file's vocabulary PARTICIPATED, never merely
    /// because a config exists. A config that defines ten aliases and is asked for none is not an input
    /// to this verdict and naming it would be noise.
    public var usedAliases: [String]
    /// ⟨0.28⟩ the lines the parse DROPPED without refusing — see `IgnoredLine`. Rides the verdict
    /// document as `ignored`, omitted when empty.
    public var ignored: [IgnoredLine]
    public init(deny: [DenyRule], allow: [AllowRule], forbid: [ForbidRule], only: [OnlyRule] = [],
                errors: [PolicyError] = [],
                usedAliases: [String] = [], ignored: [IgnoredLine] = []) {
        self.deny = deny; self.allow = allow; self.forbid = forbid; self.only = only
        self.errors = errors; self.usedAliases = usedAliases; self.ignored = ignored
    }
    /// ⟨0.24⟩ The refusal texts, in order — the GATE's view of `errors`. Empty means every line the
    /// engine could not honour is a report-only one, which is the ambiguous middle §6.2 leaves permissive.
    public var gateRefusals: [String] { errors.compactMap(\.gateReason) }
}

/// ⟨0.24⟩ A DROPPED RULE, recorded. It stays a stderr warning AND becomes a `PolicyError`, because until
/// it is reported nobody can measure how often it happens — the witness was disclosing the two cases that
/// prompted the token clause and staying silent on the six that did not. `gateReason` is supplied only by
/// the callers §6.2 makes unambiguous; the rest are report-only.
func warnRule(_ why: String, _ line: String, kind: String, token: String, accepted: [String],
              gateReason: String? = nil) -> PolicyError {
    FileHandle.standardError.write("candor: ignoring policy rule (\(why)): \(line)\n".data(using: .utf8)!)
    return PolicyError(kind: kind, token: token, accepted: accepted, rule: line,
                       message: "policy line NOT HONOURED — DROPPED (\(why)); it is absent from the parse, "
                              + "so the policy that ran is the one without it",
                       gateReason: gateReason)
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

/// ⟨0.24⟩ **A TYPO'D EFFECT NAME DELETES THE RULE, SILENTLY, FOUR-WAY GREEN** (SPEC §6.2, candor-spec
/// `1e1748a`). MEASURED 2026-07-28 on all four engines:
///
///     deny Nett app             ->  rust 0  ts 0  java 0  swift 0   the rule is DELETED, the gate is green
///     allow Nett host.example   ->  rust 0  ts 0  java 0  swift 0   the certification silently vanishes
///
/// The operator reads an armed `deny Net`; there is no gate at all. This format already calls a dropped
/// rule *"the limit case of silently rewritten into a different policy… a bigger rewrite than a narrowed
/// filter, not a smaller one"* — and yet the BIGGER rewrite was warning-only while the SMALLER one is
/// exit 2.
///
/// THE GRAMMAR DEFENCE IS REAL BUT NARROWER than it was taken to be. `deny Net Exex app` genuinely cannot
/// be told from a legitimate scope by the parser, and stays permissive. But:
///
///   - **`allow`'s effect position is a fixed, closed set.** `allow Nett …` is unambiguously a typo, with
///     no scope reading available at all.
///   - **A `deny` whose effect list ends up EMPTY after scope-splitting is malformed under either
///     reading** — there is no legitimate policy it could be — so refusing it loses nothing.
///
/// `parsepolicy` reports the ambiguous middle either way (§3.1), so the operator can always see it.
func policyEffectNameError(_ token: String, _ line: String, accepted: [String], why: String) -> String {
    (token.isEmpty
        ? "candor: policy error — this rule names NO effect at all, in: \(line)\n"
        : "candor: policy error — unrecognised effect name `\(token)` in: \(line)\n")
    + "  accepted: \(accepted.joined(separator: ", "))\n"
    + "  \(why) Dropping the rule is the LIMIT CASE of rewriting the policy — the policy that ran is the "
    + "one WITHOUT this line, so the operator reads an armed gate that does not exist. Refusing (exit 2) "
    + "— SPEC §6.2 ⟨0.24⟩"
}

/// The ⟨0.24⟩ `accepted` TOKEN LIST for a reason-class/alias position — the array form of
/// `POLICY_CLASS_TOKENS`, which is prose and stays prose because it is a human sentence in a stderr line.
/// `901f14d`: `accepted` is an array of tokens, never a prose string, because the consumer the field
/// exists for cannot parse prose.
let POLICY_CLASS_TOKEN_LIST = REASON_CLASSES + ["dynamic", "*"]

func policyClassTokenPolicyError(_ token: String, _ line: String) -> PolicyError {
    PolicyError(kind: "reason-class/alias", token: token, accepted: POLICY_CLASS_TOKEN_LIST, rule: line,
                message: "unknown reason-class/alias `\(token)` (known: "
                       + "\(REASON_CLASSES.joined(separator: ", ")); aliases: dynamic, *, or a config "
                       + "`unknown-alias`)",
                gateReason: policyClassTokenError(token, line))
}
func policyDestClassPolicyError(_ token: String, _ line: String) -> PolicyError {
    PolicyError(kind: "Net destination-class", token: token,
                accepted: NET_DEST_CLASSES.sorted() + ["*"], rule: line,
                message: "unknown Net destination-class `\(token)` (known: "
                       + "\(NET_DEST_CLASSES.sorted().joined(separator: ", ")), or *)",
                gateReason: policyDestClassTokenError(token, line))
}

public func parsePolicy(_ text: String, aliases: [String: Set<String>] = [:]) -> ParsedPolicy {
    var deny: [DenyRule] = [], allow: [AllowRule] = [], forbid: [ForbidRule] = [], only: [OnlyRule] = []
    var errors: [PolicyError] = []
    var usedAliases = Set<String>()
    var ignored: [IgnoredLine] = []
    var lineNo = 0
    // Split LINES on \n / \r\n / bare \r — the three forms Java's Files.readAllLines (the reference parser)
    // breaks on. Splitting on \n ONLY let a classic-Mac (bare-\r) file collapse to ONE line: \r is also an
    // in-line ASCII-ws token separator (§6.2), so every rule after the first was glued into the first rule's
    // tokens and dropped — a gateless-green divergence (sweep [16]/[17]). Normalize first; \v/\f stay in-line
    // token separators (Java's readLine does not break on them either).
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
        lineNo += 1
        // ⟨0.28⟩ record a DROPPED line for the verdict's `ignored` disclosure — only the drops the
        // forward-compat leniency keeps (no `gateReason`); the exit-2 policy errors never reach a
        // verdict and §6.2 classes them apart ("a policy ERROR at exit 2, not an ignored line").
        func ignore(_ why: String) {
            ignored.append(IgnoredLine(line: lineNo, text: String(rawLine), reason: why))
        }
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
                        else { errors.append(policyDestClassPolicyError(cn, line)) }
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
                        else { errors.append(policyClassTokenPolicyError(cn, line)) }
                    }
                    continue
                }
                if EFFECTS.contains(tok) || tok == "Unknown" {
                    effects.append(tok)
                    if tok == "Unknown" { unknownStar = true } // bare Unknown ⇒ all classes
                    if tok == "Net" { netStar = true }         // bare Net ⇒ all destinations
                } else { scope = tok; break }
            }
            if effects.isEmpty {
                // ⟨0.24⟩ RECORDED, not merely warned. `scope` holds the FIRST token that was not a known
                // effect — the loop assigns it and breaks — so it is exactly the token that made the
                // effect list empty. `deny` with no tokens at all leaves it "".
                // ⟨0.24⟩ AND THE GATE REFUSES IT (candor-spec `1e1748a`). A `deny` whose effect list is
                // EMPTY after scope-splitting is malformed under EITHER reading of the trailing token —
                // there is no legitimate policy it could be — so refusing loses nothing, while dropping
                // it left `deny Nett app` exiting 0 over a signature the correctly-spelled rule fails.
                // The AMBIGUOUS MIDDLE (at least one valid effect plus an unrecognised trailing token
                // that might be a scope) is untouched: it keeps its effects and stays permissive.
                errors.append(warnRule("deny names no known effect", line, kind: "effect-name",
                                       token: scope, accepted: EFFECTS.sorted(),
                                       gateReason: policyEffectNameError(
                                        scope, line, accepted: EFFECTS.sorted(),
                                        why: "a `deny` whose effect list is EMPTY after scope-splitting is "
                                           + "malformed under either reading of the trailing token.")))
                continue
            }
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
            guard t.count >= 3 else {
                errors.append(warnRule("allow names no values", line, kind: "rule-form", token: t[0],
                                       accepted: ["allow <Effect> [in <scope>] <value…>"]))
                ignore("allow names no values")
                continue
            }
            guard ALLOW_EFFECTS.contains(t[1]) else {
                // ⟨0.24⟩ AND THE GATE REFUSES IT (candor-spec `1e1748a`). `allow`'s effect position is a
                // FIXED, CLOSED set with no scope reading available, so an unrecognised token there is
                // unambiguously a typo — the grammar defence that keeps the `deny` middle permissive does
                // not reach it. Before this, `allow Nett host.example` exited 0 and the certification
                // silently vanished.
                errors.append(warnRule("allow supports only Net hosts / Llm hosts / Exec commands / Fs paths / Db tables",
                                       line, kind: "effect-name", token: t[1],
                                       accepted: ALLOW_EFFECTS.sorted(),
                                       gateReason: policyEffectNameError(
                                        t[1], line, accepted: ALLOW_EFFECTS.sorted(),
                                        why: "`allow`'s effect position is a fixed, CLOSED set with no "
                                           + "scope reading available, so a token outside it — a typo, or "
                                           + "a real effect with no literal surface to certify — cannot "
                                           + "be honoured as written.")))
                continue
            }
            var scope = ""; var vi = 2
            if t[2] == "in" { scope = t.count > 3 ? t[3] : ""; vi = 4 }
            let values = Array(t.dropFirst(vi))
            if values.isEmpty {
                errors.append(warnRule("allow names no values", line, kind: "rule-form", token: t[0],
                                       accepted: ["allow <Effect> [in <scope>] <value…>"]))
                ignore("allow names no values")
                continue
            }
            // Duplicate values dedup (the reference parser's TreeSet) — same PART 4 parity as deny.
            allow.append(AllowRule(effect: t[1], scope: scope, values: Array(Set(values)).sorted(), raw: line))
        case "forbid":
            let a = t.count > 1 ? t[1] : "", arrow = t.count > 2 ? t[2] : "", b = t.count > 3 ? t[3] : ""
            if a.isEmpty || arrow != "->" || b.isEmpty {
                errors.append(warnRule("want `forbid <scope> -> <scope>`", line, kind: "rule-form",
                                       token: t.dropFirst().joined(separator: " "),
                                       accepted: ["forbid <scope> -> <scope>"]))
                ignore("want `forbid <scope> -> <scope>`")
                continue
            }
            forbid.append(ForbidRule(from: a, to: b, raw: line))
        // ⟨0.29⟩ THE PERMISSION FORM. Token-wise like its `forbid` sibling — the arrow is its own token —
        // but everything AFTER the arrow is a permitted scope, so this takes a LIST where `forbid` takes
        // one destination. An EMPTY tail is dropped rather than read as "A may reach nothing at all":
        // that is a different rule, and one far likelier typed by accident than meant.
        case "only":
            let from = t.count > 1 ? t[1] : "", arrow = t.count > 2 ? t[2] : ""
            let to = t.count > 3 ? Array(t[3...]) : []
            if from.isEmpty || arrow != "->" || to.isEmpty {
                errors.append(warnRule("want `only <scope> -> <scope> [<scope> …]`", line,
                                       kind: "rule-form", token: t.dropFirst().joined(separator: " "),
                                       accepted: ["only <scope> -> <scope> [<scope> …]"]))
                ignore("want `only <scope> -> <scope> [<scope> …]`")
                continue
            }
            only.append(OnlyRule(from: from, to: to, raw: line))
        default:
            errors.append(warnRule("unknown rule kind `\(t[0])`", line, kind: "rule-kind", token: t[0],
                                   accepted: ["deny", "pure", "allow", "forbid", "only"]))
            ignore("unknown rule kind `\(t[0])`")
        }
    }
    return ParsedPolicy(deny: deny, allow: allow, forbid: forbid, only: only, errors: errors,
                        usedAliases: usedAliases.sorted(), ignored: ignored)
}

/// §6.2 scope match: segment run, last segment a prefix. Segments split on BOTH `.` and `::` (empty
/// parts filtered), mirroring Rust/Java's `name_segments` — so a shared `::`-scoped policy (Rust/Swift
/// path syntax) matches Swift names too, not just dotted ones. Splitting on `:` is safe: a `:` only ever
/// appears in a `::` separator in these names, so it never over-segments (no spurious match).
/// ⟨0.29⟩ SCOPE MATCHING FOR A PERMISSION, where the prefix rule below is FAIL-OPEN.
///
/// `scopeMatches`'s last segment is a PREFIX of its name-segment, so `util` matches `utilities`. For
/// deny/pure/forbid that widening is FAIL-CLOSED — a scope matching more forbids more. For the `to` list
/// of an `only` rule it is the exact inverse: a permitted scope matching more PERMITS more, so the
/// matcher that keeps every other rule kind safe silently widens the one form whose entire purpose is to
/// fail safe. MEASURED on the shipped ⟨0.29⟩ implementation: `only model -> util` let `model.go` reach
/// `utilities_untrusted.exfil` at `policy ✓` while `forbid model -> util` charged AS-EFF-009 on the same
/// reach. The `from` side keeps the prefix rule — it selects what the rule BINDS, so more is safer.
public func scopeMatchesPermitted(_ name: String, _ scope: String) -> Bool {
    if scope.isEmpty { return false }   // an empty permitted scope permits nothing, never everything
    let segs = name.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
    let parts = scope.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
    if parts.isEmpty || parts.count > segs.count { return false }
    outer: for i in 0...(segs.count - parts.count) {
        for (k, p) in parts.enumerated() where segs[i + k] != p { continue outer }
        return true
    }
    return false
}

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
