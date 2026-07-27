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
//      effect claim; its literal surfaces are not carried. It is still CHAINED — its keys are looked
//      up, so the downgrade can happen — but it grants NO COVERAGE (see rule 3).
//   3. A CHAINED PACKAGE IS COVERED, NOT BLIND — every package a TRUSTED loaded report covers
//      (envelope `package`/`packages`, plus each entry's hash prefix) is exempt from the §7.14 κ
//      ledger and the per-fn `invisible` disclosure, INCLUDING an all-pure dep's EMPTY report:
//      reports omit pure functions, so a call that joins nothing in a covered package reads pure —
//      the silence is the claim.
//
//      THE TRUST QUALIFIER IS LOAD-BEARING, and it is what rule 3 got wrong until 2026-07-27.
//      Coverage is the mechanism that turns a report's SILENCE into a purity claim, so granting it
//      on a report §2.1 has just refused to trust makes that claim on the refused report's own
//      authority: the keys such a report CARRIED read `Unknown` (right, rule 2) while every key it
//      simply did not contain read PURE (wrong, and silent). Measured on the two-tree fixture: a
//      call into a dep API the stale report has no entry for went from `invisible: ['RatesDep']`
//      unchained to ABSENT FROM `functions` — a ⟨0.21⟩ positive purity claim — the moment the
//      untrusted report was chained, and the κ ledger stopped naming the package. Staleness
//      rewrites the CONTENT of the keys a report holds; it can never conjure a key the report
//      lacks, so trusting its silence is the whole of the hole (candor-ts 651c9f9, same shape).
//
//      So a stale report's packages go to `stalePkgs`, NOT `coveredPkgs`, and `isChained` (either set)
//      is what the JOIN gates consult — dropping the package from the join too would be the mirror sin,
//      since it is the join that produces rule 2's `Unknown` downgrade in the first place. Measured: with
//      the join gated on `coveredPkgs` instead, FOUR named tests go red, three of them the stale-downgrade
//      rows. The second direction is not belt-and-braces here; it is the larger half.
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
    /// ⟨0.19⟩ THE DEPENDENCY'S OWN `unknownWhy` TOKENS, carried across the join so the REASON CLASS
    /// survives the scan boundary. Without them a chained Unknown arrives carrying only `dep:<hash>`,
    /// which SPEC §6.2 projects to `unresolved` — so the reason-scoped gate, a shipped ⟨0.19⟩ rung, was
    /// silently inert at exactly the boundary where a consumer most needs it: `deny Unknown[reflect]`
    /// went exit 1 single-tree and exit 0 the moment the same code was split and chained, while bare
    /// `deny Unknown` fired in both — which is why it survives review, since only the class-targeted
    /// middle reads green, and that middle is how the ratchet is adopted in practice.
    ///
    /// candor-java found the same gap one hop further out (`6ab26e4`) and needed no format rung, because
    /// the dependency's report ALREADY carries `unknownWhy` — nothing looked for it. Same here.
    /// `dep:<hash>` is KEPT alongside: it names the origin, which the raw tokens do not.
    var whyClasses: Set<String> = []
}

/// The CANDOR_DEPS index: `pkg#leaf` / `pkg#tail2` keys (unambiguous only) + the covered-package set.
struct DepIndex {
    var byKey: [String: DepEntry] = [:]
    var ambiguous: Set<String> = []
    /// Packages whose silence is a PURITY CLAIM (§2 rule 3) — a package covered by a report this engine
    /// TRUSTS. Consulted by the κ ledger and the per-fn `invisible` disclosure, which are exactly the
    /// hedges coverage is allowed to delete. Never consulted to decide whether to LOOK UP a key.
    var coveredPkgs: Set<String> = []
    /// Packages whose only chained report failed the §2.1 version check. Chained (so rule 2's `Unknown`
    /// downgrade fires on the keys the report does carry) but NOT covered (so a key it does not carry
    /// falls back to the `invisible` hedge instead of reading pure). A package chained twice — once fresh,
    /// once stale — is covered by the fresh report and is removed from here at the end of the load.
    var stalePkgs: Set<String> = []
    /// Does ANY chained report — trusted or not — claim this package? The predicate the JOIN gates use.
    /// Coverage decides whether SILENCE is a claim; chaining decides whether a key is worth ASKING.
    /// Conflating the two is the defect this split exists to close, and it bites in BOTH directions:
    /// gating the join on `coveredPkgs` would take rule 2's `Unknown` downgrade with it.
    func isChained(_ pkg: String) -> Bool { coveredPkgs.contains(pkg) || stalePkgs.contains(pkg) }
    /// ⟨0.23⟩ `typeSurface.returns` (SPEC §2): `<pkg>#<fn qual>` -> `<pkg>#<type qual>`, exactly as the
    /// producer published it. Same never-guess discipline as `byKey`: two reports publishing the same fn
    /// key with DIFFERENT types drop the key rather than pick one.
    var returnsIdx: [String: String] = [:]
    var returnsAmbiguous: Set<String> = []
    var isEmpty: Bool { byKey.isEmpty && coveredPkgs.isEmpty && stalePkgs.isEmpty }
    /// nil for an unknown OR ambiguous fn key. A miss here does NOT license silence — see the consumer.
    func boundType(_ key: String) -> String? { returnsAmbiguous.contains(key) ? nil : returnsIdx[key] }

    mutating func insertReturn(key: String, _ type: String) {
        if returnsAmbiguous.contains(key) { return }
        if let existing = returnsIdx[key] {
            if existing != type { returnsIdx.removeValue(forKey: key); returnsAmbiguous.insert(key) }
        } else {
            returnsIdx[key] = type
        }
    }
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
        // An UNTRUSTED report registers into `stalePkgs` instead: chained, not covered (rule 3's
        // trust qualifier — the header explains why the distinction is the whole fix).
        if let pkg = obj?["package"] as? String, !pkg.isEmpty {
            if stale { idx.stalePkgs.insert(pkg) } else { idx.coveredPkgs.insert(pkg) }
        }
        // ⟨0.23⟩ the published type surface. GATED ON `!stale` for the same reason the effects are: a
        // report from a different producer version is not trusted, and keying a consumer through a type
        // claim we just refused to believe would smuggle a stale answer back in under another field.
        // Both ends arrive fully qualified; nothing here re-qualifies or shortens them.
        if !stale, let ts = (obj?["typeSurface"] as? [String: Any])?["returns"] as? [String: Any] {
            for (fnKey, ty) in ts {
                guard let ty = ty as? String, fnKey.contains("#"), ty.contains("#") else { continue }
                idx.insertReturn(key: fnKey, ty)
            }
        }
        for pkg in (obj?["packages"] as? [String]) ?? [] where !pkg.isEmpty {
            if stale { idx.stalePkgs.insert(pkg) } else { idx.coveredPkgs.insert(pkg) }
        }

        for case let e as [String: Any] in fns {
            guard let qual = e["fn"] as? String, !qual.isEmpty else { continue }
            // The entry's package: its hash prefix (`pkg#qual`), else the envelope package. No
            // package → unchainable entry (a hashless report under-reports, the documented direction).
            let hash = e["hash"] as? String
            let pkg = hash.flatMap { $0.contains("#") ? String($0.split(separator: "#", maxSplits: 1)[0]) : nil }
                ?? (obj?["package"] as? String)
            guard let pkg, !pkg.isEmpty else { continue }
            if stale { idx.stalePkgs.insert(pkg) } else { idx.coveredPkgs.insert(pkg) }

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
                    // The dep's OWN reasons, so the ⟨0.19⟩ class survives the boundary. Only tokens the
                    // dep RECORDED: an entry that inherited its Unknown without a reason of its own
                    // (SPEC §4 makes `unknownWhy` direct-only) contributes nothing.
                    for case let w as String in (e["unknownWhy"] as? [Any]) ?? [] where !w.isEmpty {
                        entry.whyClasses.insert(w)
                    }
                    // `dep:<hash>` ONLY when the dependency classified nothing. It is a PROVENANCE
                    // pointer, not a reason, and §6.2 projects it to `unresolved` — so carrying it beside
                    // a classified reason puts an `unresolved` in the consumer's class set that the
                    // single-tree control does not have, and `deny E Unknown[unresolved]` then fires on a
                    // chained consumer and not on the same code unsplit. Chained-vs-single-tree agreement
                    // is this vein's done-ness criterion, and the origin is recoverable from `calls`;
                    // where the dep gives us nothing, `dep:` stands and the class is the conservative
                    // `unresolved` the spec prescribes for a hole nobody classified.
                    if entry.whyClasses.isEmpty {
                        entry.whyReason = "dep:\(hash ?? "\(pkg)#\(qual)")"
                    }
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
    // A package chained TWICE — once fresh, once stale — IS covered: the fresh report makes the claim and
    // the stale one adds nothing to it. Without this, a second report for an already-covered package would
    // strip the coverage the first one earned, which is the mirror sin (a real purity claim degraded to a
    // hedge by a report that says nothing new).
    idx.stalePkgs.subtract(idx.coveredPkgs)
    if !idx.stalePkgs.isEmpty {
        FileHandle.standardError.write(
            ("candor-swift: \(idx.stalePkgs.count) chained dependency report(s) were produced by a DIFFERENT engine "
             + "build — downgraded to Unknown and granted NO coverage, so their unanswered keys stay in the κ ledger "
             + "(§2.1): \(idx.stalePkgs.sorted().joined(separator: ", "))\n").data(using: .utf8)!)
    }
    return idx
}
