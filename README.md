# candor-swift

**The Swift implementation of [candor-spec](https://github.com/tombaldwin/candor-spec) 0.18** — per-function
side effects (Net/Fs/Db/Exec/Env/Clock/Ipc/Log/Rand/Clipboard), transitively across the call graph, with
the §6.2 policy gate. One of the candor family's four code engines (JVM · Rust · TypeScript · Swift —
[candor-java](https://github.com/tombaldwin/candor-java) is the reference engine — plus
[candor-agents](https://github.com/tombaldwin/candor-agents) for agent fleets), written
from the spec and validated against the shared conformance oracle: **20/20 on first run**.
Changes per release: [CHANGELOG.md](CHANGELOG.md).

```sh
swift build -c release
.build/release/candor-swift <package-dir>            # writes <dir>/.candor/report.<pkg>.Swift.json
                                                     #   + .callgraph.json / .hierarchy.json sidecars
.build/release/candor-swift <dir> --policy gate.pol  # §6.2 deny/pure/allow/forbid; exit 1 on violation
                                                     #   (or CANDOR_POLICY, or a checked-in .candor/config
                                                     #   `policy` line — discovered from the TARGET's
                                                     #   ancestors, never the CWD)
.build/release/candor-swift <dir> --policy gate.pol --gate-json verdict.json
                                                     # + the structured §3.3 verdict {spec, ok, violations}
                                                     #   (`--gate-json -` streams it to stdout)
CANDOR_BASELINE=base.json .build/release/candor-swift <dir>
                                                     # AS-EFF-005 regression guard (or a config `baseline`
                                                     #   line): an existing fn GAINING an effect vs the saved
                                                     #   report fails (exit 1; new fns exempt; a corrupt or
                                                     #   cross-build baseline refuses to evaluate, exit 2)
.build/release/candor-swift --version                # installed build + spec contract (offline) + upgrade line
.build/release/candor-swift --agents                 # the agent contract for THIS build (embedded AGENTS.md)
```

**Staying current:** check your installed version and upgrade — [candor/AGENTS.md §2a](https://github.com/tombaldwin/candor/blob/main/AGENTS.md#2a-staying-current--check-the-version-upgrade). `candor-swift --version` prints the build, the spec, and the upgrade one-liner (offline; candor never phones home).

Built on [SwiftSyntax](https://github.com/swiftlang/swift-syntax) — syntactic, like `candor-scan`: no
build of the target needed. Spec obligations carried from day one: universal `hash` emission
(`pkg#qual`, so reports chain as `CANDOR_DEPS` siblings of the other engines), the **coverage ledger**
(`candor's classifier doesn't cover N modules this code imports…` — unlisted third-party modules are INVISIBLE, not
`Unknown`, and the receipt names them per scan), and the four literal surfaces (`hosts`/`cmds`/`paths`/
`tables`, with the SPEC §2 SQL table extraction token-for-token). Net hosts are captured at
ESTABLISHING forms only (connect/ctor); a string arg at a use-verb (`writeAndFlush`) is payload,
never a host.

## The trust contract (§4), Swift edition

- A **function-typed value invoked** (`let f: () -> Void` param, a closure-typed field `d.f()`) reads
  `Unknown` — never silent purity. `unknownWhy` names each origin (`callback:f`, `dispatch:Dyn.f`).
- **Dispatch through a local protocol** resolves to the visible conformers when narrow (≤12, the family's
  shared CHA bound) and reads disclosed `Unknown` otherwise.
- A **`pure` policy rule forbids every effect, not `Unknown`** — the §4 trust marker is AS-EFF-003's
  concern, and `deny Unknown <scope>` is the explicit strictness knob where a boundary must also
  exclude uncertainty.
- **Closures attribute lexically** (a `DispatchQueue.async { … }` body charges the scheduler — the
  family's closure-attribution rule), and local-receiver method calls resolve through param/let/ctor
  type inference.

## Known v0 bounds (item 7)

The classifier covers the **platform frontier** (Foundation, Network, Dispatch, os, sqlite3) — third-party
packages contribute nothing and the ledger names them, unless a chained sibling report covers them:
`CANDOR_DEPS` / the config `deps` key (SPEC §2) join an unresolved call into a covered package to that
dep function's recorded effects + literal surfaces — a stale producer downgrades to `Unknown`, an
all-pure dep's empty report is a purity claim, and a bad token/report fails closed (exit 2). Nested
named functions attribute lexically to their enclosing unit (an over-approximation, the sound
direction). Not yet ported: the read-only queries (§3.1) — consume reports via `candor-query`, which
discovers this engine's `report.<pkg>.Swift.json` + the `hierarchy` sidecar natively. The §7.13 soundness fuzzer **has** landed (`fuzz.py`) — it threads a
known effect through receiver-typing idioms (singletons, fields, collections, casts, enum payloads,
nested receivers) and asserts every reachable function is effect-or-`Unknown`, so the §4 claim here is
now adversarially tested.

## Development

```sh
swift build                  # build → .build/debug/candor-swift
swift test                   # native unit tests (XCTest) over CandorCore: the classifier, the SQL/
                             # command/host extractors, the SwiftSyntax type helpers, the propagation fixpoint
bash smoke.sh                # end-to-end (the conformance oracle, the gate, the coverage ledger)
python3 fuzz.py              # the §7.13 soundness fuzzer (never silently pure)
python3 fabrication_probe.py # the never-fabricate probe
```

The pure cores live in the **`CandorCore`** library target (unit-tested); the executable imports them.
Compilation is gated by `-warnings-as-errors` (swiftSettings) — compiler warnings are build errors.

Licensed MIT OR Apache-2.0. Part of the [candor family](https://github.com/tombaldwin/candor) — [candor.poly.io](https://candor.poly.io).
