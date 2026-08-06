// The `.candor/config` ENGINE PIN grammar: config text in, verdict out (SPEC §3.4 ⟨0.27⟩).
//
// WHY THIS IS IN CandorCore. It is pure — a config's text and this engine's version decide the answer,
// no filesystem, no process — and it sat in the EXECUTABLE target, which SwiftPM cannot
// `@testable import`. So the only thing that could exercise it was the cross-engine conformance suite:
// forty minutes to run, and one row per rule. A NO-BREAK SPACE between `engine` and its version
// defeated this grammar here and in candor-java — the line was reported as an "unknown config key",
// a FALSE disclosure, while the pin it names went silently unenforced and a MISMATCHED version passed
// at exit 0. Nothing went red anywhere, because nothing could call it.
//
// `enforceEnginePin` stays in the executable: it exits the process, which is not a property a unit test
// should have to survive.

import Foundation

public enum PinVerdict { case absent, match, mismatch, malformed, undetermined }

private let enginePinImpls: Set<String> = ["java", "rust", "ts", "swift", "agents"]

/// The pin that applies to `impl`: the qualified form wins over the unqualified one. Two lines that
/// DISAGREE about the same key are kept BOTH, so the value cannot parse as a version and surfaces as
/// `.malformed` — one silently discarding the other is the failure this key exists to stop.
public func enginePinFor(_ text: String?, _ implName: String) -> String? {
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
public func normalizePinVersion(_ raw: String?) -> String? {
    var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3,
          // ASCII DIGITS ONLY. `Character.isNumber` is Unicode-wide, so `٣.٣` (Arabic-Indic) and `².0`
          // (a superscript) NORMALISED as versions — which made them a MISMATCH rather than MALFORMED,
          // and that difference is load-bearing: the "an unreadable unqualified line is not hidden by a
          // qualified pin" guard below keys on `normalizePinVersion(w) == nil`, so a line that is not a
          // version but parses as one was silently handed over to the qualified pin and the run passed
          // at exit 0. A version is ASCII digits; `isNumber` also admits `½`.
          parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
    return parts.count == 2 ? "\(s).0" : s
}

public func pinVerdict(_ pin: String?, _ running: String) -> PinVerdict {
    guard let pin else { return .absent }
    guard let want = normalizePinVersion(pin) else { return .malformed }
    let r = running.trimmingCharacters(in: .whitespacesAndNewlines)
    if r.isEmpty || r == "unknown" { return .undetermined }
    return want == (normalizePinVersion(r) ?? r) ? .match : .mismatch
}
