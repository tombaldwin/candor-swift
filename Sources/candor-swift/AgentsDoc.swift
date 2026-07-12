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
`Type.property` and carrying `unitKind: "accessor"` (spec 0.10, informative); ordinary
functions omit the field.

## Produce a report

```sh
git clone --depth 1 https://github.com/tombaldwin/candor-swift /tmp/candor-swift
( cd /tmp/candor-swift && swift build -c release )
/tmp/candor-swift/.build/release/candor-swift <package-dir>     # Tests/ and .build/ excluded
```

Writes `<dir>/.candor/report.<pkg>.Swift.json` (the spec-0.10 envelope) plus two sidecars:
`report.<pkg>.Swift.callgraph.json` (EVERY analyzed function a key — pure ones included, SPEC §2.2)
and `report.<pkg>.Swift.hierarchy.json` (each local type → its declared supertypes/protocols, for
dispatch-frontier queries). Add `--policy <file>` (or `CANDOR_POLICY`, or a checked-in
`.candor/config` with a `policy` line — discovered by walking UP from the scan TARGET, never the
CWD) to enforce a §6.2 policy: exit 1 on violation, 2 LOUDLY on an unreadable policy. A `pure` rule
forbids every *effect* but not the `Unknown` trust marker — `deny Unknown <scope>` is the explicit
strictness knob. `--gate-json <file|->` additionally writes the structured §3.3 verdict
`{ spec, ok, violations }`.

**Chain sibling reports** with `CANDOR_DEPS=<report paths>` (or a checked-in config `deps` line —
whitespace/colon/comma-separated; a relative config value anchors to the config's home dir): an
unresolved call into a package a loaded report covers inherits that dep function's effects AND its
literal surfaces (SPEC §2) — scan the dep once, chain it everywhere; the κ ledger names what to scan
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
project is on candor-swift 0.10.0 (spec 0.10)". (On an older build that predates `--version`, read
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

**Report shape:** `{ "candor": {…, "spec": "0.10"}, "package": "<name>", "functions": [...] }` — an
ARRAY of entries keyed `fn` (`Type.method` for members, bare `name` for free functions), each with
`inferred` (full transitive set) / `direct` / `unresolved` / `hash` (`pkg#qual`, the §2 chain key)
/ optional `hosts`/`cmds`/`paths`/`tables`. Only effectful-or-unresolved functions appear; a
function in the SIDECAR but absent from the report is pure **as far as this engine resolved** —
candor-swift claims §4 (below), but read `unresolved` before trusting any specific entry. For the
general read-only queries (show/where/callers/whatif) point candor-query or candor-ts-query at these
reports; candor-swift itself carries only two query subcommands, over a report a scan already wrote:

    candor-swift fix        <report-prefix> <fn> <Effect> <policy-file>  # the boundary FIX (JSON)
    candor-swift fix-gate   <report-prefix> <policy-file>               # a fix for EVERY crossing (JSON)
    candor-swift unverified <report-prefix> <policy-file> [--strict]    # pure/deny layers that PASS but are Unknown (not PROVABLY clean)

`fix` is the remedial inverse of the policy gate (integrations/FIX-SPEC.md): when a function performs
an effect its layer forbids, it computes where the effect belongs (hoist it to the nearest allowed-
layer caller) and which functions become pure and thread the value — `{ site, deniedSpan, hoistTo,
layer, cleanHoist, policyAlternative }`, byte-for-byte the same remedy as candor-query/java/ts.
`fix-gate` does every deny/`pure` crossing at once. Advisory: it names the structure, you write the
code; a re-scan with the gate verifies. A policy is required (the fix is defined relative to the
boundary it crosses); an unreadable policy or a missing report fails loud (exit 2).

## The trust rule — do not skip this

`inferred` is authoritative for what candor-swift resolved. A call through a function-typed value
(`let f: () -> Void` invoked, a closure-typed field `d.f()`) or a local protocol with no visible
conformer reads `Unknown` — `unknownWhy` names each origin (`callback:f`, `dispatch:Dyn.f`). Never
conclude a function is pure while `unresolved` is true. **And the curated-κ caveat:** the
classifier covers the platform frontier (Foundation, Network, Dispatch, os, sqlite3) — a
third-party package contributes NOTHING, invisible, not `Unknown`, UNLESS a chained sibling report
covers it (`CANDOR_DEPS`, above — then its entries join and its silence is a purity claim). The
receipt **names the rest per scan** (`κ doesn't know N modules this code imports…`): never conclude
"no effect" through a module that line names. Each function ALSO carries an **`invisible`** list — the κ-unknown modules it
(transitively) makes an unresolved call into — so `inferred` is never an unqualified claim PER
FUNCTION: `inferred: []` with a non-empty `invisible` means "pure as far as candor could see, but it
could not see through these" (a LOWER bound), not "pure". Because the Swift engine is parse-only it
attributes at FILE granularity — it names every κ-unknown module in the function's import scope where
the function has an unresolved external reach, not the single resolved package — so `invisible` is an
over-approximation of the blind set (disclosed, never a silent-pure).

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
