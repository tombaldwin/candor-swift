// candor-swift — the Swift implementation of candor-spec 0.5.
//
// Architecture mirrors candor-scan (the syntactic reference engine): pass A indexes declarations
// (units, field types, protocols + conformers, imports), pass B collects each function's calls
// with light local type inference (params, typed lets, constructor bindings), propagates effects
// to the least fixpoint, and emits the §2 envelope + §2.2 call-graph sidecar. The §4 trust
// contract is the core: a call through a function-typed value, an unresolvable member, or a local
// protocol's dispatch with no visible conformer contributes Unknown — never silent purity.
// Spec 0.5 MUSTs carried from day one: universal `hash` emission (pkg#qual), the §7.14 κ-coverage
// ledger (imports the classifier doesn't know, named per scan), and literal surfaces
// (hosts/cmds/paths/tables) because the §6.2 policy gate enforces `allow` rules.
//
// Known v0 honesty notes (item 7): the κ table covers the platform frontier (Foundation/Network/
// Dispatch/os + sqlite3) — third-party packages are INVISIBLE and the ledger names them; nested
// named functions attribute lexically to their enclosing unit (over-approximation, the sound
// direction); no CANDOR_DEPS consumption yet (hash is emitted so reports are chainable by others);
// the §7.13 soundness harness is not yet ported.

import Foundation
import SwiftParser
import SwiftSyntax
import CandorCore

// ════════════════════════════════════════════════════════════════════════════════════════════════
// CLI
// ════════════════════════════════════════════════════════════════════════════════════════════════

let engineVersion = "candor-swift-0.5.5"
// The bare release semver (`0.5.0`) — the ONE source of truth for both the envelope's build id above
// and `--version`, derived by stripping the engine prefix so the two can't drift.
let releaseVersion = engineVersion.replacingOccurrences(of: "candor-swift-", with: "")
// The spec contract version this engine speaks — the SAME literal that stamps the §2 envelope's `spec`
// field (see the envelope below), reused so `--version` and the report can never disagree.
let specVersion = "0.5"

var target = "."
var outPrefix: String? = nil
var policyPath: String? = ProcessInfo.processInfo.environment["CANDOR_POLICY"]
var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let a = argIter.next() {
    switch a {
    // A value-taking flag with no following value must FAIL, never silently take a nil: a trailing
    // `--policy` (e.g. `--policy $POL` where $POL expanded empty) would otherwise CLOBBER the
    // CANDOR_POLICY env gate with nil and exit 0 — the §6.2 'gateless green' state. exit 2.
    case "--out":
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --out requires a value\n".data(using: .utf8)!); exit(2)
        }
        outPrefix = v
    case "--policy":
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --policy requires a value\n".data(using: .utf8)!); exit(2)
        }
        policyPath = v
    case "-h", "--help":
        print("""
        candor-swift — Swift effect scanner (candor-spec 0.5)
        USAGE: candor-swift [<dir|file.swift>] [--out <prefix>] [--policy <file>] [--agents]
          writes <prefix>.<package>.Swift.json (report, spec 0.5 envelope) + a .callgraph.json sidecar
          CANDOR_POLICY honoured when --policy absent; exit 1 on violation, 2 on unreadable policy.
          --agents         prints the agent contract for THIS build (the embedded AGENTS.md).
          --version        print the installed build + spec contract (offline) and the upgrade line.
        """)
        exit(0)
    case "--version":
        // Two lines, fully OFFLINE: the installed build + the spec contract it speaks, then the
        // upgrade incantation. Both fields reuse the single sources of truth (releaseVersion /
        // specVersion) so this can never drift from the report envelope.
        print("candor-swift \(releaseVersion) (spec \(specVersion))")
        print("upgrade: git pull && swift build -c release")
        exit(0)
    case "--agents":
        // The agent contract for THE INSTALLED BUILD, EMBEDDED at compile time (AgentsDoc.swift,
        // generated from AGENTS.md) — doc and engine cannot drift (the spec §2.1 version-trust
        // rule applied to documentation), and unlike a Bundle.module resource it survives a binary
        // copied out of .build (the documented `cp .build/release/candor-swift …` install flow,
        // where the resource bundle is absent and Bundle.module would fatalError before any guard).
        // Canonical header shape `candor-<engine> <version>` (consistent across the family); the
        // envelope keeps the hyphenated `engineVersion` as its build id.
        print("<!-- \(engineVersion.replacingOccurrences(of: "candor-swift-", with: "candor-swift ")) · the agent contract for this installed version -->")
        // default terminator re-adds the single trailing newline a Swift multiline raw string strips
        // before its closing delimiter, so the served body matches AGENTS.md byte-for-byte.
        print(AGENTS_MD)
        exit(0)
    default:
        // An unknown flag must FAIL, not become the scan path (a stale binary handed a newer
        // doc's flag would scan a directory literally named after it; a typo'd --policy would
        // silently drop the gate).
        if a.hasPrefix("-") {
            FileHandle.standardError.write("candor-swift: unknown flag \(a) (see --help)\n".data(using: .utf8)!)
            exit(2)
        }
        target = a
    }
}

let fm = FileManager.default
var isDir: ObjCBool = false
guard fm.fileExists(atPath: target, isDirectory: &isDir) else {
    FileHandle.standardError.write("candor-swift: no such path: \(target)\n".data(using: .utf8)!)
    exit(2)
}
let rootDir = isDir.boolValue ? target : (target as NSString).deletingLastPathComponent

var sourcePaths: [String] = []
if isDir.boolValue {
    if let en = fm.enumerator(atPath: target) {
        for case let rel as String in en {
            if rel.hasSuffix(".swift") && !isHarnessPath(rel) { sourcePaths.append((target as NSString).appendingPathComponent(rel)) }
        }
    }
} else {
    sourcePaths = [target]
}
sourcePaths.sort()
if sourcePaths.isEmpty {
    FileHandle.standardError.write("candor-swift: no Swift sources under \(target)\n".data(using: .utf8)!)
    exit(2)
}

// The package name — the first half of the §2 `hash` join key. Package.swift's name, else the dir.
var pkgName = (rootDir as NSString).lastPathComponent
if let manifest = try? String(contentsOfFile: (rootDir as NSString).appendingPathComponent("Package.swift"), encoding: .utf8),
   let r = manifest.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) {
    let m = String(manifest[r])
    if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
        pkgName = String(m[m.index(after: q1)..<q2])
    }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Pass A — declarations: units, field types, protocols, conformers, imports
// ════════════════════════════════════════════════════════════════════════════════════════════════

struct FnInfo {
    var qual: String          // FULLY-QUALIFIED nested path: "Outer.Inner.name" / "Type.name" / "name".
                              // Full path (not just the immediate enclosing type) so two same-named
                              // NESTED types — `A.Backend.store` and `B.Backend.store` — are DISTINCT
                              // symbols instead of collapsing to one `Backend.store` whose effect set is
                              // the UNION of both bodies (which fabricates the effectful sibling's effect
                              // onto the pure one — the cardinal sin; the Kingfisher MemoryStorage/
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
}

final class DeclCollector: SyntaxVisitor {
    var file: String
    var converter: SourceLocationConverter
    var fns: [FnInfo] = []
    var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:] // Type -> field -> info
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
    var imports: [String] = []
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

    private func pushType(_ name: String, inheritance: InheritanceClauseSyntax?, attributes: AttributeListSyntax? = nil) {
        typeStack.append(name)
        localTypes.insert(name)
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
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
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
        pushType(name, inheritance: node.inheritanceClause); return .visitChildren
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
                var accessorBodies: [Syntax] = []
                if let ab = binding.accessorBlock {
                    switch ab.accessors {
                    case .getter(let items): accessorBodies.append(Syntax(items))
                    case .accessors(let list):
                        for acc in list {
                            if let b = acc.body { accessorBodies.append(Syntax(b)) }
                        }
                    }
                }
                if node.modifiers.contains(where: { $0.name.text == "lazy" }), let init0 = binding.initializer {
                    accessorBodies.append(Syntax(init0.value)) // lazy init runs at first ACCESS
                }
                // `static let/var x = <expr>` — the initializer runs at FIRST ACCESS (Swift statics are
                // lazy, like a JVM <clinit>), so its body is a unit charged to the first-touch read site
                // (CallCollector edges a `Type.x` read to it). An INSTANCE stored property's init runs in
                // the synthesized `init` (a different, already-collected unit) and is NOT first-touch —
                // so only statics are collected here; lazy vars are already handled above.
                if isStatic, binding.accessorBlock == nil,
                   !node.modifiers.contains(where: { $0.name.text == "lazy" }),
                   let init0 = binding.initializer {
                    accessorBodies.append(Syntax(init0.value))
                }
                for b in accessorBodies {
                    var info = FnInfo(qual: qual, loc: loc(binding))
                    info.simpleQual = simpleQual
                    info.enclosingType = ty
                    info.enclosingTypePath = tyPath
                    info.body = b
                    info.isAccessor = true
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
                    let info = typeName(ann.type)
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

    private func collect(_ name: String, sig: FunctionSignatureSyntax, body: CodeBlockSyntax?, node: some SyntaxProtocol) {
        let tyPath = typeStack.isEmpty ? nil : typeStack.joined(separator: ".")
        var info = FnInfo(qual: tyPath.map { "\($0).\(name)" } ?? name, loc: loc(node))
        info.simpleQual = typeStack.last.map { "\($0).\(name)" } ?? name
        info.enclosingType = typeStack.last
        info.enclosingTypePath = tyPath
        info.body = body.map { Syntax($0) }
        info.isMain = name == "main"
        // Generic constraints `<T: P>` — a value param typed `T` then dispatches like a `P`-typed param.
        var genericBounds: [String: String] = [:]
        let genClause = Syntax(node).as(FunctionDeclSyntax.self)?.genericParameterClause
            ?? Syntax(node).as(InitializerDeclSyntax.self)?.genericParameterClause
        for gp in genClause?.parameters ?? [] {
            if let it = gp.inheritedType, let bound = typeName(it).name { genericBounds[gp.name.text] = bound }
        }
        for (idx, p) in sig.parameterClause.parameters.enumerated() {
            let pname = (p.secondName ?? p.firstName).text
            let t = typeName(p.type)
            // ordered signature for overload resolution: the param's simple type name (nil if unresolvable)
            // and whether it has a default (so a call may legitimately omit it).
            info.paramSig.append((t.name, p.defaultValue != nil, p.ellipsis != nil))
            if t.isFunction { info.fnTypedParams.insert(pname); info.fnTypedParamIndex[pname] = idx }
            else if let tn = t.name {
                // resolve a generic param to its protocol BOUND (`x: T` where `<T: Sender>` → dispatch P)
                let resolved = genericBounds[tn] ?? tn
                if protocolMethods[resolved] != nil { info.protoParams[pname] = resolved } else { info.params[pname] = tn }
            }
            else if let elem = arrayElementName(p.type) { info.arrayParams[pname] = elem }  // `p: [T]`
            else if let val = dictValueName(p.type) { info.dictParams[pname] = val }        // `p: [K: V]`
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
        var bodies: [Syntax] = []
        if let ab = node.accessorBlock {
            switch ab.accessors {
            case .getter(let items): bodies.append(Syntax(items))
            case .accessors(let list):
                for acc in list { if let b = acc.body { bodies.append(Syntax(b)) } }
            }
        }
        for b in bodies {
            var info = FnInfo(qual: "\(tyPath).subscript", loc: loc(node))
            info.simpleQual = "\(ty).subscript"
            info.enclosingType = ty
            info.enclosingTypePath = tyPath
            info.body = b
            info.isAccessor = true
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

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Pass B — calls per function, with light local type inference
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// One argument's disposition at a call site: a closure literal (its body is already charged to
/// the passer lexically), a named reference (resolvable to a unit), or opaque.
enum ArgKind { case closure, named(String), opaque }
struct Call { var path: String; var leaf: String; var strArg: String?; var typed: Bool; var args: [ArgKind] = []
              var argTypes: [String?] = []     // inferred simple type per positional arg (nil = unknown) — overloads
              var unqualified: Bool = false }  // a bare DeclReference `name(…)` (free fn / ctor / self-sibling) —
                                               // NOT a `recv.member(…)` whose receiver type couldn't be resolved
                                               // (those must never be guessed onto a same-named sibling/free fn).

final class CallCollector: SyntaxVisitor {
    var vars: [String: String]              // local/param -> concrete type
    var fnTyped: Set<String>                // function-typed locals/params
    var opaqueFnLocals: Set<String> = []    // fn-typed LOCALS whose value is opaque (not a visible
                                            // closure): invoking one is §4 Unknown — only fn-typed
                                            // PARAMS can defer to call-site flow (callers pass them).
    var protoTyped: [String: String]        // param -> local protocol
    var arrayElem: [String: String]         // name -> element type of a `[T]` local/param (loop typing)
    var dictElem: [String: String]          // name -> VALUE type of a `[K: V]` local/param (dict loops)
    var tupleElem: [String: [String: String]]  // name -> tuple element types (`p.0` / `p.c`)
    let fields: [String: [String: (name: String?, isFunction: Bool)]]
    let fieldArrayElem: [String: [String: String]]  // Type -> field -> [T] element (self.field loops)
    let fieldDictValue: [String: [String: String]]  // Type -> field -> [K: V] value
    let localTypes: Set<String>
    let localProtocols: Set<String> // local protocol names — a receiver typed as one is DISPATCH
    let returns: [String: String]   // unambiguous factory return types (the candor-scan move)
    let enumCaseValueType: [String: String]  // unambiguous enum case -> associated value type
    var enclosingType: String?
    var calls: [Call] = []
    var directEffects: Set<String> = []
    var unresolved = false
    var why: Set<String> = []
    var hosts: Set<String> = []
    var cmds: Set<String> = []
    var paths: Set<String> = []
    var tables: Set<String> = []
    var protoDispatches: [(proto: String, member: String)] = []
    var protoPropReads: [(proto: String, member: String)] = []  // protocol PROPERTY/subscript reads — CHA
    var globalReads: Set<String> = []     // bare-name reads — candidate edges to GLOBAL initializer units
    var propertyEdges: Set<String> = []   // `Type.member` candidates from property READS
    var callbackInvoked: Set<String> = [] // fn-typed params INVOKED — deferred to callback-flow
    let dynamicMemberTypes: Set<String>   // `@dynamicMemberLookup` types — dynamic access is Unknown
    let propertyWrapperTypes: Set<String> // `@propertyWrapper` types — confirm a wrapped-property edge
    let wrappedProps: [String: [String: String]]  // Type -> property -> wrapper type (`S.count -> Logged`)

    init(info: FnInfo, fields: [String: [String: (name: String?, isFunction: Bool)]], localTypes: Set<String>,
         localProtocols: Set<String>, returns: [String: String],
         fieldArrayElem: [String: [String: String]], fieldDictValue: [String: [String: String]],
         enumCaseValueType: [String: String], dynamicMemberTypes: Set<String>,
         propertyWrapperTypes: Set<String>, wrappedProps: [String: [String: String]]) {
        self.propertyWrapperTypes = propertyWrapperTypes
        self.wrappedProps = wrappedProps
        self.dynamicMemberTypes = dynamicMemberTypes
        self.enumCaseValueType = enumCaseValueType
        self.vars = info.params
        self.fnTyped = info.fnTypedParams
        self.protoTyped = info.protoParams
        self.arrayElem = info.arrayParams
        self.dictElem = info.dictParams
        self.tupleElem = info.tupleParams
        self.fields = fields
        self.fieldArrayElem = fieldArrayElem
        self.fieldDictValue = fieldDictValue
        self.localTypes = localTypes
        self.localProtocols = localProtocols
        self.returns = returns
        self.enclosingType = info.enclosingType
        super.init(viewMode: .sourceAccurate)
    }

    /// Peel the effect-transparent wrappers Swift puts around calls — `try`/`try?`/`await`/`!`/`?`.
    /// (The GRDB interop probe: every `try statement.execute()` receiver failed to type because
    /// the binding's initializer was a TryExpr, not the call itself.)
    static func peel(_ expr: ExprSyntax) -> ExprSyntax {
        var e = expr
        while true {
            if let t = e.as(TryExprSyntax.self) { e = t.expression; continue }
            if let a = e.as(AwaitExprSyntax.self) { e = a.expression; continue }
            if let f = e.as(ForceUnwrapExprSyntax.self) { e = f.expression; continue }
            if let o = e.as(OptionalChainingExprSyntax.self) { e = o.expression; continue }
            if let p = e.as(TupleExprSyntax.self), p.elements.count == 1, let only = p.elements.first {
                e = only.expression; continue
            }
            return e
        }
    }

    /// The receiver chain's root: `FileManager.default.contents` -> ("FileManager", path). A root
    /// identifier resolves through vars (param/let types); `self` resolves to the enclosing type.
    private func rootOf(_ raw: ExprSyntax, _ depth: Int = 0) -> (root: String?, isVar: Bool, path: [String]) {
        // Receiver chains recurse with the syntactic nesting (`a.b.c…`, ternary arms, subscript bases —
        // the last via elementTypeOf/dictValueOf, which call back here). Real receivers nest <10 deep;
        // a pathological/generated expression could otherwise overflow the stack. Past a generous bound,
        // give up resolving the type (root = nil = untyped receiver) — the SAFE direction (the call may
        // under-report, never a crash), exactly what an unresolvable receiver already yields.
        if depth > 200 { return (nil, false, []) }
        let expr = Self.peel(raw)
        if let dr = expr.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            // `self` (instance) and `Self` (the enclosing TYPE, used for `Self.staticMethod()`) both resolve
            // to the enclosing type for member resolution — so `Self.decode(…)` is a precise typed call on the
            // type, not a guessed bare member that would either drop or mis-link to a same-named sibling.
            if n == "self" || n == "Self" { return (enclosingType, true, []) }
            if let t = vars[n] { return (t, true, [n]) }
            // IMPLICIT SELF: a bare identifier inside a method body can be a FIELD of the
            // enclosing type (`handler.log(s)` ≡ `self.handler.log(s)`) — the protocol-field probe
            // found dispatchers resolving as raw names and missing the field index entirely.
            if let et = enclosingType, let f = fields[et]?[n], let ft = f.name {
                return (ft, true, [n])
            }
            return (n, false, [n])
        }
        if let ma = expr.as(MemberAccessExprSyntax.self) {
            // tuple element/member: `p.0` / `p.c` where p is a tuple-typed local/param
            if let baseDR = ma.base?.as(DeclReferenceExprSyntax.self),
               let elemType = tupleElem[baseDR.baseName.text]?[ma.declName.baseName.text] {
                return (elemType, true, [])
            }
            let inner = ma.base.map { rootOf($0, depth + 1) } ?? (root: nil, isVar: false, path: [])
            let member = ma.declName.baseName.text
            // WALK THROUGH A FIELD: if the chain so far is a local type with `member` as a stored
            // field, the chain's type becomes the FIELD's type — so `self.client.send()` /
            // `outer.inner.save()` resolve the method on the field's type, not the enclosing type
            // (explicit `self.field.method()` and field-of-field chains otherwise resolved against the
            // wrong type and dropped to pure — the bare-identifier implicit-self path already did this).
            if let rt = inner.root, let f = fields[rt]?[member], let ft = f.name, !f.isFunction {
                return (ft, true, inner.path + [member])
            }
            return (inner.root, inner.isVar, inner.path + [member])
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            // `Svc().act()` — a constructor call types the chain; a FACTORY's unambiguous return
            // type does too (`db.makeStatement(...).execute()` — the GRDB shape).
            if let ctor = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let n = ctor.baseName.text
                if n.first?.isUppercase == true { return (n, true, [n]) }
                if let rt = returns[n] { return (rt, true, [n]) }
            }
            if let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
               let rt = returns[ma.declName.baseName.text] {
                return (rt, true, [ma.declName.baseName.text])
            }
            return (nil, false, [])
        }
        // `coll[i]` — an array subscript yields the element type, a dictionary subscript the value
        // type (`cs[0].send()` / `d["k"]?.send()` resolved against the bare base and dropped to pure).
        if let sub = expr.as(SubscriptCallExprSyntax.self) {
            if let t = elementTypeOf(sub.calledExpression, depth + 1) ?? dictValueOf(sub.calledExpression, depth + 1) {
                return (t, true, [])
            }
        }
        // SwiftParser leaves operators UNFOLDED, so `x as! T` and `cond ? a : b` are SequenceExprs:
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            // `x as! T` / `x as? T` → `[operand, unresolvedAsExpr, typeExpr]`: the type is the result.
            if elems.count == 3, elems[1].is(UnresolvedAsExprSyntax.self),
               let te = elems[2].as(TypeExprSyntax.self), let t = typeName(te.type).name {
                return (t, true, [])
            }
            // `cond ? a : b` → `[cond, unresolvedTernaryExpr(then), elseExpr]`: both arms one type.
            if elems.count == 3, let tern = elems[1].as(UnresolvedTernaryExprSyntax.self) {
                let a = rootOf(tern.thenExpression, depth + 1), b = rootOf(elems[2], depth + 1)
                if let ra = a.root, ra == b.root, a.isVar, b.isVar { return (ra, true, []) }
            }
        }
        return (nil, false, [])
    }

    /// The Foundation file-write idiom `value.write(to: url)` — `Data.write(to:)` and
    /// `String.write(to:)` persist to a FILE → Fs. It was unclassified (kappaMember keys on
    /// FileManager/FileHandle, not the value being written), so a `data.write(to: url)` read silently
    /// pure. GUARD the pure overloads `String` also has: `write(to: &TextOutputStream)` writes to an
    /// in-memory sink and `write(_:)` (TextOutputStream conformance) appends to a string — neither is
    /// file I/O. Both are distinguished by the `to:` argument being an INOUT expression (or absent),
    /// so classify ONLY a `write(to:)` whose destination is a non-inout value. (Data has no such pure
    /// overload; the guard is uniform and harmless there.)
    private func isFileWrite(member: String, _ node: FunctionCallExprSyntax) -> Bool {
        guard member == "write", let first = node.arguments.first, first.label?.text == "to" else { return false }
        return !Self.peel(first.expression).is(InOutExprSyntax.self)
    }

    private func argKinds(_ node: FunctionCallExprSyntax) -> [ArgKind] {
        var kinds: [ArgKind] = node.arguments.map { a in
            let e = Self.peel(a.expression)
            if e.is(ClosureExprSyntax.self) { return .closure }
            if let dr = e.as(DeclReferenceExprSyntax.self) { return .named(dr.baseName.text) }
            return .opaque
        }
        if node.trailingClosure != nil { kinds.append(.closure) }
        for extra in node.additionalTrailingClosures { _ = extra; kinds.append(.closure) }
        return kinds
    }

    /// Inferred simple type of each positional arg (nil = couldn't infer → matches any overload param).
    /// Aligned 1:1 with `argKinds`: trailing closures contribute nil. Only CONFIDENT types are returned
    /// (a resolved var/field chain or a literal) — a guess would wrongly exclude an overload (drop a real
    /// effect), so when unsure it stays nil and the overload matcher keeps the edge (union, never drop).
    private func argTypesOf(_ node: FunctionCallExprSyntax) -> [String?] {
        // Type-match ONLY a FULLY-POSITIONAL call (no labels anywhere): then arg j aligns with param j
        // exactly, so a confident type mismatch is real. The moment ANY arg is labeled, Swift may have
        // omitted an earlier defaulted param (`init(medicationId:…)` skips a defaulted param 0), breaking
        // positional alignment — so we infer NO types and fall back to arity-only (union, never a wrong
        // exclusion). The platform-shadow case (`date.compare(aDate)`) is fully positional, so it still types.
        let positional = !node.arguments.contains { $0.label != nil }
        var ts: [String?] = node.arguments.map { a in positional ? self.argType(a.expression) : nil }
        if node.trailingClosure != nil { ts.append(nil) }
        for _ in node.additionalTrailingClosures { ts.append(nil) }
        return ts
    }

    private func argType(_ raw: ExprSyntax) -> String? {
        let e = Self.peel(raw)
        if e.is(StringLiteralExprSyntax.self) { return "String" }
        if e.is(IntegerLiteralExprSyntax.self) { return "Int" }
        if e.is(FloatLiteralExprSyntax.self) { return "Double" }
        if e.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        // a leading-dot enum/static member `.foo` — type is contextual (the param type), so it can never
        // CONTRADICT an overload; leave nil so it matches any.
        if let ma = e.as(MemberAccessExprSyntax.self), ma.base == nil { return nil }
        // a var/let/param identifier, a field chain (`refDate.date`), a `T()` ctor, or a typed factory:
        // rootOf resolves these to a concrete type ONLY when it tracked one (isVar) — trust just those.
        let r = rootOf(e)
        return r.isVar ? r.root : nil
    }

    private func firstStringLiteral(_ args: LabeledExprListSyntax) -> String? {
        for a in args {
            guard let lit = a.expression.as(StringLiteralExprSyntax.self) else { continue }
            // Concatenate ALL plain segments: the parser may split a literal around escapes, so a
            // single-segment assumption silently dropped multi-line SQL (caught by the four-way
            // conformance differential on this engine's first wiring). An INTERPOLATED literal
            // (any non-plain segment) is runtime-computed — no literal claim, skip it.
            var out = ""
            var pure = true
            for seg in lit.segments {
                if let plain = seg.as(StringSegmentSyntax.self) { out += plain.content.text } else { pure = false; break }
            }
            if pure { return decodeEscapes(out) }
        }
        return nil
    }

    private func recordSurfaces(effect: String, lit: String?) {
        guard let lit else { return }
        switch effect {
        case "Net": hosts.insert(hostPart(lit))
        case "Exec":
            let head = lit.split(separator: " ").first.map(String.init) ?? lit
            cmds.insert(head)
            // a known literal head refines the cliff (curl→Net, candor→Fs/Env); Exec stays
            for e in classifyCommandHead(head) { directEffects.insert(e) }
        case "Fs": if lit.contains("/") || lit.hasPrefix(".") || lit.hasPrefix("~") { paths.insert(lit) }
        case "Db": for t in tablesInSql(lit) { tables.formUnion([t]) }
        default: break
        }
    }

    // The ELEMENT type a sequence yields per iteration. A `[T]` local/param/field; `self.field`; an
    // element-PRESERVING transform (`coll.filter/sorted/reversed/prefix/…`) → coll's element. A
    // literal/computed/transforming (map) sequence is left untyped — never guess.
    private func elementTypeOf(_ expr: ExprSyntax, _ depth: Int = 0) -> String? {
        if depth > 200 { return nil }   // bounds the rootOf ⇄ elementTypeOf recursion (see rootOf)
        let e = Self.peel(expr)
        if let dr = e.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            if let t = arrayElem[n] { return t }
            if let et = enclosingType, let t = fieldArrayElem[et]?[n] { return t }  // implicit-self field
            return nil
        }
        if let ma = e.as(MemberAccessExprSyntax.self), let base = ma.base,
           let bt = rootOf(base, depth + 1).root, let t = fieldArrayElem[bt]?[ma.declName.baseName.text] {
            return t  // a `[E]` field of ANY typed receiver: `self.items` / `pool.clients` / `ps[0].items`
        }
        if let call = e.as(FunctionCallExprSyntax.self),
           let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
           ["filter", "sorted", "reversed", "shuffled", "prefix", "suffix", "dropFirst", "dropLast", "lazy"]
               .contains(ma.declName.baseName.text), let base = ma.base {
            return elementTypeOf(base, depth + 1)  // element-preserving transform → same element type
        }
        return nil
    }

    // The VALUE type a `[K: V]` yields (its `.values`, or the `v` of a `(k, v)` iteration).
    private func dictValueOf(_ expr: ExprSyntax, _ depth: Int = 0) -> String? {
        if depth > 200 { return nil }   // bounds the rootOf ⇄ dictValueOf recursion (see rootOf)
        let e = Self.peel(expr)
        if let dr = e.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            if let t = dictElem[n] { return t }
            if let et = enclosingType, let t = fieldDictValue[et]?[n] { return t }
        }
        if let ma = e.as(MemberAccessExprSyntax.self), let base = ma.base,
           let bt = rootOf(base, depth + 1).root, let t = fieldDictValue[bt]?[ma.declName.baseName.text] { return t }
        return nil
    }

    // Drop EVERY type binding for `name`. A binder (loop var, closure param, `$0`, enum/tuple binding)
    // that cannot determine a type must CLEAR any prior binding for the name, never leave it: `vars` is
    // function-wide and never block-scoped, so a stale effectful binding (an earlier loop's
    // `x: URLSession`) would otherwise leak into a later same-named, UNINFERABLE `x` and FABRICATE its
    // effect (the review's `vars`-leak find — the worst direction). Clearing drops to honest pure (the
    // safe direction). NOTE: still not true block scoping — a cleared binding also leaks OUTWARD, which
    // can under-report (the safe direction), accepted over fabrication.
    private func clearBinding(_ name: String) {
        vars.removeValue(forKey: name)
        arrayElem.removeValue(forKey: name)
        dictElem.removeValue(forKey: name)
        tupleElem.removeValue(forKey: name)
    }

    // `for x in coll` / `for (k, v) in dict` / `for (i, x) in coll.enumerated()` — type the iteration
    // variable from the collection so its member calls resolve (else dropped to pure — §4 under-report).
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        modelImplicitIteration(node.sequence)
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            if let elem = elementTypeOf(node.sequence) { vars[name] = elem } else { clearBinding(name) }
        } else if let tup = node.pattern.as(TuplePatternSyntax.self), tup.elements.count == 2,
                  let second = tup.elements.last?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            if let v = dictValueOf(node.sequence) {
                vars[second] = v  // for (key, value) in dict — value carries the type
            } else if let call = Self.peel(node.sequence).as(FunctionCallExprSyntax.self),
                      let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
                      ma.declName.baseName.text == "enumerated", let base = ma.base,
                      let elem = elementTypeOf(base) {
                vars[second] = elem  // for (offset, element) in coll.enumerated()
            } else { clearBinding(second) }
        }
        return .visitChildren
    }

    // A `for x in seq` desugars to `var it = seq.makeIterator(); while let x = it.next() { … }` — two
    // IMPLICIT calls. When `seq` is a LOCAL type (a custom `Sequence`/`IteratorProtocol`), edge to its
    // `makeIterator`/`next` units so an effect reached only through iteration is charged (else silently
    // pure — the highest-priority hole). A stdlib `[1,2,3]` / `0..<n` / dictionary resolves to NO local
    // type, so no edge is added and the loop stays precisely pure. resolveQual drops any edge to a unit
    // the type doesn't actually declare (a `Sequence` synthesising `makeIterator` from `next`, etc.).
    private func modelImplicitIteration(_ sequence: ExprSyntax) {
        let r = rootOf(sequence)
        guard let t = r.root, r.isVar, localTypes.contains(t) else { return }
        for m in ["makeIterator", "next"] {
            calls.append(Call(path: "\(t).\(m)", leaf: m, strArg: nil, typed: true, args: [], argTypes: []))
        }
    }

    // The 8 element-yielding iterator methods: their closure's FIRST param is the receiver's element
    // (`coll.forEach/map/filter/… { x in x.method() }`). For these — and ONLY these — the element
    // param is TYPED from the receiver so the closure body (which charges lexically to the enclosing
    // unit) resolves the element's member calls.
    private static let ELEMENT_ITERATORS: Set<String> =
        ["forEach", "map", "filter", "compactMap", "flatMap", "first", "contains", "allSatisfy",
         // single-element-param predicate HOFs (closure is `(Element) -> Bool`): an effectful
         // `$0.member` inside these was silent-pure because the param stayed untyped (the 8-method
         // whitelist was too narrow). `drop`/`prefix` only carry a closure in the `(while:)` form
         // (the count forms have no closure, so typeClosureParams self-skips).
         "drop", "prefix", "firstIndex", "lastIndex", "last", "partition", "removeAll", "split"]
    // Methods whose closure params are ALL the receiver's element (`sorted(by:)`/`min(by:)`/`max(by:)`
    // take `(Element, Element) -> Bool`) — type EVERY param, not just the first, so `$0.x < $1.x`
    // resolves both sides. (reduce is deliberately ABSENT: its closure is `(Acc, Element)` — the first
    // param is the accumulator, so element-typing it would mistype the fold state.)
    private static let ELEMENT_PAIR_ITERATORS: Set<String> = ["sorted", "min", "max"]

    // Names a closure binds: explicit `{ (a, b) in … }`/`{ a, b in … }` → those names; shorthand
    // `{ $0.… }` with no signature → `$0`/`$1`/`$2` (we can't tell arity, so clear the common few).
    private func closureParamNames(_ closure: ClosureExprSyntax) -> [(name: String, annotated: String?)] {
        if let params = closure.signature?.parameterClause?.as(ClosureParameterClauseSyntax.self) {
            return params.parameters.map { p in
                (p.firstName.text, p.type.flatMap { typeName($0).name })
            }
        }
        if let shorthand = closure.signature?.parameterClause?.as(ClosureShorthandParameterListSyntax.self) {
            return shorthand.map { ($0.name.text, nil) }
        }
        if closure.signature == nil {
            // no signature → may use `$0`/`$1`/`$2` shorthand; clear the common few so a prior
            // same-named binding can't leak in
            return [("$0", nil), ("$1", nil), ("$2", nil)]
        }
        return []
    }

    // Every closure argument of EVERY call must have its params CLEARED so a prior same-named binding
    // (a loop var `request: URLSession`, an earlier `$0`) cannot leak into the closure body and
    // FABRICATE its effect — `vars` is function-wide (the review's closure-param `vars`-leak find).
    // The sole exception: the FIRST param of the element closure of one of the 8 iterator methods is
    // TYPED from the receiver's element type (so its member calls resolve). An explicit param type
    // annotation (`{ (x: Foo) in }`) types that param precisely; otherwise the param is cleared.
    private func typeClosureParams(_ node: FunctionCallExprSyntax) {
        // collect EVERY closure argument: trailing, additional-trailing, and positional
        var closures: [ClosureExprSyntax] = []
        if let tc = node.trailingClosure { closures.append(tc) }
        for atc in node.additionalTrailingClosures { closures.append(atc.closure) }
        for arg in node.arguments {
            if let c = Self.peel(arg.expression).as(ClosureExprSyntax.self) { closures.append(c) }
        }
        guard !closures.isEmpty else { return }

        // is this the element closure of a whitelisted iterator? then its first param is typed.
        let iteratorMethod: String? = (node.calledExpression.as(MemberAccessExprSyntax.self))?.declName.baseName.text
        let pairIterator = iteratorMethod.map(Self.ELEMENT_PAIR_ITERATORS.contains) ?? false
        let iteratorElem: String? = {
            guard let ma = node.calledExpression.as(MemberAccessExprSyntax.self),
                  Self.ELEMENT_ITERATORS.contains(ma.declName.baseName.text) || pairIterator,
                  let base = ma.base else { return nil }
            return elementTypeOf(base)
        }()
        // the TRAILING closure (or first positional) is the iterator's element closure
        let elemClosure = node.trailingClosure
            ?? node.arguments.lazy.compactMap { Self.peel($0.expression).as(ClosureExprSyntax.self) }.first

        for closure in closures {
            let params = closureParamNames(closure)
            for (i, p) in params.enumerated() {
                if let annotated = p.annotated {
                    vars[p.name] = annotated                 // explicit `{ (x: Foo) in }` — precise
                } else if (i == 0 || pairIterator), let elem = iteratorElem, closure == elemClosure {
                    vars[p.name] = elem                      // iterator element param — typed (both params
                    // for a pair-iterator like sorted/min/max; only the first for the rest)
                } else {
                    clearBinding(p.name)                     // every other param — CLEARED, never leak
                }
            }
        }
    }

    // `case .active(let c):` / `if case .active(let c) = …` — an enum case pattern is parsed as a call
    // `.active(let c)` (leading-dot member, a `let`-binding arg). Type the binding from the case's
    // associated value type so `c.method()` resolves (else it dropped to pure — a §4 under-report).
    private func typeEnumCaseBinding(_ node: FunctionCallExprSyntax) {
        guard let ma = node.calledExpression.as(MemberAccessExprSyntax.self), ma.base == nil else { return }
        // `t` is nil for an AMBIGUOUS or unknown case name — then the binding must be CLEARED, not left:
        // a prior `.live(let h): h=URLSession` binding would otherwise leak into `.dead(let h)` whose
        // case is ambiguous and FABRICATE `h.data()` as Net (the review's whole-program `vars`-leak find).
        // ARITY GUARD: `enumCaseValueType` only records the SINGLE-associated-value form, so it may
        // only type a pattern that ALSO has exactly one payload (`case .live(let c)`). A multi-payload
        // pattern (`case .live(let c, _)`) belongs to a DIFFERENT enum sharing the case name — binding
        // its first `let` to the single-assoc type FABRICATES (the review's enum-identity find).
        // Mismatch (or ambiguous/unknown case) → CLEAR every binding, never leave a stale leak.
        let singleAssoc = node.arguments.count == 1 ? enumCaseValueType[ma.declName.baseName.text] : nil
        for arg in node.arguments {
            if let pat = arg.expression.as(PatternExprSyntax.self),
               let vb = pat.pattern.as(ValueBindingPatternSyntax.self),
               let name = vb.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                if let singleAssoc { vars[name] = singleAssoc } else { clearBinding(name) }
            }
        }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        typeClosureParams(node)
        typeEnumCaseBinding(node)
        let lit = firstStringLiteral(node.arguments)
        if let dr = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = dr.baseName.text
            if ["Data", "NSData", "String"].contains(name),
               node.arguments.first?.label?.text == "contentsOfFile" {
                // `String(contentsOfFile: path, …)` / `Data(contentsOfFile:)` take a FILE PATH, not a
                // URL — there is no scheme to resolve, so this is UNCONDITIONALLY a file read → Fs.
                // (The `contentsOf:` scheme-resolution path below would have let it fall through to
                // pure — the 1725d0a guard keyed on `contentsOf` only — the review's under-report find.)
                directEffects.insert("Fs")
                recordSurfaces(effect: "Fs", lit: lit)
            } else if ["Data", "NSData", "String"].contains(name),
               node.arguments.first?.label?.text == "contentsOf" {
                // `Data/String(contentsOf: url)` reads from a URL that is EITHER a file (Fs) or a
                // remote endpoint (Net) — exactly one is true, but which depends on the URL's scheme.
                // Asserting BOTH (the old behaviour) always FABRICATES the wrong one — a file read
                // reported Net, a network read reported Fs (the §1 cardinal sin; caught fabricating Net
                // on SwiftFormat's config reads, where the URL is a fileURLWithPath from a helper).
                // Resolve the scheme when it's statically provable; otherwise it's an indeterminate
                // effect we can't categorise → honest `Unknown`, never a guess.
                let argText = node.arguments.description
                if argText.contains("fileURLWithPath") || argText.contains("filePath:") {
                    directEffects.insert("Fs") // a provably-FILE URL
                } else if argText.contains("\"http://") || argText.contains("\"https://")
                            || argText.contains("\"ftp://") {
                    directEffects.insert("Net") // a literal remote URL
                } else {
                    unresolved = true // indeterminate scheme: I/O happens, category unprovable
                    why.insert("contentsOf:indeterminate-url-scheme")
                }
            } else if opaqueFnLocals.contains(name) {
                // an OPAQUE local fn-typed value invoked (`let cb: () -> Void = stored!; cb()`):
                // its origin is indeterminate and it is NOT a parameter, so call-site flow can
                // never resolve it — §4 Unknown, directly. (Without this it fell through to the
                // param-deferral below and was silently resolved to pure whenever the enclosing
                // function had any caller — a soundness hole the fuzzer's forms didn't cover.)
                unresolved = true
                why.insert("callback:\(name)")
            } else if fnTyped.contains(name) {
                // a function-typed PARAM invoked — DEFERRED to callback-flow resolution: when
                // every visible call site passes a closure (already charged to its passer
                // lexically) or a named function (an edge), the Unknown is redundant; otherwise
                // it stands (§4). The TS engine's callback_named move.
                callbackInvoked.insert(name)
            } else if let t = vars[name], localTypes.contains(t) {
                // `f()` where `f` is an INSTANCE of a local type — a `callAsFunction` invocation (Swift
                // desugars `f(args)` on a non-function value to `f.callAsFunction(args)`). Edge to the
                // type's callAsFunction unit (if it has one; resolveQual drops the edge otherwise).
                calls.append(Call(path: "\(t).callAsFunction", leaf: "callAsFunction", strArg: lit, typed: true, args: argKinds(node), argTypes: argTypesOf(node)))
            } else if let eff = kappaFree(name: name, argCount: node.arguments.count) {
                directEffects.insert(eff)
                recordSurfaces(effect: eff, lit: lit)
            } else {
                calls.append(Call(path: name, leaf: name, strArg: lit, typed: false, args: argKinds(node), argTypes: argTypesOf(node), unqualified: true))
            }
        } else if let ma = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let member = ma.declName.baseName.text
            let base = ma.base.map { rootOf($0) } ?? (root: nil, isVar: false, path: [])
            // a function-typed FIELD invoked (`d.f()` where f: () -> Void) — the unknown_dyn case
            if let rt = base.root, let f = fields[rt]?[member], f.isFunction {
                unresolved = true
                why.insert("dispatch:\(rt).\(member)")
            } else if let pr = ma.base?.as(DeclReferenceExprSyntax.self), protoTyped[pr.baseName.text] != nil {
                // dispatch through a LOCAL protocol-typed param — bounded CHA or honest Unknown
                protoDispatches.append((protoTyped[pr.baseName.text]!, member))
            } else if let rt = base.root, localTypes.contains(rt) {
                // typed local receiver: Type.method — resolve to the local unit. Checked BEFORE the
                // κ classifier: a locally-declared type ALWAYS shadows the platform table, so a
                // project's own `class Channel`/`HTTPClient` (common names) resolves to its real
                // method instead of fabricating Net from the NIO tier (the GRDB `bind` lesson, for
                // member calls). Under-report-don't-fabricate.
                calls.append(Call(path: "\(rt).\(member)", leaf: member, strArg: lit, typed: true, args: argKinds(node), argTypes: argTypesOf(node)))
            } else if let rt = base.root, localProtocols.contains(rt) {
                // a PROTOCOL-typed receiver reached via a field/let/factory (`self.handler.log()`
                // where `var handler: LogHandler`) — the params-only protoTyped path missed these
                // ENTIRELY (not even Unknown — the density review's lever #1 turned out to be a
                // soundness hole). Same bounded CHA / honest-Unknown as protocol params. Also before
                // κ: a local protocol shadows the platform table.
                protoDispatches.append((rt, member))
            } else if let rt = base.root, (rt == "Data" || rt == "String"), isFileWrite(member: member, node) {
                // Data/String file write (`d.write(to: url)`) → Fs; the pure in-memory/TextOutputStream
                // overloads are excluded by isFileWrite's inout/label guard (never fabricate).
                directEffects.insert("Fs")
                recordSurfaces(effect: "Fs", lit: lit)
            } else if let rt = base.root, let eff = kappaMember(root: rt, member: member) {
                directEffects.insert(eff)
                recordSurfaces(effect: eff, lit: lit)
            } else {
                calls.append(Call(path: member, leaf: member, strArg: lit, typed: false, args: argKinds(node), argTypes: argTypesOf(node)))
            }
        } else if node.calledExpression.is(ClosureExprSyntax.self) {
            // immediately-invoked closure: body walks lexically below — nothing to record
        } else {
            // computed callee (subscript, optional-chained value, …): §4 Unknown
            unresolved = true
            why.insert("call:computed")
        }
        return .visitChildren
    }

    // `guard let c = <expr>` / `if let c = <expr>` — type the unwrapped binding from the initializer
    // (a factory call, subscript, cast, …) so `c.method()` resolves. A shorthand `guard let c` (no
    // initializer) keeps the existing param/var type. The optional is stripped by typing the value.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
           let initVal = node.initializer?.value {
            let info = rootOf(initVal)
            if info.isVar, let t = info.root { vars[name] = t }
            else if let elem = elementTypeOf(initVal) { arrayElem[name] = elem }
            else { clearBinding(name) }  // can't type the unwrapped value → clear (don't leak a stale type)
        }
        return .visitChildren
    }

    // effectful property READS (no call): κ chains AND local accessor units (computed getters)
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.parent?.is(FunctionCallExprSyntax.self) != true {
            // The κ property-read uses the RECEIVER's type + the terminal member — NOT the field-walked
            // whole node. rootOf(whole node) walks a terminal STORED field to its own type, so a pure
            // read of a field named like a κ property (`let now: Date`; `let environment: ProcessInfo`;
            // `let general: NSPasteboard`) would fabricate the effect (`self.now` → root "Date", path
            // ["now"] → a bogus Clock). The receiver-rooted path matches the genuine reads
            // (`ProcessInfo.processInfo.environment`, `Date.now`, `self.w.pinfo.environment`) without it.
            let recv = node.base.map { rootOf($0) } ?? (root: nil, isVar: false, path: [])
            if let root = recv.root,
               let eff = kappaPropertyRead(root: root, path: recv.path + [node.declName.baseName.text]) {
                directEffects.insert(eff)
            }
            // The accessor-unit edge uses the RECEIVER's type (rootOf of the BASE) — NOT the field-walked
            // whole node, whose root would be this property's own value type (`G().v` must edge to `G.v`,
            // the getter unit, not to `Int.v`). rootOf walks fields for method receivers; the terminal
            // property read here wants the type the property is read FROM.
            let recvRoot = recv.root
            let prop = node.declName.baseName.text
            // a protocol-typed PARAM base (`p.payload` where `p: HasPayload`) — `protoTyped` holds the
            // protocol, not `rootOf` (which leaves a proto param's root the bare name). Mirror the
            // method-dispatch path's `protoTyped[…]` lookup before the localTypes/localProtocols checks.
            if let baseDR = node.base?.as(DeclReferenceExprSyntax.self), let proto = protoTyped[baseDR.baseName.text] {
                protoPropReads.append((proto, prop))
            } else if let root = recvRoot, dynamicMemberTypes.contains(root), fields[root]?[prop] == nil {
                // `@dynamicMemberLookup`: `p.x` for a non-stored `x` desugars to the dynamic subscript
                // whose effect can't be pinned to the runtime member name — honest Unknown, never
                // silent-pure (precise resolution is intractable; deferred-to-Unknown per the brief).
                unresolved = true
                why.insert("dynamicMemberLookup:\(root).\(prop)")
            } else if let root = recvRoot, localTypes.contains(root) {
                // A PROPERTY-WRAPPED stored property (`@Logged var count`): `s.count` (read OR write)
                // desugars to `s._count.wrappedValue` — edge to the wrapper's wrappedValue accessor unit
                // so its I/O isn't silently pure. Gated on the attribute being a real `@propertyWrapper`
                // type (confirmed across all files), so a non-wrapper attribute never fabricates. `count`
                // itself is a stored property (no accessor unit), so the plain `S.count` edge below is
                // inert here; the wrappedValue edge is the real one.
                if let wrapper = wrappedProps[root]?[prop], propertyWrapperTypes.contains(wrapper) {
                    propertyEdges.insert("\(wrapper).wrappedValue")
                }
                propertyEdges.insert("\(root).\(prop)")
            } else if let root = recvRoot, localProtocols.contains(root) {
                // PROTOCOL PROPERTY-REQUIREMENT dispatch: `p.payload` where `p` is a protocol-typed
                // receiver — resolve to the conformers' `payload` accessor units (bounded CHA) or honest
                // Unknown, exactly like a method dispatch. The CHA-as-method-requirement path (~line 1299)
                // only knew FUNCTION requirements; a property requirement read was silently pure.
                protoPropReads.append((root, prop))
            }
        }
        return .visitChildren
    }

    // Bare-name READ of a GLOBAL initializer unit (`_ = token`): a top-level `let token = <eff>()`
    // runs its initializer at first access (lazy), so reading it edges to the `token` global unit.
    // Collect candidate names that are NOT a local var/param/fn-typed binding (those shadow a global)
    // and NOT the base of a member/call (handled by their own visitors); resolved in the fixpoint loop
    // only when the name is a known global unit (so an ordinary identifier never fabricates an edge).
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let n = node.baseName.text
        // skip when shadowed by a local binding, or when this reference is the callee/base of a call
        // or member access (those expression forms charge through their own visitors).
        if vars[n] != nil || fnTyped.contains(n) || arrayElem[n] != nil || dictElem[n] != nil { return .skipChildren }
        if let p = node.parent {
            if p.is(FunctionCallExprSyntax.self) || p.is(MemberAccessExprSyntax.self)
                || p.is(SubscriptCallExprSyntax.self) { return .skipChildren }
        }
        globalReads.insert(n)
        return .skipChildren
    }

    // OPERATOR OVERLOAD `a + b` — SwiftParser leaves operators unfolded, so this is a SequenceExpr
    // `[lhs, BinaryOperatorExpr(+), rhs]`. The `+` resolves to an operator `func` decl (a `Type.+`
    // static unit or a free `+` unit); resolve the operand's local type and edge to its operator unit
    // (else leave it — a stdlib `Int + Int` has no local unit and stays pure). The fixpoint loop edges
    // a typed `Type.op` call and an unqualified free-operator call.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elems = Array(node.elements)
        var i = 0
        while i + 2 < elems.count + 1 && i + 1 < elems.count {
            guard let op = elems[i + 1].as(BinaryOperatorExprSyntax.self) else { i += 1; continue }
            let opName = op.operator.text
            // resolve a local operand type from either side (the lhs first, then rhs)
            let lt = rootOf(elems[i]), rt = i + 2 < elems.count ? rootOf(elems[i + 2]) : (root: nil, isVar: false, path: [])
            var resolved = false
            // a binary operator takes two args — supply two opaque arg slots so overloaded operator
            // resolution (arity ≥ 2) keeps the edge.
            let opArgs: [ArgKind] = [.opaque, .opaque], opTypes: [String?] = [lt.isVar ? lt.root : nil, rt.isVar ? rt.root : nil]
            for cand in [lt.root, rt.root] {
                if let t = cand, lt.isVar || rt.isVar, localTypes.contains(t) {
                    calls.append(Call(path: "\(t).\(opName)", leaf: opName, strArg: nil, typed: true, args: opArgs, argTypes: opTypes))
                    resolved = true; break
                }
            }
            if !resolved {
                // a FREE operator overload `func + (…)` — edge via the unqualified-name path (resolved to
                // a unique free-fn unit, else dropped). Never fabricates: only fires if a `+` unit exists.
                calls.append(Call(path: opName, leaf: opName, strArg: nil, typed: false, args: opArgs, argTypes: opTypes, unqualified: true))
            }
            i += 2
        }
        return .visitChildren
    }

    // `obj[i]` / `obj[i] = v` — a subscript ACCESS runs the subscript's getter/setter body (a
    // `Type.subscript` unit). Resolve the base receiver's type; a local-type base edges to its
    // subscript unit (read/write indistinguishable here — over-approximate to the union, the sound
    // direction). A protocol-typed or untyped base is left to the existing postures (no fabrication).
    override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        let base = rootOf(node.calledExpression)
        if let rt = base.root, localTypes.contains(rt) {
            propertyEdges.insert("\(rt).subscript")
        } else if let rt = base.root, localProtocols.contains(rt) {
            protoPropReads.append((rt, "subscript"))
        }
        return .visitChildren
    }

    // `let s = Svc()` / `let s: Svc = …` / `let f = { … }` — local bindings type later calls
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            // `let (a, b) = (X(), Y())` — destructure: bind each name from the initializer tuple element
            if let tp = binding.pattern.as(TuplePatternSyntax.self),
               let tupleInit = binding.initializer?.value.as(TupleExprSyntax.self) {
                for (pe, ve) in zip(tp.elements, tupleInit.elements) {
                    guard let n = pe.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                    let info = rootOf(ve.expression)
                    if info.isVar, let t = info.root { vars[n] = t } else { clearBinding(n) }
                }
                continue
            }
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            if let ann = binding.typeAnnotation {
                if !tupleElements(ann.type).isEmpty { tupleElem[name] = tupleElements(ann.type) }  // `let p: (A, B)`
                let t = typeName(ann.type)
                if t.isFunction {
                    fnTyped.insert(name); vars.removeValue(forKey: name)
                    // A fn-typed local: a VISIBLE closure initializer walks lexically (its effects
                    // are already charged), so it is not opaque; anything else (a field/factory/
                    // force-unwrap value, or no initializer) IS opaque — invoking it is Unknown.
                    if let v0 = binding.initializer?.value, Self.peel(v0).is(ClosureExprSyntax.self) {
                        opaqueFnLocals.remove(name)
                    } else {
                        opaqueFnLocals.insert(name)
                    }
                }
                else if let tn = t.name { vars[name] = tn }
                else if let elem = arrayElementName(ann.type) { arrayElem[name] = elem }  // `let xs: [T]`
                else if let val = dictValueName(ann.type) { dictElem[name] = val }        // `let m: [K: V]`
            } else if let v0 = binding.initializer?.value {
                let v = Self.peel(v0)
                if v.is(ClosureExprSyntax.self) {
                    // visible local closure: body walks lexically; calling it adds nothing
                    fnTyped.remove(name)
                    opaqueFnLocals.remove(name)
                    vars.removeValue(forKey: name)
                } else if v.is(FunctionCallExprSyntax.self) {
                    // ctor or unambiguous factory — one resolver for both (rootOf handles peeling)
                    let info = rootOf(v)
                    if let t = info.root, info.isVar { vars[name] = t }
                    // a collection TRANSFORM result keeps the element type: `let active = cs.filter {…}`
                    // (then `for c in active` resolves). Element-preserving transforms only.
                    else if let elem = elementTypeOf(v0) { arrayElem[name] = elem }
                } else if let ma = v.as(MemberAccessExprSyntax.self),
                          let baseDR = ma.base?.as(DeclReferenceExprSyntax.self),
                          baseDR.baseName.text.first?.isUppercase == true,
                          SINGLETON_ACCESSORS.contains(ma.declName.baseName.text) {
                    // `let fm = FileManager.default` / `URLSession.shared` — a singleton accessor on a
                    // type returns an instance of that type, so the var carries it (else its member
                    // calls resolved against the bare identifier and dropped to pure; the inline
                    // `FileManager.default.removeItem` already classified Fs, the let-bound did not).
                    // BUT if the type RECORDS this accessor's real return type (`static let shared:
                    // Settings = …`), use THAT — else binding `let s = Config.shared` to "Config" when
                    // `.shared` vends a Settings FABRICATES a Config method's effect on s (review find).
                    // The inline form already does this via rootOf's field-walk; match it here.
                    let base = baseDR.baseName.text
                    if let f = fields[base]?[ma.declName.baseName.text], let ft = f.name, !f.isFunction {
                        // the type RECORDS the accessor's vended type (an explicit annotation, a ctor
                        // init, or a resolved free factory) — use THAT, the real instance type.
                        vars[name] = ft
                    } else if localTypes.contains(base) {
                        // a LOCAL type whose `.shared`/`.default` vended type is NOT recorded: the
                        // factory leaf was ambiguous/unknown, so we can't prove it vends Self. Binding
                        // to `base` here would FABRICATE the static's own-type methods on the value (the
                        // free-factory singleton find) — CLEAR instead (under-report over fabricate).
                        clearBinding(name)
                    } else {
                        // a PLATFORM accessor (`URLSession.shared`, `FileManager.default`) — these vend
                        // Self by convention, so the var carries the base type (resolves its κ members).
                        vars[name] = base
                    }
                } else if v.is(SequenceExprSyntax.self) || v.is(SubscriptCallExprSyntax.self) {
                    // `let c = x as! T` / `let c = cond ? a : b` / `let c = cs[0]` — rootOf types these
                    let info = rootOf(v0)
                    if info.isVar, let t = info.root { vars[name] = t }
                }
            }
        }
        return .visitChildren
    }
}

/// SwiftSyntax segment text is SOURCE-ACCURATE: `"a\nb"` arrives with a literal backslash-n.
/// The four-way conformance differential caught this on the engine's FIRST wiring (the Java
/// space-escape bug's twin: multi-line SQL glued, quoted identifiers kept their backslashes).
func decodeEscapes(_ raw: String) -> String {
    var out = ""
    var it = raw.makeIterator()
    while let c = it.next() {
        guard c == "\\", let n = it.next() else { out.append(c); continue }
        switch n {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "0": out.append("\0")
        case "\\": out.append("\\")
        case "\"": out.append("\"")
        case "'": out.append("'")
        default: out.append(c); out.append(n) // unknown escape (\u{…} etc.): keep raw, never guess
        }
    }
    return out
}

func hostPart(_ s: String) -> String {
    var h = s
    for scheme in ["https://", "http://", "wss://", "ws://", "tcp://"] where h.hasPrefix(scheme) {
        h = String(h.dropFirst(scheme.count))
    }
    if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
    return h
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Drive the two passes
// ════════════════════════════════════════════════════════════════════════════════════════════════

var allFns: [FnInfo] = []
var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:]
var fieldArrayElem: [String: [String: String]] = [:]
var fieldDictValue: [String: [String: String]] = [:]
var caseAssocAll: [String: Set<String>] = [:]
var staticFactoryFields: [(type: String, field: String, leaf: String)] = []
var protocolMethods: [String: Set<String>] = [:]
var conformers: [String: [String]] = [:]
var localTypes: Set<String> = []
var dynamicMemberTypes: Set<String> = []
var propertyWrapperTypes: Set<String> = []
var wrappedProps: [String: [String: String]] = [:]
var returnsIdx: [String: String] = [:]
var importCounts: [String: Int] = [:]
// The package's OWN target modules (SPM convention: Sources/<TargetName>/) — an internal import is
// local code the walk already analyzes, not a third-party blind spot (the sweep's ledger noise:
// swift-log importing its own Logging target read as unknown).
var internalModules: Set<String> = [pkgName]
for sub in ["Sources", "Source"] {
    let p = (rootDir as NSString).appendingPathComponent(sub)
    if let entries = try? fm.contentsOfDirectory(atPath: p) {
        for e in entries where !e.hasPrefix(".") { internalModules.insert(e) }
    }
}
// Non-Sources layouts (GRDB/, Alamofire's Source/*.swift): the manifest's own TARGET names are
// the internal-module ground truth — and ONLY target declarations: a bare `name:` regex also
// swallowed `.product(name: "NIOCore", …)` dependency products, silencing exactly the third-party
// modules the κ ledger exists to name (vapor's whole NIO surface vanished from the disclosure).
if let manifest = try? String(contentsOfFile: (rootDir as NSString).appendingPathComponent("Package.swift"), encoding: .utf8) {
    var search = manifest[...]
    while let r = search.range(of: #"\.(executableTarget|testTarget|target|plugin|macro)\(\s*name:\s*"([^"]+)""#,
                               options: .regularExpression) {
        let m = String(search[r])
        if let q1 = m.firstIndex(of: "\""), let q2 = m.lastIndex(of: "\""), q1 < q2 {
            internalModules.insert(String(m[m.index(after: q1)..<q2]))
        }
        search = search[r.upperBound...]
    }
}

var collectors: [DeclCollector] = []
for p in sourcePaths {
    guard let src = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
    let tree = Parser.parse(source: src)
    let rel = p.hasPrefix(rootDir) ? String(p.dropFirst(rootDir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : p
    let c = DeclCollector(file: rel, tree: tree)
    c.walk(tree)
    collectors.append(c)
}
var returnsTmp: [String: String?] = [:]
for c in collectors {
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
    for (cn, ts) in c.caseAssoc { caseAssocAll[cn, default: []].formUnion(ts) }
    for (pn, ms) in c.protocolMethods { protocolMethods[pn, default: []].formUnion(ms) }
    for (pn, ts) in c.conformers { conformers[pn, default: []].append(contentsOf: ts) }
    localTypes.formUnion(c.localTypes)
    dynamicMemberTypes.formUnion(c.dynamicMemberTypes)
    propertyWrapperTypes.formUnion(c.propertyWrapperTypes)
    for (t, ps) in c.wrappedProps { wrappedProps[t, default: [:]].merge(ps) { a, _ in a } }
    for m in c.imports { importCounts[m, default: 0] += 1 }
    staticFactoryFields.append(contentsOf: c.staticFactoryFields)
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
for f in allFns where !f.isAccessor { qualGroup[f.qual, default: 0] += 1 }
let overloadedQuals = Set(qualGroup.filter { $0.value > 1 }.keys)
var overloads: [String: [(qual: String, sig: [(type: String?, hasDefault: Bool, variadic: Bool)])]] = [:]
var overloadedBases = Set<String>()
if !overloadedQuals.isEmpty {
    var seen: [String: Int] = [:]   // identical type-sigs get a positional suffix so they stay distinct nodes
    for i in allFns.indices where !allFns[i].isAccessor && overloadedQuals.contains(allFns[i].qual) {
        let base = allFns[i].simpleQual
        overloadedBases.insert(base)
        var suffix = sigStr(allFns[i].paramSig)
        let dupKey = "\(allFns[i].qual)\(suffix)"
        let n = seen[dupKey, default: 0]; seen[dupKey] = n + 1
        if n > 0 { suffix += "#\(n)" }
        overloads[base, default: []].append(("\(allFns[i].qual)\(suffix)", allFns[i].paramSig))
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
// Match a call (arg count + inferred arg types) to overload target qual(s). Empty ⇒ confident no local
// overload matches ⇒ DROP. Non-empty ⇒ edge to all (one hit precise; several = sound union). A closure so
// it captures `overloads`/`subtypesOf`.
let matchOverloads: (String, Int, [String?]) -> [String] = { base, argc, argTypes in
    guard let cands = overloads[base] else { return [] }
    var hits: [String] = []
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
        if ok { hits.append(c.qual) }
    }
    return hits
}

// name indexes for resolution — UNAMBIGUOUS only (the family's never-guess rule)
var freeFnByName: [String: [String]] = [:]
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
    if f.enclosingType == nil && !f.isAccessor { freeFnByName[f.qual, default: []].append(f.qual) }
    if f.isAccessor && f.enclosingType == nil && !f.qual.contains(".") { globalUnitNames.insert(f.qual) }
}
// Resolve a simple "Type.member" call target to a full nested qual: an exact full-qual hit (top-level,
// already full), else the unique simple→full mapping, else nil (ambiguous/unknown → drop the edge).
// A closure (not a global func) so it captures the main-actor-isolated indexes built just above.
let resolveQual: (String) -> String? = { target in
    if byQual.contains(target) { return target }
    if let cands = qualBySimple[target], cands.count == 1 { return cands.first }
    return nil
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
var unresolvedSet: Set<String> = []
var whyMap: [String: Set<String>] = [:]
var hostsD: [String: Set<String>] = [:], cmdsD: [String: Set<String>] = [:]
var pathsD: [String: Set<String>] = [:], tablesD: [String: Set<String>] = [:]
var locOf: [String: String] = [:]
var entryPoints: Set<String> = []
var kappaSawClassified = false
var callsiteArgs: [String: [[ArgKind]]] = [:]   // resolved target -> each call site's arg kinds
var deferredCallbacks: [String: (indexes: Set<Int>, names: Set<String>)] = [:]

let localProtocolNames = Set(protocolMethods.keys)  // loop-invariant: build once, not per fn
for f in allFns {
    locOf[f.qual] = f.loc
    if f.isMain { entryPoints.insert(f.qual) }
    edges[f.qual] = edges[f.qual] ?? []
    guard let body = f.body else { continue }
    let cc = CallCollector(info: f, fields: fields, localTypes: localTypes,
                           localProtocols: localProtocolNames, returns: returnsIdx,
                           fieldArrayElem: fieldArrayElem, fieldDictValue: fieldDictValue,
                           enumCaseValueType: enumCaseValueType, dynamicMemberTypes: dynamicMemberTypes,
                           propertyWrapperTypes: propertyWrapperTypes, wrappedProps: wrappedProps)
    cc.walk(body)
    // accessor units: a property READ of a known accessor unit is an edge (the reader inherits
    // the getter's effects — `c.data` reaching the Fs inside `var data: Data { … }`)
    edges[f.qual, default: []].formUnion(cc.propertyEdges.compactMap { resolveQual($0) })
    // a bare-name read that names a GLOBAL initializer unit charges its first-touch effects here
    edges[f.qual, default: []].formUnion(cc.globalReads.filter { globalUnitNames.contains($0) && $0 != f.qual })
    direct[f.qual, default: []].formUnion(cc.directEffects)
    if !cc.directEffects.isEmpty { kappaSawClassified = true }
    if cc.unresolved { direct[f.qual, default: []].insert("Unknown"); unresolvedSet.insert(f.qual) }
    whyMap[f.qual, default: []].formUnion(cc.why)
    hostsD[f.qual, default: []].formUnion(cc.hosts)
    cmdsD[f.qual, default: []].formUnion(cc.cmds)
    pathsD[f.qual, default: []].formUnion(cc.paths)
    tablesD[f.qual, default: []].formUnion(cc.tables)

    // fn-typed params INVOKED: defer to callback-flow (resolved after all call sites are known)
    if !cc.callbackInvoked.isEmpty {
        var idxs = Set<Int>()
        for n in cc.callbackInvoked {
            if let i = f.fnTypedParamIndex[n] { idxs.insert(i) }
        }
        deferredCallbacks[f.qual] = (idxs, cc.callbackInvoked)
    }
    for call in cc.calls {
        let argc = call.args.count
        // helper: edge to a resolved overload target (no callsiteArgs for sibling/init forms which don't
        // participate in callback-flow). For an overloaded base, matchOverloads returns 0 (drop), 1
        // (precise) or several (sound union) full quals.
        if call.typed {
            if overloadedBases.contains(call.path) {
                for t in matchOverloads(call.path, argc, call.argTypes) {
                    edges[f.qual, default: []].insert(t)
                    callsiteArgs[t, default: []].append(call.args)
                }
            } else if let t = resolveQual(call.path) {
                edges[f.qual, default: []].insert(t)
                callsiteArgs[t, default: []].append(call.args)
            }
        } else if call.unqualified {
            // an UNQUALIFIED `name(…)` call: a free function, a constructor, or a self-sibling method. A
            // `recv.member(…)` whose receiver type couldn't be resolved is NOT here — it must never be
            // guessed onto a same-named sibling/free fn (Get's `handler.delegate?.urlSession?(…)` forwards
            // to an EXTERNAL delegate; resolving it to self's `urlSession` overload cluster unioned a
            // sibling's real Fs onto the pure forwarder — a fabrication).
            if overloadedBases.contains(call.path) {            // an overloaded FREE function
                for t in matchOverloads(call.path, argc, call.argTypes) {
                    edges[f.qual, default: []].insert(t)
                    callsiteArgs[t, default: []].append(call.args)
                }
            } else if let targets = freeFnByName[call.path], targets.count == 1 {
                edges[f.qual, default: []].insert(targets[0])
                callsiteArgs[targets[0], default: []].append(call.args)
            } else if localTypes.contains(call.path), overloadedBases.contains("\(call.path).init") {
                for t in matchOverloads("\(call.path).init", argc, call.argTypes) {
                    edges[f.qual, default: []].insert(t)
                }
            } else if localTypes.contains(call.path), let t = resolveQual("\(call.path).init") {
                // `_ = C0()` — a constructor call edges to the declared init (the fuzzer's init_wired
                // form caught this silent-pure hole on the harness's FIRST run: effects wired in an
                // initializer vanished — the same hole the TS engine's got-dogfood found in ctors).
                edges[f.qual, default: []].insert(t)
            } else if let et = f.enclosingType, overloadedBases.contains("\(et).\(call.leaf)") {  // overloaded sibling
                for t in matchOverloads("\(et).\(call.leaf)", argc, call.argTypes) {
                    edges[f.qual, default: []].insert(t)
                }
            } else if let ep = f.enclosingTypePath, byQual.contains("\(ep).\(call.leaf)") {
                // an unqualified call inside a type body reaches the sibling method — resolved against the
                // FULL enclosing path, so a nested type's sibling call hits its own member precisely (never
                // a same-named sibling under a different parent).
                edges[f.qual, default: []].insert("\(ep).\(call.leaf)")
            }
        }
        // otherwise: unresolvable bare member (unresolved receiver) — stays out (under-report, never a
        // guess); the κ ledger and Unknown rules above carry the honesty.
    }

    // Bounded CHA over local protocols (SPEC §4, 0.5): the protocol is local and declares the
    // method; resolve ≤12 conformers, otherwise honest Unknown.
    for d in cc.protoDispatches {
        guard protocolMethods[d.proto]?.contains(d.member) == true else { continue }
        let conf = conformers[d.proto] ?? []
        let impls = conf.compactMap { resolveQual("\($0).\(d.member)") }
        if !impls.isEmpty && impls.count <= 12 && impls.count == conf.count {
            for t in impls { edges[f.qual, default: []].insert(t) }
        } else {
            direct[f.qual, default: []].insert("Unknown")
            unresolvedSet.insert(f.qual)
            whyMap[f.qual, default: []].insert("dispatch:\(d.proto).\(d.member)")
        }
    }
    // CHA for protocol PROPERTY/subscript reads — identical bounded resolution to method dispatch,
    // but the conformer units are accessor units (`Type.payload` / `Type.subscript`). A conformer
    // satisfying the requirement with a STORED property has no accessor unit (pure, contributes
    // nothing) — so `impls.count == conf.count` would wrongly force Unknown when SOME conformers are
    // stored. Instead require every conformer to be a KNOWN local type and edge to whichever accessor
    // units exist; an unresolvable/unbounded conformer set is honest Unknown.
    for d in cc.protoPropReads {
        guard protocolMethods[d.proto]?.contains(d.member) == true else { continue }
        let conf = conformers[d.proto] ?? []
        if conf.isEmpty || conf.count > 12 {
            direct[f.qual, default: []].insert("Unknown")
            unresolvedSet.insert(f.qual)
            whyMap[f.qual, default: []].insert("dispatch:\(d.proto).\(d.member)")
            continue
        }
        for c in conf {
            if let t = resolveQual("\(c).\(d.member)") { edges[f.qual, default: []].insert(t) }
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
        unresolvedSet.insert(fq)
        for n in info.names { whyMap[fq, default: []].insert("callback:\(n)") }
    }
}

// fixpoint: effects + literal surfaces propagate over edges (the pure `propagate` lives in CandorCore)
let inferred = propagate(direct, over: edges)
let hostsAcc = propagate(hostsD, over: edges), cmdsAcc = propagate(cmdsD, over: edges)
let pathsAcc = propagate(pathsD, over: edges), tablesAcc = propagate(tablesD, over: edges)

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Report (§2 envelope, spec 0.5) + sidecar (§2.2) + receipt + κ ledger (§7.14)
// ════════════════════════════════════════════════════════════════════════════════════════════════

let prefix = outPrefix ?? (rootDir as NSString).appendingPathComponent(".candor/report")
try? fm.createDirectory(atPath: (prefix as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

let accessorQuals = Set(allFns.filter { $0.isAccessor }.map { $0.qual })
var entries: [[String: Any]] = []
for qual in inferred.keys.sorted() {
    let inf = inferred[qual] ?? []
    if inf.isEmpty { continue }
    var e: [String: Any] = [
        "fn": qual,
        "loc": locOf[qual] ?? "",
        "inferred": inf.sorted(),
        "direct": (direct[qual] ?? []).sorted(),
        "declared": [], "undeclared": [], "overdeclared": [],
        "unresolved": inf.contains("Unknown"),
        "hash": "\(pkgName)#\(qual)",   // 0.5 MUST: every report is chainable
        "calls": (edges[qual] ?? []).sorted(),
    ]
    if entryPoints.contains(qual) { e["entryPoint"] = true }
    if accessorQuals.contains(qual) { e["unitKind"] = "accessor" }  // spec 0.5 draft, informative
    if let w = whyMap[qual], !w.isEmpty { e["unknownWhy"] = w.sorted() }
    if let h = hostsAcc[qual], !h.isEmpty { e["hosts"] = h.sorted() }
    if let c = cmdsAcc[qual], !c.isEmpty { e["cmds"] = c.sorted() }
    if let p = pathsAcc[qual], !p.isEmpty { e["paths"] = p.sorted() }
    if let t = tablesAcc[qual], !t.isEmpty, inf.contains("Db") { e["tables"] = t.sorted() }
    entries.append(e)
}
let envelope: [String: Any] = [
    "candor": ["version": engineVersion, "toolchain": "swiftsyntax", "spec": specVersion],
    "package": pkgName,
    "functions": entries,
]
var cg: [String: [String]] = [:]
for f in allFns { cg[f.qual] = (edges[f.qual] ?? []).sorted() }  // §2.2: EVERY analyzed fn a key

func writeJson(_ obj: Any, _ path: String) {
    // A write failure (read-only FS, no space, a non-existent --out dir, EACCES) used to `try!`-TRAP
    // here — AFTER the whole scan completed — exiting with SIGILL and no message. Fail LOUD instead:
    // name the path and the cause, exit 1, so CI sees a real error rather than a crash signal.
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    } catch {
        FileHandle.standardError.write("candor-swift: could not serialize report for \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    // `.atomic`: Foundation writes to an auxiliary file and renames into place, so a concurrent reader
    // (a cross-engine candor-query / candor-ts merging this report as a sibling) never observes a
    // half-written file — the same write invariant the Rust and TS backends now hold (write_atomic).
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        FileHandle.standardError.write("candor-swift: could not write report to \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
// Family filename shape `<prefix>.<pkg>.Swift.json` — what candor_report::report_files DISCOVERS,
// so the unmodified candor-query binary works on Swift reports (this engine's whole consumption
// story; caught by the first query-interop probe: `show` couldn't find a `<prefix>.json`). The
// pkg segment is dot-sanitized (`GRDB.swift` would otherwise split the <crate>.<kind> parse).
let fileSafePkg = pkgName.replacingOccurrences(of: ".", with: "-")
let reportPath = "\(prefix).\(fileSafePkg).Swift.json"
writeJson(envelope, reportPath)
writeJson(cg, "\(prefix).\(fileSafePkg).Swift.callgraph.json")
FileHandle.standardError.write(
    "candor-swift: wrote \(entries.count) effectful functions (\(allFns.count) analyzed, \(sourcePaths.count) files) to \(reportPath)\n".data(using: .utf8)!)

// the κ-coverage ledger: imported modules outside the platform frontier that κ doesn't know —
// INVISIBLE, not Unknown; named per scan (SPEC §7 item 14, canonical marker)
let unlisted = importCounts.filter { !PLATFORM_MODULES.contains($0.key) && !KAPPA_MODULES.contains($0.key) && !internalModules.contains($0.key) }
    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
if !unlisted.isEmpty {
    let shown = unlisted.prefix(8).map { "\($0.key) (\($0.value) import\($0.value == 1 ? "" : "s"))" }.joined(separator: ", ")
    let more = unlisted.count > 8 ? " + \(unlisted.count - 8) more" : ""
    FileHandle.standardError.write(
        ("candor-swift: κ doesn't know \(unlisted.count) module\(unlisted.count == 1 ? "" : "s") this code imports — "
         + "effects through \(unlisted.count == 1 ? "it are" : "them are") INVISIBLE (not Unknown): \(shown)\(more)\n").data(using: .utf8)!)
}
_ = kappaSawClassified

// ════════════════════════════════════════════════════════════════════════════════════════════════
// §6.2 policy gate (deny / pure / allow / forbid) — token-for-token with the family parsers
// ════════════════════════════════════════════════════════════════════════════════════════════════

let EFFECTS: Set<String> = ["Net", "Fs", "Db", "Exec", "Env", "Clock", "Ipc", "Log", "Rand", "Clipboard"]
let ALLOW_EFFECTS: Set<String> = ["Net", "Exec", "Fs", "Db"]

struct DenyRule { var effects: [String]; var scope: String; var raw: String }
struct AllowRule { var effect: String; var scope: String; var values: [String]; var raw: String }
struct ForbidRule { var from: String; var to: String; var raw: String }

func warnRule(_ why: String, _ line: String) {
    FileHandle.standardError.write("candor: ignoring policy rule (\(why)): \(line)\n".data(using: .utf8)!)
}

func parsePolicy(_ text: String) -> (deny: [DenyRule], allow: [AllowRule], forbid: [ForbidRule]) {
    var deny: [DenyRule] = [], allow: [AllowRule] = [], forbid: [ForbidRule] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        // The §6.2 token separator is ASCII whitespace ONLY. `.whitespaces`/`Character.isWhitespace` are
        // Unicode — they'd split a NBSP/ideographic space that Java drops (a gateless-green divergence;
        // adversarial DSL review). `isASCII && isWhitespace` keeps space/tab/CR/LF/VT/FF and excludes the
        // non-ASCII spaces, so a NBSP stays part of its token → the rule is malformed and dropped.
        let asciiWS = CharacterSet(charactersIn: " \t\n\u{0B}\u{0C}\r")
        let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: asciiWS)
        if line.isEmpty { continue }
        let t = line.split(whereSeparator: { $0.isASCII && $0.isWhitespace }).map(String.init)
        switch t[0] {
        case "deny":
            var effects: [String] = []; var scope = ""
            for tok in t.dropFirst() {
                if EFFECTS.contains(tok) || tok == "Unknown" { effects.append(tok) } else { scope = tok; break }
            }
            if effects.isEmpty { warnRule("deny names no known effect", line); continue }
            deny.append(DenyRule(effects: effects.sorted(), scope: scope, raw: line))
        case "pure":
            deny.append(DenyRule(effects: [], scope: t.count > 1 ? t[1] : "", raw: line))
        case "allow":
            guard t.count >= 3 else { warnRule("allow names no values", line); continue }
            guard ALLOW_EFFECTS.contains(t[1]) else {
                warnRule("allow supports only Net hosts / Exec commands / Fs paths / Db tables", line); continue
            }
            var scope = ""; var vi = 2
            if t[2] == "in" { scope = t.count > 3 ? t[3] : ""; vi = 4 }
            let values = Array(t.dropFirst(vi))
            if values.isEmpty { warnRule("allow names no values", line); continue }
            allow.append(AllowRule(effect: t[1], scope: scope, values: values.sorted(), raw: line))
        case "forbid":
            let a = t.count > 1 ? t[1] : "", arrow = t.count > 2 ? t[2] : "", b = t.count > 3 ? t[3] : ""
            if a.isEmpty || arrow != "->" || b.isEmpty { warnRule("want `forbid <scope> -> <scope>`", line); continue }
            forbid.append(ForbidRule(from: a, to: b, raw: line))
        default:
            warnRule("unknown rule kind", line)
        }
    }
    return (deny, allow, forbid)
}

/// §6.2 scope match: segment run over ".", last segment a prefix.
func scopeMatches(_ name: String, _ scope: String) -> Bool {
    if scope.isEmpty { return true }
    let segs = name.split(separator: ".").map(String.init)
    let parts = scope.split(separator: ".").map(String.init)
    if parts.isEmpty || parts.count > segs.count { return false }
    let last = parts[parts.count - 1], initParts = parts.dropLast()
    outer: for i in 0...(segs.count - parts.count) {
        for (k, ip) in initParts.enumerated() where segs[i + k] != ip { continue outer }
        if segs[i + parts.count - 1].hasPrefix(last) { return true }
    }
    return false
}

func cmdBase(_ c: String) -> String { c.split(separator: "/").last.map(String.init) ?? c }
func pathCovered(_ allowed: String, _ reached: String) -> Bool {
    if reached.contains("..") { return false }
    if allowed == reached { return true }
    let a = allowed.hasSuffix("/") ? allowed : allowed + "/"
    return reached.hasPrefix(a)
}
func dbTableCovered(_ allowed: String, _ reached: String) -> Bool {
    let a = allowed.lowercased(), r = reached.lowercased()
    if a.hasSuffix(".*") { return r.hasPrefix(String(a.dropLast(2)) + ".") }
    return a == r
}
func literalAllowed(_ effect: String, _ reached: String, _ values: [String]) -> Bool {
    switch effect {
    case "Net": return values.contains { hostPart($0) == hostPart(reached) }
    case "Exec": return values.contains { cmdBase($0) == cmdBase(reached) }
    case "Fs": return values.contains { pathCovered($0, reached) }
    case "Db": return values.contains { dbTableCovered($0, reached) }
    default: return false
    }
}

if let pp = policyPath {
    guard let text = try? String(contentsOfFile: pp, encoding: .utf8) else {
        FileHandle.standardError.write("candor-swift: policy \(pp) could not be read; gate NOT enforced\n".data(using: .utf8)!)
        exit(2)
    }
    let pol = parsePolicy(text)
    var violations: [String] = []
    for qual in inferred.keys.sorted() {
        let inf = inferred[qual] ?? []
        if inf.isEmpty { continue }
        for r in pol.deny where scopeMatches(qual, r.scope) {
            let hits = r.effects.isEmpty ? inf.sorted() : inf.sorted().filter { r.effects.contains($0) }
            if !hits.isEmpty {
                violations.append("[AS-EFF-006] `\(qual)` performs { \(hits.joined(separator: ", ")) }, forbidden by policy: `\(r.raw)`")
            }
        }
        for r in pol.allow where scopeMatches(qual, r.scope) && inf.contains(r.effect) {
            let surface: Set<String>
            switch r.effect {
            case "Net": surface = hostsAcc[qual] ?? []
            case "Exec": surface = cmdsAcc[qual] ?? []
            case "Db": surface = tablesAcc[qual] ?? []
            default: surface = pathsAcc[qual] ?? []
            }
            if surface.isEmpty {
                violations.append("[AS-EFF-008] `\(qual)` performs \(r.effect) with no visible literal — the surface cannot be certified: `\(r.raw)`")
            } else {
                let bad = surface.filter { !literalAllowed(r.effect, $0, r.values) }.sorted()
                if !bad.isEmpty {
                    violations.append("[AS-EFF-008] `\(qual)` reaches { \(bad.joined(separator: ", ")) } outside the allowlist: `\(r.raw)`")
                }
            }
        }
    }
    for r in pol.forbid {
        for fn in cg.keys.sorted() where scopeMatches(fn, r.from) {
            var seen: Set<String> = [fn], stack = cg[fn] ?? []
            while let cur = stack.popLast() {
                if !seen.insert(cur).inserted { continue }
                if scopeMatches(cur, r.to) {
                    violations.append("[AS-EFF-009] `\(fn)` (scope `\(r.from)`) transitively reaches `\(cur)` in forbidden scope `\(r.to)`: `\(r.raw)`")
                    break
                }
                stack.append(contentsOf: cg[cur] ?? [])
            }
        }
    }
    for v in violations { print(v) }
    if violations.isEmpty {
        FileHandle.standardError.write("candor-swift: policy ✓\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("candor-swift: \(violations.count) policy violation(s)\n".data(using: .utf8)!)
        exit(1)
    }
}
