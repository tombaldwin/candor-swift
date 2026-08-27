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

/// The Swift MODULE (SwiftPM target) a source path belongs to — `Sources/<Target>/…` / `Tests/<Target>/…`,
/// one module per target. Empty for anything outside that layout.
func swiftModuleOf(_ loc: String) -> String {
    let parts = loc.split(separator: ":").first.map(String.init)?.split(separator: "/").map(String.init) ?? []
    for (i, seg) in parts.enumerated() where seg == "Sources" || seg == "Tests" {
        if i + 1 < parts.count { return parts[i + 1] }
    }
    return ""
}

func analyze(sourcePaths: [String], rootDir: String, pkgName: String, deps: DepIndex = DepIndex(),
             xcodeLinksByFile: [String: [LocalProductRef]] = [:],
             xcodeModulesByFile: [String: [String]] = [:]) -> Analysis {

    var allFns: [FnInfo] = []
    var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:]
    var fieldArrayElem: [String: [String: String]] = [:]
    var fieldDictValue: [String: [String: String]] = [:]
    var opaqueFields: [String: Set<String>] = [:]
    var caseAssocAll: [String: Set<String>] = [:]
    var staticFactoryFields: [(type: String, field: String, leaf: String)] = []
    var protocolMethods: [String: Set<String>] = [:]
    var protocolSupers: [String: Set<String>] = [:]
    var conformers: [String: [String]] = [:]
    var localTypes: Set<String> = []
    var localTypePaths: Set<String> = []
    var declaredTypes: Set<String> = []
    // ⟨0.33.1⟩ scan-wide aggregate of `DeclCollector.declaredTypesUnconditional` — see that field's doc.
    var declaredTypesUnconditional: Set<String> = []
    var typeAliases: [String: String] = [:]
    var dynamicMemberTypes: Set<String> = []
    var propertyWrapperTypes: Set<String> = []
    var resultBuilderTypes: Set<String> = []
    var globalActorTypes: Set<String> = []
    // Type-level attached-macro candidates (`DeclCollector.typeMacroAttrs`, unioned across files —
    // see that field's doc). Consulted per-function below, keyed on `FnInfo.enclosingType`.
    var typeMacroAttrs: [String: [String]] = [:]
    var wrappedProps: [String: [String: String]] = [:]
    var returnsIdx: [String: String] = [:]
    var importCounts: [String: Int] = [:]
    var fileImports: [String: [String]] = [:]   // file (rel path) -> modules it imports (per-fn blind disclosure)
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
    for raw in sourcePaths {
        let abs = candorAbsolutePath(raw)
        let rel = raw.hasPrefix(rootDir)
            ? String(raw.dropFirst(rootDir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : raw
        if let pkg = owningPackage(of: abs), let own = owningTarget(of: abs, in: pkg) {
            // BOTH conjuncts: the file's TARGET can import it, AND this run actually read it.
            importableByFile[rel] = importable(forTarget: own, in: pkg)
            declaredByFile[rel] = declaredNames(forTarget: own, in: pkg)
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
        collectors.append(c)
    }
    var returnsTmp: [String: String?] = [:]
    // FINDING 1 — aggregate the opaque/erased Sequence builder indexes across files.
    var opaqueSeqLeaves: Set<String> = []
    var seqConcreteTmp: [String: String?] = [:]
    var closureFields: [String: Set<String>] = [:]   // FINDING 2 — Type -> closure-property names (own unit)
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
        allFns.append(contentsOf: c.fns)
        for (t, fs) in c.fields { fields[t, default: [:]].merge(fs) { a, _ in a } }
        for (t, fs) in c.fieldArrayElem { fieldArrayElem[t, default: [:]].merge(fs) { a, _ in a } }
        for (t, fs) in c.fieldDictValue { fieldDictValue[t, default: [:]].merge(fs) { a, _ in a } }
        for (t, fs) in c.opaqueFields { opaqueFields[t, default: []].formUnion(fs) }
        for (cn, ts) in c.caseAssoc { caseAssocAll[cn, default: []].formUnion(ts) }
        for (pn, ms) in c.protocolMethods { protocolMethods[pn, default: []].formUnion(ms) }
        for (pn, ss) in c.protocolSupers { protocolSupers[pn, default: []].formUnion(ss) }
        for (pn, ts) in c.conformers { conformers[pn, default: []].append(contentsOf: ts) }
        localTypes.formUnion(c.localTypes)
        localTypePaths.formUnion(c.localTypePaths)
        declaredTypes.formUnion(c.declaredTypes)
        declaredTypesUnconditional.formUnion(c.declaredTypesUnconditional)
        for (a, u) in c.typeAliases { typeAliases[a] = u }   // last-writer-wins (a redeclared alias is rare)
        dynamicMemberTypes.formUnion(c.dynamicMemberTypes)
        propertyWrapperTypes.formUnion(c.propertyWrapperTypes)
        resultBuilderTypes.formUnion(c.resultBuilderTypes)
        globalActorTypes.formUnion(c.globalActorTypes)
        for (t, attrs) in c.typeMacroAttrs { typeMacroAttrs[t, default: []].append(contentsOf: attrs) }
        for (t, ps) in c.wrappedProps { wrappedProps[t, default: [:]].merge(ps) { a, _ in a } }
        for m in c.imports { importCounts[m, default: 0] += 1 }
        fileImports[c.file] = c.imports
        staticFactoryFields.append(contentsOf: c.staticFactoryFields)
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
    if !overloadedQuals.isEmpty {
        var seen: [String: Int] = [:]   // identical type-sigs get a positional suffix so they stay distinct nodes
        for i in allFns.indices where !allFns[i].isAccessor && !allFns[i].isTopLevel && overloadedQuals.contains(allFns[i].qual) {
            let base = allFns[i].simpleQual
            overloadedBases.insert(base)
            var suffix = sigStr(allFns[i].paramSig)
            let dupKey = "\(allFns[i].qual)\(suffix)"
            let n = seen[dupKey, default: 0]; seen[dupKey] = n + 1
            if n > 0 { suffix += "#\(n)" }
            overloads[base, default: []].append(("\(allFns[i].qual)\(suffix)", allFns[i].paramSig,
                                                 swiftModuleOf(allFns[i].loc)))
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
    // Match a call (arg count + inferred arg types) to overload target qual(s). Empty ⇒ confident no local
    // overload matches ⇒ DROP. Non-empty ⇒ edge to all (one hit precise; several = sound union). A closure so
    // it captures `overloads`/`subtypesOf`.
    let matchOverloads: (String, Int, [String?], String) -> [String] = { base, argc, argTypes, callerModule in
        guard let cands = overloads[base] else { return [] }
        var hits: [String] = []
        var hitsInCallerModule: [String] = []
        for c in cands {
            // arity by COUNT RANGE: a call must provide every REQUIRED param (not defaulted, not variadic) and
            // no more than the total — independent of WHICH params a labeled call omitted. A trailing VARIADIC
            // (`T...`) lifts the upper bound (it absorbs any number of args).
            let variadicIdx = c.sig.firstIndex(where: { $0.variadic })
            let required = c.sig.filter { !$0.hasDefault && !$0.variadic }.count
            let upper = variadicIdx != nil ? Int.max : c.sig.count
            if argc < required || argc > upper { continue }
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
            if ok {
                hits.append(c.qual)
                if c.module == callerModule { hitsInCallerModule.append(c.qual) }
            }
        }
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

    for (k, v) in returnsTmp { if let t = v { returnsIdx[k] = t } }
    // `static let shared = factory()` — now that the returns index exists, resolve the factory's vended
    // type and record it as the field's type, so `let r = Type.shared` carries the REAL type (not the
    // static's own type — the review's free-factory singleton find). Only an UNAMBIGUOUS factory return
    // types it; an unknown leaf leaves the field unrecorded (the binder then clears rather than guessing).
    for (ty, field, leaf) in staticFactoryFields where fields[ty]?[field] == nil {
        if let vended = returnsIdx[leaf] { fields[ty, default: [:]][field] = (vended, false) }
    }
    // An enum case binds a value type only when it is UNAMBIGUOUS project-wide (one assoc type) —
    // the same "never guess on an ambiguous leaf" discipline as the returns index.
    var enumCaseValueType: [String: String] = [:]
    for (cn, ts) in caseAssocAll where ts.count == 1 { enumCaseValueType[cn] = ts.first! }

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
    var blindDirect: [String: Set<String>] = [:]    // fn -> blind modules it DIRECTLY reaches (per-fn `invisible`)
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
    func blindModules(inFile file: String) -> Set<String> {
        let importable = importableByFile[file] ?? []
        return Set((fileImports[file] ?? []).filter {
            !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0) && !importable.contains($0)
                && !deps.coveredPkgs.contains($0) })
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
    for (file, imports) in fileImports {
        let importable = importableByFile[file] ?? []
        for m in imports where !PLATFORM_MODULES.contains(m) && !KAPPA_MODULES.contains(m)
                                && !importable.contains(m) {
            guard !deps.coveredPkgs.contains(m) else {
                if let declared = declaredByFile[file], !declared.contains(m) {
                    coverageNotDeclared[m, default: []].insert(file)
                }
                continue
            }
            uncoveredCounts[m, default: 0] += 1
        }
    }
    var locOf: [String: String] = [:]
    var entryPoints: Set<String> = []
    var callsiteArgs: [String: [[ArgKind]]] = [:]   // resolved target -> each call site's arg kinds
    var deferredCallbacks: [String: (indexes: Set<Int>, names: Set<String>)] = [:]

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
        direct[qual, default: []].formUnion(de.effects)
        if de.effects.contains("Unknown") {
            if let why = de.whyReason { whyMap[qual, default: []].insert(why) }
            // ⟨0.19⟩ the dependency's OWN reason tokens travel too, so the reason CLASS survives the
            // boundary and `deny E Unknown[<class>]` is not silently inert on a chained consumer.
            // `dep:<hash>` above names WHERE; these name WHY. See DepEntry.whyClasses.
            whyMap[qual, default: []].formUnion(de.whyClasses)
        }
        hostsD[qual, default: []].formUnion(de.hosts)
        cmdsD[qual, default: []].formUnion(de.cmds)
        pathsD[qual, default: []].formUnion(de.paths)
        tablesD[qual, default: []].formUnion(de.tables)
        if !de.invisible.isEmpty { blindDirect[qual, default: []].formUnion(de.invisible) }
        if !de.incomplete.isEmpty { incompleteD[qual, default: []].formUnion(de.incomplete) }
    }

    let localProtocolNames = Set(protocolMethods.keys)  // loop-invariant: build once, not per fn
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
    // The module names the SCANNED PROJECT itself defines (`Sources/<Module>/…`, `Tests/<Module>/…`).
    // A dotted callee whose base is one of these is NOT a platform spelling — under `@testable import
    // App`, `App.Process()` names the project's own type — so `isModuleQualifier` refuses it. See
    // `CallCollector.importedModules`.
    let projectModules = Set(allFns.map { swiftModuleOf($0.loc) }).subtracting([""])
    for f in allFns {
        locOf[f.qual] = f.loc
        if f.isMain { entryPoints.insert(f.qual) }
        edges[f.qual] = edges[f.qual] ?? []
        guard let body = f.body else { continue }
        let cc = CallCollector(info: f, fields: fields, localTypes: localTypes,
                               declaredTypes: declaredTypes,
                               localProtocols: localProtocolNames, returns: returnsIdx,
                               fieldArrayElem: fieldArrayElem, fieldDictValue: fieldDictValue,
                               opaqueFields: opaqueFields,
                               enumCaseValueType: enumCaseValueType, dynamicMemberTypes: dynamicMemberTypes,
                               propertyWrapperTypes: propertyWrapperTypes, wrappedProps: wrappedProps,
                               localFreeFns: localFreeFnNames.union(localFreeFnBaseNamesByModule[swiftModuleOf(f.loc)] ?? []),
                               conditionallyShadowedFreeFns: conditionalOnlyFreeFnNames.union(conditionalOnlyFreeFnNamesByModule[swiftModuleOf(f.loc)] ?? []),
                               conditionallyShadowedTypes: conditionallyShadowedTypeNames,
                               typeAliases: typeAliases,
                               enclosingMembers: f.enclosingType.map { t in
                                   membersVisibleCache[t] ?? {
                                       let m = membersVisibleOn(t); membersVisibleCache[t] = m; return m
                                   }()
                               } ?? [],
                               opaqueSeqBuilders: opaqueSeqBuilders, seqBuilderConcrete: seqBuilderConcrete,
                               closureFields: closureFields, moduleConstStrings: globalConstStrings,
                               importedModules: Set(fileImports[String(f.loc.prefix { $0 != ":" })] ?? []),
                               projectModules: projectModules, deps: deps)
        // The locator-move set is flow-INSENSITIVE and must be complete before the first call is collected
        // (a rebind later in the text, or earlier in time inside a loop, still invalidates the claim). The
        // parameter names go with it: a body binder that SHADOWS a parameter is the same hazard, and the
        // signature is the one binder site the body walk cannot see.
        cc.prescanLocatorMoves(body, params: f.paramNames)
        cc.walk(body)
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
            if let inMod = globalsByModule[readerModule]?[name], inMod.count == 1 {
                edges[f.qual, default: []].insert(inMod[0])
            } else if globalUnitNames.contains(name) {
                edges[f.qual, default: []].insert(name)
            } else if !deps.isEmpty {
                // The global may belong to a chained DEPENDENCY module. Reading it still forces its
                // initializer — swift globals are lazy — and the dep's report records that unit under
                // `<Module>#<name>`, but nothing looked for it, so a consumer of an effectful dependency
                // global read sound-complete pure (candor-spec SOUNDNESS-VEIN-initializer-edge.md; java and
                // rust needed the same edge on their side of the boundary). Effects attach directly, since
                // the dep's unit lives in another report. Only the file's own imports are consulted and only
                // an unambiguous single hit joins, so an unimported or ambiguous name resolves to nothing.
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                var hits: [DepEntry] = []
                for m in fileImports[file] ?? [] where deps.isChained(m) {
                    if let e = deps.lookup("\(m)#\(name)") { hits.append(e) }
                }
                if hits.count == 1, let de = hits.first { applyDepEntry(de, to: f.qual) }
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

        // fn-typed params INVOKED: defer to callback-flow (resolved after all call sites are known)
        if !cc.callbackInvoked.isEmpty {
            var idxs = Set<Int>()
            for n in cc.callbackInvoked {
                if let i = f.fnTypedParamIndex[n] { idxs.insert(i) }
            }
            deferredCallbacks[f.qual] = (idxs, cc.callbackInvoked)
        }
        for call in cc.calls {
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
                callsiteArgs[inMod[0], default: []].append(call.args)
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
                            callsiteArgs[t, default: []].append(call.args)
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
                            for m in fileImports[file] ?? [] where deps.isChained(m) {
                                if let de = deps.lookup("\(m)#\(sup).\(member)") {
                                    applyDepEntry(de, to: f.qual)
                                    resolved = true
                                }
                            }
                        }
                    }
                }
            } else if call.typed {
                let typedTargets = resolveQual(call.path)   // hoisted: the else-if chain below reads it once
                if overloadedBases.contains(call.path) {
                    for t in matchOverloads(call.path, argc, call.argTypes, swiftModuleOf(f.loc)) {
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append(call.args)
                        resolved = true
                    }
                } else if !typedTargets.isEmpty {
                    for t in typedTargets {
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append(call.args)
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
                            for t in matchOverloads(base, argc, call.argTypes, swiftModuleOf(f.loc)) {
                                edges[f.qual, default: []].insert(t)
                                callsiteArgs[t, default: []].append(call.args)
                                resolved = true
                            }
                        } else {
                            for t in resolveQual(base) {
                                edges[f.qual, default: []].insert(t)
                                callsiteArgs[t, default: []].append(call.args)
                                resolved = true
                            }
                        }
                    }
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
                        let extSupers = (supertypesOf[type] ?? []).filter { !localTypes.contains($0) }.sorted()
                        if let eff = extSupers.compactMap({ FLUENT_MODEL_PROTOCOLS.contains($0) ? fluentModelEffect(member) : nil }).first {
                            direct[f.qual, default: []].insert(eff)
                            resolved = true
                        } else if let sup = extSupers.first(where: { !STD_PURE_PROTOCOLS.contains($0) }) {
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
                if overloadedBases.contains(call.path) {            // an overloaded FREE function
                    for t in matchOverloads(call.path, argc, call.argTypes, swiftModuleOf(f.loc)) {
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append(call.args)
                        resolved = true
                    }
                } else if let targets = freeFnByName[call.path], targets.count == 1 {
                    edges[f.qual, default: []].insert(targets[0])
                    callsiteArgs[targets[0], default: []].append(call.args)
                    resolved = true
                } else if localTypes.contains(call.path), overloadedBases.contains("\(call.path).init") {
                    for t in matchOverloads("\(call.path).init", argc, call.argTypes, swiftModuleOf(f.loc)) {
                        edges[f.qual, default: []].insert(t)
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
                    edges[f.qual, default: []].formUnion(resolveQual("\(call.path).init"))
                    resolved = true
                } else if let et = f.enclosingType, overloadedBases.contains("\(et).\(call.leaf)") {  // overloaded sibling
                    for t in matchOverloads("\(et).\(call.leaf)", argc, call.argTypes, swiftModuleOf(f.loc)) {
                        edges[f.qual, default: []].insert(t)
                        resolved = true
                    }
                } else if let ep = f.enclosingTypePath, byQual.contains("\(ep).\(call.leaf)") {
                    // an unqualified call inside a type body reaches the sibling method — resolved against the
                    // FULL enclosing path, so a nested type's sibling call hits its own member precisely (never
                    // a same-named sibling under a different parent).
                    edges[f.qual, default: []].insert("\(ep).\(call.leaf)")
                    resolved = true
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
            if !resolved, !call.typed, !call.unqualified, !call.opaqueRecv, let owner = call.extOwner,
               !localTypes.contains(owner), !STD_PURE_PROTOCOLS.contains(owner),
               !RAW_VALUE_BASE_TYPES.contains(owner) {
                for sub in subtypesOf[owner] ?? [] {
                    edges[f.qual, default: []].formUnion(resolveQual("\(sub).\(call.leaf)"))
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
                    var hits: [DepEntry] = []
                    var surfaced: [String] = []
                    for m in fileImports[file] ?? [] where deps.isChained(m) {
                        guard let ty = deps.boundType("\(m)#\(callee)") else { continue }
                        surfaced.append(ty)
                        if let e = deps.lookup("\(ty).\(call.leaf)") { hits.append(e) }
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
                    if answers.count == 1, hits.count == 1, let de = hits.first {
                        applyDepEntry(de, to: f.qual)
                        continue
                    }
                }
                // A MISS — on `returns` OR on the entry lookup that follows a `returns` HIT — falls back
                // to half 1's disclosure, NEVER to silence. The second half is the one that is easy to get
                // wrong and is a requirement rather than belt-and-braces: this index DROPS a key two
                // entries share (§2 rule 1), so a miss cannot distinguish "no such method" from "I
                // withdrew the answer", and a refusal to answer is not a purity claim. rust shipped that
                // `continue` and reverted it.
                if (fileImports[file] ?? []).contains(where: { deps.isChained($0) }) {
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
            if !resolved, !deps.isEmpty, !call.typed {
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                var hits: [DepEntry] = []
                for m in fileImports[file] ?? [] where deps.isChained(m) {
                    if call.unqualified {
                        if let e = deps.lookup("\(m)#\(call.path)") ?? deps.lookup("\(m)#\(call.path).init") {
                            hits.append(e)
                        }
                    } else if let owner = call.extOwner {
                        if let e = deps.lookup("\(m)#\(owner).\(call.leaf)")
                            ?? (owner == m ? deps.lookup("\(m)#\(call.leaf)") : nil) {
                            hits.append(e)
                        }
                    }
                }
                if hits.count == 1, let de = hits.first {
                    // inherit the dep fn's own honesty markers too, so the consumer's verdict stays
                    // qualified across the chain boundary (a benign literal HERE must not certify the
                    // dep's invisible runtime endpoint) — see applyDepEntry.
                    applyDepEntry(de, to: f.qual)
                    resolved = true
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
            if !resolved && call.unqualified {
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                let blind = blindModules(inFile: file)
                for m in fileImports[file] ?? [] where blind.contains(m) {
                    blindDirect[f.qual, default: []].insert(m)
                }
            } else if !resolved, let owner = call.extOwner,
                      blindModules(inFile: String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })).contains(owner) {
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
            // OVERLOADS RESOLVE HERE EXACTLY AS THEY DO ON THE TYPED-CALL PATH, and that is not a detail.
            // The typed path routes an overloaded base through `matchOverloads`; answering it with a bare
            // `resolveQual` (which cannot name an overloaded base) DROPPED every sibling-overload edge at
            // such a site. MEASURED by the corpus A/B — swift-syntax `TokenConsumer.consume(_)` lost 5
            // edges, swift-protobuf `Message.init(String,ExtensionMap)` lost 10, firebase `Storage.bucket`
            // lost its only one — and by nothing else, because no fixture had an overloaded provided
            // member. `callsiteArgs` is recorded for the same reason the typed path records it: it is what
            // callback-flow resolves fn-typed parameters against.
            var providedEdged = false
            var frontier = [d.proto], seenProto = Set<String>()
            while let cur = frontier.popLast() {
                guard seenProto.insert(cur).inserted else { continue }
                // a SUPER-protocol's extension provides the member too (`protocol Sub: Sup`, `extension Sup`)
                let base = "\(cur).\(d.member)"
                if overloadedBases.contains(base) {
                    // `argc < 0` — an operator witness, which records no argument shape: union every
                    // overload rather than drop them all (the same sound over-approximation matchOverloads
                    // itself falls back to when the argument types cannot discriminate).
                    let targets = d.argc >= 0
                        ? matchOverloads(base, d.argc, d.argTypes, swiftModuleOf(f.loc))
                        : (overloads[base] ?? []).map(\.qual)
                    for t in targets {
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append(d.args)
                        providedEdged = true
                    }
                } else {
                    let ts = resolveQual(base)
                    if !ts.isEmpty {
                        for t in ts {
                            edges[f.qual, default: []].insert(t)
                            callsiteArgs[t, default: []].append(d.args)
                        }
                        providedEdged = true
                    }
                }
                frontier.append(contentsOf: protocolSupers[cur] ?? [])
            }
            // Not a requirement: the extension body edged above IS the answer. If neither half knows the
            // member it stays a silent drop, exactly as before (an inherited external member, a κ call on a
            // protocol-named receiver) — never a guess, never a new Unknown flood.
            guard protoOrSuperDeclares(d.proto, d.member) else { continue }
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
                let implResults = conf.map { resolveQual("\($0).\(d.member)") }
                let resolvedCount = implResults.filter { !$0.isEmpty }.count
                if resolvedCount == conf.count || providedEdged {
                    for ts in implResults { edges[f.qual, default: []].formUnion(ts) }
                } else {
                    direct[f.qual, default: []].insert("Unknown")
                    whyMap[f.qual, default: []].insert("dispatch:\(d.proto).\(d.member)")
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
                for m in fileImports[file] ?? [] where deps.isChained(m) {
                    if let e = deps.lookup("\(m)#\(cand)") { hits.append(e) }
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
                guard hits.count == 1, let de = hits.first else { continue }
                applyDepEntry(de, to: f.qual)
            }
        }
    }

    // Callback-flow resolution (the TS engine's callback_named, the Rust closure-flow slice): a
    // deferred fn-typed-param invocation drops its Unknown iff EVERY visible call site passes a
    // closure literal (charged to its passer lexically) or a NAMED local function (edged here).
    // No visible call site, a missing arg, or an opaque value: the §4 Unknown stands.
    for (fq, info) in deferredCallbacks {
        let sites = callsiteArgs[fq] ?? []
        var resolved = !sites.isEmpty
        var namedTargets: Set<String> = []
        outer: for site in sites {
            for idx in info.indexes {
                guard idx < site.count else { resolved = false; break outer }
                switch site[idx] {
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
            edges[fq, default: []].formUnion(namedTargets)
        } else {
            direct[fq, default: []].insert("Unknown")
            for n in info.names { whyMap[fq, default: []].insert("callback:\(n)") }
        }
    }

    // fixpoint: effects + literal surfaces propagate over edges (the pure `propagate` lives in CandorCore)
    let inferred = propagate(direct, over: edges)
    let hostsAcc = propagate(hostsD, over: edges), cmdsAcc = propagate(cmdsD, over: edges)
    // `fs` kinds TRAVEL the call graph — a caller that transitively only writes IS a writer — and the "?"
    // poison travels with them, so a caller of an undetermined-kind function inherits the SUPPRESSION
    // rather than a half-answer. Pinned by conformance PART 31.
    let fsAcc = propagate(fsD, over: edges)
    let pathsAcc = propagate(pathsD, over: edges), tablesAcc = propagate(tablesD, over: edges)
    // the masking surface-incompleteness and the per-fn blind-module disclosure propagate the SAME way: a
    // caller transitively reaches a callee's invisible endpoint / blind module, so it inherits the flag/set.
    let incompleteAcc = propagate(incompleteD, over: edges)
    let invisibleAcc = propagate(blindDirect, over: edges)

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
    return Analysis(
        allFns: allFns, conformers: conformers, declaredTypes: declaredTypes,
        protocolSupers: protocolSupers, protocolNames: Set(protocolMethods.keys), importCounts: importCounts,
        uncoveredCounts: uncoveredCounts, coverageNotDeclared: coverageNotDeclared,
        direct: direct, edges: edges, whyMap: whyMap,
        locOf: locOf, entryPoints: entryPoints, inferred: inferred, hostsAcc: hostsAcc, fsD: fsAcc, privKindD: privKindD,
        cmdsAcc: cmdsAcc, pathsAcc: pathsAcc, tablesAcc: tablesAcc, incompleteAcc: incompleteAcc,
        incompleteDirect: incompleteD,
        invisibleAcc: invisibleAcc, unanalyzed: unanalyzed,
        typeSurfaceReturns: buildTypeSurfaceReturns(allFns, localTypePaths))
}
