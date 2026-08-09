// candor-swift — consumer-side report chaining (SPEC §2, the CANDOR_DEPS convention).
//
// A scan accepts SIBLING REPORTS — previously-produced reports for the scanned code's dependencies —
// and an unresolved/unclassified call into a package one of them covers inherits that function's
// recorded transitive effects AND its literal surfaces. The three §2 rules, as this engine holds them:
//
//   1. JOINS NEVER GUESS — the index keys each dep entry under `pkg#leaf`, `pkg#tail2` and
//      `pkg#<full qual>` (all separators normalized to `.` — the way THIS engine names a call:
//      `Owner.member`, or a bare free-fn/ctor name). A key two dep functions share is
//      REMOVED and remembered as ambiguous (the candor-scan move) — dropped, never picked from. The
//      consumer side additionally gates every join on the call site's FILE importing a covered
//      package, so a same-named symbol in an unimported dep can never join.
//   2. STALE REPORTS ARE NOT TRUSTED — a report whose `candor.version` differs from THIS engine's
//      build (or is missing: as unverifiable as a mismatch — the family condition, mirrored from
//      candor-ts scan.mjs / candor-java Loader) contributes `Unknown` at every join, never a stale
//      effect claim; its literal surfaces are not carried. It is still CHAINED — its keys are looked
//      up, so the downgrade can happen — but it grants NO COVERAGE (see rule 3).
//   3. A CHAINED PACKAGE IS COVERED, NOT BLIND — every package a TRUSTED loaded report covers
//      (envelope `package`/`packages`, plus each entry's hash prefix) is exempt from the §7.14 κ
//      ledger and the per-fn `invisible` disclosure, INCLUDING an all-pure dep's EMPTY report:
//      reports omit pure functions, so a call that joins nothing in a covered package reads pure —
//      the silence is the claim.
//
//      THE TRUST QUALIFIER IS LOAD-BEARING, and it is what rule 3 got wrong until 2026-07-27.
//      Coverage is the mechanism that turns a report's SILENCE into a purity claim, so granting it
//      on a report §2.1 has just refused to trust makes that claim on the refused report's own
//      authority: the keys such a report CARRIED read `Unknown` (right, rule 2) while every key it
//      simply did not contain read PURE (wrong, and silent). Measured on the two-tree fixture: a
//      call into a dep API the stale report has no entry for went from `invisible: ['RatesDep']`
//      unchained to ABSENT FROM `functions` — a ⟨0.21⟩ positive purity claim — the moment the
//      untrusted report was chained, and the κ ledger stopped naming the package. Staleness
//      rewrites the CONTENT of the keys a report holds; it can never conjure a key the report
//      lacks, so trusting its silence is the whole of the hole (candor-ts 651c9f9, same shape).
//
//      ⟨0.21⟩ A REPORT THAT DECLARES ITSELF INCOMPLETE grants no coverage either — the same door with
//      a different key, read one step earlier. A non-empty `unanalyzed` is the report saying it never
//      read some of its own source, so its silence about that source answers nothing. The TREATMENT
//      differs from staleness because the evidence does: a stale report's entries come from a build
//      this engine will not repeat and are downgraded to `Unknown`; an incomplete report's entries were
//      derived from source it DID read and are kept exactly as they are. Only the silence hedges
//      (candor-ts 21277eb, ported).
//
//      So a stale report's packages go to `stalePkgs`, an incomplete one's to `incompletePkgs`, NEITHER
//      to `coveredPkgs`, and `isChained` (any of the three)
//      is what the JOIN gates consult — dropping the package from the join too would be the mirror sin,
//      since it is the join that produces rule 2's `Unknown` downgrade in the first place. Measured: with
//      the join gated on `coveredPkgs` instead, FOUR named tests go red, three of them the stale-downgrade
//      rows. The second direction is not belt-and-braces here; it is the larger half.
//
// FAIL-CLOSED (the CANDOR_CONFIG posture, matching candor-java): a CANDOR_DEPS/config-`deps` token
// that names no readable file or directory, and a dep report that does not parse as JSON, FAIL the
// run (exit 2). Silently skipping either would make every call into that dep read pure — the §2.1
// "corrupt report ≠ pure" care, undone one level up.

import Foundation
import CandorCore  // the Effect vocabulary (moved there so a test can reach it)

/// One chained dependency function: effects + the four literal surfaces (the spec says a consumer
/// inherits BOTH — effects alone would make every chained `allow` rule fail on an empty surface),
/// plus the dep fn's own honesty carriers, inherited across the join so a consumer's verdict stays
/// qualified: `invisible` (the dep's blind-module disclosure) and `incomplete` (masking — a benign
/// literal here must not certify the dep's invisible runtime endpoint).
struct DepEntry: Equatable {
    var effects: Set<String> = []
    var hosts: Set<String> = [], cmds: Set<String> = [], paths: Set<String> = [], tables: Set<String> = []
    var invisible: Set<String> = []
    var incomplete: Set<String> = []
    /// The `unknownWhy` reason a join must carry when `effects` contains Unknown (spec 0.6: a direct
    /// Unknown source names its origin): `dep-stale:<pkg>` for a distrusted producer, `dep:<hash>`
    /// when a FRESH dep entry itself reads Unknown.
    var whyReason: String? = nil
    /// ⟨0.19⟩ THE DEPENDENCY'S OWN `unknownWhy` TOKENS, carried across the join so the REASON CLASS
    /// survives the scan boundary. Without them a chained Unknown arrives carrying only `dep:<hash>`,
    /// which SPEC §6.2 projects to `unresolved` — so the reason-scoped gate, a shipped ⟨0.19⟩ rung, was
    /// silently inert at exactly the boundary where a consumer most needs it: `deny Unknown[reflect]`
    /// went exit 1 single-tree and exit 0 the moment the same code was split and chained, while bare
    /// `deny Unknown` fired in both — which is why it survives review, since only the class-targeted
    /// middle reads green, and that middle is how the ratchet is adopted in practice.
    ///
    /// candor-java found the same gap one hop further out (`6ab26e4`) and needed no format rung, because
    /// the dependency's report ALREADY carries `unknownWhy` — nothing looked for it. Same here.
    /// `dep:<hash>` is KEPT alongside: it names the origin, which the raw tokens do not.
    var whyClasses: Set<String> = []

    /// Fold another entry filed under the SAME index key into this one — the family-wide entry-collision
    /// rule (candor-spec/ENTRY-COLLISION-DECISION.md), replacing withdrawal and the trust-level preference.
    ///
    /// EXHAUSTIVE, and every field is already a Set, which is what makes the union associative,
    /// commutative and idempotent. The index no longer depends on the order reports are walked in, and
    /// chaining one report twice is not observable.
    mutating func unionWith(_ other: DepEntry) {
        effects.formUnion(other.effects)
        hosts.formUnion(other.hosts); cmds.formUnion(other.cmds)
        paths.formUnion(other.paths); tables.formUnion(other.tables)
        invisible.formUnion(other.invisible)
        incomplete.formUnion(other.incomplete)
        whyClasses.formUnion(other.whyClasses)
        // `whyReason` is the one non-Set field, so its merge has to be stated rather than fall out.
        // ORDER-INDEPENDENT BY CONSTRUCTION: a `dep-stale:` reason wins over a `dep:<hash>` one whichever
        // side it arrives on. Both project to `unresolved` so no gate turns on the choice, but they say
        // different things to a reader — `dep:<hash>` means "this dependency classified nothing here",
        // `dep-stale:` means "this report is not the one this build produced, and re-running its scan
        // fixes it". The second is the actionable one, so a collision that involves a distrusted producer
        // reports that fact rather than burying it.
        switch (whyReason, other.whyReason) {
        case (nil, let o): whyReason = o
        case (_, nil): break
        case (let a?, let b?):
            if a != b, b.hasPrefix("dep-stale:"), !a.hasPrefix("dep-stale:") { whyReason = b }
        }
    }
}

/// The CANDOR_DEPS index: `pkg#leaf` / `pkg#tail2` / `pkg#<full qual>` keys (unambiguous only) + the
/// covered-package set.
struct DepIndex {
    var byKey: [String: DepEntry] = [:]
    // NOTE: there is no `ambiguous` set any more — the entry union withdraws nothing, so there is no
    // third state between "answered" and "absent" to remember. `returnsAmbiguous` below is the RETURN-TYPE
    // index, a different question: guessing a receiver type fabricates a call target, and its fallback is
    // disclosure rather than silence, so it still withdraws.
    /// Packages whose silence is a PURITY CLAIM (§2 rule 3) — a package covered by a report this engine
    /// TRUSTS. Consulted by the κ ledger and the per-fn `invisible` disclosure, which are exactly the
    /// hedges coverage is allowed to delete. Never consulted to decide whether to LOOK UP a key.
    var coveredPkgs: Set<String> = []
    /// Packages whose only chained report failed the §2.1 version check. Chained (so rule 2's `Unknown`
    /// downgrade fires on the keys the report does carry) but NOT covered (so a key it does not carry
    /// falls back to the `invisible` hedge instead of reading pure). A package chained twice — once fresh,
    /// once stale — is covered by the fresh report and is removed from here at the end of the load.
    var stalePkgs: Set<String> = []
    /// ⟨0.21⟩ Packages whose only chained report DECLARES ITSELF INCOMPLETE — a non-empty `unanalyzed`,
    /// i.e. it names source it could not analyze. The same door as `stalePkgs` read one step earlier:
    /// rule 3 turns a report's SILENCE into a purity claim, and this report has just said it never read
    /// some of its own source, so its silence about that source answers nothing.
    ///
    /// THE TREATMENT DIFFERS FROM STALENESS, and the difference is the whole point. A stale report's
    /// entries are assertions from a build this engine does not trust, so they are DOWNGRADED to
    /// `Unknown`. An incomplete report's entries were derived from source it DID read and are true, so
    /// they are kept exactly as they are and only COVERAGE is withheld: strictly additive, an answered
    /// key still answers, an unanswered one falls back to the κ ledger's `invisible: [pkg]` hedge.
    /// Nothing is downgraded and no effect is ever removed.
    ///
    /// Ported from candor-ts `21277eb`, which found this door in its own sweep and measured the
    /// single-tree control over the same sources at exit 2 ("a gate cannot be green over unanalyzed
    /// code") — so chaining an incomplete report was strictly WORSE than not chaining it: the dependency
    /// refused to certify a gate over itself and the consumer certified one on its behalf.
    var incompletePkgs: Set<String> = []
    /// ⟨0.24⟩ Packages whose only chained report JUDGED NOTHING — `analyzed.count == 0` (or a manifest so
    /// garbled it made no claim, or, on a pre-⟨0.21⟩ producer with no manifest at all, an empty
    /// `functions` list). The third reading of the same door, and the one where the report is entirely
    /// well-formed and entirely trusted: rule 3 turns a report's SILENCE into a purity claim, and a
    /// report that judged nothing is ALL silence.
    ///
    /// THE WIRE ALREADY DISTINGUISHED THE TWO CASES AND NOTHING READ IT. A `functions: []` report is two
    /// completely different statements depending on one integer:
    ///
    ///   `analyzed.count: 0`  "I judged nothing here"           — a facade package of pure re-exports
    ///                                                            scans to exactly this. No unit in it
    ///                                                            was ever looked at, so absence carries
    ///                                                            no purity claim: NOT COVERED.
    ///   `analyzed.count: n`  "I judged n units, none effectful" — a legitimate positive all-pure claim
    ///                                                            which §2 rule 3 says a consumer SHOULD
    ///                                                            believe: COVERED, and it MUST NOT be
    ///                                                            hedged. That row is the control, and a
    ///                                                            fix that hedged both would have
    ///                                                            disabled chained coverage, not fixed it.
    ///
    /// MEASURED on the two-tree fixture (dep `hit()` reads /etc/hosts, app `go()` calls it, `deny Fs`):
    ///
    ///   unchained                     go -> invisible: ['RatesDep'], coverage.uncovered, κ nudge, exit 0
    ///   trusted                       go -> ['Fs']                                                exit 1
    ///   count: 0 (pre)                go -> ABSENT FROM `functions`, no coverage field, no nudge   exit 0
    ///
    /// — the chained arm bought MORE confidence than not chaining the package at all, which is the one
    /// thing a degraded report may never do: `deny Fs` went exit 1 -> exit 0 with the disclosure the
    /// UNCHAINED arm carries deleted on the way. Conformance PART 26 measured 64 live cells ABSENT here
    /// and printed the two arms INDISTINGUISHABLE on all four engines.
    ///
    /// TREATMENT: as for `incompletePkgs` — entries untouched, only COVERAGE withheld. A count-0 report
    /// has no entries to touch in the ordinary case; the branch matters for the contradictory report that
    /// carries entries anyway, where dropping them would be the mirror sin.
    var unjudgedPkgs: Set<String> = []
    /// Does ANY chained report — trusted or not — claim this package? The predicate the JOIN gates use.
    /// Coverage decides whether SILENCE is a claim; chaining decides whether a key is worth ASKING.
    /// Conflating the two is the defect this split exists to close, and it bites in BOTH directions:
    /// gating the join on `coveredPkgs` would take rule 2's `Unknown` downgrade with it.
    ///
    /// ⟨0.21⟩ `incompletePkgs` is in here for the reason `stalePkgs` is, and it is the trade candor-ts
    /// measured going the WRONG way when it landed this rung: withholding coverage sends the site to the
    /// κ-ledger arm, so if the half-1 disclosure were gated on COVERAGE its unanswerable-key `Unknown`
    /// would be silently REPLACED by the `invisible` hedge and `deny E Unknown[dispatch]` would go exit
    /// 1 -> exit 0 — a gate lost to a fix whose whole argument is that it only adds disclosure. This
    /// engine's half-1 gate reads `isChained`, so both voices speak; the test asserts both.
    ///
    /// ⟨0.24⟩ `unjudgedPkgs` likewise. A count-0 report contributes no keys, so in the ordinary case this
    /// changes nothing; it is here so the CONTRADICTORY report — `analyzed.count: 0` with entries anyway —
    /// still has its entries asked, since withholding coverage may never take a real answer with it.
    func isChained(_ pkg: String) -> Bool {
        coveredPkgs.contains(pkg) || stalePkgs.contains(pkg) || incompletePkgs.contains(pkg)
            || unjudgedPkgs.contains(pkg)
    }
    /// ⟨0.23⟩ `typeSurface.returns` (SPEC §2): `<pkg>#<fn qual>` -> `<pkg>#<type qual>`, exactly as the
    /// producer published it. Same never-guess discipline as `byKey`: two reports publishing the same fn
    /// key with DIFFERENT types drop the key rather than pick one.
    var returnsIdx: [String: String] = [:]
    var returnsAmbiguous: Set<String> = []
    var isEmpty: Bool {
        byKey.isEmpty && coveredPkgs.isEmpty && stalePkgs.isEmpty && incompletePkgs.isEmpty
            && unjudgedPkgs.isEmpty
    }
    /// nil for an unknown OR ambiguous fn key. A miss here does NOT license silence — see the consumer.
    func boundType(_ key: String) -> String? { returnsAmbiguous.contains(key) ? nil : returnsIdx[key] }

    mutating func insertReturn(key: String, _ type: String) {
        if returnsAmbiguous.contains(key) { return }
        if let existing = returnsIdx[key] {
            if existing != type { returnsIdx.removeValue(forKey: key); returnsAmbiguous.insert(key) }
        } else {
            returnsIdx[key] = type
        }
    }
    /// nil for an unknown key only. NOTHING IS WITHDRAWN ANY MORE — a key two reports both answer carries
    /// the union of their answers, so there is no third state between "answered" and "absent" to check.
    func lookup(_ key: String) -> DepEntry? { byKey[key] }

    /// TWO ENTRIES UNDER ONE KEY ARE UNIONED — never withdrawn, never picked between, and NOT ranked by
    /// trust either. The family-wide rule (candor-spec/ENTRY-COLLISION-DECISION.md), whose open item 4 was
    /// "does swift's trust-level-first rule COMPOSE with the union or get REPLACED by it?"
    ///
    /// **REPLACED, and the reason is a soundness one rather than a tidiness one.** The rule this replaces
    /// let a trusted entry stand alone against a stale one, on the argument that §2.1 has already ranked
    /// the two producers so preferring the trusted one is not a guess. That argument is sound about which
    /// report to BELIEVE and wrong about what to DO with the other, because of what the collision means:
    /// two reports collide under one key precisely BECAUSE one package name spans two crate versions, and
    /// both bodies are in the build. The measured corpus says so — every one of the 123 disagreements
    /// across candor-rust/pgman/ebman is one function at two versions of one crate, `hyper` 0.14 vs 1.9
    /// among them. So the stale report is not a worse answer to the same question; it is the ONLY thing
    /// that knows a second version is present and cannot be vouched for. Preferring the trusted entry
    /// deletes that, and the consumer reads the fresh version's `[]` as a purity claim over a call that
    /// may reach the other body. Under the union it reads `[Unknown]` and discloses.
    ///
    /// THE OLD INVARIANT IS DELIBERATELY BROKEN. It read: *adding an untrusted report to a dep dir that
    /// already holds a trusted one changes the consumer's report by nothing at all.* That is the wrong
    /// invariant to want. An untrusted report IS evidence — evidence that a version this build cannot
    /// verify is in the tree — and an index that absorbs it without changing has thrown it away. What
    /// replaces it is the union's own invariant, which is stronger and is what the conformance PART pins:
    /// **the result does not depend on the ORDER the reports are walked in**, because union is
    /// commutative, associative and idempotent.
    ///
    /// The measurement that motivated the old rule still holds and is still closed — this is strictly
    /// further in the same direction. On one package present twice, on a function that runs `/bin/ls`:
    ///
    ///     unchained          go -> invisible: ['RatesDep']            the honest hedge
    ///     FRESH report only  go -> ['Exec']                           the answer
    ///     STALE report only  go -> ['Unknown']  dep-stale:RatesDep     rule 2's downgrade
    ///     FRESH *and* STALE  go -> ABSENT FROM `functions`             a ⟨0.21⟩ PURITY CLAIM  (the defect)
    ///     …under the union   go -> ['Exec','Unknown']                  both claims, neither discarded
    ///
    /// EVERY SPECIAL CASE THE LADDER NEEDED IS NOW SUBSUMED rather than handled. The identical-restatement
    /// exemption (the same report present under two names, the ordinary shape once `--workspace` prepends
    /// its own directory to a configured `CANDOR_DEPS`) is just idempotence. The
    /// recoverable-vs-permanent distinction between `staleAmbiguous` and `ambiguous` existed only to let a
    /// trusted report rescue a key two stale ones had withdrawn; nothing is withdrawn, so nothing needs
    /// rescuing. All three sets are gone, and with them the ordering hazard of maintaining them.
    mutating func insert(key: String, _ entry: DepEntry) {
        byKey[key, default: DepEntry()].unionWith(entry)
    }
}

/// ⟨0.24⟩ **DOES THIS REPORT SAY IT JUDGED NOTHING?** SPEC §2's three-row table plus the two fail-closed
/// rows it implies. ONE rule, TWO routes: `loadDepReports` asks it of every CHAINED dep report (where the
/// answer decides COVERAGE — see `DepIndex.unjudgedPkgs`) and `gate --report` asks it of the report it was
/// handed DIRECTLY, because SPEC §3.1 ⟨0.24⟩ puts the obligation on the READING, not on the route the
/// report arrived by. It lives here so the two can never drift into two readings of one integer.
///
/// `analyzed` is the raw `analyzed` value off the wire (`nil` for an ABSENT key — NOT for a `null`, which
/// is `NSNull` and a garbled manifest); `entryCount` is the report's `functions` length, consulted ONLY on
/// the manifest-absent row.
///
///   · `analyzed` ABSENT → a pre-⟨0.21⟩ producer with no manifest: judged-nothing IFF it listed no
///     entries. One that LISTS functions demonstrably judged units and said so the only way it could, so
///     it keeps the standing it always had. Reading THIS row as judged-nothing would withdraw coverage
///     from every report predating the rung (java measured that mistake at 7 failing tests, ts at 15).
///   · `count` a non-negative INTEGER > 0 → judged n units. UNCHANGED, including `n > 0` with
///     `functions: []`, which is the legitimate all-pure claim §2 rule 3 requires a consumer to BELIEVE.
///     That row is the CONTROL: a change that hedged it would have disabled chained coverage, not fixed it.
///   · `count == 0` → judged nothing.
///   · anything else — `analyzed: "oops"` / `{}` / `null`, a missing, non-numeric, NEGATIVE, NON-INTEGRAL
///     or BOOLEAN `count` → **present but UNREADABLE**, which is not a claim: FAIL CLOSED, withhold
///     coverage. A denylist of proven-safe shapes, never an allowlist of rejected ones.
///
/// **A BOOLEAN IS NOT AN INTEGER, AND THIS ONE WAS LIVE** (SPEC §2 ⟨0.24⟩ names this engine). Foundation
/// bridges a JSON `true` to `__NSCFBoolean`, and `__NSCFBoolean as? Int` SUCCEEDS with `1` — so
/// `analyzed: {count: true}` read as JUDGED and granted full coverage byte-identically to `count: 2`, and
/// the caller then dropped out of `functions`: a ⟨0.21⟩ positive purity claim licensed by a manifest that
/// made no readable claim at all. That is the fabrication mirror this rung exists to close, arriving
/// through a language's type bridge rather than through a logic error. The other three engines fail
/// closed here only because their JSON readers are stricter, not because anyone tested it — so the
/// boolean row is now in the shape table (`testAnAbsentOrGarbledAnalyzedManifestIsReadAsAClaimOnlyWhenItIsOne`).
///
/// The rejection is made BEFORE the integer cast, on the number's OWN type tag rather than on its value:
/// `objCType` is `"c"` for a boolean on BOTH Darwin Foundation and swift-corelibs-foundation (`Bool` is
/// stored as `kCFNumberCharType`), while a JSON integer is `"q"`/`"l"`/`"i"` and a JSON float `"d"`. A
/// value test could not do it — `count: 1` and `count: true` are the same number.
func claimsToHaveJudgedNothing(analyzed: Any?, entryCount: Int) -> Bool {
    guard analyzed != nil else { return entryCount == 0 }     // ABSENT: entries are the pre-⟨0.21⟩ claim
    guard let c = readableAnalyzedCount(analyzed) else { return true }     // present but UNREADABLE
    return c == 0
}

/// `analyzed.count` as a READABLE non-negative integer, or `nil` when the manifest is absent, garbled
/// (`"oops"` / `null` / a list / no `count`) or carries a `count` that is not a non-negative integer —
/// **boolean, fractional, negative, non-finite or non-numeric**. See `claimsToHaveJudgedNothing` for the
/// boolean, which is the one that was live. Every reader of the wire's `count` in this engine goes through
/// here, including the one that sums it into a `gate --report` verdict: a `count: true` that reached that
/// sum would have put a fabricated `1` in the machine-readable document.
func readableAnalyzedCount(_ analyzed: Any?) -> Int? {
    guard let m = analyzed as? [String: Any], let n = m["count"] as? NSNumber else { return nil }
    // BOOLEAN, rejected before the integer cast, on the number's OWN type tag: `objCType` is `"c"` for a
    // boolean on Darwin Foundation AND on swift-corelibs-foundation (`Bool` is stored as
    // `kCFNumberCharType`), while a JSON integer is `"q"`/`"l"`/`"i"` and a JSON float `"d"`. A test on
    // the VALUE could not do it — `count: 1` and `count: true` are the same number. This also rejects a
    // genuine 8-bit integer, which no JSON reader in this family produces for a `count`, and rejecting
    // one would only WITHHOLD coverage — the direction to be wrong in.
    let tag = String(cString: n.objCType)
    if tag == "c" || tag == "C" || tag == "B" { return nil }
    let d = n.doubleValue
    // non-integral (`2.5`), negative, NaN/∞, or past what an Int can hold. `2.0` IS `2` and is believed:
    // a double is a legitimate JSON spelling of an integer, and rejecting it would hedge real reports.
    guard d.isFinite, d >= 0, d == d.rounded(), d <= Double(Int.max) else { return nil }
    return Int(d)
}

/// The `deps` / `CANDOR_DEPS` separator set. ONE PREDICATE BECAUSE TWO SPELLINGS WERE A SILENT GREEN:
/// the §3.3.1 sink-over-input guard carried its own list omitting `\n`/`\r`, so a newline-separated
/// spec was one unresolvable token to the guard and two real paths here — and a `--gate-json` naming
/// one of those reports destroyed it, the run exiting 0 with `ok: true` over the operator's input.
///
/// NOT `isWhitespace`, which is true for U+00A0: these are PATHS, and a non-breaking space inside one
/// is part of the path rather than a separator, which is how java, rust and ts read it.
func isDepSeparator(_ c: Character) -> Bool {
    c == " " || c == "\t" || c == "\n" || c == "\r" || c == ":" || c == ","
}

private func depsFail(_ msg: String) -> Never {
    FileHandle.standardError.write("candor-swift: \(msg) — failing (exit 2), a configured dep must not silently read pure\n".data(using: .utf8)!)
    // THROUGH THE GATE SINKS. This exited raw, so `--gate-json -` got nothing and a file sink kept the
    // armed placeholder rather than this reason — the machine channel silent on a cause the operator
    // configured, while stderr explained it. PART 35 pins the EXIT CODE for this cause in all four
    // engines; nothing pinned the CHANNEL until PART 36 (b8), which then found it here, in the engine
    // this release is mostly about, after the same gap had been fixed in rust and ts.
    refuseGateAndExit("candor-swift: \(msg)")
}

/// The qual's segments with the family separators normalized: `a.b.C.m` / `mod::fn` / `Owner.member`
/// all split the same way, so a tail2 key reads `C.m` no matter which engine produced the report.
private func qualSegments(_ qual: String) -> [String] {
    qual.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
}

/// Load the sibling reports named by `spec` (whitespace/colon/comma-separated paths — the family
/// separator set; a directory is walked for *.json, sidecars excluded). `engineVersion` is THIS
/// build's version string, compared against each report's `candor.version` for the §2.1 trust rule.
func loadDepReports(spec: String?, engineVersion: String) -> DepIndex {
    var idx = DepIndex()
    guard let spec, !spec.isEmpty else { return idx }
    let fm = FileManager.default

    // Collect the report files. Canonical-path dedup: the same report loaded twice would self-collide
    // on every key and be dropped as ambiguous, silently killing the chain (the candor-scan review find).
    var files: [String] = []
    var seen: Set<String> = []
    func push(_ f: String) {
        let canon = (try? fm.destinationOfSymbolicLink(atPath: f)) ?? f
        let norm = (canon as NSString).standardizingPath
        if seen.insert(norm).inserted { files.append(f) }
    }
    for tok in spec.split(whereSeparator: isDepSeparator) {
        let t = String(tok)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: t, isDirectory: &isDir) else {
            depsFail("CANDOR_DEPS names \(t) but it is not a readable file or directory")
        }
        if isDir.boolValue {
            guard let en = fm.enumerator(atPath: t) else { depsFail("CANDOR_DEPS cannot walk directory \(t)") }
            var found: [String] = []
            for case let rel as String in en {
                let name = (rel as NSString).lastPathComponent
                if name.hasSuffix(".json") && !name.contains("callgraph") && !name.contains("hierarchy") {
                    found.append((t as NSString).appendingPathComponent(rel))
                }
            }
            for f in found.sorted() { push(f) }
        } else {
            push(t)
        }
    }

    for f in files {
        guard let data = fm.contents(atPath: f) else {
            depsFail("CANDOR_DEPS report \(f) could not be read")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            depsFail("CANDOR_DEPS report \(f) is not valid JSON")
        }
        // v0.2+ envelope `{candor, package, functions}` or the legacy bare array (no version → stale).
        let obj = root as? [String: Any]
        let fns = (obj?["functions"] as? [Any]) ?? (root as? [Any]) ?? []
        // §2.1 at the join: a MISSING producing version is as unverifiable as a mismatched one (the
        // family condition — candor-ts: `d.candor?.version !== ENGINE_VERSION`).
        let depVersion = (obj?["candor"] as? [String: Any])?["version"] as? String
        let stale = depVersion != engineVersion
        // ⟨0.21⟩ …and a report that names source it could not analyze grants no coverage either (see
        // `incompletePkgs`). STALENESS IS CHECKED FIRST: a report this engine does not trust cannot be
        // trusted about its own completeness, so its `unanalyzed` claim buys it nothing beyond the
        // downgrade it already has.
        // A MALFORMED MANIFEST HAS NOT MADE A COMPLETENESS CLAIM, so it must not be read as one. The
        // previous spelling — `(obj?["unanalyzed"] as? [Any]) ?? []` — made a FAILED CAST indistinguishable
        // from an ABSENT key: `"unanalyzed": "oops"`, `{}` or `null` all collapsed to the empty array and
        // the report was read COMPLETE, buying it full coverage. That is the door the well-formed case
        // closes, reopened by a garbled one. candor-java fails closed here and candor-rust adopted that
        // reading (`dbab8be`); candor-ts fixed the same fail-open in `26a89fc`; this is the last engine.
        //
        // The three cases are genuinely different and only two of them are complete:
        //   key ABSENT                  -> complete (the overwhelming case: nothing to declare)
        //   key present, EMPTY array    -> complete (an explicit "I analysed everything")
        //   anything else               -> INCOMPLETE, including a non-array, because a report that
        //                                  garbles its own completeness claim has not made one.
        // Conflating the first two with the third is the fail-open; conflating ABSENT with INCOMPLETE is
        // the opposite error and withholds coverage from every report that simply has nothing to declare —
        // candor-java measured that mistake at 7 failing tests, candor-ts at 15.
        let incomplete: Bool = {
            guard !stale else { return false }          // staleness is decided first, as above
            guard let raw = obj?["unanalyzed"] else { return false }   // absent: nothing declared
            if raw is NSNull { return true }                            // present-but-null: garbled
            guard let arr = raw as? [Any] else { return true }          // present, not an array: garbled
            return !arr.isEmpty
        }()
        // ⟨0.24⟩ …and a report that JUDGED NOTHING grants no coverage either — the same door, third
        // reading, and the only one where the report is well-formed AND trusted. §2's three-row table:
        //
        //   `analyzed.count: 0`   `functions: []`  -> I judged nothing. NOT COVERED, exactly as if the
        //                                             package were never chained.
        //   `analyzed.count: n>0` `functions: []`  -> I judged n units and none is effectful. A positive
        //                                             all-pure claim §2 rule 3 says a consumer SHOULD
        //                                             believe — COVERED, and MUST NOT be hedged. This is
        //                                             the control the row above is meaningless without.
        //   manifest ABSENT       `functions: []`  -> a pre-⟨0.21⟩ producer made no manifest and listed
        //                                             nothing: no claim at all, so the unchained reading.
        //
        // A manifest ABSENT with entries PRESENT is the pre-⟨0.21⟩ producer that did judge something and
        // said so the only way it could — its entries. Reading that as unjudged would withdraw coverage
        // from every report predating the rung, which is the `unanalyzed` absent/garbled mistake in a new
        // costume (java measured that one at 7 failing tests, ts at 15).
        //
        // A manifest that is present but GARBLED (`analyzed: "oops"`, a `count` that is not a number, a
        // BOOLEAN `count`) has not made a completeness claim, so it must not be read as one — the same
        // fail-closed reading the `unanalyzed` cast above takes, and for the same reason. The predicate is
        // SHARED with `gate --report` (`claimsToHaveJudgedNothing` above), so the chained route and the
        // direct route cannot drift into two readings of one integer.
        let judged = !claimsToHaveJudgedNothing(analyzed: obj?["analyzed"], entryCount: fns.count)
        func register(_ pkg: String) {
            if stale { idx.stalePkgs.insert(pkg) }
            else if incomplete { idx.incompletePkgs.insert(pkg) }
            else if !judged { idx.unjudgedPkgs.insert(pkg) }
            else { idx.coveredPkgs.insert(pkg) }
        }

        // Envelope-level coverage — registers even an EMPTY report's package (§2 rule 3): singular
        // `package` (this engine, candor-report, candor-ts) and the JVM-shape plural `packages`.
        // An UNTRUSTED report registers into `stalePkgs` instead: chained, not covered (rule 3's
        // trust qualifier — the header explains why the distinction is the whole fix).
        if let pkg = obj?["package"] as? String, !pkg.isEmpty { register(pkg) }
        // ⟨0.23⟩ the published type surface. GATED ON `!stale` for the same reason the effects are: a
        // report from a different producer version is not trusted, and keying a consumer through a type
        // claim we just refused to believe would smuggle a stale answer back in under another field.
        // Both ends arrive fully qualified; nothing here re-qualifies or shortens them.
        if !stale, let ts = (obj?["typeSurface"] as? [String: Any])?["returns"] as? [String: Any] {
            for (fnKey, ty) in ts {
                guard let ty = ty as? String, fnKey.contains("#"), ty.contains("#") else { continue }
                idx.insertReturn(key: fnKey, ty)
            }
        }
        for pkg in (obj?["packages"] as? [String]) ?? [] where !pkg.isEmpty { register(pkg) }

        // ⟨0.24⟩ A LIST KEY THAT IS PRESENT BUT UNPARSEABLE IS CORRUPT INPUT (SPEC §2, candor-spec
        // `38ba3e2`), and on this path the coercion is the header's own care undone one entry down: the
        // file header says a dep report that does not parse FAILS the run, "silently skipping either would
        // make every call into that dep read pure". `(e[k] as? [Any]) ?? []` skipped a CORRUPT ENTRY on
        // exactly those terms. Returns nil when the key is present and is not a list of strings; an ABSENT
        // key is `[]`, the documented default — conflating the two would refuse every legitimate report.
        func depStrs(_ k: String, _ e: [String: Any]) -> [String]? {
            guard let raw = e[k] else { return [] }
            guard let arr = raw as? [Any] else { return nil }
            let out = arr.compactMap { $0 as? String }
            return out.count == arr.count ? out : nil
        }
        for case let e as [String: Any] in fns {
            // NOT `continue`. MEASURED on the two-tree fixture (dep `hit()` reads /etc/hosts, app `go()`
            // calls it, `deny Fs`), with the dep entry's `fn` key deleted and with its `inferred` set to
            // `[1]`:
            //
            //   intact dep report   go -> ['Fs']                     exit 1   the gate catches it
            //   unchained           go -> invisible: ['RatesDep']    exit 0   the honest hedge
            //   corrupt entry       go -> ABSENT from `functions`    exit 0   a ⟨0.21⟩ PURITY CLAIM
            //
            // — strictly more confident than not chaining the package at all, on a function the dep report
            // was TRYING to tell you was effectful. Same shape as the `gate --report` half, one layer over.
            guard let qual = e["fn"] as? String, !qual.isEmpty else {
                depsFail("CANDOR_DEPS report \(f) has a `functions` entry with no readable `fn` "
                         + "(a non-empty string is §2-required) — a corrupt entry is not an absent one, and "
                         + "dropping it would make every call it answers read PURE")
            }
            // The entry's package: its hash prefix (`pkg#qual`), else the envelope package. No
            // package → unchainable entry (a hashless report under-reports, the documented direction).
            let hash = e["hash"] as? String
            let pkg = hash.flatMap { $0.contains("#") ? String($0.split(separator: "#", maxSplits: 1)[0]) : nil }
                ?? (obj?["package"] as? String)
            guard let pkg, !pkg.isEmpty else { continue }
            register(pkg)

            var entry = DepEntry()
            if stale {
                entry.effects = ["Unknown"]      // §2.1: a different/missing producer version is not trusted
                entry.whyReason = "dep-stale:\(pkg)"
            } else {
                // Every list key this entry contributes from, checked BEFORE any of them is used —
                // `inferred` is the effect set the join carries, and dropping a member of it is the
                // silent under-report in its purest form.
                guard let inferredNames = depStrs("inferred", e), let invisibleNames = depStrs("invisible", e),
                      let incompleteNames = depStrs("incomplete", e), let whyTokens = depStrs("unknownWhy", e),
                      let surfaces = ["hosts", "cmds", "paths", "tables"].reduce([String: [String]]?([:]), {
                          guard var acc = $0, let v = depStrs($1, e) else { return nil }
                          acc[$1] = v; return acc
                      }) else {
                    depsFail("CANDOR_DEPS report \(f) entry `\(qual)` carries a §2 list key that is not a "
                             + "list of strings (`inferred`, `hosts`, `cmds`, `paths`, `tables`, "
                             + "`invisible`, `incomplete`, `unknownWhy`) — reading it as EMPTY would drop "
                             + "the effect the entry was published to carry")
                }
                for name in inferredNames {
                    // foreign vocabulary (a future spec's effect) is honestly Unknown, never dropped
                    entry.effects.insert(Effect.from(name) != nil ? name : "Unknown")
                }
                for (key, path) in [("hosts", \DepEntry.hosts), ("cmds", \.cmds), ("paths", \.paths), ("tables", \.tables)] {
                    for v in surfaces[key] ?? [] { entry[keyPath: path].insert(v) }
                }
                // carry the dep fn's own honesty markers across the join (the candor-scan sweeps [8]/[30])
                for v in invisibleNames { entry.invisible.insert(v) }
                for v in incompleteNames where Effect.from(v) != nil { entry.incomplete.insert(v) }
                if entry.effects.contains("Unknown") {
                    // The dep's OWN reasons, so the ⟨0.19⟩ class survives the boundary. Only tokens the
                    // dep RECORDED: an entry that inherited its Unknown without a reason of its own
                    // (SPEC §4 makes `unknownWhy` direct-only) contributes nothing.
                    for w in whyTokens where !w.isEmpty { entry.whyClasses.insert(w) }
                    // `dep:<hash>` ONLY when the dependency classified nothing. It is a PROVENANCE
                    // pointer, not a reason, and §6.2 projects it to `unresolved` — so carrying it beside
                    // a classified reason puts an `unresolved` in the consumer's class set that the
                    // single-tree control does not have, and `deny E Unknown[unresolved]` then fires on a
                    // chained consumer and not on the same code unsplit. Chained-vs-single-tree agreement
                    // is this vein's done-ness criterion, and the origin is recoverable from `calls`;
                    // where the dep gives us nothing, `dep:` stands and the class is the conservative
                    // `unresolved` the spec prescribes for a hole nobody classified.
                    if entry.whyClasses.isEmpty {
                        entry.whyReason = "dep:\(hash ?? "\(pkg)#\(qual)")"
                    }
                }
            }
            if entry.effects.isEmpty && entry.invisible.isEmpty && entry.incomplete.isEmpty { continue }

            // THREE key shapes per entry: `pkg#leaf`, `pkg#tail2`, and `pkg#<full qual>` — the shapes
            // this engine's call sites can derive (§2 rule 1). The full qual is the PRECISE one, and it
            // exists because a consumer that knows its target exactly had no key to ask on: `Conn.send`
            // and `Mock.Conn.send` are ONE tail2 string, so the index withdrew both as ambiguous and the
            // ⟨0.23⟩ `typeSurface.returns` consumer — which forms `<pkg>#<type qual>.<member>` from a
            // FULLY QUALIFIED type path — could only ever miss on a nested type (candor-rust `5feba18`,
            // the same prerequisite one repo over).
            //
            // NORMALIZED, not the raw `qual`: a report produced by another engine writes `mod::Type::fn`,
            // and the key a swift call site forms is dotted. `tail2` already normalizes; so must this, or
            // the new key is one no consumer can spell.
            //
            // ADDITIVE, and THE DEDUP IS WHAT MAKES IT SO. For a 1- or 2-segment qual the "full qual" IS
            // the leaf/tail2 string already pushed, so pushing it again would collide with ITSELF and the
            // never-guess rule in `insert` would REMOVE a key that already worked — a silent under-report
            // manufactured by a change whose whole argument is that it removes nothing (standing-bar item
            // 9b). Against every OTHER entry it is additive by construction: a leaf key carries no `.` and
            // a tail2 key exactly one, so a ≥3-segment full qual lives in a disjoint string space and can
            // never withdraw either. A full qual is NOT unique within a package — it can still collide
            // with another entry's full qual — so a consumer's miss on an exact key must fall back to
            // disclosure, never to silence.
            let segs = qualSegments(qual)
            guard let leaf = segs.last else { continue }
            var keys: [String] = ["\(pkg)#\(leaf)"]
            if segs.count >= 2 { keys.append("\(pkg)#\(segs[segs.count - 2]).\(leaf)") }
            let full = "\(pkg)#\(segs.joined(separator: "."))"
            if !keys.contains(full) { keys.append(full) }
            for k in keys { idx.insert(key: k, entry) }
        }
    }
    // A PACKAGE CHAINED TWICE, ONCE COMPLETE AND ONCE NOT, IS **NOT** COVERED — INCOMPLETENESS WINS.
    //
    // This line used to run the other way (`incompletePkgs.subtract(coveredPkgs)`), on the reading that a
    // complete report makes its coverage claim on its own authority and must not inherit another
    // report's hedge. That reading is wrong, and the reason is one sentence: **two reports covering one
    // package do not cover the same SOURCE.** Coverage is the rule that turns SILENCE into a purity
    // claim (§2 rule 3), and a set of reports' silence is only as strong as the weakest completeness
    // claim in the set — report A's silence about a region it never read is not evidence, and A never
    // said otherwise; it answered for its own source. B DID say it could not read some of the package,
    // and complete-wins cancelled exactly that hedge.
    //
    // MEASURED on two fresh reports for one package, A complete and B declaring `unanalyzed`:
    //
    //   B alone      goUnlisted -> invisible: ['RatesDep']    the hedge B asked for
    //   A alone      goUnlisted -> ABSENT                     A's coverage, over source A read
    //   A and B      goUnlisted -> ABSENT                     B's hedge CANCELLED by A's claim
    //
    // …and the sharper form, which is candor-rust `63bbe87`'s argument arriving on the completeness axis
    // instead of the staleness one. This index DROPS a key two TRUSTED reports disagree under (§2 rule
    // 1 forbids picking) — so with A and C disagreeing about `RatesDep#hit`, one of them incomplete:
    //
    //   C alone      go -> ['Exec']       A alone  go -> ['Net']       A and C  go -> ABSENT
    //
    // a ⟨0.21⟩ positive purity claim over a function BOTH reports call effectful. Rust refused
    // complete-wins for exactly this shape and pinned the refusal; swift had it landed.
    //
    // The cost is a HEDGE, never an effect: entries are untouched either way (incompleteness withholds
    // coverage and nothing else), so the change can only add `invisible` and κ-ledger rows. Withholding
    // coverage from a package one chained report says it could not fully read is not a false disclosure
    // — the package really does have source nobody analyzed, and the ledger says so.
    //
    // ORDER MATTERS: completeness first, so the staleness reconciliation below sees the FINAL covered
    // set. A package that is covered, stale and incomplete at once then keeps BOTH disclosures rather
    // than losing the stale one to a coverage claim that has just been withdrawn.
    idx.coveredPkgs.subtract(idx.incompletePkgs)
    // ⟨0.24⟩ …AND A PACKAGE CHAINED TWICE, ONCE JUDGED AND ONCE NOT, **IS** COVERED — the opposite
    // reconciliation to the line above, and the direction follows from what the second report SAYS.
    // An INCOMPLETE report makes a specific NEGATIVE claim about the package's source ("there is source
    // here I could not read"), and that claim is true whoever else read it, so it wins. A count-0 report
    // makes NO claim in either direction: "I judged nothing" adds nothing to a report that judged
    // something, and subtracts nothing from it either. Letting it withdraw another report's earned
    // coverage would be the mirror sin — a real purity claim degraded to a hedge by a report with no
    // content — which is exactly the argument the `stalePkgs` line below is made of.
    idx.unjudgedPkgs.subtract(idx.coveredPkgs)
    // A package chained TWICE — once fresh, once stale — IS covered: the fresh report makes the claim and
    // the stale one adds nothing to it. Without this, a second report for an already-covered package would
    // strip the coverage the first one earned, which is the mirror sin (a real purity claim degraded to a
    // hedge by a report that says nothing new). NOT the same shape as the completeness line above: a
    // stale report makes NO claim about its own source at all, whereas an incomplete one makes a specific
    // negative one — and swift's `insert` keeps the TRUSTED answer on a fresh/stale collision (`ca5feb0`)
    // rather than withdrawing the key, which is what made rust's refusal rust-specific on that axis.
    idx.stalePkgs.subtract(idx.coveredPkgs)
    if !idx.incompletePkgs.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift: \(idx.incompletePkgs.count) chained dependency report(s) declare source they "
             + "could not analyze (⟨0.21⟩ `unanalyzed`) — their entries are KEPT unchanged, but they grant "
             + "NO coverage, so a key they do not answer discloses instead of reading pure: "
             + "\(idx.incompletePkgs.sorted().joined(separator: ", "))\n").data(using: .utf8)!)
    }
    if !idx.unjudgedPkgs.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift: \(idx.unjudgedPkgs.count) chained dependency report(s) judged NOTHING (⟨0.24⟩ "
             + "`analyzed.count: 0`) — a report with no judgment in it is not an all-clear, so it grants NO "
             + "coverage and its package stays in the κ ledger exactly as if it were never chained: "
             + "\(idx.unjudgedPkgs.sorted().joined(separator: ", "))\n").data(using: .utf8)!)
    }
    if !idx.stalePkgs.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift: \(idx.stalePkgs.count) chained dependency report(s) were produced by a DIFFERENT engine "
             + "build — downgraded to Unknown and granted NO coverage, so their unanswered keys stay in the κ ledger "
             + "(§2.1): \(idx.stalePkgs.sorted().joined(separator: ", "))\n").data(using: .utf8)!)
    }
    return idx
}
