// candor-swift — the §3.4 .candor/config layer (target-anchored discovery, fail-closed).
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation

// ── .candor/config (candor-spec §config): the checked-in floor under the CANDOR_* env vars ─────────
// Discovery is anchored to the SCAN TARGET (walk up from the target dir to the repo root's
// .candor/config), never the CWD; $CANDOR_CONFIG overrides discovery. Precedence: CLI flag →
// CANDOR_* env → this file → default. FAIL-CLOSED when configured-but-unusable (exit 2 — the §6.2
// unreadable-policy posture); only genuine absence is empty. Shared key vocabulary — candor-swift
// consumes `policy`, `baseline` (the AS-EFF-005 regression guard, Baseline.swift) and `deps` (SPEC §2
// report chaining, Deps.swift); the remaining java-only gate keys stay disclosed-inert. A key OUTSIDE
// the vocabulary warns (typo protection: a misspelt `policy` must not silently drop the gate).
// ⟨0.28 PROPOSED⟩ `engine` is in the vocabulary and NOT implemented here on purpose: candor-java enforces
// the pin, and a key this spec defines must never be reported as an unknown one — that would tell an
// operator their pin was ignored while a sibling engine was enforcing it.
let candorConfigKeys: Set<String> = ["policy", "baseline", "strict", "no-ambient", "closed-world", "taint", "deps", "unknown-alias", "net-partner", "unknown-ratchet", "engine"]

// The subset of `candorConfigKeys` this engine actually wires to a mode. The rest are spec-inert HERE —
// but a checked-in enforcement key that silently does nothing is a DECLARED-GATE-SILENTLY-OFF (the
// reader believes the gate is on, and another engine really does honour it), so an inert recognized key
// DISCLOSES loudly rather than staying mute (the 2026-07-09 config amendment; byte-shape with rust's
// CONFIG_KEYS_IMPLEMENTED). One wiring site each: `policy` → the policyPath floor (main.swift), `baseline`
// → the AS-EFF-005 guard path (main.swift), `deps` → the §2 chaining spec (main.swift), `unknown-ratchet`
// → the baseline guard's Unknown opt-in (main.swift). `unknown-alias` is ALSO implemented — Policy.swift's
// parseUnknownAliases reads it straight off the config TEXT — but it is multi-value, so it exits this
// loop at the `continue` below and never reaches the check, exactly as in rust.
let candorConfigKeysImplemented: Set<String> = ["policy", "baseline", "deps", "unknown-ratchet", "engine"]

// ⟨0.19⟩ Discover `.candor/config` TEXT anchored at `targetPath`: $CANDOR_CONFIG if set + readable, else the
// nearest `.candor/config` walking UP, else nil. Read-only + LENIENT (no exit — the caller decides
// fail-closed); used to resolve reason-class `unknown-alias` for the §6.2 gate + `parsepolicy`.
func discoverConfigText(targetPath: String) -> String? { discoverConfig(targetPath: targetPath)?.text }

/// ⟨0.24⟩ The same discovery, returning the PATH beside the text (SPEC §3.1: *"If a config file supplied
/// vocabulary that participated in the verdict, the `--gate-json` document MUST name that file"*). A
/// verdict changed by a file the operator cannot see named in the output is the ambient-input failure this
/// format exists to refuse, and the remedy is the usual one — not to forbid the input, but to make it
/// unable to act unnamed. Discovery walks parent directories, so an alias file anywhere ABOVE the anchor
/// participates; naming it is the only thing that makes that visible.
func discoverConfig(targetPath: String) -> (path: String, text: String)? {
    if let override = ProcessInfo.processInfo.environment["CANDOR_CONFIG"] {
        guard let t = try? String(contentsOfFile: override, encoding: .utf8) else { return nil }
        return (override, t)
    }
    var dir = (URL(fileURLWithPath: targetPath).standardizedFileURL.path as NSString).standardizingPath
    var isDir: ObjCBool = false
    if !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) {
        dir = (dir as NSString).deletingLastPathComponent
    }
    for _ in 0..<64 {
        let cand = (dir as NSString).appendingPathComponent(".candor/config")
        if FileManager.default.fileExists(atPath: cand) {
            guard let t = try? String(contentsOfFile: cand, encoding: .utf8) else { return nil }
            return (cand, t)
        }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir || parent.isEmpty { break }
        dir = parent
    }
    return nil
}
func loadCandorConfig(targetPath: String) -> [String: String] {
    var file: String? = nil
    if let override = ProcessInfo.processInfo.environment["CANDOR_CONFIG"] {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: override, isDirectory: &isDir) || isDir.boolValue {
            // ⟨0.24⟩ a broken gate CONFIG is an exit-2 cause like any other, and it writes the refusal
            // document too (SPEC §3.1, candor-spec `1503368` — the carve-out is gone).
            refuseGateAndExit("candor-swift: CANDOR_CONFIG set but \(override) is not a readable file — failing (exit 2)")
        }
        file = override
    } else {
        // STRING-based ancestor walk (NSString.deletingLastPathComponent), NOT URL's: URL's
        // deletingLastPathComponent at the root ("/" → "/..") varies across Foundation versions — one
        // toolchain clamps, another appends forever, which spun this walk INFINITELY on CI runners
        // (every spawn hung until XCTest's 10-min allowance SIGKILLed it) while terminating locally.
        // The string API is documented stable ("/" → "/"); the hop cap is belt-and-braces.
        var dir = (URL(fileURLWithPath: targetPath).standardizedFileURL.path as NSString).standardizingPath
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) {
            dir = (dir as NSString).deletingLastPathComponent
        }
        for _ in 0..<64 {
            let cand = (dir as NSString).appendingPathComponent(".candor/config")
            if FileManager.default.fileExists(atPath: cand) { file = cand; break }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        // NO CWD fallback here (deleted): discovery is TARGET-anchored per SPEC §3.4 — a CWD probe only
        // ever fired when the CWD was OUTSIDE the target's ancestry, i.e. it applied an UNRELATED repo's
        // config (and its policy) to this scan. Genuine absence is simply "no config".
        if file == nil { return [:] }
    }
    // DEFENSIVE fail-closed, deliberately uncovered (TESTING.md §6): reachable only in the race /
    // permission gap between the fileExists probe above and this read (e.g. a 0000-mode config) —
    // the CANDOR_CONFIG-names-no-file arm above is the tested fail-closed path.
    guard let text = try? String(contentsOfFile: file!, encoding: .utf8) else {
        refuseGateAndExit("candor-swift: config \(file!) exists but could not be read — failing (exit 2)")
    }
    // Name the config that governs this scan — an ancestor-walk discovery is otherwise invisible, and a
    // surprising gate verdict ("where did that policy come from?") needs the provenance on stderr.
    FileHandle.standardError.write("candor-swift: using config \(file!)\n".data(using: .utf8)!)
    var cfg: [String: String] = [:]
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        // UNICODE whitespace, matching the other four engines. Splitting on ASCII space/tab only left
        // a NO-BREAK SPACE (U+00A0 — the ordinary artifact of pasting a config out of a rendered doc)
        // glued to the key, so `engine\u{00A0} 0.26.0` became the token `engine\u{00A0}`: not the key
        // `engine`, so it was reported as an "unknown config key 'engine '" while the pin it names went
        // silently UNENFORCED and a MISMATCHED pin passed at exit 0. A false disclosure over a fail-open.
        let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let key = parts[0].lowercased()
        let val = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !candorConfigKeys.contains(key) {
            FileHandle.standardError.write("candor-swift: ignoring unknown config key '\(key)' in \(file!)\n".data(using: .utf8)!)
            continue
        }
        // MULTI-VALUE keys, both read from the config TEXT rather than this single-value map: ⟨0.19⟩
        // `unknown-alias` via parseUnknownAliases, ⟨0.20⟩ `net-partner` via parseNetPartners. `net-partner`
        // was missing from candorConfigKeys entirely, so a config setting it drew "ignoring unknown config
        // key 'net-partner'" while the value WAS honoured — a FALSE disclosure, worse than a missing one in
        // a tool whose contract is that its statements about itself are true. Recognized now, and skipped
        // before the implemented-check so it is not then mislabelled inert either.
        if key == "unknown-alias" || key == "net-partner" { continue }
        if !candorConfigKeysImplemented.contains(key) {
            // Recognized family-wide but INERT here. Silence would read as "the gate is on" to whoever
            // checked the key in — the divergence this tool exists to prevent — so say so on stderr.
            // Disclosure only: exit code, report, verdict and stdout are untouched.
            FileHandle.standardError.write("candor-swift: config key '\(key)' is recognized by the candor family but not implemented by candor-swift — that gate/mode is NOT active on this scan (the nightly lint / another engine enforces it)\n".data(using: .utf8)!)
            continue
        }
        cfg[key] = val
    }
    // FAMILY DECISION (2026-07-09): a RELATIVE path value in .candor/config resolves against the CONFIG
    // FILE'S location — the config is checked in beside the paths it names, so `policy .candor/gate.pol`
    // must work no matter where the scan is invoked from. Resolving against the CWD (the old behaviour,
    // via the plain contentsOfFile read downstream) made the same checked-in config pass or exit 2
    // depending on the invoker's directory. The anchor is the config file's directory, stepping OUT of a
    // containing `.candor/` dir first (a discovered config lives at <root>/.candor/config, and its values
    // are written root-relative — `policy .candor/gate.pol` names <root>/.candor/gate.pol, not
    // <root>/.candor/.candor/gate.pol). An EMPTY value stays empty (configured-with-empty fails loud).
    var anchor = (file! as NSString).deletingLastPathComponent
    if (anchor as NSString).lastPathComponent == ".candor" {
        anchor = (anchor as NSString).deletingLastPathComponent
    }
    for key in ["policy", "baseline"] {
        if let p = cfg[key], !p.isEmpty, !(p as NSString).isAbsolutePath {
            cfg[key] = (anchor as NSString).appendingPathComponent(p)
        }
    }
    // `deps` is a path LIST (whitespace/colon/comma-separated, like CANDOR_DEPS) — anchor each
    // relative token to the config's home dir (the dir containing `.candor/`), same rule as `policy`.
    // Rejoined with spaces (the canonical separator); the loader re-splits identically.
    if let d = cfg["deps"], !d.isEmpty {
        cfg["deps"] = d.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "," })
            .map { tok -> String in
                let t = String(tok)
                return (t as NSString).isAbsolutePath ? t : (anchor as NSString).appendingPathComponent(t)
            }
            .joined(separator: " ")
    }
    return cfg
}

// ── ⟨0.27⟩ SPEC §3.4 `engine` — THE ENGINE↔BASELINE COUPLING ─────────────────────────────────────
// The committed baseline is a snapshot of what ONE engine build reported, and an engine swap is
// baseline-invalidating. What a PIN adds over the provenance checks already in place is that it is
// DECLARATIVE — a build id is a hash nobody can write down, so the intended version lived in CI config,
// decoupled from the baseline it is married to. It also tells tooling which engine to FETCH, and it
// reaches a run with NO baseline configured at all.
//
// TWO OF THE FIVE VERDICTS MUST NOT CHANGE THE EXIT CODE: an ABSENT pin (opt-in by construction) and an
// UNDETERMINED one, where §3.1's unanswerable-condition rule applies — disclosed, never scored,
// INCLUDING as satisfied. A mismatch is exit 2, never 1: the run is unevaluable, not violating.

enum PinVerdict { case absent, match, mismatch, malformed, undetermined }

private let enginePinImpls: Set<String> = ["java", "rust", "ts", "swift", "agents"]

/// The pin that applies to `impl`: the qualified form wins over the unqualified one. Two lines that
/// DISAGREE about the same key are kept BOTH, so the value cannot parse as a version and surfaces as
/// `.malformed` — one silently discarding the other is the failure this key exists to stop.
func enginePinFor(_ text: String?, _ implName: String) -> String? {
    guard let text else { return nil }
    var wild: String?, qual: String?
    var bad = false
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.first?.lowercased() == "engine" else { continue }
        let rest = Array(parts.dropFirst())
        func slot(_ cur: String?, _ v: String) -> String { (cur != nil && cur != v) ? "\(cur!) / \(v)" : v }
        // A KNOWN QUALIFIER DECIDES OWNERSHIP BEFORE ARITY. Checking the one-token case first made `engine swift` a WILDCARD pin whose version is the literal "swift" -> MALFORMED -> exit 2 in every engine, so one operator forgetting a version on a qualified line killed the whole family. SPEC 3.4 says the skip is whole-line 'whatever follows it' -- and nothing following it is a case of that too.
        if let head = rest.first, enginePinImpls.contains(head.lowercased()) {
            if head.lowercased() == implName {
                if rest.count == 2 { qual = slot(qual, rest[1]) } else { bad = true }
            }
            continue                     // another impl's line, whatever follows it
        }
        if rest.isEmpty { bad = true }
        else if rest.count == 1 { wild = slot(wild, rest[0]) }
        else { bad = true }
    }
    if bad { return "<unreadable>" }
    // AN UNREADABLE UNQUALIFIED LINE IS NOT HIDDEN BY A QUALIFIED PIN. `qual ?? wild` returned the quali
    // fied value, so `engine garbage` beside a good qualified line passed SILENTLY here while candor-java exit
    // ed 2 — the exact mirror of the bug just fixed in java, four engines the other way. Unreadability is a property of the LINE; precedence only decides which VERSION applies.
    if let w = wild, normalizePinVersion(w) == nil { return w }
    return qual ?? wild
}

/// A pin token → its comparable form, or nil when it is not a version at all. `latest` is MALFORMED
/// rather than a version that can never match: the difference decides whether the operator reads
/// "wrong version" or "that is not a version".
func normalizePinVersion(_ raw: String?) -> String? {
    var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3,
          parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
    return parts.count == 2 ? "\(s).0" : s
}

func pinVerdict(_ pin: String?, _ running: String) -> PinVerdict {
    guard let pin else { return .absent }
    guard let want = normalizePinVersion(pin) else { return .malformed }
    let r = running.trimmingCharacters(in: .whitespacesAndNewlines)
    if r.isEmpty || r == "unknown" { return .undetermined }
    return want == (normalizePinVersion(r) ?? r) ? .match : .mismatch
}

/// Enforce the pin for a scan of `targetPath`. Exits 2 on a mismatch or an unreadable pin.
func enforceEnginePin(targetPath: String, running: String) {
    let pin = enginePinFor(discoverConfigText(targetPath: targetPath), "swift")
    func say(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    // REFUSALS GO THROUGH `refuseGateAndExit`, NOT A BARE `exit(2)`. A bare exit left the PREVIOUS run's
    // `--gate-json` document on disk, so a CI wrapper reading the artifact instead of the exit code
    // reported a pass over a run that refused over a wrong engine version — the stale-artifact false
    // green this format exists to refuse, from the release's flagship guard. The sink is registered
    // before this point precisely so any exit-2 cause can use it; this one simply did not.
    switch pinVerdict(pin, running) {
    case .absent, .match:
        return
    case .malformed:
        refuseGateAndExit("candor-swift: .candor/config has an `engine` line that is not an engine version. "
            + "Want `engine <version>` (e.g. `engine v\(running)`) or `engine <impl> <version>` "
            + "(e.g. `engine swift v\(running)`) for a repo scanned by more than one engine. "
            + "Failing (exit 2) rather than ignoring it: a pin that cannot be read is a guard the "
            + "operator believes is on.")
    case .mismatch:
        refuseGateAndExit("candor-swift: .candor/config pins engine \(pin ?? "") but this build is "
            + "candor-swift \(running). The pin and the committed baseline move together — a newer engine "
            + "resolves more dispatch, so its report is not comparable with a baseline the pinned engine "
            + "wrote. Either run the pinned engine, or update the pin and regenerate the baseline in the "
            + "same change. Exit 2 (unevaluable), not 1 — this is not a policy violation.")
    case .undetermined:
        say("candor-swift: .candor/config pins engine \(pin ?? ""), and this build does not know its own")
        say("        release, so the pin CANNOT be checked. Disclosed, not scored — neither passed nor failed.")
    }
}
