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
    let skip = VENDOR_SKIP_DIRS
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
            // SPEC §3.2 ⟨0.28⟩ "given no value": a flag-shaped next token is a usage error, never a
            // locator (the fix/tour grammar's rule — see parseQueryArgs, where the measurement lives; a
            // bare `-` stays a value and fails loud as a report that does not exist).
            guard i < rest.count else { privacyDie("candor-swift: --report requires a value") }
            let v = rest[i]
            guard v == "-" || !v.hasPrefix("-") else {
                privacyDie("candor-swift: --report was given no value — the next token `\(v)` is a flag, "
                           + "not a locator (a path really named that is spelled ./\(v))")
            }
            reportFlag = v; i += 1
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
        // A usage description is a STRING. `<key>NSCameraUsageDescription</key><false/>` is not a
        // declaration Apple accepts, and counting it green was a false all-clear in the one direction
        // that gets a build rejected. The previous `return true` treated any non-string value as a
        // declaration; only a non-empty string is one.
        guard let str = dict[k] as? String else { return false }
        return !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
}

/// Usage-description keys declared as XCODE BUILD SETTINGS rather than in the `Info.plist` file, keyed
/// by the file they were found in.
///
/// WHY THIS EXISTS, and it is the difference between a useful verb and an embarrassing one. Since Xcode
/// 13, `GENERATE_INFOPLIST_FILE = YES` is the DEFAULT for a new target: usage descriptions are written as
/// `INFOPLIST_KEY_NSCameraUsageDescription = …` build settings and Xcode SYNTHESISES the final plist at
/// build time. The `Info.plist` in the source tree then contains none of them — and verifying it reports
/// every sensor the app reaches as under-declared.
///
/// MEASURED on three shipping open-source apps before this existed: IceCubesApp declares
/// NSCamera/NSPhotoLibrary/NSPhotoLibraryAdd in its `.pbxproj` and NONE in `Info.plist`, so the verify
/// produced THREE false "under-declared" findings against an app that is on the App Store. duckduckgo/iOS
/// and WordPress-iOS carry 8 and 12 such settings. This was not an edge case; it was the common case, and
/// a false rejection-warning is worse than no verb at all — it teaches the reader to distrust the tool.
///
/// SCOPE, deliberately conservative in the direction that matters: this can only ADD to the declared set,
/// so its failure mode is missing a real under-declaration — the cardinal sin. Two guards. (1) An empty
/// or whitespace-only value is NOT a declaration, exactly as in the plist reader (Apple rejects an empty
/// purpose string). (2) The provenance is REPORTED, never silently merged: a key satisfied only by a
/// build setting is named with the file it came from, because "declared somewhere in this project" is a
/// weaker statement than "declared in the plist this target ships" — a setting can belong to a DIFFERENT
/// target, and this cannot tell which without resolving the whole build graph.
func buildSettingUsageKeys(near plistPath: String)
    -> (byFile: [String: Set<String>], inconsistent: Set<String>) {
    let fm = FileManager.default
    var found: [String: Set<String>] = [:]
    // BOUNDED BY THE REPOSITORY. The walk had no stop condition, so a stray `.xcodeproj` or `.xcconfig`
    // ABOVE the checkout satisfied the verify — on a developer machine that is somebody else's project,
    // and the disclosure could not even show it (every pbxproj is named `project.pbxproj`, and the line
    // printed only the last path component). It now stops at a `.git` directory, and the disclosure
    // prints a repo-relative path.
    var dirs: [URL] = []
    var dir = URL(fileURLWithPath: plistPath).deletingLastPathComponent()
    var sawMarker = false
    // …AND NOT UP AT ALL WHEN THERE IS NO REPOSITORY. Same rule as `countNonSwiftSources` and
    // `discoverEntitlements`, for the third time and the same reason: the ancestors of a plist that is
    // not in a checkout are not this app's directories. Without this the marker-less arm below still
    // listed two ancestors, and on a developer machine one of them is `$TMPDIR` — 185,000 entries here,
    // which is a 72-second directory listing per verify and most of why this suite ran for an hour.
    // Direction check: what is lost is an `.xcconfig` one or two levels above a plist in a tree with
    // NONE of the five markers, which would then read as undeclared — an over-report, not a silent
    // under-report, and a tree with no marker within eight hops is not a project.
    let inACheckout = projectRootAbove(plistPath) != nil
    for level in 0..<(inACheckout ? 8 : 1) {
        if level >= 3 && !sawMarker { break }   // unmarked tree: never past the plist's 2nd ancestor
        dirs.append(dir)
        // Stop at the PROJECT ROOT, not merely at `.git`: a tree that is not a git checkout (a vendored
        // copy, a tarball, a fixture) otherwise kept walking into shared parents like /tmp or $HOME,
        // where somebody else's `.xcconfig` satisfied the verify. Any of these marks the top.
        // A TREE WITH NO MARKER MUST NOT SEARCH SHARED ANCESTORS. Without one, all 8 levels were walked,
        // so a planted `.xcconfig` in /tmp or $HOME satisfied the verify — the original above-checkout
        // defect, back for tarball and vendored trees. The walk now stops at the first marker OR at the
        // plist's own 2nd ancestor, whichever comes first: a project keeps its configs beside or just
        // above its plist, and anything further up is somebody else's.
        let markers = [".git", "Package.swift", "Package.resolved"]
        let isRoot = markers.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            || directoryHasXcodeProject(dir.path)
        if isRoot { sawMarker = true; break }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    // THE CONSISTENCY RULE APPLIES ACROSS FILES, so assignments are gathered first and judged once. A
    // key set to a real value in an xcconfig and to "" in the pbxproj's build settings is not declared
    // in the build that ships either way — judging each file alone made it declared by whichever file
    // happened to be read, which is the cross-file form of last-assignment-wins.
    var assignments: [BuildSettingAssignment] = []
    var perFile: [String: [BuildSettingAssignment]] = [:]
    // Keys a file declares in SOME configuration but not in the one that ships. Collected alongside the
    // assignments because the App Store archive is Release: a Debug-only key is not a declaration, and
    // counting it was flip #17.
    var configScoped: Set<String> = []
    func take(_ text: String, _ at: String) {
        configScoped.formUnion(configurationScopedKeys(text))
        let a = usageAssignmentsInBuildSettings(text)
        guard !a.isEmpty else { return }
        assignments += a
        perFile[at, default: []] += a
    }
    for d in dirs {
        // `atPath:` again, for the reason `directoryHasXcodeProject` carries: the URL variant stats every
        // entry, and these are directories chosen by a walk, not by this function.
        guard let names = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
        for e in names.map({ d.appendingPathComponent($0) }) {
            var candidates: [URL] = []
            if e.pathExtension == "xcodeproj" { candidates.append(e.appendingPathComponent("project.pbxproj")) }
            if e.pathExtension == "xcconfig" { candidates.append(e) }
            for c in candidates {
                guard let text = try? String(contentsOf: c, encoding: .utf8) else { continue }
                take(text, c.path)
                // FOLLOW `#include`, one level. An xcconfig that splits its settings into a shared file
                // is an ordinary layout, and missing it produced a FALSE under-declaration — the exact
                // "teaches the reader to distrust the tool" failure this reader exists to remove. One
                // level, and only relative paths inside the project: enough for the split-config case
                // without turning a config read into an unbounded file walk.
                // FOLLOW THE WHOLE CHAIN, not one level. A three-deep split config —
                // `App.xcconfig` → `Configs/mid.xcconfig` (declares) → `deep.xcconfig` (undeclares) —
                // resolves EMPTY at build time, because a later include wins. Reading one level saw the
                // declaration and never the undeclare, so the key counted as declared and the verify
                // passed: flip #18. The engine's own consistency rule would have caught it had the file
                // been read at all; the defect was purely the depth bound, and three-deep xcconfig
                // chains are an ordinary layout.
                //
                // Bounded and cycle-safe: a `visited` set (xcconfigs include each other in real
                // projects) and a depth cap, so a config read cannot become an unbounded file walk. Each
                // hop still passes through `includedConfigPaths`, which keeps the containment check.
                var frontier = includedConfigPaths(text, relativeTo: c)
                var visited: Set<String> = [c.standardizedFileURL.path]
                var depth = 0
                while !frontier.isEmpty, depth < 16 {
                    var next: [URL] = []
                    for inc in frontier where visited.insert(inc.standardizedFileURL.path).inserted {
                        guard let itext = try? String(contentsOf: inc, encoding: .utf8) else { continue }
                        take(itext, inc.path)
                        next += includedConfigPaths(itext, relativeTo: inc)
                    }
                    frontier = next
                    depth += 1
                }
            }
        }
    }
    let verdict = declaredKeys(from: assignments)
    let declared = verdict.declared.subtracting(configScoped)
    for (file, a) in perFile {
        let here = Set(a.map(\.name)).intersection(declared)
        if !here.isEmpty { found[file] = here }
    }
    // `inconsistent`: keys some file assigns a real value and another leaves EMPTY. Not counted as
    // declared — the engine cannot tell which configuration ships without the build graph, and the App
    // Store archive is the strict case — but REPORTED, because an inconsistent declaration is a genuine
    // finding about the project rather than a limitation of the reader.
    return (found, verdict.inconsistent.union(configScoped))
}

/// The files an `.xcconfig` `#include`s, resolved against its own directory.
///
/// Two boundaries, both breached in review:
///
///   * COMMENTS FIRST. Includes were extracted from RAW text, so `/* #include "keys.xcconfig" */` was
///     still followed and the keys in it counted — a declaration the build never sees. The text is now
///     comment-stripped by the same evaluator the settings go through.
///   * THE CONTAINMENT CHECK IS ON THE RESOLVED PATH. It tested the literal string for `".."`, and
///     `standardizedFileURL` does not resolve symlinks — so `#include "configs/link.xcconfig"`, a
///     symlink pointing anywhere on the filesystem, was read and its planted keys counted. Both sides
///     are now resolved before the containment test: resolve the artifact, not the string.
func includedConfigPaths(_ text: String, relativeTo config: URL) -> [URL] {
    let base = config.deletingLastPathComponent()
    let root = base.resolvingSymlinksInPath().standardizedFileURL.path
    var out: [URL] = []
    // Same single-pass stripper the settings go through, so an include cannot be found by a scan that
    // disagrees with the one that reads the file's settings.
    for rawLine in stripCommentsPreservingStrings(text).split(separator: "\n") {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("#include") else { continue }
        // `#include "a.xcconfig"` and the optional form `#include? "a.xcconfig"`.
        guard let open = line.firstIndex(of: "\""),
              let close = line.lastIndex(of: "\""), open < close else { continue }
        let rel = String(line[line.index(after: open)..<close])
        guard !rel.isEmpty, !rel.hasPrefix("/") else { continue }
        let target = base.appendingPathComponent(rel)
        // Resolve BOTH sides. A file that does not exist resolves to itself, which is fine: it will
        // fail to read a moment later.
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root || resolved.path.hasPrefix(root + "/") else { continue }
        out.append(resolved)
    }
    return out
}

// The build-settings EVALUATOR lives in CandorCore/BuildSettings.swift — moved there so it can be
// unit-tested at all. See that file: it had been rewritten three times and flipped fourteen times
// while sitting in this executable target, which SwiftPM cannot `@testable import`.

// Dispatched from main.swift when argv[1] is `privacy-manifest`.

/// Why an effect this engine reports needs NO usage-description key. One reason per effect, because
/// they differ: a runtime authorization prompt is not the same statement as "Apple requires nothing".
let keylessReason: [String: String] = [
    "Notify": "notifications gate at runtime via requestAuthorization",
    "MotionRaw": "Apple requires NSMotionUsageDescription only for the stored/derived CoreMotion APIs, "
        + "not for the raw accelerometer/gyroscope stream",
    "ContactsPicker": "the system contacts picker runs out of process — the app never gains access to "
        + "the library, only to what the user picked, so Apple requires no usage description",
    "PhotosPicker": "PHPicker runs out of process — the app never gains photo-library access, only the "
        + "assets the user selected, so Apple requires no usage description",
]

/// Does this directory hold an `.xcodeproj`/`.xcworkspace`? The `atPath:` listing, NOT `at:` — the URL
/// variant builds a `URL` (and stats) for every entry, which on a directory with 185,000 of them is a
/// 72-second call. Sampling one `--verify` put every second of it inside
/// `contentsOfDirectoryAtURL` → `_FSURLCreateWithPathAndExtendedAttributes`. Names are all this test
/// needs.
func directoryHasXcodeProject(_ path: String) -> Bool {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
    return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
}

/// The checkout `path` belongs to — `.git` / `Package.swift` / `Package.resolved` / an `.xcodeproj` or
/// `.xcworkspace` within eight hops up — or nil when there is none. ONE definition, because both
/// callers below use it for the same purpose: deciding whether a directory tree is this app's, and so
/// whether descending it answers about this app at all.
func projectRootAbove(_ path: String) -> String? {
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: path)
    var isD: ObjCBool = false
    if !(fm.fileExists(atPath: path, isDirectory: &isD) && isD.boolValue) {
        dir = dir.deletingLastPathComponent()
    }
    for _ in 0..<8 {
        let markers = [".git", "Package.swift", "Package.resolved"]
        let isRoot = markers.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            || directoryHasXcodeProject(dir.path)
        if isRoot { return dir.path }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return nil
}

/// How many NON-SWIFT source files sit in the tree this plist belongs to.
///
/// Bounded by the same project-root walk the build-settings reader uses, so it cannot wander above the
/// checkout and count somebody else's code. Counts only languages that can reach a sensor directly.
///
/// **THE WALK MUST FIND A ROOT, NOT MERELY RUN OUT OF HOPS — and `nil` when it doesn't.** The first
/// version enumerated `dir` whichever way the loop ended, so a plist with no project marker above it (a
/// temp directory, `/tmp`, an extracted archive) walked eight levels up and enumerated THAT: measured at
/// **21 minutes on one `swift test` case**, from `/var/folders/…/T/` — a census of the machine's temp
/// tree. Wrong twice over: unbounded work, and every `.c` found there is somebody else's code counted as
/// this app's undisclosed reach.
///
/// The obvious repair — fall back to the plist's own directory — fixes neither half, because that
/// directory IS `/var/folders/…/T` in the case that produced the 21 minutes. And a depth cap would trade
/// the cost for an under-count, which is the wrong currency: this number is a DISCLOSURE, so a quiet `0`
/// is a "nothing unread here" the run has no grounds for. So: no project root located ⇒ **nil**, and the
/// caller discloses that the count could not be taken rather than printing a zero it cannot support.
/// When a root IS found the enumeration is bounded by the checkout and skips the build and dependency
/// trees the other walkers skip — a vendored `Pods/` is not this target's un-analyzed source.
func countNonSwiftSources(near plistPath: String) -> Int? {
    let fm = FileManager.default
    guard let root = projectRootAbove(plistPath) else { return nil }
    let dir = URL(fileURLWithPath: root)
    let skip = VENDOR_SKIP_DIRS
    var n = 0
    guard let en = fm.enumerator(atPath: dir.path) else { return nil }
    for case let rel as String in en {
        if let leaf = rel.split(separator: "/").last.map(String.init), skip.contains(leaf) {
            en.skipDescendants(); continue
        }
        let ext = (rel as NSString).pathExtension.lowercased()
        if ["m", "mm", "c", "cc", "cpp", "cxx"].contains(ext), !isHarnessPath(rel) {
            n += 1
            if n > 5000 { break }   // a count, not a census
        }
    }
    return n
}

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
///
/// **RECURSIVE ONLY INSIDE A CHECKOUT.** `root` is the directory holding the plist, and when that is a
/// real target directory the descent is bounded by the app. When the plist was handed to `--verify`
/// from somewhere that is NOT a checkout — a temp directory, `/tmp`, an extracted archive — the descent
/// is bounded by nothing: measured at **233 seconds for one `swift test` case**, enumerating the
/// machine's whole temp tree to look for a file "beside" the plist. So the same project-root test
/// `countNonSwiftSources` uses gates the recursion: no root above the plist ⇒ "beside" means literally
/// beside, the plist's own directory and no deeper. Nothing is lost where anything could be — an
/// entitlements file three levels under a directory that is not a checkout is not this app's.
///
/// **THE SKIP SET IS `VENDOR_SKIP_DIRS`, NOT A COPY OF IT.** It was a copy, and it had lost `Carthage`
/// while the comment below still said "same exclusions as the Info.plist discovery" — so a vendored
/// `.entitlements` under `Carthage/` made this find two files and refuse, and the refusal is INVISIBLE
/// on `--json`. See `VENDOR_SKIP_DIRS` for the measured A/B and the `entitlementsUnread` block below
/// for the disclosure that makes the refusal survivable when the next vendor directory is not on any
/// list. Returns the CANDIDATES it refused over, because a refusal the reader cannot see the inputs to
/// is not actionable.
func discoverEntitlements(from root: String) -> (path: String?, several: Bool, candidates: [String]) {
    let fm = FileManager.default
    let skip = VENDOR_SKIP_DIRS
    var found: [String] = []
    guard projectRootAbove(root) != nil else {
        let here = ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
            .filter { $0.hasSuffix(".entitlements") }
            .map { (root as NSString).appendingPathComponent($0) }
        if here.count == 1 { return (here[0], false, here) }
        return (nil, here.count > 1, here.count > 1 ? here.sorted() : [])
    }
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
    if found.count == 1 { return (found[0], false, found) }
    return (nil, found.count > 1, found.count > 1 ? found.sorted() : [])
}

/// Usage-description keys an entitlements file makes REQUIRED. Boolean-true entries only: an entitlement
/// present-but-false is not granted, and treating it as granted would demand a key for a capability the
/// app has switched off.
///
/// **`nil` MEANS UNREADABLE, AND UNREADABLE IS NOT BENIGN.** This returned `[]` for a file that exists
/// but cannot be parsed — indistinguishable from "read and grants nothing" — so a corrupt
/// `.entitlements` certified clean while the Info.plist next to it got fail-loud treatment. The caller
/// decides what unreadable means (the peek bound: it could bear on every undeclared entitlement-sourced
/// key); this function's job is only to stop conflating the two answers.
func entitlementRequiredKeys(_ path: String) -> [String]? {
    // `PropertyListSerialization`, not `NSDictionary(contentsOfFile:)` — the same API `loadDeclaredKeys`
    // uses, and for the second of the two reasons its comment gives. The first is that NSDictionary
    // returns nil on ANY failure, indistinguishable from a plist whose root is not a dict. The second
    // only showed up in CI: the initialiser is DEPRECATED on swift-corelibs-foundation, and this repo
    // compiles its own code with `-warnings-as-errors`, so it built on macOS and failed the Linux leg.
    // A rule the file already documented, in a function written six hours later that ignored it.
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let d = obj as? [String: Any] else { return nil }
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

/// The determination BASIS of each DISTINCT modelled key. Per key, not per effect-row: `CalendarUI`
/// accepts Calendar's own three keys, and summing rows counted them twice — a breakdown that did not
/// add up to the `modelled` total it explains. When two effects share a key, the FIRST in
/// `PRIVACY_EFFECTS_ORDER` names the basis (deterministic, and it is the parent of a split — the
/// established row — that wins over the newcomer).
private func privacyKeyBasisByKey() -> [String: String] {
    var basisByKey: [String: String] = [:]
    for eff in PRIVACY_EFFECTS_ORDER {
        for k in privacyKeyMap[eff] ?? [] where basisByKey[k] == nil {
            basisByKey[k] = PRIVACY_KEY_BASIS[eff] ?? "type"
        }
    }
    return basisByKey
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
    for (_, basis) in privacyKeyBasisByKey() { byBasis[basis, default: 0] += 1 }
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
              + "apply — the ONE key candor cannot determine at all. Apple's page for it links no symbol, "
              + "the FileProvider framework index has no presence/known-folder symbol, and no entitlement "
              + "names it. Check by hand: if your file-provider extension reports which items the user is "
              + "viewing, declare it.")
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
    guard let model = loadFixModel(prefix: prefix, who: "privacy-manifest") else {
        privacyDie("candor-swift privacy-manifest: no report for prefix `\(prefix)` — scan first (candor-swift <dir> --out \(prefix))")
    }

    // ⟨0.28⟩ **THIS VERB HAS AN ENVELOPE AND NEVER CONSULTED COMPLETENESS** (SPEC §2 — the ruling names
    // it: "the same MUST and NOT the same shape problem" as show/map). `loadFixModel` threads the ⟨0.21⟩
    // manifest into `model.completeness` and every answer below ignored it — measured on this engine
    // 2026-08-12: over a report declaring `unanalyzed`, generate emitted a bare `{reached, required}`;
    // over a corrupt SIBLING, `reached: []` — a clean "no sensors reached" with nothing anywhere in the
    // machine output saying the universe was partial. A sensor reached only from the unread unit is
    // invisible to this verb, and an App-Store submission gate is exactly the consumer that cannot weigh
    // a caveat it never receives.
    //
    // The pinned keys ride the envelope like any other verb — `incomplete` / `unanalyzed` /
    // `judgedNothing` (an ARRAY of report paths), each omitted when not applicable, so a complete
    // report's output stays byte-identical (measured, generate + verify, all three output modes). The
    // prose half goes where this verb's answer is NOT: stdout above the answer in human mode
    // (`printNote`, the family position), stderr when stdout carries a JSON document or a plist fragment
    // (`eprintNote` — prose on those streams would corrupt the document). Exit codes are UNTOUCHED
    // (⟨0.24⟩: a disclosure, not an exit code), and `ok` still answers the declared-vs-reached question
    // it always answered — the caveat qualifies it rather than replacing it.
    let comp = model.completeness
    let compSo = "the sensor reach below covers only the code candor could see — a sensor reached in "
               + "an unread unit is invisible to this verb"
    let compTail = "A usage-description key required only by unread code cannot appear here, and a "
                 + "clean verify is conditional on it. \(comp.gateLine) Re-scan for a complete answer."
    if pm.json || pm.xml { comp.eprintNote(so: compSo, tail: compTail) }
    else { comp.printNote(so: compSo, tail: compTail) }

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
    /// Set when the verb REFUSED to read an entitlements file it found candidates for — the disclosure
    /// that keeps `ok: true` from meaning "checked and clean" on a machine surface. See the assignment.
    var entitlementsUnread: [String: Any]?
    /// The PEEK BOUND (SPEC-EXTENSION-privacy.md "Whether the verdict moves is decided by a PEEK"):
    /// true when an unattributed entitlements file COULD FLIP THIS RUN'S VERDICT — some candidate
    /// grants an entitlement whose required key is undeclared, or a chosen file could not be parsed
    /// while such a key is undeclared. Moves the verdict to INCOMPLETE (`ok: false`,
    /// `incomplete: true`, exit 2) — never to exit 1, because no file was attributed and filing the
    /// violation would charge the app with a possibly-vendored file's grant.
    var entitlementsIncomplete = false
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
        // ⟨build settings⟩ Xcode 13+ generates the shipped plist FROM build settings by default, so a
        // key absent here may still be declared — see buildSettingUsageKeys for the measurement that
        // forced this. Merged into the declared set so the verify does not raise a false rejection
        // warning, and DISCLOSED below so "declared" never silently means "declared somewhere else".
        let (fromSettings, inconsistentSettings) = buildSettingUsageKeys(near: plistPath)
        let settingKeys = fromSettings.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        // A key some file declares and another leaves EMPTY is NOT counted (see declaredKeys) — but
        // saying nothing would leave the operator reading a "missing key" they can see declared right
        // there in an xcconfig, which is how a reader learns to distrust the verb. Name it, and say
        // which way the engine resolved it.
        let stillMissingAndInconsistent = inconsistentSettings.subtracting(declared)
        if !stillMissingAndInconsistent.isEmpty {
            FileHandle.standardError.write(
                ("· \(stillMissingAndInconsistent.count) key(s) declared INCONSISTENTLY in build "
                 + "settings — set in one configuration and empty or ABSENT in another: "
                 + "\(stillMissingAndInconsistent.sorted().joined(separator: ", ")). NOT counted as "
                 + "declared: which one ships depends on the configuration being built, and an App "
                 + "Store archive is Release. Give the key a value in every configuration that ships, "
                 + "or verify the BUILT app's Info.plist.\n").data(using: .utf8)!)
        }
        let onlyInSettings = settingKeys.subtracting(declared)
        let declaredAll = declared.union(settingKeys)
        let declaredSorted = declaredAll.sorted()
        if !onlyInSettings.isEmpty {
            for (file, keys) in fromSettings.sorted(by: { $0.key < $1.key }) {
                let here = keys.intersection(onlyInSettings).sorted()
                if here.isEmpty { continue }
                FileHandle.standardError.write(
                    ("· \(here.count) key(s) declared as Xcode BUILD SETTINGS, not in this plist: "
                     + "\(here.joined(separator: ", ")) (\(URL(fileURLWithPath: file).lastPathComponent)). "
                     + "Xcode synthesises them into the shipped Info.plist. Counted as declared — but a "
                     + "setting can belong to a DIFFERENT target, which this cannot tell without the build "
                     + "graph; verify the BUILT app's Info.plist to be certain.\n").data(using: .utf8)!)
            }
        }

        // UNDER-declaration: a reached effect (except Notify, which needs no key) whose acceptable-key set
        // has NO member present in the plist — the App-Store-rejection finding.
        var underDeclared: [(effect: String, keys: [String], fns: [String])] = []
        // CONDITIONALLY under-declared: the effect's keys are absent but required only under a condition
        // this engine cannot decide (PRIVACY_CONDITIONAL_REQUIREMENT — today, EventKitUI's iOS 17
        // deployment-target fence). A ⚠ with the condition NAMED, never a ✗ and never silence: a hard
        // failure is a false claim against every iOS-17+-only app, and dropping the key is the silent
        // under-report against every pre-17 one. Exit code unchanged — disclosure, not a gate.
        var conditionallyUnder: [(effect: String, keys: [String], fns: [String], condition: String)] = []
        for eff in reached {
            let keys = privacyKeyMap[eff] ?? []
            if keys.isEmpty { continue }   // Notify — no key required, never under-declared
            if let cond = PRIVACY_CONDITIONAL_REQUIREMENT[eff] {
                if !keys.contains(where: { declaredAll.contains($0) }) {
                    conditionallyUnder.append((effect: eff, keys: keys, fns: fnsFor(eff), condition: cond))
                }
                continue
            }
            // `privacy/2` — when the direction was PROVED and this effect's keys are direction-sensitive,
            // check each proved direction against its own key set. An app that reads AND writes HealthKit
            // needs BOTH keys, and reports the missing side by name rather than as one vague "Health".
            let dirs = dirsByEffect[eff] ?? []
            if let byDir = privacyKeyMapByDirection[eff], !dirs.isEmpty {
                for d in dirs.sorted() {
                    guard let dk = byDir[d], !dk.contains(where: { declaredAll.contains($0) }) else { continue }
                    let fns = (fnsByEffectDir["\(eff)/\(d)"] ?? []).sorted().prefix(fnCap).map { $0 }
                    underDeclared.append((effect: "\(eff) (\(d))", keys: dk, fns: fns))
                }
                continue
            }
            // No proved direction (or a direction-insensitive effect) — the pre-`privacy/2` rule exactly.
            if !keys.contains(where: { declaredAll.contains($0) }) {
                underDeclared.append((effect: eff, keys: keys, fns: fnsFor(eff)))
            }
        }
        // A conditional finding is REDUNDANT when its parent effect already failed hard over the same
        // keys — "you must declare NSCalendars*" followed by "…and separately, you might need
        // NSCalendars*" is one finding wearing two glyphs. The hard row governs; declaring its key
        // satisfies both.
        conditionallyUnder.removeAll { c in
            guard let parent = EFFECT_SPLIT_PARENT[c.effect] else { return false }
            return underDeclared.contains { $0.effect == parent || $0.effect.hasPrefix("\(parent) (") }
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
        // NON-SWIFT SOURCES ARE A BLIND SPOT AND MUST SAY SO. This engine reads `.swift` only, and a
        // mixed-language app — which is what most mature iOS apps are — can reach a sensor entirely
        // from Objective-C. Measured: a target with one trivial `.swift` file beside a `.m` that calls
        // `AVCaptureDevice` verified `✓ (0 effects)`, exit 0, against an EMPTY plist, with no
        // conditionality line and nothing naming the files that were not read. The uncovered-MODULE
        // ledger did not fire because nothing Swift imported anything uncovered — the code simply was
        // not Swift.
        //
        // "Absence from the report is never a claim of purity" is this project's rule; a language the
        // scanner cannot read is exactly the case it exists for.
        let nonSwiftSources = countNonSwiftSources(near: plistPath)
        // nil = no project root could be located from the plist, so the count was NOT taken (see
        // `countNonSwiftSources`). That is disclosed on its own channel rather than through
        // `conditional`: this flag gates the COVERAGE block, and folding an unrelated "we could not
        // look" into it emitted an empty `coverage: {modules: [], uncovered: 0}` — a disclosure that
        // says nothing, attached to a question it does not answer.
        let conditional = !model.coverage.isEmpty || (nonSwiftSources ?? 0) > 0

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
        // ⟨scope travels⟩ THE SCAN ALREADY KNEW WHICH FILE. `--target` resolved this binary's
        // `CODE_SIGN_ENTITLEMENTS` from its build settings — an exact, per-target answer — and recorded
        // it in the report. Discovery is the fallback, not the rule: it walks a directory and, on the
        // multi-target repos `--target` exists for, finds several and refuses to guess, leaving the
        // entitlement-sourced keys unchecked (measured on NetNewsWire: 8 `.entitlements` in the tree, one
        // key never checked). Narrowing that SEARCH would still be a search; the build settings NAME the
        // file. A recorded path that no longer exists falls back rather than failing — the report can be
        // older than the tree.
        var ent: (path: String?, several: Bool, candidates: [String])
        var entFromScope = false
        if let scoped = model.scopeEntitlements, FileManager.default.fileExists(atPath: scoped) {
            ent = (scoped, false, [scoped])
            entFromScope = true
        } else {
            ent = discoverEntitlements(from: plistDir.isEmpty ? FileManager.default.currentDirectoryPath : plistDir)
        }
        // Candidate paths are reported relative to the plist's directory — the absolute form leaks a
        // developer's home directory into a CI artifact, and the repos that hit this have several files
        // with the SAME basename, so a bare-basename list names nothing.
        let plistDirBase = plistDir.hasSuffix("/") ? plistDir : plistDir + "/"
        func relToPlist(_ c: String) -> String {
            c.hasPrefix(plistDirBase) ? String(c.dropFirst(plistDirBase.count)) : c
        }
        if let ep = ent.path, let required = entitlementRequiredKeys(ep) {
            let need = required.filter { !declaredAll.contains($0) }
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
        } else if let ep = ent.path {
            // ⟨peek bound⟩ **A CHOSEN FILE THAT CANNOT BE PARSED IS NOT A CLEAN ONE.** This path used
            // to receive `[]` from `entitlementRequiredKeys` — indistinguishable from "read and grants
            // nothing" — so a corrupt `.entitlements` certified clean while an unreadable Info.plist
            // fails loud three screens up. The grant set is unknowable, so it could contain ANY
            // entitlement: every entitlement-sourced key not already declared could bear on this
            // verdict, and the same bound as the `several` refusal below decides whether it moves.
            let bear = ENTITLEMENT_REQUIRED_KEYS.values.filter { !declaredAll.contains($0) }.sorted()
            var unread: [String: Any] = [
                "reason": "unreadable",
                "candidates": [relToPlist(ep)],
                "uncheckedKeys": ENTITLEMENT_REQUIRED_KEYS.values.sorted(),
            ]
            if !bear.isEmpty {
                unread["couldBear"] = bear
                entitlementsIncomplete = true
            }
            entitlementsUnread = unread
            if !pm.json, !pm.xml {
                print("· \((ep as NSString).lastPathComponent) could not be parsed as a property list — "
                      + "entitlement-sourced keys (\(ENTITLEMENT_REQUIRED_KEYS.count)) are unchecked.")
                if !bear.isEmpty {
                    print("⚠ INCOMPLETE: an unreadable grant set could require "
                          + "\(bear.joined(separator: ", ")), which is not declared. Not counted as a "
                          + "violation — nothing was read — but this run cannot certify the manifest "
                          + "either. Fix or remove the file, then re-verify.")
                }
            }
        } else if ent.several {
            // ⟨peek bound⟩ **READ EVERY CANDIDATE; ATTRIBUTE NONE** (SPEC-EXTENSION-privacy.md
            // "Whether the verdict moves is decided by a PEEK"). The refusal above this line was never
            // "these files are unsafe to open" — it was a refusal to ATTRIBUTE one candidate's grants
            // to the app. So peek them all and ask the one question attribution cannot change: could
            // any candidate flip THIS run's verdict? A candidate bears when it grants an entitlement
            // whose key is undeclared; an unparseable candidate bears on every undeclared key (the
            // grant set is unknowable — unreadable is not benign). Empty ⇒ the pass below is exactly
            // as sound as an attributed pass, whichever candidate is the app's own — the bound that
            // keeps this affordable on multi-target repos (NetNewsWire: 8 files, all sandbox-class
            // grants, stays green). Non-empty ⇒ INCOMPLETE, exit 2, never exit 1.
            var bearing: Set<String> = []
            for c in ent.candidates {
                if let req = entitlementRequiredKeys(c) {
                    bearing.formUnion(req.filter { !declaredAll.contains($0) })
                } else {
                    bearing.formUnion(ENTITLEMENT_REQUIRED_KEYS.values.filter { !declaredAll.contains($0) })
                }
            }
            // ⟨entitlements unread⟩ **THE REFUSAL TRAVELS ON EVERY SURFACE, NOT JUST THE HUMAN ONE.**
            //
            // This branch is the verb deciding NOT to read the app's own `.entitlements` — so every
            // entitlement-sourced key goes unchecked and the verdict below is a claim about strictly
            // less than it appears to be. It printed under `!pm.json, !pm.xml`, so the `--json`
            // document CI reads carried `"ok": true` and NOTHING ELSE: no key, no count, no note.
            // Measured 2026-08-30 on two trees identical but for the name of a vendor directory —
            // `Pods/` exited 1 with `entitlementUnderDeclared`, `Carthage/` exited 0 with `ok: true`
            // and the key absent. `Carthage` being off one skip list caused THAT instance; the reason
            // this block exists is that the NEXT vendor directory will not be on the list either
            // (`vendor/`, `Externals/`, `Frameworks/`, a git submodule, a sibling checkout), and a
            // silent `ok: true` over an unread entitlements file is a cardinal sin whichever directory
            // produced it. The list fix removes one cause; this removes the SILENCE.
            //
            // `ok` and the exit code are DELIBERATELY UNCHANGED. Flipping them would fail every
            // multi-target repo this verb is meant to serve (measured on NetNewsWire: 8 `.entitlements`
            // in the tree) over a question this run cannot answer either way — an over-charge that
            // deletes the feature. Same shape as `conditionallyUnderDeclared` and `incomplete` above:
            // `ok: true` beside a stated caveat is not the same claim as a bare `ok: true`, and the
            // machine consumer is the reader who could not previously tell them apart.
            var unread: [String: Any] = [
                "reason": "several",
                // Repo-relative to the plist's directory, not absolute: the absolute form leaks a
                // developer's home directory into a CI artifact, and every basename here is
                // `App.entitlements` on the repos that hit this — a list of identical basenames names
                // nothing, which is the mistake `buildSettingUsageKeys` already made once.
                "candidates": ent.candidates.map(relToPlist),
                "uncheckedKeys": ENTITLEMENT_REQUIRED_KEYS.values.sorted(),
            ]
            if !bearing.isEmpty {
                unread["couldBear"] = bearing.sorted()
                entitlementsIncomplete = true
            }
            entitlementsUnread = unread
            if !pm.json, !pm.xml {
                print("· several .entitlements files here — none attributed. Entitlement-sourced keys "
                      + "(\(ENTITLEMENT_REQUIRED_KEYS.count)) are unchecked; re-scan with --target so the "
                      + "report carries this binary's own CODE_SIGN_ENTITLEMENTS.")
                if !bearing.isEmpty {
                    print("⚠ INCOMPLETE: one of them grants an entitlement requiring "
                          + "\(bearing.sorted().joined(separator: ", ")), which is not declared — and "
                          + "this run cannot tell whether that file is the app's own. Not counted as a "
                          + "violation (that would attribute a possibly-vendored grant to the app); not "
                          + "a pass either. Re-scan with --target to attribute the right file.")
                }
            }
        }
        // PROVENANCE, on a PASS as much as a finding: "we checked the entitlements" is only actionable
        // if the reader can see WHICH file, and an entitlements check that silently read the wrong
        // target's file is the failure this rung exists to remove.
        if entFromScope, let ep = ent.path, !pm.json, !pm.xml {
            print("· entitlements read from \((ep as NSString).lastPathComponent), named by the scanned "
                  + "target's CODE_SIGN_ENTITLEMENTS — not discovered by searching.")
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
            // The machine consumer gets the conditional finding too — `ok: true` beside a condition the
            // reader must settle is not the same claim as a bare `ok: true`, and CI is the reader that
            // cannot weigh a caveat it never receives. Absent when empty, so the shape is unchanged for
            // everyone else.
            if !conditionallyUnder.isEmpty {
                verdict["conditionallyUnderDeclared"] = conditionallyUnder.map {
                    ["effect": $0.effect, "keys": $0.keys, "fns": $0.fns,
                     "condition": $0.condition] as [String: Any]
                }
            }
            // PROVENANCE TRAVELS ON THE MACHINE CHANNEL TOO. `declared` merges plist keys with keys read
            // from Xcode BUILD SETTINGS, and the function that does the merge documents that the
            // provenance is "REPORTED, never silently merged" — which was true only of the human stderr
            // line. A CI consumer reading the JSON could not tell a key declared in the plist this
            // target ships from one seen in a project file up the tree, and those are not the same
            // claim: a build setting can belong to a DIFFERENT target. Present only when there is
            // something to say, so a plist-only verify's JSON keeps its previous shape exactly.
            if !onlyInSettings.isEmpty {
                verdict["declaredViaBuildSettings"] = fromSettings
                    .filter { !$0.value.intersection(onlyInSettings).isEmpty }
                    .map { file, keys in
                        ["file": URL(fileURLWithPath: file).lastPathComponent,
                         "path": file,
                         "keys": keys.intersection(onlyInSettings).sorted()] as [String: Any]
                    }
                    .sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
            }
            // The machine channel gets the same disclosure the console does: a key resolved as NOT
            // declared because the project disagrees with itself is a different answer from one that is
            // simply absent, and a consumer that cannot tell them apart cannot act on it.
            if !inconsistentSettings.isEmpty {
                verdict["inconsistentInBuildSettings"] = inconsistentSettings.sorted()
            }
            // ⟨0.15 staged⟩ conditionality block — ABSENT when fully covered, so a fully-covered
            // verify's JSON is byte-identical to the pre-⟨0.15⟩ shape.
            if conditional {
                verdict["conditional"] = true
                verdict["coverage"] = ["uncovered": uncoveredModules.count, "modules": uncoveredModules] as [String: Any]
            }
            // …and the language bound on its own key, present ONLY when the count could not be taken, so
            // a verify that DID count stays byte-identical. A machine consumer reading `ok: true` with no
            // caveat is the one this exists for: no project root means no tree to call the app's, so this
            // run cannot say whether unread Objective-C exists.
            if nonSwiftSources == nil { verdict["nonSwiftSourcesCounted"] = false }
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
                "byBasis": Dictionary(grouping: privacyKeyBasisByKey(), by: { $0.value })
                    .mapValues { $0.count },
            ] as [String: Any]
            if und.ops > 0 {
                verdict["undeterminedPaths"] = ["count": und.ops, "functions": und.fns] as [String: Any]
            }
            // …and the OTHER half of the entitlement answer: the run that checked NOTHING. Absent when
            // an entitlements file was read (or when there was none to read), so a verify that did the
            // check keeps its previous byte shape exactly.
            if let unread = entitlementsUnread { verdict["entitlementsUnread"] = unread }
            if !entitlementFindings.isEmpty {
                verdict["entitlementUnderDeclared"] = entitlementFindings
                // `ok` MUST AGREE WITH THE EXIT CODE. Leaving it as the code-derived verdict meant a
                // machine reading the field it is named for saw `"ok": true` beside exit 1 — the naive
                // CI check is `if ok`, and it would pass a manifest that is about to be rejected.
                verdict["ok"] = false
            }
            // ⟨peek bound⟩ the INCOMPLETE verdict, in the ⟨0.21⟩ vocabulary: `ok: false`,
            // `incomplete: true`, exit 2 below. NOT `entitlementUnderDeclared` — no file was
            // attributed, and filing the violation would charge the app with a possibly-vendored
            // file's grant.
            if entitlementsIncomplete {
                verdict["ok"] = false
                verdict["incomplete"] = true
            }
            // ⟨0.28⟩ the completeness caveat, in the machine document the CI consumer reads — empty on a
            // complete report, so an ordinary verify stays byte-identical. See the load site above.
            for (k, v) in comp.disclosureJSON { verdict[k] = v }
            emitPrivacyJSON(verdict)
            // ⟨0.24⟩ precedence: a CERTAIN violation (code-reach or attributed-entitlement) dominates
            // the incomplete refusal — exit 1 names the finding; only an otherwise-clean run that the
            // peek bound found unanswerable is exit 2.
            exit((ok && !entitlementUnderDeclared) ? (entitlementsIncomplete ? 2 : 0) : 1)
        }

        // `--xml` on a VERIFY prints exactly the fragment that would fix the failure — nothing else, so
        // it pipes. A verify that tells you what is missing and then makes you go and look up how to
        // write it has done half a job; this is the other half.
        if pm.xml {
            // THE SAME CAVEAT ON THE THIRD SURFACE. `--xml`'s "nothing missing" is a completeness claim,
            // and it was printed over a run that never opened the app's `.entitlements` — so the one
            // output whose entire purpose is "here is what to add" said there was nothing to add. A
            // COMMENT, so the fragment still pastes into a plist unchanged.
            //
            // **NO `--` ANYWHERE IN THESE COMMENT BODIES, WHICH IS WHY THE FLAG NAMES LOST THEIR
            // DASHES.** XML forbids `--` inside a comment. The line below used to read
            // `<!-- candor privacy-manifest --verify: … -->` and this new one was written the same way,
            // which produced output that Apple's lenient `plutil -lint` accepts and a conformant parser
            // (`xml.dom.minidom`) REJECTS as "invalid token" — in the one output whose entire purpose is
            // to be pasted into somebody's plist. Candidate PATHS are omitted for the same reason: a
            // filename may contain `--` and nothing here could stop it. `testTheXmlSurfaceIsWellFormedXml`
            // pins this against a real parser rather than against `plutil`.
            if let unread = entitlementsUnread {
                let n = (unread["candidates"] as? [String])?.count ?? 0
                if unread["reason"] as? String == "unreadable" {
                    print("<!-- candor privacy-manifest verify: the .entitlements file exists and "
                          + "could not be parsed as a property list, so the "
                          + "\(ENTITLEMENT_REQUIRED_KEYS.count) entitlement-sourced key(s) are "
                          + "unchecked and this fragment cannot be complete. -->")
                } else {
                    print("<!-- candor privacy-manifest verify: \(n) .entitlements files found here and "
                          + "NONE READ as this binary's own, so the \(ENTITLEMENT_REQUIRED_KEYS.count) "
                          + "entitlement-sourced key(s) are unchecked and this fragment cannot be "
                          + "complete. Re-scan naming this binary's own CODE_SIGN_ENTITLEMENTS "
                          + "(the `target` flag). -->")
                }
                // ⟨peek bound⟩ the verdict statement, not just the unread count — this surface's exit
                // code moves too, and a consumer must not learn that only from the shell. Key names are
                // plain identifiers, so the no-double-dash rule for these comments holds. The exit-2
                // claim is guarded the same way as the human verdict line: under ⟨0.24⟩ precedence a
                // certain violation exits 1, and a comment announcing exit 2 beside exit 1 would be
                // this surface lying about its own verdict.
                if let bear = unread["couldBear"] as? [String] {
                    if ok && !entitlementUnderDeclared {
                        print("<!-- candor privacy-manifest verify: VERDICT INCOMPLETE (exit 2). An "
                              + "unattributed .entitlements file could require "
                              + "\(bear.joined(separator: ", ")) and it is not declared. Not a violation "
                              + "(nothing was attributed) and not a pass. -->")
                    } else {
                        print("<!-- candor privacy-manifest verify: an unattributed .entitlements file "
                              + "could additionally require \(bear.joined(separator: ", ")), which is "
                              + "not declared. Not counted as a violation; the exit code reflects the "
                              + "certain findings above it. -->")
                    }
                }
            }
            if underDeclared.isEmpty {
                print("<!-- candor privacy-manifest verify: nothing missing; no keys to add. -->")
            } else {
                print(plistFragment(underDeclared.compactMap { u in
                    u.keys.first.map { (effect: u.effect, key: $0) }
                }))
            }
            // the exit code is the VERDICT and does not change with the output format (⟨0.24⟩
            // precedence: a certain violation dominates the incomplete refusal)
            exit((ok && !entitlementUnderDeclared) ? (entitlementsIncomplete ? 2 : 0) : 1)
        }

        // HUMAN: the divergences first (the actionable findings), then the verdict line.
        for u in underDeclared {
            let via = u.fns.isEmpty ? "" : " (via \(u.fns.prefix(3).joined(separator: ", ")))"
            print("✗ code reaches \(u.effect)\(via) but Info.plist declares no \(u.keys.first ?? "usage-description key")")
        }
        for c in conditionallyUnder {
            let via = c.fns.isEmpty ? "" : " (via \(c.fns.prefix(3).joined(separator: ", ")))"
            print("⚠ code reaches \(c.effect)\(via) and no \(c.keys.first ?? "usage-description key") is "
                  + "declared — \(c.condition). Candor cannot see the deployment target, so this is not "
                  + "counted as missing; if it applies to you, declare the key.")
        }
        for key in overDeclared {
            // Name the effect this key would satisfy, for context.
            let eff = privacyKeyMap.first { $0.value.contains(key) }?.key ?? "sensor"
            // NOT "unused — delete it", which is how the old wording read. Several keys are required by
            // FRAMEWORK-MEDIATED access that has no call site to find: WKWebView's site geolocation
            // needs NSLocationWhenInUseUsageDescription, and UIActivityViewController's built-in Save
            // Image activity needs NSPhotoLibraryAddUsageDescription. Both fired on shipping browsers
            // here, and acting on the old phrasing crashes the app at the share sheet. The line is true
            // about REACH and must not be read as advice about the key.
            print("⚠ \(key) declared, and this scan found no \(eff) reach for it — which may simply mean "
                  + "the access is framework-mediated (a web view's geolocation, a share-sheet activity) "
                  + "and has no call site to find. NOT a recommendation to remove it.")
        }
        if entitlementsIncomplete && ok && !entitlementUnderDeclared {
            // ⟨peek bound⟩ NO ✓ LINE OVER AN UNANSWERABLE RUN. The ⚠ INCOMPLETE detail printed at the
            // refusal site above; this is the verdict line in its place, so the two cannot disagree.
            // Guarded on `ok` because ⟨0.24⟩ precedence makes a certain violation exit 1 even when the
            // refusal also fired — this line names exit 2 and must only print when that is the verdict.
            print("· VERDICT INCOMPLETE — an entitlements file this run could not attribute could "
                  + "require a key that is not declared (see above). Exit 2: not a violation, not a "
                  + "pass.")
        } else if ok && overDeclared.isEmpty && conditionallyUnder.isEmpty {
            let n = reached.count
            print("✓ every MODELLED capability is declared (\(n) effect\(n == 1 ? "" : "s"))")
        } else if ok {
            // Clean of under-declaration, but an over-declaration or conditional warning was printed
            // above. With a CONDITIONAL key undeclared, "every modelled capability is declared" would be
            // an overclaim — the honest verdict is that nothing is PROVABLY missing.
            let n = reached.count
            let verdictNoun = conditionallyUnder.isEmpty
                ? "every MODELLED capability is declared"
                : "no MODELLED capability is provably missing"
            print("✓ \(verdictNoun) (\(n) effect\(n == 1 ? "" : "s")) — see the ⚠ note(s) above")
        }
        // ⟨0.15 staged⟩ the conditionality caveat travels with the human verdict too — LAST, so the
        // verdict line above stays where consumers expect it. Exit unchanged (disclosure, not a gate).
        if conditional {
            let n = uncoveredModules.count
            if n > 0 {
                print("⚠ verdict is conditional on \(n) uncovered module\(n == 1 ? "" : "s") — sensor usage there is invisible to this verify (chain dep reports or scan the workspace root to close the gap)")
            }
            // …and the language bound, which had no line at all. A mixed-language app can reach a
            // sensor entirely from Objective-C, and this engine reads `.swift` only.
            if let ns = nonSwiftSources, ns > 0 {
                print("⚠ verdict is conditional on \(ns) NON-SWIFT source file"
                      + "\(ns == 1 ? "" : "s") (.m/.mm/.c/.cpp) that this engine does not read "
                      + "— a sensor reached only from Objective-C is invisible here, and absence from the "
                      + "report is not a claim it is not used. Verify the BUILT app's Info.plist to be certain.")
            }
        }
        // …and its own arm, OUTSIDE `if conditional`, because "we could not look" is not the same claim
        // as "we looked and here is what is uncovered", and it must not be silent when nothing else is
        // conditional — that combination (a clean verify, no caveat) is precisely the false all-clear.
        if nonSwiftSources == nil {
            print("⚠ non-Swift sources were NOT counted: no project root (.git / Package.swift / "
                  + ".xcodeproj) could be located above \((plistPath as NSString).lastPathComponent), so "
                  + "there is no tree this verify can call the app's. A sensor reached only from "
                  + "Objective-C would be invisible here and this run cannot say whether any exist.")
        }
        // THE VOCABULARY BOUND, on every verify and especially on a PASS. A green verify means "green
        // for the keys this extension models" — and a reader who takes it for "green for Apple" is the
        // person who submits and gets rejected. Measured by a recall battery, not assumed; the reasons
        // travel with the list so this is a limitation a reader can act on rather than a disclaimer.
        printPrivacyVocabularyBound(undetermined: undeterminedPaths(model.byName),
                                    fileProvider: reachedSet.contains("FileProvider"))
        // Same verdict on every route (§3.1): certain violation 1, peek-bound incomplete 2, else 0.
        exit((ok && !entitlementUnderDeclared) ? (entitlementsIncomplete ? 2 : 0) : 1)
    }

    // ── GENERATE mode (no --verify) ─────────────────────────────────────────────────────────────────────
    // Emit the required Info.plist usage-description keys the code's sensor reach REQUIRES, each with the
    // reaching functions. `required` = {effect: [acceptable keys]} (PRIMARY key first); `reached` names the
    // effects. Notify appears in `reached` with an empty key list (no manifest key required).
    if pm.json {
        var required: [String: [String]] = [:]
        for eff in reached { required[eff] = privacyKeyMap[eff] ?? [] }
        var doc: [String: Any] = ["reached": reached, "required": required]
        // ⟨0.28⟩ the completeness caveat rides the generate document too: a `required` computed over a
        // partial universe may be SHORT, which is the under-declaration this verb exists to prevent.
        // Empty on a complete report — byte-identical output.
        for (k, v) in comp.disclosureJSON { doc[k] = v }
        emitPrivacyJSON(doc)
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
            // A conditionally-required key (EventKitUI's iOS 17 fence) must not read as an unconditional
            // requirement here either — generate is the same claim as verify, made forwards.
            let cond = PRIVACY_CONDITIONAL_REQUIREMENT[eff].map { " — \($0)" } ?? ""
            print("  \(eff) → \(primary)\(cond)\(byWhom)")
        } else {
            // NO Info.plist key — but there is more than one REASON for that now, and printing one
            // effect's reason for all of them states something false. `Notify` gates at runtime;
            // `MotionRaw` is a sensor Apple simply does not require a key for. The line said
            // "notifications gate at runtime via requestAuthorization" next to `MotionRaw`, which is a
            // wrong explanation attached to a right answer — the shape a reader learns to distrust.
            let why = keylessReason[eff] ?? "Apple documents no usage-description key for it"
            print("  \(eff) → (no Info.plist key — \(why))\(byWhom)")
        }
    }
    exit(0)
}
