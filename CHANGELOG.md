# Changelog

All notable changes to candor-swift are recorded here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); candor is pre-1.0, so minor versions may include
behavioural changes (always in the soundness-increasing direction — see the §4 trust contract).
A **⚠** heading marks a report- or verdict-affecting change: it changes report bytes or gate
verdicts, so an engine upgrade across it is baseline-invalidating (regenerate any saved baseline
with the new build — the AS-EFF-005 guard refuses a cross-build baseline by design).

## Unreleased

- ⚠ **FABRICATION, closed (safe direction, not a cardinal sin): a shared higher-order function's callback
  effects were charged to EVERY caller, not the one that actually passed them.** Found attacking the
  BACKLOG's "FABRICATION in ts and swift" entry against all four real engines: two callers of one HOF
  (`hof(sinkA)` doing `Fs`, `hof(sinkB)` pure) both read `[Fs]` — `sinkB`'s caller fabricated an effect it
  never reaches, and the scan-note diagnostic named the false path (`"callerB performs Fs, 2 hops away via
  sinkA"` — a call `callerB` never makes). java's method-reference resolution already proved this was
  solvable, not inherent to a syntactic scan. Root cause: the deferred callback-flow resolver (Driver.swift,
  "a fn-typed-param invocation drops its Unknown iff EVERY visible call site …") judged every call site into
  the shared HOF as ONE pool and, when every site resolved to a named function, edged the UNION of every
  resolved target onto the HOF's OWN node — which every caller inherits via the ordinary call edge, so two
  callers passing two different named callbacks each inherited the OTHER's target too. Fixed by moving the
  judgment to PER CALLER: `callsiteArgs` now carries the calling function alongside each site, and a
  resolvable named callback edges straight from the CALLER to the target (never through the shared HOF's
  node); an unresolvable one (a closure literal, a dynamically-chosen value, a missing arg) attributes
  `Unknown` directly to that caller. Chose the bare-`Unknown` shape (rust's, not java's `effect+Unknown`
  hedge) because it is what this exact resolver already did pre-fix for the whole-target case — moving an
  existing shape to the right scope, not choosing a new one. **The under-report guard this fix could have
  broken:** a caller reaching the HOF through an edge-adding branch that predates callsiteArgs tracking
  (an unqualified SIBLING-method call, an overloaded-sibling/init resolution, a CHA/protocol-default union
  edge — several exist, because the old per-target design never needed a caller list) escaped the per-caller
  judgment entirely in the first cut and silently kept NOTHING instead of the Unknown it deserved — caught
  auditing the fix against a live corpus, not by any existing test. Closed with `callersOf`, a reverse index
  built from the same call-edge graph `propagate` itself trusts, so every caller reaching the HOF is judged
  whether `callsiteArgs` tracked its site or not. Two new deterministic pins
  (`testTwoCallersOfOneHOFResolveIndependently`, `testSiblingCallIntoAHOFStillGetsJudged`) and
  `fuzz.py`'s `callback_recv` form updated to match (the Unknown now pins to the CALLER, not the shared
  `recv{i}` helper — its own comment now names why this generator's one-caller-per-HOF convention can't
  distinguish a per-target fix from a per-call-site one, and that a multi-caller seed is the one that would).
  `fabrication_probe.py` did not catch this: its scope is TYPE-MEMBER classification (a pure accessor vs. an
  effectful call on a platform handle), not call-graph/callback attribution — a different axis entirely, and
  not a gap in it. Regression-controlled against two real Swift packages used heavily for HOFs
  (swift-algorithms, swift-collections; 492 and 4965 analyzed units): every difference in both reports is a
  self-attributed `callback:` `Unknown` moving OFF the shared HOF's own node (now correctly pure in
  isolation) with zero new disclosures and zero effect losses elsewhere — hand-verified functionally
  identical except for the intended precision gain.

- ⚠ **CARDINAL SIN, closed: R33's deinit-glue (a `let`/`var` local bound to a fresh construction charges the
  type's effectful `deinit` at scope exit, mirroring rust's `Drop`-glue) only ever fired for the ONE binder
  shape it was written against — a name with NO type annotation (`let x = Loud(path)`) — and silently missed
  every other way to spell the same non-escaping local.** Found attacking the core syntactic engine (not the
  file-set surface the last four rounds hit): `let x: Loud = Loud(path)` and `var x: Loud? = Loud(path)` — the
  ordinary way to declare an explicitly-typed or Optional local, no rarer in real Swift than the inferred
  form — took the SIBLING branch of the same `if let ann = binding.typeAnnotation { … } else if let v0 =
  binding.initializer?.value { … }` and never reached the glue at all: `Loud`'s effectful `deinit` read
  completely silent-pure, no `Unknown`, no disclosure, on the caller whose scope actually runs it. `let _ =
  Loud(path)` (the wildcard binder — the single MOST certain non-escaping shape, since there is no name for
  a later statement to alias, store, or return) fell through the identifier-only guard entirely and missed
  it the same way. Measured with a rename/reshape control on an identical `Loud` (an effectful `deinit`
  reading `/etc/passwd`): `let x = Loud(p)` charged `Loud.deinit` to its caller; `let x: Loud = Loud(p)`,
  `var x: Loud? = Loud(p)`, and `let _ = Loud(p)` were each ABSENT from `functions` against the *identical*
  pre-fix binary — three silent purity claims from one mechanism missing three of its own binder shapes.
  (`Task { }` / `Task.detached { }` / `defer { }` bodies, and a plain `var` REASSIGNED to a fresh
  construction, were checked and already correct — closures are charged lexically to their passer
  regardless of what invokes them, and the reassignment binder already went through the working branch.)
  Fixed by extracting the glue into one function, `applyDeinitGlue(name:root:isVar:)`, keyed off `rootOf` on
  the INITIALIZER expression (never the annotation — so a protocol/supertype annotation over a concrete
  construction still resolves to what was actually built) and calling it from both the annotated-binder
  branch and a new wildcard-binder check, alongside the pre-existing unannotated-binder call site — so the
  three shapes can no longer drift into disagreeing about the same fact. A `_ = Loud(path)` bare discard
  ASSIGNMENT (no `let`/`var` — a `DiscardAssignmentExprSyntax`, a different grammar production from the
  wildcard PATTERN above) and a construction reached only through an array/dictionary LITERAL element
  (`let arr = [Loud(path)]`) were measured and are STILL silent; left open as a residual (documented, not
  fixed) rather than risk a rushed change to the much hotter `SequenceExprSyntax` assignment-detection path
  under this round's time budget — the array/dictionary case would also need new per-element provenance
  work to stay conservative.
  Controls, falsified against the pre-fix binary: the three silent→disclosed transitions above; a `Quiet`
  class with NO `deinit` bound via the identical annotated/wildcard binder shapes stays completely absent
  from `functions` on the POST binary (no fabrication from the new call sites); and — the over-charge
  control that matters most — two real, unmodified SwiftPM packages (`swift-algorithms`, 492 analyzed units;
  `swift-collections`, 4965 analyzed units, both cloned fresh from GitHub) scanned under a real `deny Net /
  deny Fs / deny Exec` policy are BYTE-IDENTICAL, full stdout including the report JSON, between the pre-fix
  and post-fix binaries. Six new process tests (`DeinitGlueBinderShapeProcessTests.swift`) pin the four
  binder shapes plus the fabrication and escape controls. All 931 XCTest cases, `smoke.sh` (148) and
  `fabrication_probe.py`/`fuzz.py` pass.

- ⚠ **CARDINAL SIN, closed: the CROSS-FILE fix directly below re-introduced a silent drop through CHA/dynamic
  dispatch, reproduced two ways.** That fix (`9496d73`) gave the peek child a `--peek-context` union and
  preserved attribution by skipping any finding whose carrying function lives in a CONTEXT (in-scope) file,
  reasoning it was "already judged by the primary gate". That reasoning is FALSE under CHA: the child
  resolves dispatch (protocol conformance, class override) over the UNION, so a context function's
  effective effect set there can include an effect the PRIMARY scan never computed, because the primary
  never saw the EXCLUDED file's conformer/override. The skip was keyed on the FILE a function lives in; the
  divergence is in the RESOLUTION, which file identity cannot see. Two reproductions, both `exit 0`,
  `"policy ✓"`, `outOfScope: []` against the pre-fix binary: a protocol conformer (`EvilDoer: Doer`
  performing `Net`) declared in an excluded test-source file, reached only through an in-scope
  `let d: Doer = PureDoer(); d.work()`, under `deny Net Runner` scoped so only the in-scope caller matches
  its name — and the identical shape via class inheritance and `override`. Control: the same code under an
  UNSCOPED `deny Net` already named `EvilDoer.work` directly, isolating the scoped rule's skip as the only
  silent route.
  Fixed by replacing the file-identity skip with an EFFECT-SET comparison: a context function's rule-matched
  effects are diffed against what this run's OWN finalized primary analysis (`effectors`, keyed by qualified
  name) already found for that exact function. An effect present in both is genuinely already judged and
  stays skipped; an effect present ONLY in the child's larger-universe computation exists solely because of
  the union and must surface. Where the responsible excluded declaration can be named with confidence — a
  call edge the context function's own resolved `calls` reaches, landing in an excluded file whose own
  inferred effects include the new one — the finding is attributed THERE, not to the in-scope call site that
  merely dispatches through it, matching `9496d73`'s own attribution rule one level up the dispatch chain.
  Where no single excluded declaration can be named with confidence (no explaining call edge, or more than
  one), the finding is disclosed against the in-scope call site under a new `dispatch-widened` class instead
  of being dropped: **a wrong-but-visible attribution is recoverable, a silent drop is not** — this is the
  direction chosen whenever attribution is uncertain. A single declaration reachable BOTH directly (its own
  qual matches the rule) and derived (an in-scope caller's dispatch resolves into it) — an unscoped `deny
  Net` matches both `EvilDoer.work` and the `Runner`-named caller that reaches it — is merged into ONE
  finding, not two, so closing the drop does not open a duplicate over-charge in its place.
  Five controls, falsified against the pre-fix binary: both CHA fixtures now answer `exit 2` naming the
  excluded declaration; the ORIGINAL cross-file fixture from `9496d73` still answers correctly (regression
  control, all 5 of its process tests unchanged); the unscoped-policy dedup control confirms one finding, not
  two, when both attribution routes name the same declaration; an excluded conformer/override that NOTHING
  in scope ever dispatches through produces no finding at all (over-charge control) — and two REAL SwiftPM
  packages (`swift-argument-parser`, `swift-algorithms`) scanned under `deny Net` and `deny Exec` are
  BYTE-IDENTICAL, report and callgraph sidecar, to the pre-fix binary; a 554-file real corpus (`swift-nio`)
  under `deny Net` completes in ~2.9s, no regression against the peek's existing 120s child-process deadline
  (measured previously at ~4.2s on a 2229-file corpus). Five new process tests
  (`PeekCHADispatchProcessTests.swift`) pin both CHA shapes, the unscoped control, the dedup control and the
  unreached-conformer over-charge control. All 925 XCTest cases, `smoke.sh` (148), `fabrication_probe.py`
  and `fuzz.py` pass.

- ⚠ **CARDINAL SIN, closed: the ⟨0.29⟩ peek's CROSS-FILE BLIND SPOT filed as "Cause B" below (latent
  since ⟨0.29⟩, applying to all five `PEEKED_CLASSES`).** The peek re-scans an excluded file in a CHILD
  PROCESS given only the excluded list (`--peek-excluded`), so when the excluded file's own effect reaches
  ONLY through a call into a file that stayed IN SCOPE, the child has no local declaration for the callee
  and the call resolves to nothing. **This is a false all-clear, not merely a disclosure gap**: settled
  first, before any fix, on a fixture where a genuinely-excluded test-source file (`import XCTest`, no bug
  in the exclusion) calls a normal in-scope `Helper.reachOut` performing `Net`, under a rule scoped so only
  the excluded caller matches (`deny Net Runner`) — the in-scope callee is never independently judged, so
  the ONLY route to a verdict is the peek. MEASURED against the pre-fix binary: `exit 0`, `candor-swift:
  policy ✓`, `outOfScope: []` — the ⟨0.30⟩ INCOMPLETE machinery never fires because the finding it keys on
  was never produced by the child in the first place (`--peek-excluded` alone against the caller's file:
  `analyzed.count: 1`, `functions: []` — the function is ABSENT, not `Unknown`).
  Fixed by giving the child a SECOND file list rather than re-deriving anything: the parent now also writes
  its own `sourcePaths` (the files its PRIMARY scan actually read) and hands the child both
  (`--peek-excluded` + the new internal `--peek-context`, main.swift). The child unions them for one
  `analyze()` call, so a call from an excluded file into a context file resolves exactly as it would in an
  ordinary scan — reusing the SAME blind-module/`Unknown` machinery an ordinary scan already has, for free.
  Attribution is unchanged: the parent's consumption loop still requires a MATCH against the original
  excluded list before reporting a finding, so an in-scope function that happens to satisfy a scope-matching
  rule is judged by the primary gate as it always was, never double-reported under the excluded slice's
  identity — a dedicated fixture (broad `deny Net`, matching both the excluded caller and the in-scope
  callee) pins that `outOfScope` names only the former.
  Four controls, falsified against the pre-fix binary: the defect fixture above now answers `exit 2`,
  `outOfScope` naming the excluded caller with `Net`, attributed to its real class (over-charge control:
  an excluded file with NO cross-file reach — direct effect entirely inside itself — produces a
  BYTE-IDENTICAL report and gate document to the pre-fix binary); the attribution fixture above (the
  control that matters most); and 30 excluded callers into one shared in-scope helper all resolve correctly
  in well under a second, nowhere near the peek's existing 120s child-process deadline. Five new process
  tests (`PeekCrossFileResolutionProcessTests.swift`) pin the mechanism (the child alone, given no context,
  still loses the call — documenting exactly what `--peek-context` closes) and all four controls. All 920
  XCTest cases, `smoke.sh` (148), `fabrication_probe.py` and `fuzz.py` pass.

- ⚠ **CARDINAL SIN, closed same-day: the entry below's SwiftPM platform pruning read `Package.swift`
  unconditionally, ignoring SwiftPM's VERSION-SPECIFIC MANIFESTS (`Package@swift-<version>.swift`), which
  OVERRIDE the base file outright when the active toolchain qualifies.** Reproduced with a control before
  fixing: `Package.swift` declaring `platforms: [.macOS(.v10_15)]` beside `Package@swift-6.0.swift`
  declaring `platforms: [.macOS(.v10_15), .visionOS(.v1)]`, a `#if os(visionOS)` function reaching `Fs`
  through a helper in a SEPARATE, always-in-scope file, under `deny Fs doVision` — the unscoped control
  caught it (`AS-EFF-006`, exit 1) and `--target Widget` answered `candor: nothing hidden` / `policy ✓` at
  exit 0, because the base-only read proved a platform restriction that was not the one governing the
  build and pruned live code. `grep -rn "Package@swift" Sources/` returned nothing before this fix — the
  version-specific-manifest rule had no counterpart anywhere in this engine.
  TWO compounding causes, only the first fixed here. **Cause A (fixed):** no structural parse of a single
  file on disk can answer "which manifest governs" — that depends on the toolchain actually invoking the
  build, which only the toolchain's own manifest loader can determine. Fixed by asking SwiftPM itself:
  whenever a `Package@swift-*.swift` file exists beside `Package.swift` at all, `dumpSwiftPackageJSON`
  (main.swift, factored out of the existing `.xcodeproj`-resolver `dump-package` fallback so both share
  ONE process-spawn implementation) runs `swift package dump-package`, and a new
  `parsePackagePlatformFamilies(dumpPackageJSON:)` (PackageTargets.swift) reads its resolved `platforms`
  array into the SAME family vocabulary the structural parser already produces. A structural read of
  `Package.swift` alone continues, UNCHANGED, whenever no version-specific manifest exists — the common
  case, and every existing control for it is untouched. FAILS CLOSED exactly like its structural sibling:
  no `platforms` key, an empty array (SwiftPM's own default of "every platform"), an unmappable
  `platformName`, or `dump-package` itself failing to run or execute (no toolchain, or a version-specific
  manifest SwiftPM selects but cannot compile) all collapse to `nil` — prune nothing, never a guess that
  falls back to trusting the base manifest, which is the exact defect this closes.
  **Cause B (bounded, not fixed): the ⟨0.29⟩ peek safety net that should have caught cause A as a
  worst-case backstop has a CROSS-FILE BLIND SPOT that this release still ships with.** The peek re-scans
  every `PEEKED_CLASSES` exclusion (`manifest`, `harness-target`, `test-source`,
  `outside-the-target-closure`, `platform-pruned`) in a CHILD PROCESS given ONLY the excluded file list
  (main.swift's `--peek-excluded`) — by design, so the child's answer is provably about the excluded set
  and nothing else. When an excluded file reaches an effect ONLY through a call into a file that stayed
  IN SCOPE, the child cannot resolve that call: MEASURED, the isolated child does not even report the
  caller with `inferred: ["Unknown"]` — the function is ABSENT from `functions` entirely, the same as a
  provably-pure function, so `outOfScope` stays `[]` and a gate reads `policy ✓` over code the peek never
  actually judged. This is not new to this fix or unique to `platform-pruned` — it is a property of the
  peek's child-process isolation itself, latent since ⟨0.29⟩, and it applies uniformly to all five peeked
  classes. It was invisible until now because no prior peekable exclusion routed its only effect through
  an in-scope helper; cause A's bug was the first trigger anyone measured. Closing cause A removes THIS
  trigger (the wrongly-excluded file no longer exists, so nothing is peeked in isolation for this
  fixture), but the blind spot itself remains open for any future exclusion whose effect crosses into
  in-scope code, and is FILED rather than fixed here — closing it would mean giving the peek child the
  full closure as resolution context while still attributing findings only to the excluded slice, which
  is a materially different design than "same walk-free entry, exact excluded set" the peek was built on,
  and risks reintroducing the timeout/attribution defects the ⟨0.29⟩ hardening rounds already closed.
  **The `.xcodeproj` path does NOT share cause A.** Its own platform pruning (`xcodeTargetScope`,
  XcodeTargets.swift) never reads a package manifest's `platforms:` at all, base or version-specific — it
  derives its single platform purely from the Xcode target's own SDKROOT build setting and checks
  `#if os(…)` against that ONE concrete value, which is not a question SwiftPM's version-specific-manifest
  selection has any bearing on. It DOES still hardcode `Package.swift` for a local package's own
  targets/products/dependencies (not platforms) when resolving `--target`'s dependency closure — an
  adjacent, pre-existing, UNFIXED gap shared with this same engine's `--target` target-closure resolution
  (`declaredSPM`/`targetClosure`, PackageTargets.swift/main.swift), reported here rather than fixed:
  reading a local package's own version-specific manifest for its declared target/product graph is a
  different, wider change than the platform-family read this entry closes.
  Four controls, falsified against the pre-fix binary before this fix existed: the reported cross-file
  shape now catches the violation (was exit 0 `policy ✓`, now exit 1 `AS-EFF-006`); a package with NO
  version-specific manifest and genuinely platform-dead code still prunes it, byte-identical to the entry
  below (over-charge control); `#if os(macOS)` code in a package that supports macOS stays live and still
  fires as an ordinary violation (the control that matters most); a `Package@swift-*.swift` that NARROWS
  the platform set — the base declares iOS, the overlay does not — is also read correctly and prunes what
  the overlay drops (INCOMPLETE, exit 2, via the peek). A fifth control pins the fail-closed path itself:
  a version-specific manifest SwiftPM selects but cannot execute (a real compile error) prunes nothing,
  keeping the gated code live rather than falling back to the base manifest's wider platform set.
  Four new process tests (`SwiftPMVersionSpecificManifestProcessTests`, SwiftPMPlatformPrunedProcessTests.swift)
  pin the widening case, the narrowing case, the fail-closed-on-unexecutable-overlay case, and the exact
  reported cross-file shape end to end. All 915 XCTest cases, `smoke.sh` (148), `fabrication_probe.py` and
  `fuzz.py` pass.

- ⚠ **`--target` platform pruning now covers SwiftPM, not just `.xcodeproj` — candor BACKLOG.md's A4:
  the previous entry below split `platform-pruned` out of `xcodeTargetScope`, but that machinery lived
  ONLY behind the `.xcodeproj` resolver (XcodeTargets.swift); `PackageTargets.swift`, the SwiftPM half of
  `--target` (~530 lines), never mentioned "platform" or `#if os` at all.** MEASURED before this fix: a
  SwiftPM package declaring `platforms: [.macOS(.v13), .iOS(.v16)]`, with a function wholly inside
  `#if os(watchOS)` calling `FileManager.createFile`, reported that function as a LIVE, undisclosed `Fs`
  effect — not excluded, not flagged, not disclosed as platform-dead — and a real `--policy deny Fs` gate
  FAILED on it (`AS-EFF-006`), a false policy violation over code that can never run on any platform the
  package ships. Strictly worse than the entry below's own starting point: there the file at least reached
  `excluded[]` under an imprecise label; here it reached nothing. Root cause: the audit that produced the
  entry below asked "is there a `platform-pruned` class for `--target`?", found one, and stopped — the
  class existed, but only ONE of `--target`'s two resolvers fed it.
  Fixed by reusing, not re-implementing, `328a67f`'s machinery: `swiftFileCompilesToNothing` (unmodified)
  still decides per-platform membership; a new `parsePackagePlatformFamilies` (PackageTargets.swift) reads
  a manifest's declared `platforms:` into the same `os(…)` family vocabulary (`.macCatalyst` folds into
  `"iOS"`, matching `inferPlatform`'s existing SDKROOT token map); a new
  `swiftFileCompilesToNothing(source:onAnyOf:)` overload (XcodeTargets.swift) asks whether a file is dead
  on EVERY family the manifest declares — the SwiftPM analogue of an Xcode target's single build platform,
  since a restricted package's declared platforms are all built from the SAME target, never one at a time.
  The SwiftPM `--target` path in `main.swift` then feeds a dead file into the SAME `excludedFiles` list
  under the SAME `"platform-pruned"` class the Xcode path already produces, so it inherits `PEEKED_CLASSES`,
  the `outOfScope`/INCOMPLETE verdict machinery, and the disclosure text for free — one class, two
  producers, no parallel implementation.
  `parsePackagePlatformFamilies` returns `nil` — "prune nothing" — for every case where a restriction
  cannot be PROVEN: no `platforms:` argument at all (SwiftPM's own default of "every platform"), a
  non-literal value (a hoisted variable), an empty literal array (SwiftPM does not accept a package with
  no supported platforms, so reading one is far more likely a parse gap than intent), or any element this
  cannot map to a known `os(…)` family (`.driverKit(…)`, a future case) — one unmappable element
  invalidates the WHOLE declaration rather than silently narrowing it, because treating "cannot map" as
  "not declared" would prune a family the manifest actually supports. Every one of these fails toward
  keeping too much, never too little, matching the Xcode side's existing posture when `inferPlatform`
  finds no SDKROOT. The shared `EXCLUDED_REASON["platform-pruned"]` string is reworded to name both
  producers ("an Xcode build setting, or a SwiftPM package's declared `platforms:`") since it now speaks
  for two different mechanisms.
  Verified against the pre-fix binary: the watchOS-gated defect case now excludes+peeks (was a live
  effect and, under a `deny Fs` policy, a false `AS-EFF-006` violation — now INCOMPLETE, exit 2, via
  `outOfScope`); a package with the SAME `platforms:` restriction but no `#if os(…)`-gated code produces a
  BYTE-IDENTICAL report (the over-charge control); `#if os(macOS)` code in a package that DOES declare
  macOS support stays live and still fires as an ordinary policy violation (the control that matters most —
  excluding it would be the silent under-report a completeness fix must never introduce); the `.xcodeproj`
  path's own three process tests from the entry below (`PlatformPrunedFileSetProcessTests`) are unchanged.
  Six new process tests (`SwiftPMPlatformPrunedProcessTests.swift`) pin the defect case, the peek/INCOMPLETE
  behaviour, the over-charge control, the genuinely-live control, and both "cannot be proven" cases (no
  `platforms:`, an unreadable one). All 911 XCTest cases, `smoke.sh` (148), `fabrication_probe.py` and
  `fuzz.py` pass.
  Whole-repo scans (no `--target` at all) and a `.xcodeproj` project scanned whole-repo remain OUT OF
  SCOPE for this fix, unchanged from before: neither resolver drops a file from the scan on platform
  grounds outside a `--target` invocation, and that is a separate, wider question (which platform is
  "the" platform for a scan that is not scoped to one binary at all) that this fix does not answer.

- ⚠ **the `--target` platform prune (`#if os(…)`, XcodeTargets.swift) now files its OWN `excluded[]`
  class, `platform-pruned`, instead of the generic `outside-the-target-closure` the before/after diff
  gave every scoped-out file.** Both classes were already MANDATORY-disclosed, PEEKED, and verdict-bearing
  before this change (⟨0.29⟩/⟨0.30⟩) — a file wholly inside `#if os(macOS)` in an iOS target's closure
  already reached `excluded[]`, already got read by the child-process peek, and an effect the policy
  denied inside it already flipped the verdict to INCOMPLETE (exit 2) via `outOfScope`, all via the
  cross-target diff at the foot of `--target` resolution (main.swift). Filed against candor `BACKLOG.md`'s
  "swift's platform-pruned files never enter `excluded[]`" as a completeness hole: MEASURED against HEAD,
  the premise did not hold — the files were already there, just under an imprecise label. What was
  missing, and what this closes, is SPEC §2's requirement that `reason` "say why the class exists, in the
  engine's own terms": `outside-the-target-closure`'s reason ("production sources... an unscoped scan
  WOULD have judged") is true of a sibling-target file but only half the truth of one that builds into
  NOTHING on this platform in EVERY target — a `#if os(macOS)` guard is not an attribution boundary, it is
  dead code. `XcodeTargetScope` now returns the dropped paths (`platformExcludedFiles`), not just their
  count, so `--target`'s Xcode resolver can file them under the precise class directly rather than let the
  generic diff re-derive a less specific reason for the same exclusion — and the diff loop skips any path
  already filed this way, so one exclusion is never counted under both classes. `platform-pruned` is
  PEEKED exactly like `outside-the-target-closure` was (same file, same classifier, same child process),
  never `judgedElsewhere` (a single `--target` invocation has not judged the file elsewhere — a SEPARATE
  invocation for the platform it DOES build on might, but nothing here can see that it did). Report bytes
  change ONLY when `--target` resolves against an `.xcodeproj` AND platform pruning actually drops a file
  (the `class` string, and only there); a whole-repo scan, an SPM-manifest-resolved `--target`, and an
  ordinary sibling-target-only exclusion are byte-identical to before — verified against the pre-fix
  binary on all three, plus the falsifying control that the pre-fix binary already produced exit 2 on the
  motivating case (mislabelled, not missing).

- **⟨0.34⟩ the spec-ladder parse now strips surrounding ASCII whitespace before parsing, per SPEC
  §2 ⟨0.34⟩'s explicit ruling.** `parseSpecLadder`/`specPredates` (`Sources/CandorCore/Policy.swift`,
  added by the item below) did not trim: `Int(" 0")` is `nil` in Swift, so a report whose envelope
  carried incidental padding on `candor.spec` (`" 0.33"`) read as unparseable and therefore as
  predating ⟨0.33⟩ — producing, via a pure formatting artifact, the exact false "this report predates
  ⟨0.33⟩, before its producer recorded a deny set" diagnosis on a report that was in fact at the floor,
  with its `scannedUnder` key plainly present. Fixed by trimming the same ASCII whitespace class this
  engine's policy-line tokenizer already uses (space, tab, CR/LF/VT/FF — never `.whitespaces`/
  `Character.isWhitespace`, which are Unicode and would also swallow non-ASCII spaces this family
  treats as ordinary characters elsewhere) before the major/minor split. Message-only, matching the
  rung it belongs to: verdict, exit code and the `--gate-json`/`fix --json` document are unchanged —
  confirmed byte-identical between a whitespace-padded and an unpadded at-floor fixture, both before
  and after. A genuinely old, padded version (`" 0.32"`) still predates and a genuinely old, unpadded
  one is unaffected — the over-charge control this fix could otherwise have broken by parsing too much.
  candor-java and candor-ts already trimmed; candor-swift and candor-rust did not (conformance PART 80's
  `ws` cell, candor-spec `0b015d3`).

- **⟨0.34⟩ ITEM 1: the ⟨0.33⟩ cross-policy remedy now names its ACTUAL cause — message-only, verdict and
  `--gate-json` unchanged.** `gate --report` and `fix` (the only two independently-coded texts for this
  cause; `fix-gate`/`unverified` disclose it as the bare `incomplete: true` flag with no sentence to
  reword) name a report whose peek was bounded by a deny set narrower than the policy in force as *"this
  report's peek was bounded by the deny set its producing scan held, and that set does not cover N
  rule(s) of this policy"* — TRUE of a ≥⟨0.33⟩ producer that genuinely scanned under a different deny
  set, but MISLEADING of a report that predates ⟨0.33⟩ entirely: such a producer never had a
  `scannedUnder` key to hold ANY deny set in, so "does not cover" reads as "chose a different policy"
  where the truth is "could not yet record one". Both readers now check the report's own envelope `spec`
  (new `CandorCore.specPredates`/`parseSpecLadder`, compared on the major.minor LADDER and never
  lexicographically — `"0.9"` sits before `"0.33"` even though the string compare inverts it; unparseable
  or absent `spec` counts as predating) and print a second sentence naming the real cause and the remedy
  ("re-scan with a 0.33+ engine under THE SAME policy") whenever EVERY report that contributed to the
  cause predates the rung. A single ≥⟨0.33⟩ contributor keeps the original sentence, because for that
  report the narrower deny set is real — the version licenses a REMEDY, never a verdict (SPEC ⟨0.34⟩
  explicitly rules out a version floor: a report's age cannot license certification, since a pre-⟨0.33⟩
  producer's peek was still bounded by SOME policy nobody here can see). No new wire key: `ok`, the exit
  code and the full `--gate-json`/`fix --json` document are byte-identical in every case — verified
  against a hand-built pre-0.33 fixture whose gate-json is byte-equal to a ≥0.33 fixture raising the
  identical rule gap, and both of `unaskedCrossPolicyRules`'s callers (`gate --report`'s exit arm and
  `armingUnread`, shared by `fix`/`fix-gate`/`unverified`) now read the flag from one shared computation
  rather than two.

- ⚠ **R61 — three idiomatic FFI mechanisms read silent-pure: no generic "unresolved call through an
  opaque value" fallback existed in this engine's dispatch model at all.** A raw `import Darwin`/`import
  Glibc` free-function call (`system("rm -rf /")`, `unlink(path)`), a direct C-symbol-linkage declaration
  (`@_silgen_name("system")` / `@_extern(c, "name")`), and `dlopen`/`dlsym` + `unsafeBitCast` to a function
  pointer, then calling it — all three exited 0, `policy ✓`, under `deny Exec`/`deny Fs`, with zero
  disclosure. The modelled `Process` API stayed correctly charged on the same fixtures throughout, so this
  was a missing fallback, not a coverage gap: candor-rust discloses `Unknown`/`native:extern fn` for the
  analogous `ForeignMod` shape and candor-java discloses `native:<name>` for `ACC_NATIVE` methods; swift
  had no such fallback anywhere in its dispatch model. Routes all three into the existing
  `Unknown`/`unknownWhy` vocabulary (`native:<symbol>`, `callback:<local>`) — never a fabricated concrete
  effect, since what a foreign call actually does is unknowable here.

  FIX 1 (`@_silgen_name`/`@_extern`): `DeclCollector` now records the linked symbol name (`FnInfo.ffiNative`)
  off either attribute; `Driver`'s `guard let body = f.body else { continue }` — previously the single
  place EVERY bodyless unit (including this one) skipped straight past having any effects at all — now
  seeds `direct`/`unknownWhy` for exactly this shape before continuing, so the existing `propagate(direct,
  over: edges)` fixpoint carries `Unknown` to every caller with no other code path touched. A bodyless
  PROTOCOL REQUIREMENT (the other reason a body is nil) is unaffected: it carries no such attribute, so it
  keeps answering through the bounded-CHA `dispatch:` machinery exactly as before.

  FIX 2 (`dlopen`/`dlsym` + `unsafeBitCast` + invocation): a `let fn = unsafeBitCast(sym, to: SomeCFn.self)`
  binding fell into `depFactoryCallee`'s "plausible dependency factory" heuristic, which feeds ONLY a later
  MEMBER call on the local (`fn.foo()`) — never the direct invocation (`fn()`) this mechanism actually
  uses, so the call resolved against nothing and dropped silently. `CallCollector` now routes an
  `unsafeBitCast`-bound local into the SAME `opaqueFnLocals` machinery an opaque stored closure property
  already uses, so the existing call-site check (`opaqueFnLocals.contains(name)`) fires and discloses
  `Unknown`/`callback:<name>` — infrastructure this engine already had and tested, reused rather than
  duplicated.

  FIX 3 (raw `system`/`unlink`/…): added to `Driver`'s unqualified-call resolution as the terminal case —
  a call that resolved against NOTHING project-local (every prior arm: overloaded free fn, `freeFnByName`,
  local ctor, enclosing sibling, all failed), in a file importing a C-interop platform module
  (`C_PLATFORM_MODULES`: Darwin/Glibc/Musl/WinSDK), and naming one of a curated set of real, dangerous C
  functions (`NATIVE_DISCLOSURE_C_FREE_FNS`: `system`/`unlink`/`mkdir`/`rename`/`fork`/`dlopen`/`dlsym`/…
  — the SAME collision-prone names `kappaFree`'s own comment already named as deliberately excluded from
  concrete classification). AN ALLOWLIST, not this codebase's usual denylist pattern — the first cut had
  no name restriction at all ("unresolved + C-module import" alone) and MEASURED 1519 false hits on
  swift-nio in the 13-package corpus this fix was calibrated against: `#if os(Linux)` / `#if
  canImport(Glibc)` build-config predicates (this engine reads both `#if` arms unconditionally and walks
  the condition expression itself as an ordinary call), `assert`/`fatalError`/`precondition`, and bare
  operators — none of them FFI. Narrowed to the explicit allowlist: 0 new disclosures in 12 of the 13
  packages, and exactly 3 genuine hits in the 13th (swift-syntax) — a real `dlopen(path, RTLD_LAZY |
  RTLD_LOCAL)` in its plugin loader, a real `kill(pid_t(...), SIGKILL)` in its CLI's process-reduction
  tool, and one more `unsafeBitCast`-to-function-pointer site (FIX 2) doing runtime metadata
  introspection — all three spot-checked against source, zero fabrications, zero noise.

  CONTROLS held: `Process`/`URLSession`/`FileHandle` stay concretely charged, unmoved, on every fixture.
  `swift test` (896/896), `smoke.sh` (148/148), `fuzz.py` (25/25) all pass. A pre/post binary diff over
  all 13 corpus packages AND this repo's own source is function-count-identical outside the 3 genuine
  swift-syntax hits above — zero regressions, zero incidental fabrications.

- ⚠ **A constrained-extension MEMBER's call edge never reached its caller — three shapes, one narrow
  root cause each.** `deny Net` scoped to a caller (`pure callConditional` / `pure callWhereExtension` /
  `pure callComposed`) exited 0, "policy ✓", over a caller that transitively reached `URLSession` through:
  (1) conditional conformance of a user generic type (`extension Box: Greeter2 where T: Greeter2 { func
  greet2() { value.greet2() } }`), (2) a `where`-constrained extension of a stdlib collection iterated
  with a `for`-loop (`extension Array where Element: Greeter3 { func greetAll3() { for e in self {
  e.greet3() } } }`), and (3) a protocol composition parameter (`func runComposed(_ x: A5 & B5) {
  x.a5() }`). An UNSCOPED `deny Net` already flagged the leaf implementer in every case, so the effect was
  discovered — the gap was the edge from the constrained member (or composed-protocol parameter) up to
  its caller. NOT one root cause: three independent gaps in the same conceptual area (a `where`/`&`
  constraint on a type is resolved for exactly one hard-coded consumer, not generally), plus a fourth,
  unrelated gap (an untyped array LITERAL local never carried an element type at all) that was needed to
  close (2)'s caller specifically.

  FIX 1 (conditional conformance): `DeclCollector`'s extension visitor recorded a `where T: P` bound
  into `selfElementStack` only when the constrained name was literally `"Element"` (the collection
  self-iteration case) — any OTHER generic parameter (`Box`'s own `T`) was silently dropped, so the
  struct's `value: T` field never resolved to `Greeter2` and stayed the bare, undeclared string `"T"`
  forever. `recordTypeGenerics` (already used for a type's OWN generic clause) now also runs over an
  extension's `where` clause, feeding the general `typeGenericBounds` map. Ordering hazard: DeclCollector
  is a single top-to-bottom pass per file, and the struct's field is very often visited BEFORE the
  extension that supplies the bound (as in the fixture), or the extension lives in a different file
  entirely — so an unresolved generic-typed field is now deferred (`unresolvedGenericFields`, new
  `typeGenericParamNames` gate) and retried once, in `Driver`, after every file's bounds are merged —
  mirroring `staticFactoryFields`'s existing two-phase shape one level down.

  FIX 2 (where-constrained collection extension via a `for`-loop): `selfElementType` (the bound `where
  Element: P` establishes on `self`) was already computed and already consumed by the CLOSURE-iterator
  path (`forEach { $0.persist() }`, R28) — but never by the `for`-loop path (`elementTypeOf`), so the
  identical extension body read silent-pure when spelled as a loop instead of a closure call.
  `elementTypeOf` now also checks `self` against `selfElementType`.

  FIX 3 (protocol composition parameter): `typeName` has no case for `CompositionTypeSyntax` at all
  (`A & B` collapses to no name), so a `_: A5 & B5` parameter was left completely untyped — none of
  `DeclCollector`'s param-typing branches fired. A new `compositionTypeNames` helper records every
  LOCALLY-declared composed protocol; the encoding reuses `protoParams`/`protoTyped` (a single
  `String`, joined with a control-character separator no Swift identifier can contain) rather than
  adding a new per-binding map, so the composition case gets `protoTyped`'s entire shadow-save/clear
  discipline for free instead of needing its own (`NameKeyedStateTests` enumerates every NEW stored
  property on `CallCollector` and requires it classified — reusing an existing map sidesteps that
  surface entirely). The one dispatch site this feeds (`x.a5()`) now emits one `ProtoDispatch` per
  composed protocol; `Driver`'s existing `protoOrSuperDeclares` guard already no-ops on a protocol that
  does not declare the called member, so trying `B5` for an `a5()` call costs nothing.

  FIX 4 (untyped array-literal local, needed to close FIX 2's caller): `let arr = [NetThing3()]` — no
  type annotation — fell through every branch of the untyped-local initializer chain (not a closure, ctor
  call, singleton accessor, sequence/subscript, or free-function alias), so `arr` never got an
  `arrayElem` entry and `arr.greetAll3()` in the caller couldn't resolve to `Array.greetAll3` at all. A
  new branch resolves an `ArrayExprSyntax` literal's element type via `rootOf` on each element,
  conservatively: only when EVERY element resolves to the exact same concrete type (never guessed on a
  mixed or unresolvable literal).

  MEASURED on the 13-package real-world corpus (Alamofire, CryptoSwift, Nimble, PromiseKit, Quick,
  ReactiveSwift, RxSwift, swift-algorithms, swift-collections, swift-syntax, swift-nio, SwiftyJSON,
  Swinject), standalone, before/after byte comparison: 11/13 byte-identical. swift-nio: one function's
  informational `calls` list narrowed by 3 entries (an overload-argument-type match that used to fall
  back to "union every overload" now has a real, if imprecise, argument type) — the function's own
  verdict was already `Unknown` for an unrelated reason both before and after, and the callee
  (`ByteBuffer.writeBytes`) is a pure in-memory buffer op, so no verdict anywhere in the corpus changed;
  this is the same measured, accepted trade-off this file already documents for the parameter case
  (`some P`/`<T: P>` resolving to its bound over an arg-type match). swift-syntax: one NEW, honest
  `Unknown` (`Array.makeLiteralSyntax`, `dispatch:ExpressibleByLiteralSyntax.makeLiteralSyntax`) where a
  `for`-loop-over-`self` call inside `extension Array: ExpressibleByLiteralSyntax where Element:
  ExpressibleByLiteralSyntax` previously resolved to nothing at all — a genuine, disclosed gain, not a
  fabrication. Zero fabrications, zero lost effects, zero lost verdicts across all 13 packages.

  CONTROLS held: existential receivers, retroactive conformance from another module, and
  extension-shadows-extension (`fixtures/protopure` in the corpus round this fix came from) are
  unchanged — same functions, same effects, before and after.

  FOUR new unit tests (`ConstrainedExtensionCallerEdgeProcessTests`), one per shape above plus the
  mixed-element-array rename control — each with a PURE control in its OWN package (not a second
  function beside the defect in the same file: the bounded CHA these fixes route through unions EVERY
  local conformer of a generic bound, a pre-existing and deliberate design this codebase already
  documents, so a same-file pure control would still read effectful for a reason unrelated to the fix
  — caught by running the control before trusting it).

## [0.33.1] — 2026-08-27

- ⚠ **An overloaded protocol-extension PROVIDED member vanished — not even `Unknown` — the moment a
  CONCRETE (non-protocol-typed) receiver reached it.** `protocol Runner { }`, one provided member
  `run(times:)` doing `Exec`: `S: Runner` with no override, `s.run(times: 3)` from `useS` — `deny
  Exec` correctly exited 1. Add ONE unrelated sibling overload to the same extension (`func run()`) and
  nothing else changes: `deny Exec` exits 0, `policy ✓`, and the callgraph shows `useS: []` — the
  cardinal sin. ROOT CAUSE, Driver.swift's "PROTOCOL-EXTENSION DEFAULT via a CONCRETE receiver" arm
  (`s.run(...)` where `S` declares no `run` of its own): it called bare `resolveQual("\(sup).\(member)")`
  with no `overloadedBases` check at all, unlike its own sibling arm three lines up (the `call.typed`
  branch) and the existential-receiver `protoDispatches` arm, both of which already route an overloaded
  base through `matchOverloads`. `resolveQual` can only name an UNAMBIGUOUS simple->full mapping, so the
  second overload made the lookup ambiguous and the ONLY edge to the provided member — the call site's
  sole reach to `Runner.run(times:)` — was dropped silently.

  FIX: the same branch now checks `overloadedBases.contains(base)` and routes through `matchOverloads`
  exactly as its siblings do — `argc`/`call.argTypes` are already captured at this call site, so an
  arity/type-discriminated call (`run(times:)` vs `run()`, different arity) resolves PRECISELY to the one
  real callee, and a genuinely ambiguous call (same arity, indistinguishable types — this engine does not
  model argument LABELS, so `run(_:)` vs `run(y:)` looks identical to it) gets the sound UNION rather than
  a drop or a guess, mirroring `matchOverloads`'s own existing over-approximation direction. A prior fix
  in this family (the shellOut name-heuristic shadow) deliberately chose winner-take-all over union to
  avoid fabricating a NEW effect over a real resolution; that does not apply here — there is no winner,
  resolution has already failed, and the choice is between a sound union and a silent drop.

  THREE CONTROLS, unit-pinned (`DriverResolutionProcessTests.testOverloadedExtensionProvidedMember
  StillResolvesThroughAConcreteReceiver` / `testLocalOverrideStillWinsOverBothProvidedOverloadsOnA
  ConcreteReceiver` / `testGenuinelyAmbiguousOverloadOnAConcreteReceiverUnionsRatherThanGuesses`): the
  non-overloaded case is untouched; a genuine local override on the concrete conformer still wins over
  both provided overloads (the earlier `resolveQual(call.path)` check in the same `call.typed` branch is
  unchanged); a same-arity, label-only-distinguished pair unions rather than guesses. BYTE-IDENTICAL
  across the majority of a 13-project real-world corpus (Nimble, Quick, CryptoSwift, PromiseKit,
  ReactiveSwift, SwiftyJSON, Swinject — checksum-verified against the pre-fix binary); the other six
  (Alamofire, RxSwift, swift-algorithms, swift-collections, swift-nio, swift-syntax) legitimately DIFFER
  because they contain this exact shape, and every diff across all six was traced: zero functions lost a
  previously-disclosed effect, all changes are gains — an ambiguous reach resolving from a guessed
  `Unknown` to a precise (often still-pure) target, or a genuinely missed effect surfacing for the first
  time. One trace followed end to end: swift-nio's `BaseSocketChannel.close0` reaches `ChannelCore
  .removeHandlers(Channel)` — a real, always-overloaded (`Channel`/`ChannelPipeline`) provided member —
  which chains through the live event-loop machinery to `NIODeadline.timeNow`, a genuine `Clock` read on
  every channel close that this engine had never charged to any of ~35 `BaseSocketChannel` methods until
  this fix.

  **KNOWN RESIDUAL, filed rather than routed around:** `matchOverloads` module-scopes its FREE-function
  union (`hitsInCallerModule`) but not its MEMBER-call union — pre-existing, unchanged by this fix, and
  shared by every other call site already using it. swift-nio surfaced it directly: `FileSystemProtocol`
  is declared independently in two separate targets (`NIOFS` and `_NIOFileSystem`), each with its own
  `withDirectoryHandle` overload, and a member-call union cannot see that a caller in one target can never
  reach the other's declaration. No observable over-charge in this corpus (both candidates already read
  `Unknown`, so the union is idempotent), but the shape is the member-call twin of the free-function
  shadow-scoping fix two entries below, unrepaired here.

- ⚠ **`outOfScope`/`scannedUnder` collapsed "asked and clear" into "never asked" over a tree with
  NOTHING excluded.** SPEC §2 ⟨0.29⟩/⟨0.33⟩ binds both keys PRESENT iff a policy was CONFIGURED and
  HONOURED — full stop, never conditioned on there being anything to peek — and present-and-empty IS a
  claim (*a policy stood and it denied nothing*) that MUST NOT collapse into ABSENT (*nothing was
  asked*). This engine additionally gated the whole peek block on `!peekable.isEmpty`, so a policy
  honoured over a tree with a genuinely empty `excluded` answered with BOTH keys omitted — the ⟨0.26⟩
  partial-manifest collapse one level out. MEASURED: a bare directory of `.swift` files (no
  `Package.swift`, nothing under `Tests/`/`.build/`) has zero excluded files, so `deny Exec` over it
  answered `policy ✓` at exit 0 with neither key present, while candor-java and candor-rust emit
  `outOfScope: []` beside `scannedUnder: {"deny":["deny Exec"]}` on the identical tree (candor-java's
  reference commit `05dfa53`). It fails CLOSED — an absent `scannedUnder` reads as the empty deny set
  and a no-exclusion report has no peeked class for a gate to consult — so nothing certified wrongly;
  it is a false statement about what was asked. INVISIBLE on every ordinary SwiftPM package, because
  `Package.swift` is always excluded as `manifest` (a `PEEKED_CLASSES` member) whenever a `deny`/`pure`
  rule stands, so `peekable` was never actually empty there.

  FIX: the outer condition drops `!peekable.isEmpty`; `report.outOfScope`/`report.scannedUnder` are now
  set whenever `!peekRules.isEmpty` (a policy configured and honoured), with the child-process peek
  itself still skipped when there is nothing to hand it (`peekable.isEmpty`) — `found` stays `[]` by
  construction rather than by never having been asked. THREE CONTROLS, unit-pinned in
  `FileSetScopeProcessTests.testAPolicyHonouredOverATreeWithNothingToPeekStillAnswersAskedAndClear`: no
  policy still omits both keys; a policy the engine REFUSES still omits both (§3.1 — the peek may not
  certify relative to a gate that evaluated nothing); a tree WITH exclusions is byte-identical to
  before, checksum-verified against the pre-fix binary rather than eyeballed.

  **CORRECTS THE ENTRY BELOW AND THE KNOWN RESIDUAL IT FILED.** "NIL under exactly `outOfScope`'s own
  emission rule" was true as an internal-consistency statement — the two keys were always set together
  — but that shared rule itself silently carried the `!peekable.isEmpty` gate this entry removes, which
  the entry below never disclosed. Its KNOWN RESIDUAL filed the symptom as "a conformance FIXTURE gap
  for the swift row specifically" (PART 69's "tree D" is never actually empty for this engine); that
  framing undersold it. The fixture gap is real and independent — PART 69 reads `swift ... OK`
  identically before and after this fix, because its own tree still carries a `Package.swift` — but the
  fixture never being able to reach the case is exactly how a real emission-rule defect stayed a
  documented limitation instead of a measured one: the comment was correct about the fixture and silent
  about the code.

- **`release.yml` gains `workflow_dispatch`, because a stalled Actions queue leaves a
  tag-triggered release unrecoverable.** During the 0.33.0 cut GitHub created this repo's release
  run and never expanded it into jobs: zero jobs, `updated_at` equal to `created_at` two hours on,
  and both cancel and force-cancel refusing with 409 *"has not been queued yet"*. A run in that
  state cannot be rerun either, so the only recovery was deleting and re-pushing a tag a live
  Release already points at. candor-ts hit the identical stall and recovered in seconds because
  its publish workflow already carried this trigger. Re-running is safe: the steps are idempotent
  and the `engineVersion` guard still asserts the tag matches the binary before anything ships.

- **`ci.yml` gains `workflow_dispatch` too.** The stall above hit `release.yml`; auditing the rest of
  this repo's workflows for the same gap found `ci.yml` had no dispatch trigger either, so a stalled
  push-triggered run here had no recovery but an empty commit. The `test`/`release-build`/`linux` jobs
  already gate on `github.event_name != 'schedule'`, so a dispatch runs them exactly like an ordinary
  push; the linux job's disclosure-recall step already special-cased `== 'workflow_dispatch'` in its
  own `if:`, which was unreachable dead code until this trigger existed.

- ⚠ **A NAME heuristic (`kappaFree`'s `shellOut`, and the whole table it belongs to) pre-empted a real,
  in-tree, unambiguous overload resolution — the cardinal sin.** `shellOut(to: Int)` calling its own
  sibling `shellOut(to: String)` (JohnSundell's ShellOut, real code) reported `Exec`/`cmds:["literal"]`
  and dropped the sibling's real `Fs`, with no `Unknown`, no `incomplete` — the shadow guard
  (`localFreeFns`) is drawn from `freeFnByName`'s keys, read AFTER the overload-suffix rewrite renames
  `shellOut` to `shellOut(Int)`/`shellOut(String)`, so the BARE identifier a call site actually uses
  (Swift never spells the disambiguator) no longer matched anything in the shadow set once a project
  overloaded a heuristic-covered name. GATE-LEVEL: a two-package `App`/vendored-ShellOut fixture had
  `deny Fs`/`deny Ipc` exit 0 — *"nothing hidden"* — over code that plainly performs both, and
  `path setupRepo Fs` answered a confident, wrong `does not perform Fs (inferred: ["Exec"])`.

  FIX, two halves, both MODULE-scoped (see below) and BOTH restore precedence to real resolution rather
  than replacing the heuristic outright — it still fires whenever resolution genuinely cannot:
  (1) Driver.swift now also shadows on each free function's BARE name, captured before the overload
  rewrite; (2) the same discipline now crosses the scan boundary — a CHAINED (`--workspace`/
  `CANDOR_DEPS`) dependency's overloaded free function shadows the heuristic too, and the cross-package
  join answers with the UNION of every overload sharing the base name (Deps.swift), never a guess at
  which one, mirroring `matchOverloads`'s own sound-union direction for an in-tree ambiguous call.

  MODULE-SCOPED, not scan-wide, and the scoping is load-bearing: an unscoped first pass regressed 1137
  functions on the swift-nio corpus, where a Windows-only `#if os(Windows) func getenv(...) {
  fatalError(...) } #endif` stub in one target shadowed `getenv`'s real `Env` charge for every OTHER
  target in the scan — a name heuristic pre-empted by a declaration the caller's own module cannot even
  see, the opposite direction from the defect this closes. `matchOverloads` already draws this exact
  module line for RESOLUTION; the SHADOW guard now draws it too.

  CONTROLS, unit-pinned (`NameHeuristicOverloadShadowProcessTests`) and measured against the published
  binary: an out-of-tree/unresolvable `shellOut` still charges `Exec` (the heuristic is not deleted); an
  overload in one target does not shadow an unrelated target's heuristic call (the swift-nio control); a
  tree with no such name collision is BYTE-IDENTICAL, checksum-verified against the pre-fix binary
  across an 11-project real-world corpus (Alamofire, vapor, SQLite.swift, swift-async-algorithms,
  swift-log, swift-crypto, Files, Kingfisher, ZIPFoundation, GRDB.swift, a bare no-manifest tree).

  **KNOWN RESIDUAL, filed rather than routed around:** the SAME-module case of the swift-nio interaction
  above is not fully closed — a `#if`-guarded platform stub sharing a heuristic name with the REAL
  cross-platform call site it stands beside (both in ONE module) still shadows, because this engine
  reads every `#if` branch unconditionally (it never models a build configuration) and, independently,
  already treats "a locally-declared name always shadows the platform table" as policy everywhere else
  in this file (the GRDB `bind` lesson, stated verbatim beside the code this change touches). Measured:
  6 functions in swift-nio's `_NIOFileSystem`/`NIOFS` lose a real `Env` tag to their own module's
  Windows-only `getenv` stub, though each keeps an `Unknown` disclosure from elsewhere in the same
  function — a softer residual than the shellOut defect (never a *confident* wrong denial), but a real
  one, and a conformance row should assert it does not regress further.

- ⚠ **CLOSES THE RESIDUAL ABOVE. A `#if`-gated stub silently shadowed a κ heuristic with NO hedge at
  all — not even the `Unknown` the residual's own words claimed was always there.** `#if os(Windows)
  func getenv(_:) -> ... { fatalError(...) } #endif` beside `if let v = getenv("PATH") { ... }` in the
  SAME module, no `#else`: `deny Env` exited 0, `policy ✓`, `functions` EMPTY — `path realUsage Env`
  answers "no function matching 'realUsage'". This engine models no build configuration, so
  `DeclCollector` reads every `#if` branch unconditionally and the Windows-only stub is exactly as
  visible as a real declaration — permanently shadowing the heuristic for every build, including the
  one that never contains the stub.

  FIX: `FnInfo` now carries `isConditionallyCompiled` (any `#if` depth, any condition, with or without
  `#else` — the engine cannot evaluate any of them). The shadow sets that feed `localFreeFns`
  (`freeFnUnconditionalQuals` scan-wide, `conditionalOnlyFreeFnNamesByModule` per-module, mirroring the
  shellOut fix's own module line) now exclude a name whose ONLY declaration(s) are conditional — a name
  with even one unconditional declaration keeps shadowing exactly as before (a real resolution exists,
  winner-take-all is right). A name shadowed ONLY by a conditional declaration is passed separately as
  `conditionallyShadowedFreeFns`: the κ heuristic fires (the call may genuinely reach the real platform
  function), and the ordinary call edge to the conditional declaration is ALSO kept, so the two readings
  UNION rather than one winning outright — resolution has not failed here, it is conditional, and that
  is the same direction `matchOverloads` already takes when an overload cannot be ruled out. The
  distinction the shellOut fix drew stands: winner-take-all when a real resolution exists, union when it
  is conditional or has failed.

  GENERAL TO THE WHOLE TABLE, not `getenv`-specific: the fix operates on the shadow-SET construction, so
  it applies uniformly to every `kappaFree` name (the ~35 switch-case names, the 16 `CAPABILITY_
  SPELLINGS` free spellings, and the model-SDK/privacy-SDK ctor tables gated by the same `localFreeFns`
  check) — none of them is named in the fix itself.

  CONTROLS: `ifhedge-A` (the fixture above) goes exit 1/`Env` after being exit 0/empty before;
  `ifhedge-control` (same code, no `#if` at all) is unmoved at exit 1 throughout; a NEW
  `ifhedge-unconditional` fixture (an unconditional same-module local `getenv`) proves the shadow still
  holds when a real declaration exists — unmoved at exit 0 throughout. Checksum-verified BYTE-IDENTICAL
  against the pre-fix binary across 12 of the 13-project real-world corpus (swift-collections,
  swift-algorithms, swift-syntax, Quick, Nimble, SwiftyJSON, RxSwift, Swinject, PromiseKit, CryptoSwift,
  Alamofire, ReactiveSwift); swift-nio is the one that legitimately differs, and every one of its 6
  changed functions was traced: `Libc.homeDirectoryFromEnvironment()` (both `NIOFS` and
  `_NIOFileSystem` copies) and the `temporaryDirectory`/`homeDirectory`/`withTemporaryDirectory` callers
  above them each gain `Env` alongside their existing `Unknown` — exactly the residual's own predicted 6
  functions, no function count change, no other effect column moved (`Env 1166 -> 1172`, everything else
  byte-identical), and no over-charge.

  **RESIDUAL, filed rather than routed around:** the DECLARED-TYPE analogue of this same defect (a
  `#if`-gated `class`/`struct` of the same name as a κ-platform type shadowing `declaredTypes` the same
  way) is not addressed here — measured to exist by construction (the same unconditional `#if` read
  applies to type decls), unmeasured in the wild, and left for a separate pass. The Bonjour/EventKit/
  privacy-capture bare-ctor arms share `localFreeFns` and so inherit the shadow-removal automatically,
  but not the union call-edge addition (added only to the primary `kappaFree` arm) — a `#if`-gated local
  type of one of those exact names would get the heuristic back but not a union with its own effects. A
  conformance row should assert the `ifhedge-A`/`ifhedge-control`/`ifhedge-unconditional` triple.

- ⚠ **CLOSES THE DECLARED-TYPE RESIDUAL FILED DIRECTLY ABOVE, now constructed and firing.**
  `DeclCollector.pushType` inserted into `declaredTypes` UNCONDITIONALLY — it never consulted
  `ifConfigDepth`, unlike `FnInfo.isConditionallyCompiled` above. `declaredTypes` is the fence the
  constructor heuristic (and the Bonjour/EventKit/privacy-capture ctor arms beside it) uses to decide a
  bare `Pipe()` means `Foundation.Pipe` (→ `Ipc`) rather than a local type:

      import Foundation
      #if os(Windows)
      class Pipe { init() { fatalError("shim") } }
      #endif
      func realUsage() -> Pipe { return Pipe() }

  `deny Ipc` exited 0, `functions` EMPTY — no `Unknown`, no `incomplete`, nothing; `typeSurface.returns`
  showed `TS#realUsage : TS#Pipe`, proving the engine had resolved to the local shadow before charging it
  nothing at all.

  FIX: `DeclCollector.declaredTypesUnconditional` is the type analogue of `isConditionallyCompiled` — the
  subset of `declaredTypes` declared outside any `#if`, aggregated scan-wide in the Driver the same way.
  `Driver.conditionallyShadowedTypeNames` (`declaredTypes.subtracting(declaredTypesUnconditional)`) is
  passed to `CallCollector` as a NEW field, `conditionallyShadowedTypes` — deliberately NOT a blanket swap
  of what `CallCollector.declaredTypes` itself holds (see the reverted-and-narrowed note below). The four
  BARE-CONSTRUCTOR κ arms (`kappaFree`, privacy-capture, Bonjour, EventKit — all in
  `visit(FunctionCallExprSyntax)`'s bare-identifier branch) now also fire when a name is in
  `conditionallyShadowedTypes`, and each keeps the ordinary call edge to the conditional declaration
  alive alongside the κ charge — UNION, not winner-take-all, the same discipline `conditionallyShadowedFreeFns`
  established for free functions. A name with even one UNCONDITIONAL declaration is unaffected (winner-
  take-all, unchanged) — verified with a control: `class Pipe { init() {} }` with no `#if` at all still
  resolves `realUsage` to its own pure init, zero `Ipc`.

  NARROWED FROM A BROADER FIRST ATTEMPT, REVERTED. Passing the restricted set as `CallCollector`'s main
  `declaredTypes` field (unscoped, matching every one of its ~15 uses) changed 16 swift-nio functions,
  and several LOST their existing `Clock`/`Env`/`Unknown` outright in favour of a bare `Net` —
  `ClientBootstrap`/`ServerBootstrap`/`DatagramBootstrap` are each declared exactly once, inside
  `NIOPosix/Bootstrap.swift`'s file-wide `#if !os(WASI)` with no alternate declaration anywhere, so they
  read as "conditional-only" under the naive rule, and NIOPosix's own INTERNAL self-dispatch between
  their overloads — resolved locally before this — fell to the blunt cross-package heuristic instead,
  losing real precision. `conditionallyShadowedTypes` is therefore consulted ONLY by the four bare-
  constructor arms, never by the typed-receiver `kappaMember` dispatch path (`bootstrap.connect(...)`),
  matching the shape of the original defect exactly (a bare `Pipe()` call has no internal-self-dispatch
  risk). Re-running the 13-project corpus after narrowing: all 13 are BYTE-IDENTICAL to the pre-fix
  binary (this defect's shape — a `#if`-gated STUB TYPE colliding with a bare-constructor κ spelling — is
  not present in this corpus; the fix is proven by four synthetic fixtures instead: the `Pipe`/`Ipc`
  repro above, `AVCaptureDevice`→Camera+Mic, `EKEventStore`→Calendar+Reminders, and `NWBrowser`→Net, each
  confirmed absent pre-fix and present post-fix). `098a035`'s own getenv fixture (`Env`) and the
  swift-nio corpus row it measured are unmoved.

  CONTROLS: an unconditional local `Pipe` still shadows fully (unmoved, exit 0 on `deny Ipc`); the
  no-`#if`-at-all control is unmoved (exit 1); the conditional stub's own `NSLog` unions to `["Ipc",
  "Log"]` on `realUsage`, mirroring the getenv fix's `["Env", "Log"]` proof exactly.

  The Bonjour/EventKit/privacy-capture arms ARE affected — verified, not assumed, with the three
  fixtures above, each going from silent-pure to their correct over-disclosure.

  **A REVIEW PASS FOUND ONE MORE, WORSE THAN ANY OF THE FOUR ABOVE: `chargeContentsCtor` (the shared
  `Data`/`NSData`/`String(contentsOfFile:|contentsOf:)` family) has its OWN separate `declaredTypes` bail-
  out, not one of the four arms this fix touched first.** `#if os(Windows) struct Data { init
  (contentsOfFile:) { fatalError() } } #endif` beside `Data(contentsOfFile: path)`: `functions` came back
  completely EMPTY for the caller — not even the `Unknown`/ordinary-call-edge the other four arms fall
  back to when shadowed, because this arm returns `false` and the CALLER (the bare-identifier chain) had
  nothing else to try for a name shaped like a type constructor with no matching κ family — so the `Fs`
  charge vanished with literally nothing left behind. Same fix, same set: the guard is now `declaredTypes
  .contains(name) && !conditionallyShadowedTypes.contains(name)`, and a `unionConditionalTypeEdge` helper
  (factored out of the four arms' identical three-line block, tightening the duplication a reviewer also
  flagged) keeps the conditional declaration's own call edge alive here too. Verified with the same
  triple: the `Data`/`Fs` repro goes empty→`["Fs"]`; an unconditional local `Data` still shadows fully
  (`realUsage` absent, resolves to its own pure init); the conditional stub's own `NSLog` unions to
  `["Fs", "Log"]`. Re-ran the 13-project corpus after this second fix too — still byte-identical across
  all 13.

  RESIDUAL: none measured, this time checked by an independent review pass rather than asserted from the
  four arms alone. A conformance row should assert the `Pipe`/`AVCaptureDevice`/`EKEventStore`/
  `NWBrowser`/`Data` five-way, plus a swift-nio-shaped negative control (a type whose ONLY declaration
  sits inside a broad `#if !os(X)` file guard, with internal self-dispatch between its own overloads,
  must not lose its typed-receiver resolution) — the shape that sank the first attempt at this fix.

- **AUDIT: an inventory of every "I can't resolve this" site in Driver.swift/CallCollector.swift/
  GateReportCLI.swift, following the four defects above (all of which share one shape: a real callee
  existed and the code that would have said so said nothing instead).** `GateReportCLI.swift`'s report-
  merge same-name resolver already does this right (`guard let cands = byName[c] else { continue }`, then
  `count == 1` edges and anything else CONTRIBUTES `Unknown`+`dispatch` — never a third, silent option).
  `Driver.swift`'s `resolveQual` does not: `if let cands = qualBySimple[target], cands.count == 1 { return
  cands.first }; return nil` folds "no candidate at all" and "2+ same-simple-name candidates, a real
  callee runs" into the same `nil`, and none of its ~15 call sites can tell the two apart. This is the
  same shape as the four fixes above, so it was tried as the session's "one funnel" step: a `QualResolution`
  enum (`.found` / `.absent` / `.ambiguous`) plus a `resolveOrDisclose` exit that discloses `Unknown` with
  a `dispatch:` reason on `.ambiguous` instead of silently returning `nil`, wired through all ~15 sites.

  **MEASURED, THEN REVERTED: this floods.** Re-running the 13-package corpus diff (the standing control for
  any Driver.swift change, per the swift-nio 1137-function regression this project has already paid for
  once) showed 6 of 13 packages differing, 116 newly-`Unknown` functions in total. Spot-checking them: they
  are overwhelmingly `Options.init`, `Index.==`, `Iterator.next`, `State.init`, `Configuration.init`,
  `Header.capacity`, `SubSequence.init`, `Words.init` — nested-type names that are pervasive, ordinary
  Swift idioms (nearly every specialized `Collection` declares its own `Index`; nearly every configurable
  type its own `Options`/`Configuration`), each colliding in `qualBySimple` because that index is keyed on
  the innermost simple name alone, with no outer-container context — the exact same collision the index's
  own comment already documents ("a simple key with MULTIPLE full quals is a genuine same-named-nested
  collision... the edge is dropped (honest under-report, NEVER a fabricated effect)"). Unlike the four
  defects above, `resolveQual`'s ambiguity is not a rare, discriminable case with a real single answer
  being thrown away — it is the ordinary, expected shape of this index, and the ONE genuine instance of it
  that WAS a cardinal sin (the overloaded-provided-member fix, `[0.33.0]` above) was fixed by routing
  around `resolveQual` entirely (`matchOverloads`, discriminated by arity/argument type), not by making
  `resolveQual` itself disclose. Converting resolveQual's ambiguity into a blanket `Unknown` is a real
  regression in the other direction this task explicitly warned about, and it is also non-conservative:
  Unknown propagates transitively, so the 116 direct sites cascaded into further callers gaining `Unknown`
  with no `dispatch:` reason of their own. Reverted; `resolveQual` is UNCHANGED. Closing this class for
  real needs `qualBySimple` (or its callers) to carry enough outer-container context to disambiguate most
  of these precisely, the way `matchOverloads` disambiguates by arity/type — a bigger job than fits one
  pass, filed rather than forced.

  **SHIPPED INSTEAD — the smallest safe step found:** the CHA "is this conformer set small and non-empty
  enough to trust individually, or must the dispatch be disclosed" decision was ITSELF duplicated, with the
  polarity flipped, between the method-dispatch CHA (`protoDispatches`, `!conf.isEmpty && conf.count <= 12`
  gating resolution) and the property/subscript-read CHA (`protoPropReads`, `conf.isEmpty || conf.count >
  12` gating disclosure) — the same `≤12`-bound decision, same `dispatch:` reason string, two places it
  could silently drift apart. Extracted to one `chaWithinBound` closure both loops now call; each loop's
  own additional completeness test (`protoDispatches`' `impls.count == conf.count || providedEdged`,
  needed because an extension-default-satisfied conformer has no override to find) is unchanged and sits
  on top of it. Proven behaviour-preserving, not merely reviewed: byte-identical `--json` output across all
  13 corpus packages before/after, and all four defects above re-verified fixed post-refactor (`useS` in
  the overloaded-provided-member fixture still resolves to `Runner.run(times:)`'s `Exec` rather than the
  stale reference capture that predates this session; the `#if os(Windows)`-shadowed `getenv`/`Pipe`
  fixtures still disclose `Env`/`Ipc` off the real heuristic, not the stub; the shellOut workspace fixture
  is byte-identical scanned with and without `.build/checkouts` present). A synthetic 13-conformer
  existential-dispatch fixture (one over the `≤12` cap) confirms the merged `chaWithinBound` path still
  discloses `Unknown` / `dispatch:Speaker.speak` exactly as the two separate implementations did.

  RESIDUAL, filed rather than fixed here: `resolveQual`'s no-outer-context ambiguity (above); a
  module-qualified free-function CALL (`Core.shared()`) whose target module declares an OVERLOADED
  `shared` falls through every branch with neither a resolution nor a disclosure (the module-qualified-call
  branch requires `inMod.count == 1`; every other branch requires `call.typed` or `call.unqualified`, both
  false for this call shape) — plausibly rare, unmeasured against the corpus, and not attempted this
  session given the `resolveQual` result above.

- ⚠ **CARDINAL SIN, CLOSED: `protoPropReads` had NO disclose-on-miss branch at all, stacked on
  `resolveQual`'s ambiguous-fold from the entry above — a protocol PROPERTY read through a colliding
  simple name went completely silent.** `protocol Loud { var value: Int { get } }`, `enum Outer1 {
  struct Config: Loud { var value: Int { /* reads /etc/hostname */ } } }` beside an UNRELATED `enum
  Outer2 { struct Config { var value: Int { 42 } } }` (not a conformer): `func use(_ l: Loud) -> Int {
  l.value }` — `caller`/`use` were absent from `functions[]` entirely, `--policy pure use` exited 0
  ("nothing hidden"), `unverified --strict` answered `{"ok":true,"unverified":[]}`, and `path use Fs`
  found nothing. Holding `Outer2.Config` constant and deleting only the collision restored the edge and
  flipped the gate red — the single variable is the colliding simple name, and the direct control
  (`--policy pure Outer1.Config.value`) already caught the effect, proving the engine SAW it and lost it
  only on the way to the caller. Two omissions stacked: `qualBySimple["Config.value"]` held both
  `Outer1.Config.value` and `Outer2.Config.value` (DeclCollector keys on the innermost simple name,
  outer nesting dropped), so `resolveQual` folded to `nil`; and unlike its neighbour `protoDispatches`
  (`impls.count == conf.count || providedEdged` else `Unknown`), `protoPropReads` never disclosed
  anything on any kind of miss — an ambiguous collision and "this conformer stores it, nothing to
  charge" read identically, silently.

  FIX, both omissions. **`resolveQual` now UNIONS instead of hedging**: `if let cands =
  qualBySimple[target] { return cands }` (was `cands.count == 1 ? cands.first : nil`) — every real
  candidate a colliding simple name could mean is edged, not one arbitrarily chosen and not all
  silently dropped. An all-pure collision (the ordinary shape the reverted entry above measured)
  contributes nothing new either way — no charge, no noise; a collision where any candidate is
  effectful now correctly reaches it. This is the SAME over-approximation direction `matchOverloads`
  and the `#if`-branch union already take in this file, and it is why the flood the entry above
  measured does not recur: the 13-package corpus (the standing control for any Driver.swift change)
  shows 7 of 13 packages differing, but only **75** newly-`Unknown` functions — well under the 116 the
  reverted funnel produced — and every single one of the 75 is a NEW appearance (previously silent-pure)
  with `inferred: ["Unknown"]` and nothing else: zero fabricated concrete effects anywhere in the diff.
  The cost is real and accepted, not hidden: a pure caller unioned with a same-simple-name sibling that
  is ITSELF `Unknown` now inherits that `Unknown` too (traced on swift-algorithms' `Iterator.next`,
  unioned 16-wide across the package's iterator types) — an honest over-charge, never a silent miss, the
  same bounded-CHA cost every other ambiguous-dispatch arm here already pays. One trace found the union
  gaining PRECISION instead: swift-nio's `NIOHTTP1TestServer.handleChannels` went from a blanket
  `dispatch:NIOSynchronousChannelOptions.setOption` `Unknown` to three real edges plus a newly-visible
  `Clock` reach, because the three colliding `SynchronousOptions.setOption` conformers now all resolve
  together instead of none of them resolving individually.

  **`protoPropReads` now has the disclose-on-miss branch its neighbour has.** A conformer is "accounted
  for" when `resolveQual` resolves it (via the union above) OR `fields[c][d.member]` still knows the
  member — DeclCollector records a `fields` entry for EVERY property with an explicit type annotation,
  stored or computed, and a computed property always carries one (Swift requires it), so an empty
  `resolveQual` result beside a `fields` hit means "declared here, stored, pure" (nothing to charge, the
  case the neighbouring loop has no equivalent of and the reason it was left silent rather than copying
  `protoDispatches`' check verbatim); empty AND absent from `fields` means the requirement is satisfied
  somewhere this loop never looked — genuine miss, now `Unknown` + `dispatch:` reason, never both, never
  neither, matching the method loop's existing discipline exactly. Measured finding this immediately
  surfaced in the corpus: Nimble's `NMBDoubleConvertible` has three conformers (`NSNumber`, `Date`,
  `NSDate`); `NSNumber`'s conformance is an empty `extension NSNumber: NMBDoubleConvertible {}` — no
  local override, satisfied entirely by NSNumber's native bridged `doubleValue` this scan cannot see —
  and the old code silently dropped that ONE missing witness while precisely editing the other two,
  never saying the conformer set was incomplete. Now correctly discloses `Unknown` for the whole
  dispatch rather than a false-precise partial union; the report's top-level verdict for the one
  affected function was already `Unknown` for an unrelated reason, so this refines the `why`, not the
  outward verdict.

  CONTROLS: the repro flips `pure use` exit 0 → exit 1, `use`/`caller` from absent to present with
  `["Fs"]`, `path use Fs` from "no function matching" to a two-hop chain through
  `Outer1.Config.value`, and `deny Fs` from one violation to three — all against a rebuilt, freshness-
  verified binary (`.build/release/candor-swift` removed and rebuilt, `--version`/`git rev-parse HEAD`
  and the binary's mtime checked together). The four defects fixed earlier in this rung are re-verified
  BYTE-IDENTICAL post-fix (`probeA`/`probeB`, the `#if`-hedge three-fixture set, the typeshadow pair, the
  `workspace-test` ShellOut fixture) — no class this session closed reopened. `smoke.sh` (148/148),
  `swift test` (884/884), `fuzz.py` (25/25), `fabrication_probe.py`, and `soundness/realworld/recall/
  recall.sh` all pass unchanged against the pinned spec commit CI uses.

  **A SEPARATE, PRE-EXISTING GAP, examined and NOT folded into this fix:** the repro's `gate --report`
  route emitted `"zeroMatch": ["pure use"]` where the scan route's `--gate-json` did not, for the
  identical `pure use` rule — flagged by the finder as possibly a §3.1 route-equality break. It is not
  one, and it is not specific to this defect: reproduced on a MINIMAL fixture with a genuinely pure
  function and no collision anywhere (`func trulyPure() { }`, policy `pure trulyPure`), the same
  divergence appears on BOTH the pre-fix and post-fix binary. The scan route resolves a `pure` rule's
  scope against every function the analysis KNOWS about (`allFns`), including pure ones; `gate --report`
  resolves it against the WRITTEN report's `functions[]`, which omits pure functions by design (they
  carry no effect to report) — so a `pure` rule over a genuinely-pure function reads as a real scope
  match on one route and a zero-match on the other, for ANY pure-scoped rule, unrelated to ambiguity or
  to this session's fix. Post-fix, the repro's OWN `pure use` divergence disappears (both routes now
  agree, because `use` is no longer pure), which is why it surfaced here at all rather than being a
  standing red in `smoke.sh`'s existing "gate --report byte-equal to scan" battery — that battery's five
  policies apparently never scope a `pure` rule onto a function that stays pure through both routes.
  Filed rather than fixed: a conformance row should assert `pure` scope-matching agrees between routes
  over a genuinely pure target, which is currently untested in either direction.

  A conformance row for THIS rung should assert the `Outer1.Config`/`Outer2.Config` collision four-way
  (or as a swift-specific case if the other three engines key differently): the effectful conformer's
  reach survives past a pure same-simple-name collision, the all-pure-collision case stays silent (no
  new `Unknown`), and a genuine per-conformer miss (a bridged/native property with an empty local
  extension) discloses `Unknown` rather than a false-precise partial edge set.

- ⚠ **A Swift MACRO was invisible, with zero disclosure — not `Unknown`, not `unanalyzed`, nothing.**
  `#urlFetch("https://danger.example.com")` (a freestanding expression macro) and `@MyBodyMacro func
  doThing() { }` (an attached macro on an apparently-empty body — the shape SwiftData `@Model`,
  `Observation`'s `@Observable`, and Swift Testing's `@Test`/`@Suite` actually take) both scanned clean
  under `deny Net`: exit 0, `policy ✓`, `functions: []`, `analyzed.count: 1`. No visitor existed for
  `MacroExpansionExprSyntax` (`#name(...)`) and no attribute handling treated a decl's own custom
  attributes as a possible attached macro, so a call reaching an arbitrary macro-injected effect read as
  though it were never there. This sat beside three siblings that were ALL already disclosed — an
  uncovered import (`invisible` + stderr), a parse failure (`unanalyzed`, fail-closed exit 2), build-only
  code (`excluded`/`peeked`) — making the macro gap the one silent exception, not a considered omission.

  A macro cannot be expanded without running its compiler plugin, out of reach for a syntax-only engine,
  so this does not attempt to resolve what a macro actually does (that would be fabrication in the
  opposite direction) — it routes the miss into the SAME disclosure vocabulary an unaddressable dispatch/
  callback already uses: `Unknown` + `unknownWhy: "macro:<name>"` (freestanding) or `"macro:@<Attr>"`
  (attached), SPEC §4. Two new visitors: `CallCollector.visit(_ node: MacroExpansionExprSyntax)` for the
  freestanding form, and a `DeclCollector`-collected `typeMacroAttrs`/`FnInfo.uppercaseAttrs` companion
  pair in `Driver.swift` for the attached form (func/init attributes were already collected for the
  `@resultBuilder` path; type-decl attributes are new). A TYPE-level attribute (`@Observable class
  Store`) is disclosed onto every member this scan already collected for that type, never a fabricated
  new unit — a type with NO collected members at all (a wholly empty `@Observable class Store { }`) has
  nothing to attach it to and stays as it already was, the same pre-existing, macro-independent blind
  spot every purely compiler-synthesized member (a memberwise init, `Equatable`'s `==`) already has here.

  THE DENYLIST IS THE HARD PART. Swift re-expressed its source-location and Objective-C interop literals
  as macros under the hood (SE-0382), so `#file`/`#line`/`#function`/`#column`/`#filePath`/`#dsohandle`/
  `#selector`/`#keyPath`/`#colorLiteral`/`#imageLiteral` parse as the identical `MacroExpansionExprSyntax`
  node a real macro does — the grammar cannot tell them apart, only the name can. The first cut of this
  list MISSED `#fileID` (SE-0274) and `#isolation` (SE-0420's `isolated (any Actor)? = #isolation`
  default), caught only by the 13-package before/after corpus diff below: swift-nio and Nimble default
  nearly every logging/assertion parameter to one of the two, and would have produced 93 and 8 hits of
  pure noise respectively. `#error`/`#warning` (this engine reads BOTH arms of every `#if` unconditionally
  — an `#else #error("…") #endif` platform stub is walked like any other code) are compile-time-only
  diagnostics and were added alongside them. Symmetrically, a LOCALLY-declared `@resultBuilder` or
  `@globalActor` type is exempted (its own existing table, or a new `globalActorTypes` one), and a small
  denylist of compiler builtins that inject no hidden behaviour (`@MainActor`, `@IBAction`, `@NSManaged`,
  …) is carved out on the same denylist-over-allowlist rule the rest of this engine uses: prove a name
  SAFE, never trust an unproven one.

  THE ONE REGRESSION CAUGHT BEFORE IT SHIPPED: a freestanding macro WITH a trailing closure (`#Preview {
  … }`) was already caught concretely — the closure body is ordinary Swift the existing
  `ClosureExprSyntax` visitor walks regardless of what contains it — and the first cut of this fix added
  `Unknown` right beside that concrete catch anyway, on every such node, unconditionally. Gated the
  disclosure on `node.trailingClosure == nil && node.additionalTrailingClosures.isEmpty`; a macro with a
  trailing closure now contributes exactly what its closure body does and nothing else, matching the
  brief's own framing precisely: "turning that into `Unknown` would be a regression from precise to
  vague."

  FALSIFIED both fixtures red before (`functions: []`) / disclosing after (`unresolved: true`,
  `unknownWhy: ["macro:urlFetch"]` / `["macro:@MyBodyMacro"]`), with `analyzed.count` unchanged in both.
  CONTROLS, all held: a name-alike non-macro (`func urlFetch(_ s: String) -> String`, `struct
  Observable`) gains nothing; a local effectful `@resultBuilder` still resolves concretely (`inferred:
  ["Net"]`, no `Unknown`); a local `@globalActor` and the builtin `@MainActor` are silent; `#file`/
  `#line`/`#function` defaults are silent. Before/after diff across all 13 real packages at
  `corpus2-swift/repos/` (Alamofire, CryptoSwift, Nimble, PromiseKit, Quick, ReactiveSwift, RxSwift,
  swift-algorithms, swift-collections, swift-nio, swift-syntax, SwiftyJSON, Swinject): every one is
  **BYTE-IDENTICAL** post-fix — none of their own top-level-scanned trees exercises a macro this fix's
  denylist doesn't already explain (real macro USAGE in this corpus lives inside nested packages a root
  scan does not cross, e.g. `swift-syntax/Examples`, its own separate `Package.swift`). Scanning that
  nested package directly confirms the mechanism end-to-end on real, macro-heavy code with zero
  fabrication: `analyzed.count` unchanged (104, identical digest), 0 → 10 macro-disclosed functions
  (`@Observable`, `@DictionaryStorage`, a generic `@MyOptionSet<UInt8>`, and five distinct freestanding
  macros including custom `#Line`/`#Column`/`#FileID`/`#FilePath` examples that are deliberately
  NOT the lowercase compiler builtins), every one carrying `inferred: ["Unknown"]` / `direct: ["Unknown"]`
  and nothing else. `swift test` (884/884), `smoke.sh` (148/148), `fuzz.py` (25/25), and
  `ci/self-gate.sh` (108 Unknown, unchanged) all pass unmoved.

  RESIDUAL, named plainly: a type carrying an attached macro attribute with ZERO collected members
  (declared, not used, in these fixtures) produces no disclosure — there is nothing in the per-function
  report model to attach it to, and inventing a synthetic per-type unit was judged out of scope for this
  fix (the brief's instruction to reuse existing disclosure vocabulary rather than mint a new one). It is
  the same pre-existing gap every compiler-synthesized member already has here, not a new one this fix
  introduces, but a spec-level decision on whether an empty macro-decorated type needs its own disclosure
  surface is open. Also open: a capitalized decl-attribute that is an EXTERNAL (not locally-declared)
  `@resultBuilder` or `@globalActor` is indistinguishable from an attached macro at the syntax level and
  is disclosed as one — sound (never a silent miss) but imprecise; none appeared in the 13-package corpus,
  so its real-world frequency is unmeasured.

## [0.33.0] — 2026-08-26

- **MIGRATION — ⟨0.33⟩ IS NOT ADDITIVE, and the cost is measured, not estimated.** If you gate a
  **STORED** report that a pre-0.33 engine produced — committed to a repo, cached between CI jobs, or
  published by a dependency and gated downstream — expect exit 2. Measured over **32 real third-party
  projects, 67 reports, 402 report×policy pairs, all four engines**, published **0.32.1** binaries as
  the producer against **0.33** HEAD as the consumer: **202 of the 265 pairs that pass today — 76.2% —
  flip to exit 2** with the policy unchanged. It is deterministic rather than statistical: a report
  carrying any `peeked: true` class refuses **202 of 202**, a report carrying none passes **63 of 63**,
  and **26 of the 32 projects** have at least one.

  **THE REMEDY: re-scan with a 0.33 engine under the SAME policy the gate applies** — not merely *a*
  policy, which is the loose reading this rung exists to close. It discharges the cost in full:
  **265 of 265** pairs green again, no residual tax and nothing to suppress. A pipeline that scans and
  gates in ONE run under ONE policy is **unaffected** — producer and consumer are the same run, so
  `P ⊆ P` holds by construction. Nor is legitimate narrowing over-charged: **62 pairs** whose
  producer's deny set genuinely covers the gate's took **0 refusals**, and over the full cross-policy
  sweep of **918 gates**, **529 refuse correctly and none fails open**.

  **The operators this hits are the ones who followed ⟨0.32⟩'s own remedy** — *scan with the policy* —
  because that is exactly what puts a `peeked: true` class into a report. They migrated one rung ago
  and are being asked to migrate again, for a hole that remedy did not close. The wording was the
  defect and the wording is the fix. It fails **CLOSED**.

- ⚠ **`scannedUnder`: a report now records the deny set its peek was BOUNDED BY, and `gate --report` /
  `fix-gate --strict` / `unverified --strict` refuse a report whose peek answered a DIFFERENT question**
  (SPEC §2 ⟨0.33⟩, candor-java's reference commit `05dfa53`). `excluded[].peeked: true` is true only
  RELATIVE to the deny set the PRODUCER held — ⟨0.29⟩ bounds the peek to effects the policy DENIES — and
  until this rung the report never recorded what that set was. A consumer gating with a DIFFERENT deny
  set got a definite answer to a question nobody asked, and it failed OPEN on `gate --report`, the
  supply-chain route, past every ⟨0.32⟩ control because the class really was read:

      candor <tree> --policy 'deny Net'  --out A   -> exit 0, `peeked: true`, `outOfScope: []`
      candor <tree> --policy 'deny Exec'           -> exit 2   (there IS an Exec out there)
      candor gate --report A --policy 'deny Exec'  -> exit 0, `no violations`      <- the hole

  PRODUCER: `report.scannedUnder = { "deny": [ "<expanded rule>", … ] }`, set at the exact site
  `outOfScope` is set (ReportModel.swift/main.swift) from the canonical-expanded rules the peek actually
  matched with — post-alias, post-`.candor/config`, deduplicated and code-point sorted
  (`CandorCore.canonicalDenySet`, shared with `ruleUpgrade`'s source-form renderer so an operator is
  quoted and a gate compares the identical string). `pure` is a deny rule with an EMPTY effect list and
  is recorded as such — flattening to effect NAMES would let the STRICTEST policy compare equal to an
  empty set, the four-way false all-clear ⟨0.30⟩ closed on the peek one layer in. NIL (key omitted) under
  exactly `outOfScope`'s own emission rule.

  CONSUMER: `CandorCore.unaskedCrossPolicyRules` is the ONE statement of the condition, called by
  `gate --report` (GateReportCLI.swift) and by the advisory verbs' `ReportCompleteness` arming
  (FixCLI.swift's `armingUnread`, now arming BOTH the unread-class and cross-policy causes together) —
  ⟨0.24⟩'s pessimism relation has broken on this family before from a new verdict cause reaching the gate
  and not its siblings, and a second computation is how it happens again. Refusal is exit 2,
  `ok:false, incomplete:true`, naming the unasked rules and pointing at THE SAME policy — not merely *a*
  policy, which is the loose reading that produces this hole. `scannedUnder` is read as strictly as every
  other §2 signature key: a non-object, or a `deny` that is not an array of strings, impeaches the
  document rather than being read as the empty set — the fail-open direction here is the MIRROR of
  `peeked`'s (there the safe-looking coercion was "no exclusions"; here it would be "the producer held
  these rules"). An ABSENT `scannedUnder` beside `peeked: true` IS the empty set for the subset test, so
  a pre-⟨0.33⟩ report fails closed — the rung, not collateral damage.

  FOUR OVER-CHARGE CONTROLS, unit-pinned in `UnreadExclusionRouteEqualityProcessTests.swift`: the same
  policy on both routes still certifies; a consumer's rules a strict subset of the producer's still
  certifies (the reason the key is a RULE SET and not a digest — a digest can decide only equality); no
  peeked exclusions at all still certifies under a differing policy (analysed code's effect sets are
  policy-independent — only the peek was ever bounded); and a garbled `scannedUnder` cannot manufacture
  coverage.

  FALSIFIED against a mutant build with the consumer half short-circuited to `[]` (the producer still
  emitting `scannedUnder`): `cross-policy`, `pure`, `fix-gate --strict` and `unverified --strict` all
  read 0 (the fail-open, four ways) while every control cell stayed green — so the controls are not what
  moved. Restoring the real implementation reddens all four.

  **KNOWN RESIDUAL, filed rather than routed around:** conformance PART 69's swift row does not yet read
  `OK`. This engine excludes `Package.swift` itself as the `manifest` class UNCONDITIONALLY whenever any
  `deny`/`pure` rule stands (`isHarnessPath`, pre-existing and unrelated to this rung), so PART 69's
  "tree D" fixture — meant to carry NO exclusions at all, for the control-3 no-peek case — is never
  actually empty for this engine: it is a second, accidental instance of the defect fixture. The
  producer/consumer mechanism above is complete and independently verified (unit tests + a falsified
  mutant, both above); the residual is a conformance FIXTURE gap for the swift row specifically,
  recorded here because a limitation left only as a comment is the shape that stops being measured.

- **`AgentsDocDriftTests` now sees its own README's headline claim.** README.md line 3 reads
  `**The Swift implementation of [candor-spec](…) 0.32**`, and the `) ` between the word and the version
  put it outside the gate's `spec` + one-to-four-of-`[-: "]` grammar. This gate is the one the other four
  engines ported at ⟨0.32⟩ *because* it was clean through that bump — and it was clean over a claim in
  its own repo that it could not read. The grammar is now one to EIGHT of `[-: "*)\]]`, which also
  covers the ALIGNED `"spec":    "0.32"` column, and the discrimination test carries both. Falsified:
  setting README line 3 to 0.31 now fails the test naming the file and the exact text.

- **The release-configuration build now happens on `main`, not for the first time on a pushed tag.**
  Every `swift build` in `ci.yml` was a *debug* build; nothing compiled `-c release` until `release.yml`
  did, on `push: tags: ['v*']`. So `candor-swift-macos-arm64` — the artifact a user downloads, and the
  only install route that does not need a Swift toolchain — was first compiled *after* the tag existed.
  `-c release` is a different compile (whole-module optimisation, a different warning set, its own link
  step), so a failure there was discoverable only by cutting. A new `release-build` job does the release
  compile and asserts the binary's own `--version` names `main.swift`'s declared `engineVersion` —
  `release.yml`'s artifact-level assertion, one step earlier, against the constant instead of the tag
  (which is what the tag is itself checked against). It is a separate job so it cannot spend `test`'s
  20-minute hang-detector budget, and it uploads the binary. `release.yml` is unchanged and still runs
  its own tag-anchored checks.

## [0.32.1] — 2026-08-25

- Build version → 0.32.1 (`engineVersion`); no analyzer change.

- **Family build bump — this engine is unchanged, and the ⚠ convention deserves a word.** No report byte
  and no verdict moves across 0.32.1; the floor stays 0.32. The AS-EFF-005 guard will still refuse a
  0.32.0 baseline against a 0.32.1 binary, because it keys on the engine-prefixed build string rather
  than on whether behaviour happened to move — so regenerate as you would across any bump, and expect
  the regenerated baseline to be identical. The patch exists for candor-java: `native.yml`'s parity gate
  withheld the v0.32.0 native binaries after the image reported `0 functions` over a tree the jar found
  210 in, and the fixed binaries are only reachable once `ENGINE_PIN` moves — one value for the whole
  family, this engine's release tag among them.

## [0.32.0] — 2026-08-25

- **The embedded AGENTS contract drifted from `AGENTS.md` on the ⟨0.32⟩ bump.** The pass rewrote three
  spellings of the spec string in the doc and two in the embedded copy: it caught `spec-0.31` and
  `"spec": "0.31"` — the two that look like declarations — and missed `(spec 0.31)` inside a quoted
  example sentence, which looks like prose. Regenerated with `gen-agents-doc.py` rather than hand-patched,
  so the one-line diff is itself the proof nothing else had drifted. The example's halves are coherent
  again too: it read `candor-swift 0.31.0 (spec 0.32)`, a pair that has never existed.

- **`fabrication_probe.py` still asserted the pre-⟨0.32⟩ ruling on argv.** ⟨0.32⟩ deliberately charges
  `ProcessInfo.arguments`/`processName` as `Env` — argv is startup state from the same `exec` as envp, and
  candor-rust has always charged `std::env::args()` that way — but the probe's PURE list was never updated.
  It was invisible because the unit-test step failed first and every later step was skipped. The two names
  moved to the probe's CONTROL list rather than being deleted, so the row keeps teeth in the direction that
  now matters; `processIdentifier`, charged nowhere, remains the pure fixture.


- **`callers`, `impact` and `path` had NO completeness reader in the other three engines — measured
  here, and this engine's `path` already hedges.** ⟨0.28⟩ widened SPEC §2's re-disclosure MUST to *"any
  verb whose output could be read as a NEGATIVE FINDING about the code — a verdict, an empty result set,
  or a zero count"*, enumerated six verbs, and skipped these three; over a report whose `excluded` names
  a class the producing scan never opened, candor-rust, candor-ts and candor-java answered FLAT on both
  channels (and on candor-ts's MCP tools). All three are fixed there.

  **This engine ships `path` and not `callers`/`impact`**, and `path` was driven over a real scan of a
  tree with an excluded harness target: `{"effect":"Fs","fn":…,"path":[…],"incomplete":true}` at exit 0
  — the data AND the warning, already. No behaviour changes here.

  What lands is TWO ROWS. `testPathsEmptyChainCarriesTheHedgeToo` pins the arm the sibling engines had
  to be TAUGHT: `path <fn> Net` where the function reaches Fs and not Net, which answers `path: []` —
  *this function does not reach that effect*, the precise reassurance a reader asks `path` for — and it
  asserts the empty chain is PRESENT rather than merely that the key exists, because an empty result is
  exactly the answer this row has to be able to tell apart from a withheld one. Its premise (the report
  really does publish `peeked: false`) is asserted first, so a broken fixture cannot pass as a green.
  And `callers`/`impact` JOIN the surface-absence list beside `show`/`map`, so a later port cannot
  arrive carrying the defect the other three just closed.

- **`show` and `map` returned the WARNING INSTEAD OF THE ANSWER — the ⟨0.32⟩ descriptive hedge, ruled
  the other way and closed four-way.** ⟨0.28⟩ Rung A tells a verb *whose pinned shape cannot carry the
  caveat* to emit the CAVEAT DOCUMENT **instead of** its result document, and yesterday's rung armed
  that substitution on the unread-exclusion-class cause. MEASURED on a two-function crate with one
  `tests/` dir (`excluded: [{class: "non-library-target", peeked: false}]`), and reproduced in every
  engine that ships these verbs:

  ```
  show <fn> --json   ->  {"incomplete": true}      exit 0    the rows are GONE
  map       --json   ->  {"incomplete": true}      exit 0    the map is GONE
  ```

  That is approximately every no-policy scan of a crate with `tests/`, `benches/`, `examples/` or a
  `build.rs`, and of a single-file TS scan with unparsed siblings — and through candor-ts's MCP tools
  `candor_show`/`candor_map` handed the same document to an AGENT, on the edit-time channel that cannot
  ask a follow-up question.

  **RETURN THE DATA AND THE WARNING; DO NOT REPLACE THE DATA WITH THE WARNING.** Rung A's wording was
  written when the trigger was a manifest a scan had FAILED to produce — there was little result to
  lose. It is wrong once the trigger is ordinary: `show` and `map` are DESCRIPTIVE, they certify
  nothing, so there is no claim for a pessimism rule to protect and withholding the answer buys no
  soundness. The same codebase already answers this way one verb over — `gains --json` keeps its gained
  set and adds `incomplete: true` beside it — and the descriptive verbs are now consistent with it.

  **THE BOUNDARY IS WHETHER THE VERB ANSWERS `ok`, AND IT IS NOW STATED IN A COMMENT IN ALL FOUR
  ENGINES.** `gate`/`gate --report`, and `unverified`/`fix-gate`/`whatif`/`fix` under `--strict`, answer
  `ok`: they still REFUSE over these same bytes (exit 2, `ok` false on the gate and OMITTED on the
  advisory siblings), which ⟨0.24⟩ requires and conformance PARTs 62 and 67 pin. Getting the boundary
  wrong in that direction re-opens the cardinal sin, so the controls for it were written FIRST and
  confirmed green before anything moved.

  **THE SHAPE: THE RESULT NESTS, THE CAVEAT SITS AT THE ROOT.** `show` hedging is
  `{"functions": [ … ], "incomplete": true, …}`; `map` hedging is `{"modules": { … }, "incomplete":
  true, …}`. Every property Rung A cited for its own shape still holds — healthy output is untouched,
  the root type change stays LOUD (a consumer doing `for (const x of doc)` over `show` still gets a
  TypeError, not a silent zero-iteration loop), and no reserved-key convention is needed. Nesting
  `map`'s USER NAMESPACE one level down *removes* the collision the ruling deferred rather than
  re-opening it: a module literally named `incomplete` is a key of `modules`, the boolean is a key of
  the root, and neither can displace the other. Relative to the shape it replaces the change is purely
  ADDITIVE: a consumer that already handles today's hedge sees one more key.

  **CONTROLS, WRITTEN FIRST AND BOTH DIRECTIONS ASSERTED**, because the safe-looking empty value passes
  a presence check while deleting the feature: the certifying verbs still refuse over an unread class
  (exit 2, `ok` withheld); a report with nothing unread produces a document BYTE-IDENTICAL to the
  pre-change binary's on both verbs, measured by diff; the hedge still appears when it should; and the
  restored answer is asserted by ROW COUNT and NAME, not by key presence.

  **THIS ENGINE SHIPS NEITHER VERB**, so the substitution has no site here and no behaviour changed:
  its descriptive surface is `path` and `tour`, and both already merged `disclosureJSON` into their
  own document (measured: `{"reaches": [...], "incomplete": true}` at exit 0). What lands here is the
  RULING, in a comment on `mustHedge`, and a row pinning `path`/`tour` on data-beside-the-hedge plus
  the absence of `show`/`map` — so a later port cannot arrive on the shape the ruling rejects.

  GATES: swift build; swift test (855 tests, 0 failures, +1 row); ci/self-gate.sh OK. Conformance was
  NOT run — candor-spec is under concurrent edit.

- ⚠ **A verdict row could not say WHICH unit it was about — the ⟨0.32⟩ identity clause, closed.**
  SPEC §2: *"a verdict row MUST carry enough identity for a consumer to tell two units apart… the sort
  key MUST include that identity."* MEASURED, `gate --report` over two reports whose members both define
  `go` and both violate `deny Exec` — two BYTE-IDENTICAL rows, `{rule, fn, effects, detail}`, with
  nothing attributing either to a package. A reader cannot tell two broken members from one listed
  twice, and a consumer that fingerprints on name alone — candor's own SARIF action did — hides one
  finding behind the other. Names are not unique even WITHIN one report: this engine's own `#1` overload
  disambiguator exists because two `go()` declarations collapse otherwise.

  `GateViolation` gains `hash` — §2.2's join key, `<package>#<qual>` — **BESIDE `fn`, never instead of
  it**: the NAME is what a policy scope matches (`nameOf`) and what a human reads, so substituting the
  qualified form would silently stop every scoped rule matching. `GateInput` gains a `hash` map beside
  `display` rather than the row reading identity off the KEY, because the two routes disagree about what
  the key IS: `gate --report` keys by `hash` already, the scan route keys by the qualified NAME and
  qualifies it with the package it is scanning — the SAME string the report writer puts in each entry.

  **AND THE SORT KEY IS HALF THE CLAUSE.** `(rule, detail)` ties on the twins (`detail` is rendered from
  the NAME), and §3.3.1 makes the document's ORDER part of the byte-equality between the two routes.
  This engine had **no sort at all**: order came from `keys.sorted()` inside each rule loop crossed with
  policy-DECLARATION order. `writeGateVerdict` — the one writer both routes call — now sorts
  `(rule, detail, hash)`.

  **NOT ADDITIVE, stated plainly:** a new key on the violation record means a verdict document is no
  longer byte-identical to a pre-⟨0.32⟩ one. Unavoidable — the MUST is that the row carry identity, and
  no arrangement of the four existing keys does. Everything that can be additive is: every pre-existing
  key keeps its name and value, and `hash` is OMITTED when the producer has none to give (a
  hand-authored report, which §3.1 says this verb serves) — ⟨0.26⟩'s *cannot answer*, never a fabricated
  id. Route byte-equality re-measured on a real scan-then-gate pipeline: identical. Conformance PART 68
  pins it four-way; its `rev` control re-lays the same two reports under swapped file stems, so an
  engine ordering by the discovery walk fails where one ordering by identity passes.

- **`tour` said "nothing hidden" over a class the scan never opened — the ⟨0.32⟩ descriptive hedge,
  ruled and closed four-way.** Over a report whose `excluded` names a class with `peeked: false`, this
  engine, candor-rust and candor-ts printed *"candor: nothing hidden — every effect sits where its name
  says it should"* at exit 0, while candor-java hedged and named the class. **candor-java was right, and
  the ruling is now in a comment in all four engines so it is not re-litigated.**

  **IT IS A DISCLOSURE, NOT A VERDICT** — `tour` answers no `ok` and has no exit-code obligation, so
  ⟨0.24⟩'s advisory pessimism MUST does not reach it and the exit code is unchanged; the arm is on
  `mustHedge` and NOT on `isIncomplete`. What reaches it is §2 ⟨0.28⟩ (*"any verb whose output could be
  read as a negative finding about the code — a verdict, an empty result set, or a zero count"*) and
  §3.1 ⟨0.18⟩, which already forbids **that exact sentence** over a ≥⅓-Unknown graph. An unread
  exclusion class is the same ignorance by another route, and the ⅓ threshold structurally cannot see
  it: an unread unit contributes no entry, so it moves neither the numerator nor the denominator. The
  argument this file used to carry — *"they take no `--policy`, so there is no question whose answer
  could depend on the unread code"* — was the wrong way round: a verb with no policy is asking the
  WIDEST question there is, the whole effect surface.

  **AND WIRING IT SURFACED A REAL ONE IN THE ARMING.** `armingUnread` only SET a flag where candor-rust
  CLEARS the list, so the moment `mustHedge` read `unread` directly a `forbid`-only run began answering
  `incomplete: true` on `fix-gate`/`unverified` — hedging exactly the allowlist run that function exists
  to leave alone. Caught by `UnreadExclusionAdvisorySiblingTests`' own no-deny-rule control; the list is
  now cleared, not merely left unarmed. Two prose defects fell out with it: the note's head clause was
  built from the three MANIFEST rows alone, so a report whose ONLY cause was `outOfScope` or an unread
  class produced *"declare 0 unit(s) candor could not analyze"* — a hedge naming a cause it does not
  have, which this family rates worse than a missing one — and the tail would have claimed
  `gate --report` exits 2 with no policy in force to say it under. Both now have their own sentence.
  `privacy-manifest`'s "complete report" control was never complete in the ⟨0.32⟩ sense (an SPM tree
  always excludes `Package.swift`); its fixture now says so, and gains the opposite arm.

- **CI was green against the WRONG CONTRACT: the candor-spec pin was 797 commits stale.** Both workflows
  clone candor-spec and check out a fixed commit — `ci.yml`'s `CANDOR_SPEC_PIN` and a LITERAL in
  `release.yml` — and both sat at `eccfac71`, which predates every ⟨0.32⟩ commit. `smoke.sh` reads its
  oracle out of that sibling checkout, so every push and every PR went green while asking the ⟨0.29⟩-era
  questions, and the rung's own rows were never run. A stale pin is not a conservative default: it is a
  check that reports on a contract nobody is shipping. Both moved to `3c643e5` (the ⟨0.32⟩ carve-out
  commit, spec HEAD), and `smoke.sh` was run against it here first — 148 passed, 0 failed.

  The two spellings are the reason it drifted: a workflow-level `env:` in `ci.yml` does not reach
  `release.yml`, so the release lane could certify against an older contract than the PR lane that
  approved the change. Both now carry a comment saying they move together, and the weekly `spec-head`
  lane stays what it always was — the early warning that HEAD has moved past the pin, which only works if
  someone reads it. The pin is what the gate enforces.

- **⚠ ⟨0.32⟩ `gate --report` CERTIFIED CODE NOBODY HAD READ — the unread-class rule was keyed on the
  PRODUCER'S HISTORY instead of the question being asked.** The ⟨0.32⟩ rule ("a class this scan did not
  READ makes the verdict INCOMPLETE") carved out the no-peek case by requiring `outOfScope` to be
  PRESENT on the report. ⟨0.29⟩ omits that key when the producing scan carried no policy — which is
  exactly the report a CI publishes when it scans in one job and gates the artifact in another — so the
  whole rule was skipped in the case it exists for. **MEASURED on an ordinary SPM tree whose test helper
  spawns `/bin/sh`: `candor-swift <dir> --policy 'deny Exec'` exits 2 naming the helper, while
  `candor-swift gate --report N --policy 'deny Exec'` over a bare `--out N` of the same tree answered
  exit 0, `{"ok": true}`, `policy ✓`.**

  The carve-out is now the one the rule is about: **whether the hole matters is decided by the policy in
  force NOW, not by the producer's history.** From a report the two causes of `peeked: false` — "opened
  it and could not read it" and "never asked" — are indistinguishable, because they leave the identical
  hole, and ⟨0.21⟩ licenses a purity claim only over units the scan JUDGED. `excluded` is mandatory from
  ⟨0.29⟩ (SPEC §2.2), so a no-policy report is a current producer stating it never opened those files.
  What survives is the condition on the QUESTION — only a `deny`/`pure` rule's answer depends on code
  outside the scan's scope — applied ONCE to the value, because that same list feeds both `incomplete`/
  `ok` in the verdict document and the exit code. `pure` counts: it is a deny rule with an EMPTY effect
  list, so an implementation flattening rules into effect NAMES would silently disarm the strictest
  policy the grammar has. Matches candor-rust `ab505c0` and candor-ts `9f22581`; conformance PART 62's
  swift row now MATCHes four-way.

  `excluded` also joins the strictly-read §2 keys, and its two flags are read on the NUMBER'S OWN TYPE
  TAG rather than through `as? Bool`: Foundation bridges the integer `1` to a number that cast accepts,
  so `"peeked": 1` would have read as "opened" and `"judgedElsewhere": 1` would have granted the
  carve-out that suppresses the refusal. This engine has already shipped one live defect through that
  same bridge (`analyzed: {count: true}` reading as JUDGED). A present-but-unreadable flag is now a
  refusal NAMING the key; an ABSENT `excluded` (a pre-⟨0.29⟩ producer) still certifies.

- **⚠ ⟨0.32⟩ …AND THE ADVISORY SIBLINGS STILL CERTIFIED (SPEC §3.2).** With the gate fixed,
  `fix-gate --strict` and `unverified --strict` answered exit 0 `{"ok": true}` over the very report
  `gate --report` refuses at exit 2 — and those documents are the agent-facing half of this tool. §3.2
  allows an advisory verb to be LESS certain than the gate, never MORE. ⟨0.30⟩'s half of the same rung
  already reached these verbs; closing a cause on the gate and not on its siblings is how that half
  drifted first. The condition is applied in ONE place against the run's own policy, and an unread class
  is deliberately not an unconditional arm: it rides almost every no-policy report, and a verb that
  hedged on every run would teach its reader to skip the hedge.

- **⚠ ⟨0.30⟩ AN ALIAS IN ONE POLICY RULE SWITCHED OFF THE DISCLOSURE FOR EVERY OTHER RULE — a strictly
  STRONGER policy answered WEAKER.** The ⟨0.30⟩ peek re-parses the policy file for itself and did so with
  no alias vocabulary, so a `deny Unknown[corp]` line written against a `.candor/config` `unknown-alias`
  was an unrecognised class token to that read — a ⟨0.24⟩ policy error — and the peek drops its ENTIRE
  rule set on any such error (⟨0.29⟩: a refused policy must not claim a look taken against rules that
  never stood). **MEASURED on an SPM tree whose test helper spawns `/bin/sh`: `deny Exec` exits 2 naming
  the helper; `deny Exec` + `deny Unknown[corp]` exits 0 saying nothing, with every excluded class left
  `peeked: false`.** Every rule of the second policy is a rule of the first, so `Reject` being
  upward-closed (PAPER3 Lemma 2) makes exit 0 there a contradiction rather than a judgement call.

  It stayed quiet because the GATE was never wrong — the gate's own parse carries the vocabulary and
  expanded `corp` correctly — so adding a rule deleted the disclosure belonging to a DIFFERENT rule that
  was never in doubt, and nothing read the `peeked: false` it left behind. The vocabulary now travels
  with the POLICY that uses it on both reads (the ⟨0.24⟩ anchoring ruling), so the gate and the
  disclosure apply one rule the same way — §6.2's requirement, which was being honoured on the rule's
  SHAPE since ⟨0.30⟩ and missed on its WORDS.

- **⚠ ⟨0.32⟩ SILENT UNDER-REPORT: six capabilities were charged at one spelling and PURE at their twin.**
  Foundation ships most process/filesystem/clock capabilities twice — a receiver-rooted spelling and a
  C-era FREE FUNCTION doing exactly the same thing — and this engine modelled the two in SEPARATE tables
  (`kappaMember`/`kappaPropertyRead` keyed on a receiver root, `kappaFree` keyed on a bare name) with
  nothing making them agree. Measured, one fixture per pair, `ABSENT` being the ⟨0.21⟩ purity claim:

  | free spelling | | member twin | |
  |---|---|---|---|
  | `ProcessInfo.processInfo.arguments` | ABSENT | `CommandLine.arguments` | `Env` |
  | `NSHomeDirectory()` / `NSHomeDirectoryForUser(_:)` | ABSENT | `FileManager…homeDirectoryForCurrentUser` | `Fs` |
  | `NSTemporaryDirectory()` | ABSENT | `FileManager…temporaryDirectory` | `Fs` |
  | `NSSearchPathForDirectoriesInDomains(…)` | ABSENT | `FileManager…urls(for:in:)` | `Fs` |
  | `NSUserName()` / `NSFullUserName()` | ABSENT | `ProcessInfo…hostName` | `Env` |
  | `CFAbsoluteTimeGetCurrent()` | ABSENT | `Date()` | `Clock` |
  | `gettimeofday(…)` / `clock_gettime(…)` | ABSENT | `ProcessInfo…systemUptime` | `Clock` |

  `pure <fn>` exited 0 over a function that reads argv. LIVE in firebase-ios-sdk:
  `AILog.additionalLoggingEnabled()` is `ProcessInfo.processInfo.arguments.contains(…)` and was absent
  from the report entirely.

  **THE FIX IS A TABLE, NOT SIX NAMES.** `CAPABILITY_SPELLINGS` holds one row per capability carrying
  every spelling of it, and both classifiers read that row — so a twin-family spelling has nowhere to be
  added to one of them. The hand-written cases for `Date`/`NSDate`/`CACurrentMediaTime`/
  `mach_absolute_time`/`getenv`/`setenv`/`unsetenv` moved onto the rows they twin, arity gate and all.
  Each row also carries `witnesses` — every spelling as an expression — which a standing battery scans as
  a generated fixture, asserting they all report the row's effect; the battery is CALIBRATED (a
  deliberately bogus row makes it fail and name the spelling). What it cannot catch is stated in the
  table: a capability nobody modelled in EITHER spelling, which is the coverage ledger's job.

  This is the THIRD instance of the shape in a week — `f419648` closed the argv divergence for
  `CommandLine.arguments` only, and `1f8ecd3` is "one spelling of a file read was classified, its twin
  was not".

  **A/B over 7 packages / 23 567 units, plus 42 gate cells:** **zero effects lost**, 44 units newly
  charged (43 `Env`, 1 `Fs`) from just **5 direct sources**, every one hand-traced to a real read —
  swift-syntax's `Reduce.runVerifyRoundTripInSeparateProcess` (`arguments[0]`), pollen's
  `importPatientDetailsFromHealthKit` (`NSFullUserName()`), firebase's `AILog.additionalLoggingEnabled`
  and `DevEventConsoleLogger.logEvent` (both `arguments.contains`), and firebase's
  `FileManager.temporaryDirectory(withName:)` (`NSTemporaryDirectory()`). One verdict cell moved:
  firebase `deny Fs` 391 → 392 violations, on both routes together. No exit code flipped.

- **⚠ ⟨0.32⟩ `gate --report` certified CLEAN where the scan REFUSED — a §3.1 route-equality violation,
  fail-OPEN.** The ⟨0.32⟩ unread-exclusion rule ("code this scan did not READ makes the verdict
  INCOMPLETE") landed on the scan route only: `writeGateVerdict`'s `unpeeked` parameter is defaulted, the
  scan route passed it and `gate --report` silently took the default. The evidence was already on the
  wire the whole time — `excluded[].peeked == false` rides the report both routes read. **Measured on
  swift-syntax under `deny Net`: scan exit 2 `{"ok":false,"incomplete":true}` against gate exit 0
  `{"ok":true}`** — and the gate route is the one a CI runs against a published report. The rung shipped
  with no test on either route, so nothing in the suite could see it.

  `gate --report` now reads `excluded` off the document and applies the SAME two conjuncts the producer
  applies: the producer's `judgedElsewhere` carve-out for a derived copy of already-judged code, and —
  the subtle one — the rule fires only if the peek RAN. `peeked: false` has two causes and only one
  licenses a refusal: "opened those files and could not read them", versus "no peek ran, because no
  policy was configured". ⟨0.29⟩ already separates them in the `outOfScope` key (OMITTED when nothing was
  asked, present-and-empty when the peek came back clean), which is the same conjunct candor-java
  (`scanWasAsked`) and candor-rust (`KeyRead::Present`) apply on their report routes. Without it every
  no-policy and every pre-⟨0.30⟩ report would exit 2 on contact. Four of the nine new rows are
  over-charge controls for exactly that.

  **A/B over 7 real packages × `deny Exec`/`deny Net`/`deny Fs` × both routes (42 cells):** route-equality
  violations 2 → 0, verdict documents byte-equal 19/21 → **21/21**, and not one scan-route cell moved.
  The second of the two was invisible to an exit-code comparison — swift-syntax under `deny Exec` agreed
  at exit 1 while the gate route's document omitted `incomplete` — which is why §3.1 makes BYTE-equality
  the acceptance test and this fix is measured against it.

  Also on this route: `candor-swift: policy ✓` was printed ABOVE the exit-2 arms, so every incomplete
  verdict led with a green tick and contradicted itself one line later. The scan route moved its own tick
  below its arms at ⟨0.30⟩; this one had kept the old position. Pinned on all three causes, with a
  clean-gate control.

- **⚠ ⟨0.32⟩ One `extension Process` anywhere in a package zeroed the `Process()` CONSTRUCTOR,
  package-wide.** The free-call κ ctor arms fenced on `localTypes`, which is filled from EXTENSIONS as
  well as declarations, so extending a platform type made its constructor read as project code
  everywhere. The member-call path has fenced on `declaredTypes` since the ShellOut cardinal-sin, so the
  two paths answered the same question differently — the sibling-route shape. Measured on real code:
  firebase-ios-sdk has four `extension Date` blocks and reported NO `Clock` anywhere in the package —
  38 units, each with a plain `Date()` in its body; swift-protobuf has one `extension FileHandle`, and
  `FileHandle(forWritingAtPath:)` — a real file OPEN for writing — read pure in three units. All four
  ctor families (κ, capture, bonjour, EventKit) now take the `declaredTypes` fence.

  **The obvious fix is a regression and ⟨0.32⟩ measured that too**: swapping the fence drops the local
  call edge an extension `convenience init` needs, and 91 firebase units LOST a true `Env` through it.
  This charges κ *and* keeps the edge, by emitting the same `Call` the fall-through arm would have
  emitted for exactly the set it used to serve — so the delta is ADDITIVE BY CONSTRUCTION, not by hope.
  The convenience-init case is a control row, not an afterthought.

  **A/B over ~23 900 units × `deny Exec`/`deny Net`/`deny Fs`**: zero verdict flips, **zero effects
  lost**, 41 units newly charged — 38 `Clock` (firebase) and 3 `Fs` (swift-protobuf), every one
  hand-traced to a real receiver, and 5 of them newly PRESENT in the report at all. swift-syntax's
  `ProcessRunner.init` does not move: ⟨0.32⟩ already charged it `Exec` through the configuration half,
  so the construction charge lands inside an effect set it already had — the null explained, not assumed.

- **⚠ ⟨0.32⟩ A module-qualified `Data`/`String` content read was silent — the one free-name family the
  spelling rule did not reach.** ⟨0.32⟩ made a module qualifier a SPELLING for the κ table and the three
  privacy ctor families, but the `Data`/`String(contentsOf:|contentsOfFile:)` arm was keyed on the callee
  NODE rather than on a name, so it kept answering one spelling: `Foundation.Data(contentsOf: u)` reported
  `Clock` alone where `Data(contentsOf: u)` disclosed `Unknown`, `Foundation.String(contentsOfFile: p)`
  lost `Fs` — and with it a `deny Fs` verdict, which passed at exit 0 over a module-qualified config read
  — and `Foundation.Data(contentsOf: URL(string: "https://…")!)` lost `Net`. The arm is now a FUNCTION
  both spellings call, so the two cannot answer differently about the same program, and the parity is
  gated as a LOOP over every classified ctor spelling rather than as one row.

  Extracting it surfaced a FABRICATION in the same arm, closed here: it was the only free-name family
  applying no local-shadow guard at all, so a project's own `struct Data { init(contentsOfFile:) }` was
  charged `Fs` and its `init(contentsOf:)` acquired an `Unknown`. It now takes the `declaredTypes` fence
  every κ family uses — an extension of Foundation's `Data` still does NOT shadow — and the qualified
  spelling is the escape hatch a package that declares its own `Data` uses to reach Foundation's.

  **A/B over ~23 900 units × `deny Exec`/`deny Net`/`deny Fs`** (firebase-ios-sdk, swift-syntax,
  swift-protobuf, pollen, promises, 22 flutterfire plugin targets, this engine's own Sources): zero
  verdict flips, zero effects lost, zero gained — the corpus holds 109 bare content reads and NOT ONE
  module-qualified one, so it measures the absence of a regression, not the value of the fix, and is
  reported that way. Filed residual: `declaredTypes` is keyed on the simple name and is package-wide, so
  a NESTED or `fileprivate` declaration shadows further than Swift's own resolution (swift-syntax has a
  `fileprivate enum Data`). Measured at ⟨0.32⟩ HEAD, a nested `fileprivate enum Pipe` already silenced
  `Pipe()` the same way — this arm joins the existing fence rather than inventing one.

- **⚠ ⟨0.32⟩ `Exec` charged construction and an enumerated list of launch verbs — everything between
  them read pure.** Two silent under-reports on the subprocess surface, both required by SPEC §1 ⟨0.32⟩
  and pinned by conformance PART 66, whose swift `configured` cell was measured-absent for exactly this:

  **CONFIGURING a received invocation was charged nowhere.** `func arm(_ t: Process, _ argv: [String])
  { t.arguments = argv }` reported NO effect at all — absent from `functions`, which under ⟨0.21⟩ is a
  positive purity claim — and a tree whose only subprocess contact was that one property write passed
  `deny Exec` at **exit 0**. An invocation object carries its own payload and travels fully armed, so
  splitting build from launch across two functions must not make the builder invisible. This is
  candor-java's PART 66 finding from the opposite end and it has the same cause: an allowlist
  under-reports every verb nobody enumerated. Now stated as the DENYLIST the clause requires — a proven
  `Process` handle is `Exec` for every member and every property WRITE, with the Object protocol carved
  out by name, `environment` REDIRECTED to `Env` (java's ruling on `ProcessBuilder.environment()`), and
  the read-back carve-out expressed as the ACCESS DIRECTION, which is Swift's equivalent of java's
  descriptor key: a property get and its setter share one name, so `let a = t.arguments` arms nothing
  and is not charged. `suspend`/`resume` — live-child control verbs simply missing from the old list —
  come with it.

  **A QUALIFIED SPELLING of the same constructor was invisible.** `Foundation.Process()` reported
  nothing where the bare `Process()` reported `Exec`, and the loss compounded: the unclassified ctor
  left `let t = Foundation.Process()` untyped, so the `try t.run()` beneath it was silent too. A module
  qualifier is a SPELLING, so it now resolves to the bare name for every κ constructor (asserted on
  `Process`, `Date`, `UUID`, `FileHandle`, and on a ctor κ does not know, which stays pure), gated on
  the qualifier being a module THIS FILE imports that the project does not itself define — under
  `@testable import App`, `App.Process()` is the project's type, not Foundation's.

  Over-charge controls written FIRST and green before AND after: a project-local `class Process` gains
  nothing (effects and verdict), a read-back-only function stays `Clock`, `URLRequest`'s property
  writes stay pure (an option builder's resource arrives at the terminal verb, the boundary §1 ⟨0.32⟩
  draws), and every control carries a clock marker so "absent" cannot pass a control that asked
  nothing. **A/B over ~23 200 units of real Swift** (firebase-ios-sdk, swift-syntax, swift-protobuf,
  pollen, promises, flutterfire, GoogleDataTransport) **× `deny Exec` / `deny Net` / `deny Fs`: zero
  verdict flips, zero effects lost, ONE unit newly charged** — swift-syntax's `ProcessRunner.init`,
  which assembles an executable URL, argv and environment for its class to launch later, and is exactly
  the shape the rung exists for. The null is explained rather than assumed: in this corpus every other
  function that configures a `Process` also constructs or launches one in the same body.

  RESIDUALS, measured and filed rather than left implicit. An arming-only function reports `Exec` with
  no `cmds`, so `allow Exec <list>` fails CLOSED on it (the surface is recorded at the launching verb).
  And the A/B surfaced a separate, older hole, now pinned as an expected-failure ratchet: an `extension
  Process` anywhere in the target zeroes the `Process()` CONSTRUCTOR target-wide, because the free-call
  κ path shadows on `localTypes` where the member path shadows on `declaredTypes`. Its obvious fix was
  A/B'd and REVERTED — it drops the local call edge an extension `convenience init` needs, and 91
  firebase units lost a true `Env` through it.

- **⚠ ⟨0.32⟩ A protocol-typed receiver silently answered half a protocol's member space.** A protocol has
  two kinds of member — REQUIREMENTS, whose witness belongs to a conformer, and EXTENSION-PROVIDED
  members, which have a body of their own — and two lookup paths each covered one kind. Which path a call
  took was decided by something orthogonal to the question: `visit(ExtensionDeclSyntax)` calls `pushType`
  on whatever it extends, so declaring ANY `extension P` put `P` into the CONCRETE-type index, and a
  `P`-typed field or local then resolved through the concrete path — which answers provided members and
  drops requirements, because a requirement has no body to name. A parameter receiver took the CHA path,
  the mirror image: requirements resolved, provided members were dropped by a requirement-only gate.

  So the dependency-injection seam that is the whole reason protocols exist read PURE. Measured on a
  `protocol Deployer` / `LiveDeployer` running `Process()`: `service.deploy(tag)` through a
  `let deployer: Deployer` field certified pure, and a `deny Exec` gate scoped at that service exited 0.
  Every protocol-extension fixture in the suite typed its receiver as the CONCRETE conforming type, which
  is why 794 tests were green over it. Both halves now resolve from one member space, whatever binder the
  receiver came from and whether or not the protocol has an extension.

  Measured on real Swift (firebase-ios-sdk, swift-syntax, swift-protobuf, a 99-file first-party app,
  ~22 000 units): 14 units gained a true `Fs` — firebase's `HeartbeatStorage` reaches disk through a
  `private let storage: any Storage` seam whose `FileStorage.read` is `Data(contentsOf:)` — and 3 gained
  a true `Env` through swift-syntax's `PluginProvider` seam. 440 units gained a disclosed `Unknown`,
  every one of them a dispatch whose conformer set is genuinely past the ≤12 bound (301 are
  `SyntaxProtocol._syntaxNode`, 145 conformers); those sites previously answered with silence.

- **⚠ ⟨0.32⟩ A base-class receiver never unioned the subclass overrides.** `a.run()` where `a: ABase`
  runs `ABase.run` OR any subclass's `override func run()`, and only the first was edged — so an
  effectful override reached through a base-typed receiver read silent-pure. The hierarchy that names the
  overrides was already recorded and already published in the `.hierarchy.json` sidecar; the dispatch
  site simply never consulted it, and the arm that does exactly this query for a base declared in a
  chained DEPENDENCY had no counterpart for a base declared here. Precise-or-nothing and additive: only
  real `<subclass>.<member>` units are edged, so a member no subclass overrides contributes nothing, and
  the `STD_PURE_PROTOCOLS` / raw-value-enum carve-outs that keep `Codable`- and `String`-typed receivers
  out of CHA apply unchanged.

- **⚠ ⟨0.32⟩ The AS-EFF-005 baseline guard joined priors on the bare `fn`, never on `hash`.** `fn` is a
  qualified name; `hash` is the §2 `<package>#<qualified>` key. The guard used neither the hash nor the
  package, so a baseline recorded from an UNRELATED package answered for this one wherever a name
  coincided — and `Logger.log`, `Client.send`, `Store.save` are names every Swift package spells.
  Measured: a `Svc.kick` that gained `Exec` exited 1 against its own baseline and exited 0, with no note
  at all, against another package's. A ratchet that silently stops ratcheting is the gateless-green
  class. The join keys on `<package>#<fn>` now; a stderr note names a package mismatch so a wave of
  AS-EFF-005 on a mispointed baseline explains itself. Deliberately a disclosure and not an exit-2
  refusal: for a target with no `Package.swift` the package name is the target's last path component, so
  a refusal there would be invented out of a path spelling rather than out of evidence about the code.


- **⟨0.32⟩ A refusal records itself beside the reports it would have written.** Measured in this engine
  before the fix: scan green, add a denied effect, refuse with an unknown flag, and
  `candor-swift gate --report .` answered **exit 0** over the previous run's bytes. The refusal now writes
  `<prefix>.refused.json`, which overwrites nothing — the report is byte-untouched across it — and the
  gate declines to certify until a completing run clears it.

  Arming that prefix is not the fix, and this engine's own armer says why: its first version overwrote a
  `.candor/report.<pkg>.Swift.json` with a placeholder, and committed reports are a pattern this project
  recommends.

  **The refusal funnel is guarded here, which the port had to discover.** `refuseGateAndExit` is only
  called on the unknown-flag path when a verdict sink already exists, so the commonest shape of all — an
  unknown flag with no `--gate-json` — exits elsewhere. Writing the marker only in the funnel produced
  none for exactly the case the rung exists for.

## [0.31.0] — 2026-08-20

- **The unevaluable-target refusal now names a remedy.** §3.3(d) makes it a MUST, and this engine printed
  only `no Swift sources under <path>` — accurate, and silent about what to do. The remedy travels inside
  the refusal string so the `--gate-json` document carries it too: whoever reads that document is exactly
  whoever cannot go and look at stderr.

- **⟨0.31⟩ `netPartners` — the ambient config that moved a verdict is named in it.** Under
  `deny Net[unknown-host]`, a call to `partner.example` exits 1; adding `net-partner partner.example` to an
  ambient `.candor/config` exits 0, and nothing named the file, its path, or the host. The report envelope
  now carries `netPartners: { config, hosts }` — which config declared partners and which of them
  **participated** — and both `scan --policy` and `gate --report` put the list of those records in the
  verdict. Verified byte-equal. Additive: no declaration, or one that never matched, carries the key
  nowhere.

  `partnerFor` is extracted as the single matcher and `netDestClass` calls it, so the disclosure asks the
  same function the decision asks. The path comes from the same discovery walk the partners were read
  through. `gate --report` **copies** the producer's record rather than recomputing it — that route has no
  target to anchor `net-partner` at, and re-classifying through the consumer's own config would make a
  verdict depend on the reader's working directory.

- **A refusal produces no report** — same defect and same fix as candor-ts (see its changelog). The clean
  case exited 2 while `--gate-json` said `ok: true`; the refusal now happens straight after the peek,
  before any envelope exists, because §3.1 binds any report a scan produced. Pinned by PART 56.

- **⚠ A target with no analyzable sources now still reads what it excluded.** A package whose only Swift
  lives in a TEST target answered `no Swift sources`, exit 2, and named nothing — while candor-rust, over
  the analogous shape, reached its peek and named the function. Found in candor-ts first, on the published
  artifact, and present here identically. When a policy is configured and there are excluded files to
  read, the run continues to the peek; **the refusal does not move**, it becomes a third exit-2 arm beside
  the ⟨0.21⟩ unanalyzed and ⟨0.30⟩ out-of-scope causes. Verdicts unchanged — exit 2 before, exit 2 after.
  candor-java's empty-class-directory case is not analogous (a class directory has nothing to peek, which
  is why java flipped 0 of 14 packages at ⟨0.30⟩).

## [0.30.0] — 2026-08-19

- **Spec floor 0.30.** The declaration this build emits as `candor.spec` moves with the family; see
  candor-spec's changelog for the rung.

### ⚠ ⟨0.30⟩ VERDICT-AFFECTING — a gate that was GREEN can now exit 2

**What changed.** When a policy is configured, candor "peeks": it reads the files the scan itself
excluded (test files, build scripts, archives under the root, files outside the build's program) and
reports any that perform an effect the policy DENIES. Until now that block was disclosure only — ⟨0.29⟩
required the exit code to stay exactly what it would have been without it. **It no longer does.** A
non-empty `outOfScope` now makes the verdict `ok: false`, `incomplete: true`, **exit 2**.

**Why.** The ⟨0.29⟩ rule assumed the peek surfaces UNCERTAINTY, which a gate may reasonably decline to
act on. Measured on published 0.29.1, it does not: it resolves a CONCRETE denied effect and names the
function. Under `deny Net`, `axios` had **37 functions the engine had concluded perform Net** — printed,
per function — and still exited 0 with `policy ✓`. (`axios` ships 5 real `.ts` files, every one a type
test, against 160 `.js` implementation files.) Also measured: `node-fetch` 15, `ky` 9, `execa` 9, `zx` 3,
`ofetch` 1. An engine that concludes a function performs the denied effect, prints that conclusion, and
then certifies the tree is committing the cardinal sin holding its own evidence.

**Exit 2, not exit 1.** These functions are never reported as `violations` and never appear in
`functions`: the gate did not JUDGE them, so claiming a violation would be false in the other direction.
Exit 2 says *I could not see enough of this tree to answer*, reusing the `{ok:false, incomplete:true}`
vocabulary ⟨0.21⟩ already defines. A real violation (exit 1) still dominates.

**What does NOT change.** The block is bounded to effects your policy DENIES, so the trigger is never
"you excluded something" but "you excluded something that does the thing you forbade". Across 27 real
packages this flips 6 and leaves 14 green — every one of those with an empty peek, because the scan read
them in full. **Measured more broadly since:** across 37 real projects and 4 realistic policies
(`deny Net`/`Exec`/`Fs`, `pure`), **16 flip at least one gate**; of 96 gates green under 0.29.1, **31 now
exit 2**. Verified by reading the named code, **29 of those 31 are genuine** — serde's `build.rs` running
`rustc`, clap's completion tests spawning shells, alamofire launching `/usr/bin/leaks`, axios's 160 unread
`.js` files. **Jar and class-directory targets are unaffected**: java flipped 0 of 14, because there is
nothing under such a root to peek. A present-and-empty `outOfScope` stays exit 0. A report produced with NO policy has no
`outOfScope` key at all, and gating it stays exit 0, so pre-⟨0.30⟩ reports are unaffected on contact.

**If this turns your gate red.** Read the `⚠` lines: each names a function, its file, and the effect.
The verdict document carries the same list under `outOfScope` for machine consumers. Then one of:

- **Bring the files into the scan** so the gate judges them properly — `--include-tests` (rust) or
  `--allow-js` (ts). Expect the truth rather than a pass: axios under `--allow-js` exits 1 with 27
  genuine violations. **There is no flag for every class**: nothing brings a rust `build.rs`, a swift
  harness target, or a **ts test file** into scope — candor-ts filters test paths unconditionally and
  has no `--include-tests` — so those need one of the options below.
- **Scope the rule** so it does not reach the excluded code (`deny Exec src`) — measured working on rust
  and swift for exactly the build-script and test-target cases above.
- **Address the effect**, which is the point of the gate.

**There is no opt-out.** No flag, environment variable or config key restores the ⟨0.29⟩ behaviour. The
rung is a decision about what a green gate means, and a halfway setting would be a second meaning. If you
are not ready, the escape is the engine pin — do not upgrade yet.

**A known over-charge, stated rather than discovered.** A write to a stream or file descriptor reached
through a helper can be charged `Net`, because `tty.WriteStream` extends `net.Socket`. It accounts for 2
of the 31 measured flips (execa under `deny Net`). It predates this rung — ⟨0.30⟩ only makes it
verdict-bearing — and it is a classifier fix with its own risk, so it is being made separately rather
than folded into a release.

**The finding states what candor CONCLUDED, not what is true.** The reason string reads *"candor's
analysis reaches this effect"*, not *"the effect is real"*. For 29 of the 31 measured flips the stronger
wording would have been accurate; for the 2 above it would not, and this family rates a FALSE disclosure
worse than a missing one. A finding that asserts ground truth makes a claim the analysis cannot support.
No verdict changes, and the `did NOT judge` phrase PART 48 pins is untouched.

### Fixed — found by an adversarial review of the rung above, before release

- **A corrupt `outOfScope` key failed OPEN.** A present-but-malformed key was coerced to nothing, so
  `gate --report` answered exit 0 / `ok: true` over a report whose peek had resolved a denied effect —
  the exact fail-open coercion the strict read exists to prevent. It now refuses (exit 2), naming the key.
- **The peek used the GATE'S OWN matcher.** It had flattened the policy into a set of effect NAMES,
  which discards `Net[known-partner]`-style destination classes and rule scopes, and reads `pure` — a
  deny rule with an empty effect list meaning *every effect except Unknown* — as denying NOTHING. So the
  strictest policy silently disarmed the rung (exit 0 where `deny Exec` exits 2 on the same tree), while
  a class-filtered rule fired on hosts it does not deny. Both directions are gone.
- **`unverified --strict` and `fix-gate --strict` follow the gate.** They answered clean at exit 0 over a
  report `gate --report` refuses at 2, which breaks the standing rule that an advisory verb must never be
  less sensitive to incompleteness than the gate over the same bytes.
- **The finding text no longer contradicts the verdict** — it said "the verdict does not account for it"
  directly above the line saying the verdict is incomplete because of it.

## [0.29.1] — 2026-08-18

- **Family build bump only — no engine changes in this repo.** 0.29.1 is a WITHIN-SPEC patch cut across
  the family; the floor is unchanged at 0.29 and this engine's behaviour is identical to 0.29.0. The
  patch carries fixes in candor-ts, candor-java and candor-rust (see their changelogs) plus the Claude
  Code stop-hook work in the umbrella. Written explicitly because an EMPTY `## Unreleased` is left
  alone by the stager, and `release.sh` then falls through to "the newest non-empty section" — which
  would have published a v0.29.1 release carrying 0.29.0's notes verbatim.

## [0.29.0] — 2026-08-17

- **The `unanalyzed` summary line names the cause the report already named.** A file that reads fine and
  fails to PARSE lands in `unanalyzed` too — measured with 2000-deep parens: `source failed to parse:
  parsing has exceeded the maximum nesting level`. The stderr summary said only "could not be read",
  sending a reader to check permissions on a file whose permissions are fine. The per-entry `reason` in
  the report was right all along; this is the line a human actually sees, so it must not narrow the cause
  the report widens. Gate behaviour is unchanged and was already correct — *a gate cannot be green over
  unanalyzed code* (exit 2), against exit 0 for the shallow control.

- **⟨0.29⟩ REVIEW FIX — the `forbid`/`only` boundary disclosure was silent for an ALL-PURE dependency,
  and its comment said otherwise.** The check read `depsIndex.byKey` (entries JOINED) while the comment
  directly above it asserted "keyed on a report having been READ, not on an entry being joined" — true of
  the design, false of the line under it. A dependency whose reached functions are pure contributes no
  entry, so the disclosure was silent in exactly the case it exists for. `reportsRead` now carries the
  fact. MEASURED four-way: rust and ts warned, java and swift did not. Third stale-comment finding of this
  rung, and the first where the comment described the intended code rather than the shipped code.
- **⟨0.29⟩ `forbid`/`only` stop at the SCAN BOUNDARY, and now say so.** Both are matched over the call
  graph; a chained dependency contributes EFFECTS, not EDGES, so a function calling into a dep has an
  empty adjacency and the crossing is invisible to them. MEASURED with a dep chained:
  `only model -> util` answered `policy ✓` over a call into the dependency while a LOCAL unpermitted scope
  in the same run fired AS-EFF-011 — the rule was armed; the boundary was the gap. **Worse for `only`**,
  which asserts A reaches the listed scopes AND NOTHING ELSE — a completeness claim — and exists precisely
  because `forbid` fails open: a package that calls a third-party library is not a leaf, and the gate
  called it one. Disclosed on the advisory channel beside the verdict, the ⟨0.29⟩ `outOfScope` posture:
  say what was not judged, leave the exit code alone. Making the rules cross would need dep-report EDGES
  and would force operators to enumerate third-party scopes in an `only` list — the enumeration-that-rots
  that form was designed to escape. Silent when no dep is chained, and when the policy carries no name rule.
- **⟨0.29⟩ a malformed `net-partner` line was kept as a junk host instead of being disclosed.** The
  grammar is `net-partner <host>`; the `=` spelling an operator reaches for by habit
  (`net-partner = partner.example`) parsed as the HOST `"= partner.example"`, entered the partner set, and
  matched nothing for the rest of the run. **The direction is SAFE** — the gate stays armed, so nothing is
  certified that should not be — which is exactly why it sat unnoticed in ALL FOUR engines: the operator
  believes a partner is declared, the verdict disagrees, and no line connects the two. ⟨0.28⟩ gave POLICY
  files an `ignored` block for this shape; config files had no equivalent anywhere. Now warns and skips,
  which is the contract candor-java's own config doc already claimed for *"every other malformed line in
  this file"*. A well-formed line stays silent.
- **⟨0.29⟩ `String/Data(contentsOf: URL(string: "…")!)` proved a remote endpoint and captured no host.**
  The idiomatic Foundation one-line GET produced an EMPTY `Net` surface while
  `URLSession.shared.dataTask(with:)` on the same URL captured the host — so `allow Net <host>` could not
  be used for this shape at all and `deny Net[unknown-host]` fired on a host the classifier can plainly
  read. It failed CLOSED, so nothing was certified wrongly; the cost was the whole surface. Routed
  through `recordSurfaces` so the host, the ⟨0.13⟩ model-host refinement and the destination class all
  behave as on every other Net call — a model URL reached this way now refines to `Llm`, which was
  impossible while no host was captured. The scheme test also now reads the `contentsOf:` ARGUMENT rather
  than the whole argument list: a text search over every argument is the "literal anywhere" hazard this
  rung removed from `Fs`/`Net`/`Db`/`Exec`, and it could have let a scheme in a trailing argument decide
  the category of a URL it is not. A file URL still classifies `Fs`, and an indeterminate scheme still
  yields `Unknown`.
- **⟨0.29⟩ `gate --report`'s `allow` refusal stated a premise this rung made false.** The message said the
  AS-EFF-008 surface-completeness marker *"does not ride the report wire"*. It rides now: `incomplete` is
  published per function and declared in `resolves`. MEASURED — reports carry
  `resolves: ["fs","incomplete"]` and `incomplete: ["Fs"]` on the masked unit, and the verb still refuses.
  **Refusing remains correct** (a producer that does not declare the marker cannot be gated on, and
  answering per-report would make one engine evaluate where its siblings refuse, splitting the verb), so
  only the stated reason changes and exit 2 is unchanged. SPEC §6.2 had already corrected this same
  wording for itself in ⟨0.24⟩ — *"This clause first said the marker 'does not ride the wire', flatly.
  That is FALSE…"* — while the engines kept shipping the flat version. A user-facing message describing a
  limitation the code has since removed is worse than a stale code comment: operators read this one.
- **⟨0.29⟩ the SPEC §2 `fs` read/write direction was missing from the two Foundation file idioms.**
  `d.write(to: url)` and `s.write(toFile:)` published `fs: None`, and `Data(contentsOfFile:)` /
  `String(contentsOfFile:)` the same — while `FileManager.createFile`/`contents(atPath:)` on the same tree
  published `fs: ["write"]` / `["read"]`. Both gaps sit in carved-out branches of the collector that
  bypass the general `kappaMember` path, which has always called `fsKind`; and in both cases the
  direction is proved by the very condition that selected the branch (`isFileWrite` for the write,
  *"UNCONDITIONALLY a file read"* for the read, in that comment's own words). §2.1 `resolves` declares
  this producer computes `fs`, so a per-call gap reintroduces per-unit the absent-vs-undetermined overload
  that declaration exists to remove. candor-rust, candor-ts and candor-java were complete here, two-path
  `copy → ["read","write"]` included. No gate filters on `fs`, so no verdict moves.
- **⟨0.29⟩ ⚠ `privacy-manifest --verify` verified GREEN over an EventKit under-declaration.** A plist
  declaring only `NSCalendarsWriteOnlyAccessUsageDescription` passed against code calling
  `EKEventStore().calendars(for: .event)` — a READ, which Apple requires full access for. `privacyKind`
  already classifies EventKit's verbs and `PRIVACY_DIRECTION_KEYS` already splits Calendar's keys
  read-vs-write, but the ONLY caller of `privacyKind` was the general `kappaMember` branch, and an EventKit
  store call is handled by its own earlier branch (the one discriminating Calendar from Reminders by entity
  type). `privacy` therefore came back ABSENT and the no-direction fallback treated every key in the family
  as an acceptable alternative. Probed all three families Apple splits: Health (write over Share-only) and
  Photos (read over Add-only) correctly exit 1; Calendar was the one whose direction never arrived.

  **A code comment two hundred lines away still claimed NONE of the three were covered** — written before
  `privacy/2` shipped the direction half and never updated. It is the reason nobody re-measured: a
  limitation stated as prose reads as considered. Two comments in one file contradicted each other and
  nothing failed. The paragraph now records what was measured, family by family.
- **⟨0.29⟩ ⚠ `excluded[].peeked` claimed a read the peek had not finished.** The rung already made
  the flag an OUTCOME rather than a lookup on the exclusion class, and stopped one level short. The peek
  reuses this engine's own entry point, so it produces its own ⟨0.21⟩ `unanalyzed` manifest — and
  the parent read only `functions` and discarded it. A peeked file that FAILED TO PARSE inside the child therefore published
  `peeked: true` beside `outOfScope: []`, byte-identical to a clean peek, on ALL FOUR engines. The
  ⟨0.26⟩ partial-manifest rule failing inside the rung built to enforce it, in the same field, twice.
  The claim is withdrawn PER CLASS — a parse failure is a fact about one file — and an unread file that
  cannot be attributed to a class withdraws the claim for all of them. SPEC §2, conformance PART 52,
  calibrated in both directions: reverting the fix fails shape A, and publishing the SAFE value
  unconditionally fails the control that notices the feature has been deleted.
- **⟨0.29⟩ ⚠ `outOfScope` was published over a policy this engine REFUSES.** SPEC §2 already said
  the key must be ABSENT there — "the peek is a producer reading the policy, and it may not certify
  relative to a gate that evaluated nothing" — and the clause shipped WITH the rung while only
  candor-java implemented it. The harm is the key, not the finding: `outOfScope: []` beside an exit 2
  reads *a policy was configured, I looked at what it denies, and there is nothing*, when the look was
  taken against rules no route would honour and the denied set searched was the parser's SALVAGE of an
  unhonourable file — the silent rewriting the refusal exists to prevent, one layer down. Conformance
  PART 53, whose two controls stop an engine passing by never emitting the key (which deletes the peek)
  and by collapsing present-and-empty into absent (⟨0.27⟩ asked-and-clear vs ⟨0.26⟩ cannot-answer).
- **⟨0.29⟩ ⚠ `only` violations carry their OWN code, `AS-EFF-011`** — not `forbid`'s `AS-EFF-009`. A rule
  code is the handle a CI suppression, a dashboard link and an alert filter key on, and the two forms are
  opposite constructs: must-not-reach versus must-be-on-the-list, with opposite remedies. **The decisive
  argument is timing.** Before this rung an `AS-EFF-009` suppression meant exactly *"I have accepted a
  `forbid` crossing"*; shipping `only` under it would make every existing suppression silently begin
  muting a class of violation its author never accepted — a fail-open change to an operator's config, made
  by us and invisible to them, which is the argument `only` itself is built on turned on the tool. Free to
  fix before release, breaking after it. Pinned by PART 49, which asserts both halves: 011 present AND 009
  absent, since a row checking only the first would pass on an engine emitting both.
- **⚠ ⟨0.29⟩ THE PEEK CHILD INHERITED THE BASELINE.** The policy was cleared from all three of its
  sources; `baselinePath` arrives by the IDENTICAL env-over-config ladder (`CANDOR_BASELINE`, then the
  config's `baseline` key) and nothing cleared it — so a peek child on any baselined project ran the
  AS-EFF-005 ratchet independently over an arbitrary excluded-file subset. REPRODUCED on the exact argv
  the parent hands the child: exit 1, `[AS-EFF-005] helper gained effect { Exec } not present in the
  baseline`. Silent only because the parent never inspected the child's exit status — so the obvious
  hardening would have started silently losing every peek finding on a baselined project. The comment
  arguing that clearing at the merge point is "the one place the answer cannot be routed around" was
  right about policy's three routes and never asked whether policy was the only GATE.
- **⚠ ⟨0.29⟩ `excluded[].peeked` came from a static class table**, so a child that crashed or returned
  nothing still published it beside `outOfScope: []`. An outcome now, and the scope block is assembled
  after the peek rather than before it.
- **⟨0.29⟩ `only`'s permitted scopes match by exact segment run** — the shared prefix matcher is
  fail-CLOSED for deny/forbid and fail-OPEN for a permission. Found by review, four-way.
- **⟨0.29⟩ A 120s deadline on the peek child**, which re-parses exactly the files this engine has never
  parsed; an unbounded wait turned one pathological input into a hung scan and a hung CI job. Also:
  `parsepolicy` publishes `only` (a test pinned the three-key set and so pinned the omission in place),
  and `--peek-excluded` with no value no longer prints its refusal twice.
- **⟨0.29⟩ `resolves` now declares `incomplete`** (SPEC §2.1). An absent `incomplete` is overloaded
  between "this producer does not compute undetermined locators" and "it computed them and found none" —
  exactly the ambiguity `resolves` was built for, one field over from the `fs` case that motivated it. A
  producer that computes the surface declares it; one that does not MUST NOT, since listing it would turn
  "unimplemented" into a false "nothing undetermined". Pinned by conformance PART 50, which checks the
  declaration BEFORE reading any absence as meaningful.
- **⟨0.29⟩ `only <A> -> <B> [<C> …]` — the PERMISSION form (SPEC §6.2, AS-EFF-009).** `A` may reach `A`
  itself and the listed scopes, nothing else. **`forbid` FAILS OPEN — the dependency you forgot to
  prohibit is silently permitted — so a leaf package could only be protected by an enumeration that does
  not cover a package added tomorrow.** `only` fails SAFE. The walk STOPS at a permitted scope, `A -> A`
  is implicit, zero-match is measured on `from`, the ⟨0.28⟩ zero-rule guard counts the new kind (its own
  doc comment says a check reading a SUBSET of the kinds is the false-answer shape it exists to close),
  and a report route REFUSES it (exit 2) for a stricter reason than `forbid`'s: `only` asks whether
  EVERYTHING reached is on a list, so a report that omits a crossing turns a green into a claim of
  COMPLETENESS.
- **⟨0.29⟩ A refusal NAMES THE RULE, not a count of its kind.** `gate --report` over a `forbid`/`allow`
  policy said *"this policy has 1 `forbid` rule(s)"* — a fact about the FILE handed to a reader asking
  which LINE stopped their gate, and with two rules every row said "2". Measured family-wide on one
  fixture: rust, java and candor-ts all printed the rule text; **this engine was the only one that did
  not.** Both kinds fixed together — `allow` is the sibling no conformance row anywhere writes into a
  `.pol` file, so nothing was watching it at all. The rule now rides `why` itself rather than a caller's
  prefix, so a channel added later cannot lose it. Pinned by the strengthened PART 47 row.
- **⟨0.29⟩ ⚠ The report declares what the scan chose not to open, and READS it.** `analyzed.count` is
  a NUMERATOR; the file selection that produced it appeared nowhere, so a consumer could not tell
  whether the answer was to the question they asked. Measured on this engine 2026-08-15: `deny Exec`
  over a package whose `Tests/Helper.swift` runs `Process().run()` answered `policy ✓`, exit 0, with
  nothing on stderr and no key in the report. Two halves, per candor-spec/FILE-SET-DESIGN.md §5.2:
  - `excluded` — one entry per class (`manifest`, `harness-target`, `test-source`,
    `outside-the-target-closure`, `build-output`) with a count and the engine's own reason. Classes
    with counts, never file lists: `.build/` is unbounded, and a gate that prints thousands of paths is
    one people scroll past. ALWAYS emitted, `[]` included — ⟨0.27⟩ makes a zero-match a positive
    statement, and ⟨0.26⟩ makes an absent key mean "this producer cannot answer".
  - `outOfScope` — THE PEEK. The excluded files are read, and an effect the policy DENIES in one of
    them is reported as its own kind. The verdict does not move: exit unchanged, `violations`
    untouched, the function absent from `functions`. A file the gate declined to judge must not decide
    an exit code. Policy-SCOPED (no policy ⇒ the key is absent, because nothing was asked) and BOUNDED
    by the policy (`deny Net` says nothing about an `Exec` in your test tree) — which is what keeps it
    quiet enough to be worth reading.

  A CHILD `candor-swift` over the parent's own excluded list, not a second analysis path. candor-rust
  recurses into `scan_one`; this engine's scan is top-level code rather than a callable function, so
  "same classifier, different file set" comes from the same BINARY. A bespoke pass would be a second
  opinion, and a drifted second opinion reported as a warning is worse than no warning. The child is
  handed the parent's list rather than re-deriving it (`--target` prunes far below the walk), gets no
  policy from flag, env or config, and a peek that cannot run leaves `[]` rather than failing the gate.
  `.build/` is counted and deliberately NOT peeked: other people's tests are not a finding about your
  project. The self-gate's subprocess inventory moves 2 → 3, with the justification recorded in it.
- **⟨0.29⟩ `unverified` and `fix-gate` certified over a policy the gate had refused.** Both hand
  `pol.deny` to the core, so `forbid`/`allow` were dropped at the call boundary and a `forbid`-only
  policy produced `{"ok": true, …}` at exit 0 — a certification relative to a gate that evaluated
  nothing. SPEC §3.1's answerability MUST binds every verb reading a §2 report, not the gate alone.
  Measured four-way: candor-java disclosed and withheld `ok`; rust, ts and swift did not. The gate's
  inline refusal block is now `wholePolicyRefusals()` and shared. `--strict` reaches exit 2 on all four.
  Pinned by conformance PART 47.
- **A test was pinning this engine's divergence from the reference.**
  `testAnAllowOnlyPolicyIsNotZeroRule` asserted `ok` was PRESENT for an `allow`-only policy — but §3.1
  names `allow` unanswerable from a report, and candor-java has always withheld `ok` there. The row's
  original point (an `allow`-only policy is not the zero-rule case) is kept; what it asserts about the
  answer has moved to the correct one.

## [0.28.2] — 2026-08-15

_A cardinal-sin fix. 0.28.1's body-less-declaration pass reopened, in two shapes, the hole it was
written to close — both found by a max-effort review of that patch, both live on npm and crates.io
until this release. The spec floor is unchanged at 0.28._

- **The self-gate's exit-2 branch is gated on the Exec verdict.** It fired before the subprocess check
  was reported, so an ESTABLISHED violation was announced as "could not evaluate" and the FAILED line
  below it was unreachable — the could-not-evaluate collapse this release fixed, inverted.

- **Version-aligned only, no functional change.** The cardinal-sin fix this release carries is in
  candor-ts; `release-preflight` [4] requires every engine's build version to agree, so this arm
  moves with the family. The spec floor is unchanged at 0.28.

## [0.28.1] — 2026-08-15

_Post-release review fixes. 0.28.0 shipped, then a high-effort review of that work found
defects in it — three of them a defect of the same class as the fix that introduced them. The
spec floor is UNCHANGED at 0.28: no contract moved, so this is a build-version patch._

- **The self-gate's `<main>` hole.** 0.28.0's claim that the gate "fails on an Exec added anywhere in
  main.swift" was overstated: it holds only for code that BINDS a unit. A spawn in BARE TOP-LEVEL code does
  not — the engine folds every file-scope statement into one synthetic `<main>`, which is declared, so
  ~1.8k of main.swift's 2159 lines were exempt. The demonstration that convinced me otherwise used a
  named `func`, which binds its own unit and IS caught. Judging `<main>` on its `direct` set instead
  does not work either: it carries Exec/Ipc there on a clean tree, because declarations fold in too.
  A SOURCE RATCHET now covers the gap — the subprocess call-site inventory, by file, comments excluded —
  and it is falsified against exactly the case the unit check misses.
- **`CompletenessManifestTests` cleans up after itself.** `reportFixture` was the one helper in that file
  without a `defer` — it returns the FILE path, so the caller never sees the directory and has nothing to
  defer on. 11 call sites, 142 trees accumulated. A/B'd: 10 leaked per run before, 0 after, 781 tests
  passing either way.
- **AGENTS.md points at the umbrella**, with the embedded `AgentsDoc.swift` regenerated in the same commit.

- **`GateProcessTests`' spec assertion compared a value to itself** — it derives from `--version`,
  which prints the same constant the verdict writer uses, and after it landed there was no in-tree
  pin of the floor at all: `specVersion = "0.29"` passed every test and both drift gates. A literal
  canary is restored in `AgentsDocDriftTests`, the same fixture candor-report keeps in the rust arm.

- **exit 2 is "could not evaluate", not a violation** — the self-gate reported the ⟨0.21⟩ fail-closed
  verdict as a red boundary and collapsed it to exit 1. Found by review in the java arm; all three
  self-gates were written with the same collapse.

## [0.28.0] — 2026-08-14

- **Self-gate: the declared boundary is a tracked file, and the four subprocess UNITS are declared rather
  than the file they live in.** The boundary used to be a `printf` inside `ci.yml`, so the repository
  declared no policy at all and `candor-swift .` in a checkout applied nothing. Worse, half (1) proved the
  core clean by DELETING `main.swift` before the scan — 2158 lines in which a new subprocess was caught by
  nothing. Now `.candor/policy` (`deny Net Db`) over the whole engine with no file excluded, plus an
  assertion that the Exec/Ipc units are exactly the four in `main.swift`. An unexplained `Process()`
  appended to `main.swift` reddens the new gate and passes BOTH halves of the old.


- **⟨0.28⟩ a caller certified what its callee left undetermined — `incomplete` now propagates
  caller-ward.** The report entry's `incomplete` was the DIRECT map (a function's own surface whose
  locator could not be pinned) where the field a consumer branches on to decide whether to trust an
  effect surface needs the TRANSITIVE view. MEASURED on **Alamofire 5.9.1** by
  `conformance/check_honesty.py`, run unmodified over a corpus round: `WebSocketRequest.socket` calls
  `WebSocketRequest.task`, which carries `incomplete`, and `socket` carried nothing — it read CERTAIN off
  an uncertain callee, breaking the invariant the conformance suite already gates on (for every edge
  f → g, uncertain(g) ⟹ uncertain(f)). candor-rust is the control and not a vacuous one: the same corpus
  gave it **34 callers of an incomplete function and it propagated 34**, where this engine propagated
  **0 of 8**. SPEC §2 states the rule over the chained-dependency join — it "applies EVERY surface …
  (`hosts`/`cmds`/`paths`/`tables`/`invisible`/`incomplete`), not just the effects", because "a join that
  carries the effect and drops `incomplete` lets a benign literal in the consumer certify what the
  dependency declared uncertifiable" — and that harm is not a property of the PACKAGE edge; `socket`
  certifying what `task` declared uncertifiable is the same sentence one boundary in. `incompleteDirect`
  still exists and is still what the privacy verify reads: the distinction is real, it was simply the
  wrong view for this field. Alamofire after: 66 incomplete fns, 54 callers of one, 54 propagated.

- **A shared loader made three verbs disclose their own incompleteness under `fix`'s name.**
  `loadFixModel` is used by `fix`/`fix-gate`/`tour`/`path`/`privacy-manifest` and hardcoded `who: "fix"`,
  a name that reaches the user only inside a disclosure — *"candor-swift fix: report `…` could not be
  parsed — OMITTED, and this answer is reported INCOMPLETE"*. So `candor-swift privacy-manifest` over a
  corrupt sibling told the reader that `fix` had dropped something. The disclosure fired and its content
  was correct, so this was never a silent under-report — but it named a command the reader was not
  running, so reproducing it meant running the wrong one. `who` is now REQUIRED rather than defaulted: a
  default would leave the trap armed for the next caller, which is exactly how three of the five existing
  callers acquired it. The sibling loaders (`loadUnverifiedFns`, `loadGateReport`, `loadBaselineCallgraph`,
  `loadInferredLoud`) were swept and already name their own verb.

- **⟨0.28⟩ the third row is not the first row: `noManifest`** (SPEC §2, *"AND THE THIRD ROW IS NOT THE
  FIRST ROW — measured, two engines report it as one"*). §2's ⟨0.24⟩ table has THREE rows, and this
  engine filed the third under the first's name. MEASURED on the release binary before this change, over
  `{"candor":…,"functions":[]}` with **no `analyzed` key at all** (a pre-⟨0.21⟩ producer): `tour`,
  `unverified`, `fix`, `fix-gate`, `privacy-manifest` and `gains` all emitted
  `judgedNothing: ["<path>"]`, and the note said the report *"say[s] they JUDGED NOTHING
  (`analyzed.count: 0`)"*. **The report declares nothing.** The hedge is the right DIRECTION — row 3's
  own instruction is *no manifest, no claim* — but the disclosure was false, and this family rates a
  false disclosure worse than a missing one (§3.4's `net-partner` finding: an engine reported "ignoring
  unknown config key" *while honouring it*). It was also a hole in ⟨0.28⟩'s own pin, which defines
  `judgedNothing` as *reports declaring `analyzed.count: 0`*: filing row 3 there made one key mean two
  things and lost the distinction the table exists to draw.

  Row 3 now carries its own SPEC-pinned key, `noManifest: ["<report path>", …]`. It is added to
  `ReportCompleteness` beside `judgedNothing`/`unanalyzed`/`unreadable`, so it reaches every consumer
  through the one key set (`disclosureJSON` — the advisory verbs, `privacy-manifest` generate + verify,
  `gains` on both sides as `noManifest`/`baselineNoManifest`) plus `tour`'s hand-built JSON, where it
  takes the sorted-map position (`judgedNothing` < `noManifest` < `reaches`) the reference emits. It has
  its own clause in the `⚠ INCOMPLETE` banner, its own per-report line, and its own `gateLine` variant
  so a row-3-only hedge stops calling the report *judged-nothing* in prose. It raises `incomplete` like
  its siblings, is omitted when empty, and — like `judgedNothing` — reaches `mustHedge` and **not**
  `isIncomplete`, so no exit code moves.

  **THE SPLIT ADDS A PREDICATE, IT DOES NOT INVERT ONE.** `claimsToHaveJudgedNothing` is not only a
  disclosure predicate: the chained dep-join reads it to decide COVERAGE (`coveredPkgs` vs
  `unjudgedPkgs`, the set that silences the κ ledger and the per-fn `invisible`) and `gate --report`
  reads it for its verdict note. An absent manifest must keep granting NONE — that is row 3's own
  instruction — so making it answer `false` for a manifest-less report to fix the LABEL would have
  turned every pre-⟨0.21⟩ report into a covered one: a silent under-report introduced by a disclosure
  fix. A second, disclosure-only `hasNoManifest` chooses the KEY for a hedge that was already happening,
  and two tests pin the coverage reading unmoved — the chained-join arm (arm-for-arm against the
  UNCHAINED run) and the gate-route note. The gate's own note is untouched: it already named the
  condition honestly (*"`analyzed.count` is 0, absent with no entries, or unreadable"*).

  **BOTH CONTROLS ARE ASSERTED.** Row 1 (`analyzed.count: 0`) keeps `judgedNothing` and never becomes
  `noManifest` — the split goes both ways or it is a rename. Row 2 (`count: 7`, `functions: []`) is a
  legitimate all-pure claim §2 rule 3 requires a consumer to BELIEVE and MUST NOT hedge; a fix that
  hedges all three has disabled the feature rather than implemented the rule. A manifest-less report
  that LISTS functions keeps its standing on both the disclosure and the coverage side, and a JSON
  `null` manifest stays row 1's fail-closed business (present-but-unreadable is not absent). Measured
  before/after across ten verb invocations per row: the row-1, row-2, manifest-less-with-entries and
  intact-report output is **byte-identical**, only the row-3 block changed.

- **⚠ ⟨0.28⟩ §3.1: a FILE locator resolves to that file — never the prefix-sibling union.**
  `resolveReportLocator` stripped a family-shaped `<prefix>.<pkg>.Swift.json` back to `<prefix>`, so
  `--report r.A.Swift.json` silently read `r.B.Swift.json` too: `path` traced a function that lives
  only in the sibling, `gate --report` fired a violation from it with `analyzed.count` summed across
  both files, and `gains` listed the sibling's effects as the named file's (all measured). Now a
  `.json` locator is that file plus its §2.2 sidecars; a sidecar name resolves to the report it is a
  sidecar OF; a nonexistent file path fails loud instead of widening to its directory. PREFIX (whole
  set, unioned) and DIRECTORY (discovery) are unchanged. ⚠ only for a consumer who relied on the
  union: name the prefix to get the set.
- **⟨0.28⟩ §3.3.1: the scan target expands to the files the run will PARSE.** A `--gate-json` under a
  directory target ending `.swift` named a file the walk was about to read — measured,
  `<dir> --gate-json <dir>/extra.swift` replaced the operator's source with the armed verdict, scanned
  the wreckage, and reported success. Refused at exit 2 having written nothing, on both sink routes;
  a not-yet-existing `.swift` under the target is the same refusal (arming would create it and the
  walk would parse the verdict as source). Containment alone is NOT refused — `<target>/.candor/…`
  stays the recommended layout, pinned by a control.
- **⟨0.28⟩ §3.3.1: a repeated `--out` is refused, with the fail-closed report at EVERY prefix named.**
  This engine took the LAST prefix, so `--out A --out B` left A holding a previous run's whole report
  set, readable as current — and a `gate --report A` over it answers from a scan that never ran. Now
  every distinct prefix named is armed to the ⟨0.21⟩ fail-closed empty and the run exits 2 (a verdict
  sink and the `--json` stream get their refusal documents too). Two spellings of one prefix are ONE
  sink and are not refused.
- **⟨0.28⟩ §2: `privacy-manifest` consults completeness.** The verb loaded `model.completeness` and
  never read it — a clean "no sensors reached" shipped over a partial or corrupt-sibling report (#65;
  the ruling pins it as the same MUST as `show`/`map`, not the same shape problem). Both machine
  documents (generate + verify) now carry `incomplete` / `unanalyzed` / `judgedNothing` (an ARRAY of
  report paths), each omitted when not applicable — a complete report's output is byte-identical.
  Prose note on the family channel per mode; exit codes and `ok` untouched.
- **⟨0.28⟩ §2: `fix-gate`/`unverified` over a zero-rule policy answer with the caveat document.** Both
  answered `{"ok": true, "<result>": []}` over a comments-only policy — an empty result set
  indistinguishable from "asked and everything passed". Now `ok` and the result key are WITHHELD and
  `unevaluated` carries the gate's whole-policy entry (one predicate, three routes). Exit unchanged,
  cell by cell: 0 (`--strict` included) over a complete report; `--strict` keeps its standing 2 only
  over an incomplete one. The zero-rule question reads every rule vector — an allow-only policy
  answers normally.
- **⟨0.28⟩ §6.2: the verdict carries `ignored` — the policy lines the parse dropped.** The zero-rule
  refusal fires only at zero survivors, so a 9-of-10-dropped policy still answered
  `{"ok": true, "violations": []}` with nothing in the document about the nine gates never asked.
  `ignored: [{line, text, reason}]` now rides the verdict on both routes, omitted when empty; distinct
  from `unevaluated` (rules that parsed and could not be answered), and the ⟨0.24⟩ exit-2 policy
  errors (a typo'd effect token) stay refusals, never `ignored` residue.
- **⟨0.28⟩ §3.3.1: `gate --report`'s input guard covers what the locator EXPANDS TO, not the locator
  string.** A `--report` locator is a prefix (or a discovery) and the verb reads its `*.Swift.json`
  siblings, but the sink guard compared only the raw flag value — so
  `gate --report r --gate-json r.B.Swift.json` armed over the operator's own report, failed the load
  on the wreckage, and wrote the refusal document over it again (measured; exit 2 both before and
  after, so the regression test asserts bytes). The same destroyer class as the scan-target fix, one
  verb over — found by asking what OTHER spelling reaches the channel just closed. The expanded set
  is enumerated by `gateReportInputFiles`, kept adjacent to `loadGateReport` so the guard and the
  loader cannot drift about what the verb reads; the discovery route (no `--report` at all) is
  guarded identically, and a control pins that a fresh sink beside the reports still gates.
- **⟨0.28⟩ …and the §2.2 SIDECARS expand too.** The first version of `gateReportInputFiles` carved the
  sidecars OUT (the gate opens none, so they read as not-inputs), and the family measurement the same
  day showed why that half matters: `gate --report r --gate-json r.<Unit>.Swift.callgraph.json` armed
  over the sidecar, the report then loaded FINE, and a REAL verdict landed where the graph belongs at
  exit 0 — a success, with the pair destroyed one half at a time; every later `fix`/`rewire` then reads
  a verdict document as a callgraph. `withGateReportSidecars` appends each report's reserved-segment
  family (existing files only). `gate` is deliberately not in the walk — `<stem>.gate.json` is the
  verdict sink's own beside-the-report layout — and the regression test pins that it still gates with
  a real verdict.
- **⟨0.28⟩ `gains` carries `judgedNothing`/`baselineJudgedNothing`, as PATH LISTS — the family ruling
  that ends a three-way key split.** This engine withheld the key on the reasoning that the reference
  did not emit it on this verb and a key one engine emits and another does not is a divergence a
  consumer sees; the instinct was right and the premise was stale — java had already shipped it as a
  path list and ts as a boolean, so the withholding PRODUCED the divergence it was avoiding (the
  names appear in SPEC zero times, the root cause; the spec is being amended in parallel to pin
  them). The ruling: the key travels, and its shape names WHICH report judged nothing — the repair
  differs per file, and `baselineIncomplete` alone cannot say. The current side emits the unprefixed
  key (same symmetry as `unanalyzed`/`baselineUnanalyzed`) and its keys now come from
  `disclosureJSON`, the one place the unprefixed key set is defined. Verdict-preserving; the human
  TSV is byte-unchanged; a complete pair emits the pre-⟨0.28⟩ document key-for-key.
- **⟨0.28⟩ `ReportCompleteness` gains the reference's `unreadable` arm — an unparseable sibling
  report now hedges every consuming verb.** A corrupt sibling was named once on stderr as OMITTED and
  the answer over the survivors read CLEAN: measured, `unverified --json` answered
  `{"ok": true, "unverified": []}` over one good and one truncated report while rust (`unreadable`
  arm), java (`bad` list) and ts (a parse throw judged nothing) each hedge the identical bytes — and
  `gate --report` hard-fails them, so the advisory verbs answered MORE confidently than the gate on
  identical input (the §3.2 relation, inverted). The gap was WRITTEN DOWN in a comment as a known
  difference from the reference — the documented-limitation pattern this project has a standing rule
  about. The arm feeds `isIncomplete`, so `unverified --strict`/`fix-gate --strict` exit 2 (matching
  the reference's `incomplete()`); no new JSON key — `incomplete: true` is the wire for this cause,
  the file is named in the prose note and on stderr. `tour`, `path`, `unverified`, `fix-gate` and
  `gains` inherit it through the shared struct, and **`fix` — which the old comment CLAIMED inherited
  the reading and did not — now actually does**: its loader threaded the struct and the verb never
  read it, so `{"crossing": false}` shipped flat even over an `unanalyzed`-declaring report. Every
  `fix` document now carries the disclosure keys and the ⚠ INCOMPLETE note goes to stderr (stdout
  always holds a document on that verb), mirroring the reference's `cmd_fix`. `privacy-manifest`
  still reads no completeness at all — left for a family decision, since its hedge would be a new
  wire surface.
- **⟨0.28⟩ SPEC §3.3.1 (1): the `--out` pre-pass walks argv with the flag loop's own value rules.**
  The precondition for arming is *"`--out` has been parsed and accepted"*, and the pre-pass matched
  the token wherever it stood: on `--policy --out X` the loop refuses at `--policy` (`--out` there is
  its rejected VALUE, never a flag), but the pre-pass armed X anyway — and the guaranteed exit-2
  skips disarm, so X's previous reports became PERMANENT placeholders on an argv the parse never
  accepts. Measured; so was `--out X --help`, which armed X behind an informational exit-0 that was
  never going to scan. The pre-pass now ends its walk at a value-taking flag whose value the loop
  would refuse (keeping an `--out` accepted BEFORE that point — `--out p --zzz` still arms, the
  rung's designed outcome), and returns nothing on the informational tokens. Unknown flags stay
  stepped over: mirroring the full vocabulary would be a second parser that drifts the first time the
  loop grows a flag.
- **⟨0.28⟩ SPEC §3.3.1 (3): the scan TARGET joins `runInputs` — arming can no longer destroy the
  artifact being scanned.** The spec's input list OPENS with "the target's own source tree" and this
  engine's registry carried every other channel (policy, env, deps, config) and never the target.
  Measured live before the fix, through BOTH arms: `app.swift --policy P --gate-json app.swift`
  replaced the operator's SOURCE FILE with the armed verdict document (the single-file target route —
  "swift targets are directories" was only the common case, never a shield), and
  `p.app.json --out p --zzz-not-a-flag` left a report-shaped target holding the fail-closed
  placeholder past the exit-2 that skips disarm. The registration is ONE EXACT ARTIFACT, never a
  containment rule: a verdict or report written INTO the scanned tree (`.candor/`, the shipped CI
  pattern) stays ordinary usage — pinned by a control test. One registration covers both sinks
  because both arms already ask the same `runInputs`/`sameArtifact` pair. Regression tests assert
  BYTES, not exit codes (the destroying runs also exited 2).
- **⟨0.28⟩ `gains` carries the ⟨0.21⟩ completeness manifest, on BOTH SIDES** (SPEC §2, conformance
  PART 39 (ii)). The last verb of the §2 re-disclosure MUST left open by the entry below. The coverage
  rider has ridden this verb since ⟨0.15⟩ — *a "no gains" over an uncovered dep reads clean with false
  confidence* — and the SAME verb, on the SAME report, in the SAME output, dropped the STRONGER caveat:
  `coverage.uncovered` says "I could not see into this dependency", `unanalyzed` says "I could not read
  this file of YOUR OWN CODE", `analyzed.count: 0` says "I judged nothing at all". The `--json` answer
  now carries `incomplete: true` + `unanalyzed` for the CURRENT report and `baselineIncomplete: true` +
  `baselineUnanalyzed` for the BASELINE — **two disclosures, not one flag**, because the answer rests on
  two reports that fail differently: an incomplete current means the gained set may be SHORT, an
  incomplete baseline means the comparison FLOOR is soft and the existing-vs-new `origin` split this
  verb exists for is unreliable. A combined flag would say "something here is incomplete" and leave a
  supply-chain reviewer unable to act on it. Key names are the candor-rust `fe5d831` set (a cross-engine
  wire surface). NOT a second manifest reader: the element rule stays in `mergeCompleteness` and the
  judged-nothing rule in `claimsToHaveJudgedNothing` — the new code only says which FILES to ask, on the
  one prefix walk the version and coverage riders now share. Verdict-preserving: the human `fn\teffect`
  TSV is byte-unchanged, a complete pair emits the pre-⟨0.28⟩ document key-for-key, and `--strict` still
  keys on the GAINED SET (a hedged pair that gained nothing exits 0; one that gained Net exits 1).
  733 unit tests, smoke 137/0.
- **⟨0.28⟩ the DESCRIPTIVE query verbs carry the ⟨0.21⟩ completeness manifest too** (SPEC §2). The
  re-disclosure MUST binds *any* verb whose output could read as a NEGATIVE FINDING — "a verdict, an
  empty result set, or a zero count" — and this engine read the manifest only for the two verbs that
  answer `ok`. Measured 2026-08-11 over a report declaring `analyzed.count: 0` and a non-empty
  `unanalyzed` — the standard artifact on disk after a failed run since the ⟨0.28⟩ arming rung —
  `tour --json` answered `{"reaches":[]}` and the prose answered *"nothing hidden — every effect sits
  where its name says it should"*, both at exit 0, out of a report whose own manifest names a file it
  could not read. A consumer could not tell *nothing is hidden* from *nothing was examined*. `tour` and
  `path` (this engine's two descriptive verbs; it has no `map`/`blindspots`/`reachable`/`containment`)
  now carry `incomplete: true` plus the manifest on the JSON channel and the ⚠ INCOMPLETE note on the
  prose one, with the reassuring sentence withdrawn — byte-identical to the candor-rust reference on
  both channels over five artifact states. **`analyzed.count: 0` is a SECOND cause the manifest reader
  did not read at all** (a report that judged nothing names no unread FILE, so the reader saw a complete
  report), decided by the same `claimsToHaveJudgedNothing` predicate the chained dep-join uses, and
  surfaced as `judgedNothing`. It reaches both DISCLOSURE channels and stops at the EXIT CODE: ⟨0.24⟩
  fixed count-0 at `gate --report`'s exit 0, so `unverified --strict` over a judged-nothing report with a
  hole still exits 1, not 2. `unverified`/`fix-gate` withdraw `ok` under the new cause for the same
  reason they withdraw it under the old one. Verdict-preserving: exit codes unchanged in all 70 measured
  (state × verb × mode) cells, and every intact-report cell byte-identical. 732 unit tests, smoke 137/0.
- **⚠ ⟨0.28⟩ the §2.2 sidecars go with the armed report — deleted, not emptied** (SPEC §3.3.1). Arming an
  `--out` report left `<stem>.callgraph.json` and `<stem>.hierarchy.json` live beside it: a pair that
  contradicts itself, with no provenance on the sidecar to arbitrate. Not decorative on this engine,
  because `gains` takes the BASELINE call graph from the sidecar ALONE (`loadBaselineCallgraph`) — a
  currently-pure function is absent from the report by §2 rule 3, so only the sidecar records it. Measured
  2026-08-11: baseline `sd_f` pure reached by `sd_g`; the new version gives `sd_f` an effect and adds
  `sd_h`; the baseline run exits 2 on an unknown flag with its report armed — and `gains --json` answered
  exit 0 with `origin: "existing"` for `sd_f` and `sd_g` and `"new"` for `sd_h`, every label computed from
  a run that FAILED. It now answers `origin: "unknown"` for all three, which is the arm ⟨0.24⟩ already
  pins for an absent baseline callgraph, and a recovering run restores both sidecars byte-identically.
  Deleted rather than `{}` because ⟨0.24⟩ has already ruled empty ≡ absent ≡ unparseable for a sidecar,
  so `{}` is a file this family has declared meaningless. **A `<stem>.gate.json` is deliberately NOT
  taken** — it is the verdict sink's own document, separately armed, and a consumer that reads a missing
  verdict as "nothing to report" goes green. The guess runs OPPOSITE to the armer's: the armer identifies
  positively by content because there an over-reach destroys a file, while here a miss merely leaves a
  sidecar behind, so this goes by the §2.2 reserved segment NAMES **scoped to one report's stem** (a
  prefix-level `<prefix>.locs.json` is nobody's sidecar on this engine and stays). Three further rules:
  the input exemption covers sidecars, over the same `runInputs`/`sameArtifact`; **the sidecars follow
  only if the report write SUCCEEDED**, since a failed arm leaves the previous run's report and taking its
  call graph would make a stale-report/no-callgraph pair no run has ever written; and **a restored orphan
  gets its sidecars back**, because handing back the report alone is a third state neither the pre-run nor
  the armed tree ever had. Conformance PART 37 candor-swift (d) SKIP → PASS. 730 unit tests, smoke 137/0
  (eight new rows, including the premise row so the block cannot pass vacuously).
- **⟨0.28⟩ the `--out <prefix>` report SET is armed too, and what the run did not write is handed back**
  (SPEC §3.3.1 (1)). The stream half shipped first and left the FILE set one hop behind: measured
  2026-08-11, `<target> --out p --zzz-not-a-flag` exited 2 with `p.<pkg>.Swift.json` byte-identical to the
  previous good run (same md5), so a downstream `gate --report` read a green report the failed run never
  produced. The verdict sink arms by writing to a path the run is about to own; a report PREFIX cannot,
  because `<pkg>` comes from a `Package.swift` that has not been read at parse time. The set the run DOES
  know then is the one the PREVIOUS run left — and that is exactly the set at risk — so arming rewrites
  every `<prefix>.*.json` to the ⟨0.21⟩ Row-1 manifest-carrying empty, from ABOVE the flag loop, before
  its own unknown-flag exit (the exit this rung is most often reached through). The default prefix
  (`.candor/report.*`) is armed on the same argument. No §2.2 sidecar is ever ARMED — none carries a
  `candor` envelope beside `functions`, so the identification test cannot reach one — and the question of
  what should happen to them instead is settled by the entry below, which DELETES them with their report.
  The ⟨0.27⟩ (2) input exemption applies to this writer: a prefix expansion
  that collides with something the run READS is left alone and named on stderr, through the same
  `runInputs`/`sameArtifact` resolver the verdict sink uses. **AND WHAT THE RUN TURNS OUT NOT TO OWN IS
  RESTORED, NOT LEFT ARMED** — the reference engine's first version kept the placeholder on every
  un-overwritten file and called it a free fix for orphaned reports; it was a new defect, because a
  placeholder's non-empty `unanalyzed` IS the ⟨0.21⟩ incomplete-analysis trigger, so a COMPLETE run began
  asserting an incompleteness it never experienced (measured here: `gate --report <the orphan>` went 0 → 2
  and no further clean run could clear it). Arming therefore remembers the previous BYTES and hands them
  back once the run has finished writing. The orphan is left exactly as found: it is a separate,
  pre-existing defect with its own wire question, and resolving it inside a staleness fix would be
  deciding it by accident. Deleting rather than restoring is rejected for §3.3.1's own reason — a consumer
  treating a missing file as "nothing to report" fails open by another route. One fail-closed document
  builder now serves both report sinks (`failClosedReportDocument`), and `writeSinkAtomically` gained the
  bytes form so a restore returns the operator's file rather than a UTF-8 round-trip of it. Conformance
  PART 37 candor-swift (a) SKIP → PASS, (b) still PASS.
  **ONLY AN EXPLICITLY NAMED `--out`, NEVER THE DEFAULT PREFIX.** The first version armed
  `<target>/.candor/report` as well, on the reasoning that an operator who passes no `--out` still has
  yesterday's reports there to go stale — right about STALENESS, wrong about OWNERSHIP, and the
  difference destroys data: measured, `candor-swift . --zzz-not-a-flag` overwrote
  `.candor/report.<pkg>.Swift.json` with the placeholder, and committed reports and baselines are the
  pattern this project recommends and ships in CI. A run that dies in argv parsing was never going to
  write there and had not been told it owned that path; destroying a version-controlled artifact is a
  worse outcome than the staleness the rung closes. ⟨0.27⟩'s rule never faced this because `--gate-json`
  has NO DEFAULT — every verdict sink is named — so "arm at the instant the sink is known" presumes a
  sink the operator NAMED, and that presumption is now explicit.
  **AND ONLY FILES POSITIVELY IDENTIFIED AS THIS ENGINE'S §2 REPORT — never a name denylist.** The first
  version excluded `.callgraph`/`.hierarchy`/`.locs` by suffix and armed everything else. SPEC §2.2 ⟨0.24⟩
  reserves SEVEN trailing segments — `callgraph`, `hierarchy`, `calibrated`, `layerreach`, `locs`, `gate`,
  and the `encountered-*` family — and records that the engines were already drifting on the list, one
  carving out six and another two; this carved out three. Measured: the armer overwrote
  `<prefix>.calibrated.json`, `.layerreach.json`, `.encountered-hosts.json` and — worst —
  `<prefix>.gate.json`, a GATE VERDICT, each with a report-shaped placeholder, so a run whose REPORT sink
  was armed silently destroyed the VERDICT sink's document beside it. THE MECHANISM WAS WRONG, NOT JUST
  THE LIST: denylist-over-allowlist is a CLASSIFYING rule, where over-approximating is the safe direction,
  and §2.2 can call an incomplete denylist "loud" because an unregistered suffix merely falls back into a
  candidate set — for a WRITER it inverts, silently destroying a file. The armer now parses each candidate
  and writes only a JSON object carrying both a `candor` envelope and `functions`, which cannot drift as
  the reserved family grows and needs no list; the input exemption is still asked first, so a `--policy`
  that is not JSON at all is named rather than skipped in silence.
- **⚠ ⟨0.28⟩ a configured policy that yielded ZERO RULES refuses** (SPEC §6.2). Measured four-way
  2026-08-10: `--policy <a README>` — the wrong path in a CI script, the commonest spelling of this
  mistake — wrote `{"ok":true,"violations":[]}` and exited 0, byte-identical to a gate that ran and found
  nothing AND to the no-gate-configured verdict, so the one consumer this format exists for could not tell
  *your code is clean* from *your gate had no rules*. The per-line `ignoring policy rule` warnings go to
  stderr, which is not the machine channel. Now exit 2 with the fail-closed refusal document, the same
  posture as the two branches beside it (unreadable file, unhonourable token) and with the same
  precedence: a certain violation — an AS-EFF-005 baseline regression is one, on evidence this run
  carries — still dominates with exit 1 and carries the refusal beside it as `unevaluated`. The
  `unevaluated` list holds the whole-policy entry §3.1 pins for a policy with no rules to name. The
  line-level ignore-with-a-warning leniency is UNTOUCHED; the rung is about what it composes to. A run
  that configures NO policy stays exit 0 — that is the honest way to say "I am not gating", and it is why
  a configured zero-rule policy is never a legitimate expression of that intent. The emptiness test reads
  every rule vector the parser can produce (`deny`, which `pure` also fills, `allow`, `forbid`): the
  reference engine's first draft read one of three and would have refused every ordinary allow-only
  allowlist gate. Conformance PART 38 candor-swift: three rows SKIP → PASS, control row still green.
  **BOTH ROUTES**, from ONE predicate (`zeroRulePolicyRefusal`). The rung landed on the scan CLI first and
  `gate --report` kept exiting 0 over a README for a day — measured 2026-08-11, all three input forms — and
  §6.2 says the defect was measured on that verb too, and that "a route is not covered by its sibling". It
  is the worse of the two to leave open: `gate --report` is the SUPPLY-CHAIN surface, the verb an adopter
  points at a report someone else produced. On the verb route the refusal is outright (no AS-EFF-005
  baseline rides the report wire, so no certain violation can stand beside it), which is the posture of the
  two branches it sits between. An `allow`-only or `forbid`-only policy already refused THERE for its own
  unrelated reason (the AS-EFF-008 marker does not ride the wire; `forbid` matches on NAME and a report
  carries no entry for a pure function) — confirmed pre-existing against a rebuild of the pre-change tree,
  and each still names its own cause rather than this one.
- **⟨0.28⟩ the report stream sink is fail-closed on exit-2, not empty** (SPEC §3.3.1 (4)). Measured:
  `candor-swift <target> --json --zzz-not-a-flag` exited 2 with STDOUT EMPTY — a JSON consumer keying on
  stdout throws a parse error and is thrown back to scraping stderr, the distinction that made the
  incomplete-analysis defect a defect. The report sink one hop upstream from the ⟨0.27⟩ verdict-stream
  rule, arriving through the door that rule was written for the verdict sink and no engine extended.
  Now on any exit-2 while `--json` (report stream) is active and stdout isn't already claimed by
  `--gate-json -` (that two-stream case is refused earlier), the ⟨0.21⟩ Row-1 manifest-carrying empty
  goes to stdout as its only content — `functions: []` + `analyzed.count: 0` + `unanalyzed` naming the
  cause. A `reportStreamWritten` latch on the successful stdout print keeps a later `exit2_refused` from
  double-writing. Conformance PART 37 candor-swift (b) flips from SKIP to PASS. The `--json <file>` sink
  is deferred: on this engine `--json` takes no value, so the file form doesn't exist here.
- **⚠ An extra positional exited 2 with a ZERO-BYTE `--gate-json -`.** The flag loop's unknown-flag arm
  routes through `refuseGateAndExit` when a sink is registered; the extra-positional arm directly below
  it — same class of usage error, same `default:` block — exited raw. candor-scan had no such refusal
  at the time — for that argv it silently scanned the wrong tree, which was fixed minutes earlier the
  same day. The defect here is the zero-byte stream. One usage error, two spellings, and only
  the spelling someone had thought about was closed. Found by the argv COMBINATION sweep in the umbrella's `probe-causes.sh`, not
  by its hand-written list of twelve causes; pinned by conformance PART 36 (b18).
- **⟨0.28⟩ a repeated `--gate-json` is refused, and every path named gets the refusal** (SPEC §3.3.1).
  Like the other three, this engine took the LAST path and left the first exactly as it found it, so a
  previous run's `{"ok": true}` survived a gate that fired. (An earlier draft of this entry said this
  engine alone refused the shape. It did not — that came from a contaminated measurement in which it had
  been handed a second POSITIONAL, so its extra-argument refusal was recorded as a duplicate-sink one.
  Re-measured against a build from before the rung landed: exit 1, stale green intact.)
- **The mostly-Unknown note stops naming a cause it cannot know.** `tour --report R` reads a report it did
  not produce, so "missing project config" was a guess about a build it never ran; it now points at the
  reasons the report itself records. Four-way, and pinned by conformance PART 4l — which had been checking
  the COUNTS only, which is how all four engines drifted here unnoticed.
## [0.27.0] — 2026-08-07









- **An EMPTY SCAN now reaches the machine channel.** `no Swift sources under <target>` exited raw, so a
  consumer reading `--gate-json -` got nothing — an ordinary CI accident (a path that moved) and the
  last cause in this engine still exiting that way. Pinned by conformance PART 36 (b17).
- **An UNREADABLE config left a stale green at the FILE sink**, while the same cause streamed its
  refusal correctly. The §3.3.1 pre-pass reads the config to learn what the sink must not overwrite and
  runs BEFORE arming; its own comment said that read was "LENIENT — no exit, no diagnostic", which was
  an assumption about the reader rather than a property of it. Three exit sites in that reader could
  fire, so the process died before arming and a previous run's `ok: true` survived on disk — the exact
  outcome arming exists to prevent. Third engine with this shape (ts and agents had it), and the first
  where only ONE of the two sink forms was affected: the stream was already right, which is why it took
  a file-sink probe to see. Pinned by conformance PART 36 (b15).
- **…and the guard now enumerates a dep directory exactly as the LOADER does.** The first repair
  registered the directory's files with a FLAT read beside a RECURSIVE loader walk, so a report one
  level down stayed unguarded — and for `--deps`, which writes one subdirectory per `name@version`, the
  nested layout is the ORDINARY one. A guard that enumerates differently from the loader guards a
  different set of files. One enumeration now serves both.
- **⚠ A `--gate-json` sink INSIDE a `deps` DIRECTORY destroyed the operator's dep report.** `deps`
  accepts a directory — `--workspace` writes `.candor/deps/` and hands that back, so it is the common
  spelling — and the loader walks it and reads each report inside. The §3.3.1 sink-over-input guard
  registered only the DIRECTORY, which never equals a file within it, so `--gate-json <depdir>/lib.json`
  was unguarded: arming destroyed the report, the run chained the wreckage and exited 0 with `ok: true`
  written over the input. All four engines. The FILE spelling of this channel had been guarded for a
  release; the directory spelling had not, and no row posed it. Now pinned by conformance PART 36 (b14),
  which asserts both the refusal AND that nothing was written.
- **A gate-adjacent flag given NO VALUE now reaches the machine channel.** `--policy`, `--out` and
  `--gate-json` with a missing value exited raw, so `--gate-json -` got nothing — the last cause in this
  engine still doing that after every other had been routed, and the one §3.1 names beside the unknown
  flag. rust and ts already answered it. Found by sweeping the causes a user can TRIGGER rather than by
  reading exit sites, which is a different list and a shorter one.
- **The configured-dep refusal reaches the machine channel.** `depsFail` exited raw, so `--gate-json -`
  got nothing and a file sink kept the armed placeholder rather than the reason. PART 35 has pinned the
  EXIT CODE for this cause in four engines for a release; nothing pinned the CHANNEL until PART 36 (b8).
- **The `gate` verb registers its stream sink before anything can exit, and writes it once.**
  `refuseGateAndExit` already knew how to write `-` to stdout; the gate verbs pre-pass never put it in
  the sink list, so an exit-2 during argument parsing left stdout empty. Registering it then exposed the
  mirror — the flag loop registered the same sink again, and one exit-2 wrote the refusal document
  TWICE. Deduped at the write, which covers every appender rather than the two that exist today.
- **⚠ MODULE IDENTITY IS NOW PER FILE, AND HONOURS THE DEPENDENCY GRAPH.** The rung the entry below
  promised, built and reviewed three times. It replaces the withdrawal: the improvement that entry gave
  up is here, on evidence rather than on filesystem shape.

  **The question the disclosure channels ask is per FILE**: *can THIS file's package — or THIS file's
  Xcode target — import THAT module?* It was being answered per SCAN: a name claimed anywhere silenced
  it everywhere. That mismatch is what nine earlier review rounds kept rediscovering, and no bound on
  the derivation fixes it, because the derivation was answering the wrong question.

  A file's owning package can import its own targets plus, through each `.package(path:)` it declares,
  the PRODUCTS those local packages expose — the product is the unit of exposure, the target is the unit
  of import, and they are not interchangeable. An `.xcodeproj` target has no `Package.swift`, so its
  answer comes from the closure the `--target` resolver already walked: the products it links, plus the
  graph behind those specific products, since Xcode puts the whole reachable graph on a target's import
  path. Anything unreadable at any step — a computed `path:`, a non-literal `targets:`, no owning
  package at all — yields no claim, so the module stays named.

  **Measured**, 20 `--target` scans across NetNewsWire, IceCubesApp and firefox-ios. THIS entry's change
  leaves NetNewsWire and firefox untouched. Their gains come from two OTHER entries below — an Xcode
  target being a module, and the path-normalization fix — so on the released build firefox's `Client`
  reads 17608 analyzed functions and 51 uncovered modules, against 17562 and 55 at the start of this
  release's work. NOT "against 0.26": the released 0.26 engine has no `--target` flag at all and cannot
  produce those numbers. Every before/after figure in this section is measured against `430c5ef`, the
  commit this thread started from, which is already past 0.26. What THIS one moves is IceCubesApp's app target: 48 uncovered modules to 38, and **all
  ten names removed have analyzed functions in the same report** (StatusKit 284, Account 109,
  DesignSystem 46, …). The 279 entries that leave `functions` with
  them carried no inferred effect between them — each held only an `invisible` hedge for a module this
  run had read.

  **The invariant that makes this safe to state**: every name that can be claimed internal has passed
  `analyzedTargets`, so a module is called internal only if a file under that target's real source root
  was read in this run. Absence is still never a claim of purity for anything unread.

- **⚠ A `--target` SCAN COULD SILENTLY DROP FILES THE PROJECT LISTS, depending on how you spelled the
  scan root.** Two halves of one defect, both live in 0.26, found by review of the work above.

  `URL(fileURLWithPath:).path` absolutizes a relative path correctly but leaves `..` in an absolute one;
  `.standardized.path` collapses those but, on a relative path, drops the base and can produce a path at
  the filesystem root. Both spellings were in use. Under the first, a pbxproj group whose path escapes
  the project directory produced keys the membership filter could never match, so every file behind it
  fell out of the scan with **no `unanalyzed` entry and no warning** — a purity claim over files the
  project explicitly lists, flipping on whether you wrote `.` or an absolute path. This is firefox-ios's
  real shape: its packages sit at `firefox-ios/../BrowserKit`, and with the fix its `Client` scan recovers
  **one source file** (1191 → 1192 of 1197) carrying **46 analyzed functions** (17562 → 17608). An earlier
  draft of this entry called that "46 files": `analyzed.count` is the analyzed-FUNCTION set, as its own
  definition says, and one file is what the header reports. Under the second, a `../repo`-style scan root disabled per-file identity
  outright. One normalizer now serves every site.

- **`scripts/scope-monotonicity.sh` — a self-differential property, one engine against itself.** For a
  leaf function in a file a `Package.swift` owns, present in both runs, a `--target` scan's `invisible`
  set must be a SUPERSET of the unscoped scan's: scoping may disclose more, never less. No expected-value
  table and nothing to keep in sync with the engine — the two runs are each other's oracle. Run it
  against any repo; it prints its live-cell count and calls a zero-cell run vacuous rather than passing.

  The naive form of that property — "a scoped scan is never more silent" — is FALSE and is documented
  in the script as such, because scoping ADDS evidence (an app-level file has no owning manifest, so the
  unscoped run claims nothing about it while the scoped run knows its target's links). It reported 991
  violations on NetNewsWire before the two restrictions that make it sound.

  Current: swift-composable-architecture 2850 cells / 0, NetNewsWire 976 / 0, IceCubesApp 684 / 0.

- **CHAINED COVERAGE THAT NOBODY DECLARED IS NOW DISCLOSED.** SPEC §2 rule 3 makes a chained report's
  coverage name-keyed and scan-global — every package a loaded report covers is accounted for, full
  stop — and this engine obeys it. It is also the one place where a NAME alone can delete a disclosure,
  and when the name is wrong the failure is silent: a package declaring no dependencies at all, whose
  `import Utils` call reaches an unresolved SDK, goes to `functions: []` the moment an unrelated package
  called `Utils` is chained.

  Where a covered package is imported by a file whose own target never names it, the scan now says so
  and changes no answer. Measured on real repos with every package chained: silent on NetNewsWire (17
  packages, 0 mismatches), and on IceCubesApp it names three — `AppAccount`, `Env`, `MediaUI` — each a
  file importing a module its manifest does not declare.

  Gating the CLAIM on this was implemented and reverted: it contradicts rule 3, 31 chaining tests pin
  that contract, and the measurement says it would have cost reach on all three IceCubes cases (shipping
  code that builds) while gaining nothing on NetNewsWire. A note needs no floor bump and cannot cost
  reach.

- **⚠ A WHOLE-REPO SCAN OF AN `.xcodeproj` TREE NOW ANSWERS MODULE IDENTITY TOO.** Without `--target`
  an app-level file had no owning `Package.swift` and no resolved scope, so it claimed nothing and every
  module it imports was named a blind spot — including local packages the run had just analyzed.
  NetNewsWire listed 32 uncovered modules, **14 of them local packages whose sources are in the same
  report**; it now lists 17, and each of the 15 removed is confirmed by functions from that module's own
  sources appearing in the report.

  It resolves every target and merges the evidence PER FILE. Not a union over the repo's targets: in one
  unscoped run of one tree, a file in a target that links the package claims its module while a file in a
  sibling target that does not link it still discloses the same name. A union would be one line and
  would silence the second file — the shortcut this ships a fixture against, because the ledger count
  separates all three possible behaviours (2 = claims nothing, 0 = claimed repo-wide, 1 = correct).

  A target that cannot be resolved is skipped rather than fatal, and the count is disclosed: whole-repo
  makes no scoping promise, so its files simply keep disclosing. Cost is one resolution per target,
  measured at 2.4s for NetNewsWire and 5.6s for firefox-ios whole-repo.

- **⚠ AN XCODE TARGET IS A MODULE, and the scan used to name its own framework targets blind spots.**
  `--target Client` on firefox-ios scans eleven Xcode targets, and then reported four of them —
  `Storage` (112 imports), `Account` (20), `Localizations` (4), `Sync` (2) — as "INVISIBLE to the scan",
  while 332 of `Storage`'s functions sat in that same report. A false disclosure, and the largest one
  left: the line teaches a reader to skim a list whose other entries are real.

  A file may now import the Xcode targets in ITS OWN target's dependency closure — per member, because
  dependency is directional, and only members that actually contributed files, so a name is still
  claimed only when the run read its sources. Module names come from `PRODUCT_MODULE_NAME`, else
  `PRODUCT_NAME`, else the target name, sanitized the way Xcode sanitizes them; a value still holding an
  unexpanded `$(…)` is discarded rather than guessed at.

  A pbxproj states "A uses B" in TWO independent places — a `PBXTargetDependency` (build order) and a
  build file in A's Frameworks phase pointing at B's `productReference` (the link) — and real projects
  use one without the other. Reading only the first left 5 functions still hedging `Storage`, because
  firefox's `WidgetKitExtension` links `Storage.framework` and declares no dependency on it. Both are
  read now. Seven firefox target scans lose blind spots; no effect set anywhere shrinks.

- **⚠ A SIBLING TARGET COULD SILENCE A REAL SDK.** The SwiftPM half of the rung above, and the same
  defect in the arm nobody looked at. Module identity was decided per PACKAGE — a file could claim every
  target its package declares — when SwiftPM lets a target import only what its own `dependencies:` name.

  One package, `App` declaring no dependencies beside a `.target` used by something else, and the only
  difference between the two runs is that target's name:

  ```
  .target(name: "Stripe")     import Stripe → functions: []        ← `ship` absent = purity claim
  .target(name: "Payments")   import Stripe → ship, invisible: ["Stripe"]
  ```

  `App/main.swift` calls `StripeClient().charge(amount: 100)`, and in the first tree that call reads
  pure. Identity is now the file's TARGET: its dependency closure, plus the products those targets name,
  intersected with what the run analyzed. Transitive, because SwiftPM puts a transitive dependency's
  module on the import path; and anything unreadable at any step yields nothing, so the file claims
  nothing and every module it imports stays named.

  All 20 corpus target scans are unchanged by this, which is what you would expect: real manifests
  declare their dependencies, so nothing that could legitimately be imported was lost.

- **FOUR DEFECTS THAT WERE ALREADY SHIPPING, found by reviewing the work above rather than by using it.**
  Two of them silent, two of them dead ends.

  - **A commented-out `.package(path: "../Old")` was discovered and CHAINED** by `--workspace`. The
    reader was a line regex requiring `.package(` and `path:` on one line, with no comment handling, so
    a package the root does not depend on was scanned and its report written to `.candor/deps` — where
    SPEC §2 rule 3 turns that package's silence into a purity claim. It now goes through the same
    SwiftSyntax parser as everything else, which was written for this and had been wired into one caller
    while its own comment described the regex in the past tense.
  - **`SDKROOT[sdk=iphoneos*]` was invisible to platform inference.** Two readers of the xcconfig format
    existed side by side and only one stripped conditional key suffixes. Fewer platform tokens makes a
    single-family answer more likely, and a wrong single family prunes files that do compile — from a
    one-line divergence between two copies.
  - **A dead hoisted `let legacyProducts = [.library(name: "Kit", …)]` refused the scan** (exit 2,
    "declared by 2 local packages" naming the same directory twice — the message refuting itself), on a
    manifest SwiftPM accepts, because an unused `let` is never validated.
  - **Two Xcode targets of one name killed the process** with a Swift runtime trap and exit 133. Now a
    contractual exit 2 that says what is ambiguous, because every name-keyed answer about that project
    would have been answering an ambiguous key.

- **⚠ THE LEDGER-NOISE IMPROVEMENT WAS WITHDRAWN — and is restored above. What ships is ten closed cardinal sins in code that
  had already shipped.** This entry replaces the running account of that work, because the running
  account described a feature that is no longer here.

  It began as a cosmetic fix: a NetNewsWire scan's κ ledger named local packages the scan had just
  analyzed — a false disclosure, prescribing work that was already done. Removing those required
  deciding, from the filesystem, which modules had been analyzed. **Nine review rounds found ten distinct silent under-reports in that decision**, six of them
  introduced by the fix for the previous one, and the tenth — a nested package's target silencing the
  root package's import of a real remote SDK — reads names the shipped 0.26 engine could not see at all.

  So the derivation is now bounded to the ROOT manifest: a module is internal when an analyzed file lives
  under a target declared in `rootDir/Package.swift`. The noise this set out to remove is still there:
  measured on NetNewsWire at its 2026-08-08 HEAD, a whole-repo scan names **35** uncovered modules and
  several are `Modules/` packages analyzed in the same run.

  (An earlier draft of this entry put that figure at 31 and said the improvement took it to 14. Neither
  number reproduces against today's checkout, and the two were not even the same invocation — 14 is what
  a `--target NetNewsWire-iOS` scan reports, on this build, WITH the derivation bounded as described. A
  measurement is only a claim if it says which command produced it.)

  **What survives is worth more than what was withdrawn.** Every name now claimed is a literal declaration
  in the root manifest, while the shipped 0.26 derivation claimed the package NAME, every `Sources/` and
  `Source/` directory entry with no manifest check whatsoever, and every regex hit anywhere in the file —
  comments, dead code, ternary branches, hoisted dependency arrays. Claims are a strict subset of 0.26's
  by construction, so every one of these is closed rather than argued:
  - the package name itself, when a package is named after the dependency it wraps (**live on
    firefox-ios**: `Dangerfile.swift`'s 41 functions hedged the sibling import and not `Danger`);
  - any directory under `Sources/` (an integration folder named after the SDK it wraps);
  - a commented-out `.target(…)`; a dead hoisted `.target(name:)` reference; a ternary's dead branch;
  - a `.testTarget`/`.plugin`/`path:`-relocated declaration read as a source root;
  - the first `name:` in a declaration's span, which for a computed target name is a DEPENDENCY's
    `.product(name:)` — by construction a real third-party module;
  - a nested package's same-named target claiming the root's import.
  Plus a crash (an unclosed `.target(` trapped the process) and, in the other direction, candor-swift
  reporting its own `CandorCore` as a blind spot when scanned relatively.

  The dependency-aware version — a nested target is internal only to consumers that can actually import
  it, which needs per-FILE rather than per-scan identity — is the first entry above. It is a rung, not a
  patch, and this entry is the argument for that. It was built after this one was written and before
  either shipped, so both are in this release: the account of the withdrawal is kept because the ten
  fixes are what made the rung possible to attempt again.

- **⚠ A TENTH SPELLING — a ternary's DEAD BRANCH read as a declaration — plus the mirror it exposed.**
  `useMock ? .target(name: "Stripe") : .executableTarget(name: "App")` had BOTH branches read as
  declarations, because each array element was sub-walked for `.target(…)` anywhere inside it. The dead
  branch claimed module Stripe, a stale `Sources/Stripe/` gave it a root, and a call into the real SDK
  read pure. Present in the shipped 0.26 engine too, on the same input, by a broader route.

  Every element must now BE a plain declaration call; anything else means the list **cannot be read**,
  which is what `packageManifestListsAreComplete` already said about the same array sixty lines away —
  the two agree now, and unreadable claims nothing.

  The mirror, found in the same round and introduced by the previous one: `PackageDescription.Package(…)`
  and `Target.target(…)` are ordinary spellings that were being rejected, so a package's OWN analyzed
  modules were named third-party blind spots. Both accepted; any other base is still refused, because
  `Foo.target(…)` is not a target declaration.

- **⚠ A NINTH SPELLING: a DEAD reference read as a declaration.** SwiftPM never validates an unused
  `let`, so a leftover `let legacyDeps: [Target.Dependency] = [.target(name: "Analytics")]` sits happily
  in a manifest that builds. Read as a declaration, and given a source root by a stale
  `Sources/Analytics/`, it claimed module Analytics — and a function calling into the real remote SDK
  vanished from `functions` with no ledger entry and no `invisible` hedge. **One dead line in a manifest,
  both disclosure channels off**, with the A/B differing by that line alone.

  The repair separates two questions that had been sharing one answer. `parsePackageTargets` collects
  `.target(…)` calls ANYWHERE, which is right for resolving a scan SCOPE — a stray one either names a
  real target (dedups harmlessly) or resolves to no sources. It is wrong for module IDENTITY, where a
  name alone is the whole answer. Identity now asks `parsePackageTargetDeclarations`, which returns only
  the elements of `Package(targets: [...])`, and returns **nil** rather than an empty list when that
  argument is hoisted or computed — "cannot be read" is not "declares nothing", and a caller that
  conflated them would claim nothing while believing it had claimed everything.

  Worth recording because it changes what the fallback plan was worth: this sin also exists in the
  SHIPPED 0.26 engine, and disabling directory inference would NOT have closed it — the phantom claim is
  name-derived, and 0.26's regex matches the dead reference just as readily.

- **⚠ AN EIGHTH SPELLING, and this one I reintroduced three hours after fixing it.** A path-less
  `.plugin(name: "Stripe")` beside a stale `Sources/Stripe/` claimed module Stripe and silenced a real
  SDK on both disclosure channels. `targetSourceDirs` was written to resolve a scan SCOPE, where a
  `.plugin` target is unreachable — plugins never appear in `dependencies:` — so it maps every non-test
  target to `Sources/<name>`. The hand-rolled parser that the consolidation deleted DID know about
  `Plugins/`; that line was round 3's own fix. Deleting the duplicate was right, and it took the one
  piece of knowledge the copy had that the original lacked.

  Fixed on the SEMANTICS rather than the layout: app code cannot `import` a plugin, and this engine's
  discovery excludes `Plugins/` outright, so a plugin declaration can never legitimately account for an
  analyzed file. `PackageTarget` now carries `isPlugin` and module identity skips those targets. Teaching
  a second place about directory conventions is what put the knowledge in two places to begin with.
- **`Source/` (singular) was a blind spot that isn't one.** One of SwiftPM's predefined source
  directories, unknown to the shared resolver, so an ANALYZED local module was named third-party — a
  false disclosure, the noise this whole thread began by trying to remove. Added as a candidate, which
  also means `--target` can now resolve packages using that layout instead of refusing them. The
  refusal's "tried" list grew by one entry and its test was updated to match, because a message that
  does not name everything it tried is the next defect.

- **⚠ A SEVENTH SPELLING, and it was the SEED: `internalModules` started life holding the package
  NAME.** A package name is not a module — and it is not even a declaration, since it comes from a
  first-`name:` regex over the manifest, falling back to the directory basename. When a package is named
  after the dependency it WRAPS, that seed marked a remote, never-analyzed module internal and silenced
  both disclosure channels.

  **Live on firefox-ios at HEAD**, which is how it was found rather than reasoned: its `Package.swift`
  declares `name: "Danger"` and wraps `.product(name: "Danger", package: "swift")`. Across
  `Dangerfile.swift`'s 41 report functions, every one hedged `DangerSwiftCoverage` — the sibling import
  in the SAME file — and none hedged `Danger`, its dominant one, which was absent from the 53-entry
  ledger entirely. Everything reached through the real Danger SDK read pure with nothing disclosed. The
  seed predates this session; the within-file control is what makes it unarguable. Gone: if a manifest
  genuinely declares a target of that name, the ordinary rule claims it on a declaration and a source
  root rather than on what the package happens to be called.
- **…and a hoisted dependency array was read as a second declaration.** `parsePackageTargets` collects
  `.target(…)` calls anywhere in the file — right for resolving a scan SCOPE, where a stray one dedups
  harmlessly, and wrong for deciding module IDENTITY. `let coreDeps: [Target.Dependency] = [.target(name:
  "Core")]` (an idiom the parser's own comment calls ordinary) widened Core's claimed roots to the
  conventional `Sources/Core`, so a stale directory of that name could claim a module whose real sources
  (`path: "Modules/Core"`) were never scanned. A real manifest declares each target once, so a
  `path:`-carrying declaration now settles that name and the convention-derived phantoms are dropped.
  Reusing a tested function for a purpose it was not written for is its own risk; this is what it cost.

- **⚠ SIX SILENT UNDER-REPORTS FROM ONE DERIVATION, and the cause was that there were TWO manifest
  parsers in this codebase.** `internalModules` decides whether a module was analyzed; it gates the κ
  coverage ledger AND the per-function `invisible` hedge, and `invisible` is the only thing between an
  unresolved call into a blind module and a ⟨0.21⟩ purity claim. Across four review rounds it produced a
  cardinal sin in six spellings, each found in the fix for the last: every entry of `<root>/Sources/`
  taken on trust; any `Sources/<X>/` anywhere; a `.testTarget`/`.plugin`/`path:`-relocated declaration
  read as a source root; a commented-out `.target(…)` read as live; the first `name:` in a declaration's
  span, which for a computed target name is a DEPENDENCY's `.product(name:)` — by construction a real
  third-party module; and, in the other direction, relative paths making the walk stop before the
  manifest, so candor-swift called its own `CandorCore` a blind spot.

  Every one of those was a rediscovery of something `parsePackageTargets` — the SwiftSyntax manifest
  parser already in CandorCore, already covered by tests because `--target` depends on it — handles
  correctly. The hand-rolled scan sitting a few files away from it was the defect; the six spellings were
  symptoms. It is deleted. Targets now come from that parser and their directories from
  `targetSourceDirs`, which also knows SwiftPM's bare `<name>/` fallback the copy had never heard of.
  `Self.literal` returns nil for anything that is not a plain string literal, so a computed name yields
  no target rather than a wrong one — safe by construction rather than by my remembering to check.

  All six fixtures disclose, the controls stay clean, candor-swift scanned relatively does not flag its
  own `CandorCore`, NetNewsWire iOS's uncovered set is byte-identical at 14 (from 31 before this work),
  and WordPress-iOS's 2570 files still scan in 46s.
- **⚠ THE SAME CARDINAL SIN IN TWO MORE SPELLINGS — one of them inside the fix for the last one.**
  A third review round measured both on the built binary:
  - **(a)** the pre-existing root rule inserted EVERY entry of `<root>/Sources/` into `internalModules`
    with no manifest check, so a manifest-less `.xcodeproj`-shaped tree with `Sources/Stripe/Shim.swift`
    reported **zero effectful functions** — `chargeCard` absent under ⟨0.21⟩, no ledger, no `invisible`.
    Shipped since ≤0.10; not a regression, but live, and the previous round's comment had waved at it as
    "the same exposure the root rule already accepts" — documented rather than measured.
  - **(b)** the NEW guard accepted a `.testTarget`/`.plugin`/`path:`-relocated declaration as proof that
    `Sources/<X>` is that target's source root, when its sources live in `Tests/<X>`, `Plugins/<X>`, or
    wherever `path:` says. A `.testTarget(name: "Stripe")` beside `Sources/Stripe/` silenced everything.

  **The rule that closes both, and the one the previous repair claimed while not implementing:** a module
  is internal when an analyzed file lives under a DECLARED TARGET'S ACTUAL SOURCE ROOT — `path:` when
  given, else SPM's per-kind default. Not a directory that looks like one. **In an Xcode tree a folder is
  not a module** (an app target compiles everything into one), so `Sources/<X>` ⇒ module X is honoured
  only where an SPM manifest says so — which makes the strict rule correct in both directions rather than
  merely safe in one.

  Caught in the other direction while checking it: scanned RELATIVELY, the walk up from `./Sources/X`
  stopped at `.` before reaching the manifest, so candor-swift reported its own `CandorCore` as an
  uncovered third-party module. Paths are standardized first. Found by scanning this engine with itself;
  NetNewsWire's uncovered set is byte-identical across the change.

- **⚠ The κ coverage ledger named modules the scan had just ANALYZED — and the first fix for it was a
  CARDINAL SIN.** On a `--target`-scoped NetNewsWire scan the ledger listed 31 uncovered modules
  including `RSCore` (20 analyzed files in that very report), `Account` (53) and `NewsBlur` (7), saying
  their effects were "INVISIBLE to the scan" and advising work that was already done. A false disclosure
  spends the reader's trust in the ledger that carries the REAL blind spots.

  The first repair took any analyzed path segment `Sources/<X>/` as proof module X had been read. **It
  proves a DIRECTORY named X was read.** `internalModules` gates BOTH disclosure channels — the ledger
  and the per-function `invisible` set, which is the only thing between an unresolved call into a blind
  module and a purity claim — so the fixture is one directory name: `App/Sources/Stripe/Shim.swift`
  importing `Stripe` and calling `StripeClient()` reported **zero effectful functions, no ledger, no
  `invisible`**, while `App/Sources/StripeIntegration/` disclosed both. Naming an integration folder
  after the SDK it wraps is ordinary in the `.xcodeproj` trees `--target` serves. Caught by a go/no-go
  re-review, reproduced on the shipped binary before believing it.

  The sound rule: a `Sources/<X>/` counts only when it IS an SPM target root — an ancestor
  `Package.swift` directly above that `Sources/` declaring a target named X. NetNewsWire's
  `Modules/Account/Package.swift` declares `Account`, so the win is unchanged at 31 → 14; the Stripe
  fixture's root manifest declares `App`, so nothing is silenced. It also drops the flat-layout artefact
  where `Sources/main.swift` inserted a FILENAME as a module.
- **A labelled `for:` now wins over an unlabelled positional in the capture media type.** Reading the
  first argument that could be a media type found `.builtInWideAngleCamera` in
  `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)` — the commonest setup
  call in AVFoundation — judged the medium undetermined, and charged Mic to a camera-only function. The
  exact complaint the deferral was built to kill, returning through a different overload. The unlabelled
  arm still matters (`devices(.audio)`) and stays, as the fallback it should always have been.
- **⚠ CARDINAL SIN, found by a go/no-go review of THIS release's own fabrication fix: a computed media
  type was settled by an unrelated sibling call.** A function opening `AVCaptureDevice.default(for:
  .video)` and, two lines later, `AVCaptureDevice.default(for: kind)` reported `[Camera]` — the possible
  Mic reach absent from `functions`, no `Unknown`, nothing in the coverage ledger, and
  `privacy-manifest --verify` telling the developer to declare only the camera key for a function that
  opens a microphone at runtime. Confirmed by running the shipped binary before fixing.

  One flag was doing two jobs. Deferring the ambiguous case to whole-body resolution is right for a call
  with NO media argument (a bare `AVCaptureSession()` — the medium comes from the devices added beside
  it, so a sibling `.video` genuinely does settle it) and wrong for a call whose media argument IS
  present and computed: that is an independent capture source nothing else in the function speaks for.
  `mediaTypeArgKind` is now three-valued — determined / undetermined / absent — and only `absent` defers.
  The fabrication this deferral was introduced to kill (Bitwarden's camera-only QR scanner charged Mic)
  stays killed, pinned as the floor beside the new test. **This is the measured shape this project keeps
  hitting: the silent under-report introduced BY the over-report fix, invisible to the fixture that
  proved the over-report closed.**
- **⚠ …and a second silent under-report in the platform prune: `os(OSX)` is LIVE Swift.** It is the
  legacy spelling of `os(macOS)` and Swift 6.3 still compiles its body on macOS — verified with
  `swiftc`, not assumed. Comparing the condition token to the platform name alone judged such a file to
  compile to nothing on a macOS target, dropped it from the scope, and left its functions absent from
  `functions` — a ⟨0.21⟩ purity claim over live code, with the stderr count asserting a justification
  false for that file. Legacy Mac codebases are where the spelling survives, and where the Apple-events
  reach lives. One-line alias, with a control proving the condition is still correctly inactive on iOS.
- **`SPEC-EXTENSION-privacy.md` contradicted itself and the code in four places**, all found by the same
  review: "two keys stay unmodelled" (it is one — `NSCriticalMessagingUsageDescription` is modelled on
  the entitlement basis, and the count that drifted sits directly under the paragraph explaining that
  the printed figure is the authority BECAUSE hand-maintained counts drift); "`LocalNetwork` is
  deliberately absent" (it is modelled now, on the constant basis — decided by the host literal, not the
  type, which is what made it earnable rather than a guess); "per-target scoping is a future refinement"
  (it shipped); and a `privacy/3` wire id in prose while every report emits `privacy/2` — the `### N-th
  wave` headings are drafting labels, and the doc now says so rather than inviting the misreading again.

- **⚠ The scan's SCOPE now travels with the report (`scope`, SPEC-EXTENSION-privacy.md).** `--target`
  scopes the SCAN; the `privacy-manifest --verify` that follows reads a REPORT and a plist, so
  everything the scan learned about which binary this is had to be in the artifact or it was lost — and
  it was lost. The verify re-discovered `.entitlements` by walking the plist's directory, found several
  on exactly the multi-target repos `--target` exists for, refused to guess, and left the
  entitlement-sourced keys unchecked. Measured on NetNewsWire: eight `.entitlements` in the tree, one
  key never checked, on both the iOS and the Mac answer.

  Narrowing that SEARCH would still be a search. `CODE_SIGN_ENTITLEMENTS` NAMES the file, per target,
  which is the answer the question was always asking for. The `.xcodeproj` resolver reads it from the
  target's build settings — its own `XCBuildConfiguration` dictionaries and its `baseConfigurationReference`
  xcconfig chain, `#include`s followed, the Xcode 16 synchronized-folder spelling included — and the
  report carries `scope: {target, project, entitlements}`. The verify prefers it and states the
  provenance on a pass as well as a finding, because an entitlements check that silently read the wrong
  target's file is the failure this removes.

  **An undefined build variable expands to the empty string**, which is Xcode's rule and the thing that
  makes this exact rather than a guess: NetNewsWire writes
  `iOS/Resources/NetNewsWire$(DEVELOPER_ENTITLEMENTS).entitlements`, and `DEVELOPER_ENTITLEMENTS` lives
  only in a personal file outside the checkout, so a clone resolves the release entitlements — which is
  what that checkout builds. The iOS and Mac targets resolve files with the SAME basename in different
  directories; discovery could never have told them apart. One shared settings walker now serves this
  and the platform prune, so there is no second copy of the xcconfig-chain reader.

  Fail-safe throughout: `entitlements` is emitted only when the resolved path names a file that EXISTS,
  a recorded path that has since gone falls back to discovery rather than checking nothing, and the key
  is omitted entirely when no scope was applied — so an unscoped report is byte-unchanged.

- **A `--target` refusal on a GENERATED-project repo was a dead end.** bitwarden/ios builds its Xcode
  project with XcodeGen, so a fresh clone has no `.xcodeproj` at all and the refusal said only "needs a
  Package.swift or an .xcodeproj … neither found" — accurate, and useless to a user whose repo is
  perfectly ordinary. The spec file is sitting in the same directory; the refusal now names it and the
  command that turns it into a project, then says to re-run the same `--target`. It names EVERY spec
  rather than picking one — bitwarden has five and the alphabetically-first builds the Authenticator,
  not the app, so suggesting one command is the same guess this resolver refuses to make everywhere
  else. `project.yml`/`Project.swift`/`Tuist.swift` are recognised too. Pinned with its control: a repo
  with Swift sources and no generator still gets the plain message and no advice it cannot act on.

- **⚠ `--target` on an `.xcodeproj` resolved the local-package closure ONE HOP SHORT — found by running
  it on NetNewsWire.** `Modules/` holds **17** local packages; the scope resolved **14**. The three
  missing were exactly those no app TARGET names directly — `CloudKitSync`, `FeedFinder`, `NewsBlur` —
  reachable only through `Account`. `NewsBlurAPICaller` is the app's sync layer, so the scoped scan
  analyzed the app minus its network client.

  The cause was one spelling. The walk followed `.product(name:package:)` edges, which is what its own
  comment claimed, and Account writes every dependency as a **bare string** (`.package(path:
  "../NewsBlur")` beside a plain `"NewsBlur"` in the target) — SwiftPM resolves a bare name against a
  dependency package's products, and `targetClosure` drops a name its own package does not declare.
  That drop is right on the SPM `--target` path, where "not declared here" does mean "no sources in this
  tree", and wrong on the `.xcodeproj` path, where the sibling package is three directories away. Bare
  names that match no in-package target now go through the same local-product index the `.product(…)`
  edges use.

  **Not a purity claim** — the import ledger still disclosed all three as uncovered modules, so nothing
  read as pure. The scope was simply smaller than the product. And the fix is disclosure-positive in the
  other direction too: a bare name matching no local product now reaches the REMOTE counter instead of
  being dropped at closure level, where it reached no counter at all. Measured after: NetNewsWire iOS
  422 → 441 files (17 packages, 2 remote), Mac 449 → 468; the only file now in neither app's scope is
  `buildscripts/VerifyNoBS.swift`, which is a build script. The A/B that motivated `--target` is
  unchanged — whole-repo verify against the iOS plist still reports the false AppleEvents
  under-declaration, the scoped one still passes. Both new tests were run against the pre-fix code and
  fail there.

- **⚠ Flip #18: the `#include` chain was followed ONE LEVEL.** A three-deep split config —
  `App.xcconfig` → `Configs/mid.xcconfig` (declares) → `deep.xcconfig` (undeclares) — resolves EMPTY at
  build time, because a later include wins. Reading one level saw the declaration and never the
  undeclare, so the key counted as declared and the verify passed. The consistency rule would have
  caught it had the file been read at all; the defect was purely the depth bound, and three-deep
  xcconfig chains are an ordinary layout. Now followed to the end, cycle-safe and depth-capped, with the
  containment check on every hop.
- **⚠ Sensor use reachable only from Objective-C was invisible with NO caveat.** A target with one
  trivial `.swift` file beside a `.m` calling `AVCaptureDevice` verified `✓ (0 effects)`, exit 0, against
  an empty plist — and nothing said that non-Swift sources had not been read. The uncovered-MODULE
  ledger could not fire, because nothing Swift imported anything uncovered: the code simply was not
  Swift. Mixed-language apps are most mature iOS apps. Now counted and disclosed as a conditionality,
  bounded by the same project-root walk the build-settings reader uses. Measured: 0 on IceCubesApp and
  duckduckgo (pure Swift), 129 on WordPress-iOS.
- **…and THREE walks anchored on the plist searched trees that are not the app's — one of them at 72
  seconds a call.** Each looked for a project root above the plist and then read whatever it was pointed
  at, so a plist handed to `--verify` from a directory that is not a checkout — a temp directory,
  `/tmp`, an extracted archive — searched somebody else's: the non-Swift source count at **21 minutes
  for one `swift test` case**, the `.entitlements` discovery at **233 seconds**, and the build-settings
  reader's ancestor walk at **72 seconds per verify**. Together that is most of why this suite ran for
  an hour instead of ten minutes.
  - **The rule, applied three times: no checkout ⇒ the ancestors are not this app's directories.** One
    shared `projectRootAbove` now gates all three. The count is not taken and says so
    (`nonSwiftSourcesCounted: false` on the JSON channel, its own ⚠ on the console, printed even when
    nothing else is conditional — a clean verify with no caveat is exactly the case it exists for);
    "beside" reverts to literally beside for the entitlements file; and the build-settings walk reads
    the plist's own directory only. Falling back to the plist's directory fixes nothing on its own,
    because that directory IS `$TMPDIR` in the case that produced the 21 minutes, and a depth cap would
    trade the cost for an under-count — the wrong currency, since the count is a DISCLOSURE and a quiet
    `0` is a "nothing unread here" the run has no grounds for. Direction check on the build-settings
    half: what is lost is an `.xcconfig` above a plist in a tree with NONE of the five markers, which
    then reads as undeclared — an over-report, not a silent under-report. Where a root IS found nothing
    changes, verified end to end.
  - **`contentsOfDirectory(at:)` vs `(atPath:)` was worth 70 of those 72 seconds.** The URL variant
    builds a `URL` and stats every entry; sampling one `--verify` put every second inside
    `_FSURLCreateWithPathAndExtendedAttributes`. The marker test only needs names. (The directory it was
    listing had 185,000 entries — 130,000 of them candor's own leaked test fixtures, which is a
    separate housekeeping item now recorded.)
- **⚠ The over-report round, continued — the two remaining rows that asserted keys Apple does not
  require.** Both settled by fetching Apple's own pages, both verified on the corpus:
  - **`NSAppleEventDescriptor` charged the SEND-only key to RECEIVE-side code.** Apple's key page:
    *"This key is required if your app uses APIs that send Apple events"* — and the descriptor is the
    wrapper BOTH sides touch. Measured on NetNewsWire: the evidence candor printed for
    `NSAppleEventsUsageDescription` was `AppDelegate.getURL`, the kAEGetURL receive handler every Mac
    app with a custom URL scheme installs. The type is out of the flat table; the effect now rides the
    one member that transmits (`sendEvent(options:timeout:)` — member-gated like `GKLocalPlayer`), the
    C send route (`AESendMessage`, a new kappaFree row), and the send-by-design types (`NSAppleScript`
    kept — a script body is invisible to static analysis — plus `SBApplication`, whose class page says
    "send Apple events" in terms, previously unmodelled). NetNewsWire's genuine send
    (`SendToBlogEditorApp.send`) still charges; its receive-only half no longer does.
  - **EventKit UI's key requirement changed with the OS, and candor asserted the old half
    unconditionally.** Apple, "Accessing the event store": *"EventKitUI presents chooser and editor UI
    outside of your app's process on iOS 17 and later. Your app can use EventKitUI without requesting
    write-only or full calendar access."* Below iOS 17 the key IS required, and candor cannot see a
    deployment target — so `EKEventEditViewController`/`EKCalendarChooser` are now a SPLIT effect,
    `CalendarUI` (parent `Calendar`, same acceptable keys, `EFFECT_SPLIT_PARENT` disclosure), and the
    verify raises an undeclared key as a NAMED CONDITION: a ⚠ carrying "required only when the
    deployment target is below iOS 17…", exit code unchanged, `conditionallyUnderDeclared` on the JSON
    channel, and a verdict line that says "no MODELLED capability is provably missing" rather than
    over-claiming. Not keyless (the ContactsPicker shape needs an UNCONDITIONAL Apple statement; this
    one is version-fenced, and keyless would silently under-report every pre-17 app), not a hard ✗ (a
    false misconfiguration claim against every 17+-only app). The reader holds the one fact that
    settles it, so the verify hands them exactly that question.

- **`--target` now resolves `.xcodeproj` targets — the audience privacy-manifest is promoted to.**
  It resolved only against a `Package.swift` and exited 2 on every Xcode-project repo, so those scans
  stayed whole-repo and charged each shipped product with every other one's sensors: NetNewsWire's iOS
  plist was charged `NSAppleEventsUsageDescription` from Mac-only code, Focus's plist was charged
  Speech reached from firefox's QuickAnswers code in a sibling project (both measured, both false, both
  gone under scoping — and the IceCubes/DuckDuckGo/WordPress app targets keep their full
  Camera/Photos/Mic/Speech reach under scoping, measured, because the fix that loses real reach is
  worse than the false alarm). The pbxproj is parsed by a hand-written OpenStep reader sharing the
  build-settings evaluator's comment stripper — no `plutil`, so the Linux leg behaves identically.
  Resolution covers the classic Sources-phase/group-tree form and Xcode 16 synchronized folders with
  both halves of their per-target membership exceptions, plus the in-project dependency closure.
  SwiftPM keeps priority whenever the manifest declares the name; the fallback states which resolver
  answered. Every failure REFUSES (exit 2) — unparseable project, unknown name (listing the real
  targets, applications first), dangling reference, missing synchronized folder — because a scope
  silently resolved short is a purity claim over the files it dropped.

  **Which package dependencies resolve, and which are disclosed.** LOCAL Swift packages — drag-in
  `wrapper` file references, `XCLocalSwiftPackageReference`s, and packages sitting in a synchronized
  folder's subdirectories (NetNewsWire's `Modules/`) — resolve INTO the scope: the product's targets,
  their in-package closure, and `.product(…)` edges between local packages, transitively. This was a
  stated boundary first and the measurement killed it: IceCubesApp's app target is a thin shell over
  `Packages/*`, and scoping analyzed `[Notify]` while the app's real Camera/Photos reach sat beside a
  green tick as a conditionality footnote. REMOTE packages (and cross-project target dependencies)
  stay outside — counted in the scope note and κ-disclosed as uncovered, never silently pure. A local
  product that cannot be resolved soundly REFUSES rather than narrowing the scan; a manifest that
  builds its lists in code (WordPress's `XcodeSupport.products`) is read by
  `swift package dump-package` — SwiftPM itself — and that execution is disclosed in the scope note.
  When the target's build settings name its platform (SDKROOT/SUPPORTED_PLATFORMS, xcconfig
  `#include` chains followed), files whose every top-level declaration sits in `#if os(…)` clauses
  provably false for it are excluded — RSCore's Apple-events code is a member of the package but
  compiles to nothing on iOS, and without this the false finding returned through the packages the
  scoping had just resolved. Undecidable conditions (`canImport`, custom flags) always keep the file.

- **⟨0.27⟩ `zeroMatch` on the verdict document (SPEC §4, conformance PART 36).** The zero-match list —
  a rule whose scope bound no function — now rides the `--gate-json` document on BOTH routes (scan and
  `gate --report`), code-point sorted via the UTF-8 view (Swift's default String `<` is canonical order,
  and a Swift String cannot hold a lone surrogate, so the UTF-8 comparison is not lossy), deduplicated,
  omitted when empty; it was stderr-only in all five engines. Never on the refusal document: the stash
  is written by the one `evaluateGate` a run performs, and a refused run never evaluates.

- **⟨0.27⟩ …and the SCAN route's COMPOSED document now carries `unevaluated` too (SPEC §3.1, PART 36
  row (a4), no longer waived).** A certain AS-EFF-005 beside a refused policy exited 1 with the
  violation and NOTHING saying the policy had never run — so a consumer reading `violations` with no
  `unevaluated` beside it takes the document as *the policy ran and this is all it found*. Every rule of
  the refused policy is now listed, raw line verbatim, the unhonourable one(s) with their specific cause
  and the rest with a `why` naming the whole-policy refusal; an unreadable file gets one entry for the
  whole policy, because an exit-1 document with an EMPTY list makes the same false claim in a quieter
  way. This engine's composed document was already right about the other half (no `refused`/`reason`
  beside `violations`), and a sole refusal is unchanged: exit 2, refusal document, its own list.
- **⚠ Flip #17: a Debug-only build setting counted as DECLARED, and the App Store archive is Release.**
  Verified end to end — `✓ every MODELLED capability is declared`, exit 0, on a project whose Release
  configuration ships no camera key. It is one click in Xcode's per-config editor, and it was invisible
  because the statement splitter threw `{`/`}` away, taking the block structure and the `name = Debug;`
  line with it. Configuration blocks are now parsed and attributed by name; a key absent from Release is
  disclosed, not counted. Only fires when the file HAS a Release configuration, so a project using
  custom names is not told its keys are missing.
- **⚠ ARKit and VisionKit were absent from the classifier entirely** — every AR app and document scanner
  verified clean with "0 effects" against an empty plist, and ARKit does not merely get rejected, it
  TRAPS at runtime without `NSCameraUsageDescription`.
- **⚠ A non-string plist value counted as a declaration.** `<key>NSCameraUsageDescription</key><false/>`
  verified green; Apple does not accept it. Only a non-empty string is a usage description.
- **THE OVER-REPORT ROUND — six ways candor told a shipping app it was broken.** All found by running
  the verb on apps it had NOT been developed against, which is the only way an over-report surfaces:
  - the system **contacts and photo pickers** were charged usage keys. Apple, on the contacts picker:
    *"The app using contact picker view does not need access to the user's contacts."* PHPicker is the
    same out-of-process design. Both are now keyless effects — the reach is still reported.
  - **`GKLocalPlayer` authentication** — the first line of every Game Center game — was charged the
    friend-list key. Member-gated to the friends APIs, like `HKObjectType.clinicalType`.
  - **`CLGeocoder`** was charged Location though it converts coordinates the CALLER supplies, and
    **`INVoiceShortcutCenter`** was charged Siri though managing an app's own shortcuts sends Siri no
    user data. Two shipping browsers were told their manifests were wrong on the latter.
  - **a labelled `mediaType:` argument went unread**, so `DiscoverySession(deviceTypes:mediaType:…)`
    fell through to "ambiguous" and fabricated Mic on a camera-only QR scanner.
  - **`AVCaptureSession` is a coordinator, not a capture.** It captures nothing until an input built
    from an `AVCaptureDevice` is added, and that call carries the media type — so the session
    contributed no information the device call does not, while over-disclosing Mic on every function
    that merely touched one, including pure teardown. A member denylist did not hold (`.forEach` on
    `session.outputs` is a member call like any other), which was the signal that the TYPE was the wrong
    place to ask. Capture ambiguity is now resolved per FUNCTION: a determinate device call in the same
    body settles it, and only a genuinely undetermined capture still over-discloses both.
  - **test code sitting beside its sources** was cited as evidence a shipping manifest was wrong. Now
    excluded by `import XCTest`/`import Testing` — deliberately NOT by filename, because `ABTests.swift`
    is production code and dropping it would be the cardinal sin this filter exists to avoid.
- **A same-file build variable read as a missing key.** `INFOPLIST_KEY_… = $(SHARED_TEXT)` with
  `SHARED_TEXT` defined two lines above is a real declaration; it was discarded with NO disclosure at
  all — silence in the false-alarm direction. Same-file variables are now substituted, one level.
- **The over-declaration warning no longer reads as "delete this key."** Several keys are required by
  framework-mediated access with no call site — a web view's geolocation, a share sheet's Save Image —
  and acting on the old phrasing crashes the app at the share sheet.


- **CI-only: the plutil differential ran on Linux and reported 38 false disagreements.** Its skip asked
  whether `/usr/bin/plutil` EXISTS — and the Linux CI image has one (libplist's) that does not accept
  Apple's `-convert json`. So the test ran, every generated case "failed to parse", and the battery
  claimed 38 disagreements that were one missing tool. Asking whether the binary is there is not the same
  question as whether it can answer. The skip is now a platform guard AND a capability probe (convert a
  trivial old-style plist and check the value comes back), as one condition so neither platform compiles
  unreachable code. The `checked` assertion — 0 cells compared, 38 claimed — is what caught it.

- **The sink guard now uses the engine's own discovery and loader** (`discoverConfigFile` +
  `loadCandorConfig`) rather than re-deriving the walk and the parse. The hand-written copy anchored an
  out-of-tree `CANDOR_CONFIG` one level too high and split `deps` on `:` alone; a second parser is a
  second set of holes.
- **⚠ `gate --report` enumerated the config channel from the REPORT's directory** while this verb's
  policy ladder discovers it from the CWD — a different question, so a config-declared policy was
  destroyed at exit 0.

- **A split narrows every policy that named the parent, silently — now disclosed.** `MotionRaw` was
  split out of `Motion` because Apple requires no usage key for the raw CoreMotion stream, which is
  correct and means an existing `deny Motion` — written by an operator who meant "no CoreMotion in this
  layer" — now PASSES a `CMMotionManager` reach while still binding, still evaluating, and still
  reporting nothing. That is a guard the operator believes is on, which is the ⟨0.24⟩ zero-match shape
  one level up, so it gets the same remedy: a stderr note naming the functions that reach the split-off
  effect and the rule to add. Verdict and exit code untouched; silent when both are denied, when neither
  is, or when nothing reaches it.
- **⚠ Flip #15 in the build-settings evaluator: the comment strippers and the statement splitter each
  tracked quotes SEPARATELY**, so any one desynchronising corrupted everything after it. A stray quote in
  a line comment — `// the "shared config` — made the block stripper read the following `/* … */` as
  string content, so a COMMENTED-OUT key was reported as declared: verified end to end through the
  shipped binary as "every MODELLED capability is declared", exit 0, on an app whose plist has none. That
  is the flip the file's own docstring records as already closed, back through a different door. The
  mirror reproduced too (`// see the note /* about camera` lost every declaration after it), as did a
  multi-line quoted value swallowing a later undeclare. Now ONE state machine, which cannot disagree with
  itself, and which handles multi-line string literals for free.
- **⚠ Flip #16: an `#include` line could not open a block comment.** The `#include` branch copied its
  whole line VERBATIM — to preserve the directive — so a `/*` sitting on that line never registered and
  the commented-out key after it was reported as DECLARED. The identical file without the include line
  answered correctly, which is what makes it diagnostic. Only the DIRECTIVE is a directive now: the token
  is emitted and the scan continues in normal mode, so quotes, `//` and `/*` after an include behave as
  they do anywhere else. A bare `hasPrefix` also matched `#includes` and `#include_foo`, which are not
  the directive; xcconfig's optional `#include?` still is. Identical answers on 129 real build-settings
  files, and the plutil differential stays green.
- **⚠ The collision guard keyed on the FLAG**, so a policy declared by `.candor/config` — the checked-in
  form CI uses — was invisible to it: `--gate-json <that policy>` destroyed it and exited 0 with
  `"ok": true`, in all four engines. It now enumerates every channel, including the `gate` verb's
  `--report`, which §3.3.1 names as an input.
- **An unreadable config was silently "no config" on the QUERY route**, dropping whatever it declared —
  a policy, a baseline, an engine pin. The scan route already refused; §3.4's posture does not vary by
  verb.
- **The `deps` splitter became Unicode-aware and refused a working config** — a dep PATH containing a
  non-breaking space was split into two nonexistent ones and the run exited 2, where java and rust loaded
  it. It also disagreed with this engine's own `CANDOR_DEPS` splitter. Paths separate on ASCII whitespace;
  only the key/value split is Unicode-aware.
- **Every keyless effect printed `Notify`'s reason.** `MotionRaw → (no Info.plist key — notifications
  gate at runtime via requestAuthorization)` is a wrong explanation attached to a right answer, which is
  the shape a reader learns to distrust. One reason per effect now.

- **A version is ASCII digits, and `Character.isNumber` is not.** `engine ٣.٣` (Arabic-Indic) and
  `engine ².0` NORMALISED as versions, so they read as a MISMATCH rather than MALFORMED — and that
  difference is load-bearing, because the "an unreadable unqualified line is not hidden by a qualified
  pin" rule keys on the normaliser REFUSING. Beside a good qualified pin the junk line was handed over
  silently and the run passed at **exit 0** while three engines exited 2. Alone, every engine already
  refused, which is why it survived a review and a five-engine matrix: only the paired shape shows it.
  Found by writing the pin grammar's first UNIT test, which contradicted an end-to-end measurement I had
  read as a refutation. candor-agents had the same defect (`str.isdigit()`); both fixed, five-way now.
- **The pin grammar moves to CandorCore** (`EnginePin.swift`), for the reason two cardinal sins already
  gave today: it was in the executable target, which SwiftPM cannot `@testable import`, so the only
  instrument that could reach it was a forty-minute cross-engine suite with one row per rule.
  `EnginePinTests` carries the fifteen spellings that matrix covered by hand.

- **⚠ `MotionRaw` was classified, gated on, and then dropped before the report.** The CoreMotion split
  shipped without an `Effect` case, so `EffectSet.init`'s `compactMap` discarded it at serialisation and
  a function whose only effect was the raw accelerometer stream serialised as `inferred: []` — under
  ⟨0.21⟩ a positive purity claim about a function with a live sensor reach. The two gate routes
  DISAGREED on the same policy and the same code (live scan exit 1, `gate --report` exit 0), because one
  reads the in-process effect set and the other reads the report the effect never reached. Removing an
  over-report had replaced it with silence, which is the worse half. `Effect` and `EffectSet` move to
  CandorCore — they were in the executable target, which SwiftPM cannot `@testable import`, so the last
  and most consequential copy of the vocabulary was untestable by construction; that is why the same
  failure had already happened once, to nine families at `privacy/3`. `EffectVocabularyTests` now pins
  the round-trip in both directions.
- **The `--gate-json` sink could be armed over the gate's own inputs.** `--policy P --gate-json P` armed
  the fail-closed refusal over `P`, the now-JSON policy parsed as zero rules, and a run that exits 1 on
  the same code exited **0 with `"ok": true`** — a machine-readable all-clear produced by deleting the
  question. Introduced by the arming commit itself: before it the sink was written only on a refusal, so
  there was nothing to destroy. Aimed at `<target>/.candor/config` the same mechanism deleted the config
  that DECLARED the policy. Now refused (exit 2, nothing written), with sameness resolved as artifacts —
  symlinks and `./` spellings included — and `.candor/config` refused by shape wherever it is.
- **Arming moved ahead of every exit, including usage errors.** It ran after the flag loop, so
  `--gate-json G --frobnicate` wrote a refusal into `G` while `--frobnicate --gate-json G` left the
  previous run's green at `G`: the contract depended on argv ORDER. SPEC §3.3 names an unknown flag as a
  broken-gate-config exit-2 cause. The `gate` verb registered a sink but never armed at all — and its
  own comment explained why registering is not arming.
- **A `--gate-json -` consumer got zero bytes on two exit paths** (unknown flag, nonexistent target)
  while an unreadable policy on the same sink produced a proper refusal — same run, same sink, three
  different answers. All three now emit exactly one refusal document.
- **The build-settings reader is a real evaluator, not a substring scan.** Eight further cardinal-sin
  flips, all with one root: it asked "does this text appear on this line" when the question is "what
  does this assignment evaluate to". A key name inside another setting's quoted value declared the key;
  two settings on one line broke BOTH honesty halves at once (the empty one read as declared, the
  genuine one was never seen); only the first `[cond]` group was skipped; a `/*` inside a quoted search
  path opened a comment that swallowed a later undeclare; a commented-out `#include` was still followed;
  and a symlinked include escaped the project tree. It now strips comments with quote awareness, splits
  into statements, and parses `NAME[cond][cond] = VALUE` with quote and bracket depth tracked. **Moved
  to CandorCore** — like the effect vocabulary it was untestable by construction, which is why three
  rewrites produced fourteen flips with no test ever going red; `BuildSettingsTests` now carries every
  one. Verified against the previous evaluator on 129 real build-settings files: identical answers.
- **Last-assignment-wins is replaced by a consistency rule.** A key assigned a real value in one place
  and left empty in another is no longer declared by whichever file was read last — an App Store archive
  is Release, and the engine cannot tell which configuration ships without the build graph. It reports
  the key as not declared and DISCLOSES the disagreement, on stderr and in the verdict JSON, because an
  inconsistent declaration is a real finding about the project rather than a limit of the reader.
- **A NO-BREAK SPACE hid an engine pin.** Config lines split on ASCII space/tab only, so
  `engine\u00A00.26.0` — what you get pasting a config out of a rendered doc — became one token, was
  reported as an "unknown config key 'engine '", and the pin went silently unenforced while a MISMATCHED
  version passed at exit 0. A false disclosure over a fail-open. Now Unicode whitespace, matching the
  other four engines; pinned five-way by conformance PART 33.
- **A second positional silently replaced the scan target** — `candor-swift . rep.json` scanned
  `rep.json` and said nothing about `.`. Now a usage error naming both.


- **`CMMotionManager` requires no usage key, and candor said it did** — reporting a shipping app as
  under-declared. Apple's `NSMotionUsageDescription` page names four APIs (`CMSensorRecorder`,
  `CMPedometer`, `CMMotionActivityManager`, `CMMovementDisorderManager`); `CMMotionManager` references
  none. The raw stream now has its own effect with no key — the access is still reported, it just isn't
  a manifest requirement. Reading Apple's list also found `CMMovementDisorderManager` mapped nowhere.
- **The build-settings reader is a value evaluator now, not a substring scanner** — it flipped to the
  cardinal sin seven more ways, every one a way somebody turns a key off or splits a file: last-wins
  empty (the Debug-declares/Release-does-not shape, and an archive is Release), CRLF resurrecting both
  earlier fixes, a `[sdk=…]` condition swallowing the `=`, `${FOO}`/`$FOO`, an unclosed `/*`, and an
  unmarked tree searching shared ancestors. Also stopped treating `#`/`//` inside a quoted value as a
  comment, which had judged real declarations empty.
- **Arming, not sink-registration.** A kill mid-run and a bare `exit(2)` both left the previous verdict;
  registering a sink only covers refusals that route through it, and enumerating exits keeps missing one.

- **A refusal must never leave the last run's green: `--gate-json` is now armed FAIL-CLOSED at run
  start.** With a mismatched or unreadable `engine` pin this engine exited 2 and left the PREVIOUS run's
  verdict document on disk, so a CI wrapper reading the artifact rather than the exit code reported a
  **pass over a run that refused** — from the release's flagship guard. Arming at the start makes it a
  class fix rather than a branch fix: every exit path leaves a refusal unless the run got far enough to
  replace it. candor-java's `armGateJson` is the model.
- **The build-settings reader flipped to the cardinal sin twice**, both by *disabling* a key — the way
  a person actually turns one off. A commented-out `INFOPLIST_KEY_…` and `= $(inherited)` each counted
  as declared, silencing the App-Store-rejection finding the verb exists to raise. The directory walk
  also had no boundary, so a stray `.xcconfig` in a shared parent satisfied the verify. Fixed, along
  with the false-alarm direction: `sdk=` conditionals and `#include`d configs now count, and `--json`
  carries `declaredViaBuildSettings` so a machine consumer can tell a plist declaration from a build
  setting seen up the tree — those are not the same claim.

- **A bare `engine <impl>` still split the family five ways.** `engine swift` — an operator forgetting
  the version on a qualified line — was skipped by candor-java and treated by the other four as a
  WILDCARD pin whose version is the literal `swift`, so it exited 2 in every engine that is *not* swift:
  one typo, a family-wide outage, on the exact property PART 33 exists to pin. The cause was arm ORDER —
  arity was tested before ownership, so the one-token case was claimed by the wildcard arm before anyone
  asked whose line it was. **A known qualifier now decides ownership first**, per §3.4's "whatever
  follows it" — and nothing following it is a case of that too.
- **`privacy-manifest --verify` now reads `INFOPLIST_KEY_*` from `.xcodeproj` and `.xcconfig`.** Since
  Xcode 13 that is where usage descriptions live by default, and the source tree's `Info.plist` often has
  none of them. Measured before the fix on three shipping open-source apps: IceCubesApp produced THREE
  false "under-declared" findings against an App Store app whose keys are all in its `.pbxproj`;
  duckduckgo/iOS carries 8 such settings and WordPress-iOS 12. A false rejection warning is worse than no
  verb — it teaches the reader to distrust the tool. It can only ADD to the declared set, so an empty
  purpose string is still not a declaration and the provenance is reported rather than silently merged (a
  setting can belong to a different target). Verified it still catches a real gap.

  **That sentence used to end "and it found a true positive in the wild: WordPress-iOS calls
  `startDeviceMotionUpdates()` with no `NSMotionUsageDescription`". It was not a true positive**, and the
  entry below on the `CMMotionManager` split says so: Apple's page for that key names four APIs, raw
  accelerometer streams are not among them, and WordPress needs no key. A retraction two entries away
  from the claim is not a retraction, so it is made here.

- **A baseline DECLARED in `.candor/config` but missing is now exit 2, not a green pass.** An adopter
  review measured this as the second-likeliest first-commit mistake (`.candor/` committed, the baseline
  not) and found every engine printing a note and exiting **0** — the gate quietly not gating. The split
  is by SOURCE, because the same absence means two different things: `CANDOR_BASELINE` is set
  unconditionally by the adopt workflow, so a path that is not there means "the ratchet is not adopted
  yet" and stays a note; a checked-in `baseline` line DECLARES that this repo has one, so an absent file
  was deleted or never committed. Verified four-way: config-declared → 2, env-named → 0.


- **Panel review: the pin grammar disagreed across engines on a shared config.** Three confirmed
  divergences, each a case conformance PART 33 had not thought of, all now fixed and pinned there:
  a junked line qualified for ANOTHER implementation (`engine swift 0.99.0 junk`) killed this engine's
  own run — SPEC §3.4 now rules the skip WHOLE-LINE, because a malformed line naming another engine is
  that engine's problem and it refuses on it, while refusing everywhere turns one typo into a
  family-wide outage; `vv0.27.0` was accepted as a version by engines that stripped every leading `v`;
  and a CRLF config broke a MATCHING pin where `\r` was not treated as whitespace.


- **⟨0.27⟩ SPEC §3.4 `engine` — the engine↔baseline coupling, enforced here too.** A build that is not
  the pinned one FAILS with exit 2 (UNEVALUABLE, never 1 — a machine consumer must not read "I could not
  trust this result" as "your code broke a rule"). Two of the five verdicts deliberately do NOT change
  the exit code: an absent pin (the key is opt-in by construction) and one this build cannot check,
  which is §3.1's unanswerable-condition rule — disclosed, never scored, *including* as satisfied. An
  unreadable pin (`engine latest`) exits 2 rather than being skipped: this is the one place §6.2's
  warn-and-skip inverts, because skipping a PIN hands the operator a guard they believe is on. A pin
  qualified for another implementation is ignored — one config serves the family, which versions as a
  ladder. Pinned four-way by conformance **PART 33**.


- **The Linux leg builds again.** `entitlementRequiredKeys` read the `.entitlements` plist with
  `NSDictionary(contentsOfFile:)`, which is deprecated on swift-corelibs-foundation — and this package
  compiles with `-warnings-as-errors`, so the macOS-green change failed CI on Linux. Now uses
  `PropertyListSerialization`, which `loadDeclaredKeys` forty lines above had been using all along.


### Constant provenance rungs 3–4: computed paths resolve

`CONSTANT-PROVENANCE-DESIGN.md`'s remaining rungs, and the same primitive the Android permission work
needs. The spellings real code uses now classify:

```
NSHomeDirectory() + "/Documents/y"                      → NSDocumentsFolderUsageDescription
"\(NSHomeDirectory())/Desktop/x"                        → NSDesktopFolderUsageDescription
let p = NSHomeDirectory() + "/Downloads/z"; use(p)      → NSDownloadsFolderUsageDescription
NSTemporaryDirectory() + "/cache"                       → nothing (app-scoped)
func f(_ p: String) { use(p) }                          → nothing, and DISCLOSED as undetermined
```

**Classes, not strings** — the resolver never reconstructs a path. It looks for a proved home-directory
anchor and takes the literal that follows; an unresolvable tail keeps the prefix, because the prefix is
what decides the class. Anything without that anchor returns nil rather than a guess, so an ordinary
computed path stays undetermined and is counted by `incomplete` instead of classified on a hunch.

**`NameKeyedStateTests` caught the fabrication this introduces**, which is the third time that guard has
paid for itself. `homeAnchoredLocals` is keyed by a BINDING NAME, so without clearing it on rebind,
`func a() { let p = NSHomeDirectory() + "/Desktop" }` charged a later `func b(_ p: String)`'s parameter
the Desktop key — a fabrication from a name collision.

**And then the clearing broke the feature**, in the way the file warns about six lines above the site:
`shadowName` runs before the initializer is walked, so recording the binding first meant the rebind
immediately wiped it and only the inline form still resolved. The value is now captured before
`shadowName` and applied after — the same carve-out `fnValueAlias` documents. The file said so and I
still had to measure it.

Recall battery 66/66 including an app-scoped guard. A/B: candor-swift 38 → 38 with no changed rows, real
app 4 effects and verify exit 0 — additive.

### §2 `incomplete` — the per-function direct signal, and the ⊤ count made real

The undetermined-path count read `paths`, which **propagates**: a function counted as determined when
anything it transitively reached named a literal. One logger writing `/tmp/app.log` zeroed the count for
a whole call graph, and every real app has one — so the "clean, and zero undetermined" state the design
asked for was manufactured by ordinary code. In the other direction it counted transitive callers that
perform no file I/O at all (52% of the number on candor's own source).

The report now carries a per-function `incomplete` list: the effects whose locator **this function
itself** could not determine. Omitted when empty, so a scan that determined everything is byte-identical
to one from before the field. `FixFn` carries it; the verify counts from it.

On the real app: **282 → 57 → 4**. The first cut was inflated, the second still masked, and 4 is the
number of functions whose own file destination is genuinely unknown. That number is small enough to act
on, which is the whole difference between a warning and noise.

`--verify --json` now carries the disclosure too — `keyCoverage`, `undeterminedPaths`,
`entitlementUnderDeclared`, and `ok` agreeing with the exit code. Every §6 mechanism had lived in the
human branch only, so CI — the intended consumer of `--json` — got a bare `"ok": true`. The field is
`keyCoverage` and not `coverage` because the verdict already had a `coverage` key (the ⟨0.15⟩ uncovered-
modules block) and the first version silently overwrote it: two different questions under one name.

### `--target` refuses an unreadable dependency list

`dependencies:` read only a literal array, so two ordinary manifest idioms — a hoisted
`let coreDeps: [Target.Dependency] = ["Core"]`, or `["Core"] + extra` — yielded `deps: []`. `--target App`
then scanned App alone and reported it performing **nothing**, while the truth was that it reaches `Fs`
through Core. An empty report is a purity claim over every function in the dropped targets, and the
"stays disclosed by the coverage ledger" promise is false for a target that was never scanned. It now
exits 2 naming the idiom.

### Two more copies of the sensor vocabulary — one of them predates today

The seven-copy problem was fixed for the copies that decide WHETHER an effect is reported. Two that
decide how it is PRESENTED were missed, and a review pass over my own claim found them.

- **The scan summary dropped effects it had computed.** `main.swift`'s effect breakdown is a
  `.filter` over a hardcoded list, so an effect absent from that list was computed, counted, written
  to the report — and silently omitted from the line a user reads first. Measured: a scan reaching NFC
  and HealthKit printed `Health 1` while the report carried `['Health', 'Nfc']`. Nothing was wrong with
  the artifact; the terminal was quieter than it.
- **`tour` could not rank any sensor added after `privacy/1`.** The salience switch scored only the
  original six at 5; Health, Motion, Calendar, Bluetooth and every family since fell to `default: 0`.
  An app quietly reaching HealthKit is the exact case `tour` exists to surface, and it was the case
  `tour` ranked last. **This one has been true since `privacy/2`**, not since today.

Both now derive from `PRIVACY_EFFECTS_ORDER`. The lesson is narrower than "there were seven copies": the
copies that gate reporting were obvious to check because a missing entry made a test fail loudly, and
the copies that gate PRESENTATION failed silently — a correct report, a quieter terminal, and no
assertion anywhere with an opinion about it.

### Entitlements: 56 of 57, and one key that is honestly out of reach

**`NSCriticalMessagingUsageDescription` has no call site — Apple's page for it links no symbol at all**,
because the capability is granted by an entitlement and the API it unlocks is ordinary messaging code.
No call-graph analysis will ever see it. So candor reads the `.entitlements` file:
`com.apple.developer.messages.critical-messaging` present ⇒ the key is required.

**This is a different kind of evidence and the output says so**, rather than folding it in:

```
✗ App.entitlements grants 1 entitlement(s) whose usage-description key is not declared: NS…
  (from the ENTITLEMENTS file, not from code — these capabilities have no call site for candor
   to find, so this is a manifest-to-manifest check.)
```

Everything else this extension reports comes from analysing code. Presenting a plist diff as a
call-graph result would misrepresent what was actually checked, so the finding is labelled at the point
of output and `entitlement` is its own determination basis in the §6 breakdown.

Same discovery discipline as the Info.plist: exactly one is read, **several REFUSE to guess** (an app
with several targets has several, and reading the wrong one answers about the wrong binary — the real
app hits exactly this and says so). An entitlement present but **false** demands nothing, which is a
cheap mistake to make when reading a plist and is pinned by a test.

**`NSFileProviderPresenceUsageDescription` stays unmodelled, and that is the honest answer.** Apple
documents no API and no entitlement for it — its page links only sibling *keys*. But it applies ONLY to
an app that ships a file provider, and candor can see that, so the verify raises it **conditionally**:

```
· this app reaches the FileProvider surface, so NSFileProviderPresenceUsageDescription MAY apply.
  Apple documents no API and no entitlement for it, so candor cannot tell — check it by hand…
```

A lead where the capability is even possible, silence everywhere else. Naming it on every app would be
noise; naming it nowhere would be the gap.

### 55 of Apple's 57 — the last five, found in the docs' `references` block

The five keys that named no type in their prose named one in their DocC **references**: Apple's own page
for `NSSystemAdministrationUsageDescription` links `ODRecordSetValue`, and `NSAudioCapture` links
*Capturing system audio with Core Audio taps*. Reading the wrong part of the JSON was the whole
obstacle.

- **SystemAdministration** → OpenDirectory (`ODRecord`, `ODNode`, `ODSession`)
- **AudioCapture** → Core Audio taps (`CATapDescription`, `AudioHardwareCreateProcessTap`)
- **EnterpriseMCAM** → the SAME visionOS camera API as `NSMainCamera`, under a managed entitlement, so
  it is an ALTERNATIVE key on the existing effect rather than a family. Which of the two applies is an
  entitlement fact this engine cannot read, and declaring either satisfies the requirement.
- **AppBundles** (`/Applications/*.app/`) and **AppData** (`~/Library/Containers/`) → **path classes**.
  Apple names no API for these because there isn't one: reading another app's bundle is ordinary file
  I/O and it is the PATH that makes it protected. Two keys that looked like they needed a new mechanism
  needed none.

**Two keys stay unmodelled, with an accurate reason instead of a shrug.** They used to read
"enterprise/managed surface; not modelled", which implies nobody got to them.
`NSCriticalMessagingUsageDescription` links no symbol at all (an entitlement for emergency SMS — the
evidence is a `.entitlements` file, not a call site) and `NSFileProviderPresenceUsageDescription` links
only sibling keys (a presence capability is declared, not called). Neither is a gap in the model; both
are outside what code analysis can see, and the verify now says that in those words.

Recall battery: **62/62, 0 broken promises.**

### LocalNetwork — and `NWBrowser` was not modelled at all

**50 of Apple's 57 keys.** The `.local` host, the RFC1918/link-local literals and the bonjour descriptor
each name the local network by definition, so the key is decided without a judgement call. A public host
gains nothing — asserted by a fixture, because charging every networking app is exactly the fabrication
that kept this key unmodelled.

**The more serious half is not the key.** `NWBrowser` — Bonjour/mDNS service discovery — was in no table
anywhere: `NWBrowser(for: .bonjour(…), using: .tcp)` produced **no effect at all**, so a
service-discovery app read pure. `NetService`/`NetServiceBrowser` likewise. That is a silent under-report
on the floor `Net` effect, found while chasing an extension key, and it is fixed independently of the
privacy vocabulary.

The bonjour descriptor is gated at the CONSTRUCTOR as well as the member, because
`NWBrowser(for: .bonjour(…))` is the spelling real code uses and the member arm only sees
`browser.start()`.

### All privacy waves ship as ONE version

Development ran through four increments in two days and each bumped the extension id. But `privacy/1` is
the only version any release has carried — v0.25.0 and v0.26.0 both ship it — so `privacy/2` … `/5` never
existed for a consumer, and publishing four of them would present our git history as somebody's upgrade
path. It ships as `privacy/2`. The increments survive as narrative here and in the extension spec, where
the *order* is the useful part: each wave was found by measuring the previous one.

### Path classes: the five folder keys, at the first two rungs

`CONSTANT-PROVENANCE-DESIGN.md` rungs 1–2, plus the two remaining type-nameable families. **47 of
Apple's 57 keys are now modelled**, up from 42.

- **rung 1 — literal paths.** `contents(atPath: "/Users/me/Desktop/x")` now also yields
  `NSDesktopFolderUsageDescription`. Classes, not strings: a proved PREFIX decides the class and the
  unknowable tail is irrelevant.
- **rung 2 — the canonical spelling.** `FileManager.default.urls(for: .desktopDirectory, in:)` — real
  code asks for the search-path constant far more often than it writes a path out, and unlike a literal
  it is always readable.
- `/Volumes/…` returns **both** removable and network-volume: macOS cannot tell a disk from a mounted
  share by path, and on a privacy manifest a false prompt costs a confused user while a false silence
  costs a rejection.
- **NearbyInteraction allow-once** needed no new family at all — `privacyKeyMap` is a list and the verify
  accepts any member, so it is a second acceptable spelling of an existing key.
- **AccessoryTracking** (`AccessoryTrackingProvider`, `AccessoryAnchor`), both verified against Apple.

**The asymmetry that keeps this safe.** An unreadable *media type* still means a capture is happening, so
that case over-discloses. An unreadable *search path* is overwhelmingly an app-scoped directory needing
no key, so it yields NOTHING — charging all three folders on every `urls(for:)` call would fabricate on
ordinary code. The miss is caught by §6's undetermined-path disclosure instead. A fixture asserts an
app-scoped write gains no folder key, and the real app's 282 file operations produced no new keys.

**The battery now models the basis distinction.** A `constant`-basis miss is checked against §6's ⊤
count: disclosed ⇒ a designed residue, silent ⇒ the cardinal sin and a hard failure. The computed
spelling (`NSHomeDirectory() + "/Documents"`, rung 4, unbuilt) is correctly reported as *"not determined,
but DISCLOSED"* rather than as a broken promise — which is the design working end to end, and is only
checkable because the basis is executable rather than documentation.

### The verify reports HOW COMPLETELY, not just which keys

§6 of `candor-spec/CONSTANT-PROVENANCE-DESIGN.md`, landed BEFORE the coverage work it exists to make
safe. Today the verify's value rests on one sentence — *"here are the keys I do not check"* — and the
moment every key is nominally modelled that sentence disappears, while coverage WITHIN several keys is
still partial. Full coverage without this would be a reduction in honesty bought with an increase in
the count.

So the disclosure changes axis. Each key now carries a **determination basis**, and the verify reports
per basis rather than as one number:

```
⚠ COVERAGE: 42 of Apple's 57 documented usage-description keys are modelled
  (7 by argument · 2 by member · 33 by type).
```

`type`, `argument` and `member` are recall-complete by construction — an unreadable argument
OVER-discloses rather than going quiet. `constant` (a path or URI class decides the key) is the only
lossy basis, and it is the one that must always report a count beside it.

**The ⊤ count.** The verify now names the file operations whose PATH it could not determine:

```
⚠ 282 function(s) perform file I/O whose PATH this scan could not determine (…).
  The folder keys above are decided by the path, so those functions are exactly where an
  NSDesktop/NSDocuments/NSDownloads/removable/network-volume requirement would hide. This is a
  LOWER BOUND: a function with one determined path and one undetermined counts as determined.
```

That is the concrete form of a caveat that used to be abstract: those keys are unmodelled **and** you
cannot rule them out by reading the report either — here is how much you cannot see. When constant
provenance lands the number becomes load-bearing; today it is honest context. It is a lower bound
because `paths` is per-function, and undercounting a disclosure is the dangerous direction, so the
output says so rather than presenting the number bare.

`FixFn` carries `paths` to make this possible — defaulted empty like `privacyKinds`, because empty is
meaningful (undetermined) rather than lossy, so a report predating the field reads as "nothing
determined", which is the honest answer for a producer that was not emitting it.

### `privacy/4` — seven more families, and 42 of Apple's 57 keys now modelled

Focus status, Wallet identity, FinanceKit, the three visionOS ARKit providers (hands, world-sensing,
main camera) and temporary location accuracy. **Every type name was verified against Apple's docs JSON
before being mapped** — a wrong type→key mapping does not merely miss, it fabricates a requirement on
real apps, and this is a vocabulary it is easy to be confidently wrong about.

Temporary accuracy exposed an ordering bug: `requestTemporaryFullAccuracyAuthorization` has its own key
but sits on `CLLocationManager`, already modelled as `Location`. The type map was consulted BEFORE the
member map, so the type always won and the temporary key could never be emitted. Member-gated families
now match first; a realistic location app gets both keys, which is what Apple requires.

The 15 keys still unmodelled are the four path-triggered macOS folder keys (the same `FileManager` call
needs a different key depending on a string — value provenance), LocalNetwork, the enterprise/MDM
surfaces, and allow-once variants that are not separable at a call site. All derived, all disclosed.

Recall battery: 44/48 caught, 0 broken promises.

### `--verify` finds the Info.plist itself

`candor privacy-manifest --verify` now takes an OPTIONAL path. Bare, it discovers the plist — so the
documented flow is two commands with nothing to look up:

```
brew install candor
candor privacy-manifest --verify
```

**It refuses when a repo ships several.** The real app this was built against has two (a macOS one and
an iOS one), and verifying the wrong one is a confident verdict about a binary the reader never asked
about — the exact artifact `--target` exists to remove, reintroduced through the back door. So more than
one candidate is exit 2 with all of them named, never a pick. Exactly one is used and SAID on stderr,
because a verdict is about a specific binary's manifest and the reader has to know which.

Build output is excluded (`.app`, `.appex`, `.framework`, `Build/`, `DerivedData`, `Pods`), and so are
test bundles: the first cut listed 22 plists for an app that has 2, because every built bundle carries a
copy of one already found. A refusal that buries the two real answers in twenty derived ones has
technically not guessed and has practically not helped.

### `privacy-manifest --xml`: a paste-ready Info.plist fragment, not a reading exercise

"Generate" printed a requirements list — `Contacts → NSContactsUsageDescription (reached by: …)`. A user
with an existing `Info.plist` then had to hand-write the XML, invent the description string, and merge it
themselves. The verb's name promised a manifest and delivered homework. (It never wrote anything, so
running it against an existing plist was safe — just unhelpful.)

`--xml` emits the fragment. On `--verify` it emits **only the missing keys**, so it pipes, and the exit
code stays the verdict — the output format does not move it:

```
$ candor-swift privacy-manifest --verify Apps/PolleniOS/Info.plist --xml
<!-- candor privacy-manifest — paste into your Info.plist <dict>.
     REPLACE each placeholder string: Apple reviews these, and this text is not a
     description of what your app does with the data. -->
<key>NSContactsUsageDescription</key>
<string>TODO: why this app needs Contacts access</string>
```

A FRAGMENT, deliberately, never a whole plist: every real app already has one, and emitting a complete
document invites overwriting it. The placeholder strings announce themselves because Apple reviews that
text — a plausible-looking generated sentence would be both wrong and, precisely because it reads well,
likely to ship.

### `--target`: scope a scan to one shipped binary

`candor-swift <dir>` scans every `.swift` file under it. For a package with several products sharing a
core that charges each product with every OTHER product's effects, and the privacy-manifest verify then
answers about code the product never compiles. On a real app, scanning the repo whole and verifying
against the macOS `Info.plist` reported

```
✗ code reaches Mic (via iOSBlowMonitor.actuallyStart, …) but Info.plist declares no NSMicrophoneUsageDescription
✗ code reaches Motion (via PolleniOSApp.init()#2, …) but Info.plist declares no NSMotionUsageDescription
```

for two sensors only the **iOS** target can reach. The analysis was right; the UNIT was not a shipped
binary. The documented remedy was to hand-build a separate `Package.swift` per product — a workaround
wearing methodology's clothes.

`--target <name>` resolves that target's in-package dependency closure from `Package.swift` and scans
exactly those sources. Same app, same command, one flag:

| scan | verified against | result |
|---|---|---|
| whole repo | `Resources/Info.plist` (macOS) | exit 1 — ✗ Mic, ✗ Motion · **artifact** |
| `--target Pollen` | `Resources/Info.plist` | **exit 0** — ✓ clean, 4 effects |
| `--target PolleniOS` | `Apps/PolleniOS/Info.plist` | **exit 1** — ✗ Contacts |

The last row is the finding that survives the correct methodology, and it survives because `Contacts`
reaches the iOS binary *through the shared core* — a reach no grep of that target's own sources can see.

**Every failure REFUSES.** This feature makes a scan see LESS, and under ⟨0.21⟩ absence from `functions`
is a positive purity claim — so an unknown target (exit 2, naming the targets that exist), a closure
member whose source directory is missing (exit 2, naming what was tried), and an empty result all stop
rather than scanning less and continuing. A scoped scan also DISCLOSES its scope on stderr: a clean
verdict over one target reads exactly like a clean verdict over the package otherwise.

`Package.swift` is parsed with SwiftSyntax, not by regex — `manifestPackageName` in `main.swift`
documents at length why the regex form is fragile. `.product(name:package:)` dependencies are external,
have no sources in this tree, and stay disclosed by the coverage ledger rather than silently joining the
closure.

**A soundness bug the tests caught on their first run:** `.target(name: "Core")` is *also* the in-package
form of a dependency reference, so descending into a target's `dependencies:` array parsed the inner call
as a second DECLARATION of `Core` — one carrying no dependencies. The two entries then raced in the
by-name lookup, and when the phantom won, the closure walk stopped at `Core` instead of continuing
through its own dependencies: sources dropped from the scan, i.e. a purity claim over every function in
them. Found by asserting on the FULL target list rather than on membership.

#### A scoped report does not claim the package's identity

Found by asking what a MACHINE consumer sees: a scoped report was byte-shaped exactly like a whole-package one — same `package`, same `hash` key
namespace, just fewer functions — and the stderr scope note is not in the artifact anyone chains. Under
⟨0.21⟩ absence from `functions` is a positive purity claim, so chaining a scoped report under the
package's name reads every function in the unscanned targets as pure. The cardinal sin, introduced by a
convenience flag.

The fix needs no format change: a scoped scan qualifies the key (`MultiTarget/MacApp#…`), so a consumer
looking for `MultiTarget#…` simply misses — and a miss is DISCLOSED, not silent.

The first attempt at that also put the target in the FILENAME, so a package's scoped reports could
coexist. That read as a feature until discovery had to choose between them: after `--target MacApp` the
privacy verb reported the microphone, which only the iOS target reaches. A silently wrong answer is worse
than the overwrite it replaced, so a scan writes ONE current report exactly as before, and `--out` is how
you keep several.

### fix: `toShare: nil` is read-only, and claiming otherwise failed every read-only HealthKit app

`privacyKind` treated `requestAuthorization(toShare:read:)` as unconditionally ambiguous and declared BOTH
directions. But `toShare: nil` is the canonical read-only spelling and is right there in the source — so a
read-only HealthKit app was charged with a WRITE and told it needed `NSHealthUpdateUsageDescription`.

That is a false under-declaration on the commonest shape in the framework, and it is the FABRICATION
direction this extension explicitly fences — not the over-disclosure the ambiguity rule is meant to buy.
Found reviewing my own privacy/2 work, not by a failing test.

Measured: a read-only app against a Share-only plist now exits 0; an app that also calls `save` against the
same plist still exits 1 naming the write. A non-nil `toShare:` set, or an argument the engine cannot see,
stays ambiguous and declares both — the invisible case must never resolve to the convenient side.

The durable lesson is narrower than "be careful": before declaring an ambiguity, check whether the
discriminating argument is actually invisible. Here it was in the source all along, exactly as the
media-type and entity-type discriminators already assume.

### `privacy/2` direction — the verify is no longer silent on read vs write

The privacy case study shipped with a stated limit: *"the verify is sound on PRESENCE and silent on
DIRECTION"*. Apple splits three key families — HealthKit Share/Update, Photos full/Add-only, Calendars
full/write-only — and treating each pair as interchangeable alternatives meant an app that both reads and
writes HealthKit passed while declaring only Share, then got rejected. That limit is now closed.

`privacyKind(root:member:)` refines a call ALREADY classified as a privacy effect with the direction its
verb implies, on exactly SPEC §2 `fs`'s contract: `["read"]`, `["write"]`, `["read","write"]`, or `[]`.

THE EMPTY CASE IS THE SAFETY PROPERTY, and it is why this could ship without re-auditing anything: an
unrecognised verb contributes nothing, and an effect with no proved direction keeps the pre-`privacy/2`
behaviour EXACTLY — any acceptable key satisfies it. The refinement can only ADD a requirement where a verb
said. A report predating the field verifies identically, so the upgrade cannot turn a passing project red
by itself.

Measured end to end: code that reads and writes HealthKit against a Share-only plist now exits 1 with
`✗ code reaches Health (write) … declares no NSHealthUpdateUsageDescription`, naming the writing functions;
with both keys it exits 0. On the real app both targets are PROVED to read and write Health and both plists
declare both keys — verdicts unchanged, which is the regression check that matters.

Asymmetry worth stating: Add-only satisfies a write and NOT a read, and write-only likewise. Tests assert
that directly, because getting it backwards is an App-Store-shaped wrong answer.

`requestAuthorization(toShare:read:)` names both sides in one call and its discriminating argument is a
runtime Set, so it is genuinely ambiguous and declares BOTH — the extension's standing trade-off.

The key tables moved to CandorCore beside `privacyKind`. The discriminator and the key families it selects
from are one concept, and splitting them across modules is how a pair drifts apart.

KNOWN LIMIT: direction resolves where the receiver's TYPE does. A module-level `let` used across files
yields none — which falls back to any-key, i.e. fails safe.

### SPEC §2 `fs` — candor-swift now emits the read/write refinement it never had

`fs` has been in SPEC §2 since long before this engine, and rust and java carry it. candor-swift did not:
its only `fs` was the effect-name enum case. So a consumer asking "does this function read the disk or
mutate it" got the answer from two engines and silence from a third.

It went unnoticed because the spec's own rule makes partial implementation HONEST — an absent `fs` means
"kind undetermined", never "read-only" — which is the design working, not an excuse. The gap is still a
gap.

**CORRECTED before release — the first version of this was direct-only and that was wrong.** I read
candor-java's `fsDirect` comment ("kind performed directly") and never followed it to `fsFixpoint()`, which
propagates over edges AND injects an `FS_UNKNOWN` poison that suppresses the whole field. So kinds DO
travel: a caller that transitively only writes is a writer, and saying so is the point of the field. What
must not travel is a PARTIAL answer — if any contributing `Fs` has no determined kind, the field is
suppressed entirely, because `["write"]` there would claim "writes but never reads" about a function that
may do both. Conformance PART 31 caught the divergence on its first run.

Measured: `copyItem` → `["read","write"]`, `contents` → `["read"]`, `createFile` → `["write"]`, a caller of
a writer → `["write"]`, and a function reaching one writer plus one undetermined-kind callee → omitted.

The verb table is deliberately the same shape and vocabulary as candor-java's `fsKind`. The surface is
spec'd four-way; two engines inventing two verb tables for one field is how a shared field stops meaning
one thing.

Tests assert what the classifier REFUSES to say as much as what it says — an unrecognised verb returns
nothing at all, and a bare `FileHandle(...)` reveals no direction. Both probed by breaking them.

### `privacy/2` — the sensor vocabulary goes from six to eighteen

Writing the privacy-manifest case study is what surfaced this. A real app's `Info.plist` declares
`NSMotionUsageDescription` and two HealthKit keys, and `privacy-manifest --verify` said **nothing about
them in either direction** — neither required nor flagged as unused — because the effects did not exist.
`exit 0` meant "the six I model are declared" while reading as "your plist is right", which is the
absence-is-a-claim shape ⟨0.26⟩ closed for sidecar keys.

Added: `Health`, `Motion`, `Calendar`, `Reminders`, `Bluetooth`, `Speech`, `Biometrics`, `MediaLibrary`,
`HomeKit`, `Tracking`, `NearbyInteraction`, `Siri` — with their Info.plist key families. Measured on the
same app: the macOS target now reports 4 effects where it reported 3, and Motion resolves on iOS.

DECISIONS WORTH THE INK:
· **The extension version moved with the vocabulary.** A consumer that understands `privacy/1` expects
  exactly six effect names; emitting `Health` under that label would make the extension's own positive
  declaration inaccurate. The envelope now discloses `privacy/2`.
· **`EKEventStore` is ambiguous exactly like `AVCaptureDevice`** — one type serving calendars AND reminders,
  chosen per call by an `EKEntityType` — so it gets the same treatment: a statically-visible
  `.event`/`.reminder` refines, anything else over-discloses both. Same code shape as `mediaTypeArg`
  DELIBERATELY, so the two cannot drift into different rules for one problem. Measured and documented: a
  local CONSTRUCTOR carries no entity type, so a function that builds a store declares both even when every
  call on it is refined — and `AVCaptureSession()` was verified to behave identically, so this is the
  trade-off already chosen rather than a new one.
· **Value types are excluded on the `CLLocation` precedent** — `HKQuantity`, `CMDeviceMotion`, `EKEvent`,
  `CBUUID`. Holding a reading is not taking one, and there is a test asserting they stay unclassified.
· **`LocalNetwork` is deliberately absent**, with a test asserting so. `NSLocalNetworkUsageDescription` is
  real, but the reach is not separable from ordinary `Net` by type (`NWBrowser`/`NWConnection` serve both)
  and the key travels with an entitlement this engine does not read. Guessing fabricates on every
  networking app.
· **`Speech` is not `Mic`** — capturing audio and recognising it are separate authorizations with separate
  keys, and an app can do either without the other.
· **A modelled TYPE is still not a covered MODULE, and the ledger keeps saying so.** A scan that charges
  `Health` on `HKHealthStore` still lists HealthKit as uncovered, because the rest of the framework is
  genuinely unmodelled. Marking the module covered would convert a disclosed blind spot into a silent
  purity claim over every other type in it — the cardinal sin, bought for a tidier-looking report.

KNOWN LIMIT, stated rather than left to be discovered: the verify is sound on PRESENCE and silent on
DIRECTION. HealthKit's two keys are not alternatives in Apple's model (Share gates reading, Update gates
writing) and this engine does not tell read from write at the call site, so an app declaring only Share
while also writing passes here and is rejected by Apple. Same for the EventKit pairs.

Tests: every new type asserted, the value-type exclusions asserted, the EventKit discriminator asserted
against all four inputs, and the LocalNetwork omission asserted. Each probed by breaking it.

## [0.26.0] — 2026-08-04 ⟨spec 0.26⟩

### ⟨0.26⟩ THE HIERARCHY SIDECAR'S KEY SET IS ITS MANIFEST — producer half, and PROTOCOLS WERE MISSING ENTIRELY

SPEC §2.2 `ea3de21`. This engine is a PRODUCER only (it ships no `callers` verb), and it had two gaps.
The sidecar inverted `conformers`, so only a type that HAS a supertype got a key at all. And protocols
were absent ALTOGETHER — they are held out of `conformers` by design (a protocol name there pollutes the
concrete-dispatch CHA and its `impls.count == conf.count` guard) and their `protocol Sub: Sup` edges live
in a separate map the sidecar never read:

    BEFORE   {"Impl": ["Mid"], "Sub": ["NSObject"]}
    AFTER    {"Base": [], "Impl": ["Mid"], "Loner": [], "Mid": ["Base"], "Sub": ["NSObject"]}

So `Impl <: Base` was unanswerable for a relation this pass actually knows. Writing them into the SIDECAR
cannot reach CHA — it is a separate output and `conformers` is untouched.

Keyed from `declaredTypes`, NOT `localTypes`: the latter also holds extension-only platform types, whose
supertypes this pass cannot see, so `[]` for them would be the false claim the rung exists to remove. Same
reason `NSObject` stays ABSENT while `Sub` keys `["NSObject"]`.

## [0.25.0] — 2026-08-02

⟨spec 0.25⟩ **Floor bump only — no behaviour change in this engine.** SPEC §2 chaining rule 1 now states
that an ambiguous join key is UNIONED rather than dropped; this engine already implemented the union
(conformance PARTs 25/26 pin it four-way), so 0.25 records the contract catching up with the code. See
candor-spec/CHANGELOG.md for the measurement and the reversal note.


### fixed — a per-entry reader of `unverified` could not see the refusal (2026-08-01)

The rung below put the unjudged function into `unverified` and its reason into the top-level
`unevaluated[]`. That is enough for a reader of the DOCUMENT and not enough for a reader of an ENTRY:
the two are joined only by the raw rule string, and nothing in the entry says the join exists. A lost
disclosure, not a fabrication — the information was in the document, one array away from where a
per-entry consumer looks.

MEASURED four-way over the conformance R11 report under `deny Net[unknown-host] app`, keys **per
entry** — not the union, because the two entry kinds differ and that is the finding:

| | ordinary hole (`app.nativeHole`) | unjudged (`app.noClass`) |
|---|---|---|
| rust | `fn, rule, unknownWhy, upgrade` | `fn, rule, why` |
| java | `fn, rule, unknownWhy, upgrade` | `fn, rule, unknownWhy, upgrade, why` |
| ts | `fn, rule, unknownWhy, upgrade` | `fn, rule, why` |
| swift **before** | `fn, rule, unknownWhy, upgrade` | `fn, rule, unknownWhy, upgrade` |
| swift **after** | unchanged | `fn, rule, unknownWhy, upgrade, why` |

- **`why` is NOT a universal key**, and the measurement is why. No engine puts one on an ordinary hole
  — that entry's reason is `unknownWhy`, and a gate-refusal field sitting beside it would invite a
  reader to take its absence as a statement. It is emitted exactly where a rule was WITHHELD, which is
  the one place a per-entry reader could not previously tell that anything had been withheld.
- **The reason-class arm is where swift lost the most**, and it is invisible in the `Net` column above.
  Under `deny Unknown[dispatch] app` over an inherited-`Unknown` report the function is BOTH an ordinary
  hole and unjudged. rust and ts emit two rows for that one (fn, rule); java merges; swift dedupes to
  one row and the refusal was dropped. So the fix could not be *"add `why` to the rows the answerability
  pass appends"* — the arm that needs it most has no such row. It attaches to the (fn, rule) PAIR,
  whichever pass emitted it: java's merged shape, and the only one of the three that leaves swift's
  one-row-per-pair rule intact.
- The three engines that carry it **do not agree with each other**, so this is not a majority vote. It
  is that a per-entry consumer written against ANY of the three found nothing in swift's entry.
- Same bytes as that entry's own `unevaluated[].why` (§3.2: inventing a second spelling is the mistake
  the document has already made four times) — but per (fn, rule) rather than per rule, since an entry is
  read about its own function while `unevaluated[]` names one exemplar per rule.
- Additive: no key repurposed or dropped, no row added or removed, ordinary holes untouched. Pinned by
  five rows in `AdvisoryBoundProcessTests` — two for the defect (both arms), one for the single
  spelling, and two mirrors: an ordinary hole must carry no `why` at all, and the row count and key sets
  must be otherwise unchanged. The over-report mirror passed before the change and is the load-bearing
  half: a blanket `why` would make the key's presence say nothing.

### fixed — ⟨0.24⟩ three advisory verbs answered a question the gate had refused (2026-08-01)

SPEC §3.2 (candor-spec `4fd140c`): **an advisory verb may be LESS certain than the gate, never more.**
Stated as a law after three local patches — a lenient manifest reader, a hole predicate ignoring the
class filter, and a fallback derivation — that differ in mechanism and share only the direction of the
error. This is the third instance, and its mechanism here is a fourth one again.

MEASURED on the conformance R11 report (`app.nativeHole` = an Unknown outside the policy's class filter;
`app.noClass` = `Net` + `hosts` and NO `netClass`; `app.writes` = a plain `Fs` violator) under
`deny Net[unknown-host] app`:

| | before | after |
|---|---|---|
| `gate --report` | exit **2** — it cannot judge `app.noClass` | unchanged |
| `unverified --json` | `ok:false`, names **only** `app.nativeHole` | names `app.noClass` too, + `unevaluated` |
| `unverified --strict` | exit **0** — green | exit **2**, `ok` omitted |
| `fix-gate --strict` | exit **0**, `ok:true` — green | exit **2**, `ok` omitted |
| `fix app.noClass Net` | `crossing:false, reason:"not-forbidden"` | `reason:"unanswerable"`, `crossing` OMITTED, + `unevaluated` |

`app.noClass` was CLEARED by the verb whose entire job is *"your green gate is not provably green"*,
while the gate declined to clear it over identical bytes. **The mechanism here is NOT the fallback
derivation §3.2 describes** — `matcherNetClasses` reads `netClass` verbatim and derives nothing — it is
that `unverified` only ever considered `Unknown`-carrying functions, so a function the gate could not
judge for a different reason had no channel and fell off the end. An assertion of the form *the verb
names SOMETHING* passed throughout, because the verb names a DIFFERENT hole; only the per-function form
catches it.

- The answerability predicate moved to `CandorCore/Answerability.swift` and `gate --report` now calls
  it. A law that is a COMPARISON cannot be checked from two implementations of the thing compared. The
  prose, iteration order and one-entry-per-rule granularity are unchanged, so the gate's bytes are the
  bytes it emitted before (conformance R6 pins that four-way).
- `unverified` names every (rule, function) the gate could not decide, with the **missing evidence** as
  the reason — carried in the gate's own `unevaluated: [{rule, why}]` (§3.1, `fc4b5f6`), not a second
  spelling — and the **evidence-free rule** as the `upgrade` (`deny Net[unknown-host] app` →
  `deny Net app`), which is what the gate's own refusal already recommends. Never a derived class.
- `fix`/`fix-gate` withhold any remedy whose anchor, pure span or hoist frontier contains a function the
  gate could not adjudicate FOR THAT EFFECT: *"a hoist plan for a boundary the gate could not adjudicate
  is a confident instruction resting on a guess."* Keyed on the effect, not on "some rule went
  unanswered" — the gate keeps charging the violations it is sure of (§3.1 precedence), and a verb that
  went quiet on an `Fs` crossing because a `Net` filter was unreadable would be LESS useful than the
  gate rather than merely less certain.
- `--class` does NOT filter these entries out. Excluding them would make the filter succeed BECAUSE THE
  EVIDENCE IS MISSING — this rung's defect one level down — and it is wrong on §6.2's own terms: the
  class set only grows, so an `Unknown` nobody classified could be `dispatch`.
- `fix`'s `does-not-perform` answer carries NO disclosure: it is read off the effect set, depends on no
  rule, and is not a claim the gate could contradict. Attaching it anyway fired on 141 of 195 sampled
  answers, which is how a disclosure stops being read.
- **AND THE DEFECT THIS CHANGE NEARLY INTRODUCED IN THE MIRROR DIRECTION**, caught in self-review before
  it shipped: the first cut withheld `fix`'s plan by answering `crossing: false`, which over a CERTAIN
  crossing whose only unadjudicable function is a hoist target would have turned a violation the gate
  CHARGES into a non-finding — a silent under-report arriving inside a fix for its opposite. `crossing`
  now says what is known and nothing else: **omitted** when the rule governing the queried function
  could not be read (undetermined, the same reasoning that omits `ok`), **`true`** when the crossing was
  decided and only the hoist plan was withheld. One new `reason` token, no new field.

**WHAT THE CORPORA EXERCISE: NOTHING, and that is the measurement.** `~/git/pollen` (1096 entries) and
this repo's `Sources` (184) carry **0** entries with `hosts` and no `netClass`, **0** `Net` entries
without `netClass`, and **0** `Unknown` entries with neither `unknownWhy` nor a `calls` edge — because
this producer floors `netClass` at `unknown-host` and records a reason beside every `Unknown` it raises.
A report THIS engine wrote cannot reach the defect; the reachable case is a report **another** producer
wrote, which is exactly what `gate --report` exists for. So the A/B is a no-regression control and the
value is measured on a DERIVED corpus:

- **A/B, both real corpora**: 288 paired `unverified`/`fix-gate` runs (12 policies × 4 flag sets) and
  7488 paired `fix` runs (12 policies × a 1-in-17 stride × 3 effects) — **0 differences, 0 functions
  lost**. Scan report bytes byte-identical.
- **DERIVED corpus** — the same pollen graph with `netClass` deleted from all 50 `Net` entries, i.e. a
  report from a producer that does not carry the ⟨0.20⟩ field. `gate --report` exits 2;
  `unverified --strict` went 1 → 2 and 459 → 460 holes (`AggregationClient.upload`, the one `Net`
  function not already named as an `Unknown` hole); `fix-gate --strict` went **0 (`ok:true`, green) → 2**.
- **DERIVED corpus 2** — `unknownWhy` + `calls` stripped (1356 fields). `unverified --strict` 1 → 2 with
  the same 459 holes: the containment already held here BY ACCIDENT, since those functions carry
  `Unknown` and the narrowed rule does not bite them. What was missing was the disclosure and the exit
  code — which is why every row of the new suite asserts a FUNCTION and an exit code, not a count.
- Across all four corpora: **0 functions lost, 1210 gained**, every gain on a derived corpus.

Conformance **R11 `swift advisory-bound` now OK** (it was FAIL and waived four-way); its baseline waiver
now reads stale, and that ratchet fires in candor-spec, not here. New `AdvisoryBoundProcessTests` (19
rows, 9 of them mirrors that pass on the unmodified build); 554 tests, smoke 108, fuzz 25 seeds,
fabrication-probe clean; PART 27 all-swift-OK and the four-way suite otherwise unchanged.

KNOWN RESIDUAL, stated rather than papered over: when `fix-gate` withholds a plan it drops the CROSSING
from `remedies` along with it — `remedies[]` has no shape for a crossing without a plan, where the
single-function `fix` does. The compensating channel is the one §3.2 names: `ok` is omitted,
`unevaluated` names the rule, and `--strict` exits 2, so no consumer can read it as clean. Not reached
on either real corpus (0 remedies withheld in 288 paired runs).

*(Amends the `conditional` note below: "there is no unanswerable narrowing to disclose" was true of the
HYPOTHETICAL surface candor-swift does not ship, and remains so — but the REPORT route does have one,
and `fix` now answers `unanswerable` rather than `not-forbidden` when it hits it.)*

### measured, no change — ⟨0.24⟩ `violations[].conditional` is N/A for candor-swift (2026-08-01)

SPEC §3.1 pins `violations[].conditional: "<the narrowing left unevaluated>"` (candor-spec `6f30540`,
corrected by `901f14d`), and it is rust-only. Measured here before building anything, because the pin is
a **`whatif` output** and candor-swift ships no `whatif`:

- Verified against rust's OUTPUT, not a description of it —
  `candor-query whatif cap_from_name Net --policy 'deny Net[unknown-host]' --json` emits
  `violations[0].conditional: "the \`Net\` you introduce reaches destination class unknown-host"`, a
  per-violation STRING, and the bare `deny Net` control emits the same document with the key absent.
- candor-swift's verb set is `path tour gains fix fix-gate unverified privacy-manifest gate parsepolicy`.
  `whatif` is not among them and exits 2 (AGENTS.md already points the general read-only queries at
  `candor-query`/`candor-ts-query`); SPEC §3.1 makes the query verbs SHOULD and names candor-swift's
  subset explicitly.
- **And no other surface here asks the question.** `conditional` exists because a hypothetical has no
  destination or reason class for a narrowing filter to quantify over, so the filter cannot be evaluated
  and the fail-closed verdict rests on an unevaluated condition. Every candor-swift verb reads a
  signature that EXISTS: `fix <fn> <Effect>` over an effect the function does not have answers
  `crossing: false, reason: does-not-perform` rather than charging a hypothetical, and after the
  `deny Net[…]` fix above a narrowed rule over a REAL `Net` is EVALUATED (`reason: not-forbidden`), not
  deferred. There is no unanswerable narrowing to disclose, and emitting the field anyway would assert a
  condition the analysis did not leave open.

No code change. Recorded so the next pass does not re-open it.

### fixed — and `deny Net[…]` was the same defect again, one field over (2026-08-01)

`DenyRule.netClasses` had the identical shape to the `unknownClasses` defect below: parsed, populated,
and read by neither `deniedLayer` nor `unverifiedHoleRule`. Same verb pair, same two directions.
MEASURED on `deny Net[unknown-host] app` over a report whose only Net reaches a `known-partner` host:

| verb | before | |
|---|---|---|
| `gate` | exit 0 | correct — the destination class is excluded |
| `fix-gate --strict` | exit 1 + a remedy naming `app.callPartner` | OVER-CHARGE: a hoist instruction for a boundary the policy does not deny |
| `unverified --strict` | exit 0, `ok: true` | UNDER-REPORT: an `Unknown`-carrying passer goes unnamed |

**What made this one different, and it was the whole of the work.** A reason class is DERIVED from
fields the records already carried (`unknownWhy` + `direct` + `calls`, §6.2's own resolution). A Net
destination class cannot be: it is a function of the host literal surface and the project's
`net-partner` set, and neither travels on a `FixFn`. So it is THREADED — the report's own ⟨0.20⟩
`netClass`, read verbatim the way `gate --report` reads it, on records where the field is
**non-defaulted** so no construction site can silently rebuild the bug. No second fixpoint: the
producer writes `netClass` from the already-accumulated host surface, so the transitive answer *is* the
field's value, and re-deriving it could only disagree with the gate.

An empty class set means NOT-forbidden, for destinations as for reasons — the disclosing direction for
both callers, and the same withholding `evaluateGate` performs. The unfloored/floored reason-class split
is untouched (the matcher takes the unfloored map, `--class` keeps the floored one).

MEASURED A/B, pollen and candor-swift's own `Sources`, 6 policies × 3 verbs × 2 corpora:

- **Gate verdicts moved: 0.** All 12 `gate` cells byte-identical, and all 4 scan-route `--policy` runs
  exit-identical. This changes what is disclosed, not what is decided.
- **Holes no longer named: 0.** Every A/B cell, both corpora.
- **Holes newly named: +49** on pollen under `deny Net[known-partner]` (410 → 459) — Unknown-carrying
  functions the narrowed rule PASSES, which `unverified` had been certifying clean. Same +49 on the
  scan-time note.
- **Remedies withdrawn: 6** (pollen, `deny Net[known-partner]`, exit 1 → 0), against a `gate` that exits
  0 on the same report and policy. Those were hoists proposed for a boundary the policy does not deny.
- **Unnarrowed policies byte-identical**: `deny Net`/`deny Exec`, `pure`, `deny Unknown[dispatch]`.

Reachable before this fix and much more so after it, so fixed with it: `ruleUpgrade` reconstructed a
rule from `effects` + `scope` alone, dropping every narrowing filter. Under `deny Net[unknown-host] app`
it told the operator their rule was `deny Net app` and offered `deny Net Unknown app` as the fix —
an edit that **silently widens the Net denial from one destination class to all of them** while
presenting itself as the addition of one token. 408–410 rows per pollen run carried that. Each term is
now spelled with its own filter and the upgrade widens the `Unknown` term alone, byte-for-byte the rust
reference's `rule_and_upgrade` (PART 12d pins the two against each other) — which subsumes and replaces
the raw-line source form the entry below introduced.

Pinned by `ScopedNetRemedyProcessTests` (14 rows: 2 gate controls, and every "must now be silent" paired
with a "must still fire", including the absent-`netClass` row where the gate's answer is a refusal).
Suite 535 passing (3 module-const rows still expected failures); smoke 108/108; fuzz 25/25;
fabrication-probe clean; conformance PART 27 green, 16 live swift cells OK.

### fixed — a class-scoped `deny Unknown[…]` meant something different to `fix-gate` and `unverified` than to the gate (2026-08-01)

`DenyRule.unknownClasses` was parsed and populated, and **neither `deniedLayer` (the `fix`/`fix-gate`
crossing predicate) nor `unverifiedHoleRule` (the provable-purity predicate) consulted it.** Both read a
narrowed rule as the bare `deny Unknown`, and off that one missing conjunct they broke in OPPOSITE
directions. MEASURED on `deny Unknown[reflect,unresolved] app` over a report whose only hole is
`native:dlopen`:

| verb | before | |
|---|---|---|
| `gate` | exit 0 | correct — the class is excluded |
| `fix-gate --strict` | exit 1 + a remedy naming `app.nativeHole` | OVER-CHARGE: a red CI check and a hoist instruction for a boundary the policy does not deny |
| `unverified --strict` | exit 0, `ok: true` | UNDER-REPORT, and the worse half |

The second is why both halves are one change. The layer PASSES the function while it still carries an
`Unknown` — that IS a pass-but-Unknown hole — and `unverified`, the verb whose entire job is to say a
green gate is not provably green, returned a green of its own. Fixing only the fabrication would have left
its silent mirror standing.

Both predicates now go through one `ruleForbids`, taking the function's TRANSITIVE reason classes
(`unknownWhy` now rides on `FixFn`, non-defaulted). An empty class set means NOT-forbidden — matching
`evaluateGate`, which withholds a scoped rule rather than charging on a default — and that is the
disclosing direction for both callers: `fix-gate` withholds a remedy the gate would not charge, and
`unverified` reads "not forbidden" as "this layer passes it" and names the hole. The map is UNFLOORED for
matching and stays FLOORED for `--class` filtering; each is the conservative choice for its own question.

MEASURED, pollen (`~/git/pollen`, 459 Unknown-bearing functions) and candor-swift's own `Sources` (54):

- **The partition is now exact.** Every Unknown-bearing function is either a gate violation or a disclosed
  hole. Before: up to **459** functions (pollen) and **54** (self) were NEITHER — silently certified.
  After: **0**, on all 7 narrowed policies tested.
- **Zero real disclosure loss.** Every function the gate charges is still covered by a remedy — uncovered
  = 0, before and after. The remedies that disappeared (up to 292 on pollen) were all for functions the
  gate does not charge.
- **Unnarrowed policies are byte-identical** — `pure`, `deny Exec`, `deny Net Exec Fs`, `deny Unknown`,
  and `deny Unknown[dynamic]` (which expands to every genuine class, so it is the convergence control).

Reachable only through this fix, and so fixed with it: `ruleUpgrade` reconstructed a narrowed rule with
its class filter dropped and appended a second token, offering the operator `deny Unknown Unknown app` as
the edit that fixes their gate. A narrowed rule's source form is now the raw line and its upgrade is that
rule UNNARROWED.

Pinned by `ScopedUnknownRemedyProcessTests` (12 rows: 2 gate controls so the comparison cannot go vacuous,
and every "must now fire" paired with a "must still be named"). Four-way conformance OK incl. PARTs 12b
and 27.

### fixed ⚠ — a rebound `Process` program reported BOTH commands (2026-08-01)

The command surface was a union of every locator write to a handle, with no notion of one write killing
another:

```swift
p.executableURL = URL(fileURLWithPath: "/bin/sh")
p.executableURL = URL(fileURLWithPath: "/bin/zsh")
try? p.run()                                    // reported cmds: ["/bin/sh", "/bin/zsh"]
```

Only `/bin/zsh` can run, so `/bin/sh` sat on the surface for an execution that does not exist and
`allow Exec /bin/zsh` failed on it. FAIL-CLOSED — a spurious failure, never a missed one — so a false
positive rather than the cardinal sin.

It was worth fixing because the engine's two locator mechanisms disagreed about one shape: the
URL/URLRequest path WITHHOLDS on a straight-line rebind (`u = URL(…)` enters `movedNames`, no host is
claimed) while this path unioned. Withholding here instead would have cost every ordinary single-write
`Process` its command.

A write W now kills an earlier write V iff **W's enclosing statement list is V's list or an ancestor of
it** — "control reaching past W has passed through W and can no longer be carrying V". Deliberately NOT
collapsed, each pinned by its own test: a conditional second write (`if c { p.launchPath = … }`), a pair
inside a block read from outside it, and anything across a closure boundary. `execLocatorInvisible` is not
subject to the kill either — a literal that dominates an unreadable write does overwrite it, but that is
the one direction here that turns a refusal into a claim, and its only support would be the dominance
argument being introduced in the same change.

A/B: **zero field diffs** across pollen, swift-syntax and candor-swift's own sources (8.5k functions) — no
command, host, path or effect moved on any real code; the shape is rare, which is also why it survived.

### fixed ⚠ — ⟨0.24⟩ `unverified --strict` and `fix-gate --strict` certified an INCOMPLETE report (2026-08-01)

SPEC §3.2 ⟨0.24⟩ (candor-spec `0075987`). The gate has honoured the ⟨0.21⟩ completeness manifest for three
rungs — `ok` requires no violation AND a complete analysis, and an incomplete-but-clean report exits 2.
Nothing else did. candor-ts measured the same hole in its MCP `candor_gate`; this engine ships no MCP and
no LSP, so the equivalent surfaces are its other machine-output verbs, and two of them had it. Measured,
one report declaring one `unanalyzed` unit, one policy that finds nothing:

    gate --report R --policy P          exit 2    ok:false   incomplete:true + the manifest
    unverified --strict …               exit 0    ok:TRUE
    fix-gate   --strict …               exit 0    ok:TRUE

`--strict` is how CI consumes both, so a pipeline running `unverified --strict` over a partially-parsed
tree got a green from the verb whose whole job is "not PROVABLY clean".

**The shape is `whatif`'s, not the gate's: `ok` is OMITTED.** These verbs are advisory, and their
`ok: false` does not mean "did not certify" — it means "a hole/crossing EXISTS, here it is". A `false`
beside an empty `unverified`/`remedies` array would assert a finding the run never made, which is the
fabrication mirror and worse than the `true` it replaces; `true` over a knowingly partial universe is the
over-claim. So `incomplete: true` plus the manifest take the field's place, `if (r.ok)` reads falsy and
fails safe, and `--strict` exits **2** rather than the 1 that would claim a finding. The arrays still ship:
a partial answer that says it is partial beats a refusal. The gate keeps `ok: false`, unchanged — there the
`false` is a statement, not an invention.

A COMPLETE report is byte-identical to before, asserted in the same test.

### changed ⚠ — ⟨0.24⟩ `policyVocabulary.aliases` is an OBJECT, mapping each alias to its classes (2026-08-01)

SPEC §3.1 ⟨0.24⟩ (candor-spec `7f5b5ba`). This engine emitted `aliases: ["corp"]`, as did rust and java;
candor-ts emitted `{"corp": ["reflect"]}` and is right. The ruling did not go to the majority because it
was argued from §3.1's own sentence: `configSources: [path]` is rejected there because *a disclosure that
names the source but not the content leaves the reader knowing they were affected and not how* — and the
array of alias NAMES fails that same test one level down. Measured here, one unchanged policy line
`deny Unknown[corp] app` over one unchanged report whose only hole is `native:`:

    unknown-alias corp = reflect           exit 0      disclosed  aliases: ["corp"]
    unknown-alias corp = reflect,native    exit 1      disclosed  aliases: ["corp"]

Two different gates, one identical disclosure — so a reader diffing the two verdicts saw the exit flip with
nothing in the document accounting for it, and had to open the config file the disclosure exists to save
them opening. The value is now `{"corp": ["reflect"]}` / `{"corp": ["native","reflect"]}`.

A strict SUPERSET: the key set is exactly the array it replaces, so a consumer that only wanted the names
still has them. `config` is unchanged, and the block is still emitted only when a vocabulary was actually
consumed. Both gate routes build it from one shared function (`consumedAliasVocabulary`) — §3.1's
byte-equality between `scan --policy` and `gate --report` is a MUST, and this field's own history is what
two independent constructions of one disclosure cost.

### fixed ⚠ — a shadowed `Process` binder named the outer handle's program (2026-07-29)

The exec locator maps are keyed by NAME and body-wide. A `let p` inside a block SHADOWS an outer handle,
writes its literal under the same key, and the outer `p.launch()` below the block then reported a program
that handle was never given:

```swift
func spawn(make: () -> Process) {
    let p = make()                                          // locator unknown, never written here
    if true { let p = Process(); p.launchPath = "/bin/x" }  // a DIFFERENT binding
    p.launch()                                              // reported cmds: ["/bin/x"]
}
```

`allow Exec /bin/x` certified that call. Neither existing guard covers it: a shadow is not a reassignment,
so the move pre-pass records nothing, and the outer handle takes no write at all, so `execLocatorInvisible`
raises no refusal. The gate is now the binder COUNT — a name with more than one binder site in the unit
(the function's own parameters counted) is not a name a body-wide literal claim can be made about — and it
sits at the READ, so the suppressing half stays monotone.

`NameKeyedStateTests.disposition` said this map was safe because "a rebind of the handle is already
recorded in `movedNames`". True of a rebind, false of a shadow BINDER; the note is corrected in the same
commit, because the argument for keeping the map was resting on the premise that was wrong.

Measured cost: **zero rows** across pollen, applike, AppTarget, candor-swift and swift-syntax (8.6k
functions — no host, command, path or effect losses). The one shape it does cost is two DISJOINT bindings
sharing a name in sibling branches, where the per-function union would have been right — pinned as
`testKnownCostSiblingScopeHandlesShareANameAndBothAreRefused` so a future scope-aware refinement shows up
as a deliberate change rather than passing unnoticed.

### fixed ⚠ — the singleton FIELD had no type, so the call on it was silent-pure (2026-07-29)

Found by the A/B for the locator work, not looked for. A stored property's type came from its ANNOTATION,
or from a ctor CALL in its initializer. The dominant Apple-platform spelling is neither —
`private let session = URLSession.shared` is a member ACCESS — so the field stayed untyped, every call on
it missed κ and resolved to no unit, and the enclosing function read **silent-pure**. On a realistic
target, three network-performing methods were absent from the report altogether. No amount of host or
command extraction reaches this: the effect itself was never charged.

The same inference already existed for a LOCAL binding — `SINGLETON_ACCESSORS` is in the classifier and its
comment says `let d = UserDefaults.standard` carries the type. Only the field case was missing.

The inference is `Type.member : Type`, true for the canonical singleton accessors and NOT in general, so it
is guarded by that existing allowlist plus a bare-uppercase-identifier base. A `static let logger: Logger`
on a local type would otherwise type the field as its OWNER and resolve calls to the owner's methods,
fabricating whatever those do — the mirror fixture for exactly that was confirmed to FAIL when the
allowlist is removed, so it is not a vacuous control.

Measured A/B: pollen gained **5 new report entries and 29 enlarged effect sets, with zero losses**. Traced
to ground truth: a SwiftUI card holding `MedicationStore.shared` calls `store.log(…)`, which calls
`saveEntries()`, which writes to `UserDefaults` — a real disk write, reported as pure. `MedicationStore`
declares `public static let shared = MedicationStore()`, so the type premise holds exactly.

### fixed ⚠ — locator provenance 3/3: the property write that names the program (2026-07-29)

`Process()` takes no command. The program is named by a property WRITE (`p.launchPath = "/bin/sh"`,
`p.executableURL = URL(fileURLWithPath: …)`) and executed by `p.run()`/`p.launch()`, which take no argument
at all — so the direct-argument rule saw no literal anywhere on the Foundation subprocess surface. EVERY
`Process` form yielded no `cmds`: `allow Exec` failed closed over all of it, and the `classifyCommandHead`
cliff refinement (a visible `curl` reaching `Net`) never fired. The write is now carried forward to the
launching verb.

**The launching verb also marks `Exec` INCOMPLETE when it cannot read the program, and that half is not
optional.** Before this mechanism the surface was always empty and `allow Exec` failed closed *by accident*.
The moment a literal can be captured, a benign visible `/bin/sh` would otherwise COVER for a runtime
program spawned beside it and certify the whole function — the AS-EFF-008 masking evasion, and the precise
way this work could have made the gate quieter. Marking it changes nothing for the all-invisible case an
empty surface already refused. Pinned directly and transitively.

**The A/B found a fabrication in this mechanism that all 25 fixtures had passed.** A `SequenceExpr` is
FLAT — the parser gives `p.launchPath = "/usr/bin/" + tool` as `[lhs, =, "/usr/bin/", +, tool]` — so reading
the element after the `=` yielded the literal `"/usr/bin/"` and reported *that* as the program, which
`allow Exec /usr/bin/` would then have certified for an entirely runtime command. It surfaced on a negative
control written into the corpus, not in a unit fixture; the remainder is now re-wrapped and handed to the
resolver that already knows how to refuse it. Three fixtures were added from that one finding.

Measured A/B (4 corpora, 8 568 functions): **12 functions gained a command surface** — `/usr/bin/iconutil` in pollen's icon
tool, `/bin/sh` across candor's own soundness fixtures, `/usr/bin/git`/`curl`/`iconutil` in the app target —
`+1 Net` from a command-head refinement, and **zero losses of any kind**. swift-syntax's `ProcessRunner`
(`process.executableURL = executableURL`, a parameter) correctly gained nothing: a real-world negative
control. Conformance four-way OK; smoke 108/108; fuzz 25/25; fabrication-probe clean.

### fixed ⚠ — locator provenance 2/3: the local the locator was bound to (2026-07-29)

The other half of the URLSession surface: `let u = URL(string: "…")!` then `dataTask(with: u)`, and the
POST idiom `var req = URLRequest(url: …); req.httpMethod = "POST"`. rust/java/ts all extract from a local
binding as well as from an inline literal. The literal now travels through the SAME const-string index the
direct form uses, so the host refinement, the ⟨0.13⟩ `Llm` classification and the privacy manifest follow
without a second resolver.

Admitting `var` — which the `URLRequest` idiom forces, since a request cannot be configured any other way —
needs a claim the walk could not previously make, because the walk is flow-INSENSITIVE: it records a
binding at the declaration and reads it at the call, in SOURCE order. A rebind later in the text (or
earlier in TIME, because the pair sits in a loop) would leave a stale literal standing and the report would
name a destination the program never contacts. So a **pre-pass** now sweeps the whole body before a single
call is collected and records every name whose value can move: a whole-name or compound assignment, an
`inout` pass, or a property write outside an allowlist of spellings proven not to move the locator
(`httpMethod`/`httpBody`/headers/caching — `url` pointedly absent). A moved name carries no claim at all,
at EVERY use, including one lexically earlier than the move.

The two pre-pass maps are classified in `NameKeyedStateTests` as `deliberatelyKept`, and for the opposite
reason to the hedges beside them: every other row there asks what a rebind does to a fact, while these ARE
the record that a rebind happened — clearing one on a rebind would delete the evidence that suppresses the
claim and leave a fabricated host standing.

Measured A/B (4 corpora): +1 host, +1 `Llm` classification, +1 `unknown-host` → `known-partner`, zero
losses of any kind. Cumulative for 1+2: **13 hosts gained, 3 destination classes named, 0 effect sets
shrank, 0 literals lost, 0 entries dropped.**

### fixed ⚠ — locator provenance 1/3: the constructor between the literal and the call (2026-07-29)

swift captured a Net host only when the literal was a DIRECT string argument of the establishing call —
`NWConnection(host:port:)`, the single idiom conformance PART 4e pins. On Apple platforms almost nothing
is written that way: `URL(string:)` interposes, so **every `URLSession` form yielded no `hosts`** and read
`netClass: ["unknown-host"]`. Three live consequences, all on the released line: a narrowed
`deny Net[known-telemetry]` passed GREEN over a `URLSession` call to `api.segment.io`; a call to
`api.openai.com` never reached the §1 ⟨0.13⟩ `Llm` refinement or the privacy manifest; and `allow Net`
failed closed over essentially all Apple-platform code. rust/java/ts all unwrap their equivalents.

`URL(string:)` / `URL(fileURLWithPath:)` / `URL(filePath:)` / `URLRequest(url:)` (and the `NS` twins) now
resolve to the locator they carry, nested and bounded, through the same const-anchored resolver the direct
form already used — so `Llm`, `netClass` and the privacy manifest all follow with no new machinery.

This moves the gate in the RELAXING direction, so the guard is an **allowlist of companion arguments**,
the exact inverse of the denylist rule that governs narrowing an over-approximation: an unrecognised label
refuses. `relativeTo:` is why — `URL(string: "/v1/track", relativeTo: base)` keeps its authority in `base`,
and reading the `string:` argument would fabricate the host `/v1/track`. A locally-declared `URL` type or
free function shadows the unwrap, as every κ entry point in this engine does.

Measured A/B (4 corpora, 8 568 functions): 12 hosts gained, 2 `unknown-host` → `known-telemetry`,
**zero effect sets shrank, zero hosts/cmds/paths lost, zero entries dropped**.

### fixed ⚠ — ⟨0.24⟩ neither §3.1 rule has a carve-out, and both of ours did (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `1503368`). **Precedence binds `forbid`/`allow` too**: measured,
`deny Fs` + `forbid app.Domain -> app.Infra` in one policy exited 2 with the certain violation absent from
the document — the identical harm the precedence rung closed, surviving under a different rule KIND,
because those two refusals returned before the report was even opened. Now exit 1, the document names the
violation, and the unevaluated rule is disclosed beside it. The refused rules are still never evaluated
(the gate is handed a deny-only policy), so no `allow` can be certified off a wire that does not carry the
AS-EFF-008 surface-completeness marker.

**And the refusal document has no exempt cause**: an unreadable policy, a report that never loaded AS one,
a broken `.candor/config` and an invalid baseline now all write the same fail-closed document
(`ok:false`, `refused:true`, the reason, no `violations` key). A stale green on disk does not care why this
run declined to overwrite it. The one case that still writes nothing is a usage error inside the flag loop,
where `--gate-json`'s value is not yet resolved — asserted, not assumed.

### fixed ⚠ — ⟨0.24⟩ the precedence fix FABRICATED a violation, and this is the half that makes it safe (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `5a8cf48`), found by implementing `7271c69` rather than by reading it.
Removing the refusal's short-circuit made the evaluator reach code it had never reached: the reason-class
matcher floored an unknown class set at `unresolved`, so a scoped `deny Unknown[unresolved]` over an entry
whose `Unknown` is INHERITED and reasonless began emitting an actual violation RECORD — in the same run
whose stderr said that rule could not be evaluated over that function. A self-contradicting document,
reachable only THROUGH the soundness fix.

    entry `app.orphanU` (inferred [Unknown], direct [], no calls), deny Unknown[unresolved]
      after the precedence commit   exit 1, violations: [{fn: "app.orphanU"}]   <- FABRICATED
      now                           exit 2, the refusal document, no violations key

That floor is the right fail-closed default for a MATCHER — "could this rule apply?" — and the wrong basis
for a FIRING — "did it?". **A fail-closed default is not portable between a predicate that GUARDS and one
that CHARGES.** The `unresolved` default is still applied, at the ENTRY (both `gateInputFromScan` and
`gateInputFromReport`), gated on a DIRECT `Unknown` the function did not name — where it composes and where
it is evidenced. The matcher now WITHHOLDS instead, per (rule, function): the same rule fires on a function
whose match its own entry evidences and is withheld on one whose it does not, in the same run, with exit 1
for what fired and a disclosure for what could not be evaluated.

### changed ⚠ — ⟨0.24⟩ the gate verdict's `coverage` block spells its name list `packages` (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `aafa021`), which pins the verdict's coverage block as
`{ "uncovered": <n>, "packages": [ … ] }` for the first time. §2 defines the *report's* ledger —
`coverage.uncovered` as an array of `{name, calls}` — and that is a different shape from the *verdict's*,
so the verdict shape was never stated and the engines diverged unobserved: rust and ts emitted `packages`,
candor-swift emitted `modules`, and §3.1's single prose mention said `modules` too, because it was written
describing this engine's output. `packages` is correct, and not because it is three-to-one: the §2 envelope
names the very same objects `package`/`packages`, so a verdict that renames them mid-document is drift, and
`module` already means a different thing in two of the four implementation languages.

**A machine consumer reading `coverage.modules` from a candor-swift verdict must move to
`coverage.packages`.** Both swift routes go through one writer, so `scan --policy` and `gate --report`
change together and §3.1's byte-equality is unaffected. NOT renamed: the `privacy-manifest --verify --json`
document's own `coverage.modules` — that is the privacy/1 extension's surface, no clause and no conformance
PART pins it, and it is recorded as the second instance of the same hole rather than renamed unilaterally.

### fixed ⚠ — ⟨0.24⟩ policy VOCABULARY anchored at the target on a scan and at the policy on a gate (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `99eb4e9`). §3.1's MUST NOT names three channels an effect must never enter
a gate through; review found a FOURTH that no engine tested — `.candor/config`'s `unknown-alias`. The two
routes anchored config discovery DIFFERENTLY (gate verbs at the policy file's directory, scan routes at the
target), so with the policy filed OUTSIDE the scan target the same rule expanded differently and §3.1's
byte-equality MUST was breakable by a file that is neither the report nor the policy. Measured, one report
+ one policy `deny Unknown[corp]`, `unknown-alias corp = reflect` filed beside the POLICY:

    gate --report R --policy P    exit 0    alias found — narrows to [reflect], no match
    scan TARGET   --policy P      exit 1    alias NOT found — widened to a bare `deny Unknown`

Vocabulary now travels with the policy that uses it: `unknown-alias` resolves relative to the resolved
`--policy` file's directory on BOTH routes. Target-scoped keys (`deps`, `net-partner`, scan settings) keep
anchoring at the target, because they describe the thing being scanned.

**And the ambience is disclosed.** When a config file supplied vocabulary that PARTICIPATED in the verdict,
the `--gate-json` document names it under `policyVocabulary: {config, aliases}` — the file AND which aliases
it supplied. Discovery walks parent directories, so an alias
file anywhere above the policy participates; a verdict changed by a file the operator cannot see named is
the ambient-input failure this format exists to refuse. Named only when an alias was actually consumed — a
config defining aliases nobody asked for is not an input to this verdict.

### fixed ⚠ — ⟨0.24⟩ an unrecognised token silently REWROTE the rule — in EVERY policy value list (2026-07-28)

SPEC §6.2 ⟨0.24⟩ (candor-spec `382a7e0`), which withdraws its own asymmetry argument — "a dropped policy
token leaves a WIDER rule standing, so the failure is loud". Measured on this engine, over a signature
whose ONLY hole class is `indirect`:

    deny Unknown[dispatch,indirct]  typo BESIDE a valid token — dropped, the rule NARROWED to
                                    `[dispatch]` and stopped gating the `indirect` hole it was written
                                    for. EXIT 0 on BOTH routes. FAIL-OPEN, and the common case.
    deny Unknown[corp]              sole unrecognised token — "candor: ignoring policy rule (unknown
                                    reason-class/alias `corp`)" printed, and then the rule KEPT and
                                    WIDENED to a bare `deny Unknown`, exit 1. A FALSE DISCLOSURE, the
                                    `net-partner` class PART 13b exists for.
    after                           both exit 2 on BOTH routes, naming the token and the accepted set.

A policy that cannot be honoured as written is not silently rewritten into a different policy. The
narrowing direction is the common case, because a typo lands beside correct tokens far more often than
alone. `parsePolicy` now returns a `ParsedPolicy` carrying `errors`; the rules still parse, so the
ADVISORY readers (`parsepolicy`, `unverified`, `fix`, `fix-gate`) are unchanged — `parsepolicy` is the
conformance suite's four-way grammar witness and its battery deliberately contains a rule with an
unrecognised token. It is the GATE routes (`scan --policy` and `gate --report`) that refuse, before any
verdict is derived and with no `--gate-json` document, so §3.1's byte-equality holds on a broken policy by
there being nothing to disagree about. A `.candor/config` `unknown-alias` still resolves.

**EXTENDED TO ALL THREE VOCABULARIES** after candor-spec `be0b9a9` widened the ruling (it had said
"reason-class" only because a reason-class token was what the review measured, and the argument in it never
mentioned which vocabulary the token belonged to). Both siblings are live fail-opens:

    deny Net[known-partner,unknown-hosst]   narrows to [known-partner] — exit 0 where the correctly
                                            spelled rule exits 1
    unknown-alias house = dispatch,indirct  the DEFINITION becomes {dispatch}; the policy line
                                            `deny Unknown[house]` reads perfectly well and gates nothing

The second is the quietest of the three: the typo is in the vocabulary the policy is written AGAINST rather
than in the policy itself. Reserved-NAME rejection (`unknown-alias reflect = …`) is a different rule and
stays warn-and-skip, pinned four-way by conformance PART 4.

### fixed ⚠ — ⟨0.24⟩ a refusal wrote NO `--gate-json` document, so CI re-read yesterday's green (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `107755b`). The canonical CI wrapper is
`candor-swift gate … --gate-json v.json || true` then `jq .ok v.json`. Seed `v.json` with a green document
from a previous clean run, then refuse:

    before   exit 2, v.json UNTOUCHED — `jq .ok` returns the stale `true`
    after    v.json = {spec, ok:false, refused:true, reason:"…"} — `jq .ok` returns false

Deleting the path is not the fix: a consumer that treats a missing file as "nothing to report" fails open
by a different route. The naive read of a document this format emits has to be the safe one, because the
naive read is the one that ships. The document carries **no `violations` key**, and that absence is the
load-bearing part — the gate is making no claim about violations, and `[]` is precisely the claim it
cannot make. All three answerability refusals (`forbid`, `allow`, a scoped `deny` whose scoping datum is
absent) take it, on `--gate-json <path>` and on `--json`. A broken gate CONFIG or a report that never
loaded AS one still writes nothing (§3.3 cause (a)) — there the input to the verdict is unreadable, so
even `refused: true` would attribute a refusal to a policy nobody could parse.

### fixed ⚠ — ⟨0.24⟩ a refusal standing beside a FIRING rule DELETED the certain violation (2026-07-28)

SPEC §3.1 ⟨0.24⟩ (candor-spec `7271c69`), which corrects its own ruling of an hour earlier. The
precedence is **violation (1) > refusal (2) > incomplete (2)**, and the first rung is forced by Lemma 2
rather than chosen: if a rule FIRES on evidence the report carries the policy is Rejected, and `Reject` is
upward-closed, so however an unanswerable rule would have resolved cannot un-reject it. Measured on a
two-entry report, one policy:

    deny Fs                                        exit 1   document names `app.writes`
    deny Net[unknown-host] app                     exit 2   no document (the entry has no netClass)
    BOTH IN ONE POLICY                             exit 2   NO DOCUMENT AT ALL          <- pre
    BOTH IN ONE POLICY                             exit 1   document names `app.writes` <- post

The harm was **in the document, not the exit code**: the refusal ran before the gate did, so the verdict
that would have named the certain violation was never computed, and the finding vanished from every
machine channel. Byte-identical in harm to the ⟨0.21⟩ incomplete-analysis path one rung down, and the
same fix — compute the verdict first, decide the exit from it. The refusal is **not swallowed**: every
unanswered rule is still named on stderr beside the verdict it is not part of. A refusal with no firing
rule beside it still exits 2, unchanged.

### fixed ⚠ — ⟨0.24⟩ a CORRUPT chained dep entry was skipped, so the calls it answered read PURE (2026-07-28)

The sibling of the `gate --report` rung below, one layer over, found while verifying it. This file's own
header already states the principle — a dep report that does not parse FAILS the run, because "silently
skipping either would make every call into that dep read pure" — and `(e[k] as? [Any]) ?? []` plus a
`continue` on a missing `fn` undid it one entry down. Measured on the two-tree fixture (dep `hit()` reads
`/etc/hosts`, app `go()` calls it, `deny Fs`), the dep's one entry doctored:

    intact dep report   go -> ['Fs']                     exit 1   the gate catches it
    unchained control   go -> invisible: ['RatesDep']    exit 0   the honest hedge
    `fn` key deleted    go -> ABSENT from `functions`    exit 0   a ⟨0.21⟩ PURITY CLAIM
    `inferred: [1]`     go -> ABSENT from `functions`    exit 0   a ⟨0.21⟩ PURITY CLAIM

Both corrupt arms are **strictly more confident than not chaining the package at all**, over a function
the dep report was trying to say was effectful. A dep entry with no readable `fn`, or with a §2 list key
that is present and is not a list of strings (`inferred`, `hosts`, `cmds`, `paths`, `tables`, `invisible`,
`incomplete`, `unknownWhy`), now FAILS the run (exit 2) naming the report — the posture the loader already
takes for a report that does not parse at all. An **absent** optional key still takes its default, pinned
by its own control: an entry carrying only `fn`, `hash` and `inferred` still joins.

### fixed ⚠ — ⟨0.24⟩ a `gate --report` key that is PRESENT but unparseable was coerced to its empty value (2026-07-28)

SPEC §2 ⟨0.24⟩ (candor-spec `38ba3e2`). The shape that generalises the count-0 and missing-`functions`
rungs is *a reader that recovers from a type mismatch by substituting the default* — and on every key in
this format that default is the PERMISSIVE value (`0`, `[]`, absent), so the coercion converts corrupt
input into a claim, and the claim is always the safe-looking one. Measured before, `deny Net` over a
one-entry report, all four binaries rebuilt at HEAD:

    entry with NO `fn` key, `inferred: ["Net"]`   rust 2   ts 2   java 2   swift 0   <- silently dropped
    entry with `inferred: [1]`                    rust 2   ts 0   java 0   swift 0   <- three fail open

The first row is the cardinal-sin shape exactly: a CORRUPT entry silently became an ABSENT one, and under
⟨0.21⟩ absent is a positive purity claim about a function the report was trying to tell you about. Now
each is a refusal (exit 2) naming what could not be read: `fn` must be a non-empty string; a §2 list key
that is PRESENT must be a list of strings (`inferred`, `direct`, `calls`, `hosts`, `cmds`, `paths`,
`tables`, `netClass`, `unknownWhy`); `unanalyzed` and `coverage` must parse.

`unanalyzed` is the sharpest of them, because its **non-emptiness IS the fail-closed trigger**: read as
empty, `NOT certified` (exit 2) becomes `policy ✓` (exit 0). Both spellings the spec measured now refuse —
a bare string list (`["src/broken.swift"]`, which all four engines dropped) and a non-list.

An **absent** key still takes its documented default, and that separation is pinned by its own control: a
minimal entry carrying only `fn` and `inferred` gates normally in both directions. Conflating absent with
present-but-unparseable would refuse every legitimate report.

### fixed ⚠ — ⟨0.24⟩ `gate --report`'s reason-class refusal was OVER-BROAD, and named the wrong function (2026-07-28)

SPEC §3.1 ⟨0.24⟩ names this engine's refusal by name. **The refusal is MINIMAL, and monotone denial is
what makes that safe**: a class-scoped `deny` is not unanswerable merely because some evidence is missing,
because the class set only ever GROWS (§6.2 — a reason is *contributed*, never retracted) and `Reject` is
upward-closed in it. When the classes determinable FROM THE ENTRY ALONE already intersect the filter, the
rule FIRES and no further evidence could change that.

A reasonless **DIRECT** `Unknown` contributes `unresolved` from the entry alone, with no transitive step —
so `deny Unknown[unresolved]` over it is answerable. Measured four-way on a one-entry report, all four
binaries rebuilt at HEAD:

    deny Unknown[unresolved]              rust 1   ts 1   java 1   swift 2   <- over-broad
    deny Unknown[unresolved] app.direct   rust 1   ts 1   java 1   swift 2   <- and with a scope

Exit 2 is not wrong in the fail-closed sense; it is a **worse answer than the correct one**, and a verb
whose value is being a pure function of its input should not decline questions it can answer.

**And the remedy pointed at the wrong function.** Over a report with three `Unknown` carriers — one direct
and reasonless, one inheriting through a `calls` edge to it, one inheriting from nowhere the report names
— `deny Unknown[dispatch,unresolved]` refused naming `app.inheritU` where rust, ts and java all name
`app.orphanU`. Same exit code, and the only actionable part of the message was wrong. Both halves are one
fix: `unresolved` is now contributed at the ENTRY, before the fixpoint, so `app.mystery` and (transitively)
`app.inheritU` both have non-empty class sets and the refusal falls through to the one entry whose reason
channel really is missing. The refusal predicate itself is unchanged.

Contributing at the ENTRY rather than at the join is what makes it COMPOSE: a caller of one reasonless
entry and one `dispatch:` entry accumulates `{unresolved, dispatch}` and is caught by both filters — the
§6.2 counterexample in which *adding* a call turned a red verdict green. It is gated on a **direct**
`Unknown` the entry did not name, never on the reason set being empty, because emptiness is also what an
inherited `Unknown` looks like and marking those is the mirror fabrication. Same shape as candor-rust
`gate.rs` and candor-java `Loader` (`82bf4d4`).

One pre-existing fixture moved with it: `testScopedUnknownDenyWithNoReachableReasonIsRefused` posed
`direct: ["Unknown"]` (the test helper defaults `direct` to `inferred`) while its prose said "an Unknown
with neither its own `unknownWhy` nor a `calls` edge". Those are two different states and ⟨0.24⟩ separates
them; the fixture had picked one spelling of two, and now poses the inherited one it meant.

### fixed — ⟨0.24⟩ `gate --report` over a count-0 report printed `policy ✓` and nothing else (2026-07-28)

SPEC §3.1 ⟨0.24⟩, as corrected in candor-spec `0744d29`. A report presented DIRECTLY to the gate with
`analyzed.count: 0` makes the same claim as a chained one — it judged nothing, so it licenses no purity
claim — and the verb MUST say so. Measured before, on a count-0 report with `deny Net`:

    exit 0, stdout empty, stderr exactly `candor-swift: policy ✓`

**The exit code and the verdict document are UNMOVED, deliberately.** §3.1 makes byte-equality with
`scan --policy`'s `--gate-json` the acceptance test and a scan of an empty facade package exits 0 with a
clean verdict, so diverging would split the verb this rung exists to keep single; §3.3 enumerates exactly
two exit-2 causes (a broken gate CONFIG, an INCOMPLETE analysis of the target's own code) and a
judged-nothing dependency is neither. And a verdict is an ASSERTION — the consumer has no evidence of any
effect here, so manufacturing one would be the fabrication mirror of the silent under-report. What was
missing was the human channel: `analyzed.count: 0` already rode the machine one. So a caveat now goes to
stderr naming the locator, and byte-equality is re-verified (12 policies).

The unreadable-manifest rows reach the same caveat, because a claim that cannot be READ is not a claim. And
they no longer reach the verdict: an unreadable `count` contributed to the document's own `analyzed.count`,
measured at **`count: true` -> `analyzed: {count: 1}`** and **`count: -1` -> `analyzed: {count: -1}`** — a
fabricated number in the machine channel, the mirror of the missing disclosure. Both are now `0`.

### fixed ⚠ — ⟨0.24⟩ `analyzed: {count: true}` read as JUDGED — a BOOLEAN is not an integer (2026-07-28)

SPEC §2 ⟨0.24⟩ names this engine for it. Foundation bridges a JSON `true` to `__NSCFBoolean`, and
`__NSCFBoolean as? Int` **succeeds with `1`** — so the manifest reader took `{count: true}` for "one unit
judged" and granted the package **full coverage, byte-identically to `count: 2`**. The caller into that
package then dropped out of `functions` entirely: a ⟨0.21⟩ **positive purity claim licensed by a manifest
that made no readable claim at all** — the fabrication mirror of the rung directly below, arriving through
a language's type bridge rather than through a logic error.

Measured on the two-tree fixture (dep report doctored to `functions: []`, app calls an API the dep never
listed), one row against its own control:

    count: 2                     goUnlisted -> ABSENT from `functions`   (correct: an all-pure claim)
    count: true   pre            goUnlisted -> ABSENT from `functions`   <- indistinguishable
    count: true   post           goUnlisted -> invisible: ['RatesDep']   + κ ledger + advisory

The rejection is made **before** the integer cast and on the number's own type tag (`objCType == "c"`,
which is the boolean spelling on Darwin Foundation *and* swift-corelibs-foundation), because no test on
the *value* could separate them — `count: 1` and `count: true` are the same number. `count` must be a
**non-negative integer**: a boolean, a fraction (`2.5`), a negative, a string or a missing `count` are all
**present-but-unreadable**, which is not a claim, so coverage is withheld. `2.0` is a legitimate JSON
spelling of `2` and is still believed — the anti-flood control for the numeric half.

The predicate is now **one function** (`claimsToHaveJudgedNothing`) shared by the chained-dep route and
`gate --report`, so the two cannot drift into two readings of one integer. Seven new rows in the shape
table, the boolean one verified to fail before the fix.

### fixed ⚠ — ⟨0.24⟩ a chained report that JUDGED NOTHING no longer reads as an all-clear (2026-07-28)

SPEC §2's three-row table. A chained dependency report carrying `functions: []` **and**
`analyzed.count: 0` bought a consumer **more confidence than not chaining the package at all**: every
call into it dropped out of `functions`, which under ⟨0.21⟩ is a positive purity claim, with no advisory
in either channel — while the same scan with **no dep report** correctly discloses `invisible` +
`coverage.uncovered` + the κ nudge. A silent under-report, and conformance PART 26 measured it in all
four engines (64 live cells ABSENT here).

Measured, two-tree fixture (dep `hit()` reads `/etc/hosts`, app `go()` calls it, `deny Fs`):

    unchained        go -> invisible: ['RatesDep'], coverage.uncovered, κ nudge   exit 0
    trusted          go -> ['Fs']                                                 exit 1
    count: 0   pre   go -> ABSENT from `functions`, no coverage, no advisory      exit 0
    count: 0   post  go -> invisible: ['RatesDep'], coverage.uncovered, κ nudge   exit 0

**The wire already distinguished the two cases and nothing read it.** A facade target scans to
`count: 0`; an all-pure target scans to `count: n` with the same empty `functions`. So `count: 0` now
registers into a new `unjudgedPkgs` — chained (its keys are still asked) but NOT covered, the same
treatment ⟨0.21⟩ `incompletePkgs` gets and for the same reason: coverage is the rule that turns a
report's SILENCE into a purity claim, and a report that judged nothing is all silence. Entries are
untouched; only coverage is withheld, so nothing is ever downgraded or dropped.

**The second row is the control, and a fix that hedged it too would have deleted chained coverage rather
than implemented the rule.** `count: n > 0` with an empty `functions` is a legitimate all-pure claim §2
rule 3 says a consumer SHOULD believe: unchanged, believed, no new hedge, no advisory. Both directions
are mutation-verified — forcing the count-0 arm covered turns the three FLOOR tests red and leaves the
control green; hedging both arms turns the control (and eight pre-existing coverage tests) red and
leaves the FLOOR test green.

Two reconciliations, running in **opposite** directions, because they follow what the second report
*says*. An INCOMPLETE report makes a specific negative claim about the package's source, so it beats a
complete sibling. A count-0 report makes no claim at all, so a package chained once judged and once not
**keeps** its coverage — letting an empty report withdraw an earned purity claim is the mirror sin.

Blast radius, real code: **1 report in 37** emits `count: 0` (swift-syntax's 21 modules + candor-swift's
2 + 14 soundness fixtures) — and it is swift-syntax's `SwiftSyntax-all`, a target whose only source file
is a comment saying "this is a fake target that depends on all targets". A rare facade, not half a dep
tree. PART 26 now prints `swift  SEPARATED on 24/80 cells — the engine distinguishes them`, where all
four engines printed INDISTINGUISHABLE.

### changed — ⟨0.24⟩ a `--class` value that cannot be honoured is REFUSED, not quietly narrowed (2026-07-27)

SPEC §6.2's **value grammar**, which conformance PART 27 found unimplemented in **all four** engines
rather than divergent between them — the suite's only `engine: "*"` waiver, and the last thing holding
the floor below 0.24. `--class <c>[,<c>…]` takes ONE comma-separated list of the six reason classes plus
the aliases `dynamic` and `*`. Two things that used to exit 0 on `unverified --class` (this engine's only
`--class` consumer — there is no `blindspots` or `callers` verb here) now exit **2**:

- **an unrecognised token.** `--class dyanmic` printed `--class ignores unknown reason-class …` and
  carried on with whatever was left of the list — for a one-token list, an EMPTY filter. It now names the
  token and lists the accepted set. `*` is also honoured only after the whole list is walked, so
  `--class *,dyanmic` reports the typo instead of short-circuiting past it.
- **a repeated `--class`.** It was last-wins, silently discarding the first list. A second occurrence is
  a usage error, not a union — and not last-wins either.

**Why the query side refuses what the policy side drops**, since the asymmetry reads as an inconsistency
until it is written down: a token dropped out of `deny E Unknown[reflect,dyanmic]` leaves the **wider**
rule standing, so the mistake is loud — the gate over-fires and somebody comes to look. The same token
dropped out of `--class` leaves a **narrower** filter, and a narrower filter on `unverified` comes back
as a **smaller number**, indistinguishable from a real all-clear in the one verb whose whole job is to
say "green, but not provably so". A refusal also emits **no answer document at all**; a narrower result
one exit code away from a refusal is the same fail-open in a different hat.

`parseClassFilter` now throws `ClassFilterUsageError` rather than warning, so the rule lives in one
place. Nothing changes for well-formed input — the new suite pins the unfiltered baseline and each
filter's exact selection alongside the refusals.

### added — ⟨0.24⟩ `ambiguous:` is a fifth §4 kind: candor-swift already conformed; the controls did not exist (2026-07-27)

SPEC §4's `unknownWhy` kind set gains **`ambiguous:`** — name resolution was ambiguous, so no owner could
be formed at all. §4 ⟨0.24⟩ warns that an engine holds this vocabulary **twice** (a prefix/string
classifier feeding §6.2's class table, and a typed/structural one) and that when §4 goes stale the string
half stays right while the typed half does not — measured on the reference JVM engine, where one token
classified `dispatch` on the string path and `unresolved` on the typed path, silently.

**candor-swift holds it ONCE.** `reasonClass(_:)` (Policy.swift) is the only representation: an
`unknownWhy` token is a raw `String` from its emission site to the JSON writer, with no `Kind` enum, no
union, no accepted-prefix set and no validator anywhere in `Sources/`. Its `dispatch` arm has covered
`ambiguous` since the ⟨0.19⟩ reason-scoped rung. So the JVM failure mode is structurally unreachable here
and **nothing in production changed** — no report byte, no gate verdict. `dep:<hash>`/`dep-stale:<pkg>`,
which §4 ⟨0.24⟩ registers as permanent kinds rather than migration ones, sit in no migration bucket
either: this repo has none, and they project to `unresolved` exactly as the spec prescribes. The two
places the kind set could have drifted in prose — `AGENTS.md` and `README.md` — never restate it; they
give two examples of a reason, which is not a set.

**What was missing is the control §4 ⟨0.24⟩ asks for**, and its absence is the whole point of the clause:
without it, "added a fifth kind" and "stopped checking the kind set" are the same diff. Added at both
levels, over the path this engine can actually meet the kind on — it EMITS no `ambiguous:` (its producers
are `dispatch:`, `callback:`, `dynamicMemberLookup:`, `contentsOf:` and the `dep:` pointers) but it
**RELAYS** one, since `loadDepIndex` carries a dependency's own tokens across the join. A fabricated
`banana:whatever` and a relayed `ambiguous:go` are driven through `scan --policy` and `unverified
--class`, the two verbs whose class sets are accumulated by two independent code paths
(`Gate.buildGateInput`, `Fix.reasonClassesTransitive`) — the divergence shape §4 describes.

Mutation-verified with four mutations, each caught by a **different** arm: the blanket catch-all →
`dispatch` fails both controls; dropping the `ambiguous` prefix fails the gate and both class paths;
recognising the token SHAPE (`contains(":")`) instead of the SET leaves every gate arm of the
`ambiguous:` test green and is caught only by the fabricated kind; and normalising the relayed token to
its class is caught only by the round-trip arms.

### added — ⟨0.24⟩ `gate --report`: the gate as a function of a GIVEN signature (2026-07-27)

    candor-swift gate --report <locator> --policy <file> [--json] [--gate-json <f>]

SPEC §3.1's ⟨0.24⟩ verb: apply a policy to an EXISTING report, with **no scan**. Exit codes and verdict
shape are exactly `--policy`'s on a scan (0 / 1 / 2); the only difference is where `S` and `D` come from.
`--json` **is** `--gate-json -` — the verb's machine output is the verdict, and a second meaning for
`--json` would be the one place a consumer could tell the two routes apart. A query verb, so it inherits
§3.3.1 unchanged: the same three locator forms, the same discovery and `CANDOR_POLICY`/config fallbacks,
and no positionals (a stray one is a usage error — `gate` has no argument of its own, and a swallowed
token is how a gate runs green).

Two things this buys. It is the **supply-chain verb** — gating a dependency's published report is what an
adopter actually wants and could not express without re-analysing code they do not have. And it makes the
code-implements-spec direction **testable**: every other route recomputes the effect set from source, so a
defect in the gate and a defect in the classifier were indistinguishable from any test this repo could
write.

**THE SEAM.** `evaluateGate` now takes a `GateInput` — a record of already-accumulated maps — built either
by `gateInputFromScan` (the reason-class fixpoint and the per-fn `netClassesOf` derivation, moved out of
the gate body and off `main.swift`) or by `gateInputFromReport`. There is deliberately **no second copy of
the §6.2 matching**: the clause mandating this verb exists about exactly that mistake, an open-coded copy
of a classification rule drifting from the gate's, silently, because nothing compared them.

**REPORT-LOADING.** This engine ships no `callers`/`show`/`where` (it is the producer; the read-only
queries are candor-query's), so `gate` is its first verb that CONSUMES a report to reach a verdict. The
§3.3.1 locator machinery already existed and is reused (`resolveReportLocator`, `discoverReportPrefix`,
`discoverPolicy`); the reader itself is new, because it must read **strictly less** than the existing one.

**THE MUST NOT.** §3.1: an engine must not re-derive, widen or re-classify, and an ABSENT entry is absent
— the ⟨0.21⟩ purity claim — never back-filled from a callgraph sidecar or a chained dep. `loadGateReport`
opens the report file(s) and nothing else: no `.callgraph.json` (which `loadFixModel` does merge, for
fix/fix-gate/tour/path), no `.hierarchy.json`, no `loadDepReports` chaining, and `hosts`/`cmds`/`paths`/
`tables`/`netClass` taken verbatim rather than re-matched or re-mapped through this machine's
`net-partner` config. Proved with `app.Facade.load` ABSENT from a report while three baits sit beside it:
a sidecar naming it and edging it to a `Net` unit, a chained dep report giving it `Net` outright, and a
`.candor/config` `deps` key inside the one directory the verb does open a config from. Verdict clean; the
positive control beside it (same directory, same baits, a report that DOES carry the effect) exits 1.
Both halves mutation-verified — back-filling from either the sidecar or the dep flips the clean half to
exit 1. Separately measured: gating a report written WITH a `net-partner` config, from a process whose
config has none, still produces the verdict byte-for-byte — `netClass` came off the wire.

**ANSWERABILITY — three refusals, each fail-OPEN if approximated instead.** `forbid A -> B` is refused
whole-policy: a report carries an entry only for a function with an EFFECT, so a wholly pure unit has no
entry and no edges, while `forbid` matches on NAME. `allow <E> …` is refused whole-policy: the AS-EFF-008
surface-completeness marker does not ride the wire, and `netClass: unknown-host` is not it (that token
also names a merely unrecognised host). Whole-policy in both cases because enforcing the answerable half
and exiting 0 is gateless-green. The third is per-(rule, function): a class-scoped `deny` whose scoping
datum is ABSENT on a matched entry. **Measured on this engine with the check disabled:**

    report                                    deny Net[unknown-host]   deny Net
    Net-bearing entry, netClass ABSENT        exit 0  ← green          exit 1

    report                                    deny Unknown[dispatch]   deny Unknown
    Unknown, no unknownWhy and no calls edge  exit 0  ← green          exit 1

The narrowing succeeds *because the evidence is missing* — an absence-keyed relaxation of a fail-closed
gate. Per-(rule, function) so a scoped rule whose own matches carry their evidence still evaluates; the
message names the exact `deny` line, the function, and the remedy. None of the three fires on a report
this engine wrote.

**EQUIVALENCE, and it is byte-level.** 80 rows over four corpora — candor-swift's own `Sources` (526
analyzed fns, 20 policies, up to 95 violations), a reason-class fixture, a host-literal fixture with a
`net-partner`/`unknown-alias` config, and a tree with an unreadable file — every `--gate-json` document
BYTE-EQUAL between `scan --policy` and `gate --report`, and every exit code equal. `analyzed.count`,
`reasonClass`, `netClass`, the ⟨0.15⟩ coverage advisory and the ⟨0.21⟩ `incomplete`+`unanalyzed` manifest
(the exit-2 rows) all included. No divergence found.

**MODEL CROSS-CHECK** against `candor-spec/reference/policy_model.py`: 256 signatures × 5 verbs = 1280
rows. `deny Fs Unknown[reflect,unresolved]` and `pure` agree 256/256. All 100 disagreements are ONE
family — `Llm ∈ S` with `Net ∉ S` under a `deny Net`, where the model applies Definition 4's refinement
preorder (`Llm ⊑ₑ Net`) and the engine intersects the denied set with `inferred`; direction is uniform,
model REJECT / engine pass. That is the same model-versus-contract shape SPEC §6 pins for `Db` (since
amended out of the model, so the residual has MOVED rather than closed): §6.2's normative `deny` grammar
has no refinement clause. It is also unreachable from a scan — SPEC §1 ⟨0.13⟩ has the engines CO-EMIT
`Llm` and `Net`, and this one does at three sites in `CallCollector.swift`. Restricted to that
well-formed sub-lattice (`Llm ⇒ Net`), **0 disagreements**. Not patched here: making `deny Net` fire on
`Llm` alone is a family-wide contract change, not a candor-swift one.

Pinned by `GateReportVerbProcessTests` (15 process-level cases, each verified to FAIL under a targeted
mutation of the shipped binary) plus four `smoke.sh` cases. `swift test` 387 passed; `smoke.sh` 108/0.

### ⚠ soundness — a chained dependency's ACCESSOR read, and the UNBOUND factory call, were silent-pure (2026-07-27)

Two chained-boundary defects found by conformance PART 24 (split-invariance) on its first run, each
re-derived from a hand-written two-package fixture. Under ⟨0.21⟩ an absent-but-analysed function is a
positive purity claim, so both were false all-clears rather than gaps.

- **A property ACCESSOR on a dependency's type.** `l.v` where `L` is a chained dependency's type and `v`
  is a computed/lazy/static property that performs I/O. The dep's report already carried `L.v ['Fs']
  unitKind:accessor` — every reader-side branch in the property-read path was gated on
  `localTypes`/`localProtocols`, so the read fell off the end of the chain and was never recorded.
  Not lazy-specific: computed, lazy and static spellings were all silent. PART 19's fixture reads a
  module-level GLOBAL, which IS modelled, so the accessor spelling had never been asked.
- **A factory call with NO intermediate binding.** `build().fetch()` and `getDyn().run()` read
  silent-pure while `let c = build(); c.fetch()` resolved and `let t = getDyn(); t.run()` disclosed
  `Unknown[dispatch:untyped cross-package receiver]`. That is a hole in a SHIPPED guard: PART 21's
  ruling is that an unformable key must not read pure, and PART 21's fixture binds the result.

Both fixes emit the call shape the join already understands, so **neither needed a report-format
change**: the accessor read becomes a `propertyExternal` candidate joined against the sibling report
under `<Module>#<Type>.<member>` (the third member of the `stringifyExternal`/`deinitExternal` set), and
the unbound receiver recovers its provenance through `depFactoryCallee` — now a shared function, so the
bound and unbound spellings cannot drift apart again.

The mirror controls, each verified by mutating its guard out: a LOCAL type whose accessor is pure,
sharing a name with a dependency type whose same-named accessor is `Fs`, stays pure (it resolves to its
own unit — the reason this is a candidate set and not a `propertyEdges` entry); a dependency accessor
the report shows as pure, and a dependency STORED property, add nothing; `max(a,b).advanced(by:)` and a
call on a nested local `func`'s result acquire no hedge.

A/B over 8 real Swift targets: **unchained is byte-identical** (3082 entries, 0 changed) — with no dep
report loaded neither candidate set is consulted. Chained against per-module swift-syntax reports,
candor-swift's own scan gains 35 `Unknown`-only entries and 0 real effects, every one traceable to a
genuine SwiftSyntax accessor unit the dep's report itself marks `Unknown`. The A/B also caught the one
over-fire this join has had: `.map(String.init)` keyed swift-syntax's own `extension String`, so
`.init`/`.self`/`.Type`/`.Protocol` are now excluded as metatype spellings no accessor can answer.
`CANDOR_DEPMEMBER_DEBUG=1` prints each candidate and whether it hit, because a diff shows which
functions moved and never which key moved them.

### soundness — `unverified --class` read the direct `unknownWhy` as if it were the transitive one (2026-07-27)

`unverified` names the functions a `pure`/`deny E` layer PASSES without proving anything. Its ⟨0.20⟩
`--class` filter matched against the report's `unknownWhy` FIELD, which is the wrong quantity twice:

- SPEC §4 makes `unknownWhy` **direct-only**, so a function that INHERITS its `Unknown` records no
  reason of its own — and matched no class, so every inherited hole was dropped by every filter.
  44% of pollen's `Unknown`-bearing entries (192/435) and 67% of candor-swift's own (35/52) are that shape.
- SPEC §6.2 ⟨0.24⟩: a reasonless `Unknown` **CONTRIBUTES** `unresolved`. The site contributed nothing,
  so `--class unresolved` — the filter whose job is the holes nobody could classify — missed them.

The tell is that `--class dynamic` names every genuine class and so cannot exclude a hole, yet returned
strictly fewer. Measured, `deny Exec`, holes unfiltered → `--class dynamic`:

| target | unfiltered | dynamic BEFORE | dynamic AFTER |
|---|---|---|---|
| pollen | 387 | 230 (−41%) | **387** |
| candor-swift | 51 | 16 (−69%) | **51** |

Both halves are required and each is the other's guard: contributing on absence alone would give an
inherited `Unknown` `unresolved` when its callee classified it `dispatch` — the fail-open traded for its
fabrication mirror. So the contribution is gated on `direct` ∋ `Unknown` (the function introduced the
hole and named nothing), and inheritance is resolved by the same least-fixpoint over `calls` the gate
uses. The filter still discriminates after the change — pollen `--class unresolved` = 6 of 387,
`--class native` = 0 — which is the control that separates this from "everything matches everything".
`UnverifiedClassFilterTests` pins both directions; the mutation dropping the `direct` gate fails only the
control rows. No report-format change: `direct` and `calls` were already on every entry, unread.

The ⟨0.24⟩ projection change does **not** move any gate verdict here: candor-swift attaches a reason at
the SOURCE (`dep:<hash>` synthesized per dep entry exactly when the dependency classified nothing), so a
function's class set is never empty and the gate's empty-set default is unreachable — instrumented, 0
fires across 487 `Unknown`-bearing functions on two real targets, and the three-row counterexample
(reasonless dep, reasoned dep, both) is already rejected on the both row.

### soundness — ⚠ a binder that CAN type its new binding still has to invalidate the old one (2026-07-27)

A review found one site; the rename control that reproduced it found four more. `shadowName` drops the
four name-keyed FLAGS and `clearBindingTypeOnly` drops the TYPE indexes — and every branch that
succeeded in TYPING a rebound name called the first and wrote `vars` over the top, leaving `protoTyped`
describing a binding that is no longer there. The member-dispatch site consults `protoTyped` BEFORE the
`vars` root, so the fresh type does not mask the stale protocol, and the call dispatched over the
SHADOWED parameter's conformers:

| binder | reads | rename control |
|---|---|---|
| `switch e { case .active(let j): j.run() }` beside `j: Job` | `['Fs']` | ABSENT |
| `if let j = o { j.run() }` | `['Fs']` | ABSENT |
| `xs.forEach { (j: Ctx) in j.run() }` | `['Fs']` | ABSENT |
| `let (j, _) = (Ctx(), 1); j.run()` | `['Fs']` | ABSENT |
| `func inner(_ j: Ctx) { j.run() }` inside `f(_ j: Job)` | `['Fs']` | ABSENT |

**The clear is also a RECOVERY**: the stale entry was not only fabricating, it was masking the shadowing
binding's own type, so `if let j = o { j.go() }` and the closure form now resolve `Ctx.go` for the first
time. The ordering carve-out (`let u = u.asURL()` resolves THROUGH the entry being cleared) is a
denylist and is pinned by its own row — the mutant that clears unconditionally fails only that one.
A/B over 13 real Swift packages: 0 gains, 0 losses; the shape needs a stale `protoTyped` under a
shadowing binder, which no corpus site has (instrumented: 0 of 89 live-index hits at the payload site),
so the corpus is the fabrication control and the fixtures are the evidence.

`NameKeyedStateTests` was green through all five and correctly so — it derives the SET of name-keyed
maps and checks each map's classification, and what was violated is per-NAME and per-CONTROL-PATH,
which a parse tree cannot see. Both derivable strengthenings were priced and both would have PASSED on
the defective code; the limit is now stated in that file rather than left to be assumed away.

### deps — ⚠ completeness, and the identical-entry rule at every trust level (2026-07-27)

- **A complete report no longer cancels an incomplete sibling's hedge over the same package.** Coverage
  turns SILENCE into a purity claim (§2 rule 3), so a set of reports' silence is only as strong as the
  weakest completeness claim in it — **two reports covering one package do not cover the same SOURCE**.
  Measured: with A complete and B declaring `unanalyzed`, B alone hedges `invisible: ['RatesDep']` and
  A+B went ABSENT. The sharper form is candor-rust `63bbe87`'s argument on the completeness axis: two
  fresh reports disagreeing on a key withdraw it (§2 rule 1, correctly) and complete-wins turned that
  withdrawal into a positive purity claim over a function both reports call effectful. The cost is a
  hedge, never an effect — entries are untouched either way.
- **The identical-entry exemption now applies at every trust level.** Two byte-identical entries from
  two STALE reports were withdrawn as ambiguous, costing the §2.1 `Unknown` downgrade the stale arm
  exists to produce (`go` went from `['Unknown'] dep-stale:RatesDep` to a bare ledger hedge). 476 of
  8367 join keys already collide within a single real report, across 12 of the 13 corpus packages, so
  the population is not marginal. candor-rust `6f2210c` aligned.

### fix — `--workspace`'s cache sweep, twice more (2026-07-27)

- **It deleted a report a healthy sibling had just written.** The sweep skipped deps that SUCCEEDED,
  which is not the set of files THIS RUN PRODUCED: a workspace holding one package twice (a vendored
  fork beside the upstream checkout) has the FAILED copy owning exactly the file the healthy copy wrote,
  and the retry-plus-second-sweep deleted it twice. The consumer went from `['Fs']` with its literal
  surface to `invisible: ['Shared']`. The guard is the simplest one — never delete a file this run
  wrote — and the per-dep failure line no longer claims a removal that did not happen.
- **The sweep's manifest parse was not the writer's, and a comment said it was.** The sweep anchored
  after `Package(`; the writer takes the first `name:` in the whole file. A hoisted target or dependency
  array splits them, and both failure directions land at once: the stale report SURVIVES (a ⟨0.21⟩
  purity claim over a dependency that writes to disk) and a user-placed file under the invented name is
  DELETED. There is now one parse and one name transform, both the writer's, both called by the writer.

### soundness — ⚠ an enum-case payload binding is a LOCAL, and no shadow guard knew it (2026-07-27)

`typeEnumCaseBinding` typed `case .active(let c)` when the case name was unambiguous and carried exactly
one associated value. Everything else — the `case let .active(c)` spelling (the `let` outside the
parens, which parses to a bare `patternExpr > identifierPattern` with no `ValueBindingPattern` to
match), an ambiguous case name, and every multi-payload pattern the arity guard refuses to type — left
the bound name in NEITHER `vars` NOR `boundLocals`, i.e. invisible to every shadow guard in
`CallCollector`. Two fabrications followed, both measured on real code:

- **a BARE READ of the name charged the enclosing type's same-named property.** Alamofire's
  `AuthenticationInterceptor.adapt` was charged its own `credential` accessor; `WebSocketRequest.didClose`
  was charged the inherited `Request.error`; TCA's `TypeSyntax.identifier` was reported as its own
  caller.
- **PASSING it as an argument charged a same-named FREE FUNCTION**, because the fn-ref-as-argument rule
  (`xs.map(transform)`) can only skip arguments it can see are locals. `UploadRequest.task`'s
  `case let .data(data)` resolved to the unrelated `DataRequest.data`, and inherited an `Unknown` from it.

**AND THE SECOND FABRICATION MANUFACTURED A DISCLOSURE, which is why the previous round reverted.** A
phantom free-fn reference resolves to no local unit, and that is exactly the Driver's test for "this unit
reaches code the scan cannot see" — so vapor's `DecodingError.reason`, whose only unresolvable "call" was
the name of its own `case let .dataCorrupted(ctx)` binding, carried an `invisible: [HTTPTypes]` it had no
business carrying, and `DecodingError.description` inherited it through `self.reason`. Both units are in
the report ONLY because of that disclosure, so closing the fabrication removes the entries. A vanishing
report entry looked like the cardinal sin and was a fabricated disclosure being withdrawn.

A/B over 13 real Swift packages (11,924 report entries): **0 gains, 8 fabricated call edges removed, 13
manufactured `invisible` disclosures withdrawn and one fabricated `Unknown`** — every change traced to
source.

The payload names live in their own LEXICALLY SCOPED set rather than in `boundLocals`, and both halves of
that were forced by measurement. Folding them into the function-wide set drops the genuine property read
that FOLLOWS the block (swift-syntax's `IfConfigDiagnostic.asDiagnostic` binds `syntax` in three `if case`
blocks and then reads the real `self.syntax`) — a silent under-report manufactured by a fabrication fix.
Scoping `boundLocals` itself instead is worse: `Driver` reads it once, AFTER the walk, where a restored
set is empty, so `if c { let loadIt = { }; loadIt() }` starts edging to a same-named free function.
Both directions are pinned by fixtures, and five mutants each fail a named one.

### process — the set of name-keyed maps a rebind must invalidate is now DERIVED (2026-07-27)

One mechanism has produced **seven** defects in `CallCollector` across three days, every one the same
shape: a name-keyed fact outliving the binding that set it. `42093b6` removed the enumeration of binder
FORMS by binding to `IdentifierPatternSyntax`, which is where the language puts every pattern binding —
and it clears a LIST of maps, which is the same enumeration one level up. Two of the seven were maps
missing from that list.

`NameKeyedStateTests` makes the obligation derived rather than listed: it parses `CallCollector.swift`
with SwiftParser, enumerates the class's stored properties from the parse tree, and requires each one to
be classified — cleared (and whether scoped), deliberately kept as a hedge, a program-wide index, or not
per-binding at all. **Adding a map without that decision fails a test**; classifying one as cleared
without writing the clear fails another; classifying one as scoped without both saving AND restoring it
fails a third. All three verified by mutation, and the stale-entry direction caught a real one on its
first run. What is derived is the SET (nobody keeps it current, in either direction); what is authored
is the JUDGEMENT, which has to be — whether a `[String: X]` is keyed by a binding name or a type name is
a fact about meaning, not syntax, and the two hedging sets must NOT be cleared.

The classification is also where the two maps this pass did NOT fix are filed, with their measurement,
so the next audit inherits the numbers instead of the surprise.

### soundness — ⟨0.21⟩ a chained report that DECLARES ITSELF INCOMPLETE no longer grants coverage (2026-07-27)

⚠ **A dependency report carrying a non-empty `unanalyzed` was still registering full coverage for its
package** (`Deps.swift`). §2 rule 3 turns a report's SILENCE into a purity claim; a report with a
non-empty `unanalyzed` has just said it never read some of its own source, so its silence about that
source answers nothing. The same door `stalePkgs` closed, read one step earlier — staleness asks
whether to believe what a report SAYS, completeness asks whether its silence means anything.

Measured on the two-tree fixture: a call into a dep API the incomplete report has no entry for went
from `invisible: ['RatesDep']` unchained — the honest hedge — to **absent from `functions`**, a ⟨0.21⟩
positive purity claim, the moment the report was chained. candor-ts, which found this door in its own
sweep (`21277eb`) and whose treatment this ports, measured the single-tree control over the same
sources at exit 2 ("a gate cannot be green over unanalyzed code"), so chaining an incomplete report was
strictly WORSE than not chaining it.

The TREATMENT differs from staleness because the evidence does. A stale report's entries are assertions
from a build this engine will not repeat and are downgraded to `Unknown`; an incomplete report's
entries were derived from source it DID read and are kept **unchanged** — effects, literal surfaces and
all. Only the SILENCE hedges: strictly additive, no effect is ever removed. Staleness is checked FIRST
(a report we do not trust cannot be trusted about its own completeness), a package chained both
complete and incomplete keeps the complete report's coverage, and half 1's unanswerable-key `Unknown`
speaks BESIDE the ledger hedge rather than being replaced by it — the trade candor-ts measured going
the wrong way, where withholding coverage silently took `deny E Unknown[dispatch]` from exit 1 to
exit 0. Six guards, six mutants, each failing its named test and only it. ⚠ a chained consumer may
newly carry `invisible` where a dependency's report is incomplete; regenerate baselines.

Corpus: 0 of 34 real Swift packages produce a report declaring an `unanalyzed` unit, so the rung is
inert there — the corpus is the fabrication control and the fixtures are the evidence. It fires exactly
when a dependency ships source candor cannot read, which is precisely when its silence is worth least.

**A second, smaller repair fell out of the fixture**: two reports carrying an IDENTICAL entry for the
same key were withdrawing it as ambiguous. The header's canonical-path dedup catches the same FILE
loaded twice but not the same report present under two names — the ordinary shape once `--workspace`
prepends its scanned directory to a configured `CANDOR_DEPS`. §2 rule 1 forbids PICKING between
candidates; there is nothing to pick when they are equal.

### soundness — a stale report BESIDE a fresh one withdrew the fresh answer (2026-07-27)

⚠ **A package chained both FRESH and STALE read as a positive purity claim** (`Deps.swift`). Two
mechanisms met. §2 rule 1 withdraws a key two entries share, so the fresh `{Net}` entry and the stale
`{Unknown}` entry for the same dependency function cancelled each other and the key resolved to
NOTHING; `stalePkgs.subtract(coveredPkgs)` then — correctly — left the package COVERED on the fresh
report's authority, and §2 rule 3 turned that nothing into a claim. Measured on the two-report fixture:

    unchained          go -> invisible: ['RatesDep']          the honest hedge
    FRESH report only  go -> ['Net'] + the host literal
    STALE report only  go -> ['Unknown'], dep-stale:RatesDep
    FRESH *and* STALE  go -> ABSENT FROM `functions`           a ⟨0.21⟩ purity claim

Strictly worse than not chaining at all, and NON-MONOTONE: adding a report removed an answer that was
already there. A dep directory holding one package twice is the ordinary situation rather than a corner
— candor-rust, which found this and handed it over, measured it at 7/167 of its own dep reports, 9/259
on pgman and 30/378 on ebman — and in this engine `--workspace` reaches it by construction, since it
PREPENDS its own scanned directory to the configured `CANDOR_DEPS` spec.

Rule 1 exists because two DIFFERENT dependency functions can share a leaf/tail2 key with nothing to
tell them apart. That is not this case: §2.1 has already ranked the two producers, so preferring the
trusted one is the rule the engine spent rule 2 stating, not a guess. Trust now decides first and the
collision rule applies WITHIN a trust level — trusted vs trusted withdraws permanently (unchanged),
trusted vs stale keeps the trusted entry whichever order they load in, stale vs stale withdraws
recoverably so a trusted report can still claim the key. The invariant the test asserts: **adding an
untrusted report to a dep dir that already holds a trusted one changes the consumer's report by
nothing at all.** ⚠ a chained consumer may newly carry effects it was silently dropping.

### data loss — `--workspace`'s cache sweep deleted reports the user put there (2026-07-27)

**`--workspace` removed every `*.json` in `<root>/.candor/deps` that its own path-dependency scans had
not produced this run** (`main.swift`) — including a report the USER placed there, which SPEC §2 makes
the ordinary way to chain a BINARY dependency, a hand-produced report, or another engine's report in a
polyglot repo. Unrecoverable, and unrelated to the stale path-dep report the sweep was aimed at. Not an
analysis defect at all, which is why it is stated on its own: candor's contract is that it does not
destroy information, and a file the user chose to put there is information.

The sweep exists for a real reason (`43a0eaa` — a stale child report standing in for a failed rescan is
a ⟨0.21⟩ false all-clear), so the fix distinguishes reports the run OWNS from reports it merely FOUND,
rather than sweeping less. Ownership is DERIVED from `Package.swift` and needs no marker file: the
candidates are the discovered local path deps, and a failed dep's report file is found by the package
name an earlier round recorded, else its own manifest's `name:`, else the directory basename — the same
three sources, in the same order, that the writer uses. Anything else in the directory is **named on
stderr and left in place**; whether to trust it is §2.1's staleness call, not the sweep's. Residual,
stated rather than hidden: a report for a package that USED to be a path dep and no longer is now
lingers — information kept rather than destroyed, and disclosed.

Two guards, two mutants, each failing its named test and only it. The manifest-name row uses a dep
whose DIRECTORY name differs from its package name, because with `Dep0/` holding package `Dep0` the
basename fallback answers correctly too and the branch under test could be deleted with the row still
green.

### soundness — a fifth name-keyed map a rebind never invalidated, and this one edges to a BODY (2026-07-27)

⚠ **`fnValueAlias` outlived the binding that set it** (`CallCollector.swift`). It maps an inferred
fn-value local to a NAMED LOCAL FUNCTION (`let g = eff` → invoking `g()` edges to `eff`), and no clear
path touched it: not `clearBinding`, not `clearBindingTypeOnly`, not `shadowName`, and
`leaveShadowScope` neither saved nor restored it. So an alias established for a name answered for every
LATER and every INNER binding of that name. Measured with the rename control:
`func f(_ jobs: [() -> Void]) { let g = eff; for g in jobs { g() } }` reads `['Fs']` — `eff`'s effect
charged to an invocation of a loop element — while the identical body binding `h` is ABSENT; the same
for an inner `let g = { }`, a visibly pure closure that inherited `eff`'s body.

This is the **fifth** map in one mechanism and the widest of them: the other four are TYPE indexes, so
leaking one charges whatever some type's member happens to do, while this one charges a named
function's entire transitive effect set. It is now cleared by `shadowName` and saved/restored by the
enclosing scope, with the same self-referential-initializer carve-out `protoTyped` needs (`let g = g`
resolves through the binding it replaces). Three guards, three mutants, each failing its named
assertion and only it.

Measured on 34 real Swift packages: **0 gains, 0 losses, 0 entry delta** — and per the standing bar
that clean diff is the fabrication CONTROL, not the evidence. Instrumented, the rung is established
exactly ONCE across the corpus (console-kit's `let rpp = linux_readpassphrase`) and the fix's trigger
— a rebind dropping a live alias — fires **zero** times there. The fixtures are the evidence.

### soundness — the FULL-QUAL dep-index key, and the guard it makes provable (2026-07-27)

**A third dep-index key shape: `pkg#<full qual>`.** The `CANDOR_DEPS` index held exactly `pkg#leaf`
and `pkg#tail2`, so a consumer that knew its target PRECISELY had no key to ask on — `Conn.send` and
`Mock.Conn.send` are one tail2 string, and the ⟨0.23⟩ `typeSurface.returns` join, which forms
`<pkg>#<type qual>.<member>` from a fully qualified path, could only ever miss on a nested type.
Normalized rather than raw, so a report another engine wrote as `mod::Type::fn` is keyed the way a
Swift call site spells it. Additive by construction against every other entry (a leaf key carries no
`.`, a tail2 key exactly one), and the **DEDUP is the whole safety argument**: for a 1- or 2-segment
qual the "full qual" IS the string already pushed, so an undeduped third push self-collides and §2
rule 1 withdraws a key that already worked. Both directions are asserted by one test and both were
verified to catch — with the dedup deleted, a bare free call into the dependency goes ABSENT from the
report, which under the ⟨0.21⟩ manifest is a positive purity claim. Index grew 14 535 → 15 398 keys
over seven real repos split one package per target; keys present before and absent after: 0. Report
bytes unchanged: 11 targets unchained and 43 chained consumers, all byte-identical, 0 gains, 0 losses.

**The `typeSurface` exact type-path match is no longer an open question.** It shipped honestly marked
UNPROVEN, because relaxing it to a suffix match failed no test — a suffix match returns a path of two
or more segments, the consumer forms a three-segment key, and the old index missed it. With the third
key the wrong answer LANDS: a factory returning a type the package does not declare then publishes the
nested type that merely shares its leaf, and the caller is charged an effect it cannot reach while
losing its disclosure with it. Pinned by a fixture written with the key, mutation-verified, and paired
with the row that must still resolve.

### ⚠ soundness — the five-shape cross-engine sweep (2026-07-27)

Five defect shapes confirmed in one engine each the day before, swept here. Three were PRESENT, one
ABSENT with the line that prevents it named, and one — swift's own — was VERIFIED holding and then
found leaking through two maps its verification did not cover. Every fix carries both fixtures (the
case that must now work AND the case that must still work), every guard was mutated out with its
named failing test recorded, and every arm's binary was kept by content hash.

**⚠ An untrusted chained report no longer grants COVERAGE.** §2 rule 3 turns a report's silence into a
purity claim and §2.1 says a report from another engine build is not ours to repeat; the loader did
both at once, so the keys a stale report CARRIED read `Unknown` (right) while every key it did not
contain read PURE. A stale report is now CHAINED but not COVERED — the split matters in both
directions, since gating the join on coverage too would take rule 2's downgrade with it (four named
tests). Measured live: with console-kit's six dependency reports marked as another build, 29 functions
gain an `invisible` hedge and 18 that were absent from the report entirely come back, 0 effect losses.

**⚠ The report differed from itself under `CANDOR_WORKSPACE_CHAIN`.** Protocol-CHA union entries were
appended from two DICTIONARY iterations, so five runs of one binary over Alamofire gave five report
hashes carrying the same 879 entries in five orders. Sorted at the point of emission; content
bit-identical.

**⚠ `--workspace` kept a previous run's report when this run's scan of that dependency FAILED.** The
child's stderr went to `/dev/null` and the skip was silent, so `.candor/deps/` handed the analysis a
stale answer and §2 rule 3 made its silence a purity claim — a warm run and a cold run of identical
source disagreeing, one reading `invisible: ['DepLib']` and the other absent from `functions`. Reports
no successful scan produced are now swept, the failure is disclosed with the child's own reason, and
the fixpoint re-runs once so a sibling that chained the removed report is re-derived without it.

**⚠ The reason-scoped gate was inert twice over.** `reasonClass` tested `dynamicMemberLookup` for
EQUALITY while the engine emits `kind:detail`, so `Unknown[reflect]` was silently unsatisfiable even
single-tree; and a chained dependency's Unknown arrived carrying only `dep:<hash>`, so the class was
lost at the first hop. Both fixed with no format rung — the dependency's report already carries
`unknownWhy`. Over a three-package chain `deny Unknown[reflect]` now bites single-tree, one hop and two
hops alike, while `[native]` bites in none of them and `[unresolved]` no longer fires on a classified
hole.

**⚠ Two name-keyed maps a binder never invalidated, both fabricating.** `protoTyped` charged a local
protocol's conformers to a call on a loop binder that shadowed the protocol-typed parameter;
`localConstStrings` attributed a literal host to a `dataTask` whose address is a runtime value. Each
measured with the rename control that separates a leaked flag from an untyped binder. The obvious
placement cost Alamofire's `URLRequest.init` its disclosed `Unknown` — SwiftSyntax walks a binding's
pattern before its initializer, and that function is `let url = try url.asURL()` — so the clear lives
where a binder cannot type the new binding, plus one line guarded on the initializer not mentioning
the name.

**The `unresolved` marker does NOT fail open here** (candor-ts `e66f29e` swept): it is DERIVED from the
effect set at the single writer, and over 12 004 real entries — 10 539 carrying `Unknown` — 0 fail the
marker and 0 carry a direct `Unknown` without an `unknownWhy`. The dead parallel `unresolvedSet`, whose
only possible future was to disagree with that line, was removed and the invariant pinned by tests.

**Half 1's provenance conjunct no longer fires on the enclosing type's own methods.** Instrumented over
14 targets it bound 289 locals — led by `rootOf`, `classifyItems`, `createFunction`, all enclosing-type
methods, then `sin`/`cos`/`atan2`/`sqrt` — and not one was a dependency factory. Now 123. The exclusion
is scoped to the enclosing type and its local supertypes, never a flat leaf set, because widening it
drops a genuine disclosure.


### ⚠ soundness — three defects in the erasure/typeSurface gates, found by adversarial review

Three fixes, each with its own two-direction fixtures and each guard verified by mutating it out and
naming the test that fails. A/B over 14 real Swift targets / 12 004 entries (pollen, candor-swift,
swift-syntax, Alamofire, vapor, TCA, SQLite.swift, swift-argument-parser, console-kit, Files, swift-log,
Commander, ShellOut, swifter): 0 effect gains, 0 losses, Unknown unchanged.

**A ternary's opacity is a claim about BOTH arms.** `rootOf` composed `cond ? a : b`'s monomorphization
flags with `||`, so a receiver monomorphized on one arm and ERASED on the other was treated as fully
monomorphized: the local-conformer CHA was skipped for the erased arm too and the function went ABSENT
from `functions` — a positive purity claim, under the ⟨0.21⟩ manifest, about a body that performs the
conformer's effect. Opacity licenses suppression, so it composes by conjunction.

**A binder is an `IdentifierPattern`, not an entry on a list.** `patternNames` enumerated three of the
seven `PatternSyntax` kinds, so `for case let x?`, `for case .some(let x)`, `for case let x as T` and
`for var x` never reached the shadowing path at all and the enclosing signature's opacity /
dependency-provenance flags stayed attached to the loop's own unrelated binding — silent-pure in one
direction, a false `Unknown[dispatch:…]` for a purely local value in the other. Now a walk for every
`IdentifierPatternSyntax` in the pattern subtree (verified in both directions against SwiftParser: every
bound name reaches one, and no non-binding pattern produces one), plus a catch-all that CLEARS any binder
no specific visitor claimed — so an unenumerated form defaults to dropping a stale binding rather than
keeping one. Two forms are now typed as well, since scoping alone left them untyped and silent for a
second reason: `for case let x as T` (T is written in the source) and `for case let x?` (Optional sugar).
A loop binder's type no longer outlives its loop. Also fixed: `catch let e as MyError` matched a
`DeclReferenceExpr` where the parser puts a `patternExpr > identifierPattern`, so that branch never fired.

**The `typeSurface` ANSWER must be unambiguous, not just the entry.** The ⟨0.23⟩ consumer keys a BARE
callee name against every covered package the file imports and gated only on the entry lookup being
unambiguous. Two chained packages both exporting `build` — one returning a type with an effectful
`fetch`, the other a type whose `fetch` is pure and therefore absent — charged the first package's effect
AND its path literal to a caller that reaches only the second, with `unresolved` left false so nothing
disclosed it. SPEC §2 rule 1's never-guess rule now applies across the file's imports too, and refusing
falls back to half 1's disclosure. `CANDOR_TYPESURFACE_DEBUG` reports `AMBIGUOUS` as its own verdict.


### ⚠ ⟨0.23⟩ `typeSurface.returns` — the factory-bound receiver resolves, not just discloses

`let c = build(); c.fetch()` types `c` from `build`'s RETURN type, and a PURE `build` is ABSENT from the
dependency's report entirely (SPEC §2 rule 3), so no consumer could recover it from the entries. Half 1
made that disclose `Unknown` instead of reading silent-pure; this recovers the effect. `deny Fs` on
identical source goes one-package exit 1 -> split+chained exit 0 -> exit 1 again.

PRODUCER: a new optional envelope field `typeSurface.returns`, mapping `<pkg>#<fn qual>` to
`<pkg>#<type qual>`, both FULLY QUALIFIED in this package's own namespace. Omitted when empty, so a report
with nothing to say is byte-identical to a pre-rung one and a ⟨0.22⟩ consumer is unaffected. A wrapper
return (`-> Conn?`, `-> Result<Conn,E>`, `-> [Conn]`, `-> Box<Conn>`) publishes NOTHING: the binding holds
the wrapper, and keying its `map` against the payload would charge effects nobody runs. A PROTOCOL return
IS published — `func make() -> SomeProtocol` is the commonest Swift factory — and the key it forms is
answered by the producer's `interfaceUnion` entry, so the two mechanisms are layered.

CONSUMER: a miss on `returns`, or on the entry lookup that follows a `returns` hit, falls back to half 1's
disclosure and never to silence — the index deliberately drops keys two entries share, so a miss cannot
tell "no such method" from "I withdrew the answer". A STALE producer's surface is not read at all.

Measured: 11 real targets unchained, 0 effect gains/losses/entry deltas and the only envelope change is
the new field (3 564 entries published). 5 chained consumers, 0 gains, 0 losses; the consumer arm is
entered 20 times and misses every time — instrumented via `CANDOR_TYPESURFACE_DEBUG`, which prints the
producer counts and every consumer hit/miss.

Residuals, deliberate: a NESTED type's method is unreachable for the consumer (the key is three segments
and the dep index carries `pkg#leaf`/`pkg#tail2` only — it misses and discloses); `-> any P` / `-> some P`
returns are refused.

### soundness — one apply site for a chained dep entry; the chained-GLOBAL one had drifted

The engine carried three copies of "inherit a chained `DepEntry`", and the chained-global read applied
the effects, `hosts`, `cmds` and `paths` while silently dropping `tables`, `invisible` and `incomplete`.
A consumer reading a dependency's effectful lazy global therefore inherited the EFFECT and none of the
dependency's own honesty markers — turning a qualified claim (`Fs`, plus a blind spot inside the
dependency) into an unqualified one. Now one `applyDepEntry`. No corpus output changes; the fixture is
the evidence.

### soundness — two scope leaks in the erasure gate, both silent under-reports

Both are the standing-bar item 0 shape — a fabrication fix narrowing past a real reach — and both are
invisible in a corpus A/B because each needs a name collision no measured target contains.

- The ELEMENT-opacity set was written in lockstep with the element TYPE (the CLEAR half of the scope
  discipline) but was never added to the scope SAVE. An inner block binding an existing name from a
  monomorphized source (`if c { let ys = xs.filter { … } }`, `xs: [some P]`) marked `ys` monomorphized for
  the rest of the FUNCTION, so the ERASED `ys: [any P]` parameter it shadowed lost its dispatch and an
  Env-performing function read pure.
- A nested `func`'s PARAMETERS were not a scope. `func outer(_ s: some P) { func inner(_ s: any P) { … } }`
  suppressed the CHA on `inner`'s genuinely erased receiver because the enclosing parameter, a different
  variable, is spelled `some`. The nested signature's own opacity is re-applied, so the mirror
  fabrication does not open.

### ⚠ soundness — implicit stringification through a PROTOCOL-typed operand (Swift arm of the four-way vein)

Closes a silent under-report (cardinal sin): `"\(e)"` / `String(describing: e)` / `print(e)` runs the
operand's `description` (or `debugDescription`), and when the operand's static type is an EXISTENTIAL
(`any P`), a GENERIC bound (`<T: P>`), or a caught `error`, the witness belongs to a CONFORMER — so
nothing was edged and the function read PURE while its `description` performed I/O. The concrete-operand
form was already modeled (the implicit-conversion vectors in smoke.sh); only the dispatching form was
missing. This is the Swift arm of the common-mode vein recorded in
`candor-spec/SOUNDNESS-VEIN-implicit-stringify.md` (found on HikariCP through SLF4J parameterized
logging by the dynamic oracle, reproduced in all four engines).

A stringification site whose operand is a local protocol — or one of the stringify/error protocols whose
CONFORMANCE is declared in the analysed code (`CustomStringConvertible`, `CustomDebugStringConvertible`,
`Error`, `LocalizedError`) — now resolves by CHA over the conformers (and their subclasses), edging to
the `description`/`debugDescription` accessor units that exist and climbing to an INHERITED witness (a
protocol-extension default) when the conformer declares none. `catch` bindings are typed for this path
only: the implicit `error`, `catch let e`, and the concrete `catch let e as MyError`.

PRECISE-OR-NOTHING, deliberately: an unresolvable conformer set edges nothing rather than disclosing
`Unknown` (a conformer with no `description` stringifies through the stdlib's PURE reflective default,
and interpolation is pervasive enough in Swift that an Unknown here would flood every report). RESIDUAL,
recorded not repaired: a conformer declared outside the analysed code whose `description` is effectful is
still missed. No fabrication: a String/Int/library operand edges nothing, and the external-protocol list
is closed by NAME precisely because Swift's inheritance clause is overloaded — `enum Suit: String`
records String as a "conformed supertype", so an open rule would edge every `"\(someString)"` to that
enum's `description`.

A/B over 10 real packages (Alamofire, console-kit, Files, SQLite.swift, swift-argument-parser,
swift-composable-architecture, swift-log, vapor, pollen, candor-swift itself — 4360 reported functions):
3 gains, all explained, all transitive `Unknown` inherited from units that already carried it —
SQLite.swift `Context.set` (`String(describing: result)` on a `Binding?` → `Blob.description` →
`Blob.toHex`), and vapor `BodyStreamResult.description`/`.debugDescription` (`"error(\(error))"` on an
`any Error` payload → `DebuggableError`/`ValidationsError`/`MacroError` `description`). Zero fabricated
effects; every conformance fixture byte-identical (the four-way differential is untouched).

## [0.23.1] — 2026-07-20

### performance — quadratic per-function loop-invariant removed (no output change)

The per-function analysis loop rebuilt `Set(freeFnByName.keys)` at every `CallCollector` construction —
`freeFnByName` is fixed after decl-aggregation and never mutated in the loop, so this was O(freeFns) × N =
**O(N²)** on any function-heavy corpus (ms/function rose 0.07 → 0.40 across 500→10000 funcs). Hoisted to a
single build before the loop → flat ~0.05 ms/function, **8.4× faster at 10k functions**. Report output
verified byte-for-byte identical (this is a loop-invariant hoist, not a semantic change); `swift test` green.

### ⚠ soundness — sync callback-invoker opaque-arg (Swift arm of the four-way parity fix)

Fixes a silent under-report (cardinal sin): an OPAQUE closure passed to a SYNCHRONOUS higher-order
invoker — `Sequence/Collection.forEach/map/filter/compactMap/flatMap/reduce/first/contains/allSatisfy/
sorted/min/max/…` (and their bare-`self` forms in a `Collection` extension) — read PURE, when the
invoker CALLS its closure argument in-thread. `xs.forEach(cb)` where `cb` is a fn-typed param is the
exact sibling of the already-correct direct call `cb()` and must contribute `Unknown` (`callback:<arg>`).
INLINE closure literals (`xs.forEach { … }`) keep their analyzed effect (charged lexically to the
passer — never reach the guard) and RESOLVABLE named callables (`xs.forEach(namedFn)`) keep their
resolved effect via the fn-ref edge — only OPAQUE args disclose, so over-disclosure is low. Matches
candor-java's `SYNC_CALLBACK_INVOKERS` opaque-arg guard (c755acd). A/B on swift-argument-parser:
+2 direct sites (`InputOrigin.forEach`, `ErrorMessageGenerator.unknownOptionMessage`) + 3 honest
transitive reaches; zero fabrication, zero inline-closure flood; report bytes otherwise unchanged.

## [0.23.0] — 2026-07-20

Spec floor → **0.23**. Soundness-increasing, report-shape-neutral:
- **cross-package protocol dispatch** (interfaceUnion, the 0.23 rung): a chained consumer's protocol method
  resolves to the conformer's effect (gated behind `CANDOR_WORKSPACE_CHAIN`). PART 18 conformance.
- **⚠ opaque closure → synchronous invoker** (`arr.forEach(cb)`/`map`/`filter`/… with an opaque closure
  param) discloses `Unknown` — the four-way sync-callback rung (PART 1 `sync_callback_opaque`). Inline
  closure literals keep their analyzed effect (no over-disclosure).
- protocol-union emission guarded against same-tail-type name collision.

## [0.22.0] — 2026-07-18

Spec floor → **0.22** (the `verify` oracle rung, shipped on the java/ts arms). candor-swift declares `0.22`; the
report and verdict schema are unchanged from 0.21, so this engine's output is byte-identical across the bump. No
functional change to the Swift engine.

## [0.19.0] — 2026-07-17

Reason-scoped `Unknown` policies (SPEC §6.2): `deny E Unknown[reflect,dispatch,indirect,native,unresolved,setup]`
narrows the `Unknown` part of a deny to a fixed reason-class vocabulary, with the `dynamic`/`*` aliases and
config `.candor/config` `unknown-alias <name> = <class…>` names. Bare `deny E Unknown` is unchanged
(`Unknown[*]`); an unrecognized reason maps to `unresolved`; the class propagates transitively. An AS-EFF-006
`--gate-json` verdict whose `effects` include `Unknown` carries a **`reasonClass`** array. Report bytes
unchanged. Also: a scan-level **SETUP warning** — a `Package.swift` that declares dependencies but has no
fetched `.build/checkouts` prints a "run `swift build`" remediation (the analog of a missing node_modules).

## [0.18.0] — 2026-07-16

### spec 0.18 — the trust-trio

candor-swift now declares **spec `0.18`** (`specVersion`; engine `candor-swift-0.18.0`). A pinned-tool-surface
rung (no report/verdict change), pinned four-way in the conformance suite:

- **`--strict` advisory-verb CI gate**: `fix-gate`, `gains`, `unverified` are advisory (exit 0); `--strict`
  makes each a CI gate (exit 1 while a finding remains). `gains` rejects a `--policy` (exit 2), naming the
  scan-time `deny <E> gained` gate (`AS-EFF-005`).
- **mostly-Unknown disclosure**: the scan opener (`emitSurface`) + `tour` never say "nothing hidden" over a
  ≥⅓-Unknown graph; `tour --json` carries an additive `unknown: {count, total}`.
- Hardening from a Fable-model code review: the scan opener gained the ⅓-Unknown gate it was missing (only
  `tour` had it); `gains --strict` added.

## [0.16.0] — 2026-07-16

### ⚠ The callgraph-aware baseline guard + Unknown-only advisory ⟨0.16⟩

The AS-EFF-005 regression ratchet (`CANDOR_BASELINE`) now keys existence on the baseline CALLGRAPH
sidecar, not the report. The report OMITS pure functions, so the pre-⟨0.16⟩ guard read a formerly-
PURE function turning effectful as "new" (exempt) and let it escape — the sharpest supply-chain
shape. ⟨0.16⟩ the sidecar lists every analyzed function (pure ones included, SPEC §2.2), so a
pure→effectful transition is now caught: `[AS-EFF-005]`, exit 1.

- **Callgraph-keyed existence.** A function present in the baseline callgraph sidecar but absent from
  its report is a KNOWN-PURE function; gaining a real boundary effect against it is a violation. When
  no sidecar accompanies the baseline the guard degrades to report-only existence (a stderr note,
  exit unchanged) rather than failing; a corrupt sidecar fails closed (exit 2).
- **Unknown-only gain is advisory, not exit 1.** A corpus test found the guard, on real dependency
  bumps, firing only on gained-`Unknown` — resolution noise, not a capability gain. `Unknown` is the
  §4 trust marker (pure policies exclude it), so failing pure→Unknown broke CI on innocuous bumps.
  Now the ratchet (exit 1) fires only on gaining a REAL boundary effect; an Unknown-ONLY gain is
  disclosed as one advisory note, exit unchanged (`--gate-json` stays `ok: true`). A real+Unknown
  gain still fails and reports only the real effect. Pinned by conformance PART 15c.

**⚠ report/verdict-affecting** — an upgrade across 0.16 is baseline-invalidating (regenerate the
saved baseline, callgraph sidecar included, with the new build); and **⚠ the `spec` string changed**
to `0.16` — a consumer pinning `spec == "0.15"` must accept `0.16`.

## [0.15.0] — 2026-07-15

### ⚠ The coverage envelope + privacy-manifest conditionality ⟨0.15⟩ (candor-spec/COVERAGE-DESIGN.md)

The wikipedia-ios false-confidence find (a real-world corpus-testing find, SOUNDNESS-LOG 2026-07-15):
"what the scan couldn't see" — the κ ledger — now travels WITH the report and conditions the
verdicts, instead of evaporating on stderr. Before: `privacy-manifest --verify` answered `ok: true`
with no caveat over 19 invisible modules; after: `conditional: true` + `coverage: { uncovered: 19 }`,
exit code unchanged. Pinned by conformance PART 4s.

- **`coverage` envelope field.** The κ-coverage ledger (the stderr `classifier doesn't cover` line)
  as data: `"coverage": { "uncovered": [ { "name", "calls" }, … ] }` — same modules, same import
  counts, same order; OMITTED entirely when nothing is uncovered, so a fully-covered report keeps
  the exact pre-0.15 document shape (verified byte-identical against the prior release binary
  before the version bump; the shipped envelope differs only in its `version`/`spec` strings).
- **`privacy-manifest --verify` is coverage-conditional.** When the report's ledger is non-empty (or
  any fn carries `invisible`), the JSON verdict gains `conditional: true` +
  `coverage: { uncovered: N, modules: [...] }`, and the human output appends the
  `⚠ verdict is conditional on N uncovered modules…` line. Exit code UNCHANGED (disclosure, not a
  gate); both keys absent on a fully-covered report.
- **`--gate-json` advisory coverage note.** The structured verdict carries the same small
  `coverage` block when the ledger is non-empty — VERDICT-PRESERVING (ok/violations/exit computed
  exactly as before; the ⟨0.9⟩ provable-purity auto-disclosure precedent).
- **`gains --json` re-discloses coverage.** The CURRENT report's envelope `coverage` block rides the
  answer verbatim when present, plus `coverageDelta: { nowUncovered, noLongerUncovered }` when the
  baseline's uncovered NAME SET differs (names only). Human TSV unchanged (pinned surface).
- **Per-fn `invisible`, module-qualified precision.** A member call whose confidently-resolved
  receiver root IS a blind imported module (`SomeSDK.doThing()`) now attributes `invisible` with
  exactly that module — precise, not file-granular, so the sweep-[33]/[36] no-flooding guard for
  member calls on stdlib/κ-pure receivers is untouched. (Report bytes change only for that shape —
  an added disclosure, the sound direction.)

### Host-resolution recall — constant strings + literal heads

Two recall improvements to the §1 host-refinement path (`Llm`/`Db`/`Net` uniformly), matching
candor-java; both conservative — any ambiguity stays bare `Net`, no fabrication:

- **Constant-string resolution** (conformance **PART 4q**). A host built from a string constant —
  `let apiBase = "https://api.openai.com"; URL(string: "\(apiBase)/chat")` (interpolation, bare
  ref, or const-left concat) — now resolves through the host-refinement path exactly like an inline
  literal. A module/global/static or local `let NAME = "literal"` is indexed; a var, runtime value,
  or non-const first segment stays bare `Net`, and ambiguous same-name consts resolve to nil.
- **Literal-head extraction** (conformance **PART 4r**). An interpolation/concat whose FIRST literal
  segment itself completes `scheme://authority/` — `"https://api.openai.com/v1/\(path)"` — now
  extracts the host and fires the refinement (was bare `Net`). A split authority, interpolated
  port, or unterminated authority stays bare `Net`; a CDN-style head stays `Net` (no fabrication).

### spec 0.15 — the coverage-envelope rung (§2)

candor-swift now declares **spec `0.15`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.15 is another tier-2 (pinned-tool-surface) rung, additive over 0.14: it admits
the envelope `coverage` ledger and the coverage-conditional verdict surfaces into the pinned contract.
**⚠ report bytes change** — every envelope's `version`/`spec` strings, plus wherever a scan has
uncovered modules (the report gains the `coverage` field) or a newly-refined host shape (gains
`hosts`/`Llm`/`Db`) — so an upgrade across 0.15 is baseline-invalidating; and **⚠ the `spec` string
changed** — a consumer pinning `spec == "0.14"` must accept `0.15`.

## [0.14.1] — 2026-07-14

Patch — a soundness fix, still spec `0.14` (a false-pure hole closed; report bytes change for the fixed shapes).

- **Tuple-destructured global no longer dropped.** `let (a, b) = effectfulInit()` at file scope binds
  names (so it is not a `<main>` statement), but the identifier-pattern-only unit guard SILENTLY DROPPED
  its initializer effect — a `let (a, b) = readConfig()` global read pure (the cardinal sin, the top-level
  sibling). Each bound name now carries the shared initializer's effect (a sound first-touch
  over-approximation); the same fix covers a `static let (p, q) = …` type member. Found probing adjacent
  cases after the 0.14 top-level rung.

## [0.14.0] — 2026-07-14

### ⚠ FIXED — the top-level `<main>` initializer unit (a false-"pure" empty report — the cardinal sin)

A `main.swift` / script file whose **bare top-level executable statements** performed an effect was
SILENTLY DROPPED: those statements belong to no function, so the collector minted no unit for them and
the report came back a false-"pure" empty — the cardinal sin. A `deny Llm` / `deny Net` gate PASSED
such a file even though its top level opened a socket or called a model provider. The top level is now
synthesized as **one `<main>` unit per file**, carrying `unitKind: "initializer"`, with the file's
top-level effects and its transitive call edges — so the effect is disclosed and the gate now catches
it. The unit is minted **only when the top level carries or reaches an effect** — a pure top level mints
no unit (report bytes unchanged for pure files). Global-var initializers, computed properties, and
stored-property inits were already sound and are **unchanged**.

Conformance **PART 4p** pins the top-level-initializer unit four-way (java `<clinit>` / ts `<module>` /
swift `<main>`; rust N/A — no free top-level executable statements). **⚠ report bytes change** on any
file with an effectful top level (a previously empty/"pure" report gains the `<main>` unit), so an
upgrade across 0.14 is baseline-invalidating.

### spec 0.14 — the top-level-initializer rung (§3.1)

candor-swift now declares **spec `0.14`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.14 is another tier-2 (pinned-tool-surface) rung, additive over 0.13: it admits the
`<main>` top-level initializer unit (`unitKind: "initializer"`) into the pinned contract. **⚠ report
bytes change** where a file's effectful top level is now surfaced as a `<main>` unit (a report
previously seen as empty/"pure" gains the unit), so an upgrade across 0.14 is baseline-invalidating; and
**⚠ the `spec` string changed** — a consumer pinning `spec == "0.13"` must accept `0.14`.

## [0.13.0] — 2026-07-14

### ✨ NEW `Llm` effect — a model-provider call (boundary effect refining Net)

candor-swift now classifies a call to an LLM/model provider as the **`Llm`** effect — a boundary
effect that refines `Net` (the Db precedent: a specialised network reach kept distinct so a policy can
name it), so an `Llm` call also carries `Net`. Two recognisers: the shared **model-host table**
(`MODEL_HOSTS` + `isModelHost`, verbatim from the family — the OpenAI/Anthropic/Bedrock/Ollama-style
endpoints, with Ollama pinned to the `:11434` loopback and Bedrock matched on the first service label,
not an S3-bucket substring); and a curated **Swift model-SDK TYPE list** (MacPaw/OpenAI,
AnthropicSwiftSDK, Bedrock, **plus Apple on-device FoundationModels** — `SystemLanguageModel` /
`LanguageModelSession`, so local inference counts). The SDK table is keyed by type NAME — the syntactic
engine can't resolve module owners — and a project's own same-named type SHADOWS it, so a local type is
never fabricated as an `Llm`. `Llm` joins the boundary/salience/allow sets, and an `allow Llm` rides
the `Net` host surface.

### ✨ NEW `privacy/1` SPEC EXTENSION — Apple privacy-sensor effects + the manifest verb

The first candor **spec extension** (SPEC.md §Versioning engine-extensions clause; contract in
**SPEC-EXTENSION-privacy.md**) — swift-led and ecosystem-specific. It adds **six Apple privacy-sensor
effects** — `Location` / `Camera` / `Mic` / `Contacts` / `Photos` / `Notify` — classified by the Apple
framework TYPE a call reaches (`CLLocationManager`, `AVAudioRecorder`, `CNContactStore`,
`PHPhotoLibrary`, `UNUserNotificationCenter`, `AVCaptureSession`), with the same declared-type shadow
as the `Llm` SDK types (a local same-named type is not the framework's — no fabrication). AVFoundation
capture reads the visible `.audio`/`.video` media-type (audio→`Mic`, video→`Camera`); an ambiguous
capture OVER-discloses `{Camera, Mic}` — the privacy asymmetry (never UNDER-declare a sensor, the
inverse of the never-fabricate rule) — and `AVAudioEngine` is member-gated to `.inputNode` so a
playback-only engine carries no `Mic`. The six are boundary effects (containment + the sharp
salience-5 set), gate-able by deny/containment but NOT allowlistable (no host literal, like
`Ipc`/`Clipboard`) and not injection-class. The envelope discloses `extensions: ["privacy/1"]` **only
when a privacy effect is active** — a plain report stays byte-unchanged.

- **NEW `privacy-manifest` verb** — `candor-swift privacy-manifest [--report <locator>] [--verify
  <Info.plist>] [--json]`. GENERATES the required Apple usage-description keys from the code's
  transitive sensor reach, or VERIFIES an existing `Info.plist` against it: a reached capability the
  manifest omits is the App-Store-rejection-shaped **under-declaration** (exit 1); a declared-but-unused
  key is an over-declaration (warning, exit 0). The effect→key mapping and JSON shape are in
  SPEC-EXTENSION-privacy.md; plist parse via `PropertyListSerialization` (XML + binary, fail-loud
  exit 2). It reuses the query-verb report-locator + loud-load machinery (one source of truth).

### `gains` loader loudness (follow-through on the 0.12 verb)

Per-entry drops among otherwise-good entries are now DISCLOSED with a count (Rust wording); the loud
loader mirrors the reference net rule per side — no files → exit 2, net-empty with any hard failure →
exit 2 (tightening the previous exit-0 empty answer over a clean-empty + corrupt sibling), a partial
merge tolerated with a "delta is computed over a PARTIAL side" summary.

### spec 0.13 — the Llm + privacy-extension rung (§3.1)

candor-swift now declares **spec `0.13`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.13 is another tier-2 (pinned-tool-surface) rung, additive over 0.12: it admits the
`Llm` boundary effect and the `privacy/1` extension surface into the pinned contract. The `privacy/1`
extension carries its OWN version (`"privacy/1"` in the envelope `extensions` array — independent of the
spec string). **⚠ report bytes change** where an `Llm` or a privacy sensor is now classified (a call
previously seen as plain `Net`, or unclassified, gains the refined effect), so an upgrade across 0.13 is
baseline-invalidating; and **⚠ the `spec` string changed** — a consumer pinning `spec == "0.12"` must
accept `0.13`.

## [0.12.0] — 2026-07-14

### ✨ NEW `gains` verb — the supply-chain alarm (this engine's first)

`candor-swift gains <current> <baseline> [--json]` lists every `fn\teffect` the surface **gained**
between two reports (current `inferred` minus baseline, per function, sorted) — the alarm a CI job
raises when a dependency update quietly grows a capability. Both positionals are report locators (the
family's two-positional comparative form, like `diff` — no discovery, no policy); the default output is
the byte-stable `fn\teffect` TSV, `--json` the `{baseline_version, byFunction, engine_version, gained}`
machine form. Each `byFunction` entry carries **`origin`**: `existing` (the function was there at the
baseline and now performs the effect — the supply-chain *attack* signal), `new` (a new function grew
the effect — a feature), or `unknown`. Existence is keyed on the **baseline callgraph sidecar**
(reports omit pure functions, so a baseline-pure function is a graph node with no report entry); a
**partial** graph — a matched sidecar that fails to read or parse — degrades the negative claim to
`unknown`, never a mislabel, while a node still in the partial graph stays `existing`. Mirrors the
Rust reference `candor-query gains`; pinned four-way by conformance PART 5b.

### Report acceptance + loudness on the comparative verb

- **Legacy bare-array reports accepted** — the v0.1 form, including the clean-empty `[]` the other
  three engines already answer on (was a four-way divergence: candor-swift alone exited 2).
- **All-junk reports fail loud** — a non-empty `functions` array in which every entry is unusable is
  corruption (exit 2 + a naming stderr line), never an empty `{byFunction:[],gained:[]}` all-clear at
  exit 0; a well-formed empty array stays a valid pure report.
- **Producing-build provenance** — `gains --json` carries the unconditional
  `baseline_version`/`engine_version` fields (`""` = unknown), and when both are known and differ a
  §2.1 stderr ⚠ discloses that a "gained capability" may be the engine reclassifying, not the
  dependency changing (the TSV stdout is unchanged — the disclosure is stderr-only).

### spec 0.12 — the gains-origin rung (§3.1)

candor-swift now declares **spec `0.12`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.12 is another tier-2 (pinned-tool-surface) rung, additive over 0.11 and
invocation-compatible with it: it promotes the §3.1 `gains` **`origin`** field and the provenance
fields into the pinned contract, four-way (conformance **PART 5b**, including the partial-sidecar and
no-baseline cases). No report-schema, classifier, or verdict change — a 0.11 report/verdict is
byte-identical under 0.12. **⚠ the `spec` string changed** — a consumer pinning `spec == "0.11"` must
accept `0.12`.

## [0.11.0] — 2026-07-13

### spec 0.11 — the surprising-reach surface rung (§3.1)

candor-swift now declares **spec `0.11`** (`specVersion` in `main.swift`; the envelope + `--gate-json`
verdict carry it). 0.11 is another tier-2 (pinned-tool-surface) rung: it promotes the **§3.1
surprising-reach surface** into the pinned contract — the scan-time opener (the single most surprising
transitive reach, a mundane-named function inheriting a boundary effect from hops away, with a
ready-to-run `candor path` command) and the **`tour [N]`** verb (the same deterministic ranking on
demand, top-N default 10, plus a pinned `--json` shape). One shared heuristic across the four engines,
with a **salience floor** (`Clock`/`Log`/`Rand` never surface), **module-segment test exclusion**
(drops `*Tests`/`tests::`, never a production `test_connection`), and the plain "nothing hidden"
fallback over a manufactured surprise. Pinned four-way by conformance **PARTs 4f–4k**. No
report-schema, classifier, or verdict change — a 0.10 report/verdict is byte-identical under 0.11.
**⚠ the `spec` string changed** — a consumer pinning `spec == "0.10"` must accept `0.11`.

### ✨ NEW `path` verb — the provenance chain to the nearest source

`candor-swift path <fn> <effect>` walks the saved callgraph (BFS, sorted frontier) from a function to
the **nearest source of an effect** and prints the human chain — byte-identical to the Rust
reference — plus a `--json` form. This is the command the scan opener suggests; before 0.11 the swift
engine printed the suggestion without having the verb, a dead end for cold readers.

### Corrupt-report loudness parity

A **located report that yields no trustworthy functions fails loudly** (exit 2) — found-but-corrupt is
never an empty all-clear, while a well-formed `functions: []` stays a valid pure report. A
missing/empty callgraph sidecar falls back to the report's inline `calls` (never a false "nothing
hidden"); a present-but-corrupt sidecar gets a stderr disclosure; `tour 0` exits 2 instead of a false
all-clear. Pinned by conformance PARTs 4h and 4k.

### Plural `packages` tour-header label

`reportPackage` honours the SPEC §2 plural `packages` envelope (the JVM shape): the tour header labels
a multi-package report by the list's longest common dotted prefix (one entry verbatim; none shared →
basename fallback), so a cross-engine query over a JVM report names the code, not the filename.
Pinned by the conformance 4g addendum.

### Coverage-ledger marker: `classifier doesn't cover`

The de-jargoned ledger marker ships in this release — the [0.10.0] entry below describes the rename,
but the κ retirement landed after the v0.10.0 tag, so 0.11.0 is the first release carrying it. A
consumer grepping the old `κ doesn't know` marker must update to `classifier doesn't cover`.

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
