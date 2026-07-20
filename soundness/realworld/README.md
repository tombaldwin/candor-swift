# candor-swift real-world dynamic oracle

The **mechanism-independent** soundness check — the third tier after static analysis and cross-engine
conformance. Conformance is the *weakest* check (shared blind spots hide from agreement — the RQ3 point);
a runtime syscall trace shares no code, spec interpretation, or author intuition with the analyzer, so it
catches what agreement can't. candor-swift was the last engine without one (rust has a strace oracle, java a
bytecode agent, candor-ts `verify-core`).

## How it works (`run.sh`)

Each driver is a small Swift program exercising **one** real effectful API with a distinctive marker. The
harness compiles it, runs it under `strace`, and confirms the effect actually executed (the marker appears
in the syscall trace). If it did, it asserts candor-swift's **static** prediction for that program contains
the effect — **or** discloses uncertainty (`Unknown`/unresolved/invisible/blind/incomplete), which is
honest. An effect that demonstrably **ran** but which candor predicts nowhere and discloses nowhere
(silent-pure) is a real under-report — the cardinal sin. A pure control guards the fabrication mirror.

Linux + `strace` only (the swift CI Linux job; locally via a `swift:6.1` Docker container with
`--cap-add=SYS_PTRACE`). Wired as a standing gate in `.github/workflows/ci.yml`.

## Coverage

**Active** (validated end-to-end on Linux — marker fires, candor predicts the effect):

| driver | effect | how |
|--------|--------|-----|
| `fs_read`  | Fs | `String(contentsOfFile:)` → `openat` on the marker path |
| `fs_write` | Fs | `Data`/`String.write(toFile:atomically:false)` → `openat` on the marker path |
| `pure_ctrl` | — | pure arithmetic; nothing runs, nothing predicted (fabrication control) |

**Staged** (drivers written; candor predicts them correctly — `exec_proc`→Exec, `net_url`→Net — but the
marker does not yet fire under strace on Linux): Foundation `Process` routes through `posix_spawn` and
`URLSession` through libcurl, so the exec argv / connect address land differently than the naive string
marker expects. They are deliberately **left out of `CASES`** rather than left in to always-SKIP (a silent
coverage gap is exactly what candor exists to prevent). **TODO:** pin the Linux syscall attribution — e.g.
have the Exec child perform a directly-traced syscall on a marker path (proving it executed), and confirm
whether `URLSession`'s libcurl `connect` on Linux carries the literal address or a resolved form; re-add to
`CASES` only once the marker fires in this harness. Best iterated from real CI logs.
