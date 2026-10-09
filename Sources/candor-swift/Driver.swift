// candor-swift — the two-pass drive: collect declarations, collect calls, resolve, fixpoint.
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax
import CandorCore

// Swift/Apple compiler-recognized CAPITALIZED declaration attributes that inject NO hidden behaviour —
// they are compile-time enforcement/wiring markers the compiler checks against source that is already
// fully visible, never a synthesized member, body, or call. Carved out of the attached-macro disclosure
// below on the denylist-over-allowlist rule (candor-spec: narrow a sound over-approximation by proving a
// name SAFE, never by trusting an unproven one) — the over-approximation is "any unexplained capitalized
// decl-attribute might be an attached macro"; only a name on this list, or a locally-declared
// `@resultBuilder`/`@globalActor` type (handled separately, see their own tables), is exempted.
/// SOUNDNESS R867 §1b KILL SWITCH (the in-scan twin; main.swift reads the same variable for the producer).
private let driverR867Off = ProcessInfo.processInfo.environment["CANDOR_R867_OFF"] != nil
/// VEIN C §1b KILL SWITCH (R903, R876).
private let veinCOff = ProcessInfo.processInfo.environment["CANDOR_VEINC_OFF"] != nil
/// VEIN C REACH PROBE (§E1): one stderr line per down-walk edge actually added.
private let veinCProbe = ProcessInfo.processInfo.environment["CANDOR_VEINC_PROBE"] != nil
private let KNOWN_BUILTIN_DECL_ATTRS: Set<String> = [
    "MainActor", "UIApplicationMain", "NSApplicationMain",
    "IBAction", "IBSegueAction", "IBOutlet", "IBInspectable", "IBDesignable",
    "NSManaged", "NSCopying", "GKInspectable",
]

/// Everything the report/ledger/gate stages need from the analysis — returned as one value so the
/// two-pass drive is a callable unit (it was ~500 lines of top-level statements in main.swift).
struct Analysis {
    var allFns: [FnInfo]
    var conformers: [String: [String]]
    /// ⟨0.26⟩ Types with a REAL local definition (see DeclCollector's note). The §2.2 hierarchy sidecar
    /// keys on this so its KEY SET is a manifest of what the pass indexed — `conformers` alone gives a key
    /// only to types that HAVE a supertype, which leaves a supertypeless one indistinguishable from one
    /// that was never analysed. Deliberately NOT `localTypes`: that also holds extension-only platform
    /// types, whose supertypes this pass cannot see, so an empty list for them would be a false claim.
    var declaredTypes: Set<String>
    /// ⟨0.26⟩ `protocol Sub: Sup` edges, and (via `protocolNames`) the set of protocols this pass indexed.
    /// The hierarchy sidecar needs BOTH: a protocol is a supertype a concrete type's chain runs THROUGH, so
    /// without these edges every `Impl: Mid` / `Mid: Base` chain dead-ends at `Mid` and the whole relation
    /// is unanswerable. Kept out of `conformers` on purpose (a protocol name there pollutes concrete
    /// dispatch CHA and its `impls.count == conf.count` guard) — the SIDECAR is a separate output, so
    /// writing them there cannot reach CHA.
    var protocolSupers: [String: Set<String>]
    var protocolNames: Set<String>
    /// SOUNDNESS R867 — local protocol -> its REQUIREMENTS (the members a call on an existential or a bound
    /// DISPATCHES on). The producer's union entry is published beside a real `P.m` only for these: an
    /// extension-only member is dispatched statically to the extension body, so a conformer's same-named
    /// method never runs through `p.m()` and unioning it would charge an effect no execution performs.
    var protocolMethods: [String: Set<String>]
    var importCounts: [String: Int]
    /// module -> how many analyzed FILES import it while their own package cannot. The κ ledger, computed
    /// where the per-file answer lives rather than reconstructed from a scan-global set that could not
    /// express it. See the derivation in `analyze`.
    var uncoveredCounts: [String: Int]
    /// module -> files importing it whose target does not name it, though a chained report covers it.
    var coverageNotDeclared: [String: Set<String>]
    var direct: [String: Set<String>]
    var edges: [String: Set<String>]
    var whyMap: [String: Set<String>]
    var locOf: [String: String]
    var entryPoints: Set<String>
    var inferred: [String: Set<String>]
    var hostsAcc: [String: Set<String>]
    var fsD: [String: Set<String>]
    var privKindD: [String: [String: Set<String>]]
    var cmdsAcc: [String: Set<String>]
    var pathsAcc: [String: Set<String>]
    var tablesAcc: [String: Set<String>]
    var incompleteAcc: [String: Set<String>]
    /// The UNPROPAGATED incompleteness — a function's OWN surface whose locator could not be determined.
    /// `incompleteAcc` is the transitive view, which is right for the gate and WRONG for a per-function
    /// disclosure: propagation means a caller inherits its callees' incompleteness and, symmetrically, a
    /// determined callee masks nothing. The privacy verify needs "did THIS function's own file write name
    /// its destination", which only the direct map can answer.
    var incompleteDirect: [String: Set<String>]
    var invisibleAcc: [String: Set<String>]
    /// ⟨0.39⟩ SPEC §4 obligation 1 — fn -> the abstraction MEMBERS it dispatches on, transitively, in wire
    /// form. Its presence makes an otherwise-PURE row EMIT (the deliberate exception to §2 rule 3).
    var dispatchAcc: [String: Set<String>]
    /// ⟨0.39⟩ SPEC §4 obligation 2 — every abstraction this package implements, mapped to the package that
    /// OWNS it: this one for a locally-declared protocol or superclass, the DEPENDENCY for a foreign one.
    /// A name absent from this map is one whose owner could not be decided; its union entry is not
    /// published at all, because a key keyed under the wrong package is worse than an absent one.
    var abstractionOwnerPkg: [String: String]
    /// VEIN D — an abstraction whose owner is proven to be ONE OF these packages but not which.
    var abstractionUndecidedPkgs: [String: Set<String>] = [:]
    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): the TARGET's own .swift source candor could NOT read/parse —
    // a file whose `String(contentsOfFile:)` returned nil (unreadable: EACCES, invalid UTF-8, gone).
    // (SwiftSyntax's Parser.parse is error-TOLERANT — always returns a tree, never throws — so the
    // practical swift "unanalyzed" case is an unreadable file, not a parse failure.) Its effects are
    // absent NOT because pure but because never seen; carried into the report + gate verdict so a gate
    // over skipped source fails closed, never green. (path, reason), in discovery order.
    var unanalyzed: [(path: String, reason: String)]
    /// ⟨0.23⟩ `typeSurface.returns` (SPEC §2, `DEP-RECEIVER-TYPING-DESIGN.md`): fn qual -> the FULLY
    /// QUALIFIED type a binding bound from that fn HOLDS. Both ends are qualified in this package's own
    /// namespace, so main.swift prefixes each with `<pkg>#` — the same namespace the entry hashes use.
    /// The point of the rung: a PURE factory is absent from `functions` entirely (§2 rule 3), so its
    /// return type can never be recovered from the entries, and every later method call on the binding
    /// drops. Empty when there is nothing to say, and the field is then omitted so the report stays
    /// byte-identical to a pre-rung one.
    var typeSurfaceReturns: [String: String]
    /// ⟨0.40⟩ `typeSurface.holds` / `returnsProtocol` / `types` / `adds`, already `<pkg>#`-qualified.
    var typeSurface040 = TypeSurfaceOut()
}

/// ⟨0.23⟩ THE `typeSurface.returns` PRODUCER (SPEC §2, `DEP-RECEIVER-TYPING-DESIGN.md`).
///
/// `let c = build(); c.fetch()` types `c` from `build`'s RETURN type, and a PURE `build` is absent from
/// the dependency's report entirely (§2 rule 3) — so no consumer can recover it from the entries, and
/// every later method call on `c` drops. This publishes it.
///
/// QUALIFICATION IS THE WHOLE RULE, and it is the defect rust shipped and reverted. A leaf-keyed surface
/// makes `Sync.Client` and `Mock.Client` one string, and a PURE `mockClient()` then charges the real
/// client's effects to a caller that cannot reach them. So the written spelling is resolved against the
/// DECLARING type path, outward exactly as Swift's own lookup runs, and the result must match a declared
/// type path EXACTLY — never a leaf, never a suffix. A name that resolves to nothing (an imported type,
/// a stdlib type, a generic parameter) publishes NOTHING: it names no unit in this report, so a consumer
/// keying through it could only miss, and a miss it cannot explain is worse than an absent entry.
///
/// A fn qual that several functions share (a same-name overload set, whose members may return different
/// types) publishes nothing either — the never-guess rule the whole dep index runs on.
/// SOUNDNESS R1048 residual — argument position for each parameter index, aligning a call's argument LABELS to a
/// declaration's external labels in order (`_` = unlabelled); a defaulted parameter may be skipped, a variadic is
/// never mapped, and parameters left over after the last parenthesised argument may be trailing closures. `nil`
/// when the labels cannot fit this declaration.
func alignWitnessArgs(_ labels: [String?], _ params: [String],
                      _ sig: [(type: String?, hasDefault: Bool, variadic: Bool)]) -> [Int: Int]? {
    var map: [Int: Int] = [:], a = 0
    for (i, pl) in params.enumerated() {
        let want: String? = pl == "_" ? nil : pl
        let variadic = i < sig.count && sig[i].variadic
        if a < labels.count, labels[a] == want {
            if variadic { a += 1; while a < labels.count, labels[a] == nil { a += 1 } } else { map[i] = a; a += 1 }
            continue
        }
        if i < sig.count, sig[i].hasDefault || variadic { continue }
        if a == labels.count { break }
        return nil
    }
    return a == labels.count ? map : nil
}

func buildTypeSurfaceReturns(_ allFns: [FnInfo], _ localTypePaths: Set<String>) -> [String: String] {
    var byQualCount: [String: Int] = [:]
    for f in allFns { byQualCount[f.qual, default: 0] += 1 }

    /// Resolve a written type spelling against the scope it was written in. `Client` inside
    /// `enum Sync { … }` is `Sync.Client`; inside `Sync.Inner` it is `Sync.Inner.Client`, else
    /// `Sync.Client`, else the top-level `Client` — the outward walk, stopping at the first EXACT hit.
    func resolveTypePath(_ written: String, scope: String?) -> String? {
        var segs = scope.map { $0.split(separator: ".").map(String.init) } ?? []
        while !segs.isEmpty {
            let cand = segs.joined(separator: ".") + "." + written
            if localTypePaths.contains(cand) { return cand }
            segs.removeLast()
        }
        return localTypePaths.contains(written) ? written : nil
    }
    // THE EXACTNESS OF THAT LAST LINE IS LOAD-BEARING, and it became PROVABLE only once the dep index
    // grew its third key shape (`pkg#<full qual>`, this repo's `9a51e7f`, candor-rust's `5feba18`).
    // Before that, relaxing it to a suffix match (`first { $0.hasSuffix(".\(written)") }`) failed NO
    // test and changed NO corpus output: a suffix match can only return a path of TWO OR MORE segments,
    // the consumer then forms a THREE-segment key, and an index carrying only `pkg#leaf`/`pkg#tail2`
    // misses it — a wrong answer with nowhere to land. An untestable guard is a hope, not a guard, so
    // it was written here as an open question rather than a claim.
    //
    // It is a claim now, and the fixture was written WITH the key: `openForeign() -> Progress` names
    // Foundation's type, which this package does not declare, and a suffix match answers `Mock.Progress`
    // instead — whose `pause` is effectful, so the guess LANDS on the third key and charges Env to a
    // caller holding a Foundation object. `testAForeignReturnSpellingPublishesNothingRatherThanSuffix-
    // Matching` fails under exactly that mutation and its sibling row asserts the other direction: a
    // spelling that resolves EXACTLY must still publish its full path.
    //
    // MEASURED, because "the key is what makes it matter" is itself checkable: with the third key
    // mutated back OUT and the suffix mutant left IN, the CONSUMER rows go green again —
    // `viaForeignFactory` misses and discloses, harmlessly. Only the producer-side "publishes nothing"
    // row still fails. So what the key changed is not that a wrong answer can be OBSERVED; it is that a
    // wrong answer now LANDS.

    var out: [String: String] = [:]
    for f in allFns {
        guard let written = f.retBoundTypeSpelling, byQualCount[f.qual] == 1,
              let resolved = resolveTypePath(written, scope: f.enclosingTypePath) else { continue }
        out[f.qual] = resolved
    }
    if ProcessInfo.processInfo.environment["CANDOR_TYPESURFACE_DEBUG"] != nil {
        let spelled = allFns.filter { $0.retBoundTypeSpelling != nil }.count
        let ambiguous = allFns.filter { $0.retBoundTypeSpelling != nil && byQualCount[$0.qual]! > 1 }.count
        let line = "TYPESURFACE producer: fns=\(allFns.count) plain-nominal-returns=\(spelled) "
            + "ambiguous-qual=\(ambiguous) type-paths=\(localTypePaths.count) published=\(out.count)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
    return out
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Drive the two passes
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// Std types that appear in an inheritance clause as a RAW VALUE, not a conformance: `enum Suit: String`
/// makes `String` look like a supertype of `Suit`. Dispatching over the "conformers" of one of these
/// would send every call on a String/Int-typed receiver into raw-value enums' methods — a fabrication,
/// so they are carved out of the imported-supertype CHA below.
let RAW_VALUE_BASE_TYPES: Set<String> = [
    "String", "Character", "Bool", "Double", "Float", "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
]

/// The bare `Sources`/`Tests`-segment heuristic, taking a PATH ALREADY STRIPPED of its `:line:col`
/// suffix and already relative to whatever root it is being read against. Factored out so both the
/// plain top-level `swiftModuleOf` below and `analyze`'s nested-package-aware shadow of it (see
/// `nestedManifestDirs` there) share the exact one-segment rule rather than drifting apart.
func swiftModuleSegment(_ filePath: String) -> String {
    let parts = filePath.split(separator: "/").map(String.init)
    for (i, seg) in parts.enumerated() where seg == "Sources" || seg == "Tests" {
        if i + 1 < parts.count { return parts[i + 1] }
    }
    return ""
}

/// The Swift MODULE (SwiftPM target) a source path belongs to — `Sources/<Target>/…` / `Tests/<Target>/…`,
/// one module per target. Empty for anything outside that layout.
///
/// PLAIN top-level form: no knowledge of nested manifests, so a vendored SwiftPM package physically
/// nested inside another target's `Sources/` tree (its own `Package.swift` sitting several segments
/// below the enclosing target's) resolves to the FIRST `Sources`/`Tests` segment found — the OUTER
/// target's name, colliding with the outer target's own module. `analyze` shadows this with a
/// manifest-boundary-aware version (see `nestedManifestDirs` below) for every call site it makes
/// internally; this plain form remains for anything outside that scope (currently nothing — kept as
/// the fallback definition and the thing the shadow delegates to past its last boundary).
/// SOUNDNESS R267 — IS THIS CALL LEAF AN OPERATOR? A DENYLIST, NOT AN ALLOWLIST.
///
/// `memberFirst` (below, in the unqualified-call chain) has to exclude operators, because Swift resolves
/// an operator by overload resolution over the OPERAND TYPES rather than by lexical scope. It used to ask
/// the opposite question — *"does the leaf START WITH A LETTER OR `_`?"* — and treated everything else as
/// an operator. That is an ALLOWLIST over a set nobody enumerated, and it fails in the direction that
/// hides itself: **SwiftSyntax hands back a backtick-escaped or raw identifier WITH its backticks**, so
/// `` `default` `` and Swift 5.9's `` `w 288` `` both begin with a backtick, were classified as operators,
/// and the three member arms were skipped onto the pre-R255 free-first path.
///
/// MEASURED over a generated 1152-cell matrix (visibility x file/module placement x call site x nesting x
/// identifier spelling x inheritance depth x overloading x effect polarity), every cell compiled and RUN:
/// **232 cells red — the member is what executes and candor charged the global instead** — and 152 more
/// where the same misclassification happened to give the right answer only because the member was
/// invisible at the call site anyway (R265), i.e. right for the wrong reason. It runs in BOTH directions:
/// with an effectful member it is a silent under-report; with a PURE member (116 of the 232) it is a pure
/// OVER-CHARGE, the caller charged `Fs` over a program that provably deletes nothing.
///
/// The fix is to ask the question the language actually defines. A backticked leaf is an IDENTIFIER by
/// construction — Swift spells a keyword or a raw identifier with backticks and never spells an operator
/// that way — and anything else is an operator only if its first character is an `operator-head` from the
/// Swift grammar. Enumerating the OPERATOR set (a denylist) rather than the identifier set means a
/// spelling nobody thought of lands on the member-first path, which is where R255 says it belongs; the old
/// allowlist sent every unforeseen spelling to the free arm instead.
func swiftLeafIsOperator(_ leaf: String) -> Bool {
    // Backticked: an identifier, full stop (`default`, `w 288`, any Swift 5.9 raw identifier).
    if leaf.hasPrefix("`") { return false }
    guard let c = leaf.unicodeScalars.first else { return false }
    // `operator-head` from the Swift language grammar (Lexical Structure -> Operators).
    if "/=-+!*%<>&|^~?".unicodeScalars.contains(c) { return true }
    for r in SWIFT_OPERATOR_HEAD_SCALARS where r.contains(c.value) { return true }
    return false
}

/// The non-ASCII `operator-head` ranges, transcribed from the Swift grammar. Kept beside the function
/// that reads them so the two cannot drift.
let SWIFT_OPERATOR_HEAD_SCALARS: [ClosedRange<UInt32>] = [
    0x00A1...0x00A7, 0x00A9...0x00A9, 0x00AB...0x00AB, 0x00AC...0x00AC, 0x00AE...0x00AE,
    0x00B0...0x00B1, 0x00B6...0x00B6, 0x00BB...0x00BB, 0x00BF...0x00BF, 0x00D7...0x00D7,
    0x00F7...0x00F7, 0x2016...0x2017, 0x2020...0x2027, 0x2030...0x203E, 0x2041...0x2053,
    0x2055...0x205E, 0x2190...0x23FF, 0x2500...0x2775, 0x2794...0x2BFF, 0x2E00...0x2E7F,
    0x3001...0x3003, 0x3008...0x3020, 0x3030...0x3030,
]

/// SOUNDNESS R832 — the producer's spelling of a fn qual whose LEAF it declared with backticks
/// (`static func \`default\`()` is published as `Client.\`default\``), from the call site's spelling,
/// which never carries them. nil when the leaf already has them.
func backtickedLeafKey(_ qual: String) -> String? {
    var segs = qual.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard let leaf = segs.last, !leaf.isEmpty, !leaf.hasPrefix("`") else { return nil }
    segs[segs.count - 1] = "`\(leaf)`"
    return segs.joined(separator: ".")
}

func swiftModuleOf(_ loc: String) -> String {
    let filePath = loc.split(separator: ":").first.map(String.init) ?? loc
    return swiftModuleSegment(filePath)
}

func analyze(sourcePaths: [String], rootDir: String, pkgName: String, deps: DepIndex = DepIndex(),
             xcodeLinksByFile: [String: [LocalProductRef]] = [:],
             xcodeModulesByFile: [String: [String]] = [:],
             nestedManifestDirs: [String] = []) -> Analysis {
    // R73/R74 FOLLOW-ON — a target that vendors a nested SwiftPM package (its own `Package.swift`
    // physically inside the enclosing target's `Sources/<Name>/` tree, e.g. `Sources/outer2/Vendor/
    // NestedPkg/Sources/NestedTarget/main.swift`) broke the plain `swiftModuleOf` heuristic above: it
    // takes the FIRST `Sources`/`Tests` segment it finds, so BOTH `Sources/outer2/main.swift` and the
    // vendored `.../Vendor/NestedPkg/Sources/NestedTarget/main.swift` resolved to the SAME module name
    // ("outer2") — a genuine collision, not a mere duplicate label: R74's `<main>` disambiguation keys
    // off exactly this string, so a pure target's `<main>` inherited the vendored package's `Env` read.
    // MEASURED: reproduces even after R74 (R74 disambiguates BY module name; it cannot help when two
    // DIFFERENT targets compute the SAME name).
    //
    // FIX: `nestedManifestDirs` is every directory (relative to the scan root, `/`-separated, the outer
    // scan's own root manifest EXCLUDED) that main.swift's walk found a `Package.swift` in — i.e. every
    // NESTED manifest, gathered from signal the walk already collects (the `excluded[].class ==
    // "manifest"` entries), not a second filesystem pass ("ask the authority", corpus brief rule G: the
    // nested Package.swift IS the authoritative boundary marker SwiftPM itself would use to know this is
    // a separate package root — reading its presence is strictly more sound than guessing from path
    // shape alone). A file under the DEEPEST such directory that contains it is scoped to a MODULE KEY
    // PREFIXED by that directory, so it can never collide with a module name computed outside the
    // boundary, or with another nested package's module of the same bare name (two vendored copies of
    // the same library, say). Sorted longest-first so a doubly-nested vendor (a vendored package that
    // itself vendors another) resolves to its own innermost boundary, not an ancestor's.
    //
    // ENUMERATED, against the plain heuristic's failure modes (corpus brief, Finding 1's instruction):
    //   - first-match vs last-match ambiguity                    MOOT — boundaries come from manifests,
    //                                                             not from guessing which occurrence to
    //                                                             prefer; each boundary's OWN first match
    //                                                             is unambiguous by construction.
    //   - `Tests` nested under `Sources` (or vice versa)         SAME MECHANISM — a nested manifest under
    //                                                             either resolves relative to its own
    //                                                             boundary regardless of which literal
    //                                                             the outer segment was.
    //   - a target directory literally named `Sources`/`Tests`   UNCHANGED — still resolved by
    //                                                             `swiftModuleSegment`'s first-match
    //                                                             WITHIN a boundary, which was already
    //                                                             correct for this case (a target named
    //                                                             `Sources` has no nested manifest of its
    //                                                             own, so this never engages).
    //   - a nested package under `Tests/`                        COVERED — boundary detection does not
    //                                                             care which literal precedes it.
    //   - symlinked package roots                                NOT VERIFIED. `FileManager.enumerator`'s
    //                                                             symlink-following behaviour is untested
    //                                                             here; a symlinked nested package may
    //                                                             still collide. Disclosed, not fixed.
    //   - a path with no `Sources` segment at all                UNCHANGED — falls through to the same
    //                                                             `""` a bare heuristic already returned.
    //   - a module colliding with a directory name higher up     FIXED — the boundary prefix makes the
    //                                                             two keys unequal even when the bare
    //                                                             target names are spelled identically.
    //
    // NOT ATTEMPTED: routing this through SwiftPM's own target resolution (`swift package describe`,
    // as `--target` already does for ITS manifest parse) rather than a heuristic at all. That would
    // still not resolve THIS case soundly — a vendored copy with its own `Package.swift`, physically
    // inside another target's source tree but never declared via `.package(path:)`, is invisible to the
    // OUTER manifest's own target resolution; SwiftPM's real `swift build` over such a tree does not
    // treat it as a separate module either (confirmed: it tries to compile the vendored package's own
    // files as part of the outer target and can fail with a duplicate-producer error when both trees
    // have same-named entry points). The manifest-boundary heuristic here answers a narrower, achievable
    // question — "give genuinely different targets genuinely different keys" — without claiming to
    // reproduce what SwiftPM would actually build.
    // Sorted longest-first so a doubly-nested vendor resolves to its own innermost boundary. When this
    // is empty (the overwhelmingly common case — no vendored nested package anywhere in the scan) the
    // loop below never matches anything and every call falls straight through to `swiftModuleSegment`,
    // making this SHADOW byte-for-byte identical to the plain top-level `swiftModuleOf` it replaces for
    // every call site inside `analyze` — no behaviour change for any tree without a nested manifest.
    let sortedNestedDirs = nestedManifestDirs.sorted { $0.count > $1.count }
    // Shadows the top-level `swiftModuleOf(_:)` for every unqualified call inside `analyze` (all of
    // them — see the enumeration above for why a NAME conflict inside its own body would recurse: this
    // is a fresh definition, not a wrapper around the outer one, so it does not call it).
    func swiftModuleOf(_ loc: String) -> String {
        let filePath = loc.split(separator: ":").first.map(String.init) ?? loc
        for d in sortedNestedDirs where filePath.hasPrefix(d + "/") {
            let rel = String(filePath.dropFirst(d.count + 1))
            let inner = swiftModuleSegment(rel)
            return inner.isEmpty ? "" : "\(d)::\(inner)"
        }
        return swiftModuleSegment(filePath)
    }

    var allFns: [FnInfo] = []
    var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:]
    var fieldArrayElem: [String: [String: String]] = [:]
    /// SOUNDNESS R585 (b4/b6) — the metatype twins of `fields` / `fieldArrayElem`.
    var fieldMetatypes: [String: [String: String]] = [:]
    var fieldMetatypeArrayElem: [String: [String: String]] = [:]
    var fieldArrayElemNested: [String: [String: String]] = [:]   // R278
    var fieldDictValue: [String: [String: String]] = [:]
    var fieldTypeArgs: [String: [String: [String]]] = [:]   // SOUNDNESS R905
    var opaqueFields: [String: Set<String>] = [:]
    var caseAssocAll: [String: Set<String>] = [:]
    var caseAssocMetatypeAll: [String: Set<String>] = [:]   // R585 (b10)
    var staticFactoryFields: [(type: String, field: String, leaf: String)] = []
    // R73 — module-scope global NAME -> its concrete type, scoped by MODULE (not merged flat like `fields`)
    // because a bare global name is not guaranteed unique project-wide the way a declared TYPE name is —
    // two different modules can each declare their own `let worker = …`, and picking the wrong one to
    // dispatch a method call against would FABRICATE an effect from the wrong class, not just under-report
    // one. Module-scoping is free of that risk: within one Swift module a top-level `let`/`var` name is
    // unique by construction (a redeclaration is a compile error), so there is no in-module ambiguity to
    // adjudicate. Consulted by `CallCollector.rootOf` exactly like `fields`/`vars`, module-sliced at
    // construction time below (mirrors `localFreeFnBaseNamesByModule`'s existing per-module slicing).
    var globalTypesByModule: [String: [String: String]] = [:]
    // R79 — the SUBSET of each module's `globalTypesByModule` entry that is `public`/`open`
    // (`DeclCollector.globalPublic`). A cross-module lookup consults ONLY this table, never
    // `globalTypesByModule` directly: an internal/private global genuinely is not visible outside its
    // declaring module, and resolving it anyway would fabricate a receiver type across a boundary real
    // Swift access control forbids. Same module-scoping discipline as `globalTypesByModule` itself.
    //
    // R85 — this table is now DERIVED, once, after every pass that can populate `globalTypesByModule`
    // has run (see the derivation just after the `globalFactories` resolution loop below), rather than
    // written directly during the per-file merge. It used to be written at merge time, filtered through
    // that file's OWN `globalTypes` — which only ever held the DIRECT-annotation and DIRECT-constructor
    // shapes, because the FACTORY shape (`let x = makeX()`) resolves its type in a separate, LATER pass
    // that wrote only into `globalTypesByModule` and never revisited this table. A public factory (or
    // destructured) global was therefore typed but permanently invisible cross-module — SOUNDNESS.md
    // R85, a cardinal sin. One authority (`globalTypesByModule` for the TYPE, `globalPublicByModule`
    // just below for VISIBILITY) computed into a single filter closes the class rather than adding a
    // third write site that could drift the same way again.
    var publicGlobalTypesByModule: [String: [String: String]] = [:]
    // R85 — the NAME SET half of the derivation above: every `public`/`open` global name, module-scoped,
    // merged from each file's `DeclCollector.globalPublic` regardless of which binder shape recorded it
    // (plain identifier, direct constructor, factory call, singleton access, or — new in R85 — a
    // tuple-destructure element). `publicGlobalTypesByModule` is computed from this PLUS
    // `globalTypesByModule`, once, after all resolution passes complete.
    var globalPublicByModule: [String: Set<String>] = [:]
    // R73's loop sibling — module-scope `[T]` global name -> its ELEMENT type, module-scoped for the
    // same reason `globalTypesByModule` is.
    var globalArrayElemByModule: [String: [String: String]] = [:]
    /// SOUNDNESS R585 (b7/b6) — the metatype twins of `globalTypesByModule` / `globalArrayElemByModule`,
    /// module-sliced for the same reason those are.
    var globalMetatypesByModule: [String: [String: String]] = [:]
    var globalMetatypeArrayElemByModule: [String: [String: String]] = [:]
    var globalDictValueByModule: [String: [String: String]] = [:]   // SOUNDNESS R994
    // (module, global name, factory leaf) for a global initialized by a bare lowercase call
    // (`let x = makeX()`) — the leaf's return type isn't known until `returnsIdx` is built, so resolution
    // is deferred exactly like `staticFactoryFields` above.
    var globalFactories: [(module: String, name: String, leaf: String)] = []
    // Merged `DeclCollector.typeGenericBounds` across every file — a type's generic param may be BOUND by
    // a conditional-conformance extension living anywhere (later in the same file, or another file), so
    // the merge has to complete before `unresolvedGenericFields` below can be retried.
    var typeGenericBoundsAll: [String: [String: String]] = [:]
    /// R243 — merged `DeclCollector.typeGenericFnParams`: Type -> generic params a SAME-TYPE requirement
    /// binds to a FUNCTION TYPE. Same merge-then-retry ordering as `typeGenericBoundsAll`, and for the
    /// same reason: the constraining extension can live in any file.
    var typeGenericFnParamsAll: [String: Set<String>] = [:]
    // A stored field typed as its enclosing type's own (as-yet-unbound) generic parameter — resolved once
    // per-file collection is done and `typeGenericBoundsAll` is complete. Mirrors `staticFactoryFields`'s
    // two-phase shape one level down (see `DeclCollector.unresolvedGenericFields`'s doc for the ordering
    // hazard this exists to close).
    var unresolvedGenericFields: [(ty: String, field: String, param: String)] = []
    var protocolMethods: [String: Set<String>] = [:]
    var protocolFnTypedMembers: Set<String> = []   // SOUNDNESS R563 — see DeclCollector
    var protocolPropTypesAll: [String: [String: String]] = [:]   // SOUNDNESS R578 — see DeclCollector
    var protocolPropNamesAll: [String: Set<String>] = [:]          // SOUNDNESS R904 — see DeclCollector
    var protocolPaths: Set<String> = []           // ⟨0.39⟩ see DeclCollector.protocolPaths
    var protocolSupers: [String: Set<String>] = [:]
    var conformers: [String: [String]] = [:]
    /// R266 — `DeclCollector.pathSupers`, unioned: SUBTYPE FULL PATH -> supertype names.
    var pathSupers: [String: [String]] = [:]
    var localTypes: Set<String> = []
    var localTypePaths: Set<String> = []
    var declaredTypes: Set<String> = []
    // ⟨0.33.1⟩ scan-wide aggregate of `DeclCollector.declaredTypesUnconditional` — see that field's doc.
    var declaredTypesUnconditional: Set<String> = []
    var typeAliases: [String: String] = [:]
    var declaredTypePathsAI: Set<String> = []                    // VEIN A(i)
    var fileTypeAliasesAI: [String: String] = [:]                // VEIN A(i) N-d
    var typeGenericParamNamesAI: [String: Set<String>] = [:]     // VEIN A(i) N-d
    var typeAliasArms: [String: Set<String>] = [:]   // R429 — every arm of a `#if`-duplicated alias
    var memberTypeAliasesAll: [String: [String: Set<String>]] = [:]   // R915 (B) — see DeclCollector
    // R178 — function-typed aliases (`typealias Cb = () -> Void`), unioned across files and then
    // closed transitively below. See `DeclCollector.fnTypeAliases`.
    var fnTypeAliasesRaw: Set<String> = []
    var dynamicMemberTypes: Set<String> = []
    var propertyWrapperTypes: Set<String> = []
    var resultBuilderTypes: Set<String> = []
    var globalActorTypes: Set<String> = []
    // Type-level attached-macro candidates (`DeclCollector.typeMacroAttrs`, unioned across files —
    // see that field's doc). Consulted per-function below, keyed on `FnInfo.enclosingType`.
    var typeMacroAttrs: [String: [String]] = [:]
    var wrappedProps: [String: [String: String]] = [:]
    var returnsIdx: [String: String] = [:]
    /// SOUNDNESS R585 (b9) — the metatype half of `returnsIdx`: fn leaf -> the type whose METATYPE it
    /// returns. Separate map for `globalMetatypes`' reason — `returnsIdx` answers "what VALUE type does
    /// this factory vend", and a metatype answer there would make `mk().validate()` an instance call.
    var metatypeReturnsIdx: [String: String] = [:]
    var genericReturnArgIdx: [String: GenericReturnArg] = [:]   // SOUNDNESS R1044
    var localGenerics = LocalGenericFacts()                      // SOUNDNESS R1044 residual
    var metatypeReturnsTmp: [String: String?] = [:]
    var importCounts: [String: Int] = [:]
    var fileImports: [String: [String]] = [:]   // file (rel path) -> modules it imports (per-fn blind disclosure)
    /// ⟨0.39⟩ spelled inherited-type path -> the FILES whose conformances named it. Obligation 2 keys a
    /// foreign abstraction's union entry under the OWNING package, and the only evidence a Swift
    /// conformance carries about the owner is its file's import list — see `foreignOwnerModule`.
    var conformanceFiles: [String: Set<String>] = [:]
    // ── INTERNAL MODULES: A DECLARED TARGET'S ACTUAL SOURCE ROOT, AND NOTHING ELSE ────────────────
    //
    // `internalModules` gates BOTH disclosure channels — the κ coverage ledger and the per-function
    // `invisible` hedge — and `invisible` is the only thing between an unresolved call into a blind
    // module and a ⟨0.21⟩ purity claim. So a name wrongly marked internal is a SILENT UNDER-REPORT, and
    // this derivation has now produced one three times, each in a different spelling:
    //
    //   · every entry of `<root>/Sources/` inserted with no manifest check at all, so a manifest-less
    //     `.xcodeproj`-shaped tree with `Sources/Stripe/Shim.swift` reported ZERO functions;
    //   · any analyzed `Sources/<X>/` anywhere taken as proof of module X (the folder-named-after-an-SDK
    //     case, round 2);
    //   · a `.testTarget`/`.plugin`/`path:`-relocated declaration accepted as proof that
    //     `Sources/<X>` is that target's source root, when its sources live in `Tests/<X>`,
    //     `Plugins/<X>` or wherever `path:` says (round 3, inside the fix for round 2).
    //
    // The rule that closes all three, and the one the previous repair claimed while not implementing:
    // a module is internal when an analyzed file lives under a DECLARED TARGET'S ACTUAL SOURCE ROOT.
    // Not a directory that looks like one.
    //
    // **In an Xcode tree a folder is not a module** — an app target compiles all its files into ONE
    // module, so `import Networking` beside a `Sources/Networking/` folder refers to a framework or a
    // package, never to the folder. `Sources/<X>` ⇒ module X is an SPM convention, so it is honoured
    // only where an SPM manifest says so. That makes this strict rule correct in BOTH directions rather
    // than merely safe in one.
    // NO `pkgName` SEED. A package NAME is not a module — and `pkgName` is not even a declaration: it
    // comes from a first-`name:` regex over the manifest, falling back to the directory basename. When a
    // package is named after the dependency it WRAPS, the seed marked a remote, never-analyzed module
    // internal and both disclosure channels vanished.
    //
    // Live on firefox-ios at HEAD, which is how this was caught: its `Package.swift` declares
    // `name: "Danger"` and wraps `.product(name: "Danger", package: "swift")`. Measured on the full
    // repo — `Dangerfile.swift`'s 41 functions all hedge `DangerSwiftCoverage`, the sibling import in
    // the SAME file, and NONE hedge `Danger`, its dominant one; `Danger` is absent from the ledger
    // entirely. Everything reached through the real Danger SDK read pure with nothing disclosed.
    //
    // If the manifest genuinely declares a target of that name, the loop below claims it on the
    // evidence — a declaration and a source root — rather than on the package being called something.
    // ONE MANIFEST PARSER IN THIS CODEBASE, not two — and for a while there were two, which is worth
    // recording because the second one was DEAD and carried all the reasoning. What stood beside
    // `targetsIn` was a hand-rolled scan — a regex for `.target(`, a paren matcher, a hand-written
    // argument reader — a few files away from `parsePackageTargets`, which does the same job with
    // SwiftSyntax and is covered by tests because the `--target` resolver depends on it. Every defect
    // that derivation produced was a rediscovery of something the real parser already handles: comments,
    // string literals, nesting, a computed value where a literal was assumed, an unclosed paren. Six
    // silent under-reports across four review rounds, each found in the fix for the last, and every one
    // of them lived in the copy. It is gone; this rationale belongs to the function BELOW, which runs.
    //
    // `Self.literal` in the parser returns nil for anything that is not a plain string literal, so a
    // computed name yields no target rather than a wrong one — the safe direction, by construction
    // rather than by my remembering to check. `targetSourceDirs` then gives the target's REAL source
    // directory, including SwiftPM's bare `<name>/` fallback, which the hand-rolled version did not know
    // about at all.
    // ── MODULE IDENTITY IS PER-FILE, AND HONOURS THE DEPENDENCY GRAPH ─────────────────────────────
    //
    // `internalModules` was a per-SCAN set answering a per-FILE question. That mismatch is what nine
    // review rounds kept finding: a name claimed anywhere silenced it everywhere, so a nested mock
    // package's `.target(name: "AcmePay")` made the ROOT package's import of the real AcmePay read pure.
    // Bounding the claim to the root manifest (0.27.0) removed that at the cost of naming every local
    // package a blind spot again — sound, and noisy.
    //
    // The question a disclosure channel actually asks is: *can THIS FILE's package import THAT module?*
    // Which is answered by the dependency graph, not by the filesystem:
    //   · a file's OWNING package is the one whose declared target roots contain it;
    //   · a package can import its own targets, plus — through each `.package(path:)` it DIRECTLY
    //     declares — the PRODUCTS those local packages expose and the targets those products name.
    //     ONE HOP, not transitive: SwiftPM requires a package to declare a dependency itself before its
    //     targets may import from it, so a grandchild's products are not on this file's import path.
    //     (The `.xcodeproj` arm IS transitive, and for the opposite reason — Xcode puts the whole
    //     reachable graph on a target's import path. Two build systems, two answers; see
    //     `localPackageDirsByTarget`.)
    // A module outside that set is genuinely invisible to this file, whatever else the scan analyzed.
    //
    // Everything unreadable resolves toward disclosure: no owning package, an unreadable `targets:` or
    // `dependencies:` list, a computed path — each yields no claim, so the module stays named. That is
    // the direction the whole 0.27 thread had to be beaten into, and it is the default here.
    var declaredIn: [String: [(name: String, root: String)]] = [:]   // package dir -> its targets
    var declTargets: [String: [PackageTarget]] = [:]                 // …and their full declarations
    var localDepsOf: [String: [String]] = [:]                        // package dir -> local dep dirs
    func targetsIn(_ pkgDir: String) -> [(name: String, root: String)] {
        if let c = declaredIn[pkgDir] { return c }
        var out: [(name: String, root: String)] = []
        if let src = try? String(contentsOfFile: (pkgDir as NSString).appendingPathComponent("Package.swift"),
                                 encoding: .utf8) {
            let isDir: (String) -> Bool = { p in
                var d: ObjCBool = false
                return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
            }
            let parsed = parsePackageTargetDeclarations(manifestSource: src) ?? []
            declTargets[pkgDir] = parsed
            let pathPinned = Set(parsed.filter { $0.path != nil }.map(\.name))
            for t in parsed where !t.isPlugin && (t.path != nil || !pathPinned.contains(t.name)) {
                if let dirs = try? targetSourceDirs([t], packageRoot: pkgDir, exists: isDir) {
                    for d in dirs { out.append((t.name, candorAbsolutePath(d))) }
                }
            }
            localDepsOf[pkgDir] = (parsePackageLocalDependencies(manifestSource: src) ?? []).map {
                candorAbsolutePath((pkgDir as NSString).appendingPathComponent($0))
            }
        }
        declaredIn[pkgDir] = out
        return out
    }
    /// What ONE PRODUCT of a package EXPOSES to importers: the targets that product names, and nothing
    /// else — SwiftPM exposes products, and a target left out of every product cannot be imported from
    /// outside the package at all.
    ///
    /// This function had a coarser sibling, `exposed(by pkgDir:)`, answering for a whole package. It is
    /// deleted rather than left here, because every defect in this area has been a consumer reaching for
    /// the coarse answer to a fine question. Two of them were exactly this pair: `importable` once began
    /// `Set(targetsIn(pkgDir).map(\.name))` — every declared target, so a dependency's INTERNAL target
    /// silenced the parent's import of a same-named remote module (a `Mocks` package exposing only
    /// `MockKit` while declaring an internal `.target(name: "AcmePay")` made the root's `import AcmePay`
    /// vanish from every channel) — and later the `.xcodeproj` arm called the package-wide version for a
    /// target that links ONE product, so a sibling product's targets were claimed.
    ///
    /// A PRODUCT NAME IS NOT A MODULE: `.library(name: "Pay", targets: ["PayCore"])` is imported as
    /// `PayCore`, and claiming `Pay` silences a real remote module of that name. The product is the unit
    /// of exposure; the target is the unit of import; they are not interchangeable.
    ///
    /// `exposed(by:)` is the right answer where the importer declared a dependency on the whole PACKAGE
    /// — the SwiftPM arm, where a manifest's `.package(path:)` does exactly that. An Xcode target links
    /// PRODUCTS, one at a time, and a package commonly vends several. Measured: `PkgA` vending `AProd`
    /// and `BProd`, with target `App` linking `AProd` only — `import BTarget` in App went silent on BOTH
    /// channels, `appEntry` absent from `functions` under ⟨0.21⟩, while a control import of an undeclared
    /// name was correctly disclosed. App cannot link `BProd`, so that name belongs to something else.
    ///
    /// The resolver's walk was already product-granular; the answer was collapsed to a directory on the
    /// way out and this is where it got spent. Keeping the product costs nothing — it is the key the
    /// walk already used.
    var exposedProductCache: [String: Set<String>] = [:]
    func exposed(product: String, in pkgDir: String) -> Set<String> {
        let key = pkgDir + "\u{0}" + product
        if let c = exposedProductCache[key] { return c }
        var out = Set<String>()
        if let src = try? String(contentsOfFile: (pkgDir as NSString).appendingPathComponent("Package.swift"),
                                 encoding: .utf8) {
            let analyzed = analyzedTargets(in: pkgDir)
            // DECLARATIONS ONLY, and MEMBER TARGETS ONLY — for the same two reasons as `exposed(by:)`
            // above. nil (unreadable or non-literal) exposes nothing, which errs toward disclosure.
            for p in parsePackageProductDeclarations(manifestSource: src) ?? [] where p.name == product {
                for t in p.targets where analyzed.contains(t) { out.insert(t) }
            }
        }
        exposedProductCache[key] = out
        return out
    }

    /// Which modules a file inside `pkgDir` may import: the package's own declared targets, plus what
    /// each DIRECTLY declared local dependency exposes. Not transitive: SwiftPM requires a direct
    /// dependency declaration to import a product, so inheriting a grandchild's products would claim on
    /// evidence the manifest does not carry.
    var importableCache: [String: Set<String>] = [:]
    /// Which local package declares PRODUCT `name`, among the packages `pkgDir` directly depends on.
    /// nil unless exactly one does — two candidates is an ambiguous key, and an ambiguous key must not
    /// license a purity claim.
    func localPackageDeclaring(product name: String, dependencyOf pkgDir: String) -> String? {
        var hit: String? = nil
        for dep in localDepsOf[pkgDir] ?? [] {
            _ = targetsIn(dep)                                       // populates declTargets for the dep
            guard let src = try? String(contentsOfFile: (dep as NSString).appendingPathComponent("Package.swift"),
                                        encoding: .utf8),
                  let prods = parsePackageProductDeclarations(manifestSource: src),
                  prods.contains(where: { $0.name == name }) else { continue }
            if hit != nil { return nil }
            hit = dep
        }
        return hit
    }
    /// What a file in TARGET `t` of package `pkgDir` may import.
    ///
    /// PER TARGET, NOT PER PACKAGE — and this was per package until it was measured. SwiftPM lets a
    /// target import only what its own `dependencies:` name, so a package's OTHER targets are not on
    /// its import path. Starting from every declared target of the package meant a sibling target could
    /// silence a real external module of the same name:
    ///
    ///     .executableTarget(name: "App")          // declares NO dependencies
    ///     .target(name: "Stripe")                 // a local stub, used by something else
    ///
    /// with `App/main.swift` doing `import Stripe` and calling into the real SDK. Measured on the built
    /// binary: `functions: []` and an empty ledger — `ship` absent under ⟨0.21⟩ is a purity claim over
    /// an SDK call. Rename that sibling to `Payments`, change nothing else, and the same tree reports
    /// `ship` with `invisible: ["Stripe"]`. One target name in the manifest was the whole difference.
    ///
    /// This is the SwiftPM twin of the defect fixed three times over on the `.xcodeproj` side: a
    /// per-container answer to a per-member question. It sat twelve lines from those fixes through
    /// three review rounds because every round was briefed on the Xcode arm.
    ///
    /// TRANSITIVE, deliberately: SwiftPM puts a transitive dependency's module on the import path, so
    /// excluding it would name a readable module a blind spot. Anything unreadable at any step — a
    /// non-literal `dependencies:`, an unresolvable product, a target this parse never saw — yields
    /// NOTHING for that file, so it claims nothing and every module it imports stays named.
    /// Every dependency name a target's closure NAMES — in-package targets plus product names, whether
    /// or not they resolve to anything local. Wider than `importable` on purpose: a REMOTE product is
    /// named here and absent there. Used ONLY to report the chained-coverage mismatch below; it does not
    /// gate any claim, because SPEC §2 rule 3 says coverage applies to every package a loaded report
    /// covers, full stop.
    var declaredNamesCache: [String: Set<String>] = [:]
    func declaredNames(forTarget t: String, in pkgDir: String) -> Set<String> {
        let key = pkgDir + "\u{0}" + t
        if let c = declaredNamesCache[key] { return c }
        _ = importable(forTarget: t, in: pkgDir)
        return declaredNamesCache[key] ?? []
    }
    func importable(forTarget t: String, in pkgDir: String) -> Set<String> {
        let key = pkgDir + "\u{0}" + t
        if let c = importableCache[key] { return c }
        _ = targetsIn(pkgDir)                                        // populates declTargets/localDepsOf
        let byName = Dictionary(grouping: declTargets[pkgDir] ?? [], by: \.name).compactMapValues(\.first)
        var inPackage: Set<String> = []
        var wantProducts: [String] = []
        var stack = [t]
        var unreadable = false
        while let cur = stack.popLast() {
            guard inPackage.insert(cur).inserted else { continue }
            guard let pt = byName[cur] else { continue }
            if pt.dependenciesUnreadable || pt.productDependenciesUnreadable { unreadable = true; break }
            for d in pt.dependencies {
                // A plain string naming an in-package target is a TARGET edge; one that names nothing
                // here is a PRODUCT of a dependency package — SwiftPM accepts both spellings.
                if byName[d] != nil { stack.append(d) } else { wantProducts.append(d) }
            }
            wantProducts.append(contentsOf: pt.productDependencies)
        }
        declaredNamesCache[key] = unreadable ? [] : inPackage.union(wantProducts)
        var out: Set<String> = []
        if !unreadable {
            // THE INVARIANT: only names whose sources this run actually read. Everything else is a
            // module we have nothing to say about, and saying nothing about it means disclosing it.
            let analyzed = analyzedTargets(in: pkgDir)
            out = inPackage.filter { analyzed.contains($0) }
            for prod in wantProducts {
                guard let dep = localPackageDeclaring(product: prod, dependencyOf: pkgDir) else { continue }
                out.formUnion(exposed(product: prod, in: dep))
            }
        }
        importableCache[key] = out
        return out
    }

    /// The package that owns an analyzed file — the nearest ancestor manifest one of whose declared
    /// target roots contains it. nil when no manifest claims the file, which claims nothing.
    var ownerCache: [String: String?] = [:]
    /// Which of `pkgDir`'s declared targets owns `file` — the one whose real source root contains it.
    /// nil when two roots do (a `path:` nesting one target's directory inside another's), because the
    /// file's import path would then be ambiguous and an ambiguous answer must not license a claim.
    func owningTarget(of file: String, in pkgDir: String) -> String? {
        let hits = targetsIn(pkgDir).filter { file.hasPrefix($0.root + "/") }
        return hits.count == 1 ? hits[0].name : nil
    }
    func owningPackage(of file: String) -> String? {
        if let c = ownerCache[file] { return c }
        var dir = (file as NSString).deletingLastPathComponent
        var found: String? = nil
        while dir.count > 1 {
            if targetsIn(dir).contains(where: { file.hasPrefix($0.root + "/") }) { found = dir; break }
            // STOP AT THE FIRST PACKAGE BOUNDARY, claim or no claim. A manifest that yields nothing —
            // unreadable, a `.binaryTarget`, a computed `path:` — used to let the walk continue UP, and
            // the file then inherited an ANCESTOR package's importable set. A vendored package under
            // `Sources/App/Vendor/`, or any root target with `path: "."`, is enough: the vendored file
            // gets the root's dependency list, and a name the root may import but the vendored package
            // may not reads as internal. Stopping here yields no owner, so the file claims nothing and
            // every module it imports stays named.
            if FileManager.default.fileExists(
                atPath: (dir as NSString).appendingPathComponent("Package.swift")) { break }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        ownerCache[file] = found
        return found
    }
    /// module -> the absolute analyzed files that may import it. Used by both disclosure channels.
    // KEYED BY THE RELATIVE PATH, exactly as `fileImports` is — the two are looked up together at every
    // use site, and keying one absolutely and the other relatively would silently return the empty set
    // for every file, which reads as "nothing importable" and floods the disclosure rather than
    // suppressing it. (The safe direction, but a defect all the same: nothing would ever be internal.)
    // …AND IT MUST HAVE BEEN ANALYZED — **BY THE PACKAGE THE NAME RESOLVES TO**.
    //
    // This was a scan-wide set of bare NAMES, and that made it the tenth instance of the pattern every
    // defect in this derivation has been: two questions sharing one answer. "Can this file import X" is
    // answered per dependency graph; "did this run read X" was answered against ANY package's
    // same-named target. Measured: a scan root declaring `.package(path: "../LibA")` — LibA outside the
    // scan, its `URLSession` client never read — plus an unrelated in-scan package whose target is also
    // called `Core`, and the root's `import Core` went silent on both channels. Rename that unrelated
    // target and the disclosure returns.
    //
    // So the conjunct is per (package, target): a name counts as read only where the package that
    // exposes it actually had files in this scan.
    var analyzedInCache: [String: Set<String>] = [:]
    // HOISTED. This was rebuilt inside `analyzedTargets` on every uncached package: on a large
    // `.xcodeproj` corpus that is one `URL` construction per file per package — ~300k of them at
    // 10k files × 30 packages — for an answer that does not vary.
    let absSourcePaths = sourcePaths.map { candorAbsolutePath($0) }
    func analyzedTargets(in pkgDir: String) -> Set<String> {
        if let c = analyzedInCache[pkgDir] { return c }
        let absPaths = absSourcePaths
        var out = Set<String>()
        for t in targetsIn(pkgDir) where absPaths.contains(where: { $0.hasPrefix(t.root + "/") }) {
            out.insert(t.name)
        }
        analyzedInCache[pkgDir] = out
        return out
    }
    var importableByFile: [String: Set<String>] = [:]                 // rel file -> importable modules
    var declaredByFile: [String: Set<String>] = [:]                   // …and what its target NAMES
    /// SOUNDNESS R592 — …and EVERY TARGET ITS OWN PACKAGE DECLARES, analyzed or not. `importableByFile`
    /// is intersected with `analyzedTargets`, so a target this run read nothing of is absent from it —
    /// and a C target has no `.swift` files, so it is absent from it ALWAYS. That left the package's own
    /// C targets as the only surviving "foreign" candidates in `foreignOwnerModule`. This index answers
    /// the question that one actually asks — *is this name someone ELSE's module?* — from the manifest's
    /// declarations rather than from what the run happened to parse.
    ///
    /// The FULL parsed declaration list, not `targetsIn`'s filtered one: a plugin, or a target whose
    /// `path:` this run could not resolve to a directory, is still not a foreign package's module.
    var ownTargetsByFile: [String: Set<String>] = [:]
    for raw in sourcePaths {
        let abs = candorAbsolutePath(raw)
        let rel = raw.hasPrefix(rootDir)
            ? String(raw.dropFirst(rootDir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : raw
        if let pkg = owningPackage(of: abs), let own = owningTarget(of: abs, in: pkg) {
            // BOTH conjuncts: the file's TARGET can import it, AND this run actually read it.
            importableByFile[rel] = importable(forTarget: own, in: pkg)
            declaredByFile[rel] = declaredNames(forTarget: own, in: pkg)
            ownTargetsByFile[rel] = Set((declTargets[pkg] ?? []).map(\.name))   // R592
        } else if xcodeLinksByFile[abs] != nil || xcodeModulesByFile[abs] != nil {
            let deps = xcodeLinksByFile[abs] ?? []
            // AN XCODE TARGET'S FILE has no owning `Package.swift` — a folder in an Xcode target is not
            // a module, and the target compiles all of its files into one. What it may import is the
            // local-package closure the `--target` resolver ALREADY walked, so this reads that answer
            // rather than deriving a second one. Without it, an `.xcodeproj` repo claims nothing and
            // every local package it genuinely depends on is named a blind spot (NetNewsWire: 27 of
            // them, nearly all analyzed in the same run).
            //
            // PER FILE, not per closure. The closure's union answers the SCOPE question — what code is
            // in the scan — and answering identity with it lets a file in the app target inherit the
            // share extension's package links, which is a purity claim over a module this file cannot
            // see. `deps` is what THIS file's target(s) link. A file the resolver could not attribute
            // to a target is simply absent here and claims nothing, so the failure direction is
            // disclosure.
            // EXPOSED, not importable: an Xcode target links a local package's PRODUCTS, so it sees
            // what that package publishes — not the internal targets only its own files may import.
            // An Xcode target is a MODULE. Its files compile into one, and a target that depends on it
            // imports it by name — so a scan that reads both and still calls the dependency invisible is
            // describing a blind spot it does not have. These names come from the resolver, which
            // already knows each member's own dependency closure and admits only members that
            // contributed files: the run-analyzed conjunct, kept.
            var out = Set(xcodeModulesByFile[abs] ?? [])
            for dep in deps {
                // The RESOLVER's membership, intersected with what this run analyzed. Re-deriving the
                // membership here was the third instance in this branch of a consumer throwing away a
                // producer's answer — and the manifests it got wrong were exactly the ones the resolver
                // had already repaired with `swift package dump-package`, so the scope note said "read
                // via SwiftPM" while the ledger called the same package's module invisible.
                let analyzed = analyzedTargets(in: dep.packageDir)
                for t in dep.members where analyzed.contains(t) { out.insert(t) }
            }
            importableByFile[rel] = out
        }
    }
    var collectors: [DeclCollector] = []
    var surfaceCollectors: [TypeSurfaceCollector] = []   // ⟨0.40⟩ the declared-type surface producer
    var surfaceAliases: Set<String> = []
    var surfaceExported: Set<String> = []                // `@_exported import`s anywhere in the package
    // SOUNDNESS R859 — every name this package spells as an EXISTENTIAL (`any P`), package-wide. Swift
    // admits only a protocol after `any`, so this is the source's own statement that `P` is an
    // abstraction — the one fact about a DEPENDENCY's type the consumer can read without the dependency
    // publishing it (R843: reports carry no supertypes). See the R859 arm in the call loop.
    var existentialSpelled: Set<String> = []
    var someSpelled: Set<String> = []   // SOUNDNESS R706 (residual)
    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): a file that fails to read used to be SILENTLY skipped by the
    // `guard…else { continue }` — a green report would then hide the code candor never saw. Track it.
    var unanalyzed: [(path: String, reason: String)] = []
    for p in sourcePaths {
        guard let src = try? String(contentsOfFile: p, encoding: .utf8) else {
            // RELATIVE, like every other path this report carries — the line just below computes one
            // for the readable case, and this branch was the only one emitting an absolute. An absolute
            // path records where the CI runner's checkout was, and makes the SAME defect produce
            // DIFFERENT BYTES on two machines, which a report-diffing consumer reads as a change.
            unanalyzed.append((path: rel(p, to: rootDir), reason: "source failed to read"))
            continue
        }
        let tree = Parser.parse(source: src)
        let rel = p.hasPrefix(rootDir) ? String(p.dropFirst(rootDir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : p
        // ⟨0.21⟩ A FILE THAT DID NOT PARSE IS UNANALYZED, and until now this engine could not tell.
        //
        // `Parser.parse` is error-tolerant: it always returns a tree and never throws, so a syntax error
        // arrived here indistinguishable from clean source and the file counted as fully analyzed. The
        // comment on `unanalyzed` above used to conclude from that "the practical swift unanalyzed case is
        // an unreadable file, not a parse failure" — which treats a parse failure as not a case. MEASURED,
        // it is a case, and a gate-flipping one. Two trees, identical `Hidden.leak` performing Net, the
        // second preceded by one unparseable declaration:
        //
        //     well-formed        functions: [Hidden.leak -> Net]   `deny Net Hidden`  exit 1
        //     one syntax error   functions: [nope -> Net]          `deny Net Hidden`  exit 0, ok: true
        //
        // Error recovery folds `enum Hidden { static func leak()` into `nope`'s body, so the effect is
        // MISATTRIBUTED rather than lost — and `Hidden.leak` disappears from `functions` entirely, which
        // under ⟨0.21⟩ is a positive claim of purity over a function that performs Net. The scoped gate
        // then passes green with nothing disclosed anywhere. That is the cardinal sin at gate level,
        // reached by one stray character. Found by conformance PART 29 (P5) on its first honest run.
        //
        // RECORDED AND STILL WALKED — the file is NOT skipped, and that ordering is the whole design.
        // The recovered tree is partial but TRUE: the Net above is real, and dropping the file would turn
        // a misattribution into a total loss. It is the same treatment ⟨0.21⟩ already gives an incomplete
        // dependency report (`Deps.swift`: entries derived from source it DID read are kept exactly as
        // they are, and only COVERAGE is withheld). So this is strictly additive — it can only add a
        // hedge and fail a gate closed, never remove an effect.
        //
        // ERRORS ONLY, not warnings: a warning is a well-formed tree the parser merely has an opinion
        // about, and hedging on those would flood `unanalyzed` with files candor read perfectly well.
        if let firstError = ParseDiagnosticsGenerator.diagnostics(for: tree)
            .first(where: { $0.diagMessage.severity == .error }) {
            unanalyzed.append((path: p, reason: "source failed to parse: \(firstError.message)"))
        }
        let c = DeclCollector(file: rel, tree: tree)
        c.walk(tree)
        existentialSpelled.formUnion(ExistentialSpellingCollector.names(in: tree))   // R859
        someSpelled.formUnion(ExistentialSpellingCollector.names(in: tree, specifier: "some"))   // R706 residual
        // R532 — the type declarations found inside func/init/subscript/deinit bodies, which the four
        // `.skipChildren` sites cannot walk in place. Drained HERE, after the file pass, rather than by a
        // nested `walk` from inside a visit: `SyntaxVisitor.walk` is not re-entrant.
        c.finishBodyLocalTypes()
        collectors.append(c)
        let tsc = TypeSurfaceCollector(file: rel)   // ⟨0.40⟩
        tsc.walk(tree)
        surfaceCollectors.append(tsc)
        surfaceAliases.formUnion(TypeSurfaceCollector.aliasNames(in: tree))
        for item in tree.statements {
            if let imp = item.item.as(ImportDeclSyntax.self),
               imp.attributes.contains(where: { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "_exported" }),
               let m = imp.path.first?.name.text { surfaceExported.insert(m) }
        }
    }
    var returnsTmp: [String: String?] = [:]
    var genericReturnArgTmp: [String: GenericReturnArg?] = [:]                 // SOUNDNESS R1044
    var memberReturnNamesAll: [(leaf: String, owner: String, name: String)] = []   // SOUNDNESS R1010
    var lgOrderTmp: [String: [String]?] = [:], lgReturnArgsTmp: [String: [String]?] = [:]   // SOUNDNESS R1044 residual
    var lgMemberReturnsAll: [(ty: String, leaf: String, param: String?)] = []
    var lgFieldParamsAll: [(ty: String, field: String, param: String)] = []
    var lgInitsAll: [(ty: String, shape: LocalGenericInit)] = []
    // FINDING 1 — aggregate the opaque/erased Sequence builder indexes across files.
    var opaqueSeqLeaves: Set<String> = []
    var seqConcreteTmp: [String: String?] = [:]
    var closureFields: [String: Set<String>] = [:]   // FINDING 2 — Type -> closure-property names (own unit)
    var mutableClosureFields: [String: Set<String>] = [:]   // R96 — the `var` subset of the above
    // CONST-STRING PROPAGATION — module/global + static string constants, aggregated across files. Same
    // ambiguity rule: a name bound to ≥2 DIFFERENT literals (here, across files) → nil (never resolved).
    var constStrings: [String: String?] = [:]
    for c in collectors {
        opaqueSeqLeaves.formUnion(c.opaqueSeqLeaves)
        for (k, v) in c.seqConcreteRetTmp {
            if let existing = seqConcreteTmp[k] {
                if existing != v { seqConcreteTmp[k] = String?.none }   // ambiguous across files — never guess
            } else { seqConcreteTmp[k] = v }
        }
        for (t, ps) in c.closureFields { closureFields[t, default: []].formUnion(ps) }
        for (t, ps) in c.mutableClosureFields { mutableClosureFields[t, default: []].formUnion(ps) }
        for (k, v) in c.constStrings {
            if let existing = constStrings[k] {
                if existing != v { constStrings[k] = String?.none }   // ambiguous across files — never guess
            } else { constStrings[k] = v }
        }
        for (k, v) in c.returnsTmp {
            if let existing = returnsTmp[k] {
                if existing != v { returnsTmp[k] = String?.none }
            } else {
                returnsTmp[k] = v
            }
        }
        for (k, v) in c.genericReturnArgTmp {   // SOUNDNESS R1044 — same ambiguity rule as `returnsTmp`
            if let existing = genericReturnArgTmp[k] {
                if existing != v { genericReturnArgTmp[k] = GenericReturnArg?.none }
            } else {
                genericReturnArgTmp[k] = v
            }
        }
        memberReturnNamesAll.append(contentsOf: c.memberReturnNames)   // SOUNDNESS R1010
        for (k, v) in c.lgOrder {   // SOUNDNESS R1044 residual — same ambiguity rule as `returnsTmp`
            if let e = lgOrderTmp[k] { if e != v { lgOrderTmp[k] = [String]?.none } } else { lgOrderTmp[k] = v }
        }
        for (k, v) in c.lgReturnArgs {
            if let e = lgReturnArgsTmp[k] { if e != v { lgReturnArgsTmp[k] = [String]?.none } } else { lgReturnArgsTmp[k] = v }
        }
        lgMemberReturnsAll.append(contentsOf: c.lgMemberReturns)
        lgFieldParamsAll.append(contentsOf: c.lgFieldParams)
        lgInitsAll.append(contentsOf: c.lgInits)
        localGenerics.nonTypeNames.formUnion(c.lgAssocNames)
        for (k, v) in c.metatypeReturnsTmp {   // R585 (b9) — same ambiguity rule as `returnsTmp`
            if let existing = metatypeReturnsTmp[k] {
                if existing != v { metatypeReturnsTmp[k] = String?.none }
            } else {
                metatypeReturnsTmp[k] = v
            }
        }
        allFns.append(contentsOf: c.fns)
        for (t, fs) in c.fields { fields[t, default: [:]].merge(fs) { a, _ in a } }
        for (t, fs) in c.fieldArrayElem { fieldArrayElem[t, default: [:]].merge(fs) { a, _ in a } }
        for (t, fs) in c.fieldMetatypes { fieldMetatypes[t, default: [:]].merge(fs) { a, _ in a } }   // R585
        for (t, fs) in c.fieldMetatypeArrayElem { fieldMetatypeArrayElem[t, default: [:]].merge(fs) { a, _ in a } }
        for (t, fs) in c.fieldArrayElemNested { fieldArrayElemNested[t, default: [:]].merge(fs) { a, _ in a } }
        for (t, fs) in c.fieldDictValue { fieldDictValue[t, default: [:]].merge(fs) { a, _ in a } }
        for (t, fs) in c.fieldTypeArgs { fieldTypeArgs[t, default: [:]].merge(fs) { a, _ in a } }   // R905
        for (t, fs) in c.opaqueFields { opaqueFields[t, default: []].formUnion(fs) }
        for (cn, ts) in c.caseAssoc { caseAssocAll[cn, default: []].formUnion(ts) }
        for (cn, ts) in c.caseAssocMetatype { caseAssocMetatypeAll[cn, default: []].formUnion(ts) }   // R585
        for (pn, ms) in c.protocolMethods { protocolMethods[pn, default: []].formUnion(ms) }
        protocolFnTypedMembers.formUnion(c.protocolFnTypedMembers)   // R563
        for (pn, ps) in c.protocolPropTypes { protocolPropTypesAll[pn, default: [:]].merge(ps) { a, _ in a } }   // R578
        for (pn, ps) in c.protocolPropNames { protocolPropNamesAll[pn, default: []].formUnion(ps) }   // R904
        protocolPaths.formUnion(c.protocolPaths)   // ⟨0.39⟩
        for (pn, ss) in c.protocolSupers { protocolSupers[pn, default: []].formUnion(ss) }
        for (pn, ts) in c.conformers {
            conformers[pn, default: []].append(contentsOf: ts)
            conformanceFiles[pn, default: []].insert(c.file)     // ⟨0.39⟩ obligation 2, see `conformanceFiles`
        }
        for (sub, sups) in c.pathSupers { pathSupers[sub, default: []].append(contentsOf: sups) }
        localTypes.formUnion(c.localTypes)
        localTypePaths.formUnion(c.localTypePaths)
        declaredTypes.formUnion(c.declaredTypes)
        declaredTypesUnconditional.formUnion(c.declaredTypesUnconditional)
        for (a, u) in c.typeAliases { typeAliases[a] = u }   // last-writer-wins (a redeclared alias is rare)
        declaredTypePathsAI.formUnion(c.declaredTypePaths)
        for (a, u) in c.fileTypeAliases { fileTypeAliasesAI[a] = u }
        for (t, ns) in c.typeGenericParamNames { typeGenericParamNamesAI[t, default: []].formUnion(ns) }
        // R429 — …and the ARMS, unioned. The line above is the last-writer-wins the row was filed
        // against; it stays because 26 call sites read `dealias` as single-valued and a multi-valued
        // resolution there would be a large mechanical refactor, which this project's own history
        // prices above the defect it prevents. The arm SET is what the call-edge site reads instead:
        // an edge per arm makes the effects union through the propagation that already exists.
        for (a, u) in c.typeAliasArms { typeAliasArms[a, default: []].formUnion(u) }
        for (t, m) in c.memberTypeAliases {                                  // R915 (B)
            for (a, u) in m { memberTypeAliasesAll[t, default: [:]][a, default: []].formUnion(u) }
        }
        fnTypeAliasesRaw.formUnion(c.fnTypeAliases)          // R178
        dynamicMemberTypes.formUnion(c.dynamicMemberTypes)
        propertyWrapperTypes.formUnion(c.propertyWrapperTypes)
        resultBuilderTypes.formUnion(c.resultBuilderTypes)
        globalActorTypes.formUnion(c.globalActorTypes)
        for (t, attrs) in c.typeMacroAttrs { typeMacroAttrs[t, default: []].append(contentsOf: attrs) }
        for (t, ps) in c.wrappedProps { wrappedProps[t, default: [:]].merge(ps) { a, _ in a } }
        for m in c.imports { importCounts[m, default: 0] += 1 }
        fileImports[c.file] = c.imports
        staticFactoryFields.append(contentsOf: c.staticFactoryFields)
        // R73 — module-scope global receiver typing (see `globalTypesByModule` above). A same-module
        // redeclaration is a compile error, so `merge(a,_ in a)` here only ever protects against the
        // pathological/unparseable edge case, never adjudicates a real ambiguity.
        let cMod = swiftModuleOf(c.file)
        globalTypesByModule[cMod, default: [:]].merge(c.globalTypes) { a, _ in a }
        // R85 — ONLY the public/open NAME SET is recorded here now; the TYPE lookup is deferred to the
        // single derivation pass after the `globalFactories` resolution loop below, once every pass that
        // can populate `globalTypesByModule` (this merge AND that later factory pass) has run. See
        // `publicGlobalTypesByModule`'s own comment for why a second, earlier write site here was the
        // R85 defect, not a style choice.
        globalPublicByModule[cMod, default: []].formUnion(c.globalPublic)
        globalArrayElemByModule[cMod, default: [:]].merge(c.globalArrayElem) { a, _ in a }
        globalDictValueByModule[cMod, default: [:]].merge(c.globalDictValue) { a, _ in a }   // R994
        globalMetatypesByModule[cMod, default: [:]].merge(c.globalMetatypes) { a, _ in a }              // R585
        globalMetatypeArrayElemByModule[cMod, default: [:]].merge(c.globalMetatypeArrayElem) { a, _ in a }
        globalFactories.append(contentsOf: c.globalFactories.map { (cMod, $0.name, $0.leaf) })
        for (t, bs) in c.typeGenericBounds { typeGenericBoundsAll[t, default: [:]].merge(bs) { a, _ in a } }
        for (t, ps) in c.typeGenericFnParams { typeGenericFnParamsAll[t, default: []].formUnion(ps) }   // R243
        unresolvedGenericFields.append(contentsOf: c.unresolvedGenericFields)
    }

    // FINDING 1 — resolve the opaque/erased Sequence builder indexes now that the GLOBAL localTypes set is
    // complete. A leaf whose body returns an unambiguous CONCRETE LOCAL iterable → `seqBuilderConcrete` (the
    // iteration site edges to that type's `next`, precise); any other opaque-seq leaf (ambiguous body, a
    // non-local concrete type, or an erased value that can't be pinned) → `opaqueSeqBuilders` (the iteration
    // site reads honest Unknown). A leaf that is BOTH an opaque-seq builder AND something else (an overload
    // returning a plain type) stays in opaqueSeqBuilders only via this disjoint split — Unknown is the safe side.
    var seqBuilderConcrete: [String: String] = [:]
    var opaqueSeqBuilders: Set<String> = []
    for leaf in opaqueSeqLeaves {
        if let some = seqConcreteTmp[leaf], let concrete = some, localTypes.contains(concrete) {
            seqBuilderConcrete[leaf] = concrete
        } else {
            opaqueSeqBuilders.insert(leaf)
        }
    }

    // PARAM-TYPE OVERLOAD RESOLUTION. The syntactic engine keys a method by NAME, so same-name overloads merge
    // into ONE node = the UNION of every overload body — fabricating an effectful overload's effect onto a pure
    // sibling (SwiftDate: the relative `compare(_:DateComparisonType)` reads the clock, so the pure
    // `compare(toDate:granularity:)` and ~13 callers inherited Clock; and `Date.compare(_:Date)` — Foundation's
    // pure compare — mis-resolved to the same-name+arity extension). Split overloaded names into per-SIGNATURE
    // nodes and route each call to the overload(s) its ARG TYPES are consistent with.
    // SAFETY (no regression / no new under-report): when arg types are UNKNOWN the call matches ALL
    // arity-compatible overloads — a UNION, exactly the old merged behaviour; an overload is excluded only on a
    // CONFIDENT arity/type mismatch; a call matching NONE is dropped (it targets a non-local/platform overload,
    // e.g. Foundation's compare). A name with ONE signature stays bare (qual unchanged → byte-identical).
    func sigStr(_ ps: [(type: String?, hasDefault: Bool, variadic: Bool)]) -> String {
        "(" + ps.map { ($0.type ?? "_") + ($0.variadic ? "..." : "") }.joined(separator: ",") + ")"
    }
    var qualGroup: [String: Int] = [:]
    // `<main>` top-level units are excluded from overload suffixing (like accessors): the wire name MUST
    // stay exactly `<main>` (never `<main>()`), and a multi-file package's per-file top levels union under
    // the one `<main>` module-entry unit rather than becoming spurious overloads.
    for f in allFns where !f.isAccessor && !f.isTopLevel { qualGroup[f.qual, default: 0] += 1 }
    // THE BARE NAME OF EVERY LOCAL FREE FUNCTION, captured BEFORE the overload-suffix rewrite below renames
    // `shellOut` to `shellOut(Int)` / `shellOut(String)`. `freeFnByName` (built later, from the RENAMED
    // quals) is what `localFreeFns` was drawn from — so once a project overloaded a name a hard-coded
    // free-call heuristic ALSO answers for (`shellOut`, JohnSundell's ShellOut is the found case, but the
    // whole `kappaFree` table is exposed the same way — see Classifier.swift), the bare identifier at the
    // call site (`shellOut(to: "literal")` — Swift call sites are never written with the disambiguator) no
    // longer matched anything in the shadow set, so the heuristic fired UNGUARDED and pre-empted real,
    // in-tree, unambiguous overload resolution — dropping the true callee's effects with no `Unknown`, no
    // `incomplete`, nothing (the 0.33.0 corpus find). A NON-overloaded local fn was never affected (its
    // qual is never suffixed, so the bare name was already the key) — this only restores the shadow for the
    // overloaded case.
    //
    // KEYED BY MODULE, unlike the rest of `localFreeFns` — and the restriction is load-bearing, not
    // cosmetic. MEASURED on swift-nio: a `#if os(Windows) … #else getenv(...) #endif` idiom means the
    // syntactic scan (which reads BOTH branches of every `#if`, having no platform to compile for) sees a
    // Windows-only stub `func getenv(_: UnsafePointer<CChar>) { fatalError(...) }` in one target
    // (`NIOFS`/`_NIOFileSystem`) — declared TWICE, once per target, which is exactly what made it
    // OVERLOADED and is why an unscoped fix here would have gone live-broad instead of staying at the
    // shellOut shape. An UNSCOPED (whole-scan) shadow set made that stub's bare name shadow the platform
    // heuristic for `getenv(...)` calls EVERYWHERE in the scan, including inside a wholly unrelated target
    // (`NIOEmbedded`, `NIOCore`) that cannot even SEE `NIOFS`'s internal free function — 1137 functions
    // across the tree lost a real, previously-correct `Env` charge to a stub they cannot call, the
    // opposite direction from the defect this fix exists to close. `matchOverloads` already draws this
    // exact module line for RESOLUTION (`hitsInCallerModule`, above) — the SHADOW guard has to draw it too,
    // or a name heuristic gets pre-empted by a declaration the caller's own module cannot reach, which is
    // just as wrong as being pre-empted by a heuristic when a same-module declaration COULD reach it.
    var localFreeFnBaseNamesByModule: [String: Set<String>] = [:]
    // ⟨0.33.1⟩ THE #if-GATED STUB, one scope level from the fix directly above. `getenv`/etc declared
    // inside `#if os(Windows) … #endif` with NO `#else` is exactly as visible to this syntactic scan as
    // an unconditional declaration — SwiftSyntax carries no build configuration, so DeclCollector reads
    // it and it lands in `allFns` marked `isConditionallyCompiled` (see that field's doc). Left
    // unhandled, such a declaration shadows the SAME-MODULE κ heuristic for EVERY build, including every
    // one that will never contain the stub — swift-nio's `NIOFS`/`_NIOFileSystem` `getenv` shim lost
    // `realUsage`'s real Env charge this way with no `Unknown`, no `incomplete`, nothing (the ifhedge-A
    // corpus find).
    //
    // A name with AT LEAST ONE UNCONDITIONAL declaration in the module keeps shadowing exactly as
    // before — a real, in-tree declaration exists and winner-take-all is right (the module-scoping fix
    // above draws the same line for RESOLUTION; this is the same discipline for the SHADOW guard). A
    // name whose ONLY module declaration(s) sit inside a `#if` is recorded in
    // `conditionalOnlyFreeFnNamesByModule` instead of the shadow set: the heuristic is allowed to fire
    // (the call MAY genuinely reach the real platform function), and `CallCollector` additionally keeps
    // the ordinary call edge to the conditional declaration alive — so a build where the stub genuinely
    // is the one compiled still gets ITS effects too. UNION, not winner-take-all, because resolution
    // here has not failed — it is CONDITIONAL, and the safe side of "cannot tell" is to count both
    // readings rather than pick one (the same direction `matchOverloads` takes when arg types cannot
    // rule an overload out).
    var conditionalOnlyFreeFnNamesByModule: [String: Set<String>] = [:]
    do {
        var unconditionalByModule: [String: Set<String>] = [:]
        var anyByModule: [String: Set<String>] = [:]
        for f in allFns where f.enclosingType == nil && !f.isAccessor && !f.isTopLevel {
            let m = swiftModuleOf(f.loc)
            anyByModule[m, default: []].insert(f.qual)
            if !f.isConditionallyCompiled { unconditionalByModule[m, default: []].insert(f.qual) }
        }
        for (m, names) in unconditionalByModule { localFreeFnBaseNamesByModule[m, default: []].formUnion(names) }
        for (m, names) in anyByModule {
            let conditionalOnly = names.subtracting(unconditionalByModule[m] ?? [])
            if !conditionalOnly.isEmpty { conditionalOnlyFreeFnNamesByModule[m] = conditionalOnly }
        }
    }
    // R74 — `<main>` IS THE SAME VEIN AS `<lazy>::CFG` / bare `cfg`, ONE NAME OVER. `<main>` is minted once
    // PER FILE (DeclCollector, `isTopLevel`) and deliberately kept out of both disambiguation passes above
    // (the `qualGroup`/overload pass and the free-fn shadow pass both exclude `isTopLevel`) — on purpose,
    // because a single SwiftPM executable target commonly spreads its top-level statements over several
    // files, and Swift really does run them as ONE program entry, so they must union under one `<main>`
    // unit rather than becoming spurious siblings. But the qual stayed the bare literal, unscoped by
    // module — so a directory holding TWO+ SwiftPM executable targets (each its own separate program
    // entry) unions under that SAME literal too: `direct["<main>"]`/`edges["<main>"]` are dictionary keys,
    // and every target's top-level FnInfo shares the key. MEASURED: a pure target's `<main>` inherited an
    // unrelated target's `Fs` read on a 2-target fixture, reported at the PURE target's own file location —
    // a fabrication, not an under-report (candor-spec SOUNDNESS-VEIN-global-unit-identity.md — the identical
    // class; that vein's fixes (b616caf/7cec437/7f18c38) never reached `<main>` because `isTopLevel` sits
    // outside the passes they patched).
    //
    // Disambiguate ONLY when 2+ DISTINCT modules actually mint a `<main>` — by far the common case is one
    // module (a single executable target, or zero: a pure library tree mints no `<main>` at all), and that
    // case touches nothing here, so its qual stays the bare literal `<main>`, byte-identical to every
    // report emitted before this fix. Modules are ordered ALPHABETICALLY, not by file-walk order (which is
    // not a stable public contract), so the assignment is deterministic run to run: the alphabetically-first
    // module keeps bare `<main>`; each subsequent module gets `<main>#n` — the same positional-suffix shape
    // `globalDup` immediately below already uses for a same-named global collision. Every FnInfo belonging
    // to one module receives the SAME suffix (not a per-file one), so a target's own multi-file union is
    // completely unaffected — only the CROSS-module collision breaks.
    let topLevelModules = Set(allFns.filter { $0.isTopLevel }.map { swiftModuleOf($0.loc) }).sorted()
    if topLevelModules.count > 1 {
        var mainQualForModule: [String: String] = [:]
        for (i, m) in topLevelModules.enumerated() {
            mainQualForModule[m] = i == 0 ? "<main>" : "<main>#\(i)"
        }
        for i in allFns.indices where allFns[i].isTopLevel {
            let q = mainQualForModule[swiftModuleOf(allFns[i].loc)] ?? allFns[i].qual
            allFns[i].qual = q
            allFns[i].simpleQual = q
        }
    }
    // FILE-SCOPE GLOBALS are accessor units and so sit outside the overload pass above — which meant two
    // modules each declaring `let cfg` collapsed into ONE unit carrying the union of both initializers'
    // effects, reported at one file's location, and a reader of either was charged both. Give them the same
    // positional disambiguation ordinary functions get, so the units stay distinct; module-scoped resolution
    // below then picks the right one. (candor-spec SOUNDNESS-VEIN-global-unit-identity.md — rust had the
    // same merge on `<lazy>::NAME` and was fixed the same way.)
    var globalDup: [String: Int] = [:]
    for f in allFns where f.isAccessor && f.enclosingType == nil && !f.qual.contains(".") {
        globalDup[f.qual, default: 0] += 1
    }
    let mergedGlobals = Set(globalDup.filter { $0.value > 1 }.keys)
    if !mergedGlobals.isEmpty {
        var seenGlobal: [String: Int] = [:]
        for i in allFns.indices
        where allFns[i].isAccessor && allFns[i].enclosingType == nil
              && !allFns[i].qual.contains(".") && mergedGlobals.contains(allFns[i].qual) {
            let n = seenGlobal[allFns[i].qual, default: 0]
            seenGlobal[allFns[i].qual] = n + 1
            if n > 0 { allFns[i].qual = "\(allFns[i].qual)#\(n)"; allFns[i].simpleQual = allFns[i].qual }
        }
    }
    let overloadedQuals = Set(qualGroup.filter { $0.value > 1 }.keys)
    var overloads: [String: [(qual: String, sig: [(type: String?, hasDefault: Bool, variadic: Bool)], module: String)]] = [:]
    var overloadedBases = Set<String>()
    /// SOUNDNESS R266 — the same overload table keyed on the declaration's FULL NESTED PATH instead of
    /// its `simpleQual`. `overloadedBases` is keyed short (`S.run`), so `enum Outer { class S }` and an
    /// unrelated top-level `class S` share one key and an unqualified sibling call inside either reaches
    /// BOTH. This twin is exact. It is ADDITIVE — the short index still drives every other consumer.
    var overloadsByPath: [String: [(qual: String, sig: [(type: String?, hasDefault: Bool, variadic: Bool)], module: String)]] = [:]
    var overloadedBasesPath = Set<String>()
    if !overloadedQuals.isEmpty {
        var seen: [String: Int] = [:]   // identical type-sigs get a positional suffix so they stay distinct nodes
        for i in allFns.indices where !allFns[i].isAccessor && !allFns[i].isTopLevel && overloadedQuals.contains(allFns[i].qual) {
            let base = allFns[i].simpleQual
            let pathBase = allFns[i].qual        // R266 — the FULL nested path, before the sig suffix
            overloadedBases.insert(base)
            overloadedBasesPath.insert(pathBase)
            var suffix = sigStr(allFns[i].paramSig)
            let dupKey = "\(allFns[i].qual)\(suffix)"
            let n = seen[dupKey, default: 0]; seen[dupKey] = n + 1
            if n > 0 { suffix += "#\(n)" }
            let entry = ("\(allFns[i].qual)\(suffix)", allFns[i].paramSig, swiftModuleOf(allFns[i].loc))
            overloads[base, default: []].append(entry)
            overloadsByPath[pathBase, default: []].append(entry)
            allFns[i].qual = "\(allFns[i].qual)\(suffix)"
            allFns[i].simpleQual = "\(base)\(suffix)"
        }
    }
    // SUBTYPE INDEX for overload matching. `conformers[P]` lists the types that declared `: P` (protocol
    // conformers AND class subclasses — `pushType` records both). Build the TRANSITIVE subtype set per
    // supertype so a strict subtype/conformer (`Dog` for `Animal`, `Puppy` for `Animal` via `Dog`) is
    // recognised, not just direct conformers. Used below: a string `!=` on type names is SUBTYPE-BLIND —
    // `"Dog" != "Animal"` would wrongly exclude the effectful `handle(_: Animal)` overload, and if no sibling
    // matched the edge was DROPPED and the caller came back SILENTLY PURE (the cardinal soundness violation).
    var subtypesOf: [String: Set<String>] = [:]   // supertype -> all (transitive) known subtypes/conformers
    for (sup, subs) in conformers {
        var seen = Set<String>(), frontier = subs
        while let s = frontier.popLast() {
            if !seen.insert(s).inserted { continue }
            if let more = conformers[s] { frontier.append(contentsOf: more) }
        }
        subtypesOf[sup, default: []].formUnion(seen)
    }
    // INVERSE: type -> its (transitive) supertypes — the protocols it conforms to and classes it extends.
    // Used to resolve a PROTOCOL-EXTENSION DEFAULT method reached via a CONCRETE receiver (`j.emit()` where
    // `j: Job`, Job: Logging, and Logging's extension defaults `emit`): Job declares no `emit`, so the typed
    // `Job.emit` doesn't resolve and the call read pure — fall back to the default body on a conformed super.
    var supertypesOf: [String: Set<String>] = [:]
    for (sup, subs) in subtypesOf { for s in subs { supertypesOf[s, default: []].insert(sup) } }
    // SOUNDNESS R915 (A) — every `Outer.Inner` ADJACENT pair of a declared type path (`A.B.C` gives
    // `A.B` and `B.C`), so a member hop that names a NESTED TYPE (`Outer.Inner.make()`) is read as that
    // type rather than as a value hop that keeps `Outer`.
    var nestedTypePairsR915: Set<String> = []
    if !DeclCollector.r915AOff {
        for p in localTypePaths {
            let c = p.split(separator: ".").map(String.init)
            if c.count >= 2 { for i in 0..<(c.count - 1) { nestedTypePairsR915.insert("\(c[i]).\(c[i + 1])") } }
        }
    }
    // SOUNDNESS R906 — the CLASS part of that map, for a ternary's common-superclass join.
    var classSupertypesR906: [String: Set<String>] = [:]
    let protocolNamesR906 = Set(protocolMethods.keys)
    for (t, sups) in supertypesOf where declaredTypes.contains(t) && !protocolNamesR906.contains(t) {
        let cls = sups.filter { declaredTypes.contains($0) && !protocolNamesR906.contains($0) && $0 != t }
        if !cls.isEmpty { classSupertypesR906[t] = cls }
    }
    // Match a call (arg count + inferred arg types) to overload target qual(s). Empty ⇒ confident no local
    // overload matches ⇒ DROP. Non-empty ⇒ edge to all (one hit precise; several = sound union). A closure so
    // it captures `overloads`/`subtypesOf`.
    /// SOUNDNESS R537 — THE ARG-TYPE FILTER MAY NARROW THE CANDIDATE SET, NEVER EMPTY IT. One
    /// implementation of the one question, shared by `matchOverloads` and `matchOverloadsPath` (R266's
    /// twin) so the two cannot drift — the comment on that twin already says they are meant to be
    /// literally one implementation, and they were two copies of this loop.
    ///
    /// **THE DEFECT.** `at != pt` with no recorded subtype relation was read as a PROVEN mismatch. It is
    /// not one when `pt` is a TYPE PARAMETER — `Self`, the owner's generic parameter, an associated type
    /// — because no `subtypesOf` entry can ever exist for a name that is not a type. So every overload of
    /// `Rope.prepend(_ other: Self)` / `prepend(_ item: Element)` was excluded once the argument had a
    /// concrete type, the candidate set went to ZERO, the edge was DROPPED, and the caller read
    /// SILENTLY PURE — the cardinal sin, in the one direction this filter's own comment says it must
    /// never take.
    ///
    /// **WHY THE FIX IS "NEVER ZERO" AND NOT "DETECT A TYPE PARAMETER".** Detecting one needs the set of
    /// generic-parameter NAMES, and the scan records only the BOUNDED ones (`typeGenericBounds` is
    /// written from `gp.inheritedType`), so a bare `struct Box<T>`'s `T` is invisible to any such test —
    /// measured, `Box.take(T)` is dropped exactly like `Self`. A rule keyed on the OUTCOME needs no
    /// index: when type-filtering leaves nothing, fall back to the ARITY-compatible set, which is
    /// precisely the sound over-approximation this function already uses whenever argument types are
    /// unknown. Every case where at least one overload matches is byte-identical to before, so no
    /// precision is given back; only the silent-pure outcome is removed.
    ///
    /// Reachable from TWO spellings and pre-existing in one of them: `b.add(bags[0])` — a subscript, which
    /// this engine has typed since long before R537 — is ABSENT at v0.39.0 and charges `Fs` after this.
    /// R537's widening is what made the second spelling (`bags.first`) reach it, and finding it that way
    /// is the reason the fix's own A/B is run on real code rather than reasoned about.
    let narrowByArgTypes: ([(qual: String, sig: [(type: String?, hasDefault: Bool, variadic: Bool)], module: String)], Int, [String?])
        -> [(qual: String, sig: [(type: String?, hasDefault: Bool, variadic: Bool)], module: String)] = { cands, argc, argTypes in
        var arityOK: [(qual: String, sig: [(type: String?, hasDefault: Bool, variadic: Bool)], module: String)] = []
        var typed: [(qual: String, sig: [(type: String?, hasDefault: Bool, variadic: Bool)], module: String)] = []
        for c in cands {
            // arity by COUNT RANGE: a call must provide every REQUIRED param (not defaulted, not variadic) and
            // no more than the total — independent of WHICH params a labeled call omitted. A trailing VARIADIC
            // (`T...`) lifts the upper bound (it absorbs any number of args).
            let variadicIdx = c.sig.firstIndex(where: { $0.variadic })
            let required = c.sig.filter { !$0.hasDefault && !$0.variadic }.count
            let upper = variadicIdx != nil ? Int.max : c.sig.count
            if argc < required || argc > upper { continue }
            arityOK.append(c)
            var ok = true
            let typeLimit = variadicIdx ?? c.sig.count   // don't positionally type-check at/after a variadic param
            for j in 0..<min(argc, typeLimit) where j < argTypes.count {  // confident type mismatch (positional call)
                // SUBTYPE-AWARE exclusion (soundness-first): exclude this overload ONLY when the arg type is
                // PROVABLY NOT a subtype/conformer of the param type. `at == pt` matches; `at` ∈ the param's
                // transitive subtype set matches (a concrete conformer/subclass passed where the base/protocol
                // is declared). When the relation can't be proven, KEEP the overload (union its effects) rather
                // than exclude — the safe over-approximate direction, never a silent-pure drop.
                guard let at = argTypes[j], let pt = c.sig[j].type, at != pt else { continue }
                if subtypesOf[pt]?.contains(at) == true { continue }   // arg is a known subtype/conformer of param
                ok = false; break
            }
            if ok { typed.append(c) }
        }
        return typed.isEmpty ? arityOK : typed
    }

    let matchOverloads: (String, Int, [String?], String) -> [String] = { base, argc, argTypes, callerModule in
        guard let cands = overloads[base] else { return [] }
        let kept = narrowByArgTypes(cands, argc, argTypes)
        let hits = kept.map(\.qual)
        let hitsInCallerModule = kept.filter { $0.module == callerModule }.map(\.qual)
        let isFreeFunction = !base.contains(".")
        return (isFreeFunction && !hitsInCallerModule.isEmpty) ? hitsInCallerModule : hits
    }

    // MODULE-QUALIFIED FREE CALL (`Core.shared()`). Swift lets a call name the declaring module to
    // disambiguate, and it is the idiomatic way a wrapper delegates to a same-named implementation
    // elsewhere (`SwiftSyntaxMacrosTestSupport` → `SwiftSyntaxMacrosGenericTestSupport.assertMacroExpansion`).
    // Such a call was read as a member call on a TYPE named `Core`, which does not exist, so the edge was
    // DROPPED and the caller came back silent-pure — the cardinal sin (candor-spec
    // SOUNDNESS-VEIN-global-unit-identity.md). Indexed `module -> leaf -> quals`, and used only when the
    // module name is a real target and the leaf is unambiguous within it, so it can never guess.
    var freeFnByModule: [String: [String: [String]]] = [:]
    // module -> bare global name -> unit quals (the quals may carry a `#n` disambiguator).
    var globalsByModule: [String: [String: [String]]] = [:]
    // name indexes for resolution — UNAMBIGUOUS only (the family's never-guess rule)
    var freeFnByName: [String: [String]] = [:]
    // ⟨0.33.1⟩ `freeFnByName`'s keys, RESTRICTED to quals with at least one UNCONDITIONAL (not inside a
    // `#if`) declaration — the scan-wide counterpart of `conditionalOnlyFreeFnNamesByModule` above, used
    // to build `localFreeFnNames` below. `freeFnByName` itself stays untouched (still every declaration,
    // conditional or not) because it also drives ordinary call-graph RESOLUTION, where a call made from
    // inside the same `#if` branch as its callee must still resolve.
    var freeFnUnconditionalQuals: Set<String> = []
    var byQual: Set<String> = []
    // Receivers resolve to SIMPLE type names (`vars`/`fields`/`typeName` are simple), but qual is now the
    // full nested path — so a typed call edge `Backend.store` (simple) is matched to the full qual through
    // this index. A simple key with exactly ONE full qual resolves precisely (the common non-colliding
    // nested type); a simple key with MULTIPLE full quals is a genuine same-named-nested collision that
    // simple-name resolution cannot disambiguate → the edge is dropped (honest under-report, NEVER a
    // fabricated effect). Top-level types: simple == full, so the direct `byQual` hit fires and behaviour
    // is unchanged.
    var qualBySimple: [String: Set<String>] = [:]
    // Top-level GLOBAL initializer units (an accessor unit with a bare, dot-free qual) — a bare-name read
    // edges here. Kept distinct from free functions so a bare reference to a function name never resolves
    // as a global-init touch.
    var globalUnitNames: Set<String> = []
    for f in allFns {
        byQual.insert(f.qual)
        if f.qual != f.simpleQual { qualBySimple[f.simpleQual, default: []].insert(f.qual) }
        // accessor units (computed/global/default-expr bodies) are NOT callable free functions — they're
        // reached by property/global-read edges, so they must not pollute the free-fn name index (a
        // same-qual default-expr accessor unit otherwise made its function's name AMBIGUOUS, dropping every
        // call edge to it — the hole-9 default-arg fix's own footgun).
        // `<main>` is not a callable free function (no Swift call site names it) — keep it out of the
        // free-fn index so it neither resolves phantom `<main>()` calls nor makes any name ambiguous.
        if f.enclosingType == nil && !f.isAccessor && !f.isTopLevel {
            freeFnByName[f.qual, default: []].append(f.qual)
            if !f.isConditionallyCompiled { freeFnUnconditionalQuals.insert(f.qual) }
            // key on the SIMPLE name: the qual may already carry an overload suffix (`shared()#1`).
            let leaf = f.simpleQual.split(separator: "(").first.map(String.init) ?? f.simpleQual
            freeFnByModule[swiftModuleOf(f.loc), default: [:]][leaf, default: []].append(f.qual)
        }
        if f.isAccessor && f.enclosingType == nil && !f.qual.contains(".") {
            globalUnitNames.insert(f.qual)
            let bare = f.qual.split(separator: "#").first.map(String.init) ?? f.qual
            globalsByModule[swiftModuleOf(f.loc), default: [:]][bare, default: []].append(f.qual)
        }
    }
    // Resolve a simple "Type.member" call target to the set of full nested quals it may run: an exact
    // full-qual hit (top-level, already full) is a singleton; a `qualBySimple` hit UNIONS every colliding
    // candidate; no candidate at all returns empty (genuinely unresolved — the only case a caller may
    // still treat as "unknown", never "ambiguous"). A closure (not a global func) so it captures the
    // function-local indexes built just above.
    //
    // TRIED AND REVERTED, THEN FIXED (2026-08-27): the old single-qual form's `cands.count == 1` branch
    // folded "no candidate" and "2+ same-simple-name candidates, a real callee runs" into the SAME `nil`
    // outcome — a silent drop indistinguishable from "nothing to resolve". Disclosing `Unknown` on the
    // ambiguous case was tried as the "one funnel" fix and reverted: MEASURED on the 13-package corpus,
    // 6/13 packages differed, 116 newly-`Unknown` functions, dominated by ordinary Swift idioms —
    // `Options.init`, `Index.==`, `Iterator.next`, `State.init` — where many unrelated types each declare
    // their own nested type of that name and `qualBySimple` (keyed on the innermost simple name alone)
    // collides them. That is the ordinary, expected shape of this index, not a rare dispatch hidden
    // behind it, and disclosing on it was a flood, not a fix — see CHANGELOG `[0.33.0]`.
    //
    // UNIONING instead — every real caller of `resolveQual` already edges to WHATEVER it returns, exactly
    // the sound-over-approximation direction `matchOverloads` and the `#if`-branch union take elsewhere
    // in this file: a call that could run any of N same-named nested members is modeled as reaching ALL
    // of them, never a fabrication (each edged unit is a REAL declaration, not a merged/invented one —
    // see `FnInfo.qual`'s note on why merging the units themselves, rather than the call edges, would
    // fabricate). An all-pure collision (`Options.init` beside another unrelated `Options.init`)
    // contributes nothing new either way — no charge, no noise, so the 116-function flood does not
    // recur; a collision where any candidate is effectful now correctly reaches it, which the silent
    // `nil` never did. Cost: this can OVER-charge a caller with an effect belonging to the sibling it
    // didn't actually call — the same bounded-CHA cost every other ambiguous-dispatch arm here already
    // accepts, never a silent miss.
    let resolveQual: (String) -> Set<String> = { target in
        if byQual.contains(target) { return [target] }
        if let cands = qualBySimple[target] { return cands }
        return []
    }

    // SOUNDNESS R1047 — AN `extension String { init(randomAlphaNumericOfLength:) }` IS NOT EVERY `String(…)`.
    // The constructor arm edged a call `T(…)` to EVERY init this scan declares on `T`, whatever the call's argument
    // labels. For a type the scan DECLARES that over-approximation only unions the type's own inits; for a type it
    // merely EXTENDS (the stdlib's `String`, Foundation's `Data`), the platform owns the other initialisers, and
    // `String(cString: p)` / `String(describing: x)` / `String(x)` were all charged the extension's body —
    // swift-nio's `String(randomAlphaNumericOfLength:)` reached ~3,000 rows through it once that body was
    // (correctly) charged `Rand` (R1032). Swift's own rule decides: an init whose labels the call's labels cannot
    // satisfy (in order, a defaulted parameter skippable, a variadic one absorbing unlabelled arguments) is not
    // the one that runs. Applied ONLY to an extension-only owner and only where the call recorded its labels.
    // A qual more than one unit shares (an init and a synthesized unit of the same name) is not filtered: only a
    // qual with exactly ONE recorded signature can say which labels it takes.
    var initSigByQual: [String: [(label: String?, hasDefault: Bool, variadic: Bool)]] = [:]
    var initSigQualSeen: [String: Int] = [:]
    for f in allFns { initSigQualSeen[f.qual, default: 0] += 1 }
    for f in allFns where f.paramLabels.count == f.paramSig.count && initSigQualSeen[f.qual] == 1 {
        initSigByQual[f.qual] = zip(f.paramLabels, f.paramSig).map {
            ($0.0 == "_" ? nil : $0.0, $0.1.hasDefault, $0.1.variadic) }
    }
    let r1047Off = ProcessInfo.processInfo.environment["CANDOR_R1047_OFF"] != nil
    func extensionInitLabelsAdmit(_ call: Call, _ target: String) -> Bool {
        // The OWNER: an unqualified ctor's path is the type (`String`); a typed call's is `String.init`.
        let owner = call.path.hasSuffix(".init") ? String(call.path.dropLast(5)) : call.path
        // A NESTED owner (`BigString.UnicodeScalarView`) is keyed by its leaf in `declaredTypes`, so a dotted path
        // can not be proved extension-only here: it is left unfiltered (the release's union).
        guard !r1047Off, let labels = call.argLabels, !owner.contains("."), !declaredTypes.contains(owner),
              let sig = initSigByQual[target], target.contains(".init") else { return true }
        if ProcessInfo.processInfo.environment["CANDOR_R1047_PROBE"] != nil {
            FileHandle.standardError.write("R1047 \(target) labels=\(labels) sig=\(sig)\n".data(using: .utf8)!)
        }
        var j = 0
        for p in sig {
            if j < labels.count, labels[j] == p.label {
                j += 1
                if p.variadic { while j < labels.count, labels[j] == nil { j += 1 } }
            } else if !p.hasDefault && !p.variadic {
                return false
            }
        }
        return j == labels.count
    }

    /// SOUNDNESS R1081 — AN OPERATOR OVERLOAD IS ADMITTED ONLY WHERE ITS OPERANDS COULD BIND. A binary operator call was
    /// edged to every project unit of that NAME on the operand's type or its supertypes, so `(x + 1) * 2 - x / 3` on an
    /// `Int` charged `Fs` through `extension Shadow { static func + (a: Self, b: String) }` — a `String` parameter an
    /// integer literal cannot bind (executed: no write). This refuses a target only on PROOF, per operand: a literal
    /// whose kind the parameter's concrete type cannot take, or a typed operand of a concrete type that is neither the
    /// parameter's type nor a recorded subtype of it. A parameter spelled with a type parameter (`Self`, `T`), a
    /// protocol, or anything not known to be a concrete type proves nothing, and neither does an untyped operand —
    /// those keep the edge (the over-approximation the release took), so an undecidable call never turns silent.
    /// Only the EDGE is filtered; `resolved` is left to each site, as R1047 does.
    let r1081Off = DeclCollector.r1081Off
    let r1081Probe = CallCollector.veinBProbe
    var fnInfoByQualR1081: [String: FnInfo] = [:]
    for f in allFns where fnInfoByQualR1081[f.qual] == nil { fnInfoByQualR1081[f.qual] = f }
    let protoNamesR1081 = protocolPaths.union(protocolMethods.keys)
    let numericR1081: Set<String> = RAND_ROOTS.subtracting(["Bool"])
    let platformConcreteR1081: Set<String> = RAND_ROOTS.union(["String", "Substring", "Character", "Data", "URL", "Date", "UUID"])
    // A name that is ALSO a typealias anywhere in the scan proves nothing: the receiver's spelling can be the alias
    // (`typealias DisposeKey = Bag<Disposable>.KeyType`, i.e. `BagKey`) while a same-named struct exists elsewhere
    // (`CompositeDisposable.DisposeKey`) — measured on RxSwift, where it refused the real `==(BagKey,BagKey)`.
    let aliasNamesR1081: Set<String> = surfaceAliases.union(typeAliases.keys)
        .union(memberTypeAliasesAll.values.flatMap { $0.keys })
    func concreteR1081(_ t: String, generics: Set<String>) -> Bool {
        guard !generics.contains(t), !protoNamesR1081.contains(t), !aliasNamesR1081.contains(t),
              !t.contains(".") else { return false }
        return platformConcreteR1081.contains(t) || declaredTypes.contains(t)
    }
    /// Records a refusal on a stdlib scalar (`RAND_ROOTS`, not declared here): the operator is then the stdlib's own, so the
    /// call is answered — no edge, and no hedge — exactly as the release answered it with the wrong edge. Returns false,
    /// so it can sit in a `where` clause after a refused admission. On any other type a refusal leaves the call
    /// unanswered and the inherited-member arm below decides whether to disclose.
    var r1081Answered = false
    func r1081Refused(_ type: String) -> Bool {
        if !r1081Off, RAND_ROOTS.contains(type), !declaredTypes.contains(type) { r1081Answered = true }
        return false
    }
    func operatorOperandsAdmit(_ call: Call, _ target: String) -> Bool {
        guard !r1081Off, !call.operandLits.isEmpty, let f = fnInfoByQualR1081[target], f.paramSig.count == 2 else { return true }
        let generics = f.genericParamNames.union(typeGenericParamNamesAI.values.joined())
        for j in 0..<2 {
            guard let pt = f.paramSig[j].type, concreteR1081(pt, generics: generics) else { continue }
            let sups = supertypesOf[pt] ?? []
            if let lit = call.operandLits[j] {
                // Only a PLATFORM concrete type is judged against a literal: a project type's literal conformance can
                // arrive through a refinement (`DoubleWidth: FixedWidthInteger` takes an integer literal), which the
                // supertype index does not close over, so a project type never refuses a literal.
                guard platformConcreteR1081.contains(pt) else { continue }
                let ok: Bool
                switch lit {
                case "int":    ok = numericR1081.contains(pt) || sups.contains("ExpressibleByIntegerLiteral")
                case "float":  ok = ["Double", "Float", "CGFloat"].contains(pt) || sups.contains("ExpressibleByFloatLiteral")
                case "string": ok = ["String", "Substring", "Character"].contains(pt) || sups.contains("ExpressibleByStringLiteral")
                                    || sups.contains("ExpressibleByStringInterpolation")
                case "bool":   ok = pt == "Bool" || sups.contains("ExpressibleByBooleanLiteral")
                default:       ok = true
                }
                if !ok {
                    if r1081Probe { FileHandle.standardError.write("VBHIT\tR1081\t\(target) operand \(j) \(lit)-literal vs \(pt)\n".data(using: .utf8)!) }
                    return false
                }
            } else if j < call.argTypes.count, let at = call.argTypes[j], at != pt, concreteR1081(at, generics: generics),
                      subtypesOf[pt]?.contains(at) != true,
                      !(["Double", "CGFloat"].contains(at) && ["Double", "CGFloat"].contains(pt)) {   // implicit conversion
                if r1081Probe { FileHandle.standardError.write("VBHIT\tR1081\t\(target) operand \(j) \(at) vs \(pt)\n".data(using: .utf8)!) }
                return false
            }
        }
        return true
    }

    /// SOUNDNESS R572 — THE ONE IMPLEMENTATION of "which project units can `<Type>.<member>` run at a
    /// call site with this argument shape". An OVERLOADED declaration's qual carries a SIGNATURE SUFFIX
    /// (`Impl.two(Int)` — see `overloads`/`overloadedBases` above), so a bare `resolveQual("Impl.two")`
    /// is an exact-name miss and returns EMPTY for every overloaded member. Whatever folds that empty
    /// set in has silently dropped the whole witness, which is the cardinal sin: R572 lost EVERY
    /// conformer of an overloaded protocol requirement. `inheritedUnqualTargets` below had already been
    /// repaired for exactly this at the R32/R44 provided-member class, and the typed-call path at the
    /// `overloadedBases.contains(call.path)` arm too — three copies of one question (§F1.3), of which
    /// the per-conformer CHA was the copy that never got it. This closure is now the only spelling.
    ///
    /// `argc < 0` means the site records no argument shape (an operator witness): union EVERY overload
    /// rather than drop them all — the same sound over-approximation `matchOverloads` itself falls back
    /// to when the argument types cannot discriminate.
    ///
    /// THE OVERLOAD SET IS UNIONED WITH `resolveQual`'S, NOT SUBSTITUTED FOR IT, and that is the one
    /// place this differs from the two older copies. The signature-suffixing pass SKIPS accessor and
    /// top-level units, so a base can be in `overloadedBases` and STILL have real units carrying the
    /// bare name — a default-argument-expression accessor unit is the common one (`Argument.init`
    /// beside `Argument.init(Decoder)` …, 45 of them in swift-argument-parser). Returning only the
    /// matched overloads would have DROPPED those bodies: MEASURED on the 7-package corpus, 10 rows
    /// lost a call edge that way. A fix whose direction is additive must not smuggle a removal in, so
    /// the bare-name hit is kept and the overload set added to it.
    let memberTargets: (String, Int, [String?], String) -> Set<String> = { base, argc, argTypes, callerModule in
        var out = resolveQual(base)
        guard overloadedBases.contains(base) else { return out }
        out.formUnion(argc >= 0 ? Set(matchOverloads(base, argc, argTypes, callerModule))
                                : Set((overloads[base] ?? []).map(\.qual)))
        return out
    }

    /// SOUNDNESS R266 — `matchOverloads` against the PATH-keyed table. Same body, same authority; the
    /// only difference is that `base` is a full nested path (`Outer.S.run`), so a same-short-named type
    /// elsewhere in the scan cannot answer. The free-function branch below is unreachable here (a path
    /// base always contains a dot) and is kept only so the two forms stay literally one implementation.
    let matchOverloadsPath: (String, Int, [String?], String) -> [String] = { base, argc, argTypes, _ in
        guard let cands = overloadsByPath[base] else { return [] }
        // R537 — through the SHARED filter, which is what "literally one implementation" above was
        // supposed to mean: the two copies of this loop had already drifted by the time the never-zero
        // rule was needed, and fixing one of them would have left the other silent.
        return narrowByArgTypes(cands, argc, argTypes).map(\.qual)
    }

    /// SOUNDNESS R266 — SHORT type name -> every declared FULL PATH carrying it. More than one entry is a
    /// genuine same-short-name collision, and it is the only condition under which the short-keyed
    /// inherited climb below is narrowed to the path-keyed one. Everywhere else the short index answers
    /// exactly as it did, so R134's coverage is untouched (`localTypePaths` holds top-level types too,
    /// where path == short name and the two indexes are the same index).
    var typePathsBySimple: [String: Set<String>] = [:]
    for tp in localTypePaths {
        typePathsBySimple[tp.split(separator: ".").last.map(String.init) ?? tp, default: []].insert(tp)
    }

    /// SOUNDNESS R266 — transitive supertypes keyed on the SUBTYPE'S FULL PATH. Supertype names are
    /// resolved through `typePathsBySimple` so a nested base spelled by its short name lands on its own
    /// path; a name that resolves to several paths is kept as ALL of them (over-approximate, never a
    /// dropped edge — the same direction every other climb here takes).
    var supertypePathsOf: [String: Set<String>] = [:]
    for (sub, sups) in pathSupers {
        var seen = Set<String>(), frontier = sups
        while let name = frontier.popLast() {
            for path in (typePathsBySimple[name] ?? [name]) where !seen.contains(path) {
                seen.insert(path)
                frontier.append(contentsOf: pathSupers[path] ?? [])
            }
        }
        supertypePathsOf[sub] = seen.subtracting([sub])
    }

    /// SOUNDNESS R265 — per-declaration ACCESS CONTROL, keyed on the FINAL qual (after the overload
    /// signature suffix, so `matchOverloads`/`matchOverloadsPath` results look up directly).
    var declVisibility: [String: (access: String, file: String, owner: String)] = [:]
    for f in allFns where f.enclosingTypePath != nil {
        declVisibility[f.qual] = (f.access,
                                  f.loc.split(separator: ":").first.map(String.init) ?? f.loc,
                                  f.enclosingTypePath ?? "")
    }

    /// SOUNDNESS R265 — CAN AN UNQUALIFIED CALL AT THIS SITE SEE THIS MEMBER?
    ///
    /// Swift's unqualified lookup stops at the type scope only when the member is VISIBLE there. R255
    /// reordered the member arms in front of the free-function arms on the (true) ground that a visible
    /// member always beats a module-scope function of the same name — but keyed that decision on
    /// `overloadedBases`/`byQual`/`supertypesOf`, none of which carry access control or file/module
    /// scope. So a `private` member claimed a call Swift binds to the effectful global, and the caller
    /// went ABSENT from `functions[]` under the "nothing hidden" clean bill.
    ///
    /// MEASURED on a generated 1152-cell matrix, every cell compiled and EXECUTED: **94 cells regressed
    /// against the v0.35.0 artifact** — `private` 52, `fileprivate` 28, `internal` 14, `public` **0**,
    /// which is the visibility axis behaving exactly as the language says and the control that this is
    /// the right rule. 24 of the 94 are in ONE FILE: `private` is scoped to the declaring declaration and
    /// its same-file extensions, and **a subclass is neither**, so an inherited `private` member is
    /// invisible even to a subclass one line below it. A guard written against file PLACEMENT rather than
    /// against the language's visibility rule leaves exactly those 24.
    ///
    /// `package` is treated as visible. It is visible across every module of the same Swift package, and a
    /// scan is normally one package; guessing the other way would decline a member arm that Swift does
    /// bind, which is R255's silence reintroduced.
    let memberVisibleAt: (String, String, String?) -> Bool = { target, callerFile, callerTypePath in
        guard let v = declVisibility[target] else { return true }   // not a member decl: unchanged behaviour
        switch v.access {
        case "open", "public", "package": return true
        case "internal":   return swiftModuleOf(v.file) == swiftModuleOf(callerFile)
        case "fileprivate": return v.file == callerFile
        case "private":
            guard v.file == callerFile, let cp = callerTypePath else { return false }
            // the declaring declaration itself, its same-file extensions, and scopes nested inside it
            return cp == v.owner || cp.hasPrefix(v.owner + ".") || v.owner.hasPrefix(cp + ".")
        default: return true
        }
    }

    /// R134 — the project units an UNQUALIFIED (implicit-self) call to `leaf` can run when the enclosing
    /// type `et` does not declare `leaf` itself: the member is INHERITED from a superclass, a base's
    /// extension, or a conformed protocol's extension default. Empty ⇒ no supertype provides it ⇒ the
    /// caller must resolve to NOTHING, exactly as before.
    ///
    /// This is the same query the TYPED-receiver protocol-extension-default arm answers (`j.emit()` where
    /// Job conforms to Logging and Logging's extension defaults `emit`), so it climbs the SAME index the
    /// same way and carries no extra filter: the direction is UP, from one concrete type to the few
    /// supertypes it actually declares, and only REAL `<sup>.<leaf>` units are returned — never DOWN over
    /// a supertype's conformers, which is the direction that needs `STD_PURE_PROTOCOLS`/
    /// `RAW_VALUE_BASE_TYPES` to stay out of a fabrication flood. `supertypesOf` is already transitive, so
    /// `Base -> Mid -> Sub` needs no loop here.
    ///
    /// AN OVERLOADED INHERITED MEMBER MUST NOT VANISH — the R32/R44 provided-member class, and the exact
    /// way a fix like this reintroduces the sin it closes. An overloaded declaration's qual carries a
    /// SIGNATURE SUFFIX (see `overloads`/`overloadedBases` above), so plain `resolveQual("Base.run")`
    /// returns EMPTY when `Base` declares `run()` beside `run(times:)` — the whole edge would be dropped
    /// silently. Route those through `matchOverloads`, exactly as the typed arm does, using the same
    /// `argc`/`argTypes` authority the rest of this file uses (§F1.3: one question, one implementation).
    let inheritedUnqualTargets: (String, String, Int, [String?], String) -> Set<String> = {
        et, leaf, argc, argTypes, callerModule in
        var out = Set<String>()
        for sup in (supertypesOf[et] ?? []).sorted() where sup != et {
            let base = "\(sup).\(leaf)"
            if overloadedBases.contains(base) {
                out.formUnion(matchOverloads(base, argc, argTypes, callerModule))
            } else {
                out.formUnion(resolveQual(base))
            }
        }
        return out
    }

    /// SOUNDNESS R266 — `inheritedUnqualTargets` climbing FULL PATHS. Used only when the caller's short
    /// type name is ambiguous scan-wide (`typePathsBySimple[et].count > 1`), because that is the only
    /// condition under which the short-keyed climb can reach an unrelated hierarchy's members. Same body,
    /// same overload authority; `supertypePathsOf` replaces `supertypesOf`.
    let inheritedUnqualTargetsPath: (String, String, Int, [String?], String) -> Set<String> = {
        ep, leaf, argc, argTypes, callerModule in
        var out = Set<String>()
        for sup in (supertypePathsOf[ep] ?? []).sorted() where sup != ep {
            let base = "\(sup).\(leaf)"
            if overloadedBasesPath.contains(base) {
                out.formUnion(matchOverloadsPath(base, argc, argTypes, callerModule))
            } else {
                out.formUnion(resolveQual(base))
            }
        }
        return out
    }

    // SOUNDNESS R1010 — a member's `-> T` where `T` is its OWNER's generic parameter (declared in whichever file
    // declares the type, so only known here) names no type: poison the leaf, as `recordReturn` does for the
    // function's own generic parameters.
    for (leaf, owner, name) in memberReturnNamesAll where typeGenericParamNamesAI[owner]?.contains(name) == true {
        returnsTmp[leaf] = String?.none
    }
    for (k, v) in returnsTmp { if let t = v { returnsIdx[k] = t } }
    // SOUNDNESS R1044 — a leaf whose ONLY declarations return their argument's generic type, and that no ordinary
    // return also answers (a leaf both indexes speak for is ambiguous and neither may answer).
    for (k, v) in genericReturnArgTmp { if let g = v, returnsIdx[k] == nil { genericReturnArgIdx[k] = g } }
    // SOUNDNESS R1044 residual — the instantiation facts, keyed by the type's SIMPLE name. A member key two
    // declarations answer differently (an overload returning `V` beside one returning `Int`, or two same-named
    // types) answers nothing; so does a field or init of a type whose parameter list is poisoned.
    if !DeclCollector.r1044bOff {
        for (k, v) in lgOrderTmp { if let o = v { localGenerics.order[k] = o } }
        var mr: [String: Int?] = [:]
        for (ty, leaf, g) in lgMemberReturnsAll {
            guard let o = localGenerics.order[ty] else { continue }
            let idx: Int? = g.flatMap { o.firstIndex(of: $0) }
            let k = "\(ty).\(leaf)"
            if let e = mr[k] { if e != idx { mr[k] = Int?.none } } else { mr[k] = idx }
        }
        for (k, v) in mr { if let i = v { localGenerics.memberReturns[k] = i } }
        var fp: [String: Int?] = [:]
        for (ty, f, g) in lgFieldParamsAll {
            guard let o = localGenerics.order[ty], let i = o.firstIndex(of: g) else { continue }
            let k = "\(ty).\(f)"
            if let e = fp[k] { if e != i { fp[k] = Int?.none } } else { fp[k] = i }
        }
        for (k, v) in fp { if let i = v { localGenerics.fieldParams[k] = i } }
        for (ty, shape) in lgInitsAll where localGenerics.order[ty] != nil {
            localGenerics.inits[ty, default: []].append(shape)
        }
        for (k, v) in lgReturnArgsTmp { if let a = v, returnsIdx[k] != nil { localGenerics.returnArgs[k] = a } }
        for ns in typeGenericParamNamesAI.values { localGenerics.nonTypeNames.formUnion(ns) }
        for f in allFns { localGenerics.nonTypeNames.formUnion(f.genericParamNames) }
        localGenerics.memberLeaves = Set(localGenerics.memberReturns.keys.compactMap { $0.split(separator: ".").last.map(String.init) })
        localGenerics.fieldNames = Set(localGenerics.fieldParams.keys.compactMap { $0.split(separator: ".").last.map(String.init) })
    }
    // ── SOUNDNESS R1072 — A DEPENDENCY'S GENERIC TYPES, READ FROM ITS OWN SOURCES ───────────────────────────────
    //
    // `func f(_ b: Box<E>) { b.get().go() }` with `Box<V>` declared by a dependency: R1044's instantiation facts
    // are built from the SCANNED files only, so `get() -> V` answered nothing and the hop could only be disclosed
    // (R1066). Where the dependency's sources are readable (resolved `.build/checkouts`, a path dependency), the
    // same collector runs over them and the same facts — parameter order, which member/field is which parameter,
    // the inits — are offered to the files that IMPORT that module. A RESOLUTION, not a hedge: `E.go` is charged.
    //
    // Fenced so that a dependency fact never displaces or invents a local answer: a name the scan declares,
    // extends or already has facts for keeps the local reading; a name two imported dependency modules both
    // answer, or one module answers twice differently, answers nothing (the `lgOrderTmp` rule); platform
    // container names (`Array`, `Optional`, …) are never taken from a dependency; and only facts about a type,
    // never a free factory's return arguments, travel. Kill switch `CANDOR_R1072_OFF`.
    let r1072Off = DeclCollector.r1044bOff || DeclCollector.r1072Off
    var depLgByModule: [String: LocalGenericFacts?] = [:]
    func depGenericFacts(_ m: String) -> LocalGenericFacts? {
        if let c = depLgByModule[m] { return c }
        var out: LocalGenericFacts? = nil
        if let files = deps.moduleSwiftSources[m], !files.isEmpty {
            var order: [String: [String]?] = [:]
            var mrs: [(ty: String, leaf: String, param: String?)] = []
            var fps: [(ty: String, field: String, param: String)] = []
            var ins: [(ty: String, shape: LocalGenericInit)] = []
            var ok = true
            for path in files where path.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { ok = false; break }
                let tree = Parser.parse(source: text)
                let c = DeclCollector(file: "<dep:\(m)>/" + (path as NSString).lastPathComponent, tree: tree)
                c.walk(tree)
                c.finishBodyLocalTypes()
                for (k, v) in c.lgOrder {
                    if let e = order[k] { if e != v { order[k] = [String]?.none } } else { order[k] = v }
                }
                mrs.append(contentsOf: c.lgMemberReturns); fps.append(contentsOf: c.lgFieldParams); ins.append(contentsOf: c.lgInits)
            }
            if ok {
                var f = LocalGenericFacts()
                for (k, v) in order { if let o = v { f.order[k] = o } }
                var mr: [String: Int?] = [:]
                for (ty, leaf, g) in mrs {
                    guard let o = f.order[ty] else { continue }
                    let idx: Int? = g.flatMap { o.firstIndex(of: $0) }
                    let k = "\(ty).\(leaf)"
                    if let e = mr[k] { if e != idx { mr[k] = Int?.none } } else { mr[k] = idx }
                }
                for (k, v) in mr { if let i = v { f.memberReturns[k] = i } }
                var fp: [String: Int?] = [:]
                for (ty, fl, g) in fps {
                    guard let o = f.order[ty], let i = o.firstIndex(of: g) else { continue }
                    let k = "\(ty).\(fl)"
                    if let e = fp[k] { if e != i { fp[k] = Int?.none } } else { fp[k] = i }
                }
                for (k, v) in fp { if let i = v { f.fieldParams[k] = i } }
                for (ty, shape) in ins where f.order[ty] != nil { f.inits[ty, default: []].append(shape) }
                out = f
            }
        }
        depLgByModule[m] = out
        return out
    }
    let lgLocalNames = Set(localGenerics.order.keys).union(localTypes).union(declaredTypes)
        .union(PLATFORM_VALUE_TYPES).union(STDLIB_GENERIC_CONTAINERS)
    var lgByImports: [[String]: LocalGenericFacts] = [:]
    func localGenericsFor(file: String) -> LocalGenericFacts {
        guard !r1072Off else { return localGenerics }
        var closure = Set<String>(), queue = (fileImports[file] ?? []).filter {
            !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0) && !(ownTargetsByFile[file] ?? []).contains($0)
        }
        while let x = queue.popLast() {
            guard closure.insert(x).inserted else { continue }
            queue.append(contentsOf: deps.moduleReexports[x] ?? [])
        }
        let mods = closure.filter { !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0) }.sorted()
        if mods.isEmpty { return localGenerics }
        if let c = lgByImports[mods] { return c }
        var merged = localGenerics, owner: [String: String] = [:], poisoned = Set<String>()
        for m in mods {
            guard let f = depGenericFacts(m) else { continue }
            for (ty, o) in f.order where !lgLocalNames.contains(ty) {
                if let prev = owner[ty], prev != m { poisoned.insert(ty) } else { owner[ty] = m; merged.order[ty] = o }
            }
            for (k, i) in f.memberReturns {
                let ty = String(k[..<(k.lastIndex(of: ".") ?? k.endIndex)])
                if owner[ty] == m { merged.memberReturns[k] = i }
            }
            for (k, i) in f.fieldParams {
                let ty = String(k[..<(k.lastIndex(of: ".") ?? k.endIndex)])
                if owner[ty] == m { merged.fieldParams[k] = i }
            }
            for (ty, sh) in f.inits where owner[ty] == m { merged.inits[ty] = sh }
        }
        for ty in poisoned {
            merged.order[ty] = nil; merged.inits[ty] = nil
            merged.memberReturns = merged.memberReturns.filter { !$0.key.hasPrefix(ty + ".") }
            merged.fieldParams = merged.fieldParams.filter { !$0.key.hasPrefix(ty + ".") }
        }
        merged.memberLeaves = Set(merged.memberReturns.keys.compactMap { $0.split(separator: ".").last.map(String.init) })
        merged.fieldNames = Set(merged.fieldParams.keys.compactMap { $0.split(separator: ".").last.map(String.init) })
        if CallCollector.veinBProbe, merged.order.count != localGenerics.order.count {
            FileHandle.standardError.write("VBHIT\tR1072F\t\(file) +\(merged.order.count - localGenerics.order.count) types\n".data(using: .utf8)!)
        }
        lgByImports[mods] = merged
        return merged
    }
    // SOUNDNESS R990–R992 — THE DECLARED-TYPE FACTS, resolved once every file's aliases are known.
    // A container alias declared twice with different right-hand sides (two `#if` arms, two scopes sharing a
    // simple owner name) is POISONED rather than chosen: the same never-guess rule `returnsTmp` applies.
    var containerAliasTmp: [String: TypeSyntax?] = [:]
    for c in collectors {
        for (k, ts) in c.containerAliasDecls {
            for t in ts {
                if let existing = containerAliasTmp[k] {
                    if existing?.trimmedDescription != t.trimmedDescription { containerAliasTmp[k] = TypeSyntax?.none }
                } else { containerAliasTmp[k] = t }
            }
        }
    }
    var containerAliasIdx: [String: TypeSyntax] = [:]
    for (k, v) in containerAliasTmp { if let t = v { containerAliasIdx[k] = t } }
    // A name this scan DECLARES as a type is that type, never an alias — `dealias`'s shadow rule.
    let aliasExpander: (String?) -> ((String) -> TypeSyntax?) = { owner in
        { name in
            if localTypes.contains(name) { return nil }
            if let o = owner, let t = containerAliasIdx["\(o).\(name)"] { return t }
            return containerAliasIdx[name]
        }
    }
    // `returnFactsIdx` — leaf AND `Owner.leaf` -> the facts of the declared return clause. Every declaration
    // under one key must agree, or the key answers nothing: the leaf `mk` declared `-> [Ctx]` on one type
    // and `-> Int` on another is poisoned exactly as `returnsTmp` poisons it, and the `Owner.mk` keys are
    // what then still answer for each type.
    var returnFactsTmp: [String: DeclaredFacts?] = [:]
    if !DeclCollector.r991Off || !DeclCollector.r990Off {
        for c in collectors {
            for (k, ts) in c.returnDecls {
                let owner = k.contains(".") ? String(k.split(separator: ".").first!) : nil
                for (t, fnGens, scope) in ts {
                    var f = declaredFacts(t, expand: DeclCollector.r992Off ? nil : aliasExpander(owner))
                    // A fact that names a GENERIC PARAMETER (the function's, or — for a member — any type's
                    // of that simple name, since an extension does not repeat them) or `Self` describes no
                    // type: the key is POISONED, so it can neither answer nor be answered by a sibling.
                    var gens = fnGens.union(["Self"])
                    if let o = owner { gens.formUnion(typeGenericParamNamesAI[o] ?? []) }
                    else { for (_, ns) in typeGenericParamNamesAI { gens.formUnion(ns) } }
                    let named = [f.scalar, f.arrayElem, f.arrayElemNested, f.dictValue].compactMap { $0 }
                    if named.contains(where: { gens.contains($0) || gens.contains(String($0.split(separator: ".").first ?? "")) }) {
                        returnFactsTmp[k] = DeclaredFacts?.none
                        continue
                    }
                    // A SHARED simple type name is resolved in the DECLARING scope — `-> Builder` inside
                    // `extension _HashNode` is `_HashNode.Builder`, not swift-collections' `Rope.Builder` (the
                    // fabricated `Rand` this change's own A/B found on `TreeDictionary.filter`). The innermost
                    // enclosing type that nests the name wins; a unique name stays as written; an ambiguous one
                    // with no match in scope POISONS the key rather than choosing.
                    var unresolvable = false
                    func scoped(_ n: String?) -> String? {
                        guard let n, !n.contains("."), let paths = typePathsBySimple[n], paths.count > 1 else { return n }
                        var parts = (scope ?? "").split(separator: ".").map(String.init)
                        while !parts.isEmpty {
                            let cand = parts.joined(separator: ".") + "." + n
                            if localTypePaths.contains(cand) { return cand }
                            parts.removeLast()
                        }
                        if localTypePaths.contains(n) { return n }   // a top-level declaration of the name
                        unresolvable = true; return n
                    }
                    f.scalar = scoped(f.scalar); f.arrayElem = scoped(f.arrayElem)
                    f.arrayElemNested = scoped(f.arrayElemNested); f.dictValue = scoped(f.dictValue)
                    if unresolvable { returnFactsTmp[k] = DeclaredFacts?.none; continue }
                    if let existing = returnFactsTmp[k] {
                        if existing != f { returnFactsTmp[k] = DeclaredFacts?.none }
                    } else { returnFactsTmp[k] = f }
                }
            }
        }
    }
    var returnFactsIdx: [String: DeclaredFacts] = [:]
    for (k, v) in returnFactsTmp { if let f = v { returnFactsIdx[k] = f } }
    // (member-alias canonicalisation of `returnFactsIdx` happens below, once `memberTypeAliasesR915` exists)
    // R585 (b9) — and a leaf the ORDINARY returns index already answers is left to it: this map may
    // add a resolution where there was none, never replace one (the R584 additive rule).
    for (k, v) in metatypeReturnsTmp { if let t = v, returnsIdx[k] == nil { metatypeReturnsIdx[k] = t } }
    // `static let shared = factory()` — now that the returns index exists, resolve the factory's vended
    // type and record it as the field's type, so `let r = Type.shared` carries the REAL type (not the
    // static's own type — the review's free-factory singleton find). Only an UNAMBIGUOUS factory return
    // types it; an unknown leaf leaves the field unrecorded (the binder then clears rather than guessing).
    for (ty, field, leaf) in staticFactoryFields where fields[ty]?[field] == nil {
        if let vended = returnsIdx[leaf] { fields[ty, default: [:]][field] = (vended, false) }
    }
    // SOUNDNESS R915 (B) — A MEMBER ALIAS, RESOLVED IN THE SCOPE THAT DECLARED IT. `let parent: Parent`
    // inside `ObserveOnSink` names `ObserveOnSink.Parent`, and `fields` stores the spelling `Parent`, which
    // every reader then dealiased through the bare-name, last-writer-wins `typeAliases` — `Zip8` for all
    // seventy-five RxSwift sinks. Only an alias the owner declares ONE way is applied (two same-named
    // nested owners declaring it differently keep the release's answer), and only to a field whose
    // spelling is exactly that alias.
    let memberTypeAliasesR915: [String: [String: String]] = DeclCollector.r915BOff ? [:]
        : memberTypeAliasesAll.mapValues { $0.compactMapValues { $0.count == 1 ? $0.first : nil } }
    for (ty, aliases) in memberTypeAliasesR915 {
        for (fname, f) in fields[ty] ?? [:] {
            // A chain that ends on a dotted spelling nothing here declares (`Observers.KeyType`) is not
            // an answer; the release's bare-name reading stands.
            if let n = f.name, let u0 = aliases[n], u0 != n {
                if let u = memberAliasRecordable(resolveMemberAliasChain(u0, memberTypeAliasesR915), localTypes), u != n {
                    fields[ty]![fname] = (u, f.isFunction)
                }
            }
        }
    }
    // SOUNDNESS R990 — A RETURN SPELLED WITH THE OWNER'S MEMBER ALIAS IS RESOLVED IN THE OWNER'S SCOPE, exactly
    // as R915 (B) resolves a field above. `func synchronized_subscribe() -> Connection` inside RxSwift's
    // `ShareReplay1WhileConnected` names `ShareReplay1WhileConnected.Connection`; handed to the caller as the bare
    // spelling `Connection`, the caller dealiased it through the last-writer-wins name table — another class's
    // `Connection` — and the binding's member calls went to the wrong type (measured: `subscribe` lost `Clock`).
    // An alias the owner declares that does not resolve to a recordable type POISONS the key: a bare member
    // alias name is never an answer outside the scope that declared it.
    for k in Array(returnFactsIdx.keys) where k.contains(".") {
        let owner = String(k.split(separator: ".").first!)
        guard let aliases = memberTypeAliasesAll[owner], var f = returnFactsIdx[k] else { continue }
        var poisoned = false
        func canon(_ n: String?) -> String? {
            guard let n, aliases[n] != nil else { return n }
            if let u0 = memberTypeAliasesR915[owner]?[n],
               let u = memberAliasRecordable(resolveMemberAliasChain(u0, memberTypeAliasesR915), localTypes) { return u }
            poisoned = true; return n
        }
        f.scalar = canon(f.scalar); f.arrayElem = canon(f.arrayElem)
        f.arrayElemNested = canon(f.arrayElemNested); f.dictValue = canon(f.dictValue)
        if poisoned { returnFactsIdx.removeValue(forKey: k) } else { returnFactsIdx[k] = f }
    }
    // SOUNDNESS R999 — EACH FUNCTION'S PARAMETER TYPES BY ARGUMENT LABEL, the contextual type an implicit member
    // argument (`f(domain: .unix)`) is resolved against. Keyed by `simpleQual` (`f`, `T.f`, `T.init`); one entry
    // per overload. A parameter typed by a GENERIC parameter (the function's own, or its owner's) or `Self` has
    // no contextual type to give, and an owner's member alias is resolved in the owner's scope (as above).
    var implicitParamIdx: [String: [[(label: String, type: String?)]]] = [:]
    // A parameter's type NAME is resolved in the CALLEE's scope, the way Swift resolves it there: the innermost
    // enclosing type that nests a type of that name, else the one declared type of that name. A simple name
    // several types nest with none in scope is AMBIGUOUS and gives no context; a PROTOCOL gives none either (the
    // first corpus run's fabricated `dispatch:` hedges were nested `State`/`Error` spellings resolved out of
    // scope); a name no local type declares is a platform/dependency type and is kept as written.
    func scopedContextType(_ n: String, scope: String?, generics: Set<String>) -> String? {
        if generics.contains(n) || n == "Self" { return nil }
        if n.contains(".") { return protocolPaths.contains(n) ? nil : n }
        let paths = typePathsBySimple[n] ?? []
        if paths.isEmpty { return n }
        if let sc = scope {
            var parts = sc.split(separator: ".").map(String.init)
            while !parts.isEmpty {
                let cand = parts.joined(separator: ".") + "." + n
                if localTypePaths.contains(cand) {
                    return protocolPaths.contains(cand) ? nil : (paths.count == 1 ? n : cand)
                }
                parts.removeLast()
            }
        }
        guard paths.count == 1, let only = paths.first, !protocolPaths.contains(only) else { return nil }
        return n
    }
    if !CallCollector.r999Off {
        for f in allFns where !f.isAccessor && !f.paramLabels.isEmpty {
            var gens = f.genericParamNames.union(["Self"])
            if let o = f.enclosingType { gens.formUnion(typeGenericParamNamesAI[o] ?? []) }
            let byIndex = Dictionary(f.paramIndex.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
            var sig: [(label: String, type: String?)] = []
            for (i, label) in f.paramLabels.enumerated() {
                var t: String? = nil
                if let pn = byIndex[i], let ty = f.paramDeclTypes[pn] {
                    let facts = declaredFacts(ty)
                    if let sc = facts.scalar, !facts.isFunction, !gens.contains(sc),
                       !gens.contains(String(sc.split(separator: ".").first ?? "")) {
                        t = sc
                        if let o = f.enclosingType, let al = memberTypeAliasesAll[o], al[sc] != nil {
                            t = memberTypeAliasesR915[o]?[sc].flatMap {
                                memberAliasRecordable(resolveMemberAliasChain($0, memberTypeAliasesR915), localTypes) }
                        }
                        t = t.flatMap { scopedContextType($0, scope: f.enclosingTypePath ?? f.enclosingType, generics: gens) }
                    }
                }
                sig.append((label, t))
            }
            // An OVERLOAD's `simpleQual` carries its disambiguation (`pick(Top)`, `bind(…)#1`); the call site
            // spells only the name, and every overload under it must be asked.
            let key = String(f.simpleQual.prefix { $0 != "(" && $0 != "#" })
            implicitParamIdx[key, default: []].append(sig)
        }
    }
    // SOUNDNESS R999 — the `Type.member` keys this scan has a BODY for. An implicit member on a LOCAL type with
    // no such body is an enum case or a synthesized (memberwise) initialiser: nothing runs that the scan could
    // charge, and walking its qualified spelling only reaches the engine's missed-member fallback — which, in the
    // first corpus run, hedged `dispatch:` Unknowns over protocols the type merely conforms to.
    var implicitMemberUnits: Set<String> = []
    var memberUnitKeys: Set<String> = []   // SOUNDNESS R1032 — the same keys, unconditionally
    for f in allFns {
        // keyed `<type leaf>.<member>`: a member written in `extension Outer.Inner` has the simpleQual
        // `Outer.Inner.member`, and the context type is resolved to its leaf `Inner`
        let parts = String(f.simpleQual.prefix { $0 != "(" && $0 != "#" }).split(separator: ".").map(String.init)
        memberUnitKeys.insert(parts.suffix(2).joined(separator: "."))
    }
    if !CallCollector.r999Off { implicitMemberUnits = memberUnitKeys }
    // SOUNDNESS R1048 — local types the stdlib can ITERATE: a (transitive) conformance to an iteration protocol, or
    // a declared `next`/`makeIterator`/`makeAsyncIterator` body.
    var iterableLocalTypes: Set<String> = []
    for proto in STDLIB_ITERATION_PROTOCOLS { for t in subtypesOf[proto] ?? [] where localTypes.contains(t) { iterableLocalTypes.insert(t) } }
    for k in memberUnitKeys {
        let parts = k.split(separator: ".").map(String.init)
        if parts.count == 2, ["next", "makeIterator", "makeAsyncIterator"].contains(parts[1]), localTypes.contains(parts[0]) {
            iterableLocalTypes.insert(parts[0])
        }
    }
    // R73 — same deferred resolution for a module-scope global initialized by a bare factory call
    // (`let worker = makeWorker()`). Only an UNAMBIGUOUS project-wide factory return types it — an
    // ambiguous/unknown leaf leaves the global untyped, same "never guess" discipline as every other
    // consumer of `returnsIdx`.
    for (module, name, leaf) in globalFactories where globalTypesByModule[module]?[name] == nil {
        if let vended = returnsIdx[leaf] { globalTypesByModule[module, default: [:]][name] = vended }
    }
    // R85 — derive `publicGlobalTypesByModule` HERE, in the one place, now that both passes that can
    // populate `globalTypesByModule` (the per-file merge above and this factory-resolution loop) have
    // run. A name is visible cross-module iff it is in the public/open name set AND ended up with a
    // resolved type — a public factory (or destructured) global whose leaf never resolved (ambiguous or
    // unknown) correctly stays absent here too, the same "never guess" discipline `globalFactories`'
    // own resolution already documents. This single derivation is what makes the factory/destructure
    // binder shapes gain cross-module visibility for free: they write into the SAME two upstream tables
    // (`globalTypesByModule`, `globalPublicByModule`) the plain-identifier/direct-constructor shapes
    // always did, so nothing downstream of this line needs to know which binder shape produced a name.
    for (module, names) in globalPublicByModule {
        for n in names {
            if let t = globalTypesByModule[module]?[n] { publicGlobalTypesByModule[module, default: [:]][n] = t }
        }
    }
    // Conditional conformance of a USER generic type (`extension Box: Greeter2 where T: Greeter2`): now
    // that every file's `where`-clause bounds are merged into `typeGenericBoundsAll`, retry each field
    // DeclCollector could not resolve on its own single top-to-bottom pass (the extension supplying the
    // bound can sit later in the same file, or in a different file, relative to the field). Guarded on the
    // field STILL reading exactly the bare param name it was deferred under — if some other resolution
    // already overwrote it, that one wins, never this fallback. Without this, `Box(value: NetThing2())
    // .greet2()` under `extension Box: Greeter2 where T: Greeter2 { func greet2() { value.greet2() } }`
    // left `value` typed `"T"` forever (a name nothing declares), so the call inside never dispatched to
    // `Greeter2`'s conformers and a caller charged only via that field read silent-pure.
    // SOUNDNESS R578 — each protocol's PROPERTY requirements with their declared types, INHERITED ones
    // included (a `protocol Sub: Sup` receiver reads `Sup`'s requirements too); the protocol's own
    // declaration wins over an inherited one of the same name.
    var protoReqFieldTypesFlat: [String: [String: String]] = [:]
    for p in Set(protocolPropTypesAll.keys).union(protocolSupers.keys) {
        var out: [String: String] = [:], seen: Set<String> = [], frontier = [p]
        while let cur = frontier.popLast() {
            guard seen.insert(cur).inserted else { continue }
            for (m, t) in protocolPropTypesAll[cur] ?? [:] where out[m] == nil { out[m] = t }
            frontier.append(contentsOf: protocolSupers[cur] ?? [])
        }
        if !out.isEmpty { protoReqFieldTypesFlat[p] = out }
    }
    // SOUNDNESS R904 — the same walk for the requirement NAMES.
    var protoReqPropsFlat: [String: Set<String>] = [:]
    for p in Set(protocolPropNamesAll.keys).union(protocolSupers.keys) {
        var out: Set<String> = [], seen: Set<String> = [], frontier = [p]
        while let cur = frontier.popLast() {
            guard seen.insert(cur).inserted else { continue }
            out.formUnion(protocolPropNamesAll[cur] ?? [])
            frontier.append(contentsOf: protocolSupers[cur] ?? [])
        }
        if !out.isEmpty { protoReqPropsFlat[p] = out }
    }
    // SOUNDNESS R256 — fields whose param is bound BOTH ways; see CallCollector.genericCallableFields.
    var genericCallableFields: [String: Set<String>] = [:]
    for (ty, field, param) in unresolvedGenericFields where fields[ty]?[field]?.name == param {
        if let bound = typeGenericBoundsAll[ty]?[param] {
            fields[ty, default: [:]][field] = (bound, false)
            opaqueFields[ty, default: []].insert(field)
            if typeGenericFnParamsAll[ty]?.contains(param) == true { genericCallableFields[ty, default: []].insert(field) }
        } else if typeGenericFnParamsAll[ty]?.contains(param) == true {
            // R243 — the param is bound to a FUNCTION TYPE by a same-type requirement
            // (`extension Gen where F == (Int) -> Bool`), so the field HOLDS A CALLABLE. `(nil, true)` is
            // the exact spelling R178's alias completion below already normalises every other callable
            // field to, which is what makes `v.filter(op)` / `op()` disclose here the way a directly-typed
            // `let cb: (Int) -> Bool` does — one representation, one consumer (§F1.3). Before this,
            // `Gen.run` was ABSENT from `functions[]` over a real, executed file deletion.
            //
            // A DISCLOSURE, NOT A RESOLUTION: the field carries no visible body, so this yields the
            // `dispatch:`/`callback:` hedge, never a guess at which closure was stored. And it is
            // strictly narrower than charging an UNBOUNDED generic field — the +1,697-row over-charge
            // shape candor-java measured and rejected during R217 — because it fires only where a
            // requirement in the source SAYS the param is a function.
            fields[ty, default: [:]][field] = (nil, true)
        }
    }
    // ══ R178 — COMPLETE THE FUNCTION-TYPE ALIASES, IN ONE PLACE, BEFORE ANYTHING READS `isFunction` ══
    //
    // `typeName` peels `Optional`/`some`/`any` but knows nothing about typealiases, so `typealias Cb =
    // () -> Void` made every callable spelled through it read as a plain nominal type and its
    // `isFunction` flag FALSE. Three indexes carry that flag and all three were wrong together:
    // `fields[T][n]`, `FnInfo.fnTypedParams`/`fnTypedParamIndex`, and (in CallCollector) an annotated
    // local's `typeName(ann).isFunction`. Measured against the true v0.34.0 build AND HEAD, with ground
    // truth EXECUTED and a plainly-spelled twin as the control in every row: `Box.fireA` ABSENT while
    // `Box.fireP` disclosed `dispatch:Box.cbP`; `directAliasParam` ABSENT while `directPlainParam`
    // disclosed `callback:c`; `localAlias` ABSENT while `localPlain` disclosed `callback:l`.
    //
    // Done HERE rather than in DeclCollector because an alias CHAIN (`typealias Cb2 = Cb`) and the alias
    // itself may live in different files from the use — a single-file top-to-bottom pass cannot see
    // either. This is the same deferred-completion shape as `staticFactoryFields` and
    // `unresolvedGenericFields` directly above, for the same reason.
    //
    // THE FIX IS A COMPLETION, NOT A SECOND RESOLVER: each index ends up holding exactly what
    // DeclCollector would have written had it known — `(nil, true)` for a field, the name in
    // `fnTypedParams` WITH its position in `fnTypedParamIndex` for a parameter. So the alias spelling
    // and the plain spelling are byte-identical downstream rather than two paths that agree today.
    var fnTypeAliases = fnTypeAliasesRaw.subtracting(localTypes)   // a real type of the same name wins
    var aliasClosureChanged = true
    while aliasClosureChanged {                                    // `typealias Cb2 = Cb`, any depth
        aliasClosureChanged = false
        for (a, u) in typeAliases
        where !fnTypeAliases.contains(a) && !localTypes.contains(a) && fnTypeAliases.contains(u) {
            fnTypeAliases.insert(a); aliasClosureChanged = true
        }
    }
    if !fnTypeAliases.isEmpty {
        // A NAME THAT IS BOTH A CALLABLE FIELD AND A METHOD ON THE SAME TYPE IS NOT COMPLETED, and this
        // guard was written from a measurement, not from caution. swift-nio's `ClientBootstrap` declares
        // BOTH `private var channelInitializer: ChannelInitializerCallback` (Bootstrap.swift:814) and
        // `public func channelInitializer(_:) -> Self` (:888). Completing the field made the member-call
        // arm read `bootstrap.channelInitializer { … }` — the BUILDER METHOD, spelled with a trailing
        // closure — as an invocation of the field, so three callers (`TCPThroughputBenchmark.setUp`,
        // `makeHTTPChannel`, `<main>#8`) lost a real call edge and got a `dispatch:` hedge instead. The
        // effect sets happened not to move, which is exactly why the wide-key diff is the one to audit.
        // Where the two spellings collide, the pre-existing answer stands: this completion may add a
        // disclosure, never take an edge away.
        var methodNamesByType: [String: Set<String>] = [:]
        for f in allFns where !f.isAccessor && !f.isTopLevel {
            guard let ty = f.enclosingType else { continue }
            methodNamesByType[ty, default: []].insert(String(f.qual.split(separator: ".").last ?? ""))
        }
        for (ty, fs) in fields {
            for (name, info) in fs where !info.isFunction {
                guard methodNamesByType[ty]?.contains(name) != true else { continue }
                if let n = info.name, fnTypeAliases.contains(n) { fields[ty]![name] = (nil, true) }
            }
        }
        for i in allFns.indices {
            for (p, t) in allFns[i].params where fnTypeAliases.contains(t) {
                allFns[i].params.removeValue(forKey: p)
                allFns[i].fnTypedParams.insert(p)
                if let idx = allFns[i].paramIndex[p] { allFns[i].fnTypedParamIndex[p] = idx }
            }
        }
    }

    // An enum case binds a value type only when it is UNAMBIGUOUS project-wide (one assoc type) —
    // the same "never guess on an ambiguous leaf" discipline as the returns index.
    var enumCaseValueType: [String: String] = [:]
    for (cn, ts) in caseAssocAll where ts.count == 1 { enumCaseValueType[cn] = ts.first! }
    // SOUNDNESS R585 (b10) — the metatype twin, under the SAME unambiguity rule. A case name that is a
    // metatype in one enum and an ordinary type in another is ambiguous ACROSS the two maps, so it is
    // dropped from both rather than answered twice.
    var metatypeEnumCaseValueType: [String: String] = [:]
    for (cn, ts) in caseAssocMetatypeAll where ts.count == 1 && caseAssocAll[cn] == nil {
        metatypeEnumCaseValueType[cn] = ts.first!
    }
    // STRICTLY ADDITIVE, and the discarded alternative is worth naming. A case name that is a metatype
    // in one enum and an ordinary type in another is genuinely ambiguous, and POISONING BOTH maps is
    // the more correct answer — but it REMOVES an existing resolution, which is a different question
    // from the one R585 asks and the direction an A/B's removal column is where fixes go too far (§E1).
    // Filed as the assumption it is rather than folded in.

    var direct: [String: Set<String>] = [:]
    var edges: [String: Set<String>] = [:]
    var whyMap: [String: Set<String>] = [:]
    // THE SHARED CAP-AND-DISCLOSE DECISION for bounded CHA over a protocol's conformer set (SPEC §4's
    // ≤12 bound). "Is this conformer set small and non-empty enough to trust individually, or must the
    // dispatch be disclosed instead" was two independent copies below — the method-dispatch CHA
    // (`protoDispatches`) and the property/subscript-read CHA (`protoPropReads`) each re-derived the same
    // `count == 0 || count > 12` test with the polarity flipped (one written as `!isEmpty && count <= 12`
    // to gate resolving, the other as `isEmpty || count > 12` to gate disclosing). Same decision, same
    // reason string, two places it could silently drift apart if one were ever edited without the other.
    // Returns `true` when the caller may go on to resolve each conformer; on `false` it has ALREADY
    // disclosed `Unknown` with a `dispatch:` reason at `caller`, and the caller must resolve nothing more
    // for this dispatch — never both, never neither.
    let chaWithinBound: (Int, String, String, String) -> Bool = { count, proto, member, caller in
        if count == 0 || count > 12 {
            direct[caller, default: []].insert("Unknown")
            whyMap[caller, default: []].insert("dispatch:\(proto).\(member)")
            return false
        }
        return true
    }
    var hostsD: [String: Set<String>] = [:], cmdsD: [String: Set<String>] = [:]
    // SPEC §2 `fs` — DIRECT ONLY, deliberately, matching candor-java's `fsDirect` ("kind performed
    // directly"). It must NOT propagate over edges: a caller reaching one callee that writes and another
    // whose Fs kind is undetermined would inherit `["write"]` and thereby CLAIM "writes but never reads",
    // which is the partial-claim §2 forbids. Direct-only means `fs` answers a question about this
    // function's own calls, where every contributing verb was seen.
    var fsD: [String: Set<String>] = [:]
    var privKindD: [String: [String: Set<String>]] = [:]
    var pathsD: [String: Set<String>] = [:], tablesD: [String: Set<String>] = [:]
    var incompleteD: [String: Set<String>] = [:]   // fn -> effects with a structurally-incomplete surface (masking)
    var unreadableAliasArmFns: Set<String> = []   // R429 — see CallCollector.unreadableAliasArm
    var blindDirect: [String: Set<String>] = [:]    // fn -> blind modules it DIRECTLY reaches (per-fn `invisible`)
    /// ⟨0.39⟩ SPEC §4 obligation 1 — fn -> the abstraction MEMBERS it dispatches on, already in wire form
    /// (`<owning pkg>#<type path>.<member>`). DIRECT; `propagate`d over the call graph below, because the
    /// clause requires the member to REACH the caller transitively and a pure intermediary omitted breaks
    /// a consumer's walk one hop short.
    var dispatchDirect: [String: Set<String>] = [:]
    // The κ-unknown modules this code imports (the ledger's set, hoisted for per-fn `invisible` attribution):
    // not a platform-frontier module, not a κ tier, not an internal target — effects through them are
    // INVISIBLE. A module a chained sibling report COVERS is exempt (SPEC §2 rule 3): the report — even an
    // EMPTY one — is the producer's claim over that package, so a joined-nothing call into it reads pure,
    // not blind.
    //
    // `coveredPkgs`, NOT `isChained`, and that asymmetry is the whole of the 2026-07-27 fix. A report
    // §2.1 refused to trust is still CHAINED (its keys are looked up, so rule 2's `Unknown` downgrade
    // fires) but makes NO coverage claim, so the package it names stays blind HERE and a key it does not
    // answer keeps its `invisible` hedge instead of reading pure. See the rule-3 note in Deps.swift.
    // PER FILE. The global set answered "is this module internal to the SCAN"; the question every use
    // site actually asks is "is it invisible to THIS file", and those differ the moment a scan holds
    // more than one package. `importableByFile` carries the dependency-graph answer; a file with no
    // owning package gets an empty set, so nothing is claimed and everything it imports stays named.
    /// SOUNDNESS R827 — the modules a file can NAME: its own imports, plus whatever a COVERED dependency
    /// module re-exports (`@_exported import CShim` inside a chained Swift target). The report of the
    /// importing module covers its Swift bodies and none of the re-exported names, so an unqualified call
    /// that resolves to nothing may land in the re-exported module — and with only the covered import in
    /// view, the ledger read that silence as purity. Before R565 that dependency was UNCHAINED whenever
    /// its package name differed from the module, so the hedge named the importing module instead; this
    /// restores the hedge, on the module it belongs to, without unchaining the Swift half.
    ///
    /// Transitive, and only through COVERED modules: an uncovered import is already named itself.
    func effectiveImports(_ file: String) -> [String] {
        var out = fileImports[file] ?? []
        guard !deps.moduleReexports.isEmpty else { return out }
        var seen = Set(out)
        var queue = out.filter { deps.coversModule($0) }
        while let m = queue.popLast() {
            for r in (deps.moduleReexports[m] ?? []).sorted() where seen.insert(r).inserted {
                out.append(r)
                if deps.coversModule(r) { queue.append(r) }
            }
        }
        return out
    }
    func blindModules(inFile file: String) -> Set<String> {
        let importable = importableByFile[file] ?? []
        return Set(effectiveImports(file).filter {
            !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0) && !importable.contains($0)
                && !deps.coversModule($0) })      // R565 — the ledger asked a MODULE of a PACKAGE set
    }

    // COMPUTED HERE, NOT WHERE `importableByFile` IS BUILT. `fileImports` is filled by the collector
    // loop, which runs after it — so computing the ledger up there produced an EMPTY one, and every
    // fixture in the nine-round battery went silent at once. Caught by running that battery, which is
    // the entire argument for keeping it.
    // The ledger, as a union over files. A module is uncovered when SOME analyzed file imports it and
    // that file's own package cannot — which is the same question the per-function hedge asks, so the
    // two channels cannot drift apart the way they could while one read a global set. A file with no
    // owning package contributes every import it has: unknown provenance claims nothing.
    /// ⟨0.27⟩ CHAINED COVERAGE THAT NOBODY DECLARED — reported, never acted on.
    ///
    /// SPEC §2 rule 3 is explicit: a coverage disclosure treats EVERY package a loaded report covers as
    /// accounted for, even with zero joins. That is deliberately name-keyed and scan-global, and this
    /// engine obeys it. But it is the one place where a name alone can delete a disclosure, and the
    /// failure is silent: chain a report for a package your code does not use, have your code import a
    /// DIFFERENT module of that name, and an unresolved call into it reads pure. Measured on a package
    /// declaring no dependencies at all — `functions: []`, empty ledger, the calling function absent
    /// from the report entirely.
    ///
    /// So the situation is DISCLOSED rather than changed. A note is not a verdict, needs no floor bump,
    /// and cannot cost reach the way gating on it would (a package re-exported through a dependency is
    /// legitimately imported by code whose own manifest never names it).
    ///
    /// Only where the module is actually IMPORTED by a file whose target does not name it: a report for
    /// `swift-log` beside a target declaring the product `Logging` is the ordinary case, nobody imports
    /// `swift-log`, and warning about it would be the false disclosure this note exists to avoid.
    var coverageNotDeclared: [String: Set<String>] = [:]   // module -> files importing it
    var uncoveredCounts: [String: Int] = [:]
    // SOUNDNESS R827 REACH PROBE (§E1) — one line per (file, module) the R827 gates CHANGE: an import the
    // chain would have taken as covered (its owner is chained) but no Swift report can contain, and a
    // re-exported module the file never names. An unchanged A/B row is not evidence the branch ran.
    if ProcessInfo.processInfo.environment["CANDOR_R827_PROBE"] != nil {
        for (file, imports) in fileImports.sorted(by: { $0.key < $1.key }) {
            for m in imports where deps.notSwiftCoverable.contains(m)
                                   && deps.isChained(deps.notSwiftOwner[m] ?? deps.pkgOfModule(m)) {
                FileHandle.standardError.write("R827HIT \(file) \(m)\n".data(using: .utf8)!)
            }
            for m in effectiveImports(file).dropFirst(imports.count)
            where !deps.coversModule(m) && !PLATFORM_MODULES.contains(m) && !KAPPA_MODULES.contains(m) {
                FileHandle.standardError.write("R827RHIT \(file) \(m)\n".data(using: .utf8)!)
            }
        }
    }
    for file in fileImports.keys {
        let imports = effectiveImports(file)   // R827 — re-exported modules count too
        let importable = importableByFile[file] ?? []
        for m in imports where !PLATFORM_MODULES.contains(m) && !KAPPA_MODULES.contains(m)
                                && !importable.contains(m) {
            guard !deps.coversModule(m) else {   // R565
                // only a module the file ITSELF imports: a re-exported one is reached through a module
                // the target does declare, which is the ordinary case this note must not fire on.
                if let declared = declaredByFile[file], !declared.contains(m),
                   (fileImports[file] ?? []).contains(m) {
                    coverageNotDeclared[m, default: []].insert(file)
                }
                continue
            }
            uncoveredCounts[m, default: 0] += 1
        }
    }
    var locOf: [String: String] = [:]
    var entryPoints: Set<String> = []
    // resolved target -> each call site's (calling function, arg kinds). The CALLER travels with the
    // args now (⟨0.34⟩ fix): callback-flow used to judge a callback param across the UNION of every call
    // site into the target and then attribute the answer to the target's own node, which every caller
    // inherits via the ordinary call edge — so two callers passing two different named callbacks through
    // one HOF each inherited the OTHER's effect too. Resolution below is grouped by `caller` so each
    // caller is judged only against the sites IT makes.
    var callsiteArgs: [String: [(caller: String, args: [ArgKind])]] = [:]
    /// SOUNDNESS R951 — the argument TYPES at each resolved call site, beside `callsiteArgs`; and the
    /// comparison witnesses each unit needs from its caller's instantiation (`CallCollector.genericWitnessReqs`).
    var callsiteArgTypes: [String: [(caller: String, types: [String?], forward: [Int: Int], wit: (labels: [String?], types: [String?])?)]] = [:]
    var genericWitnessReqsByUnit: [String: Set<String>] = [:]
    var deferredCallbacks: [String: (indexes: Set<Int>, names: Set<String>)] = [:]

    /// SOUNDNESS R720 — the subset of `deferredCallbacks[fq].names` that has NO PARAMETER POSITION in
    /// `fq`'s own signature, so no call site of `fq` can ever address it: an annotated fn-typed LOCAL,
    /// or a fn-typed parameter of a NESTED function/closure collected into `fq`. Kept BESIDE `names`
    /// rather than taken out of it, because `names` is what the per-caller branch writes and the caller
    /// side must not move (see the note where this is filled). Read once, at the mark site.
    var undischargeableCallbacks: [String: Set<String>] = [:]

    /// ⟨0.39⟩ Which DEPENDENCY package owns an external type named in `file`, when that can be decided
    /// without guessing. Swift spells neither the owner at the type (`b: Backend`, not rust's
    /// `&dyn iface::Backend` or java's `iface.Backend b`) nor the module at the import (`import Iface`
    /// imports every name in it), so the owner is only derivable when the file leaves ONE candidate:
    /// an import that its own target DECLARES as a dependency, is not a platform/κ module, and is not a
    /// target this run analyzed. Two candidates refuse — the never-guess rule the whole dep index runs on
    /// — which costs a disclosure the engine did not have before and can never mint a charge.
    ///
    let r592Probe = ProcessInfo.processInfo.environment["CANDOR_R592_PROBE"] != nil
    /// SOUNDNESS R592 — AND A TARGET OF THE FILE'S OWN PACKAGE IS NOT A FOREIGN OWNER, ANALYZED OR NOT.
    /// `importable` is `declaredNames` INTERSECTED WITH `analyzedTargets`, and that intersection is the
    /// trap: it answers "did this run read it", not "is it ours". A C target has no `.swift` files, so no
    /// run ever reads one — `declared` holds it, `importable` never can, and it therefore survived every
    /// filter here as the file's sole "foreign" candidate.
    ///
    /// BOTH error directions were live, and the second is the one that costs a disclosure:
    ///   (a) MISATTRIBUTION — one surviving C target publishes `CNIOLinux#Swift.type`, a key whose
    ///       package half no producer's hash can equal, so obligations 1 and 2 can never be joined;
    ///   (b) SUPPRESSION — a C target sitting BESIDE the genuine foreign import makes `cands.count == 2`,
    ///       the never-guess rule fires, and the real owner's key is dropped outright.
    ///
    /// MEASURED at 96211f0 over 11 real packages, one variable — this filter — everything else held:
    /// 21,807 `dispatchesOn` occurrences, 4,952 foreign-prefixed, **4,880 of those (98.5%) prefixed with
    /// a C target of the package being scanned** (CNIOLinux 3,071, CNIOWindows 1,205, CNIOBoringSSL 587,
    /// CNIOAtomics 14, CNIOLLHTTP 3). At file granularity: 43 files published an owner, 40 of them naming
    /// a target of their own package; 19 files were suppressed, **every one of the 19 by a C target**, and
    /// one of those (`NIOSSL/NIOSSLHandler.swift`, `[CNIOBoringSSL, NIOTLS]`) is a genuine foreign owner
    /// this rule hands back.
    ///
    /// The exclusion cannot lose a real owner: if this package DECLARES a target of that name, SwiftPM
    /// resolves the import to the local target, so the name was never the dependency's to begin with.
    ///
    /// SOUNDNESS R593 — AND ONE MODULE IMPORTED TWICE IS ONE CANDIDATE. `fileImports` is a
    /// `[String: [String]]` — a LIST — and `cands.count == 1` was applied to it without dedup, so the
    /// never-guess rule fired on an ambiguity that does not exist. The cross-platform `#if` idiom
    /// produces it as a matter of course: swift-nio's `NIOFileSystem/FileInfo.swift` imports `CNIOLinux`
    /// under both `canImport(Glibc)` and `canImport(Musl)`, and **4 files in one corpus package were
    /// suppressed for this reason alone** (`FileInfo`, `FileDescriptor+Syscalls`, `Mocking`,
    /// `SystemFileHandle`). Deduping is a `Set`, and it must land AFTER R592 rather than before: on that
    /// corpus every duplicate is a C target of the scanning package, so deduping first would have
    /// published four MORE misattributed keys instead of none.
    func foreignOwnerModule(inFile file: String) -> String? {
        let declared = declaredByFile[file] ?? [], importable = importableByFile[file] ?? []
        let ownTargets = ownTargetsByFile[file] ?? []                              // R592
        let raw = (fileImports[file] ?? []).filter {
            declared.contains($0) && !importable.contains($0)
                && !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0)
        }
        let base = Set(raw)                                                        // R593
        let cands = base.subtracting(ownTargets)                                    // R592
        func verdict(_ s: Set<String>) -> String {
            s.count == 1 ? "PUBLISH:" + (s.first ?? "") : (s.isEmpty ? "NONE" : "SUPPRESS")
        }
        // REACH PROBES (§E1) — an unchanged row is not evidence either filter ran. Each prints only
        // where ITS OWN step changed the candidate set, with the verdict it changed FROM and TO.
        if r592Probe, cands.count != base.count {
            FileHandle.standardError.write(
                ("R592HIT file=\(file) dropped=\(base.intersection(ownTargets).sorted()) "
                 + "was=\(verdict(base)) now=\(verdict(cands))\n").data(using: .utf8)!)
        }
        if r592Probe, raw.count != base.count {
            FileHandle.standardError.write(
                ("R593HIT file=\(file) raw=\(raw.sorted()) deduped=\(base.sorted()) "
                 + "now=\(verdict(cands))\n").data(using: .utf8)!)
        }
        return cands.count == 1 ? cands.first : nil
    }
    // ── VEIN D (SOUNDNESS R774, R548's two-import half, R843(ii)'s member half) ──────────────────────────
    //
    // `foreignOwnerModule` answers "which module owns a foreign name" from the FILE alone, so a file that
    // imports two dependency modules refuses for EVERY name in it — and three things then go missing at
    // once with nothing disclosed: obligation 1's dispatch key, obligation 2's union entry, and ⟨0.40⟩'s
    // `supers`. Swift's own lookup is never ambiguous there (a bare type name two imported modules both
    // declare does not compile), so the refusal is a fact about this engine's evidence, not about the code.
    //
    // THE RELEASE ANSWER IS THE FLOOR. Every site below asks `foreignOwnerModule` first and keeps its
    // answer byte for byte; this is consulted only where that refused, and it answers only on a PROOF:
    //   · the candidates are ONE PACKAGE (R603's own rule, applied per file — the key is package-prefixed);
    //   · the PUBLISHED SURFACE: exactly one candidate package's chained report declares `<pkg>#<name>` in
    //     its ⟨0.40⟩ `types` — the authority `resolveForeign` already uses for `supers` (§F1.3);
    //   · the DEPENDENCY'S OWN SOURCES (an unchained scan): exactly one candidate module (re-exports
    //     followed) declares the name at file scope, it declares it `public`/`open`, and EVERY other
    //     candidate's sources were read in full and declare no such name. A candidate that cannot be read,
    //     is a C module, or holds a top-level macro expansion cannot be excluded, so it refuses.
    // Anything else stays refused — no key is ever minted from a guess.
    let veinDOff = ProcessInfo.processInfo.environment["CANDOR_VEIND_OFF"] != nil
    let veinDProbe = ProcessInfo.processInfo.environment["CANDOR_VEIND_PROBE"] != nil
    var moduleDeclCache: [String: (names: [String: Bool], opaque: Bool)?] = [:]
    func moduleDeclarations(_ m: String) -> (names: [String: Bool], opaque: Bool)? {
        if let c = moduleDeclCache[m] { return c }
        var out: (names: [String: Bool], opaque: Bool)? = nil
        if let files = deps.moduleSwiftSources[m], !files.isEmpty {
            var names: [String: Bool] = [:], opaque = false, ok = true
            for path in files {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { ok = false; break }
                let r = topLevelTypeDeclarations(source: text)
                for (n, v) in r.names { names[n] = (names[n] ?? false) || v }
                if r.opaque { opaque = true }
            }
            if ok { out = (names, opaque) }
        }
        moduleDeclCache[m] = out
        return out
    }
    /// The verdict of the owner proof. `proven` keys a wire entry; `undecided` carries every package that
    /// may own the name and is reached ONLY on evidence that the name IS a dependency's (some candidate
    /// declares it) — it is what the sites below DISCLOSE on; `none` is the release's refusal, unchanged.
    enum OwnerProof { case proven(String), undecided(Set<String>), none }
    /// The owning PACKAGE of the foreign type spelled `spelled` in `file`, for a file whose release vote
    /// refused (two or more candidate modules). Callers ask `foreignOwnerModule` first.
    ///
    /// Each candidate module (and every module it `@_exported import`s) is classified DECLARES / EXCLUDED /
    /// UNKNOWN for the spelling's leading name — from its sources when they are readable (which also says
    /// whether the declaration is `public`/`open`), else from its package's chained ⟨0.40⟩ `types`, else
    /// UNKNOWN. A C module, an unreadable target and a top-level macro expansion are UNKNOWN. PROVEN needs
    /// exactly one declaring package, nothing unknown, and — where the sources answered — a public
    /// declaration (an internal one is invisible to this file, so it can be a declarer for EXCLUSION
    /// purposes but never the proof). A chained report carries no access level, so a `types` key is
    /// accepted as the proof only where every candidate is accounted for.
    func ownerProof(of spelled: String, inFile file: String, site: String) -> OwnerProof {
        guard !veinDOff else { return .none }
        let declared = declaredByFile[file] ?? [], importable = importableByFile[file] ?? []
        let cands = Set((fileImports[file] ?? []).filter {
            declared.contains($0) && !importable.contains($0)
                && !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0)
        }).subtracting(ownTargetsByFile[file] ?? [])
        guard cands.count > 1 else { return .none }
        let segs = spelled.split(separator: ".").map(String.init)
        // A module-qualified spelling (`Dep.Type`) is not this proof's question: the release's handling
        // of it is left exactly as it was.
        guard let top = segs.first, !top.isEmpty, !(fileImports[file] ?? []).contains(top) else { return .none }
        var verdict: OwnerProof = .none
        var via = "-"
        let pkgs = Set(cands.map { deps.pkgOfModule($0) })
        let platformName = PLATFORM_REFINES[top] != nil || PLATFORM_LEAVES.contains(top)
            || PLATFORM_VALUE_TYPES.contains(top) || STD_SUPERS_PUBLIC.contains(top)
        if pkgs.count == 1, let p = pkgs.first {
            verdict = .proven(p); via = "onepkg"   // R603's rule, per file: the key is package-prefixed
        } else if !platformName {
            var closure = Set<String>(), queue = Array(cands)
            while let m = queue.popLast() {
                guard closure.insert(m).inserted else { continue }
                queue.append(contentsOf: deps.moduleReexports[m] ?? [])
            }
            var declares: [String: Bool] = [:]     // package -> declared PUBLICLY (nil access = from `types`)
            var unknown = Set<String>()
            var fromSurface = Set<String>()
            for m in closure.sorted() where !PLATFORM_MODULES.contains(m) && !KAPPA_MODULES.contains(m) {
                let p = deps.pkgOfModule(m)
                if !deps.notSwiftCoverable.contains(m), let d = moduleDeclarations(m), !d.opaque {
                    if let pub = d.names[top] { declares[p] = (declares[p] ?? false) || pub }
                } else if !deps.notSwiftCoverable.contains(m), deps.surface.typesPublishedPkgs.contains(p),
                          !deps.surface.distrustedPkgs.contains(p) {
                    // A trusted ⟨0.40⟩ manifest lists every type its package declares, so its silence
                    // EXCLUDES; a judged-nothing, stale or pre-⟨0.40⟩ copy is UNKNOWN (below), never a "no".
                    if deps.surface.typeKeysSeen.contains("\(p)#\(spelled)")
                        || deps.mentionedTypes.contains("\(p)#\(spelled)") {
                        declares[p] = declares[p] ?? false; fromSurface.insert(p)
                    }
                } else {
                    unknown.insert(p)
                }
            }
            if declares.count == 1, unknown.subtracting(declares.keys).isEmpty, let (p, pub) = declares.first,
               pub || fromSurface.contains(p) {
                verdict = .proven(p); via = fromSurface.contains(p) ? "surface" : "source"
            } else if !declares.isEmpty {
                verdict = .undecided(Set(declares.keys).union(unknown)); via = "evidence"
            } else if !unknown.isEmpty {
                // NO EVIDENCE the name is a dependency's at all (it may be a platform type), and a
                // candidate this run cannot see into: the release's refusal stands. Named for the probe.
                via = "unknown:\(unknown.sorted().joined(separator: ","))"
            }
        }
        if veinDProbe {
            let v: String
            switch verdict {
            case .proven(let p): v = "-> \(p)"
            case .undecided(let ps): v = "UNDECIDED \(ps.sorted())"
            case .none: v = "NONE"
            }
            FileHandle.standardError.write(
                ("VEIND \(site) file=\(file) name=\(spelled) cands=\(cands.sorted()) \(v) via=\(via)\n").data(using: .utf8)!)
        }
        return verdict
    }
    func provenOwnerPackage(of spelled: String, inFile file: String, site: String) -> String? {
        if case .proven(let p) = ownerProof(of: spelled, inFile: file, site: site) { return p }
        return nil
    }
    /// SOUNDNESS R1066 — THE BLIND DEPENDENCY MODULES OF `file` WHOSE OWN SOURCES PUBLICLY DECLARE THE TYPE `spelled`
    /// NAMES. Positive evidence only: a module (or one it `@_exported import`s) whose readable sources declare the
    /// name `public`/`open` at file scope. Empty where no source answers — an unreadable dependency, a platform
    /// type, a type this scan declares or extends (local wins) — and the release's silence then stands.
    ///
    /// NOT the ⟨0.39⟩ obligation-1 key, which is published for EVERY unresolved member call in a one-dependency
    /// file, platform receivers included (`Iface#Date.addingTimeInterval`). That key cannot be narrowed to make it
    /// evidence of the owner: where the dependency EXTENDS the platform type (`extension Date { func stamp() }`)
    /// the same spelling is the only carrier of the member's effect to a downstream consumer (measured: stripping
    /// it took `Fs` off the consumer, executed). So the key stays the floor, and ownership is asked here instead.
    let r1066Off = ProcessInfo.processInfo.environment["CANDOR_R1066_OFF"] != nil
    let r1066Probe = CallCollector.veinBProbe
    var sourceProvenCache: [String: Set<String>] = [:]
    func sourceProvenDepModules(of spelled: String, inFile file: String) -> Set<String> {
        let ck = "\(file)\u{0}\(spelled)"
        if let c = sourceProvenCache[ck] { return c }
        var segs = spelled.split(separator: ".").map(String.init)
        let imports = fileImports[file] ?? []
        var cands = blindModules(inFile: file).subtracting(ownTargetsByFile[file] ?? [])
        if segs.count > 1, imports.contains(segs[0]) {          // `Iface.Box`: the source named the module
            cands = cands.intersection([segs[0]]); segs.removeFirst()
        }
        var out = Set<String>(), direct = Set<String>()
        if let name = segs.first, !name.isEmpty, name.first?.isUppercase == true,
           !localTypes.contains(name), !declaredTypes.contains(name), !protocolMethods.keys.contains(name) {
            func declares(_ x: String) -> Bool {
                !PLATFORM_MODULES.contains(x) && !KAPPA_MODULES.contains(x) && moduleDeclarations(x)?.names[name] == true
            }
            for m in cands.sorted() {
                if declares(m) { direct.insert(m); continue }
                var closure = Set<String>(), queue = [m]
                while let x = queue.popLast() {
                    guard closure.insert(x).inserted else { continue }
                    queue.append(contentsOf: deps.moduleReexports[x] ?? [])
                }
                if closure.contains(where: declares) { out.insert(m) }
            }
        }
        // A module that declares the name itself is the owner; one that only RE-EXPORTS a declarer
        // (`_CryptoExtras` -> `Crypto`) is named only when no imported module declares it directly.
        if !direct.isEmpty { out = direct }
        sourceProvenCache[ck] = out
        return out
    }
    /// SOUNDNESS R1071 — the blind dependency modules of `file` whose readable sources declare a PUBLIC member
    /// `member` in an extension of the type `spelled` names (`extension Date { public func stamp() }`), for a
    /// receiver type the dependency does not itself declare — a PLATFORM type, typically. Same candidate set,
    /// re-export closure and direct-over-re-exporter rule as `sourceProvenDepModules`. The member is the
    /// dependency's only where the platform does not also declare it; that cannot be read here, so a match
    /// over-attributes in that case — an `invisible` naming a module the call may not reach, which is the
    /// direction a disclosure is allowed to err in, never a charge.
    let r1071Off = ProcessInfo.processInfo.environment["CANDOR_R1071_OFF"] != nil
    var moduleExtCache: [String: [String: [String: Bool]]?] = [:]
    func moduleExtensionMembers(_ m: String) -> [String: [String: Bool]]? {
        if let c = moduleExtCache[m] { return c }
        var out: [String: [String: Bool]]? = nil
        if let files = deps.moduleSwiftSources[m], !files.isEmpty {
            var all: [String: [String: Bool]] = [:], ok = true
            for path in files where path.hasSuffix(".swift") {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { ok = false; break }
                for (t, ms) in topLevelExtensionMembers(source: text).members {
                    for (n, v) in ms { all[t, default: [:]][n] = (all[t]?[n] ?? false) || v }
                }
            }
            if ok { out = all }
        }
        moduleExtCache[m] = out
        return out
    }
    func sourceExtendingDepModules(of spelled: String, member: String, inFile file: String) -> Set<String> {
        guard !r1071Off else { return [] }
        var segs = spelled.split(separator: ".").map(String.init)
        let imports = fileImports[file] ?? []
        var cands = blindModules(inFile: file).subtracting(ownTargetsByFile[file] ?? [])
        if segs.count > 1, imports.contains(segs[0]) { cands = cands.intersection([segs[0]]); segs.removeFirst() }
        guard let name = segs.last, name.first?.isUppercase == true else { return [] }
        func extends(_ x: String) -> Bool {
            !PLATFORM_MODULES.contains(x) && !KAPPA_MODULES.contains(x) && moduleExtensionMembers(x)?[name]?[member] == true
        }
        var out = Set<String>(), direct = Set<String>()
        for m in cands.sorted() {
            if extends(m) { direct.insert(m); continue }
            var closure = Set<String>(), queue = [m]
            while let x = queue.popLast() {
                guard closure.insert(x).inserted else { continue }
                queue.append(contentsOf: deps.moduleReexports[x] ?? [])
            }
            if closure.contains(where: extends) { out.insert(m) }
        }
        return direct.isEmpty ? out : direct
    }
    /// SOUNDNESS R532 — THE ABSTRACTION A RECEIVER SPELLING NAMES, once a GENERIC PARAMETER has been
    /// resolved to its bound. `nil` means "publish nothing for this receiver".
    ///
    /// ⟨0.39⟩ obligation 1 turns `call.extOwner` — the receiver's spelled type — into a wire key. For
    /// `func useIt<T: Handler>(_ h: T) { h.handle() }` that spelling is `T`, so the engine published
    /// `Iface#T.handle`: a key naming a type the owning package does not have, which is the
    /// `DepLib#String.lowercased` class the rung's own commit message names, AND a lost charge, because
    /// no producer can publish under the CONSUMER's type-parameter name. MEASURED at 0.39.0, one
    /// variable — the parameter's spelling — everything else held identical: `_ h: Handler` gives
    /// `inferred: [Net]` and `deny Net` exit 1; `<T: Handler>(_ h: T)` gives `inferred: []`,
    /// `dispatchesOn: [Iface#T.handle]` and exit 0, over the same dependency and the same conformer.
    /// The LOCAL-protocol path has resolved the bound since R26 (`solo#Handler.handle` for both
    /// spellings), so this is two implementations of one question that drifted — F1.3 — and only the
    /// newer one is on the wire.
    ///
    /// THE RESOLUTION IS SOUND FOR THIS KEY AND NOT FOR THE CHA EDGE LOOP BESIDE IT, which is why it is
    /// applied here and not by rewriting the receiver's type. `<T: P>` is monomorphized by the CALLER, so
    /// this package's own conformers are NOT the witness set (the argument is written out at
    /// `DeclCollector.collect`'s `some P` branch and was measured on 14 targets); the KEY, by contrast,
    /// says only "this row dispatches on `P.member`", which every instantiation of `T` does by the
    /// declaration's own constraint. Identical to what the rung already publishes for `any P`/`_ : P`.
    ///
    /// A bound that is LOCAL, a std-pure protocol, or a raw-value base returns nil rather than a key:
    /// a local abstraction is the in-scan CHA's question, and the other two are the fabrication
    /// carve-outs the call site beside this one already applies to a non-generic owner. Refusing is the
    /// same posture `foreignOwnerModule` takes on an undecidable owner — never a key nobody can answer.
    ///
    /// SOUNDNESS R550 — AND THE BOUND IS NOT ALWAYS THE FUNCTION'S. `FnInfo.genericBounds` is built by
    /// `DeclCollector` from a `FunctionDecl`/`InitializerDecl`'s OWN generic clause and `where` clause, so
    /// `struct Box<B: Backend> { func f(_ b: B) { b.size() } }` — the bound declared on the ENCLOSING TYPE
    /// — was invisible HERE, at the one site ⟨0.39⟩ spells a receiver onto the wire. R532 therefore closed
    /// one spelling of its own class and left the sibling open (§A.2: the fixture inherits the blind spot
    /// of the report, and the report named a function-level bound). `typeGenericBoundsAll` is the merged,
    /// scan-global answer to "is this name a bounded generic parameter of that type", already built above
    /// for `unresolvedGenericFields` — the same question, one index, not a second copy of it (§F1.3).
    ///
    /// IT WAS A LOST EFFECT, NOT ONLY A BAD KEY, because the §2 chained join below keys on THIS function
    /// too. MEASURED before the fix, one variable — where `B: Backend` is written — the dependency, the
    /// conformer, the consumer text and the binary all held identical:
    /// `func appSize<B: Backend>(_ b: B)` → `inferred [Net]`, `dispatchesOn [Iface#Backend.size]`,
    /// `deny Net` exit 1; `struct Box<B: Backend>` → `inferred []`, `dispatchesOn [Iface#B.size]`, exit 0
    /// over a call reaching a third package's `URLSession.dataTask`.
    ///
    /// THE FUNCTION'S OWN BOUND STILL WINS, because a method may shadow its type's parameter name; and an
    /// UNBOUND type parameter is deliberately not handled — `b.size()` on a `B` with no constraint does
    /// not type-check in Swift, so that branch has no reachable input to be tested with (§E3).
    ///
    /// SOUNDNESS R555 — AND THE `localTypes` GUARD BELOW CANNOT FIRE FOR A PROTOCOL, which is nearly
    /// every bound a dispatch has. `pushType` fills `localTypes` from class/struct/enum/actor/extension
    /// and DELIBERATELY not from `ProtocolDecl` (a protocol in `conformers` would pollute the CHA), so
    /// the doc paragraph above — "a bound that is LOCAL … returns nil" — described a check with no
    /// reachable input for the case it was written for. It is left as it is rather than widened,
    /// because REFUSING is the wrong remedy: `subtypesOf["T"]` is empty for a type parameter, so the
    /// in-scan CHA this function defers to never runs on this spelling and dropping the key loses the
    /// chain outright. The OWNERSHIP is what was wrong, and it is fixed where the key is SPELLED — see
    /// the publish site's R555 comment. This function keeps one job: name the abstraction.
    let r550Probe = ProcessInfo.processInfo.environment["CANDOR_R550_PROBE"] != nil
    let r555Probe = ProcessInfo.processInfo.environment["CANDOR_R555_PROBE"] != nil
    /// SOUNDNESS R836 §1b KILL SWITCH — restores the chained-only gate on a guessed owner's disclosure, so
    /// a standalone producer's row falls silent again and the three-package-chain tests go red.
    let r836Off = ProcessInfo.processInfo.environment["CANDOR_R836_OFF"] != nil
    let r836Probe = ProcessInfo.processInfo.environment["CANDOR_R836_PROBE"] != nil
    /// SOUNDNESS R859 §1b KILL SWITCH and reach probe — see the R859 arm after the R705 disclosure.
    let r859Off = ProcessInfo.processInfo.environment["CANDOR_R859_OFF"] != nil
    let r859Probe = ProcessInfo.processInfo.environment["CANDOR_R859_PROBE"] != nil
    /// SOUNDNESS R706 §1b KILL SWITCH (and `CANDOR_VT_OFF`) and reach probe (under `CANDOR_VEINB_PROBE`).
    let r706Off = DeclCollector.vtOff || ProcessInfo.processInfo.environment["CANDOR_R706_OFF"] != nil
    let r706iOff = ProcessInfo.processInfo.environment["CANDOR_R706I_OFF"] != nil   // SOUNDNESS R706 residual
    let r706iProbe = CallCollector.veinBProbe
    let r706Probe = CallCollector.veinBProbe
    /// SPEC ⟨0.25⟩ at the cross-package join: §1b kill switch (restores drop-on-ambiguity) and reach probe.
    let joinUnionOff = ProcessInfo.processInfo.environment["CANDOR_JOIN_UNION_OFF"] != nil
    let joinUnionProbe = ProcessInfo.processInfo.environment["CANDOR_JOIN_UNION_PROBE"] != nil
    let joinDebug = ProcessInfo.processInfo.environment["CANDOR_JOIN_DEBUG"] != nil
    /// SOUNDNESS R910 §1b KILL SWITCH and reach probe — see `askOwnKey`.
    let r910Off = ProcessInfo.processInfo.environment["CANDOR_R910_OFF"] != nil
    let r910Probe = ProcessInfo.processInfo.environment["CANDOR_R910_PROBE"] != nil
    let r849Off = ProcessInfo.processInfo.environment["CANDOR_R849_OFF"] != nil
    /// SOUNDNESS R847 / R850 — THE BARE-NAME DEPENDENCY JOIN KEEPS v0.39.2'S `pkg#<leaf>` LOOKUP, AND THE
    /// ONLY REMOVAL IS ONE THAT IS A PROOF UNDER SWIFT'S OWN LOOKUP: a name a BINDER holds in the current
    /// lexical scope (`binderShadow`, a case payload) is that local and nothing else — the callers skip it
    /// (`depGlobalReads`, `argBoundLocal`) before this is asked. nio-http2's `while let next = it.next() {
    /// … next.count … }` joined `swift-nio#next` (`BufferedStream.Iterator.next()`, `Env`) that way.
    ///
    /// EVERY OTHER CONDITION TRIED WAS A DECISION BY NAME, AND NONE IS A PROOF. R847's supertype walk saw
    /// only the CONSUMER's edges (R848: a member one hop up inside the dependency went ABSENT); `ad95c22`'s
    /// "a local type declares a member of that name" and "the scan has a global or free function of that
    /// name" are defeated by Swift itself — member lookup gathers EVERY overload of a base name across the
    /// hierarchy (a local `grandTok(_ x: Int)` does not hide the inherited `grandTok`), a member always
    /// shadows a module-level name, and a local protocol-extension default is one more candidate, not a
    /// replacement (R850, all executed 1/1 -> 0/0). The consumer has neither the dependency's signatures
    /// nor its supertype edges (SOUNDNESS R843), so a name-based removal cannot meet the bar. The leaf is
    /// kept, with the false charges it has always carried.
    func bareNameDepEntry(_ p: String, _ name: String, _ f: FnInfo) -> DepEntry? {
        deps.lookup("\(p)#\(name)")
    }
    /// SOUNDNESS R849 — the named module's package ANSWERED (R846) and another chained package answers the
    /// SAME key. The report cannot say whether that other entry is a member of the other package's own
    /// same-named type (R846's fabrication, not to be charged) or an `extension` of the named type — an
    /// overload the source may be calling (ThirdKit's `extension RatesCore.Client { func fetch(_:) }`,
    /// executed Fs, silent). Neither the dependency's overload signatures nor its declared-vs-extended types
    /// reach the consumer, so it DISCLOSES rather than choose, naming the member.
    func discloseOtherAnswers(_ key: String, tiers: [[(p: String, mods: [String])]], why: String, _ qual: String) {
        guard !r849Off, tiers.count == 2 else { return }
        let named = Set(tiers[0].map { $0.p })
        for (p, _) in tiers[1] where !named.contains(p) && deps.lookup("\(p)#\(key)") != nil {
            direct[qual, default: []].insert("Unknown")
            whyMap[qual, default: []].insert(why)
            return
        }
    }
    /// SOUNDNESS R846 — the chained packages a key is asked of, PREFERRING the one the source named. When
    /// the receiver's type was spelled `RatesCore.Client`, `RatesCore`'s package is asked first; if it
    /// ANSWERS, that answer stands alone (the source said which `Client`). If it does not, every chained
    /// package is asked, because a member can live in a DIFFERENT module than its type — an `extension
    /// RatesCore.Client` in a third package publishes under that package's name — and restricting there
    /// would be the silent direction. Two tiers; the caller stops at the first that answers.
    func joinTiers(_ file: String, module: String?) -> [[(p: String, mods: [String])]] {
        let all = deps.chainedPkgs(importing: fileImports[file] ?? []).map { (p: $0.0, mods: $0.1) }
        guard let m = module else { return [all] }
        let named = all.filter { $0.mods.contains(m) || deps.pkgOfModule(m) == $0.p }
        return named.isEmpty || named.count == all.count ? [all] : [named, all]
    }
    func dispatchAbstraction(_ owner: String, _ f: FnInfo) -> String? {
        let typeBound = f.enclosingType.flatMap { typeGenericBoundsAll[$0]?[owner] }
        // REACH PROBE (§E1) — "CHANGED 0 is not evidence until REACH is measured". Fires only on the arm
        // this change ADDS, so an A/B over a corpus containing none of the shape says so out loud instead
        // of reporting a flattering zero. Same channel and same shape as `CANDOR_TYPESURFACE_DEBUG`.
        if r550Probe, typeBound != nil, f.genericBounds[owner] == nil {
            FileHandle.standardError.write(
                "R550HIT \(f.qual) \(owner)->\(typeBound!)\n".data(using: .utf8)!)
        }
        guard let bound = f.genericBounds[owner] ?? typeBound else { return owner }  // not a type parameter
        guard !localTypes.contains(bound), !STD_PURE_PROTOCOLS.contains(bound),
              !RAW_VALUE_BASE_TYPES.contains(bound) else { return nil }
        return bound
    }
    /// ⟨0.39⟩ OBLIGATION 2 — the abstractions this package implements that it does NOT own, each with the
    /// dependency package that DOES. Anything local (a protocol declared here, a superclass declared here)
    /// is excluded: it is already keyed under this package. A name whose owner cannot be decided is
    /// OMITTED, not keyed under this package — candor-rust published nine `io#Write::write_all` rows
    /// naming a package that does not exist before it added the manifest filter, and a key no consumer can
    /// join is worse than an absent one because it looks like an answer.
    var abstractionOwnerPkg: [String: String] = [:]
    var abstractionUndecidedPkgs: [String: Set<String>] = [:]   // VEIN D — see the obligation-2 vote below
    for (pn, files) in conformanceFiles {
        // LOCAL WINS, and on three indexes rather than one. The two error directions cost differently:
        // keying a genuinely local abstraction under a DEPENDENCY would publish a union entry into
        // someone else's namespace, where a same-named abstraction's consumer could join it — a
        // fabricated charge. Keying a foreign one under OURS only ever produces a key nobody asks for.
        if protocolPaths.contains(pn) || localTypePaths.contains(pn) || localTypes.contains(pn) {
            abstractionOwnerPkg[pn] = pkgName
        } else {
            // R565 — ⟨0.39⟩ obligation 2 says the key is "fully qualified in the OWNING package's
            // namespace, the same namespace that package's entry hashes use". `foreignOwnerModule`
            // answers with a MODULE, so every foreign union entry this engine published was keyed under
            // a name no producer's hash prefix can equal and no consumer could join.
            // SOUNDNESS R603 — AND THE VOTE IS COUNTED IN PACKAGES, NOT MODULES. This gate is the
            // never-guess rule: two owners for one abstraction refuse rather than pick. But it was
            // counting MODULES while the thing it assigns is a PACKAGE, so a consumer conforming to one
            // dependency's protocol across two files that import two modules OF THAT SAME PACKAGE —
            // `import NIOTLS` here, `import NIOFoundationCompat` there, both `swift-nio` — read as two
            // owners and dropped the entry. That is R565's module-vs-package confusion at the one site
            // R565 did not reach, and `Deps.chainedPkgs` already carries the identical rationale for the
            // join half ("a loss manufactured by the fix, on exactly the multi-module dependencies the
            // fix exists for"). `pkgOfModule` is that same authority, not a second copy of it.
            //
            // MEASURED on nio-ssl + its 6 resolved checkouts, one variable — this line: R592 un-suppressed
            // `NIOSSL/NIOSSLHandler.swift` to `NIOTLS`, its sibling conformance file already answered
            // `NIOFoundationCompat`, and **36 `swift-nio#ChannelInboundHandler.*` union entries carrying
            // real effects** (`Env`/`Net`/`Fs`/`Unknown`) vanished. Deduping by package restores all 36.
            //
            // NOTE WHERE THIS CANNOT FIRE, deliberately: in an UNCHAINED scan `pkgOfModule` falls back to
            // the module name, so `pkgs == mods` and the verdict is unchanged. The fix moves only the arm
            // where the index actually knows which package a module belongs to — which is the only arm in
            // which the key it publishes could have been joined anyway.
            let mods = Set(files.compactMap { foreignOwnerModule(inFile: $0) })
            var pkgs = Set(mods.map { deps.pkgOfModule($0) })
            // VEIN D (R774) — ONLY where the release refused in EVERY conformance file: the per-file proof.
            // A file the release answered is never re-asked, so no package the release assigned can move.
            // Every file must PROVE the same one package; a file left UNDECIDED (on evidence that the name
            // is a dependency's) makes the abstraction undecided, and main.swift then publishes an
            // `Unknown` union entry under each package that may own it — a disclosure where the release
            // published nothing and the chained consumer's join read the miss as purity.
            if pkgs.isEmpty, !veinDOff {
                var proven = Set<String>(), possible = Set<String>()
                for file in files.sorted() {
                    switch ownerProof(of: pn, inFile: file, site: "obl2") {
                    case .proven(let p): proven.insert(p)
                    case .undecided(let ps): possible.formUnion(ps)
                    case .none: break
                    }
                }
                if possible.isEmpty, proven.count == 1 { pkgs = proven }
                else if !possible.isEmpty || proven.count > 1 {
                    abstractionUndecidedPkgs[pn] = possible.union(proven)
                }
            }
            // REACH PROBE (§E1) — this line is INERT wherever `modulePkgs` is empty (no readable
            // dependency manifest), so a 0-diff A/B over such a corpus proves nothing about it. Fires
            // exactly where the module count and the package count disagree, which is the whole change.
            if r592Probe, pkgs.count != mods.count {
                FileHandle.standardError.write(
                    ("R603HIT abstraction=\(pn) mods=\(mods.sorted()) pkgs=\(pkgs.sorted())\n")
                        .data(using: .utf8)!)
            }
            if pkgs.count == 1, let p = pkgs.first { abstractionOwnerPkg[pn] = p }
        }
    }
    /// ⟨0.39⟩ OBLIGATION 3, HALF 2 — THIS CONSUMER'S OWN VISIBLE IMPLEMENTORS of the abstraction a
    /// chained key names, edged as ordinary calls so their effects flow through the same fixpoint
    /// everything else does. `key` is a wire key, `<owning pkg>#<type path>.<member>`.
    ///
    /// GATED ON THE ABSTRACTION BEING THE SAME ONE. `conformers` is keyed on the spelled inheritance
    /// path, so a consumer with its own unrelated `protocol Backend` would otherwise have ITS conformers
    /// charged to a call dispatching the DEPENDENCY's `Backend` — a minted edge, which §4 lists as
    /// fabrication. `abstractionOwnerPkg` answers "whose abstraction is the one I conform to", using the
    /// same owner resolution the PRODUCER side keys its union entries with, so the two ends cannot drift.
    func unionOwnImplementors(forKey key: String, to qual: String) {
        guard let hashSep = key.firstIndex(of: "#") else { return }
        let keyPkg = String(key[key.startIndex..<hashSep])
        let path = String(key[key.index(after: hashSep)...])
        guard let dot = path.lastIndex(of: "."), abstractionOwnerPkg[String(path[..<dot])] == keyPkg
        else { return }
        let proto = String(path[..<dot]), member = String(path[path.index(after: dot)...])
        let conf = conformers[proto] ?? []
        guard !conf.isEmpty else { return }
        // SPEC §4's shared bound, through the SAME decision the in-scan protocol CHA makes rather than a
        // second copy of it: too many implementors is disclosed indeterminacy, never a partial union read
        // as the whole set. `chaWithinBound` discloses on `false` itself.
        guard chaWithinBound(conf.count, proto, member, qual) else { return }
        for c in conf { edges[qual, default: []].formUnion(resolveQual("\(c).\(member)")) }
    }

    // THE ONE APPLY SITE for a chained dependency entry (SPEC §2). It was three, and they had drifted:
    // the chained-GLOBAL read carried the effects, `hosts`, `cmds` and `paths` and silently dropped
    // `tables`, `invisible` and `incomplete`. So a consumer that reached a dependency's effectful lazy
    // global inherited the EFFECT and not the dependency's own honesty markers — its blind-module
    // disclosure vanished, and its masking-incompleteness with it, which is precisely the case SPEC §2
    // names: a benign literal in the consumer must not certify what the dependency declared
    // uncertifiable. candor-rust found three drifted copies of this (7cb5748) and candor-java two
    // (6ab26e4) by asking the same question, so it is a duplication defect and not a swift accident.
    // Every field of `DepEntry` a consumer can inherit is applied HERE and nowhere else; adding one to
    // `DepEntry` and not to this function is the next instance of the same bug.
    func applyDepEntry(_ de: DepEntry, to qual: String) {
        // ⟨0.39⟩ OBLIGATION 3 — THE JOIN UNIONS, PER KEY. A worklist rather than recursion because a
        // chained entry reached through `dispatchesOn` may itself dispatch (the abstraction's owner is not
        // always the implementor's owner — that is R504's four-package chain), and Swift's local functions
        // cannot be mutually recursive. `seenKeys` makes it terminate on a cyclic chain and idempotent on
        // a diamond, which matters because the whole index is built on union being commutative and
        // associative (ENTRY-COLLISION-DECISION.md).
        var pending = [de]
        var seenKeys = Set<String>()
        while let cur = pending.popLast() {
            direct[qual, default: []].formUnion(cur.effects)
            if cur.effects.contains("Unknown") {
                if let why = cur.whyReason { whyMap[qual, default: []].insert(why) }
                // ⟨0.19⟩ the dependency's OWN reason tokens travel too, so the reason CLASS survives the
                // boundary and `deny E Unknown[<class>]` is not silently inert on a chained consumer.
                // `dep:<hash>` above names WHERE; these name WHY. See DepEntry.whyClasses.
                whyMap[qual, default: []].formUnion(cur.whyClasses)
            }
            hostsD[qual, default: []].formUnion(cur.hosts)
            cmdsD[qual, default: []].formUnion(cur.cmds)
            pathsD[qual, default: []].formUnion(cur.paths)
            tablesD[qual, default: []].formUnion(cur.tables)
            if !cur.invisible.isEmpty { blindDirect[qual, default: []].formUnion(cur.invisible) }
            if !cur.incomplete.isEmpty { incompleteD[qual, default: []].formUnion(cur.incomplete) }
            if joinDebug {   // REACH/diagnosis (§E1): which entry, reached through which key, charged whom
                FileHandle.standardError.write("JOINAPPLY \(qual) why=\(cur.whyReason ?? "-") eff=\(cur.effects.sorted())\n".data(using: .utf8)!)
            }
            for k in cur.dispatchesOn where seenKeys.insert(k).inserted {
                if joinDebug { FileHandle.standardError.write("JOINKEY \(qual) \(k) hit=\(deps.lookup(k) != nil)\n".data(using: .utf8)!) }
                // (a) EVERY CHAINED ENTRY CARRYING THAT KEY. One `lookup`, because the index has already
                // UNIONED the contributors filed under it — which is precisely the ⟨0.25⟩ ambiguous-key
                // rule ⟨0.39⟩ says it is reusing: this adds a contributor, not a resolution rule.
                if let e = deps.lookup(k) { pending.append(e) }
                // (b) …AND THIS CONSUMER'S OWN VISIBLE IMPLEMENTORS — see `unionOwnImplementors`.
                unionOwnImplementors(forKey: k, to: qual)
            }
        }
    }

    /// SOUNDNESS R910 — THE §2 JOIN ASKS THE KEY UNDER ITS OWNER'S PACKAGE, NOT ONLY UNDER THE CHAINED ONES.
    ///
    /// `joinTiers` forms `<p>#<owner>.<member>` only for packages that are chained AND imported. A protocol
    /// requirement's answer is the `interfaceUnion` entry a CONFORMER's report publishes under the
    /// PROTOCOL OWNER's prefix (obligation 2) — so where the owner's package is not chained, that entry
    /// (`ProtoPkg#Backend774.run`, from IfaceDep's report) sat in the index and nothing asked for it.
    /// Measured: App importing ProtoPkg + IfaceDep, chained on IfaceDep only — `useBackend774` `[]`,
    /// `deny Fs` and `deny Unknown` exit 0, executed writing the file; chained on both, `['Fs']`, exit 1.
    /// The asymmetry is the tell: `applyDepEntry` already asks a DEPENDENCY entry's `dispatchesOn` key by
    /// exact string, wherever its package sits; the consumer's own call, which PUBLISHES that same key
    /// (obligation 1), never asked it.
    ///
    /// THE OWNER IS THE ONE OBLIGATION 1 ALREADY DECIDES — `foreignOwnerModule`, else vein D's
    /// `ownerProof` — never a new guess, and nil for anything this package declares. A `<pkg>#` key is in
    /// the index only if a chained report published it, so a hit names this type's own abstraction.
    ///
    /// TWO REFUSALS THE PUBLISH SITE DOES NOT MAKE, because a published key no one can join costs nothing
    /// and an ASKED one charges the row. (1) A platform name is never a dependency's: the one-import floor
    /// keys a platform conformance under the file's sole dependency (`DProto#CustomStringConvertible
    /// .description`, pinned in `ForeignOwnerProofProcessTests`), and asking that key would charge every
    /// `description` read in a file with one import. (2) Where the floor module's own sources are readable
    /// and do not declare the name, the floor's guess is refuted and nothing is asked (a re-exported owner
    /// lands here too — the release's silence, not a new charge).
    func ownerKeyPkg(_ abs: String, inFile file: String) -> String? {
        guard !r910Off, !abs.isEmpty, !localTypes.contains(abs), localProtocolWirePath(abs) == nil else { return nil }
        let top = String(abs.prefix { $0 != "." })
        guard !localTypes.contains(top), PLATFORM_REFINES[top] == nil, !PLATFORM_LEAVES.contains(top),
              !PLATFORM_VALUE_TYPES.contains(top), !STD_SUPERS_PUBLIC.contains(top) else { return nil }
        if let m = foreignOwnerModule(inFile: file) {
            if let d = moduleDeclarations(m), !d.opaque, d.names[top] == nil { return nil }
            return deps.pkgOfModule(m)
        }
        return provenOwnerPackage(of: abs, inFile: file, site: "r910")
    }
    /// …and applies what it answers ADDITIVELY: beside whatever the site charges, without setting the
    /// caller's `resolved`, so every disclosure the miss path fires (R705, R859, vein D, R826, the κ
    /// ledger) still fires. A RESOLUTION that can remove nothing. Skipped where the owner's package was
    /// already in `asked` — the §2 join asked that identical string and missed.
    @discardableResult
    func askOwnKey(_ ownerPkg: String, _ path: String, asked: Set<String>, to qual: String) -> Bool {
        guard ownerPkg != pkgName, !asked.contains(ownerPkg) else { return false }
        // REACH PROBE (§E1) — two lines: ASK counts the population this arm runs on, HIT the subset it moves.
        if r910Probe { FileHandle.standardError.write("R910ASK \(qual) \(ownerPkg)#\(path)\n".data(using: .utf8)!) }
        guard let e = deps.lookup("\(ownerPkg)#\(path)") else { return false }
        if r910Probe {
            FileHandle.standardError.write(
                "R910HIT \(qual) \(ownerPkg)#\(path) eff=\(e.effects.sorted())\n".data(using: .utf8)!)
        }
        applyDepEntry(e, to: qual)
        return true
    }

    // ── ⟨0.40⟩ THE CONSUMER (SPEC §2 ⟨0.40⟩; SOUNDNESS R843; PART 95). Everything below ADDS: an entry the
    // surface resolves is applied beside whatever the site already charged, and a hop the surface does not
    // fully answer adds `Unknown`. Nothing here sets `resolved`, so every disclosure the release made at a
    // site still fires — the clause's MAY-withdrawal is deliberately not taken. ──
    let r843Off = ProcessInfo.processInfo.environment["CANDOR_R843_OFF"] != nil
    let r843Probe = ProcessInfo.processInfo.environment["CANDOR_R843_PROBE"] != nil
    /// The walk from a declared target `start` for `leaf`: `<T>.<leaf>` where the index has it (and stop
    /// on that path), else every supertype in `T`'s COMPLETE `supers` plus every `adds` a chained report
    /// records for `T`. A type with no key or a KIND-ONLY key ends its path as a MISS — never as "no
    /// supertypes" — and so does a type whose package has a distrusted copy. No path reaching the member at
    /// all is ⟨0.23⟩'s member miss. `forcedProtocol`: a `returnsProtocol` target is a protocol whatever
    /// `types` says (PART 95 o12), so its kind is never the unknown one.
    func surfaceAnswer(_ start: String, _ leaf: String, forcedProtocol: Bool)
        -> (hits: [String], visited: [String], answered: Bool, exactFrom: String?, structural: Bool, pkgs: Set<String>)
    {
        var hits: [String] = [], visited: [String] = []
        let startKind = forcedProtocol ? "protocol" : deps.surface.knownKind(start)
        var miss = startKind == nil   // an unknown kind is open
        // An EXACT receiver (`final` / `value`) runs its own body or an inherited one, never a sibling
        // implementor's: past the start node, only a body the ancestor itself carries is joined.
        let exact = startKind == "final" || startKind == "value"
        var structural = miss   // a miss the MANIFEST caused (no key, kind-only, distrusted, unknown kind)
        var pkgs = Set<String>()
        var stack = [start], seen = Set<String>()
        while let t = stack.popLast() {
            guard seen.insert(t).inserted else { continue }
            if let h = t.firstIndex(of: "#") {
                pkgs.insert(String(t[..<h]))
                if deps.surface.distrustedPkgs.contains(String(t[..<h])) { miss = true; structural = true }
            }
            let k = "\(t).\(leaf)"
            visited.append(k)
            let present = (exact && t != start) ? deps.lookupOwn(k) != nil : deps.lookup(k) != nil
            if present { hits.append(k); continue }
            stack.append(contentsOf: (deps.surface.adds[t] ?? []).sorted())
            guard case .full(_, let sups) = deps.surface.state(t) else { miss = true; structural = true; continue }
            stack.append(contentsOf: sups)
        }
        if hits.isEmpty { miss = true }
        return (hits, visited, !miss, exact ? start : nil, structural, pkgs)
    }
    func applySurface(_ a: (hits: [String], visited: [String], answered: Bool, exactFrom: String?,
                            structural: Bool, pkgs: Set<String>),
                      to qual: String) {
        for k in a.hits {
            let own = a.exactFrom.map { !k.hasPrefix("\($0).") } ?? false
            if let e = own ? deps.lookupOwn(k) : deps.lookup(k) { applyDepEntry(e, to: qual) }
        }
        // ⟨0.39⟩'s route for each key the walk asked: this package's own implementors / subclasses — except
        // past the start of an EXACT receiver, where they are siblings whose witnesses never run.
        for k in a.visited where a.exactFrom.map({ k.hasPrefix("\($0).") }) ?? true {
            unionOwnImplementors(forKey: k, to: qual)
        }
    }
    /// The declared targets a chained `holds` gives `hop`, the module-named tier first (as the member join
    /// asks), and whether any package asked carries a distrusted copy.
    func holdsTargets(_ hop: String, _ file: String, _ module: String?) -> (targets: [String], distrusted: Bool) {
        var distrusted = false
        for tier in joinTiers(file, module: module) {
            var t = Set<String>()
            for (p, _) in tier {
                if let s = deps.surface.holds["\(p)#\(hop)"] { t.formUnion(s) }
                if deps.surface.distrustedPkgs.contains(p) { distrusted = true }
            }
            if !t.isEmpty { return (t.sorted(), distrusted) }
        }
        return ([], distrusted)
    }
    /// Did a TRUSTED surface answer this hop completely — a `holds` hit, every target's walk hitting, no
    /// unknown kind, no distrusted copy? Only then is a guessed owner's lookup exempt from the miss rule.
    func holdsAnswered(_ hop: String, _ leaf: String, _ file: String, _ module: String?) -> Bool {
        let (ts, distrusted) = holdsTargets(hop, file, module)
        guard !ts.isEmpty, !distrusted else { return false }
        return ts.allSatisfy { surfaceAnswer($0, leaf, forcedProtocol: false).answered }
    }

    /// ⟨0.40⟩ THE WALK FOR A RECEIVER TYPED FROM THE CONSUMER'S OWN SOURCE whose own key missed (SPEC §2
    /// ⟨0.40⟩): entries the walk reaches are ADDED; EVERY STRUCTURAL MISS on the way (an unkeyed or kind-only
    /// node — a `@dynamicMemberLookup` type is always kind-only, R890 — a distrusted copy, an unknown kind)
    /// ADDS `Unknown`, because Swift has no language-scoped permission: a member a protocol extension adds is
    /// in scope wherever its module is imported. A walk whose every node is keyed and closed is the
    /// producer's purity claim, except that `adds` is never complete: a member some package the walk did
    /// not visit publishes may come from a conformance it adds unseen (o10_adds_partial). A GUESSED owner's
    /// hedge is the miss rule's (below), which a trusted `holds` exempts, so it is not hedged here.
    func isPlatformTypeName(_ n: String) -> Bool {
        PLATFORM_REFINES[n] != nil || PLATFORM_LEAVES.contains(n) || PLATFORM_VALUE_TYPES.contains(n)
            || STD_SUPERS_PUBLIC.contains(n)
    }
    /// `<pkg>#<P>` for a platform PROTOCOL the package extends (R889): a platform name, kind `protocol`, and
    /// every super another such node of the same package. A dependency's OWN type that happens to share a
    /// platform name (RxSwift's `Observable` class) is not one, and keeps every hedge it had.
    func isPlatformExtensionNode(_ key: String) -> Bool {
        guard let h = key.firstIndex(of: "#") else { return false }
        let pkg = String(key[..<h]), name = String(key[key.index(after: h)...])
        guard isPlatformTypeName(name), case .full(let kind, let sups) = deps.surface.state(key), kind == "protocol"
        else { return false }
        return sups.allSatisfy { $0.hasPrefix("\(pkg)#") && isPlatformTypeName(String($0.dropFirst(pkg.count + 1))) }
    }
    func sourceTypedWalk(_ key: String, _ leaf: String, tiers: [[(p: String, mods: [String])]],
                         to qual: String, guessed: Bool) {
        var starts: [String] = []
        for tier in tiers where starts.isEmpty {
            for (p, _) in tier where deps.surface.typeKeysSeen.contains("\(p)#\(key)")
                                     || deps.surface.adds["\(p)#\(key)"] != nil {
                starts.append("\(p)#\(key)")
            }
        }
        var walkMiss = false
        for st in starts {
            let a = surfaceAnswer(st, leaf, forcedProtocol: false)
            applySurface(a, to: qual)
            // A receiver typed as a PLATFORM type (`some Sequence`) whose `<pkg>#<P>` node exists only because a
            // package extends it: a member no package publishes is the standard library's own, classified
            // as it always was — the `adds` hedge is for a DEPENDENCY type a conformance may be added to.
            let platformStart = isPlatformExtensionNode(st)
            if !a.answered, a.structural
                || (!platformStart && deps.anyChainedPackagePublishesLeaf(leaf, excluding: a.pkgs)) {
                walkMiss = true
            }
            if r843Probe {
                FileHandle.standardError.write("R843WALK \(qual) \(st).\(leaf) hits=\(a.hits) answered=\(a.answered) structural=\(a.structural)\n".data(using: .utf8)!)
            }
        }
        if walkMiss, !guessed {
            direct[qual, default: []].insert("Unknown")
            whyMap[qual, default: []].insert("dispatch:\(key).\(leaf)")
        }
    }

    let localProtocolNames = Set(protocolMethods.keys)  // loop-invariant: build once, not per fn
    let r1073Off = DeclCollector.r1073Off   // SOUNDNESS R1073
    let r1073Probe = CallCollector.veinBProbe
    /// VEIN C — the accessor units (computed property / observer / lazy init / subscript bodies). The two
    /// down-walks below edge ONLY these: `resolveQual("Sub.task")` also answers a METHOD named `task`
    /// (`override func task(for:using:)`), and a property read never runs a method. Measured: without
    /// this filter Alamofire `Request.urlSessionTasks` gained a fabricated `Net` from `DataRequest.task(…)`.
    /// …MINUS every qual a non-accessor unit also holds: a method's DEFAULT-ARGUMENT bodies are emitted as
    /// `isAccessor` units under the METHOD's own qual (`DeclCollector`, default values), so Alamofire's
    /// `func response(queue: DispatchQueue = .main, …)` looked like an accessor named `response` and was
    /// edged from `request.response` (measured on the corpus; no effect moved, still a wrong edge). The
    /// method's own qual is overload-suffixed while its default-argument units keep the bare one, so the
    /// comparison is on the base name.
    let veinCAccessorQuals = Set(allFns.filter { $0.isAccessor }.map { $0.qual })
        .subtracting(allFns.filter { !$0.isAccessor }.map { f in
            // an OVERLOADED method's qual carries a signature suffix its default-argument units do not
            String(f.qual.prefix { $0 != "(" && $0 != "#" })
        })
    // SOUNDNESS R534 — BACKFILL `protoParams`, THE HALF DeclCollector STRUCTURALLY CANNOT SEE.
    // `DeclCollector.protocolMethods` is per-FILE and filled as that file's walk descends, so the test it
    // can run at parameter-collection time is "is this protocol declared EARLIER, in THIS file?" — a
    // question about source layout, answered as if it were a question about types. `protocolMethods` here
    // is the merged, scan-global map, and this is the first point it is complete; every `CallCollector`
    // below is constructed after it, so a `protoParams` entry written here reaches all seven of the
    // consumers that read `protoTyped` (method dispatch, property read, `if let` unwrap, closure/`map`
    // element typing, operator dispatch, stringification, the let-binding copy).
    //
    // WHY IT IS NOT ENOUGH TO POPULATE `params` (which DeclCollector now also always does): the two maps
    // have DISJOINT consumer sets, which is the whole shape of R534. Measured on the 66-arm fixture: with
    // the protocol declared BELOW or in another file, `params` was populated and `h?.emit()` charged —
    // while `h.map { $0.emit() }` and `<T: P>(_ h: T?) { if let g = h … }` were ABSENT, because the
    // closure- and `if let`-typing paths read `protoTyped` and nothing else. Fixing only the direction the
    // row was filed from would have left that mirror hole open and looked like a complete fix.
    //
    // ADDITIVE and PRECISE-OR-NOTHING: only a name already recorded in `params` (so a real parameter of a
    // real declared type), only when that name — resolved through this function's OWN generic bounds, so
    // `<T: P>(_ h: T?)` reaches `P` rather than the useless `T` — names a protocol THIS SCAN declared, and
    // never over an entry DeclCollector already wrote. A dependency's protocol is not in `protocolMethods`
    // and is left to the imported-protocol CHA further down, unchanged.
    for i in allFns.indices {
        for (pname, tn) in allFns[i].params where allFns[i].protoParams[pname] == nil {
            let resolved = allFns[i].genericBounds[tn] ?? tn
            if protocolMethods[resolved] != nil { allFns[i].protoParams[pname] = resolved }
        }
    }
    // ⟨0.39⟩ THE ONE WIRE SPELLING FOR A DISPATCHED ABSTRACTION (SPEC §4, obligations 1 and 2). It is
    // ⟨0.23⟩'s `typeSurface` rule — fully qualified in the OWNING package's namespace, the namespace that
    // package's entry hashes use — and the clause forbids inventing a second one. A dispatch site spells a
    // nested protocol either way (`Backend` inside `Term`, `Term.Backend` outside it), so a bare leaf is
    // mapped to its declared path and an AMBIGUOUS leaf is REFUSED rather than guessed: Swift 5.10's
    // SE-0404 makes `Term.Backend` and `Ui.Backend` a real pair, and publishing the leaf for either would
    // key a consumer onto the other's effects — a fabricated charge, not a missed one.
    var protocolPathByLeaf: [String: [String]] = [:]
    for pp in protocolPaths {
        protocolPathByLeaf[pp.contains(".") ? String(pp.split(separator: ".").last!) : pp, default: []].append(pp)
    }
    func localProtocolWirePath(_ spelled: String) -> String? {
        if protocolPaths.contains(spelled) { return spelled }
        guard let c = protocolPathByLeaf[spelled], c.count == 1 else { return nil }
        return c[0]
    }
    // Does protocol `p` declare `member` DIRECTLY, or INHERIT it from a (transitive) super-protocol
    // (`protocol Sub: Sup` → `protocolSupers[Sub] = {Sup}`)? A super-protocol method IS callable on a
    // `Sub`-bound / `any Sub` receiver, and the sub's own concrete conformers (which provide the inherited
    // witness — `Impl.base`) resolve it via the `conformers[Sub]` CHA below. Walked transitively with a
    // visited-set (a cyclic/deep hierarchy terminates); only genuine super-PROTOCOLs are in the map, so no
    // unrelated type hijacks a Sub receiver. Without this `s.base()` (base ∈ Sup, `s: any Sub`) read
    // silent-pure — the dispatch gate checked `protocolMethods[Sub]` alone.
    func protoOrSuperDeclares(_ p: String, _ member: String) -> Bool {
        var seen = Set<String>(), frontier = [p]
        while let cur = frontier.popLast() {
            if !seen.insert(cur).inserted { continue }
            if protocolMethods[cur]?.contains(member) == true { return true }
            frontier.append(contentsOf: protocolSupers[cur] ?? [])
        }
        return false
    }
    // Collapse the const-string index: drop ambiguous (nil) names, keep only the unambiguous NAME→literal.
    var globalConstStrings: [String: String] = [:]
    for (k, v) in constStrings { if let v { globalConstStrings[k] = v } }
    // Loop-invariant: `freeFnByName` is fully built above (the decl-aggregation pass) and never mutated in
    // the per-fn loop, so its key set is fixed. Build it ONCE here — not once PER function inside the loop
    // (`Set(freeFnByName.keys)` at the CallCollector site was O(freeFns) rebuilt N times = O(N²) on a
    // free-function-heavy corpus). Byte-identical: the set passed to each CallCollector is the same value.
    //
    // ⟨0.33.1⟩ RESTRICTED to `freeFnUnconditionalQuals`: a bare name whose EVERY declaration sits inside
    // a `#if` (no unconditional declaration anywhere in the scan) must not shadow the κ heuristic — see
    // the doc at `conditionalOnlyFreeFnNamesByModule` above, which this is the scan-wide counterpart of.
    // A name with even one unconditional declaration is unaffected (still in this set, still shadows).
    let localFreeFnNames = freeFnUnconditionalQuals
    // The scan-wide twin of `conditionalOnlyFreeFnNamesByModule`: names in `freeFnByName` that have NO
    // unconditional declaration anywhere. Passed to `CallCollector` alongside the module-scoped set so
    // it can UNION the κ heuristic's charge with the conditional declaration's own effects (not just
    // suppress the shadow) — see `conditionallyShadowedFreeFns`'s use, below and in CallCollector.
    let conditionalOnlyFreeFnNames = Set(freeFnByName.keys).subtracting(freeFnUnconditionalQuals)
    // ⟨0.33.1⟩ THE TYPE ANALOGUE of `conditionalOnlyFreeFnNames`, directly above — a `#if`-gated
    // `class`/`struct`/`enum`/`actor` of the same NAME as a κ-platform type (`Pipe`, `AVCaptureDevice`,
    // `EKEventStore`, `NWBrowser`, …) shadows the BARE-CONSTRUCTOR κ arms in `CallCollector` (the
    // `kappaFree`/privacy-capture/Bonjour/EventKit arms in `visit(FunctionCallExprSyntax)`'s bare-
    // identifier branch) exactly the way an unconditional one does — same "SwiftSyntax reads every `#if`
    // branch" root cause, same missing hedge.
    //
    // SCOPED TO THOSE FOUR ARMS ONLY, deliberately NOT a blanket swap of `declaredTypes` itself (that was
    // tried first and reverted — see the corpus note below). `declaredTypes` stays the RAW aggregate
    // everywhere else it is consulted: the §2.2 type-hierarchy sidecar, `isInvocationValue`'s `Process`
    // check, `chargeContentsCtor`, and — the reason for the narrower scope — every TYPED-RECEIVER member-
    // dispatch arm (`kappaMember` via `base.root`, e.g. `bootstrap.connect(...)`). MEASURED on swift-nio:
    // passing the restricted set as `CallCollector.declaredTypes` wholesale (the broad version of this
    // fix) changed 16 functions, and several of them LOST their existing `Clock`/`Env`/`Unknown` outright
    // in favour of a bare `Net` — `ClientBootstrap`/`ServerBootstrap`/`DatagramBootstrap` are declared
    // exactly once each, inside `Sources/NIOPosix/Bootstrap.swift`'s file-wide `#if !os(WASI)` (no
    // alternate declaration anywhere, so they read as "conditional-only" under the naive rule), and
    // NIOPosix's OWN internal self-dispatch between their overloads is what the typed-receiver arm was
    // resolving locally before this — losing that shadow there means an INTERNAL call within the type's
    // own method loses its true local resolution in favour of the blunt cross-package heuristic, which is
    // a real precision regression (dropping an honest `Unknown`/`Clock`/`Env` for a confident-but-
    // incomplete `Net`), not the additive gain this fix exists to make. A bare CONSTRUCTOR call
    // (`Pipe()`) has no such internal-self-dispatch shape — the four arms below are the only place the
    // narrowing is safe, matching the shape of the original `getenv`/`Pipe` defect exactly.
    let conditionallyShadowedTypeNames = declaredTypes.subtracting(declaredTypesUnconditional)
    // MEMBER NAMES PER LOCAL TYPE, for half 1's provenance conjunct. A bare `foo()` inside `struct Bar`
    // is `self.foo()` when `Bar` declares `foo` — a purely LOCAL call, never a dependency factory — but
    // the conjunct only excluded FREE functions, so every such call recorded a dependency-provenance
    // binding and every later member call on its result disclosed a false
    // `Unknown[dispatch:untyped cross-package receiver]`. Instrumented over 14 real targets: 289 bindings,
    // led by `rootOf` (16), `classifyItems`, `createFunction`, `parseMisplacedSpecifiers`, `expandMacros`
    // — enclosing-type methods, every one.
    //
    // Keyed by TYPE, not a flat leaf set, and the enclosing type's local SUPERS are climbed: the exclusion
    // must be as narrow as Swift's own bare-name resolution, because widening it drops a genuine half-1
    // disclosure, which is the direction that costs soundness. A same-named method on an UNRELATED local
    // type must exempt nothing.
    var localTypeMembers: [String: Set<String>] = [:]
    for f in allFns {
        guard let dot = f.simpleQual.lastIndex(of: ".") else { continue }
        let owner = String(f.simpleQual[..<dot])
        let member = String(f.simpleQual[f.simpleQual.index(after: dot)...])
        localTypeMembers[owner, default: []].insert(member.split(separator: "(").first.map(String.init) ?? member)
    }
    let localMemberLeaves = Set(localTypeMembers.values.joined())   // SOUNDNESS R1065
    /// `t`'s own members plus every LOCAL supertype's, transitively — an inherited method is callable
    /// bare too. Walked with the same sorted, seen-guarded traversal the dispatch paths use.
    func membersVisibleOn(_ t: String) -> Set<String> {
        var out = localTypeMembers[t] ?? []
        var seen: Set<String> = [t], queue = Array(supertypesOf[t] ?? []).sorted()
        while let s = queue.popLast() {
            guard seen.insert(s).inserted else { continue }
            out.formUnion(localTypeMembers[s] ?? [])
            queue.append(contentsOf: (supertypesOf[s] ?? []).sorted())
        }
        return out
    }
    var membersVisibleCache: [String: Set<String>] = [:]
    // ── SOUNDNESS R268 — AN INHERITED STORED PROPERTY IS A CALLABLE / CONTAINER SOURCE TOO ─────────
    //
    // R211/R192/R215 made a container or callable field of `self` a callable source, so
    // `for c in cbs { c(p) }` over `let cbs: [(String) -> Void]` is charged. Those three indexes —
    // `fields` (via `CallCollector.fieldIsCallable`), `fieldArrayElem` and `fieldDictValue` — are keyed
    // on the enclosing type and are read with `enclosingType` alone, so they NEVER CLIMBED. The
    // method-call path (R134, the same range and the same day) climbs, and the property-ACCESSOR path
    // climbs and asserts in its own comment that it does so "exactly as the method-call path does".
    // Three paths answer "what does this member hold"; one did not — §F1.3, two implementations of one
    // question, drifted.
    //
    // MEASURED on a generated 126-cell matrix, every cell compiled and EXECUTED: an inherited container
    // field really invokes a stored closure that deletes a file, and the enclosing function is **ABSENT
    // from `functions[]` — no row, no `Unknown`, nothing** — while the OWN-TYPE spelling of the same
    // program is correctly disclosed as `Unknown`. **36 cells, and every sub-axis fails: one and two
    // levels of inheritance, `[T]` element / `[K: V]` value / plain callable, and the bare, `self.`- and
    // `let`-copy spellings.**
    //
    // THE ROW'S EXCULPATING CLAUSE WAS WRONG AND IT IS A FIX BOUNDARY. It said "the inherited COMPUTED
    // property is correct, which is the drift." That is true of the property-ACCESSOR path — an
    // effectful getter reached from a subclass is charged correctly at every depth (9 of 9 cells) — and
    // FALSE of a computed property that VENDS CALLABLES: `var cbs: [(String) -> Void] { [bomb] }` is
    // silent at every inherited depth exactly like the stored `let`, and **18 of the 36 silent cells are
    // computed**. A fix written to that sentence would climb for stored fields only and leave half the
    // class open. The real drift is OWN-TYPE DISCLOSED vs INHERITED ABSENT, not stored vs computed.
    //
    // FIXED IN THE INDEX, NOT AT THE FOUR READ SITES. `CallCollector` has no supertype index and there
    // are four consumers (`elementTypeOf`, `dictValueOf`, `callableName`, `closurePropertyInvocation`);
    // teaching each to climb is the shape that produced this drift in the first place. Flattening once,
    // here, is exact rather than approximate — a subclass really does have its superclasses' stored
    // properties — and it is ADDITIVE: an entry is written only where the subtype does not declare that
    // member itself, so an OVERRIDE always wins and nothing already resolved can move. `supertypesOf` is
    // transitive, so `Base -> Mid -> Sub` needs no loop.
    for (sub, sups) in supertypesOf where sub != "" {
        for sup in sups.sorted() where sup != sub {
            // ONLY THE CALLABLE ENTRIES, and the narrowing is a MEASUREMENT, not caution. `fields` has
            // four MEMBERSHIP-ONLY readers — `isModuleQualifier`, the shadowing guards at
            // CallCollector:4273 and :5140, and the `dynamicMemberTypes` arm — which ask *is there a
            // field of this name* and do not care what it holds. Flattening every inherited entry
            // flipped those, and a 1325-file, 8-package corpus A/B caught it: six rows LOST effects or
            // an `Unknown` disclosure (swift-nio `shutdownSocket`, `finishConnectSocket`, two
            // `getOption`s; Alamofire's three `WebSocket*.close` lost `Net`) — a precision gain in
            // appearance and a DISCLOSURE LOSS in fact, introduced by a fix for a silent under-report,
            // which is this family's measured failure rate arriving on schedule. `fieldIsCallable` is
            // the only consumer R268 needs from this index, and it reads exactly `isFunction` (the
            // alias spelling is rewritten to `(nil, true)` by the completion pass above), so the
            // narrowed flattening covers the row and leaves every membership test answering as before.
            // Re-measured after narrowing: those six rows are unchanged from v0.35.0.
            for (m, v) in fields[sup] ?? [:] where v.isFunction && fields[sub]?[m] == nil {
                fields[sub, default: [:]][m] = v
            }
            for (m, v) in fieldArrayElemNested[sup] ?? [:] where fieldArrayElemNested[sub]?[m] == nil {
                fieldArrayElemNested[sub, default: [:]][m] = v
            }
            for (m, v) in fieldArrayElem[sup] ?? [:] where fieldArrayElem[sub]?[m] == nil {
                fieldArrayElem[sub, default: [:]][m] = v
            }
            for (m, v) in fieldDictValue[sup] ?? [:] where fieldDictValue[sub]?[m] == nil {
                fieldDictValue[sub, default: [:]][m] = v
            }
        }
    }

    // The module names the SCANNED PROJECT itself defines (`Sources/<Module>/…`, `Tests/<Module>/…`).
    // A dotted callee whose base is one of these is NOT a platform spelling — under `@testable import
    // App`, `App.Process()` names the project's own type — so `isModuleQualifier` refuses it. See
    // `CallCollector.importedModules`.
    let projectModules = Set(allFns.map { swiftModuleOf($0.loc) }).subtracting([""])
    // R79 — a cross-module global RECEIVER (`sharedWorker.doWork()` where `public let sharedWorker =
    // SharedWorker()` lives in a DIFFERENT module the calling file imports). `globalTypesByModule` is
    // deliberately module-scoped (see its own comment: a bare global name is not project-wide unique),
    // so a name declared only in an imported module missed it entirely — `rootOf` fell through to the
    // untyped-name fallback, `owner` came back nil, and the terminal member-access arm in
    // `visit(FunctionCallExprSyntax)` recorded a bare-leaf `Call` no edge ever matches: the CALLER itself
    // (not just this one call) could end up carrying no effect and vanish from `functions[]` outright
    // (SOUNDNESS.md R79). Resolved by walking the calling FILE's own `import`s: a name absent from the
    // file's own module is looked up across every OTHER imported PROJECT module's `publicGlobalTypesByModule`
    // — the access-checked table, so a non-public global in another module keeps missing exactly as before.
    // A name two-or-more imported modules each declare `public` is genuinely ambiguous (which one binds is
    // a real Swift name-lookup question this pass cannot answer without the compiler) — resolve NOTHING,
    // never guess: same "never guess" discipline `globalFactories`' deferred resolution already documents.
    // Cached per FILE (not per module) because imports are per-file — two files in one module can import
    // different things — and this runs once per function below, not once per file.
    var crossModuleGlobalTypesCache: [String: [String: String]] = [:]
    func crossModuleGlobalTypes(forFile file: String, ownModule: String) -> [String: String] {
        if let cached = crossModuleGlobalTypesCache[file] { return cached }
        let ownGlobals = globalTypesByModule[ownModule] ?? [:]
        let imported = Set(fileImports[file] ?? []).intersection(projectModules).subtracting([ownModule])
        var extra: [String: String] = [:]
        if !imported.isEmpty {
            var byName: [String: (type: String, moduleCount: Int)] = [:]
            for m in imported {
                for (name, ty) in publicGlobalTypesByModule[m] ?? [:] where ownGlobals[name] == nil {
                    if let existing = byName[name] {
                        // a second imported module also declares this name — ambiguous, mark the count
                        // (the actual TYPE recorded doesn't matter once count > 1; it's dropped below).
                        byName[name] = (existing.type, existing.moduleCount + 1)
                    } else {
                        byName[name] = (ty, 1)
                    }
                }
            }
            for (name, v) in byName where v.moduleCount == 1 { extra[name] = v.type }
        }
        crossModuleGlobalTypesCache[file] = extra
        return extra
    }
    // VEIN A(i) — the type-identity scope every CallCollector resolves a spelling in (see
    // `CallCollector.canonicalTypeRef`). A SHARED simple name's full paths join `localTypes` /
    // `declaredTypes` because those are the spellings the canonicaliser hands on for it (R266/R132): the
    // unit keys' own prefixes, never a guessed leaf. Protocols keep their leaf (the dispatch machinery is
    // keyed by it). Nothing here moves under `CANDOR_AI_OFF=1`.
    // SOUNDNESS R951 — op -> the local types declaring that comparison witness as a static member.
    var opWitnessTypesR951: [String: Set<String>] = [:]
    for f in allFns {
        guard let et = f.enclosingType else { continue }
        let leaf = String((f.simpleQual.split(separator: ".").last.map(String.init) ?? "").prefix { $0 != "(" && $0 != "#" })
        if leaf == "==" || leaf == "<" { opWitnessTypesR951[leaf, default: []].insert(et) }
        // SOUNDNESS R974 (b) — a declared `hash(into:)` is the Hashable witness container operations run.
        if leaf == "hash", f.paramLabels == ["into"] { opWitnessTypesR951["hash", default: []].insert(et) }
    }
    var aiBase = AiTypeIndex()
    var aiSharedPaths = Set<String>()      // the FULL paths added above — the canonicaliser's precise spellings
    if !CallCollector.aiOff {
        aiBase.enabled = true
        aiBase.localTypePaths = localTypePaths
        aiBase.pathsByLeaf = typePathsBySimple
        aiBase.protocolPaths = protocolPaths
        aiBase.fileAliases = fileTypeAliasesAI
        aiBase.memberAliases = memberTypeAliasesAll.mapValues { $0.compactMapValues { $0.count == 1 ? $0.first : nil } }
        for (_, m) in memberTypeAliasesAll { for (a, u) in m { aiBase.nestedAliasTargets[a, default: []].formUnion(u) } }
        aiBase.supertypes = supertypesOf
        for (_, ps) in typePathsBySimple where ps.count > 1 {
            for p in ps where p.contains(".") && !protocolPaths.contains(p) && !localTypes.contains(p) {
                localTypes.insert(p)
                aiSharedPaths.insert(p)
                if declaredTypePathsAI.contains(p) { declaredTypes.insert(p) }
            }
        }
    }
    for f in allFns {
        locOf[f.qual] = f.loc
        if f.isMain { entryPoints.insert(f.qual) }
        edges[f.qual] = edges[f.qual] ?? []
        // R61 — a bodyless func is normally a PROTOCOL REQUIREMENT (its call sites already get an honest
        // `dispatch:` from the bounded-CHA machinery below; this unit itself is never a call TARGET, so
        // leaving it out of `direct` is correct, not a gap). `ffiNative` narrows to the one bodyless shape
        // that IS a real call target with a real, unseeable body: `@_silgen_name`/`@_extern` direct
        // C-symbol linkage. Seeding `direct` here — the ONLY place a bodyless unit's own effects are ever
        // set — means the ordinary `propagate(direct, over: edges)` fixpoint carries `Unknown` to every
        // caller exactly as it would for a real callee, with no special-casing anywhere else: the call
        // graph already resolves `c_system(cstr)` to this qual via `freeFnByName` (built without a
        // `body != nil` filter), so the transitive reach was always there — only the seed was missing.
        guard let body = f.body else {
            if let sym = f.ffiNative {
                direct[f.qual, default: []].insert("Unknown")
                whyMap[f.qual, default: []].insert("native:\(sym)")
            }
            continue
        }
        let fMod = swiftModuleOf(f.loc)
        // R79 — own-module entries win unconditionally (`merging` keeps the FIRST/left value on a
        // collision); `crossModuleGlobalTypes` already excludes any name the own module has anyway, so
        // this `merging` call never actually adjudicates a real collision, only documents which side wins.
        let effectiveGlobalTypes = (globalTypesByModule[fMod] ?? [:])
            .merging(crossModuleGlobalTypes(forFile: String(f.loc.prefix { $0 != ":" }), ownModule: fMod)) { own, _ in own }
        // ── SOUNDNESS R584 — ONE PRECEDENCE, TWO MAPS ───────────────────────────────────────────────
        // "What does a TYPE-POSITION receiver spelling denote" is ONE question with two answers: a local
        // PROTOCOL (the bounded-CHA machinery R563 wired) and a local CONCRETE TYPE — a class bound, or
        // the metatype of any declared type — which had NO wiring at all. `f<P: EffBase>(_ t: P.Type)
        // { P.make() }`, its `t.make()` twin, the same inside `struct Box<P: EffBase>`, a concrete class
        // metatype `f(_ t: CBase.Type) { t.validate() }` — every one ABSENT from `functions[]` over a
        // body that executes `URLSession.dataTask`, while the PROTOCOL twin of each resolved `[Net]`.
        // R563 closed the protocol half and the class half was never asked (§9 — an audit scoped to the
        // shape in hand; the discriminating control is that `EffBase.make()` with the class named
        // LITERALLY already resolves, so the variable is the receiver spelling, not the class).
        //
        // THE MAPS ARE BUILT FROM ONE `typeParamBounds`, SPLIT AFTERWARDS, and that ordering is R580's
        // rule rather than a style: a filter that runs BEFORE a precedence silently reinstates whatever
        // the precedence was there to remove. Function bound beats enclosing-type bound (a method may
        // shadow its type's parameter name), then the two filters PARTITION the result — so
        // `struct Box<P: Pr> { func shadowClass<P: EffBase>(_ t: P.Type) }` puts `P` in the class map and
        // in NEITHER protocol's conformer set, which is what the call actually does.
        var typeParamBounds: [String: String] = [:]
        if let et = f.enclosingType, let tb = typeGenericBoundsAll[et] {
            for (g, b) in tb { typeParamBounds[g] = b }
        }
        for (g, b) in f.genericBounds { typeParamBounds[g] = b }
        var protoBoundParamsMap = typeParamBounds.filter { localProtocolNames.contains($0.value) }
        // The CLASS half: `localTypes` MINUS `localProtocols`, the same partition every other consumer in
        // this file uses — `pushType` puts a protocol in `localTypes` the moment anything extends it.
        var typeBoundParamsMap = typeParamBounds.filter {
            localTypes.contains($0.value) && !localProtocolNames.contains($0.value)
        }
        // …AND THE METATYPE PARAMETER THAT STANDS FOR ONE. `_ t: P.Type` makes `t` a second spelling of
        // `P` in receiver position, so it is entered under the PARAMETER's name against the same bound —
        // for a type PARAMETER (`P.Type` where `<P: EffBase>`) and, R584, for a CONCRETE type named
        // directly (`_ t: CBase.Type`), which is swift-argument-parser's `ParsableCommand.Type` shape one
        // kind over. Protocol first, so the two maps stay disjoint on every spelling.
        // SOUNDNESS R704 — …AND A FOURTH ARM, because the three above ALL require the base to be declared
        // in this scan and a metatype parameter over a DEPENDENCY's type therefore entered no map at all.
        // `_ t: RBase.Type` for a chained `RBase` resolved to nothing while the literal `RBase.go()` in the
        // same file joined `RatesDep#RBase.go` — and R585's own table lists this binder as the CONTROL that
        // already worked, which is what stopped it being measured (§K). A local PROTOCOL base keeps going
        // to `protoBoundParamsMap` above and is excluded here for the reason
        // `metatypeBaseResolvable` states: it has its own read site, and answering it twice would change
        // an answer that is already right.
        var metatypeParamsForeign: [String: String] = [:]
        for (pn, base) in f.metatypeParams {
            if let b = protoBoundParamsMap[base] { protoBoundParamsMap[pn] = b }
            else if let b = typeBoundParamsMap[base] { typeBoundParamsMap[pn] = b }
            else if localProtocolNames.contains(base) { protoBoundParamsMap[pn] = base }
            else if localTypes.contains(base) { typeBoundParamsMap[pn] = base }
            else { metatypeParamsForeign[pn] = base }   // R704
        }
        // SOUNDNESS R992 — a parameter whose written type is a CONTAINER ALIAS (`_ x: A` where `typealias
        // A = [Ctx]`) gets the facts the spelled-out `[Ctx]` gets. DeclCollector reads one file and the
        // alias may live in another, so this is asked here, once all are known. ADDITIVE: a parameter
        // DeclCollector already gave a container record keeps it.
        var f = f
        if !DeclCollector.r992Off {
            for (pn, t) in f.paramDeclTypes where f.arrayParams[pn] == nil && f.dictParams[pn] == nil
                && f.arrayParamsNested[pn] == nil {
                let x = expandTypeAliasHead(t, aliasExpander(f.enclosingType))
                guard x.trimmedDescription != t.trimmedDescription else { continue }
                let facts = declaredFacts(x)
                if CallCollector.veinBProbe, facts.hasContainerFact {
                    FileHandle.standardError.write("VBHIT\tR992\tparam \(f.qual) \(pn)\n".data(using: .utf8)!)
                }
                if let inner = facts.arrayElemNested { f.arrayParamsNested[pn] = inner }
                else if let e = facts.arrayElem {
                    f.arrayParams[pn] = e
                    if facts.arrayElemOpaque { f.opaqueArrayParams.insert(pn) }
                }
                if let v = facts.dictValue { f.dictParams[pn] = v }
            }
        }
        let cc = CallCollector(info: f, fields: fields, localTypes: localTypes,
                               globalTypes: effectiveGlobalTypes,
                               globalArrayElem: globalArrayElemByModule[swiftModuleOf(f.loc)] ?? [:],
                               globalDictValue: globalDictValueByModule[swiftModuleOf(f.loc)] ?? [:],   // R994
                               containerAliases: containerAliasIdx,                                    // R992
                               returnFacts: returnFactsIdx,                                            // R990/R991
                               implicitParams: implicitParamIdx,                                       // R999
                               implicitMemberUnits: implicitMemberUnits,                               // R999
                               memberUnitKeys: memberUnitKeys,                                         // R1032
                               iterableLocalTypes: iterableLocalTypes,                                 // R1048
                               declaredTypes: declaredTypes,
                               localProtocols: localProtocolNames,
                               // SOUNDNESS R563 — the unit's GENERIC PARAMETERS that are bound to a LOCAL
                               // protocol, so a type parameter used as a RECEIVER (`P.make(v)`,
                               // `P(sink: v)`, `t.make(v)`) reaches the same bounded CHA a protocol-typed
                               // VALUE does. Function bound FIRST, enclosing type second — a method may
                               // shadow its type's parameter name, which is the same precedence
                               // `dispatchAbstraction` applies to the wire key (R550).
                               //
                               // SOUNDNESS R580 — THE PRECEDENCE RUNS FIRST AND THE FILTER SECOND, and
                               // the order is the whole bug. This built each map with
                               // `where localProtocolNames.contains(b)` applied AS IT MERGED, so a
                               // function bound that is NOT a local protocol never entered the map and
                               // therefore could not DISPLACE the enclosing type's — `Box<P: Pr>` +
                               // `func shadowed<P: Base>(_ t: P.Type) { P.make() }` charged the caller
                               // `Pr`'s conformers and published `Sh#Pr.make`, over a call that executes
                               // `Sub.make`. A filter that runs before a precedence silently reinstates
                               // whatever the precedence was there to remove. `dispatchAbstraction`
                               // applies the same precedence unconditionally and refuses afterwards; the
                               // comment above claimed these were "the same precedence" and they were
                               // not — §F1.3, twelve lines apart, again.
                               // (both maps are built above, from ONE `typeParamBounds` — see R584)
                               protoBoundParams: protoBoundParamsMap,
                               typeBoundParams: typeBoundParamsMap,
                               protoFnTypedMembers: protocolFnTypedMembers,
                               protoReqFieldTypes: protoReqFieldTypesFlat,   // R578
                               protoReqProps: protoReqPropsFlat,             // R904
                               genericCallableFields: genericCallableFields, // R256
                               classSupertypes: classSupertypesR906,         // R906
                               supertypesAll: DeclCollector.r915COff ? [:] : supertypesOf,   // R915 (C)
                               nestedTypePairs: nestedTypePairsR915,                          // R915 (A)
                               memberTypeAliases: memberTypeAliasesR915,                      // R915 (B)
                               returns: returnsIdx,
                               metatypeReturns: metatypeReturnsIdx,                                  // R585
                               genericReturnArgs: genericReturnArgIdx,                               // R1044
                               localGenerics: localGenericsFor(file: String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })),   // R1044 residual, R1072
                               globalMetatypes: globalMetatypesByModule[swiftModuleOf(f.loc)] ?? [:], // R585
                               globalMetatypeArrayElem: globalMetatypeArrayElemByModule[swiftModuleOf(f.loc)] ?? [:],
                               fieldMetatypes: fieldMetatypes,                                        // R585
                               fieldMetatypeArrayElem: fieldMetatypeArrayElem,
                               fieldArrayElem: fieldArrayElem, fieldArrayElemNested: fieldArrayElemNested,
                               fieldDictValue: fieldDictValue,
                               fieldTypeArgs: fieldTypeArgs,                                           // R905
                               opaqueFields: opaqueFields,
                               enumCaseValueType: enumCaseValueType,
                               metatypeEnumCaseValueType: metatypeEnumCaseValueType,   // R585
                               metatypeParamsForeign: metatypeParamsForeign,            // R704 (b1)
                               dynamicMemberTypes: dynamicMemberTypes,
                               propertyWrapperTypes: propertyWrapperTypes, wrappedProps: wrappedProps,
                               localFreeFns: localFreeFnNames.union(localFreeFnBaseNamesByModule[swiftModuleOf(f.loc)] ?? []),
                               conditionallyShadowedFreeFns: conditionalOnlyFreeFnNames.union(conditionalOnlyFreeFnNamesByModule[swiftModuleOf(f.loc)] ?? []),
                               conditionallyShadowedTypes: conditionallyShadowedTypeNames,
                               typeAliases: typeAliases, typeAliasArms: typeAliasArms,
                               fnTypeAliases: fnTypeAliases,
                               enclosingMembers: f.enclosingType.map { t in
                                   membersVisibleCache[t] ?? {
                                       let m = membersVisibleOn(t); membersVisibleCache[t] = m; return m
                                   }()
                               } ?? [],
                               opaqueSeqBuilders: opaqueSeqBuilders, seqBuilderConcrete: seqBuilderConcrete,
                               closureFields: closureFields, mutableClosureFields: mutableClosureFields,
                               moduleConstStrings: globalConstStrings,
                               importedModules: Set(fileImports[String(f.loc.prefix { $0 != ":" })] ?? []),
                               projectModules: projectModules, deps: deps,
                               ai: {
                                   guard aiBase.enabled else { return aiBase }
                                   var a = aiBase
                                   let path = f.enclosingTypePath ?? f.enclosingType
                                   a.enclosingTypePath = path
                                   var g = Set(f.genericBounds.keys)
                                   for seg in (path ?? "").split(separator: ".") {
                                       g.formUnion(typeGenericParamNamesAI[String(seg)] ?? [])
                                   }
                                   a.genericNames = g
                                   return a
                               }(),
                               opWitnessTypes: opWitnessTypesR951)
        // The locator-move set is flow-INSENSITIVE and must be complete before the first call is collected
        // (a rebind later in the text, or earlier in time inside a loop, still invalidates the claim). The
        // parameter names go with it: a body binder that SHADOWS a parameter is the same hazard, and the
        // signature is the one binder site the body walk cannot see.
        cc.prescanLocatorMoves(body, params: f.paramNames)
        cc.prescanBodyAliases(Syntax(body))                                   // VEIN A(i) / R790
        cc.prescanLocalTypeArgs(Syntax(body))                                 // R951
        cc.prescanLocalPlatformGenerics(Syntax(body))                         // R905 (residual)
        cc.prescanLocalGenericBindings(Syntax(body))                          // R1044 residual
        if CallCollector.veinBProbe { FileHandle.standardError.write("VBFN\t\(f.qual)\n".data(using: .utf8)!) }
        cc.walk(body)
        if !cc.genericWitnessReqs.isEmpty { genericWitnessReqsByUnit[f.qual] = cc.genericWitnessReqs }   // R951
        // accessor units: a property READ/WRITE of a known accessor unit is an edge (the reader inherits
        // the getter/observer/subscript's effects — `c.data` reaching the Fs inside `var data: Data { … }`).
        // resolveQual matches the OWN type's `Type.member` unit; when the accessor is INHERITED (the body
        // lives on a superclass or conformed protocol — `d.payload` where `payload`'s getter is on `Base`)
        // the own-type key misses. Climb `supertypesOf` exactly as the method-call path does (an inherited
        // METHOD already resolves this way) — else an effectful inherited accessor reads SILENT-PURE (the
        // swift inherited-property-accessor vein: methods climbed, property/observer/subscript units did not).
        // Only when the own key doesn't resolve — an override on the subclass wins (its unit resolves first),
        // so we never fabricate over a real overriding accessor; a member no supertype defines edges nothing.
        for pe in cc.propertyEdges {
            let ts = resolveQual(pe)
            if !ts.isEmpty {
                edges[f.qual, default: []].formUnion(ts)
            } else if let dot = pe.lastIndex(of: "."), localTypes.contains(String(pe[..<dot])) {
                let type = String(pe[..<dot]), member = String(pe[pe.index(after: dot)...])
                for sup in supertypesOf[type] ?? [] {
                    edges[f.qual, default: []].formUnion(resolveQual("\(sup).\(member)"))
                }
            }
            // ── VEIN C (SOUNDNESS R903) — …AND DOWN, as a method call does. `b.pv` with `b: BaseP` runs
            // `SubP.pv` when the value is a `SubP` (`override var pv`), exactly as `b.m()` runs `SubP.m`; the
            // method arm (`subtypesOf[owner]`, the class-CHA rule) edged the override and this loop climbed
            // UP only, so the read was ABSENT while its method twin was charged (executed: the override
            // wrote its file, `deny Fs` 0). PRECISE-OR-NOTHING and ADDITIVE, the method arm's rule: only
            // real `<sub>.<member>` accessor units are edged, nothing above is changed. A PROTOCOL owner is
            // not walked here — an extension-only member is statically dispatched, so a conformer's
            // same-named property never runs through it; a REQUIREMENT read goes through `protoPropReads`.
            // A `super.` read does not walk down (pinned by `readSuperP`), and only ACCESSOR units are edged
            // (pinned by `readBaseM`: a subclass METHOD sharing the property's name never runs on a read).
            if !veinCOff, let dot = pe.lastIndex(of: ".") {
                let type = String(pe[..<dot]), member = String(pe[pe.index(after: dot)...])
                // A type DECLARED here and not a protocol: only a class has subtypes. NOT `localTypes`, which
                // also holds a FOREIGN protocol this package merely extends (`extension FixedWidthInteger`):
                // walking its conformers edged swift-numerics' `DoubleWidth.high` from a read no
                // `FixedWidthInteger` requirement names (measured on the corpus; Unknown-only, still wrong).
                if declaredTypes.contains(type), !localProtocolNames.contains(type),
                   !STD_PURE_PROTOCOLS.contains(type), !RAW_VALUE_BASE_TYPES.contains(type) {
                    for sub in (subtypesOf[type] ?? []).sorted() where sub != type {
                        let vcHits = resolveQual("\(sub).\(member)").filter { veinCAccessorQuals.contains($0) }
                        if veinCProbe, !vcHits.isEmpty {
                            FileHandle.standardError.write("VEINC \(f.qual) \(type).\(member) -> \(vcHits.sorted()) locs=\(vcHits.sorted().map { locOf[$0] ?? "?" })\n".data(using: .utf8)!)
                        }
                        edges[f.qual, default: []].formUnion(vcHits)
                    }
                }
            }
        }
        // @resultBuilder: a func annotated `@SomeBuilder` (where SomeBuilder is a local `@resultBuilder`
        // type) has its body transformed into `SomeBuilder.build*(…)` calls that RUN when the func is
        // called — edge to the builder's build-method units so an effectful builder isn't silently pure
        // (R29). resolveQual drops the build methods the builder doesn't define; a pure builder's methods
        // contribute nothing (no flood, no fabrication).
        for attr in f.uppercaseAttrs where resultBuilderTypes.contains(attr) {
            for m in ["buildBlock", "buildExpression", "buildOptional", "buildEither", "buildArray",
                      "buildFinalResult", "buildPartialBlock", "buildLimitedAvailability"] {
                edges[f.qual, default: []].formUnion(resolveQual("\(attr).\(m)"))
            }
        }
        // ATTACHED MACRO / unresolved external result-builder disclosure. A capitalized decl-attribute
        // this scan cannot explain is not a fourth possibility to enumerate — Swift admits exactly two on
        // a func/init (a result builder or an attached macro) and exactly two on a type (a global actor or
        // an attached macro), and both explained cases are already carved out above (`resultBuilderTypes`)
        // or via `globalActorTypes`/the builtin denylist below. Neither can be EXPANDED without running
        // the compiler plugin (out of reach here), so this does not guess what the attribute does — it
        // discloses that candor could not see past it, in the SAME vocabulary a dispatch/callback already
        // uses (`Unknown` + `unknownWhy: "macro:@Name"`, SPEC §4), never a fabricated concrete effect.
        //
        // A func attribute reaches only THIS function — a body/peer/accessor macro's whole visible surface
        // is the one declaration it decorates. A TYPE attribute (`@Observable class Store`) can introduce
        // members the source never spells, so it is disclosed onto every member this scan already collected
        // for that type (never a synthesized new unit — see the AGENT-CORPUS-BRIEF note on not minting a
        // new disclosure vocabulary): a type with no collected members at all stays as it already was — the
        // pre-existing, macro-independent blind spot every purely-compiler-synthesized member (a memberwise
        // init, Equatable's `==`) already has here.
        for attr in f.uppercaseAttrs where !resultBuilderTypes.contains(attr)
            && !KNOWN_BUILTIN_DECL_ATTRS.contains(attr) && !globalActorTypes.contains(attr) {
            direct[f.qual, default: []].insert("Unknown")
            whyMap[f.qual, default: []].insert("macro:@\(attr)")
        }
        if let et = f.enclosingType {
            for attr in typeMacroAttrs[et] ?? [] where !KNOWN_BUILTIN_DECL_ATTRS.contains(attr)
                && !globalActorTypes.contains(attr) {
                direct[f.qual, default: []].insert("Unknown")
                whyMap[f.qual, default: []].insert("macro:@\(attr)")
            }
        }
        // a bare-name read that names a GLOBAL initializer unit charges its first-touch effects here
        // A bare global read resolves in the reader's OWN module when that module declares the name —
        // the same lexical rule the free-function path uses, and the reason the two `cfg`s above needed to
        // stay distinct units first. Falls back to the plain name match, so a module that declares no such
        // global still reaches a uniquely-named one elsewhere exactly as before.
        let readerModule = swiftModuleOf(f.loc)
        for name in cc.globalReads where name != f.qual {
            // R847 — a bare read a binder holds locally is never a dependency declaration; only the
            // chained arm below consults this (the local arms above see every read, as before).
            let depReadable = CallCollector.r847Off || cc.depGlobalReads.contains(name)
            if let inMod = globalsByModule[readerModule]?[name], inMod.count == 1 {
                edges[f.qual, default: []].insert(inMod[0])
            } else if globalUnitNames.contains(name) {
                edges[f.qual, default: []].insert(name)
            } else if !deps.isEmpty, depReadable {
                // The global may belong to a chained DEPENDENCY module. Reading it still forces its
                // initializer — swift globals are lazy — and the dep's report records that unit under
                // `<Module>#<name>`, but nothing looked for it, so a consumer of an effectful dependency
                // global read sound-complete pure (candor-spec SOUNDNESS-VEIN-initializer-edge.md; java and
                // rust needed the same edge on their side of the boundary). Effects attach directly, since
                // the dep's unit lives in another report. Only the file's own imports are consulted and only
                // an unambiguous single hit joins, so an unimported or ambiguous name resolves to nothing.
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                var hits: [DepEntry] = []
                // R565 — the key is `<PACKAGE>#<name>`, and this loop used to spell a MODULE there.
                for (p, _) in deps.chainedPkgs(importing: fileImports[file] ?? []) {
                    // R847 — a bare READ denotes a dependency global, or an implicit-self member of the
                    // enclosing type's chain — never an arbitrary method sharing the leaf.
                    if let e = bareNameDepEntry(p, name, f) {
                        if joinDebug { FileHandle.standardError.write("JOINSITE global \(f.qual) \(p)#\(name) -> \(e.whyReason ?? "-")\n".data(using: .utf8)!) }
                        hits.append(e)
                    }
                }
                // SPEC §2 rule 1 ⟨0.25⟩ — two packages answering is an AMBIGUOUS key: UNION, never drop
                // (see the member-call join's note below; this is the same rule at the global-read site).
                if hits.count == 1 || (!joinUnionOff && hits.count > 1) {
                    if hits.count > 1, joinUnionProbe {
                        FileHandle.standardError.write("JOINUNION global \(f.qual) \(name) n=\(hits.count)\n".data(using: .utf8)!)
                    }
                    for de in hits { applyDepEntry(de, to: f.qual) }
                }
            }
        }
        cc.resolveAmbiguousCapture()   // the function is fully walked by here — see `ambiguousCapture`
        direct[f.qual, default: []].formUnion(cc.directEffects)
        if cc.unresolved { direct[f.qual, default: []].insert("Unknown") }
        whyMap[f.qual, default: []].formUnion(cc.why)
        hostsD[f.qual, default: []].formUnion(cc.hosts)
        fsD[f.qual, default: []].formUnion(cc.fsKinds)
        for (eff, kinds) in cc.privacyKinds { privKindD[f.qual, default: [:]][eff, default: []].formUnion(kinds) }
        cmdsD[f.qual, default: []].formUnion(cc.cmds)
        pathsD[f.qual, default: []].formUnion(cc.paths)
        tablesD[f.qual, default: []].formUnion(cc.tables)
        if !cc.incompleteSurfaces.isEmpty { incompleteD[f.qual, default: []].formUnion(cc.incompleteSurfaces) }
        if cc.unreadableAliasArm { unreadableAliasArmFns.insert(f.qual) }   // R429 — expanded after propagate

        // fn-typed params INVOKED: defer to callback-flow (resolved after all call sites are known)
        //
        // SOUNDNESS R720 — AND A NAME WITH NO PARAMETER POSITION CAN NEVER BE DISCHARGED BY CALL-SITE
        // FLOW, SO POOLING IT INTO THE INDEX JUDGMENT MADE THAT JUDGMENT VACUOUS. `callbackInvoked` is
        // named for fn-typed PARAMS but the invocation site that fills it reads `fnTyped`, which also
        // holds names that are not parameters of THIS unit:
        //   · an ANNOTATED fn-typed LOCAL — `let g: ([(String) -> Void]) -> Void = { … }; g(cbs)`.
        //     CallCollector's annotated-binder arm inserts it into `fnTyped`; the UNANNOTATED twin
        //     REMOVES the name there, which is why only the annotated spelling was affected.
        //   · a fn-typed parameter of a NESTED function or closure (`func inner(_ f: (String) -> Void)
        //     { f("x") }`) — collected into the ENCLOSING unit, whose signature never declared `f`.
        //   · in principle an alias-typed param whose `paramIndex` lookup above (~:1578) came back nil.
        // For any of those `fnTypedParamIndex` yields nothing, `idxs` stayed EMPTY, and the discharge
        // test downstream — `for idx in info.indexes { … }` over an initial `resolved =
        // !argLists.isEmpty` — iterated ZERO times. So `resolved` was TRUE for any caller at all,
        // `allCallersResolved` stayed true, and the `Unknown` was written to NEITHER the caller NOR
        // `fq`: a function that provably invokes an unaddressable value dropped out of `functions`,
        // which under ⟨0.21⟩ is an affirmative purity claim. With NO caller the `byCaller.isEmpty`
        // fallback still marked the row — which is exactly why the symptom was "the disclosure vanishes
        // the moment the enclosing function has a call site", and why two BYTE-IDENTICAL bodies in one
        // scan disagreed. Measured on `796700a`: `deny Unknown runAllWithCaller` exit 0,
        // `deny Unknown runAllNoCaller` exit 1 (UndischargeableCallbackNameProcessTests).
        //
        // THE FIX IS RECORDED HERE AND APPLIED AT THE JUDGMENT, and it is deliberately ADDITIVE-ONLY:
        // `deferredCallbacks` still carries the FULL `callbackInvoked` set, so every caller-side write
        // below stays byte-identical, and the undischargeable names are recorded ALONGSIDE it so the
        // judgment can refuse to let a vacuous verdict stand for `fq` itself.
        //
        // THE FIRST ATTEMPT WAS NOT ADDITIVE AND THE LOSS AUDIT CAUGHT IT. It removed the
        // undischargeable names from `info.names` and wrote their Unknown straight onto `f.qual`. That
        // fixed `fq`, and it took the reason AWAY from the callers `callsiteArgs` never tracked: a
        // caller with no recorded site takes the `resolved = !argLists.isEmpty` = FALSE branch below and
        // pre-fix received `Unknown` + `callback:<n>` DIRECTLY. Measured over 16 real packages: 4 rows
        // lost their whole `unknownWhy` (`EventLoopFuture._wait`, `ErrorMessageGenerator.makeErrorMessage`,
        // two `DetailViewController` members) while keeping `inferred: Unknown` by propagation. The
        // effect never moved and no gate flipped — but "the gate still fires" is a measurement of one
        // corpus, and recording the names instead of moving them makes REMOVED 0 a property of the code
        // rather than a result. The narrow write is per-name at the mark site below.
        if !cc.callbackInvoked.isEmpty {
            var idxs = Set<Int>()
            var undischargeable: Set<String> = []
            for n in cc.callbackInvoked {
                if let i = f.fnTypedParamIndex[n] { idxs.insert(i) }
                else {
                    undischargeable.insert(n)
                    if ProcessInfo.processInfo.environment["CANDOR_R720_PROBE"] != nil {
                        FileHandle.standardError.write(
                            "R720 undischargeable \(f.qual) :: \(n)\n".data(using: .utf8)!)
                    }
                }
            }
            deferredCallbacks[f.qual] = (idxs, cc.callbackInvoked)
            if !undischargeable.isEmpty { undischargeableCallbacks[f.qual] = undischargeable }
        }
        for var call in cc.calls {
            // VEIN A(i) — A CANONICAL FULL PATH (a shared simple name) IS ASKED PRECISELY FIRST, AND THE
            // RELEASE'S SPELLING IS THE FLOOR. The exact unit or the exact overload set answers it (R266/
            // R132: the namesake's member is not reached); where neither exists — an inherited member, a
            // protocol-extension default, a property the overload index keys short — the call is handed
            // on as the simple `Leaf.member` the release would have formed, so every arm keyed on simple
            // names answers it as before. Not where the leaf is ALSO a top-level type: there the simple
            // spelling is an EXACT key for the namesake, a wrong join, and the release left the dotted
            // spelling unanswered anyway.
            if !CallCollector.aiOff, call.typed, let dot = call.path.lastIndex(of: "."),
               aiSharedPaths.contains(String(call.path[..<dot])),
               !byQual.contains(call.path), !overloadedBasesPath.contains(call.path) {
                let type = String(call.path[..<dot]), member = String(call.path[call.path.index(after: dot)...])
                let leafType = type.split(separator: ".").last.map(String.init) ?? type
                if !localTypePaths.contains(leafType) { call.path = "\(leafType).\(member)" }
            }
            // SOUNDNESS R915 REACH — what a guessed-root typed local call resolved to (probe only).
            let r915Before = call.r915Site == nil ? nil
                : (edges[f.qual] ?? [], direct[f.qual] ?? [], whyMap[f.qual] ?? [])
            defer {
                if let site = call.r915Site, let b = r915Before {
                    let e = (edges[f.qual] ?? []).subtracting(b.0).sorted()
                    let d = (direct[f.qual] ?? []).subtracting(b.1).sorted()
                    let w = (whyMap[f.qual] ?? []).subtracting(b.2).sorted()
                    // classification of the hop (probe only): the hop member is the last `.x` of the receiver text
                    let recvText = site.split(separator: "\t").last.map(String.init) ?? ""
                    let hopMember = String(recvText.split(separator: ".").last ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "?!"))
                    let rt915 = call.path.lastIndex(of: ".").map { String(call.path[..<$0]) } ?? call.path
                    var cls: [String] = []
                    if hopMember.first?.isUppercase == true, localTypes.contains(hopMember) { cls.append("nested") }
                    let sups = (supertypesOf[rt915] ?? []).sorted()
                    for sp in sups { if let fi = fields[sp]?[hopMember] { cls.append("inh:\(sp)=\(fi.name ?? "nil")") } }
                    if let fi = fields[rt915]?[hopMember] { cls.append("own=\(fi.name ?? "nil")\(fi.isFunction ? "fn" : "")") }
                    let ext = sups.filter { !localTypes.contains($0) }
                    if !ext.isEmpty { cls.append("extsup:\(ext.joined(separator: "+"))") }
                    let selfEdge = e.contains(f.qual) ? "SELF" : ""
                    FileHandle.standardError.write("R915SITE\t\(f.qual)\t\(call.path)\t\(site)\tedges=\(e.joined(separator: ","))\tdirect=\(d.joined(separator: ","))\twhy=\(w.joined(separator: ","))\tcls=\(cls.joined(separator: ";"))\t\(selfEdge)\n".data(using: .utf8)!)
                }
            }
            // ⟨0.40⟩ the `<holds>` marker: a receiver hop whose DECLARED type a chained `holds` may give.
            // A hit joins the declared target (ADDED to whatever the guess beside it charges); a hit whose
            // join misses, or whose kind is unknown, ADDS `Unknown` (⟨0.23⟩'s miss rule, word for word).
            if call.path.hasPrefix("<holds>.") {
                guard !r843Off, let hop = call.holdsHop, !deps.isEmpty else { continue }
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                let (targets, distrusted) = holdsTargets(hop, file, call.ownerModule)
                for t in targets {
                    let a = surfaceAnswer(t, call.leaf, forcedProtocol: false)
                    applySurface(a, to: f.qual)
                    if !a.answered || distrusted {
                        direct[f.qual, default: []].insert("Unknown")
                        whyMap[f.qual, default: []].insert("dispatch:\(hop).\(call.leaf)")
                    }
                }
                if r843Probe, !targets.isEmpty {
                    FileHandle.standardError.write("R843HOLDS \(f.qual) \(hop).\(call.leaf) -> \(targets)\n".data(using: .utf8)!)
                }
                continue
            }
            // SHADOW GUARD: an UNQUALIFIED bare-name call (`helper()`) whose name is a NESTED func or a
            // closure-bound local in THIS unit resolves to that local — whose body already attributes
            // lexically here. Edging it ALSO to a same-named module-level/sibling free fn would FABRICATE
            // that free fn's effects onto this caller (the call-graph-key-collision class: the local unit is
            // never registered, so `freeFnByName[name]` has a single — wrong — candidate). Drop the edge.
            if call.unqualified, !call.typed,
               cc.localFuncs.contains(call.path) || cc.boundLocals.contains(call.path) { continue }
            let argc = call.args.count
            // A call that resolves to NO local edge is a reach into code the syntactic engine can't see — a
            // third-party blind module (NOT a fabrication: under-report, never a guess). Track it per call so
            // the per-fn `invisible` disclosure can name the blind modules in the fn's import scope. A call
            // that DOES resolve to a local unit is covered by transitive propagation of that unit's invisible.
            var resolved = false
            /// SOUNDNESS R651 — **THE RECEIVER'S TYPE IS IN `localTypes` ONLY BECAUSE THIS PACKAGE
            /// EXTENDS IT.** `CallCollector` sets `extOwner` on a TYPED call at exactly one site — the
            /// typed-local-receiver branch, and only when `declaredTypes` does NOT hold the root — so
            /// this marker IS the predicate, and no second copy of *"is this owner really ours?"* lives
            /// here (§F1.3, the two-implementations-of-one-question rule).
            ///
            /// It unlocks the two arms below that ASK A DEPENDENCY — the ⟨0.39⟩ obligation-1 / CHA arm
            /// and the §2 CANDOR_DEPS join — both of which were gated `!call.typed` and one of which is
            /// additionally gated `!localTypes.contains(owner)`. Local resolution above keeps first
            /// refusal untouched: these arms run only when it resolved NOTHING, so a member the
            /// consumer's own extension really does provide still wins outright.
            ///
            /// FAILS TOWARD OVER-CHARGE, which is the safe direction here and is a change of direction
            /// rather than of degree: the pre-fix behaviour was SILENCE (a ⟨0.21⟩ purity claim), and the
            /// join it re-enables is the same one every unextended consumer of the same dependency
            /// already gets — ONE hit across the file's covered imports or nothing (§2 rule 1), keyed
            /// `<pkg>#<owner>.<leaf>` on a receiver type the source spells out. A wrong answer here is a
            /// row with an effect too many, which a gate reads as a FAIL and a human then checks; the
            /// behaviour it replaces was a gate that passed.
            let r651Extended = call.typed && call.extOwner != nil
            // helper: edge to a resolved overload target (no callsiteArgs for sibling/init forms which don't
            // participate in callback-flow). For an overloaded base, matchOverloads returns 0 (drop), 1
            // (precise) or several (sound union) full quals.
            // MODULE-QUALIFIED FREE CALL (`Core.shared()`) — checked FIRST, because such a call is neither
            // `typed` (its base names a module, not a type) nor `unqualified`, so it reached no branch at
            // all and the caller came back silent-pure. Swift lets a call name the declaring module to
            // disambiguate, and it is how a wrapper delegates to a same-named implementation elsewhere
            // (`SwiftSyntaxMacrosTestSupport` → `SwiftSyntaxMacrosGenericTestSupport.assertMacroExpansion`).
            // Exact, not a guess: the base must be a real target that is NOT also a local type, and that
            // target must declare exactly one free function of the name — otherwise nothing resolves.
            if !call.typed, !call.unqualified, let modName = call.extOwner,
               !localTypes.contains(modName),                       // a real type shadows a module name
               let inMod = freeFnByModule[modName]?[call.leaf], inMod.count == 1 {
                edges[f.qual, default: []].insert(inMod[0])
                callsiteArgs[inMod[0], default: []].append((f.qual, call.args)); callsiteArgTypes[inMod[0], default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                resolved = true
            } else if call.extOwner == CallCollector.superMarker {
                // `super.m()` — resolve on the SUPERTYPE chain, never on the enclosing type: for an
                // override (`override func load() { super.load() }`) the enclosing type's own unit IS the
                // caller, so edging there would add nothing and the base's effect stayed silent. Walking the
                // chain also covers the different-name form (`func run() { super.other() }`). Every matching
                // supertype is edged — a union across a chain is sound, and an unresolvable `super` (an
                // external base) resolves to nothing, exactly as before.
                let member = call.leaf
                if let et = f.enclosingType {
                    for sup in supertypesOf[et] ?? [] where sup != et {
                        for t in resolveQual("\(sup).\(member)") {
                            edges[f.qual, default: []].insert(t)
                            callsiteArgs[t, default: []].append((f.qual, call.args)); callsiteArgTypes[t, default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                            resolved = true
                        }
                    }
                    // ACROSS THE SCAN BOUNDARY (SPEC §2). The walk above resolves against PROJECT units
                    // only, so when the base class lives in a CHAINED DEPENDENCY it matched nothing and the
                    // override read silent-pure — `class Sub: DepBase { override func load() { super.load()
                    // } }` where `DepBase.load` performs Fs. MEASURED on the two-package fixture: one
                    // package gives `Sub.load -> ['Fs']`; split with the dep report chained it vanished from
                    // `functions` entirely and `deny Fs` exited 0 with "policy ✓" — a false all-clear on
                    // identical source.
                    //
                    // The dep's report already carried the answer under exactly the key computable here
                    // (`DepLib#DepBase.load`); nothing looked for it, because the generic dep join below
                    // keys on `call.extOwner`, and for a `super.` call that is the literal `<super>` MARKER
                    // rather than a type — so the key it built could never match anything. Found by
                    // instrumenting `extOwner` for a different question and noticing the marker in the
                    // distribution.
                    //
                    // UNION over the chain, matching what the local walk above already does: the call runs
                    // exactly one implementation and a syntactic scan cannot say which, so covering all of
                    // them is the sound direction. Inheritance rather than an edge, because the dep's unit
                    // lives in another report and there is no node to edge to.
                    if !resolved, !deps.isEmpty {
                        let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                        for sup in supertypesOf[et] ?? [] where sup != et {
                            for (p, _) in deps.chainedPkgs(importing: fileImports[file] ?? []) {   // R565
                                // R867 — `lookupStatic`: a `super.` call is statically dispatched, so the
                                // override union published beside the base's body is not its answer.
                                if let de = deps.lookupStatic("\(p)#\(sup).\(member)") {
                                    if joinDebug { FileHandle.standardError.write("JOINSITE super \(f.qual) \(p)#\(sup).\(member)\n".data(using: .utf8)!) }
                                    applyDepEntry(de, to: f.qual)
                                    resolved = true
                                }
                            }
                        }
                    }
                }
            } else if call.typed {
                let typedTargets = resolveQual(call.path)   // hoisted: the else-if chain below reads it once
                if !CallCollector.aiOff, !overloadedBases.contains(call.path), overloadedBasesPath.contains(call.path) {
                    // VEIN A(i) — the exact overload set of a canonical FULL path (see the loop head).
                    for t in matchOverloadsPath(call.path, argc, call.argTypes, swiftModuleOf(f.loc)) {
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append((f.qual, call.args)); callsiteArgTypes[t, default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                        resolved = true
                    }
                } else if overloadedBases.contains(call.path) {
                    for t in matchOverloads(call.path, argc, call.argTypes, swiftModuleOf(f.loc)) {
                        resolved = true
                        guard extensionInitLabelsAdmit(call, t), operatorOperandsAdmit(call, t) else { continue }   // R1047, R1081
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append((f.qual, call.args)); callsiteArgTypes[t, default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                    }
                } else if !typedTargets.isEmpty {
                    for t in typedTargets where extensionInitLabelsAdmit(call, t) && operatorOperandsAdmit(call, t) {   // R1047, R1081
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append((f.qual, call.args)); callsiteArgTypes[t, default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                    }
                    resolved = true
                } else if let dot = call.path.lastIndex(of: "."),
                          localTypes.contains(String(call.path[..<dot])) {
                    // PROTOCOL-EXTENSION DEFAULT via a CONCRETE receiver: `Job.emit` didn't resolve (Job
                    // declares no `emit`), but Job conforms to a protocol whose EXTENSION defaults `emit`.
                    // Edge to the default body on each conformed supertype that provides it (bounded by the
                    // few protocols a type conforms to; a sound union if more than one). Resolves only REAL
                    // `<Proto>.<member>` units — a member no conformed protocol defaults edges nothing.
                    let type = String(call.path[..<dot])
                    let member = String(call.path[call.path.index(after: dot)...])
                    r1081Answered = false
                    for sup in supertypesOf[type] ?? [] {
                        let base = "\(sup).\(member)"
                        // AN OVERLOADED PROVIDED MEMBER MUST NOT VANISH. `resolveQual` can only name an
                        // UNAMBIGUOUS simple->full mapping (`qualBySimple[base].count == 1`); a protocol
                        // extension declaring a second, unrelated overload of the same base name
                        // (`run()` beside `run(times:)`) makes that count 2, so plain `resolveQual`
                        // returned nil and the whole edge — the ONLY call site to the provided member —
                        // was silently dropped, with no `Unknown`, exactly the cardinal sin this project
                        // exists to prevent. Route through `matchOverloads` instead, exactly as the
                        // sibling protoDispatches/existential-receiver arm above already does: `argc` and
                        // `call.argTypes` ARE available at this call site (the call is `s.run(times: 3)`,
                        // fully typed), so an arity/type-discriminated call resolves PRECISELY to the one
                        // real callee, and a genuinely ambiguous one gets the sound UNION rather than
                        // being dropped — the same over-approximate direction `matchOverloads` already
                        // takes everywhere else, never a guess at which one.
                        if overloadedBases.contains(base) {
                            for t in matchOverloads(base, argc, call.argTypes, swiftModuleOf(f.loc))
                                where operatorOperandsAdmit(call, t) || r1081Refused(type) {   // R1081
                                edges[f.qual, default: []].insert(t)
                                callsiteArgs[t, default: []].append((f.qual, call.args)); callsiteArgTypes[t, default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                                resolved = true
                            }
                        } else {
                            for t in resolveQual(base) where operatorOperandsAdmit(call, t) || r1081Refused(type) {   // R1081
                                edges[f.qual, default: []].insert(t)
                                callsiteArgs[t, default: []].append((f.qual, call.args)); callsiteArgTypes[t, default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                                resolved = true
                            }
                        }
                    }
                    if r1081Answered { resolved = true }   // SOUNDNESS R1081 — see `r1081Refused`
                    // No LOCAL supertype default resolved. If the type conforms to / inherits an EXTERNAL
                    // base (a super not declared locally — `final class Todo: Model` where Model is FluentKit's),
                    // the member is inherited from that external base's extension → it must NOT read silent (the
                    // inherited-into-project vein, conforms-to-external-protocol shape; found corpus-testing the
                    // Vapor template — `todo.save(on:)`/`Todo.query(on:)` read pure). A MODELED external
                    // protocol's verb is classified (Fluent `Model` CRUD → Db); an unmodeled external base whose
                    // body candor can't see → Unknown. This fires ONLY when `member` resolved to NO project unit
                    // (a same-named project method took resolveQual above), so it never fabricates over real
                    // project code. Std value protocols (Codable/Equatable/…) are excluded — their synthesized
                    // requirements are pure, so disclosing Unknown there would be false over-disclosure.
                    if !resolved {
                        // SORTED. `supertypesOf` is a [String: Set<String>], and a Set's iteration order
                        // varies between processes — so `.first` below picked a different supertype on
                        // different runs of the SAME binary on the SAME input. Effect sets were unaffected
                        // (Unknown either way), but the DISCLOSURE REASON churned: `dispatch:CodingKey.self`
                        // vs `dispatch:String.self`, and the per-function reason SET even changed size when
                        // two call sites happened to pick differently.
                        //
                        // That is not cosmetic. A/B diffing reports on real code is this project's primary
                        // evidence, and a report that differs from ITSELF injects noise into every diff —
                        // it cost a false datapoint before anyone thought to run a report against itself.
                        // It also makes `gains` noisy between identical inputs, which is product-facing.
                        // SOUNDNESS R1073 — A STDLIB OPERATOR ON A PLATFORM TYPE IS NOT BLAMED ON A LOCAL PROTOCOL.
                        // `localTypes` holds a protocol only once something EXTENDS it (`pushType`, R555), so
                        // `extension Int: AtomicPrimitive {}` over swift-nio's OWN `protocol AtomicPrimitive` left that
                        // protocol here as an "external" base, and every stdlib operator on a typed `Int` (`x % y`,
                        // `a == b`, `i &+ 1`) was hedged `dispatch:AtomicPrimitive.%` — 1,300+ reasons in swift-nio.
                        // NARROW on purpose (a first cut that dropped every local protocol for every member moved 1,176
                        // rows over a dozen unrelated protocols and was not taken): only an OPERATOR, only on a type
                        // this scan does not DECLARE (a platform type it merely extends, so the operator is that type's
                        // own), and only a local protocol that neither REQUIRES that operator nor provides it (an
                        // extension member reached through the concrete type resolved in the loop above). What such a
                        // protocol can still hide is what it inherits from a protocol this scan does not declare, so it
                        // is replaced by those external ancestors, transitively, rather than dropped.
                        let isOperator = member.first.map { !($0.isLetter || $0 == "_" || $0 == "`") } ?? false
                        // The NARROWED set decides only the final hedge below: the R657 dependency ask and the Fluent
                        // arm keep the release's set, so no join a chained report answers is skipped (measured: gating
                        // the ask on the narrowed set dropped 19 `dep:` reasons on swift-certificates).
                        let extSupers = (supertypesOf[type] ?? []).filter { !localTypes.contains($0) }.sorted()
                        let hedgeSupers: [String] = {
                            let raw = supertypesOf[type] ?? []
                            let legacy = extSupers
                            // A stdlib SCALAR (`RAND_ROOTS`: the integer, floating-point and Bool types) the scan does not
                            // declare, and whose operator no imported module's readable sources add in an `extension` of
                            // it (that would be a dependency's overload, which the hedge may be covering).
                            let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                            guard !r1073Off, isOperator, RAND_ROOTS.contains(type), !declaredTypes.contains(type),
                                  !cc.droppedMember,
                                  !(fileImports[file] ?? []).contains(where: { moduleExtensionMembers($0)?[type]?[member] != nil })
                            else { return legacy }
                            var out = Set<String>(), seen = Set<String>(), queue = Array(raw)
                            while let x = queue.popLast() {
                                guard seen.insert(x).inserted else { continue }
                                let localProto = localProtocolNames.contains(x) || protocolPaths.contains(x)
                                // A protocol the release already dropped (extended, so in `localTypes`) stays dropped,
                                // with no ancestors: this may only narrow what the release hedged, never add to it.
                                if localTypes.contains(x) { continue }
                                if localProto, protocolMethods[x]?.contains(member) != true {
                                    if r1073Probe, raw.contains(x) {
                                        FileHandle.standardError.write("VBHIT\tR1073\t\(f.qual) \(type).\(member) via \(x)\n".data(using: .utf8)!)
                                    }
                                    // A stdlib/platform protocol ancestor is not an external base this arm ever blamed.
                                    queue.append(contentsOf: (protocolSupers[x] ?? []).filter {
                                        !LAYOUT_SUPERS_PUBLIC.contains($0) && !STD_SUPERS_PUBLIC.contains($0)
                                            && PLATFORM_REFINES[$0] == nil && !PLATFORM_LEAVES.contains($0)
                                    })
                                } else if !localTypes.contains(x) { out.insert(x) }
                            }
                            return out.sorted()
                        }()
                        // SOUNDNESS R657 — ASK THE CHAINED DEPENDENCY BEFORE ANSWERING FROM LOCAL
                        // KNOWLEDGE. This whole block exists because the member's body is INVISIBLE; a
                        // chained report (SPEC §2) means it is not, and both answers below are guesses
                        // about a body somebody already analysed. `resolved = true` on either of them
                        // preempts the §2 join ~500 lines down, so the dependency's own row for exactly
                        // this key was never read — the consumer ended up reading MORE CERTAINTY than the
                        // report it was handed (R692, the cross-engine vein: candor-java's `crossDepJoin`
                        // gated on `effect == null` is the identical shape one engine over).
                        //
                        // MEASURED, one variable — whether the dependency's sources sit inside the scanned
                        // tree. `extension Chan: Marker { }` in the consumer, `Chan.poke` reading the
                        // environment in the dependency:
                        //     one tree            viaReceiver -> ['Env']      deny Env exit 1
                        //     split + chained     viaReceiver -> ['Unknown']  deny Env exit 0
                        // and the same pair for a dependency PROTOCOL-EXTENSION DEFAULT reached through a
                        // consumer's own conformer (`struct Mine: Sink`, `m.emit()`), which is the second
                        // trigger and is NOT a retroactive conformance — the row was filed from the first.
                        //
                        // TWO KEYS, MOST SPECIFIC FIRST, and both are keys this engine already publishes:
                        //   `<pkg>#<type>.<member>`  — the receiver type IS the dependency's type. This is
                        //     the key the ordinary §2 join would have formed had it not been preempted, so
                        //     this arm is a REORDER and nothing more.
                        //   `<pkg>#<sup>.<member>`   — the receiver is a LOCAL type conforming to the
                        //     dependency's protocol and the body is that protocol's extension default. The
                        //     ordinary join cannot reach it (its key names the local owner), and it is the
                        //     EXACT member this block was about to blame in `dispatch:<sup>.<member>`.
                        // Same never-guess discipline as every other join site: ONE hit or nothing, across
                        // the file's chained imports, and `!resolved` above means no local unit answered —
                        // a member the consumer really does provide still wins outright.
                        //
                        // IT FAILS TOWARD WITHDRAWING AN `Unknown` (or, above, a modeled `Db`) and
                        // REPLACING IT with the dependency's published row — i.e. it can only move a row
                        // from "this member is unanalysable" to "this member was analysed, here is what it
                        // does". That IS a disclosure removal and it is audited by
                        // `RetroactiveConformanceProcessTests`' control arms: an UNCHAINED consumer keeps
                        // the `Unknown` byte for byte, a key the dependency does not publish keeps it, and
                        // an AMBIGUOUS key keeps it. `CANDOR_R657_OFF=1` restores the preempting order so
                        // the defect rows can be shown to fail without a revert (§1b).
                        //
                        // SCOPED TO THE CALLS THE LOCAL ARMS WOULD HAVE CLAIMED, and that scoping is the
                        // whole of the removal audit's finding. A first cut asked the dependency whenever
                        // this block was reached, i.e. also when `extSupers` is EMPTY and NEITHER arm below
                        // would have fired. Those calls used to fall through to the ⟨0.39⟩ obligation-1
                        // publish site (`!resolved`, ~380 lines down) and then to the ordinary §2 join;
                        // answering them here produced the SAME effects by the SAME `applyDepEntry` and
                        // skipped the publish site in between. MEASURED on nio-ssl + nio-http2 with a live
                        // chain: 91 rows silently LOST a `dispatchesOn` key —
                        // `swift-nio#EventLoopPromise.fail`, `swift-nio#ByteBuffer.setInteger`,
                        // `swift-nio#ChannelPipeline.SynchronousOperations.addHandler` — because
                        // `extension EventLoopPromise where …` puts a dependency type in `localTypes`
                        // (R656) while adding no supertype. That is R656's own defect class reintroduced by
                        // R656's neighbour: a consumer row that stops naming the abstraction breaks
                        // obligation 3 one hop short. R657's row predicted exactly this — *"reordering a
                        // `resolved` short-circuit can withdraw whatever the later arm would have
                        // answered"* — so the lookup is gated on a local answer EXISTING, which makes this
                        // change a REORDER of two arms and not a new claim on any call.
                        let fluentEff = extSupers.compactMap({
                            FLUENT_MODEL_PROTOCOLS.contains($0) ? fluentModelEffect(member) : nil }).first
                        let unknownSup = extSupers.first(where: { !STD_PURE_PROTOCOLS.contains($0) })
                        var depAnswer: DepEntry?
                        if fluentEff != nil || unknownSup != nil, !deps.isEmpty,
                           ProcessInfo.processInfo.environment["CANDOR_R657_OFF"] == nil {
                            let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                            let pkgs = deps.chainedPkgs(importing: fileImports[file] ?? [])   // R565
                            for keys in [[type], extSupers.filter { !STD_PURE_PROTOCOLS.contains($0) }] {
                                var hits: [DepEntry] = []
                                for (p, _) in pkgs {
                                    for k in keys {
                                        if let e = deps.lookup("\(p)#\(k).\(member)") { hits.append(e) }
                                    }
                                }
                                if hits.count == 1 { depAnswer = hits[0]; break }
                                // ⟨0.25⟩ — two packages answering is a UNION, never a drop; the local
                                // fallback below still runs (its hedge or modeled effect is what v0.39.2 said).
                                if hits.count > 1, !joinUnionOff {
                                    for de in hits { applyDepEntry(de, to: f.qual) }
                                    break
                                }
                            }
                        }
                        if let de = depAnswer {
                            // REACH, counted on the CHANGED BRANCH (brief §E1): an unchanged row is not
                            // evidence the new code ran. `CANDOR_R657_PROBE=1` prints one line per call
                            // site this arm actually answered from a chained report.
                            if ProcessInfo.processInfo.environment["CANDOR_R657_PROBE"] != nil {
                                FileHandle.standardError.write(
                                    "R657HIT \(f.qual) -> \(type).\(member)\n".data(using: .utf8)!)
                            }
                            applyDepEntry(de, to: f.qual)
                            resolved = true
                        } else if let eff = fluentEff {
                            direct[f.qual, default: []].insert(eff)
                            resolved = true
                        } else if let sup = ((r1073Off || unknownSup == nil) ? unknownSup
                                                 : hedgeSupers.first(where: { !STD_PURE_PROTOCOLS.contains($0) })) {
                            direct[f.qual, default: []].insert("Unknown")
                            whyMap[f.qual, default: []].insert("dispatch:\(sup).\(member)")
                            resolved = true
                        }
                    }
                }
                // CHA OVER LOCAL SUBTYPES OF A TYPED RECEIVER. `a.run()` where `a: ABase` runs `ABase.run`
                // OR any subclass's `override func run()`, and only the first was edged: the hierarchy is
                // recorded (`conformers`/`subtypesOf` hold `AImpl -> ABase` — `pushType` puts class
                // inheritance in the same index as protocol conformance, and the `.hierarchy.json` sidecar
                // publishes it) but this dispatch site never consulted it, so an effectful override reached
                // through a base-class-typed receiver read silent-pure. No protocol and no extension needed;
                // AGENTS.md states the bounded-CHA contract for protocols only, which is what made the class
                // half easy to miss. The IMPORTED-owner arm below (`subtypesOf[owner]`, ~60 lines down)
                // already does exactly this when the base is a DEPENDENCY's type — this is the same query
                // for a base declared HERE.
                //
                // PRECISE-OR-NOTHING and ADDITIVE, copied from that arm: only real `<sub>.<member>` units
                // are edged (a member no subclass overrides contributes nothing — no Unknown flood), and
                // `resolved` is untouched so the external-supertype disclosure above and the §2 dep join
                // below still see the call exactly as they did. Both of that arm's fabrication carve-outs
                // apply for the same reasons: STD_PURE_PROTOCOLS because nearly every type conforms to
                // them, and RAW_VALUE_BASE_TYPES because `enum Suit: String` records `String` as a
                // supertype, so a String-typed receiver would otherwise dispatch into raw-value enums.
                if let dot = call.path.lastIndex(of: ".") {
                    let owner = String(call.path[..<dot])
                    let member = String(call.path[call.path.index(after: dot)...])
                    if !STD_PURE_PROTOCOLS.contains(owner), !RAW_VALUE_BASE_TYPES.contains(owner) {
                        for sub in (subtypesOf[owner] ?? []).sorted() where sub != owner {
                            edges[f.qual, default: []].formUnion(resolveQual("\(sub).\(member)"))
                        }
                    }
                }
            } else if call.unqualified {
                // an UNQUALIFIED `name(…)` call: a free function, a constructor, or a self-sibling method. A
                // `recv.member(…)` whose receiver type couldn't be resolved is NOT here — it must never be
                // guessed onto a same-named sibling/free fn (Get's `handler.delegate?.urlSession?(…)` forwards
                // to an EXTERNAL delegate; resolving it to self's `urlSession` overload cluster unioned a
                // sibling's real Fs onto the pure forwarder — a fabrication).
                // SOUNDNESS R255 — A MEMBER OF `self` BEATS A MODULE-SCOPE FUNCTION OF THE SAME NAME, and
                // these three member arms therefore run BEFORE the free-function arms. They used to run
                // after, so
                // `func wipe(_:)` at module scope beside `class Base { func wipe(_:) }` made the free function
                // claim the call and BOTH `SubA.caller` (inherited) and `OwnB.caller` (own class) were ABSENT
                // from `functions[]` — a real, EXECUTED file deletion certified silent-pure while the pure
                // global was charged in its place.
                //
                // NOT A JUDGEMENT CALL — the compiler settles it, and it also removes the fallback case this
                // reorder would otherwise have to preserve. Swift's unqualified lookup stops at the innermost
                // scope holding the name and never widens to module scope, so a program where the member
                // exists but its SIGNATURE does not match DOES NOT COMPILE:
                //     error: use of 'wipeC' refers to instance method rather than global function 'wipeC' in
                //            module 'shadow' — note: use 'shadow.' to reference the global function
                // There is no arity-mismatch arm to fall through to; the only way to reach the global is to
                // spell the module (`shadow.wipeC(p)`), which is not an unqualified call and never lands here.
                // So when a member arm matches by name, edging the global instead is a FABRICATION, and
                // resolving to nothing when its overloads do not match is the pre-existing honest answer for a
                // member call — this reorder extends that behaviour to the shadowed case, it does not add it.
                //
                // OPERATORS ARE EXCLUDED, and that is a second fact about the language rather than
                // caution. Swift does NOT resolve an operator by lexical scope: `a == b` is resolved by
                // OVERLOAD RESOLUTION OVER THE OPERAND TYPES across every visible declaration, so the
                // enclosing type's own `==` has no priority at all. MEASURED on Kingfisher: without this
                // gate, `r1.cacheKey == r2.cacheKey` — a String comparison — inside
                // `extension Source: Hashable { static func == }` resolved to `Source.==` itself, and
                // `Source.==` LOST its `Unknown` disclosure while three `KFImage.Context` rows dropped
                // out of `functions[]` entirely. A disclosure loss, i.e. the exact direction this reorder
                // exists to close, introduced by the reorder. `memberFirst` is the identifier test.
                // …and the exclusion is scoped to the ORDERING DECISION ALONE. Gating the member arms
                // outright would ALSO change how an operator resolves when no free-function arm claims
                // it — a THIRD question, pre-existing, and worth 802 changed rows across this corpus
                // when measured. `freeArmWouldClaim` keeps operators on exactly the old path: an
                // operator reaches a member arm only in the cases where it already did.
                let freeArmWouldClaim = overloadedBases.contains(call.path)
                    || (freeFnByName[call.path]?.count == 1)
                    || localTypes.contains(call.path)
                // SOUNDNESS R267 — the operator test is `swiftLeafIsOperator` (a DENYLIST over the
                // grammar's `operator-head`), not "starts with a letter". The old allowlist classified
                // every BACKTICK-ESCAPED and raw identifier as an operator, because SwiftSyntax keeps the
                // backticks in the leaf. See that function for the 232-red-cell measurement.
                let memberFirst = !swiftLeafIsOperator(call.leaf) || !freeArmWouldClaim
                // SOUNDNESS R265 / R266 — the three member arms are resolved BEFORE the chain branches,
                // because two things now have to be true of a candidate before it may claim the call, and
                // both of them can empty an arm that used to match:
                //
                //   * R266 — IT MUST BE THE CALLER'S OWN TYPE'S MEMBER, keyed on the FULL nested path.
                //     `overloadedBases` and `supertypesOf` are keyed on the SHORT type name, so
                //     `enum Outer { class S }` and an unrelated top-level `class S` shared one key: an
                //     unqualified call inside the nested type edged into the OTHER type's members, and
                //     R255 moved these arms in FRONT of the free arms, so the collision now pre-empts a
                //     call Swift binds to a global. Executed: 16 of a 1152-cell matrix gained an unrelated
                //     `Clock`, 4 of them also losing the real member. Arm 2 was already path-precise and
                //     its comment SAID SO — the two siblings it names were the ones that were wrong.
                //     Keying arm 1 on the path also closes the opposite miss: a caller in
                //     `extension Outer.S` has `enclosingType == "Outer.S"` (an extension pushes the whole
                //     dotted spelling as ONE stack element), so the short-keyed lookup missed its own
                //     overloaded sibling and fell to the global.
                //   * R265 — IT MUST BE VISIBLE HERE. See `memberVisibleAt`.
                //
                // When every arm is empty the chain falls through to the free-function arms exactly as it
                // did before R255 — which is the correct answer precisely when no member is visible.
                let callerFile = f.loc.split(separator: ":").first.map(String.init) ?? f.loc
                let visibleHere: (Set<String>) -> Set<String> = { cands in
                    cands.filter { memberVisibleAt($0, callerFile, f.enclosingTypePath) }
                }
                var siblingOverloads: Set<String> = []
                if memberFirst, let ep = f.enclosingTypePath, overloadedBasesPath.contains("\(ep).\(call.leaf)") {
                    siblingOverloads = visibleHere(Set(matchOverloadsPath("\(ep).\(call.leaf)", argc,
                                                                          call.argTypes, swiftModuleOf(f.loc))))
                }
                var siblingExact: Set<String> = []
                if memberFirst, siblingOverloads.isEmpty, let ep = f.enclosingTypePath,
                   byQual.contains("\(ep).\(call.leaf)") {
                    siblingExact = visibleHere(["\(ep).\(call.leaf)"])
                }
                var inheritedTargets: Set<String> = []
                if memberFirst, siblingOverloads.isEmpty, siblingExact.isEmpty, let et = f.enclosingType {
                    // R266 — narrow to the path-keyed climb ONLY where the short name is proven ambiguous;
                    // everywhere else the short index answers exactly as R134 left it, UNIONED with the
                    // path climb (which adds nothing when the name is unique, and is the only index that
                    // answers for a nested type).
                    //
                    // SOUNDNESS R277 — and the short key is `et`'s LAST COMPONENT, not `et`. An
                    // `extension Outer.S` pushes the whole dotted spelling as ONE `typeStack` element, so
                    // `enclosingType` there is `"Outer.S"` while `conformers`/`supertypesOf` were keyed
                    // `"S"` at the DECLARATION — the climb looked up a key that cannot exist and returned
                    // empty, and R255 then handed the call to a same-named module-scope function. Silent
                    // at v0.35.0 as well as at HEAD: 96 cells of the matrix, every one a caller in an
                    // extension of a nested type reaching an INHERITED member, both effect polarities.
                    let etShort = et.split(separator: ".").last.map(String.init) ?? et
                    var raw: Set<String>
                    if (typePathsBySimple[etShort]?.count ?? 0) > 1, let ep = f.enclosingTypePath {
                        raw = inheritedUnqualTargetsPath(ep, call.leaf, argc, call.argTypes, swiftModuleOf(f.loc))
                    } else {
                        raw = inheritedUnqualTargets(etShort, call.leaf, argc, call.argTypes, swiftModuleOf(f.loc))
                        if let ep = f.enclosingTypePath {
                            raw.formUnion(inheritedUnqualTargetsPath(ep, call.leaf, argc, call.argTypes,
                                                                     swiftModuleOf(f.loc)))
                        }
                    }
                    inheritedTargets = visibleHere(raw)
                }

                if !siblingOverloads.isEmpty {                            // overloaded sibling
                    for t in siblingOverloads.sorted() {
                        edges[f.qual, default: []].insert(t)
                        resolved = true
                    }
                } else if !siblingExact.isEmpty {
                    // an unqualified call inside a type body reaches the sibling method — resolved against the
                    // FULL enclosing path, so a nested type's sibling call hits its own member precisely (never
                    // a same-named sibling under a different parent).
                    for t in siblingExact.sorted() {
                        edges[f.qual, default: []].insert(t)
                        resolved = true
                    }
                } else if !inheritedTargets.isEmpty {
                    // R134 — THE INHERITED member reached by the IMPLICIT-SELF spelling. Every arm above
                    // resolves `call.leaf` against the ENCLOSING TYPE only (`byQual`/`overloadedBases` keyed
                    // on `ep`/`et`), so `class Sub: Base { func caller(p) { wipe(p) } }` — `wipe` declared on
                    // `Base` — matched nothing and `Sub.caller` was ABSENT from `functions[]` entirely, under
                    // the "nothing hidden" clean bill. EXECUTED ground truth: the file is really deleted, and
                    // `deny Fs Sub.caller` / `pure Sub.caller` / `deny Unknown Sub.caller` /
                    // `deny Fs Unknown Sub.caller` all exited 0; a blanket `deny Fs` exits 1 only
                    // INCIDENTALLY, via `Base.wipe`, never naming the caller.
                    //
                    // PARITY WITH `super.`, which is the right target and not a coincidence: `wipe(p)` and
                    // `super.wipe(p)` run the SAME body whenever the subclass declares no `wipe` of its own,
                    // and that is exactly the case this arm sees — the sibling arms above already claimed
                    // every call an override would answer, so an override can never be shadowed by this
                    // climb. The `super.` arm (`CallCollector.superMarker`, ~200 lines up) has climbed
                    // `supertypesOf` since the initializer-edge vein; the property/subscript accessor path
                    // climbs too, and its comment at the `propertyEdges` loop asserts it does so "exactly as
                    // the method-call path does" — an assertion that was FALSE for this spelling, which is
                    // §E2/§F1.3 (two paths answering one question, drifted) on top of the hole itself.
                    // SOUNDNESS R22 had already closed this for accessors reached through an EXPLICIT
                    // receiver; the implicit spelling kept the hole.
                    //
                    // MEASURED, 18 executed shapes: THIRTEEN were silent, not one — two-level
                    // `Base -> Mid -> Sub`, a generic base, a member declared in `extension Base`, a
                    // protocol-extension default (struct AND via a class hierarchy), a caller declared in
                    // `extension Sub`, an inherited `class func` from a static caller, the call nested in a
                    // closure, an argument-labelled call, a protocol requirement witnessed on the base, a
                    // conformance spelled on `extension S: P`, and a nested `enum Outer { class S: B }`.
                    // `supertypesOf` is TRANSITIVE (built from the transitive `subtypesOf`), so one lookup
                    // covers the whole chain.
                    for t in inheritedTargets.sorted() {
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append((f.qual, call.args)); callsiteArgTypes[t, default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                        resolved = true
                    }
                } else if overloadedBases.contains(call.path) {            // an overloaded FREE function
                    for t in matchOverloads(call.path, argc, call.argTypes, swiftModuleOf(f.loc))
                        where operatorOperandsAdmit(call, t) {   // R1081
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append((f.qual, call.args)); callsiteArgTypes[t, default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                        resolved = true
                    }
                } else if let targets = freeFnByName[call.path], targets.count == 1, operatorOperandsAdmit(call, targets[0]) {   // R1081
                    edges[f.qual, default: []].insert(targets[0])
                    callsiteArgs[targets[0], default: []].append((f.qual, call.args)); callsiteArgTypes[targets[0], default: []].append((f.qual, call.argTypes, call.genericForward, call.witnessArgs))
                    resolved = true
                } else if localTypes.contains(call.path), overloadedBases.contains("\(call.path).init") {
                    // R1047 — `resolved` keeps the release's answer (a matched overload); only the EDGE is filtered.
                    for t in matchOverloads("\(call.path).init", argc, call.argTypes, swiftModuleOf(f.loc)) {
                        if extensionInitLabelsAdmit(call, t) { edges[f.qual, default: []].insert(t) }
                        resolved = true
                    }
                } else if localTypes.contains(call.path) {
                    // `_ = C0()` — a constructor call edges to the declared init (the fuzzer's init_wired
                    // form caught this silent-pure hole on the harness's FIRST run: effects wired in an
                    // initializer vanished — the same hole the TS engine's got-dogfood found in ctors).
                    // Constructing a local type is a fully-resolved LOCAL reach (touches no κ-unknown module),
                    // so mark resolved REGARDLESS of whether an explicit `init` unit exists — a synthesized
                    // init has no unit to edge to but the construction is still local; without this the caller
                    // was falsely tagged `invisible` (the over-disclosure regression, sweep [36]).
                    edges[f.qual, default: []].formUnion(resolveQual("\(call.path).init").filter { extensionInitLabelsAdmit(call, $0) })
                    resolved = true
                } else if !call.argRef, !call.argLabelled,
                          NATIVE_DISCLOSURE_C_FREE_FNS.contains(call.path),
                          argc > 0 || NATIVE_DISCLOSURE_C_NULLARY_FNS.contains(call.path) {
                    // R61 — every arm above tried and failed to resolve `call.path` against something THIS
                    // scan can see (a project free fn, a local ctor, a sibling). `system("rm -rf /")` and
                    // `unlink(path)` under `import Darwin` ended here, unresolved, and this branch used to
                    // be silence: no `Unknown`, no `unresolved`, nothing — exit 0 under `deny Exec`/`deny Fs`.
                    // `NATIVE_DISCLOSURE_C_FREE_FNS` is an ALLOWLIST, not a denylist — see its doc comment
                    // for why: gating on "unresolved AND the file imports a C module", with NO name
                    // restriction, MEASURED 1519 false hits on swift-nio alone (`os`/`canImport` `#if`
                    // predicates, `assert`/`fatalError`, bare operators — none of them FFI).
                    //
                    // R130 — AND THE C-MODULE-IMPORT CHECK IS GONE. It read as the half that made a hit
                    // trustworthy; what it actually did was make the whole allowlist a SILENT UNDER-REPORT
                    // on the commonest spelling. Foundation re-exports Darwin on Apple platforms, so
                    // `import Foundation` + `symlink(a, b)` compiles, RUNS, creates a real symlink on disk
                    // — and reported `functions: 0` with all five policy forms exit 0, against an
                    // `import Darwin` arm identical in every other byte that reported `Unknown` +
                    // `native:symlink`. The gate was an allowlist of MODULES sitting in front of an
                    // allowlist of NAMES, and only the names were ever load-bearing: see
                    // `C_PLATFORM_MODULES` for the A/B and for the two real-corpus shapes (swift-nio's
                    // `dlopen`/`dlsym` under `import Atomics`/`NIOCore`, swift-tools-support-core's
                    // `unlink` under selective `import class Foundation.FileHandle`) that no module list
                    // could have covered.
                    //
                    // `!call.argLabelled` is the one narrowing that replaced it, and it is a fact about
                    // Swift rather than a guess about intent: a C function imported into Swift has NO
                    // argument labels, so `remove(at: index)` cannot bind to libc's `remove`. Measured: it
                    // removes 2 of the 3 false hits gate-removal costs across 13 real packages. The third
                    // — `remove(element)` on an `OptionSet` — is syntactically identical to a libc
                    // `remove(path)` and stays disclosed, in the fail-closed direction.
                    //
                    // R135 — AND `argc > 0`, THE SAME KIND OF FACT, ON THE ARITY. R130's own exclusion
                    // rule was "this name is ALSO A TYPE" (`stat`/`statfs`), and the same commit added
                    // `flock` without applying it: `struct flock` is the fcntl advisory-lock record and
                    // `var fl = flock()` is how you build one, so this branch charged `Unknown` +
                    // `native:flock` to a function that touches no fd and no path (executed:
                    // `describeLock() = 3`, and `deny Unknown describeLock` exited 1 over it).
                    // `!call.argLabelled` CANNOT catch that — a struct construction carries no labels
                    // either, so `flock()` and `flock(fd, LOCK_EX)` are byte-identical on every other
                    // field this arm can read. The count is the only thing that distinguishes them.
                    //
                    // NOT a blanket "zero args ⇒ not C": `fork(void)`/`vfork(void)` really are nullary, so
                    // they are exempted BY NAME through `NATIVE_DISCLOSURE_C_NULLARY_FNS`, whose doc holds
                    // the per-name arity measurement. A blanket gate here would have swapped a fabrication
                    // for a silent under-report on process creation.
                    //
                    // `argc` is `call.args.count`, the SAME authority `matchOverloads` uses a few arms up
                    // — not a second count computed for this branch (§F1.3). The one Call construction
                    // site that does not populate `args` is the bare-identifier ARGUMENT form, and it sets
                    // `argRef: true`, which this arm already rejects on its first condition;
                    // `CNativeDisclosureArityProcessTests.testEveryUnqualifiedCallSiteRecordsItsArguments`
                    // pins that over the source rather than leaving it as a claim in this comment.
                    direct[f.qual, default: []].insert("Unknown")
                    whyMap[f.qual, default: []].insert("native:\(call.path)")
                }
            }
            // otherwise: unresolvable bare member (unresolved receiver) — stays out (under-report, never a
            // guess); the κ ledger and Unknown rules above carry the honesty.
            // DISPATCH OVER AN IMPORTED PROTOCOL/BASE WHOSE CONFORMERS ARE LOCAL. `s.speak()` where
            // `s: Speaker`, `Speaker` is a DEPENDENCY's protocol and `final class AppSpeaker: Speaker` is
            // declared HERE: `protocolMethods`/`protoParams` are local-only, so `s` was never recognised as
            // protocol-typed and no dispatch was recorded at all — the call read silent-pure even though the
            // witness that runs is a project unit candor analysed correctly two files away
            // (candor-spec/SOUNDNESS-VEIN-crossing-the-scan-boundary.md; `trait_decls is local-only` is the
            // rust sibling). This half is recoverable with NO dep report — the conformance declaration is
            // ours — and `conformers` already records it: Swift's inheritance clause is where a conformance
            // to an imported protocol is spelled, so `subtypesOf[Speaker]` holds our conformers.
            //
            // PRECISE-OR-NOTHING and ADDITIVE. Only real `<conformer>.<member>` units are edged, so a member
            // no conformer declares contributes nothing (no Unknown flood over every external-typed
            // receiver). `resolved` is deliberately NOT set: the local conformer set is a LOWER bound on the
            // true one — a dependency's own conformers are still invisible — so the call keeps its κ/blind
            // disclosure AND still reaches the §2 join below (which is what carries a chained sibling's
            // conformers, via its protocol-CHA union entries).
            //
            // Two carve-outs, both fabrication guards on Swift's OVERLOADED inheritance clause (the same
            // hazard the stringification witness table documents). STD_PURE_PROTOCOLS: their requirements
            // are synthesized and pure, and nearly every type conforms, so CHA there would union unrelated
            // project methods onto `Codable`/`Hashable`/`Sequence`-typed receivers. RAW_VALUE_BASE_TYPES:
            // `enum Suit: String` records `String` as a supertype, so without the carve-out a call on any
            // String/Int-typed value would dispatch into raw-value enums' methods — a pure fabrication.
            // ERASURE, and it belongs HERE rather than at the binding. `some P` is opaque: the CALLER
            // picks one conforming type, so the local conformers are not this receiver's witnesses and
            // unioning them fabricates. `any P` is an existential and genuinely may be any of them.
            // Only THIS arm is suppressed — the §2 dep join below still runs on an opaque receiver, and
            // soundly, since every monomorphization must conform to P. An earlier version enforced the
            // distinction by withholding the receiver's TYPE, which took the dep join with it and made an
            // Fs-performing function read PURE.
            // SOUNDNESS R651 — `r651Extended` relaxes exactly two of these conjuncts, and only together:
            // `!call.typed`, because the typed-local-receiver branch is where an extension-only owner is
            // emitted; and `!localTypes.contains(owner)`, which asks *"is this type ours?"* and answers
            // YES for a type this package merely extends. The fabrication carve-outs below
            // (`STD_PURE_PROTOCOLS`, `RAW_VALUE_BASE_TYPES`) are NOT relaxed — they are what stops
            // `extension String { … }` in a consumer publishing `Pkg#String.lowercased` and CHA-ing into
            // every `enum Suit: String` in the package.
            // SOUNDNESS R705 — **IS THIS CALL AN ERASED DISPATCH OVER AN ABSTRACTION THIS SCAN DOES NOT
            // DECLARE?** Non-nil names the abstraction; nil means this row is not R705's population and
            // nothing below may hedge. See the disclosure at the end of this call's processing.
            //
            // The two spellings are ONE question and both reach it here rather than at two sites:
            //   · `_ t: some P`         — `opaqueRecv`, set from `isOpaqueParam` at the binding
            //   · `<T: P>(_ t: T)`      — the spelled owner is a type PARAMETER, resolved through the SAME
            //                             two indexes `dispatchAbstraction` reads (function bound first,
            //                             then the enclosing type's), not a third copy of the question.
            // `isOpaqueParam`'s own doc says these are the same thing under two spellings, so answering
            // one and not the other would be §F1.3 again.
            //
            // THE FENCES ARE THIS ARM'S OWN, plus the third conjunct the `<untyped>` disclosure below
            // already carries and for its reason: for an UNCHAINED package the κ ledger discloses
            // `invisible: [M]`, so a second disclosure there would be pure false uncertainty — it is
            // precisely when the package IS chained that the ledger correctly falls silent (§2 rule 3)
            // and the silence becomes the claim worth spending a disclosure on. `STD_PURE_PROTOCOLS`
            // matters most of all here: `Sendable`, `Collection`, `Sequence`, `Equatable`, `Hashable`
            // are the commonest generic bounds in Swift, their requirements are synthesized and pure,
            // and without that carve-out this would disclose over half the generic code in any package.
            let r705Off = ProcessInfo.processInfo.environment["CANDOR_R705_OFF"] != nil
            let r705UOff = ProcessInfo.processInfo.environment["CANDOR_R705U_OFF"] != nil   // §1b, the unchained arm
            var veinDUndecided: String? = nil   // VEIN D — set at the obligation-1 site, disclosed after the join
            let erasedForeignDispatch: String? = {
                guard !r705Off, !call.unqualified, let owner = call.extOwner else { return nil }
                let bound = f.genericBounds[owner]
                    ?? f.enclosingType.flatMap { et in typeGenericBoundsAll[et]?[owner] }
                guard call.opaqueRecv || bound != nil else { return nil }
                let abs = bound ?? owner
                guard !localTypes.contains(abs), !localProtocolNames.contains(abs),
                      !STD_PURE_PROTOCOLS.contains(abs), !RAW_VALUE_BASE_TYPES.contains(abs),
                      !localTypes.contains(owner), !localProtocolNames.contains(owner) else { return nil }
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                // SOUNDNESS R705 (unchained arm) — the κ ledger's `invisible: [M]` is NOT a sufficient disclosure here,
                // which the paragraph above assumed: it names the dependency that DECLARES the abstraction, while the
                // witness the caller passes may be a LOCAL conformer. Executed (`swiftagent-v043/fx/r705u`): a local
                // `Mine: Sink` deleting a file through `viaGen<T: Sink>` read `[]` + `invisible: [Iface]`, `deny Fs
                // Unknown viaGen` exit 0, while the count-0 and one-tree arms said `Unknown`. Fenced exactly as R706's
                // residual is — the file's ONE dependency module, uncovered, and not a platform/stdlib protocol —
                // because the wider fence ("any blind import") measured 7 false rows over platform protocols
                // (`UIGestureRecognizer`, `NSTextInputClient`, `Escapable`) and 0 true ones.
                if deps.chainedPkgs(importing: fileImports[file] ?? []).isEmpty {
                    guard !r705UOff, !PLATFORM_PROTOCOL_NAMES.contains(abs), !STDLIB_ITERATION_PROTOCOLS.contains(abs),
                          let m = foreignOwnerModule(inFile: file), blindModules(inFile: file).contains(m) else { return nil }
                    if r706iProbe { FileHandle.standardError.write("VBHIT\tR705U\t\(f.qual) \(abs).\(call.leaf)\n".data(using: .utf8)!) }
                }
                return abs
            }()
            // ── SOUNDNESS R705 — THE ERASED-FOREIGN DISPATCH IS PRECISE-OR-NOTHING, AND "NOTHING"
            //    READS AS A POSITIVE PURITY CLAIM ────────────────────────────────────────────────────
            //
            // A dependency declares the abstraction; THIS package declares its ONLY implementor and
            // dispatches through the bound. Measured one-tree-vs-split on the same bytes, one variable
            // (the receiver's spelling), everything else identical, at `709311c`:
            //
            //     _ t: Sink / any Sink     split ['Env']   tree ['Env']        ← control, unchanged
            //     <T: Sink>(_ t: T)        split  []       tree ['Env']   `unresolved: false`
            //     _ t: some Sink           split ABSENT    tree ['Env']
            //
            // **THE FIRST READING OF THAT TABLE IS WRONG AND THE FIXTURE BELOW THIS FILE PROVES IT.**
            // The obvious fix — make the erased spellings union the local conformers, like the
            // existential — reverses `d62dd69` and reds SIXTEEN assertions in
            // `ScanBoundaryVeinProcessTests`, which pins exactly that as a FABRICATION with call sites
            // that pass only the PURE conformer: `some P` / `<T: P>` is monomorphized BY THE CALLER, so
            // this package's conformers are not this receiver's witnesses, and candor-rust reached the
            // same conclusion from the other side (see `isOpaqueParam`). Measured, not reasoned: the
            // union was implemented, and those sixteen went red. The erasure carve-out stays.
            //
            // WHAT IS ACTUALLY WRONG IS THE OTHER CONJUNCT — the rust R693 shape, two locally-correct
            // decisions whose INTERSECTION is silent. The carve-out withholds the edge (right), and this
            // arm is PRECISE-OR-NOTHING with **no disclose-on-miss** (wrong), so the row comes out
            // `inferred: []`, `unresolved: false` — an affirmative claim that the call reaches nothing —
            // while the LOCAL protocol-CHA loop below answers the identical question with `Unknown` +
            // `dispatch:<P>.<member>`. The fix is at the END of this call's processing, where whether
            // anything ANSWERED is known; see the R705 disclosure there. `resolved` is what tells them
            // apart, which is why the hedge cannot live in this arm.
            if !resolved, !call.typed || r651Extended, !call.unqualified, !call.opaqueRecv,
               let owner = call.extOwner,
               !localTypes.contains(owner) || r651Extended, !STD_PURE_PROTOCOLS.contains(owner),
               !RAW_VALUE_BASE_TYPES.contains(owner) {
                // SOUNDNESS R651 REACH — the CHA/obligation-1 half, counted separately from the §2 join
                // below because they move different fields (`inferred` via a local override vs
                // `dispatchesOn`), and a diff keyed on effects alone cannot see the second.
                if CallCollector.r651Probe, r651Extended {
                    FileHandle.standardError.write(
                        "R651CHA \(f.qual) -> \(owner).\(call.leaf) subs=\((subtypesOf[owner] ?? []).count)\n"
                            .data(using: .utf8)!)
                }
                for sub in subtypesOf[owner] ?? [] {
                    edges[f.qual, default: []].formUnion(resolveQual("\(sub).\(call.leaf)"))
                }
                // ⟨0.39⟩ OBLIGATION 1 OVER A FOREIGN ABSTRACTION — SOUNDNESS R504's shape, the MIDDLE
                // package that owns neither the abstraction nor any implementor of it. The loop above is
                // this package's own LOWER bound on the witness set; naming the member is what lets a
                // CONSUMER add the rest, and without it the chain breaks one hop short and the consumer's
                // row is ABSENT — under ⟨0.21⟩ a positive claim of purity.
                //
                // DELIBERATELY THE SAME SITE AND THE SAME CONJUNCTS as the CHA above, not a second
                // judgement about what may be a dispatch. Those guards are this engine's existing answer
                // to exactly that question, fabrication carve-outs included: `STD_PURE_PROTOCOLS` because
                // nearly every type conforms to them, and `RAW_VALUE_BASE_TYPES` because `enum Suit:
                // String` records `String` as a supertype. A first cut recorded at its own site with its
                // own conjuncts and published `DepLib#String.lowercased` — a key naming an owner the
                // package does not have — which `testRawValueBaseDoesNotDispatchIntoItsEnums` caught, the
                // same class candor-rust's nine `io#Write::write_all` rows were.
                //
                // AND THIS ENGINE CANNOT SEE THAT THE CALL IS A DISPATCH, which is a real difference from
                // the other three and is recorded rather than smoothed over: rust reads `&dyn
                // iface::Backend`, java reads INVOKEINTERFACE, ts reads the named import — Swift source
                // says only `b.size()` on a parameter typed `Backend`, and whether `Backend` is a
                // protocol, a class or a struct lives in a module this scan never opened. So the member is
                // named for every surviving unresolved member call on a dependency-owned receiver. That
                // over-approximates "dispatch" in the only direction that is safe: the key published is
                // the key the consumer's ordinary §2 join would form for the same call, so a union under
                // it charges what the call really reaches — a concrete method's entry when the owner is
                // concrete, the implementors' union when it is an abstraction — never a body the call
                // cannot reach.
                //
                // R532 — AND THE SPELLING IS RESOLVED THROUGH `dispatchAbstraction` BEFORE IT BECOMES A
                // KEY. `owner` is the receiver's spelled type, which for `<T: Handler>(_ h: T)` is the
                // TYPE PARAMETER. See that function for the measurement; the edge loop above deliberately
                // keeps the raw spelling, because a monomorphized generic's witnesses are the caller's,
                // not ours.
                //
                // SOUNDNESS R555 — AND WHOSE ABSTRACTION IT IS IS DECIDED HERE, LOCAL FIRST. The owner
                // module used to be `foreignOwnerModule` unconditionally, on the reasoning that a LOCAL
                // bound had already been refused upstream — and that refusal cannot fire for a protocol,
                // which is nearly every bound (see `dispatchAbstraction`'s R555 paragraph). So a protocol
                // THIS package declares was published under a DEPENDENCY's module: measured on swift-nio,
                // 15 keys / 33 occurrences / 29 rows spelling `CNIOAtomics#AtomicPrimitive.*` and
                // `CNIOAtomics#NIOAtomicPrimitive.*` for two protocols declared in NIOConcurrencyHelpers
                // itself. That key is dead in both directions: no consumer can join it (obligation 3's
                // `unionOwnImplementors` gates on `abstractionOwnerPkg[proto] == keyPkg`, and obligation
                // 2 already answers `pkgName` for a local protocol), and it names an abstraction the
                // module it names does not have — the `DepLib#String.lowercased` class again.
                //
                // `localProtocolWirePath` is THE existing answer to "is this spelling a protocol of ours,
                // and what is its wire path" — the same function the in-scan protocol-CHA publish site
                // keys with, not a second copy (§F1.3), so the two sites that spell one abstraction can
                // no longer disagree (R549's shape). It also carries the nested-path and AMBIGUOUS-leaf
                // rules for free. An ambiguous leaf returns nil and therefore keeps the foreign spelling
                // rather than gaining a guessed local one: refusing to decide must not be spelled as a
                // decision.
                //
                // `foreignOwnerModule` IS STILL THE TRIGGER, and that is deliberate even though the local
                // branch does not use `m`. Dropping it was implemented and MEASURED first: it publishes a
                // local key in files with no decidable dependency import too — 18 further sites, 10 new
                // rows — and 4 of those keys name a member the protocol does not have
                // (`_CollectionsTestSupport#_SortedCollection.distance`; `_SortedCollection` is an EMPTY
                // marker protocol and `distance` arrives from `Collection`). Adding keys nobody can answer
                // is the class R532b already has open, so that widening is NOT taken here: it needs a
                // requirement gate (`protoOrSuperDeclares`, the sibling site's answer to the same
                // question) and its own removal audit. Keeping the trigger makes this change exactly one
                // thing — the OWNER of a key that was already published — and the A/B says so: ADDED 0.
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                // SOUNDNESS R826 — a CONVENTION owner publishes its key only where the §2 join below
                // ANSWERED it (see there). Published unconditionally it re-mints the keys R567(a) removed
                // for platform singletons — `Alamofire#DispatchQueue.async`, `…#NotificationCenter.addObserver`
                // — a type the named package does not declare, which no consumer can join.
                // (R836: a convention owner's key is published unconditionally again, as v0.39.2 published
                // it. Withholding it until the chained join hit made a STANDALONE producer publish nothing,
                // and a chained producer's miss publish only `Unknown` where v0.39.2 let a consumer's own
                // implementors answer the key under obligation 3.)
                let floorOwner = foreignOwnerModule(inFile: file)
                // VEIN D (R548, R843(ii)) — the release refused this FILE; publish where the OWNER is proven.
                // A local protocol's key stays where R555 left it (the trigger is the release's), so this
                // adds dependency-owned keys only.
                // An UNDECIDED owner (the name IS a dependency's, which one is not proven) publishes no key
                // and is DISCLOSED after the §2 join below, if nothing there answered the call.
                if floorOwner == nil, !veinDOff, let abs = dispatchAbstraction(owner, f),
                   localProtocolWirePath(abs) == nil {
                    switch ownerProof(of: abs, inFile: file, site: "obl1") {
                    case .proven(let p): dispatchDirect[f.qual, default: []].insert("\(p)#\(abs).\(call.leaf)")
                    case .undecided: veinDUndecided = "dispatch:\(abs).\(call.leaf)"
                    case .none: break
                    }
                }
                if let m = floorOwner, let abs = dispatchAbstraction(owner, f) {
                    let localPath = localProtocolWirePath(abs)
                    // REACH PROBE (§E1) — an unchanged row is not evidence the branch ran.
                    if r555Probe, localPath != nil {
                        FileHandle.standardError.write(
                            "R555HIT \(f.qual) \(owner)->\(abs).\(call.leaf)\n".data(using: .utf8)!)
                    }
                    if r555Probe, localPath == nil, (protocolPathByLeaf[abs]?.count ?? 0) > 1 {
                        FileHandle.standardError.write(
                            "R555AMBIG \(f.qual) \(abs).\(call.leaf)\n".data(using: .utf8)!)
                    }
                    // R565 — AND THE FOREIGN HALF IS A PACKAGE, NOT A MODULE. `DepEntry.dispatchesOn`
                    // documents this key's wire form as `<owning pkg>#<type path>.<member>`, and
                    // `applyDepEntry` feeds it straight to `deps.lookup(k)` and to
                    // `unionOwnImplementors`, which compares it against `abstractionOwnerPkg` — so
                    // obligation 1's key and obligation 2's hash MUST be spelled in one namespace or the
                    // join silently misses. The local arm already spells `pkgName`; this is the same
                    // resolution for the foreign one.
                    let ownerPrefix = localPath.map { "\(pkgName)#\($0)" } ?? "\(deps.pkgOfModule(m))#\(abs)"
                    dispatchDirect[f.qual, default: []].insert("\(ownerPrefix).\(call.leaf)")
                }
            }
            // COULD-NOT-FORM-A-KEY (DEP-RECEIVER-TYPING-DESIGN.md half 1). The receiver was bound from a
            // call out of this target whose return type never travelled, so no key was ever formed and
            // NOTHING was looked up — the dep report's silence is only an answer to a question that was
            // asked. Dropping here makes the caller a confident purity claim; under the ⟨0.21⟩ manifest it
            // is still counted in `analyzed`, so the omission reads as a positive claim rather than a gap.
            //
            // THREE conjuncts, the third learned by measuring in rust: untyped receiver AND dep provenance
            // AND the package is CHAINED. For an UNCHAINED package the κ ledger already discloses
            // `invisible: [M]`, so a second disclosure would be pure false uncertainty; it is precisely
            // when the package IS chained that the ledger correctly falls silent (§2 rule 3) and the
            // silence becomes the claim worth spending a disclosure on.
            if call.path.hasPrefix("<untyped>.") {
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                // ⟨0.23⟩ HALF 2 — DETERMINATION (SPEC §2 `typeSurface.returns`). Ask the dependency what
                // its factory RETURNS, then key the ordinary chained lookup with it. Both ends of the
                // surface are fully qualified in the producing package's namespace — the same namespace
                // the entry hashes use — so the key we form here is `<pkg>#<type qual>.<method>` and no
                // new resolution path is added: it is the shape the join already understands.
                //
                // Same never-guess discipline as every other join on this path: only the file's OWN
                // imports, only packages a loaded report COVERS, and only an unambiguous SINGLE hit.
                if let callee = call.depCallee {
                    // ⟨0.40⟩ `returnsProtocol`: the factory's result is ONE protocol, so the member dispatches
                    // through ⟨0.39⟩'s union whatever `types` says (PART 95 r6, o12). ADDED; the disclosure
                    // below still fires exactly as it did.
                    var rpTargets = 0, rpAnswered = true
                    if !r843Off {
                        for (p, _) in deps.chainedPkgs(importing: fileImports[file] ?? []) {
                            let keys = ["\(p)#\(callee)"] + (backtickedLeafKey(callee).map { ["\(p)#\($0)"] } ?? [])
                            for key in keys {
                                for t in (deps.surface.returnsProtocol[key] ?? []).sorted() {
                                    let a = surfaceAnswer(t, call.leaf, forcedProtocol: true)
                                    applySurface(a, to: f.qual)
                                    rpTargets += 1
                                    if !a.answered { rpAnswered = false }
                                    if !a.answered {
                                        direct[f.qual, default: []].insert("Unknown")
                                        whyMap[f.qual, default: []].insert("dispatch:\(callee).\(call.leaf)")
                                    }
                                }
                            }
                        }
                    }
                    var hits: [DepEntry] = []
                    var surfaced: [String] = []
                    var missedAnswer = false   // R845 — an answered type whose member is not in the report
                    for (p, _) in deps.chainedPkgs(importing: fileImports[file] ?? []) {   // R565
                        // R832 — a static factory whose name is a keyword is published as the producer
                        // DECLARED it (`Client.\`default\``) and spelled at the call site without the
                        // backticks; ask both, the second only when the first misses.
                        guard let ty = deps.boundType("\(p)#\(callee)")
                                ?? backtickedLeafKey(callee).flatMap({ deps.boundType("\(p)#\($0)") })
                        else { continue }
                        surfaced.append(ty)
                        if let e = deps.lookup("\(ty).\(call.leaf)") { hits.append(e) } else { missedAnswer = true }
                    }
                    // THE ANSWER MUST BE UNAMBIGUOUS TOO, not only the entry lookup that follows it.
                    // `depCallee` is a BARE name (`build`) — an idiomatic Swift call into a dependency
                    // carries no module — so every covered import of this file is asked the same fn key,
                    // and two libraries may both export a `build`. Gating on `hits.count == 1` alone let
                    // ONE of two different answers be picked whenever the other package's type happened
                    // to have no entry for the member: Alpha publishing `build -> Alpha#Client` (whose
                    // `fetch` is Fs, with `/etc/secrets` in its `paths`) and Beta publishing
                    // `build -> Beta#Stub` (whose `fetch` is pure, so absent) charged Alpha's effect AND
                    // its path literal to a caller that reaches Beta, with `unresolved` left false so
                    // nothing disclosed it. That is a leaf-keyed collapse of two distinct types — rust's
                    // reverted defect 1 — reappearing ACROSS packages rather than within one.
                    //
                    // §2 rule 1 says a key two entries share is DROPPED, never picked from, and the
                    // index enforces that WITHIN a report (`returnsAmbiguous`); this is the same rule
                    // ACROSS the file's imports, where no single report can see the collision. Refusing
                    // falls through to half 1's disclosure below — never to silence.
                    let answers = Set(surfaced)
                    // An A/B diff cannot show that a mechanism never fired, or fired on the wrong thing —
                    // so the trigger, the `returns` answer and the entry lookup are each observable.
                    if ProcessInfo.processInfo.environment["CANDOR_TYPESURFACE_DEBUG"] != nil {
                        let verdict = answers.count > 1 ? "AMBIGUOUS"
                            : (hits.count == 1 ? "HIT " : (surfaced.isEmpty ? "MISS-returns" : "MISS-entry"))
                        let line = "TYPESURFACE-\(verdict) \(f.qual) :: \(callee) -> "
                            + "\(surfaced.isEmpty ? "<no returns entry>" : surfaced.sorted().joined(separator: "|"))"
                            + " :: .\(call.leaf)()\n"
                        FileHandle.standardError.write(line.data(using: .utf8)!)
                    }
                    // SOUNDNESS R845 — TWO CHAINED PACKAGES ANSWERING THE FACTORY is an ambiguous key, and SPEC
                    // ⟨0.25⟩ UNIONS it (the rule the paragraph above predates). R565 made it reachable: a
                    // second package whose `Package(name:)` differs from its module now chains, and
                    // `makeClient().fetch()` went `['Env']` -> `['Unknown']` (`deny Env` 1 -> 0) the moment
                    // it also declared a `makeClient`. Every answered type's entry is applied; a type whose
                    // member the report does NOT answer still falls through to the disclosure below, as the
                    // single-answer case always has.
                    if !joinUnionOff, answers.count > 1, !hits.isEmpty {
                        if joinUnionProbe {
                            FileHandle.standardError.write("JOINUNION typesurface \(f.qual) \(callee) n=\(answers.count)\n".data(using: .utf8)!)
                        }
                        for de in hits { applyDepEntry(de, to: f.qual) }
                        for ty in answers { unionOwnImplementors(forKey: "\(ty).\(call.leaf)", to: f.qual) }
                        if !missedAnswer { continue }
                    }
                    if answers.count == 1, hits.count == 1, let de = hits.first,
                       let ty = answers.first {
                        applyDepEntry(de, to: f.qual)
                        // ⟨0.39⟩ OBLIGATION 3 AT THIS JOIN TOO. The key formed here — `<pkg>#<type>.<member>`
                        // — is answered by the dependency's own `interfaceUnion` entry, whose union is over
                        // the DEPENDENCY's conformers. That is a lower bound on the witness set whenever the
                        // consumer supplies a conformer of its own, which is exactly the case ⟨0.39⟩ exists
                        // for; without this line the hedge is traded for an answer that is missing the half
                        // the consumer can see. Reaching the union entry at all is new in this rung (it rode
                        // behind CANDOR_WORKSPACE_CHAIN), so this is the second half of one change, not an
                        // extension of an old one.
                        unionOwnImplementors(forKey: "\(ty).\(call.leaf)", to: f.qual)
                        continue
                    }
                    // SOUNDNESS R832 — A STATIC RECEIVER NO CHAINED REPORT SPEAKS ABOUT KEEPS THE RELEASE'S
                    // ANSWER. `Type.factory()` is spelled identically for a dependency's type and the
                    // platform's, and on the corpus the platform dominated: `Unmanaged.passUnretained(x)
                    // .toOpaque()`, `UnsafeMutablePointer.allocate(…).deallocate()`, `DispatchSource.make…`,
                    // a generic parameter's `C.H.hash(…)` — 200+ sites on nine entries, none a dependency
                    // reach. The free-function spelling settles that with a carve-out list of stdlib names;
                    // for a TYPE the evidence is on the wire instead: the type is the dependency's when a
                    // report the file imports names it (`mentionedTypes`). A `returns` MISS on a type no
                    // report names is the release's silence, unchanged; a MISS on a named type — a factory
                    // returning `any P`, `some P`, `C?` — discloses as the bare spelling always has; and a
                    // `returns` HIT never reaches here.
                    // ⟨0.40⟩ A `returnsProtocol` answer that EVERY path hit is the protocol twin of the `returns`
                    // hit above, and ends the site the same way: a bare `-> P` factory sat in `returns` until
                    // ⟨0.40⟩ forbade it, and was joined there with no disclosure — so this keeps that site
                    // exactly as it was. For an `any P` / `some P` factory it is the one disclosure this rung
                    // withdraws (SPEC §2 ⟨0.40⟩ permits it where a trusted `returnsProtocol` resolves the hop and
                    // every walk path hits); the join it rests on is ⟨0.39⟩'s implementor union.
                    if !r843Off, rpTargets > 0, rpAnswered, surfaced.isEmpty { continue }
                    if surfaced.isEmpty, callee.contains("."), let dot = callee.lastIndex(of: ".") {
                        let ty = String(callee[..<dot])
                        let named = deps.chainedPkgs(importing: fileImports[file] ?? [])
                            .contains { deps.mentionedTypes.contains("\($0.pkg)#\(ty)") }
                        // R1066 — a STANDALONE instance hop whose type a blind dependency's own sources declare is the
                        // same evidence by another route (no report to name it); it reaches the hedge below.
                        if !named, r1066Off || !call.instanceHop
                            || !deps.chainedPkgs(importing: fileImports[file] ?? []).isEmpty
                            || sourceProvenDepModules(of: ty, inFile: file).isEmpty { continue }
                    }
                }
                // A MISS — on `returns` OR on the entry lookup that follows a `returns` HIT — falls back
                // to half 1's disclosure, NEVER to silence. The second half is the one that is easy to get
                // wrong and is a requirement rather than belt-and-braces: this index DROPS a key two
                // entries share (§2 rule 1), so a miss cannot distinguish "no such method" from "I
                // withdrew the answer", and a refusal to answer is not a purity claim. rust shipped that
                // `continue` and reverted it.
                //
                // SOUNDNESS R836 — AND A GUESSED OWNER DISCLOSES IN A STANDALONE SCAN TOO. The chained
                // gate below rests on "for an UNCHAINED package the κ ledger already discloses", and for a
                // MEMBER call that is not so: the ledger is report-level (`coverage.uncovered`), per-row
                // `invisible` fires only for unqualified calls, and a consumer that later chains this
                // report reads neither. So the row's silence became a purity claim one package
                // downstream — `deny Env` and `deny Env Unknown` both 1 -> 0 across a three-package chain
                // against v0.39.2. For a `guessedOwner` marker the gate is therefore "did the release publish
                // a key a consumer will join" — chained OR not — rather than "is it chained". The
                // release's key for the same call is still published (the floor), so a consumer that CAN
                // answer it still does; this only stops the answer being read as certain.
                let fileImps = fileImports[file] ?? []
                let chainedHere = !deps.chainedPkgs(importing: fileImps).isEmpty   // R565
                // BOUNDED TO WHERE THE RELEASE PUBLISHED A KEY — the same conjuncts as obligation 1's publish
                // arm, asked of the guessed owner. That is exactly the population whose downstream answer a
                // guess can make wrong (a consumer joins the floor key and reads a miss as purity); anywhere
                // else the release published nothing for a consumer to misread, and a hedge there is new
                // uncertainty with no silence behind it. MEASURED the wider way first ("the file sees any
                // uncovered module"): it charged `Unknown` to Bitwarden's `session.outputs.forEach {…}` on an
                // `AVCaptureSession` (`PrivacyEffectsTests`), 291 corpus sites dominated by UIKit, `Self` and
                // stdlib roots.
                let r836Standalone: Bool = {
                    guard !chainedHere, !r836Off, let g = call.guessedOwner, !call.opaqueRecv,
                          !localTypes.contains(g), !STD_PURE_PROTOCOLS.contains(g),
                          !RAW_VALUE_BASE_TYPES.contains(g) else { return false }
                    if foreignOwnerModule(inFile: file) != nil { return dispatchAbstraction(g, f) != nil }
                    // VEIN D — and wherever the proof above published the same key for a guessed owner.
                    guard !veinDOff, let abs = dispatchAbstraction(g, f), localProtocolWirePath(abs) == nil
                    else { return false }
                    return provenOwnerPackage(of: abs, inFile: file, site: "r836") != nil
                }()
                // REACH PROBE (§E1) — only the arm this change ADDS: a guessed owner disclosed WITHOUT a chain.
                if r836Standalone, r836Probe {
                    FileHandle.standardError.write(
                        "R836HIT \(f.qual) \(call.guessedOwner ?? "?").\(call.leaf)\n".data(using: .utf8)!)
                }
                // SOUNDNESS R1065 — an INSTANCE member's result (`dep.label().uppercased()`) is untyped because
                // the producer publishes `returns` only for its OWN types: `-> String` and `-> V` look alike
                // here. Disclose only where the next member's leaf could be a body someone answers — declared
                // by a local type (the generic-argument case: `Box(v: E()).get().go()` runs `E.go`) or published
                // by a chained package. A leaf only the platform declares (`uppercased`) stays as it was.
                if call.instanceHop,
                   !(localMemberLeaves.contains(call.leaf) || deps.anyChainedPackagePublishesLeaf(call.leaf)) {
                    continue
                }
                // SOUNDNESS R1066 — …AND THE SAME INSTANCE HOP IN A STANDALONE SCAN, where the receiver's type is a blind
                // dependency's by its own sources. `b.get().go()` with `b: Box<E>`: the chained arm above hedges it,
                // the standalone arm did not, and the row's `[]` became a purity claim one package downstream — a
                // consumer chaining this report joins the floor key `Iface#Box.get`, finds the dependency's pure
                // `get`, and `deny Fs Unknown` passed over a call that runs `E.go` (executed). R836's reasoning,
                // for the hop R836 did not reach; bounded by the leaf rule above and by SOURCE ownership, never
                // by the file's import vote, so a platform receiver (`url.appendingPathComponent(…).path`) is
                // untouched.
                let r1066Standalone: Bool = {
                    guard !chainedHere, !r1066Off, call.instanceHop, let cal = call.depCallee,
                          let dot = cal.lastIndex(of: ".") else { return false }
                    return !sourceProvenDepModules(of: String(cal[..<dot]), inFile: file).isEmpty
                }()
                if r1066Standalone, r1066Probe {
                    FileHandle.standardError.write("VBHIT\tR1066H\t\(f.qual) \(call.depCallee ?? "?").\(call.leaf)\n".data(using: .utf8)!)
                }
                if chainedHere || r836Standalone || r1066Standalone {
                    direct[f.qual, default: []].insert("Unknown")
                    whyMap[f.qual, default: []].insert("dispatch:untyped cross-package receiver")
                }
                continue
            }
            // CANDOR_DEPS cross-package JOIN (SPEC §2), GATED: an unclassified call that resolved to NO
            // local unit, in a file that IMPORTS a package a sibling report covers, inherits the dep fn's
            // recorded effects + literal surfaces. Key shapes (§2 rule 1 — the way THIS engine names the
            // call): a bare free call `hit()` → `M#hit`; a bare ctor `Rates()` → `M#Rates.init`; a member
            // call on a resolved external owner `c.fetch()` / static `RatesClient.fetch()` → `M#Owner.leaf`;
            // a module-qualified free call `RatesDep.hit()` (owner == the module) → `M#hit`. EXACTLY ONE
            // hit across the file's covered imports joins — two candidates (or an index-ambiguous key) are
            // dropped, never picked from. A local resolution above is always authoritative (never guess
            // over project code), so this runs only when !resolved.
            // SOUNDNESS R651 — `!call.typed` was the conjunct an `extension Chan { }` in the consumer's
            // own tree used to switch this whole join off. `r651Extended` re-admits exactly the calls
            // whose receiver type this package only EXTENDS; the `!resolved` guard above it is unchanged,
            // so a member the extension itself provides never reaches here.
            if !resolved, !deps.isEmpty, !call.typed || r651Extended {
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                var hits: [DepEntry] = []
                // R565 — `m` was a MODULE and the key prefix is a PACKAGE. `mods` carries the modules
                // that resolved to this package, because the `owner == m` arm below asks about the
                // MODULE spelling, not the package.
                var hitKey: String? = nil   // R826 — the key that answered, for a convention owner's publish
                let memberTiers = joinTiers(file, module: call.unqualified ? nil : call.ownerModule)
                for (ti, tier) in memberTiers.enumerated() where hits.isEmpty {
                for (p, mods) in tier {
                    if call.unqualified {
                        // R847 — a bare identifier passed as an ARGUMENT (`String(next)`) is a function
                        // REFERENCE; the only dependency declaration a bare name can reference is a FREE
                        // function (`declaresFreeName`, R649's predicate) or a type's `init`. `pkg#<leaf>`
                        // is minted for every METHOD too, so the unrestricted lookup handed a local's name
                        // to whichever method shared it.
                        let bare = !call.argRef ? deps.lookup("\(p)#\(call.path)")
                            : ((call.argBoundLocal && !CallCollector.r847Off) ? nil : bareNameDepEntry(p, call.path, f))
                        if let e = bare ?? deps.lookup("\(p)#\(call.path).init") {
                            if joinDebug { FileHandle.standardError.write("JOINSITE unqual\(call.argRef ? "-argref" : "") \(f.qual) \(p)#\(call.path) -> \(e.whyReason ?? "-")\n".data(using: .utf8)!) }
                            hits.append(e)
                        }
                    } else if let owner = call.extOwner {
                        // R532 — the same type-parameter resolution the ⟨0.39⟩ key above uses, and the
                        // SAME function, so the key this join ASKS on and the key the rung PUBLISHES
                        // cannot spell one abstraction two ways. `owner == m` stays on the RAW spelling:
                        // that arm is the module-qualified free call (`RatesDep.hit()`), where the owner
                        // IS the module name and no generic bound can apply.
                        let key = dispatchAbstraction(owner, f) ?? owner
                        if let e = deps.lookup("\(p)#\(key).\(call.leaf)") {
                            if joinDebug { FileHandle.standardError.write("JOINSITE member \(f.qual) \(p)#\(key).\(call.leaf) typed=\(call.typed)\n".data(using: .utf8)!) }
                            hits.append(e); hitKey = "\(p)#\(key).\(call.leaf)"
                        } else if mods.contains(owner), let e = deps.lookup("\(p)#\(call.leaf)") {
                            if joinDebug { FileHandle.standardError.write("JOINSITE modleaf \(f.qual) \(p)#\(call.leaf) owner=\(owner)\n".data(using: .utf8)!) }
                            hits.append(e)
                        }
                    }
                }
                if ti == 0, !hits.isEmpty, !call.unqualified, let owner = call.extOwner {
                    let key = "\(dispatchAbstraction(owner, f) ?? owner).\(call.leaf)"
                    discloseOtherAnswers(key, tiers: memberTiers, why: "dispatch:\(key)", f.qual)
                }
                }
                // SPEC §2 rule 1 ⟨0.25⟩ — AN AMBIGUOUS KEY IS UNIONED; IT MUST NOT BE PICKED FROM AND MUST NOT
                // BE DROPPED. This arm dropped it: two chained packages both answering the key read as "no
                // answer", the row fell out of `functions[]`, and under ⟨0.21⟩ that is a purity claim. It
                // was latent until R567(b) (`8931087`) published the BARE spelling of every overloaded
                // dependency member — which made keys collide ACROSS packages where they had not: measured
                // on RxAlamofire, `map { $0.validate() }` inside `extension ObservableType` was answered by
                // Alamofire's `DataResponse.map` alone on v0.39.2 (`['Unknown']`), and by Alamofire AND
                // RxSwift's newly-bare `map` after R567(b) — 2 hits, dropped, and four
                // `ObservableType.validate` rows went from `['Unknown']` to ABSENT. The union is what
                // SPEC ⟨0.25⟩ has required since that rung; it over-charges (both packages' members) and
                // never under-reports, and it is monotone against the release by construction: whatever
                // the release's single hit charged is one of the union's contributors.
                // ⟨0.40⟩ THE WALK, for an owner whose own key missed: the member may be INHERITED inside the
                // dependency (a superclass method, a protocol-extension default — R858/R859/R865), or come from
                // a conformance a chained package ADDS to a type it does not own (`extension Tok: PBase`,
                // r8). Entries the walk reaches are ADDED; `resolved` is left as it was, so whatever the
                // release disclosed here still fires. `adds` is never complete, so a walk that misses
                // discloses — bounded, as R859 bounds it, to a leaf some chained package publishes a body for.
                if !r843Off, hits.isEmpty, !call.unqualified, let owner = call.extOwner {
                    sourceTypedWalk(dispatchAbstraction(owner, f) ?? owner, call.leaf, tiers: memberTiers,
                                    to: f.qual, guessed: call.guessHop)
                }
                // SOUNDNESS R910 — see `ownerKeyPkg`. After the walk, so nothing it decides is changed.
                if hits.isEmpty, !call.unqualified, let owner = call.extOwner {
                    let abs = dispatchAbstraction(owner, f) ?? owner
                    if let op = ownerKeyPkg(abs, inFile: file),
                       askOwnKey(op, "\(abs).\(call.leaf)", asked: Set(memberTiers.flatMap { $0.map { $0.p } }), to: f.qual),
                       call.guessHop {
                        // ⟨0.40⟩ a hit on a GUESSED owner keeps the guess's `Unknown` (PART 95 o1).
                        direct[f.qual, default: []].insert("Unknown")
                        whyMap[f.qual, default: []].insert("dispatch:untyped cross-package receiver")
                    }
                }
                // ⟨0.40⟩ EVERY LOOKUP ON A GUESSED OWNER THAT NO TRUSTED SURFACE ANSWERS KEEPS THE GUESS AND
                // ADDS `Unknown` — a HIT included: `Wrong.shared.ping()` joining `Wrong.ping` is a guess that the
                // value is a `Wrong`, and over an older producer nothing says otherwise (PART 95 o1, o1b). A
                // miss counts when a chained report names the owner type, so a PLATFORM singleton the
                // convention types correctly (`FileManager.default`) is not swept in.
                if !r843Off, call.guessHop, !call.unqualified, let owner = call.extOwner {
                    let chained = deps.chainedPkgs(importing: fileImports[file] ?? [])
                    let named = chained.contains {
                        deps.mentionedTypes.contains("\($0.pkg)#\(owner)")
                            || deps.surface.typeKeysSeen.contains("\($0.pkg)#\(owner)")
                    }
                    if !chained.isEmpty, !hits.isEmpty || named,
                       !(call.holdsHop.map { holdsAnswered($0, call.leaf, file, call.ownerModule) } ?? false) {
                        if r843Probe {
                            FileHandle.standardError.write("R843GUESS \(f.qual) \(owner).\(call.leaf) hit=\(!hits.isEmpty) hop=\(call.holdsHop ?? "-")\n".data(using: .utf8)!)
                        }
                        direct[f.qual, default: []].insert("Unknown")
                        whyMap[f.qual, default: []].insert("dispatch:untyped cross-package receiver")
                    }
                }
                if hits.count > 1, joinUnionProbe {
                    FileHandle.standardError.write(
                        "JOINUNION member \(f.qual) \(call.extOwner ?? "-").\(call.leaf) n=\(hits.count)\n".data(using: .utf8)!)
                }
                if hits.count > 1, !joinUnionOff {
                    for de in hits.dropFirst() { applyDepEntry(de, to: f.qual) }
                }
                if hits.count == 1 || (!joinUnionOff && hits.count > 1), let de = hits.first {
                    // inherit the dep fn's own honesty markers too, so the consumer's verdict stays
                    // qualified across the chain boundary (a benign literal HERE must not certify the
                    // dep's invisible runtime endpoint) — see applyDepEntry.
                    // SOUNDNESS R651 REACH — the MARK IS THE JOIN THAT ANSWERED, not the branch that ran.
                    // `R651HIT` counts every extension-only member call (a project with one
                    // `extension String` produces thousands); this counts the ones where the dependency
                    // actually had the answer, which is the only population the A/B can move.
                    if CallCollector.r651Probe, r651Extended {
                        FileHandle.standardError.write(
                            "R651JOIN \(f.qual) -> \(call.extOwner ?? "?").\(call.leaf)\n".data(using: .utf8)!)
                    }
                    applyDepEntry(de, to: f.qual)
                    resolved = true
                    // R826 — the convention owner's ⟨0.39⟩ obligation-1 key, published now that the
                    // dependency has answered it (withheld above until this point).
                    if call.conventionOwner, let k = hitKey { dispatchDirect[f.qual, default: []].insert(k) }
                }
            }
            // SOUNDNESS R826 — A SINGLETON-CONVENTION KEY THAT NOTHING ANSWERED. The owner was taken on
            // convention (`Client.shared` is a `Client`), not from a recorded binding, so a miss cannot
            // tell "the member is pure" from "`.shared` vends some other type". Disclose, with the SAME
            // token and the SAME chained gate R567(a)'s refusal uses — this is that refusal, deferred to
            // the one point where it is known whether the dependency answered. A HIT never reaches here.
            if !resolved, call.conventionOwner {
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                if !deps.chainedPkgs(importing: fileImports[file] ?? []).isEmpty {
                    direct[f.qual, default: []].insert("Unknown")
                    whyMap[f.qual, default: []].insert("dispatch:untyped cross-package receiver")
                }
            }
            // A call that resolved to no local edge AND is an UNQUALIFIED free-call/ctor reaches a blind module
            // — disclose the fn's blind imports (file-granular: the syntactic engine can't pin WHICH import a
            // dropped call lands in, so it names every κ-unknown module in scope — an honest LOWER bound).
            // ONLY unqualified calls count: a bare MEMBER call (`str.uppercased()`, `p.canReadObject()`) on a
            // κ-known-pure or stdlib receiver also resolves to no local edge but is NOT a blind reach — counting
            // it tagged every function touching a stdlib method in a blind-importing file (rampant false
            // uncertainty, sweep [33]/[36]). The construction (`BlindClient()`) / free call into a blind lib is
            // the honest signal; a member-only blind receiver is covered by the scan-level κ-ledger.
            if ProcessInfo.processInfo.environment["CANDOR_R548_PROBE"] != nil, !resolved {
                let _pf = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                FileHandle.standardError.write(
                    ("R548 fn=\(f.qual) leaf=\(call.leaf) unqual=\(call.unqualified) "
                     + "extOwner=\(call.extOwner ?? "-") blind=\(blindModules(inFile: _pf).sorted()) "
                     + "foreignOwner=\(foreignOwnerModule(inFile: _pf) ?? "-")\n").data(using: .utf8)!)
            }
            if !resolved && call.unqualified {
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                let blind = blindModules(inFile: file)
                for m in effectiveImports(file) where blind.contains(m) {   // R827
                    blindDirect[f.qual, default: []].insert(m)
                }
            } else if !r706iOff, !resolved, !call.unqualified, !call.path.hasPrefix("<"), let raw = call.extOwner,
                      case let owner = f.genericBounds[raw] ?? raw,
                      existentialSpelled.contains(owner) || someSpelled.contains(owner)
                        || f.genericBounds[raw] != nil,
                      !localTypes.contains(owner), !localProtocolNames.contains(owner),
                      !STD_PURE_PROTOCOLS.contains(owner), !STDLIB_ITERATION_PROTOCOLS.contains(owner),
                      !PLATFORM_PROTOCOL_NAMES.contains(owner),
                      case let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" }),
                      let module = foreignOwnerModule(inFile: file), blindModules(inFile: file).contains(module) {
                // SOUNDNESS R706 (residual) — A MEMBER CALL THROUGH AN EXPLICIT PROTOCOL SPELLING (`any P`, `some P`,
                // `<T: P>`) WHOSE OWNER IS A BLIND DEPENDENCY. SPEC §2 (`invisible`): the per-function attribution of
                // the coverage ledger, and an engine MUST disclose at least one of `invisible`/`Unknown`, "never
                // silently pure". The arm below this one (and the general member-call rule above) withholds it for a
                // member call because a bare receiver's module cannot be decided — the reverted widening tagged an
                // `NSPasteboard` receiver. The predicate here is narrower than that one by construction: the source
                // SPELLS the owner as a protocol, the owner is neither declared here nor a platform/stdlib protocol
                // this engine names, and the value is the file's ONE dependency module (`foreignOwnerModule`, the
                // same owner the ⟨0.39⟩ `dispatchesOn` key already publishes) — so the attribution is the module the
                // free-call rows name. ⟨0.24⟩: a judged-nothing chained copy covers nothing, so this fires in that
                // arm exactly as unchained. Non-gating by design (R133): `deny`/`pure` do not move.
                if r706iProbe { FileHandle.standardError.write("VBHIT\tR706I\t\(f.qual) \(owner).\(call.leaf) -> \(module)\n".data(using: .utf8)!) }
                blindDirect[f.qual, default: []].insert(module)
            } else if !resolved, !call.typed, let owner = call.extOwner,
                      blindModules(inFile: String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })).contains(owner) {
                // SOUNDNESS R651 — `!call.typed` PINS THIS ARM'S POPULATION AND CHANGES NOTHING TODAY.
                // Before R651 no typed call carried an `extOwner`, so this conjunct was implied; R651
                // makes typed calls carry one and this arm is not a place that should follow. It fires on
                // a receiver root that IS an imported blind MODULE name, and R651's owners are type names
                // — the two coincide only where a project extends a type sharing a blind module's name,
                // where the honest answer is the scan-level κ ledger's, not a per-fn `invisible`. Written
                // as a guard rather than left implied because "no construction site sets that today" is
                // exactly the kind of sentence that goes stale one commit later.
                // ⟨0.15 staged⟩ a MODULE-QUALIFIED member call whose confidently-resolved receiver root IS
                // a blind imported module (`SomeSDK.doThing()` — extOwner == the module name, in this file's
                // import scope) demonstrably reaches that exact module. PRECISE, not file-granular — it names
                // only the module the call text targets, so the sweep-[33]/[36] guard (member calls on
                // stdlib/κ-pure receivers must NOT flood blind imports) is untouched: an unresolvable member
                // call on any OTHER receiver still attributes nothing and stays covered by the scan ledger.
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                if (fileImports[file] ?? []).contains(owner) {
                    blindDirect[f.qual, default: []].insert(owner)
                }
            } else if !r1066Off, !resolved, !call.unqualified, !call.path.hasPrefix("<"), let raw = call.extOwner,
                      case let owner = f.genericBounds[raw] ?? raw,
                      case let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" }),
                      case let mods = { () -> Set<String> in
                          let t = sourceProvenDepModules(of: owner, inFile: file)
                          return t.isEmpty ? sourceExtendingDepModules(of: owner, member: call.leaf, inFile: file) : t
                      }(), !mods.isEmpty {
                // SOUNDNESS R1071 — or whose sources EXTEND it (a platform type) with this public member.
                // SOUNDNESS R1066 — A MEMBER CALL ON A RECEIVER WHOSE TYPE A BLIND DEPENDENCY'S OWN SOURCES DECLARE
                // (`func f(_ b: Box<E>) { b.get() }`, `Box` public in the one dependency). SPEC §2 (`invisible`): an
                // engine MUST disclose at least one of `invisible`/`Unknown` for a function that demonstrably calls
                // an uncovered package, never silently pure — and the rows above withhold it for a member call
                // because a bare receiver's module cannot be decided from the FILE (the reverted widening tagged
                // an `NSPasteboard`). Here it is decided from the DEPENDENCY: its sources declare the type, so the
                // member is that module's (or an extension of it, which is no less a reach into uncovered code).
                // A platform type no dependency declares answers nothing and stays as it was. Non-gating (R133).
                if r1066Probe { FileHandle.standardError.write("VBHIT\tR1066\t\(f.qual) \(owner).\(call.leaf) -> \(mods.sorted())\n".data(using: .utf8)!) }
                blindDirect[f.qual, default: []].formUnion(mods)
            }
            // ── SOUNDNESS R705, THE DISCLOSURE ────────────────────────────────────────────────────────
            //
            // NOTHING ANSWERED AN ERASED DISPATCH OVER AN ABSTRACTION THIS SCAN DOES NOT OWN. The
            // carve-out above correctly withheld the CHA edge (the caller monomorphizes `some P`/`<T: P>`,
            // so our conformers are not this receiver's witnesses — `d62dd69`, sixteen assertions), the
            // ⟨0.39⟩ obligation-1 KEY was published for a consumer to answer, and the §2 join found no
            // entry for it. Three correct steps, and their intersection was a row reading `inferred: []`
            // with `unresolved: false` — a POSITIVE claim that this call reaches nothing, over a call
            // whose witness is simply not in anything the scan was given. The LOCAL protocol-CHA loop
            // below answers this exact shape with `Unknown` + `dispatch:<P>.<member>`; this is the same
            // answer for the foreign half, and it is the whole fix: the edge stays withheld.
            //
            // **PLACED HERE, AFTER THE JOIN, BECAUSE `resolved` IS THE DISCRIMINATOR.** A hedge inside the
            // arm above could not tell "no witness anywhere" from "the dependency published the answer and
            // the join is about to apply it" — measured: a dependency whose protocol EXTENSION provides
            // the member publishes `Pkg#P.member`, the join hits, and hedging there would have put a false
            // `Unknown` beside a correct effect on every such row. `resolved` is set by exactly the things
            // that can answer (a local resolution, or the §2 join), which is why this reads it rather than
            // re-deriving the question.
            //
            // THE DIRECTION THIS FAILS IN IS OVER-DISCLOSURE: it adds `Unknown` and removes no effect and
            // no edge. `deny Unknown` / `deny <E> Unknown` therefore catch what was silent; a bare
            // `deny <E> <fn>` still passes, and that is correct rather than a shortfall — the scan does not
            // know WHICH effect, and claiming one would be the fabrication this arm's carve-out exists to
            // prevent.
            // VEIN D — THE UNDECIDED OWNER, DISCLOSED. The release refused this file's owner vote and so
            // published no key; the name is proven to be a dependency's (a candidate declares it) but not
            // WHICH one's, so no key may be minted. Placed after the join for R705's reason: `resolved`
            // says whether anything answered, and a hedge beside a real answer is false uncertainty.
            if !resolved, let why = veinDUndecided {
                direct[f.qual, default: []].insert("Unknown")
                whyMap[f.qual, default: []].insert(why)
            }
            if !resolved, let abs = erasedForeignDispatch {
                if ProcessInfo.processInfo.environment["CANDOR_R705_PROBE"] != nil {
                    let line = "R705HIT \(f.qual) \(call.extOwner ?? "?")->\(abs).\(call.leaf) "
                        + "opaque=\(call.opaqueRecv)\n"
                    FileHandle.standardError.write(line.data(using: .utf8)!)
                }
                direct[f.qual, default: []].insert("Unknown")
                whyMap[f.qual, default: []].insert("dispatch:\(abs).\(call.leaf)")
            }
            // ── SOUNDNESS R859 — THE ERASED SPELLING OF THE SAME QUESTION, WHERE A MEMBER IS INHERITED ──
            //
            // `func f(_ t: any PSub) { t.pTok() }`, dependency `protocol PSub: PBase` with
            // `extension PBase { func pTok() }` reading env. The generic spelling `<T: PSub>` discloses
            // through R705 above; the existential is not R705's population (the CHA arm runs for it,
            // because an existential's local conformers ARE candidate witnesses), and so the row read
            // `[]` — `deny Env` and `deny Env Unknown` both 0 — over code that reads env (executed).
            //
            // The chain is three correct steps again: the local CHA finds no `SConf.pTok` (the body is
            // the dependency's, inherited through a protocol the wire does not record — R843); the ⟨0.39⟩
            // key `RatesCore#PSub.pTok` is published; the §2 join MISSES it, because the producer keys the
            // body `PBase.pTok`. A miss on a type's own key is a purity claim only if that key could have
            // had the body, and for an abstraction whose supertypes are unpublished it could not.
            //
            // So, after the join, where `resolved` says nothing answered: DISCLOSE — `Unknown` with
            // R705's own `dispatch:<P>.<member>` token, adding nothing else and removing nothing. Bounded
            // by three conjuncts, each the source's or the chain's own evidence rather than a guess:
            //   · the receiver's type is an ABSTRACTION this package does not declare — spelled `any P`
            //     somewhere in it (Swift admits only a protocol there), or adopted by a local type
            //     (`subtypesOf`); a dependency CLASS used concretely is not this population;
            //   · the file imports a chained package (the κ ledger speaks for an unchained one);
            //   · some chained report publishes a body under this LEAF at all (`pkg#<leaf>`). If none
            //     does, no inherited body with an effect exists anywhere in the chain, and the miss is
            //     the purity claim it reads as — which keeps this off every pure protocol member.
            if !resolved, !r859Off, erasedForeignDispatch == nil, !call.unqualified,
               let owner = call.extOwner, !call.path.hasPrefix("<"),
               !localTypes.contains(owner), !localProtocolNames.contains(owner),
               !STD_PURE_PROTOCOLS.contains(owner), !RAW_VALUE_BASE_TYPES.contains(owner),
               case let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" }),
               case let chained = deps.chainedPkgs(importing: fileImports[file] ?? []),
               existentialSpelled.contains(owner) || !(subtypesOf[owner] ?? []).isEmpty
                || (!r706Off && chained.contains { deps.surface.knownKind("\($0.pkg)#\(owner)") == "protocol" }
                    && (subtypesOf[owner] ?? []).isEmpty) {
                // (R706: a bare `_ t: Sink` IS the existential when the chain says `Sink` is a protocol — Swift
                // admits only that reading — so the attested kind is a third way into this arm, beside an
                // `any P` spelling and a local adopter.)
                // SOUNDNESS R706 — …OR THE CHAIN SAYS THE OWNER IS A PROTOCOL. The leaf conjunct keeps this off
                // pure protocol members, and it is right while SOME chained package has a body to be inherited;
                // with ZERO implementors anywhere it made `any DepProto` read pure across the boundary (the tree
                // arm discloses), and an UNRELATED `OtherL.put` in the dependency flipped the verdict. ⟨0.40⟩'s
                // `types` surface publishes each declared type's `kind`, so the dependency now SAYS the owner is
                // a protocol: an `any P` receiver over a protocol requirement no visible package implements has
                // an unknown witness, which is a disclosure, not a purity claim. A dependency CLASS (the
                // `_ c: DepClient` shape the leaf conjunct also guards) has kind `class` and is untouched.
                // …AND THE CHAIN DECLARES NO SUBTYPE OF IT. A pure implementor in the dependency publishes no row,
                // so "no body under this leaf" cannot tell ZERO implementors from PURE ones — the over-charge the
                // first cut of this put on a pure dependency hierarchy (`testAMetatypeBinderOverAPureDepHierarchy
                // GainsNothing`). The `types` surface lists every declared type's `supers`, pure ones included:
                // only a protocol NOTHING visible conforms to (here or in the chain) has an unknown witness.
                let ownerIsChainedProtocol = !r706Off && (subtypesOf[owner] ?? []).isEmpty && chained.contains {
                    deps.surface.knownKind("\($0.pkg)#\(owner)") == "protocol"
                        && !deps.surface.hasDeclaredSubtype("\($0.pkg)#\(owner)")
                }
                if !chained.isEmpty, deps.anyChainedPackagePublishesLeaf(call.leaf) || ownerIsChainedProtocol {
                    if r706Probe, ownerIsChainedProtocol, !deps.anyChainedPackagePublishesLeaf(call.leaf) {
                        FileHandle.standardError.write("VBHIT\tR706\t\(f.qual) \(owner).\(call.leaf)\n".data(using: .utf8)!)
                    }
                    if r859Probe {
                        FileHandle.standardError.write(
                            "R859HIT \(f.qual) \(owner).\(call.leaf) any=\(existentialSpelled.contains(owner))\n"
                                .data(using: .utf8)!)
                    }
                    direct[f.qual, default: []].insert("Unknown")
                    whyMap[f.qual, default: []].insert("dispatch:\(owner).\(call.leaf)")
                }
            }
        }

        // Bounded CHA over local protocols (SPEC §4, 0.5): the protocol is local and declares the
        // method; resolve ≤12 conformers, otherwise honest Unknown.
        for d in cc.protoDispatches {
            // THE MEMBER SPACE OF A PROTOCOL HAS TWO HALVES and a dispatch must consult BOTH. A member is
            // either a REQUIREMENT (no body — the witness that runs belongs to a conformer, resolved by the
            // CHA below) or EXTENSION-PROVIDED (`extension P { func provided() {…} }` — a real `P.provided`
            // unit whose body runs, and which the CHA below can never find because no conformer declares it).
            // This loop used to `continue` on anything that was not a requirement, so the extension half was
            // dropped outright; the other lookup path (CallCollector's `localTypes` branch, which an
            // `extension P` silently opted the protocol into) covered the extension half and dropped the
            // requirement half. Each path answered one half and certified the other pure. Both halves are
            // answered HERE now, and the receiver kind — parameter, field, local — no longer selects which.
            //
            // UNION, not either/or: a requirement WITH a default has both a `P.member` body and per-conformer
            // overrides, and a syntactic scan cannot say which one a given receiver runs.
            // OVERLOADS RESOLVE IN **BOTH** HALVES EXACTLY AS THEY DO ON THE TYPED-CALL PATH — through
            // `memberTargets`, which is now the single spelling of that question. The typed path routes an
            // overloaded base through `matchOverloads`; answering it with a bare `resolveQual` (which
            // cannot name an overloaded base, its qual carrying a signature suffix) DROPPED every
            // sibling-overload edge at such a site. MEASURED by the corpus A/B — swift-syntax
            // `TokenConsumer.consume(_)` lost 5 edges, swift-protobuf `Message.init(String,ExtensionMap)`
            // lost 10, firebase `Storage.bucket` lost its only one — and by nothing else, because no
            // fixture had an overloaded provided member. `callsiteArgs` is recorded for the same reason the
            // typed path records it: it is what callback-flow resolves fn-typed parameters against.
            //
            // ⚠ THIS PARAGRAPH SAID "HERE" AND MEANT THE PROVIDED HALF ONLY — the per-conformer CHA below
            // it kept the bare `resolveQual` for another month, and that is SOUNDNESS R572, a cardinal sin
            // live in Alamofire. A comment that asserts a property of "this code" while one of the two
            // implementations beneath it lacks the property is what stops the second one being measured:
            // the 2×2 that found it (overloaded × defaulted) had never been written because this said it
            // was covered. Both halves now go through one closure so the sentence cannot drift again.
            var providedEdged = false
            var frontier = [d.proto], seenProto = Set<String>()
            while let cur = frontier.popLast() {
                guard seenProto.insert(cur).inserted else { continue }
                // a SUPER-protocol's extension provides the member too (`protocol Sub: Sup`, `extension Sup`)
                let ts = memberTargets("\(cur).\(d.member)", d.argc, d.argTypes, swiftModuleOf(f.loc))
                if !ts.isEmpty {
                    for t in ts {
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append((f.qual, d.args))
                    }
                    providedEdged = true
                }
                frontier.append(contentsOf: protocolSupers[cur] ?? [])
            }
            // SOUNDNESS R859, THE LOCAL-REFINEMENT SPELLING — `protocol LSub: PBase {}` declared HERE over a
            // DEPENDENCY's `PBase`, whose `extension PBase { func pTok() }` reads env, and `t.pTok()` on
            // `any LSub`. The walk above reaches `PBase` (it is in `protocolSupers`) but can only ask LOCAL
            // resolution about it, and `protoOrSuperDeclares` below knows local declarations only, so the
            // call was dropped: ABSENT on v0.39.2 and HEAD, executed. The "inherited external member"
            // the next comment names is exactly this case, and "silent drop" is the defect, not the design.
            //
            // So a FOREIGN protocol the walk reached is asked of the dependency by its own key
            // (`<pkg>#PBase.pTok` — the producer keys an extension body by the protocol that declares it),
            // with this package's conformers' own members unioned beside it, as the foreign-abstraction
            // CHA arm does. A hit is a RESOLUTION. A miss where some chained report still publishes a body
            // under this leaf is the R859 disclosure (the member may sit further up a chain the wire does
            // not record); a miss with no such body anywhere is the purity claim it reads as. Additive:
            // nothing the walk or the CHA below does is changed.
            if !r859Off, !providedEdged, !protoOrSuperDeclares(d.proto, d.member) {
                let foreignSupers = seenProto.filter {
                    !localProtocolNames.contains($0) && !localTypes.contains($0) && !STD_PURE_PROTOCOLS.contains($0)
                }
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                let chained = deps.chainedPkgs(importing: fileImports[file] ?? [])
                if !foreignSupers.isEmpty, !chained.isEmpty {
                    var answered = false
                    for s in foreignSupers.sorted() {
                        for (p, _) in chained {
                            if let e = deps.lookup("\(p)#\(s).\(d.member)") { applyDepEntry(e, to: f.qual); answered = true }
                        }
                    }
                    // This package's conformers' own members, unioned whether or not the dependency
                    // answered: for a REQUIREMENT the foreign protocol declares, they are witnesses the
                    // dependency's report cannot know about (the obligation-3 half of ⟨0.39⟩).
                    // A local witness does NOT stand in for the disclosure below: for a member an EXTENSION
                    // provides, Swift dispatches statically to the extension and a conformer's same-named
                    // method never runs, so it cannot certify the call.
                    for c in conformers[d.proto] ?? [] {
                        edges[f.qual, default: []].formUnion(
                            memberTargets("\(c).\(d.member)", d.argc, d.argTypes, swiftModuleOf(f.loc)))
                    }
                    if !answered, deps.anyChainedPackagePublishesLeaf(d.member) {
                        direct[f.qual, default: []].insert("Unknown")
                        whyMap[f.qual, default: []].insert("dispatch:\(d.proto).\(d.member)")
                    }
                    if r859Probe {
                        FileHandle.standardError.write(
                            "R859LOCAL \(f.qual) \(d.proto).\(d.member) supers=\(foreignSupers.sorted()) answered=\(answered)\n"
                                .data(using: .utf8)!)
                    }
                }
            }
            // Not a requirement: the extension body edged above IS the answer. If neither half knows the
            // member it stays a silent drop, exactly as before (a κ call on a protocol-named receiver) —
            // never a guess, never a new Unknown flood. (An inherited member of a DEPENDENCY's protocol is
            // asked of the dependency just above — R859.)
            guard protoOrSuperDeclares(d.proto, d.member) else { continue }
            // ⟨0.39⟩ OBLIGATION 1. RECORDED WHATEVER THE CHA BELOW ANSWERS, and that is the whole point:
            // the toggle this rung closes runs between ZERO implementors (disclosed `Unknown`) and ONE
            // PURE one (silently certified), so a field recorded only on the indeterminate branch is
            // absent in exactly the arm that needs it.
            if let path = localProtocolWirePath(d.proto) {
                dispatchDirect[f.qual, default: []].insert("\(pkgName)#\(path).\(d.member)")
            }
            let conf = conformers[d.proto] ?? []
            // `chaWithinBound` alone covers the `conf.isEmpty` case (an empty conformer set fails the
            // shared `count == 0` test and discloses on its own, exactly as the standalone `!conf.isEmpty`
            // conjunct this replaces did — an empty set discloses regardless of `providedEdged`, because a
            // requirement with zero LOCAL conformers may still be satisfied by an external one the extension
            // default doesn't speak for). Within bound, `impls.count == conf.count` is the wrong
            // completeness test whenever a default exists: a conformer that does NOT declare the member
            // runs the extension DEFAULT, already edged above, so it IS accounted for — without the
            // `providedEdged` disjunct, the commonest Swift idiom of all (a requirement with a default that
            // most conformers do not override) would turn from a precise answer into an `Unknown` at every
            // such call site.
            //
            // `resolveQual` now UNIONS an ambiguous same-simple-name collision instead of dropping it (see
            // its definition), so "did conformer `c` resolve" is "is the returned set non-empty", and the
            // per-conformer completeness count is over how many conformers resolved AT ALL, not how many
            // single quals came back.
            if chaWithinBound(conf.count, d.proto, d.member, f.qual) {
                // SOUNDNESS R572 — THROUGH `memberTargets`, the same authority the provided half above
                // uses. This line was a bare `resolveQual`, which cannot name an overloaded base: an
                // overloaded conformer member resolved to EMPTY for every conformer, `resolvedCount`
                // went to 0, and `|| providedEdged` (true, because the extension default DID match
                // through the overload table) took the union branch and unioned empty sets — no edge and
                // no `Unknown`. The comment above claiming overloads resolve here exactly as on the
                // typed-call path was true of the provided half and false of this one.
                let implResults = conf.map {
                    memberTargets("\($0).\(d.member)", d.argc, d.argTypes, swiftModuleOf(f.loc))
                }
                let resolvedCount = implResults.filter { !$0.isEmpty }.count
                if resolvedCount == conf.count || providedEdged {
                    for ts in implResults { edges[f.qual, default: []].formUnion(ts) }
                } else {
                    direct[f.qual, default: []].insert("Unknown")
                    whyMap[f.qual, default: []].insert("dispatch:\(d.proto).\(d.member)")
                }
            }
            // SOUNDNESS R867, THE IN-SCAN TWIN — A SUBCLASS OF A CONFORMING CLASS OVERRIDES THE WITNESS.
            // `conformers[P]` holds only the types that SPELL `: P`, so `protocol D { func dispose() }`,
            // `open class Sink: D`, `final class DebugSink: Sink { override func dispose() { <fs> } }` and
            // `f(_ d: D) { d.dispose() }` edged `Sink.dispose` alone and `f` read PURE while a `DebugSink`
            // passed to it writes the file — and the chained consumer of the same package, reading the
            // producer's (now transitive) union entry, was charged correctly: the package's own answer was
            // weaker than its consumer's. Found in the corpus A/B (RxSwift `Disposable` / `Sink` /
            // `DebugSink.dispose`, Clock). PRECISE-OR-NOTHING and ADDITIVE, the class-CHA arm's rule: only
            // real `<sub>.<member>` units are edged, and nothing above is changed or bounded by it.
            if !driverR867Off {
                for c in conf.sorted() {
                    for sub in (subtypesOf[c] ?? []).sorted() where sub != c && !conf.contains(sub) {
                        edges[f.qual, default: []].formUnion(
                            memberTargets("\(sub).\(d.member)", d.argc, d.argTypes, swiftModuleOf(f.loc)))
                    }
                }
            }
        }
        // CHA for protocol PROPERTY/subscript reads — identical bounded resolution to method dispatch,
        // but the conformer units are accessor units (`Type.payload` / `Type.subscript`). A conformer
        // satisfying the requirement with a STORED property has no accessor unit (pure, contributes
        // nothing) — so a naive `impls.count == conf.count` would wrongly force Unknown when SOME
        // conformers are stored. ⟨2026-08-27⟩ THIS LOOP HAD NO DISCLOSE-ON-MISS BRANCH AT ALL — every
        // conformer that didn't resolve simply contributed nothing, silently, which is the exact
        // structural gap `resolveQual`'s old ambiguous-nil fold produced one level up: a `Type.member`
        // that could not be pinned (an ambiguous same-simple-name collision, OR the requirement being
        // satisfied via a superclass property this per-conformer loop never climbed to) read identically
        // to "this conformer stores it, nothing to charge". `resolveQual` now unions the ambiguous case
        // (so that half of the gap is closed at the source), but a genuine miss — an inherited computed
        // property, or any other conformer this loop cannot resolve at all — must still say so, the way
        // the neighbouring method-dispatch loop above does, rather than default to pure. The stored-
        // property case is told apart from a genuine miss by `fields[c][d.member]`: DeclCollector
        // records a `fields` entry for EVERY property with an explicit type annotation, whether stored
        // or computed, and a computed property always carries one (Swift requires it) — so if
        // `resolveQual` came back empty AND `fields` still knows the member, it is a declared-here
        // stored property (pure, accounted for); empty AND absent from `fields` means the requirement
        // is satisfied somewhere this loop never looked, which is the honest-Unknown case.
        for d in cc.protoPropReads {
            // Same two-halved member space as the method loop above: an extension-provided COMPUTED property
            // (or `subscript`) is a real `P.<member>` accessor unit whose body runs, and no conformer
            // declares it, so the conformer CHA below can never find it. Edged first, on the protocol and on
            // its transitive supers, and a member that is not also a requirement stops there.
            var providedEdged = false
            var frontier = [d.proto], seenProto = Set<String>()
            while let cur = frontier.popLast() {
                guard seenProto.insert(cur).inserted else { continue }
                let ts = resolveQual("\(cur).\(d.member)")
                if !ts.isEmpty {
                    edges[f.qual, default: []].formUnion(ts)
                    providedEdged = true
                }
                frontier.append(contentsOf: protocolSupers[cur] ?? [])
            }
            guard protoOrSuperDeclares(d.proto, d.member) else { continue }
            if let path = localProtocolWirePath(d.proto) {     // ⟨0.39⟩ obligation 1, property/subscript half
                dispatchDirect[f.qual, default: []].insert("\(pkgName)#\(path).\(d.member)")
            }
            let conf = conformers[d.proto] ?? []
            guard chaWithinBound(conf.count, d.proto, d.member, f.qual) else { continue }
            var impls = Set<String>()
            var accounted = 0
            for c in conf {
                let ts = resolveQual("\(c).\(d.member)")
                if !ts.isEmpty {
                    impls.formUnion(ts)
                    accounted += 1
                } else if fields[c]?[d.member] != nil {
                    accounted += 1   // a declared STORED property — pure, nothing to charge, not a miss
                }
            }
            if accounted == conf.count || providedEdged {
                for t in impls { edges[f.qual, default: []].insert(t) }
            } else {
                direct[f.qual, default: []].insert("Unknown")
                whyMap[f.qual, default: []].insert("dispatch:\(d.proto).\(d.member)")
            }
            // VEIN C (SOUNDNESS R876) — R867's in-scan twin, for a PROPERTY/subscript requirement. `conf`
            // holds only the types that SPELL `: P`, so `open class BaseQ: HasQ { open var qv }` and
            // `final class SubQ: BaseQ { override var qv { <fs> } }` edged `BaseQ.qv` alone and `h.qv` on
            // `h: HasQ` read pure while a `SubQ` wrote the file (executed). Same rule as the method loop:
            // precise-or-nothing, additive, real accessor units only.
            if !veinCOff {
                for c in conf.sorted() {
                    for sub in (subtypesOf[c] ?? []).sorted() where sub != c && !conf.contains(sub) {
                        let vcHits = resolveQual("\(sub).\(d.member)").filter { veinCAccessorQuals.contains($0) }
                        if veinCProbe, !vcHits.isEmpty {
                            FileHandle.standardError.write("VEINC-CONF \(f.qual) \(d.proto).\(d.member) -> \(vcHits.sorted())\n".data(using: .utf8)!)
                        }
                        edges[f.qual, default: []].formUnion(vcHits)
                    }
                }
            }
        }
        // IMPLICIT STRINGIFICATION over a PROTOCOL-typed operand — `"\(e)"` / `String(describing: e)` /
        // `print(e)` where `e: any P` (or a generic `<T: P>`): the `description`/`debugDescription` that
        // RUNS is the conformer's witness, and no call site spells it. The concrete-receiver form already
        // edged (CallCollector Vector 1/2); the existential form reached NOTHING — the four-way
        // implicit-stringification vein (candor-spec/SOUNDNESS-VEIN-implicit-stringify.md), found on
        // HikariCP through SLF4J parameterized logging and reproduced in all four engines.
        //
        // CHA over the protocol's (transitive) conformers/subclasses, like the property-read rung above —
        // but PRECISE-OR-NOTHING: a conformer set that resolves to no `description` unit edges nothing
        // instead of disclosing `Unknown`, and there is no ≤12 bound (the bound exists to decide when to
        // fall back to Unknown; with no Unknown to fall back to, capping would only DROP real dispatch
        // targets — a silent under-report, the thing being fixed). Rationale for precise-or-nothing (and
        // the honest residual): a conformer that does NOT declare `description` stringifies through the
        // stdlib's PURE reflective default, so "no local witness" is overwhelmingly "nothing runs" rather
        // than "something hidden runs" — and interpolation is pervasive enough in Swift that an Unknown
        // here would flood every program's report (the usability catastrophe the vein write-up warns
        // against). RESIDUAL, recorded not repaired: a conformer declared OUTSIDE the analysed code whose
        // `description` is effectful is still missed.
        for d in cc.stringifyDispatches {
            for c in subtypesOf[d.proto] ?? [] {
                let ts = resolveQual("\(c).\(d.member)")
                if !ts.isEmpty {
                    edges[f.qual, default: []].formUnion(ts)
                } else {
                    // an INHERITED witness (the `description` accessor lives on a superclass / a conformed
                    // protocol's extension) — climb exactly as the accessor-unit edge above does.
                    for sup in supertypesOf[c] ?? [] {
                        edges[f.qual, default: []].formUnion(resolveQual("\(sup).\(d.member)"))
                    }
                }
            }
        }
        // DESUGARED EDGES ACROSS THE SCAN BOUNDARY. Two mechanisms that run without any call being
        // spelled at the site — the implicit `description`/`debugDescription` witness of a
        // stringification, and the `deinit` glue of a constructed non-escaping local — are modeled
        // INSIDE the scan by LOCAL-only indexes (`localTypes`, `localProtocols`/`conformers`). When the
        // type belongs to a chained DEPENDENCY it is in none of them, so the site recorded NOTHING, not
        // even Unknown, and a `deny`-gated app went GREEN on code its single-package control fails
        // (candor-spec/SOUNDNESS-VEIN-crossing-the-scan-boundary.md; rust closed its stringification
        // half in candor-rust 1623a07). In both cases the dep's own report already holds the answer
        // under `<Module>#<Type>.<member>` — nothing looked for it.
        //
        // Effects attach DIRECTLY, since the dep's unit lives in another report — the shape the
        // chained-global edge (7a1b077) and the §2 call join both use. Same discipline as both: only the
        // file's OWN imports are consulted, only packages a loaded report COVERS, and only an
        // unambiguous single hit joins, so an unimported, uncovered or ambiguous type resolves to
        // nothing rather than being guessed. Both candidate sets self-filter: a pure witness / a type
        // with no effectful `deinit` is ABSENT from the dep report (reports omit pure functions), so the
        // join adds nothing. With no dep report loaded neither set is consulted at all, which is why the
        // unchained analysis is unchanged by construction.
        //
        // `propertyExternal` is the THIRD member of this set and arrived the same way: an accessor unit
        // is a body that RUNS on a property read, the dep's report carries it under the same
        // `<Module>#<Type>.<member>` key (`unitKind: "accessor"`), and the reader-side branch was
        // local-only so the read was never recorded. It self-filters identically — a STORED property and
        // a PURE computed one are absent from the dep report — and it is a candidate set rather than a
        // `propertyEdges` entry precisely so a local type sharing a dependency type's name resolves to
        // its OWN unit and can never inherit the dependency's (candor-spec SCAN-BOUNDARY-WORK-QUEUE §3c).
        if !deps.isEmpty, !(cc.stringifyExternal.isEmpty && cc.deinitExternal.isEmpty
                            && cc.propertyExternal.isEmpty) {
            let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
            for cand in cc.stringifyExternal.union(cc.deinitExternal).union(cc.propertyExternal) {
                var hits: [DepEntry] = []
                // R846 — the module the source spelled, when every recording of this candidate spelled one
                // and they agree; otherwise every chained package.
                let cmods = cc.externalCandidateOpen.contains(cand) ? [] : (cc.externalCandidateModules[cand] ?? [])
                let candTiers = joinTiers(file, module: cmods.count == 1 ? cmods.first : nil)
                for (ti, tier) in candTiers.enumerated() where hits.isEmpty {
                    for (p, _) in tier {   // R565
                        if let e = deps.lookup("\(p)#\(cand)") { hits.append(e) }
                    }
                    if ti == 0, !hits.isEmpty { discloseOtherAnswers(cand, tiers: candTiers, why: "dispatch:\(cand)", f.qual) }
                }
                // An A/B diff shows which FUNCTIONS moved, never which KEY moved them — and the one
                // over-fire this join has had (`String.init`, see `METATYPE_MEMBERS`) was invisible in
                // the diff and obvious in this line. Same reason `CANDOR_TYPESURFACE_DEBUG` exists.
                if ProcessInfo.processInfo.environment["CANDOR_DEPMEMBER_DEBUG"] != nil {
                    let kind = cc.propertyExternal.contains(cand) ? "prop"
                        : (cc.deinitExternal.contains(cand) ? "deinit" : "stringify")
                    FileHandle.standardError.write(
                        "DEPMEMBER-\(hits.count == 1 ? "HIT " : "MISS") \(kind) \(f.qual) :: \(cand)\n"
                            .data(using: .utf8)!)
                }
                // SOUNDNESS R844 — SPEC ⟨0.25⟩: an ambiguous key is UNIONED. This site kept `hits.count == 1`
                // after R842 unioned the member and global joins, and R565 made a second hit reachable:
                // `RatesCore.Client` and `OtherKit.Client` both publishing `Client.token` dropped the
                // read, the stringification and the `deinit` to ABSENT (1/1 -> 0/0 against v0.39.2).
                if hits.count > 1, joinUnionProbe {
                    FileHandle.standardError.write("JOINUNION depmember \(f.qual) \(cand) n=\(hits.count)\n".data(using: .utf8)!)
                }
                // ⟨0.40⟩ a PROPERTY read on a dependency type walks as a member call does: an inherited
                // computed property, or one forwarded through `@dynamicMemberLookup` (R890), is not a
                // purity claim.
                if !r843Off, hits.isEmpty, cc.propertyExternal.contains(cand), let dot = cand.lastIndex(of: ".") {
                    sourceTypedWalk(String(cand[..<dot]), String(cand[cand.index(after: dot)...]),
                                    tiers: candTiers, to: f.qual, guessed: false)
                }
                // SOUNDNESS R910 — a property read / `deinit` / stringification on a dependency type asks its
                // owner's package too (`viaProp910`: `s.level` on a protocol-typed parameter was ABSENT).
                if hits.isEmpty, let dot = cand.lastIndex(of: ".") {
                    let owner = String(cand[..<dot])
                    if let op = ownerKeyPkg(owner, inFile: file) {
                        askOwnKey(op, cand, asked: Set(candTiers.flatMap { $0.map { $0.p } }), to: f.qual)
                    }
                }
                guard hits.count == 1 || (!joinUnionOff && hits.count > 1) else { continue }
                for de in hits { applyDepEntry(de, to: f.qual) }
            }
        }
    }

    // Callback-flow resolution (the TS engine's callback_named, the Rust closure-flow slice): a
    // deferred fn-typed-param invocation drops its Unknown iff EVERY visible call site *that same
    // caller makes* passes a closure literal (charged to its passer lexically) or a NAMED local
    // function (edged here). No visible call site, a missing arg, or an opaque value: the §4 Unknown
    // stands.
    //
    // PER-CALLER, not per-target (⟨0.34⟩ fix — SOUNDNESS-VEIN, BACKLOG "a shared HOF's effects are
    // charged to EVERY caller"): this used to pool every call site into `fq` (the HOF) into ONE
    // judgment and, when every site happened to resolve, edge the UNION of every resolved target onto
    // `fq` itself — which every caller inherits via the ordinary call edge into `fq`. Two callers
    // passing two different named callbacks (`hof(sinkA)` doing Fs, `hof(sinkB)` pure) each then
    // inherited the OTHER caller's target too: an over-report, safe-direction, but a false positive in
    // a `deny` gate and a `tour`/scan-note diagnostic naming a call path (`2 hops away via sinkA`) the
    // pure caller never takes. `callsiteArgs` now carries the calling function alongside each site
    // (see its declaration), so the judgment below is grouped by CALLER: caller A's own sites decide
    // caller A's edge, caller B's own sites decide caller B's, and callers are never allowed to see
    // each other's resolution.
    //
    // `callsiteArgs` is NOT a complete map of every caller of `fq` — several edge-adding branches above
    // (an unqualified sibling-method call, an overloaded-sibling/init resolution, a CHA/protocol-default
    // union edge) add a plain call edge without ever recording a site, because the OLD per-target design
    // didn't need one: any caller reached `fq`'s node through the ordinary edge regardless, and inherited
    // whatever `fq` was marked. Judging PER CALLER now means a caller `callsiteArgs` never saw would
    // silently escape the judgment entirely and keep its own (unrelated) direct effects — i.e. NOTHING —
    // which is exactly the false-all-clear this fix must not introduce. `callersOf` is the fix: built
    // from `edges` itself (the same graph `propagate` trusts as ground truth for who reaches whom), so
    // every caller with a plain edge into `fq` is judged below, tracked or not; an untracked one has no
    // recorded sites and so falls to the `resolved = !argLists.isEmpty` branch — the honest Unknown.
    var callersOf: [String: Set<String>] = [:]
    for (caller, targets) in edges {
        for t in targets { callersOf[t, default: []].insert(caller) }
    }
    for (fq, info) in deferredCallbacks {
        var byCaller: [String: [[ArgKind]]] = [:]
        for site in callsiteArgs[fq] ?? [] { byCaller[site.caller, default: []].append(site.args) }
        for caller in callersOf[fq] ?? [] where byCaller[caller] == nil { byCaller[caller] = [] }
        if byCaller.isEmpty {
            // No caller reaches `fq` at all in THIS scan (dead code, or an entry point candor doesn't
            // model as a caller) — the old whole-target fallback: Unknown on `fq`'s own node. Nobody
            // inherits it (there are no callers), but it keeps `fq` itself honest if it is ever queried
            // directly (`candor path fq …`), matching the pre-fix behaviour for the unreachable case.
            direct[fq, default: []].insert("Unknown")
            for n in info.names { whyMap[fq, default: []].insert("callback:\(n)") }
            continue
        }
        // R125 — `fq`'s OWN row is honest only if SOME caller discharged the deferral. `byCaller.isEmpty`
        // above is not the only way `fq` ends up carrying nothing: when every caller is judged UNRESOLVED
        // the Unknown was written to each caller and never to `fq`, so `fq` — a function that provably
        // invokes an unaddressable value — dropped out of the report and `pure <fq>` / `deny Unknown <fq>`
        // exited 0 on it. Measured on the PUBLISHED 0.34.0 binary and introduced by `7a89dbc`, not by the
        // unpushed wave; `_BTree.forEach` in swift-collections is the real-code instance.
        // WHY THIS COSTS NO PRECISION, which is the whole reason it can be done here: it fires only when
        // NOT ONE caller resolved, so every caller of `fq` has ALREADY had the identical `Unknown` +
        // `callback:<n>` written to it three lines below. Propagating `fq`'s copy over the call edges can
        // therefore reach no caller that did not already have it — the A/B in the commit message is the
        // measurement, not this sentence.
        // SOUNDNESS R127 — …AND `anyCallerResolved` WAS THE WRONG QUANTIFIER. The paragraph that stood
        // here called the mixed case a "known residual": when SOME caller resolves the deferral and
        // another does not, `fq` was left silent, on the argument that marking it would propagate
        // `Unknown` over the ordinary call edge into the caller that resolved precisely (⟨0.34⟩'s
        // fabrication control, `testTwoCallersOfOneHOFResolveIndependently`).
        //
        // THE ARGUMENT IS TRUE AND IT PRICED ONE SIDE. What it bought was a ⟨0.21⟩ POSITIVE PURITY CLAIM
        // over a function that provably invokes an unaddressable value: `Box.hof` ABSENT from
        // `functions`, with `deny Unknown Box.hof` AND `pure Box.hof` both exit 0. What it cost is a
        // resolved caller gaining an `Unknown` it does not deserve — a false disclosure, which is the
        // cheap direction. A silent under-report outranks a precision loss; the family rule is that a
        // FIXABLE silent under-report gets fixed rather than accepted as a low residual.
        //
        // AND THE PRECISION COST IS MEASURED AT ZERO, re-measured after R563 moved resolution rates
        // (`CANDOR_R127_PROBE`, below — the counter is at the decision site so the number can be
        // re-derived rather than believed). Over 12 real corpora — alamofire, Kingfisher, nio-http2,
        // nio-ssl, swift-algorithms, swift-argument-parser, swift-async-algorithms, swift-collections,
        // swift-log, swift-nio, swift-numerics, candor-swift itself — **419 HOF deferral sites: 418 with
        // NO caller resolved (where `fq` was already marked), 1 with EVERY caller resolved (which this
        // change does not touch), and 0 MIXED.** So the corpus A/B for this change is byte-identical and
        // is SAFETY-ONLY, written down as such here rather than discovered later (§E1).
        //
        // The probe is calibrated rather than trusted: it prints
        // `R127 Box.hof callers=2 anyResolved=true allResolved=false` on the fixture below, so the
        // zero is a measurement and not a check that cannot fire.
        //
        // ALL-RESOLVED IS STILL SILENT, and that is not the same residual. When every caller discharged
        // the deferral there is no unaddressed invocation left to disclose — `fq`'s row is honest — and
        // marking it there WOULD be the ⟨0.34⟩ fabrication with nothing bought.
        var anyCallerResolved = false
        var allCallersResolved = true
        for (caller, argLists) in byCaller {
            var resolved = !argLists.isEmpty
            var namedTargets: Set<String> = []
            outer: for args in argLists {
                for idx in info.indexes {
                    guard idx < args.count else { resolved = false; break outer }
                    switch args[idx] {
                    case .named(let n):
                        if let t = freeFnByName[n], t.count == 1 { namedTargets.insert(t[0]) }
                        else { resolved = false; break outer }
                    case .closure, .opaque:
                        // a CLOSURE arg stays opaque for the deferral (the Rust/TS rule — its body is
                        // charged to the passer, but the receiver still executes an unaddressable value:
                        // the §4 Unknown stands; the fuzzer caught the looser reading red-handed)
                        resolved = false; break outer
                    }
                }
            }
            if resolved {
                // Edge from the CALLER directly to the resolved target(s) — never onto `fq`, which is
                // the shared node every OTHER caller also reaches. `fq`'s own (non-callback) direct
                // effects still apply to `caller` via the pre-existing caller->fq call edge; this adds
                // only the precisely-resolved callback effect, scoped to the one caller that chose it.
                edges[caller, default: []].formUnion(namedTargets)
                anyCallerResolved = true
            } else {
                allCallersResolved = false
                direct[caller, default: []].insert("Unknown")
                for n in info.names { whyMap[caller, default: []].insert("callback:\(n)") }
            }
        }
        if ProcessInfo.processInfo.environment["CANDOR_R127_PROBE"] != nil, !byCaller.isEmpty {
            FileHandle.standardError.write(
                ("R127 \(fq) callers=\(byCaller.count) anyResolved=\(anyCallerResolved) "
                 + "allResolved=\(allCallersResolved)\n").data(using: .utf8)!)
        }
        if !allCallersResolved {
            direct[fq, default: []].insert("Unknown")
            for n in info.names { whyMap[fq, default: []].insert("callback:\(n)") }
        }
        // SOUNDNESS R720 — …AND `allCallersResolved` IS A VACUOUS VERDICT FOR A NAME WITH NO PARAMETER
        // POSITION. `info.indexes` collects only the names `fnTypedParamIndex` could place, so for an
        // annotated fn-typed LOCAL (`let g: ([(String) -> Void]) -> Void = { … }; g(cbs)`) or a nested
        // function's own fn-typed parameter the loop above ran ZERO times per call site and `resolved`
        // kept its initial `!argLists.isEmpty`. ONE TRACKED CALLER therefore "discharged" a deferral no
        // call site can address, `allCallersResolved` stayed true, and the branch above did not fire:
        // `fq` dropped out of `functions` entirely, which under ⟨0.21⟩ is an affirmative purity claim.
        // With NO caller the `byCaller.isEmpty` fallback still marked it — which is why the symptom was
        // "the disclosure vanishes the moment the enclosing function has a call site", and why two
        // BYTE-IDENTICAL bodies in one scan disagreed. That differential is what R280 was filed on
        // (2026-09-07) and it still reproduced at `796700a`: `deny Unknown runAllWithCaller` exit 0
        // against `deny Unknown runAllNoCaller` exit 1, over a fixture whose callback was EXECUTED and
        // really deleted a file through that value (UndischargeableCallbackNameProcessTests, §E3).
        //
        // ONLY THE UNDISCHARGEABLE NAMES ARE WRITTEN, not `info.names`: in the MIXED shape — a real
        // fn-typed param plus an annotated local — the param genuinely resolved, and naming it here
        // would be the ⟨0.34⟩ fabrication this lineage already priced. `deny Unknown` reads `inferred`,
        // so every caller of `fq` inherits this over the ordinary call edge; nothing is written to a
        // caller, which is what keeps the change additive (the caller branch above is untouched).
        //
        // FAILURE DIRECTION: ADD-ONLY, by construction rather than by measurement. This block can
        // insert an `Unknown` and a `callback:<n>`; there is no path through it that removes either, and
        // every other write in this loop is unchanged. The price is a false hedge on a `let` bound to a
        // VISIBLE closure literal whose body is pure — its honest answer is no hedge, since the body is
        // charged lexically and a `let` cannot be reassigned — and `callbackInvoked` does not record
        // which kind an entry came from. The A/B in the commit message prices that; this sentence does not.
        if let un = undischargeableCallbacks[fq] {
            direct[fq, default: []].insert("Unknown")
            for n in un { whyMap[fq, default: []].insert("callback:\(n)") }
        }
    }

    // fixpoint: effects + literal surfaces propagate over edges (the pure `propagate` lives in CandorCore)
    // SOUNDNESS R951 — a comparison on a FUNCTION generic parameter runs the witness of whatever type the
    // CALLER instantiated it with: `eq(Noisy(v: 3), Noisy(v: 3))` runs `Noisy.==` inside `eq`. The edge is the
    // caller's (its instantiation), resolved from the argument type each resolved call site recorded; a call
    // site whose argument type is unknown or not local resolves nothing (no union of every witness).
    // SOUNDNESS R974 (c) — A GENERIC CALLER PASSING ITS OWN `T` ALONG INHERITS THE CALLEE'S REQUIREMENT, to a fixpoint:
    // `g<T: Equatable>(_ a: T, _ b: T) { eq(a, b) }` requires of ITS callers exactly what `eq` requires of `g`, at
    // the position `a` arrives in. The release resolved the requirement only at a call site whose argument TYPE
    // was known, so `g(Noisy(), Noisy())` reached `Noisy.==` through `eq` and reported nothing.
    // SOUNDNESS R1048 residual — …AND THE ALIGNMENT WAS POSITIONAL. `<idx>` is the callee's PARAMETER index, and
    // `site.types` / `site.forward` are indexed by ARGUMENT position, which agree only on a fully-positional call:
    // `argTypes` is blanked the moment one argument is labelled, and `&x` was never typed. So `iterL(seq: Loud())`,
    // `iterIO(&l)`, `eqL(lhs: Noisy(), rhs: Noisy())` and a labelled forward answered nothing while the program
    // ran the witness (executed). `witnessPos` aligns the call's labelled arguments to the callee's declared
    // labels (Swift's own rule: in order, a defaulted parameter may be skipped); a declaration whose labels do not
    // fit the call cannot be the callee, and declarations that fit but place `<idx>` differently answer nothing.
    // ADDITIVE: the positional answer below is kept unchanged as the floor; this only adds a second position.
    var paramShapesByQual: [String: [(labels: [String], sig: [(type: String?, hasDefault: Bool, variadic: Bool)])]] = [:]
    if !CallCollector.r1048LabelOff {
        for f in allFns where !f.paramLabels.isEmpty { paramShapesByQual[f.qual, default: []].append((f.paramLabels, f.paramSig)) }
    }
    func witnessPos(_ callee: String, _ labels: [String?]?, _ idx: Int) -> Int? {
        guard let labels, let shapes = paramShapesByQual[callee] else { return nil }
        var found: Int?? = nil   // .none = no fitting declaration yet; .some(nil) = fitting declarations disagree
        for sh in shapes {
            guard let m = alignWitnessArgs(labels, sh.labels, sh.sig) else { continue }
            let p = m[idx]
            if case .some(let prev) = found { if prev != p { return nil } } else { found = .some(p) }
        }
        return found ?? nil
    }
    if !CallCollector.r951Off, !CallCollector.r974Off {
        var changed = true, rounds = 0
        while changed, rounds < 32 {
            changed = false; rounds += 1
            for (callee, reqs) in genericWitnessReqsByUnit {
                for site in callsiteArgTypes[callee] ?? [] where !site.forward.isEmpty {
                    for req in reqs {
                        let parts = req.split(separator: ":", maxSplits: 1).map(String.init)
                        guard parts.count == 2, let idx = Int(parts[0]) else { continue }
                        var ks: [Int] = []
                        if let k = site.forward[idx] { ks.append(k) }
                        if let p = witnessPos(callee, site.wit?.labels, idx), let k = site.forward[p], !ks.contains(k) {
                            ks.append(k)
                            if CallCollector.veinBProbe {
                                FileHandle.standardError.write("VBHIT\tR1048L\tforward \(site.caller) -> \(callee) \(k)\n".data(using: .utf8)!)
                            }
                        }
                        for k in ks where genericWitnessReqsByUnit[site.caller, default: []].insert("\(k):\(parts[1])").inserted {
                            changed = true
                        }
                    }
                }
            }
        }
    }
    if !CallCollector.r951Off {
        for (callee, reqs) in genericWitnessReqsByUnit {
            for site in callsiteArgTypes[callee] ?? [] {
                for req in reqs {
                    let parts = req.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let idx = Int(parts[0]) else { continue }
                    var xs: [String] = []
                    if idx < site.types.count, let x = site.types[idx], localTypes.contains(x) { xs.append(x) }
                    if let p = witnessPos(callee, site.wit?.labels, idx), let w = site.wit, p < w.types.count,
                       let x = w.types[p], localTypes.contains(x), !xs.contains(x) {
                        xs.append(x)
                        if CallCollector.veinBProbe {
                            FileHandle.standardError.write("VBHIT\tR1048L\t\(site.caller) -> \(callee) \(x):\(parts[1])\n".data(using: .utf8)!)
                        }
                    }
                    for x in xs {
                    // SOUNDNESS R1048 — the iteration requirement: the argument's own iterator bodies, and the
                    // iterator type its `makeIterator` is declared to return.
                    if parts[1] == "#iter" {
                        guard iterableLocalTypes.contains(x) else { continue }
                        var owners = [x]
                        for m in ["makeIterator", "makeAsyncIterator"] {
                            if let it = returnFactsIdx["\(x).\(m)"]?.scalar, localTypes.contains(it) { owners.append(it) }
                        }
                        for o in owners {
                            for m in ["makeIterator", "next", "makeAsyncIterator"] {
                                edges[site.caller, default: []].formUnion(resolveQual("\(o).\(m)"))
                            }
                        }
                        continue
                    }
                    let base = "\(x).\(parts[1])"
                    let module = swiftModuleOf(locOf[site.caller] ?? "")
                    let ts = overloadedBases.contains(base) ? Set(matchOverloads(base, 2, [x, x], module)) : resolveQual(base)
                    if CallCollector.r951Probe, !ts.isEmpty {
                        FileHandle.standardError.write("R951CALLER \(site.caller) -> \(callee) \(base)\n".data(using: .utf8)!)
                    }
                    edges[site.caller, default: []].formUnion(ts)
                    }
                }
            }
        }
    }
    let inferred = propagate(direct, over: edges)
    let hostsAcc = propagate(hostsD, over: edges), cmdsAcc = propagate(cmdsD, over: edges)
    // `fs` kinds TRAVEL the call graph — a caller that transitively only writes IS a writer — and the "?"
    // poison travels with them, so a caller of an undetermined-kind function inherits the SUPPRESSION
    // rather than a half-answer. Pinned by conformance PART 31.
    let fsAcc = propagate(fsD, over: edges)
    let pathsAcc = propagate(pathsD, over: edges), tablesAcc = propagate(tablesD, over: edges)
    // the masking surface-incompleteness and the per-fn blind-module disclosure propagate the SAME way: a
    // caller transitively reaches a callee's invisible endpoint / blind module, so it inherits the flag/set.
    // SOUNDNESS R429 — A `#if` ARM THIS ENGINE COULD NOT READ MAKES THE CALLER'S SURFACE INCOMPLETE.
    // Deferred to here because the effects are not known at collection time: they arrive by propagation
    // from the sibling arm's call edge. `inferred` exists now, so the flag can be expanded into the real
    // effect names. Without this the arm the engine COULD read publishes its literal and certifies for
    // the arm it could not — `allow Fs <lit>` passing over a set whose other arm names a destination
    // nobody saw (PART 89 b9mixedallow). `Unknown` is excluded: it names no destination, so there is no
    // surface of it to be incomplete, and including it would put a meaningless key in every such row.
    //
    // PER FUNCTION, NOT PER CALL, and that is this engine's existing granularity rather than a choice
    // made here — `incomplete` is keyed by qual throughout. It over-marks a function that also reaches
    // the same effect through an unrelated, fully-determined call. That is the fail-closed direction:
    // the cost is a refusal to certify, never a silent certification.
    for q in unreadableAliasArmFns {
        let effs = (inferred[q] ?? []).subtracting(["Unknown"])
        if !effs.isEmpty { incompleteD[q, default: []].formUnion(effs) }
    }
    let incompleteAcc = propagate(incompleteD, over: edges)
    let invisibleAcc = propagate(blindDirect, over: edges)
    // ⟨0.39⟩ …and the dispatched MEMBERS travel the same way. SPEC §4 obligation 1 requires the member to
    // REACH the caller transitively, and states explicitly that a producer MAY instead publish DIRECT
    // members and let `calls` carry the closure. This engine takes the transitive spelling — the same
    // fixpoint every other transitive fact here uses — because its `calls` list is already every local
    // edge including pure ones, so both readings are available to a consumer and the transitive one costs
    // it no walk. (candor-java takes the other branch, and had to: on the JVM the closure is
    // unserialisable — jooq-3.19.10 died with 8 GB of heap. Swift protocols are not JVM interfaces; the
    // corpus A/B for this change is in the commit message.)
    let dispatchAcc = propagate(dispatchDirect, over: edges)

    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): a LOUD stderr line naming the count (like rust/java), so a
    // human sees the incompleteness even when they don't read the JSON. The machine-legible disclosure
    // rides the report's `unanalyzed` + the gate verdict (built in main.swift from this array).
    if !unanalyzed.isEmpty {
        FileHandle.standardError.write(
            // "read OR PARSED": the set is not only unreadable files. A file that reads fine and fails to
            // parse (measured: 2000-deep parens — "parsing has exceeded the maximum nesting level") lands
            // here too, and "could not be read" sends the reader to check permissions on a file whose
            // permissions are fine. The per-entry `reason` in the report already carries the true cause;
            // this line is the one a human actually sees, so it must not narrow the cause the report widens.
            "candor-swift: \(unanalyzed.count) source file(s) could not be read or parsed — NOT analyzed (their effects are unseen, not pure); see `unanalyzed` in the report for the reason on each\n"
                .data(using: .utf8)!)
    }
    // ⟨0.40⟩ THE PRODUCER (SPEC §2 ⟨0.40⟩). ⟨0.23⟩'s `returns` is PLAIN NOMINAL AND NEVER NAMES A PROTOCOL:
    // a bare `-> P` resolving to a protocol moves to `returnsProtocol`, because a shipped consumer joins a
    // `returns` value EXACTLY and would take `P`'s default body alone (SPEC §2 ⟨0.40⟩, measured on v0.39.3).
    let returnsAll = buildTypeSurfaceReturns(allFns, localTypePaths)
    var returnsNonProtocol: [String: String] = [:]
    var protocolResults: [(qual: String, spelled: String, scope: String?, file: String)] = []
    var protoQualCount: [String: Int] = [:]
    for f in allFns { protoQualCount[f.qual, default: 0] += 1 }
    for (q, ty) in returnsAll {
        if protocolPaths.contains(ty) {
            let file = String((allFns.first { $0.qual == q }?.loc ?? "").prefix { $0 != ":" })
            protocolResults.append((q, ty, nil, file))
        } else { returnsNonProtocol[q] = ty }
    }
    for f in allFns where protoQualCount[f.qual] == 1 {
        guard let sp = f.retProtocolSpelling else { continue }
        protocolResults.append((f.qual, sp, f.enclosingTypePath, String(f.loc.prefix { $0 != ":" })))
    }
    func surfaceImports(_ file: String) -> [String] { (fileImports[file] ?? []) + surfaceExported.sorted() }
    func surfaceOwnModules(_ file: String) -> Set<String> {
        (importableByFile[file] ?? []).union(ownTargetsByFile[file] ?? [])
    }
    let surface040 = buildTypeSurface040(
        pkg: pkgName, collectors: surfaceCollectors, aliases: surfaceAliases,
        isProtocolKey: { key in
            if key.hasPrefix("\(pkgName)#") { return protocolPaths.contains(String(key.dropFirst(pkgName.count + 1))) }
            return deps.surface.types[key]?.kind == "protocol"
        },
        isModuleName: { name, file in
            surfaceImports(file).contains(name) || surfaceOwnModules(file).contains(name) || deps.modulePkgs[name] != nil
        },
        resolveForeign: { spelled, file, fallback in
            let imports = surfaceImports(file)
            let own = surfaceOwnModules(file)
            let segs = spelled.split(separator: ".").map(String.init)
            if segs.count > 1, imports.contains(segs[0]) || own.contains(segs[0]) || deps.modulePkgs[segs[0]] != nil {
                let m = segs[0], rest = segs.dropFirst().joined(separator: ".")
                if PLATFORM_MODULES.contains(m) || KAPPA_MODULES.contains(m) { return .platform }
                if own.contains(m) { return .unresolved }
                return .foreign("\(deps.pkgOfModule(m))#\(rest)")
            }
            var cands = Set<String>()
            for (p, _) in deps.chainedPkgs(importing: imports)
            where deps.surface.typeKeysSeen.contains("\(p)#\(spelled)") { cands.insert("\(p)#\(spelled)") }
            if cands.count == 1, let c = cands.first { return .foreign(c) }
            if cands.count > 1 { return .unresolved }
            if STD_SUPERS_PUBLIC.contains(spelled) || PLATFORM_MODULES.contains(spelled) { return .platform }
            let foreignMods = Set(imports.filter {
                !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0) && !own.contains($0)
            })
            if foreignMods.isEmpty { return .platform }
            if fallback, foreignMods.count == 1, let m = foreignMods.first {
                return .foreign("\(deps.pkgOfModule(m))#\(spelled)")
            }
            // VEIN D — two foreign imports: the same owner proof the obligation sites use. Only a PROOF
            // resolves; an undecided name stays kind-only, which is ⟨0.40⟩'s own disclosure.
            if !veinDOff, foreignMods.count > 1, let p = provenOwnerPackage(of: spelled, inFile: file, site: "supers") {
                return .foreign("\(p)#\(spelled)")
            }
            return .unresolved
        },
        protocolResults: protocolResults)
    return Analysis(
        allFns: allFns, conformers: conformers, declaredTypes: declaredTypes,
        protocolSupers: protocolSupers, protocolNames: Set(protocolMethods.keys), protocolMethods: protocolMethods,
        importCounts: importCounts,
        uncoveredCounts: uncoveredCounts, coverageNotDeclared: coverageNotDeclared,
        direct: direct, edges: edges, whyMap: whyMap,
        locOf: locOf, entryPoints: entryPoints, inferred: inferred, hostsAcc: hostsAcc, fsD: fsAcc, privKindD: privKindD,
        cmdsAcc: cmdsAcc, pathsAcc: pathsAcc, tablesAcc: tablesAcc, incompleteAcc: incompleteAcc,
        incompleteDirect: incompleteD,
        invisibleAcc: invisibleAcc, dispatchAcc: dispatchAcc,
        abstractionOwnerPkg: abstractionOwnerPkg, abstractionUndecidedPkgs: abstractionUndecidedPkgs,
        unanalyzed: unanalyzed,
        typeSurfaceReturns: returnsNonProtocol,
        typeSurface040: surface040)
}
