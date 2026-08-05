<!-- MAINTAINERS: this is the canonical doc. After editing it, regenerate the embedded Swift copy in the SAME commit or CI's drift gate (smoke.sh) fails: python3 gen-agents-doc.py -->
# Using candor-swift (instructions for an AI coding agent)

You are working in a Swift package. **candor-swift** tells you, for every function, which side
effects it can reach — network, filesystem, database, subprocess, env, clock — *including effects
inherited transitively through any chain of calls across files*. The language-agnostic consumption
contract is [candor-spec/AGENTS.md](https://github.com/tombaldwin/candor-spec/blob/main/AGENTS.md);
this file is the Swift-specific surface.

> **This document is embedded inside the binary.** `candor-swift --agents` prints the contract
> for the *installed* build — always prefer that over a vendored or fetched copy, which can
> describe a different candor-swift than the one you are running.

A computed property's getter/setter/observer (and a `lazy` initializer) is its own unit, named
`Type.property` and carrying `unitKind: "accessor"` (spec 0.23, informative); ordinary
functions omit the field. A file's TOP-LEVEL executable statements (the bare statements Swift allows
at file scope in `main.swift` / script files) are collected as one synthetic unit named `<main>`
carrying `unitKind: "initializer"` — but only when they carry an effect or reach one; a pure top level
mints no unit.

## Produce a report

```sh
git clone --depth 1 https://github.com/tombaldwin/candor-swift /tmp/candor-swift
( cd /tmp/candor-swift && swift build -c release )
/tmp/candor-swift/.build/release/candor-swift <package-dir>     # Tests/ and .build/ excluded
```

Writes `<dir>/.candor/report.<pkg>.Swift.json` (the spec-0.27 envelope) plus two sidecars:
`report.<pkg>.Swift.callgraph.json` (EVERY analyzed function a key — pure ones included, SPEC §2.2)
and `report.<pkg>.Swift.hierarchy.json` (each local type → its declared supertypes/protocols, for
dispatch-frontier queries). Add `--policy <file>` (or `CANDOR_POLICY`, or a checked-in
`.candor/config` with a `policy` line — discovered by walking UP from the scan TARGET, never the
CWD) to enforce a §6.2 policy: exit 1 on violation, 2 LOUDLY on an unreadable policy. A `pure` rule
forbids every *effect* but not the `Unknown` trust marker — `deny Unknown <scope>` is the explicit
strictness knob. `--gate-json <file|->` additionally writes the structured §3.3 verdict
`{ spec, ok, violations }` — plus, when the scan's coverage ledger is non-empty, an ADVISORY
`coverage: { uncovered: <n>, modules: [...] }` note (⟨0.15⟩): the verdict and exit code are
computed exactly as before (a gate does not fail on uncovered deps), the note only makes the blind
spot travel with the verdict.

**Chain sibling reports** with `CANDOR_DEPS=<report paths>` (or a checked-in config `deps` line —
whitespace/colon/comma-separated; a relative config value anchors to the config's home dir): an
unresolved call into a package a loaded report covers inherits that dep function's effects AND its
literal surfaces (SPEC §2) — scan the dep once, chain it everywhere; the coverage ledger names what to scan
next. Three trust rules at the join: a report from a DIFFERENT candor-swift build (or carrying no
version) reads `Unknown`, never a stale effect claim; an all-pure dep's EMPTY report is a purity
claim (the package is covered, not blind); a deps token naming no readable file — or an unparseable
report — exits 2, fail-closed (a configured dep must never silently read pure).

**Ratchet regressions** with `CANDOR_BASELINE=<saved report>` (or a checked-in config `baseline`
line — a relative value anchors to the config's home dir): an existing function GAINING an effect
versus the baseline is `[AS-EFF-005]`, exit 1 (new functions are exempt — reviewed as new code);
the records join the `--gate-json` verdict. A baseline is comparable only to its PRODUCING build
(§2.1): a corrupt, versionless, or cross-build baseline refuses to evaluate (exit 2, loud — never
a silent skip, never a bogus violation wave); an absent file is a stderr note and the guard is
inactive. Record one: `candor-swift <dir> --json > baseline.json`.

**Already installed? Report the version, then ask before upgrading.** If this project already has
candor — a `.candor/` report dir, or `candor-swift` built/on PATH — do this BEFORE you scan. Run
`candor-swift --version` (offline) and TELL THE USER plainly which build they're on, e.g. "This
project is on candor-swift 0.23.1 (spec 0.27)". (On an older build that predates `--version`, read
`candor.version`/`candor.spec` from an existing `.candor/report*.json` instead.)

**Staying current — candor can't check for you, *you* can.** candor never makes a network call to
see if it's out of date: its own policy is `deny Net` (it's an effect auditor — phoning home would
make it perform the exact effect it exists to forbid). So the version check is *your* job, not the
tool's. `candor-swift --version` prints the installed build + the spec contract it speaks (offline,
two lines: `candor-swift <ver> (spec <SPEC>)` then the upgrade incantation). Then YOU (you have
network; candor doesn't) compare the installed version against the latest GitHub release
([github.com/tombaldwin/candor-swift/releases](https://github.com/tombaldwin/candor-swift/releases)).
If it's behind, **ASK the user before upgrading** — e.g. "candor-swift 0.8.2 is available (you're on
0.8.1) — upgrade before I scan?" — and only if they agree, check out the latest RELEASE TAG and build:
`git fetch --tags && git checkout <latest vX.Y.Z> && swift build -c release` (a release tag, never a
bare `git pull` of main — an untagged HEAD is not a released build). Never upgrade silently. If it's current or the user declines, just proceed with the build they have;
if candor isn't installed at all, install it normally (clone + build, below).

**Report shape:** `{ "candor": {…, "spec": "0.27"}, "package": "<name>", "functions": [...] }` — an
ARRAY of entries keyed `fn` (`Type.method` for members, bare `name` for free functions), each with
`inferred` (full transitive set) / `direct` / `unresolved` / `hash` (`pkg#qual`, the §2 chain key)
/ optional `hosts`/`cmds`/`paths`/`tables`. ⟨0.15⟩ the envelope also carries
`"coverage": { "uncovered": [ { "name": "<module>", "calls": <n> }, … ] }` — the κ-coverage ledger
(the stderr `classifier doesn't cover` line) as data, same modules and import counts (swift counts
imports; the field name stays `calls` per the spec), OMITTED entirely when nothing is uncovered
(a fully-covered report is byte-identical to a pre-⟨0.15⟩ one). Consume it before trusting an
"all clear": those modules' effects are absent from the report, NOT claimed pure.
Only effectful-or-unresolved functions appear; a
function in the SIDECAR but absent from the report is pure **as far as this engine resolved** —
candor-swift claims §4 (below), but read `unresolved` before trusting any specific entry. **A MULTI-TARGET PACKAGE: SCAN ONCE PER SHIPPED BINARY.** `candor-swift <dir>` reads every `.swift`
file under `<dir>`, so a package with several products sharing a core charges each product with every
OTHER product's effects — and a `privacy-manifest --verify` against one product's `Info.plist` then
answers about code that product never compiles. `--target <name>` resolves that target's in-package
dependency closure from `Package.swift` and scans exactly those sources:

    candor-swift . --target MacApp        # this product and its closure, nothing else

It REFUSES rather than scanning less: an unknown target exits 2 and names the ones that exist, and so
does a closure member whose sources cannot be found. A scoped scan writes the one current report (use
`--out` to keep several) and qualifies its identity — `package` and every `hash` become
`<pkg>/<target>#…`, so the report CANNOT be joined as the whole package's. If you are chaining a scoped
report, that mismatch is deliberate: a miss resolves to disclosed, where reading it as the package
would claim purity over every function in the targets it never scanned.

For the
general read-only queries (show/where/callers/whatif) point candor-query or candor-ts-query at these
reports; candor-swift itself carries a few query subcommands, over a report a scan already wrote:

    candor-swift path       <fn> <Effect>                              # the call chain by which a fn comes to perform an effect (no policy)
    candor-swift fix        <fn> <Effect> [--report <locator>] --policy <file> [--json]   # the boundary FIX (JSON)
    candor-swift fix-gate   [--report <locator>] --policy <file> [--json]                 # a fix for EVERY crossing (JSON)
    candor-swift unverified [--report <locator>] --policy <file> [--json] [--strict]      # pure/deny layers that PASS but are Unknown (not PROVABLY clean)
    candor-swift tour [<N>]                                             # the N most surprising transitive reaches (default 10; no policy)
    candor-swift gains      <current> <baseline> [--json]              # effects the surface GAINED since the baseline (supply-chain alarm)
    candor-swift privacy-manifest [--verify [<plist>]] [--xml]      # generate/verify the Apple privacy manifest from the sensor reach (privacy/2); --xml = a paste-ready Info.plist fragment (on --verify, only the MISSING keys)
    candor-swift gate --report <locator> --policy <file> [--json] [--gate-json <f>]       # apply a policy to an EXISTING report, with NO scan

⟨0.24⟩ `gate --report <locator> --policy <file>` (SPEC §3.1) applies a policy to an EXISTING report
with no scan — the supply-chain gate (gate a dependency's published report without re-analysing code
you do not have), and the one route that reaches §6.2 as a function of a GIVEN signature rather than
through the classifier. Exit codes and verdict shape are exactly `--policy`'s on a scan: 0 clean,
1 violation, 2 could-not-evaluate. **`--json` IS `--gate-json -`** — the verb's machine output is the
verdict, not a report. It reads the report file(s) and NOTHING else: no callgraph sidecar, no chained
dep, no re-classification, so an entry ABSENT from the report is absent (the ⟨0.21⟩ purity claim) and
is never back-filled. Two rule kinds are REFUSED (exit 2, whole-policy) because the wire does not carry
their evidence and approximating them fails OPEN: **`forbid A -> B`** (a report has an entry only for a
function with an EFFECT, so a wholly pure unit is invisible while `forbid` matches on NAME) and
**`allow <E> …`** (the AS-EFF-008 surface-completeness marker does not ride the wire; `netClass:
unknown-host` is NOT that marker — it also names a merely unrecognised host). A third refusal is
per-(rule, function): a class-scoped **`deny Net[…]`/`deny Unknown[…]` whose scoping datum is ABSENT**
on a matched entry — measured, that narrowing silently succeeds *for lack of evidence* and returns
exit 0 where the bare `deny` returns 1. None of the three fires on a report this engine wrote.

`fix` is the remedial inverse of the policy gate (integrations/FIX-SPEC.md): when a function performs
an effect its layer forbids, it computes where the effect belongs (hoist it to the nearest allowed-
layer caller) and which functions become pure and thread the value — `{ site, deniedSpan, hoistTo,
layer, cleanHoist, policyAlternative }`, byte-for-byte the same remedy as candor-query/java/ts.
`fix-gate` does every deny/`pure` crossing at once. Advisory: it names the structure, you write the
code; a re-scan with the gate verifies. A policy is required (the fix is defined relative to the
boundary it crosses); `--report` is optional — omitted, the report is discovered from the repo's
`.candor/` dir (the scan's default output). An unreadable policy or a missing report fails loud (exit 2).
⟨0.24⟩ **Over a report declaring `unanalyzed`, `fix-gate` and `unverified` OMIT `ok`** and add
`incomplete: true` + the `unanalyzed` manifest (SPEC §3.2). Neither boolean is honest there: `true`
claims a clean result over a universe the report says it could not fully see, and `false` beside an
empty `remedies`/`unverified` array asserts a finding that was never made. `if (r.ok)` therefore reads
falsy and fails safe. The arrays still ship — a partial answer that says it is partial beats a refusal —
and `--strict` exits **2** (could-not-fully-evaluate), the gate's code for the same situation, not the 1
that would claim a finding. The GATE keeps `ok: false`: there the `false` is true, it did not certify.
⟨0.24⟩ **AN ADVISORY VERB MAY BE LESS CERTAIN THAN THE GATE, NEVER MORE** (SPEC §3.2). Where
`gate --report` refuses for want of evidence — a class-scoped `deny Net[…]` / `deny Unknown[…]` over a
report carrying no `netClass`, or no reason reachable for an `Unknown` — `unverified` NAMES the function
the gate could not judge (its `upgrade` is the evidence-free rule, `deny Net[unknown-host] app` →
`deny Net app`, never a derived class), `fix`/`fix-gate` withhold any remedy premised on that evidence,
all three carry the gate's own `unevaluated: [{ rule, why }]` array, `ok` is omitted, and `--strict`
exits **2**. `fix` answers `reason: unanswerable` there rather than `not-forbidden`, which would assert
the rule was evaluated and did not fire. `--class` does NOT filter these out: a hole nobody classified
could be of the class you asked for, so dropping it would let the filter succeed for lack of evidence.
`tour [<N>]` lists the N (default 10) most SURPRISING transitive reaches in the report — a benign-named
function that reaches a scary effect a few hops down — each with a ready-to-run `candor path` command;
`--json` for machines. No policy, read-only, the same heuristic as the scan-time note. A missing report
fails loud (exit 2).
`path <fn> <Effect>` traces the call chain by which `<fn>` comes to perform `<Effect>` — from the
function down to the nearest DIRECT source, each step indented one deeper, the source annotated
`[<Effect> source @ file:line]`. It is the ready-to-run follow-up the scan-note / `tour` print. No
policy, read-only; `--json` emits `{ effect, fn, path:[{ fn, loc, source }] }`. If the fn does not
perform the effect (or the source is not a local function) the chain is honestly empty. A missing
report or an unmatched fn fails loud (exit 2).
`privacy-manifest` (the `privacy/4` extension, SPEC-EXTENSION-privacy.md) turns the report's privacy-sensor
reach — the transitive union of Location/Camera/Mic/Contacts/Photos/Notify, which grep can't see — into an
Apple privacy declaration. With no `--verify` it GENERATES the required Info.plist usage-description keys
(each with the reaching functions); `--verify <Info.plist>` diffs the plist's declared keys against the
reach — a reached effect with no satisfying key is an UNDER-declaration (the App-Store-rejection finding,
exit 1), a declared sensor key with no reach is an OVER-declaration (an unused permission, a warning, still
exit 0). Notify needs no key (it gates at runtime). Read-only; `--json` emits `{ reached, required, declared,
underDeclared:[{effect,keys,fns}], overDeclared, ok }`. A missing report or an unreadable/unparseable plist
fails loud (exit 2).
`gains <current> <baseline> [--json]` diffs two reports (the supply-chain alarm). ⟨0.15⟩ the
`--json` answer re-discloses coverage: the CURRENT report's envelope `coverage` block rides it
verbatim when present (absent otherwise — a "no gains" over an uncovered dep must not read as total),
and when the baseline's uncovered NAME SET differs from the current's it also carries
`coverageDelta: { nowUncovered: [...], noLongerUncovered: [...] }` (names only). The human
`fn\teffect` TSV is a pinned consumer surface and is unchanged.
⟨0.15⟩ **the privacy-manifest verify verdict is coverage-CONDITIONAL**: when the report's
coverage ledger is non-empty (or any function carries `invisible`), the JSON gains `conditional: true`
and `coverage: { uncovered: <n>, modules: [...] }`, and the human output appends a `⚠ verdict is
conditional on N uncovered modules…` line — sensor usage inside an uncovered module is invisible to
this verify, so a clean answer holds only for the covered code (chain dep reports or scan the
workspace root to close the gap). Disclosure, not a gate: the exit code is unchanged (under-declaration
1, otherwise 0), and both keys are ABSENT on a fully-covered report.

## The trust rule — do not skip this

`inferred` is authoritative for what candor-swift resolved. A call through a function-typed value
(`let f: () -> Void` invoked, a closure-typed field `d.f()`) or a local protocol with no visible
conformer reads `Unknown` — `unknownWhy` names each origin (`callback:f`, `dispatch:Dyn.f`). Never
conclude a function is pure while `unresolved` is true. **And the coverage caveat:** the
classifier covers the platform frontier (Foundation, Network, Dispatch, os, sqlite3) — a
third-party package contributes NOTHING, invisible, not `Unknown`, UNLESS a chained sibling report
covers it (`CANDOR_DEPS`, above — then its entries join and its silence is a purity claim). **Two
kinds of chained report grant NO coverage**, so a key they do not answer falls back to the ledger's
hedge instead of reading pure: one produced by a DIFFERENT engine build (§2.1 — its entries are also
downgraded to `Unknown`), and one that **declares itself INCOMPLETE** — a non-empty ⟨0.21⟩
`unanalyzed`, i.e. it names source it could not analyze. The incomplete case keeps its entries
UNCHANGED (they were derived from source it *did* read); only its silence hedges, so chaining an
incomplete report is never worse than not chaining it. The
receipt **names the rest per scan** (the coverage ledger: `candor's classifier doesn't cover N
modules this code imports…`): never conclude "no effect" through a module that line names. Each
function ALSO carries an **`invisible`** list — the uncovered modules it
(transitively) makes an unresolved call into — so `inferred` is never an unqualified claim PER
FUNCTION: `inferred: []` with a non-empty `invisible` means "pure as far as candor could see, but it
could not see through these" (a LOWER bound), not "pure". Because the Swift engine is parse-only it
mostly attributes at FILE granularity — an unresolved unqualified call names every uncovered module
in the function's import scope, not the single resolved package — so `invisible` is an
over-approximation of the blind set (disclosed, never a silent-pure); a MODULE-QUALIFIED call
(`SomeSDK.doThing()`) attributes precisely, naming only that module ⟨0.15⟩.

## Swift-specific things to know

- **Closures attribute lexically**: a `DispatchQueue.global().async { … }` body charges the
  scheduling function (the family's closure-attribution rule); nested named functions likewise
  attribute to their enclosing unit (a documented over-approximation, the sound direction).
- **Protocol dispatch is bounded CHA** (≤12 local conformers, the family bound) — `store.save()`
  on an injected local protocol resolves to the conformers, or reads disclosed `Unknown`.
- **Constructors are edges**: `_ = C()` reaches `C.init` (the fuzzer's first catch — effects wired
  in an initializer were silently pure for one build).
- The §7.13 soundness harness is `fuzz.py` (9 forms, deterministic seeds); run it after touching
  resolution.
