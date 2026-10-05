import Foundation
import SwiftSyntax
import CandorCore

// ════════════════════════════════════════════════════════════════════════════════════════════════
// ⟨0.40⟩ DECLARED TYPES AND THE DEPENDENCY'S OWN HIERARCHY — `typeSurface.holds`, `returnsProtocol`,
// `types` and `adds`, FOR RESOLUTION ONLY (candor-spec SPEC §2 ⟨0.40⟩; SOUNDNESS R843; conformance
// PART 95, `gen_type_surface.py`).
//
// THE PRODUCER half publishes four keys beside ⟨0.23⟩'s `returns`; THE CONSUMER half (the index below,
// read by `Driver.analyze`'s call loop) uses them to ADD a resolution and never to remove one:
//
//   * a hit ADDS the declared target's join and the guess the consumer already made is KEPT beside it;
//   * a walk reads an absent `<T>.<member>` as "may be inherited" and continues through `supers` (and
//     every `adds` a chained report records for `T`); a path through a type with no key, or with a
//     KIND-ONLY key, is a MISS — never "complete, no supertypes" (the `?? []` mutant PART 95 o14/c7b
//     exist to catch);
//   * an unknown kind is open: joined, unioned with ⟨0.39⟩'s route, and hedged;
//   * two trusted copies UNION their `holds`/`returnsProtocol`/`adds`, and read a `types` key they do
//     not agree on as ABSENT; a stale, judged-nothing or malformed copy contributes a MISS;
//   * every lookup on a GUESSED owner that no trusted surface answers keeps the guess and ADDS `Unknown`.
//
// Nothing here withdraws a disclosure the release made. SPEC §2 ⟨0.40⟩ PERMITS withdrawing an untyped-hop
// `Unknown` where every walk path hits; this engine does not take that permission — every row this rung
// changes gains effects or `Unknown` and loses neither (the measured A/B is in the CHANGELOG).
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// The five kinds SPEC §2 ⟨0.40⟩ defines. Anything else (`actor`, a typo, a future kind) is an UNKNOWN
/// kind — never an exact one.
let TYPE_SURFACE_KINDS: Set<String> = ["protocol", "final", "class", "open", "value"]

/// One `types` key as the wire carries it. `supers == nil` is a KIND-ONLY key: the producer knows the
/// kind but could not close the supertypes. It is NOT an empty list, and nothing in this file may ever
/// read it as one — that is the whole of PART 95 `o14_kind_only`.
struct DeclaredTypeInfo: Equatable {
    var kind: String
    var supers: [String]?
    static func == (a: DeclaredTypeInfo, b: DeclaredTypeInfo) -> Bool {
        a.kind == b.kind && a.supers.map(Set.init) == b.supers.map(Set.init)
    }
}

/// The consumer's view of every chained ⟨0.40⟩ surface.
struct TypeSurfaceIndex {
    /// `<pkg>#<owner>.<member>` -> declared targets, UNIONED across trusted copies (c6_disagree).
    var holds: [String: Set<String>] = [:]
    var returnsProtocol: [String: Set<String>] = [:]
    /// `<owner pkg>#<foreign type>` -> supertypes some chained package adds. Never complete.
    var adds: [String: Set<String>] = [:]
    /// The MERGED manifest: a key is here only if every trusted copy of its package carries it, with the
    /// same kind and the same `supers` (or every copy carries it kind-only).
    var types: [String: DeclaredTypeInfo] = [:]
    /// Every `types` key ANY trusted copy carried, merged or not — the existence question "does a chained
    /// report speak about this type at all", read only to decide whether a guessed owner is a dependency's
    /// type (and so whether its lookup is the miss rule's business). Never consulted to join.
    var typeKeysSeen: Set<String> = []
    /// Packages one of whose copies is stale (§2.1), judged nothing (⟨0.24⟩) or carries a malformed surface:
    /// any hop into them is a MISS, whatever a trusted copy resolves beside it (o9_stale_beside).
    var distrustedPkgs: Set<String> = []
    /// VEIN D — packages with at least one TRUSTED copy that publishes a readable `types` manifest. Only
    /// such a package's SILENCE about a type name is evidence that it does not declare it; an older
    /// producer, a judged-nothing copy or a malformed one says nothing either way.
    var typesPublishedPkgs: Set<String> = []
    /// per report package: one element per TRUSTED copy. `nil` = the copy publishes no readable `types`
    /// (an older producer, `types` not in `resolves`, or not an object); an inner `nil` = that key is
    /// malformed in that copy (read as absent, never as `[]` and never as `final`).
    fileprivate var typeCopies: [String: [[String: DeclaredTypeInfo?]?]] = [:]

    enum State { case unkeyed, kindOnly(String), full(String, [String]) }

    func state(_ key: String) -> State {
        guard let t = types[key] else { return .unkeyed }
        if let s = t.supers { return .full(t.kind, s) }
        return .kindOnly(t.kind)
    }
    /// The kind, only when it is one of the five; `nil` is an UNKNOWN kind.
    func knownKind(_ key: String) -> String? {
        guard let k = types[key]?.kind, TYPE_SURFACE_KINDS.contains(k) else { return nil }
        return k
    }

    /// Read one report's ⟨0.40⟩ keys. `trusted` is false for a stale or judged-nothing report: its surface
    /// is no more trusted than its entries, so it contributes nothing but a MISS for its package.
    mutating func ingest(_ obj: [String: Any]?, package pkg: String?, trusted: Bool) {
        guard let obj else { return }
        let ts = obj["typeSurface"] as? [String: Any]
        let resolves = Set((obj["resolves"] as? [Any] ?? []).compactMap { $0 as? String })
        guard trusted else {
            if let pkg, !pkg.isEmpty { distrustedPkgs.insert(pkg) }
            return
        }
        var malformed = false
        func stringMap(_ k: String) -> [String: String] {
            guard resolves.contains(k), let raw = ts?[k] else { return [:] }
            guard let m = raw as? [String: Any] else { malformed = true; return [:] }
            var out: [String: String] = [:]
            for (key, v) in m {
                guard let s = v as? String, key.contains("#"), s.contains("#") else { malformed = true; continue }
                out[key] = s
            }
            return out
        }
        for (k, v) in stringMap("holds") { holds[k, default: []].insert(v) }
        for (k, v) in stringMap("returnsProtocol") { returnsProtocol[k, default: []].insert(v) }
        if resolves.contains("adds"), let raw = ts?["adds"] {
            if let m = raw as? [String: Any] {
                for (k, v) in m {
                    guard let arr = v as? [Any] else { malformed = true; continue }
                    for s in arr { if let s = s as? String, s.contains("#") { adds[k, default: []].insert(s) } }
                }
            } else { malformed = true }
        }
        var copy: [String: DeclaredTypeInfo?]? = nil
        if resolves.contains("types"), let raw = ts?["types"] {
            if let m = raw as? [String: Any] {
                var c: [String: DeclaredTypeInfo?] = [:]
                for (k, v) in m {
                    typeKeysSeen.insert(k)
                    guard let e = v as? [String: Any], let kind = e["kind"] as? String else { c[k] = .some(nil); continue }
                    if let rs = e["supers"] {
                        // A PRESENT `supers` that is not a list of strings is MALFORMED — absent for this key,
                        // never an empty list.
                        guard let arr = rs as? [Any] else { c[k] = .some(nil); continue }
                        let ss = arr.compactMap { $0 as? String }
                        guard ss.count == arr.count else { c[k] = .some(nil); continue }
                        c[k] = DeclaredTypeInfo(kind: kind, supers: ss)
                    } else {
                        c[k] = DeclaredTypeInfo(kind: kind, supers: nil)   // KIND-ONLY: not `[]`
                    }
                }
                copy = c
            } else { malformed = true }
        }
        if let pkg, !pkg.isEmpty {
            typeCopies[pkg, default: []].append(copy)
            if copy != nil { typesPublishedPkgs.insert(pkg) }
            if malformed { distrustedPkgs.insert(pkg) }
        }
    }

    /// Merge the per-copy `types` tables. A key every copy of its package carries identically is kept;
    /// anything else — a different kind, a different `supers`, present in one copy and absent in another,
    /// FULL in one and KIND-ONLY in the other, malformed anywhere — is read as ABSENT (SPEC §2 ⟨0.40⟩ "two
    /// copies union; a distrusted copy is a miss"; PART 95 c7, c7b). Taking `supers` from whichever copy
    /// closes the type would rebuild the short closure the manifest rule exists to forbid.
    mutating func finalize() {
        for (_, copies) in typeCopies {
            var keys = Set<String>()
            for c in copies { if let c { keys.formUnion(c.keys) } }
            for k in keys {
                var agreed: DeclaredTypeInfo? = nil
                var ok = true
                for c in copies {
                    guard let c, let present = c[k], let v = present else { ok = false; break }
                    if let a = agreed { if a != v { ok = false; break } } else { agreed = v }
                }
                if ok, let v = agreed { types[k] = v }
            }
        }
        typeCopies = [:]
    }

    var isEmpty: Bool { holds.isEmpty && returnsProtocol.isEmpty && adds.isEmpty && types.isEmpty }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// THE PRODUCER — a separate, self-contained walk over each parsed file. It reads only declarations, so
// nothing it does can change an effect: its output is four wire keys and nothing else.
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// Attributes the COMPILER defines. Any other attribute on a type or extension declaration may be an
/// attached macro — including an `@attached(extension, conformances: …)` one declared in another package,
/// whose conformance list this producer cannot see — so the type's `supers` cannot be closed (SPEC §2
/// ⟨0.40⟩, PART 95 w1_macro). THE LIST IS THE SAFE DIRECTION: an attribute it does not know withholds
/// `supers` (a miss downstream), never publishes a short list (a silence downstream). A custom global
/// actor (`@MyActor`) is withheld for that reason too — it is indistinguishable from a macro by spelling.
let COMPILER_TYPE_ATTRIBUTES: Set<String> = [
    "available", "objc", "objcMembers", "nonobjc", "frozen", "usableFromInline", "inlinable",
    "propertyWrapper", "resultBuilder", "dynamicMemberLookup", "dynamicCallable", "globalActor", "main",
    "UIApplicationMain", "NSApplicationMain", "testable", "_spi", "_spi_available", "preconcurrency",
    "unchecked", "retroactive", "IBDesignable", "requires_stored_property_inits", "_fixed_layout",
    "_alwaysEmitIntoClient", "_marker", "_implementationOnly", "MainActor", "Sendable",
    "warn_unqualified_access", "_documentation", "_originallyDefinedIn", "backDeployed", "_nonSendable",
    "_eagerMove", "_moveOnly", "_unavailableFromAsync", "discardableResult", "_disfavoredOverload",
    "_typeEraser", "_functionBuilder", "_hasMissingDesignatedInitializers",
    "_inheritsConvenienceInitializers", "_borrowed", "_exported", "_silgen_name", "_cdecl",
    "_objcRuntimeName", "_staticInitializeObjCMetadata", "objc_non_lazy_realization", "_nonoverride",
    "_semantics", "_effects", "_optimize", "_specialize", "_transparent", "_spiOnly",
    "_restatedObjCConformance", "_show_in_interface", "_weakLinked", "_alignment", "_rawLayout",
    "_noMetadata", "_addressableSelf", "_addressableForDependencies", "_allowFeatureSuppression",
    "_unsafeNonescapableResult", "_nonEphemeral", "_staticExclusiveOnly", "_extern",
]

/// The one named marker Swift has (SPEC §2 ⟨0.40⟩ "Exactly ONE protocol" ignores it and nothing else).
private let MARKER_PROTOCOLS: Set<String> = ["Sendable"]

/// A declared value's type, classified for `holds`. `.nominal` is a plain nominal spelling (which may name
/// a protocol — a bare existential); `.oneProtocol` is `any P` / `some P` / `any P & Sendable`.
enum SurfaceValueType: Equatable { case nominal(String), oneProtocol(String) }

/// `any P`, `some P`, `any P & Sendable`, `(any P)` -> `P`'s spelling. A composition of two protocols, an
/// optional, a wrapper, a generic argument list -> nil (a wrapper is still a wrapper).
func oneProtocolSpelling(_ t: TypeSyntax) -> String? {
    if let tup = t.as(TupleTypeSyntax.self), tup.elements.count == 1, let only = tup.elements.first,
       only.firstName == nil {
        return oneProtocolSpelling(only.type)
    }
    guard let so = t.as(SomeOrAnyTypeSyntax.self) else { return nil }
    let c = so.constraint
    if let comp = c.as(CompositionTypeSyntax.self) {
        var names: [String] = []
        for el in comp.elements {
            guard let n = plainNominalTypeName(el.type) else { return nil }
            if MARKER_PROTOCOLS.contains(n) || n == "Swift.Sendable" { continue }
            names.append(n)
        }
        return names.count == 1 ? names[0] : nil
    }
    if let tup = c.as(TupleTypeSyntax.self), tup.elements.count == 1, let only = tup.elements.first {
        return plainNominalTypeName(only.type)
    }
    return plainNominalTypeName(c)
}

func classifySurfaceValueType(_ t: TypeSyntax) -> SurfaceValueType? {
    if let p = oneProtocolSpelling(t) { return .oneProtocol(p) }
    if let n = plainNominalTypeName(t) { return .nominal(n) }
    return nil
}

/// The supertype spellings of an inheritance clause, generic arguments stripped (`Base<Int>` -> `Base`),
/// with `nil` for an entry whose spelling cannot be read as a nominal (a composition, a `~Copyable`
/// suppression is skipped as a layout fact).
private func inheritedSpellings(_ clause: InheritanceClauseSyntax?) -> [String?] {
    guard let clause else { return [] }
    var out: [String?] = []
    for it in clause.inheritedTypes {
        var ty = it.type
        if let att = ty.as(AttributedTypeSyntax.self) { ty = att.baseType }   // `@unchecked Sendable`
        if ty.is(SuppressedTypeSyntax.self) { continue }                      // `~Copyable`
        out.append(nominalStrippingGenerics(ty))
    }
    return out
}

private func nominalStrippingGenerics(_ t: TypeSyntax) -> String? {
    if let id = t.as(IdentifierTypeSyntax.self) { return id.name.text }
    if let mem = t.as(MemberTypeSyntax.self), let head = nominalStrippingGenerics(mem.baseType) {
        return "\(head).\(mem.name.text)"
    }
    return nil
}

private func hasDynamicMemberAttribute(_ attrs: AttributeListSyntax) -> Bool {
    attrs.contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "dynamicMemberLookup" }
}

private func hasMacroCandidateAttribute(_ attrs: AttributeListSyntax) -> Bool {
    for a in attrs {
        guard let attr = a.as(AttributeSyntax.self) else { return true }   // an `#if` inside attributes
        let name = attr.attributeName.trimmedDescription
        if !COMPILER_TYPE_ATTRIBUTES.contains(name) { return true }
    }
    return false
}

final class TypeSurfaceCollector: SyntaxVisitor {
    struct TypeDecl { var path: String; var kind: String; var inherits: [String?]; var unclosable: Bool; var scope: String?
                      /// conformances the language supplies without an inheritance clause (an enum's
                      /// `Equatable`/`Hashable`, an actor's `Actor`), read only against `extendedPlatform`
                      var implicit: [String] = []
                      /// `@dynamicMemberLookup` or a `subscript(dynamicMember:)`: forwards members no manifest lists
                      var dynMember: Bool = false }
    struct ExtDecl { var spelled: String; var scope: String?; var inherits: [String?]; var macro: Bool
                     var hasMembers: Bool = false; var dynMember: Bool = false }
    struct ValueDecl { var owner: String?; var ownerIsExtension: Bool; var member: String; var type: SurfaceValueType; var scope: String?; var fromCtor: Bool }

    let file: String
    var types: [TypeDecl] = []
    var exts: [ExtDecl] = []
    var values: [ValueDecl] = []
    /// The lexical type path; an extension pushes its EXTENDED type's spelling.
    private var stack: [(name: String, isExtension: Bool, rec: Int)] = []

    init(file: String) {
        self.file = file
        super.init(viewMode: .sourceAccurate)
    }

    private var path: String? { stack.isEmpty ? nil : stack.map(\.name).joined(separator: ".") }
    private var inExtension: Bool { stack.contains { $0.isExtension } }

    private func pushType(_ name: String, kind: String, inherits: InheritanceClauseSyntax?,
                          attrs: AttributeListSyntax, extraUnclosable: Bool = false, implicit: [String] = []) {
        let scope = path
        let full = scope.map { "\($0).\(name)" } ?? name
        types.append(TypeDecl(path: full, kind: kind, inherits: inheritedSpellings(inherits),
                              unclosable: hasMacroCandidateAttribute(attrs) || extraUnclosable, scope: scope,
                              implicit: implicit, dynMember: hasDynamicMemberAttribute(attrs)))
        stack.append((name, false, types.count - 1))
    }

    private func classKind(_ mods: DeclModifierListSyntax) -> String {
        let names = Set(mods.map { $0.name.text })
        if names.contains("final") { return "final" }
        if names.contains("open") { return "open" }
        return "class"
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, kind: classKind(node.modifiers), inherits: node.inheritanceClause, attrs: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, kind: "value", inherits: node.inheritanceClause, attrs: node.attributes)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        // An enum is `Equatable`/`Hashable` with no clause when its cases carry no payload — listed for every
        // enum, over-approximating in the direction that can only add a supertype.
        pushType(node.name.text, kind: "value", inherits: node.inheritanceClause, attrs: node.attributes,
                 implicit: ["Equatable", "Hashable"])
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { stack.removeLast() }
    /// An actor cannot be subclassed, so `final` is exact for it.
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, kind: "final", inherits: node.inheritanceClause, attrs: node.attributes,
                 implicit: ["Actor", "AnyActor", "Sendable"])
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { stack.removeLast() }
    /// A protocol's `where Self: X` clause is a supertype the inheritance clause does not show — not
    /// closable from this declaration alone, so kind-only.
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, kind: "protocol", inherits: node.inheritanceClause, attrs: node.attributes,
                 extraUnclosable: node.genericWhereClause != nil)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { stack.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let spelled = nominalStrippingGenerics(node.extendedType) ?? node.extendedType.trimmedDescription
        let hasMembers = node.memberBlock.members.contains {
            let d = $0.decl
            return d.is(FunctionDeclSyntax.self) || d.is(VariableDeclSyntax.self) || d.is(SubscriptDeclSyntax.self)
                || d.is(InitializerDeclSyntax.self)
        }
        exts.append(ExtDecl(spelled: spelled, scope: path, inherits: inheritedSpellings(node.inheritanceClause),
                            macro: hasMacroCandidateAttribute(node.attributes), hasMembers: hasMembers,
                            dynMember: hasDynamicMemberAttribute(node.attributes)))
        stack.append((spelled, true, exts.count - 1))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { stack.removeLast() }

    // Bodies declare nothing a consumer can name.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    /// `subscript(dynamicMember:)` makes its owner forward members no manifest lists (SPEC §2 ⟨0.40⟩: such a
    /// type is never closed; PART 95 o16_dyn_member, SOUNDNESS R890).
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.parameterClause.parameters.contains(where: { $0.firstName.text == "dynamicMember" }),
           let top = stack.last {
            if top.isExtension { exts[top.rec].dynMember = true } else { types[top.rec].dynMember = true }
        }
        return .skipChildren
    }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let mods = Set(node.modifiers.map { $0.name.text })
        if mods.contains("private") || mods.contains("fileprivate") { return .skipChildren }
        for b in node.bindings {
            guard let raw = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`"))   // `` `default` `` is `default`
            var ty: SurfaceValueType? = nil
            var fromCtor = false
            if let ann = b.typeAnnotation {
                ty = classifySurfaceValueType(ann.type)
            } else if let v = b.initializer?.value, let call = v.as(FunctionCallExprSyntax.self),
                      call.trailingClosure == nil {
                // `static let shared = Client()` — a construction's static type is the constructed type.
                // Only a CONSTRUCTOR-shaped callee (a capitalised type spelling) qualifies; the Driver then
                // requires it to resolve to a declared NON-protocol type, so a capitalised free function
                // that happens to share a type's name cannot type the value.
                let callee = call.calledExpression.trimmedDescription
                if let first = callee.split(separator: ".").last?.first, first.isUppercase,
                   callee.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) {
                    ty = .nominal(callee); fromCtor = true
                }
            }
            guard let ty else { continue }
            values.append(ValueDecl(owner: path, ownerIsExtension: inExtension, member: name, type: ty, scope: path, fromCtor: fromCtor))
        }
        return .skipChildren   // accessor bodies declare nothing a consumer can name
    }
}

/// The ⟨0.40⟩ producer's output, already qualified (`<pkg>#…`).
struct TypeSurfaceOut {
    var holds: [String: String] = [:]
    var returnsProtocol: [String: String] = [:]
    var types: [String: DeclaredTypeInfo] = [:]
    var adds: [String: [String]] = [:]
}

extension TypeSurfaceCollector {
    /// Local `typealias` names, collected by a second tiny pass so a supertype spelled through an alias
    /// (`class X: Alias`, where the alias may name a composition) is never resolved as a nominal.
    static func aliasNames(in tree: SourceFileSyntax) -> Set<String> {
        final class A: SyntaxVisitor {
            var names: Set<String> = []
            override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
                names.insert(node.name.text); return .skipChildren
            }
        }
        let a = A(viewMode: .sourceAccurate)
        a.walk(tree)
        return a.names
    }
}

/// How a written type spelling resolved, from one file's point of view.
enum SpellingResolution: Equatable {
    case local(String)       // a type this package DECLARES, by its full path
    case foreign(String)     // `<pkg>#<path>` in the owning package's namespace
    case platform            // the standard library / a platform SDK: omitted, as SPEC §2 ⟨0.40⟩ permits
    case unresolved          // nothing this producer can stand behind
}

/// THE ⟨0.40⟩ PRODUCER. `resolveForeign` answers a non-local spelling for one file (chained `types`,
/// an explicit module qualifier, the import fallback); it is passed in because the facts it reads live in
/// `analyze`. `protocolResults` is fn qual -> the ONE protocol its declared result is (any/some/bare).
func buildTypeSurface040(pkg: String, collectors: [TypeSurfaceCollector], aliases: Set<String>,
                         isProtocolKey: (String) -> Bool,
                         isModuleName: (_ name: String, _ file: String) -> Bool,
                         resolveForeign: (_ spelled: String, _ file: String, _ fallback: Bool) -> SpellingResolution,
                         protocolResults: [(qual: String, spelled: String, scope: String?, file: String)])
    -> TypeSurfaceOut
{
    var out = TypeSurfaceOut()
    var declared: [String: [(TypeSurfaceCollector.TypeDecl, String)]] = [:]
    for c in collectors { for t in c.types { declared[t.path, default: []].append((t, c.file)) } }
    let declaredPaths = Set(declared.keys)

    func resolveLocal(_ written: String, scope: String?) -> String? {
        var segs = scope.map { $0.split(separator: ".").map(String.init) } ?? []
        while !segs.isEmpty {
            let cand = segs.joined(separator: ".") + "." + written
            if declaredPaths.contains(cand) { return cand }
            segs.removeLast()
        }
        return declaredPaths.contains(written) ? written : nil
    }
    func resolve(_ written: String, scope: String?, file: String, fallback: Bool) -> SpellingResolution {
        if let l = resolveLocal(written, scope: scope) { return .local(l) }
        if aliases.contains(written) { return .unresolved }
        return resolveForeign(written, file, fallback)
    }
    func qualified(_ r: SpellingResolution) -> String? {
        switch r {
        case .local(let p): return "\(pkg)#\(p)"
        case .foreign(let k): return k
        default: return nil
        }
    }
    // An extension's EXTENDED type, resolved once.
    var extTarget: [Int: [SpellingResolution]] = [:]
    for (ci, c) in collectors.enumerated() {
        extTarget[ci] = c.exts.map { resolve($0.spelled, scope: $0.scope, file: c.file, fallback: true) }
    }

    // ── `types`: EVERY declared type, its kind, and its COMPLETE direct supertypes or none ──
    var supersOf: [String: Set<String>] = [:]
    var unclosable: Set<String> = []
    // ⟨0.40⟩ (SPEC §2 ⟨0.40⟩, R889) the PLATFORM supertypes each type names or is given implicitly — omitted
    // from `supers` as permitted, EXCEPT where this package extends one with a member (below).
    var platformOf: [String: Set<String>] = [:]
    func platformName(_ s: String) -> String {
        let segs = s.split(separator: ".").map(String.init)
        return segs.count > 1 && (PLATFORM_MODULES.contains(segs[0]) || KAPPA_MODULES.contains(segs[0]))
            ? segs.dropFirst().joined(separator: ".") : s
    }
    for (path, decls) in declared {
        if Set(decls.map { $0.0.kind }).count != 1 { continue }   // two arms disagree on the kind: no key
        for (d, file) in decls {
            if d.unclosable || d.dynMember { unclosable.insert(path) }
            platformOf[path, default: []].formUnion(d.implicit)
            for s in d.inherits {
                guard let s else { unclosable.insert(path); continue }
                if LAYOUT_SUPERS_PUBLIC.contains(s) { continue }
                let r = resolve(s, scope: d.scope, file: file, fallback: true)
                switch r {
                case .platform: platformOf[path, default: []].insert(platformName(s)); continue
                case .unresolved: unclosable.insert(path)
                default: if let q = qualified(r) { supersOf[path, default: []].insert(q) }
                }
            }
        }
    }
    // The platform types this package EXTENDS WITH A MEMBER — the member it publishes under `<pkg>#<P>`.
    var extendedPlatform: Set<String> = []
    for (ci, c) in collectors.enumerated() {
        for (ei, e) in c.exts.enumerated() {
            let tgt = extTarget[ci]?[ei] ?? .unresolved
            if case .platform = tgt, e.hasMembers { extendedPlatform.insert(platformName(e.spelled)) }
            var sups: [String] = []
            var plats: [String] = []
            var short = false
            for s in e.inherits {
                guard let s else { short = true; continue }
                if LAYOUT_SUPERS_PUBLIC.contains(s) { continue }
                let r = resolve(s, scope: e.scope, file: c.file, fallback: true)
                switch r {
                case .platform: plats.append(platformName(s)); continue
                case .unresolved: short = true
                default: if let q = qualified(r) { sups.append(q) }
                }
            }
            switch tgt {
            case .local(let p):
                if e.macro || short || e.dynMember { unclosable.insert(p) }
                supersOf[p, default: []].formUnion(sups)
                platformOf[p, default: []].formUnion(plats)
            case .foreign(let k):
                // `adds` is never complete, so an unresolvable supertype is simply not published.
                if !sups.isEmpty { out.adds[k, default: []].append(contentsOf: sups) }
            default: break
            }
        }
    }
    // ⟨0.40⟩ R890: a type that forwards through `@dynamicMemberLookup` is never closed — nor is any type
    // that inherits it from a local superclass or protocol (fixpoint over local supertypes).
    var dyn = Set(declared.compactMap { p, ds in ds.contains { $0.0.dynMember } ? p : nil })
    for c in collectors { for e in c.exts where e.dynMember { if let p = resolveLocal(e.spelled, scope: nil) { dyn.insert(p) } } }
    var changed = true
    while changed {
        changed = false
        for (path, sups) in supersOf where !dyn.contains(path) {
            if sups.contains(where: { $0.hasPrefix("\(pkg)#") && dyn.contains(String($0.dropFirst(pkg.count + 1))) }) {
                dyn.insert(path); changed = true
            }
        }
    }
    unclosable.formUnion(dyn)
    // ⟨0.40⟩ R889: a PLATFORM type this package extends with a member MUST be in the `supers` of every type it
    // declares that conforms to it — directly, implicitly, through a standard refinement, or through a local
    // supertype — spelled `<pkg>#<P>`, where this package's own entries spell the extension. A platform
    // supertype whose refinements this producer does not know could reach one of them unseen, so it leaves
    // the type unclosed instead of listing short.
    if !extendedPlatform.isEmpty {
        for (path, direct) in platformOf {
            var closure = Set<String>(), stack = Array(direct)
            var unknown: [String] = []
            while let n = stack.popLast() {
                guard closure.insert(n).inserted else { continue }
                if let r = PLATFORM_REFINES[n] { stack.append(contentsOf: r) }
                else if !PLATFORM_LEAVES.contains(n), !extendedPlatform.contains(n) { unknown.append(n) }
            }
            if !unknown.isEmpty {
                unclosable.insert(path)
                if ProcessInfo.processInfo.environment["CANDOR_R843_PROBE"] != nil {
                    FileHandle.standardError.write("R843UNCLOSED \(pkg)#\(path) unknown=\(unknown.sorted()) extended=\(extendedPlatform.sorted())\n".data(using: .utf8)!)
                }
            }
            for p in closure.intersection(extendedPlatform) { supersOf[path, default: []].insert("\(pkg)#\(p)") }
        }
        // A platform VALUE type (`String`, `Array`) is never anyone's supertype, so it needs no key: its
        // added members are reached by the ordinary `<pkg>#String.<member>` join, as before.
        for p in extendedPlatform where declared[p] == nil && !PLATFORM_VALUE_TYPES.contains(p) {
            let sups = (PLATFORM_REFINES[p] ?? []).filter { extendedPlatform.contains($0) }.map { "\(pkg)#\($0)" }
            out.types["\(pkg)#\(p)"] = DeclaredTypeInfo(
                kind: PLATFORM_VALUE_TYPES.contains(p) ? "value" : "protocol", supers: sups.sorted())
        }
    }
    for (path, decls) in declared {
        let kinds = Set(decls.map { $0.0.kind })
        guard kinds.count == 1, let kind = kinds.first else { continue }
        out.types["\(pkg)#\(path)"] = DeclaredTypeInfo(
            kind: kind, supers: unclosable.contains(path) ? nil : (supersOf[path] ?? []).sorted())
    }
    for (k, v) in out.adds { out.adds[k] = Array(Set(v)).sorted() }

    // ── `holds`: a declared value -> the type it is DECLARED to hold ──
    var holdsConflict: Set<String> = []
    for c in collectors {
        for v in c.values {
            // The OWNER: the lexical path, with a leading module qualifier on an extended type dropped
            // (`extension Base.Tok` declares members of `Tok`; the qualifier is a spelling).
            var ownerPath: String? = v.owner
            if v.ownerIsExtension, let o = v.owner, resolveLocal(o, scope: nil) == nil {
                var segs = o.split(separator: ".").map(String.init)
                while segs.count > 1, isModuleName(segs[0], c.file) { segs.removeFirst() }
                ownerPath = segs.joined(separator: ".")
            }
            let key = ownerPath.map { "\(pkg)#\($0).\(v.member)" } ?? "\(pkg)#\(v.member)"
            var target: String? = nil
            switch v.type {
            case .nominal(let s), .oneProtocol(let s):
                let r = resolve(s, scope: v.scope, file: c.file, fallback: false)
                target = qualified(r)
                let isProto = target.map { isProtocolKey($0) || out.types[$0]?.kind == "protocol" } ?? false
                if case .oneProtocol = v.type, !isProto { target = nil }
                if v.fromCtor, isProto { target = nil }   // a construction never yields a protocol
            }
            guard let t = target else { continue }
            if let prev = out.holds[key], prev != t { holdsConflict.insert(key) } else { out.holds[key] = t }
        }
    }
    for k in holdsConflict { out.holds.removeValue(forKey: k) }

    // ── `returnsProtocol` ──
    var rpConflict: Set<String> = []
    for r in protocolResults {
        let res = resolve(r.spelled, scope: r.scope, file: r.file, fallback: false)
        guard let t = qualified(res), isProtocolKey(t) || out.types[t]?.kind == "protocol" else { continue }
        let key = "\(pkg)#\(r.qual)"
        if let prev = out.returnsProtocol[key], prev != t { rpConflict.insert(key) } else { out.returnsProtocol[key] = t }
    }
    for k in rpConflict { out.returnsProtocol.removeValue(forKey: k) }
    return out
}

/// Spellings of supertypes that are layout constraints rather than declarations, and of the standard
/// library / platform protocols a member is classified through rather than joined (the builtin
/// frontier). Omitted from `supers` as SPEC §2 ⟨0.40⟩ permits for a standard-library or platform
/// supertype — a member reached only through one of them falls to the member miss, and is disclosed.
let LAYOUT_SUPERS_PUBLIC: Set<String> = ["AnyObject", "Any", "Copyable", "Escapable", "BitwiseCopyable"]
let STD_SUPERS_PUBLIC: Set<String> = STD_PURE_PROTOCOLS.union(RAW_VALUE_BASE_TYPES).union([
    "Error", "LocalizedError", "CustomNSError", "NSObject", "NSObjectProtocol", "NSCoding", "NSSecureCoding",
    "NSCopying", "ExpressibleByStringLiteral", "ExpressibleByIntegerLiteral", "ExpressibleByArrayLiteral",
    "ExpressibleByDictionaryLiteral", "ExpressibleByBooleanLiteral", "ExpressibleByFloatLiteral",
    "ExpressibleByNilLiteral", "ExpressibleByUnicodeScalarLiteral", "ExpressibleByExtendedGraphemeClusterLiteral",
    "ExpressibleByStringInterpolation", "TextOutputStream", "TextOutputStreamable", "LosslessStringConvertible",
    "CustomReflectable", "CustomPlaygroundDisplayConvertible", "SetAlgebra", "Numeric", "SignedNumeric",
    "BinaryInteger", "FixedWidthInteger", "SignedInteger", "UnsignedInteger", "FloatingPoint",
    "BinaryFloatingPoint", "LazySequenceProtocol", "LazyCollectionProtocol", "RangeExpression",
    "Actor", "AnyActor", "GlobalActor", "DistributedActor", "ObservableObject", "Observable",
    // Foundation protocols a conformance names without a module qualifier. Without them, a file that also
    // imports exactly ONE non-platform module had them attributed to that module by the import fallback
    // (measured on swift-nio: `ByteBufferView`'s supers read `SystemPackage#DataProtocol`) — a dead
    // supertype that only ever MISSES, but a wrong one.
    "ContiguousBytes", "DataProtocol", "MutableDataProtocol", "NSFastEnumeration", "CodingKey",
    "Encoder", "Decoder", "KeyedEncodingContainerProtocol", "KeyedDecodingContainerProtocol",
    "UnkeyedEncodingContainer", "UnkeyedDecodingContainer", "SingleValueEncodingContainer",
    "SingleValueDecodingContainer", "URLSessionDelegate", "URLSessionTaskDelegate", "URLSessionDataDelegate",
    "URLSessionDownloadDelegate", "URLSessionStreamDelegate", "URLSessionWebSocketDelegate",
])

/// ⟨0.40⟩ R889 — the standard library's refinement edges among the platform supertypes a Swift type commonly
/// names, so a type conforming to `Hashable` is known to conform to an `Equatable` this package extends.
/// A platform supertype NOT in this table or in `PLATFORM_LEAVES` leaves its type unclosed (kind-only) when
/// the package extends any platform type with a member: a refinement this table does not know could be
/// the edge to it. The table can only ADD supertypes; a missing edge costs a disclosure, never a silence.
let PLATFORM_REFINES: [String: [String]] = [
    "Hashable": ["Equatable"], "Comparable": ["Equatable"], "Strideable": ["Comparable"],
    "Identifiable": [], "CaseIterable": [], "RawRepresentable": [], "Error": ["Sendable"],
    "LocalizedError": ["Error"], "CustomNSError": ["Error"], "Codable": ["Encodable", "Decodable"],
    "Sequence": [], "IteratorProtocol": [], "Collection": ["Sequence"],
    "BidirectionalCollection": ["Collection"], "RandomAccessCollection": ["BidirectionalCollection"],
    "MutableCollection": ["Collection"], "RangeReplaceableCollection": ["Collection"],
    "LazySequenceProtocol": ["Sequence"], "LazyCollectionProtocol": ["Collection", "LazySequenceProtocol"],
    "AsyncSequence": [], "AsyncIteratorProtocol": [], "SetAlgebra": ["Equatable", "ExpressibleByArrayLiteral"],
    "OptionSet": ["SetAlgebra", "RawRepresentable"], "AdditiveArithmetic": ["Equatable"],
    "Numeric": ["AdditiveArithmetic", "ExpressibleByIntegerLiteral"], "SignedNumeric": ["Numeric"],
    "BinaryInteger": ["Hashable", "Numeric", "Strideable", "CustomStringConvertible"],
    "FixedWidthInteger": ["BinaryInteger"], "SignedInteger": ["BinaryInteger", "SignedNumeric"],
    "UnsignedInteger": ["BinaryInteger"], "FloatingPoint": ["Hashable", "SignedNumeric", "Strideable"],
    "BinaryFloatingPoint": ["FloatingPoint"],
    "StringProtocol": ["BidirectionalCollection", "Comparable", "Hashable", "TextOutputStream",
                       "TextOutputStreamable", "LosslessStringConvertible", "ExpressibleByStringInterpolation"],
    "ExpressibleByStringInterpolation": ["ExpressibleByStringLiteral"],
    "ExpressibleByStringLiteral": ["ExpressibleByExtendedGraphemeClusterLiteral"],
    "ExpressibleByExtendedGraphemeClusterLiteral": ["ExpressibleByUnicodeScalarLiteral"],
    "LosslessStringConvertible": ["CustomStringConvertible"],
    "DataProtocol": ["RandomAccessCollection"], "MutableDataProtocol": ["DataProtocol", "MutableCollection", "RangeReplaceableCollection"],
    "Actor": ["AnyActor", "Sendable"], "AnyActor": [], "GlobalActor": [], "DistributedActor": ["AnyActor", "Sendable"],
    "NSObject": ["NSObjectProtocol", "Equatable", "Hashable", "CustomStringConvertible", "CustomDebugStringConvertible"],
    "NSObjectProtocol": [], "NSCoding": [], "NSSecureCoding": ["NSCoding"], "NSCopying": [],
    "ObservableObject": ["AnyObject"], "Observable": [],
    // A raw-value enum's "supertype" `String` / `Int` is its RAW TYPE: it makes the enum RawRepresentable.
    "String": ["RawRepresentable"], "Character": ["RawRepresentable"], "Bool": ["RawRepresentable"],
    "Double": ["RawRepresentable"], "Float": ["RawRepresentable"], "Int": ["RawRepresentable"],
    "Int8": ["RawRepresentable"], "Int16": ["RawRepresentable"], "Int32": ["RawRepresentable"],
    "Int64": ["RawRepresentable"], "UInt": ["RawRepresentable"], "UInt8": ["RawRepresentable"],
    "UInt16": ["RawRepresentable"], "UInt32": ["RawRepresentable"], "UInt64": ["RawRepresentable"],
    "URLSessionDelegate": ["NSObjectProtocol"], "URLSessionTaskDelegate": ["URLSessionDelegate"],
    "URLSessionDataDelegate": ["URLSessionTaskDelegate"], "URLSessionDownloadDelegate": ["URLSessionTaskDelegate"],
    "URLSessionStreamDelegate": ["URLSessionTaskDelegate"], "URLSessionWebSocketDelegate": ["URLSessionTaskDelegate"],
    "ManagedBuffer": [],
]
/// Platform supertypes with no refinement edge worth knowing (no supertype a package would extend).
let PLATFORM_LEAVES: Set<String> = [
    "Equatable", "Encodable", "Decodable", "Sendable", "Copyable", "Escapable", "BitwiseCopyable",
    "CustomStringConvertible", "CustomDebugStringConvertible", "CustomReflectable",
    "CustomPlaygroundDisplayConvertible", "TextOutputStream", "TextOutputStreamable",
    "ExpressibleByIntegerLiteral", "ExpressibleByArrayLiteral", "ExpressibleByDictionaryLiteral",
    "ExpressibleByBooleanLiteral", "ExpressibleByFloatLiteral", "ExpressibleByNilLiteral",
    "ExpressibleByUnicodeScalarLiteral", "RangeExpression", "ContiguousBytes", "NSFastEnumeration",
    "CodingKey", "Encoder", "Decoder", "AnyObject", "KeyedEncodingContainerProtocol",
    "KeyedDecodingContainerProtocol", "UnkeyedEncodingContainer", "UnkeyedDecodingContainer",
    "SingleValueEncodingContainer", "SingleValueDecodingContainer", "Hasher",
]
/// Platform nominal types that are VALUES (an extension of one gets `kind: value` on its `<pkg>#<T>` key).
let PLATFORM_VALUE_TYPES: Set<String> = RAW_VALUE_BASE_TYPES.union([
    "Array", "Dictionary", "Set", "Optional", "Result", "Data", "URL", "Date", "UUID", "Substring",
])
