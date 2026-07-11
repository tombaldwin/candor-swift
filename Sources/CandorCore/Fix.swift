import Foundation

// candor-swift `fix` / `fix-gate` — the boundary fix (integrations/FIX-SPEC.md), the remedial inverse of the
// gate: when a function performs an effect its layer forbids, compute WHERE the effect belongs (hoist it to
// the nearest allowed-layer caller) and which functions become pure and thread the value. The byte-for-byte
// port of candor-query / candor-java / candor-ts's cut. Pure over the report graph — the CLI side loads the
// report + callgraph from disk and calls in here. candor-swift stays scan-first: this is a read-only query
// over what a scan already wrote, and it never mutates source (the analyzer's soundness contract is untouched).

// A per-function record the cut needs (from the §2 report envelope).
public struct FixFn {
    public let inferred: Set<String>
    public let direct: Set<String>
    public let calls: [String]
    public init(inferred: Set<String>, direct: Set<String>, calls: [String]) {
        self.inferred = inferred
        self.direct = direct
        self.calls = calls
    }
}

// A computed boundary remedy — the deterministic cut between "must stay pure" (`deniedSpan`) and "may perform
// the effect" (`hoistTo`). Field names match the other engines' JSON exactly.
public struct Remedy {
    public let fn: String
    public let effect: String
    public let layer: String
    public let cleanHoist: Bool
    public let site: [String]
    public let deniedSpan: [String]
    public let hoistTo: [String]
    public let hoistHigher: [String]
    public let policyAlternative: String
    public func toJSON() -> [String: Any] {
        [
            "fn": fn, "effect": effect, "layer": layer, "cleanHoist": cleanHoist,
            "site": site, "deniedSpan": deniedSpan, "hoistTo": hoistTo, "hoistHigher": hoistHigher,
            "policyAlternative": policyAlternative,
        ]
    }
}

// The deny/`pure` scope (the "layer") forbidding `effect` at `fn`, or nil if performing it there is allowed.
// Mirrors Gate.swift's AS-EFF-006 predicate exactly: a `deny` fires when it names the effect; a `pure` rule
// (empty effects) forbids every real effect but not Unknown.
public func deniedLayer(_ fn: String, _ effect: String, _ deny: [DenyRule]) -> String? {
    for r in deny {
        let denies = r.effects.isEmpty ? (effect != "Unknown") : r.effects.contains(effect)
        if denies && scopeMatches(fn, r.scope) { return r.scope }
    }
    return nil
}

// The callee→callers adjacency.
public func reverseGraph(_ cg: [String: [String]]) -> [String: [String]] {
    var rev: [String: [String]] = [:]
    for (caller, callees) in cg {
        for c in callees { rev[c, default: []].append(caller) }
    }
    return rev
}

// The site-anchored cut, shared by `fix` and `fixGate`. `start` performs `effect` and sits in the deny-effect
// layer `layer`; `cg` is caller→callees, `rev` its inverse. Forward-BFS to the direct site(s), then climb UP
// through the denied layer so the pure span is root-independent (the inheritors of one crossing collapse to
// one identical remedy); the allowed-layer callers where the climb stops are the hoist frontier.
public func computeRemedy(start: String, effect: String, layer: String,
                          byName: [String: FixFn], cg: [String: [String]], rev: [String: [String]],
                          deny: [DenyRule]) -> Remedy {
    // direct site(s): forward BFS from `start` through effect-carrying callees to the DIRECT source(s).
    var sites = Set<String>()
    var fseen: Set<String> = [start]
    var fq = [start]
    while !fq.isEmpty {
        let cur = fq.removeFirst()
        if let fe = byName[cur], fe.direct.contains(effect) { sites.insert(cur) }
        for c in cg[cur] ?? [] {
            guard let ce = byName[c], ce.inferred.contains(effect), !fseen.contains(c) else { continue }
            fseen.insert(c)
            fq.append(c)
        }
    }
    // anchor on the site(s) (fall back to `start` for a cross-module/Unknown source with no local site) and
    // walk UP: denied-layer effect-carriers are the pure span; the allowed callers where the climb stops are
    // the hoist frontier.
    let anchors = sites.isEmpty ? [start] : Array(sites)
    var deniedSpan = Set<String>()
    var hoist = Set<String>()
    var up: [String] = []
    for a in anchors {
        if deniedLayer(a, effect, deny) != nil { deniedSpan.insert(a) }
        up.append(a)
    }
    while !up.isEmpty {
        let cur = up.removeFirst()
        for caller in rev[cur] ?? [] {
            guard let ce = byName[caller], ce.inferred.contains(effect) else { continue } // routes the effect?
            if deniedLayer(caller, effect, deny) != nil {
                if deniedSpan.insert(caller).inserted { up.append(caller) } // denied → span; keep climbing
            } else {
                hoist.insert(caller) // allowed → the boundary
            }
        }
    }
    // higher hoist options: allowed-layer transitive callers of the minimal frontier that also route the
    // effect — hoisting higher keeps the frontier pure too, at the cost of threading through more signatures
    // (FIX-SPEC: the trade-off, disclosed not hidden).
    // The SANDWICHED-layer check (/code-review): a hoist is CLEAN only if no forbidden fn sits ABOVE the
    // frontier. If a denied fn calls into a hoist target, hoisting the effect there leaves that caller
    // violating. Detected in the same climb that gathers `higher` (the allowed ancestors).
    var higher = Set<String>()
    var sandwiched = false
    var hseen = hoist
    var hq = Array(hoist)
    while !hq.isEmpty {
        let cur = hq.removeFirst()
        for caller in rev[cur] ?? [] {
            guard let ce = byName[caller], ce.inferred.contains(effect) else { continue }
            if deniedLayer(caller, effect, deny) != nil {
                sandwiched = true
            } else if hseen.insert(caller).inserted {
                higher.insert(caller)
                hq.append(caller)
            }
        }
    }
    let cleanHoist = !hoist.isEmpty && !sandwiched
    let allowEdit = layer.isEmpty ? "allow \(effect)" : "allow \(effect) \(layer)"
    return Remedy(fn: start, effect: effect, layer: layer, cleanHoist: cleanHoist,
                  site: sites.sorted(), deniedSpan: deniedSpan.sorted(), hoistTo: hoist.sorted(),
                  hoistHigher: higher.sorted(), policyAlternative: allowEdit)
}

// The single-function fix. Returns nil if `target` matches no function; a `(crossing:false, reason)` no-op if
// it performs the effect but isn't forbidden there (or doesn't perform it); else the remedy.
public enum FixResult {
    case noSuchFn
    case notACrossing(fn: String, effect: String, reason: String)
    case remedy(Remedy)
}

public func fix(target: String, effect: String, byName: [String: FixFn], cg: [String: [String]],
                deny: [DenyRule]) -> FixResult {
    let names = Array(byName.keys)
    guard let m = bestMatches(names, target), !m.isEmpty else { return .noSuchFn }
    // prefer a match that actually performs the effect (so a bare leaf resolves to the violating function)
    let start = m.first(where: { byName[$0]?.inferred.contains(effect) == true }) ?? m[0]
    guard let fe = byName[start], fe.inferred.contains(effect) else {
        return .notACrossing(fn: start, effect: effect, reason: "does-not-perform")
    }
    guard let layer = deniedLayer(start, effect, deny) else {
        return .notACrossing(fn: start, effect: effect, reason: "not-forbidden")
    }
    return .remedy(computeRemedy(start: start, effect: effect, layer: layer,
                                 byName: byName, cg: cg, rev: reverseGraph(cg), deny: deny))
}

// fix-gate: a remedy for EVERY deny/`pure` (AS-EFF-006) crossing in the report, collapsing the inheritors of
// one root cause to a single plan (keyed by effect|layer|site|hoist).
public func fixGate(byName: [String: FixFn], cg: [String: [String]], deny: [DenyRule]) -> (ok: Bool, remedies: [Remedy]) {
    let rev = reverseGraph(cg)
    var plans: [String: Remedy] = [:]
    for fn in byName.keys.sorted() {
        guard let fe = byName[fn] else { continue }
        for effect in fe.inferred.sorted() {
            guard let layer = deniedLayer(fn, effect, deny) else { continue }
            let p = computeRemedy(start: fn, effect: effect, layer: layer, byName: byName, cg: cg, rev: rev, deny: deny)
            let key = "\(p.effect)|\(p.layer)|\(p.site)|\(p.hoistTo)"
            if plans[key] == nil { plans[key] = p }
        }
    }
    let remedies = plans.keys.sorted().map { plans[$0]! }
    return (remedies.isEmpty, remedies)
}

// The query name-match ladder (exact > segment-suffix > substring), same tiers as the family engines.
func matchTier(_ name: String, _ q: String) -> Int {
    if name == q { return 3 }
    if name.hasSuffix(q), name.count > q.count {
        let before = name[name.index(name.endIndex, offsetBy: -q.count - 1)]
        if before == "." || before == ":" || before == "#" || before == "$" { return 2 }
    }
    if name.contains(q) { return 1 }
    return 0
}
func bestMatches(_ names: [String], _ q: String) -> [String]? {
    let best = names.map { matchTier($0, q) }.max() ?? 0
    if best == 0 { return nil }
    return names.filter { matchTier($0, q) >= best }.sorted()
}
