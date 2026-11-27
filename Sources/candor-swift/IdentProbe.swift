import Foundation
import CandorCore

// SOUNDNESS R1938 (type-identity lanes L0/L1) — the TYPE-IDENTITY PROBE. An env-gated trace of every place the engine records or
// re-resolves a type NAME for a receiver, written to STDERR one tab-separated record per line:
//
//   IDT file  module  package     a file's manifest target (SwiftPM) — or `xcode` records' module list
//   IDD file  swiftModuleOf  declared-paths  local-paths  imports  aliases  generic-params     one per file
//   IDG / IDF / IDL / IDR / IDS    binder records: globals, fields, locals, scoped returns, simple returns
//   IDU file  enclosing-path  spelled  answer  local?    every `canonicalTypeRef` answer at a USE site
//   IDM / IDX / IDMS               L1: the module-identity comparison (ModuleIdentityProbe.swift)
//
// `tools/ident_census.py` and `tools/kappa_shadow.py` read these. OFF BY DEFAULT: with `CANDOR_IDENT_PROBE` unset the guard below
// returns before the record's text is built (the argument is an autoclosure), nothing is written, and no report byte changes —
// the final tier compares reports with the probe ON against reports with it OFF and requires them byte-equal (only stderr differs).
//
// It is a measurement instrument, not a switch: it never feeds a decision, so it is not in `switches` and cannot move a result.
let identProbeOn = Env.trace("CANDOR_IDENT_PROBE")   // a TRACE, not a switch: Env.swift is the one place the environment is read
final class IdentProbeSink: @unchecked Sendable {
    let lock = NSLock(); var seen = Set<String>()
    static let shared = IdentProbeSink()
}
func identProbe(_ line: @autoclosure () -> String) {
    guard identProbeOn else { return }
    let l = line(); let s = IdentProbeSink.shared
    s.lock.lock(); defer { s.lock.unlock() }
    if s.seen.insert(l).inserted { FileHandle.standardError.write((l + "\n").data(using: .utf8)!) }
}
