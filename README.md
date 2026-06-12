# candor-swift

**The Swift implementation of [candor-spec](https://github.com/tombaldwin/candor-spec) 0.4** — per-function
side effects (Net/Fs/Db/Exec/Env/Clock/Ipc/Log/Rand/Clipboard), transitively across the call graph, with
the §6.2 policy gate. The fourth engine in the candor family (Rust · JVM · TypeScript · Swift), written
from the spec and validated against the shared conformance oracle: **20/20 on first run**.

```sh
swift build -c release
.build/release/candor-swift <package-dir>          # writes <dir>/.candor/report.json + callgraph sidecar
.build/release/candor-swift <dir> --policy gate.pol  # §6.2 deny/pure/allow/forbid; exit 1 on violation
```

Built on [SwiftSyntax](https://github.com/swiftlang/swift-syntax) — syntactic, like `candor-scan`: no
build of the target needed. Spec-0.4 obligations carried from day one: universal `hash` emission
(`pkg#qual`, so reports chain as `CANDOR_DEPS` siblings of the other engines), the **κ-coverage ledger**
(`κ doesn't know N modules this code imports…` — unlisted third-party modules are INVISIBLE, not
`Unknown`, and the receipt names them per scan), and the four literal surfaces (`hosts`/`cmds`/`paths`/
`tables`, with the SPEC §2 SQL table extraction token-for-token).

## The trust contract (§4), Swift edition

- A **function-typed value invoked** (`let f: () -> Void` param, a closure-typed field `d.f()`) reads
  `Unknown` — never silent purity. `unknownWhy` names each origin (`callback:f`, `dispatch:Dyn.f`).
- **Dispatch through a local protocol** resolves to the visible conformers when narrow (≤12, the family's
  shared CHA bound) and reads honest `Unknown` otherwise.
- **Closures attribute lexically** (a `DispatchQueue.async { … }` body charges the scheduler — the
  family's closure-attribution rule), and local-receiver method calls resolve through param/let/ctor
  type inference.

## Honest v0 bounds (item 7)

The κ table covers the **platform frontier** (Foundation, Network, Dispatch, os, sqlite3) — third-party
packages contribute nothing and the ledger names them. Nested named functions attribute lexically to
their enclosing unit (an over-approximation, the sound direction). Not yet ported: `CANDOR_DEPS`
consumption (hashes are emitted, so candor-swift reports are already chainable *by* the other engines),
the read-only queries (§3.1), and the §7.13 soundness fuzzer — the fuzzer is the family's next ritual
for this engine, and until it lands the §4 claim here is implemented but not adversarially tested.

Licensed MIT OR Apache-2.0. Part of the [candor family](https://github.com/tombaldwin/candor).
