import CandorCore
import Foundation

// The `privacy-manifest` verb (SPEC-EXTENSION-privacy.md, "Product surface"): the code-level truth behind
// an app's Apple privacy declaration. Read-only over a report a scan already wrote — the reached privacy
// effects (the union of every fn's `inferred`, intersected with the six privacy/1 effects) are the sensors
// the code actually touches, TRANSITIVELY, which grep can't see. GENERATE (no --verify) emits the required
// Info.plist usage-description keys; VERIFY <Info.plist> diffs the declared keys against the reach: a reached
// effect with no key is an UNDER-declaration (the App-Store-rejection finding, exit 1), a declared key with
// no reach is an OVER-declaration (an unused permission, a warning, still exit 0). Fail-loud (exit 2) on a
// missing/corrupt report or an unreadable/unparseable plist — never a silently-empty answer.
//
// Modeled on the other query verbs (FixCLI.swift): the report is DISCOVERED from .candor/ or via --report
// (the shared resolveReportLocator + the loud load), no policy. The verb has no positional args.

// The six privacy/1 effects (SPEC-EXTENSION-privacy.md "The effect vocabulary"), in a stable order.
private let privacyEffects = ["Location", "Camera", "Mic", "Contacts", "Photos", "Notify"]

// The effect → acceptable Info.plist usage-description keys (SPEC-EXTENSION-privacy.md "The effect →
// usage-description key mapping"). The FIRST key of each list is the PRIMARY one (what GENERATE names first).
// `Notify` maps to NO key — notifications gate via a runtime requestAuthorization, so a Notify reach is
// reported as a declared capability that requires no manifest key (always satisfied, never under-declared).
private let privacyKeyMap: [String: [String]] = [
    "Location": ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription",
                 "NSLocationAlwaysUsageDescription", "NSLocationUsageDescription"],
    "Camera": ["NSCameraUsageDescription"],
    "Mic": ["NSMicrophoneUsageDescription"],
    "Contacts": ["NSContactsUsageDescription"],
    "Photos": ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"],
    "Notify": [],
]

// The whole privacy-cluster key universe — used to scope the OVER-declaration check to the sensor cluster
// (a stray unrelated key like NSCalendarsUsageDescription is not this verb's concern). Every acceptable key
// across every effect.
private let privacyClusterKeys: Set<String> = Set(privacyKeyMap.values.flatMap { $0 })

private func privacyDie(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

private func emitPrivacyJSON(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: data, encoding: .utf8) else {
        privacyDie("candor-swift privacy-manifest: could not serialize the result")
    }
    print(s)
}

// The parsed `privacy-manifest` invocation. Like `tour`/`path`, there is NO deprecated leading-report
// positional and NO policy — the report comes ONLY from --report/discovery, and there are no other
// positionals. `--verify <plist>` selects VERIFY mode; its absence is GENERATE.
private struct PrivacyManifestArgs {
    var report: String?     // resolved report prefix/path (nil ⇒ discovery failed, caller fails loud)
    var verify: String?     // the Info.plist path to verify against (nil ⇒ GENERATE mode)
    var json = false
}

// Parse `privacy-manifest [--report <locator>] [--verify <Info.plist>] [--json]`. No positional args are
// accepted — a stray positional is a usage error (exit 2), never mis-read as a report/plist.
private func parsePrivacyManifestArgs(_ args: [String]) -> PrivacyManifestArgs {
    var pm = PrivacyManifestArgs()
    var reportFlag: String?
    var it = args.dropFirst(2).makeIterator()   // drop the binary name + the verb
    while let a = it.next() {
        switch a {
        case "--json": pm.json = true
        case "--report":
            // Consume the next token as the value unconditionally (mirrors the fix/tour grammar) so a
            // value beginning `-` can be passed; only a genuinely absent value is the exit-2 error.
            guard let v = it.next() else { privacyDie("candor-swift: --report requires a value") }
            reportFlag = v
        case "--verify":
            guard let v = it.next() else { privacyDie("candor-swift: --verify requires a value") }
            pm.verify = v
        default:
            if a.hasPrefix("-") { privacyDie("candor-swift: unknown flag \(a)") }
            privacyDie("usage: candor-swift privacy-manifest [--report <locator>] [--verify <Info.plist>] [--json]")
        }
    }
    // Resolve the report: --report flag → discovery. NO positional report (the query-verb grammar).
    pm.report = reportFlag.map(resolveReportLocator) ?? discoverReportPrefix()
    return pm
}

// Load the plist at `path` as a top-level string dictionary of usage-description keys. NSDictionary handles
// BOTH the XML and binary plist encodings transparently. Returns nil (the caller fails loud, exit 2) if the
// file is missing, unreadable, or not a plist dictionary — never a silent empty "no keys declared", which
// would flip every reach into a false under-declaration OR (the worse direction) hide a genuine gap.
private func loadDeclaredKeys(_ path: String) -> Set<String>? {
    let url = URL(fileURLWithPath: path)
    // PropertyListSerialization is the direct API (NSDictionary(contentsOf:) silently returns nil on ANY
    // failure, indistinguishable from a plist that is a non-dict root); this lets us fail loud on a genuine
    // parse error while still accepting XML or binary.
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dict = obj as? [String: Any] else {
        return nil
    }
    // Scope to usage-description keys: any top-level key ending "UsageDescription" (so a newly-minted Apple
    // usage key is still seen for over-declaration), which is a superset of the mapping's keys. Non-string
    // values are tolerated — a key's PRESENCE is the declaration, its description string is not inspected.
    return Set(dict.keys.filter { $0.hasSuffix("UsageDescription") })
}

// Dispatched from main.swift when argv[1] is `privacy-manifest`.
func runPrivacyManifestCLI(_ args: [String]) -> Never {
    let pm = parsePrivacyManifestArgs(args)
    guard let prefix = pm.report else {
        privacyDie("candor-swift privacy-manifest: no report — pass --report <locator> or run from a repo with a .candor/ dir (scan: candor-swift <dir>)")
    }
    // Load the report the same way tour/path/fix do — a missing/corrupt report fails loud (exit 2), never a
    // silently-empty surface that would print a false "no sensors reached" clean bill of health (§4).
    guard let model = loadFixModel(prefix: prefix) else {
        privacyDie("candor-swift privacy-manifest: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
    }

    // The REACHED privacy effects: the union over all fns' `inferred` sets, intersected with the six
    // privacy/1 effects. For each reached effect, collect the fns whose inferred (or direct) set contains it
    // — the under-declaration detail (a few representative fn names, sorted, capped).
    var reachedSet: Set<String> = []
    var fnsByEffect: [String: [String]] = [:]
    for (fn, f) in model.byName {
        for eff in f.inferred.union(f.direct) where privacyKeyMap[eff] != nil {
            reachedSet.insert(eff)
            fnsByEffect[eff, default: []].append(fn)
        }
    }
    // Stable, deterministic order for the reached list (the vocabulary order) and the fn lists (sorted,
    // capped at 20 so a huge crate's detail stays readable).
    let reached = privacyEffects.filter { reachedSet.contains($0) }
    let fnCap = 20
    func fnsFor(_ eff: String) -> [String] {
        let all = (fnsByEffect[eff] ?? []).sorted()
        return Array(all.prefix(fnCap))
    }

    if let plistPath = pm.verify {
        // ── VERIFY mode ───────────────────────────────────────────────────────────────────────────────
        guard let declared = loadDeclaredKeys(plistPath) else {
            privacyDie("candor-swift privacy-manifest: Info.plist `\(plistPath)` could not be read or parsed (expected an XML or binary property list) — refusing to report a verify result over an unreadable manifest.")
        }
        let declaredSorted = declared.sorted()

        // UNDER-declaration: a reached effect (except Notify, which needs no key) whose acceptable-key set
        // has NO member present in the plist — the App-Store-rejection finding.
        var underDeclared: [(effect: String, keys: [String], fns: [String])] = []
        for eff in reached {
            let keys = privacyKeyMap[eff] ?? []
            if keys.isEmpty { continue }   // Notify — no key required, never under-declared
            if !keys.contains(where: { declared.contains($0) }) {
                underDeclared.append((effect: eff, keys: keys, fns: fnsFor(eff)))
            }
        }

        // OVER-declaration: a declared privacy-cluster key that satisfies NO reached effect — an unused
        // sensor permission (a warning, not a failure). Scoped to the cluster keys (an unrelated
        // usage-description key is not this verb's concern). A key satisfies a reached effect when it is
        // one of that effect's acceptable keys AND the effect was reached.
        let satisfyingKeys: Set<String> = Set(reached.flatMap { privacyKeyMap[$0] ?? [] })
        let overDeclared = declaredSorted.filter { privacyClusterKeys.contains($0) && !satisfyingKeys.contains($0) }

        let ok = underDeclared.isEmpty

        // ⟨0.15 staged⟩ coverage conditionality (SPEC §2 `coverage` re-disclosure; the wikipedia-ios
        // false-confidence finding): when the report's κ ledger is non-empty OR any examined function
        // carries a per-fn `invisible` (the verb's reach computation examines EVERY function, so any
        // uncovered module could hide sensor usage the verify cannot see), the verdict is CONDITIONAL —
        // a "clean" answer holds only for the covered part of the code. DISCLOSURE, not a gate: the
        // exit code is computed exactly as before (under-declaration 1, otherwise 0).
        let uncoveredModules = model.coverage.modules
        let conditional = !model.coverage.isEmpty

        if pm.json {
            // The pinned JSON shape (SPEC-EXTENSION-privacy.md): reached / required / declared /
            // underDeclared[{effect,keys,fns}] / overDeclared / ok. `required` names the acceptable keys
            // per reached effect (PRIMARY first) — the same map GENERATE emits, so a verify payload also
            // carries the target manifest.
            var required: [String: [String]] = [:]
            for eff in reached { required[eff] = privacyKeyMap[eff] ?? [] }
            let under: [[String: Any]] = underDeclared.map {
                ["effect": $0.effect, "keys": $0.keys, "fns": $0.fns]
            }
            var verdict: [String: Any] = [
                "reached": reached,
                "required": required,
                "declared": declaredSorted,
                "underDeclared": under,
                "overDeclared": overDeclared,
                "ok": ok,
            ]
            // ⟨0.15 staged⟩ conditionality block — ABSENT when fully covered, so a fully-covered
            // verify's JSON is byte-identical to the pre-⟨0.15⟩ shape.
            if conditional {
                verdict["conditional"] = true
                verdict["coverage"] = ["uncovered": uncoveredModules.count, "modules": uncoveredModules] as [String: Any]
            }
            emitPrivacyJSON(verdict)
            exit(ok ? 0 : 1)   // EXIT UNCHANGED by coverage — disclosure, not a gate
        }

        // HUMAN: the divergences first (the actionable findings), then the verdict line.
        for u in underDeclared {
            let via = u.fns.isEmpty ? "" : " (via \(u.fns.prefix(3).joined(separator: ", ")))"
            print("✗ code reaches \(u.effect)\(via) but Info.plist declares no \(u.keys.first ?? "usage-description key")")
        }
        for key in overDeclared {
            // Name the effect this key would satisfy, for context.
            let eff = privacyKeyMap.first { $0.value.contains(key) }?.key ?? "sensor"
            print("⚠ \(key) declared but no \(eff) reach found")
        }
        if ok && overDeclared.isEmpty {
            let n = reached.count
            print("✓ every accessed capability is declared (\(n) effect\(n == 1 ? "" : "s"))")
        } else if ok {
            // Clean of under-declaration, but an over-declaration warning was printed above.
            let n = reached.count
            print("✓ every accessed capability is declared (\(n) effect\(n == 1 ? "" : "s")) — see the ⚠ over-declaration note(s) above")
        }
        // ⟨0.15 staged⟩ the conditionality caveat travels with the human verdict too — LAST, so the
        // verdict line above stays where consumers expect it. Exit unchanged (disclosure, not a gate).
        if conditional {
            let n = uncoveredModules.count
            print("⚠ verdict is conditional on \(n) uncovered module\(n == 1 ? "" : "s") — sensor usage there is invisible to this verify (chain dep reports or scan the workspace root to close the gap)")
        }
        exit(ok ? 0 : 1)
    }

    // ── GENERATE mode (no --verify) ─────────────────────────────────────────────────────────────────────
    // Emit the required Info.plist usage-description keys the code's sensor reach REQUIRES, each with the
    // reaching functions. `required` = {effect: [acceptable keys]} (PRIMARY key first); `reached` names the
    // effects. Notify appears in `reached` with an empty key list (no manifest key required).
    if pm.json {
        var required: [String: [String]] = [:]
        for eff in reached { required[eff] = privacyKeyMap[eff] ?? [] }
        emitPrivacyJSON(["reached": reached, "required": required])
        exit(0)
    }

    if reached.isEmpty {
        print("candor privacy-manifest — no privacy-sensor reach found; no usage-description keys required.")
        exit(0)
    }
    print("candor privacy-manifest — usage-description keys required by the code's sensor reach:")
    for eff in reached {
        let keys = privacyKeyMap[eff] ?? []
        let fns = fnsFor(eff)
        let byWhom = fns.isEmpty ? "" : " (reached by: \(fns.prefix(3).joined(separator: ", "))\(fns.count > 3 ? ", …" : ""))"
        if let primary = keys.first {
            print("  \(eff) → \(primary)\(byWhom)")
        } else {
            // Notify — no Info.plist key; declared at runtime.
            print("  \(eff) → (no Info.plist key — notifications gate at runtime via requestAuthorization)\(byWhom)")
        }
    }
    exit(0)
}
