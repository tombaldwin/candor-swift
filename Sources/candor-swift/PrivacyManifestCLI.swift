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
// DERIVED from the one ordered source (`PRIVACY_EFFECTS_ORDER`). This list was a sixth copy of the
// sensor vocabulary, and it is the one the manifest ITERATES — so privacy/3's nine families were in the
// type table, in the key map and in four other lists, and still reported nothing, because this one had
// not moved. The effect was computed and then dropped for not being on a list.
private let privacyEffects = PRIVACY_EFFECTS_ORDER

// The effect → acceptable Info.plist usage-description keys (SPEC-EXTENSION-privacy.md "The effect →
// usage-description key mapping"). The FIRST key of each list is the PRIMARY one (what GENERATE names first).
// `Notify` maps to NO key — notifications gate via a runtime requestAuthorization, so a Notify reach is
// reported as a declared capability that requires no manifest key (always satisfied, never under-declared).
// The tables themselves live in CandorCore beside `privacyKind` — the discriminator and the key families
// it selects from are one concept, and splitting them across modules is how the pair drifts apart.

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
    /// `--xml`: emit a paste-ready Info.plist fragment instead of a human list.
    var xml = false
}

// Parse `privacy-manifest [--report <locator>] [--verify <Info.plist>] [--json]`. No positional args are
// accepted — a stray positional is a usage error (exit 2), never mis-read as a report/plist.

/// Sentinel meaning "`--verify` was given with no path — go and find the Info.plist".
let PLIST_DISCOVER = "\u{0}discover"

/// Find the app's `Info.plist` when `--verify` was passed bare.
///
/// AMBIGUITY IS THE HAZARD, not absence. A repo with several shipped binaries has several plists — the
/// real app this feature was built against has two — and verifying against the WRONG one produces
/// exactly the artifact `--target` exists to remove: a confident verdict about a binary the reader was
/// not asking about. So this REFUSES on more than one rather than picking, on the same reasoning as
/// every other ambiguity in this engine: a wrong answer here is worse than a question.
func discoverInfoPlist(from root: String) -> (path: String?, error: String?) {
    let fm = FileManager.default
    let skip: Set<String> = [".build", ".git", "DerivedData", "Pods", "node_modules", "Carthage", ".swiftpm"]
    // BUILD OUTPUT IS NOT A SOURCE MANIFEST. The first version of this listed 22 plists for an app that
    // has two, because every built `.app`, `.appex` and `Build/Products` tree carries a COPY of one it
    // already found. A refusal that buries the two real answers in twenty derived ones has technically
    // not guessed and has practically not helped.
    let derivedSuffix = [".app", ".appex", ".framework", ".xcarchive", ".xctest", ".bundle", ".playground"]
    var found: [String] = []
    if let en = fm.enumerator(atPath: root) {
        for case let rel as String in en {
            let parts = rel.split(separator: "/").map(String.init)
            if parts.contains(where: { p in
                skip.contains(p) || derivedSuffix.contains(where: { p.hasSuffix($0) }) || p == "Build"
            }) { en.skipDescendants(); continue }
            // A TEST bundle's plist is not a shipped binary's — same rule the scanner uses for sources.
            if parts.contains(where: { $0.hasSuffix("Tests") || $0.hasSuffix("UITests") }) {
                en.skipDescendants(); continue
            }
            // `<Target>-Info.plist` is Xcode's long-standing convention. Matching only the bare basename
            // meant a repo whose REAL manifest is `App-Info.plist` and which had any other plain
            // `Info.plist` (a sample, a fixture) got a confident green verdict about the wrong file — and
            // the ambiguity refusal never fired, because by its own name test there was only one candidate.
            let base = (parts.last ?? "").lowercased()
            if base == "info.plist" || base.hasSuffix("-info.plist") {
                found.append((root as NSString).appendingPathComponent(rel))
            }
        }
    }
    // DEDUPE by resolved path: the enumerator reached several of these twice (a symlinked root yields
    // both spellings), and a refusal that lists the same file twice reads as two different binaries.
    var seen = Set<String>()
    found = found.filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
    switch found.count {
    case 0: return (nil, "no Info.plist found under \(root) — pass one: --verify <path>")
    case 1: return (found[0], nil)
    default:
        let list = found.sorted().map { "    " + $0 }.joined(separator: "\n")
        return (nil, """
            \(found.count) Info.plist files under \(root) — refusing to guess which binary you meant, \
            because verifying the wrong one is a confident answer about the wrong app. Pass one:
            \(list)
            """)
    }
}

private func parsePrivacyManifestArgs(_ args: [String]) -> PrivacyManifestArgs {
    var pm = PrivacyManifestArgs()
    var reportFlag: String?
    // Index-based, not an iterator: `--verify` takes an OPTIONAL value, so it must PEEK at the next
    // token and leave it alone when it is another flag. An iterator can only consume.
    let rest = Array(args.dropFirst(2))          // drop the binary name + the verb
    var i = 0
    while i < rest.count {
        let a = rest[i]; i += 1
        switch a {
        case "--json": pm.json = true
        case "--xml": pm.xml = true
        case "--report":
            // Consume the next token as the value unconditionally (mirrors the fix/tour grammar) so a
            // value beginning `-` can be passed; only a genuinely absent value is the exit-2 error.
            guard i < rest.count else { privacyDie("candor-swift: --report requires a value") }
            reportFlag = rest[i]; i += 1
        case "--verify":
            // OPTIONAL value. `--verify <path>` verifies that plist; bare `--verify` DISCOVERS one, so
            // the documented flow is `candor privacy-manifest --verify` with nothing to look up. A
            // following token that starts with `-` is the next flag, not a path.
            if i < rest.count, !rest[i].hasPrefix("-") { pm.verify = rest[i]; i += 1 }
            else { pm.verify = PLIST_DISCOVER }
        default:
            if a.hasPrefix("-") { privacyDie("candor-swift: unknown flag \(a)") }
            privacyDie("usage: candor-swift privacy-manifest [--report <locator>] [--verify [<Info.plist>]] [--json|--xml]")
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
private /// Apple REJECTS an empty or whitespace-only purpose string, so presence alone is not a declaration —
/// a plist with `<key>NSCameraUsageDescription</key><string></string>` verified green and would then be
/// rejected, which is precisely the outcome this verb exists to prevent, one `.isEmpty` away.
func loadDeclaredKeys(_ path: String) -> Set<String>? {
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
    // usage key is still seen for over-declaration), which is a superset of the mapping's keys.
    //
    // AN EMPTY OR WHITESPACE-ONLY STRING IS NOT A DECLARATION. This used to tolerate any value, on the
    // reasoning that presence is the declaration and the prose is not ours to judge — but Apple REJECTS an
    // empty purpose string, so `<key>NSCameraUsageDescription</key><string></string>` verified green and
    // was then rejected: the exact outcome this verb exists to prevent, one `.isEmpty` away. A NON-string
    // value is still tolerated (it is malformed in a way that is not ours to adjudicate); only a string we
    // can see is empty is rejected.
    return Set(dict.keys.filter { k in
        guard k.hasSuffix("UsageDescription") else { return false }
        if let str = dict[k] as? String {
            return !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    })
}

// Dispatched from main.swift when argv[1] is `privacy-manifest`.

/// A PASTE-READY `Info.plist` fragment for a set of required keys.
///
/// WHY THIS EXISTS. "Generate" printed a human list — `Contacts → NSContactsUsageDescription (reached
/// by: …)` — which is a REQUIREMENTS REPORT, not a manifest. A user with an existing plist had to read
/// the list, hand-write the XML, invent the description string, and merge by hand. The verb's name
/// promised a manifest and delivered homework.
///
/// It is a FRAGMENT, deliberately, not a whole plist: an Info.plist already exists in every real app and
/// emitting a complete one would invite overwriting it. This is the thing you paste INTO the `<dict>`.
///
/// The description strings are placeholders and say so in the text. Apple reviews these strings and a
/// generated one would be both wrong and, if it read plausibly, likely to ship — so it is written to be
/// impossible to leave in by accident.
private func plistFragment(_ keys: [(effect: String, key: String)]) -> String {
    var out = ["<!-- candor privacy-manifest — paste into your Info.plist <dict>.",
               "     REPLACE each placeholder string: Apple reviews these, and this text is not a",
               "     description of what your app does with the data. -->"]
    for k in keys {
        out.append("<key>\(k.key)</key>")
        out.append("<string>TODO: why this app needs \(k.effect) access</string>")
    }
    return out.joined(separator: "\n")
}


/// Print what this verify does NOT check. See `PRIVACY_UNMODELLED_KEYS`.
/// The `.entitlements` beside a plist, if there is exactly one. Same discovery discipline as the
/// Info.plist: exactly one is used, several REFUSE to guess (an app with several targets has several,
/// and reading the wrong one answers about the wrong binary), none is simply absent.
func discoverEntitlements(from root: String) -> (path: String?, several: Bool) {
    let fm = FileManager.default
    let skip: Set<String> = [".build", ".git", "DerivedData", "Pods", "node_modules", ".swiftpm"]
    var found: [String] = []
    if let en = fm.enumerator(atPath: root) {
        for case let rel as String in en {
            let parts = rel.split(separator: "/").map(String.init)
                // Same exclusions as the Info.plist discovery — a TEST target's entitlements are not the
            // shipped binary's, and a built bundle carries a copy of one already found.
            if parts.contains(where: { p in
                skip.contains(p) || p == "Build" || p.hasSuffix("Tests") || p.hasSuffix("UITests")
                || [".app", ".appex", ".framework", ".xcarchive"].contains(where: { p.hasSuffix($0) })
            }) { en.skipDescendants(); continue }
            if rel.hasSuffix(".entitlements") { found.append((root as NSString).appendingPathComponent(rel)) }
        }
    }
    var seen = Set<String>()
    found = found.filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
    if found.count == 1 { return (found[0], false) }
    return (nil, found.count > 1)
}

/// Usage-description keys an entitlements file makes REQUIRED. Boolean-true entries only: an entitlement
/// present-but-false is not granted, and treating it as granted would demand a key for a capability the
/// app has switched off.
func entitlementRequiredKeys(_ path: String) -> [String] {
    guard let d = NSDictionary(contentsOfFile: path) as? [String: Any] else { return [] }
    return ENTITLEMENT_REQUIRED_KEYS.compactMap { ent, key in
        guard let v = d[ent] else { return nil }
        // NOT GRANTED unless the value says so. Rejecting only a literal Boolean `false` let three
        // shapes through as granted: the string "false", an array, and — the one that matters — a
        // nested dict with the capability switched off. `v as? Bool` also succeeds for NSNumber 0, so
        // that case was right by accident rather than by the guard.
        if let b = v as? Bool { return b ? key : nil }
        if let n = v as? NSNumber { return n.boolValue ? key : nil }
        if let str = v as? String {
            return ["false", "no", "0", ""].contains(str.lowercased()) ? nil : key
        }
        if let dict = v as? [String: Any] {
            // A dict form is granted only if nothing inside it switches the capability off.
            let offs = dict.values.compactMap { ($0 as? Bool) }.filter { $0 == false }
            return offs.isEmpty ? key : nil
        }
        if let arr = v as? [Any] { return arr.isEmpty ? nil : key }
        return key
    }.sorted()
}

/// Functions performing file I/O whose PATH the scan could not name — the ⊤ count of
/// CONSTANT-PROVENANCE-DESIGN.md, computed from what the report already carries.
///
/// A LOWER BOUND, deliberately and stated as one: `paths` is per-FUNCTION, so a function with one
/// determined path and one undetermined counts here as determined. Undercounting is the dangerous
/// direction for a disclosure, which is why the output says so rather than presenting the number bare.
func undeterminedPaths(_ byName: [String: FixFn]) -> (ops: Int, fns: [String]) {
    var fns: [String] = []
    // THE DIRECT SIGNAL, not the propagated one. Two defects lived in the earlier version, in opposite
    // directions, and both are gone:
    //   · INFLATION — counting transitive reachers put functions performing no file I/O into the list
    //     (52% of the number on candor's own source), and alphabetical sorting put them first.
    //   · MASKING — `paths` PROPAGATES, so a function counted as determined when anything it
    //     transitively reached named a literal. One logger writing "/tmp/app.log" zeroed the count for a
    //     whole call graph, and every real app has one. The maximum-confidence state the design asked
    //     for — "clean, and zero undetermined" — was manufactured by ordinary code.
    // `incomplete` is per-function and unpropagated: it says THIS function's own Fs destination could not
    // be determined, which is the question actually being asked.
    for (fn, f) in byName where f.incomplete.contains("Fs") { fns.append(fn) }
    return (fns.count, fns.sorted())
}

/// §6 of CONSTANT-PROVENANCE-DESIGN.md — report HOW COMPLETELY, not just which keys.
///
/// `undetermined` is the number of file operations whose PATH this scan could not name. It is reported
/// even though no key is currently resolved by path, because it is the concrete form of the caveat: the
/// folder keys are unmodelled AND you cannot rule them out by inspection either, and here is how much
/// you cannot see. When those keys land it becomes load-bearing rather than contextual.
private func printPrivacyVocabularyBound(undetermined: (ops: Int, fns: [String]),
                                         fileProvider: Bool) {
    let modelled = Set(privacyKeyMap.values.flatMap { $0 }).count
    var byBasis: [String: Int] = [:]
    for (eff, keys) in privacyKeyMap where !keys.isEmpty {
        byBasis[PRIVACY_KEY_BASIS[eff] ?? "type", default: 0] += keys.count
    }
    let bases = byBasis.sorted { $0.key < $1.key }.map { "\($0.value) by \($0.key)" }.joined(separator: " · ")
    print("⚠ COVERAGE: \(modelled) of Apple's \(APPLE_PRIVACY_KEYS.count) documented usage-description keys "
          + "are modelled (\(bases)).")
    print("  It says NOTHING — in either direction — about the other \(PRIVACY_UNMODELLED_KEYS.count), "
          + "so a clean result here is not a clean App Store review. Declare these yourself if they apply:")
    for k in PRIVACY_UNMODELLED_KEYS {
        print("    \(k.key)  (\(k.why))")
    }
    // CONDITIONAL, and only raised where it is even possible. NSFileProviderPresence has no documented
    // API and no documented entitlement, so it cannot be determined — but it applies ONLY to an app that
    // ships a file provider, and that candor CAN see. Naming it at every app would be noise; naming it
    // where the capability exists is a lead.
    if fileProvider {
        print("· this app reaches the FileProvider surface, so NSFileProviderPresenceUsageDescription MAY "
              + "apply. Apple documents no API and no entitlement for it, so candor cannot tell — check it "
              + "by hand if your provider reports which files are being viewed.")
    }
    if undetermined.ops > 0 {
        let names = undetermined.fns.prefix(3).joined(separator: ", ")
        print("⚠ \(undetermined.ops) function(s) perform file I/O whose PATH this scan could not determine "
              + "(\(names)\(undetermined.fns.count > 3 ? ", …" : "")).")
        print("  The folder keys above are decided by the path, so these are where an NSDesktop/NSDownloads/"
              + "removable/network-volume requirement could hide.")
        // The caveat now describes the mechanism that actually ships. Two earlier versions were wrong:
        // the first claimed a same-function weakness (narrow, and false), the second correctly reported
        // that propagation masked the count — which was true until the per-function `incomplete` signal
        // landed and made it unnecessary.
        print("  Counted per function from its OWN undetermined destination, not inherited from what it "
              + "calls — so a literal path elsewhere in the call graph cannot mask this, and ZERO here "
              + "means zero. What it still cannot see: a path this scan determined but does not "
              + "recognise as protected.")
    }
}

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
    // `privacy/2` — the union of PROVED directions per effect, and the fns that proved each one. Unioned
    // across the whole scan: if any function writes Health, the app needs the write key.
    var dirsByEffect: [String: Set<String>] = [:]
    var fnsByEffectDir: [String: [String]] = [:]   // "<effect>/<direction>" -> fns
    for (fn, f) in model.byName {
        for eff in f.inferred.union(f.direct) where privacyKeyMap[eff] != nil {
            reachedSet.insert(eff)
            fnsByEffect[eff, default: []].append(fn)
        }
        for (eff, kinds) in f.privacyKinds where privacyKeyMap[eff] != nil {
            for k in kinds {
                dirsByEffect[eff, default: []].insert(k)
                fnsByEffectDir["\(eff)/\(k)", default: []].append(fn)
            }
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

    var entitlementUnderDeclared = false
    var entitlementFindings: [String] = []
    if var plistPath = pm.verify {
        // ── VERIFY mode ───────────────────────────────────────────────────────────────────────────────
        // Bare `--verify` discovers the plist. Announced on stderr, never silently: a verdict is about a
        // SPECIFIC binary's manifest, so the reader has to be told which file it was about.
        if plistPath == PLIST_DISCOVER {
            let d = discoverInfoPlist(from: FileManager.default.currentDirectoryPath)
            guard let p = d.path else {
                privacyDie("candor-swift privacy-manifest --verify: \(d.error ?? "no Info.plist")")
            }
            plistPath = p
            FileHandle.standardError.write("candor-swift: verifying against \(p) (discovered — pass --verify <path> to choose)\n"
                .data(using: .utf8)!)
        }
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
            // `privacy/2` — when the direction was PROVED and this effect's keys are direction-sensitive,
            // check each proved direction against its own key set. An app that reads AND writes HealthKit
            // needs BOTH keys, and reports the missing side by name rather than as one vague "Health".
            let dirs = dirsByEffect[eff] ?? []
            if let byDir = privacyKeyMapByDirection[eff], !dirs.isEmpty {
                for d in dirs.sorted() {
                    guard let dk = byDir[d], !dk.contains(where: { declared.contains($0) }) else { continue }
                    let fns = (fnsByEffectDir["\(eff)/\(d)"] ?? []).sorted().prefix(fnCap).map { $0 }
                    underDeclared.append((effect: "\(eff) (\(d))", keys: dk, fns: fns))
                }
                continue
            }
            // No proved direction (or a direction-insensitive effect) — the pre-`privacy/2` rule exactly.
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

        // COMPUTED BEFORE THE JSON BRANCH, which used to exit ~100 lines above this and so
        // carried no entitlement finding at all — the CI-facing form was the one missing it.
        // ENTITLEMENT-SOURCED requirements, reported SEPARATELY because they are a different kind of
        // evidence: a plist compared with a plist, not a call graph. Folding them in would present a
        // manifest diff as a code analysis. This is also the only route to keys that have NO call site —
        // Apple's page for NSCriticalMessaging links no symbol at all, because there is nothing to link.
        // ANCHORED TO THE PLIST UNDER TEST, not to the process's cwd. Anchoring on cwd meant verifying an
        // explicit plist from an unrelated directory read THAT directory's entitlements and reported a
        // finding about a project not being analysed, attributed to the one that was.
        let plistDir = (plistPath as NSString).deletingLastPathComponent
        let ent = discoverEntitlements(from: plistDir.isEmpty ? FileManager.default.currentDirectoryPath : plistDir)
        if let ep = ent.path {
            let need = entitlementRequiredKeys(ep).filter { !declared.contains($0) }
            if !need.isEmpty {
                // `✗` is this verb's glyph for a rejection-shaped finding, and everywhere else it means
                // exit 1. It printed AFTER a `✓` verdict line and left the exit code at 0 — a granted
                // entitlement without its key is a real rejection cause, and the gate passed it.
                entitlementUnderDeclared = true
                entitlementFindings = need
                // PROSE ONLY IN HUMAN MODE. The block moved above the `--json` branch so the machine
                // form would carry the finding — and then printed to stdout ahead of the JSON document,
                // making it unparseable. The finding travels as `entitlementUnderDeclared` in the JSON.
                if !pm.json && !pm.xml {
                    print("✗ \((ep as NSString).lastPathComponent) grants \(need.count) entitlement(s) whose "
                          + "usage-description key is not declared: \(need.joined(separator: ", "))")
                    print("  (from the ENTITLEMENTS file, not from code — these capabilities have no call "
                          + "site for candor to find, so this is a manifest-to-manifest check.)")
                }
            }
        } else if ent.several, !pm.json, !pm.xml {
            print("· several .entitlements files here — not read. Entitlement-sourced keys "
                  + "(\(ENTITLEMENT_REQUIRED_KEYS.count)) are unchecked; pass one target's tree, as with --target.")
        }

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
            // THE MACHINE CONSUMER GETS THE DISCLOSURE TOO. Every §6 mechanism lived in the human branch
            // only, so `--json` — the form CI reads — returned a bare `"ok": true` with no coverage, no
            // undetermined count, no unmodelled list and no entitlement finding. The reader who can weigh
            // a caveat was the only one receiving it, and the reader who cannot was the one being told
            // "clean". That is the machine-consumer channel ⟨0.21⟩ closed elsewhere, reopened here.
            let und = undeterminedPaths(model.byName)
            // `keyCoverage`, NOT `coverage`. The verdict ALREADY carries a `coverage` key — the ⟨0.15⟩
            // conditionality block naming the uncovered MODULES — and writing this one over it replaced
            // a disclosure with a different disclosure, silently. Two different questions ("which
            // modules could I not see" vs "how many of Apple's keys do I model") wearing one name.
            verdict["keyCoverage"] = [
                "modelledKeys": Set(privacyKeyMap.values.flatMap { $0 }).count,
                "appleDocumentedKeys": APPLE_PRIVACY_KEYS.count,
                "unmodelled": PRIVACY_UNMODELLED_KEYS.map { ["key": $0.key, "why": $0.why] },
                "byBasis": Dictionary(grouping: privacyKeyMap.filter { !$0.value.isEmpty },
                                      by: { PRIVACY_KEY_BASIS[$0.key] ?? "type" })
                    .mapValues { $0.reduce(0) { $0 + $1.value.count } },
            ] as [String: Any]
            if und.ops > 0 {
                verdict["undeterminedPaths"] = ["count": und.ops, "functions": und.fns] as [String: Any]
            }
            if !entitlementFindings.isEmpty {
                verdict["entitlementUnderDeclared"] = entitlementFindings
                // `ok` MUST AGREE WITH THE EXIT CODE. Leaving it as the code-derived verdict meant a
                // machine reading the field it is named for saw `"ok": true` beside exit 1 — the naive
                // CI check is `if ok`, and it would pass a manifest that is about to be rejected.
                verdict["ok"] = false
            }
            emitPrivacyJSON(verdict)
            exit((ok && !entitlementUnderDeclared) ? 0 : 1)
        }

        // `--xml` on a VERIFY prints exactly the fragment that would fix the failure — nothing else, so
        // it pipes. A verify that tells you what is missing and then makes you go and look up how to
        // write it has done half a job; this is the other half.
        if pm.xml {
            if underDeclared.isEmpty {
                print("<!-- candor privacy-manifest --verify: nothing missing; no keys to add. -->")
            } else {
                print(plistFragment(underDeclared.compactMap { u in
                    u.keys.first.map { (effect: u.effect, key: $0) }
                }))
            }
            exit((ok && !entitlementUnderDeclared) ? 0 : 1)   // the exit code is the VERDICT and does not change with the output format
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
            print("✓ every MODELLED capability is declared (\(n) effect\(n == 1 ? "" : "s"))")
        } else if ok {
            // Clean of under-declaration, but an over-declaration warning was printed above.
            let n = reached.count
            print("✓ every MODELLED capability is declared (\(n) effect\(n == 1 ? "" : "s")) — see the ⚠ over-declaration note(s) above")
        }
        // ⟨0.15 staged⟩ the conditionality caveat travels with the human verdict too — LAST, so the
        // verdict line above stays where consumers expect it. Exit unchanged (disclosure, not a gate).
        if conditional {
            let n = uncoveredModules.count
            print("⚠ verdict is conditional on \(n) uncovered module\(n == 1 ? "" : "s") — sensor usage there is invisible to this verify (chain dep reports or scan the workspace root to close the gap)")
        }
        // THE VOCABULARY BOUND, on every verify and especially on a PASS. A green verify means "green
        // for the keys this extension models" — and a reader who takes it for "green for Apple" is the
        // person who submits and gets rejected. Measured by a recall battery, not assumed; the reasons
        // travel with the list so this is a limitation a reader can act on rather than a disclaimer.
        printPrivacyVocabularyBound(undetermined: undeterminedPaths(model.byName),
                                    fileProvider: reachedSet.contains("FileProvider"))
        exit((ok && !entitlementUnderDeclared) ? 0 : 1)
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
        if pm.xml { print("<!-- candor privacy-manifest — no privacy-sensor reach found; no keys required. -->") }
        else { print("candor privacy-manifest — no privacy-sensor reach found; no usage-description keys required.") }
        exit(0)
    }
    if pm.xml {
        print(plistFragment(reached.compactMap { eff in
            (privacyKeyMap[eff] ?? []).first.map { (effect: eff, key: $0) }
        }))
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
