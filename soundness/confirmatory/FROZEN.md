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

## Result (GitHub CI, swift:6.1 Linux, 2026-07-21)

3/3 held-out packages: every kernel-observed effect class (Fs/Net/Exec) is **covered** by candor-swift.
**0 program-level false all-clears; H holds on all.**

| package | tag | observed | covered | violations |
|---|---|---|---|---|
| ZIPFoundation | 0.9.20 | Fs,Net,Exec | Fs,Net,Exec | 0 |
| Path.swift | 1.6.0 | Fs,Net,Exec | Fs,Net,Exec | 0 |
| FlyingFox | 0.19.0 | Fs,Exec | Fs,Exec | 0 |

Same honest caveat as the Rust arm: program-level, and the XCTest harness inflates `observed` (safe
direction). Mechanism-independent kernel oracle on held-out Swift packages.
