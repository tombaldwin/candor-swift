// GENERATED from AGENTS.md by gen-agents-doc.py — do not edit.
// The agent contract, embedded so `--agents` needs no resource bundle (a copied binary has none).
let AGENTS_MD = #####"""
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

Writes `<dir>/.candor/report.<pkg>.Swift.json` (the spec-0.23 envelope) plus two sidecars:
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
project is on candor-swift 0.22.0 (spec 0.23)". (On an older build that predates `--version`, read
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

**Report shape:** `{ "candor": {…, "spec": "0.23"}, "package": "<name>", "functions": [...] }` — an
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
candor-swift claims §4 (below), but read `unresolved` before trusting any specific entry. For the
general read-only queries (show/where/callers/whatif) point candor-query or candor-ts-query at these
reports; candor-swift itself carries a few query subcommands, over a report a scan already wrote:

    candor-swift path       <fn> <Effect>                              # the call chain by which a fn comes to perform an effect (no policy)
    candor-swift fix        <fn> <Effect> [--report <locator>] --policy <file> [--json]   # the boundary FIX (JSON)
    candor-swift fix-gate   [--report <locator>] --policy <file> [--json]                 # a fix for EVERY crossing (JSON)
    candor-swift unverified [--report <locator>] --policy <file> [--json] [--strict]      # pure/deny layers that PASS but are Unknown (not PROVABLY clean)
    candor-swift tour [<N>]                                             # the N most surprising transitive reaches (default 10; no policy)
    candor-swift gains      <current> <baseline> [--json]              # effects the surface GAINED since the baseline (supply-chain alarm)
    candor-swift privacy-manifest [--verify <Info.plist>]              # generate/verify the Apple privacy manifest from the sensor reach (privacy/1)

`fix` is the remedial inverse of the policy gate (integrations/FIX-SPEC.md): when a function performs
an effect its layer forbids, it computes where the effect belongs (hoist it to the nearest allowed-
layer caller) and which functions become pure and thread the value — `{ site, deniedSpan, hoistTo,
layer, cleanHoist, policyAlternative }`, byte-for-byte the same remedy as candor-query/java/ts.
`fix-gate` does every deny/`pure` crossing at once. Advisory: it names the structure, you write the
code; a re-scan with the gate verifies. A policy is required (the fix is defined relative to the
boundary it crosses); `--report` is optional — omitted, the report is discovered from the repo's
`.candor/` dir (the scan's default output). An unreadable policy or a missing report fails loud (exit 2).
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
`privacy-manifest` (the `privacy/1` extension, SPEC-EXTENSION-privacy.md) turns the report's privacy-sensor
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
covers it (`CANDOR_DEPS`, above — then its entries join and its silence is a purity claim). The
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
"""#####
