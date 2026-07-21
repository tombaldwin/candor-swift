# Swift confirmatory arm — strengthened run adjudication (CI, 2026-07-21)

The strengthened run (baseline-subtraction, named-vs-`Unknown`, `-k` per-function) on the 3 held-out packages:

| package | observed_raw | named | unknown_only | program viol | -k level | per-fn |
|---|---|---|---|---|---|---|
| ZIPFoundation 0.9.20 | Exec,Fs,Net | Fs | Exec,Net | 0 | perfn | H-holds |
| Path.swift 1.6.0 | Exec,Fs,Net | Fs | Exec,Net | 0 | perfn | **PF-VIOLATION[next@Net]** |
| FlyingFox 0.19.0 | Exec,Fs | Fs | Exec | 0 | perfn | H-holds |

**Program-level: 3/3 H-holds, 0 violations.** The `-k` per-function check ran on all three.

## The Path.swift `next@Net` PF-VIOLATION is a `-k` attribution artifact, not a candor miss

The `-k` check charged `Net` to `Path.swift`'s `next` (inferred `{Fs}`, no `Net`, no `Unknown`). Verified
against source (tag 1.6.0): **Path.swift performs no networking whatsoever** — no `URLSession`/`Network`/
`Socket`/`NWConnection`/`getaddrinfo` anywhere in `Sources/` (the only `http` strings are doc-comment URLs).
The flagged `next()` is the directory-listing iterator at `Sources/Path+ls.swift:41` — pure `Fs` (it reads
directory entries), which is exactly why candor inferred it `{Fs}`. So the `Net` the `-k` walk attributed to
`next` did **not** originate in `next` or anywhere in Path.swift; it is the XCTest runner's own socket (the
program-level `Net` in `observed_raw`, covered by `unknown_only`) charged to the wrong frame.

**Cause: leaf-name collision in the `-k` attribution.** The strengthening intersects demangled on-stack leaf
names with candor's reported function names. `next` is one of the most common leaf names in Swift (every
`IteratorProtocol`/`Sequence` conformer has one — stdlib, Foundation, XCTest). A `next` frame from a
*different* type on the stack when the harness `Net` fired matched Path.swift's reported `next`. candor's
classifier is correct (`next` does no `Net`); the over-flag is in the instrument.

**Direction: safe (over-flag).** The `-k` per-function check is a *stricter* additional datapoint layered on
the program-level gate; a `-k` false positive raises a flag that adjudication then dismisses, it never hides a
real miss (the program-level gate on `observed_raw` still stands). But it means the `-k` per-function numbers
must be read with a collision caveat.

**Fix (future work):** attribute on *fully-qualified* demangled frames (module + type + method), not leaf
names, so a foreign `next` cannot match a reported `next`; and subtract the harness-baseline stack frames
from the `-k` attribution the same way `observed_crate` subtracts them from the class set. Until then the
`-k` per-function result is reported as "fired, 1 flag, traced to a leaf-name-collision artifact."
