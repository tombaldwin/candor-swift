// The Xcode BUILD-SETTINGS evaluator: which `INFOPLIST_KEY_*UsageDescription` keys a project declares.
//
// WHY THIS IS IN CandorCore. It lived in the executable target, which SwiftPM cannot
// `@testable import`, so across three rewrites and fourteen confirmed cardinal-sin flips it never had
// a single unit test — every regression was found by a human reading it, and the fixture that proves
// one flip closed cannot show the next. Untestable-by-construction was the real defect; the parser
// below is the other half of the fix.

import Foundation

/// ── THE BUILD-SETTINGS EVALUATOR ────────────────────────────────────────────────────────────────
///
/// What it answers: *does this key hold a real, non-empty value in the configuration that SHIPS?*
///
/// It has been rewritten three times and every rewrite was flipped into the cardinal sin — a key
/// counted DECLARED when the shipped build has none, which is the one answer that gets an app
/// rejected after candor said clean. Fourteen distinct flips across those rounds, and they all had one
/// root: the reader was a SUBSTRING SCAN pretending to be a parser. It asked "does this text appear on
/// this line" when the question is "what does this assignment evaluate to". Patching the substring scan
/// case by case is what produced fourteen of them; two formats (pbxproj and xcconfig) with quoting,
/// comments, per-statement `;` separators and conditional names cannot be read that way.
///
/// So this is a small real evaluator: normalise, strip comments with quote awareness, split into
/// STATEMENTS, and parse each as `NAME[cond][cond] = VALUE` with quote and bracket depth tracked. The
/// flips it exists to close, each recorded because each is a way somebody actually writes a project:
///
///   shellScript = "echo INFOPLIST_KEY_NSCameraUsageDescription = present";
///                                  a key name inside a QUOTED VALUE of an unrelated setting declared
///                                  the key. The name is now only read from the LEFT of an assignment.
///   CAM = ""; MIC = "Record audio";
///                                  two settings on one line: the empty CAM was read as declared (its
///                                  "value" ran to end of line) and the genuine MIC was never seen —
///                                  both honesty halves broken by one line. Statements now split on `;`.
///   "KEY[config=Debug][sdk=*]" = "";
///                                  only the FIRST `]` was skipped, so the value was `*] = ""` —
///                                  non-empty, declared. Bracket groups are now skipped as a group, and
///                                  the whole-name-quoted spelling (which is what Xcode writes) parses.
///   HEADER_SEARCH_PATHS = "$(SRCROOT)/Vendor/**";
///                                  the `/*` inside that PATH opened a block comment that swallowed a
///                                  later `KEY = ""` undeclare. Block stripping is now quote-aware.
///   /* #include "keys.xcconfig" */ includes were extracted from RAW text, so a commented-out include
///                                  was still followed and its keys counted.
///   Release: KEY = "";  Debug: KEY = "real"
///                                  last-assignment-wins made the answer depend on serialisation order,
///                                  and an App Store archive is RELEASE. See the consistency rule below.
///
/// THE CONSISTENCY RULE, which replaces last-wins. A key counts as declared only if EVERY assignment to
/// it — across configurations, across files — has a real value. If some assignment leaves it empty, the
/// engine cannot tell which configuration ships without the build graph, and the App Store one is the
/// strict case. Rather than guess, it reports the key as NOT declared and DISCLOSES that it was declared
/// inconsistently, which is both the safe direction and a genuine finding about the project. Modelling
/// `Debug`/`Release` by name would be the guess this rule exists to avoid.

/// One assignment as it appears in a build-settings file.
public struct BuildSettingAssignment {
    public let name: String
    public let value: String
    /// True when the value cannot be shown to be non-empty at build time: empty, or nothing but build
    /// variable references. `$(inherited)` with nothing to inherit resolves to EMPTY, which is exactly
    /// the case the first empty-value guard was written for and was defeated by seven characters.
    public var isEffectivelyEmpty: Bool {
        let stripped = value
            .replacingOccurrences(of: "\\$\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\$\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\$[A-Za-z_][A-Za-z0-9_]*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty
    }
}

/// Walk `chars`, tracking whether we are inside a double-quoted string. `\"` does not close one.
private func quoteAwareScan(_ chars: [Character], _ body: (Int, Character, Bool) -> Bool) {
    var inQuotes = false, i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\\", inQuotes, i + 1 < chars.count { i += 2; continue }   // an escape, whatever follows
        if c == "\"" { inQuotes.toggle(); if !body(i, c, inQuotes) { return }; i += 1; continue }
        if !body(i, c, inQuotes) { return }
        i += 1
    }
}

/// Remove every comment, preserving string literals, in ONE pass.
///
/// THIS IS ONE FUNCTION BECAUSE THREE WERE A DEFECT. The previous shape ran three scans — block
/// comments over the RAW text with whole-file quote tracking, then line comments PER LINE with a fresh
/// quote state each time, then statement splitting with whole-file tracking again — and any disagreement
/// between them desynchronised everything after it. Measured (flip #15):
///
///     // the "shared config          <- one stray quote, inside a LINE comment
///     /*
///     INFOPLIST_KEY_NSCameraUsageDescription = "For photos"
///     */
///
/// The block-comment pass had not yet removed the line comment, so its lone `"` opened a string, the
/// `/* … */` that followed was read as string content and never stripped, and a COMMENTED-OUT key was
/// reported as DECLARED — verified end to end through the shipped binary as "every MODELLED capability
/// is declared", exit 0, on an app whose plist has none. That is the flip this file's own docstring
/// already records as closed, back through a different door. The mirror reproduced too:
/// `// see the note /* about camera` lost every declaration in the rest of the file.
///
/// A single state machine cannot desynchronise with itself. It also handles multi-line string literals
/// for free — legal in an OpenStep plist, and previously able to swallow a later undeclare.
///
/// `#include` is a DIRECTIVE, not a comment, and survives. `#` is otherwise treated as a comment in both
/// formats even though only `//` formally is, and deliberately: a `# INFOPLIST_KEY_X = "y"` someone
/// wrote to disable a key must NOT read as a declaration. The cost is a false MISSING on an unquoted `#`
/// in a value, which is the safe direction.
public func stripCommentsPreservingStrings(_ raw: String) -> String {
    let chars = Array(raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    var out = ""
    var i = 0, inString = false
    while i < chars.count {
        let c = chars[i]
        if inString {
            if c == "\\", i + 1 < chars.count { out.append(c); out.append(chars[i + 1]); i += 2; continue }
            if c == "\"" { inString = false }
            out.append(c); i += 1; continue
        }
        if c == "\"" { inString = true; out.append(c); i += 1; continue }
        if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
            var j = i + 2
            while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
            i = (j + 1 < chars.count) ? j + 2 : chars.count      // unclosed: rest of file is comment
            continue
        }
        if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
            while i < chars.count, chars[i] != "\n" { i += 1 }
            continue
        }
        if c == "#" {
            if String(chars[i...]).hasPrefix("#include") {
                while i < chars.count, chars[i] != "\n" { out.append(chars[i]); i += 1 }
                continue
            }
            while i < chars.count, chars[i] != "\n" { i += 1 }
            continue
        }
        out.append(c); i += 1
    }
    return out
}

/// Split a build-settings file into STATEMENTS: `;`, a newline, `{` or `}` outside a string ends one.
///
/// This is what makes `CAM = ""; MIC = "Record audio";` two assignments instead of one whose value ran
/// to the end of the line — which had counted the empty key as declared AND lost the real one. Comments
/// are already gone by the time this runs, so its string tracking is the only state in play.
public func buildSettingStatements(_ raw: String) -> [String] {
    let chars = Array(stripCommentsPreservingStrings(raw))
    var out: [String] = [], cur = ""
    var inString = false, i = 0
    while i < chars.count {
        let c = chars[i]
        if inString {
            if c == "\\", i + 1 < chars.count { cur.append(c); cur.append(chars[i + 1]); i += 2; continue }
            if c == "\"" { inString = false }
            cur.append(c); i += 1; continue
        }
        if c == "\"" { inString = true; cur.append(c); i += 1; continue }
        if c == ";" || c == "\n" || c == "{" || c == "}" { out.append(cur); cur = ""; i += 1; continue }
        cur.append(c); i += 1
    }
    out.append(cur)
    return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Strip one layer of surrounding double quotes, honouring `\"` escapes inside.
private func unquoted(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return t }
    let inner = String(t.dropFirst().dropLast())
    return inner.replacingOccurrences(of: "\\\"", with: "\"")
}

/// Parse `NAME[cond][cond] = VALUE`, or nil when the statement is not a usage-description assignment.
///
/// The split is at the first `=` that is outside BOTH quotes and brackets. Xcode writes a conditional
/// setting with the whole name quoted — `"INFOPLIST_KEY_X[sdk=*]" = "…"` — and also accepts it bare, so
/// both spellings have to parse; taking the first `=` outright put the condition's own `=` inside the
/// value, which made an EMPTY declaration look non-empty.
public func parseUsageAssignment(_ statement: String) -> BuildSettingAssignment? {
    let chars = Array(statement)
    var eq: Int? = nil, depth = 0
    quoteAwareScan(chars) { i, c, inQuotes in
        guard !inQuotes else { return true }
        if c == "[" { depth += 1 }
        else if c == "]" { depth = max(0, depth - 1) }
        else if c == "=", depth == 0 { eq = i; return false }
        return true
    }
    guard let eq else { return nil }
    var name = unquoted(String(chars[0..<eq]))
    if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
    name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.hasPrefix("INFOPLIST_KEY_"), name.hasSuffix("UsageDescription") else { return nil }
    // Return the INFO.PLIST key, not the build-setting name: the caller unions this with the keys read
    // from the plist itself, so the `INFOPLIST_KEY_` prefix must come off or nothing ever matches and
    // every genuine build-settings declaration reads as MISSING. (The rewrite of this evaluator dropped
    // the strip and a negative control against the previous version caught it — a fabrication fix
    // introducing the miss, which is the failure mode this reader has produced at every round.)
    name = String(name.dropFirst("INFOPLIST_KEY_".count))
    let value = unquoted(String(chars[(eq + 1)...]))
    return BuildSettingAssignment(name: name, value: value)
}

/// Every usage-description assignment a build-settings file makes, in order.
public func usageAssignmentsInBuildSettings(_ raw: String) -> [BuildSettingAssignment] {
    buildSettingStatements(raw).compactMap(parseUsageAssignment)
}

/// The keys a build-settings file DECLARES with a real value — see the consistency rule above.
public func usageKeysInBuildSettings(_ raw: String) -> Set<String> {
    declaredKeys(from: usageAssignmentsInBuildSettings(raw)).declared
}

/// Apply the consistency rule to a set of assignments gathered from one file or many.
public func declaredKeys(from assignments: [BuildSettingAssignment])
    -> (declared: Set<String>, inconsistent: Set<String>) {
    var real: Set<String> = [], empty: Set<String> = []
    for a in assignments {
        if a.isEffectivelyEmpty { empty.insert(a.name) } else { real.insert(a.name) }
    }
    return (real.subtracting(empty), real.intersection(empty))
}

