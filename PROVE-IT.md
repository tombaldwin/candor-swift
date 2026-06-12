# Prove it on *your* repo — a 15-minute self-experiment (Swift)

Same protocol as the family's pre-registered evals (the [Rust](https://github.com/tombaldwin/candor-rust/blob/main/PROVE-IT.md),
[JVM](https://github.com/tombaldwin/candor-java/blob/main/PROVE-IT.md) and
[TS](https://github.com/tombaldwin/candor-ts/blob/main/PROVE-IT.md) variants): your agent commits a
manual blast-radius trace BEFORE the tool runs, then verifies every diff at a file:line. Either
outcome is informative — including "candor didn't help here".

**Paste into your agent at the package root:**

```text
We're testing whether a static effect-analysis tool (candor-swift) tells me things about MY Swift
package that you'd otherwise miss or take longer to find. Follow IN ORDER — the order is the
experiment's integrity.

STEP 1 — Pick ONE production function (not Tests/) that performs I/O and has callers. State it.
STEP 2 — MANUAL TRACE, committed first: from source alone, list every TRANSITIVE caller of the
target across all files, one per line, named as the callgraph keys them (Type.method for members,
bare names for free functions; closures and nested functions fold into their enclosing function).
Write ./candor-manual-<target>.txt. Note how many file-reads/searches it took.
STEP 3 — git clone --depth 1 https://github.com/tombaldwin/candor-swift /tmp/candor-swift
         (cd /tmp/candor-swift && swift build -c release)
         /tmp/candor-swift/.build/release/candor-swift .
STEP 4 — Compute the tool's answer from .candor/report.callgraph.json (a keyed map): reverse the
edges, BFS from the target, save ./candor-tool-<target>.txt.
STEP 5 — Diff and VERIFY both directions at file:line (a candor miss through a function-typed
value or an unlisted module is its DOCUMENTED honest territory — check the receipt's κ line and
unknownWhy before calling it a bug; a genuinely dropped edge → file an issue).
STEP 6 — Scorecard, honestly, including the unflattering outcome.
```
