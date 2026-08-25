import Foundation

// candor-swift `fix` / `fix-gate` — the boundary fix (integrations/FIX-SPEC.md), the remedial inverse of the
// gate: when a function performs an effect its layer forbids, compute WHERE the effect belongs (hoist it to
// the nearest allowed-layer caller) and which functions become pure and thread the value. The byte-for-byte
// port of candor-query / candor-java / candor-ts's cut. Pure over the report graph — the CLI side loads the
// report + callgraph from disk and calls in here. candor-swift stays scan-first: this is a read-only query
// over what a scan already wrote, and it never mutates source (the analyzer's soundness contract is untouched).

// A per-function record the cut needs (from the §2 report envelope).
public struct FixFn {
    /// ⟨0.32⟩ the DISTINCT §2.2 join keys seen under this NAME across the loaded report set. More than
    /// one means two different units declare it, and this model — which is addressed by NAME, because
    /// `candor fix <fn> <Effect>` is what a person types — cannot tell them apart. It does not GUESS:
    /// `fixGate` plans no remedy for such a name and discloses it instead. Planning an edit against the
    /// wrong function is the failure this exists to prevent, and the loader used to make it silently by
    /// letting the last report read win the key outright.
    public var joinKeys: Set<String> = []
    public let inferred: Set<String>
    public let direct: Set<String>
    public let calls: [String]
    /// The §4 `unknownWhy` reasons this function recorded DIRECTLY. `deniedLayer` needs it: a
    /// `deny Unknown[<class>…]` rule only forbids `Unknown` at a function whose reason classes intersect
    /// the rule's, and `direct` + `calls` + this field are exactly the §6.2 resolution's inputs.
    ///
    /// NOT defaulted, deliberately, and unlike `loc` below. A construction site that omitted it would
    /// leave every function classless, every narrowed rule permanently unmatched, and every remedy for a
    /// scoped `deny Unknown` silently gone — a lost disclosure indistinguishable from a clean report.
    public let unknownWhy: [String]
    /// The §2 `paths` this function's Fs calls named, read verbatim. Carried so a consumer can tell a
    /// DETERMINED file destination from an undetermined one — §6 of CONSTANT-PROVENANCE-DESIGN.md, where
    /// the count of Fs functions with NO determined path is the disclosure that stands in for the
    /// path-triggered folder keys until constant provenance lands.
    ///
    /// Defaulted to empty like `privacyKinds`: empty is MEANINGFUL (undetermined), not lossy, so a report
    /// predating the field reads as "nothing determined" — which is the honest answer for a producer that
    /// was not emitting it.
    public var paths: [String] = []

    /// The §2 `incomplete` list — effects whose locator this function could NOT determine, directly.
    /// Defaulted empty like `paths`: a report predating the field reads as "nothing known to be
    /// undetermined", which is the honest answer for a producer that was not emitting it.
    public var incomplete: [String] = []

    /// `privacy/2` THE READ/WRITE DIRECTIONS THIS FUNCTION'S PRIVACY CALLS REVEALED, off the §2
    /// report entry verbatim. Like `netClass` this cannot be derived from the other fields: the verb
    /// that said "save" rather than "execute" is gone by the time a consumer reads a report, so the
    /// producer's answer has to travel.
    ///
    /// Defaulted to empty, unlike `unknownWhy`, because empty is MEANINGFUL here rather than lossy:
    /// an absent direction means UNDETERMINED, which is exactly the pre-`privacy/2` behaviour (any
    /// acceptable key satisfies the effect). A report predating the field therefore verifies exactly
    /// as it did before, and can never be made to FAIL by the upgrade.
    public var privacyKinds: [String: [String]] = [:]
    /// ⟨0.20⟩ THE `netClass` DESTINATION CLASSES THIS FUNCTION REACHES, off the §2 report entry verbatim.
    ///
    /// A `deny Net[<dest>…]` rule only forbids `Net` at a function reaching one of those, and unlike the
    /// reason class this CANNOT BE DERIVED from the other fields on this record. A reason class resolves
    /// out of `unknownWhy` + `direct` + `calls` (§6.2); a destination class is a function of the host
    /// literal surface and the project's `net-partner` set, neither of which travels here. So it is
    /// THREADED — read the way `gate --report` reads it, from a field the producer already accumulated
    /// transitively and already floored at `unknown-host`.
    ///
    /// NOT defaulted, for the same reason `unknownWhy` is not: a construction site that omitted it would
    /// leave every function destination-less, every `deny Net[…]` permanently unmatched, and every remedy
    /// for a scoped `deny Net` silently gone.
    public let netClass: [String]
    /// "file:line" from the §2 report envelope ("" when absent) — the `tour` verb's source callout uses it;
    /// `fix`/`fix-gate` don't. Defaulted so existing constructions stay valid.
    public let loc: String
    public init(inferred: Set<String>, direct: Set<String>, calls: [String], unknownWhy: [String],
                netClass: [String], loc: String = "") {
        self.inferred = inferred
        self.direct = direct
        self.calls = calls
        self.unknownWhy = unknownWhy
        self.netClass = netClass
        self.loc = loc
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

/// Does `r` forbid `effect` at a function whose TRANSITIVE `Unknown` reason classes are `fnClasses` and
/// whose ⟨0.20⟩ `Net` destination classes are `fnNet`?
///
/// THE SINGLE PLACE the `fix`/`unverified` side answers Gate.swift's AS-EFF-006 membership question, and
/// it has to give the same answer: a `pure` rule (empty effects) forbids every real effect but not the §4
/// `Unknown` marker; a `deny` fires when it names the effect; ⟨0.19⟩ a `deny … Unknown[<class>…]` keeps
/// its `Unknown` hit ONLY for a function whose reason classes intersect the rule's; and ⟨0.20⟩ a
/// `deny … Net[<dest>…]` keeps its `Net` hit ONLY for a function reaching one of those destinations.
///
/// Those last two conjuncts are what this file did not have — the SAME omission twice, closed one rung
/// apart. `DenyRule.unknownClasses` and `DenyRule.netClasses` were both parsed and populated and neither
/// `deniedLayer` nor `unverifiedHoleRule` read either, so both treated `deny Unknown[reflect]` and
/// `deny Net[unknown-host]` as their bare forms — and, off that one omission, broke in OPPOSITE
/// directions: `fix-gate` invented a remedy for a boundary the policy does not deny, and `unverified`
/// certified as clean a layer that PASSES while carrying an Unknown, which is precisely the object it
/// exists to name. See ScopedUnknownRemedyProcessTests and ScopedNetRemedyProcessTests for the two
/// measurements; they are the same table with one column changed.
///
/// AN EMPTY CLASS SET MEANS NOT-FORBIDDEN — for `fnClasses` and `fnNet` alike — and that direction is
/// chosen, not incidental. It is what `evaluateGate` does — the rule is WITHHELD on that (rule, function)
/// pair rather than charged on a default — and both callers here want it: `fix-gate` withholds a remedy
/// the gate would not charge, and `unverifiedHoleRule` reads "not forbidden" as "this layer PASSES it",
/// which turns an unclassifiable `Unknown` into a DISCLOSED hole. The conservative answer is the same
/// answer for both, which is why one predicate can serve them. It is also why the reason-class map handed
/// in here must be the UNFLOORED one: floor the empty set to `unresolved` and a `deny Unknown[unresolved]`
/// starts firing on functions nobody classified — fabricating a remedy in `fix-gate` and, in `unverified`,
/// swallowing the hole again. (`fnNet` needs no such split: the producer floors it at `unknown-host`
/// before it is written, so an empty set on the wire means "this producer did not carry the field", which
/// `gate --report` refuses outright as unanswerable rather than resolving either way.)
public func ruleForbids(_ r: DenyRule, _ effect: String, _ fnClasses: Set<String>, _ fnNet: Set<String>) -> Bool {
    if r.effects.isEmpty { return effect != "Unknown" }
    guard r.effects.contains(effect) else { return false }
    if effect == "Unknown", !r.unknownClasses.isEmpty {
        return fnClasses.contains(where: { r.unknownClasses.contains($0) })
    }
    if effect == "Net", !r.netClasses.isEmpty {
        return fnNet.contains(where: { r.netClasses.contains($0) })
    }
    return true
}

// The deny/`pure` scope (the "layer") forbidding `effect` at `fn`, or nil if performing it there is allowed.
// Mirrors Gate.swift's AS-EFF-006 predicate exactly (see `ruleForbids`). `classes` is the UNFLOORED §6.2
// transitive reason-class map — `matcherReasonClasses`, never `reasonClassesTransitive`; `netClasses` is
// the ⟨0.20⟩ destination-class map, read off the report's own `netClass` field (`matcherNetClasses`).
public func deniedLayer(_ fn: String, _ effect: String, _ deny: [DenyRule],
                        _ classes: [String: Set<String>], _ netClasses: [String: Set<String>]) -> String? {
    for r in deny where scopeMatches(fn, r.scope) {
        if ruleForbids(r, effect, classes[fn] ?? [], netClasses[fn] ?? []) { return r.scope }
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
                          deny: [DenyRule], classes: [String: Set<String>],
                          netClasses: [String: Set<String>]) -> Remedy {
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
        if deniedLayer(a, effect, deny, classes, netClasses) != nil { deniedSpan.insert(a) }
        up.append(a)
    }
    while !up.isEmpty {
        let cur = up.removeFirst()
        for caller in rev[cur] ?? [] {
            guard let ce = byName[caller], ce.inferred.contains(effect) else { continue } // routes the effect?
            if deniedLayer(caller, effect, deny, classes, netClasses) != nil {
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
            if deniedLayer(caller, effect, deny, classes, netClasses) != nil {
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
    case notACrossing(fn: String, effect: String, reason: String, unanswered: [UnansweredRule])
    /// ⟨0.24⟩ THE GATE COULD NOT ANSWER THIS ONE (SPEC §3.2). `crossing` is `nil` when the refusal is
    /// about THIS function — the rule that governs it could not be read, so whether it crosses is
    /// undetermined and any boolean would be an invention — and `true` when the crossing itself is
    /// CERTAIN and only the hoist PLAN rests on a boundary the gate declined to adjudicate.
    ///
    /// That second case is a defect this change nearly introduced in the other direction: withholding
    /// the plan by answering `crossing: false` would have turned a violation the gate CHARGES into a
    /// non-finding — the cardinal sin, arriving inside a fix for its mirror. The crossing is reported;
    /// only the instruction is withheld.
    case unanswerable(fn: String, effect: String, crossing: Bool?, unanswered: [UnansweredRule])
    case remedy(Remedy, unanswered: [UnansweredRule])
}

/// ⟨0.24⟩ SPEC §3.2 applies here too, and in the sharpest form the verb has: `reason: "not-forbidden"`
/// asserts *the rule was evaluated and did not fire*. Over a report the gate REFUSES, no rule was
/// evaluated — so the answer becomes `unanswerable`, with the gate's own `unevaluated` disclosure
/// beside it. `does-not-perform` is untouched: that one is read off the effect set, which is present.
public func fix(target: String, effect: String, byName: [String: FixFn], cg: [String: [String]],
                deny: [DenyRule]) -> FixResult {
    let names = Array(byName.keys)
    let classes = matcherReasonClasses(byName, deny)
    let netClasses = matcherNetClasses(byName, deny)
    let cells = unanswerableCells(inferred: byName.mapValues(\.inferred), reasonClasses: classes,
                                  netClasses: netClasses, deny: deny)
    let unadjudicable = unanswerablePairs(cells)
    let disclosure = unansweredDisclosure(cells)
    guard let m = bestMatches(names, target), !m.isEmpty else { return .noSuchFn }
    // prefer a match that actually performs the effect (so a bare leaf resolves to the violating function)
    let start = m.first(where: { byName[$0]?.inferred.contains(effect) == true }) ?? m[0]
    guard let fe = byName[start], fe.inferred.contains(effect) else {
        // NO DISCLOSURE HERE, and the asymmetry is measured rather than tidy. `does-not-perform` is read
        // off the effect set: it depends on no rule, so it is not a claim the gate could contradict and
        // the §3.2 bound has nothing to say about it. Attaching the disclosure anyway was a hedge, and
        // hedges are always ALLOWED — but on the derived pollen corpus it fired on 141 of 195 sampled
        // answers under one narrowed policy, which is how a disclosure stops being read.
        return .notACrossing(fn: start, effect: effect, reason: "does-not-perform", unanswered: [])
    }
    guard let layer = deniedLayer(start, effect, deny, classes, netClasses) else {
        // `not-forbidden` claims the rule fired and missed. When the rule governing THIS function could
        // not be read, nothing fired and nothing missed — and `crossing` goes unstated with it.
        if unadjudicable.contains("\(start)|\(effect)") {
            return .unanswerable(fn: start, effect: effect, crossing: nil, unanswered: disclosure)
        }
        return .notACrossing(fn: start, effect: effect, reason: "not-forbidden", unanswered: disclosure)
    }
    let p = computeRemedy(start: start, effect: effect, layer: layer,
                          byName: byName, cg: cg, rev: reverseGraph(cg), deny: deny, classes: classes,
                          netClasses: netClasses)
    // A plan resting on a boundary the gate declined to adjudicate is withheld here for the same reason
    // `fix-gate` withholds it — the single-function surface is the one an agent acts on directly. The
    // CROSSING still ships: `deniedLayer` decided it, and the gate charges it (§3.1 precedence).
    guard !remedyRestsOnRefusedEvidence(p, unadjudicable) else {
        return .unanswerable(fn: start, effect: effect, crossing: true, unanswered: disclosure)
    }
    return .remedy(p, unanswered: disclosure)
}

// fix-gate: a remedy for EVERY deny/`pure` (AS-EFF-006) crossing in the report, collapsing the inheritors of
// one root cause to a single plan (keyed by effect|layer|site|hoist).
//
// ⟨0.24⟩ …EXCEPT WHERE THE GATE COULD NOT READ THE EVIDENCE (SPEC §3.2, candor-spec `4fd140c`): *"a hoist
// plan for a boundary the gate could not adjudicate is a confident instruction resting on a guess."* The
// climb in `computeRemedy` asks `deniedLayer` of every caller, and `deniedLayer` answers NOT-FORBIDDEN
// for a function whose class set is empty BECAUSE THE FIELD IS ABSENT — so an unadjudicable caller
// becomes a hoist TARGET, and the operator is told to move the effect to a layer nobody established is
// allowed to hold it. Withheld, and disclosed instead.
public func fixGate(byName: [String: FixFn], cg: [String: [String]], deny: [DenyRule])
    -> (ok: Bool, remedies: [Remedy], unanswered: [UnansweredRule]) {
    let rev = reverseGraph(cg)
    let classes = matcherReasonClasses(byName, deny)
    let netClasses = matcherNetClasses(byName, deny)
    let cells = unanswerableCells(inferred: byName.mapValues(\.inferred), reasonClasses: classes,
                                  netClasses: netClasses, deny: deny)
    let unadjudicable = unanswerablePairs(cells)
    var plans: [String: Remedy] = [:]
    // ⟨0.32⟩ names two units declare — no plan, a disclosure. SPEC §3.2 makes this verb's confidence a
    // COMPARISON against the gate, and the gate keys by `hash`, so it holds the two apart and answers
    // about each. This model cannot; the honest answer is therefore "I cannot say which", never a
    // remedy computed against whichever report happened to be read last.
    var ambiguousNames: [UnansweredRule] = []
    for fn in byName.keys.sorted() where (byName[fn]?.joinKeys.count ?? 0) > 1 {
        let keys = (byName[fn]?.joinKeys ?? []).sorted().joined(separator: ", ")
        ambiguousNames.append(UnansweredRule(
            rule: "fix-gate",
            why: "`\(fn)` is declared by more than one unit in this report set (\(keys)) and this verb is "
               + "addressed by NAME, so it cannot tell which one a remedy would edit. `gate --report` "
               + "keys by `hash` and judges them separately — gate there, or narrow the report set to "
               + "one unit.",
            fn: fn, effect: ""))
    }
    for fn in byName.keys.sorted() {
        guard let fe = byName[fn] else { continue }
        guard fe.joinKeys.count <= 1 else { continue }
        for effect in fe.inferred.sorted() {
            guard let layer = deniedLayer(fn, effect, deny, classes, netClasses) else { continue }
            let p = computeRemedy(start: fn, effect: effect, layer: layer, byName: byName, cg: cg, rev: rev,
                                  deny: deny, classes: classes, netClasses: netClasses)
            guard !remedyRestsOnRefusedEvidence(p, unadjudicable) else { continue }
            let key = "\(p.effect)|\(p.layer)|\(p.site)|\(p.hoistTo)"
            if plans[key] == nil { plans[key] = p }
        }
    }
    let remedies = plans.keys.sorted().map { plans[$0]! }
    // ⟨0.32⟩ `ok` is FALSE when a name went unplanned for ambiguity — `ok: true` beside an empty remedy
    // list is this verb saying "nothing to do", and there is something to do: disambiguate. The
    // disclosure rides the same channel as the unanswerable filters because it is the same kind of fact
    // — a question this run could not answer — and a consumer already reads that channel.
    return (remedies.isEmpty && ambiguousNames.isEmpty,
            remedies,
            unansweredDisclosure(cells) + ambiguousNames)
}

/// Does this plan assert a layer status the gate declined to decide? KEYED ON THE PLAN'S OWN EFFECT, not
/// on "some rule went unanswered": an unanswerable `Net` filter says nothing about an `Fs` crossing, and
/// the gate itself keeps charging the violations it is sure of (§3.1 precedence). A suppression coarser
/// than that would make the advisory verb LESS USEFUL than the gate rather than merely less certain,
/// which is the opposite error and just as much a defect.
///
/// Every function the plan makes a claim about is in scope — the anchor, the span it says becomes pure,
/// and both hoist frontiers, since "hoist it HERE" is exactly the assertion that HERE is allowed.
func remedyRestsOnRefusedEvidence(_ p: Remedy, _ unadjudicable: Set<String>) -> Bool {
    guard !unadjudicable.isEmpty else { return false }
    for fn in [p.fn] + p.site + p.deniedSpan + p.hoistTo + p.hoistHigher
    where unadjudicable.contains("\(fn)|\(p.effect)") { return true }
    return false
}

// A per-function record the `unverified` check needs (fn name + inferred effects + the Unknown reasons).
// `direct` and `calls` are what the ⟨0.24⟩ reason-class resolution needs and `unknownWhy` alone cannot
// give: `unknownWhy` is DIRECT-ONLY per SPEC §4, so the class of an INHERITED `Unknown` lives at the
// callee (`calls` reaches it), and a function that introduced its own `Unknown` without recording a
// reason is only distinguishable from one that merely inherited it by `direct` (§6.2's contribution
// case). Both are non-defaulted: a construction site that omitted them would silently rebuild the
// direct-field-only reading this field pair exists to end.
public struct UnverifiedFn {
    public let fn: String
    public let inferred: Set<String>
    public let direct: Set<String>
    public let unknownWhy: [String]
    public let calls: [String]
    /// ⟨0.20⟩ the report entry's `netClass`, verbatim — see `FixFn.netClass` for why this one is THREADED
    /// rather than derived. Non-defaulted for the same reason as the pair above.
    public let netClass: [String]
    public init(fn: String, inferred: Set<String>, direct: Set<String>, unknownWhy: [String],
                calls: [String], netClass: [String]) {
        self.fn = fn
        self.inferred = inferred
        self.direct = direct
        self.unknownWhy = unknownWhy
        self.calls = calls
        self.netClass = netClass
    }
}

public struct UnverifiedHole {
    public let fn: String
    public let rule: String
    public let unknownWhy: [String]
    public let upgrade: String
    /// WHY THE GATE COULD NOT JUDGE THIS (fn, rule) — the §3.1 refusal's own prose, verbatim, or nil when
    /// no rule was withheld here. Emitted only in the second case, which is the whole design of the key:
    ///
    /// MEASURED four-way over the conformance R11 report under `deny Net[unknown-host] app`, per ENTRY
    /// (AdvisoryBoundProcessTests records the table). Every engine spells an ORDINARY hole
    /// `[fn, rule, unknownWhy, upgrade]` and none of them puts a `why` on one — that entry's reason is
    /// `unknownWhy`, and a gate-refusal field beside it would invite a reader to take its absence as a
    /// statement. For the UNJUDGED entry rust and ts emit `[fn, rule, why]`, java merges to all five,
    /// and swift alone carried nothing: the reason existed only in the top-level `unevaluated[]`, joinable
    /// only by the raw rule string, with nothing in the entry saying a join was required. A per-entry
    /// consumer written against any of the other three read swift's entry and learned nothing.
    ///
    /// So: java's merged shape, not rust's and ts's separate row. Not because two engines beat two, but
    /// because swift emits ONE row per (fn, rule) on purpose (see `unverified`'s dedupe note) and the
    /// reason-class arm — where the same function is BOTH an ordinary hole and unjudged — has no
    /// second row to put a `why` on. Attaching it to the pair covers both arms and adds no row.
    public let why: String?
    public init(fn: String, rule: String, unknownWhy: [String], upgrade: String, why: String? = nil) {
        self.fn = fn
        self.rule = rule
        self.unknownWhy = unknownWhy
        self.upgrade = upgrade
        self.why = why
    }
    public func toJSON() -> [String: Any] {
        var o: [String: Any] = ["fn": fn, "rule": rule, "unknownWhy": unknownWhy, "upgrade": upgrade]
        if let why { o["why"] = why }        // ABSENT, never `null` — the key's presence IS the signal
        return o
    }
}

// Reconstruct a rule's source form and its `Unknown`-forbidding upgrade: (source, upgrade). `pure <scope>`
// → ("pure <scope>", "deny Unknown <scope>"); `deny <E…> <scope>` → ("deny <E…> <scope>", "deny <E…> Unknown
// <scope>"). Shared so the gate note and `unverified` name the identical upgrade.
//
// EVERY EFFECT TERM CARRIES ITS NARROWING FILTER, because a rule that PASSED this function and still
// governs it is, by construction, usually a narrowed one — and the note is telling an operator what they
// wrote and what to write instead. Reconstructing from `effects` alone drops the filter from both halves
// and gets both wrong, in the two ways the two rungs found:
//
//   • ⟨0.19⟩ `deny Unknown[reflect] app` — the source form read back `deny Unknown app`, and appending a
//     second token produced the upgrade `deny Unknown Unknown app`, which is not a line anyone can paste.
//     Unreachable until `unverifiedHoleRule` learned to read `unknownClasses`.
//   • ⟨0.20⟩ `deny Net[unknown-host] app` — the source form read back `deny Net app`, and the offered
//     upgrade `deny Net Unknown app` silently WIDENS the operator's Net denial from one destination class
//     to all of them, while presenting itself as the addition of a single token. Reachable before this
//     rung (any Unknown-only function under a Net-narrowed rule), and on the hot path after it.
//
// So: each term is spelled with its own filter, and the UPGRADE widens the `Unknown` term ALONE — every
// other narrowing the operator wrote is preserved, because the hole being named is an Unknown one and
// nothing about it argues for changing where their Net may go. Byte-identical to the rust reference's
// `rule_and_upgrade` (conformance PART 12d pins the two against each other), and it subsumes the earlier
// raw-line special case: the tokens are sorted at parse, so the reconstruction IS the canonical spelling.
// ⟨0.33⟩ The source-form half is now `canonicalDenyRule` (CandorCore/Policy.swift) — the ONE renderer,
// shared with the SPEC §2 ⟨0.33⟩ `scannedUnder` key, so the string an operator is quoted here and the
// string a gate compares there cannot become two spellings of one rule.
public func ruleUpgrade(_ r: DenyRule) -> (rule: String, upgrade: String) {
    let suffix = r.scope.isEmpty ? "" : " \(r.scope)"
    if r.effects.isEmpty {
        return (canonicalDenyRule(r), "deny Unknown\(suffix)")
    }
    func term(_ e: String) -> String {
        if e == "Unknown", !r.unknownClasses.isEmpty { return "Unknown[\(r.unknownClasses.joined(separator: ","))]" }
        if e == "Net", !r.netClasses.isEmpty { return "Net[\(r.netClasses.joined(separator: ","))]" }
        return e
    }
    if r.effects.contains("Unknown") {
        // Already denies `Unknown`, so the edit is to UNNARROW that term — not to append a second one.
        let widened = r.effects.sorted().map { $0 == "Unknown" ? "Unknown" : term($0) }.joined(separator: " ")
        return (canonicalDenyRule(r), "deny \(widened)\(suffix)")
    }
    let effs = r.effects.sorted().map(term).joined(separator: " ")
    return (canonicalDenyRule(r), "deny \(effs) Unknown\(suffix)")
}

// The single predicate for a provable-purity hole (eval/fixloop/DISPATCH-NOTE.md): a function that is
// `Unknown`, sits in a pure/deny scope, and PASSES that rule (carries none of its forbidden real effects) —
// so its compliance is asserted but not verified (the Unknown could hide the very effect the rule forbids;
// the classic case is a fn/closure-injected port). A *real* violation is the gate's job, not this. Returns
// the first governing rule under which the function is such a hole, or nil. Shared by the gate note
// (main.swift) and `unverified` so "what a hole is" has ONE definition (conformance PART 12d pins agreement).
///
/// `classes` is the function's UNFLOORED transitive reason-class set (`matcherReasonClasses`) and `netCls`
/// its ⟨0.20⟩ destination-class set. Without them this predicate read `deny Unknown[reflect] app` and
/// `deny Net[unknown-host] app` as their bare forms, concluded "the gate is already reporting this one",
/// and returned nil — so a layer that PASSES a function while it carries an `Unknown` outside the rule's
/// filters was certified clean by the verb whose entire job is to say a green gate is not provably green.
/// The under-report half of the same missing conjunct `deniedLayer` over-charged on; see `ruleForbids`,
/// ScopedUnknownRemedyProcessTests and ScopedNetRemedyProcessTests.
public func unverifiedHoleRule(_ fn: String, _ inferred: Set<String>, _ deny: [DenyRule],
                               _ classes: Set<String>, _ netCls: Set<String>) -> DenyRule? {
    guard inferred.contains("Unknown") else { return nil }
    for r in deny {
        guard scopeMatches(fn, r.scope) else { continue }
        // Does this rule actually bite here? `pure` on any real effect; `deny E…` on a named effect —
        // on `Unknown` only when the rule's reason classes reach this function's, and on `Net` only when
        // its destination classes do.
        let violates = inferred.contains(where: { ruleForbids(r, $0, classes, netCls) })
        if !violates { return r }                                  // else a real violation the gate reports
    }
    return nil
}

/// Each function's TRANSITIVE `Unknown` reason-class set (SPEC §6.2), over a loaded report's entries —
/// the `unverified` counterpart of the gate's `reasonClassAcc`, and it must answer the same question the
/// same way or `--class` and `deny E Unknown[<class>]` disagree about one report.
///
/// Two rules, and BOTH are needed. Either alone is a defect in its own direction:
///
///  - ⟨0.24⟩ CONTRIBUTION. A function whose `Unknown` carries no recorded reason CONTRIBUTES `unresolved`
///    — never "defaults to it when the set is empty", which is keyed on absence and so is removed by
///    learning a second, classifiable reason. The reasonless case is `direct` ∋ `Unknown` with no
///    `unknownWhy`: the function introduced the hole itself and named nothing.
///  - TRANSITIVITY. `unknownWhy` is DIRECT-ONLY by SPEC §4, so an inherited `Unknown` records no reason
///    of its own and its class lives at the callee. Reading the direct field as if it were the
///    transitive one drops every inherited hole from every filter.
///
/// Applying the contribution rule to an INHERITED `Unknown` would be the mirror fabrication — an
/// `unresolved` on a function whose callee classified the hole perfectly well — which is why the
/// contribution is gated on `direct` and not on the absence of a reason. The final sweep is neither
/// rule: a function still carrying `Unknown` that nothing in its reach explains (a truncated report, a
/// callee entry in a report that was not loaded) is a hole nobody classified, and §6.2's conservative
/// projection for that is `unresolved`.
/// One §2 entry, reduced to the four fields a §6.2 class resolution reads — so `fix`/`fix-gate` (whose
/// rows are `FixFn`) and `unverified` (whose rows are `UnverifiedFn`) resolve classes through the SAME
/// code. Two copies of this fixpoint is exactly the drift SPEC §3.1 forbids between the gate's two routes.
typealias ReasonRow = (fn: String, inferred: Set<String>, direct: Set<String>, unknownWhy: [String], calls: [String])

/// The §6.2 seed-and-propagate. `floorUnexplained` decides what happens to an `Unknown` that NOTHING in
/// its reach explains (a truncated report, a callee whose entry was never loaded), and the two callers
/// need OPPOSITE answers — which is the whole reason this is a parameter and not a constant:
///
///  - `--class` FILTERING (`floorUnexplained: true`): §6.2's conservative projection for a hole nobody
///    classified is `unresolved`, so `--class unresolved` — the filter that exists to catch exactly
///    those — keeps it. Flooring here makes the filter DISCLOSE more.
///  - RULE MATCHING (`floorUnexplained: false`): the same floor would make `deny Unknown[unresolved]`
///    FIRE on that function, which drops it from `unverified` (the gate is presumed to own it) and
///    invents a `fix-gate` remedy — asserting a reason nobody recorded, in a predicate that CHARGES.
///    `evaluateGate` refuses the same floor for the same reason (Gate.swift's ⟨0.24⟩ note).
///
/// Both settings are the more-disclosing one for their caller. One principle, two maps.
func reasonClassFixpoint(_ rows: [ReasonRow], floorUnexplained: Bool) -> [String: Set<String>] {
    var seed: [String: Set<String>] = [:]
    var edges: [String: Set<String>] = [:]
    var unknownBearing: Set<String> = []
    for e in rows {
        if !e.calls.isEmpty { edges[e.fn, default: []].formUnion(e.calls) }
        if e.inferred.contains("Unknown") { unknownBearing.insert(e.fn) }
        if !e.unknownWhy.isEmpty {
            seed[e.fn, default: []].formUnion(e.unknownWhy.map(reasonClass))
        } else if e.direct.contains("Unknown") {
            seed[e.fn, default: []].insert("unresolved")
        }
    }
    var acc = propagate(seed, over: edges)
    if floorUnexplained {
        for fn in unknownBearing where acc[fn]?.isEmpty ?? true { acc[fn] = ["unresolved"] }
    }
    return acc
}

func reasonClassesTransitive(_ fns: [UnverifiedFn]) -> [String: Set<String>] {
    reasonClassFixpoint(fns.map { ($0.fn, $0.inferred, $0.direct, $0.unknownWhy, $0.calls) },
                        floorUnexplained: true)
}

/// Does any rule narrow `Unknown` on a reason class? THE ONLY condition under which the class map is
/// read at all — `ruleForbids` ignores `fnClasses` for every other rule shape — so it is also the only
/// condition under which the fixpoint is worth walking. Stated once, because `fix`, `fix-gate` and
/// `unverified` drifting about WHEN they resolve classes is how they would end up disagreeing about a
/// verdict again.
func narrowsOnReasonClass(_ deny: [DenyRule]) -> Bool { deny.contains { !$0.unknownClasses.isEmpty } }

/// The ⟨0.20⟩ sibling: does any rule narrow `Net` on a destination class? Same role — the only condition
/// under which the destination map is consulted at all.
func narrowsOnNetClass(_ deny: [DenyRule]) -> Bool { deny.contains { !$0.netClasses.isEmpty } }

/// The ⟨0.20⟩ destination-class map the rule predicates take: each function's `netClass`, READ OFF THE
/// REPORT, exactly as `gateInputFromReport` reads it.
///
/// There is no fixpoint here and that is not an omission. `unknownWhy` is DIRECT-ONLY by SPEC §4, so a
/// reason class has to be propagated to the callers that inherit the hole; `netClass` is written by the
/// producer from the ALREADY-ACCUMULATED host surface, so the transitive answer is the field's value. A
/// second propagation over it would be a second implementation of a derivation this consumer is not
/// entitled to redo — and could only disagree with the gate, which reads the same field flat.
///
/// Empty when nothing narrows, which `ruleForbids` then never consults.
func matcherNetClasses(_ fns: [UnverifiedFn], _ deny: [DenyRule]) -> [String: Set<String>] {
    guard narrowsOnNetClass(deny) else { return [:] }
    var out: [String: Set<String>] = [:]
    for e in fns where !e.netClass.isEmpty { out[e.fn, default: []].formUnion(e.netClass) }
    return out
}

/// The same map over the `fix`/`fix-gate` rows.
func matcherNetClasses(_ byName: [String: FixFn], _ deny: [DenyRule]) -> [String: Set<String>] {
    guard narrowsOnNetClass(deny) else { return [:] }
    var out: [String: Set<String>] = [:]
    for (fn, f) in byName where !f.netClass.isEmpty { out[fn] = Set(f.netClass) }
    return out
}

/// The UNFLOORED map the rule predicates take — matching `gateInputFromScan`'s `reasonClasses` exactly
/// (the §6.2 CONTRIBUTION applied at the ENTRY, on a DIRECT `Unknown` the function did not name, and no
/// floor in the matcher). Empty when nothing narrows, which the predicates then never consult. See
/// `ruleForbids` for why this map and `reasonClassesTransitive` must not be swapped.
func matcherReasonClasses(_ fns: [UnverifiedFn], _ deny: [DenyRule]) -> [String: Set<String>] {
    guard narrowsOnReasonClass(deny) else { return [:] }
    return reasonClassFixpoint(fns.map { ($0.fn, $0.inferred, $0.direct, $0.unknownWhy, $0.calls) },
                               floorUnexplained: false)
}

/// The same map over the `fix`/`fix-gate` rows.
func matcherReasonClasses(_ byName: [String: FixFn], _ deny: [DenyRule]) -> [String: Set<String>] {
    guard narrowsOnReasonClass(deny) else { return [:] }
    return reasonClassFixpoint(byName.map { ($0.key, $0.value.inferred, $0.value.direct, $0.value.unknownWhy, $0.value.calls) },
                               floorUnexplained: false)
}

// unverified: the PROVABLE-PURITY disclosure (eval/fixloop/DISPATCH-NOTE.md, mirrors candor-query). A
// `pure`/`deny E` layer PASSES a function that carries none of its forbidden effects — but if that function is
// `Unknown` (an unresolvable call), the pass is UNVERIFIED: the Unknown could hide the very effect the rule
// forbids (the fn/closure-port hole). Returns each such function + the `deny E Unknown <scope>` upgrade.
///
/// ⟨0.24⟩ …AND EVERY FUNCTION THE GATE COULD NOT JUDGE (SPEC §3.2, candor-spec `4fd140c`). A function
/// `gate --report` refuses over is an unverified hole in the strongest sense this verb has — it is
/// precisely *"your green gate is not provably green"* — and it was being cleared here, because the only
/// holes this loop knew how to name were `Unknown`-carrying ones and `app.noClass` (Net, `hosts`, no
/// `netClass`) carries no `Unknown` at all. See `Answerability.swift` for the measurement. The reason
/// recorded is the MISSING EVIDENCE (`unevaluated[].why`, the gate's own field) and the edit offered is
/// the evidence-free rule; neither is a class, because a derived class is the second opinion §3.2 says
/// an advisory verb is not entitled to.
public func unverified(_ fns: [UnverifiedFn], _ deny: [DenyRule], classFilter: Set<String>? = nil)
    -> (ok: Bool, holes: [UnverifiedHole], unanswered: [UnansweredRule]) {
    var holes: [UnverifiedHole] = []
    // Computed once, and ONLY when a filter will consult it — the unfiltered list is unchanged by it.
    let classes = classFilter == nil ? [:] : reasonClassesTransitive(fns)
    // The MATCHER's map, and a DIFFERENT one: unfloored, because here an unexplained `Unknown` must read
    // as "the rule does not provably bite" (→ a disclosed hole), where `--class` wants it floored to
    // `unresolved` (→ kept by the filter that hunts exactly those). See `reasonClassFixpoint`. Computed
    // only when some rule actually narrows — no narrowed rule, no map consulted, no cost.
    let matcherClasses = matcherReasonClasses(fns, deny)
    // ⟨0.20⟩ the destination-class half, which no map here could DERIVE — see `matcherNetClasses`.
    let matcherNet = matcherNetClasses(fns, deny)
    // ⟨0.24⟩ THE §3.2 BOUND — every (rule, function) the gate could not decide. Resolved BEFORE the hole
    // loop and not after it, because a row the hole loop is about to emit may be one of these, and then
    // its refusal has to ride out ON it (see `sortedCells` below).
    var inferredByFn: [String: Set<String>] = [:]
    for e in fns { inferredByFn[e.fn, default: []].formUnion(e.inferred) }
    let cells = unanswerableCells(inferred: inferredByFn, reasonClasses: matcherClasses,
                                  netClasses: matcherNet, deny: deny)
    // Sorted ONCE and read twice — by the attachment below and by the append at the end — so that when a
    // pair has TWO cells (one rule narrowing both `Net` and `Unknown`, defeated on both at one function)
    // the reason that rides on the row is the same one either path would have appended. `effect` is the
    // tiebreak and is not decoration: without it the ordering of two cells sharing an (fn, rule) is
    // whatever the sort happens to do, and the row would carry an arbitrary one of two true reasons.
    // `Net` < `Unknown` reproduces `unanswerableCells`'s own stated order (Net checked first).
    let sortedCells = cells.sorted(by: { ($0.fn, $0.rule.raw, $0.effect) < ($1.fn, $1.rule.raw, $1.effect) })
    // THE REFUSAL, KEYED BY (function, rule) — the join a per-entry consumer would otherwise have to
    // perform against `unevaluated[]` by hand, and could not know was required. See `UnverifiedHole.why`
    // for the four-way measurement; the key is on the PAIR rather than on the answerability pass's rows
    // because the reason-class arm produces no such row (the hole loop already emitted it).
    //
    // FINER-GRAINED THAN `unevaluated[]`, which names ONE exemplar function per rule (`unansweredDisclosure`)
    // because a rule is the field an operator edits. An ENTRY is not read that way: it is read about its own
    // function, so it carries its own function's reason. For the exemplar the two are the same bytes; for
    // every other function under the same rule the entry is the one that names the right function.
    var whyByPair: [String: String] = [:]
    for c in sortedCells where whyByPair["\(c.fn)|\(c.rule.raw)"] == nil {
        whyByPair["\(c.fn)|\(c.rule.raw)"] = c.why
    }
    for e in fns {
        // Same predicate + upgrade as the gate note (main.swift) — one source of truth for a hole.
        guard let r = unverifiedHoleRule(e.fn, e.inferred, deny, matcherClasses[e.fn] ?? [],
                                         matcherNet[e.fn] ?? []) else { continue }
        // ⟨0.20⟩ --class: keep only holes whose Unknown is of a matching reason class. ⟨0.24⟩ that class
        // set is the TRANSITIVE one above, not the report's direct `unknownWhy` field: measured on
        // pollen under `deny Exec`, the direct reading returned 230 of 387 holes for `--class dynamic`,
        // a filter which names every genuine class and therefore cannot exclude one.
        if let cf = classFilter, !(classes[e.fn] ?? []).contains(where: { cf.contains($0) }) { continue }
        let (rule, upgrade) = ruleUpgrade(r)
        // …and if the gate ALSO could not judge this pair, the row says so itself. This is the whole
        // reason-class arm: the function is an ordinary hole AND unjudged, the dedupe below then declines
        // to add a second row for it, and before this the refusal simply did not survive the tie.
        holes.append(UnverifiedHole(fn: e.fn, rule: rule, unknownWhy: e.unknownWhy, upgrade: upgrade,
                                    why: whyByPair["\(e.fn)|\(rule)"]))
    }
    // The answerability pass's own rows, appended in code-point order after the holes this verb already
    // knew about — a separate pass because it is a separate question (`Answerability.swift`: *can this be
    // answered*, not *does this rule forbid it*), and one entry per pair rather than per rule because the
    // whole point is naming the FUNCTION.
    //
    // NOT SUBJECT TO `--class`, and this is the one design choice here worth arguing for. The filter
    // selects among holes BY REASON CLASS; a function the gate could not judge has no reason class to
    // select on, and a `Net` refusal has none at all. Excluding these would make the filter succeed
    // BECAUSE THE EVIDENCE IS MISSING — the exact shape of the defect this rung closes, one level down.
    // It is also wrong on §6.2's own terms: the class set only ever GROWS, so an Unknown nobody
    // classified COULD be `dispatch`, and `--class dispatch` dropping it asserts that it is not.
    // MEASURED on the derived pollen corpus (`unknownWhy` + `calls` stripped, `deny Unknown[dispatch]`):
    // 199 functions, every one of them a candidate the report cannot rule in or out.
    //
    // ONE ENTRY PER (function, rule), and the loop above wins the tie. The two passes OVERLAP whenever a
    // narrowed rule is both unanswerable and non-biting at the same function — the reason-class arm is
    // exactly that case, which is how the containment already held there BY ACCIDENT while `--strict`
    // still exited 0. A second row for a function already named would double-count a hole without
    // naming a new one; the winning row carries the refusal as its `why` (rust and ts instead emit that
    // second row, which is the same disclosure at the cost of the invariant this dedupe protects).
    var seenPair = Set(holes.map { "\($0.fn)|\($0.rule)" })
    for c in sortedCells where seenPair.insert("\(c.fn)|\(c.rule.raw)").inserted {
        holes.append(UnverifiedHole(fn: c.fn, rule: c.rule.raw, unknownWhy: [],
                                    upgrade: evidenceFreeRule(c.rule, effect: c.effect), why: c.why))
    }
    return (holes.isEmpty, holes, unansweredDisclosure(cells))
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
