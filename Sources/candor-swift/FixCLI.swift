import CandorCore
import Foundation

// The `fix` / `fix-gate` subcommands (integrations/FIX-SPEC.md). candor-swift is scan-first, but these are a
// read-only query over what a scan already wrote — they load the §2 report + its §2.2 callgraph sidecar from
// a prefix and compute the boundary remedy (the pure algorithm lives in CandorCore/Fix.swift). JSON output,
// like the rest of candor-swift's machine surface; a policy is required (the fix is defined relative to the
// boundary it crosses), fail-loud (exit 2) on an unreadable/absent policy or a missing report — never a
// silently-empty answer.

private func fixDie(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

private func emitJSON(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: data, encoding: .utf8) else {
        fixDie("candor-swift: could not serialize the fix result")
    }
    print(s)
}

// ⟨0.15 staged⟩ The report's coverage disclosure, as loaded (SPEC §2): the envelope `coverage`
// ledger's module names (merged across sibling reports) + the union of per-function `invisible`
// lists. A report-consuming verb whose verdict could change under uncovered reach (privacy-manifest
// --verify) re-discloses this — verdict-preserving. `invisible` is folded in so a pre-⟨0.15⟩ or
// foreign report (loaded directly by path, no envelope ledger) still conditions the verdict when
// its functions carry the per-fn attribution.
struct ReportCoverage {
    var envelopeModules: Set<String> = []    // envelope `coverage.uncovered[].name`
    var invisibleModules: Set<String> = []   // union of per-fn `invisible`
    var modules: [String] { envelopeModules.union(invisibleModules).sorted() }
    var isEmpty: Bool { envelopeModules.isEmpty && invisibleModules.isEmpty }
}

// ⟨0.24⟩ THE REPORT'S OWN ⟨0.21⟩ COMPLETENESS MANIFEST, as the ADVISORY verbs must read it.
//
// The gate has honoured this since ⟨0.21⟩ — `ok` requires no violation AND a complete analysis, and an
// incomplete-but-clean report exits 2. NOTHING ELSE DID. Measured on this engine, one report declaring
// one `unanalyzed` unit:
//
//     gate --report R --policy P            exit 2   ok:false  incomplete:true  + the manifest
//     unverified --report R --policy P      exit 0   ok:TRUE   (--strict: still 0)
//     fix-gate   --report R --policy P      exit 0   ok:TRUE   (--strict: still 0)
//
// Two of the three are gates when `--strict` is passed, which is how they are used in CI. So the rule the
// gate route has enforced for three rungs was absent from every OTHER surface that answers `ok`, and a
// pipeline that ran `unverified --strict` over a partially-parsed tree got a green.
//
// SPEC §3.2 ⟨0.24⟩ (candor-spec `0075987`) supplies the shape, and it is `whatif`'s, not the gate's:
// **`ok` is OMITTED.** These verbs are ADVISORY by default — they exit 0 whether or not they found
// something — so their `ok:false` does not mean "this did not pass", it means "a hole/crossing EXISTS,
// here it is". Answering `false` beside an EMPTY `unverified`/`remedies` array would assert a finding
// the analysis never made, which is the fabrication mirror and worse than the over-claim it replaces.
// `ok:true` over a knowingly partial universe is the over-claim. Neither is honest, so neither ships:
// `incomplete: true` plus the manifest take the field's place, a consumer writing `if (r.ok)` gets
// undefined and fails safe, and the arrays still ship because a partial answer that says it is partial
// beats a refusal.
//
// The gate keeps `ok:false` and is NOT changed to match: there `false` is TRUE — the gate did not
// certify. A shape is copied for its reasoning, not its familiarity.
//
// ⟨0.28⟩ **AND "THE ADVISORY VERBS" WAS ITSELF THE SCOPING MISTAKE.** The header above says this is read
// for the verbs that answer `ok`, and the DESCRIPTIVE verbs — the ones that answer a QUESTION rather than
// render a verdict — were never given it. SPEC §2 ⟨0.28⟩ corrects the clause to the condition that always
// justified it: the obligation binds *"any verb whose output could be read as a NEGATIVE FINDING about the
// code — a verdict, an empty result set, or a zero count"*. An empty result set is exactly what these
// verbs produce. MEASURED on this engine over a report declaring `analyzed.count: 0` and a non-empty
// `unanalyzed` — the standard post-failure artifact since the ⟨0.28⟩ arming rung, i.e. what is on disk
// after a failed run:
//
//     tour 3 --json   {"reaches":[]}                                     exit 0, no hedge
//     tour 3          candor: nothing hidden — every effect sits …       exit 0, no hedge
//
// "nothing hidden" is the single most reassuring sentence this binary prints, and there it is printed out
// of a report whose own manifest names a file it could not read. A consumer cannot tell *nothing is
// hidden* from *nothing was examined*. Same struct, same two channels, same no-op-when-complete rule —
// `mustHedge` is the trigger a descriptive verb asks, `isIncomplete` stays the one an EXIT CODE asks.
//
// ⟨0.28⟩ **AND `analyzed.count: 0` IS THE SECOND CAUSE, WHICH THIS STRUCT DID NOT READ AT ALL.** SPEC §2:
// *"a report-consuming verb MUST re-disclose a non-empty `unanalyzed`, **and an `analyzed.count` of 0**,
// on the same terms."* A report that judged nothing carries no `unanalyzed` — there is no unread FILE to
// name, the scan simply reached no conclusion — so the manifest reader saw a COMPLETE report and the
// verbs answered over it just the same. `judgedNothing` is that arm, decided by the SHARED
// `claimsToHaveJudgedNothing` predicate the chained dep-join and `gate --report` already use, so a report
// cannot be judged-nothing on one route and not the other.
struct ReportCompleteness {
    var unanalyzed: [(path: String, reason: String)] = []
    /// ⟨0.28⟩ The report FILES under this locator that say they judged nothing — SPEC §2's
    /// `analyzed.count == 0` row. A THIRD CAUSE, not a third spelling of the first: `unanalyzed` names
    /// source the scan could not READ, this is a scan that read whatever it read and reached no
    /// conclusion about any of it. Only the union of the two covers both the post-failure artifact
    /// (which carries both) and the facade/re-export report (which carries only this).
    var judgedNothing: [String] = []
    /// ⟨0.28⟩ SPEC §2 — **THE THIRD ROW IS NOT THE FIRST ROW.** The report FILES under this locator
    /// carrying NO `analyzed` key at all — §2's row 3, a pre-⟨0.21⟩ producer.
    ///
    /// MEASURED on this engine over `{"candor":…,"functions":[]}` with no `analyzed` key: `tour`,
    /// `unverified`, `fix`, `fix-gate`, `privacy-manifest` and `gains` all listed the file under
    /// `judgedNothing`, and the note said it *"say[s] they JUDGED NOTHING (`analyzed.count: 0`)"*. **The
    /// report declares nothing.** The HEDGE is the right direction — row 3's own instruction is *no
    /// manifest, no claim* — but the disclosure is FALSE, and this family rates a false disclosure worse
    /// than a missing one (§3.4's `net-partner` finding: an engine reported "ignoring unknown config
    /// key" *while honouring it*).
    ///
    /// A SEPARATE FIELD, NOT A RE-LABEL: ⟨0.28⟩ pins `judgedNothing` to *"reports declaring
    /// `analyzed.count: 0`"*, so putting row 3 there makes one key mean two things and loses the
    /// distinction the table exists to draw. The REPAIRS differ too — row 1 wants a scan that reaches a
    /// conclusion, row 3 wants a producer that emits a manifest at all. It raises `mustHedge` exactly as
    /// `judgedNothing` does and, like it, stops at the exit code: `isIncomplete` does not read it.
    var noManifest: [String] = []
    /// ⟨0.28⟩ The report FILES under this locator that could not be read AS reports at all — the
    /// `unreadable` arm the Rust reference has carried since ⟨0.24⟩ and this struct did not, a
    /// difference every caller inherited. Until this arm existed, a corrupt sibling was named once on
    /// stderr as OMITTED and the answer then read CLEAN over the survivors: measured, `unverified
    /// --json` over one good and one truncated sibling answered `{"ok": true, "unverified": []}` while
    /// rust, java and ts each hedge the same bytes (`unreadable` arm / `bad` list / a parse throw
    /// counted as judged-nothing). A file the gate hard-fails over cannot read as clean here — that is
    /// the §3.2 at-least-as-pessimistic-as-the-gate relation, and it is why this arm feeds
    /// `isIncomplete` (the EXIT predicate) and not only `mustHedge`. No JSON key of its own: the
    /// disclosure key set is the pinned cross-engine wire surface and the reference raises only
    /// `incomplete: true` for this cause — the file is named in the prose note and on stderr.
    var unreadable: [String] = []

    /// ⟨0.30⟩ the peek's findings across the reports under this locator — see `isIncomplete`.
    var outOfScope: [[String: Any]] = []

    /// ⟨0.32⟩ the exclusion CLASSES the producing scan never opened (`excluded[].peeked == false` with no
    /// `judgedElsewhere`) — the sibling of `outOfScope` and the other half of one rung.
    ///
    /// **COLLECTED HERE, ARMED BY THE CALLER *FOR THE EXIT CODE ONLY***, because the condition is the
    /// policy in force NOW — only a `deny`/`pure` rule's answer depends on code outside the scan's scope
    /// — and this loader holds no policy. So `isIncomplete` reads `unreadArmed`, never this list
    /// directly: an unread class rides almost every no-policy report, and a `--strict` verb exiting 2 on
    /// every one of them would be MORE pessimistic than the gate, which ⟨0.24⟩ forbids in the same
    /// breath as the under-claim.
    ///
    /// ⟨0.32⟩ **THE *DISCLOSURE* READS THIS LIST DIRECTLY — see `mustHedge`, which carries the ruling.**
    /// This comment used to end *"`tour` and `path` NEVER ARM IT … they take no `--policy`, so there is
    /// no question whose answer could depend on the unread code"*, and that was overturned four-way on
    /// 2026-08-24.
    var unread: [String] = []
    /// ⟨0.32⟩ Has the calling verb decided that THIS run's policy makes `unread` matter? Held apart from
    /// `unread` being non-empty so that "no policy was given" and "this policy denies nothing" cannot be
    /// confused with "the producer read everything".
    var unreadArmed = false

    /// ⟨0.33⟩ RAW, per REPORT FILE that peeked something (an `excluded` entry with `peeked: true` and no
    /// `judgedElsewhere`) — the deny set THAT FILE's producer held, or the empty set when it peeked but
    /// carries no `scannedUnder` at all (a pre-⟨0.33⟩ producer). NEVER unioned across files: `scannedUnder`
    /// is a fact about ONE producing scan (SPEC §2 ⟨0.33⟩), so this is a LIST of per-file sets, not one set
    /// — the same reason `outOfScope`/`unread` are collected per entry rather than folded into one flag.
    ///
    /// COLLECTED HERE, ARMED BY THE CALLER FOR THE EXIT CODE ONLY, exactly as `unread`/`unreadArmed` are:
    /// the condition is the policy in force NOW, and this loader holds no policy.
    ///
    /// ⟨0.34⟩ …and that file's own declared `candor.spec` (verbatim, `""` for a pre-spec-field producer),
    /// carried BESIDE the deny set it qualifies rather than re-read later once `armingUnread` knows which
    /// rules are missing — the same reason the deny set itself is captured here instead of re-parsing the
    /// report a second time.
    var scannedUnderOfPeeked: [(deny: Set<String>, spec: String)] = []
    /// ⟨0.33⟩ THE ARMED ANSWER — this run's own deny rules that some `scannedUnderOfPeeked` entry does not
    /// cover (`CandorCore.unaskedCrossPolicyRules`), set by `armingUnread` once the run's policy is known.
    /// An ARM of `isIncomplete`, not merely a disclosure: ⟨0.24⟩ binds every verb that answers `ok` to be
    /// at least as pessimistic as the gate over the same bytes, and `gate --report` refuses on this
    /// exact condition (GateReportCLI.swift). Closing a cause on the gate and leaving its advisory
    /// siblings certifying is the ⟨0.32⟩/⟨0.30⟩ shape repeating a rung later.
    var crossPolicy: [String] = []
    /// ⟨0.34⟩ **NAMES THE CAUSE OF `crossPolicy`, NEVER MOVES THE VERDICT.** `true` when `crossPolicy` is
    /// non-empty AND every report that contributed to it predates ⟨0.33⟩ (`CandorCore.specPredates`
    /// against `"0.33"`) — i.e. the gap is fully explained by producers that could not yet have WRITTEN
    /// `scannedUnder` at all, never by one that ran under a genuinely different or narrower deny set. Set
    /// by `armingUnread` alongside `crossPolicy`, from the identical `unaskedCrossPolicyRules` call, so
    /// the two can never drift into disagreeing about one run's bytes.
    var crossPolicyPredates033 = false

    /// Is the universe this verb reasoned over known-partial? **EITHER ARM OF THIS IS AN EXIT CODE**, and
    /// that is why `judgedNothing` is deliberately NOT one of them. `unverified --strict` and
    /// `fix-gate --strict` answer 2 off this — *"the gate refuses over these bytes, so do I"* — but
    /// ⟨0.24⟩ ruled count-0 the other way for exactly those bytes: *"A DISCLOSURE, NOT AN EXIT CODE"*,
    /// because `gate --report` exits 0 over a facade package and a verb exiting 2 there would claim it
    /// got LESS far than the gate on identical input. So the count-0 cause reaches the two DISCLOSURE
    /// channels via `mustHedge` and stops at the exit code. `unreadable` IS an arm: the gate refuses
    /// over a file that does not load as a report, so the strict verbs answer 2 with it, exactly as the
    /// reference's `incomplete()` counts its `unreadable` list.
    /// ⟨0.30⟩ `outOfScope` IS AN ARM, for the reason the ⟨0.24⟩ rule states: an advisory verb must never
    /// be LESS sensitive to incompleteness than the gate over the same bytes, and that rule names
    /// `unverified`, `fix-gate` "and any later sibling". ⟨0.30⟩ made the gate exit 2 when the peek
    /// resolved a denied effect and left these verbs certifying — MEASURED on candor-rust and candor-ts,
    /// where the gate exited 2 and `--strict` answered clean at 0 over the identical report.
    /// ⟨0.32⟩ `unreadArmed` IS AN ARM, and it is the same MUST arriving one shape over: the gate refuses
    /// over a class the producing scan never opened, so a `--strict` verb over those bytes must not
    /// certify. MEASURED on this engine the moment the gate route gained the rule — `gate --report` exit
    /// 2 `ok:false` beside `fix-gate --strict` and `unverified --strict` at exit 0 `{"ok": true}`, over
    /// one no-policy report. Closing a cause on the gate and not on its siblings is how this rung's
    /// ⟨0.30⟩ half drifted first.
    var isIncomplete: Bool {
        !unanalyzed.isEmpty || !unreadable.isEmpty || !outOfScope.isEmpty || unreadArmed || !crossPolicy.isEmpty
    }

    /// ⟨0.28⟩ **Is there anything at all to disclose — the trigger for an ANSWER, where `isIncomplete` is
    /// the trigger for a VERDICT.** A descriptive verb asks THIS: its empty set is a negative finding
    /// under both causes, and it has no exit code for the distinction above to matter to. Both channels
    /// are keyed on it, so a caller cannot get the JSON half's trigger and the prose half's trigger to
    /// disagree — one channel going quiet is the mutant this family has already shipped once.
    /// ⟨0.28⟩ `noManifest` (SPEC §2 row 3) is an arm of THIS and not of `isIncomplete`, for the identical
    /// reason `judgedNothing` is: the gate exits 0 over a manifest-less report too (its own note names
    /// the condition — *"`analyzed.count` is 0, absent with no entries, or unreadable"*), so a verb
    /// exiting 2 there would claim it got LESS far than the gate on the same bytes. The row-3 split
    /// re-routes a hedge that was already happening; it must not also move an exit code.
    ///
    /// ⟨0.32⟩ **AND `unread` IS AN ARM OF THIS, *UNARMED* — RULED 2026-08-24 AFTER A FOUR-WAY
    /// DIVERGENCE. DO NOT RE-LITIGATE IT HERE.** Over a report whose `excluded` names a class the scan
    /// never opened, `tour` printed the bare *"nothing hidden — every effect sits where its name says it
    /// should"* at exit 0 in this engine, candor-rust and candor-ts, while candor-java hedged and named
    /// the class. **candor-java was right.**
    ///
    /// **IT IS A DISCLOSURE, NOT A VERDICT, AND IT MUST NOT MOVE AN EXIT CODE** — which is why the arm
    /// is here and NOT on `isIncomplete`. ⟨0.24⟩'s advisory-verb pessimism MUST binds verbs that answer
    /// `ok`; `tour` answers none and has no exit-code obligation, so that clause does not reach it. What
    /// reaches it is SPEC §2 ⟨0.28⟩, which widens the re-disclosure MUST to *"any verb whose output
    /// could be read as a negative finding about the code — a verdict, an empty result set, or a zero
    /// count"*, and SPEC §3.1 ⟨0.18⟩, which already forbids THIS EXACT SENTENCE over a ≥⅓-Unknown graph.
    /// An unread exclusion class is the same ignorance arriving by a different route, and the ⅓
    /// threshold structurally CANNOT see it: an unread unit contributes no entry, so it moves neither
    /// the numerator nor the denominator.
    ///
    /// **AND THE ARGUMENT THAT KEPT IT OUT WAS THE WRONG WAY ROUND.** Three engines reasoned *"these
    /// verbs take no `--policy`, so there is no question whose answer could depend on the unread code"*.
    /// The condition ⟨0.32⟩ states is the QUESTION IN FORCE, and a verb with no policy is not asking a
    /// NARROWER question than `deny Exec` — it is asking the widest one there is, the whole effect
    /// surface. A `deny`/`pure` rule's answer can depend on unread code; an `allow`/`forbid`/`only`/
    /// `layer` policy's answer cannot; a descriptive verb's answer always can.
    ///
    /// **THE TRIGGER IS THE GATE'S, MINUS THE POLICY CONDITION**: `peeked == false` with no
    /// `judgedElsewhere`, off the same key through the same reader, `count` IGNORED — measured
    /// 2026-08-24, all four gates refuse over a `count: 0` unread class and certify over a
    /// `judgedElsewhere: true` one. One matcher, so a report that earns an unhedged `tour` is exactly a
    /// report `gate --report` can certify. The NOISE objection — this fires on nearly every no-policy
    /// report — is real, and it is answered by the REMEDY rather than by silence: scan with the policy,
    /// the peek reads the class, `peeked` turns true and the hedge goes away.
    ///
    /// **KNOWN RESIDUAL, stated rather than asserted away:** `peeked: true` means the class was READ,
    /// not ANALYZED — the peek looks only for effects the PRODUCER's policy denied — so an undenied
    /// effect inside a peeked class is still outside `tour`'s graph and outside this hedge. That is the
    /// gate's residual too (SPEC §2 ⟨0.32⟩ files it), and closing it is a rung, not a fix.
    ///
    /// ⟨0.32⟩ **AND THE BOUNDARY THIS PREDICATE DRAWS WAS RULED AGAIN ON 2026-08-25, ON THE OTHER SIDE:
    /// A VERB THAT HEDGES RETURNS ITS DATA *AND* THE WARNING — IT NEVER RETURNS THE WARNING INSTEAD OF
    /// THE DATA.** ⟨0.28⟩ Rung A tells a verb *whose pinned shape cannot carry the caveat* to emit the
    /// CAVEAT DOCUMENT INSTEAD of its result, and the arm above then armed that substitution on nearly
    /// every no-policy report. Measured four-way: in the three engines that ship them, `show <fn> --json`
    /// and `map --json` answered `{"incomplete": true}` with the result GONE, including through
    /// candor-ts's MCP tools, which is the edit-time agent channel.
    ///
    /// **THE TEST IS WHETHER THE VERB ANSWERS `ok`.** `path`, `tour`, `show`, `map` and the rest of the
    /// descriptive surface certify NOTHING — no `ok`, no verdict, no exit-code obligation — so there is
    /// no claim for a pessimism rule to protect and withholding the answer buys no soundness; they take
    /// `mustHedge` and keep their result. `gate`, and `fix-gate`/`unverified`/`fix` under `--strict`, DO
    /// answer `ok`: they take `isIncomplete`, they refuse over these same bytes, and this ruling does not
    /// touch them (⟨0.24⟩'s "never LESS sensitive than the gate"; conformance PARTs 62 and 67 pin it).
    /// Getting that direction wrong re-opens the cardinal sin.
    ///
    /// **THIS ENGINE SHIPS NEITHER `show` NOR `map`** (surface: `path tour gains fix fix-gate unverified
    /// privacy-manifest gate parsepolicy`), so Rung A's substitution has no site here and nothing changed
    /// for the ruling — `path` and `tour` already merge `disclosureJSON` into their own document. Pinned
    /// by `UnreadExclusionAdvisorySiblingTests.testTheDescriptiveVerbsKeepTheirResultBesideTheHedge`,
    /// which also asserts the two verbs are still absent so a later port cannot arrive on the old shape.
    var mustHedge: Bool {
        isIncomplete || !judgedNothing.isEmpty || !noManifest.isEmpty || !unread.isEmpty
    }

    /// Readable manifest entries PLUS files whose manifest could not be read at all — the reference's
    /// `units()`, so the two engines' prose counts agree over identical bytes.
    var units: Int { unanalyzed.count + unreadable.count }
    var json: [[String: Any]] { unanalyzed.map { ["path": $0.path, "reason": $0.reason] as [String: Any] } }

    /// The MACHINE half: the ⟨0.28⟩ disclosure keys, or EMPTY when there is nothing to disclose — so
    /// merging it into an ordinary run's document is a no-op and that output stays byte-identical.
    /// `incomplete: true` is the flag EITHER cause raises (a consumer that only branches on it is safe
    /// under both); each manifest is omitted when empty, so a document raised by `unanalyzed` alone is
    /// byte-identical to the pre-⟨0.28⟩ one.
    var disclosureJSON: [String: Any] {
        guard mustHedge else { return [:] }
        var d: [String: Any] = ["incomplete": true]
        if !unanalyzed.isEmpty { d["unanalyzed"] = json }
        if !judgedNothing.isEmpty { d["judgedNothing"] = judgedNothing }
        // ⟨0.28⟩ SPEC §2 row 3, pinned verbatim in the rung that introduced it:
        //     "noManifest": [ "<report path>", … ]   // consulted reports carrying no `analyzed` key
        // Its own key rather than a third member of `judgedNothing`, because that key is defined as
        // "reports declaring `analyzed.count: 0`" and a row-3 report declares nothing. Omitted when empty
        // like its siblings, so a document raised by either of them alone is byte-identical to its
        // pre-row-3 form.
        if !noManifest.isEmpty { d["noManifest"] = noManifest }
        return d
    }

    /// What `gate --report` does over THESE SAME BYTES, as one sentence for a note's tail — a computed
    /// property rather than a fixed string because the two causes get OPPOSITE answers. Every pre-⟨0.28⟩
    /// disclosure closes with *"`gate --report` exits 2 over these bytes"*, which is true of `unanalyzed`
    /// (§3.3 makes an incomplete analysis of the target's own code an exit-2 cause) and FALSE of
    /// `analyzed.count: 0` (⟨0.24⟩: a disclosure, not an exit code). A note that sends the reader to a CI
    /// job which then passes teaches them the note is noise — the disclosure discrediting itself.
    ///
    /// ⟨0.28⟩ **AND A ROW-3-ONLY HEDGE GETS THE SAME EXIT REPORTED WITHOUT THE WRONG NOUN.** The gate
    /// exits 0 over a manifest-less report too, so the urgency is identical; but calling the report
    /// *judged-nothing* in a sentence printed under the row-3 disclosure would re-assert, in prose, the
    /// exact claim the split was made to stop making.
    var gateLine: String {
        if isIncomplete { return "`gate --report` exits 2 over these bytes." }
        // ⟨0.32⟩ THE UNARMED UNREAD CAUSE GETS ITS OWN SENTENCE, because both of the ones below are FALSE
        // of it in opposite directions: "exits 2 over these bytes" is unqualified and this verb holds no
        // policy to say it under, while "exits 0 over a judged-nothing report" names a cause that is not
        // present and sends the reader to a CI job that will pass. `gate --report` can only ever evaluate
        // a deny-family rule — measured 2026-08-24, all four engines refuse an `allow`-only policy as NO
        // RULES and a `forbid` rule as unevaluable on that route — so the exit is a certainty once a
        // policy exists, and the gap is only that none does here.
        if !unread.isEmpty {
            return "`gate --report` exits 2 over these bytes under any policy it can evaluate (they are "
                 + "all `deny`/`pure`), and this verb holds none — so NOTHING DOWNSTREAM IS FAILING "
                 + "CLOSED ON IT HERE and this note is the whole of the warning."
        }
        if judgedNothing.isEmpty {
            return "NOTHING DOWNSTREAM WILL CATCH THIS FOR YOU — `gate --report` exits 0 over a report "
                 + "carrying no `analyzed` manifest (⟨0.24⟩: a disclosure, not an exit code), so this "
                 + "note is the whole of the warning."
        }
        return "NOTHING DOWNSTREAM WILL CATCH THIS FOR YOU — `gate --report` exits 0 over a judged-nothing "
             + "report (⟨0.24⟩: a disclosure, not an exit code), so this note is the whole of the warning."
    }

    /// The HUMAN half — nil on a complete report, so an ordinary run stays byte-identical. ONE prose
    /// implementation for every caller: two copies of this text is exactly how the family arrived at two
    /// element rules for the manifest reader. Wording is the Rust reference's, character for character.
    func note(so soWhat: String, tail: String) -> String? {
        guard mustHedge else { return nil }
        // The unanalyzed-ONLY sentence is unchanged from the reference's pre-⟨0.28⟩ one: that is the case
        // every existing caller was measured on, and the count-0 arm is additive.
        //
        // ⟨0.28⟩ …and SPEC §2's THIRD ROW gets its OWN clause, appended, for the same reason: the
        // sentence above was FALSE of it. A manifest-less report does not "say it judged nothing" — it
        // says nothing, and a reader sent to re-run a scan that already reached a conclusion goes to the
        // wrong repair. Appended rather than folded into the arms so the measured wordings stay
        // character-for-character what they were when no row-3 report is present.
        //
        // ⟨0.32⟩ **AND THE FIRST ARM ASKS `units`, NOT `isIncomplete`.** Those are different questions
        // and the gap between them is a sentence that says nothing: `isIncomplete` has counted the two
        // SCOPE causes since ⟨0.30⟩ while this head was built from the MANIFEST rows alone, so a note
        // whose ONLY cause is out-of-scope or unread code came out as *"declare 0 unit(s) candor could
        // not analyze"* — a hedge that names a cause it does not have, which is the false disclosure this
        // family rates worse than a missing one. candor-rust and candor-java each measured the same line
        // on the same rung; here it was unreachable while the unread cause stayed out of `mustHedge`, and
        // reachable on nearly every no-policy report the moment it was not.
        var head: String
        switch (units > 0, judgedNothing.count) {
        case (true, 0):
            head = "the report(s) under this locator declare \(units) unit(s) candor could not analyze,"
        case (true, let n):
            head = "the report(s) under this locator declare \(units) unit(s) candor could not analyze, "
                 + "and \(n) report(s) that judged nothing at all,"
        // Reachable only with a row-3 report in hand: `mustHedge` gated the early return above, and with
        // no unanalyzed unit, no unreadable file and no count-0 report, `noManifest` is the only arm left
        // that could have raised it.
        case (false, 0):
            head = ""
        case (false, let n):
            head = "\(n) report(s) under this locator say they JUDGED NOTHING (`analyzed.count: 0`),"
        }
        // ONE JOINER FOR EVERY LATER CLAUSE — `first` opens the sentence when nothing has yet, otherwise
        // the clause comma is swapped for `, and …`. Three copies of that comma dance is how the head
        // above acquired a branch per cause.
        func append(_ first: String, _ more: String) {
            if head.isEmpty { head = first } else { head.removeLast(); head += more }
        }
        if !noManifest.isEmpty {
            let n = noManifest.count
            append("\(n) report(s) under this locator carry NO `analyzed` manifest at all "
                 + "(SPEC §2 row 3, a pre-⟨0.21⟩ producer),",
                   ", and \(n) report(s) carrying NO `analyzed` manifest at all,")
        }
        // ⟨0.30⟩/⟨0.32⟩ THE TWO SCOPE CAUSES, which the head never named — see the note on the switch.
        if !outOfScope.isEmpty {
            let n = outOfScope.count
            append("the report(s) under this locator name \(n) function(s) OUTSIDE the scan's scope "
                 + "performing an effect the producing scan's policy DENIED,",
                   ", and \(n) function(s) OUTSIDE the scan's scope performing a DENIED effect,")
        }
        if !unread.isEmpty {
            let n = unread.count
            append("the report(s) under this locator declare \(n) exclusion class(es) the scan did NOT "
                 + "READ (`excluded[].peeked: false`),",
                   ", and \(n) exclusion class(es) the scan did NOT READ,")
        }
        // ⟨0.33⟩ THE FOURTH CAUSE — a peeked exclusion class the producer read under a DIFFERENT deny
        // set, so its clean finding answers a question this run is not asking (SPEC §2 ⟨0.33⟩).
        //
        // ⟨0.34⟩ TWO SENTENCES, ONE CAUSE, chosen by `crossPolicyPredates033` — SAME verdict, same exit
        // (this clause only ever moves `head`'s WORDING). When every contributing report predates ⟨0.33⟩
        // the "does not cover" framing names the wrong culprit: it reads as "a producer chose a different
        // policy", and the true statement is "no producer here could yet WRITE the policy it peeked
        // under". The `else` arm is character-for-character the pre-⟨0.34⟩ text — the control this rung
        // ships with.
        if !crossPolicy.isEmpty {
            let n = crossPolicy.count
            if crossPolicyPredates033 {
                append("the report(s) under this locator predate ⟨0.33⟩ — before a producing scan "
                     + "recorded the deny set its peek ran under — so they cannot say whether \(n) "
                     + "rule(s) of THIS policy were ever asked,",
                       ", and \(n) rule(s) of THIS policy the report(s) — from before ⟨0.33⟩ — cannot "
                     + "say they were asked about,")
            } else {
                append("the report(s) under this locator carry a peek bounded by a deny set that does not "
                     + "cover \(n) rule(s) of THIS policy,",
                       ", and a peek bounded by a deny set that does not cover \(n) rule(s) of THIS policy,")
            }
        }
        var lines = ["  ⚠ INCOMPLETE — \(head)", "      so \(soWhat):"]
        for u in unanalyzed { lines.append("      \(u.path) — \(u.reason)") }
        // The reference's line, character for character; the "(see above)" is the loader's own stderr
        // OMITTED disclosure, which named the file before the answer was printed.
        for p in unreadable {
            lines.append("      \(p) — its `unanalyzed` manifest could not be read (see above)")
        }
        for p in judgedNothing {
            lines.append("      \(p) — `analyzed.count: 0`: this report judged NOTHING, so it names no "
                       + "function at all and its silence is not a purity claim")
        }
        for p in noManifest {
            lines.append("      \(p) — NO `analyzed` manifest at all (SPEC §2 row 3, a pre-⟨0.21⟩ "
                       + "producer): it DECLARES nothing about what was judged, so its silence licenses "
                       + "no purity claim either. Re-scan with a current engine so the report carries "
                       + "its manifest")
        }
        for o in outOfScope {
            let fn = (o["fn"] as? String) ?? "(unnamed)"
            let effs = ((o["effects"] as? [String]) ?? []).joined(separator: ", ")
            lines.append("      \(fn) — OUTSIDE the producing scan's scope: it performs \(effs), and the "
                       + "gate did not judge it")
        }
        // ONE FACT SENTENCE, TWO REMEDIES. The fact is the same on both routes; the REPAIR is not — an
        // ARMED run already holds the policy to re-scan with, and a descriptive verb holds none, so
        // telling it to re-run "WITH this policy" names a thing the reader does not have.
        for c in unread {
            let remedy = unreadArmed
                ? "Re-run the producing scan WITH this policy (candor-swift <dir> --policy <p>)"
                : "Re-run the producing scan WITH a `deny`/`pure` policy so the peek reads it "
                  + "(candor-swift <dir> --policy <p>)"
            lines.append("      \(c) — this exclusion class went UNREAD (`excluded[].peeked: false`): "
                       + "its effects are absent because nothing looked, not because there are none. "
                       + remedy)
        }
        // ⟨0.33⟩ THE REMEDY SAYS THE SAME POLICY, NOT A POLICY — the loose reading is what PRODUCES this
        // hole, because the operator DID scan with a policy and got a report whose peek answered a
        // different one (SPEC §2 ⟨0.33⟩).
        //
        // ⟨0.34⟩ ONE FACT, TWO REMEDIES — same split as `unread`'s `remedy` above, and for the same
        // reason: the CAUSE differs, so the REPAIR does. `else` is the pre-⟨0.34⟩ sentence, unchanged.
        let crossPolicyCauseAndRemedy = crossPolicyPredates033
            ? "these reports were produced before ⟨0.33⟩, when a producing scan did not yet record the "
            + "deny set its peek ran under — so an empty finding there cannot be read as an answer to "
            + "THIS policy's question. Re-scan with a 0.33+ engine under THE SAME policy this run is "
            + "applying (candor-swift <dir> --policy <p>)"
            : "this report's peek was bounded by a deny set that does not cover this rule: an excluded "
            + "file it reports as read was searched for OTHER effects, so an empty finding there is not "
            + "an answer to this question. Re-run the producing scan under THE SAME policy this run is "
            + "applying (candor-swift <dir> --policy <p>)"
        for r in crossPolicy {
            lines.append("      \(r) — \(crossPolicyCauseAndRemedy)")
        }
        lines.append("      \(tail)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `note` to STDOUT, BEFORE the answer — the Rust reference's channel and position, MEASURED rather
    /// than assumed. The first draft here sent it to stderr, on the reasoning that stdout is the machine
    /// surface even in prose mode; diffing the two engines over the SAME report file showed the text
    /// matching character for character on OPPOSITE channels, which is a divergence a consumer sees and
    /// no assertion in either tree would have caught. It goes above the answer because it qualifies what
    /// the verb DID find as much as what it did not.
    func printNote(so soWhat: String, tail: String) {
        guard let n = note(so: soWhat, tail: tail) else { return }
        print(n, terminator: "")
    }

    /// `printNote` on STDERR, for a verb whose stdout carries a JSON document — the reference's
    /// `eprint_note`, and for its reason: prose written to stdout beside a document would corrupt the
    /// document, and dropping the note instead is one channel going quiet, the mutant this family has
    /// already shipped once.
    func eprintNote(so soWhat: String, tail: String) {
        guard let n = note(so: soWhat, tail: tail) else { return }
        FileHandle.standardError.write(Data(n.utf8))
    }
}

// The envelope's ⟨0.21⟩/⟨0.28⟩ completeness manifest, merged across sibling reports — BOTH causes, in one
// place, so a caller cannot pick up one and miss the other. A member of `unanalyzed` that is not a
// `{path, …}` object is SKIPPED rather than failing the load: these are advisory verbs, and the
// alternative — refusing to answer at all — is strictly less than the partial answer §3.2 asks for.
// (The GATE route does fail loud on a malformed manifest, deliberately: it is certifying.)
//
// ⟨0.28⟩ the judged-nothing arm is decided PER FILE and by `claimsToHaveJudgedNothing` (Deps.swift), the
// predicate the chained dep-join already uses: a locator naming several siblings must disclose EACH
// silent one by name, and reimplementing the `analyzed.count` reading here is how two routes come to
// disagree about the same bytes. Its fail-closed arms travel with it — a manifest that is PRESENT but
// garbled reads as judged-nothing, exactly as it does for coverage.
private func mergeCompleteness(_ obj: [String: Any], path: String, entryCount: Int,
                               into c: inout ReportCompleteness) {
    for case let m as [String: Any] in (obj["unanalyzed"] as? [Any]) ?? [] {
        guard let p = m["path"] as? String else { continue }
        c.unanalyzed.append((path: p, reason: m["reason"] as? String ?? ""))
    }
    // ⟨0.28⟩ …AND THEN SPLIT BY WHICH ROW OF SPEC §2's TABLE IT IS, which is a SECOND question asked of
    // the same envelope, never an edit to the answer above. `claimsToHaveJudgedNothing` decides COVERAGE
    // on two other routes (the chained dep-join's `coveredPkgs`, `gate --report`), where a manifest-less
    // report must keep granting none — row 3's own instruction is *no manifest, no claim*. Flipping it
    // here to correct a LABEL would make every pre-⟨0.21⟩ report read as covered: a silent under-report
    // introduced by a disclosure fix. So the hedge stands and only its KEY is chosen, by the
    // disclosure-only `hasNoManifest`.
    if claimsToHaveJudgedNothing(analyzed: obj["analyzed"], entryCount: entryCount) {
        if hasNoManifest(analyzed: obj["analyzed"]) { c.noManifest.append(path) }
        else { c.judgedNothing.append(path) }
    }
    // ⟨0.30⟩ the peek's findings, so `--strict` is at least as pessimistic as the gate (the ⟨0.24⟩ MUST).
    //
    // PRESENT-BUT-NOT-A-LIST IS CORRUPT, and it must reach the ADVISORY verbs too. The `as? [Any]` cast
    // failed silently on a garbled key, so the findings vanished and `--strict` certified a report
    // `gate --report` refuses at exit 2 — the ⟨0.24⟩ relation broken one shape over from where it was
    // closed. A corrupt key rides `unreadable`, which is ALREADY an arm of `isIncomplete`, so this uses
    // the fail-closed path that rule established rather than adding one beside it. Same for a non-object
    // MEMBER: `compactMap` dropped it, which is the identical coercion one level in.
    if obj["outOfScope"] != nil {
        guard let oos = obj["outOfScope"] as? [Any] else {
            c.unreadable.append(path)
            return
        }
        for e in oos {
            guard let m = e as? [String: Any] else {
                c.unreadable.append(path)
                return
            }
            c.outOfScope.append(m)
        }
    }
    // ⟨0.32⟩ THE OTHER HALF OF THE SAME RUNG — the classes the producing scan never opened. Read here
    // UNCONDITIONALLY and off the same key `gate --report` reads (`readableFlag` is that route's own
    // reader, shared rather than re-spelled: two readings of one flag is how the two arms of ⟨0.30⟩
    // drifted). Whether it MATTERS is the caller's decision, because it turns on the policy in force.
    //
    // CORRUPT RIDES `unreadable`, exactly as the `outOfScope` block above does it: a garbled `excluded`
    // read as "this scan excluded nothing" is the safe-LOOKING value, and here it would silently delete
    // an arm rather than raise one.
    // ⟨0.33⟩ does THIS FILE carry any peeked (and not `judgedElsewhere`) exclusion? — the precondition
    // for the cross-policy fact below, exactly as `mergeGateReport` (GateReportCLI.swift) computes it.
    var filePeekedAny = false
    if let rawX = obj["excluded"] {
        guard let arr = rawX as? [Any] else { c.unreadable.append(path); return }
        for x in arr {
            guard let m = x as? [String: Any], let cls = m["class"] as? String, !cls.isEmpty,
                  let peeked = readableFlag(m["peeked"]),
                  let judgedElsewhere = readableFlag(m["judgedElsewhere"]) else {
                c.unreadable.append(path)
                return
            }
            if !peeked && !judgedElsewhere { c.unread.append(cls) }
            if peeked && !judgedElsewhere { filePeekedAny = true }
        }
    }
    // ⟨0.33⟩ THE QUESTION THIS FILE'S PEEK WAS PUT (SPEC §2 ⟨0.33⟩) — read as strictly as `gate --report`
    // reads it (GateReportCLI.swift's `mergeGateReport`), and for the identical reason: a garbled value
    // read permissively would MANUFACTURE coverage the producer never claimed, so it rides `unreadable`
    // exactly as a garbled `excluded`/`outOfScope` does above.
    var scannedUnderThisFile: Set<String>? = nil
    if let rawSU = obj["scannedUnder"] {
        guard let m = rawSU as? [String: Any], let denyRaw = m["deny"] as? [Any] else {
            c.unreadable.append(path)
            return
        }
        let denyStrs = denyRaw.compactMap { $0 as? String }
        guard denyStrs.count == denyRaw.count else {
            c.unreadable.append(path)
            return
        }
        scannedUnderThisFile = Set(denyStrs)
    }
    // ⟨0.33⟩ ONLY WHEN THIS FILE PEEKED SOMETHING — the over-charge control this rung's design names
    // first. An ABSENT `scannedUnder` beside a peeked class is the EMPTY SET for the subset test, never
    // a licence (a pre-⟨0.33⟩ producer fails closed).
    //
    // ⟨0.34⟩ …carried beside this file's own declared `candor.spec` — read here, once, rather than
    // re-parsing `obj` from `armingUnread` once the missing rules are known (see the field doc on
    // `ReportCompleteness.scannedUnderOfPeeked`). `""` when absent/unreadable, the same "treat as
    // pre-spec-field" reading `CandorCore.specPredates` already commits to.
    if filePeekedAny {
        let fileSpec = (obj["candor"] as? [String: Any])?["spec"] as? String ?? ""
        c.scannedUnderOfPeeked.append((deny: scannedUnderThisFile ?? [], spec: fileSpec))
    }
}

// ⟨0.24⟩ Emit an advisory verb's answer and exit, applying the §3.2 incompleteness rule in ONE place so
// `unverified` and `fix-gate` cannot drift apart on it (and a third such verb inherits it by construction).
//
// COMPLETE — unchanged from before, byte for byte: `ok` plus the verb's own array, `--strict` exits 1 on
// a finding. INCOMPLETE — `ok` is omitted, `incomplete`/`unanalyzed` are added, and `--strict` exits 2
// (could-not-fully-evaluate, the gate's code for the same situation) rather than the 1 that would claim a
// finding or the 0 that would certify. Without `--strict` these verbs are advisory and still exit 0: the
// agent fix-loop reads the body, and turning its exit red would be a different change than this one.
//
// ⟨0.24⟩ **AND THE SAME TREATMENT FOR A RULE THE GATE COULD NOT EVALUATE** (SPEC §3.2, candor-spec
// `4fd140c`). It arrives here rather than at either call site for the reason the incompleteness rule
// did: two verbs applying one law in two places is how they drifted the first time. The shape is not a
// new one — `unevaluated: [{rule, why}]` is the GATE's field (§3.1, `fc4b5f6`), and §3.2 is explicit
// that inventing a second spelling for it is the mistake that document has made four times.
//
// `ok` is OMITTED for the same reason incompleteness omits it, and the reasoning is worth keeping
// separate for each verb: `unverified` always NAMES the function it could not clear, so its `ok` would
// read `false` and be defensible — but `fix-gate` WITHHOLDS the remedy, so `ok:true` there would
// certify "no crossings" over a policy nobody finished evaluating. One rule for both, and it is the
// fail-safe one: a consumer writing `if (r.ok)` gets undefined.
func emitAdvisoryAnswer(_ body: [String: Any], ok: Bool, completeness c: ReportCompleteness,
                        strict: Bool, unevaluated: [UnansweredRule] = []) -> Never {
    var out = body
    if !unevaluated.isEmpty { out["unevaluated"] = unevaluated.map { $0.toJSON() } }
    // ⟨0.28⟩ THE DOCUMENT GATE AND THE EXIT ARGUMENT ARE NOW DIFFERENT PREDICATES, deliberately.
    //
    //   · the DOCUMENT withdraws `ok` on `mustHedge`: a report that judged NOTHING licenses `ok` no more
    //     than one naming source it could not read does, and leaving this on `isIncomplete` would have
    //     let a `true` ship beside the INCOMPLETE note the same struct is printing — one channel going
    //     quiet, the split this family has already been bitten by;
    //   · the EXIT stays on `isIncomplete`, because ⟨0.24⟩ fixed count-0's exit at the gate's (exit 0),
    //     and a verb answering 2 where `gate --report` answers 0 would claim it got LESS far than the
    //     gate on identical bytes. So a count-0 report with a HOLE still exits 1 under `--strict`, as it
    //     did before this rung: the caveat is added, the refusal is not.
    let refuses = c.isIncomplete || !unevaluated.isEmpty
    if c.mustHedge || !unevaluated.isEmpty {
        for (k, v) in c.disclosureJSON { out[k] = v }
        emitJSON(out)
        exit(refuses ? (strict ? 2 : 0) : (strict && !ok ? 1 : 0))
    }
    out["ok"] = ok
    emitJSON(out)
    exit(strict && !ok ? 1 : 0)
}

// Parse one `functions`-envelope report file into `byName` (+ its coverage disclosure into `coverage`).
// Returns false (with a stderr note) on an
// unparseable / non-report file — the caller FAILS LOUD, never reads it as an empty "no crossings".
private func mergeFixReport(_ full: String, into byName: inout [String: FixFn],
                            coverage: inout ReportCoverage,
                            completeness: inout ReportCompleteness,
                            scopeEntitlements: inout [String],
                            who: String) -> Bool {
    let fm = FileManager.default
    guard let data = fm.contents(atPath: full),
          let root = try? JSONSerialization.jsonObject(with: data),
          let obj = root as? [String: Any],
          let fns = obj["functions"] as? [[String: Any]] else {
        // ⟨0.28⟩ OMITTED *and counted*: the answer over the surviving siblings is INCOMPLETE, not clean.
        // Recording the casualty here rather than only on stderr is what lets every caller of this
        // loader hedge — see `ReportCompleteness.unreadable`.
        completeness.unreadable.append(full)
        FileHandle.standardError.write("candor-swift \(who): report `\(full)` could not be parsed — OMITTED, and this answer is reported INCOMPLETE (`gate --report` refuses over these bytes).\n".data(using: .utf8)!)
        return false
    }
    // ⟨scope travels⟩ the `.entitlements` this report's `--target` resolved. COLLECTED, not decided
    // here: several reports may be merged, and if they name DIFFERENT files they are different binaries
    // and the caller must not pick one.
    if let sc = obj["scope"] as? [String: Any], let ent = sc["entitlements"] as? String {
        scopeEntitlements.append(ent)
    }
    for e in fns {
        guard let fn = e["fn"] as? String, !fn.isEmpty else { continue }
        let inferred = Set((e["inferred"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let direct = Set((e["direct"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let calls = (e["calls"] as? [Any])?.compactMap { $0 as? String } ?? []
        let loc = e["loc"] as? String ?? ""
        // ⟨0.19⟩ `unknownWhy` rides along for the §6.2 reason-class resolution `deniedLayer` now performs:
        // a `deny Unknown[<class>…]` only forbids `Unknown` where the classes meet, and until this field
        // was read `fix-gate` computed a hoist remedy for holes the policy explicitly does not deny. A
        // report predating the field loads it empty, which leaves the narrowed rule unmatched there —
        // the same withholding `evaluateGate` applies rather than charging on a default.
        let why = (e["unknownWhy"] as? [Any])?.compactMap { $0 as? String } ?? []
        // ⟨0.20⟩ `netClass` rides along for the destination-class conjunct `deniedLayer` now performs: a
        // `deny Net[<dest>…]` only forbids `Net` where the destinations meet, and until this field was
        // read `fix-gate` computed a hoist remedy for endpoints the policy explicitly tolerates. Read
        // VERBATIM — the producer already accumulated it transitively and already floored it at
        // `unknown-host`, which is how `gate --report` consumes the same field. A report predating it
        // loads empty, leaving the narrowed rule unmatched there: the same withholding.
        let netClass = (e["netClass"] as? [Any])?.compactMap { $0 as? String } ?? []
        var rec = FixFn(inferred: inferred, direct: direct, calls: calls, unknownWhy: why,
                           netClass: netClass, loc: loc)
        // `privacy/2` direction, read verbatim like `netClass`. Absent ⇒ undetermined ⇒ the old
        // any-key semantics, so an older report is never made to fail by this field's arrival.
        rec.paths = (e["paths"] as? [Any])?.compactMap { $0 as? String } ?? []
        rec.incomplete = (e["incomplete"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let pk = e["privacy"] as? [String: Any] {
            var m: [String: [String]] = [:]
            for (eff, v) in pk { m[eff] = (v as? [Any])?.compactMap { $0 as? String } ?? [] }
            rec.privacyKinds = m
        }
        // ⟨0.32⟩ RECORD THE JOIN KEY, and NEVER let a second report silently take the name. This line
        // used to be a bare overwrite: two units declaring `A.run` left whichever report was read LAST,
        // so a remedy could be computed against a function the operator never asked about — and nothing
        // said so. The first record stands and the collision is MARKED; `fixGate` refuses to plan on a
        // marked name (SPEC §3.2 — this verb's answer is a comparison against a gate that keys by hash).
        let jk = (e["hash"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fn
        if var existing = byName[fn] {
            existing.joinKeys.insert(jk)
            byName[fn] = existing
        } else {
            rec.joinKeys = [jk]
            byName[fn] = rec
        }
        for case let m as String in (e["invisible"] as? [Any]) ?? [] { coverage.invisibleModules.insert(m) }
    }
    // ⟨0.15 staged⟩ envelope `coverage` ledger (absent on a fully-covered or pre-⟨0.15⟩ report).
    if let cov = obj["coverage"] as? [String: Any], let unc = cov["uncovered"] as? [[String: Any]] {
        for entry in unc { if let name = entry["name"] as? String { coverage.envelopeModules.insert(name) } }
    }
    // ⟨0.21⟩ completeness manifest, ⟨0.24⟩ read HERE for the first time — see `ReportCompleteness`.
    // ⟨0.28⟩ …and its `analyzed.count: 0` row alongside it, from the SAME reader.
    mergeCompleteness(obj, path: full, entryCount: fns.count, into: &completeness)
    return true
}

// Merge one `.callgraph.json` sidecar into `cg`. A PRESENT but corrupt/unreadable sidecar silently
// shrinks the call graph — so tour/fix under-report reaches whose edges lived in the dropped file, and a
// gate can go false-GREEN. Mirror Rust's `load_callgraph`: disclose on stderr when a sidecar that EXISTS
// fails to read or parse (a genuinely MISSING sidecar is NOT passed here — that silent fallback is fine).
// Returns false on that read/parse failure so a caller who NEEDS a complete graph (gains `origin`) can
// mark the merged result PARTIAL rather than trust it whole.
@discardableResult
private func mergeCallgraph(_ full: String, into cg: inout [String: [String]]) -> Bool {
    guard let data = FileManager.default.contents(atPath: full) else {
        FileHandle.standardError.write(
            "candor-swift: callgraph `\(full)` could not be read — its edges are OMITTED, so the call graph may be incomplete (tour/fix under-report)\n"
                .data(using: .utf8)!)
        return false
    }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        FileHandle.standardError.write(
            "candor-swift: callgraph `\(full)` failed to parse — its edges are OMITTED, so the call graph may be incomplete (corrupt or mid-write); re-run the scan\n"
                .data(using: .utf8)!)
        return false
    }
    for (k, v) in obj { cg[k] = (v as? [Any])?.compactMap { $0 as? String } ?? [] }
    return true
}

// Load every `<prefix>*.Swift.json` report (merging siblings) + the `.callgraph.json` sidecars for the graph.
// Returns nil if no report file is found for the prefix (the caller fails loud).
//
// A `prefix` that is ITSELF an existing regular `.json` file is loaded DIRECTLY as that one report (§3.3.1:
// "a path ending .json → that single report file loaded directly, any .json file, whatever its internal
// dot-segments") — so one engine can query another engine's report by its exact path, even when the filename
// does not fit the `<prefix>.<pkg>.Swift.json` family shape. A matching `.callgraph.json` sibling (same stem)
// is still picked up for the graph if present.
//
// `who` is the CALLING VERB, and it is REQUIRED rather than defaulted. It reaches the user only inside a
// DISCLOSURE — mergeFixReport's "report `…` could not be parsed — OMITTED, and this answer is reported
// INCOMPLETE". fix/fix-gate/tour/path/privacy-manifest all share this loader, and it used to hardcode
// `"fix"`, so three of those five disclosed their own incompleteness under ANOTHER VERB'S NAME: a user
// running `privacy-manifest` over a corrupt sibling was told `candor-swift fix:` had dropped something.
// A default value would leave that same trap armed for the next caller, which is how the three got it.
func loadFixModel(prefix: String, who: String) -> (byName: [String: FixFn], cg: [String: [String]],
                                                   coverage: ReportCoverage, completeness: ReportCompleteness,
                                                   scopeEntitlements: String?)? {
    let fm = FileManager.default
    var byName: [String: FixFn] = [:]
    var cg: [String: [String]] = [:]
    var coverage = ReportCoverage()
    var completeness = ReportCompleteness()
    var foundReport = false
    // ⟨scope travels⟩ every scoped report's entitlements path; ONE distinct value is an answer, several
    // are different binaries and the caller keeps its own discovery.
    var scopeEnts: [String] = []

    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        // Direct single-file load (any `.json` filename).
        foundReport = mergeFixReport(prefix, into: &byName, coverage: &coverage,
                                     completeness: &completeness, scopeEntitlements: &scopeEnts, who: who)
        let stem = (prefix as NSString).deletingPathExtension
        let sidecar = stem + ".callgraph.json"
        if fm.fileExists(atPath: sidecar) { mergeCallgraph(sidecar, into: &cg) }
        guard foundReport else { return nil }
        if cg.isEmpty { for (fn, f) in byName { cg[fn] = f.calls } }
        return (byName, cg, coverage, completeness, Set(scopeEnts).count == 1 ? scopeEnts[0] : nil)
    }

    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

    for name in entries.sorted() where name.hasPrefix(base + ".") {
        let full = dir + "/" + name
        if name.hasSuffix(".Swift.callgraph.json") {
            mergeCallgraph(full, into: &cg)
        } else if name.hasSuffix(".Swift.json") {
            // A report file present but unparseable (truncated / mid-write / not a report) FAILS LOUD;
            // `foundReport` flips true only after a successful parse, so a lone corrupt report leaves it
            // false → loadFixModel returns nil → exit 2.
            if mergeFixReport(full, into: &byName, coverage: &coverage,
                              completeness: &completeness, scopeEntitlements: &scopeEnts, who: who) { foundReport = true }
        }
    }
    guard foundReport else { return nil }
    // The callgraph sidecar is the graph of record; if it is absent (an older/`--json`-only report), fall
    // back to the report's own inline `calls` so a prefix that has only the envelope still answers.
    if cg.isEmpty { for (fn, f) in byName { cg[fn] = f.calls } }
    return (byName, cg, coverage, completeness, Set(scopeEnts).count == 1 ? scopeEnts[0] : nil)
}

/// ⟨0.32⟩ ARM THE UNREAD-CLASS CAUSE FOR THIS RUN'S POLICY — the one place the condition is applied, so
/// the three advisory verbs cannot answer it three ways.
///
/// The condition is the same one `gate --report` applies to its own `unpeeked` value, and it is about
/// the QUESTION rather than about the producer: only a `deny`/`pure` rule's answer depends on code
/// outside the scan's scope. `pol.deny` is the right list and `pure` is IN it — the parser appends a
/// `pure` line as a DenyRule with an empty effect list — so reading the question off a flattened set of
/// effect NAMES would silently disarm the strictest policy the grammar has.
///
/// ⟨0.32⟩ **AND A POLICY THAT ASKS NOTHING *CLEARS* THE LIST, IT DOES NOT MERELY LEAVE IT UNARMED** —
/// the candor-rust reference does it this way and the reason showed up the moment `mustHedge` started
/// reading `unread` directly (the 2026-08-24 descriptive ruling): with the list left in place, a
/// `forbid`-only run began emitting `incomplete: true` on `fix-gate`/`unverified`, hedging exactly the
/// allowlist run this function exists to leave alone. `UnreadExclusionAdvisorySiblingTests`'
/// no-deny-rule CONTROL caught it. Nothing downstream may read a list this run has decided is not a
/// question.
///
/// ⟨0.33⟩ **AND THE SAME FUNCTION ARMS THE CROSS-POLICY CAUSE**, deliberately: both conditions ask *does
/// THIS run's deny set reach code the producer's peek did not answer for*, and arming one without the
/// other is exactly how a rung has shipped on `gate --report` and not on its advisory siblings before
/// (⟨0.24⟩; conformance PART 67 is the standing example). `unaskedCrossPolicyRules` already returns `[]`
/// for a policy with no deny rule and for a report that peeked nothing, so there is no second "clears
/// the list" branch to write here — those are the SAME structural carve-outs `gate --report` gets for
/// free (CandorCore.unaskedCrossPolicyRules).
private func armingUnread(_ c: ReportCompleteness, under pol: ParsedPolicy) -> ReportCompleteness {
    var out = c
    if !out.unread.isEmpty {
        if pol.deny.isEmpty { out.unread = [] } else { out.unreadArmed = true }
    }
    // ⟨0.34⟩ ONE CALL, BOTH FIELDS — `crossPolicy` and `crossPolicyPredates033` come from the SAME
    // `unaskedCrossPolicyRules` computation, so this verb's document and its prose note cannot read two
    // different accounts of which reports contributed the gap (see the field doc on `crossPolicyPredates033`).
    let cp = unaskedCrossPolicyRules(pol.deny, against: c.scannedUnderOfPeeked)
    out.crossPolicy = cp.rules
    out.crossPolicyPredates033 = cp.oldCaused
    return out
}

private func loadDenyOrDie(_ policyPath: String, who: String) -> [DenyRule] {
    loadPolicyOrDie(policyPath, who: who).deny
}

/// The FULL parse, for the callers that must ask the ⟨0.28⟩ zero-rule question over EVERY rule vector —
/// a check that reads `.deny` alone would call an allow-only or forbid-only policy "no rules at all"
/// (the same subset mistake the reference engine's first draft made, recorded on
/// `zeroRulePolicyRefusal`).
private func loadPolicyOrDie(_ policyPath: String, who: String) -> ParsedPolicy {
    guard let text = try? String(contentsOfFile: policyPath, encoding: .utf8) else {
        fixDie("candor-swift \(who): policy `\(policyPath)` could not be read — no fix computed")
    }
    return parsePolicy(text)
}

/// ⟨0.28⟩ **AN ADVISORY VERB OVER A ZERO-RULE POLICY ANSWERS WITH THE CAVEAT DOCUMENT, RESULT KEYS
/// WITHHELD, EXIT UNCHANGED** (SPEC §2). §6.2 makes a configured zero-rule policy an exit-2 refusal for
/// the GATE, because `ok: true` is a claim about the code no such run may make. These verbs are ADVISORY
/// — they set no verdict, so the refusal posture is the wrong import — but what they produce is an
/// answer *relative to a policy*, and relative to no rules that answer is not a finding, it is an
/// absence of questions. Measured on this engine 2026-08-12 over a comments-only policy:
///
///     unverified --json    {"ok": true, "unverified": []}      exit 0
///     fix-gate   --json    {"ok": true, "remedies": []}        exit 0
///
/// — an empty result set indistinguishable from "we asked and everything passed", for the same reason
/// ⟨0.27⟩'s refusal document must not carry `violations`. So: the result keys (`unverified`/`remedies`)
/// and `ok` are WITHHELD, and the document carries `unevaluated` with the whole-policy entry — the
/// gate's own shape (§3.1 pins it for a policy with no lines to name), because inventing a second
/// spelling of "this could not be asked" is the mistake the spec has recorded four times. The ⟨0.21⟩/
/// ⟨0.28⟩ completeness keys still ride it: an unread unit qualifies this non-answer as much as any
/// answer.
///
/// THE EXIT IS UNCHANGED — a disclosure, per ⟨0.24⟩'s standing ruling that count-0 reaches both
/// disclosure channels and STOPS at the exit code. On these bytes the verbs exited 0 (nothing to find,
/// `--strict` included) and 2 only for `--strict` over an INCOMPLETE report (`emitAdvisoryAnswer`'s
/// standing rule); both are preserved here rather than borrowing the gate's 2, which would claim the
/// verb got LESS far than it did.
///
/// Returns normally when the policy carries at least one rule of ANY kind — the caller proceeds.
///
/// ⟨0.28⟩ Phase 1b: `fix` IS ROUTED HERE NOW. This paragraph used to say it deliberately was not,
/// because SPEC named three verbs and `fix <fn> <Effect>` answers a NAMED question whose `crossing`
/// shape the clause did not touch — so extending the withholding unasked would have been a one-engine
/// guess of exactly the kind `judgedNothing`'s boolean was. That was the right call and the premise
/// expired: SPEC §2 ⟨0.28⟩ now states the rule over the CONDITION (every verb answering relative to a
/// CONFIGURED policy) and cites this split — rust extended the list and flagged it, this engine read it
/// as closed and reported the cell — as having been created BY the clause, not by either engine.
private func answerZeroRulePolicyWithCaveat(_ pol: ParsedPolicy, at policyPath: String, who: String,
                                            completeness c: ReportCompleteness, strict: Bool) {
    guard let zr = zeroRulePolicyRefusal(pol, at: policyPath, who: "candor-swift \(who)") else { return }
    FileHandle.standardError.write(
        ("candor-swift \(who): the policy \(policyPath) yielded NO RULES — every line was ignored, the "
         + "file is empty, or it holds only comments. This verb answers relative to a policy, and "
         + "relative to no rules there is no question to answer: the result keys are withheld (an empty "
         + "list here would read as \"asked and clear\"). The gate refuses these bytes at exit 2; this "
         + "verb is advisory and its exit is unchanged. If you did not mean to gate, remove the `policy` "
         + "setting.\n").data(using: .utf8)!)
    var out: [String: Any] = ["unevaluated": zr.unevaluated.map {
        ["rule": $0.rule, "why": $0.why] as [String: Any]
    }]
    for (k, v) in c.disclosureJSON { out[k] = v }
    emitJSON(out)
    // The exits this verb already had on these bytes: 0, and --strict's 2 only for the incomplete
    // report emitAdvisoryAnswer has always refused (the gate refuses those bytes too).
    exit(c.isIncomplete && strict ? 2 : 0)
}

// ── §3.3.1 canonical query grammar (0.10) ──────────────────────────────────────────────────────────
// The three exposed query verbs (fix / fix-gate / unverified) are driven the canonical way: the report
// is DISCOVERED by default, `--report <locator>` overrides with the one 3-way locator rule, `--policy`
// is a flag (never a positional), `--json` selects JSON, `--strict` guards `unverified`. The prior
// positional forms (a leading report prefix, a positional policy) stay accepted as DEPRECATED aliases
// with a one-line stderr note — the conformance suite still drives them positionally. Shared here so all
// three verbs resolve the report + policy identically.

// Emit the one-line deprecation note to STDERR (stdout stays pure JSON). Called at most once per
// invocation from parseQueryArgs, which passes the combined "what" so it is genuinely one line.
private func noteDeprecated(_ what: String) {
    FileHandle.standardError.write(
        ("candor-swift: note — \(what) is a DEPRECATED positional form; use the flag grammar "
         + "(--report <locator> --policy <file>). The positional form is removed at the next breaking bump.\n")
            .data(using: .utf8)!)
}

// Resolve a `--report <locator>` value to what the report loaders consume, by the ONE shared rule
// (§3.1 ⟨0.28⟩ — what each locator form RESOLVES TO):
//   · a DIRECTORY → `<dir>/.candor/report` (the discovery spelling — the reports discovered inside it);
//   · a path ending `.json` → THAT FILE, loaded directly (plus its §2.2 sidecars, which the loaders'
//     direct-file arms pick up by stem);
//   · otherwise a bare PREFIX → the whole `<prefix>.*.Swift.json` sibling set, unioned by the loaders.
//
// ⟨0.28⟩ **A FILE LOCATOR DOES NOT UNION THE PREFIX SIBLINGS BESIDE IT.** This function used to strip a
// family-shaped `<prefix>.<pkg>.Swift.json` back to `<prefix>`, so `--report r.A.Swift.json` silently
// read `r.B.Swift.json` too — MEASURED 2026-08-12 on this engine: `path B.doFs Fs --report
// r.A.Swift.json` traced a function that lives only in the sibling, and `gate --report r.A.Swift.json`
// fired a violation from it (`analyzed.count` summed BOTH files). The operator named one artifact;
// silently reading three makes `--report r.json` mean something different depending on what else sits in
// the directory — the mirror of the sink-guard expansion bug. candor-java and candor-ts already resolve
// a FILE to the file, and the spec pins that reading. A locator naming a §2.2 SIDECAR still resolves to
// the report it is a sidecar OF (`<stem>.callgraph.json` → `<stem>.json`): the pair is read together,
// and the sidecar itself is not a report.
func resolveReportLocator(_ locator: String) -> String {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: locator, isDirectory: &isDir), isDir.boolValue {
        return (locator as NSString).appendingPathComponent(".candor/report")
    }
    if locator.hasSuffix(".json") {
        // The §2.2 reserved data segments (the same five `gateReportInputFiles` walks): a sidecar name
        // is normalized to its report FILE, never to the prefix.
        var s = locator
        for sidecar in ["calibrated", "callgraph", "hierarchy", "layerreach", "locs"]
        where s.hasSuffix(".\(sidecar).json") {
            s = String(s.dropLast(".\(sidecar).json".count)) + ".json"
        }
        // A `.json` path that names no existing file falls through to the loaders unchanged: their
        // prefix walk matches `<locator>.` and finds nothing, so a typo'd file path fails LOUD rather
        // than quietly widening to whatever siblings share its directory.
        return s
    }
    return locator
}

// Does `tok` resolve to an EXISTING report (a `.json` file, or a dir/prefix with a matching sibling
// report)? Used ONLY to tell the DEPRECATED leading-positional report apart from a canonical first
// positional (fix's <fn>): `fix <report.json> <fn> <Effect> <policy>` (old) vs `fix <fn> <Effect> <policy>`
// (canonical, report discovered). A QUIET probe — it must not emit the not-found chatter, so a canonical
// first positional (a fn substring) simply reads as "not a report". Mirrors candor-java's `looksLikeReport`
// so the surplus-1 trailing-policy case (`fix doNet Net policy.txt`) parses identically in both engines.
private func looksLikeReport(_ tok: String) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if tok.hasSuffix(".json") {
        return fm.fileExists(atPath: tok, isDirectory: &isDir) && !isDir.boolValue
    }
    if fm.fileExists(atPath: tok, isDirectory: &isDir), isDir.boolValue {
        return quietPrefixMatches((tok as NSString).appendingPathComponent(".candor/report"))
    }
    return quietPrefixMatches(tok)
}

// True iff a `<prefix>.<pkg>.Swift.json` sibling report exists, WITHOUT the loader's stderr chatter.
private func quietPrefixMatches(_ prefix: String) -> Bool {
    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
    return entries.contains { n in
        n.hasPrefix(base + ".") && n.hasSuffix(".Swift.json")
            && !n.hasSuffix(".callgraph.json") && !n.hasSuffix(".hierarchy.json")
    }
}

// Discover the report prefix when no --report is given: CANDOR_REPORT overrides; otherwise walk UP from
// the CWD for a `.candor/` directory and use `<that>/.candor/report` as the prefix (§3.4 discovery,
// mirroring Config.swift's ancestor walk). Returns nil if neither is found (the caller fails loud).
func discoverReportPrefix() -> String? {
    if let env = ProcessInfo.processInfo.environment["CANDOR_REPORT"], !env.isEmpty {
        return resolveReportLocator(env)
    }
    var dir = (URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path as NSString).standardizingPath
    for _ in 0..<64 {
        let cand = (dir as NSString).appendingPathComponent(".candor")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cand, isDirectory: &isDir), isDir.boolValue {
            return (cand as NSString).appendingPathComponent("report")
        }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir || parent.isEmpty { break }
        dir = parent
    }
    return nil
}

// Policy fallback when --policy is absent (mirrors the scan surface): CANDOR_POLICY env, then the
// discovered .candor/config `policy` key (CWD-anchored — the query has no scan target). Returns nil if
// neither is set (the caller fails loud, as fix requires a policy to define the boundary it crosses).
// Internal (not private) so ⟨0.24⟩ `gate --report` inherits the SAME §3.3.1 fallback as fix/fix-gate/
// unverified rather than open-coding a second one.
func discoverPolicy() -> String? {
    if let env = ProcessInfo.processInfo.environment["CANDOR_POLICY"], !env.isEmpty { return env }
    let cfg = loadCandorConfig(targetPath: ".")
    if let p = cfg["policy"], !p.isEmpty { return p }
    return nil
}

// The parsed canonical invocation shared by all three verbs. `verbArgs` are the leading positionals
// (fix's <fn> <Effect>); report/policy are resolved (flag → discovery); strict/json are the flags.
private struct QueryArgs {
    var verbArgs: [String] = []
    var report: String?   // resolved report prefix/path (nil ⇒ discovery failed, caller fails loud)
    var policy: String?   // resolved policy path (nil ⇒ none configured)
    var strict = false
    var json = false
    var classFilter: String?  // ⟨0.20⟩ --class <c,…> reason-class drill-down (unverified)
}

// Parse the canonical grammar for a query verb, accepting the deprecated positional aliases.
//   canonical:  <verb> <verbArgs…> [--report <loc>] [--policy <file>] [--json] [--strict]
//   deprecated: <verb> <prefix> <verbArgs…> <policy> [--strict]   (leading-positional report + positional policy)
// `expectedVerbArgs` is how many leading positionals the verb takes AFTER the report (fix: 2, else 0).
// Extra trailing positionals map to the deprecated leading-report then positional-policy, in that order.
private func parseQueryArgs(_ args: [String], expectedVerbArgs: Int) -> QueryArgs {
    var q = QueryArgs()
    var reportFlag: String?
    var policyFlag: String?
    var positionals: [String] = []
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": q.json = true
        case "--strict": q.strict = true
        // SPEC §3.2 ⟨0.28⟩ (each value-taking flag below): "given no value" MEANS the next token is
        // flag-shaped, or the clause is unimplementable. This grammar used to consume the next token
        // UNCONDITIONALLY — "mirrors candor-java", and candor-java changed under it (ec3ffe1): a
        // written-down mirror of a sibling is not a measurement of it. Measured here 2026-08-12:
        // `unverified --policy --json` diagnosed *policy `--json` could not be read* — exit 2 with the
        // wrong cause, the operator's output flag read as a filename, the §6.2 silent reinterpretation
        // one position over. A bare `-` stays a value and fails loud downstream (an unreadable file /
        // an unknown class token); `./--weird` spells a file genuinely named like a flag.
        case "--report":
            guard let v = it.next() else { fixDie("candor-swift: --report requires a value") }
            guard v == "-" || !v.hasPrefix("-") else {
                fixDie("candor-swift: --report was given no value — the next token `\(v)` is a flag, "
                       + "not a locator (a path really named that is spelled ./\(v))")
            }
            reportFlag = v
        case "--policy":
            guard let v = it.next() else { fixDie("candor-swift: --policy requires a value") }
            guard v == "-" || !v.hasPrefix("-") else {
                fixDie("candor-swift: --policy was given no value — the next token `\(v)` is a flag, "
                       + "not a path (a file really named that is spelled ./\(v))")
            }
            policyFlag = v
        case "--class":
            guard let v = it.next() else {
                fixDie("candor-swift: --class requires a <class,…> value\n  accepted: \(CLASS_FILTER_TOKENS)")
            }
            guard v == "-" || !v.hasPrefix("-") else {
                fixDie("candor-swift: --class was given no value — the next token `\(v)` is a flag, "
                       + "not a <class,…> list")
            }
            // SPEC §6.2 ⟨0.24⟩: `--class` takes ONE comma-separated list and is NOT REPEATABLE — a second
            // occurrence is a usage error, not a union. Neither silent reading is safe: last-wins (what
            // this did) DROPS the first list, and a union would WIDEN past what the second flag asked
            // for. Both answer a different question than the line on screen, and on `unverified` a
            // quietly different question comes back as a quietly different NUMBER.
            if q.classFilter != nil {
                fixDie("candor-swift: --class given more than once — it takes ONE comma-separated list "
                       + "(`--class a,b`), not a repeated flag\n"
                       + "  a second occurrence is a usage error, not a union (SPEC §6.2 ⟨0.24⟩)")
            }
            q.classFilter = v
        default:
            if a == "--text" || a == "--human" { continue }  // candor-ts output-mode flags (#8); swift prose is the default — tolerate for cross-engine `candor <verb> --text`
            if a.hasPrefix("-") { fixDie("candor-swift: unknown flag \(a)") }
            positionals.append(a)
        }
    }

    // The verb's own positional args (fix's <fn> <Effect>) always come FIRST when supplied via flags.
    // In the deprecated form a leading report positional precedes them; the trailing positional is a policy.
    // Layout of `positionals` in the deprecated form: [<report>] <verbArgs…> [<policy>].
    //
    // ARITY-GATED, CONTENT-GATED peel (§3.3.1, aligned with candor-java):
    //   • The FIRST positional is claimed as the deprecated leading report ONLY when it actually resolves
    //     to a report (a dir, a `.json` file, or a prefix with sibling reports) — never a bare probe on
    //     count. So `fix <report.json> <fn> <Effect> <policy>` peels the report; `fix doNet Net policy.txt`
    //     leaves `doNet` as the fn and DISCOVERS the report. Ambiguity resolves toward the canonical
    //     (discovering) reading, never toward a silent misparse.
    //   • After that peel, any positional BEYOND the verb's canonical arity is the deprecated trailing
    //     policy. This is the surplus that distinguishes `fix doNet Net policy.txt` (surplus 1 → policy)
    //     from `fix doNet Net` (no surplus → discovered policy).
    var pos = positionals
    var deprecatedReport: String?
    var deprecatedPolicy: String?

    if reportFlag == nil, let first = pos.first, looksLikeReport(first) {
        // A leading positional that resolves to a report ⇒ deprecated leading-report. Consume it.
        deprecatedReport = pos.removeFirst()
    }
    // Take the verb's positional args off the front.
    if pos.count >= expectedVerbArgs {
        q.verbArgs = Array(pos.prefix(expectedVerbArgs))
        pos.removeFirst(expectedVerbArgs)
    } else {
        q.verbArgs = pos
        pos = []
    }
    // Any remaining trailing positional (a surplus beyond the verb's arity) is the deprecated policy.
    if policyFlag == nil, let last = pos.first { deprecatedPolicy = last }

    switch (deprecatedReport != nil, deprecatedPolicy != nil) {
    case (true, true):  noteDeprecated("a leading report prefix and a positional policy file")
    case (true, false): noteDeprecated("a leading report prefix")
    case (false, true): noteDeprecated("a positional policy file")
    case (false, false): break
    }

    // Resolve the report: --report flag → deprecated leading positional → discovery.
    if let r = reportFlag {
        q.report = resolveReportLocator(r)
    } else if let r = deprecatedReport {
        q.report = resolveReportLocator(r)
    } else {
        q.report = discoverReportPrefix()
    }
    // Resolve the policy: --policy flag → deprecated positional → CANDOR_POLICY / .candor/config.
    if let p = policyFlag {
        q.policy = p
    } else if let p = deprecatedPolicy {
        q.policy = p
    } else {
        q.policy = discoverPolicy()
    }
    return q
}

// Parse one `functions`-envelope report file into `out` for the `unverified` check. Returns false (with a
// stderr note) on an unparseable / non-report file — the caller fails loud, never an empty "no holes".
private func mergeUnverifiedReport(_ full: String, into out: inout [UnverifiedFn],
                                   completeness: inout ReportCompleteness) -> Bool {
    guard let data = FileManager.default.contents(atPath: full),
          let root = try? JSONSerialization.jsonObject(with: data),
          let obj = root as? [String: Any],
          let fns = obj["functions"] as? [[String: Any]] else {
        // ⟨0.28⟩ same as mergeFixReport's arm: the casualty is COUNTED, so `unverified` hedges (and
        // `--strict` refuses) rather than certifying the survivors as the whole universe.
        completeness.unreadable.append(full)
        FileHandle.standardError.write("candor-swift unverified: report `\(full)` could not be parsed — OMITTED, and this answer is reported INCOMPLETE (`gate --report` refuses over these bytes).\n".data(using: .utf8)!)
        return false
    }
    for e in fns {
        guard let fn = e["fn"] as? String, !fn.isEmpty else { continue }
        let inferred = Set((e["inferred"] as? [Any])?.compactMap { $0 as? String } ?? [])
        // `direct` + `calls` ride along for the ⟨0.24⟩ reason-class resolution (CandorCore.unverified):
        // the class of an INHERITED `Unknown` is at the callee, and only `direct` separates a function
        // that introduced an unrecorded `Unknown` from one that inherited a classified one. A report
        // predating either field loads it empty, which the resolution tolerates (it falls back to the
        // conservative `unresolved` for anything left unexplained) — never to a dropped hole.
        let direct = Set((e["direct"] as? [Any])?.compactMap { $0 as? String } ?? [])
        let why = (e["unknownWhy"] as? [Any])?.compactMap { $0 as? String } ?? []
        let calls = (e["calls"] as? [Any])?.compactMap { $0 as? String } ?? []
        // ⟨0.20⟩ and `netClass`, which cannot be derived from any of the above — see `FixFn.netClass`.
        // Without it a `deny Net[<dest>…]` layer that PASSES an Unknown-carrying function read as one
        // that denies it, and the hole went unnamed by the verb that exists to name it.
        let netClass = (e["netClass"] as? [Any])?.compactMap { $0 as? String } ?? []
        out.append(UnverifiedFn(fn: fn, inferred: inferred, direct: direct, unknownWhy: why,
                                calls: calls, netClass: netClass))
    }
    // ⟨0.21⟩ completeness manifest, ⟨0.24⟩ read HERE for the first time — see `ReportCompleteness`.
    // ⟨0.28⟩ …and its `analyzed.count: 0` row alongside it, from the SAME reader.
    mergeCompleteness(obj, path: full, entryCount: fns.count, into: &completeness)
    return true
}

// Load (fn, inferred, unknownWhy) from every `<prefix>*.Swift.json` report for the `unverified` check. As in
// loadFixModel, a `prefix` that is itself an existing regular `.json` file is loaded DIRECTLY (§3.3.1).
private func loadUnverifiedFns(prefix: String) -> (fns: [UnverifiedFn], completeness: ReportCompleteness)? {
    let fm = FileManager.default
    var out: [UnverifiedFn] = []
    var completeness = ReportCompleteness()
    var found = false

    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        found = mergeUnverifiedReport(prefix, into: &out, completeness: &completeness)
        return found ? (out, completeness) : nil
    }

    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    for name in entries.sorted() where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.json") {
        if mergeUnverifiedReport(dir + "/" + name, into: &out, completeness: &completeness) { found = true }
    }
    return found ? (out, completeness) : nil
}

// Dispatched from main.swift when argv[1] is `unverified`. §3.3.1 canonical grammar:
//   candor-swift unverified [--report <loc>] [--policy <file>] [--json] [--strict]
// (deprecated: `unverified <prefix> <policy> [--strict]`). JSON-only surface; `--strict` → exit 1 on a hole.
func runUnverifiedCLI(_ args: [String]) -> Never {
    let q = parseQueryArgs(args, expectedVerbArgs: 0)
    guard let policy = q.policy else {
        fixDie("usage: candor-swift unverified [--report <locator>] --policy <file> [--json] [--strict]")
    }
    guard let prefix = q.report else {
        fixDie("candor-swift unverified: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
    }
    let pol = loadPolicyOrDie(policy, who: "unverified")
    guard let loaded = loadUnverifiedFns(prefix: prefix) else {
        fixDie("candor-swift unverified: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
    }
    let fns = loaded.fns
    // §6.2 ⟨0.24⟩: an unrecognised token is a USAGE ERROR (exit 2) and NO answer is emitted — a narrower
    // result one exit code away from a refusal is the same fail-open in a different hat. See
    // `parseClassFilter` for why this half of the rule is not the policy side's drop-with-a-warning.
    let classFilter: Set<String>?
    do { classFilter = try parseClassFilter(q.classFilter) }
    catch let e as ClassFilterUsageError { fixDie(e.message) }
    catch { fixDie("candor-swift: --class could not be parsed: \(error)") }
    // ⟨0.28⟩ a zero-rule policy asked nothing — the caveat document, result keys withheld, exit
    // unchanged. AFTER the usage errors above (a bad --class refuses whatever the policy says), and a
    // no-op when any rule of any kind parsed.
    // ⟨0.32⟩ the unread-class cause, armed against THIS run's policy — see `armingUnread`. Computed
    // once and used by every channel below, so the document and the exit cannot disagree.
    let uvComp = armingUnread(loaded.completeness, under: pol)
    answerZeroRulePolicyWithCaveat(pol, at: policy, who: "unverified",
                                   completeness: uvComp, strict: q.strict)
    let (ok, holes, unansweredCore) = unverified(fns, pol.deny, classFilter: classFilter)
    // ⟨0.29⟩ …AND THE TWO WHOLE-POLICY KINDS, which this verb dropped at the call boundary: it hands
    // `pol.deny` to the core and `forbid`/`allow` never travelled. So a `forbid`-only policy produced
    // an EMPTY refusal set and the verb answered `{"ok": true, …}` at exit 0 — measured — over a
    // policy whose only rule nothing had evaluated. `gate --report` refused the same policy
    // correctly; the rule lived inline in the gate and its advisory siblings never saw it.
    // `fn: ""` because the kind is unanswerable over the whole report, not at one function.
    let unanswered = unansweredCore + wholePolicyRefusals(pol, policy)
        .map { UnansweredRule(rule: $0.rule, why: $0.why, fn: "", effect: "") }

    // ⟨0.24⟩ over a report declaring `unanalyzed`, `ok` is OMITTED — see `emitAdvisoryAnswer`. The holes
    // still ship: an unverified layer this report DID see is worth naming whether or not another file
    // went unread. Same for a rule the gate could not evaluate (§3.2): the holes ship, `unevaluated`
    // rides beside them, and `--strict` matches the gate's exit 2.
    emitAdvisoryAnswer(["unverified": holes.map { $0.toJSON() }],
                       ok: ok, completeness: uvComp, strict: q.strict,
                       unevaluated: unanswered)
}

// Dispatched from main.swift when argv[1] is `tour` (before the scan flag loop). §3.3.1 canonical grammar,
// like fix-gate but with an OPTIONAL positional integer N (default 10):
//   candor-swift tour [<N>] [--report <locator>] [--json]
// Read-only: lists the N most SURPRISING transitive reaches in an existing report — NO re-scan. Delegates to
// the SHARED CandorCore.bestFinds (the same heuristic the scan-note uses, so the ranking can't drift),
// reading the §2 report + its §2.2 callgraph sidecar the scan already wrote. Fails LOUD (exit 2) if no
// report resolves. Matches the Rust reference `candor-query tour` byte-for-byte (a conformance PART pins
// this four-way).
// The parsed `tour` invocation. Unlike the fix/fix-gate/unverified grammar (parseQueryArgs), `tour` has
// NO deprecated leading-report positional and NO policy: the single optional positional is N, and the
// report comes ONLY from --report/discovery. Kept separate so `tour <report.json>` can never be silently
// mis-read as a leading report with N defaulting to 10 — it is a non-integer positional → exit 2.
private struct TourArgs {
    var positional: String?   // the raw first positional (validated as N by the caller)
    var report: String?       // resolved report prefix/path (nil ⇒ discovery failed, caller fails loud)
    var json = false
}

// Parse `tour [<N>] [--report <locator>] [--json]`. Every positional is N (the caller validates it as a
// positive integer). A second positional, or `--policy`/`--strict`, is a usage error (exit 2) — `tour`
// takes neither. Mirrors the Rust reference: report from --report/discovery, N is the lone positional.
private func parseTourArgs(_ args: [String]) -> TourArgs {
    var t = TourArgs()
    var reportFlag: String?
    var positionals: [String] = []
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": t.json = true
        case "--report":
            // SPEC §3.2 ⟨0.28⟩ "given no value" — the parseQueryArgs rule, stated where its comment is.
            // Measured 2026-08-12: `tour --report --json` blamed a report named `--json`.
            guard let v = it.next() else { fixDie("candor-swift: --report requires a value") }
            guard v == "-" || !v.hasPrefix("-") else {
                fixDie("candor-swift: --report was given no value — the next token `\(v)` is a flag, "
                       + "not a locator (a path really named that is spelled ./\(v))")
            }
            reportFlag = v
        default:
            if a == "--text" || a == "--human" { continue }  // candor-ts output-mode flags (#8); swift prose is the default — tolerate for cross-engine `candor <verb> --text`
            if a.hasPrefix("-") { fixDie("candor-swift: unknown flag \(a)") }
            positionals.append(a)
        }
    }
    // At most ONE positional (N). A surplus positional is a usage error — never peeled as a report.
    if positionals.count > 1 {
        fixDie("usage: candor-swift tour [<N>] [--report <locator>] [--json]   (N is a positive integer ≥ 1)")
    }
    t.positional = positionals.first
    // Resolve the report: --report flag → discovery. NO positional report (tour's grammar divergence).
    t.report = reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()
    return t
}

// The report's `package` name (the §2 envelope field), or nil if absent/unreadable — the tour header
// prefers it (meaningful, locator-independent) over the prefix basename. Mirrors Rust's `report_package`:
// read the FIRST matching report for the prefix and return its non-empty `package`. A `packages` PLURAL
// envelope (the JVM shape, SPEC §2) is honoured too: one entry names it verbatim; several name their
// longest common dotted prefix (`com.a.x` + `com.a.y` → `com.a`); none shared → nil (basename fallback).
// Accepts a direct `.json` locator or a `<prefix>.<pkg>.Swift.json` family prefix.
private func reportPackage(prefix: String) -> String? {
    let fm = FileManager.default
    func packageOf(_ path: String) -> String? {
        guard let data = fm.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let pkg = obj["package"] as? String, !pkg.isEmpty { return pkg }
        if let pkgs = obj["packages"] as? [Any] {
            return packagesLabel(pkgs.compactMap { $0 as? String }.filter { !$0.isEmpty })
        }
        return nil
    }
    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        return packageOf(prefix)
    }
    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
    for name in entries.sorted()
    where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.json")
        && !name.hasSuffix(".callgraph.json") && !name.hasSuffix(".hierarchy.json") {
        if let pkg = packageOf(dir + "/" + name) { return pkg }
    }
    return nil
}

// The longest common dot-separated prefix of a plural `packages` list — whole segments only (`com.ab` +
// `com.ac` share `com`, not `com.a`); nil when nothing is shared. Mirrors Rust's packages_label (tour.rs).
private func packagesLabel(_ pkgs: [String]) -> String? {
    guard let head = pkgs.first else { return nil }
    if pkgs.count == 1 { return head }
    let first = head.split(separator: ".", omittingEmptySubsequences: false)
    var n = first.count
    for p in pkgs.dropFirst() {
        let segs = p.split(separator: ".", omittingEmptySubsequences: false)
        var i = 0
        while i < min(n, segs.count) && segs[i] == first[i] { i += 1 }
        n = i
        if n == 0 { return nil } // nothing shared — the basename fallback is more honest
    }
    return first[0..<n].joined(separator: ".")
}

func runTourCLI(_ args: [String]) -> Never {
    // §3.3.1 grammar for `tour`: the single optional positional is N (how many to list), and EVERY
    // positional is treated as N — there is NO deprecated leading-report positional (that is `tour`'s
    // grammar divergence from fix/fix-gate). A non-integer positional (INCLUDING a report path) or N < 1
    // is a usage error (exit 2). N must be a positive integer ≥ 1: `tour 0` would otherwise print a false
    // "nothing hidden" all-clear over an effectful crate (the §4 cardinal sin). The report comes ONLY from
    // `--report`/discovery. Matches the Rust reference `candor-query tour` byte-for-byte.
    let t = parseTourArgs(args)
    var n = 10
    if let first = t.positional {
        guard let v = Int(first), v >= 1 else {
            fixDie("usage: candor-swift tour [<N>] [--report <locator>] [--json]   (N is a positive integer ≥ 1)")
        }
        n = v
    }
    guard let prefix = t.report else {
        fixDie("candor-swift tour: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
    }
    // Load the report + callgraph the same way fix/fix-gate do (fail loud on a missing/typo'd report).
    guard let model = loadFixModel(prefix: prefix, who: "tour") else {
        fixDie("candor-swift tour: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
    }

    // Build the maps the heuristic wants from the report entries + the callgraph sidecar. `inferred`/`direct`/
    // `loc` come from the report; `calls` prefers the callgraph sidecar (loadFixModel already falls back to the
    // report's inline `calls` when the sidecar is absent), which records EVERY edge like the scan held in memory.
    var inferred: [String: Set<String>] = [:]
    var direct: [String: Set<String>] = [:]
    var loc: [String: String] = [:]
    for (fn, f) in model.byName {
        inferred[fn] = f.inferred
        if !f.direct.isEmpty { direct[fn] = f.direct }
        if !f.loc.isEmpty { loc[fn] = f.loc }
    }
    var calls: [String: Set<String>] = [:]
    for (k, v) in model.cg { calls[k] = Set(v) }

    let finds = bestFinds(inferred: inferred, direct: direct, calls: calls, loc: loc, n: n)

    // The header names the report's PACKAGE (the §2 envelope field) — meaningful and locator-independent,
    // so every engine and every --report form print the same crate (Rust: `report_package(pre)`). Falls
    // back to the prefix basename (Rust: `prefix_base(pre)`) — e.g. `.candor/report` → `report`.
    let crateName = reportPackage(prefix: prefix) ?? (prefix as NSString).lastPathComponent

    // ⟨0.28⟩ AND THE SAME ARGUMENT AS THE `unknown` FIELD BELOW, ONE CAUSE OVER. That field exists because
    // `{"reaches":[]}` read as clean to a JSON consumer over a mostly-Unknown graph; a report that judged
    // nothing, or one naming a file it could not read, produces the IDENTICAL empty array from strictly
    // less evidence — and the ⅓-Unknown threshold cannot see it (an unread unit contributes no entry, so
    // it moves neither `unknown` nor `total`). Same shape, same two channels, and a no-op on a complete
    // report so an ordinary tour stays byte-identical. See `ReportCompleteness`.
    let comp = model.completeness
    let tourSoWhat = "the reaches below are ranked over only the call graph candor could see"
    let tourTail = "A surprising reach whose path runs through an unread unit is not ranked here at all, "
                 + "and cannot be. \(comp.gateLine) Re-scan for the full tour."

    if t.json {
        // Pure JSON to stdout: {"reaches":[{"fn","effect","hops","source","loc","score"}, …]}.
        let reaches: [[String: Any]] = finds.map { f in
            ["fn": f.func_, "effect": f.effect, "hops": f.hops,
             "source": f.source, "loc": f.sourceLoc, "score": f.score]
        }
        // The MACHINE half of the mostly-Unknown disclosure (Fable-review finding E): a JSON consumer got a
        // bare {"reaches":[]} and read it as clean — the same false all-clear the text branch qualifies.
        // ADDITIVE + present only when the ≥⅓-Unknown threshold trips (byte-identical otherwise).
        let total = inferred.values.filter { !$0.isEmpty }.count
        let unknown = inferred.values.filter { $0.contains("Unknown") }.count
        emitTourJSON(reaches, unknown: (total > 0 && unknown * 3 >= total) ? (unknown, total) : nil,
                     completeness: comp)
        exit(0)
    }

    comp.printNote(so: tourSoWhat, tail: tourTail)
    if finds.isEmpty {
        // Effectful-but-nothing-surprising vs genuinely-pure both land here; either way the honest line is
        // the useful answer (never a manufactured surprise) — mirrors the scan-note fallback. BUT never
        // reassure "nothing hidden" over a meaningfully-Unknown graph: the Unknowns ARE the hidden part
        // (re-audit cardinal sin; four-way with candor-ts/rust/java). ≥⅓ effectful Unknown → qualify.
        let total = inferred.values.filter { !$0.isEmpty }.count
        let unknown = inferred.values.filter { $0.contains("Unknown") }.count
        if total > 0 && unknown * 3 >= total {
            print("candor: no surprising reaches — but \(unknown) of \(total) function(s) are Unknown (unresolved calls; their transitive effects are NOT analyzed). Run `candor blindspots` — the report records a reason for each.")
            exit(0)
        }
        // ⟨0.28⟩ "nothing hidden" is the single most reassuring sentence this binary prints, and over a
        // report that judged nothing it is the false all-clear in plain English. The ⅓-Unknown branch
        // above cannot catch this case, for the reason given where `comp` is read.
        if comp.mustHedge {
            print("candor: nothing hidden in what candor COULD SEE — but see the INCOMPLETE note above; this is NOT \"nothing is hidden\".")
            exit(0)
        }
        print("candor: nothing hidden — every effect sits where its name says it should.")
        exit(0)
    }
    let reachWord = finds.count == 1 ? "reach" : "reaches"
    print("candor tour — the \(finds.count) most surprising \(reachWord) in \(crateName):")
    for (i, f) in finds.enumerated() {
        let hopWord = f.hops == 1 ? "hop" : "hops"
        let whereS = f.sourceLoc.isEmpty ? "" : " (\(f.sourceLoc))"
        print("  \(i + 1). `\(f.func_)` performs \(f.effect), \(f.hops) \(hopWord) away via `\(f.source)`\(whereS)")
        print("     →  candor path \(f.func_) \(f.effect)")
    }
    exit(0)
}

// Serialize the tour `--json` payload to STDOUT as COMPACT JSON (one line), matching the Rust reference's
// `serde_json::to_string(&json!({ "reaches": … }))` BYTE-FOR-BYTE. The reference wraps the reaches in a
// `serde_json::Value`, whose object is a sorted map, so each reach's keys come out ALPHABETICALLY sorted:
// effect, fn, hops, loc, score, source. Built by hand (JSONSerialization neither guarantees key order nor a
// compact form), so this is emitted explicitly rather than via JSONSerialization.
private func emitTourJSON(_ reaches: [[String: Any]], unknown: (count: Int, total: Int)? = nil,
                          completeness comp: ReportCompleteness = ReportCompleteness()) {
    func jstr(_ s: String) -> String {
        // Minimal JSON string escaping (the fields are qualified names / effects / file:line — no control
        // chars in practice, but escape the JSON-significant characters for correctness).
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }
    var parts: [String] = []
    for r in reaches {
        let fn = r["fn"] as? String ?? ""
        let effect = r["effect"] as? String ?? ""
        let hops = r["hops"] as? Int ?? 0
        let source = r["source"] as? String ?? ""
        let loc = r["loc"] as? String ?? ""
        let score = r["score"] as? Int ?? 0
        // Keys ALPHABETICAL to match serde_json::Value's sorted-map output: effect, fn, hops, loc, score, source.
        parts.append("{\"effect\":\(jstr(effect)),\"fn\":\(jstr(fn)),\"hops\":\(hops),\"loc\":\(jstr(loc)),\"score\":\(score),\"source\":\(jstr(source))}")
    }
    // `unknown` (when present) sorts AFTER `reaches` (reaches < unknown) with count < total — matching the
    // Rust reference's serde sorted-map output byte-for-byte (Fable-review finding E, additive disclosure).
    let unknownPart = unknown.map { ",\"unknown\":{\"count\":\($0.count),\"total\":\($0.total)}" } ?? ""
    // ⟨0.28⟩ the completeness disclosure, in the SAME sorted-map positions the Rust reference emits it:
    // `incomplete` and `judgedNothing` sort BEFORE `reaches`, `unanalyzed` after it and before `unknown`.
    // Empty on a complete report, so an ordinary tour is byte-identical to the pre-⟨0.28⟩ one — this file
    // hand-builds its JSON precisely because key ORDER is the pinned four-way contract here, and a
    // disclosure rung that silently re-sorts the answers it is disclosing about has changed the one thing
    // it promised not to touch.
    var head = ""
    var unanalyzedPart = ""
    if comp.mustHedge {
        head = "\"incomplete\":true,"
        if !comp.judgedNothing.isEmpty {
            head += "\"judgedNothing\":[" + comp.judgedNothing.map(jstr).joined(separator: ",") + "],"
        }
        // ⟨0.28⟩ SPEC §2 row 3. `noManifest` also sorts BEFORE `reaches` (n < r), between `judgedNothing`
        // and it (j < n), which is where the reference's sorted-map serialiser puts it — this file
        // hand-builds its JSON precisely because that order is the pinned four-way contract.
        if !comp.noManifest.isEmpty {
            head += "\"noManifest\":[" + comp.noManifest.map(jstr).joined(separator: ",") + "],"
        }
        if !comp.unanalyzed.isEmpty {
            unanalyzedPart = ",\"unanalyzed\":["
                + comp.unanalyzed.map { "{\"path\":\(jstr($0.path)),\"reason\":\(jstr($0.reason))}" }
                    .joined(separator: ",")
                + "]"
        }
    }
    print("{\(head)\"reaches\":[\(parts.joined(separator: ","))]\(unanalyzedPart)\(unknownPart)}")
}

// Dispatched from main.swift when argv[1] is `fix` or `fix-gate` (before the scan flag loop). §3.3.1:
//   candor-swift fix <fn> <Effect> [--report <loc>] [--policy <file>] [--json]
//   candor-swift fix-gate          [--report <loc>] [--policy <file>] [--json]
// (deprecated: `fix <prefix> <fn> <Effect> <policy>`, `fix-gate <prefix> <policy>`).
func runFixCLI(_ args: [String]) -> Never {
    let cmd = args[1]
    if cmd == "fix" {
        let q = parseQueryArgs(args, expectedVerbArgs: 2)
        guard q.verbArgs.count == 2 else {
            fixDie("usage: candor-swift fix <fn> <Effect> [--report <locator>] --policy <file> [--json]")
        }
        let (target, effect) = (q.verbArgs[0], q.verbArgs[1])
        guard let policy = q.policy else {
            fixDie("usage: candor-swift fix <fn> <Effect> [--report <locator>] --policy <file> [--json]")
        }
        guard let prefix = q.report else {
            fixDie("candor-swift fix: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
        }
        let fixPol = loadPolicyOrDie(policy, who: "fix")
        let deny = fixPol.deny
        guard let model = loadFixModel(prefix: prefix, who: "fix") else {
            fixDie("candor-swift fix: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
        }
        // ⟨0.28⟩ THE COMMENT SAID `fix` INHERITED THE COMPLETENESS READING, AND IT DID NOT. The loader
        // threads the struct into `model.completeness` and this verb never read it — measured, over a
        // report declaring `unanalyzed`, `fix a Fs --json` answered `{"crossing": false, …}` flat on
        // both channels. Every answer below is a claim over the report (`crossing: false` rests on an
        // effect set a callee in an unread file contributes nothing to; a hoist plan names CALLERS, and
        // a caller in an unread file is invisible to it), so the disclosure reaches all three documents
        // and the note goes to STDERR — stdout always carries a document on this verb. The reference's
        // `cmd_fix` does exactly this (`warn_unreadable("fix")` + `write_json` on each branch); the
        // exit code stays 0, for its reason: this verb answers no `ok` for `--strict` to follow.
        // ⟨0.32⟩ …and the unread-class cause, armed against this verb's own policy (`armingUnread`).
        let comp = armingUnread(model.completeness, under: fixPol)
        // ⟨0.28⟩ Phase 1b: `fix` TAKES THE ZERO-RULE WITHHOLDING TOO. The doc on
        // `answerZeroRulePolicyWithCaveat` used to say this verb was deliberately NOT routed here,
        // because SPEC named three verbs and extending it unasked would be "a one-engine guess of
        // exactly the kind judgedNothing's boolean was". That reasoning was right and the premise
        // expired: SPEC §2 ⟨0.28⟩ now states the rule over the CONDITION — every verb answering
        // relative to a CONFIGURED policy — and records that naming three verbs instead of the
        // condition is what split rust (which extended it) from this engine (which did not).
        // Measured here before the change: `{"crossing": false, "reason": "not-forbidden"}` at exit 0,
        // and not-forbidden BY A POLICY THAT FORBIDS NOTHING is vacuously true. Composed with the
        // `crossing` ruling (§6.1: present exactly when the verb ANSWERED) the key is absent here,
        // which the caveat document gives for free by carrying no result keys at all.
        answerZeroRulePolicyWithCaveat(fixPol, at: policy, who: "fix", completeness: comp, strict: false)
        comp.eprintNote(so: "any remedy below is computed over a universe candor cannot fully see",
                        tail: "A callee in one of those contributes no effect here, and a caller in one "
                            + "is invisible to the hoist. \(comp.gateLine) Re-scan for a complete answer.")
        switch fix(target: target, effect: effect, byName: model.byName, cg: model.cg, deny: deny) {
        case .noSuchFn:
            fixDie("candor-swift fix: no function matching `\(target)`")
        case let .notACrossing(fn, eff, reason, unanswered):
            // ⟨0.24⟩ `crossing:false` IS a claim, so the §3.2 disclosure rides it — see `CandorCore.fix`.
            var out: [String: Any] = ["fn": fn, "effect": eff, "crossing": false, "reason": reason]
            if !unanswered.isEmpty { out["unevaluated"] = unanswered.map { $0.toJSON() } }
            for (k, v) in comp.disclosureJSON { out[k] = v }
            emitJSON(out)
            exit(0)
        case let .unanswerable(fn, eff, crossing, unanswered):
            // ⟨0.24⟩ `crossing` is OMITTED when the gate could not decide it — the same reasoning that
            // omits `ok` on the array verbs, and for the same reason: a boolean nobody derived is worse
            // than an absent key a consumer must handle. It IS present, and `true`, when the crossing
            // was decided and only the hoist plan was withheld.
            var out: [String: Any] = ["fn": fn, "effect": eff, "reason": "unanswerable"]
            if let c = crossing { out["crossing"] = c }
            out["unevaluated"] = unanswered.map { $0.toJSON() }
            for (k, v) in comp.disclosureJSON { out[k] = v }
            emitJSON(out)
            exit(0)
        case let .remedy(r, unanswered):
            var out = r.toJSON()
            out["crossing"] = true
            if !unanswered.isEmpty { out["unevaluated"] = unanswered.map { $0.toJSON() } }
            for (k, v) in comp.disclosureJSON { out[k] = v }
            emitJSON(out)
            exit(0)
        }
    } else { // fix-gate
        let q = parseQueryArgs(args, expectedVerbArgs: 0)
        guard let policy = q.policy else {
            fixDie("usage: candor-swift fix-gate [--report <locator>] --policy <file> [--json]")
        }
        guard let prefix = q.report else {
            fixDie("candor-swift fix-gate: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
        }
        let pol = loadPolicyOrDie(policy, who: "fix-gate")
        guard let model = loadFixModel(prefix: prefix, who: "fix-gate") else {
            fixDie("candor-swift fix-gate: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
        }
        // ⟨0.28⟩ a zero-rule policy asked nothing — the caveat document, result keys withheld, exit
        // unchanged. No-op when any rule of any kind parsed.
        // ⟨0.32⟩ the unread-class cause, armed against THIS run's policy — see `armingUnread`. One
        // value for the caveat, the document and the exit, so the three cannot disagree about a run.
        let fgComp = armingUnread(model.completeness, under: pol)
        answerZeroRulePolicyWithCaveat(pol, at: policy, who: "fix-gate",
                                       completeness: fgComp, strict: q.strict)
        let (ok, remedies, unansweredCore) = fixGate(byName: model.byName, cg: model.cg, deny: pol.deny)
        // ⟨0.29⟩ …AND THE TWO WHOLE-POLICY KINDS, which this verb dropped at the call boundary: it hands
        // `pol.deny` to the core and `forbid`/`allow` never travelled. So a `forbid`-only policy produced
        // an EMPTY refusal set and the verb answered `{"ok": true, …}` at exit 0 — measured — over a
        // policy whose only rule nothing had evaluated. `gate --report` refused the same policy
        // correctly; the rule lived inline in the gate and its advisory siblings never saw it.
        // `fn: ""` because the kind is unanswerable over the whole report, not at one function.
        let unanswered = unansweredCore + wholePolicyRefusals(pol, policy)
            .map { UnansweredRule(rule: $0.rule, why: $0.why, fn: "", effect: "") }

        // Advisory by default (exit 0 — the agent fix-loop reads the remedy and edits); `--strict` makes the
        // exit follow `ok`, so CI can REQUIRE zero outstanding crossings (mirrors `unverified --strict`).
        // ⟨0.24⟩ …and over a report declaring `unanalyzed`, `ok` is OMITTED and `--strict` exits 2 — see
        // `emitAdvisoryAnswer`. The remedies still ship: a crossing this report DID see needs the same
        // hoist whether or not another file went unread.
        emitAdvisoryAnswer(["remedies": remedies.map { $0.toJSON() }],
                           ok: ok, completeness: fgComp, strict: q.strict,
                           unevaluated: unanswered)
    }
}

// ── `path <fn> <Effect>` (SPEC §3.1) ────────────────────────────────────────────────────────────────
// The read-only query the scan-note / `tour` opener names as its ready-to-run follow-up: trace the call
// chain by which `<fn>` comes to perform `<Effect>`, from the function down to the nearest DIRECT source.
// NO policy — it is a pure structural read over the report graph. Report from --report/discovery, `--json`
// for the §3.1 pinned shape. Byte-for-byte the Rust reference `candor-query path` (callers.rs::cmd_path),
// which conformance PART 5 pins four-way. Fails LOUD (exit 2) on a missing report / an unmatched fn.

// The parsed `path` invocation: two leading positionals (<fn> <Effect>), a report from --report/discovery,
// `--json`. Like `tour`, there is NO deprecated leading-report positional and NO policy — the report comes
// ONLY from --report/discovery, so a report path can never be silently mis-read as the <fn> positional.
private struct PathArgs {
    var positionals: [String] = []   // [<fn>, <Effect>]
    var report: String?              // resolved report prefix/path (nil ⇒ discovery failed, caller fails loud)
    var json = false
}

// Parse `path <fn> <Effect> [--report <locator>] [--json]`. Exactly TWO positionals are required; a
// surplus positional, or `--policy`/`--strict`, is a usage error (exit 2). Mirrors the Rust reference's
// `Shape { verb_args: 2, has_policy: false }`: report from --report/discovery, the two positionals are
// <fn> and <Effect>.
private func parsePathArgs(_ args: [String]) -> PathArgs {
    var p = PathArgs()
    var reportFlag: String?
    var positionals: [String] = []
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": p.json = true
        case "--report":
            // SPEC §3.2 ⟨0.28⟩ "given no value" — the parseQueryArgs rule, stated where its comment is.
            // Measured 2026-08-12: `path f Net --report --json` blamed a report named `--json`.
            guard let v = it.next() else { fixDie("candor-swift: --report requires a value") }
            guard v == "-" || !v.hasPrefix("-") else {
                fixDie("candor-swift: --report was given no value — the next token `\(v)` is a flag, "
                       + "not a locator (a path really named that is spelled ./\(v))")
            }
            reportFlag = v
        default:
            if a == "--text" || a == "--human" { continue }  // candor-ts output-mode flags (#8); swift prose is the default — tolerate for cross-engine `candor <verb> --text`
            if a.hasPrefix("-") { fixDie("candor-swift: unknown flag \(a)") }
            positionals.append(a)
        }
    }
    p.positionals = positionals
    // Resolve the report: --report flag → discovery. NO positional report (like `tour`).
    p.report = reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()
    return p
}

// Dispatched from main.swift when argv[1] is `path`. Loads the report + callgraph the same way fix/tour do,
// resolves `<fn>` by exact-then-substring match (like the Rust reference), then BFS through the effect-
// carrying call graph to the nearest DIRECT source, recording the chain.
func runPathCLI(_ args: [String]) -> Never {
    let p = parsePathArgs(args)
    guard p.positionals.count == 2 else {
        fixDie("usage: candor-swift path <fn-substring> <Effect> [--report <locator>] [--json]")
    }
    let (fnArg, effect) = (p.positionals[0], p.positionals[1])
    guard let prefix = p.report else {
        fixDie("candor-swift path: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
    }
    guard let model = loadFixModel(prefix: prefix, who: "path") else {
        fixDie("candor-swift path: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
    }
    // A TYPO'D EFFECT NAME IS A LOUD ERROR. Before this, `path caller Fsz` printed
    // "caller does not perform Fsz  (inferred: [\"Fs\"])" and exited 0 — a typo scored as a confident
    // NEGATIVE, in the verb people reach for to check one specific claim. The other engines grew this
    // guard on `where` after the corpus audit and never grew it on `path`; this engine ships no `where`
    // at all, so `path` is the only place it can live here.
    //
    // A KNOWN effect that is simply absent stays a legitimate negative answer, and an unknown name that
    // is PRESENT in the report (a spec extension effect from another engine) is allowed — error only
    // when the name is NEITHER known NOR present.
    let knownEffects = ["Net", "Fs", "Db", "Llm", "Exec", "Env", "Clock", "Ipc", "Log", "Rand",
                        "Clipboard", "Unknown"]
    if !knownEffects.contains(effect)
        && !model.byName.values.contains(where: { $0.inferred.contains(effect) }) {
        fixDie("candor-swift path: unknown effect `\(effect)` (known: \(knownEffects.joined(separator: ", ")))")
    }
    let byName = model.byName
    let cg = model.cg

    // ⟨0.28⟩ SPEC §2 binds the re-disclosure to *any* verb whose output could read as a NEGATIVE FINDING —
    // "a verdict, an empty result set, or a zero count" — and `path` has TWO empty-result answers, both
    // phrased as facts about the code: `{"fn":…,"effect":…,"path":[]}`, printed as *"X does not perform
    // E"* and *"…not statically traceable"*. Over a report naming source it could not read, neither is
    // supportable: the chain that would have answered may run through a function that is simply absent
    // from the report. Over an ARMED / count-0 report `path` already refuses at exit 2 (no fn matches),
    // which is why this is the PARTIAL report's case. Same struct, same two channels, no-op when complete.
    //
    // The note is printed BEFORE the answer and on EVERY branch, not just the empty ones: an unread unit
    // qualifies a chain that WAS found as much as one that was not — the chain may not be the shortest,
    // and its `source` may not be the nearest.
    let comp = model.completeness
    let pathSoWhat = "the call chain below is traced through only the call graph candor could see"
    let pathTail = "A function in an unread unit is ABSENT from the report, so no chain can be traced "
                 + "through it and none can be ruled out. \(comp.gateLine) Re-scan for a complete answer."

    // Resolve <fn>: EXACT name first, else the first (deterministic) fn whose qual CONTAINS the substring —
    // mirrors the Rust reference (`find(func == arg).or_else(find(func.contains(arg)))`). Sorted so the
    // substring fallback is stable across dictionary orderings.
    let names = byName.keys.sorted()
    let startName = names.first { $0 == fnArg } ?? names.first { $0.contains(fnArg) }
    guard let start = startName else {
        // Fail loud (exit 2) on an unmatched fn — never a silently-empty answer (matches the family).
        fixDie("candor-swift path: no function matching '\(fnArg)'")
    }
    let startFn = byName[start]!

    // ⟨0.28⟩ ONE attachment point for the machine half, so the three `path` documents cannot drift into
    // three different manifests. `disclosureJSON` is EMPTY on a complete report and `emitJSON` sorts its
    // keys, so an ordinary run is byte-identical.
    func emitPathJSON(_ steps: [[String: Any]]) {
        var out: [String: Any] = ["fn": start, "effect": effect, "path": steps]
        for (k, v) in comp.disclosureJSON { out[k] = v }
        emitJSON(out)
    }
    // …and one for the human half, BEFORE any answer reaches stdout. The `--json` branches below exit
    // before this could matter; they carry the keys instead.
    if !p.json { comp.printNote(so: pathSoWhat, tail: pathTail) }

    // The honest empty answer (NOT an error): the fn does not carry the effect at all. In --json mode emit
    // the pinned {effect,fn,path:[]} object (a `jq` consumer would choke on human text on stdout); in human
    // mode name it, matching the Rust wording, including the sorted inferred set for context.
    if !startFn.inferred.contains(effect) {
        if p.json {
            emitPathJSON([])
        } else {
            let inf = "[" + startFn.inferred.sorted().map { "\"\($0)\"" }.joined(separator: ", ") + "]"
            // ⟨0.28⟩ NOT the bare "does not perform" over a partial report: that sentence is the prose
            // spelling of the empty `path` array, and it is a claim about the whole function, which is
            // more than the report candor was handed can support.
            if comp.mustHedge {
                print("\(start) does not perform \(effect) in what candor COULD SEE  (inferred: \(inf))"
                    + " — but see the INCOMPLETE note above; this is NOT \"\(start) never performs \(effect)\".")
            } else {
                print("\(start) does not perform \(effect)  (inferred: \(inf))")
            }
        }
        exit(0)
    }

    // BFS through effect-carrying callees to the FIRST fn with the effect in its DIRECT set (the nearest
    // local source). Traverse only through callees that transitively carry the effect (inferred), so the
    // frontier stays on-effect — matches the scan-note's `nearestSource` and the Rust reference.
    // `prev[x]` = the predecessor on the BFS tree; the start maps to "" (no predecessor — reconstruction
    // stops there). A key's PRESENCE marks "visited", so the start is seeded before the walk.
    var prev: [String: String] = [start: ""]
    var queue: [String] = [start]
    var head = 0
    var source: String?
    while head < queue.count {
        let cur = queue[head]; head += 1
        guard let f = byName[cur] else { continue }
        if f.direct.contains(effect) { source = cur; break }
        // Deterministic frontier order (sorted) so BFS-distance ties resolve identically across engines.
        for c in (cg[cur] ?? []).sorted() where prev[c] == nil {
            if let cf = byName[c], cf.inferred.contains(effect) {
                prev[c] = cur
                queue.append(c)
            }
        }
    }

    guard let src = source else {
        // Reached via a cross-package call / Unknown — the honest empty-path answer (§3.1), not an error.
        if p.json {
            emitPathJSON([])
        } else {
            // ⟨0.28⟩ "not statically traceable" reads as a property of the CODE; over a partial report it
            // may only be a property of what was read, and the difference is the whole point of the note.
            print("\(start) performs \(effect) but its source is not a local function "
                + "(cross-crate, or via Unknown) — not statically traceable"
                + (comp.mustHedge ? " in what candor could see (see the INCOMPLETE note above)." : "."))
        }
        exit(0)
    }

    // Reconstruct the chain start → … → source.
    var chain: [String] = []
    var n = src
    while !n.isEmpty {
        chain.append(n)
        n = prev[n] ?? ""
    }
    chain.reverse()

    if p.json {
        let steps: [[String: Any]] = chain.enumerated().map { (i, name) in
            ["fn": name, "loc": byName[name]?.loc ?? "", "source": i == chain.count - 1]
        }
        emitPathJSON(steps)
        exit(0)
    }

    // HUMAN: header, then the chain — each step indented one deeper (2 spaces per level, from level 1), the
    // source step tagged `[<Effect> source @ file:line]` (or `[<Effect> source]` when loc is absent).
    print("candor path — how `\(start)` comes to perform \(effect):\n")
    for (i, name) in chain.enumerated() {
        let indent = String(repeating: "  ", count: i + 1)
        let arrow = i == 0 ? "" : "→ "
        var tag = ""
        if i == chain.count - 1 {
            let loc = byName[name]?.loc ?? ""
            tag = loc.isEmpty ? "   [\(effect) source]" : "   [\(effect) source @ \(loc)]"
        }
        print("\(indent)\(arrow)\(name)\(tag)")
    }
    exit(0)
}

// ── `gains <current> <baseline> [--json]` (SPEC §5.1) ──────────────────────────────────────────────
// The package-level SUPPLY-CHAIN alarm: every `<fn>\t<effect>` the surface GAINED between two reports
// (current `inferred` minus baseline `inferred`, per fn), sorted. The two-positional comparative verb
// (the family's §3.3.1 exception, like `diff`): both positionals ARE report locators, each resolved by
// the shared 3-way rule — NO discovery, NO --report, NO policy. Read-only over reports scans already
// wrote. Mirrors the Rust reference `candor-query gains` (diff.rs::cmd_gains): the default output is the
// `fn\teffect` TSV, `--json` the {byFunction, gained} machine form a CI gate can alarm on when a
// dependency update quietly gains a capability.

// Parse one report into `inferredByFn`, UNIONING on a name collision — two sibling reports can render
// a function with the same printed name, and an overwrite would drop one sibling's effects, so a
// newly-gained Net could silently VANISH from `gains` (a supply-chain miss; mirrors the Rust reference
// load_fninfo's union-not-overwrite rule). Accepts BOTH the §2 `{candor, functions}` envelope and the
// legacy v0.1 bare-array form (the migration contract the Rust reference's report_entries honors — a
// bare `[]` is a VALID clean-empty report the whole family answers on, not a parse failure). Returns
// false (with a stderr note naming the CONSEQUENCE — the file's functions are omitted, so the delta may
// under- or over-report) on an unparseable / non-report file — the caller applies the net rule, never a
// silently-empty "no gains". A NON-EMPTY entries array in which EVERY entry is unusable (no `fn`) is
// the same failure, not an empty report: treating it as parsed would print {byFunction:[],gained:[]}
// at exit 0 over a corrupt current — the false all-clear a gate silently PASSES on (the §4 cardinal sin).
// A PARTIAL drop (some entries junk, some usable) is DISCLOSED with a count and tolerated — the Rust
// reference load_entries_inner's rule (load.rs): a dropped entry is the same under-report as a dropped
// file, so it must never silently vanish (and read as pure) from the merged answer.
private func mergeInferredReport(_ full: String, into inferredByFn: inout [String: Set<String>]) -> Bool {
    let entries: [Any]
    guard let data = FileManager.default.contents(atPath: full) else {
        FileHandle.standardError.write("candor-swift gains: report `\(full)` could not be read — its functions are OMITTED from this gains answer, so the delta may under- or over-report.\n".data(using: .utf8)!)
        return false
    }
    if let root = try? JSONSerialization.jsonObject(with: data) {
        if let obj = root as? [String: Any], let fns = obj["functions"] as? [Any] {
            entries = fns                     // the §2 envelope
        } else if let arr = root as? [Any] {
            entries = arr                     // the legacy bare-array report
        } else {
            FileHandle.standardError.write("candor-swift gains: report `\(full)` failed to parse — its functions are OMITTED from this gains answer, so the delta may under- or over-report (corrupt or mid-write); re-run the scan.\n".data(using: .utf8)!)
            return false
        }
    } else {
        FileHandle.standardError.write("candor-swift gains: report `\(full)` failed to parse — its functions are OMITTED from this gains answer, so the delta may under- or over-report (corrupt or mid-write); re-run the scan.\n".data(using: .utf8)!)
        return false
    }
    var usable = 0
    var dropped = 0
    for e in entries {
        guard let d = e as? [String: Any], let fn = d["fn"] as? String, !fn.isEmpty else {
            dropped += 1
            continue
        }
        let inferred = Set((d["inferred"] as? [Any])?.compactMap { $0 as? String } ?? [])
        inferredByFn[fn, default: []].formUnion(inferred)
        usable += 1
    }
    if !entries.isEmpty && usable == 0 {
        // A well-formed EMPTY functions array is a valid pure report; a non-empty one that yields
        // ZERO usable entries is semantic corruption — fail loud, never an all-clear.
        FileHandle.standardError.write("candor-swift gains: report `\(full)` has no usable functions — every entry was dropped (corrupt report); its functions are OMITTED from this gains answer, so the delta may under- or over-report; re-run the scan.\n".data(using: .utf8)!)
        return false
    }
    if dropped > 0 {
        // A per-entry drop is the same under-report as a whole-file failure — disclose the count,
        // never let a corrupt function silently vanish (and read as pure) from the merged answer.
        FileHandle.standardError.write(
            "candor-swift gains: report `\(full)` — \(dropped) function entr\(dropped == 1 ? "y" : "ies") could not be parsed and \(dropped == 1 ? "is" : "are") OMITTED from this gains answer (corrupt or mid-write); re-run the scan.\n"
                .data(using: .utf8)!)
    }
    return true
}

// Load fn → inferred effects for every `<prefix>*.Swift.json` report (merging siblings). As in
// loadFixModel, a `prefix` that is itself an existing regular `.json` file is loaded DIRECTLY (§3.3.1).
// Returns the merged map PLUS the file accounting the caller's net rule needs — the Rust reference
// load_entries_inner's `hard_fail` bit (load.rs), generalized to a count so a PARTIAL merge is
// distinguishable: filesFound (matched report files) and hardFails (files that wholly failed to read /
// parse, or parsed to zero usable entries while non-empty). One corrupt file among valid siblings is
// disclosed-and-tolerated (mergeInferredReport's stderr note; the valid siblings still merge — the Rust
// rule, NOT a hard fail); the NET verdict is the caller's (loadInferredLoud below).
private struct InferredLoad {
    var byFn: [String: Set<String>] = [:]
    var filesFound = 0
    var hardFails = 0
}

private func loadInferredByFn(prefix: String) -> InferredLoad {
    let fm = FileManager.default
    var load = InferredLoad()

    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        load.filesFound = 1
        if !mergeInferredReport(prefix, into: &load.byFn) { load.hardFails = 1 }
        return load
    }

    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return load }
    for name in entries.sorted() where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.json") {
        load.filesFound += 1
        if !mergeInferredReport(dir + "/" + name, into: &load.byFn) { load.hardFails += 1 }
    }
    return load
}

// The LOUD wrapper — the Rust reference load_fninfo_loud's net rule (diff.rs), applied per side:
//   no files found            → exit 2 ("check the path" — a typo'd locator must never read as an
//                               empty surface; a typo'd current shows zero gains, a typo'd baseline
//                               shows every effect as newly gained);
//   NET-EMPTY after any hard  → exit 2 — every found report failed to load, and printing
//   failure                     {byFunction:[],gained:[]} over corrupt input is the §4 cardinal-sin
//                               false all-clear (a CLEAN-empty valid report stays a non-fatal empty);
//   PARTIAL merge (some       → tolerated, but SUMMARIZED on stderr: the per-file OMITTED notes name
//   siblings failed, some       each casualty, this line names the NET consequence — the delta is
//   answered)                   computed over a partial surface, so gains may under- or over-report.
private func loadInferredLoud(prefix: String, which: String) -> [String: Set<String>] {
    let load = loadInferredByFn(prefix: prefix)
    if load.filesFound == 0 {
        fixDie("candor-swift gains: no report files at \(which) prefix `\(prefix)` — check the path.")
    }
    if load.byFn.isEmpty && load.hardFails > 0 {
        fixDie("candor-swift gains: every report found at \(which) prefix `\(prefix)` failed to load — refusing to report an empty (all-clear) answer over a corrupt report; re-run the scan.")
    }
    if load.filesFound > 1 && load.hardFails > 0 {
        FileHandle.standardError.write(
            "candor-swift gains: \(load.hardFails) of \(load.filesFound) \(which) reports failed to load — the delta is computed over a PARTIAL \(which).\n"
                .data(using: .utf8)!)
    }
    return load.byFn
}

// The BASELINE callgraph for `origin` — SIDECAR-ONLY, deliberately NOT loadFixModel's inline-`calls`
// fallback: `origin` keys "did this fn exist at the baseline" on the baseline GRAPH, and the inline
// calls of the (effectful-only) report entries are an INCOMPLETE graph — a baseline-PURE fn is absent
// from it, so the fallback would mark an EXISTING fn "new" and downgrade the supply-chain alarm to a
// feature (a silent under-report). An absent sidecar stays an EMPTY graph → "unknown" (the JSON itself
// discloses); a MATCHED sidecar that fails to read/parse keeps mergeCallgraph's stderr disclosure AND
// flips `partial` — the merged graph is missing that file's nodes, so a fn absent from it is NOT
// provably "new" (origin degrades to "unknown", never a mislabel). Absent ≠ partial. Mirrors the Rust
// reference load_callgraph (sidecars only).
private func loadCallgraphSidecars(prefix: String) -> (cg: [String: [String]], partial: Bool) {
    let fm = FileManager.default
    var cg: [String: [String]] = [:]
    var partial = false

    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        let sidecar = ((prefix as NSString).deletingPathExtension) + ".callgraph.json"
        if fm.fileExists(atPath: sidecar), !mergeCallgraph(sidecar, into: &cg) { partial = true }
        return (cg, partial)
    }

    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return (cg, partial) }
    for name in entries.sorted() where name.hasPrefix(base + ".") && name.hasSuffix(".Swift.callgraph.json") {
        if !mergeCallgraph(dir + "/" + name, into: &cg) { partial = true }
    }
    return (cg, partial)
}

// The report FILES under one gains locator, by the §3.3.1 3-way rule the loaders above apply: a `prefix`
// that is ITSELF an existing regular `.json` file IS the one report; otherwise every
// `<prefix>.*.Swift.json` sibling in its directory, in name order.
//
// ONE walk for the three ENVELOPE riders — the producing version, the ⟨0.15⟩ coverage ledger and the
// ⟨0.21⟩ completeness manifest. They had a copy each, and a rider walking a different file set than the
// one whose delta is being printed would disclose about reports the answer did not come from (and, worse,
// stay SILENT about one it did). The `functions` loaders keep their own walk: theirs merges and counts.
private func gainsReportFiles(prefix: String) -> [String] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if prefix.hasSuffix(".json"), fm.fileExists(atPath: prefix, isDirectory: &isDir), !isDir.boolValue {
        return [prefix]
    }
    let ns = prefix as NSString
    let dirRaw = ns.deletingLastPathComponent
    let dir = dirRaw.isEmpty ? "." : dirRaw
    let base = ns.lastPathComponent
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    return entries.sorted()
        .filter { $0.hasPrefix(base + ".") && $0.hasSuffix(".Swift.json") }
        .map { dir + "/" + $0 }
}

// The PRODUCING build of the report(s) at `prefix` — the §2.1 envelope `candor.version`, "" when
// absent/unreadable (candor-ts's convention: the provenance fields are unconditional, empty = unknown;
// a legacy bare-array report has no header). First sibling with a version wins — one prefix's siblings
// are one scan's output. Mirrors candor-ts query-core reportVersion / candor-java reportVersion.
private func gainsReportVersion(prefix: String) -> String {
    let fm = FileManager.default
    for f in gainsReportFiles(prefix: prefix) {
        guard let data = fm.contents(atPath: f),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let candor = obj["candor"] as? [String: Any],
              let v = candor["version"] as? String, !v.isEmpty else { continue }
        return v
    }
    return ""
}

// ⟨0.15 staged⟩ The `coverage` envelope ledger at `prefix` — the uncovered-module entries, merged
// across sibling reports (union by name; counts sum, matching what one whole-workspace scan would
// count), in the ledger order (count desc, name asc). Empty when no report carries the field (a
// fully-covered or pre-⟨0.15⟩ report). Read tolerantly (a malformed entry is skipped): this is a
// re-DISCLOSURE rider on gains, never a reason to refuse the delta the loud loaders already vetted.
private func gainsCoverage(prefix: String) -> [(name: String, calls: Int)] {
    let fm = FileManager.default
    var counts: [String: Int] = [:]
    for f in gainsReportFiles(prefix: prefix) {
        guard let data = fm.contents(atPath: f),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cov = obj["coverage"] as? [String: Any],
              let unc = cov["uncovered"] as? [[String: Any]] else { continue }
        for entry in unc {
            guard let name = entry["name"] as? String, !name.isEmpty else { continue }
            counts[name, default: 0] += entry["calls"] as? Int ?? 0
        }
    }
    return counts.map { (name: $0.key, calls: $0.value) }
        .sorted { $0.calls != $1.calls ? $0.calls > $1.calls : $0.name < $1.name }
}

// ⟨0.28⟩ The ⟨0.21⟩ completeness manifest at `prefix`, for the SAME rider treatment `gainsCoverage` has
// had since ⟨0.15⟩ — and NOT a second reading of it. The element rule stays in `mergeCompleteness`, the
// judged-nothing rule stays in `claimsToHaveJudgedNothing`; this only says WHICH FILES to ask, which is
// the one thing the existing prefix-keyed loaders (`loadFixModel`, `loadUnverifiedFns`) could not lend —
// they load a whole query MODEL, on the `functions`-envelope-or-fail terms `gains` deliberately does not
// take (it accepts the legacy bare-array form, and it has already applied its own loud net rule by the
// time the riders run). Two copies of the manifest READING is the mistake; a third `for f in files` is not.
//
// ⟨0.28⟩ A file that does not parse is COUNTED, not skipped. The first version of this rider skipped it
// on the reasoning that `mergeInferredReport` had already named it on stderr — which is true and was the
// documented-limitation trap: the comment recorded that the SHARED struct lacked the reference's
// `unreadable` arm and every verb inherited the lack, and writing that down is what stopped it being
// measured. The struct now carries the arm; this rider feeds it the same way the two loud loaders do,
// so a corrupt sibling hedges the gains answer exactly as it hedges `tour`/`path`/`unverified`/`fix`.
// A legacy bare-ARRAY report is NOT unreadable: it parses, it has no envelope to carry a manifest, and
// hedging over every pre-envelope report would put the caveat on ordinary input and train the reader to
// ignore it (the reference does not hedge there either).
private func gainsCompleteness(prefix: String) -> ReportCompleteness {
    let fm = FileManager.default
    var c = ReportCompleteness()
    for f in gainsReportFiles(prefix: prefix) {
        guard let data = fm.contents(atPath: f),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            c.unreadable.append(f)
            continue
        }
        guard let obj = root as? [String: Any] else { continue }   // legacy bare array — valid, no envelope
        mergeCompleteness(obj, path: f, entryCount: (obj["functions"] as? [Any])?.count ?? 0, into: &c)
    }
    return c
}

// Dispatched from main.swift when argv[1] is `gains`.
func runGainsCLI(_ args: [String]) -> Never {
    var wantJson = false
    var strict = false
    var positionals: [String] = []
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": wantJson = true
        // Advisory by default (exit 0 — gains is a diff view); `--strict` fails on ANY gained effect so a
        // supply-chain CI job can require a bump introduce no new capability (mirrors `unverified --strict`).
        case "--strict": strict = true
        default:
            if a == "--text" || a == "--human" { continue }  // candor-ts output-mode flags (#8); swift prose is the default — tolerate for cross-engine `candor <verb> --text`
            if a == "--policy" {
                // gains has no `--policy` of its own — reject it loud (never swallow → exit-0 false-clean) and
                // point at the real gate. Effect-specific gating is a `deny <E> gained` scan policy (AS-EFF-005).
                fixDie("candor-swift gains: unknown flag --policy — gains is a diff view; to FAIL CI on a newly-gained effect gate at scan time with a `deny <E> gained` policy (AS-EFF-005), or use --strict to fail on ANY gain")
            }
            if a.hasPrefix("-") { fixDie("candor-swift: unknown flag \(a)") }
            positionals.append(a)
        }
    }
    // Exactly TWO positionals (<current> <baseline>); a surplus is a usage error — never silently ignored.
    guard positionals.count == 2 else {
        fixDie("usage: candor-swift gains <current> <baseline> [--json] [--strict]")
    }
    let curPre = resolveReportLocator(positionals[0])
    let basePre = resolveReportLocator(positionals[1])
    // Both sides load LOUD (loadInferredLoud — the Rust reference load_fninfo_loud rule): a no-files
    // locator AND a net-empty merge over corrupt reports both exit 2; a partial sibling merge answers
    // but discloses the partial-surface summary on stderr.
    let cur = loadInferredLoud(prefix: curPre, which: "current")
    let base = loadInferredLoud(prefix: basePre, which: "baseline")

    // §2.1 producing-build provenance — a DISCLOSURE, not a guard (unlike the baseline gate, gains still
    // ANSWERS): a baseline is comparable only to reports from its own producing build, so when BOTH
    // versions are known and differ, a "gained capability" may be the ENGINE reclassifying (a κ batch
    // unmasking effects), not the dependency changing. One stderr ⚠ line + the unconditional
    // baseline_version/engine_version JSON fields ("" = unknown). Mirrors candor-ts / candor-java gains.
    let curVersion = gainsReportVersion(prefix: curPre)
    let baseVersion = gainsReportVersion(prefix: basePre)
    if !curVersion.isEmpty, !baseVersion.isEmpty, curVersion != baseVersion {
        FileHandle.standardError.write(
            "candor-swift: ⚠ baseline @\(baseVersion) ≠ engine @\(curVersion) — a \"gained capability\" may be the engine reclassifying, not the dependency changing. Regenerate both reports with one build to compare releases.\n"
                .data(using: .utf8)!)
    }

    var out: [(fn: String, effect: String)] = []
    for (fn, inf) in cur {
        for e in inf.subtracting(base[fn] ?? []) { out.append((fn: fn, effect: e)) }
    }
    out.sort { $0.fn == $1.fn ? $0.effect < $1.effect : $0.fn < $1.fn }

    if wantJson {
        // The supply-chain alarm (SPEC §5.1): `gained` is the UNION of effects the surface gained between
        // the two reports — a dependency that grew a Net/Exec reach between releases — with the
        // per-function detail under `byFunction`.
        //
        // ⟨spec 0.12 staged⟩ each byFunction entry carries `origin` — the candor-gains prototype's key
        // finding promoted into the open query. A gain on a fn that EXISTED at the baseline (shipped
        // pure, now does Net — the supply-chain attack signal) is a different alarm from a NEW fn that
        // does Net (a feature). Reports OMIT pure functions (SPEC §2), so existence is keyed on the
        // baseline CALLGRAPH sidecar (a baseline-pure fn is a graph node with no report entry):
        //   "existing" — in the baseline report, or a baseline-callgraph node (caller key or callee);
        //   "new"      — a COMPLETE baseline callgraph was loaded and the fn is in neither (the fn
        //                did not exist at the baseline);
        //   "unknown"  — absent from the baseline report AND the graph is EMPTY (no sidecar found) OR
        //                PARTIAL (a matched sidecar failed to read/parse and its nodes were dropped —
        //                the fn may have lived in the dropped file): existence is undecidable —
        //                DISCLOSED, never guessed (§4). A node still IN the partial graph stays
        //                "existing"; only the negative claim degrades.
        // JSON-only: the human `fn\teffect` TSV is a pinned consumer surface across the family
        // (line-matched seen-file dedup) and stays byte-stable. Mirrors candor-rust cmd_gains.
        let (baseCg, baseCgPartial) = loadCallgraphSidecars(prefix: basePre)
        var baseCgNodes = Set(baseCg.keys)
        for callees in baseCg.values { baseCgNodes.formUnion(callees) }
        func originOf(_ fn: String) -> String {
            if base[fn] != nil { return "existing" }
            if baseCgNodes.contains(fn) { return "existing" }
            if baseCg.isEmpty || baseCgPartial { return "unknown" }
            return "new"
        }
        let gained = Set(out.map { $0.effect }).sorted()
        let byFunction: [[String: Any]] = out.map {
            // Keys ALPHABETICAL within each entry (emitJSON's .sortedKeys): effect, fn, origin.
            ["effect": $0.effect, "fn": $0.fn, "origin": originOf($0.fn)]
        }
        // Top-level keys ALPHABETICAL too (emitJSON's .sortedKeys): baseline_version, byFunction,
        // [coverage], [coverageDelta], engine_version, gained.
        var doc: [String: Any] = ["baseline_version": baseVersion, "byFunction": byFunction,
                                  "engine_version": curVersion, "gained": gained]
        // ⟨0.15 staged⟩ coverage re-disclosure (SPEC §2/§3.1; the java reference's shape): the CURRENT
        // report's envelope `coverage` block rides the answer verbatim when present (absent otherwise) —
        // a "no gains" over an uncovered dep must not read as total. And when the BASELINE's uncovered
        // NAME SET differs from the current's (a dep became uncovered between scans — itself a signal),
        // `coverageDelta` names the difference, names only (call-count changes are not a delta).
        // Human TSV unchanged (pinned consumer surface); verdict-free, purely additive.
        let curCov = gainsCoverage(prefix: curPre)
        if !curCov.isEmpty {
            doc["coverage"] = ["uncovered": curCov.map { ["name": $0.name, "calls": $0.calls] as [String: Any] }]
        }
        let curNames = Set(curCov.map(\.name))
        let baseNames = Set(gainsCoverage(prefix: basePre).map(\.name))
        if curNames != baseNames {
            doc["coverageDelta"] = ["nowUncovered": curNames.subtracting(baseNames).sorted(),
                                    "noLongerUncovered": baseNames.subtracting(curNames).sorted()] as [String: Any]
        }
        // ⟨0.28⟩ §2 — AND THE ⟨0.21⟩ MANIFEST TRAVELS TOO, on exactly the terms the block above travels on.
        // The coverage rider has been here since ⟨0.15⟩ for the reason §2 gives — *a "no gains" over an
        // uncovered dep reads clean with false confidence* — and the SAME verb, on the SAME report, in the
        // SAME output, dropped the STRONGER caveat: `coverage.uncovered` says "I could not see into this
        // dependency", `unanalyzed` says "I could not read this file of YOUR OWN CODE", and
        // `analyzed.count: 0` says "I judged nothing at all". The mechanism was here and pointed at the
        // weaker field.
        //
        // BOTH SIDES, DISCLOSED SEPARATELY, because a gains answer rests on TWO reports and they fail
        // differently. An incomplete CURRENT means the gained set may be SHORT — effects the reader is not
        // being told about. An incomplete BASELINE means the comparison FLOOR is soft, so the
        // existing-vs-new `origin` split this verb exists for is unreliable. One combined flag would say
        // "something here is incomplete" and leave a supply-chain reviewer unable to act on it. The
        // baseline half takes the `baseline`-prefixed spelling this document already uses for the other
        // two-sided fact (`baseline_version`), rather than inventing a third shape.
        //
        // KEY NAMES ARE THE CROSS-ENGINE WIRE SURFACE — `incomplete`/`unanalyzed`/`judgedNothing` +
        // the same three under the `baseline` prefix. `mustHedge` is the trigger, and `judgedNothing`
        // IS carried, as a list of the report paths that judged nothing. The previous revision withheld
        // it, reasoning that the reference did not emit it on this verb and that a key one engine emits
        // and another does not is a divergence a consumer sees — the instinct was right and the premise
        // was STALE: java had already shipped the key as a path list and ts as a boolean, so the
        // withholding PRODUCED a three-way split of exactly the kind it was avoiding. The family ruling
        // (2026-08-12, being pinned into SPEC — the names appeared there zero times, which is the root
        // cause of the split): the key travels, its shape is the PATH LIST, because it names WHICH
        // report judged nothing — the repair differs per file, and `baselineIncomplete` alone cannot
        // say. The current side carries the unprefixed key for the same symmetry `unanalyzed`/
        // `baselineUnanalyzed` already have. The current side's keys come from `disclosureJSON`, the
        // one place the unprefixed key set is defined; the baseline side re-spells them under the
        // prefix this document already uses for its other two-sided fact (`baseline_version`).
        // Verdict-preserving — the exit does not move; `gains` is advisory by default and `--strict`
        // keys on the GAINED SET, which this does not touch. JSON-only, like `coverage` above: the
        // human `fn\teffect` TSV is a pinned consumer surface.
        let curComp = gainsCompleteness(prefix: curPre)
        let baseComp = gainsCompleteness(prefix: basePre)
        for (k, v) in curComp.disclosureJSON { doc[k] = v }
        if baseComp.mustHedge {
            doc["baselineIncomplete"] = true
            if !baseComp.unanalyzed.isEmpty { doc["baselineUnanalyzed"] = baseComp.json }
            if !baseComp.judgedNothing.isEmpty { doc["baselineJudgedNothing"] = baseComp.judgedNothing }
            // ⟨0.28⟩ SPEC §2 row 3 on the baseline side too, under the same prefix rule — the reference
            // derives `baselineNoManifest` mechanically from the one key set. Separate from the key above
            // for the reason the whole split exists: a supply-chain reviewer deciding whether to trust
            // the comparison floor needs "this report reached no conclusion" apart from "this report came
            // from a producer that emits no manifest".
            if !baseComp.noManifest.isEmpty { doc["baselineNoManifest"] = baseComp.noManifest }
        }
        emitJSON(doc)
        exit(strict && !out.isEmpty ? 1 : 0)
    }
    for p in out { print("\(p.fn)\t\(p.effect)") }
    if strict && !out.isEmpty {
        FileHandle.standardError.write("candor-swift gains --strict: the surface gained new effect(s) vs the baseline → exit 1\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}
