import Foundation
import CandorCore
import SwiftSyntax

// SOUNDNESS R1938 (type-identity lane LS) — THE NARROW PLATFORM-NAME SHADOW.
//
// The engine's type key space is the scan's SIMPLE names (`localTypes`, `declaredTypes`), unioned package-wide. So a scan type
// named like a platform or κ type — `Node.Data` nested in a target nobody imports, a top-level `struct Data` in a sibling target
// the file does not import — captured EVERY bare `Data` in the package, at both layers:
//   layer 1, the binding: `canonicalTypeRef("Data")` answered "local", and `d.write(to:)` bound the union `Node.Data.write` +
//            `Outer.Data.write`;
//   layer 2, the κ shadow: every `declaredTypes.contains("Data")` fence suppressed the curated classification.
// Executed (Tests/Fixtures/TypeIdentity fx6, fx9, fx9r): `Data(…).write(to:)` WRITES, the row was ABSENT, `deny Fs` and
// `deny Fs Unknown` exited 0, on v0.43.0 and on main.
//
// THE RULE (DESIGN.md §2.3, the part this lane needs). For a unit U and a platform name N, Swift can see a scan type named N from
// U's own scope only through: a type nested in U's enclosing path (or a member alias there); a type or alias nested in, or an
// associated type of, one of the enclosing types' supertypes; a generic parameter or a body-local declaration named N; a top-level
// declaration (or non-private alias) of N in U's own module or in an own module U's file can see (imports + `@_exported` closure).
// When NONE of those holds, every spelling of bare N WRITTEN IN U's BODY names a non-scan type — the platform's, or a dependency's —
// and the engine must read it exactly as it reads N in a package with the invisible declarations renamed (the fx6 control Pkg6c).
// That is what `names(…)` returns: the names for which that "as if undeclared" reading applies to U's in-scope spellings.
//
// REFUSALS, each the conservative direction (U keeps today's reading, which is main's):
//   · the file has no manifest/Xcode target (DESIGN §2.4: the module, and so the visible set, is unknown);
//   · an enclosing type the scan does not DECLARE (an extension of a dependency type: its member types are unknown), unless it
//     is a platform nominal, whose nested types the generated `STDLIB_NOMINALS` lists (refused when it lists `T.N`);
//   · an enclosing type with a supertype the scan does not declare that is not a stdlib protocol (a dependency superclass or
//     protocol may contribute a member type or an associated type named N), or a stdlib protocol whose associated type is N
//     (`Clock.Duration`);
//   · a scan supertype nesting N, aliasing N, or a scan protocol (enclosing or a supertype) declaring an associated type N (L4
//     owns that walk);
//   · a κ PACKAGE name (`File`, `Storage`, `Logger` (swift-log half), `Channel`, …) unless the file sees one of that package's modules.
//
// SCOPE (DESIGN §7.1): this index decides; CallCollector applies the answer ONLY to spellings whose scope is the unit — a local
// annotation, a local constructor, an inline constructor head, `as!`, and a receiver bound by one of those. Fields, globals,
// returns and closure parameters typed from a callee's signature keep their binding: their spelling's scope is a declaration
// elsewhere (Fable's F-B3r, fx7 `H.b3r`). Kill switch `CANDOR_TYPE_ID_SHADOW_OFF`.

/// Every name the platform modules declare (nominals and protocols), plus the κ member roots.
let LS_PLATFORM_NAMES_R1938: Set<String> = {
    var s = Set(STDLIB_NOMINALS.filter { !$0.contains(".") })
    s.formUnion(PLATFORM_VALUE_TYPES)
    s.formUnion(STDLIB_PROTOCOLS.filter { !$0.contains(".") })
    for (n, e) in KAPPA_REGISTRY where e.surfaces.contains(.member) && n.first?.isUppercase == true { s.insert(n) }
    return s
}()

/// A κ name that describes ONLY package entities -> those packages' modules (a name that also describes a platform entity, such
/// as `Logger`, is platform and needs no import).
let LS_PACKAGE_ONLY_MODULES_R1938: [String: Set<String>] = {
    var out: [String: Set<String>] = [:]
    for (n, e) in KAPPA_REGISTRY where e.surfaces.contains(.member) {
        var mods: Set<String> = [], platform = false
        for d in e.describes {
            switch d {
            case .platform: platform = true
            case .package(let p, _): mods.formUnion(p.modules ?? [])
            }
        }
        if !platform { out[n] = mods }
    }
    return out
}()

/// Stdlib protocols with an associated type whose name is itself a platform nominal. A conformer's bare spelling of that name
/// means the WITNESS, not the platform type.
let LS_STDLIB_ASSOC_COLLISIONS_R1938: Set<String> = ["Duration"]

struct LsShadowIndexR1938 {
    /// The platform names some scan file DECLARES (a real declaration, nested or top-level, not an extension).
    let candidates: Set<String>
    let idx: ModuleIdentityIndex
    /// N -> own modules declaring top-level N (a type, or a non-private top-level alias).
    let topLevelModules: [String: Set<String>]
    /// N -> files declaring a PRIVATE/fileprivate top-level alias N.
    let privateAliasFiles: [String: Set<String>]
    let localTypePaths: Set<String>
    let declaredTypePaths: Set<String>
    /// type path -> member alias names declared on it; simple owner -> member alias names.
    let memberAliasNamesByPath: [String: Set<String>]
    let memberAliasNamesBySimple: [String: Set<String>]
    /// scan protocol path -> its associated types (and primary associated types)
    let assocByProtocol: [String: Set<String>]
    let protocolPaths: Set<String>
    /// simple name -> its declared full paths
    let pathsByLeaf: [String: Set<String>]
    let supertypesBySimple: [String: Set<String>]
    let supertypesByPath: [String: Set<String>]
    /// protocol -> the protocols it refines (kept out of `supertypes*` by the Driver, so closed over here)
    let protocolSupers: [String: Set<String>]
    let typeGenericNames: [String: Set<String>]

    func isScanDeclared(_ seg: String) -> Bool {
        declaredTypePaths.contains(seg) || protocolPaths.contains(seg) || !(pathsByLeaf[seg]?.isEmpty ?? true)
            || protocolPaths.contains { $0 == seg || $0.hasSuffix("." + seg) }
    }
    /// A scan protocol named `s` (simple or path) declares an associated type `n`.
    private func protocolAssoc(_ s: String, _ n: String) -> Bool {
        if assocByProtocol[s]?.contains(n) == true { return true }
        let leaf = s.split(separator: ".").last.map(String.init) ?? s
        return assocByProtocol.contains { (p, a) in (p == leaf || p.hasSuffix("." + leaf)) && a.contains(n) }
    }
    /// A supertype spelled with a platform module qualifier (`Swift.Error`, `Foundation.LocalizedError`) is that platform name.
    private func unqualifiedPlatform(_ s: String) -> String {
        for m in ["Swift.", "Foundation.", "_Concurrency.", "Dispatch."] where s.hasPrefix(m) { return String(s.dropFirst(m.count)) }
        return s
    }

    /// Does scan type `s` (a simple name or a path) make N visible as a member type of its subtypes?
    private func supertypeContributes(_ s: String, _ n: String) -> Bool {
        let leaf = s.split(separator: ".").last.map(String.init) ?? s
        var paths = pathsByLeaf[leaf] ?? []
        if declaredTypePaths.contains(s) { paths.insert(s) }
        for p in paths {
            if localTypePaths.contains(p + "." + n) { return true }
            if memberAliasNamesByPath[p]?.contains(n) == true { return true }
        }
        if memberAliasNamesBySimple[leaf]?.contains(n) == true { return true }
        if localTypePaths.contains(leaf + "." + n) { return true }   // `extension S { struct N }`
        return false
    }

    /// The platform names whose bare in-unit spellings read "as if undeclared" in this unit, and why each refused one refused
    /// (for the probe). `bodyDecls` are the type/alias names declared inside the unit's own body.
    func names(file: String, enclosingPath: String?, generics: Set<String>, bodyDecls: Set<String>) -> (ok: Set<String>, refused: [String: String]) {
        var ok: Set<String> = [], refused: [String: String] = [:]
        guard !candidates.isEmpty else { return (ok, refused) }
        guard let module = idx.moduleOf(file) else {
            for n in candidates { refused[n] = "no-module" }
            return (ok, refused)
        }
        let visible = idx.visibleModules(inFile: file)
        let segs = (enclosingPath ?? "").split(separator: ".").map(String.init)
        var prefixes: [String] = []
        for i in segs.indices { prefixes.append(segs[0...i].joined(separator: ".")) }
        // the enclosing types must be scan-declared, or a PLATFORM nominal whose own nested types the generated table lists
        // (`STDLIB_NOMINALS` holds `AsyncStream.Iterator` etc.); an extension of any other foreign type has unknown member types
        let foreignPrefixes = prefixes.filter { !declaredTypePaths.contains($0) && !isScanDeclared($0) }
        let foreignEnclosing: String? = foreignPrefixes.first { !STDLIB_NOMINALS.contains($0) }
        let platformEnclosing = foreignPrefixes.filter { STDLIB_NOMINALS.contains($0) }
        // the supertypes of every enclosing type, transitively as the Driver already computes them
        var supers: Set<String> = []
        for (i, p) in prefixes.enumerated() {
            supers.formUnion(supertypesByPath[p] ?? [])
            supers.formUnion(supertypesBySimple[segs[i]] ?? [])
        }
        // an enclosing PROTOCOL's refinements, and every supertype's, transitively (associated types and extension aliases are
        // inherited through refinement)
        for (i, p) in prefixes.enumerated() where protocolPaths.contains(p) || assocByProtocol[segs[i]] != nil { supers.insert(segs[i]) }
        var frontier = Array(supers)
        while let x = frontier.popLast() {
            let leaf = x.split(separator: ".").last.map(String.init) ?? x
            for q in (protocolSupers[x] ?? []).union(protocolSupers[leaf] ?? []) where supers.insert(q).inserted { frontier.append(q) }
        }
        var genericAll = generics
        for s in segs { genericAll.formUnion(typeGenericNames[s] ?? []) }
        for n in candidates.sorted() {
            if let pkgMods = LS_PACKAGE_ONLY_MODULES_R1938[n], pkgMods.isDisjoint(with: visible) { refused[n] = "kappa-package-not-imported"; continue }
            if genericAll.contains(n) { refused[n] = "generic"; continue }
            if bodyDecls.contains(n) { refused[n] = "body-local"; continue }
            if let fe = foreignEnclosing { refused[n] = "foreign-enclosing:\(fe)"; continue }
            if let pe = platformEnclosing.first(where: { STDLIB_NOMINALS.contains($0 + "." + n) }) { refused[n] = "platform-nested:\(pe).\(n)"; continue }
            if let p = prefixes.first(where: { localTypePaths.contains($0 + "." + n) || memberAliasNamesByPath[$0]?.contains(n) == true }) {
                refused[n] = "visible-nested:\(p).\(n)"; continue
            }
            if let p = prefixes.first(where: { protocolPaths.contains($0) && protocolAssoc($0, n) }) { refused[n] = "assoc:\(p).\(n)"; continue }
            if let s = supers.sorted().first(where: { sup0 in
                let sup = unqualifiedPlatform(sup0)
                if isScanDeclared(sup) { return supertypeContributes(sup, n) || protocolAssoc(sup, n) }
                if STDLIB_PROTOCOLS.contains(sup) || PLATFORM_LEAVES.contains(sup) || STDLIB_NOMINALS.contains(sup) {
                    return LS_STDLIB_ASSOC_COLLISIONS_R1938.contains(n) || STDLIB_NOMINALS.contains(sup + "." + n)
                }
                return true
            }) {
                refused[n] = "supertype:\(s)"; continue
            }
            let tops = topLevelModules[n] ?? []
            if tops.contains(module) { refused[n] = "own-module-top-level"; continue }
            if !tops.isDisjoint(with: visible) { refused[n] = "visible-module-top-level"; continue }
            if privateAliasFiles[n]?.contains(file) == true { refused[n] = "file-alias"; continue }
            ok.insert(n)
        }
        return (ok, refused)
    }
}

/// The type and alias names a unit's own BODY declares (a body-local type shadows every outer one).
func lsBodyDeclNamesR1938(_ body: Syntax?) -> Set<String> {
    guard let body else { return [] }
    final class V: SyntaxVisitor {
        var out: Set<String> = []
        override func visit(_ n: StructDeclSyntax) -> SyntaxVisitorContinueKind { out.insert(n.name.text); return .visitChildren }
        override func visit(_ n: ClassDeclSyntax) -> SyntaxVisitorContinueKind { out.insert(n.name.text); return .visitChildren }
        override func visit(_ n: EnumDeclSyntax) -> SyntaxVisitorContinueKind { out.insert(n.name.text); return .visitChildren }
        override func visit(_ n: ActorDeclSyntax) -> SyntaxVisitorContinueKind { out.insert(n.name.text); return .visitChildren }
        override func visit(_ n: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { out.insert(n.name.text); return .visitChildren }
        override func visit(_ n: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { out.insert(n.name.text); return .visitChildren }
        override func visit(_ n: GenericParameterSyntax) -> SyntaxVisitorContinueKind { out.insert(n.name.text); return .visitChildren }
    }
    let v = V(viewMode: .sourceAccurate)
    v.walk(body)
    return v.out
}
