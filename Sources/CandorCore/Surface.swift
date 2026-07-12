// Surface the single most SURPRISING transitive reach (the cold-repo hook).
//
// After the effect summary + κ ledger, candor-swift emits ONE more stderr line: the most surprising
// transitive reach in the package + a ready-to-run `candor path` command. This is the Swift port of
// candor-scan's `src/surface.rs` — SAME behaviour, so every engine surfaces the same reach on a shared
// fixture (candor-rust/SURFACE-BEST-FIND-DESIGN.md, phase P3 cross-engine parity).
//
// Fully deterministic — pure call-graph + name analysis, NO LLM. A CANDIDATE is a function `F` that
// INHERITS an effect `E` (E ∈ inferred[F] but E ∉ direct[F]); we BFS to the nearest local direct SOURCE
// `S` and score by how surprising the reach is (a benign-named function reaching a scary effect). The
// find is never *wrong*: `candor path` re-derives the chain and the gate is ground truth. When nothing
// clears the bar we emit an honest "nothing hidden" fallback — never a manufactured surprise.
//
// Swift note: the qualified-name separator is `.` (e.g. `Settings.load`, `Foo.Bar.baz`), where the Rust
// reference uses `::`. Everything else — the lexicons, the score, the tie-break, the emitted text — is
// byte-for-byte the reference behaviour.

import Foundation

/// Name tokens that read as local / pure / config — a function whose leaf is named like this reaching a
/// scary effect is the core surprise signal. COPIED verbatim from surface.rs's BENIGN.
private let BENIGN: Set<String> = [
    "settings", "config", "conf", "options", "opts", "util", "utils", "helper", "helpers", "model",
    "models", "dto", "entity", "format", "fmt", "parse", "get", "load", "new", "default", "validate",
    "valid", "render", "view", "build", "builder", "item", "entry", "record", "state", "context",
    "ctx", "info", "meta", "data", "value", "node", "field", "name", "key", "id", "path", "kind",
    "type", "status", "check", "init", "setup",
]

/// Name tokens that are effect-suggestive — a function in/near an effect-flavored context reaching that
/// effect is EXPECTED, not surprising, so we EXCLUDE it. COPIED verbatim from surface.rs's EFFECTY.
private let EFFECTY: Set<String> = [
    "fetch", "http", "https", "client", "api", "sync", "request", "req", "download", "upload", "query",
    "sql", "store", "save", "persist", "connect", "conn", "socket", "send", "recv", "read", "write",
    "open", "file", "fs", "io", "net", "tcp", "udp", "dns", "url", "host", "port", "cmd", "command",
    "shell", "process", "proc", "exec", "spawn", "env", "clock", "time", "now", "rand", "random",
    "log", "logger", "trace", "db",
]

/// Split a qualified name (or a leaf) into lowercase tokens on `.`, `_` and camelCase boundaries.
/// (The Rust reference also splits on `:`; a Swift qual uses `.` as its separator, so `.` is added and
/// `:` is kept harmless — neither appears in a Swift member qual.)
func surfaceTokenize(_ name: String) -> [String] {
    var out: [String] = []
    var cur = ""
    var prevLower = false
    for ch in name {
        if ch == "_" || ch == ":" || ch == "." {
            if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
            prevLower = false
            continue
        }
        // camelCase boundary: a lower/digit followed by an upper starts a new token.
        if ch.isUppercase && prevLower && !cur.isEmpty {
            out.append(cur)
            cur = ""
        }
        cur.append(Character(ch.lowercased()))
        prevLower = ch.isLowercase || (ch.isNumber && ch.isASCII)
    }
    if !cur.isEmpty {
        out.append(cur)
    }
    return out
}

/// The leaf (final `.` segment) of a qualified name.
private func leaf(_ qual: String) -> String {
    if let i = qual.range(of: ".", options: .backwards) {
        return String(qual[i.upperBound...])
    }
    return qual
}

/// The module/type portion of a qualified name (everything before the leaf).
private func moduleOf(_ qual: String) -> String {
    if let i = qual.range(of: ".", options: .backwards) {
        return String(qual[..<i.lowerBound])
    }
    return ""
}

/// First token of `name` that is in `lexicon`, or nil.
private func hasToken(_ name: String, _ lexicon: Set<String>) -> String? {
    surfaceTokenize(name).first { lexicon.contains($0) }
}

/// Salience of an effect — the boundary/security-relevant effects a reviewer cares about score higher.
private func salience(_ effect: String) -> Int {
    switch effect {
    case "Net", "Exec", "Db", "Ipc": return 5
    case "Fs", "Env": return 3
    case "Clock", "Log", "Rand": return 1
    default: return 0
    }
}

private func hopsFactor(_ hops: Int) -> Int {
    switch hops {
    case 1: return 2
    case 2...4: return 3
    case 5...6: return 2
    default: return 1  // ≥7 (hops is always ≥1 for an inherited reach)
    }
}

/// A scored candidate reach. Public so the candor-swift target's `tour` verb can render it.
public struct SurfaceFind {
    public let func_: String
    public let effect: String
    public let hops: Int
    public let source: String
    /// "file:line" of the effect SOURCE, resolved from the caller's `loc` map ("" when absent) —
    /// mirrors the Rust `Find.source_loc`. The scan-note emit renders `?` when this is empty.
    public let sourceLoc: String
    public let benignToken: String
    public let score: Int
}

/// Test code — a Swift qual has no `::tests::` convention, so mirror the Rust reference's SPIRIT (a fn
/// living in a test MODULE): exclude a fn ONLY when its module (the qual with the final leaf removed)
/// indicates a test context. A non-leaf segment counts as a test context when it is, case-insensitively,
/// exactly "test" or "tests", OR ends with "Test" or "Tests" (an XCTest-style `FooTests` suite type).
///
/// The LEAF (final segment) is NEVER considered — a PRODUCTION function like `Manifest.testConnection`
/// (leaf begins "test") is real code, kept in the scan-note and tour. So: `Manifest.testConnection` is
/// KEPT (module "Manifest"); `FooTests.testBar` is excluded (module "FooTests" ends "Tests");
/// `App.tests.helper` is excluded (segment "tests"). Shared by the scan-note and the tour verb.
private func isTest(_ qual: String) -> Bool {
    let segs = qual.split(separator: ".", omittingEmptySubsequences: false)
    // Only the MODULE segments (everything before the final leaf) can flag test code.
    guard segs.count >= 2 else { return false }
    for seg in segs.dropLast() {
        let s = String(seg)
        let lower = s.lowercased()
        if lower == "test" || lower == "tests" { return true }
        if s.hasSuffix("Test") || s.hasSuffix("Tests") { return true }
    }
    return false
}

/// BFS from `func_` over `calls` (follow callees, shortest hops) to the nearest function `S` with
/// `effect` ∈ direct[S]. Returns (hops≥1, S). Only traverses through callees that transitively carry
/// the effect, so the frontier stays on-effect (matches `candor path`'s walk).
private func nearestSource(
    _ func_: String,
    _ effect: String,
    _ direct: [String: Set<String>],
    _ inferred: [String: Set<String>],
    _ calls: [String: Set<String>]
) -> (Int, String)? {
    var seen: Set<String> = [func_]
    var q: [(String, Int)] = [(func_, 0)]
    var head = 0
    while head < q.count {
        let (cur, d) = q[head]
        head += 1
        // A direct source found at distance d≥1 is the nearest (BFS). The start `func_` itself is an
        // INHERITED reach (E ∉ direct[func_]) so it never matches at d==0.
        if d >= 1, direct[cur]?.contains(effect) == true {
            return (d, cur)
        }
        if let cs = calls[cur] {
            // Deterministic frontier order (sorted) — matches the Rust BTreeSet iteration so ties in
            // BFS distance resolve identically across engines.
            for c in cs.sorted() where !seen.contains(c) && inferred[c]?.contains(effect) == true {
                seen.insert(c)
                q.append((c, d + 1))
            }
        }
    }
    return nil
}

/// The three-valued result of `bestFind`, mirroring the Rust `Option<Option<Find>>`.
enum SurfaceResult {
    case noEffects            // ZERO effectful functions — caller emits nothing
    case fallback             // effectful but no winner — caller emits the honest fallback
    case winner(SurfaceFind)  // the winning reach
}

/// Compute the top-`n` most surprising reaches, most-surprising first. DEDUPED by function — each
/// function appears at most once (its single highest-scoring reach). The list is empty when nothing
/// clears the bar (the caller decides whether to emit the honest fallback vs nothing, using
/// `surfaceAnyEffectful`).
///
/// Ranking (the tie-break, applied to the whole candidate pool before the per-function dedup + take):
/// score DESC → hops ASC → qual ASC. With `n == 1` the result is BYTE-IDENTICAL to the old scan-time
/// `bestFind` (the scan note + conformance PART 4f pin this). This is the Swift port of the Rust
/// `candor_classify::surface::best_finds`; both the scan note and the `tour` verb delegate here so the
/// ranking cannot drift.
public func bestFinds(
    inferred: [String: Set<String>],
    direct: [String: Set<String>],
    calls: [String: Set<String>],
    loc: [String: String],
    n: Int
) -> [SurfaceFind] {
    // Deterministic iteration: sort quals ascending so the tie-break (qual ascending) is stable and
    // dictionary order never leaks into the result.
    let quals = inferred.keys.sorted()

    var cands: [SurfaceFind] = []

    for f in quals {
        let inf = inferred[f] ?? []
        if isTest(f) {
            continue
        }
        let fLeaf = leaf(f)
        let fMod = moduleOf(f)
        // EXCLUDE the whole function if its leaf OR module reads effecty — its reach is obvious.
        if hasToken(fLeaf, EFFECTY) != nil || hasToken(fMod, EFFECTY) != nil {
            continue
        }
        let dir = direct[f] ?? []
        // Candidate effects: inherited (in inferred, not direct), not Unknown. Sorted ascending.
        let effects = inf.filter { $0 != "Unknown" && !dir.contains($0) }.sorted()
        for e in effects {
            let sal = salience(e)
            if sal == 0 {
                continue
            }
            guard let (hops, s) = nearestSource(f, e, direct, inferred, calls) else {
                continue  // no LOCAL direct source — nothing to show
            }
            let benign = hasToken(fLeaf, BENIGN)
            let benignity = benign != nil ? 3 : 1
            let crossing = moduleOf(s) != fMod ? 2 : 1
            let score = sal * benignity * hopsFactor(hops) * crossing
            if score == 0 {
                continue
            }
            cands.append(SurfaceFind(
                func_: f, effect: e, hops: hops, source: s,
                sourceLoc: loc[s] ?? "", benignToken: benign ?? "", score: score))
        }
    }

    // Rank the whole pool: score DESC, hops ASC, qual ASC. Quals were iterated ascending and effects
    // ascending, so on a full tie the first-pushed (smallest qual) candidate sorts first — matching the
    // old `bestFind`'s "keep the earliest winner on an exact tie". A STABLE sort preserves that push
    // order for full ties (Swift's `sort(by:)` is not guaranteed stable, so the comparator is total —
    // qual is unique per function, but two effects of ONE function can tie on score+hops; the effects
    // were pushed ascending, so keep that by breaking the final tie on `effect` ascending).
    cands.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        if a.hops != b.hops { return a.hops < b.hops }
        if a.func_ != b.func_ { return a.func_ < b.func_ }
        return a.effect < b.effect
    }

    // DEDUP by function — each function appears at most once (its single highest-scoring reach, the
    // first one in ranked order). Then take up to `n` distinct functions.
    var seenFns: Set<String> = []
    var out: [SurfaceFind] = []
    for c in cands {
        if out.count >= n { break }
        if seenFns.insert(c.func_).inserted {
            out.append(c)
        }
    }
    return out
}

/// Is the package EFFECTFUL — does ANY function carry a real (non-Unknown) effect? Governs whether the
/// caller emits the honest "nothing hidden" fallback (effectful, but nothing clears the bar) vs nothing
/// at all. Mirrors the Rust `any_effectful`.
func surfaceAnyEffectful(_ inferred: [String: Set<String>]) -> Bool {
    inferred.values.contains { $0.contains { $0 != "Unknown" } }
}

/// Compute the single most surprising reach — the scan-note view, expressed via `bestFinds(…, n: 1)`
/// so the ranking cannot drift from `tour`. Returns the three-valued result the scan-note emit wants.
func surfaceBestFind(
    inferred: [String: Set<String>],
    direct: [String: Set<String>],
    calls: [String: Set<String>]
) -> SurfaceResult {
    let finds = bestFinds(inferred: inferred, direct: direct, calls: calls, loc: [:], n: 1)
    if let b = finds.first {
        return .winner(b)
    }
    return surfaceAnyEffectful(inferred) ? .fallback : .noEffects
}

/// Render the surface note to STDERR. `loc` maps qual → "file:line" for the source callout. The prefix
/// is `candor:` (brand voice, NOT `candor-swift:`) and the command is `candor path …` — identical on
/// every engine, so a reader sees the same opener whichever engine scanned.
public func emitSurface(
    inferred: [String: Set<String>],
    direct: [String: Set<String>],
    calls: [String: Set<String>],
    loc: [String: String]
) {
    switch surfaceBestFind(inferred: inferred, direct: direct, calls: calls) {
    case .noEffects:
        break  // zero effectful functions — emit nothing
    case .fallback:
        FileHandle.standardError.write(
            "candor: nothing hidden — every effect sits where its name says it should.\n"
                .data(using: .utf8)!)
    case .winner(let f):
        // `surfaceBestFind` computes with an empty `loc` (the note doesn't need per-candidate loc), so
        // resolve the source's file:line HERE against the caller's `loc`, matching the prior behaviour
        // (`?` when absent). `tour` uses `bestFinds`'s own `sourceLoc` instead.
        let whereS = loc[f.source] ?? "?"
        let hopWord = f.hops == 1 ? "hop" : "hops"
        let benignNote = f.benignToken.isEmpty
            ? ""
            : "          a \"\(f.benignToken)\"-named function reaching \(f.effect).\n"
        let line =
            "candor: most surprising reach — `\(f.func_)` performs \(f.effect), "
            + "\(f.hops) \(hopWord) away via `\(f.source)` (\(whereS)).\n"
            + benignNote
            + "          →  candor path \(f.func_) \(f.effect)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}
