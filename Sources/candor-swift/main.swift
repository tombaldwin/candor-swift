// candor-swift — the Swift implementation of candor-spec 0.7.
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

let engineVersion = "candor-swift-0.7.5"
// The bare release semver (`0.5.0`) — the ONE source of truth for both the envelope's build id above
// and `--version`, derived by stripping the engine prefix so the two can't drift.
let releaseVersion = engineVersion.replacingOccurrences(of: "candor-swift-", with: "")
// The spec contract version this engine speaks — the SAME literal that stamps the §2 envelope's `spec`
// field (see the envelope below), reused so `--version` and the report can never disagree.
let specVersion = "0.7"

var target = "."
var outPrefix: String? = nil
var wantJson = false
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
    case "--json":
        // Print the §2 envelope to STDOUT instead of writing the report file(s)/sidecars (matching the
        // candor-scan reference). The §6.2 policy gate below STILL runs and keeps its exit codes —
        // `--json --policy p` prints the report AND exits 1 on a violation.
        wantJson = true
    case "--policy":
        guard let v = argIter.next(), !v.hasPrefix("-") else {
            FileHandle.standardError.write("candor-swift: --policy requires a value\n".data(using: .utf8)!); exit(2)
        }
        policyPath = v
    case "-h", "--help":
        print("""
        candor-swift \(releaseVersion) — Swift effect scanner (candor-spec \(specVersion))

        USAGE: candor-swift [<dir|file.swift>] [--out <prefix>] [--json] [--policy <file>] [--agents] [--version]

          <target>          a dir or a single .swift file to scan (default: .)
          --out <prefix>    write the report to <prefix>.<package>.Swift.json + a .callgraph.json sidecar
          --json            print the report as JSON to stdout (instead of writing files)
          --policy <file>   enforce a policy file (deny/pure/allow/forbid, candor-spec §6.2) — exit 1 on a violation, 2 if unreadable; honours $CANDOR_POLICY when the flag is absent
          --agents          print the agent contract for this build (AGENTS.md)
          -V, --version     print the build and spec version (offline)
          -h, --help        show this help

        See https://github.com/tombaldwin/candor
        """)
        exit(0)
    case "--version", "-V":
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
    var fnValueAlias: [String: String] = [:] // INFERRED-type fn-value locals bound to a NAMED local fn
                                            // (`let g = eff`): invoking `g()` edges to `eff` (the real
                                            // unit — more precise than Unknown). The README §4 contract
                                            // ("a function-typed value invoked reads Unknown — never silent
                                            // purity") held only WITH an explicit annotation; an inferred
                                            // `let g = eff` fell through untracked and read silent-pure.
    var protoTyped: [String: String]        // param -> local protocol
    var arrayElem: [String: String]         // name -> element type of a `[T]` local/param (loop typing)
    var dictElem: [String: String]          // name -> VALUE type of a `[K: V]` local/param (dict loops)
    var tupleElem: [String: [String: String]]  // name -> tuple element types (`p.0` / `p.c`)
    let fields: [String: [String: (name: String?, isFunction: Bool)]]
    let fieldArrayElem: [String: [String: String]]  // Type -> field -> [T] element (self.field loops)
    let fieldDictValue: [String: [String: String]]  // Type -> field -> [K: V] value
    let localTypes: Set<String>
    let declaredTypes: Set<String>  // types with a REAL local definition (NOT extension-only) — the shadow
                                    // discipline keys on this so a member call on an extension-only κ-platform
                                    // type (`self.launch()` in `extension Process`) reaches the κ table.
    let localFreeFns: Set<String>   // local free-function names — a bare `name(...)` call to one is the
                                    // project's OWN fn, so the platform free-call classifier (kappaFree)
                                    // must NOT fire (else a local `func NSLog`/`Pipe`-ctor fabricates)
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
    // Effects whose literal SURFACE is structurally incomplete (a host-establishing Net call with no
    // captured host — the masking guard; see isNetEstablishingMember). Propagated transitively; an
    // allowlisted-effect gate fails CLOSED on an incomplete surface (AS-EFF-008).
    var incompleteSurfaces: Set<String> = []
    var protoDispatches: [(proto: String, member: String)] = []
    var protoPropReads: [(proto: String, member: String)] = []  // protocol PROPERTY/subscript reads — CHA
    var globalReads: Set<String> = []     // bare-name reads — candidate edges to GLOBAL initializer units
    var boundLocals: Set<String> = []     // EVERY local binding name (even literal/unresolved-type ones,
                                          // which `vars` drops) — so a bare read / fn-ref of a SHADOWING
                                          // local isn't mistaken for an implicit-self property or a free fn
    var localFuncs: Set<String> = []      // NESTED `func` names declared in this unit's body. Their bodies
                                          // attribute lexically (DeclCollector skips them; we walk them here),
                                          // so a bare `helper()` call to a local func must NOT also edge to a
                                          // SAME-NAMED module-level/sibling free fn — that fabricates the
                                          // free fn's effects onto a caller whose local `helper` shadows it.
    var propertyEdges: Set<String> = []   // `Type.member` candidates from property READS
    var callbackInvoked: Set<String> = [] // fn-typed params INVOKED — deferred to callback-flow
    let dynamicMemberTypes: Set<String>   // `@dynamicMemberLookup` types — dynamic access is Unknown
    let propertyWrapperTypes: Set<String> // `@propertyWrapper` types — confirm a wrapped-property edge
    let wrappedProps: [String: [String: String]]  // Type -> property -> wrapper type (`S.count -> Logged`)
    let typeAliases: [String: String]     // `typealias Proc = Process` — name -> underlying simple type
    // FINDING 1 — opaque/erased iterable builders. `opaqueSeqBuilders` = leaf names whose declared return is
    // `some Sequence`/`AnySequence` with NO resolvable concrete local type (iterating the result is Unknown);
    // `seqBuilderConcrete` = leaf -> the CONCRETE LOCAL iterable type its body returns (iterating edges to
    // that type's `next`/`makeIterator` — precise). Built in the driver after the global localTypes set.
    let opaqueSeqBuilders: Set<String>
    let seqBuilderConcrete: [String: String]
    let closureFields: [String: Set<String>]   // FINDING 2 — Type -> stored closure-property names (own unit)

    init(info: FnInfo, fields: [String: [String: (name: String?, isFunction: Bool)]], localTypes: Set<String>,
         declaredTypes: Set<String>,
         localProtocols: Set<String>, returns: [String: String],
         fieldArrayElem: [String: [String: String]], fieldDictValue: [String: [String: String]],
         enumCaseValueType: [String: String], dynamicMemberTypes: Set<String>,
         propertyWrapperTypes: Set<String>, wrappedProps: [String: [String: String]],
         localFreeFns: Set<String>, typeAliases: [String: String],
         opaqueSeqBuilders: Set<String>, seqBuilderConcrete: [String: String],
         closureFields: [String: Set<String>]) {
        self.opaqueSeqBuilders = opaqueSeqBuilders
        self.seqBuilderConcrete = seqBuilderConcrete
        self.closureFields = closureFields
        self.typeAliases = typeAliases
        self.localFreeFns = localFreeFns
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
        self.declaredTypes = declaredTypes
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

    /// Resolve a type spelling through LOCAL typealiases (`Proc` → `Process`), bounded against a cycle.
    /// A LOCAL type shadows an alias of the same name (the never-fabricate discipline: the project's own
    /// type wins, exactly as the κ shadow rules do). A non-alias name returns unchanged.
    private func dealias(_ name: String) -> String {
        var n = name, hops = 0
        while !localTypes.contains(n), let u = typeAliases[n], u != n, hops < 16 { n = u; hops += 1 }
        return n
    }

    /// The dotted TYPE-PATH spelled by a member-access chain of plain identifiers — `Outer.Inner` →
    /// "Outer.Inner". Returns nil if any link is not a bare identifier (a value receiver, a call, a
    /// subscript) — so only a genuine nested-type reference (`Outer.Inner()`) resolves, never a value
    /// chain (`obj.field`). Used to recognise a nested-type constructor whose callee is a MemberAccess.
    private func dottedTypePath(_ node: Syntax) -> String? {
        if let dr = node.as(DeclReferenceExprSyntax.self) { return dr.baseName.text }
        if let ma = node.as(MemberAccessExprSyntax.self), let base = ma.base,
           let head = dottedTypePath(Syntax(base)) {
            return "\(head).\(ma.declName.baseName.text)"
        }
        return nil
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
            // a bare TYPE/alias reference (`FM.default`, the base of a static-member chain): resolve a
            // typealias to its underlying type so κ keys on the real spelling (`FM`→`FileManager`).
            return (dealias(n), false, [n])
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
                // `Proc()` where `typealias Proc = Process` — the ctor types the value as the aliased
                // type so its members classify (`p.run()`→Exec). A LOCAL type shadows (dealias no-ops).
                if n.first?.isUppercase == true { return (dealias(n), true, [n]) }
                if let rt = returns[n] { return (rt, true, [n]) }
            }
            // `Outer.Inner()` — a NESTED-TYPE constructor: the callee is a member-access spelling a dotted
            // TYPE path (`Outer.Inner`), not a factory member. When that dotted path is a known local type,
            // the value carries it so its methods resolve (`let i = Outer.Inner(); i.wipe()` → Fs). Checked
            // BEFORE the factory-return path so a nested ctor isn't mistaken for a `.member`-named factory.
            if let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
               let dotted = dottedTypePath(Syntax(ma)), localTypes.contains(dealias(dotted)) {
                return (dealias(dotted), true, [ma.declName.baseName.text])
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
        guard member == "write", let first = node.arguments.first else { return false }
        // `write(toFile: path, …)` (the path-STRING overload of Data/String/NSData) is UNAMBIGUOUSLY a
        // file write — there is no TextOutputStream variant for it, so no inout guard needed.
        if first.label?.text == "toFile" { return true }
        // `write(to: url)` — Fs, unless the destination is an inout TextOutputStream (the in-memory sink).
        return first.label?.text == "to" && !Self.peel(first.expression).is(InOutExprSyntax.self)
    }

    /// A Foundation `Data`-PRODUCING call: `<encoder>.encode(_:)` (JSON/PropertyList/…) or
    /// `<string>.data(using:)`. Such a value is `Data`, so `.write(to:)` on it is a real file write — but
    /// rootOf types the chain by its ROOT (the encoder / the string), missing the Data result, so
    /// `JSONEncoder().encode(...).write(to:)` and `s.data(using:.utf8).write(to:)` read silent-pure (a
    /// real-world dogfood vein). Used at the write site AND when typing a `let` bound to such a call.
    private func producesFoundationData(_ raw: ExprSyntax?) -> Bool {
        guard let raw = raw,
              let call = Self.peel(raw).as(FunctionCallExprSyntax.self),
              let ma = call.calledExpression.as(MemberAccessExprSyntax.self) else { return false }
        let m = ma.declName.baseName.text
        // `.encode(_:)` (unlabeled first arg) is the Data-returning encoder method; `.encode(to:)` is the
        // Encodable witness (returns Void) and must NOT match — gate on the absent label.
        if m == "encode", call.arguments.first?.label == nil { return true }
        if m == "data", call.arguments.first?.label?.text == "using" { return true }  // String.data(using:) -> Data
        return false
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

    // The static string literal of the argument whose label is in `labels` (the empty string "" matches
    // the first UNLABELED positional arg — `replaceItemAt`'s source). Same pure-segment discipline as
    // firstStringLiteral: an interpolated/computed value yields nil (no literal claim). Returns nil if
    // no matching arg or it is not a plain literal.
    private func literalForLabel(_ args: LabeledExprListSyntax, _ labels: Set<String>) -> String? {
        for a in args {
            let lab = a.label?.text ?? ""
            guard labels.contains(lab) else { continue }
            guard let lit = a.expression.as(StringLiteralExprSyntax.self) else { return nil }
            var out = ""
            for seg in lit.segments {
                if let plain = seg.as(StringSegmentSyntax.self) { out += plain.content.text } else { return nil }
            }
            return decodeEscapes(out)
        }
        return nil
    }

    // The integer-literal value of a labeled arg (`port: 8080` → "8080"), for folding a separate port
    // argument into the host:port surface — NWConnection(host:"…", port: 8080) and similar two-arg Net APIs.
    private func intLiteralForLabel(_ args: LabeledExprListSyntax, _ label: String) -> String? {
        for a in args where (a.label?.text ?? "") == label {
            if let lit = a.expression.as(IntegerLiteralExprSyntax.self) { return lit.literal.text }
        }
        return nil
    }

    // A two-path Fs op (copyItem/moveItem/createSymbolicLink/…): inspect EVERY required path locator, not
    // just the first. Capture each locator's literal as an Fs surface, and report Fs INCOMPLETE if ANY
    // locator is non-literal — so a literal source can't MASK a runtime destination (the two-path gate
    // evasion). Returns true if `member` is a two-path op (handled here), false to fall back to the
    // single-locator path. Mutates paths/incompleteSurfaces directly.
    private func recordTwoPathFs(member: String, _ args: LabeledExprListSyntax) -> Bool {
        guard let locators = FS_TWO_PATH_MEMBERS[member] else { return false }
        var anyMissing = false
        for spelling in locators {
            if let lit = literalForLabel(args, spelling) {
                if lit.contains("/") || lit.hasPrefix(".") || lit.hasPrefix("~") { paths.insert(lit) }
            } else {
                anyMissing = true  // this required locator is runtime-built (or absent) → invisible
            }
        }
        if anyMissing { incompleteSurfaces.insert("Fs") }
        return true
    }

    private func recordSurfaces(effect: String, lit: String?, args: LabeledExprListSyntax? = nil) {
        guard let lit else { return }
        switch effect {
        case "Net":
            var h = hostPort(lit)
            // Fold a SEPARATE integer port arg (NWConnection(host: "…", port: 8080)) into host:port, so the
            // surface reads like the URL-string forms the other engines see (conformance §2 [4e]). Skipped
            // when the host already carries a colon (an embedded port, or an IPv6 literal).
            if !h.contains(":"), let args, let p = intLiteralForLabel(args, "port") { h = "\(h):\(p)" }
            hosts.insert(h)
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
            // An EXPLICIT loop-var annotation (`for await x: Item in s`) names the element type directly —
            // honor it over the sequence's inferred element, so an unpinned/async sequence whose element
            // type candor can't infer still types the loop var (was ignored → `x.member()` silent-pure).
            if let ann = node.typeAnnotation, let tn = typeName(ann.type).name {
                vars[name] = tn
            } else if let elem = elementTypeOf(node.sequence) { vars[name] = elem } else { clearBinding(name) }
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
        if let t = r.root, r.isVar, localTypes.contains(t) {
            for m in ["makeIterator", "next"] {
                calls.append(Call(path: "\(t).\(m)", leaf: m, strArg: nil, typed: true, args: [], argTypes: []))
            }
            return
        }
        // FINDING 1 — iterating the RESULT of an opaque/erased Sequence builder (`for _ in b.build(…)` where
        // `build() -> some Sequence`). The opaque return hid the concrete iterator from rootOf (it peels to
        // the bare protocol name, not a local type), so the loop read silent-pure. Identify the builder by
        // its callee leaf: if its body returns a CONCRETE LOCAL iterable, edge to that type's next/makeIterator
        // (precise); otherwise the concrete iterator is genuinely unknowable → honest Unknown, never pure.
        let peeled = Self.peel(sequence)
        guard let call = peeled.as(FunctionCallExprSyntax.self) else { return }
        // Resolve the builder's KEY (`Type.method`, or a bare free-fn name) — the same simple-qual key the
        // DeclCollector recorded — so a same-named builder on another type never cross-resolves.
        var key: String? = nil
        if let ma = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let leaf = ma.declName.baseName.text
            if let base = ma.base {
                let recv = rootOf(base)
                if let rt = recv.root { key = "\(rt).\(leaf)" }   // `b.build(…)` → Builder.build
            } else if let et = enclosingType {
                key = "\(et).\(leaf)"   // implicit-self `.build(…)` (rare in a for-in head)
            }
        } else if let dr = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let leaf = dr.baseName.text
            // a bare `build(…)` is a self-sibling method (key on the enclosing type) OR a free fn (bare leaf).
            // Try the enclosing-type key first; fall back to the bare free-fn key.
            if let et = enclosingType, (seqBuilderConcrete["\(et).\(leaf)"] != nil || opaqueSeqBuilders.contains("\(et).\(leaf)")) {
                key = "\(et).\(leaf)"
            } else { key = leaf }
        }
        guard let key else { return }
        if let concrete = seqBuilderConcrete[key] {
            for m in ["makeIterator", "next"] {
                calls.append(Call(path: "\(concrete).\(m)", leaf: m, strArg: nil, typed: true, args: [], argTypes: []))
            }
        } else if opaqueSeqBuilders.contains(key) {
            unresolved = true
            why.insert("callback:opaque-sequence:\(key)") // opaque iteration (makeIterator/next on an unresolved iterator) — owner-less, ≈ opaque callback; canonical `callback:` (SPEC §4 ⟨0.7⟩)
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
        // VECTOR 2 — `String(describing: x)` / `String(reflecting: x)` and `print(x)` / `debugPrint(x)`
        // stringify their operands through `description` / `debugDescription`. Edge each LOCAL-typed
        // operand to its witness; an Int/String/external/unresolvable operand edges nothing (stays pure).
        modelStringificationCall(node)
        // VECTOR 2b — the WRITER side: `print(x, to: &s)` / `value.write(to: &s)` drive the destination
        // stream's `TextOutputStream.write`. modelStringificationCall edges the arg-side `description`;
        // this edges the writer's `write` (the cross-engine write!/fmt::Write blind spot — silent in the
        // rust deep/scan engines too, fixed there).
        modelOutputStreamCall(node)
        // VECTOR 4 — `coll.sorted()` / `.max()` / `.min()` over a local element type runs its `<`.
        edgeComparableWitness(node)
        // A LOCAL function/method passed BY REFERENCE as an argument (`xs.map(loadFree)`,
        // `xs.map(self.load)`) may be INVOKED by the callee, so its effects are reachable here. The
        // precise callback-flow only resolves a LOCAL callee's invoked params; a non-local HOF (map/
        // forEach/sorted) dropped the reference → silent-pure. Edge to the referenced unit (the Rust/TS
        // engines' fn-as-value posture). A plain value identifier resolves to no unique fn unit (or is a
        // local var/param, skipped) → dropped, never fabricated.
        for arg in node.arguments {
            let e = Self.peel(arg.expression)
            if let dr = e.as(DeclReferenceExprSyntax.self) {
                let n = dr.baseName.text
                // skip a bound LOCAL (a value, not a free-fn reference) — `vars` drops literal-typed
                // locals, so `boundLocals` guards them too, else passing such a local fabricates a
                // same-named free fn's effect.
                if vars[n] == nil && !fnTyped.contains(n) && !boundLocals.contains(n) {
                    // FINDING 2 — `xs.map(transform)` where `transform` is a stored CLOSURE PROPERTY of the
                    // enclosing type: passing it as a fn-ref to a HOF that invokes it reaches the closure's
                    // effects. Edge to the property-scoped unit `<Type>.transform` (its own collected unit).
                    // Implicit-self property, so it's NOT a free-fn ref — guard before the free-call emit.
                    if let et = enclosingType, closureFields[et]?.contains(n) == true {
                        propertyEdges.insert("\(et).\(n)")
                    } else if let et = enclosingType, let f = fields[et]?[n], f.isFunction {
                        // a function-typed FIELD passed by ref that is NOT a resolvable local closure
                        // (assigned in init / no initializer) — the invoked value is unaddressable → Unknown.
                        unresolved = true; why.insert("dispatch:\(et).\(n)")
                    } else {
                        calls.append(Call(path: n, leaf: n, strArg: nil, typed: false, unqualified: true))
                    }
                }
            } else if let ma = e.as(MemberAccessExprSyntax.self), let base = ma.base {
                let recv = rootOf(base)
                let m = ma.declName.baseName.text
                if let rt = recv.root, closureFields[rt]?.contains(m) == true {
                    // `xs.map(obj.transform)` — an explicit closure-property ref on a local receiver.
                    propertyEdges.insert("\(rt).\(m)")
                } else if let rt = recv.root, let f = fields[rt]?[m], f.isFunction {
                    // a non-closure function-typed field passed by ref → unaddressable invocation → Unknown.
                    unresolved = true; why.insert("dispatch:\(rt).\(m)")
                } else if let rt = recv.root, localTypes.contains(rt) {
                    calls.append(Call(path: "\(rt).\(m)", leaf: m, strArg: nil, typed: true))
                }
            }
        }
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
                if lit == nil { incompleteSurfaces.insert("Fs") }  // path is the arg → invisible if not literal (masking)
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
            } else if let target = fnValueAlias[name] {
                // an INFERRED-type fn-value local invoked (`let g = eff; g()`): edge to the aliased local
                // fn (the real unit). Emit as an unqualified free-call so the fixpoint resolver links it to
                // `eff` via freeFnByName (unique by construction — only known-fn names enter fnValueAlias).
                calls.append(Call(path: target, leaf: target, strArg: lit, typed: false,
                                  args: argKinds(node), argTypes: argTypesOf(node), unqualified: true))
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
            } else if let et = enclosingType, !boundLocals.contains(name), closureFields[et]?.contains(name) == true {
                // FINDING 2 — a bare `f(0)` invoking a stored CLOSURE PROPERTY of the enclosing type
                // (`self.f` implicit): the closure body runs. Edge to its property-scoped unit `<Type>.f` so
                // the closure's effects are reached (was silent-pure — the deferred/direct closure-property
                // hole). Guarded against a shadowing local `f` (boundLocals), which is a different value.
                propertyEdges.insert("\(et).\(name)")
            } else if let et = enclosingType, !boundLocals.contains(name),
                      let f = fields[et]?[name], f.isFunction {
                // a bare invocation of a function-typed FIELD that is NOT a resolvable local closure
                // (assigned in init / no initializer) — the value is unaddressable → honest Unknown.
                unresolved = true
                why.insert("dispatch:\(et).\(name)")
            } else if let t = vars[name], localTypes.contains(t) {
                // `f()` where `f` is an INSTANCE of a local type — a `callAsFunction` invocation (Swift
                // desugars `f(args)` on a non-function value to `f.callAsFunction(args)`). Edge to the
                // type's callAsFunction unit (if it has one; resolveQual drops the edge otherwise).
                calls.append(Call(path: "\(t).callAsFunction", leaf: "callAsFunction", strArg: lit, typed: true, args: argKinds(node), argTypes: argTypesOf(node)))
            } else if let et = enclosingType, !boundLocals.contains(name), !localFreeFns.contains(name),
                      !declaredTypes.contains(et), let eff = kappaMember(root: et, member: name) {
                // an IMPLICIT-self member call inside an `extension <κ-platform-type>`: `launch()` inside
                // `extension Process` is `self.launch()` → Exec (the ShellOut `launchBash` cardinal-sin: it
                // read silent-pure). Mirrors the explicit-self path (line ~1417). Only fires when the
                // enclosing type is NOT declared locally (an extension of the real platform type) and the κ
                // table knows the member — a declared type shadows κ, a local free fn / shadowing local wins.
                directEffects.insert(eff)
                recordSurfaces(effect: eff, lit: lit, args: node.arguments)
                if lit == nil, isEstablishingMember(effect: eff, root: et, member: name) { incompleteSurfaces.insert(eff) }
            } else if !localTypes.contains(name), !localFreeFns.contains(name),
                      let eff = kappaFree(name: dealias(name), argCount: node.arguments.count) {
                // A LOCALLY-declared type ctor (`Pipe()` where `class Pipe`) or free fn (`NSLog(...)` where
                // `func NSLog`) ALWAYS shadows the platform free-call table — else a project's own
                // `Pipe`/`NSDate`/`NSLog`/`CACurrentMediaTime` fabricates Ipc/Clock/Log (the cardinal sin;
                // the same shadow discipline the member-call path applies via `localTypes`). When shadowed
                // it falls through to the unqualified Call below, which resolves to the local def.
                // `dealias(name)` resolves a typealias-named ctor (`Proc()`→`Process`→Exec) before κ; a
                // local type/free fn already short-circuited above, so an alias never overrides the project.
                let aliasName = dealias(name)
                directEffects.insert(eff)
                recordSurfaces(effect: eff, lit: lit, args: node.arguments)
                if lit == nil, isEstablishingFree(effect: eff, name: aliasName) { incompleteSurfaces.insert(eff) }
            } else {
                calls.append(Call(path: name, leaf: name, strArg: lit, typed: false, args: argKinds(node), argTypes: argTypesOf(node), unqualified: true))
            }
        } else if let ma = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let member = ma.declName.baseName.text
            let base = ma.base.map { rootOf($0) } ?? (root: nil, isVar: false, path: [])
            // a function-typed FIELD invoked (`d.f()` where f: () -> Void) — the unknown_dyn case
            if let rt = base.root, let f = fields[rt]?[member], f.isFunction {
                // FINDING 2 — `obj.f()` where `f` is a stored CLOSURE PROPERTY (a resolvable local closure
                // unit `<Type>.f`): edge to that unit (its closure's effects), precise instead of Unknown.
                // A function-typed field WITHOUT a closure unit (assigned in init / no init) stays Unknown.
                if closureFields[rt]?.contains(member) == true {
                    propertyEdges.insert("\(rt).\(member)")
                } else {
                    unresolved = true
                    why.insert("dispatch:\(rt).\(member)")
                }
            } else if let pr = ma.base?.as(DeclReferenceExprSyntax.self), protoTyped[pr.baseName.text] != nil {
                // dispatch through a LOCAL protocol-typed param — bounded CHA or honest Unknown
                protoDispatches.append((protoTyped[pr.baseName.text]!, member))
            } else if let rt = base.root, localTypes.contains(rt),
                      // An extension-ONLY κ-platform type does NOT shadow: `self.launch()` inside
                      // `extension Process` is a real Exec, not a project method (the ShellOut cardinal-sin —
                      // it read silent-pure). Only a DECLARED type (or a κ-unknown extension target) takes
                      // the local-dispatch path; a declared type still shadows κ (the GRDB `bind` lesson).
                      // `isFileWrite` is the OTHER κ signal (file writes aren't kappaMembers): a project
                      // `extension Data {…}` must not shadow `data.write(to:)`→Fs (a real-world dogfood vein:
                      // SwiftLint has `extension Data`, which silently dropped every Data/String file write).
                      (declaredTypes.contains(rt)
                       || (kappaMember(root: rt, member: member) == nil && !isFileWrite(member: member, node))) {
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
            } else if ((base.root == "Data" || base.root == "String")
                       // a STRING-LITERAL receiver IS a String (`"data".write(toFile:…)`): rootOf can't type a
                       // literal (no var/decl), so the `Data`/`String` branch missed it and the file write read
                       // silent-pure. A literal base has the same write(toFile:)/write(to:) surface as a typed
                       // String, so classify it identically (isFileWrite's inout/label guard still excludes the
                       // pure TextOutputStream overloads — never fabricate).
                       || (ma.base.map { Self.peel($0).is(StringLiteralExprSyntax.self) } ?? false)
                       // an INLINE Data producer: `JSONEncoder().encode(...).write(to:)` — the value is Data
                       // (the chain root is the encoder, not Data), the dogfood "serialize-then-write" vein.
                       || producesFoundationData(ma.base)),
                      isFileWrite(member: member, node) {
                // Data/String file write (`d.write(to: url)`) → Fs; the pure in-memory/TextOutputStream
                // overloads are excluded by isFileWrite's inout/label guard (never fabricate).
                directEffects.insert("Fs")
                recordSurfaces(effect: "Fs", lit: lit)
                if lit == nil { incompleteSurfaces.insert("Fs") }  // write destination is the arg → invisible if not literal
            } else if let rt = base.root, let eff = kappaMember(root: rt, member: member) {
                directEffects.insert(eff)
                // A two-path Fs op (copyItem/moveItem/createSymbolicLink/…) carries a SOURCE *and* a
                // DESTINATION locator; the single-`lit` guard below captures only the first, so a literal
                // source would MASK a runtime destination (the two-path gate-evasion). Inspect EVERY
                // locator: capture all literals, mark Fs incomplete if any locator is non-literal.
                if eff == "Fs", rt == "FileManager", recordTwoPathFs(member: member, node.arguments) {
                    // handled — surfaces + incompleteness recorded per-locator
                } else {
                    recordSurfaces(effect: eff, lit: lit, args: node.arguments)
                    if lit == nil, isEstablishingMember(effect: eff, root: rt, member: member) { incompleteSurfaces.insert(eff) }
                }
            } else {
                calls.append(Call(path: member, leaf: member, strArg: lit, typed: false, args: argKinds(node), argTypes: argTypesOf(node)))
            }
        } else if node.calledExpression.is(ClosureExprSyntax.self) {
            // immediately-invoked closure: body walks lexically below — nothing to record
        } else {
            // computed callee (subscript, optional-chained value, …): §4 Unknown
            unresolved = true
            why.insert("callback:computed") // a computed/unresolved callee value (subscript, optional-chained, …) — owner-less unresolved invocation; canonical `callback:` (SPEC §4 ⟨0.7⟩)
        }
        return .visitChildren
    }

    // `guard let c = <expr>` / `if let c = <expr>` — type the unwrapped binding from the initializer
    // (a factory call, subscript, cast, …) so `c.method()` resolves. A shorthand `guard let c` (no
    // initializer) keeps the existing param/var type. The optional is stripped by typing the value.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
           let initVal = node.initializer?.value {
            // `guard let d = s.data(using:.utf8)` / `= enc.encode(x)` — the unwrapped value is Data, so a
            // later `d.write(to:)` is Fs (the via-optional-binding dogfood vein; matches the plain-`let` path).
            if producesFoundationData(initVal) { vars[name] = "Data" }
            else {
                let info = rootOf(initVal)
                if info.isVar, let t = info.root { vars[name] = t }
                else if let elem = elementTypeOf(initVal) { arrayElem[name] = elem }
                else { clearBinding(name) }  // can't type the unwrapped value → clear (don't leak a stale type)
            }
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
            if let root = recv.root, !declaredTypes.contains(root),
               // a REAL local type named like a platform clock/env owner (`struct ContinuousClock { let now }`)
               // shadows the κ table; an EXTENSION of a platform type (`extension ProcessInfo {…}`) does NOT
               // — it's in localTypes but not declaredTypes. Gate on declaredTypes (parity with the method
               // κ-path) so env/fs property reads aren't silently zeroed project-wide by such an extension
               // (the real-world dogfood vein: `extension ProcessInfo` nulled all Env detection).
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
        // IMPLICIT-SELF property read: a bare `token` inside a method of a type that DECLARES `token` as a
        // computed/lazy property is `self.token` — reading it RUNS the accessor. The MemberAccess visitor
        // only fires for the explicit `self.token`; a bare read routed solely to globalReads missed the
        // accessor unit (an effectful lazy/computed property came back pure). Edge to the enclosing type's
        // `<Type>.token` accessor unit — resolveQual drops it unless `token` is a real accessor unit on
        // THIS type (a plain stored field, or a name belonging to another type, resolves to nothing → no
        // fabrication), exactly as the explicit-self path does.
        // ...unless `n` is a LOCAL binding (a literal/arithmetic-bound `let n = …` that `vars` drops
        // because its type didn't resolve) — then the bare read is the local, NOT `self.n`; edging to the
        // enclosing type's `n` accessor would FABRICATE its effect (regression). boundLocals tracks these.
        if let et = enclosingType, !boundLocals.contains(n) { propertyEdges.insert("\(et).\(n)") }
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
            // a binary operator takes two args — supply two opaque arg slots so overloaded operator
            // resolution (arity ≥ 2) keeps the edge.
            let opArgs: [ArgKind] = [.opaque, .opaque], opTypes: [String?] = [lt.isVar ? lt.root : nil, rt.isVar ? rt.root : nil]
            var localOperand = false
            for cand in [lt.root, rt.root] {
                if let t = cand, lt.isVar || rt.isVar, localTypes.contains(t) {
                    calls.append(Call(path: "\(t).\(opName)", leaf: opName, strArg: nil, typed: true, args: opArgs, argTypes: opTypes))
                    localOperand = true; break
                }
            }
            // When an operand is a LOCAL-typed value, ALSO try the FREE operator overload: a custom
            // operator is most often a TOP-LEVEL `func + (a: V, b: V)` (a free fn named `+`), NOT a static
            // member `V.+` — so the typed edge above (member form) missed it and an effectful free operator
            // (`a + b`, `x += y`, a custom `<>`, a `log << msg` DSL) read silently PURE. Resolved by operand
            // TYPE via matchOverloads. GATED on a local operand: without it, `1 + 2` over the std Int `+`
            // would edge a same-named local `func +(V,V)` via the unique-free-fn path (which ignores arg
            // types) — a fabrication. With confident local operand types, matchOverloads discriminates.
            if localOperand {
                calls.append(Call(path: opName, leaf: opName, strArg: nil, typed: false, args: opArgs, argTypes: opTypes, unqualified: true))
            }
            i += 2
        }
        return .visitChildren
    }

    // PREFIX (`~>x`) / POSTFIX (`x<!>`) operator overloads — SwiftParser leaves these as their own
    // PrefixOperatorExpr / PostfixOperatorExpr nodes (NOT inside a SequenceExpr), so the binary-only
    // resolver above missed them and an effectful custom unary operator read silently PURE (sweep [35]).
    // Same posture as the binary case: resolve the single operand's LOCAL type, edge to `Type.<op>` and
    // (gated on a local operand, to avoid fabricating a same-named local op onto `-x`/`!x` over std types)
    // the FREE `<op>` overload, with one opaque arg so arity-1 overload resolution keeps the edge.
    override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        resolveUnaryOperator(node.operator.text, node.expression); return .visitChildren
    }
    override func visit(_ node: PostfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        resolveUnaryOperator(node.operator.text, node.expression); return .visitChildren
    }
    private func resolveUnaryOperator(_ opName: String, _ operand: ExprSyntax) {
        let ot = rootOf(operand)
        guard let t = ot.root, ot.isVar, localTypes.contains(t) else { return }  // std operand → no local op
        let opArgs: [ArgKind] = [.opaque], opTypes: [String?] = [t]
        calls.append(Call(path: "\(t).\(opName)", leaf: opName, strArg: nil, typed: true, args: opArgs, argTypes: opTypes))
        calls.append(Call(path: opName, leaf: opName, strArg: nil, typed: false, args: opArgs, argTypes: opTypes, unqualified: true))
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

    // KEY PATH to a property accessor (`\KP.heavy`, `obj[keyPath: \KP.heavy]`, `xs.map(\.heavy)`):
    // applying a key path READS the property — it runs its getter. No visitor saw `KeyPathExprSyntax`, so
    // an effectful getter reached via a key path was silent-pure. Resolve the path's TERMINAL property on
    // its root type and edge to that accessor unit. Explicit root (`\KP.heavy`) gives the type directly;
    // an implicit root (`\.heavy` as a `map`/`filter`/… argument) takes the receiver's ELEMENT type. A
    // non-local / unresolved root edges nothing (resolveQual drops it — no fabrication).
    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        guard let lastProp = node.components.last?.component
                .as(KeyPathPropertyComponentSyntax.self)?.declName.baseName.text else { return .visitChildren }
        var rootType: String? = node.root.flatMap { typeName($0).name }
        if rootType == nil {
            // implicit root: the key path is the argument of an element-iterator call `recv.map(\.prop)` —
            // its type is the receiver's element. Walk to the enclosing call and type from its receiver.
            var p: Syntax? = node.parent
            while let cur = p, !cur.is(FunctionCallExprSyntax.self) { p = cur.parent }
            if let call = p?.as(FunctionCallExprSyntax.self),
               let ma = call.calledExpression.as(MemberAccessExprSyntax.self), let base = ma.base {
                rootType = elementTypeOf(base)
            }
        }
        if let rt = rootType, localTypes.contains(rt) { propertyEdges.insert("\(rt).\(lastProp)") }
        return .visitChildren
    }

    // ── IMPLICIT-CONVERSION / COERCION edges ─────────────────────────────────────────────────────────
    // An effect reached through an IMPLICIT protocol-witness conversion (a `CustomStringConvertible`
    // `description`, an `ExpressibleBy*Literal` init, a `Comparable` `<`) is NEVER spelled at the call
    // site — yet it RUNS. A fn reported PURE while such a witness performs I/O is the cardinal sin.
    // GOVERNING RULE: resolve the OPERAND's TYPE to its LOCAL witness and edge ONLY when local; an
    // unresolvable-type operand gets NO edge (stays pure — never flood with Unknown); a PURE witness
    // contributes nothing (resolveQual finds the unit, propagation adds no effect). NEVER fabricate.

    /// The LOCAL type of an operand expression, or nil. Trusts ONLY a confidently-resolved value type
    /// (`rootOf(...).isVar`) that is a known LOCAL type — exactly the discipline the operator/KeyPath
    /// paths use. An Int/String/external-typed or unresolvable operand → nil → NO edge (stays pure).
    private func localTypeOfOperand(_ raw: ExprSyntax) -> String? {
        let r = rootOf(raw)
        guard r.isVar, let t = r.root, localTypes.contains(t) else { return nil }
        return t
    }

    /// Edge an interpolation/`String(describing:)`/`print` operand to its local type's stringification
    /// witness. `reflecting` picks `debugDescription` (the `CustomDebugStringConvertible` witness), else
    /// `description`. A property READ (the getter runs) — `propertyEdges`/resolveQual drop it when the
    /// type declares no such accessor unit (a stored property, or a synthesised/external witness) → no
    /// fabrication; a PURE `description` accessor contributes nothing.
    private func edgeStringWitness(_ operand: ExprSyntax, reflecting: Bool) {
        guard let t = localTypeOfOperand(operand) else { return }
        propertyEdges.insert("\(t).\(reflecting ? "debugDescription" : "description")")
    }

    /// The WRITER side of formatting: a destination stream passed as `to: &stream` to `print`/`debugPrint`/
    /// `dump` or to a `value.write(to:)` drives `<stream>.write` (the `TextOutputStream` conformance). The
    /// arg-side (`description`) is modeled by `modelStringificationCall`; the writer's effectful `write` was
    /// dropped — silent-pure (the cross-engine write!/fmt::Write writer-side blind spot; the rust deep and
    /// scan engines had it too). Edge to the stream's local `write` (resolve-or-skip: a std `String` sink or
    /// an unresolved operand edges nothing → no fabrication). Gated to the stream-output callees so an
    /// unrelated `f(x, to: &y)` is never mistaken for a stream write.
    private func modelOutputStreamCall(_ node: FunctionCallExprSyntax) {
        let leaf: String?
        if let dr = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            leaf = dr.baseName.text
        } else if let ma = node.calledExpression.as(MemberAccessExprSyntax.self) {
            leaf = ma.declName.baseName.text
        } else {
            leaf = nil
        }
        guard let leaf, ["print", "debugPrint", "dump", "write"].contains(leaf) else { return }
        // a project's OWN `print`/`debugPrint`/`dump` shadows the stdlib free fn — don't model.
        if leaf != "write", localFreeFns.contains(leaf) || localFuncs.contains(leaf) { return }
        for arg in node.arguments where arg.label?.text == "to" {
            guard let io = Self.peel(arg.expression).as(InOutExprSyntax.self) else { continue }
            guard let t = localTypeOfOperand(io.expression) else { continue }
            calls.append(Call(path: "\(t).write", leaf: "write", strArg: nil, typed: true))
        }
    }

    // VECTOR 1 — STRING INTERPOLATION `"row=\(w)"`. Each `\(expr)` segment implicitly invokes the
    // operand type's `description` (its `CustomStringConvertible` witness) — SwiftParser models the
    // segment as an ExpressionSegmentSyntax holding the operand. An operand of a LOCAL type edges to
    // `Type.description`; an Int/String/external/unresolvable operand edges nothing (stays pure). There
    // is no source spelling for `\(reflecting:)` interpolation, so interpolation only ever drives
    // `description` (debugDescription comes via `String(reflecting:)` / `debugPrint`, Vector 2).
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        for seg in node.segments {
            guard let expr = seg.as(ExpressionSegmentSyntax.self) else { continue }
            for arg in expr.expressions { edgeStringWitness(arg.expression, reflecting: false) }
        }
        return .visitChildren
    }

    // VECTOR 3 — `ExpressibleBy*Literal` init at a TYPE-ANNOTATED literal binding `let v: W = "lit"` /
    // `= 42` / `= [..]` / `= [k: v]`. The literal coerces through `W`'s `init(stringLiteral:)` /
    // `init(integerLiteral:)` / `init(arrayLiteral:)` / `init(dictionaryLiteral:)` — which RUNS. When
    // `W` is a LOCAL type, edge to `W.init` (a typed call; the driver routes it through arity/overload
    // resolution and drops it if `W` declares no init — synthesised/external → no fabrication; a PURE
    // init contributes nothing). The literal TYPE is supplied so a 1-arg overload matcher can route.
    private func edgeLiteralInit(annotation: TypeSyntax, value: ExprSyntax) {
        guard let t = typeName(annotation).name, localTypes.contains(dealias(t)) else { return }
        let lt = literalKind(Self.peel(value))
        guard lt != nil else { return }
        let ty = dealias(t)
        calls.append(Call(path: "\(ty).init", leaf: "init", strArg: nil, typed: true,
                          args: [.opaque], argTypes: [lt]))
    }
    /// The synthetic operand type of a coercible LITERAL expression (`"x"`→String, `42`→Int, …), or nil
    /// if the value is not a bare literal (a call/identifier is an ordinary init, not a literal coercion).
    private func literalKind(_ e: ExprSyntax) -> String? {
        if e.is(StringLiteralExprSyntax.self) { return "String" }
        if e.is(IntegerLiteralExprSyntax.self) { return "Int" }
        if e.is(FloatLiteralExprSyntax.self) { return "Double" }
        if e.is(BooleanLiteralExprSyntax.self) { return "Bool" }
        if e.is(ArrayExprSyntax.self) { return "Array" }
        if e.is(DictionaryExprSyntax.self) { return "Dictionary" }
        return nil
    }

    // VECTOR 4 — `Comparable` via `sorted()` / `max()` / `min()`. Ordering an array of a local type runs
    // that type's `<` (its `Comparable` witness, most often a `static func <`). `coll.sorted()` /
    // `.max()` / `.min()` (the NO-CLOSURE forms — a `(by:)` closure supplies its OWN comparator, charged
    // lexically) over a LOCAL element type edges to `Element.<`. A stdlib `[Int]`/`[String]` element has
    // no local `<` unit (resolveQual drops it) → stays pure. matchOverloads/resolveQual route the typed
    // `Element.<` call; a PURE `<` contributes nothing.
    private static let COMPARABLE_ORDERERS: Set<String> = ["sorted", "max", "min"]
    private func edgeComparableWitness(_ node: FunctionCallExprSyntax) {
        guard let ma = node.calledExpression.as(MemberAccessExprSyntax.self),
              Self.COMPARABLE_ORDERERS.contains(ma.declName.baseName.text), let base = ma.base else { return }
        // a `(by:)`/`(into:)` etc. closure form supplies its own comparator — no implicit `<` runs.
        if node.arguments.contains(where: { Self.peel($0.expression).is(ClosureExprSyntax.self) })
            || node.trailingClosure != nil { return }
        guard let elem = elementTypeOf(base), localTypes.contains(elem) else { return }
        // the `<` witness is EITHER a `static func <` member (`Element.<`) OR a top-level free
        // `func <(a: Element, b: Element)` — emit both forms, exactly as the binary-operator visitor does.
        // The free form is gated on a CONFIDENT local element type (argTypes), so matchOverloads routes by
        // type and never fabricates a same-named local `<` onto a stdlib `[Int].sorted()`.
        calls.append(Call(path: "\(elem).<", leaf: "<", strArg: nil, typed: true,
                          args: [.opaque, .opaque], argTypes: [elem, elem]))
        calls.append(Call(path: "<", leaf: "<", strArg: nil, typed: false,
                          args: [.opaque, .opaque], argTypes: [elem, elem], unqualified: true))
    }

    // VECTOR 2 — explicit stringification calls that run an operand's `description`/`debugDescription`:
    //   `String(describing: x)` / `String(reflecting: x)` — the `reflecting:` label picks debugDescription
    //   `print(x, …)` / `debugPrint(x, …)` — print uses description, debugPrint uses debugDescription
    // A `String(...)` call with neither label is an ordinary String init (not a coercion) → skipped. A
    // LOCAL-typed operand edges to its witness; an Int/String/external/unresolvable operand → no edge.
    // GUARD: `print`/`debugPrint` shadowed by a local fn of the same name is the project's own — skip.
    private func modelStringificationCall(_ node: FunctionCallExprSyntax) {
        guard let dr = node.calledExpression.as(DeclReferenceExprSyntax.self) else { return }
        let name = dr.baseName.text
        switch name {
        case "String":
            for arg in node.arguments {
                if arg.label?.text == "describing" { edgeStringWitness(arg.expression, reflecting: false) }
                else if arg.label?.text == "reflecting" { edgeStringWitness(arg.expression, reflecting: true) }
            }
        case "print", "debugPrint":
            // a project's OWN `func print`/`debugPrint` shadows the stdlib free fn — don't model coercion.
            if localFreeFns.contains(name) || localFuncs.contains(name) { return }
            let reflecting = name == "debugPrint"
            for arg in node.arguments where arg.label == nil {  // skip separator:/terminator:/to: trailing labels
                edgeStringWitness(arg.expression, reflecting: reflecting)
            }
        default: return
        }
    }

    // `let s = Svc()` / `let s: Svc = …` / `let f = { … }` — local bindings type later calls
    // A NESTED `func` declared in this unit's body. DeclCollector skips it (it mints no unit of its
    // own); its effects attribute LEXICALLY to this enclosing unit — so we KEEP WALKING the body
    // (`.visitChildren`) to fold them in. Record the name so a bare `helper()` call below resolves to
    // THIS local func (shadowing) and is NOT also edged to a same-named module-level/sibling free fn —
    // which would fabricate the free fn's effects onto a caller whose local `helper` shadows it.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        localFuncs.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            // `let (a, b) = (X(), Y())` — destructure: bind each name from the initializer tuple element
            if let tp = binding.pattern.as(TuplePatternSyntax.self),
               let tupleInit = binding.initializer?.value.as(TupleExprSyntax.self) {
                for (pe, ve) in zip(tp.elements, tupleInit.elements) {
                    guard let n = pe.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                    boundLocals.insert(n)
                    let info = rootOf(ve.expression)
                    if info.isVar, let t = info.root { vars[n] = t } else { clearBinding(n) }
                }
                continue
            }
            // VECTOR 3 — `let v: W = "lit"` / `let _: W = 42` / `= [..]`: a literal at a type-annotated
            // binding coerces through `W`'s `ExpressibleBy*Literal` init, which RUNS. Edge to `W.init` when
            // `W` is local + the value is a bare literal (a non-literal initializer is an ordinary init).
            // Runs BEFORE the name guard so a WILDCARD binding (`let _: W = "lit"`, common) is covered too.
            if let ann = binding.typeAnnotation, let v0 = binding.initializer?.value {
                edgeLiteralInit(annotation: ann.type, value: v0)
            }
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            boundLocals.insert(name)  // record the SHADOW (any local, even a literal-typed one `vars` drops)
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
                    // a Foundation Data producer (`let d = s.data(using:.utf8)` / `= enc.encode(x)`) types
                    // the local as Data, so a later `d.write(to:)` is Fs (the via-local dogfood vein).
                    if producesFoundationData(v0) { vars[name] = "Data" }
                    else {
                        // ctor or unambiguous factory — one resolver for both (rootOf handles peeling)
                        let info = rootOf(v)
                        if let t = info.root, info.isVar { vars[name] = t }
                        // a collection TRANSFORM result keeps the element type: `let active = cs.filter {…}`
                        // (then `for c in active` resolves). Element-preserving transforms only.
                        else if let elem = elementTypeOf(v0) { arrayElem[name] = elem }
                    }
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
                } else if let dr = v.as(DeclReferenceExprSyntax.self),
                          localFreeFns.contains(dr.baseName.text),
                          vars[dr.baseName.text] == nil, !boundLocals.contains(dr.baseName.text) {
                    // INFERRED-type FUNCTION VALUE: `let g = eff` where `eff` is a known local free fn (and
                    // NOT shadowed by a local var/binding of the same name). Without an explicit `: () -> Void`
                    // annotation this fell through untracked and `g()` read silent-pure — violating the README
                    // §4 contract that "a function-typed value invoked reads Unknown — never silent purity".
                    // Alias `g`→`eff` so invoking `g()` edges to the REAL unit (more precise than Unknown).
                    // Gated on the RHS being a known local FN name, so an ordinary value copy never fabricates.
                    fnValueAlias[name] = dr.baseName.text
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

/// The hostname part of a `host[:port]` literal — scheme and path stripped, then the trailing `:port`
/// dropped so `allow Net api.stripe.com` covers a reached `api.stripe.com:443` (SPEC §6.2: a Net host
/// matches by hostname with the port ignored). IPv6-aware, mirroring Rust's `host_part`: a bracketed
/// `[host]:port` yields the bracketed host, and a BARE IPv6 literal (>1 colon, no brackets) has no port
/// to strip and is returned whole — a naive first-colon split would collapse every `2001:db8::*` to
/// `2001`, accepting any address in that block. A hostname/IPv4 `host`/`host:port` (≤1 colon) splits at
/// the colon. Was a live cross-engine gate-verdict divergence: Swift kept the port, Rust/Java/TS didn't.
// The §2 host SURFACE value: scheme + path stripped, but the statically-known PORT KEPT
// (`https://api.example.com:8080/x` → `api.example.com:8080`) — the conformance suite's [4e] pins that
// the port is part of the surface, so it must NOT be dropped here.
func hostPort(_ s: String) -> String {
    var h = s
    for scheme in ["https://", "http://", "wss://", "ws://", "tcp://"] where h.hasPrefix(scheme) {
        h = String(h.dropFirst(scheme.count))
    }
    if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
    return h
}

// `hostPort` with the :port ALSO stripped — for port-INSENSITIVE policy matching (spec §6.2: a Net host
// matches by hostname with the port ignored, `api.stripe.com` allows `api.stripe.com:443`). Used only at
// match time (both the allow value and the reached surface are stripped), never on the stored surface.
func hostPart(_ s: String) -> String {
    let h = hostPort(s)
    if h.hasPrefix("[") {
        // `[ipv6]` or `[ipv6]:port` — the host is between the brackets.
        let inner = String(h.dropFirst())
        if let close = inner.firstIndex(of: "]") { return String(inner[..<close]) }
        return inner
    }
    if h.filter({ $0 == ":" }).count > 1 { return h }  // bare IPv6 literal — no port suffix to strip
    if let colon = h.firstIndex(of: ":") { return String(h[..<colon]) }
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
var declaredTypes: Set<String> = []
var typeAliases: [String: String] = [:]
var dynamicMemberTypes: Set<String> = []
var propertyWrapperTypes: Set<String> = []
var wrappedProps: [String: [String: String]] = [:]
var returnsIdx: [String: String] = [:]
var importCounts: [String: Int] = [:]
var fileImports: [String: [String]] = [:]   // file (rel path) -> modules it imports (per-fn blind disclosure)
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
// FINDING 1 — aggregate the opaque/erased Sequence builder indexes across files.
var opaqueSeqLeaves: Set<String> = []
var seqConcreteTmp: [String: String?] = [:]
var closureFields: [String: Set<String>] = [:]   // FINDING 2 — Type -> closure-property names (own unit)
for c in collectors {
    opaqueSeqLeaves.formUnion(c.opaqueSeqLeaves)
    for (k, v) in c.seqConcreteRetTmp {
        if let existing = seqConcreteTmp[k] {
            if existing != v { seqConcreteTmp[k] = String?.none }   // ambiguous across files — never guess
        } else { seqConcreteTmp[k] = v }
    }
    for (t, ps) in c.closureFields { closureFields[t, default: []].formUnion(ps) }
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
    declaredTypes.formUnion(c.declaredTypes)
    for (a, u) in c.typeAliases { typeAliases[a] = u }   // last-writer-wins (a redeclared alias is rare)
    dynamicMemberTypes.formUnion(c.dynamicMemberTypes)
    propertyWrapperTypes.formUnion(c.propertyWrapperTypes)
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
// INVERSE: type -> its (transitive) supertypes — the protocols it conforms to and classes it extends.
// Used to resolve a PROTOCOL-EXTENSION DEFAULT method reached via a CONCRETE receiver (`j.emit()` where
// `j: Job`, Job: Logging, and Logging's extension defaults `emit`): Job declares no `emit`, so the typed
// `Job.emit` doesn't resolve and the call read pure — fall back to the default body on a conformed super.
var supertypesOf: [String: Set<String>] = [:]
for (sup, subs) in subtypesOf { for s in subs { supertypesOf[s, default: []].insert(sup) } }
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
var incompleteD: [String: Set<String>] = [:]   // fn -> effects with a structurally-incomplete surface (masking)
var blindDirect: [String: Set<String>] = [:]    // fn -> blind modules it DIRECTLY reaches (per-fn `invisible`)
// The κ-unknown modules this code imports (the ledger's set, hoisted for per-fn `invisible` attribution):
// not a platform-frontier module, not a κ tier, not an internal target — effects through them are INVISIBLE.
let blindModules = Set(importCounts.keys.filter {
    !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0) && !internalModules.contains($0) })
var locOf: [String: String] = [:]
var entryPoints: Set<String> = []
var callsiteArgs: [String: [[ArgKind]]] = [:]   // resolved target -> each call site's arg kinds
var deferredCallbacks: [String: (indexes: Set<Int>, names: Set<String>)] = [:]

let localProtocolNames = Set(protocolMethods.keys)  // loop-invariant: build once, not per fn
for f in allFns {
    locOf[f.qual] = f.loc
    if f.isMain { entryPoints.insert(f.qual) }
    edges[f.qual] = edges[f.qual] ?? []
    guard let body = f.body else { continue }
    let cc = CallCollector(info: f, fields: fields, localTypes: localTypes,
                           declaredTypes: declaredTypes,
                           localProtocols: localProtocolNames, returns: returnsIdx,
                           fieldArrayElem: fieldArrayElem, fieldDictValue: fieldDictValue,
                           enumCaseValueType: enumCaseValueType, dynamicMemberTypes: dynamicMemberTypes,
                           propertyWrapperTypes: propertyWrapperTypes, wrappedProps: wrappedProps,
                           localFreeFns: Set(freeFnByName.keys), typeAliases: typeAliases,
                           opaqueSeqBuilders: opaqueSeqBuilders, seqBuilderConcrete: seqBuilderConcrete,
                           closureFields: closureFields)
    cc.walk(body)
    // accessor units: a property READ of a known accessor unit is an edge (the reader inherits
    // the getter's effects — `c.data` reaching the Fs inside `var data: Data { … }`)
    edges[f.qual, default: []].formUnion(cc.propertyEdges.compactMap { resolveQual($0) })
    // a bare-name read that names a GLOBAL initializer unit charges its first-touch effects here
    edges[f.qual, default: []].formUnion(cc.globalReads.filter { globalUnitNames.contains($0) && $0 != f.qual })
    direct[f.qual, default: []].formUnion(cc.directEffects)
    if cc.unresolved { direct[f.qual, default: []].insert("Unknown"); unresolvedSet.insert(f.qual) }
    whyMap[f.qual, default: []].formUnion(cc.why)
    hostsD[f.qual, default: []].formUnion(cc.hosts)
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
        if call.typed {
            if overloadedBases.contains(call.path) {
                for t in matchOverloads(call.path, argc, call.argTypes) {
                    edges[f.qual, default: []].insert(t)
                    callsiteArgs[t, default: []].append(call.args)
                    resolved = true
                }
            } else if let t = resolveQual(call.path) {
                edges[f.qual, default: []].insert(t)
                callsiteArgs[t, default: []].append(call.args)
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
                    if let t = resolveQual("\(sup).\(member)") {
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append(call.args)
                        resolved = true
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
                    let extSupers = (supertypesOf[type] ?? []).filter { !localTypes.contains($0) }
                    if let eff = extSupers.compactMap({ FLUENT_MODEL_PROTOCOLS.contains($0) ? fluentModelEffect(member) : nil }).first {
                        direct[f.qual, default: []].insert(eff)
                        resolved = true
                    } else if let sup = extSupers.first(where: { !STD_PURE_PROTOCOLS.contains($0) }) {
                        direct[f.qual, default: []].insert("Unknown")
                        unresolvedSet.insert(f.qual)
                        whyMap[f.qual, default: []].insert("dispatch:\(sup).\(member)")
                        resolved = true
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
                for t in matchOverloads(call.path, argc, call.argTypes) {
                    edges[f.qual, default: []].insert(t)
                    callsiteArgs[t, default: []].append(call.args)
                    resolved = true
                }
            } else if let targets = freeFnByName[call.path], targets.count == 1 {
                edges[f.qual, default: []].insert(targets[0])
                callsiteArgs[targets[0], default: []].append(call.args)
                resolved = true
            } else if localTypes.contains(call.path), overloadedBases.contains("\(call.path).init") {
                for t in matchOverloads("\(call.path).init", argc, call.argTypes) {
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
                if let t = resolveQual("\(call.path).init") { edges[f.qual, default: []].insert(t) }
                resolved = true
            } else if let et = f.enclosingType, overloadedBases.contains("\(et).\(call.leaf)") {  // overloaded sibling
                for t in matchOverloads("\(et).\(call.leaf)", argc, call.argTypes) {
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
            for m in fileImports[file] ?? [] where blindModules.contains(m) {
                blindDirect[f.qual, default: []].insert(m)
            }
        }
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
// the masking surface-incompleteness and the per-fn blind-module disclosure propagate the SAME way: a
// caller transitively reaches a callee's invisible endpoint / blind module, so it inherits the flag/set.
let incompleteAcc = propagate(incompleteD, over: edges)
let invisibleAcc = propagate(blindDirect, over: edges)

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Report (§2 envelope, spec 0.5) + sidecar (§2.2) + receipt + κ ledger (§7.14)
// ════════════════════════════════════════════════════════════════════════════════════════════════

let prefix = outPrefix ?? (rootDir as NSString).appendingPathComponent(".candor/report")

let accessorQuals = Set(allFns.filter { $0.isAccessor }.map { $0.qual })
// ── The candor domain model (candor-spec/MODEL.md) — candor-swift's named realization of the shared
// vocabulary. Independently derived (NO shared code across engines — that independence is what the
// conformance differential proves); mirrors candor-java's `io.poly.candor.model` and Rust's candor-report
// structs. These types OWN the §2 wire serialization, so the entry/envelope shape lives in one place.
enum Effect: String, CaseIterable {
    case clipboard = "Clipboard", clock = "Clock", db = "Db", env = "Env", exec = "Exec"
    case fs = "Fs", ipc = "Ipc", log = "Log", net = "Net", rand = "Rand", unknown = "Unknown"
    var specName: String { rawValue }
    var isTrustMarker: Bool { self == .unknown }                                 // SPEC §4: Unknown is not an effect
    var isBoundary: Bool { switch self { case .db, .net, .exec, .fs, .ipc, .clipboard: return true; default: return false } }
    var isAmbient: Bool { switch self { case .log, .clock, .rand, .env: return true; default: return false } }
    static func from(_ name: String) -> Effect? { Effect(rawValue: name) }
}
// A set of effects (SEMANTICS §1). Wire form = spec-name-sorted names — which, for this vocabulary, is the
// same lexicographic order a `Set<String>.sorted()` produced, so adoption is byte-identical.
struct EffectSet {
    private(set) var effects: Set<Effect>
    init(_ effects: Set<Effect> = []) { self.effects = effects }
    init(names: some Sequence<String>) { self.effects = Set(names.compactMap(Effect.from)) }
    var isEmpty: Bool { effects.isEmpty }
    func contains(_ e: Effect) -> Bool { effects.contains(e) }
    func toNames() -> [String] { effects.map { $0.specName }.sorted() }
}
// Which engine produced a report and which contract it conforms to (§2.1).
struct Provenance {
    let version: String, toolchain: String, spec: String
    func toJSON() -> [String: Any] { ["version": version, "toolchain": toolchain, "spec": spec] }
}
// The per-unit report entry (§2). candor-swift is analyze-only, so declared/undeclared/overdeclared are
// always empty (no DI-conformance pass) — kept in the wire shape for cross-engine schema parity.
struct Effector {
    let fn: String, loc: String
    let inferred: EffectSet, direct: EffectSet
    let unresolved: Bool, hash: String, calls: [String]
    var entryPoint = false
    var unitKind: String? = nil
    var unknownWhy: [String]? = nil
    var hosts: [String]? = nil, cmds: [String]? = nil, paths: [String]? = nil, tables: [String]? = nil
    var invisible: [String]? = nil   // per-fn blind-spot disclosure: κ-unknown modules reached (qualifies `inferred`)
    func toJSON() -> [String: Any] {
        var e: [String: Any] = [
            "fn": fn, "loc": loc,
            "inferred": inferred.toNames(), "direct": direct.toNames(),
            "declared": [String](), "undeclared": [String](), "overdeclared": [String](),
            "unresolved": unresolved,
            "hash": hash,                       // 0.5 MUST: every report is chainable
            "calls": calls,
        ]
        if entryPoint { e["entryPoint"] = true }
        if let k = unitKind { e["unitKind"] = k }   // spec 0.5 draft, informative
        if let w = unknownWhy, !w.isEmpty { e["unknownWhy"] = w }
        if let h = hosts, !h.isEmpty { e["hosts"] = h }
        if let c = cmds, !c.isEmpty { e["cmds"] = c }
        if let p = paths, !p.isEmpty { e["paths"] = p }
        if let t = tables, !t.isEmpty { e["tables"] = t }
        if let v = invisible, !v.isEmpty { e["invisible"] = v }
        return e
    }
}
// The §2 envelope: provenance + the package + the effectors.
struct Report {
    let provenance: Provenance, package: String, effectors: [Effector]
    func toJSON() -> [String: Any] {
        ["candor": provenance.toJSON(), "package": package, "functions": effectors.map { $0.toJSON() }]
    }
}

var effectors: [Effector] = []
// A pure fn that reaches a blind module is NOT in `inferred` (no effect seeds it), but it must still
// appear — carrying `invisible` — so `inferred: []` is never an unqualified pure claim. Union the keys.
let reportQuals = Set(inferred.keys).union(invisibleAcc.keys)
for qual in reportQuals.sorted() {
    let inf = inferred[qual] ?? []
    let invisible = (invisibleAcc[qual] ?? []).sorted()
    if inf.isEmpty && invisible.isEmpty { continue }
    var ef = Effector(
        fn: qual, loc: locOf[qual] ?? "",
        inferred: EffectSet(names: inf), direct: EffectSet(names: direct[qual] ?? []),
        unresolved: inf.contains("Unknown"), hash: "\(pkgName)#\(qual)",
        calls: (edges[qual] ?? []).sorted())
    if entryPoints.contains(qual) { ef.entryPoint = true }
    if accessorQuals.contains(qual) { ef.unitKind = "accessor" }
    if let w = whyMap[qual], !w.isEmpty { ef.unknownWhy = w.sorted() }
    if let h = hostsAcc[qual], !h.isEmpty { ef.hosts = h.sorted() }
    if let c = cmdsAcc[qual], !c.isEmpty { ef.cmds = c.sorted() }
    if let p = pathsAcc[qual], !p.isEmpty { ef.paths = p.sorted() }
    if let t = tablesAcc[qual], !t.isEmpty, inf.contains("Db") { ef.tables = t.sorted() }
    if !invisible.isEmpty { ef.invisible = invisible }
    effectors.append(ef)
}
let report = Report(
    provenance: Provenance(version: engineVersion, toolchain: "swiftsyntax", spec: specVersion),
    package: pkgName, effectors: effectors)
let envelope: [String: Any] = report.toJSON()
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
if wantJson {
    // --json: emit the §2 envelope to STDOUT and write NO report file(s)/sidecars (the candor-scan
    // reference behaviour). The κ-coverage ledger and the §6.2 policy gate below STILL run (the gate
    // keeps its exit codes), so `--json --policy p` prints the report AND exits 1 on a violation.
    // Serialize exactly as writeJson does (pretty + sorted keys) so the stdout document is byte-for-byte
    // the report file's content.
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    } catch {
        FileHandle.standardError.write("candor-swift: could not serialize report: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
} else {
    // Create `.candor/` (or the --out parent) only on the file-writing path — --json is documented as
    // writing NO files, so it must not leave an empty directory behind as a side effect.
    try? fm.createDirectory(atPath: (prefix as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    writeJson(envelope, reportPath)
    writeJson(cg, "\(prefix).\(fileSafePkg).Swift.callgraph.json")
    // Type-hierarchy sidecar (SPEC §4 / 0.7): each local type -> its declared supertypes/protocols, by
    // INVERTING `conformers` (supertype -> subtypes, from pushType). Lets candor-query's dispatch-frontier
    // (callers --include-unknown) resolve whether a confirmed reacher overrides a `dispatch:` owner. Keyed by
    // the bare type name — matching this engine's `Type.member` fn quals + `dispatch:Type.member` reasons.
    var typeHierarchy: [String: [String]] = [:]
    for (sup, subs) in conformers {
        for sub in subs { typeHierarchy[sub, default: []].append(sup) }
    }
    for k in typeHierarchy.keys { typeHierarchy[k] = Array(Set(typeHierarchy[k]!)).sorted() }
    writeJson(typeHierarchy, "\(prefix).\(fileSafePkg).Swift.hierarchy.json")
    FileHandle.standardError.write(
        "candor-swift: wrote \(effectors.count) effectful functions (\(allFns.count) analyzed, \(sourcePaths.count) files) to \(reportPath)\n".data(using: .utf8)!)
    // Effect breakdown — make the result visible at a glance, not just a count + a file path.
    var counts: [String: Int] = [:]
    for e in effectors { for x in e.inferred.toNames() { counts[x, default: 0] += 1 } }
    let breakdown = ["Net", "Fs", "Db", "Exec", "Ipc", "Env", "Clipboard", "Clock", "Log", "Rand"]
        .filter { counts[$0] != nil }.map { "\($0) \(counts[$0]!)" }.joined(separator: " · ")
    let unknown = counts["Unknown"] ?? 0
    if !breakdown.isEmpty || unknown > 0 {
        let u = unknown > 0 ? "\(breakdown.isEmpty ? "" : "   ·   ")Unknown \(unknown) (disclosed)" : ""
        FileHandle.standardError.write("  \(breakdown)\(u)\n".data(using: .utf8)!)
    }
}

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
    // Split LINES on \n / \r\n / bare \r — the three forms Java's Files.readAllLines (the reference parser)
    // breaks on. Splitting on \n ONLY let a classic-Mac (bare-\r) file collapse to ONE line: \r is also an
    // in-line ASCII-ws token separator (§6.2), so every rule after the first was glued into the first rule's
    // tokens and dropped — a gateless-green divergence (sweep [16]/[17]). Normalize first; \v/\f stay in-line
    // token separators (Java's readLine does not break on them either).
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
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

/// §6.2 scope match: segment run, last segment a prefix. Segments split on BOTH `.` and `::` (empty
/// parts filtered), mirroring Rust/Java's `name_segments` — so a shared `::`-scoped policy (Rust/Swift
/// path syntax) matches Swift names too, not just dotted ones. Splitting on `:` is safe: a `:` only ever
/// appears in a `::` separator in these names, so it never over-segments (no spurious match).
func scopeMatches(_ name: String, _ scope: String) -> Bool {
    if scope.isEmpty { return true }
    let segs = name.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
    let parts = scope.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
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
            // An INCOMPLETE surface — a host-establishing Net call with a structurally-invisible host —
            // can't be certified even when visible hosts cover the allowlist, else the benign literal MASKS
            // the invisible forbidden endpoint (the masking gate-evasion; candor-java 0.5.29 / rust / ts).
            let surfaceIncomplete = incompleteAcc[qual]?.contains(r.effect) ?? false
            if surface.isEmpty || surfaceIncomplete {
                // Two distinct failures share AS-EFF-008: no literal AT ALL, vs the MASKING case where a
                // visible literal exists but coexists with a structurally-invisible endpoint it can't cover for.
                let why = surface.isEmpty
                    ? "performs \(r.effect) with no visible literal — the surface cannot be certified"
                    : "reaches a structurally-invisible \(r.effect) endpoint a visible literal cannot mask"
                violations.append("[AS-EFF-008] `\(qual)` \(why): `\(r.raw)`")
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
    // Violation lines are diagnostics, not the report — route them to STDERR so `--json --policy p`
    // keeps stdout a single clean JSON document (a violation line on stdout broke `… | jq`). The human
    // summary already goes to stderr, so emit here unconditionally (not only when --json).
    for v in violations { FileHandle.standardError.write((v + "\n").data(using: .utf8)!) }
    if violations.isEmpty {
        FileHandle.standardError.write("candor-swift: policy ✓\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("candor-swift: \(violations.count) policy violation(s)\n".data(using: .utf8)!)
        exit(1)
    }
}
