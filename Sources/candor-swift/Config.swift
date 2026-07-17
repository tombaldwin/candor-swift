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
let candorConfigKeys: Set<String> = ["policy", "baseline", "strict", "no-ambient", "closed-world", "taint", "deps", "unknown-alias", "unknown-ratchet"]

// ⟨0.19⟩ Discover `.candor/config` TEXT anchored at `targetPath`: $CANDOR_CONFIG if set + readable, else the
// nearest `.candor/config` walking UP, else nil. Read-only + LENIENT (no exit — the caller decides
// fail-closed); used to resolve reason-class `unknown-alias` for the §6.2 gate + `parsepolicy`.
func discoverConfigText(targetPath: String) -> String? {
    if let override = ProcessInfo.processInfo.environment["CANDOR_CONFIG"] {
        return try? String(contentsOfFile: override, encoding: .utf8)
    }
    var dir = (URL(fileURLWithPath: targetPath).standardizedFileURL.path as NSString).standardizingPath
    var isDir: ObjCBool = false
    if !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) {
        dir = (dir as NSString).deletingLastPathComponent
    }
    for _ in 0..<64 {
        let cand = (dir as NSString).appendingPathComponent(".candor/config")
        if FileManager.default.fileExists(atPath: cand) { return try? String(contentsOfFile: cand, encoding: .utf8) }
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
            FileHandle.standardError.write("candor-swift: CANDOR_CONFIG set but \(override) is not a readable file — failing (exit 2)\n".data(using: .utf8)!)
            exit(2)
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
        FileHandle.standardError.write("candor-swift: config \(file!) exists but could not be read — failing (exit 2)\n".data(using: .utf8)!)
        exit(2)
    }
    // Name the config that governs this scan — an ancestor-walk discovery is otherwise invisible, and a
    // surprising gate verdict ("where did that policy come from?") needs the provenance on stderr.
    FileHandle.standardError.write("candor-swift: using config \(file!)\n".data(using: .utf8)!)
    var cfg: [String: String] = [:]
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let key = parts[0].lowercased()
        let val = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        if !candorConfigKeys.contains(key) {
            FileHandle.standardError.write("candor-swift: ignoring unknown config key '\(key)' in \(file!)\n".data(using: .utf8)!)
            continue
        }
        if key == "unknown-alias" { continue }  // ⟨0.19⟩ MULTI-VALUE — extracted via parseUnknownAliases
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
        cfg["deps"] = d.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" || $0 == "," })
            .map { tok -> String in
                let t = String(tok)
                return (t as NSString).isAbsolutePath ? t : (anchor as NSString).appendingPathComponent(t)
            }
            .joined(separator: " ")
    }
    return cfg
}
