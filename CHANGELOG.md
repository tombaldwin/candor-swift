# Changelog

All notable changes to candor-swift are recorded here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); candor is pre-1.0, so minor versions may include
behavioural changes (always in the soundness-increasing direction — see the §4 trust contract).
A **⚠** heading marks a report- or verdict-affecting change: it changes report bytes or gate
verdicts, so an engine upgrade across it is baseline-invalidating (regenerate any saved baseline
with the new build — the AS-EFF-005 guard refuses a cross-build baseline by design).

## [0.10.0] — 2026-07-12

### spec 0.10 — the canonical query grammar rung (§3.3.1)

candor-swift now declares **spec `0.10`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.10 ratchets the conformance floor onto the newly-landed **§3.3.1 canonical query
grammar**: report discovery + the canonical `--report`, `--json`, and `--policy` flag forms are the pinned
§3.3.1 contract, and the old positional argument forms are **deprecated-but-still-accepted** (a scan or gate
invoked the old way still works — the deprecation is documentation-level, no behaviour change). Pinned by
conformance **PART 17**. This is a **version bump only** — no report-schema, classifier, or verdict change: a
0.9 report/verdict is byte-identical under 0.10. **⚠ the `spec` string changed** — a consumer pinning
`spec == "0.9"` must accept `0.10`.

### coverage-ledger rename — drop the bare "κ" from user- and agent-facing surfaces

The coverage-ledger stderr line no longer opens with the Greek letter **κ** — the first thing a cold
user saw with no explanation. The line now reads `candor-swift: candor's classifier doesn't cover N
module(s) this code imports — their effects are INVISIBLE to the scan (absent from the report, NOT a
claim they're pure): …`, and the shared **machine marker every engine keys off is now `classifier
doesn't cover`** (was `κ doesn't know`). README, AGENTS.md (+ the generated `AgentsDoc.swift`), and the
internal ledger comment follow suit. κ survives only as internal maintainer vocabulary — code
identifiers (`KAPPA_MODULES`, the κ table) and this changelog's history. No report bytes or gate
verdicts change — this is a text/marker rename only.

## [0.9.0] — 2026-07-11

### spec 0.9 — the remedial-loop rung

candor-swift now declares **spec `0.9`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.9 is a **tier-2 (pinned-tool-surface) rung** (candor-spec §"Conformance tiers"): no
report-schema or verdict change — a 0.8 report/verdict is byte-identical under 0.9 — but the remedial loop
(`fix`/`fix-gate`, `unverified`, and the gate auto-disclosure below) is now the pinned §3.1/§3.3 contract.
**⚠ the `spec` string changed** — a consumer pinning `spec == "0.8"` must accept `0.9`.

### ✨ Gate scans auto-disclose the provable-purity gap (no need to know to run `unverified`)

A policy scan now emits the `unverified` disclosure automatically as a stderr note: after the gate verdict,
any function in a `pure`/`deny <E>` scope that PASSES but is `Unknown` (an unresolvable call — the classic
fn/closure-injected "port") is named, with the `deny <E> Unknown <scope>` upgrade that makes the layer PROVABLY
clean. Closes the discovery gap — an author learns their "pure" layer isn't *provably* pure without knowing the
`unverified` command exists. **Advisory only**: a note, never a violation, so the exit code, gate verdict, and
`--gate-json` are untouched. Emitted from `main.swift` after `evaluateGate`. Mirrors candor-scan/java/ts
(four-engine parity). Existing tests unchanged (128 + smoke 94 pass). The gate note and `unverified` share ONE
predicate (`CandorCore.unverifiedHoleRule` + `ruleUpgrade`) — a single definition of a hole, so the two
disclosure paths cannot drift (PART 12d pins it).

## [0.8.15] — 2026-07-11

### ✨ `unverified` — the provable-purity disclosure ported here (four-engine parity)

Ports candor-query's `unverified` (candor-query 0.8.10): a `pure`/`deny <E>` layer PASSES a function that has
no such effect — but if that function is `Unknown` (an unresolvable call, e.g. a fn/closure-injected port), the
pass is UNVERIFIED. Discloses each such function in a governed layer + the `deny <E> Unknown <scope>` upgrade
that makes the layer PROVABLY clean. `--strict` → exit 1. JSON `{ok, unverified[]}`. Byte-for-byte the same
disclosure as the other engines, pinned four-way by conformance PART 12c. Read-only; gate verdict untouched.

## [0.8.14] — 2026-07-11

### `fix`: the sandwiched-layer case is now handled (last correctness gap closed)

When an ALLOWED layer is CALLED BY a forbidden one (`D1 → A → D2 → site`, deny on the D layer), hoisting the
effect to the nearest allowed frontier `A` would leave `D1` still inheriting it. `cleanHoist` is now `false`
in that case (a forbidden fn calls into the frontier), with a message that names the sandwich and offers the
port/relax options — instead of a misleading "hoist to A". Detected in the same upward climb that gathers
`hoistHigher`; identical across all four engines, pinned four-way by conformance PART 12b's sandwiched
sub-check. Read-only; additive.

## [0.8.13] — 2026-07-11

### `fix`: fail loud on a corrupt report (from a high-effort /code-review)

The `fix`/`fix-gate` loader set `foundReport = true` BEFORE parsing, so a present-but-unparseable report
(truncated / mid-write / missing `functions`) was treated as "found" and `fix-gate` emitted a silently-clean
`{ok:true, remedies:[]}` over a report that exists but couldn't be read. The flag is now set only after a
successful parse (and the corruption is disclosed on stderr), so a lone corrupt report fails loud (exit 2) —
the fail-loud contract the file comment promises. Also aligns start resolution with the family (prefer an
effect-performing match), already the case here — a regression test pins it.

## [0.8.12] — 2026-07-11

### `fix`/`fix-gate`: the higher-hoist trade-off (FIX-SPEC's last refinement)

Each remedy gains `hoistHigher` beside `hoistTo`: the allowed-layer transitive callers of the minimal
frontier that also route the effect — every place you could originate it *further up* (hoisting higher keeps
the frontier pure too, at the cost of threading through more signatures). `hoistTo` (the minimal fix) is
unchanged. Byte-for-byte identical to candor-query/java/ts, pinned four-way by conformance PART 12b. Read-
only, additive JSON field; not report- or verdict-affecting.

## [0.8.11] — 2026-07-11

### ✨ `fix` / `fix-gate` — the boundary fix reaches the fourth engine (FIX-SPEC P3)

candor-swift gains its first read-only query subcommands: `fix <report-prefix> <fn> <Effect> <policy>` and
`fix-gate <report-prefix> <policy>` (JSON), the remedial inverse of the policy gate (integrations/FIX-SPEC.md).
When a function performs an effect its architecture layer forbids, candor computes the *architectural remedy*
— the direct call **site** to hoist, the forbidden-layer functions that become pure and thread the value (the
**deniedSpan**), and the nearest allowed-layer caller (**hoistTo**) — plus the policy-relax alternative. The
cut is **site-anchored** (walks up from the site through the denied layer), so the pure span is root-
independent; `fix-gate` collapses the inheritors of one crossing to a single plan. Byte-for-byte the same
remedy as candor-query / candor-java / candor-ts, now pinned four-way by candor-spec conformance **PART 12b**.

The pure algorithm is `CandorCore/Fix.swift` (reusing the existing `scopeMatches` + deny/`pure` predicate); a
small on-disk report + callgraph loader in `Sources/candor-swift/FixCLI.swift` reads a report a scan already
wrote (candor-swift stays scan-first — read-only, no report/verdict change). A policy is required (the fix is
defined relative to the boundary it crosses); an unreadable policy or a missing report fails loud (exit 2).
Five `FixTests` pin the collapse, the single-function cut, the clean case, and the no-op branches. Not
report- or verdict-affecting.

## [0.8.10] — 2026-07-11

### ⚠ Conditional conformance on a stdlib collection now dispatches (soundness R28 — report-affecting)

`extension Array: Saveable where Element: Saveable { func persist() { forEach { $0.persist() } } }` reached
via `xs.persist()` (xs: [Item]) read silent-pure — two coupled gaps, both fixed:
- the **array-receiver edge**: `xs.persist()` now resolves to the local `Array.persist` extension unit (a
  soft `resolveQual` edge, so a std array method like `xs.forEach` drops silently — no spurious Unknown);
- the **self-element dispatch**: a bare `forEach { $0.persist() }` over `self` inside the extension now types
  `$0` as the extension's element bound (`where Element: Saveable`), so it dispatches to the conformers.

A pure conditional conformance stays pure (no fabrication); a std array method with a local Array extension
present charges precisely (no Unknown). Gated by
`DriverResolutionProcessTests.testConditionalConformanceOnArrayCollectionDispatches`. **This closes the last
FIXABLE silent-under-report residual — only the fundamental syntactic-limit residuals (R2–R8) remain open.**

## [0.8.9] — 2026-07-10

### ⚠ Property-wrapper `$`-projection and keypath reads charge their effects (soundness round — report-affecting)

Two more accessor access-paths where the effectful accessor unit existed but the ACCESS SITE didn't edge to
it, so the effect read silent-pure (register R24, R25):

- **`m.$name`** — a property wrapper's `projectedValue` (the `$`-projection) is now edged, mirroring the
  existing `wrappedValue` edging (an effectful projection was dropped while `wrappedValue` was charged).
- **`h[keyPath: \.data]`** — applying a keypath via subscript READS the property; the implicit-root keypath
  resolver only handled the element-iterator form (`xs.map(\.p)`), so a `[keyPath:]` subscript application —
  whose root is the receiver's OWN type — was missed. Now resolved to the member's accessor unit.

Both are the same class as R22/R23 (the accessor unit carried the effect; only the access edge was missing).
The element-map keypath keeps working (no regression); a pure member read via `$`/keypath stays pure (no
fabrication); `@dynamicMemberLookup` still discloses `Unknown` (sound — a member it can't pin to a name).
swift-specific accessor surface. Gated by
`DriverResolutionProcessTests.testProjectedValueAndKeyPathAccessorEffectsCharge`.

Also, **generic-constrained dispatch** (register R26, R27): the inline `<T: P>` bound already dispatched
`x.method()` to `P`'s conformers, but two forms were missed and read silent-pure — a **`where T: P`** clause
(now collected alongside the inline clause), and a **type-level bound** `struct Box<T: P> { let x: T }`
reaching `x.method()` (the field typed `T` now resolves to its bound `P`, so the existing protocol-typed-field
dispatch fires). An unconstrained generic, and a bounded generic with no dispatched call, stay pure (no
fabrication). Gated by `DriverResolutionProcessTests.testGenericConstrainedDispatchWhereClauseAndTypeLevelBounds`.

And **`@resultBuilder`** (register R29): a func annotated `@SomeBuilder` has its body compiler-transformed
into `SomeBuilder.buildBlock(...)` etc, so an effectful builder RUNS when the func is called — but that
transform is implicit (no call site), so it read silent-pure. The annotated func now edges to the builder
type's `build*` units. A pure builder adds nothing (no fabrication). Gated by
`DriverResolutionProcessTests.testResultBuilderTransformChargesBuilderEffects`. (Known low residual R28:
conditional conformance on a stdlib type — `extension Array: P where Element: P` reached via `xs.method()`
— stays silent for now; a compound resolution, tracked in SOUNDNESS.md.)

## [0.8.8] — 2026-07-10

### ⚠ Setter `newValue` is now typed — effects through it charge (soundness round — report-affecting)

An effect reached **through a setter's implicit value param** — `set { newValue.write(toFile: …) }` on a
computed property or subscript, or a `willSet` observer — read SILENT-PURE, because `newValue` was never
given a type, so a member call on it didn't resolve to the effectful method. Hit computed-property setters,
subscript setters, `willSet`, and renamed setter params (`set(v)`). Fixed by seeding the accessor unit's
`newValue` (or the named param) with the property/subscript element type (the same `params` typing regular
parameters get). Effects where `newValue` is merely an ARG to an already-resolved call
(`set { UserDefaults.standard.set(newValue, …) }`, `set { save(newValue) }`) already worked — this is the
narrower *receiver* case. A pure setter still stays pure (no fabrication). Found by an adversarial
operator/setter probe. The `==`/`+`/subscript-getter operator paths were probed and were already sound;
candor-ts/kotlin/rust use explicit typed setter params (no implicit `newValue`), so this is swift-specific.
Gated by `DriverResolutionProcessTests.testSetterNewValueIsTypedSoEffectsThroughItResolve`. Register: R23
(CLOSED).

## [0.8.7] — 2026-07-10

### ⚠ Inherited property accessors now charge their effects (soundness round — report-affecting)

An effectful **computed property**, **`didSet`/`willSet` observer**, or **subscript** whose body lives on a
**superclass** read SILENT-PURE when accessed through a subclass: `d.payload` (where `payload`'s getter is on
`Base`), `s.name = x` (an inherited observer), `l.payload` (two-level). Property-edge resolution matched only
the accessed type's own `Type.member` accessor unit and — unlike the method-call path, which already climbs
the type hierarchy — never consulted the supertypes. So a method inherited from a base was charged, but a
property accessor inherited from the same base was dropped (the cardinal sin: a silent under-report). The
fix mirrors the method climb for property edges (`supertypesOf`, transitive → two-level works); an override
on the subclass still wins (its own unit resolves first, so nothing is fabricated), and a pure inherited
property stays pure. Found by an adversarial soundness probe, not corpus/CI; gated by a twin regression
(`DriverResolutionProcessTests.testInheritedPropertyAccessorEffectsClimbTheHierarchy`). candor-ts/java were
checked and are sound (they climb) — swift-specific, not a shared blind spot. Register: R22 (CLOSED).

## [0.8.6] — 2026-07-10

- ⚠ **The AS-EFF-005 baseline guard** (SPEC §7 item 5): `CANDOR_BASELINE` / the config `baseline`
  key now gate — an existing fn gaining an effect vs a same-build baseline is a violation (exit 1);
  a stale/provenance-less/unparseable or configured-but-EMPTY baseline is invalid gate input
  (exit 2, no evaluation); an absent file is a note (guard inactive). Previously disclosed-inert.
- **`parsepolicy`** subcommand: the §6.2 grammar witness, java-parity verified (building it fixed
  a set-dedup parser gap — duplicate deny effects/allow values now dedupe like every other engine).
  The cross-engine grammar differential (conformance PART 4) is hard four-way with this.
- Docs: family framing (reference engine = candor-java), the payload-host and pure-vs-Unknown
  rules in standing docs, release-tag upgrade guidance, identity drift gates, the cardinal-sin
  comment ruling.

## [0.8.5] — 2026-07-09

### ⚠ Net hosts are captured at ESTABLISHING forms only (report-affecting)

A string arg at a USE verb on an already-established channel (`Channel.writeAndFlush("x")`) is a
PAYLOAD, not a destination — capturing it minted a bogus host that could trip `allow Net` on data.
Hosts are now recorded only at establishing forms (connect/ctor), matching candor-java and
candor-ts; the establishing ctor's `host:port` capture is unchanged (conformance [4e]).

### ⚠ `pure` no longer counts `Unknown` as a violation (family ruling — verdict-affecting)

An Unknown-only function no longer trips a `pure` rule: `Unknown` is the §4 trust marker, not an
effect — AS-EFF-003 owns the uncertainty residual, and `deny Unknown <scope>` is the explicit
strictness knob (it keeps firing, effects `["Unknown"]`). Aligns this engine's verdict with the
reference engine (candor-java) and the rust/ts engines; pinned four-way by conformance PART 16.

### Added — consumer-side report chaining (SPEC §2)

`CANDOR_DEPS=<report paths>` (or a checked-in `.candor/config` `deps` line) joins an unresolved
call into a covered package to that dep function's recorded effects AND literal surfaces. Trust
rules at the join: a stale/versionless producer downgrades to `Unknown`; an all-pure dep's empty
report is a purity claim; a bad token or unparseable report fails closed (exit 2).

### Internal — main.swift split + pure §6.2 helpers extracted (no behavior change)

The ~2,900-line main.swift is now Config/DeclCollector/CallCollector/Driver/ReportModel/Gate +
CandorCore/Policy.swift (the pure parser/matchers, now directly unit-tested); plus a test wave
(forbid-loop pins, table-driven κ pins + shadow twins, actor attribution, driver resolution,
CANDOR_DEPS fail-closed arms) and the shared process-test harness.

## [0.8.4] — 2026-07-09

### ⚠ κ covered-module sweep: UserDefaults / Keychain / Bundle resources → Fs (report-affecting)

`UserDefaults` reads/writes, Keychain `SecItem*` CRUD, and `Bundle` resource lookups
(`url/path(forResource:)`) lived inside covered platform modules unmodeled — the covered-module
silent-pure shape. All now classify Fs (family decision: UserDefaults is a file-backed store;
SecItem* is the system secure store, not Db; Bundle resource lookup is an on-disk stat); the pure
surface (`volatileDomainNames`, `bundleIdentifier`) stays pure, with anti-fabrication twins.

### Changed — config discovery is target-anchored only; config-relative paths

The `.candor/config` CWD fallback is deleted (it only ever applied an UNRELATED repo's config);
a relative `policy` value now resolves against the config's home dir, and the governing config is
named on stderr.

### Added — CI + release hardening

Linux lane (swift:6.1 container), pinned-spec + weekly HEAD-tracking conformance, release.yml
tag ⇔ engineVersion guard, the fabrication probe gated in CI; README/AGENTS speak spec 0.8 with
smoke-gated spec strings.

## [0.8.3] — 2026-07-02

### Fixed — startup hang on some toolchains (0.8.2 users should upgrade)

The `.candor/config` ancestor walk (new in 0.8.2) used `URL.deletingLastPathComponent`, whose
behavior at the filesystem root varies across Foundation versions — on toolchains where `/` →
`/..` the walk never terminated and every invocation hung. Now a string-based walk (stable root
semantics) with a hop cap; plus CI hang mitigations (TTY-wrapped `swift test`, job timeout,
superseded-run cancellation).

---

Older: see [GitHub releases](https://github.com/tombaldwin/candor-swift/releases).
