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
`Type.property` and carrying `unitKind: "accessor"` (spec 0.5 draft, informative); ordinary
functions omit the field.

## Produce a report

```sh
git clone --depth 1 https://github.com/tombaldwin/candor-swift /tmp/candor-swift
( cd /tmp/candor-swift && swift build -c release )
/tmp/candor-swift/.build/release/candor-swift <package-dir>     # Tests/ and .build/ excluded
```

Writes `<dir>/.candor/report.json` (spec-0.5 envelope) and `.candor/report.callgraph.json`
(EVERY analyzed function a key — pure ones included, SPEC §2.2). Add `--policy <file>` (or
`CANDOR_POLICY`) to enforce a §6.2 policy: exit 1 on violation, 2 LOUDLY on an unreadable policy.

**Report shape:** `{ "candor": {…, "spec": "0.5"}, "package": "<name>", "functions": [...] }` — an
ARRAY of entries keyed `fn` (`Type.method` for members, bare `name` for free functions), each with
`inferred` (full transitive set) / `direct` / `unresolved` / `hash` (`pkg#qual`, the §2 chain key)
/ optional `hosts`/`cmds`/`paths`/`tables`. Only effectful-or-unresolved functions appear; a
function in the SIDECAR but absent from the report is pure **as far as this engine resolved** —
candor-swift claims §4 (below), but read `unresolved` before trusting any specific entry. No
read-only query commands yet: compute blast radius from the callgraph sidecar (reverse the edge
map, BFS — ~10 lines of any scripting language).

## The trust rule — do not skip this

`inferred` is authoritative for what candor-swift resolved. A call through a function-typed value
(`let f: () -> Void` invoked, a closure-typed field `d.f()`) or a local protocol with no visible
conformer reads `Unknown` — `unknownWhy` names each origin (`callback:f`, `dispatch:Dyn.f`). Never
conclude a function is pure while `unresolved` is true. **And the curated-κ caveat:** the
classifier covers the platform frontier (Foundation, Network, Dispatch, os, sqlite3) — a
third-party package contributes NOTHING, invisible, not `Unknown`. The receipt **names these per
scan** (`κ doesn't know N modules this code imports…`): never conclude "no effect" through a module
that line names.

## Swift-specific things to know

- **Closures attribute lexically**: a `DispatchQueue.global().async { … }` body charges the
  scheduling function (the family's closure-attribution rule); nested named functions likewise
  attribute to their enclosing unit (a documented over-approximation, the sound direction).
- **Protocol dispatch is bounded CHA** (≤12 local conformers, the family bound) — `store.save()`
  on an injected local protocol resolves to the conformers, or reads honest `Unknown`.
- **Constructors are edges**: `_ = C()` reaches `C.init` (the fuzzer's first catch — effects wired
  in an initializer were silently pure for one build).
- The §7.13 soundness harness is `fuzz.py` (9 forms, deterministic seeds); run it after touching
  resolution.
