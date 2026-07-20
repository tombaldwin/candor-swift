# candor-swift real-world dynamic oracle

The **mechanism-independent** soundness check — the third tier after static analysis and cross-engine
conformance. Conformance is the *weakest* check (shared blind spots hide from agreement — the RQ3 point);
a runtime syscall trace shares no code, spec interpretation, or author intuition with the analyzer, so it
catches what agreement can't. candor-swift was the last engine without one (rust has a strace oracle, java a
bytecode agent, candor-ts `verify-core`).

## How it works (`run.sh`)

Each driver is a small Swift program exercising **one** real effectful API with a distinctive marker. The
harness compiles it, runs it under `strace`, and confirms the effect actually executed (the marker appears
in the syscall trace). If it did, it renders a **three-way honesty verdict** per driver (mirroring
candor-ts `verify-core`):

1. **precise** — the effect is in candor's precise (non-`Unknown`) prediction. Held tightly.
2. **held by disclosure** — not precise, but candor disclosed `Unknown`. Honest, and **blame-tracked**: the
   `unknownWhy` reason names the exact unresolved edge (`dispatch:…`, `reflect:…`, `callback:…`) to resolve
   for a precise answer. (backlog P3 — blame-tracked `Unknown`.)
3. **violation** — neither: an effect that demonstrably ran but candor predicts nowhere and discloses
   nowhere. A silent-pure = the cardinal sin. Reds the gate.

A pure control guards the fabrication mirror. Linux + `strace` only (the swift CI Linux job; locally via a
`swift:6.1` Docker container with `--cap-add=SYS_PTRACE`). Wired as a standing gate in
`.github/workflows/ci.yml`.

## Coverage

| driver | effect | how the marker is traced |
|--------|--------|--------------------------|
| `fs_read`  | Fs | `String(contentsOfFile:)` → `openat` on the marker path |
| `fs_write` | Fs | `String.write(toFile:atomically:false)` → `openat` |
| `fs_filehandle` | Fs | `FileHandle(forWritingAtPath:)` opens an fd → `openat` |
| `fs_fh_read` | Fs | `FileHandle(forReadingAtPath:)` + `readToEnd()` → `openat` |
| `fs_data`  | Fs | `Data(contentsOf: fileURL)` → `openat` |
| `fs_remove` | Fs | `FileManager.removeItem` → `unlink` on the marker path |
| `exec_proc` | Exec | `Process` spawns `/bin/sh -c 'echo > <marker>'`; the CHILD's `openat` proves the subprocess ran (robust vs argv inside the parent's `posix_spawn`) |
| `exec_env` | Exec | `Process` with a set `environment` spawns `/bin/sh` → child `openat` |
| `net_url`  | Net | `URLSession` request → `connect` carries the TEST-NET marker IP |
| `net_raw`  | Net | raw `import Glibc; socket()`/non-blocking `connect(fd,&addr,len)` → `connect` carries the marker IP |
| `pure_ctrl` | — | pure arithmetic; nothing runs, nothing predicted (fabrication control) |

## Resolved: raw POSIX sockets now classify Net

An earlier note here recorded that candor-swift read a raw `import Glibc; connect()` as **pure** — a real
under-report this oracle surfaced. **Fixed** (`kappaFree`): the POSIX socket **wire verbs** now classify
`Net`, **gated on the exact C arity** and shadow-guarded by the call site's `localFreeFns`:
`connect`(3-arg), `sendto`/`recvfrom`(6-arg), `sendmsg`/`recvmsg`(3-arg). The collision-prone SETUP/common
verbs stay deliberately **absent** (`bind` is the GRDB `Statement.bind` case that once fabricated Net onto
214 fns; `socket`/`send`/`recv`/`listen` are too common as bare identifiers) — for those, under-reporting the
rare direct-syscall program still beats a wrong label on a common one. Regression: `ClassifierTests`
(connect(3)→Net, connect(2)/bind/socket/send→nil).

**Four-way check (2026-07-20):** the raw-socket gap was swift-SPECIFIC. The other engines classify their
low-level socket surface as `Net` already, because they are path/type-qualified and never had the bare-
identifier collision: rust `libc::connect`/`nix::sys::socket::connect`/socket2, java `Socket.connect` /
`SocketChannel.connect`, ts `net.Socket.connect` / `net.connect`. Verified by scanning a raw-socket program
through each engine (all → `Net`); no fix needed there.
