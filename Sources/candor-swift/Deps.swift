// candor-swift — consumer-side report chaining (SPEC §2, the CANDOR_DEPS convention).
//
// A scan accepts SIBLING REPORTS — previously-produced reports for the scanned code's dependencies —
// and an unresolved/unclassified call into a package one of them covers inherits that function's
// recorded transitive effects AND its literal surfaces. The three §2 rules, as this engine holds them:
//
//   1. JOINS NEVER GUESS — the index keys each dep entry under `pkg#leaf` and `pkg#tail2` (tail2 =
//      the qual's last two segments, `.`/`::` separators normalized to `.` — the way THIS engine
//      names a call: `Owner.member`, or a bare free-fn/ctor name). A key two dep functions share is
//      REMOVED and remembered as ambiguous (the candor-scan move) — dropped, never picked from. The
//      consumer side additionally gates every join on the call site's FILE importing a covered
//      package, so a same-named symbol in an unimported dep can never join.
//   2. STALE REPORTS ARE NOT TRUSTED — a report whose `candor.version` differs from THIS engine's
//      build (or is missing: as unverifiable as a mismatch — the family condition, mirrored from
//      candor-ts scan.mjs / candor-java Loader) contributes `Unknown` at every join, never a stale
//      effect claim; its literal surfaces are not carried. Its PACKAGE is still covered (rule 3 —
//      coverage is the producer's claim of scope, not of currency).
//   3. A CHAINED PACKAGE IS COVERED, NOT BLIND — every package a loaded report covers (envelope
//      `package`/`packages`, plus each entry's hash prefix) is exempt from the §7.14 κ ledger and
//      the per-fn `invisible` disclosure, INCLUDING an all-pure dep's EMPTY report: reports omit
//      pure functions, so a call that joins nothing in a covered package reads pure — the silence
//      is the claim.
//
// FAIL-CLOSED (the CANDOR_CONFIG posture, matching candor-java): a CANDOR_DEPS/config-`deps` token
// that names no readable file or directory, and a dep report that does not parse as JSON, FAIL the
// run (exit 2). Silently skipping either would make every call into that dep read pure — the §2.1
// "corrupt report ≠ pure" care, undone one level up.

import Foundation

/// One chained dependency function: effects + the four literal surfaces (the spec says a consumer
/// inherits BOTH — effects alone would make every chained `allow` rule fail on an empty surface),
/// plus the dep fn's own honesty carriers, inherited across the join so a consumer's verdict stays
/// qualified: `invisible` (the dep's blind-module disclosure) and `incomplete` (masking — a benign
/// literal here must not certify the dep's invisible runtime endpoint).
struct DepEntry {
    var effects: Set<String> = []
    var hosts: Set<String> = [], cmds: Set<String> = [], paths: Set<String> = [], tables: Set<String> = []
    var invisible: Set<String> = []
    var incomplete: Set<String> = []
    /// The `unknownWhy` reason a join must carry when `effects` contains Unknown (spec 0.6: a direct
    /// Unknown source names its origin): `dep-stale:<pkg>` for a distrusted producer, `dep:<hash>`
    /// when a FRESH dep entry itself reads Unknown.
    var whyReason: String? = nil
}

/// The CANDOR_DEPS index: `pkg#leaf` / `pkg#tail2` keys (unambiguous only) + the covered-package set.
struct DepIndex {
    var byKey: [String: DepEntry] = [:]
    var ambiguous: Set<String> = []
    var coveredPkgs: Set<String> = []
    var isEmpty: Bool { byKey.isEmpty && coveredPkgs.isEmpty }
    /// nil for an unknown OR ambiguous key — an ambiguous key is dropped, never picked from (§2 rule 1).
    func lookup(_ key: String) -> DepEntry? { ambiguous.contains(key) ? nil : byKey[key] }

    mutating func insert(key: String, _ entry: DepEntry) {
        if ambiguous.contains(key) { return }
        if byKey[key] != nil {
            byKey.removeValue(forKey: key)   // two dep fns share the key — drop it, never guess
            ambiguous.insert(key)
        } else {
            byKey[key] = entry
        }
    }
}

private func depsFail(_ msg: String) -> Never {
    FileHandle.standardError.write("candor-swift: \(msg) — failing (exit 2), a configured dep must not silently read pure\n".data(using: .utf8)!)
    exit(2)
}

/// The qual's segments with the family separators normalized: `a.b.C.m` / `mod::fn` / `Owner.member`
/// all split the same way, so a tail2 key reads `C.m` no matter which engine produced the report.
private func qualSegments(_ qual: String) -> [String] {
    qual.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
}

/// Load the sibling reports named by `spec` (whitespace/colon/comma-separated paths — the family
/// separator set; a directory is walked for *.json, sidecars excluded). `engineVersion` is THIS
/// build's version string, compared against each report's `candor.version` for the §2.1 trust rule.
func loadDepReports(spec: String?, engineVersion: String) -> DepIndex {
    var idx = DepIndex()
    guard let spec, !spec.isEmpty else { return idx }
    let fm = FileManager.default

    // Collect the report files. Canonical-path dedup: the same report loaded twice would self-collide
    // on every key and be dropped as ambiguous, silently killing the chain (the candor-scan review find).
    var files: [String] = []
    var seen: Set<String> = []
    func push(_ f: String) {
        let canon = (try? fm.destinationOfSymbolicLink(atPath: f)) ?? f
        let norm = (canon as NSString).standardizingPath
        if seen.insert(norm).inserted { files.append(f) }
    }
    for tok in spec.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == ":" || $0 == "," }) {
        let t = String(tok)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: t, isDirectory: &isDir) else {
            depsFail("CANDOR_DEPS names \(t) but it is not a readable file or directory")
        }
        if isDir.boolValue {
            guard let en = fm.enumerator(atPath: t) else { depsFail("CANDOR_DEPS cannot walk directory \(t)") }
            var found: [String] = []
            for case let rel as String in en {
                let name = (rel as NSString).lastPathComponent
                if name.hasSuffix(".json") && !name.contains("callgraph") && !name.contains("hierarchy") {
                    found.append((t as NSString).appendingPathComponent(rel))
                }
            }
            for f in found.sorted() { push(f) }
        } else {
            push(t)
        }
    }

    for f in files {
        guard let data = fm.contents(atPath: f) else {
            depsFail("CANDOR_DEPS report \(f) could not be read")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            depsFail("CANDOR_DEPS report \(f) is not valid JSON")
        }
        // v0.2+ envelope `{candor, package, functions}` or the legacy bare array (no version → stale).
        let obj = root as? [String: Any]
        let fns = (obj?["functions"] as? [Any]) ?? (root as? [Any]) ?? []
        // §2.1 at the join: a MISSING producing version is as unverifiable as a mismatched one (the
        // family condition — candor-ts: `d.candor?.version !== ENGINE_VERSION`).
        let depVersion = (obj?["candor"] as? [String: Any])?["version"] as? String
        let stale = depVersion != engineVersion

        // Envelope-level coverage — registers even an EMPTY report's package (§2 rule 3): singular
        // `package` (this engine, candor-report, candor-ts) and the JVM-shape plural `packages`.
        if let pkg = obj?["package"] as? String, !pkg.isEmpty { idx.coveredPkgs.insert(pkg) }
        for pkg in (obj?["packages"] as? [String]) ?? [] where !pkg.isEmpty { idx.coveredPkgs.insert(pkg) }

        for case let e as [String: Any] in fns {
            guard let qual = e["fn"] as? String, !qual.isEmpty else { continue }
            // The entry's package: its hash prefix (`pkg#qual`), else the envelope package. No
            // package → unchainable entry (a hashless report under-reports, the documented direction).
            let hash = e["hash"] as? String
            let pkg = hash.flatMap { $0.contains("#") ? String($0.split(separator: "#", maxSplits: 1)[0]) : nil }
                ?? (obj?["package"] as? String)
            guard let pkg, !pkg.isEmpty else { continue }
            idx.coveredPkgs.insert(pkg)

            var entry = DepEntry()
            if stale {
                entry.effects = ["Unknown"]      // §2.1: a different/missing producer version is not trusted
                entry.whyReason = "dep-stale:\(pkg)"
            } else {
                for case let name as String in (e["inferred"] as? [Any]) ?? [] {
                    // foreign vocabulary (a future spec's effect) is honestly Unknown, never dropped
                    entry.effects.insert(Effect.from(name) != nil ? name : "Unknown")
                }
                for (key, path) in [("hosts", \DepEntry.hosts), ("cmds", \.cmds), ("paths", \.paths), ("tables", \.tables)] {
                    for case let v as String in (e[key] as? [Any]) ?? [] { entry[keyPath: path].insert(v) }
                }
                // carry the dep fn's own honesty markers across the join (the candor-scan sweeps [8]/[30])
                for case let v as String in (e["invisible"] as? [Any]) ?? [] { entry.invisible.insert(v) }
                for case let v as String in (e["incomplete"] as? [Any]) ?? [] where Effect.from(v) != nil {
                    entry.incomplete.insert(v)
                }
                if entry.effects.contains("Unknown") {
                    entry.whyReason = "dep:\(hash ?? "\(pkg)#\(qual)")"
                }
            }
            if entry.effects.isEmpty && entry.invisible.isEmpty && entry.incomplete.isEmpty { continue }

            // `pkg#leaf` + `pkg#tail2` — the two shapes this engine's call sites can derive (§2 rule 1).
            let segs = qualSegments(qual)
            guard let leaf = segs.last else { continue }
            idx.insert(key: "\(pkg)#\(leaf)", entry)
            if segs.count >= 2 {
                idx.insert(key: "\(pkg)#\(segs[segs.count - 2]).\(leaf)", entry)
            }
        }
    }
    return idx
}
