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

| driver | effect | how the marker is traced |
|--------|--------|--------------------------|
| `fs_read`  | Fs | `String(contentsOfFile:)` → `openat` on the marker path |
| `fs_write` | Fs | `String.write(toFile:atomically:false)` → `openat` on the marker path |
| `exec_proc` | Exec | `Process` spawns `/bin/sh -c 'echo ran > <marker>'`; the CHILD's `openat` on the marker path proves the subprocess ran (robust vs matching argv inside the parent's `posix_spawn`) |
| `net_url`  | Net | `URLSession` request to a TEST-NET-1 address (RFC 5737) → `connect` carries the literal marker IP |
| `pure_ctrl` | — | pure arithmetic; nothing runs, nothing predicted (fabrication control) |

`fs_read`/`fs_write`/`pure_ctrl` are validated end-to-end on Linux CI. `exec_proc`/`net_url` use markers
chosen to trace reliably under Foundation's Linux syscall routing (`Process`→`posix_spawn`,
`URLSession`→libcurl); a driver whose effect doesn't execute under strace a given run is SKIPped (logged),
never a failure — the gate only reds on a genuine under-report.

## Observed scope boundary (not a driver — a note)

candor-swift classifies a **raw POSIX socket** (`import Glibc; socket()/connect()`) as **pure** — no `Net`,
no disclosed uncertainty. Idiomatic Swift reaches the network through `URLSession`/`Network.framework` (both
modelled → `Net`), so this is arguably out of scope, but a program doing a bare `connect()` reads silent-pure.
Recorded here as a candid gap for a future decision (model it → `Net`, or disclose `Unknown`); the oracle's
Net driver deliberately uses `URLSession` so it exercises candor's real, honest prediction.
