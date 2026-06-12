# Real-package sweep — robustness + analysis profile (2026-06-12)

The Swift analog of the family's calibration sweeps: six popular packages cloned at HEAD, one scan
each. **Measures:** robustness, speed, profile plausibility, and the fabrication direction.
**Not measured:** completeness ground truth (PROVE-IT's job).

## Current numbers (post recall fixes — accessors, implicit-self, protocol-field dispatch, NIO tier)

| package | files | analyzed | effectful | profile | receipt (κ ledger) | scan |
|---|---:|---:|---:|---|---|---:|
| swift-log | 12 | 177 | 33 | Unknown 33, Log 9 | clean | 0.35s |
| swift-argument-parser | 89 | 778 | 79 | Unknown 75, Fs 2, Net 1, Exec 1 | C, FoundationEssentials | 1.3s |
| swift-collections | 549 | 4436 | 750 | Unknown 747, Rand 47 | clean | 6.9s |
| Alamofire | 53 | 1069 | 285 | Unknown 272, **Net 36**, Fs 16, Clock 4, Rand 3 | zlib | 1.6s |
| GRDB.swift | 181 | 3092 | 952 | Unknown 746, **Db 713**, Rand 11, Fs 9, Clock 1 | SQLCipher (68 imports) | 4.6s |
| vapor | 220 | 1545 | 126 | Unknown 99, Log 28, Env 20, Net 5, Clock 5, Exec 4, Fs 3 | 39 modules (HTTPTypes, NIO\*, RoutingKit…) | 2.3s |

Spot-checks on the surprising cells: swift-argument-parser's `Net 1` is `ChangelogAuthors.run`
(a repo tool fetching github.com), its `Fs 2` are the two doc-generator `validate`s, `Exec 1` is
`executeCommand` — all real. GRDB's profile is what a SQLite wrapper should look like, and its
ledger names SQLCipher (68 imports) as the disclosed invisible frontier. vapor's ledger naming 39
unclassified NIO-ecosystem modules is the honest shape of a framework that delegates its I/O —
chaining (reports for those packages via the family's deps convention) is the closure, not more κ.

### Movement vs first contact (what each recall fix bought, measured)

- **GRDB 731→952 effectful, Db 506→713**: implicit-self field resolution + protocol-field
  dispatch — `self.db.execute(...)` through a protocol-typed field now resolves instead of
  silently missing.
- **Alamofire 204→285, Net 16→36**: accessor units (computed getters/observers are now analyzed
  bodies) + callback-flow resolution at all-named call sites.
- **vapor (new)**: scannable at all once the κ NIO tier landed (ClientBootstrap/Channel/HTTPClient
  verbs → Net); Env 20 is its `Environment` plumbing, real.
- **swift-argument-parser 73→79 effectful but Fs 6→2 / Exec 5→1 / Env 4→0**: the harness
  exclusions (Examples/, Package.swift manifests, plugins) removed non-package code the first
  sweep had wrongly counted as the library; the remaining carriers spot-check as real (above).
- **swift-collections Rand 141→47**: same cause — benchmark/example harness code excluded; the
  residual `Rand` (`shuffle`/`random` overloads consuming system entropy) is correct.
- **swift-log 30→33**: accessor units surfaced three computed-property carriers.

## What the FIRST run caught (all fixed same-day, the family thesis again)

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
4. **The Vapor ledger was silenced** by a bare `name:` regex swallowing `.product(name:)` names —
   the target-only manifest regex restored the 39-module disclosure.

## The honest residual

- **`Unknown` density is high by construction** (swift-log 33/33): measured across the family in
  candor's `docs/unknown-density.md` — the dominant density is HONEST (closure callbacks invoked,
  fn-typed members, over-bound dispatch). Closures stay opaque per the family rule; the §4
  contract says Unknown, not a guess. Do not chase 0%.
- swift-collections' residual `Rand 47` is **correct**: `BitSet.random`/`shuffle` convenience
  overloads genuinely consume system entropy (the verb-gated posture, same as the Rust `rand`
  rules).
- The package name in the swift-collections report is `UnstableContainersPreview` — that is the
  manifest's actual top-level package name at HEAD, not a bug.
