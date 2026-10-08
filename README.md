# candor-swift

**The Swift implementation of [candor-spec](https://github.com/tombaldwin/candor-spec) 0.40** — per-function
side effects (Net/Llm/Fs/Db/Exec/Env/Clock/Ipc/Log/Rand/Clipboard), transitively across the call graph, with
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
                                                     #   line): a fn GAINING an effect vs the saved report
                                                     #   fails (exit 1) — ⟨0.40⟩ incl. a fn ABSENT from it
                                                     #   (prior ∅; a new pure fn passes); a corrupt or
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
  `Unknown` — designed never to read as silent purity (known open gaps, e.g. R792, are in candor-spec's
  SOUNDNESS.md). `unknownWhy` names each origin (`callback:f`, `dispatch:Dyn.f`).
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

### The named miss: dispatch through a DEPENDENCY's abstraction

SPEC §4 permits an engine to leave a dispatch through an external abstraction it does not model
unflagged **only if it is documented as a named miss** (§7 item 7). This is that document, and it is
written from measurements on this engine rather than from the intent.

**This engine cannot see that such a call IS a dispatch.** rust reads `&dyn iface::Backend`, java reads
`INVOKEINTERFACE`, TypeScript reads the named import; Swift source says only `b.size()` on a value
typed `Backend`, and whether `Backend` is a protocol, a class or a struct lives in a module this scan
never opened. What follows are the consequences, each measured on a three-package fixture (an
abstraction's owner, an effectful conformer, a consumer):

- **Chained, and nothing anywhere implements the abstraction: the consumer reads silently pure.** The
  row is `inferred: []`, `unresolved: false`, no `unknownWhy`, no `invisible` — it carries only the
  non-gating `dispatchesOn` key. `pure` and `deny Net` both **exit 0** over a call whose target this
  engine knows nothing about. (SOUNDNESS R533; three of the four engines behave this way, TypeScript
  is the one that discloses. Pinned four-way as conformance PART 92 `c9_consumer_zero_union`.)
- **Unchained, the disclosure depends on how the consumer's body is written.** A consumer that calls a
  free function taking the abstraction (`termSize(b)`) carries `invisible: [<blind modules>]`; a
  consumer that dispatches directly on the value (`b.size()`) carries none, and where the owning module
  cannot be decided its row is **absent from `functions[]` entirely** — under the ⟨0.21⟩ manifest that
  is a positive claim of purity, not a gap. (SOUNDNESS R548, open, PART 92 `c10_unchained_direct`. The
  obvious widening — treat EVERY such member call as a blind reach — was tried and **reverted**: it tagged
  a `NSPasteboard` receiver in a file that merely imports a blind module, which is false uncertainty in
  every such file, and this engine's own smoke gate rejects it.)
  **The narrower predicate now exists for one shape (SOUNDNESS R706, residual):** when the source SPELLS
  the receiver's owner as a protocol — `any P`, `some P` or a generic bound `<T: P>` — and `P` is neither
  declared in this package nor a platform/stdlib protocol (`PLATFORM_PROTOCOL_NAMES`,
  `STD_PURE_PROTOCOLS`, `STDLIB_ITERATION_PROTOCOLS`), the row carries `invisible: [<the file's one
  dependency module>]` — the same module a free call into that dependency names, and the same owner the
  ⟨0.39⟩ `dispatchesOn` key publishes. A judged-nothing chained report covers nothing (⟨0.24⟩), so that arm
  answers identically. Non-gating by design: `deny`/`pure` do not move. A BARE class-or-protocol spelling
  (`_ b: Backend`) is still undecided and keeps the row above.
- **The `dispatchesOn` key names an owner this engine GUESSES from the file's imports.** It is the
  file's single declared, non-platform dependency import; a file with zero or two such imports
  publishes no key at all, and a bound that is a protocol the scanned package declares *itself* is
  still keyed under that import. So a published key may name a package that does not own the
  abstraction, and a consumer joining on it finds nothing. (SOUNDNESS R532b.)

`CANDOR_DEPS` narrows the first of these — chaining the implementor's report lets the effect cross —
but it does not remove it: a chained abstraction with no implementor in *any* chained report still
reads pure.

### Documented resolved-pure dispatch: equality, hashing, coding and friends (SPEC §4)

SPEC §4 permits an engine to treat dispatch over a curated set of conventionally-pure standard-library
protocols as resolved-pure, and requires it to say WHICH. This engine's set is `STD_PURE_PROTOCOLS`
(`Sources/CandorCore/Classifier.swift`):

`Codable`, `Encodable`, `Decodable`, `Equatable`, `Hashable`, `Sendable`, `Comparable`, `Identifiable`,
`CaseIterable`, `RawRepresentable`, `CustomStringConvertible`, `CustomDebugStringConvertible`, `Error`,
`Strideable`, `OptionSet`, `AdditiveArithmetic` — and nine iteration protocols (`Sequence`,
`IteratorProtocol`, the five `Collection` refinements, `AsyncSequence`, `AsyncIteratorProtocol`), see below.

What "resolved-pure" means here, precisely, because it is narrower than it sounds:

- **It is a FALLBACK rule, not a pass.** It is consulted only where a project type conforms to one of
  these and an inherited requirement resolves to NO project body (a synthesized `==`, `hash(into:)`,
  `encode(to:)`): that call reads pure instead of disclosing `Unknown`. A HAND-WRITTEN witness is a
  project body and is charged normally — including when it is reached through a generic or a container:
  `a == b` inside `<T: Equatable>` (R951), `Set`/`Dictionary` operations (R974 b), and
  `a.hash(into:)` / `Hasher.combine(a)` inside `<T: Hashable>` (R1045) all reach the caller's witness.
- **Across a chain, equality and hashing ARE treated as resolved-pure (R974 a).** A dependency's
  `func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }` publishes no row, so a consumer calling it
  with its own effectful `==` is not charged. The one-tree scan charges it. This is the §4 permission
  exercised for `Equatable`/`Hashable` requirements reached in ANOTHER package; closing it needs a ⟨0.39⟩
  `dispatchesOn` key for a stdlib-owned requirement, which the spec does not yet spell.
- **The iteration protocols are in the
  set ONLY for the synthesized-requirement fallback.** SPEC §4 forbids extending resolved-pure to
  iterators, and this engine does not: a hand-written `next()`/`makeIterator()` is charged wherever the
  stdlib iterates the value — `for x in s`, a generic `<S: Sequence>` / `some` / `any` parameter iterated
  by a project function (answered at the caller's argument), stdlib algorithms (`reduce`, `map`,
  `contains`, …) on a local iterable, and `Array(s)`/`Set(s)`/`zip` (SOUNDNESS R1048). The caller's
  argument is aligned to the parameter BY LABEL (a labelled, defaulted-skip or `inout` argument answers like a
  positional one), and the same alignment serves R951's comparison witnesses and R974 (c)'s forwarding.

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
