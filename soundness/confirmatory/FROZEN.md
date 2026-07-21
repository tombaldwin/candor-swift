# FROZEN confirmatory corpus — Swift (syscall arm)

The Swift analog of `candor-java/eval/corpus-confirmatory` and `candor-rust/soundness/confirmatory`. The
**mechanism is already proven and CI-green**: `soundness/realworld/run.sh` runs Swift programs under
`strace` and checks candor-swift's prediction against the kernel (Fs/Net/Exec), with a 3-way honesty verdict
+ blame-tracking. This directory adds the **frozen, pre-registered** discipline on a **held-out** Swift-package
corpus, executed on the swift CI Linux job.

> Status: **harness + pre-registration authored; run wired into CI** (`.github/workflows/confirmatory-corpus.yml`),
> where the swift:6.1 Linux container has `strace` — the proper home, since Swift builds SwiftSyntax from
> source (slow) and the author's local Docker was too CPU-starved to run it. No Swift confirmatory *result*
> is claimed until CI runs it; the JVM arm is the one executed frozen result to date.

## What is frozen (in this commit, before the run)

- **Engine:** `candor-swift`, built from THIS commit's source (the source pin is the freeze).
- **Corpus:** `manifest.tsv` — held-out packages (version-pinned), **excluding the dogfooded set**
  (`Files`/`ShellOut`/`SQLite.swift`/`swifter`/`GRDB` — see the swift dogfood notes).
- **Protocol:** per package — `candor-swift` scans the source → per-function report; `swift build
  --build-tests` builds the package's **own** XCTest bundle; that bundle is run under `strace -f`; observed
  `openat`/`connect`/`execve` map to `Fs`/`Net`/`Exec`; **program-level H** — every observed class must be
  named by some function or disclosed `Unknown`; a violation is an observed class no function covers.
- **Acceptance:** zero *undisclosed* observed-effect classes; disclosed `Unknown` is a pass; reported not fixed.

### Columns emitted (`results/FROZEN-SUMMARY.tsv`)

`package  tag  observed_raw  observed_crate  named  unknown_only  violations  level  verdict`

- **`observed_raw`** — every effect class the kernel emitted under strace. **This is the set the H-violation
  check runs on.**
- **`observed_crate`** *(informational)* — `observed_raw` minus a measured **harness baseline**. Before the
  corpus loop the harness builds a throwaway SwiftPM package with one empty XCTest and runs *its* test
  bundle through the identical strace pipeline, recording the classes XCTest + the Swift runtime + the
  loader produce themselves (dlopen of runtime dylibs → `Fs`; a runtime control socket → `Net`). Subtracting
  gives a coverage story about the package's *own* effects, not the runner's. **⚠ This column NEVER gates** —
  subtracting the baseline from the checked set could delete a class that is both a harness artifact and a
  genuine package effect, hiding a real under-report (the cardinal sin). Over-observation is the safe
  direction, so the violation check stays on `observed_raw` (a loud banner + a `SOUNDNESS:` comment in
  `run_frozen.sh` pin this; the Python iterates `observed_raw`).
- **`named`** *(strong)* — observed_raw classes some function's `inferred` set literally contains.
- **`unknown_only`** *(weak)* — observed_raw classes covered *only* by a disclosed `Unknown`. Honest but
  near-vacuous; the split from `named` says how strongly each class is held.
- **`violations`** — observed_raw classes NO function names AND NO function discloses `Unknown` (cardinal
  sin). Empty = H holds.
- **`level`** — `perfn` when the `-k` kernel stacks reconstructed and a frame demangled to a reported
  package function (a real per-function check ran); `program` on the honest fallback.

### Per-function `-k` check (best-effort, honest fallback)

Each test bundle is also traced with `strace -k`. Swift `$s…` frames are batch-demangled via
`swift-demangle` (shipped in the swift toolchain image), reduced to a method/func leaf, intersected with the
functions candor reported for this package, and each on-stack package function is checked for per-function H
(names the class or discloses `Unknown`). A package function on the stack at an effect it reads pure and
does not disclose is a `PF-VIOLATION`, attributed to the exact function. When `swift-demangle` is absent or
no effect stack yields an attributable package frame, the package records `level=program` and only the
program-level verdict stands — we never claim per-function on a program-level-only run.

## Result (GitHub CI, swift:6.1 Linux, 2026-07-21)

3/3 held-out packages: every kernel-observed effect class (Fs/Net/Exec) is **covered** by candor-swift.
**0 program-level false all-clears; H holds on all.** The table is the earlier program-level view; the
harness now also emits `observed_crate` (baseline-subtracted, informational), the `named` / `unknown_only`
split, and a per-function `level` (see *Columns emitted*) — those land on the next CI run of this commit.

| package | tag | observed_raw | named | unknown_only | violations |
|---|---|---|---|---|---|
| ZIPFoundation | 0.9.20 | Fs,Net,Exec | Fs | Net,Exec | 0 |
| Path.swift | 1.6.0 | Fs,Net,Exec | Fs | Net,Exec | 0 |
| FlyingFox | 0.19.0 | Fs,Exec | Fs,Net | Exec | 0 |

(The split is illustrative of the new columns' shape — a package's own Fs/Net is function-named; classes
that come from the XCTest runner are typically held only by a disclosed `Unknown`. Exact values are
whatever CI records.)

Same caveat as the Rust arm, stated plainly: the primary check is **program-level** on `observed_raw`, not
per-function; the `-k` per-function upgrade is best-effort and falls back to `program` when Swift frames
don't demangle. The XCTest harness inflates `observed_raw` (safe direction); `observed_crate` reports it
baseline-removed but **only informationally** — the violation check reads `observed_raw`, since
baseline-subtracting the checked set could mask a real package effect sharing a class with a harness
artifact. Mechanism-independent kernel oracle on held-out Swift packages.
