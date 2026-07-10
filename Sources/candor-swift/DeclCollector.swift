// candor-swift — Pass A (declaration collection: units, field types, protocols, imports).
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation
import SwiftSyntax
import CandorCore

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Pass A — declarations: units, field types, protocols, conformers, imports
// ════════════════════════════════════════════════════════════════════════════════════════════════

struct FnInfo {
    var qual: String          // FULLY-QUALIFIED nested path: "Outer.Inner.name" / "Type.name" / "name".
                              // Full path (not just the immediate enclosing type) so two same-named
                              // NESTED types — `A.Backend.store` and `B.Backend.store` — are DISTINCT
                              // symbols instead of collapsing to one `Backend.store` whose effect set is
                              // the UNION of both bodies (which fabricates the effectful sibling's effect
                              // onto the pure one — a fabrication, the precision failure; the Kingfisher MemoryStorage/
                              // DiskStorage sweep). Top-level types have a single-element type stack, so
                              // qual == simpleQual there — non-nested code is byte-identical.
    var simpleQual: String = ""   // the immediate "Type.name" form — receivers resolve to SIMPLE type
                                  // names, so call edges are matched simple→full through `qualBySimple`.
    var enclosingTypePath: String?    // FULL nested path of the enclosing type (for precise sibling edges)
    var paramSig: [(type: String?, hasDefault: Bool, variadic: Bool)] = []  // ordered param signature for
                                      // PARAM-TYPE overload resolution: distinguishes same-name overloads
                                      // (`compare(_:Date)` vs `compare(_:DateComparisonType)`), including the
                                      // same-arity ones arity/labels can't tell apart. `variadic` (a trailing
                                      // `T...`) lifts the arg-count upper bound (`run(_:String,_:Binding?...)`).
    var loc: String
    var params: [String: String] = [:]       // param name -> type name (concrete)
    var fnTypedParams: Set<String> = []      // params of function type
    var fnTypedParamIndex: [String: Int] = [:] // fn-typed param name -> position
    var protoParams: [String: String] = [:]  // param name -> local protocol name
    var arrayParams: [String: String] = [:]  // param name -> ELEMENT type (a `[T]` param, for `for x in p`)
    var dictParams: [String: String] = [:]   // param name -> VALUE type (a `[K: V]` param, for `for (k,v)`)
    var tupleParams: [String: [String: String]] = [:]  // param -> tuple element types (`p.0`/`p.c`)
    var body: Syntax?
    var enclosingType: String?
    var isMain: Bool = false
    var isAccessor: Bool = false   // a computed-property/observer/lazy-init body (spec 0.5 unitKind)
    var uppercaseAttrs: [String] = []   // capitalized @-attributes (a `@SomeBuilder` result-builder candidate)
}

// Collects the expression of every explicit `return <expr>` inside a body (Finding 1: pinning a function's
// concrete returned iterable type). Does NOT descend into nested closures/functions — a `return` there
// belongs to that inner scope, not the function whose concrete result type we're resolving.
final class ReturnExprWalker: SyntaxVisitor {
    var exprs: [ExprSyntax] = []
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if let e = node.expression { exprs.append(e) }
        return .visitChildren
    }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

final class DeclCollector: SyntaxVisitor {
    var file: String
    var converter: SourceLocationConverter
    var fns: [FnInfo] = []
    var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:] // Type -> field -> info
    var typeGenericBounds: [String: [String: String]] = [:]  // Type -> its generic param -> protocol bound
    var fieldArrayElem: [String: [String: String]] = [:]  // Type -> field -> ELEMENT type (`[T]` field)
    var fieldDictValue: [String: [String: String]] = [:]  // Type -> field -> VALUE type (`[K: V]` field)
    var protocolMethods: [String: Set<String>] = [:]   // protocol -> declared method names
    var returnsTmp: [String: String?] = [:]            // fn leaf -> return type (nil = ambiguous)
    var conformers: [String: [String]] = [:]           // protocol -> conforming local types
    var caseAssoc: [String: Set<String>] = [:]         // enum case -> single-associated-value type(s) seen
    // `static let shared = factory()` — Type.field -> factory leaf, resolved to the vended type AFTER
    // the returns index is built (a free factory's return type isn't known during this first pass).
    var staticFactoryFields: [(type: String, field: String, leaf: String)] = []
    var localTypes: Set<String> = []
    // Types with a REAL local definition (class/struct/enum/actor/protocol) — a SUBSET of localTypes,
    // which also carries types that only ever appear in an `extension`. An `extension Process { … }` adds
    // "Process" to localTypes (so its members resolve to any sibling helpers) but NOT to declaredTypes —
    // it does not redefine the platform type. The shadow discipline (a project's own `class Channel` must
    // not fabricate NIO Net) keys on `declaredTypes`: a member call on an extension-ONLY κ-platform type
    // (`self.launch()` inside `extension Process`) that resolves to no local unit falls through to the κ
    // table instead of reading silent-pure (the ShellOut cardinal-sin: `Process.launch` was lost).
    var declaredTypes: Set<String> = []
    // Types declared `@propertyWrapper`, and the wrapped stored properties per type
    // (`wrappedProps["S"]["count"] = "Logged"`). A `@Logged var count` desugars `s.count` to
    // `s._count.wrappedValue`; CallCollector edges the access to `Logged.wrappedValue` so an effectful
    // wrapper accessor isn't silently pure. The attribute NAME is recorded raw (any uppercase-first
    // property attribute); CallCollector confirms it against `propertyWrapperTypes` (unioned across all
    // files) before edging, so a non-wrapper attribute / a wrapper declared in another file never
    // fabricates and ordering can't matter.
    var propertyWrapperTypes: Set<String> = []
    var wrappedProps: [String: [String: String]] = [:]
    var dynamicMemberTypes: Set<String> = []   // `@dynamicMemberLookup`-annotated local types
    var resultBuilderTypes: Set<String> = []   // `@resultBuilder`-annotated local types
    // LOCAL `typealias Name = Underlying` declarations (name -> the underlying type's SIMPLE name). The
    // κ classifier keys on the LITERAL type spelling, so an alias (`typealias Proc = Process`) evaded it
    // and a `Proc()`/`FM.default` reach read silent-pure. Resolved through in CallCollector before the κ
    // table and type resolution so `Proc`→`Process`→Exec, `FM`→`FileManager`→Fs. Only a simple-identifier
    // underlying type is recorded (a function-type/generic/tuple alias has no κ-relevant single name).
    var typeAliases: [String: String] = [:]
    var imports: [String] = []
    // FINDING 1 — opaque/erased effectful Sequence builders. A function whose DECLARED return type is an
    // opaque (`some Sequence`) or erased (`AnySequence`) iterable hides its concrete iterator from callers:
    // a `for x in builder()` runs a `next()` candor can't pin to a unit. Two indexes drive the precise-or-
    // honest fix at the iteration site:
    //   opaqueSeqLeaves      — leaf names whose return type is such an opaque/erased iterable
    //   seqConcreteRetTmp    — leaf -> the CONCRETE LOCAL type its body returns (`return FileEater()`, or
    //                          `AnySequence(FileEater())` peeled through the eraser), nil = ambiguous/none.
    // When the concrete type resolves, the iteration site edges to its `next` (precise); otherwise it reads
    // Unknown (honest). Keyed by leaf (the call site sees `b.build(…)` — the member name).
    var opaqueSeqLeaves: Set<String> = []
    var seqConcreteRetTmp: [String: String?] = [:]
    // FINDING 2 — stored effectful closure PROPERTIES. `let f: (Int)->Void = { … }` charges its closure
    // body to `<Type>.init`; invoking `f(0)` / `map(f)` reached NOTHING. Collect the closure initializer as
    // its OWN property-scoped accessor unit `<Type>.f` (so a pure closure property contributes nothing — no
    // flood), and record the property name so CallCollector can edge an invocation to it.
    var closureFields: [String: Set<String>] = [:]   // Type -> stored closure-property names (with a `<Type>.<prop>` unit)
    private var typeStack: [String] = []

    init(file: String, tree: SourceFileSyntax) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    private func loc(_ node: some SyntaxProtocol) -> String {
        let l = node.startLocation(converter: converter)
        return "\(file):\(l.line):\(l.column)"
    }

    private func pushType(_ name: String, inheritance: InheritanceClauseSyntax?, attributes: AttributeListSyntax? = nil,
                          isExtension: Bool = false) {
        typeStack.append(name)
        localTypes.insert(name)
        // An `extension` does not DECLARE the type — it adds to whatever (possibly platform) type already
        // exists. Only a real definition shadows the κ table (see declaredTypes' note).
        if !isExtension { declaredTypes.insert(name) }
        for inh in inheritance?.inheritedTypes ?? [] {
            if let pname = typeName(inh.type).name {
                conformers[pname, default: []].append(name)
            }
        }
        // `@dynamicMemberLookup` — a member access `p.x` on this type desugars to the dynamic
        // subscript, whose effect cannot be statically pinned to the runtime member name. A read of
        // an UNDECLARED member on such a type is honest Unknown (modeled in CallCollector).
        for attr in attributes ?? [] {
            if let a = attr.as(AttributeSyntax.self) {
                let an = a.attributeName.trimmedDescription
                if an == "dynamicMemberLookup" { dynamicMemberTypes.insert(name) }
                // A `@propertyWrapper` type: `@Wrapper var p` desugars `p` to `_p.wrappedValue`, so a
                // read/write of the wrapped property runs the wrapper's wrappedValue accessor. Record
                // the wrapper TYPE so CallCollector can edge a wrapped-property access to it.
                if an == "propertyWrapper" { propertyWrapperTypes.insert(name) }
                // A `@resultBuilder` type: a func annotated `@ThisBuilder` has its body transformed into
                // `ThisBuilder.buildBlock(...)` etc — so the builder's build methods RUN when the func is
                // called. Record the type so Driver can edge such a func to its build* units (R29).
                if an == "resultBuilder" { resultBuilderTypes.insert(name) }
            }
        }
    }

    // Enum case associated-value types: `case active(Client)` → caseAssoc["active"] = {"Client"}.
    // Used to type a `case .active(let c)` binding (switch/if-case) so `c.method()` resolves. Only the
    // SINGLE-associated-value form is recorded; an unambiguous case name (one assoc type project-wide)
    // is bindable, an ambiguous one (`.success(A)` vs `.success(B)`) is left unbound — never guess.
    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for el in node.elements {
            guard let params = el.parameterClause?.parameters, params.count == 1,
                  let t = typeName(params.first!.type).name else { continue }
            caseAssoc[el.name.text, default: []].insert(t)
        }
        return .visitChildren
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let first = node.path.first { imports.append(first.name.text) }
        return .skipChildren
    }
    // `typealias Proc = Process` — record name -> underlying SIMPLE type name. Only a resolvable simple
    // name (peeling Optional/some/any/single-tuple) is recorded; a function/generic/tuple alias is left
    // out (no single κ-relevant type). The CallCollector resolves a receiver/type spelling through these.
    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        if let underlying = typeName(node.initializer.value).name {
            typeAliases[node.name.text] = underlying
        }
        return .skipChildren
    }
    // TYPE-LEVEL generic bounds (`struct Pipe<T: Saver>` / `… where T: Saver`) — recorded so a stored field
    // typed `T` resolves to its bound `Saver`, letting `item.save()` dispatch (else it read silent-pure, R27).
    private func recordTypeGenerics(_ name: String, _ clause: GenericParameterClauseSyntax?, _ whereClause: GenericWhereClauseSyntax?) {
        for gp in clause?.parameters ?? [] {
            if let it = gp.inheritedType, let b = typeName(it).name { typeGenericBounds[name, default: [:]][gp.name.text] = b }
        }
        for req in whereClause?.requirements ?? [] {
            guard case .conformanceRequirement(let c) = req.requirement,
                  let l = typeName(c.leftType).name, let r = typeName(c.rightType).name else { continue }
            typeGenericBounds[name, default: [:]][l] = r
        }
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeGenerics(node.name.text, node.genericParameterClause, node.genericWhereClause)
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeGenerics(node.name.text, node.genericParameterClause, node.genericWhereClause)
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeGenerics(node.name.text, node.genericParameterClause, node.genericWhereClause)
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeGenerics(node.name.text, node.genericParameterClause, node.genericWhereClause)
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // A non-identifier extended type (`extension [Foo]`, `extension Optional<X>`) needs a
        // STABLE name — the old "?" fallback merged every such extension into one phantom unit
        // ("?.name" showed up as a caller in the swift-argument-parser probe), cross-wiring their
        // methods. The trimmed source text is unique per type; spaces drop for qual hygiene.
        let name = typeName(node.extendedType).name
            ?? node.extendedType.trimmedDescription.replacingOccurrences(of: " ", with: "")
        pushType(name, inheritance: node.inheritanceClause, isExtension: true); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        var methods = Set<String>()
        for member in node.memberBlock.members {
            if let f = member.decl.as(FunctionDeclSyntax.self) { methods.insert(f.name.text) }
            // PROPERTY requirements (`var payload: Int { get }`) and SUBSCRIPT requirements — recorded
            // so a protocol-typed property/subscript READ can dispatch CHA to conformers' accessor units
            // (the property-requirement dispatch hole: only function requirements were known).
            else if let v = member.decl.as(VariableDeclSyntax.self) {
                for b in v.bindings {
                    if let n = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                        protocolMethods[node.name.text, default: []].insert(n)
                    }
                }
            } else if member.decl.is(SubscriptDeclSyntax.self) {
                protocolMethods[node.name.text, default: []].insert("subscript")
            }
        }
        protocolMethods[node.name.text, default: []].formUnion(methods)
        return .skipChildren
    }

    // Field types (for `self.f()` / `d.f()` resolution and fn-typed-field Unknown) — and ACCESSOR
    // UNITS: a computed getter, get/set block, didSet/willSet observer, or lazy initializer has a
    // BODY that runs (the fuzz probe found all four silently pure — the TS engine's property-arrow
    // hole, Swift edition). Each body collects under `Type.property`; duplicate quals union.
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if let ty = typeStack.last {
            let tyPath = typeStack.joined(separator: ".")
            let isStatic = node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
            for binding in node.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                let qual = "\(tyPath).\(name)"          // fully-qualified nested path
                let simpleQual = "\(ty).\(name)"
                // the property's declared type — used to TYPE a setter's implicit param so an effect
                // reached THROUGH it (`set { newValue.write(toFile:) }`) resolves (else newValue is an
                // untyped bare identifier and the member call reads silent-pure). nil ⇒ inferred type, skip.
                let propType = binding.typeAnnotation.flatMap { typeName($0.type).name }
                // (body, the setter param to type as `propType`) — nil for a getter/lazy/static-init body.
                var accessorBodies: [(body: Syntax, setterParam: String?)] = []
                if let ab = binding.accessorBlock {
                    switch ab.accessors {
                    case .getter(let items): accessorBodies.append((Syntax(items), nil))
                    case .accessors(let list):
                        for acc in list {
                            guard let b = acc.body else { continue }
                            // set/willSet ⇒ `newValue`; didSet ⇒ `oldValue`; each renamable via `set(x)`.
                            let sp: String?
                            switch acc.accessorSpecifier.text {
                            case "set", "willSet": sp = acc.parameters?.name.text ?? "newValue"
                            case "didSet":         sp = acc.parameters?.name.text ?? "oldValue"
                            default:               sp = nil   // get — no implicit value param
                            }
                            accessorBodies.append((Syntax(b), sp))
                        }
                    }
                }
                if node.modifiers.contains(where: { $0.name.text == "lazy" }), let init0 = binding.initializer {
                    accessorBodies.append((Syntax(init0.value), nil)) // lazy init runs at first ACCESS
                }
                // `static let/var x = <expr>` — the initializer runs at FIRST ACCESS (Swift statics are
                // lazy, like a JVM <clinit>), so its body is a unit charged to the first-touch read site
                // (CallCollector edges a `Type.x` read to it). An INSTANCE stored property's init runs in
                // the synthesized `init` (a different, already-collected unit) and is NOT first-touch —
                // so only statics are collected here; lazy vars are already handled above.
                if isStatic, binding.accessorBlock == nil,
                   !node.modifiers.contains(where: { $0.name.text == "lazy" }),
                   let init0 = binding.initializer {
                    accessorBodies.append((Syntax(init0.value), nil))
                }
                // An INSTANCE STORED property's initializer (`let session = makeSession()`) runs during
                // CONSTRUCTION — in every init, before its body. With an EXPLICIT init the field init
                // merges into that collected `<Type>.init` unit (duplicate quals union); but with a
                // SYNTHESIZED init (no explicit init) there is no such unit and the initializer's effects
                // were ORPHANED (a `let db = Connection(...)` dependency-wiring read pure at the
                // construction site). Collect the initializer under `<Type>.init` so `Type()` edges to it
                // either way. (Static/lazy are handled above as first-touch reads, not construction.)
                // GATE on the binding being a DIRECT type member (parent is a MemberBlockItem). The
                // visitor descends into accessor bodies (returns .visitChildren), so a `let p = Process()`
                // NESTED in a computed getter is re-visited here with `typeStack.last` still the enclosing
                // type — and (no accessorBlock + an initializer) it satisfied this S-init shape, fabricating
                // the getter's effect onto `<Type>.init`/construction even when the property is never read.
                if node.parent?.is(MemberBlockItemSyntax.self) == true,
                   !isStatic, binding.accessorBlock == nil,
                   !node.modifiers.contains(where: { $0.name.text == "lazy" }),
                   let init0 = binding.initializer {
                    var info = FnInfo(qual: "\(tyPath).init", loc: loc(binding))
                    info.simpleQual = "\(ty).init"
                    info.enclosingType = ty
                    info.enclosingTypePath = tyPath
                    info.body = Syntax(init0.value)
                    fns.append(info)
                }
                // FINDING 2 — a stored CLOSURE-valued property (`let f: (Int)->Void = { … }`): the closure
                // body runs when the property is INVOKED (`f(0)` / `map(f)`), not at construction. Collect it
                // as its OWN property-scoped accessor unit `<Type>.f` so an invocation can edge to JUST this
                // closure's effects (property-scoped — a pure closure property's unit is pure, contributing
                // nothing; no flood, no fabrication). Record the name so CallCollector recognises the
                // invocation. GATE on a DIRECT type member (not a closure nested in a getter, like the
                // S-init guard above) and an initializer that is genuinely a CLOSURE literal.
                if node.parent?.is(MemberBlockItemSyntax.self) == true,
                   binding.accessorBlock == nil,
                   !node.modifiers.contains(where: { $0.name.text == "lazy" }),
                   let init0 = binding.initializer,
                   init0.value.as(ClosureExprSyntax.self) != nil {
                    var info = FnInfo(qual: qual, loc: loc(binding))
                    info.simpleQual = simpleQual
                    info.enclosingType = ty
                    info.enclosingTypePath = tyPath
                    info.body = Syntax(init0.value)
                    info.isAccessor = true
                    fns.append(info)
                    closureFields[ty, default: []].insert(name)
                }
                for (b, setterParam) in accessorBodies {
                    var info = FnInfo(qual: qual, loc: loc(binding))
                    info.simpleQual = simpleQual
                    info.enclosingType = ty
                    info.enclosingTypePath = tyPath
                    info.body = b
                    info.isAccessor = true
                    // type the setter's implicit value param so `newValue.effectfulMethod()` resolves
                    if let sp = setterParam, let pt = propType { info.params[sp] = pt }
                    fns.append(info)
                }
                // A property-wrapper attribute (`@Logged var count`): record the wrapper TYPE so a read/
                // write of `count` edges to `<Wrapper>.wrappedValue`. Any uppercase-first @-attribute is a
                // candidate; CallCollector gates on `propertyWrapperTypes` so non-wrappers (@MainActor,
                // @objc) and library wrappers (@Published — no local unit) never fabricate.
                for attr in node.attributes {
                    if let a = attr.as(AttributeSyntax.self) {
                        let an = a.attributeName.trimmedDescription
                        if an.first?.isUppercase == true {
                            wrappedProps[ty, default: [:]][name] = an
                            break
                        }
                    }
                }
                if let ann = binding.typeAnnotation {
                    var info = typeName(ann.type)
                    // a field typed as the enclosing type's GENERIC PARAM resolves to its bound, so a
                    // protocol-typed field dispatches (`Pipe<T: Saver>.item` → Saver → `item.save()` fires).
                    if let tn = info.name, let bound = typeGenericBounds[ty]?[tn] { info = (bound, info.isFunction) }
                    fields[ty, default: [:]][name] = info
                    if let elem = arrayElementName(ann.type) { fieldArrayElem[ty, default: [:]][name] = elem }
                    if let val = dictValueName(ann.type) { fieldDictValue[ty, default: [:]][name] = val }
                } else if let initVal = binding.initializer?.value,
                          let call = initVal.as(FunctionCallExprSyntax.self),
                          let ctor = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                    if ctor.baseName.text.first?.isUppercase == true {
                        fields[ty, default: [:]][name] = (ctor.baseName.text, false)
                    } else {
                        // `static let shared = build()` — a free FACTORY (lowercase leaf), not a ctor.
                        // Record the leaf; resolve to the vended type once the returns index exists so
                        // `Type.shared`'s real type (not the static's own type) backs the binding (the
                        // review's free-factory singleton find).
                        staticFactoryFields.append((ty, name, ctor.baseName.text))
                    }
                }
            }
        } else {
            // TOP-LEVEL GLOBAL `let/var x = <expr>` — a global's initializer runs at first ACCESS
            // (lazy, like a static), so it's a unit charged to the first bare-name read (`_ = x`).
            // Only a stored global with an initializer; a computed global var is collected via the
            // accessor branch above (which requires a type stack, so handle it here too).
            for binding in node.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                var bodies: [Syntax] = []
                if let ab = binding.accessorBlock {
                    switch ab.accessors {
                    case .getter(let items): bodies.append(Syntax(items))
                    case .accessors(let list):
                        for acc in list { if let b = acc.body { bodies.append(Syntax(b)) } }
                    }
                } else if let init0 = binding.initializer {
                    bodies.append(Syntax(init0.value))
                }
                for b in bodies {
                    var info = FnInfo(qual: name, loc: loc(binding))
                    info.simpleQual = name
                    info.body = b
                    info.isAccessor = true
                    fns.append(info)
                }
            }
        }
        return .visitChildren
    }

    private func recordReturn(_ name: String, _ sig: FunctionSignatureSyntax) {
        guard let rt = sig.returnClause.map({ typeName($0.type) }), let tn = rt.name else { return }
        if let existing = returnsTmp[name] {
            if existing != tn { returnsTmp[name] = String?.none } // ambiguous leaf — never guess
        } else {
            returnsTmp[name] = tn
        }
    }

    // FINDING 1 — a function returning an OPAQUE/ERASED iterable (`some Sequence` / `AnySequence`). Record
    // the leaf as opaque-seq, and try to pin the CONCRETE LOCAL type its body returns so the iteration site
    // can edge precisely to that type's `next`. The concrete type is the body's single returned expression:
    // a local ctor `FileEater()` (direct), or `AnySequence(FileEater())` (peeled through the eraser ctor).
    // Ambiguity across multiple `return`s → nil (never guess); the site then reads honest Unknown.
    private func recordOpaqueSeqReturn(_ name: String, _ sig: FunctionSignatureSyntax, body: CodeBlockSyntax?) {
        guard let rc = sig.returnClause, opaqueIterableName(rc.type) != nil else { return }
        // Key by the SIMPLE qual `Type.method` (top-level free fn: bare name) — the iteration site
        // resolves the receiver type, so a same-named `build` on a different type can't collide (the leaf-
        // keyed version cross-contaminated `Builder.build` with `PureBuilder.build`/`MethodRef.build`).
        let key = typeStack.last.map { "\($0).\(name)" } ?? name
        opaqueSeqLeaves.insert(key)
        guard let body else { return }
        // collect every returned expression: an explicit `return <expr>` and an implicit single-expr body.
        var returns: [ExprSyntax] = []
        if body.statements.count == 1, let only = body.statements.first?.item.as(ExprSyntax.self) {
            returns.append(only)   // implicit single-expression return (`{ FileEater() }`)
        }
        let walker = ReturnExprWalker(viewMode: .sourceAccurate)
        walker.walk(body)
        returns.append(contentsOf: walker.exprs)
        var concrete: String? = nil
        for r in returns {
            guard let t = concreteIterableType(r) else { seqConcreteRetTmp[key] = String?.none; return }
            if let c = concrete, c != t { seqConcreteRetTmp[key] = String?.none; return }
            concrete = t
        }
        if let c = concrete {
            if let existing = seqConcreteRetTmp[key] {
                if existing != c { seqConcreteRetTmp[key] = String?.none }   // ambiguous (overloads on same type)
            } else { seqConcreteRetTmp[key] = c }
        } else if seqConcreteRetTmp[key] == nil {
            seqConcreteRetTmp[key] = String?.none   // opaque return, no resolvable concrete body → Unknown site
        }
    }

    /// The CONCRETE LOCAL type produced by a returned expression: a ctor `FileEater()` → "FileEater", or an
    /// eraser ctor `AnySequence(FileEater())` / `AnyIterator(it)` → the single arg's local ctor type. Returns
    /// nil when the concrete type can't be pinned (a variable, a factory, a non-local type) — caller treats
    /// nil as "iteration site reads Unknown". Only a LOCAL constructed type is returned (never a guess).
    private func concreteIterableType(_ raw: ExprSyntax) -> String? {
        let e = CallCollector.peel(raw)
        guard let call = e.as(FunctionCallExprSyntax.self),
              let ctor = call.calledExpression.as(DeclReferenceExprSyntax.self),
              ctor.baseName.text.first?.isUppercase == true else { return nil }
        let n = ctor.baseName.text
        // an eraser ctor `AnySequence(<concrete>)` — peel to the single concrete-ctor argument (the local
        // type check happens in the driver where the global localTypes set is complete).
        if ERASED_ITERABLES.contains(n), call.arguments.count == 1,
           let arg = call.arguments.first?.expression {
            return concreteIterableType(arg)
        }
        return n   // a constructed type name; the driver gates it on being a known LOCAL type
    }

    private func collect(_ name: String, sig: FunctionSignatureSyntax, body: CodeBlockSyntax?, node: some SyntaxProtocol) {
        let tyPath = typeStack.isEmpty ? nil : typeStack.joined(separator: ".")
        var info = FnInfo(qual: tyPath.map { "\($0).\(name)" } ?? name, loc: loc(node))
        info.simpleQual = typeStack.last.map { "\($0).\(name)" } ?? name
        info.enclosingType = typeStack.last
        info.enclosingTypePath = tyPath
        info.body = body.map { Syntax($0) }
        info.isMain = name == "main"
        // capture capitalized @-attributes on the func (`@EffBuilder`) — Driver edges to a result-builder
        // type's build methods once all `@resultBuilder` decls are known (declaration order is not assured).
        for attr in Syntax(node).as(FunctionDeclSyntax.self)?.attributes ?? [] {
            if let a = attr.as(AttributeSyntax.self) {
                let an = a.attributeName.trimmedDescription
                if an.first?.isUppercase == true { info.uppercaseAttrs.append(an) }
            }
        }
        // Generic constraints — a value param typed `T` then dispatches like its bound `P`-typed param.
        // BOTH forms bind the same way: the inline `<T: P>` clause AND the `where T: P` clause (the latter
        // was ignored, so `func f<T>(_ x: T) where T: P { x.method() }` read silent-pure — R26).
        var genericBounds: [String: String] = [:]
        let genClause = Syntax(node).as(FunctionDeclSyntax.self)?.genericParameterClause
            ?? Syntax(node).as(InitializerDeclSyntax.self)?.genericParameterClause
        for gp in genClause?.parameters ?? [] {
            if let it = gp.inheritedType, let bound = typeName(it).name { genericBounds[gp.name.text] = bound }
        }
        let whereClause = Syntax(node).as(FunctionDeclSyntax.self)?.genericWhereClause
            ?? Syntax(node).as(InitializerDeclSyntax.self)?.genericWhereClause
        for req in whereClause?.requirements ?? [] {
            guard case .conformanceRequirement(let conf) = req.requirement,
                  let lhs = typeName(conf.leftType).name, let rhs = typeName(conf.rightType).name else { continue }
            genericBounds[lhs] = rhs   // `where T: P` — same binding as `<T: P>`
        }
        for (idx, p) in sig.parameterClause.parameters.enumerated() {
            let pname = (p.secondName ?? p.firstName).text
            let t = typeName(p.type)
            // ordered signature for overload resolution: the param's simple type name (nil if unresolvable)
            // and whether it has a default (so a call may legitimately omit it).
            info.paramSig.append((t.name, p.defaultValue != nil, p.ellipsis != nil))
            if t.isFunction { info.fnTypedParams.insert(pname); info.fnTypedParamIndex[pname] = idx }
            // Container ELEMENT extraction runs before the plain-typed-param branch: a generic container
            // (`Array<T>`/`Set<T>`/`AsyncStream<T>`/`TaskGroup<T>`) has a non-nil simple name, so without
            // this it landed in `params` as the useless container name and `for x in p` left the loop var
            // untyped — the structured-concurrency `for await x in stream` silent-pure hole. `[T]`/`[K:V]`
            // (no simple name) were already reaching here; this just also catches the angle-bracket forms.
            else if let elem = arrayElementName(p.type) { info.arrayParams[pname] = elem }  // `[T]`/`AsyncStream<T>`/…
            else if let val = dictValueName(p.type) { info.dictParams[pname] = val }        // `[K: V]`/`Dictionary<K,V>`
            else if let tn = t.name {
                // resolve a generic param to its protocol BOUND (`x: T` where `<T: Sender>` → dispatch P)
                let resolved = genericBounds[tn] ?? tn
                if protocolMethods[resolved] != nil { info.protoParams[pname] = resolved } else { info.params[pname] = tn }
            }
            else { let te = tupleElements(p.type); if !te.isEmpty { info.tupleParams[pname] = te } }  // `p: (A, B)`
        }
        fns.append(info)
        // DEFAULT-ARGUMENT expressions: `func f(_ x: T = effExpr())` — when a caller OMITS the arg the
        // default expr runs. It only runs when `f` is CALLED, so its effects are a subset of what every
        // call to `f` reaches — charging them to `f`'s unit (a same-qual accessor unit that unions in
        // propagation) is sound and reaches every omitting caller. (Mislocates onto the callee rather
        // than the caller — accepted, never silent-pure; the precise per-caller attribution would need
        // call-site omission analysis, out of scope for this LOW-priority hole.)
        for p in sig.parameterClause.parameters {
            guard let dv = p.defaultValue?.value else { continue }
            var d = FnInfo(qual: info.qual, loc: loc(node))
            d.simpleQual = info.simpleQual
            d.enclosingType = typeStack.last
            d.enclosingTypePath = tyPath
            d.body = Syntax(dv)
            d.isAccessor = true
            fns.append(d)
        }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        recordReturn(node.name.text, node.signature)
        recordOpaqueSeqReturn(node.name.text, node.signature, body: node.body)
        collect(node.name.text, sig: node.signature, body: node.body, node: node)
        return .skipChildren // nested decls attribute lexically via the body walk (documented)
    }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        collect("init", sig: node.signature, body: node.body, node: node)
        return .skipChildren
    }

    // SUBSCRIPT accessor units (the silent-pure hole: `obj[i]` runs the getter/setter body, which
    // had no visitor at all). A subscript collects under `Type.subscript`; a read `obj[i]` / write
    // `obj[i] = v` edges to it (CallCollector models the SubscriptCallExpr). Getter AND setter bodies
    // union — a read of an effectful setter over-approximates (the sound direction), as candor can't
    // tell read vs write apart at every site (`obj[i] += 1` does both).
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let ty = typeStack.last else { return .skipChildren }
        let tyPath = typeStack.joined(separator: ".")
        // the element type — types the setter's implicit `newValue` so `newValue.effectfulMethod()` in a
        // subscript setter resolves (else it read silent-pure, the property-setter hole, subscript edition).
        let elemType = typeName(node.returnClause.type).name
        var bodies: [(body: Syntax, setterParam: String?)] = []
        if let ab = node.accessorBlock {
            switch ab.accessors {
            case .getter(let items): bodies.append((Syntax(items), nil))
            case .accessors(let list):
                for acc in list {
                    guard let b = acc.body else { continue }
                    let sp: String?
                    switch acc.accessorSpecifier.text {
                    case "set", "willSet": sp = acc.parameters?.name.text ?? "newValue"
                    case "didSet":         sp = acc.parameters?.name.text ?? "oldValue"
                    default:               sp = nil
                    }
                    bodies.append((Syntax(b), sp))
                }
            }
        }
        for (b, setterParam) in bodies {
            var info = FnInfo(qual: "\(tyPath).subscript", loc: loc(node))
            info.simpleQual = "\(ty).subscript"
            info.enclosingType = ty
            info.enclosingTypePath = tyPath
            info.body = b
            info.isAccessor = true
            if let sp = setterParam, let et = elemType { info.params[sp] = et }
            fns.append(info)
        }
        return .skipChildren
    }

    // `deinit` I/O (no visitor existed — its body was invisible). Collect under `Type.deinit`; the
    // effect attributes to the deinit unit itself (it runs at scope-exit; there is no single caller
    // site to charge, mirroring a JVM finalizer / the spec's scope-exit attribution).
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let ty = typeStack.last else { return .skipChildren }
        let tyPath = typeStack.joined(separator: ".")
        var info = FnInfo(qual: "\(tyPath).deinit", loc: loc(node))
        info.simpleQual = "\(ty).deinit"
        info.enclosingType = ty
        info.enclosingTypePath = tyPath
        info.body = node.body.map { Syntax($0) }
        info.isAccessor = true
        fns.append(info)
        return .skipChildren
    }
}
