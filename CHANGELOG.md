# Changelog

All notable changes to candor-swift are recorded here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); candor is pre-1.0, so minor versions may include
behavioural changes (always in the soundness-increasing direction — see the §4 trust contract).
A **⚠** heading marks a report- or verdict-affecting change: it changes report bytes or gate
verdicts, so an engine upgrade across it is baseline-invalidating (regenerate any saved baseline
with the new build — the AS-EFF-005 guard refuses a cross-build baseline by design).

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
