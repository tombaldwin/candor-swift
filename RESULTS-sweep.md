# Real-package sweep — robustness + analysis profile (2026-06-12)

The Swift analog of the family's calibration sweeps: five popular packages cloned at HEAD, one scan
each, first contact with real-world Swift. **Measures:** robustness, speed, profile plausibility,
and the fabrication direction. **Not measured:** completeness ground truth (PROVE-IT's job).

| package | files | analyzed | effectful | profile (post-fix) | scan |
|---|---:|---:|---:|---|---:|
| swift-log | 12 | 143 | 30 | Unknown 30, Log 9 | 0.4s |
| swift-argument-parser | 103 | 560 | 73 | Unknown 64, Fs 6, Exec 5, Env 4 | 1.4s |
| swift-collections | 587 | 3643 | 665 | Unknown 662, Rand 141 | 7.5s |
| Alamofire | 53 | 848 | 204 | Unknown 194, Net 16, Rand 3, Clock 3 | 1.6s |
| GRDB.swift | 181 | 2678 | 731 | Unknown 587, **Db 506**, Rand 8, Fs 5 | 4.5s |

## What the first run caught (all fixed same-day, the family thesis again)

1. **A real fabrication: bare-POSIX κ names.** GRDB read `Net` on 214 functions — a database
   library. Root cause: classifying bare free calls named `bind`/`connect`/`open`/… as syscalls;
   GRDB's local `bind(...)` sits on its hottest Statement path and smeared Net transitively. The
   whole bare-POSIX tier is now deliberately ABSENT from κ (raw syscalls in Swift arrive through
   imports the ledger names); under-report beats a wrong label.
2. **Harness code scanned as the package.** swift-collections read `Exec` from a benchmark BUILD
   PLUGIN spawning a Rust compiler probe. `Benchmarks/`, `Plugins/`, `Examples/`, `Snippets/` and
   the `Package.swift` manifest itself (the build.rs analog) are now excluded like `Tests/`.
3. **Ledger noise.** Self-imports of the package's own targets (GRDB, Logging) and libc/SDK shims
   (Musl, WinSDK, ucrt…) drowned the disclosure. Internal modules now come from `Sources/*` dir
   names + the manifest's own target names; the platform frontier covers the libc variants and
   Apple SDK frameworks. Post-fix the ledgers are high-signal: Alamofire names exactly `zlib`.

## The honest residual

- **`Unknown` density is high by construction** (swift-log 30/30): Swift's protocol-witness and
  closure-heavy style is this engine's calibration frontier, exactly like the TS engine's
  zod-era flood — sound, loud, and the next precision lever (protocol-CHA only covers
  narrow LOCAL conformances today; fn-typed members always read Unknown).
- `Rand` on swift-collections is **correct**: `BitSet.random`/`shuffle` convenience overloads
  genuinely consume system entropy (the verb-gated posture, same as the Rust `rand` rules).
- GRDB's `Db 506` is the profile a SQLite wrapper should have; its Fs 5 (file-path APIs) and
  Rand 8 (UUID/salts) spot-check plausibly.
