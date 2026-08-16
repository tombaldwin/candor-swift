import Foundation

// ⟨0.24⟩ SPEC §3.2 — **AN ADVISORY VERB MAY BE LESS CERTAIN THAN THE GATE, NEVER MORE** (candor-spec
// `4fd140c`). One predicate, three consumers, because the law is a COMPARISON and a comparison cannot be
// checked from two implementations of the thing being compared.
//
// THE QUESTION THIS FILE ANSWERS is not `ruleForbids`'s. That one asks *does this rule forbid this
// effect here*; this one asks *can that question be answered AT ALL from what the report carries*. They
// are different questions with different failure modes, and conflating them is the shape of the defect:
// `ruleForbids` treats an empty class set as NOT-forbidden — deliberately, so the matcher withholds
// rather than charging on a default — and that answer is correct for a function whose classes are known
// and simply do not match. For a function whose class set is EMPTY BECAUSE THE FIELD IS ABSENT it is
// also "not forbidden", and there the two situations become indistinguishable downstream. The gate
// already separates them (`gate --report` refuses, exit 2, §3.1 answerability); nothing else did.
//
// MEASURED on this engine over the conformance R11 report — `hosts` present, `netClass` absent — under
// `deny Net[unknown-host] app`:
//
//     gate --report        exit 2   it could NOT judge `app.noClass`
//     unverified           exit 0   names `app.nativeHole` and CLEARS `app.noClass`
//     unverified --strict  exit 0   green
//     fix-gate  --strict   exit 0   green, `ok:true`
//
// The mechanism here is NOT the fallback derivation §3.2 describes — `matcherNetClasses` reads the
// report's `netClass` verbatim and derives nothing. It is that `unverified` only ever considered
// `Unknown`-carrying functions, so a function the gate could not judge for a DIFFERENT reason had no
// channel at all and fell off the end. Same direction of error, different mechanism, which is why the
// spec states the invariant rather than a behaviour: **U_clear ⊆ G_clear.**
//
// WHY THE PREDICATE IS MINIMAL, AND WHAT MAKES THAT SAFE (SPEC §3.1, restated at the gate's own call
// site): a class-scoped `deny` is not unanswerable merely because some evidence is thin. The class set
// only ever GROWS (§6.2 — a reason is CONTRIBUTED, never retracted) and `Reject` is upward-closed in it
// (PAPER3 Lemma 2), so a NON-EMPTY determinable set answers the rule outright: it fires or it does not,
// and no further evidence could change which. Only an EMPTY determinable set leaves the question open.
// That is the one state named here, and it is why the mirrors hold — carry one token of evidence and
// every verb goes back to silence.

/// ONE (rule, function) pair this report cannot decide. `effect` is the one whose FILTER could not be
/// read (`Net` or `Unknown`), and it is carried rather than inferred at the use site because the
/// `fix`/`fix-gate` suppression is keyed on it: an unanswerable `Net` filter says nothing about an `Fs`
/// crossing, and a suppression that ignored the effect would make the advisory verb LESS USEFUL than the
/// gate rather than merely less certain — the gate keeps charging the violations it is sure of (§3.1
/// precedence).
public struct UnansweredCell {
    /// the function whose missing evidence defeats the rule.
    public let fn: String
    /// `Net` or `Unknown` — the effect whose narrowing filter has nothing to read.
    public let effect: String
    /// the rule, as parsed. `rule.raw` is the verbatim policy line the disclosure keys on.
    public let rule: DenyRule
    /// the gate's own prose for this refusal, verbatim.
    public let why: String
}

/// ONE ENTRY OF THE `unevaluated: [{rule, why}]` DISCLOSURE — the gate's shape (SPEC §3.1, candor-spec
/// `fc4b5f6`), reused rather than respelled. §3.2 is explicit that inventing a second spelling for this
/// is the mistake the document has already made four times, so the advisory verbs emit these bytes and
/// the gate's `Unevaluated` is built from them.
public struct UnansweredRule {
    /// the RAW policy line, verbatim — never a kind, never a count.
    public let rule: String
    /// why this run could not decide it.
    public let why: String
    /// the function that defeated it — the exemplar, not the whole set (see `unansweredDisclosure`).
    public let fn: String
    /// `Net` or `Unknown`.
    public let effect: String
    public func toJSON() -> [String: Any] { ["rule": rule, "why": why] }
    /// ⟨0.29⟩ PUBLIC so a report route can add the two WHOLE-POLICY unanswerable kinds (`forbid`,
    /// `allow`) to this list. Those are unanswerable over the whole report rather than at a function, so
    /// `fn` and `effect` are empty — and the renderers partition on `fn.isEmpty` rather than printing a
    /// blank name, because a refusal rendered as an empty identifier reads as a bug in the tool.
    public init(rule: String, why: String, fn: String, effect: String) {
        self.rule = rule; self.why = why; self.fn = fn; self.effect = effect
    }
}

/// EVERY (rule, function) pair this report cannot decide, in the gate's own iteration order: rule outer,
/// function inner and code-point sorted, `Net` checked before `Unknown` at each function.
///
/// `inferred`, `reasonClasses` and `netClasses` must be the maps the MATCHER uses — the §6.2 fixpoint
/// with the CONTRIBUTION applied and NO `unresolved` floor, and the report's `netClass` read flat. Hand
/// in the floored reason map and this predicate stops firing on exactly the functions it exists to
/// catch; hand in a re-derived destination map and it becomes the second opinion §3.2 forbids.
public func unanswerableCells(inferred: [String: Set<String>],
                              reasonClasses: [String: Set<String>],
                              netClasses: [String: Set<String>],
                              deny: [DenyRule]) -> [UnansweredCell] {
    // Nothing narrows ⇒ nothing can be unanswerable, and the maps are never consulted. Stated first so
    // the ordinary policy pays nothing for this file existing.
    guard deny.contains(where: { !$0.netClasses.isEmpty || !$0.unknownClasses.isEmpty }) else { return [] }
    var out: [UnansweredCell] = []
    for r in deny {
        guard !r.netClasses.isEmpty || !r.unknownClasses.isEmpty else { continue }
        for fn in inferred.keys.sorted() where scopeMatches(fn, r.scope) {
            let inf = inferred[fn] ?? []
            if !r.netClasses.isEmpty, inf.contains("Net"), (netClasses[fn] ?? []).isEmpty {
                out.append(UnansweredCell(fn: fn, effect: "Net", rule: r, why:
                    "`\(r.raw)` narrows on the Net DESTINATION CLASS, but `\(fn)` carries Net with no "
                    + "`netClass` in this report — the field the filter reads is absent, so the narrowing "
                    + "would succeed for lack of evidence and drop a Net the bare `deny Net` catches. "
                    + "Refusing (exit 2) rather than passing: an absent optional field must not relax a "
                    + "fail-closed gate. Use the bare `deny Net`, or gate at scan time."))
            }
            if !r.unknownClasses.isEmpty, inf.contains("Unknown"), (reasonClasses[fn] ?? []).isEmpty {
                out.append(UnansweredCell(fn: fn, effect: "Unknown", rule: r, why:
                    "`\(r.raw)` narrows on the Unknown REASON CLASS, but `\(fn)` carries Unknown with no "
                    + "reason reachable in this report — neither its own `unknownWhy` nor a `calls` edge to "
                    + "one. §6.2 resolves the class set TRANSITIVELY over the gate's reach; with the channel "
                    + "missing, every narrowed filter silently tolerates while only the bare `deny Unknown` "
                    + "fires. Refusing (exit 2). Use the bare `deny Unknown`, or gate at scan time."))
            }
        }
    }
    return out
}

/// THE DISCLOSURE: at most ONE entry per RULE, the first function that defeats it being the example.
/// SPEC §3.1's granularity, and the reason it is not per-cell — naming every match buries the rule,
/// which is the field an operator acts on. The full cell list stays available for the `fix`/`fix-gate`
/// suppression, which needs every function and not an exemplar.
public func unansweredDisclosure(_ cells: [UnansweredCell]) -> [UnansweredRule] {
    var seen = Set<String>()
    var out: [UnansweredRule] = []
    for c in cells where seen.insert(c.rule.raw).inserted {
        out.append(UnansweredRule(rule: c.rule.raw, why: c.why, fn: c.fn, effect: c.effect))
    }
    return out
}

/// The (function, effect) pairs a remedy must not assert a layer status for. Membership means: for THIS
/// effect, at THIS function, the gate declined to say whether the layer allows it — so an instruction
/// that treats it as an allowed boundary, or as a denied one, is a guess wearing a plan's clothes.
public func unanswerablePairs(_ cells: [UnansweredCell]) -> Set<String> {
    Set(cells.map { "\($0.fn)|\($0.effect)" })
}

/// THE EVIDENCE-FREE FORM OF A RULE — the edit `unverified` offers beside a function the gate could not
/// judge. It DROPS the narrowing on the term whose evidence is missing and touches nothing else:
/// `deny Net[unknown-host] app` → `deny Net app`, `deny Exec Unknown[dispatch] app` → `deny Exec
/// Unknown app`.
///
/// Derived from the POLICY ALONE, which is the whole point. `ruleUpgrade`'s `Unknown`-widening edit is
/// the answer to a different question ("this layer passes an Unknown") and offering it here would tell
/// an operator to add a term when the actionable change is to stop depending on a field their report
/// does not carry — which is also, verbatim, what the gate's own refusal already recommends.
public func evidenceFreeRule(_ r: DenyRule, effect: String) -> String {
    let suffix = r.scope.isEmpty ? "" : " \(r.scope)"
    func term(_ e: String) -> String {
        if e == effect { return e }
        if e == "Unknown", !r.unknownClasses.isEmpty { return "Unknown[\(r.unknownClasses.joined(separator: ","))]" }
        if e == "Net", !r.netClasses.isEmpty { return "Net[\(r.netClasses.joined(separator: ","))]" }
        return e
    }
    if r.effects.isEmpty { return "pure\(suffix)" }
    return "deny \(r.effects.sorted().map(term).joined(separator: " "))\(suffix)"
}
