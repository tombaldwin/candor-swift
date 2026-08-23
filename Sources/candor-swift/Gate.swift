// candor-swift — §6.2 gate EXECUTION (report → violations) + the §3.3 structured verdict.
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation
import CandorCore

// ════════════════════════════════════════════════════════════════════════════════════════════════
// §6.2 policy gate (deny / pure / allow / forbid)
// The PURE parser + literal matchers (parsePolicy / scopeMatches / hostPart / pathCovered /
// dbTableCovered / literalAllowed) live in CandorCore/Policy.swift — token-for-token with the family
// parsers, directly unit-tested there; this file keeps only the gate EXECUTION (report → violations).
// ════════════════════════════════════════════════════════════════════════════════════════════════


// A structured gate violation (candor-spec §3.3 ⟨0.8⟩): `effects` is the specific effect set the violation
// concerns — the denied set (006), the allowed effect (008), or [] (009 layer-flow); `detail` is the message
// BODY (no `[AS-EFF-00x]` prefix — the rule carries the code). The console prints `[rule] detail`; --gate-json
// serializes the records verbatim. Written from the SAME list that sets the exit code, so it can't disagree.
// ⟨0.19⟩ `reasonClass`: on an AS-EFF-006 violation whose `effects` include `Unknown`, all reason classes
// present (transitively) on the fn — every reason the strict gate bit (SPEC §6.2). Empty otherwise.
// ⟨0.20⟩ `netClass`: on an AS-EFF-006 violation whose `effects` include `Net`, all destination classes
// present (transitively) on the fn — which class the security gate bit (NET-DESTINATION-CLASS-DESIGN.md).
typealias GateViolation = (rule: String, fn: String, effects: [String], detail: String, reasonClass: [String], netClass: [String])

/// ⟨0.24⟩ ONE POLICY RULE THIS RUN COULD NOT DECIDE (SPEC §3.1, candor-spec `fc4b5f6`).
///
/// The exit-1 clause said the refusal "MUST still disclose which rules could not be evaluated" and named
/// no field, no shape and no channel — sitting beside the clause requiring every machine field to be
/// pinned in the rung that introduces it. MEASURED on `deny Fs` + `allow Fs /var/data`, exit 1:
///
///     rust    NOTHING in the document — stderr only
///     swift   NOTHING in the document — stderr only            ← this engine
///     java    "unevaluated": [{"rule": "forbid (× 1)"}]        ← a KIND AGGREGATE; WHICH rules is lost
///     ts      "unevaluated": [{"rule": "<raw line>", "why"}]   ← correct, and the pinned shape
///
/// **A machine consumer of this engine's exit-1 verdict could not see that any rule went unevaluated at
/// all** — a finding that never reaches the consumer, arriving through the disclosure this rung added to
/// stop exactly that. stderr is not the machine channel; that is the same distinction that made the
/// incomplete-analysis defect a defect.
///
/// ONE ENTRY PER RULE, `rule` being the RAW policy line VERBATIM. Java's aggregate answers "how many"
/// when the operator's question is "which", so it satisfies a naive reading of "disclose which rules"
/// while answering the other one. OMITTED when empty, so a fully-answered verdict stays byte-identical
/// and the four-way clean-gate comparison is untouched.
///
/// It rides BOTH documents, matching the reference engine: the exit-1 VERDICT (where a violation
/// dominates and the unanswered rules travel beside it) and the exit-2 REFUSAL document (where they ARE
/// the reason). Withholding it from the refusal document would put the whole disclosure back on stderr in
/// exactly the case where nothing else is said.
struct Unevaluated {
    /// the RAW policy line, verbatim — never a kind, never a count.
    let rule: String
    /// why this run could not decide it.
    let why: String
}

/// The `unevaluated` array as it goes on the wire — shared by the verdict and the refusal document so the
/// two can never spell it differently.
private func unevaluatedJson(_ xs: [Unevaluated]) -> [[String: Any]] {
    xs.map { ["rule": $0.rule, "why": $0.why] as [String: Any] }
}

func writeGateVerdict(_ violations: [GateViolation], to path: String, spec: String,
                      analyzedCount: Int,
                      unanalyzed: [(path: String, reason: String)] = [],
                      coverage uncoveredModules: [String] = [],
                      policyVocabulary: (config: String, aliases: [String: [String]])? = nil,
                      // ⟨0.31⟩ the ambient `net-partner` records that MOVED a classification — a LIST,
                      // because a `--report` prefix can match several reports each anchoring its own
                      // config, while one report carries one record. Copied, never recomputed.
                      netPartners: [(config: String, hosts: [String])] = [],
                      unevaluated: [Unevaluated] = [],
                      ignored: [IgnoredLine] = [],
                      outOfScope: [OutOfScopeFinding] = [],
                      // ⟨0.32⟩ exclusion classes this scan did NOT READ — `excluded[].peeked == false`
                      // without `judgedElsewhere`. Defaulted so every existing caller keeps compiling and
                      // keeps its current verdict; the routes that can supply it pass it explicitly.
                      unpeeked: [String] = []) {
    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): a gate over source candor could NOT analyze must NOT read green —
    // its effects are invisible, so a `deny`/`allow` that "passes" over it is a false-pure. `ok` requires
    // BOTH no violation AND a complete analysis (the caller exits 2 on this incomplete-but-clean path).
    // ⟨0.30⟩ THE SECOND CAUSE. `unanalyzed` is "I opened this file and could not read it"; `outOfScope` is
    // "I never opened it, and when the peek looked afterwards it performed the effect this policy denies".
    // Both mean the gate could not see enough of the tree to certify it, so both suppress `ok`. Reverses
    // ⟨0.29⟩'s "the verdict does not move" on the measurement that the peek resolves a CONCRETE denied
    // effect rather than uncertainty.
    // ⟨0.32⟩ THE THIRD CAUSE — code this scan admits it never READ. ⟨0.30⟩ keys on what the peek FOUND,
    // and a peek that could not open a file finds nothing, which is byte-identical to finding it clean.
    // MEASURED on candor-java before the rung: `deny Exec` passed green over a tree holding an
    // uncompiled source calling `Runtime.exec("curl … | sh")`, with `excluded` saying `peeked: false`
    // beside it and that flag moving no verdict at all.
    let incomplete = !unanalyzed.isEmpty || !outOfScope.isEmpty || !unpeeked.isEmpty
    var dict: [String: Any] = [
        "spec": spec,
        "ok": violations.isEmpty && !incomplete,
        // ⟨0.21⟩ (Gap 1) the analyzed-universe count, so a --gate-json consumer sees the scan's scope from the
        // verdict alone (mirrors the report envelope's `analyzed`). ALWAYS present.
        "analyzed": ["count": analyzedCount] as [String: Any],
        "violations": violations.map { v -> [String: Any] in
            var m: [String: Any] = ["rule": v.rule, "fn": v.fn, "effects": v.effects, "detail": v.detail]
            if !v.reasonClass.isEmpty { m["reasonClass"] = v.reasonClass }  // omitted when empty (byte-compat)
            if !v.netClass.isEmpty { m["netClass"] = v.netClass }           // ⟨0.20⟩ omitted when empty
            return m
        },
    ]
    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): the machine-legible incompleteness — the units candor couldn't
    // analyze, so a CI/agent reading the JSON learns WHY the gate can't certify (the stderr line alone hid
    // this from a machine). `incomplete:true` + the list; the caller exits 2 (could-not-fully-evaluate).
    if incomplete {
        dict["incomplete"] = true
        if !unanalyzed.isEmpty {
            dict["unanalyzed"] = unanalyzed.map { ["path": $0.path, "reason": $0.reason] as [String: Any] }
        }
    }
    // ⟨0.30⟩ …and WHICH functions made it incomplete, in the machine channel — the same entries the report
    // carries, so `gate --report` re-emits them from the report and §3.1's byte-equality holds by
    // construction. Omitted when empty, so a clean verdict stays byte-identical to a ⟨0.29⟩ one.
    if !outOfScope.isEmpty { dict["outOfScope"] = outOfScope.map { $0.toJSON() } }
    // ⟨0.15 staged⟩ advisory coverage note (SPEC §2 `coverage` re-disclosure): when the scan's κ ledger
    // is non-empty, the verdict names the uncovered modules — VERDICT-PRESERVING (the ⟨0.9⟩ provable-purity
    // auto-disclosure precedent): ok/violations/exit are computed exactly as before, this field only ADDS.
    // A gate does NOT fail on uncovered deps (nearly every real scan has some); the policy author decides.
    // ⟨0.24⟩ SPEC §3.1 pins the VERDICT's coverage block as `{ "uncovered": <n>, "packages": [ … ] }`, and
    // until 2026-07-28 this document never said so. §2 defines the REPORT's ledger — `coverage.uncovered`
    // as an ARRAY of `{name, calls}` — which is a DIFFERENT shape from the verdict's (a count plus a name
    // list), so the verdict shape was never pinned and the engines diverged unobserved: rust and ts emit
    // `packages`, this engine emitted `modules`, and the single prose mention in §3.1 said `modules` too,
    // because it was written describing THIS engine's output. `packages` is correct, and NOT because it is
    // three-to-one: the §2 envelope names the very same objects `package`/`packages`, so a verdict that
    // renames them mid-document is drift, and `module` already means a different thing in two of the four
    // implementation languages (a compilation unit, which is not what is being counted).
    if !uncoveredModules.isEmpty {
        dict["coverage"] = ["uncovered": uncoveredModules.count, "packages": uncoveredModules.sorted()] as [String: Any]
    }
    // ⟨0.24⟩ THE AMBIENCE IS DISCLOSED (SPEC §3.1): if a config file supplied VOCABULARY that participated
    // in this verdict — today `unknown-alias`, the only key that expands a policy token — the document
    // NAMES that file AND the aliases it supplied. Config discovery walks parent directories, so an alias
    // file anywhere above the policy participates; a verdict changed by a file the operator cannot see
    // named in the output is the ambient-input failure this format exists to refuse. Present only when the
    // vocabulary was actually CONSUMED: a config that defines aliases nobody asked for is not an input to
    // this verdict, and naming it unconditionally is noise a reader learns to ignore.
    //
    // KEY AND SHAPE ARE FOUR-WAY, not this engine's choice. It shipped here for one commit as a
    // `configSources` string list; conformance PART 27 R9's key-parity arm — added the same day, because
    // WITHIN-engine byte-equality is structurally blind to a key every route of one engine spells the same
    // wrong way — measured java and ts on `policyVocabulary: {config, aliases}`, rust on `vocabulary`, and
    // swift on `configSources`. Three names for one field, and none of them wrong on its own.
    //
    // ⟨0.24⟩ AND `aliases` IS AN OBJECT — `{"corp": ["reflect"]}`, each alias mapped to the classes it
    // EXPANDS TO (SPEC §3.1, candor-spec `7f5b5ba`). This engine shipped the ARRAY `["corp"]`, as did rust
    // and java; candor-ts kept the object and won the argument against the three of us from this section's
    // own sentence, not from a headcount: `configSources: [path]` is rejected three paragraphs down because
    // *a disclosure that names the source but not the content leaves the reader knowing they were affected
    // and not how* — and `aliases: ["corp"]` fails that same test ONE LEVEL DOWN. `corp = reflect` and
    // `corp = reflect,native` gate DIFFERENTLY under one unchanged policy line, so a reader handed only the
    // NAME cannot tell which gate ran. The object is a strict superset: a consumer that wanted the array
    // still has it as the key set. Classes sorted, as the alias names already were, for byte-stability.
    // ⟨0.31⟩ same position on both routes, because §3.1 makes byte-equality between the scan verdict and
    // the `gate --report` verdict the acceptance test. Omitted when empty, so every verdict without
    // ambient partner vocabulary stays byte-identical.
    if !netPartners.isEmpty {
        dict["netPartners"] = netPartners.map { ["config": $0.config, "hosts": $0.hosts] }
    }
    if let pv = policyVocabulary, !pv.aliases.isEmpty {
        dict["policyVocabulary"] = ["config": pv.config,
                                    "aliases": pv.aliases.mapValues { $0.sorted() }] as [String: Any]
    }
    // ⟨0.24⟩ WHICH RULES THIS VERDICT DOES NOT ANSWER (SPEC §3.1) — see `Unevaluated`. Exit 1 reports the
    // violation it is sure of; it does not conceal the part it could not read, and it does not confine
    // that admission to stderr.
    if !unevaluated.isEmpty { dict["unevaluated"] = unevaluatedJson(unevaluated) }
    // ⟨0.28⟩ SPEC §6.2 — THE LINES THE PARSE DROPPED, so a machine consumer can see that the gate it is
    // reading is smaller than the gate that was written. The zero-rule refusal fires only at zero
    // survivors; at every fraction below 100% the human channel warned per line and this document said
    // nothing — a 90%-gateless green. Distinct from `unevaluated` (rules that PARSED and could not be
    // answered): this is text that never became a rule at all. Omitted when nothing was dropped, so a
    // clean policy's verdict stays byte-identical; carried on BOTH routes (this writer serves them both,
    // and §6.2 measured the defect on `gate --report` too — a route is not covered by its sibling).
    if !ignored.isEmpty { dict["ignored"] = ignored.map(\.json) }
    // ⟨0.27⟩ SPEC §4 `zeroMatch` — the rules whose SCOPE bound no function, verbatim: the same list the
    // stderr lines carry, in the machine channel, on BOTH routes (this writer serves them both). It was
    // stderr-only in all five engines, so a wrapper reading the document could not see that a rule bound
    // nothing — the typo'd-scope silent green, one channel over. Disclosure only: `ok` above and the
    // caller's exit code never consult it; omitted when empty so a fully-binding verdict is
    // byte-identical. Stashed by `evaluateGate` rather than passed, so no caller can forget it.
    if !lastGateZeroMatch.isEmpty { dict["zeroMatch"] = lastGateZeroMatch }
    if path == "-" {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) { print(s) }
    } else {
        // The verdict is a SURFACING side-output and MUST NOT change the gate's exit code — writeJson's
        // failure path exits 1, which turned a PASSING gate into a red check when the path was unwritable
        // (max-review find). One stderr line instead; the process keeps the gate's true exit.
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            // ⟨0.28⟩ through the shared sink writer: `.atomic` renames, which replaces a symlink and
            // strands a hard link's other name. See writeSinkAtomically.
            try writeSinkAtomically(String(decoding: data, as: UTF8.self), to: path)
        } catch {
            FileHandle.standardError.write("candor-swift: could not write --gate-json \(path): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
}

/// ⟨0.24⟩ THE REFUSAL DOCUMENT (SPEC §3.1) — what `--gate-json` gets when the gate REFUSES.
///
/// **THE STALE-VERDICT HAZARD.** A refusal used to write nothing at all, so the canonical CI wrapper
/// (`candor-swift gate … --gate-json v.json || true` then `jq .ok v.json`) re-read **the PREVIOUS run's
/// document as current** — a green file from yesterday's clean run, still on disk, is how a refusal
/// becomes an all-clear. Deleting the path is not the fix either: a consumer that treats a missing file
/// as "nothing to report" fails open by a different route. The only safe answer is a document whose
/// NAIVE read is the fail-closed one, because the naive read is the one that ships.
///
/// `ok: false` so a consumer keying only on `ok` lands on FAIL; `refused: true` + `reason` so one keying
/// on `refused` learns why. **NO `violations` KEY, and that absence is load-bearing**: the gate is making
/// no claim about violations here, and `[]` is precisely the claim it cannot make — every consumer in
/// existence reads an empty array as "we looked and found none". ABSENT, not empty.
///
/// A failure to WRITE is not escalated: the exit is already 2 and already fail-closed, and a second exit
/// code would be a lie about which refusal happened. It is disclosed on stderr naming the stale-read
/// consequence, because that is the one thing the operator can act on.
/// ⟨0.24⟩ Where a refusal document goes, set by whichever CLI parsed `--gate-json` / `--json`. Module-wide
/// because THE REFUSAL DOCUMENT HAS NO EXEMPT CAUSE (SPEC §3.1, candor-spec `1503368`): an unreadable
/// policy, a broken `.candor/config` and an invalid baseline all leave the same stale document on disk as
/// an answerability refusal does, and a stale green does not care why this run declined to overwrite it.
/// Those causes are raised in files that never see the gate's own choreography, so the sink travels
/// instead of the plumbing. EMPTY until a CLI sets it, which is what keeps a pre-flag usage error (where
/// `--gate-json`'s value is not yet known, or is the thing being rejected) from writing anywhere.
///
/// `nonisolated(unsafe)` because this is a single-threaded CLI process: the value is written once, by the
/// verb's flag loop, before any work begins, and read only on the way out.
nonisolated(unsafe) var gateVerdictSinks: [String] = []

/// ⟨0.27⟩ The refused policy's rules, when a certain violation DOMINATED a whole-policy refusal and the
/// run therefore writes a VERDICT (exit 1) rather than a refusal document. Set by the scan route's
/// `refuseUnlessAViolationStands`; read by the one `writeGateVerdict` call on that route. It lives here
/// rather than beside the caller because the write happens ~150 lines later, past `break policyBlock`,
/// and a local would have had to be threaded through a scope the refusal jumps out of.
///
/// Empty on every other path — including a SOLE refusal, which writes the refusal document with its own
/// `unevaluated` argument and never reaches the verdict tail.
nonisolated(unsafe) var gateUnevaluated: [Unevaluated] = []

/// ⟨0.27⟩ SPEC §4 `zeroMatch` — the raw text of every rule whose SCOPE bound no function, stashed by the
/// one `evaluateGate` call a run performs and read by `writeGateVerdict` so the disclosure reaches the
/// machine channel on BOTH routes without threading a parameter through every caller. Same shape and
/// same single-threaded-one-shot-CLI safety argument as `gateVerdictSinks` above. Empty until a gate
/// evaluates, which is also why the refusal document (written when the gate never evaluated) can never
/// carry it.
nonisolated(unsafe) var lastGateZeroMatch: [String] = []

/// SPEC §3.3.1 ⟨0.28⟩ (4) — was `--json` (the REPORT stream) requested? Set once in the scan CLI before
/// the pre-pass, so every exit-2 path downstream can decide *what to write on exit-2* the same way
/// `gateVerdictSinks` decides for the verdict sink. On this engine `--json` is stdout-only (it takes no
/// value; a following non-flag token is a second positional, refused later), so
/// `argv.contains("--json")` is exact.
///
/// Rule (4) of the ⟨0.28⟩ report-sink clause: on any exit-2 in a `--json` run, the fail-closed report is
/// written to stdout, exactly once, as the stream's only content. An empty stream on exit-2 throws a
/// JSON consumer back to scraping stderr — the distinction that made the incomplete-analysis defect a
/// defect. Measured four-way on the unknown-flag exit-2, stdout was 0 bytes on every engine.
nonisolated(unsafe) var wantJsonStream = false

/// SPEC §3.3.1 ⟨0.28⟩ — has the successful scan already printed the report to stdout via `--json`?
/// Set on the successful `--json` write in main.swift, so a later `exit(2)` from the gate-completeness
/// arm below the report does not double-write a fail-closed placeholder over the real report a
/// consumer just parsed. Two documents on one stream is exactly the shape the two-stream refusal
/// clause already exists to prevent, arriving through a different door.
nonisolated(unsafe) var reportStreamWritten = false

/// SPEC §3.3.1 ⟨0.28⟩ (4) — the fail-closed REPORT is written to stdout as its only content on any
/// exit-2, if `--json` (stream) was requested. Shape is the ⟨0.21⟩ Row-1 manifest-carrying empty:
/// `functions: []` + `analyzed.count: 0` + `unanalyzed` naming the cause. A ⟨0.24⟩ consumer already
/// reads this as *nothing was judged, no purity licence*, so no new reader logic is needed. Called
/// from `refuseGateAndExit` and every direct-`exit(2)` site in the scan CLI.
///
/// A no-op if `--json` was not requested, if `--gate-json -` also claims stdout (the two-stream case
/// is refused with a verdict document earlier, and its refusal document IS the one document on that
/// stream), or if the report has already been printed to stdout (a completed scan on `--json`;
/// guarded by `reportStreamWritten`).
func writeReportStreamFailClosed(reasonKey: String, why: String) {
    guard wantJsonStream else { return }
    if gateVerdictSinks.contains("-") { return }
    if reportStreamWritten { return }
    guard let text = failClosedReportDocument(reason: "\(reasonKey): \(why)") else { return }
    print(text)
    reportStreamWritten = true
}

/// SPEC §3.3.1 ⟨0.28⟩ (2) — THE FAIL-CLOSED REPORT, as text. ONE builder for BOTH report sinks.
///
/// The ⟨0.21⟩ Row-1 manifest-carrying empty: `functions: []` + `analyzed.count: 0` + a non-empty
/// `unanalyzed`. Row 1 of the ⟨0.24⟩ table pins the reading — *nothing was judged*, not *nothing to
/// judge* — so a consumer needs no new logic to refuse a purity licence over it.
///
/// Extracted from `writeReportStreamFailClosed` when the `--out <prefix>` armer needed the same
/// document, and the inline copy is GONE (the `bffc868` rule: two copies of one shape is how the
/// stream form and the file form later disagree about what "no claim" looks like, and a consumer
/// keying on one of them then reads the other as a report). The `--out` armer additionally needs the
/// EXACT BYTES back, to tell "this run rewrote the file" from "this file is still holding the
/// placeholder" — which only works while there is a single builder.
func failClosedReportDocument(reason: String) -> String? {
    let doc: [String: Any] = [
        "candor": ["version": engineVersion, "toolchain": "swiftsyntax", "spec": specVersion] as [String: Any],
        "functions": [] as [Any],
        "analyzed": ["count": 0] as [String: Any],
        "unanalyzed": [["path": "<run>", "reason": reason] as [String: Any]] as [Any],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return nil }
    return text
}

/// ⟨0.28⟩ A CONFIGURED POLICY THAT YIELDED ZERO RULES IS A BROKEN GATE CONFIG (SPEC §6.2) — the refusal
/// text and the whole-policy `unevaluated` entry, for BOTH routes. Returns nil when the policy carries at
/// least one rule of any kind, i.e. when there is nothing to refuse.
///
/// The same refusal posture as the unreadable-policy and unhonourable-token branches each route already
/// has, for the reason §6.2 gives for an unreadable file: "a typo'd policy path that runs green is a gate
/// that silently passes everything". MEASURED four-way 2026-08-10: `--policy <a README>` wrote
/// `{"ok":true,"violations":[]}` and exited 0 on every engine — byte-identical to a gate that ran and
/// found nothing, AND byte-identical to the no-gate-configured verdict, so the one consumer this format
/// exists for cannot tell "your code is clean" from "your gate had no rules". The per-line "ignoring
/// policy rule" warnings go to stderr, which is not the machine channel.
///
/// The line-level leniency is UNTOUCHED and still right: an unrecognised line stays
/// ignored-with-a-warning, because silent reinterpretation is the one thing a security gate must not do,
/// and an engine meeting a rule kind from a newer rung must not refuse the file over it. This is about
/// what that leniency COMPOSES TO — every line ignored is a gate that asked nothing.
///
/// THE CONTROL, which is what makes this a rule and not a blanket: a caller only asks this question once a
/// policy has been CONFIGURED (`--policy`, CANDOR_POLICY, or the config `policy` key). A run that
/// configured no gate never reaches it and stays exit 0 — that is the honest way to say "I am not gating",
/// and it is precisely why a configured zero-rule policy is never a legitimate expression of that intent.
///
/// EVERY RULE VECTOR THE PARSER CAN PRODUCE, and the reference engine's first draft read only one of them
/// (candor-rust `960b879`): `ParsedPolicy` splits the four kinds across `deny` (which `pure` also appends
/// to), `allow` and `forbid`, so keying on `deny` alone would make an allow-only or forbid-only policy —
/// `allow Net api.stripe.com`, a perfectly ordinary allowlist gate — refuse as if it had no rules at all. A
/// zero-rule check that reads a SUBSET of the rule kinds is the same false-answer shape this rung exists to
/// close, pointed the other way.
///
/// ONE PREDICATE, TWO ROUTES. The scan CLI shipped this rung first (`5552a36`) with the check inline, and
/// `gate --report` — the SUPPLY-CHAIN surface, where a consumer points the gate at a report someone else
/// produced — kept exiting 0 over a README. SPEC §6.2 says the defect was measured on both and that "a
/// route is not covered by its sibling"; two copies of the emptiness test is how one of them later narrows
/// to `deny` alone without the other noticing, so there is exactly one and both routes call it.
func zeroRulePolicyRefusal(_ pol: ParsedPolicy, at path: String,
                           who: String) -> (why: String, unevaluated: [Unevaluated])? {
    // ⟨0.29⟩ …and `only`. This function's own doc comment says a zero-rule check reading a SUBSET of the
    // rule kinds is the false-answer shape the rung exists to close — so the kind added by a later rung
    // has to arrive here, or an `only`-only policy (a LIVE gate) is refused as an empty file.
    guard pol.deny.isEmpty, pol.allow.isEmpty, pol.forbid.isEmpty, pol.only.isEmpty else { return nil }
    let why = "\(who): the policy \(path) yielded NO RULES — refusing (exit 2, gate NOT enforced). "
        + "Every line was ignored (see the `ignoring policy rule` warnings above), the file is empty, "
        + "or it holds only comments. A gate with no rules cannot have caught anything, and reporting "
        + "`ok: true` here would be indistinguishable from a gate that ran and found nothing. If you "
        + "did not mean to gate this run, remove the `policy` setting rather than pointing it at a file "
        + "with no rules in it."
    // SPEC §3.1 — the whole-policy entry, the shape pinned for a policy with no lines to NAME (there are
    // no honoured rules to list, and listing the ignored lines would imply they were rules).
    return (why, [Unevaluated(rule: "(entire policy \(path) — no rules parsed)",
                              why: "the configured policy yielded zero rules, so nothing was evaluated "
                                 + "and no rule can have passed")])
}

/// Print the reason, write the refusal document to every requested sink, exit 2.
/// ⟨0.24⟩ `unevaluated` travels with it when the refusal IS a set of undecidable rules (SPEC §3.1) — the
/// machine channel for the same disclosure the `reason` string carries for the human.
// ⟨0.32⟩ THE REFUSAL MARKER — SPEC §3.3.1 ⟨0.32⟩.
//
// A run given no `--out` still writes reports, to its default prefix, and a refusal leaves whatever the
// last successful run put there readable as current. MEASURED in this engine: scan green, add a denied
// effect, refuse with an unknown flag, and `candor-swift gate --report .` answers exit 0 over the
// previous run's bytes.
//
// Arming that prefix is NOT the answer, and the comment at this engine's own armer says why — the first
// version of it overwrote a `.candor/report.<pkg>.Swift.json` with a placeholder, and committed reports
// are a pattern this project recommends. Naming a prefix is a declaration; a default is a convention.
//
// So the refusal is recorded BESIDE the reports and overwrites nothing. Because it destroys nothing it
// is written at the EARLIEST moment the prefix is known — during argument parsing — which is what lets
// it cover the argv-death case arming structurally cannot reach.
// `nonisolated(unsafe)`, matching `gateVerdictSinks` above and for the same stated reason: this is a
// single-threaded CLI process and each value is written once, during argument parsing, before anything
// reads it.
nonisolated(unsafe) var refusalPrefix: String? = nil
nonisolated(unsafe) var refusalTarget: String? = nil

func noteRefusalPrefix(_ p: String) { if refusalPrefix == nil { refusalPrefix = p } }
func noteRefusalTarget(_ t: String) { if refusalTarget == nil { refusalTarget = t } }

func writeRefusalMarker(_ why: String) {
    guard let pfx = refusalPrefix else { return }
    let doc: [String: Any] = [
        "candor": ["spec": specVersion],
        "refused": true,
        "prefix": pfx,
        "target": refusalTarget ?? ".",
        // The marker carries its own `prefix` because §3.3.1's DIRECT-FILE locator accepts any `.json`
        // name whatever its dot-segments: a consumer handed one file cannot recover the prefix from the
        // filename and reads it out of the marker instead.
        "reason": why,
    ]
    let dir = (pfx as NSString).deletingLastPathComponent
    if !dir.isEmpty {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
        // A marker that cannot be written fails OPEN — the status quo, never worse than before the rung.
        try? data.write(to: URL(fileURLWithPath: pfx + ".refused.json"))
    }
}

/// ⟨0.32⟩ …and a run that COMPLETES its write phase removes it, so the marker's presence means exactly
/// "the most recent attempt over this prefix refused". A marker left behind makes every later gate refuse
/// for ever — the permanent-red mirror of the permanent-green this closes.
func clearRefusalMarker(_ resolved: String? = nil) {
    for pfx in [refusalPrefix, resolved].compactMap({ $0 }) {
        try? FileManager.default.removeItem(atPath: pfx + ".refused.json")
    }
}

func refuseGateAndExit(_ reason: String, unevaluated: [Unevaluated] = []) -> Never {
    writeRefusalMarker(reason)   // ⟨0.32⟩ over the RUN, not over the fourteen call sites
    FileHandle.standardError.write((reason + "\n").data(using: .utf8)!)
    // DEDUPE AT THE WRITE, not at each append. Two code paths register the stream sink — the gate verb's
    // pre-pass (so a refusal during ARGUMENT PARSING still reaches stdout) and the flag loop that learns
    // `--gate-json` normally — and with both, one exit-2 wrote the refusal document TWICE onto one
    // stream. §3.1/§4's "one input means one document" is what a machine consumer parses against; two
    // concatenated objects are not a document at all.
    //
    // Introduced by the fix that added the pre-pass registration, and caught by the second go/no-go
    // panel rather than by any test. Deduping here covers every appender, present and future, which is
    // the reason it is here and not in the two call sites that happen to exist today.
    var written = Set<String>()
    for t in gateVerdictSinks where written.insert(t).inserted {
        writeGateRefusal(reason, to: t, spec: specVersion, unevaluated: unevaluated)
    }
    // ⟨0.28⟩ REPORT STREAM: the same rule the verdict stream gets, one hop upstream. If `--json`
    // (report to stdout) was requested and stdout is not already claimed by `--gate-json -` (that
    // two-stream case is refused earlier and its refusal document IS the one document on stdout),
    // write the ⟨0.21⟩ Row-1 fail-closed report as stdout's only content. Without this, an
    // unknown-flag exit-2 left stdout EMPTY — the report-sink analog of the defect ⟨0.27⟩ closed for
    // the verdict sink.
    writeReportStreamFailClosed(reasonKey: "refused", why: reason)
    exit(2)
}

func writeGateRefusal(_ reason: String, to path: String, spec: String, unevaluated: [Unevaluated] = []) {
    var dict: [String: Any] = ["spec": spec, "ok": false, "refused": true, "reason": reason]
    if !unevaluated.isEmpty { dict["unevaluated"] = unevaluatedJson(unevaluated) }
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write("candor-swift: could not serialize the refusal document\n".data(using: .utf8)!)
        return
    }
    if path == "-" { print(text); return }
    do {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        FileHandle.standardError.write(
            ("candor-swift: could not write the refusal document to --gate-json \(path): "
             + "\(error.localizedDescription) — a consumer reading that path will see the PREVIOUS run's "
             + "verdict, which is stale. Delete it, or treat exit 2 as a failure.\n").data(using: .utf8)!)
    }
}

/// ⟨0.24⟩ THE GATE'S INPUT — the seam between "what produced the signature" and "what §6.2 does with it".
/// Every field is ALREADY ACCUMULATED (transitive): the gate runs no fixpoint and reads no scan state, so
/// the same matching code serves both routes in.
///
/// `gateInputFromScan` builds it from the classifier's live maps (the reason-class fixpoint and the
/// per-fn `netClassesOf` derivation that used to sit inline in the gate); `gateInputFromReport`
/// (GateReportCLI.swift) builds it from a WRITTEN report and nothing else. That split is the point of
/// SPEC §3.1 ⟨0.24⟩: until it existed the gate was reachable only THROUGH the classifier, so a defect in
/// the gate and a defect in the classifier were indistinguishable from any test this repo could write.
/// Do NOT re-implement the §6.2 matching on the report side — the clause exists about exactly that
/// mistake (an open-coded second copy of a classification rule drifting from the gate's, silently,
/// because nothing compared them).
struct GateInput {
    /// per fn, the TRANSITIVE effect set — the model's `S`, with candor's `Unknown` marker carried as a
    /// member (this family's encoding of `D ≠ ∅`).
    let inferred: [String: Set<String>]
    /// per fn, the TRANSITIVE reason-class tokens — the model's `D` (SPEC §6.2 ⟨0.19⟩).
    let reasonClasses: [String: Set<String>]
    /// per Net-bearing fn, its ⟨0.20⟩ destination classes, ALREADY derived (scan: `netClassesOf`;
    /// report: the wire's `netClass`, verbatim).
    let netClasses: [String: [String]]
    /// per fn, the TRANSITIVE literal surface AS-EFF-008 certifies.
    let hosts: [String: Set<String>], cmds: [String: Set<String>]
    let paths: [String: Set<String>], tables: [String: Set<String>]
    /// per fn, the effects whose literal surface is structurally incomplete — the AS-EFF-008 fail-closed
    /// marker. It does NOT ride the ⟨0.24⟩ wire, which is why `gate --report` refuses every `allow` rule.
    let surfaceIncomplete: [String: Set<String>]
    /// the call graph AS-EFF-009 walks.
    let edges: [String: [String]]
    /// ⟨0.32⟩ KEY → the function's NAME. Every map above is keyed by the report's `hash` when it carries
    /// one (SPEC §2.2: join by `hash`, never by bare `fn`), and a hash matches no policy scope and reads
    /// as nothing in a message — so a rule keyed against the raw key would bind NOTHING and pass, which
    /// is the silent direction. EMPTY on the scan route, where the key IS the name: `nameOf` falls back
    /// to the key, so that route is byte-identically unchanged.
    var display: [String: String] = [:]
}

/// The SCAN route into the gate: the classifier's live maps, plus the two derivations the gate used to
/// run inline. Behaviour-preserving — `netClassesOf` was only ever asked for a fn that HAS `Net` (it is
/// the `deny` membership that triggers it), so materializing exactly those is the same set of answers.
func gateInputFromScan(inferred: [String: Set<String>],
                       whyMap: [String: Set<String>],
                       direct: [String: Set<String>],
                       edges: [String: Set<String>], cg: [String: [String]],
                       hostsAcc: [String: Set<String>], cmdsAcc: [String: Set<String>],
                       pathsAcc: [String: Set<String>], tablesAcc: [String: Set<String>],
                       incompleteAcc: [String: Set<String>],
                       netPartners: Set<String>) -> GateInput {
    // Reason-scoped Unknown (REASON-SCOPED-UNKNOWN-DESIGN.md): the Unknown reason CLASS must travel the
    // call graph the same way the Unknown EFFECT does (whyMap is direct-only). Classify each fn's direct
    // reasons to class tokens, then propagate transitively — so `deny E Unknown[reflect]` at a caller
    // inheriting Unknown from a reflect-caused callee still fires (matches java/rust/ts reasonClassAcc).
    var reasonClassDirect: [String: Set<String>] = [:]
    for (fn, whys) in whyMap where !whys.isEmpty {
        reasonClassDirect[fn] = Set(whys.map { reasonClass($0) })
    }
    // ⟨0.24⟩ §6.2's CONTRIBUTION, applied HERE rather than in the matcher (SPEC §3.1, candor-spec
    // `5a8cf48`). A function that raises `Unknown` DIRECTLY and names no reason for it contributes
    // `unresolved` — at the ENTRY, BEFORE the fixpoint, which is what makes it COMPOSE and is exactly what
    // `gateInputFromReport` does on the other route. The floor used to live in `evaluateGate` instead
    // (`fnClasses = classes.isEmpty ? ["unresolved"] : …`), and that is the wrong place for it: a
    // fail-closed default is not portable between a predicate that GUARDS and one that CHARGES. As a
    // guard it made the matcher conservative; as grounds to EMIT a violation it asserted a reason nobody
    // recorded. Same shape as `netClassesOf` below, which has always floored at `unknown-host` in the
    // INPUT rather than in the match.
    //
    // Gated on a DIRECT `Unknown` the function did not name, never on the reason set being empty:
    // emptiness is also what an INHERITED `Unknown` looks like, and marking those is the mirror
    // fabrication. On this route the guard is belt-and-braces — over 14 real targets / 12 004 entries,
    // 0 carry a direct `Unknown` without an `unknownWhy` (§4's invariant, pinned by
    // UnknownMarkerInvariantProcessTests) — but it is what lets the matcher stop flooring at all.
    for (fn, d) in direct where d.contains("Unknown") && (whyMap[fn]?.isEmpty ?? true) {
        reasonClassDirect[fn, default: []].insert("unresolved")
    }
    var netClasses: [String: [String]] = [:]
    for (qual, inf) in inferred where inf.contains("Net") {
        netClasses[qual] = netClassesOf(Array(hostsAcc[qual] ?? []),
                                        netIncomplete: incompleteAcc[qual]?.contains("Net") ?? false,
                                        partners: netPartners)
    }
    return GateInput(inferred: inferred,
                     reasonClasses: propagate(reasonClassDirect, over: edges),
                     netClasses: netClasses,
                     hosts: hostsAcc, cmds: cmdsAcc, paths: pathsAcc, tables: tablesAcc,
                     surfaceIncomplete: incompleteAcc, edges: cg)
}

/// Evaluate a parsed §6.2 policy against an ALREADY-ACCUMULATED signature — the SAME violation list
/// drives the console lines, --gate-json and the exit code, so they can never disagree. THE ONLY §6.2
/// matching code in this engine: `scan --policy` and `gate --report` both land here, which makes "the
/// same verdict from the same signature" a property of the code rather than of two consistent authors.
/// Returns the violations AND the rules whose scope bound no function. The second is a DISCLOSURE
/// beside the verdict, not a new verdict field — the verdict shape is spec-pinned.
func evaluateGate(_ pol: ParsedPolicy, _ gi: GateInput) -> (violations: [GateViolation], zeroMatch: [String]) {
    let inferred = gi.inferred
    let hostsAcc = gi.hosts, cmdsAcc = gi.cmds, pathsAcc = gi.paths, tablesAcc = gi.tables
    let incompleteAcc = gi.surfaceIncomplete, cg = gi.edges, reasonClassAcc = gi.reasonClasses
    // ⟨0.32⟩ THE KEY IS NOT THE NAME on the report route. Every accumulator above is keyed by the §2.2
    // join key (`hash` when the report carries one); a POLICY SCOPE and every human-readable message are
    // about the NAME. Matching a scope against a raw key does not error — it simply matches nothing, so
    // the rule binds nothing and the gate goes green: the silent direction, and the reason this is a
    // helper used at EVERY name-consuming site rather than a substitution at the few that looked wrong.
    // The scan route leaves `display` empty and the key IS the name, so it is the identity there.
    func nameOf(_ k: String) -> String { gi.display[k] ?? k }
    var gateViolations: [GateViolation] = []
        // ZERO-MATCH DISCLOSURE. A rule whose SCOPE binds no function is scored as satisfied — so a
        // one-character typo in a layer name (`deny Net ordrs`) turns a failing gate green and
        // `unverified` then calls the layer "PROVABLY clean". The asymmetry is the tell: a typo'd EFFECT
        // token exits 2 naming the accepted vocabulary, a typo'd LAYER token binds nothing and passes.
        //
        // The fix is DISCLOSURE, not refusal, and ⟨0.24⟩ §3.1 already rules it: an unanswerable condition
        // must be disclosed, never scored as a satisfied one. Refusal would be wrong because a zero-match
        // rule is LEGITIMATE when one policy is shared across repos and a layer exists in only some.
        var scopeMatchCount: [String: Int] = [:]
        for r in pol.deny where !r.scope.isEmpty { scopeMatchCount[r.raw] = 0 }
        for r in pol.forbid { scopeMatchCount[r.raw] = 0 }
        for r in pol.only { scopeMatchCount[r.raw] = 0 }
        for qual in inferred.keys {
            for r in pol.deny where !r.scope.isEmpty && scopeMatches(nameOf(qual), r.scope) {
                scopeMatchCount[r.raw, default: 0] += 1
            }
            for r in pol.forbid where scopeMatches(nameOf(qual), r.from) || scopeMatches(nameOf(qual), r.to) {
                scopeMatchCount[r.raw, default: 0] += 1
            }
            // ⟨0.29⟩ ON `from` ONLY, deliberately not either endpoint the way a `forbid` counts. A
            // forbid's subject is the pair; an `only`'s subject is the scope it makes a PROMISE about, so
            // a rule whose destinations all resolve while its `from` names nothing has bound nothing —
            // exactly the typo that leaves an operator believing a leaf is protected.
            for r in pol.only where scopeMatches(nameOf(qual), r.from) {
                scopeMatchCount[r.raw, default: 0] += 1
            }
        }
        // ⟨0.27⟩ CODE-POINT order, explicitly (the `zeroMatch` verdict key pins the `viaDispatchOn`
        // collation, SPEC §4). Swift's default String `<` orders by Unicode canonical comparison, which
        // agrees with code-point order on ASCII and can disagree off it — and the raw line is built from
        // user identifiers. UTF-8 byte order IS code-point order, and unlike Java/JS a Swift String
        // cannot hold a lone surrogate, so comparing the UTF-8 views is not lossy here.
        let zeroMatch = scopeMatchCount.filter { $0.value == 0 }.keys
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        // …stashed module-wide so `writeGateVerdict` can carry the same list on the verdict document
        // (SPEC §4 `zeroMatch`) without threading a parameter through every caller — the same shape as
        // `gateVerdictSinks`, and safe for the same reason (a single-threaded one-shot CLI: written by
        // the one gate evaluation a run performs, read on the way out).
        lastGateZeroMatch = zeroMatch

        for qual in inferred.keys.sorted() {
            let inf = inferred[qual] ?? []
            if inf.isEmpty { continue }
            for r in pol.deny where scopeMatches(nameOf(qual), r.scope) {
                // `pure` (empty forbidden set) forbids every EFFECT — not `Unknown`, the §4 trust
                // marker (AS-EFF-003's concern; `deny Unknown <scope>` is the explicit knob). The
                // reference engine, the rust engines and candor-ts exclude it identically; this
                // engine wrongly counted an Unknown-only fn as a `pure` violation until 2026-07-09.
                var hits = r.effects.isEmpty ? inf.sorted().filter { $0 != "Unknown" }
                                             : inf.sorted().filter { r.effects.contains($0) }
                // Reason-scoped Unknown: a `deny E Unknown[classes]` keeps its Unknown hit only for a fn
                // whose TRANSITIVE reason classes include one of those.
                //
                // ⟨0.24⟩ **NO FLOOR HERE — THE MATCHER MUST NOT CHARGE ON A DEFAULT** (SPEC §3.1,
                // candor-spec `5a8cf48`). This line used to read
                // `reasonClassAcc[qual].map { $0.isEmpty ? ["unresolved"] : … } ?? ["unresolved"]`, and
                // while the answerability refusal SHORT-CIRCUITED before the gate ran, the floor was
                // unreachable on the one route where an empty set is possible. Removing that
                // short-circuit (the precedence fix) made it reachable, and MEASURED it FABRICATED: a
                // scoped `deny Unknown[unresolved]` over an entry whose `Unknown` is INHERITED and
                // reasonless emitted an actual violation RECORD naming that function — in the same run
                // whose stderr said the rule could not be evaluated over it. A self-contradicting
                // document, and a soundness fix was what made it reachable.
                //
                // A fail-closed default is not portable between a predicate that GUARDS and one that
                // CHARGES. The `unresolved` default is still applied — at the ENTRY, in
                // `gateInputFromScan` / `gateInputFromReport`, gated on a DIRECT `Unknown` the function
                // did not name — where it composes and where it is evidenced. An EMPTY set here means the
                // match is not evidenced by this function's own entry, so the rule is WITHHELD on this
                // (rule, function) pair and disclosed by the caller. Withholding is per (rule, function),
                // never whole-policy: the same rule may fire on one function and be withheld on another.
                if hits.contains("Unknown"), !r.unknownClasses.isEmpty {
                    let fnClasses = reasonClassAcc[qual] ?? []
                    if !fnClasses.contains(where: { r.unknownClasses.contains($0) }) {
                        hits.removeAll { $0 == "Unknown" }
                    }
                }
                // Net destination-class: a `deny Net[dest…]` keeps its Net hit only for a fn reaching one of
                // those destination classes; else tolerate (only asserted-safe destinations). Fail-closed: a
                // masked surface / a Net with no visible host is unknown-host. ⟨0.24⟩ the class set is
                // ALREADY DERIVED in `gi.netClasses` — from the transitive hostsAcc + incompleteAcc on the
                // scan route, and read verbatim off the wire's `netClass` on the `gate --report` route.
                // An EMPTY set here cannot mean "no destinations": `netClassesOf` floors at unknown-host, and
                // the report route refuses a scoped rule over an entry whose field is absent (GateReportCLI).
                if hits.contains("Net"), !r.netClasses.isEmpty {
                    let fnNet = gi.netClasses[qual] ?? []
                    if !fnNet.contains(where: { r.netClasses.contains($0) }) {
                        hits.removeAll { $0 == "Net" }
                    }
                }
                if !hits.isEmpty {
                    // When Unknown is denied, report ALL reason classes on the fn (transitive) — every reason bit.
                    let rc = hits.contains("Unknown") ? (reasonClassAcc[qual].map { $0.sorted() } ?? []) : []
                    // ⟨0.20⟩ when Net is denied, report ALL of the fn's destination classes (transitive).
                    let nc = hits.contains("Net") ? (gi.netClasses[qual] ?? []) : []
                    gateViolations.append((rule: "AS-EFF-006", fn: nameOf(qual), effects: hits,
                        detail: "`\(nameOf(qual))` performs { \(hits.joined(separator: ", ")) }, forbidden by policy: `\(r.raw)`",
                        reasonClass: rc, netClass: nc))
                }
            }
            for r in pol.allow where scopeMatches(nameOf(qual), r.scope) && inf.contains(r.effect) {
                let surface: Set<String>
                switch r.effect {
                // `Llm` ⟨0.13⟩ rides Net's host literal (SPEC §1) — `allow Llm <host…>` restricts which MODEL
                // hosts a scope may reach, matched by hostname like Net. The reached surface is the SAME
                // captured Net hosts (a model host WAS captured as a Net host literal).
                case "Net", "Llm": surface = hostsAcc[qual] ?? []
                case "Exec": surface = cmdsAcc[qual] ?? []
                case "Db": surface = tablesAcc[qual] ?? []
                default: surface = pathsAcc[qual] ?? []
                }
                // An INCOMPLETE surface — a host-establishing Net call with a structurally-invisible host —
                // can't be certified even when visible hosts cover the allowlist, else the benign literal MASKS
                // the invisible forbidden endpoint (the masking gate-evasion; candor-java 0.5.29 / rust / ts).
                // `Llm`'s incompleteness keys off "Net" (its surface IS the Net host surface): a runtime/masked
                // host marks Net incomplete → `allow Llm` fails closed too, so a benign visible model host can't
                // mask a runtime model host (candor-java's `incompleteAsLlm`; parity decision #3).
                let incompleteKey = r.effect == "Llm" ? "Net" : r.effect
                let surfaceIncomplete = incompleteAcc[qual]?.contains(incompleteKey) ?? false
                if surface.isEmpty || surfaceIncomplete {
                    // Two distinct failures share AS-EFF-008: no literal AT ALL, vs the MASKING case where a
                    // visible literal exists but coexists with a structurally-invisible endpoint it can't cover for.
                    let why = surface.isEmpty
                        ? "performs \(r.effect) with no visible literal — the surface cannot be certified"
                        : "reaches a structurally-invisible \(r.effect) endpoint a visible literal cannot mask"
                    gateViolations.append((rule: "AS-EFF-008", fn: nameOf(qual), effects: [r.effect], detail: "`\(nameOf(qual))` \(why): `\(r.raw)`", reasonClass: [], netClass: []))
                } else {
                    let bad = surface.filter { !literalAllowed(r.effect, $0, r.values) }.sorted()
                    if !bad.isEmpty {
                        gateViolations.append((rule: "AS-EFF-008", fn: nameOf(qual), effects: [r.effect],
                            detail: "`\(nameOf(qual))` reaches { \(bad.joined(separator: ", ")) } outside the allowlist: `\(r.raw)`", reasonClass: [], netClass: []))
                    }
                }
            }
        }
        for r in pol.forbid {
            for fn in cg.keys.sorted() where scopeMatches(nameOf(fn), r.from) {
                var seen: Set<String> = [fn], stack = cg[fn] ?? []
                while let cur = stack.popLast() {
                    if !seen.insert(cur).inserted { continue }
                    if scopeMatches(nameOf(cur), r.to) {
                        gateViolations.append((rule: "AS-EFF-009", fn: nameOf(fn), effects: [],
                            detail: "`\(nameOf(fn))` (scope `\(r.from)`) transitively reaches `\(nameOf(cur))` in forbidden scope `\(r.to)`: `\(r.raw)`",
                            reasonClass: [], netClass: []))
                        break
                    }
                    stack.append(contentsOf: cg[cur] ?? [])
                }
            }
        }
        // ⟨0.29⟩ AS-EFF-011 — `only A -> B …`: a fn in A may reach A and the listed scopes, NOTHING else.
        // The same walk as `forbid` above with the test INVERTED, and the inversion is the point rather
        // than the code: `forbid` fails OPEN, so a leaf can only be protected by enumerating what it must
        // not reach — a list that does not cover a package added tomorrow. `only` fails SAFE.
        //
        // THE WALK STOPS AT A PERMITTED SCOPE. A permitted callee's own dependencies are governed by the
        // rules about IT; descending past it would make `only` demand the transitive closure of everything
        // you permit, which is the same enumeration-that-rots one level down. `from` IS descended through.
        for r in pol.only {
            for fn in cg.keys.sorted() where scopeMatches(nameOf(fn), r.from) {
                var seen: Set<String> = [fn], stack = cg[fn] ?? []
                while let cur = stack.popLast() {
                    if !seen.insert(cur).inserted { continue }
                    // ⟨0.29⟩ EXACT segment match — the shared prefix matcher is fail-OPEN here.
                    if r.to.contains(where: { scopeMatchesPermitted(nameOf(cur), $0) }) { continue }
                    if !scopeMatches(nameOf(cur), r.from) {
                        // ⟨0.29⟩ ITS OWN CODE, not `forbid`'s — a rule code is what a CI suppression
                        // keys on, and these two are opposite constructs. Sharing 009 would make an
                        // existing `forbid` suppression silently mute `only` violations nobody accepted.
                        gateViolations.append((rule: "AS-EFF-011", fn: nameOf(fn), effects: [],
                            detail: "`\(nameOf(fn))` reaches `\(nameOf(cur))`, which this permission rule does not permit: `\(r.raw)`",
                            reasonClass: [], netClass: []))
                        break
                    }
                    stack.append(contentsOf: cg[cur] ?? [])
                }
            }
        }
    return (gateViolations, zeroMatch)
}
