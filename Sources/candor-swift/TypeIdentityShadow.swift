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
    /// `Own.T…` -> `T…` when `Own` is an own module (Fable merge review B1), else nil. The stripped spelling is ADDED beside the
    /// recorded one, never instead of it, and a head that is ALSO some scan type's name is stripped too (Fable recheck B2: a
    /// package-wide "not a type name" exclusion missed `extension Own15.Outer15` when a sibling target declares `struct Own15`, though
    /// Swift's shadowing is per file). A wrong strip can only add a refusal, i.e. keep main's reading; the per-file rule is a
    /// design-queue row, not this lane's.
    let stripOwnModule: (String) -> String?
    /// R1950 — a WIDENED (own-module-stripped) path -> the spelling the scan recorded it under (`Outer13.Data` ->
    /// `Own13.Outer13.Data`), so a rewrite names the key the units are filed under. A recorded path maps to itself (absent).
    var recordedPath: [String: String] = [:]
    /// SOUNDNESS R1938 lane L4 — the supertype walk's facts (nil under `CANDOR_TYPE_ID_L4_OFF`: the release-of-L3 refusals stand).
    var l4: L4WalkFactsR1938? = nil

    static func ownModuleStripper(ownModules: Set<String>) -> (String) -> String? {
        return { p in
            guard let dot = p.firstIndex(of: ".") else { return nil }
            guard ownModules.contains(String(p[..<dot])) else { return nil }
            return String(p[p.index(after: dot)...])
        }
    }

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
    /// `only` (lane L2) restricts the decision to the names the unit's body spells: L2's candidates are every declared simple
    /// name, and deciding all of them per unit would be units x names.
    func names(file: String, enclosingPath: String?, generics: Set<String>, bodyDecls: Set<String>, only: Set<String>? = nil) -> (ok: Set<String>, refused: [String: String]) {
        // an enclosing path spelled with an own module (`extension Own13.Outer13 { … }`) is decided under BOTH spellings, the
        // recorded one and the stripped one: a name is read "as if undeclared" only if neither refuses (Fable recheck B2 — adding a
        // spelling can only add a refusal)
        let r = decide(file: file, enclosingPath: enclosingPath, generics: generics, bodyDecls: bodyDecls, only: only)
        return (r.ok, r.refused)
    }
    /// `names` plus, per refused name, the INNERMOST enclosing member type Swift binds it to (SOUNDNESS R1950), as the path the
    /// scan RECORDED it under. Present only where the refusal is `visible-nested`, the hit is a nested TYPE (not a member alias),
    /// no supertype of any enclosing type contributes a member of that name, and both spellings of an own-module-qualified
    /// enclosing path agree.
    func decide(file: String, enclosingPath: String?, generics: Set<String>, bodyDecls: Set<String>, only: Set<String>? = nil)
        -> (ok: Set<String>, refused: [String: String], innermost: [String: String]) {
        let cands = only.map { candidates.intersection($0) } ?? candidates
        let a = namesFor(file: file, enclosingPath: enclosingPath, generics: generics, bodyDecls: bodyDecls, cands: cands)
        guard let ep = enclosingPath, let stripped = stripOwnModule(ep) else { return a }
        let b = namesFor(file: file, enclosingPath: stripped, generics: generics, bodyDecls: bodyDecls, cands: cands)
        var inner: [String: String] = [:]
        for (n, p) in a.innermost where b.innermost[n] == p { inner[n] = p }
        return (a.ok.intersection(b.ok), a.refused.merging(b.refused) { x, _ in x }, inner)
    }
    private func namesFor(file: String, enclosingPath: String?, generics: Set<String>, bodyDecls: Set<String>, cands candidates: Set<String>)
        -> (ok: Set<String>, refused: [String: String], innermost: [String: String]) {
        var ok: Set<String> = [], refused: [String: String] = [:], innermost: [String: String] = [:]
        guard !candidates.isEmpty else { return (ok, refused, innermost) }
        guard let module = idx.moduleOf(file) else {
            for n in candidates { refused[n] = "no-module" }
            return (ok, refused, innermost)
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
            // SOUNDNESS R1938 lane L4 — Swift's member-type lookup replaces the three refusals below (visible nested, enclosing
            // associated type, a contributing supertype): innermost enclosing type first, its OWN members, then its supertypes'
            // nearest first, then the next enclosing type out. A nested type or a member alias onto a scan type found that way is the
            // binding (`innermost`, path-keyed); an associated type, an unknown supertype or a tie keeps main's reading.
            if let w = l4 {
                switch l4Walk(n, prefixes: prefixes, facts: w, file: file) {
                case .some(.nested(let p, let via)):
                    refused[n] = "\(via):\(p)"
                    innermost[n] = recordedPath[p] ?? p
                    continue
                case .some(.refuse(let why)):
                    refused[n] = why
                    continue
                case .some(.foreignNested):
                    // a DEPENDENCY supertype whose readable sources nest N: N is that dependency's type here
                    ok.insert(n)
                    continue
                case .none:
                    break
                }
                let tops = topLevelModules[n] ?? []
                if tops.contains(module) { refused[n] = "own-module-top-level"; continue }
                if !tops.isDisjoint(with: visible) { refused[n] = "visible-module-top-level"; continue }
                if privateAliasFiles[n]?.contains(file) == true { refused[n] = "file-alias"; continue }
                ok.insert(n)
                continue
            }
            if let p = prefixes.first(where: { localTypePaths.contains($0 + "." + n) || memberAliasNamesByPath[$0]?.contains(n) == true }) {
                refused[n] = "visible-nested:\(p).\(n)"
                // R1950 — Swift binds the INNERMOST enclosing member type (a nested type of `Outer.Mid` before one of `Outer`), not
                // the package-wide simple key. Only a nested TYPE answers (a member alias keeps main's reading), and only when no
                // supertype of an enclosing type could contribute a member of the name (L4 owns that walk).
                if let q = prefixes.reversed().first(where: { localTypePaths.contains($0 + "." + n) || memberAliasNamesByPath[$0]?.contains(n) == true }),
                   memberAliasNamesByPath[q]?.contains(n) != true,
                   !supers.contains(where: { sup0 in
                       let sup = unqualifiedPlatform(sup0)
                       if isScanDeclared(sup) { return supertypeContributes(sup, n) || protocolAssoc(sup, n) }
                       if let st = stripOwnModule(sup0), isScanDeclared(st) { return supertypeContributes(st, n) || protocolAssoc(st, n) }
                       return STDLIB_NOMINALS.contains(sup + "." + n) || !(STDLIB_PROTOCOLS.contains(sup) || PLATFORM_LEAVES.contains(sup) || STDLIB_NOMINALS.contains(sup))
                   }) {
                    innermost[n] = recordedPath[q + "." + n] ?? (q + "." + n)
                }
                continue
            }
            if let p = prefixes.first(where: { protocolPaths.contains($0) && protocolAssoc($0, n) }) { refused[n] = "assoc:\(p).\(n)"; continue }
            // a supertype spelled with an own module refuses if EITHER spelling refuses (recheck B2: the strip only adds)
            func supRefuses(_ sup: String) -> Bool {
                if isScanDeclared(sup) { return supertypeContributes(sup, n) || protocolAssoc(sup, n) }
                if STDLIB_PROTOCOLS.contains(sup) || PLATFORM_LEAVES.contains(sup) || STDLIB_NOMINALS.contains(sup) {
                    return LS_STDLIB_ASSOC_COLLISIONS_R1938.contains(n) || STDLIB_NOMINALS.contains(sup + "." + n)
                }
                return true
            }
            if let s = supers.sorted().first(where: { sup0 in
                supRefuses(unqualifiedPlatform(sup0)) || (stripOwnModule(sup0).map(supRefuses) ?? false)
            }) {
                refused[n] = "supertype:\(s)"; continue
            }
            let tops = topLevelModules[n] ?? []
            if tops.contains(module) { refused[n] = "own-module-top-level"; continue }
            if !tops.isDisjoint(with: visible) { refused[n] = "visible-module-top-level"; continue }
            if privateAliasFiles[n]?.contains(file) == true { refused[n] = "file-alias"; continue }
            ok.insert(n)
        }
        return (ok, refused, innermost)
    }
}

// SOUNDNESS R1938 (type-identity lane L4) — THE SUPERTYPE WALK.
//
// LS/L2 refused every name a supertype of an enclosing type might contribute ("L4 owns that walk"), and the refusal kept main's
// reading: the package-wide simple key. That key is not a Swift rule. A bare `Cfg` inside `class Sub: Mid` (Mid: Base, Base nests
// `Cfg`) beside a top-level `Cfg` of the same module bound the TOP-LEVEL type (fx26 `Sub26.a_grand`: ABSENT over an executed
// write; the mirror `a_grand_mirror` charged the top level's loud member to code that runs the nested pure one); a member alias a
// superclass or a protocol extension declares lost to a same-named top-level type (`b_super_alias`, `b_proto_alias`); and an
// enclosing type's own member alias lost the same way (`b_own_alias`, fx10 `M10.assoc_witness`). Where no top-level twin existed the
// package-wide key happened to land on the one nested type with that leaf (the "unique leaf" fallback, DESIGN §0 point 2): fx7
// `Sub.inh_nested` read right by accident, `Sub2.inh_shared` read the union of `Base2.Knob` and an unrelated `Other.Knob`.
//
// THE RULE (DESIGN §2.3 (a)). For each enclosing type path, innermost first: the type's OWN member types and member aliases (an
// associated type if it is a protocol), then those of its supertypes, NEAREST FIRST (breadth-first over the direct supertypes; a
// protocol's refinements are its supertypes); the first level that answers decides. Then the next enclosing type out. Answers:
//   · a nested type `S.N` -> `nested` (the binding is that path, through R1950's `innermost` channel);
//   · a member alias `S.N = T` whose target is a scan type -> `nested` at the target's path (the alias resolved in its owner's
//     scope: the owner's enclosing path outward, then a declared path);
//   · an associated type, a member alias onto a non-scan type, two different answers at one level, a supertype whose members the
//     engine cannot know (a dependency's class or protocol, a platform type outside the generated tables) -> `refuse` (main's
//     reading, as LS/L2 refused);
//   · a DEPENDENCY supertype whose readable sources nest `N` -> `foreignNested`: N is that dependency's type, read "as if
//     undeclared" (the scan's same-named type is not this spelling's).
// A platform supertype the generated tables or the platform-class list know (`NSObject`, `Error`, the stdlib protocols) contributes
// only the member types the generated table lists for it (`STDLIB_NOMINALS` `T.N`) or a scan extension of it declares; the walk
// does not continue past it (its own supertypes are platform types too). SOUNDNESS R1948: `class Sp12: NSObject` no longer refuses
// a bare `Data`. Kill switch `CANDOR_TYPE_ID_L4_OFF` (the facts are not built; every refusal is L2's).
struct L4WalkFactsR1938 {
    /// type path (as recorded and own-module-stripped) -> its DIRECT supertype spellings (generic arguments dropped)
    let directSupers: [String: [String]]
    /// type path -> member alias -> its target spellings (more than one: the alias is conditional or redeclared)
    let aliasTargetsByPath: [String: [String: Set<String>]]
    /// simple owner name -> member alias -> target spellings (a protocol extension's alias is keyed by the protocol's simple name)
    let aliasTargetsBySimple: [String: [String: Set<String>]]
    /// (file, a dependency supertype spelling, N): the dependency's readable sources nest a type N in that type. nil = not known.
    let dependencyNests: (String, String, String) -> Bool?
}

enum L4WalkHitR1938: Equatable {
    case nested(String, via: String)
    case refuse(String)
    case foreignNested(String)
}

/// A type spelling with every generic argument clause removed, keeping any member after it (`P<A, B>.Source` -> `P.Source`).
func l4StripGenericsR1938(_ s: String) -> String {
    guard s.contains("<") else { return s }
    var out = "", depth = 0
    for ch in s {
        if ch == "<" { depth += 1; continue }
        if ch == ">" { depth = max(0, depth - 1); continue }
        if depth == 0 { out.append(ch) }
    }
    return out.replacingOccurrences(of: " ", with: "")
}

/// Platform supertypes the walk may cross: their member types are the generated table's, and a package-declared name is not one.
let L4_PLATFORM_SUPERS_R1938: Set<String> = STD_SUPERS_PUBLIC.union(PLATFORM_REFINES.keys).union(PLATFORM_LEAVES)
    .union(STDLIB_PROTOCOLS.filter { !$0.contains(".") })

extension LsShadowIndexR1938 {
    /// A supertype spelling written in the declaration of `sub` -> the scan paths it names (Swift resolves an inheritance clause
    /// from the subtype's own enclosing scope outward, then the module level): `sub`'s enclosing prefixes outward, then the
    /// declared path itself, then a unique leaf (a nested base spelled bare from a sibling file's scope). Empty: not a scan type.
    func l4SuperPaths(_ spelled: String, of sub: String) -> [String] {
        let s = stripOwnModule(spelled) ?? spelled
        var segs = sub.split(separator: ".").map(String.init)
        segs.removeLast()
        while !segs.isEmpty {
            let c = segs.joined(separator: ".") + "." + s
            if declaredTypePaths.contains(c) || protocolPaths.contains(c) { return [c] }
            segs.removeLast()
        }
        if declaredTypePaths.contains(s) || protocolPaths.contains(s) { return [s] }
        let leaf = s.split(separator: ".").last.map(String.init) ?? s
        if !s.contains("."), let ps = pathsByLeaf[leaf], ps.count == 1, let p = ps.first { return [p] }
        // a protocol is not in `declaredTypePaths`'s leaf index when it is only declared (protocolPaths holds its path)
        let protos = protocolPaths.filter { $0 == s || $0.hasSuffix("." + s) }
        return protos.count == 1 ? [protos.first!] : (pathsByLeaf[leaf].map { Array($0).sorted() } ?? [])
    }

    /// A member alias `N` declared on scan type `p` -> the scan path its target names (resolved from the owner's scope), or a
    /// refusal reason.
    private func l4AliasTarget(_ targets: Set<String>, owner p: String) -> Result<String, L4Refusal> {
        guard targets.count == 1, var t = targets.first else { return .failure(L4Refusal("alias-ambiguous:\(p)")) }
        t = l4StripGenericsR1938(t)
        t = stripOwnModule(t) ?? t
        var segs = p.split(separator: ".").map(String.init)
        while !segs.isEmpty {
            let c = segs.joined(separator: ".") + "." + t
            if localTypePaths.contains(c) { return .success(c) }
            segs.removeLast()
        }
        if declaredTypePaths.contains(t) { return .success(t) }
        return .failure(L4Refusal("alias-nonscan:\(p)"))
    }
    struct L4Refusal: Error { let why: String; init(_ w: String) { why = w } }

    /// What scan type path `p` contributes as a member named `n`, ignoring its supertypes.
    private func l4Own(_ p: String, _ n: String, _ w: L4WalkFactsR1938, via: String) -> L4WalkHitR1938? {
        if localTypePaths.contains(p + "." + n) { return .nested(p + "." + n, via: via) }
        let leaf = p.split(separator: ".").last.map(String.init) ?? p
        if let ts = w.aliasTargetsByPath[p]?[n] ?? (p.contains(".") ? nil : w.aliasTargetsBySimple[leaf]?[n]) {
            switch l4AliasTarget(ts, owner: p) {
            case .success(let t): return .nested(t, via: via + "-alias")
            case .failure(let e): return .refuse(e.why)
            }
        }
        // a protocol's extension alias is keyed by the protocol's simple name
        if protocolPaths.contains(p), let ts = w.aliasTargetsBySimple[leaf]?[n] {
            switch l4AliasTarget(ts, owner: p) {
            case .success(let t): return .nested(t, via: via + "-alias")
            case .failure(let e): return .refuse(e.why)
            }
        }
        if protocolPaths.contains(p) && protocolAssoc(p, n) { return .refuse("assoc:\(p).\(n)") }
        return nil
    }

    /// DESIGN §2.3 (a), the walk itself (see `L4WalkFactsR1938`).
    func l4Walk(_ n: String, prefixes: [String], facts w: L4WalkFactsR1938, file: String) -> L4WalkHitR1938? {
        for q in prefixes.reversed() {
            if let own = l4Own(q, n, w, via: "member-type") { return own }
            // breadth-first over q's supertypes; a level that answers decides
            var level: [(spelled: String, sub: String)] = (w.directSupers[q] ?? []).map { ($0, q) }
            if level.isEmpty, let leaf = q.split(separator: ".").last.map(String.init), protocolPaths.contains(q) {
                level = (protocolSupers[q] ?? protocolSupers[leaf] ?? []).sorted().map { ($0, q) }
            }
            var seen: Set<String> = [q]
            var depth = 0
            while !level.isEmpty, depth < 32 {
                depth += 1
                var hits: [L4WalkHitR1938] = []
                var next: [(spelled: String, sub: String)] = []
                for (sp0, sub) in level {
                    let sp = unqualifiedPlatformL4(sp0)
                    let paths = l4SuperPaths(sp0, of: sub)
                    if !paths.isEmpty {
                        var answers: [L4WalkHitR1938] = []
                        for p in paths where seen.insert(p).inserted {
                            if let h = l4Own(p, n, w, via: "inherited") { answers.append(h); continue }
                            next.append(contentsOf: (w.directSupers[p] ?? []).map { ($0, p) })
                            let leaf = p.split(separator: ".").last.map(String.init) ?? p
                            if protocolPaths.contains(p) { next.append(contentsOf: (protocolSupers[p] ?? protocolSupers[leaf] ?? []).sorted().map { ($0, p) }) }
                        }
                        if paths.count > 1, !answers.isEmpty { hits.append(.refuse("supertype-ambiguous:\(sp0)")) } else { hits.append(contentsOf: answers) }
                        continue
                    }
                    // not a scan type: a scan EXTENSION of it may still nest N or alias it
                    if localTypePaths.contains(sp + "." + n) { hits.append(.nested(sp + "." + n, via: "extension-of-supertype")); continue }
                    if let ts = w.aliasTargetsBySimple[sp]?[n] {
                        switch l4AliasTarget(ts, owner: sp) {
                        case .success(let t): hits.append(.nested(t, via: "inherited-alias"))
                        case .failure(let e): hits.append(.refuse(e.why))
                        }
                        continue
                    }
                    if L4_PLATFORM_SUPERS_R1938.contains(sp) || STDLIB_NOMINALS.contains(sp) {
                        if STDLIB_NOMINALS.contains(sp + "." + n) { hits.append(.refuse("platform-nested:\(sp).\(n)")) }
                        else if LS_STDLIB_ASSOC_COLLISIONS_R1938.contains(n) { hits.append(.refuse("platform-assoc:\(sp).\(n)")) }
                        continue
                    }
                    // a dependency's (or an unknown platform module's) type: its member types are not the scan's to know
                    switch w.dependencyNests(file, sp0, n) {
                    case .some(true): hits.append(.foreignNested("dependency-nested:\(sp0).\(n)"))
                    default: hits.append(.refuse("supertype:\(sp0)"))
                    }
                }
                if !hits.isEmpty {
                    let distinct = Set(hits.map { h -> String in
                        switch h { case .nested(let p, _): return "n:" + p; case .refuse(let r): return "r:" + r; case .foreignNested: return "f" }
                    })
                    if distinct.count == 1 { return hits[0] }
                    // two different answers at one level: refuse (Swift reports an ambiguity or picks by rules this walk does not model)
                    if let r = hits.first(where: { if case .refuse = $0 { return true }; return false }) { return r }
                    return .refuse("supertype-ambiguous:\(n)")
                }
                level = next
            }
        }
        return nil
    }
    private func unqualifiedPlatformL4(_ s: String) -> String {
        for m in ["Swift.", "Foundation.", "_Concurrency.", "Dispatch.", "ObjectiveC."] where s.hasPrefix(m) { return String(s.dropFirst(m.count)) }
        return s
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

// SOUNDNESS R1938 (type-identity lane L2) — THE USE-UNIT GUARD, beside LS.
//
// LS reads a PLATFORM name "as if undeclared" where Swift cannot see the scan's same-named type from the unit. L2 applies the same
// per-unit rule (`LsShadowIndexR1938.decide`, the same refusals) to every OTHER name the scan declares: a bare `Lib` that a
// sibling target Feature does not import declares, or a `Vault` the scan declares only nested in an unrelated type, names a
// DEPENDENCY's type in that unit (fx4: 26 executed-WRITES cells ABSENT on 0.43.0 and main; the mirror `Kit` charged the scan's
// loud member to code that runs the dependency's pure one). It also owns three spellings LS does not touch:
//   · `M.N` with `M` an IMPORTED module the scan does not own (`Guess.Lib`, `Foundation.Data` — SOUNDNESS R1947): the type is
//     M's, whatever the scan declares, so N reads "as if undeclared" in that node only;
//   · a module-level typealias `A = N` whose target N is read "as if undeclared" from the ALIAS's own file (fx4 `DepLib`): the
//     use spelling `A` reads as N does there;
//   · SOUNDNESS R1950: inside an enclosing type that nests N, bare N is the INNERMOST nested type, not the package-wide simple
//     key (fx12 `Outer12.inner_nested` bound Core12's top-level `Data`; fx9r bound the union `Outer9.Data` + `Base9.Data`).
// The scope is LS's: only spellings WRITTEN in the unit (local annotation, local constructor, inline constructor head, `N.init`,
// `as!`, and a receiver bound by one of those). Fields, globals, returns and closure parameters typed from a callee are L3's: their
// spelling's scope is a declaration elsewhere (fx7 `H.b3r`). Kill switch `CANDOR_TYPE_ID_L2_OFF`.
struct L2UnitFactsR1938 {
    /// non-platform names this unit's in-scope spellings read "as if undeclared"
    var names: Set<String> = []
    /// a module-level alias spelled in this unit -> the target name it reads as (decided in the alias's file)
    var aliases: [String: String] = [:]
    /// R1950: bare name -> the innermost enclosing member type's recorded path
    var innermost: [String: String] = [:]
    /// `M.N` with M an imported non-own module reads N "as if undeclared"
    var qualified = false
    /// the scan's own modules (manifest/Xcode targets): `Own.N` is the scan's own type, never "as if undeclared" (measured on
    /// SourceKitten: `SourceKittenFramework.Structure(file:)` lost its edge before this)
    var ownModules: Set<String> = []
    var isEmpty: Bool { names.isEmpty && aliases.isEmpty && innermost.isEmpty && !qualified }
}

/// Every BARE type-shaped identifier a unit's body spells (a type position, or an uppercase reference in an expression): the names
/// L2 decides for the unit. A member name (`Outer.Inner`'s `Inner`) is not a bare spelling and is not decided. Over-inclusive on
/// purpose otherwise (a value named `Lib` is still filtered at the binder).
func l2SpelledNamesR1938(_ body: Syntax?) -> Set<String> {
    guard let body else { return [] }
    final class V: SyntaxVisitor {
        var out: Set<String> = []
        override func visit(_ n: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind { out.insert(n.name.text); return .visitChildren }
        override func visit(_ n: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            // a MEMBER position (`Resp19.Status19.isValid`: `Status19`, `isValid`) is not a bare spelling (Fable's merge review B1)
            if let ma = n.parent?.as(MemberAccessExprSyntax.self), ma.declName.id == n.id { return .visitChildren }
            if n.baseName.text.first?.isUppercase == true { out.insert(n.baseName.text) }
            return .visitChildren
        }
    }
    let v = V(viewMode: .sourceAccurate)
    v.walk(body)
    return v.out
}

// SOUNDNESS R1938 (type-identity lane L3) — IDENTITY RECORDED AT THE DECLARATION.
//
// L2 decided a spelling in the unit that WROTE it. A field, a global and a declared return are spelled in a declaration
// elsewhere — the declaring type's file and type path, the declaring file, the declaring function's scope (DESIGN §0 point 1,
// Fable's fx7 `H.b3r`) — and every unit that reaches the value through it reads the type the DECLARATION names. So the Driver
// decides each such spelling ONCE, in its own scope, with the same per-scope rule (`LsShadowIndexR1938.decide`), and hands the
// answer to every collector as a fact keyed by the binder:
//   · `ctx` — `\u{1}N` when the declaration's scope reads a scan-declared name N "as if undeclared" (fx4 `var f: Lib` in a file
//     that imports Guess and not Core; `Guess.Ledger()` beside the scan's own `Ledger`). `\u{1}` because the USE unit's own
//     innermost-nested rewrite (R1950) is not this spelling's scope. Empty when the declaration names a type the scan does not
//     declare at all: nothing is shadowed, only the declaring file matters;
//   · `file` — the declaring file. A use unit in another file (B3: `extension Holder` in a file with no `import Guess`, legal in
//     Swift 5 because member visibility is module-wide) resolves the receiver's MODULE where the declaration resolved it: the
//     Driver evaluates the call's dependency route (join key, `invisible`, `identity:foreign`) in the declaring file, not in the
//     use file (L3: when the use file imported nothing the declaring file did not; R1981 lane B3: always, see `FileImportsR1981`);
//   · `spelled` — the type string the merged tables hold for the binder: the fact applies only while the use unit's table still
//     holds exactly that (an overlay that retyped the field — R1481, R1513 — keeps its own reading).
// Kill switch `CANDOR_TYPE_ID_L3_OFF` (no facts are built; every reading is L2's).
struct L3BindR1938: Equatable {
    let ctx: String
    let file: String
    let spelled: String
    /// The stored context string (`\u{1}N\u{3}file`, or `\u{3}file`).
    var raw: String { ctx + "\u{3}" + file }
}
struct L3DeclFactsR1938 {
    /// owner key (simple name and full path, as `fields` keys them) -> field -> the binder's identity
    var fields: [String: [String: L3BindR1938]] = [:]
    /// global name -> its identity (module-wide: a global is visible in every file of its module)
    var globals: [String: L3BindR1938] = [:]
    /// function or method LEAF -> its declared return's identity (the key `returns` uses)
    var returns: [String: L3BindR1938] = [:]
    /// a declaring file -> its imports (a qualified spelling `Guess.Lib` is read with the DECLARING file's modules)
    var importsByFile: [String: Set<String>] = [:]
    var isEmpty: Bool { fields.isEmpty && globals.isEmpty && returns.isEmpty && importsByFile.isEmpty }   // (T4 contexts register their files)
}

// SOUNDNESS R1981 (type-identity lane B3) — THE IMPORT SET A DECLARED VALUE'S CALL IS ROUTED THROUGH.
//
// L3 evaluated a call on a value bound through a declaration (a field, a global, a declared return, a callee-typed closure
// parameter) in the DECLARING file only when the use file imported nothing the declaring file did not; otherwise the use file's own
// imports re-resolved the value's type. A use file importing a dependency that declares a same-named twin then routed the member to
// the twin (fx23 `UB23.field_kit`: a pure DepA member charged with DepB's write), and one importing an own module with a twin bound
// the scan's type (fx23 `UC23.field_lib`: ABSENT over a write). The value's type is a fact of its declaration, so the call is now
// ALWAYS evaluated in the declaring file. The use site contributes only what Swift lets it contribute: EXTENSION members, visible
// target-wide (Swift 5/6 language modes; the use file alone under `MemberImportVisibility`, SE-0444). Those modules are added to the
// declaring file's imports for that one call (`overlay`), and only modules that cannot be the receiver's type: a module that declares
// a top-level type of the receiver's name (readable sources, or a chained report's published types) is the twin and is never added.
//
// `fileImports` is read through this wrapper so the overlay reaches every route question the call asks (join packages, the
// `invisible` ledger, obligation 1's owner, the C12 evidence) without threading a parameter through each; `store` is the merged
// table, read directly by the questions that are about the DECLARATION's spelling (aliases, generics), not the route.
// Kill switch `CANDOR_TYPE_ID_B3_OFF` (L3's import-subset rule; also off under `CANDOR_TYPE_ID_L3_OFF`).
struct FileImportsR1981 {
    var store: [String: [String]] = [:]
    /// (declaring file, the imports the current call is routed through); nil outside a B3 call
    var overlay: (file: String, imports: [String])? = nil
    subscript(_ f: String) -> [String]? {
        get { if let o = overlay, o.file == f { return o.imports }; return store[f] }
        set { store[f] = newValue }
    }
    /// A cache keyed by a file whose answer reads the imports must not serve (or keep) an overlaid answer under the plain key.
    func cacheTag(_ f: String) -> String {
        guard let o = overlay, o.file == f else { return "" }
        return "\u{5}" + o.imports.joined(separator: ",")
    }
}
