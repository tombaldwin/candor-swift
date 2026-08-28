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
    /// ⟨0.23⟩ `typeSurface.returns` — the PLAIN NOMINAL return type AS SPELLED (`Client`, `Sync.Client`),
    /// or nil for a wrapper/tuple/function/opaque return, which must not publish its payload. Left
    /// UNRESOLVED here: turning the spelling into a fully-qualified type is a module-wide question
    /// (`Client` inside `enum Sync` means `Sync.Client`), so the Driver resolves it against the declared
    /// type paths with `enclosingTypePath` as the lookup scope.
    var retBoundTypeSpelling: String? = nil
    var paramSig: [(type: String?, hasDefault: Bool, variadic: Bool)] = []  // ordered param signature for
                                      // PARAM-TYPE overload resolution: distinguishes same-name overloads
                                      // (`compare(_:Date)` vs `compare(_:DateComparisonType)`), including the
                                      // same-arity ones arity/labels can't tell apart. `variadic` (a trailing
                                      // `T...`) lifts the arg-count upper bound (`run(_:String,_:Binding?...)`).
    var loc: String
    var params: [String: String] = [:]       // param name -> type name (concrete)
    var paramNames: Set<String> = []         // EVERY parameter name, whatever its type resolved to. `params`
                                             // and its five siblings each hold the subset they could type, so
                                             // none of them — nor their union — is the signature. A body
                                             // binder that shadows a parameter is a shadow, so the locator
                                             // pre-pass needs the WHOLE list (see prescanLocatorMoves).
    var fnTypedParams: Set<String> = []      // params of function type
    var fnTypedParamIndex: [String: Int] = [:] // fn-typed param name -> position
    /// Params declared `some P` — opaque, so the CALLER monomorphizes and the local conformers are NOT
    /// this receiver's candidate witnesses. Recorded so the Driver's CHA arm can skip them while every
    /// other use of the type (classifier, §2 dep join) proceeds normally.
    var opaqueParams: Set<String> = []
    /// Params whose ELEMENT type is monomorphized: `[some P]`, and `[T]` under a `<T: P>` bound. Unlike a
    /// bare `T` param (whose type name resolves to nothing) the element IS resolved to the bound below, so
    /// a `for x in p` / `p.forEach { $0 … }` binder inherits a protocol name for which the CALLER picked a
    /// single conformer — the same monomorphized receiver `opaqueParams` covers, one container out.
    var opaqueArrayParams: Set<String> = []
    var protoParams: [String: String] = [:]  // param name -> local protocol name
    var arrayParams: [String: String] = [:]  // param name -> ELEMENT type (a `[T]` param, for `for x in p`)
    var dictParams: [String: String] = [:]   // param name -> VALUE type (a `[K: V]` param, for `for (k,v)`)
    var tupleParams: [String: [String: String]] = [:]  // param -> tuple element types (`p.0`/`p.c`)
    var body: Syntax?
    var enclosingType: String?
    var isMain: Bool = false
    var isAccessor: Bool = false   // a computed-property/observer/lazy-init body (spec 0.5 unitKind)
    // the synthetic `<main>` unit for a file's TOP-LEVEL executable statements (Swift allows executable
    // statements directly at file scope in main.swift / script files). Emits `unitKind: "initializer"`
    // (spec §2 recommended value; the JVM engine's `<clinit>` uses the same kind) — the top level runs
    // once, like a static initializer. Distinct from `isAccessor` so it is NOT relabelled "accessor".
    var isTopLevel: Bool = false
    var uppercaseAttrs: [String] = []   // capitalized @-attributes (a `@SomeBuilder` result-builder candidate)
    // self's ELEMENT type when this method lives in a COLLECTION extension with an element bound
    // (`extension Array where Element: Saveable` → "Saveable") — so a bare `forEach { $0.method() }`
    // over `self` types `$0` and dispatches (the conditional-conformance vein, R28).
    var selfElementType: String? = nil
    // ⟨0.33.1⟩ Declared inside a `#if` CONDITIONAL-COMPILATION block (any condition — `os(Windows)`,
    // `DEBUG`, `canImport(…)`, with or without an `#else`). The syntactic scan has no build
    // configuration and reads BOTH/ALL clauses of every `#if` unconditionally (SwiftSyntax's default
    // visitor descends into an `IfConfigDeclSyntax` whichever way the condition would actually
    // resolve), so a declaration living in one clause is exactly as visible here as an unconditional
    // one — but it may not exist AT ALL in the build this scan's caller ships. See the SHADOW note at
    // Driver.swift's `localFreeFnBaseNamesByModule`/`conditionalOnlyFreeFnNamesByModule`: a bare-name
    // κ heuristic (`getenv`) must not be permanently shadowed by a same-named declaration that only
    // exists on a platform this scan cannot pin.
    var isConditionallyCompiled: Bool = false
    /// R61 — a bodyless func declared via DIRECT C-SYMBOL LINKAGE (`@_silgen_name("system")`,
    /// `@_extern(c, "name")`): the compiler wires the call straight to a native symbol, so there is no
    /// Swift body for this scan to see. `body` is nil for one other reason too (a protocol requirement),
    /// which must NOT be treated the same way — a requirement's call sites already get an honest
    /// `dispatch:` from the bounded-CHA machinery, and flagging every bodyless unit here would double that
    /// disclosure (or worse, fire on requirements no fixture ever exercises). Gating on this specific,
    /// rare, deliberately-written attribute keeps the blast radius to exactly the FFI shape it names: the
    /// symbol string from the attribute when present, else the Swift-side function name as a fallback so
    /// `native:<x>` is never empty. See `Driver.swift`'s `guard let body = f.body else { continue }`.
    var ffiNative: String? = nil
}

// Collects the expression of every explicit `return <expr>` inside a body (Finding 1: pinning a function's
// concrete returned iterable type). Does NOT descend into nested closures/functions — a `return` there
// belongs to that inner scope, not the function whose concrete result type we're resolving.
/// True when a `let`/`var` sits at FILE SCOPE, i.e. is a real module global rather than a local.
///
/// Swift allows executable statements at file scope, so a binding inside a top-level `if`/`for`/`while`
/// block is lexically outside any type while being an ordinary LOCAL of that block. Registering those as
/// globals minted a unit named after a local — candor-swift's own `main.swift` has `let pipe = Pipe()`
/// three blocks deep inside `if wantWorkspace { for … { … } }`, and the report carried a global `pipe`
/// with `Ipc` that no module-level `pipe` exists to justify. Global units are keyed by bare name, so such
/// a phantom is also a magnet: any bare read of that name anywhere in the module resolves to it.
///
/// At true file scope the parent chain is VariableDecl -> CodeBlockItem -> CodeBlockItemList -> SourceFile.
/// Any `CodeBlockSyntax` or closure on the way up means a nested block, so: a local.
func isFileScopeBinding(_ node: VariableDeclSyntax) -> Bool {
    var p: Syntax? = node.parent
    while let cur = p {
        if cur.is(SourceFileSyntax.self) { return true }
        if cur.is(CodeBlockSyntax.self) || cur.is(ClosureExprSyntax.self) { return false }
        p = cur.parent
    }
    return false
}

final class ReturnExprWalker: SyntaxVisitor {
    var exprs: [ExprSyntax] = []
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if let e = node.expression { exprs.append(e) }
        return .visitChildren
    }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

/// A control character — cannot occur in a Swift identifier, so it round-trips a JOINED list of protocol
/// names through the single-`String`-valued `protoParams`/`protoTyped` maps without a false split/merge.
/// Used for a protocol COMPOSITION parameter (`_ x: A & B`), which needs to try EACH composed protocol at
/// a member-dispatch call site rather than pick one. Reusing the existing single-name map (instead of
/// adding a parallel `[String: [String]]`) means the composition case gets `protoTyped`'s entire
/// shadow-save/clear discipline for FREE — every rebind/scope site that already invalidates a stale
/// `protoTyped[name]` invalidates this exactly the same way, because as far as those sites are concerned
/// it is still just a `String`. The five OTHER consumers of `protoTyped` (the closure-iterator, if-let
/// unwrap, property-read, operator-dispatch and stringification paths) do not split on this separator, so
/// a composition-typed name flowing through them resolves to nothing (this joined string matches no real
/// protocol) — an inert no-op, not a fabrication, and a named residual rather than a silent gap.
let protoCompositionSep: Character = "\u{1}"

/// The composed protocol names of a param typed `A & B` / `any A & B` / `(A & B)?` (peeling the same
/// Optional/attribute/`some`/`any` wrappers `typeName` peels), or nil for anything else — including a
/// composition where SOME element doesn't resolve to a plain name, which is left alone rather than
/// guessed at (the safe direction: the caller falls through to the existing, unchanged silent-pure path
/// for a type this cannot parse the way it can already parse `A & B`).
func compositionTypeNames(_ t: TypeSyntax) -> [String]? {
    if let opt = t.as(OptionalTypeSyntax.self) { return compositionTypeNames(opt.wrappedType) }
    if let att = t.as(AttributedTypeSyntax.self) { return compositionTypeNames(att.baseType) }
    if let some = t.as(SomeOrAnyTypeSyntax.self) { return compositionTypeNames(some.constraint) }
    guard let comp = t.as(CompositionTypeSyntax.self) else { return nil }
    let names = comp.elements.compactMap { typeName($0.type).name }
    return names.count == comp.elements.count ? names : nil
}

final class DeclCollector: SyntaxVisitor {
    var file: String
    var converter: SourceLocationConverter
    var fns: [FnInfo] = []
    var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:] // Type -> field -> info
    var typeGenericBounds: [String: [String: String]] = [:]  // Type -> its generic param -> protocol bound
    // Type -> the RAW generic parameter names its own declaration introduces (`struct Box<T>` -> {"Box":
    // {"T"}}), recorded regardless of whether a bound is known yet. A conditional-conformance extension
    // (`extension Box: Greeter2 where T: Greeter2`) supplies the BOUND for a param the type declaration
    // already named, and — because DeclCollector is a single top-to-bottom pass per file — the extension
    // is frequently visited AFTER a field of that same param type has already been resolved (as here: the
    // struct's `let value: T` field sits above the extension in the fixture that found this), or lives in
    // a DIFFERENT file entirely. This set is what lets the field-resolution branch below tell "an
    // as-yet-unbound generic param of THIS type" (defer, see `unresolvedGenericFields`) from "a genuine
    // forward/unresolvable type reference" (leave alone, unchanged behavior).
    var typeGenericParamNames: [String: Set<String>] = [:]
    // A stored field whose type is its enclosing type's OWN generic parameter, recorded with NO bound
    // resolved at declaration time — deferred here so Driver can retry once every file's extensions
    // (same file, later; or a different file, any order) have contributed their `where` clauses to the
    // merged `typeGenericBounds`. Mirrors `staticFactoryFields`'s exact two-phase shape one level down.
    var unresolvedGenericFields: [(ty: String, field: String, param: String)] = []
    /// Fields whose recorded type is MONOMORPHIZED rather than erased: a field typed as the enclosing
    /// type's generic param (`struct Pipe<T: Saver> { var item: T }` — resolved to `Saver` below), or one
    /// spelled `some P`. Whoever instantiates `Pipe` picks the single conforming type, so the conformers
    /// visible here are not this field's candidate witnesses. Consumed only by the Driver's CHA arm.
    var opaqueFields: [String: Set<String>] = [:]         // Type -> field names
    var fieldArrayElem: [String: [String: String]] = [:]  // Type -> field -> ELEMENT type (`[T]` field)
    var fieldDictValue: [String: [String: String]] = [:]  // Type -> field -> VALUE type (`[K: V]` field)
    var protocolMethods: [String: Set<String>] = [:]   // protocol -> declared method names
    var protocolSupers: [String: Set<String>] = [:]    // protocol -> its DIRECT super-protocols (`Sub: Sup`)
    var returnsTmp: [String: String?] = [:]            // fn leaf -> return type (nil = ambiguous)
    var conformers: [String: [String]] = [:]           // protocol -> conforming local types
    var caseAssoc: [String: Set<String>] = [:]         // enum case -> single-associated-value type(s) seen
    // `static let shared = factory()` — Type.field -> factory leaf, resolved to the vended type AFTER
    // the returns index is built (a free factory's return type isn't known during this first pass).
    var staticFactoryFields: [(type: String, field: String, leaf: String)] = []
    var localTypes: Set<String> = []
    /// Every declared/extended type's FULL nested path (`Client`, `Sync.Client`) — `localTypes` keeps only
    /// the simple name, which is exactly the collision `typeSurface` must not publish through: two
    /// `Client`s under `enum Sync` and `enum Mock` are ONE string there and two strings here.
    var localTypePaths: Set<String> = []
    // Types with a REAL local definition (class/struct/enum/actor/protocol) — a SUBSET of localTypes,
    // which also carries types that only ever appear in an `extension`. An `extension Process { … }` adds
    // "Process" to localTypes (so its members resolve to any sibling helpers) but NOT to declaredTypes —
    // it does not redefine the platform type. The shadow discipline (a project's own `class Channel` must
    // not fabricate NIO Net) keys on `declaredTypes`: a member call on an extension-ONLY κ-platform type
    // (`self.launch()` inside `extension Process`) that resolves to no local unit falls through to the κ
    // table instead of reading silent-pure (the ShellOut cardinal-sin: `Process.launch` was lost).
    var declaredTypes: Set<String> = []
    // ⟨0.33.1⟩ The SUBSET of `declaredTypes` declared OUTSIDE any `#if` — the TYPE analogue of
    // `FnInfo.isConditionallyCompiled`. `declaredTypes` itself stays exactly as before (every real
    // definition, conditional or not — it also seeds the §2.2 type-hierarchy sidecar, which must still
    // answer for a `#if`-gated type since the engine cannot rule out that branch either); this narrower
    // set is what the Driver uses to build the shadow guard CallCollector's κ-ctor arms fence on, so a
    // name whose ONLY declaration(s) sit inside a `#if` (no `#else` needed — the engine reads every
    // branch) does not permanently shadow the heuristic the way an unconditional declaration must. See
    // `pushType`'s use of `ifConfigDepth`, and the getenv/free-function fix this mirrors (098a035).
    var declaredTypesUnconditional: Set<String> = []
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
    var globalActorTypes: Set<String> = []     // `@globalActor`-annotated local types (e.g. a custom `@DBActor`)
    // Capitalized @-attributes applied to a class/struct/enum/actor DECLARATION itself (`@Observable
    // class Store`), raw and unfiltered — the type-level companion to `FnInfo.uppercaseAttrs`. Swift
    // admits exactly two explanations for a capitalized custom attribute here: a global actor (excluded
    // via `globalActorTypes` once the driver has unioned every file) or an attached macro — there is no
    // third category a type declaration can carry, unlike a var/param site where a property wrapper is
    // also possible. Driver filters this against the unioned `globalActorTypes` and a small denylist of
    // compiler builtins (`@MainActor`, `@IBDesignable`, …) before disclosing the residue as Unknown.
    var typeMacroAttrs: [String: [String]] = [:]
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
    // CONST-STRING PROPAGATION — module/global and `static let` string CONSTANTS whose initializer is a
    // PLAIN string literal (`let apiBase = "https://api.openai.com/v1"`). Keyed by the SIMPLE bound name —
    // a bare reference / interpolation-prefix / concat-left uses the name only. VALUE is the literal, or
    // nil when the SAME name is bound to ≥2 DIFFERENT literals (ambiguous → never resolve). ONLY plain
    // string literals of a `let` enter: a `var`, an interpolation, a function/computed result do NOT (they
    // could be reassigned or are runtime — resolving them would FABRICATE a host). Fed to CallCollector so
    // a const-anchored Net/Db/Llm host is resolved through the EXISTING host-refinement path.
    var constStrings: [String: String?] = [:]
    private var typeStack: [String] = []
    // parallel to typeStack: self's ELEMENT bound when the current scope is a COLLECTION extension with a
    // `where Element: P` clause (`extension Array where Element: Saveable` → "Saveable"); nil otherwise.
    private var selfElementStack: [String?] = []
    // ⟨0.33.1⟩ Depth of `#if` CONDITIONAL-COMPILATION nesting the walker currently sits inside. >0 for
    // every clause of every `#if`/`#elseif`/`#else` — SwiftSyntax carries no build configuration, so
    // this walker (like the rest of the engine) reads every branch, and cannot tell which one, if any,
    // the actual build will keep. See `FnInfo.isConditionallyCompiled`.
    private var ifConfigDepth = 0
    override func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        ifConfigDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: IfConfigDeclSyntax) { ifConfigDepth -= 1 }

    init(file: String, tree: SourceFileSyntax) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    private func loc(_ node: some SyntaxProtocol) -> String {
        let l = node.startLocation(converter: converter)
        return "\(file):\(l.line):\(l.column)"
    }

    // TOP-LEVEL EXECUTABLE STATEMENTS — Swift allows bare executable statements directly at file scope in
    // `main.swift` / script files (`URLSession.shared.dataTask(…)`, `work()`, `if …`). They run once when
    // the file's module entry point executes — like a static initializer. Without this they were collected
    // by NOTHING (they belong to no declaration), so a file whose only effect lives at the top level scanned
    // as an EMPTY report — a false "pure" verdict (the cardinal sin, top-level edition).
    //
    // Synthesize ONE `<main>` unit per file whose body is JUST the executable items — expression statements,
    // control-flow statements, and WILDCARD/`_` variable decls (`let _ = …`, which bind no name so no lazy
    // global-var unit was ever minted for them). Named global `let x = …` / `var x` decls are EXCLUDED — they
    // are already collected as first-touch lazy units (the else-branch of visit(VariableDeclSyntax)); folding
    // their initializers in here would double-attribute. Func / type / import / typealias declarations are
    // also EXCLUDED — each is (or contributes) its own unit; inlining a `func work(){…}` body would charge
    // work's effects to `<main>` as DIRECT instead of transitively through the `work()` call edge.
    //
    // Minted only when the filtered list is non-empty (a plain library file — imports + declarations, no
    // executable statements — gets no `<main>` at all). A `<main>` that turns out pure carries no effect and
    // is omitted from the report's `functions` (pure units are dropped downstream), exactly like a pure
    // global-var / func unit — so this never floods the effect report.
    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        var executable: [CodeBlockItemSyntax] = []
        for item in node.statements {
            switch item.item {
            case .stmt, .expr:
                executable.append(item)
            case .decl(let decl):
                // Only a variable decl whose bindings bind NO name (`let _ = …`, or a `_`-only tuple) —
                // a wildcard binding runs its initializer for effect but was never a named lazy unit.
                if let v = decl.as(VariableDeclSyntax.self),
                   v.bindings.allSatisfy({ !bindsAnyName($0.pattern) }) {
                    executable.append(item)
                }
            }
        }
        if let first = executable.first {
            let block = CodeBlockItemListSyntax(executable)
            var info = FnInfo(qual: "<main>", loc: loc(first))
            info.simpleQual = "<main>"
            info.body = Syntax(block)
            info.isTopLevel = true
            fns.append(info)
        }
        return .visitChildren
    }

    // Does this pattern bind at least one name (vs a pure-wildcard `_` / `(_, _)`)?
    private func bindsAnyName(_ pattern: PatternSyntax) -> Bool {
        if pattern.is(IdentifierPatternSyntax.self) { return true }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.contains { bindsAnyName($0.pattern) }
        }
        // WildcardPattern (`_`), and any other non-identifier pattern, binds no name.
        return false
    }

    // Every identifier bound by a pattern, recursing into tuples: `x` → [x]; `(a, b)` → [a, b];
    // `(_, x)` → [x]. A TUPLE-destructured binding (`let (a, b) = effectfulInit()`) shares ONE
    // initializer, so charging that init to each name's first-touch read is a sound over-approximation
    // (either read could force the lazy global). Without this, a tuple-pattern binding fell through the
    // IdentifierPattern-only guard and its initializer effect was SILENTLY DROPPED (a `let (a,b) =
    // readConfig()` global read pure — the cardinal sin, the top-level sibling the <main> collector
    // excludes because it binds names).
    // The PLAIN string-literal value of an initializer, or nil if it is not a pure string literal (an
    // interpolated/computed value). Mirrors CallCollector.firstStringLiteral's pure-segment discipline:
    // ANY non-plain (interpolation) segment ⇒ nil (no const claim). Escape decoding is deferred to the
    // use-site (CallCollector), which runs the value through the same host path as an inline literal.
    private func plainStringLiteralValue(_ expr: ExprSyntax) -> String? {
        guard let lit = expr.as(StringLiteralExprSyntax.self) else { return nil }
        var out = ""
        for seg in lit.segments {
            if let plain = seg.as(StringSegmentSyntax.self) { out += plain.content.text } else { return nil }
        }
        return out
    }

    /// R61 — the LAST plain string-literal argument of an attribute (`@_silgen_name("system")`'s only
    /// argument; `@_extern(c, "name")`'s second — the linked symbol name, not the `c`/`wasm` ABI tag which
    /// is a bare identifier and never matches `StringLiteralExprSyntax`). `@_extern(c)` alone has no string
    /// argument at all and returns nil here, on purpose — the caller falls back to the Swift-side name.
    private func lastStringLiteralArgument(_ attr: AttributeSyntax) -> String? {
        guard case .argumentList(let args) = attr.arguments else { return nil }
        var last: String? = nil
        for arg in args { if let s = plainStringLiteralValue(arg.expression) { last = s } }
        return last
    }

    // Record a `let NAME = "literal"` STRING CONSTANT into the const-string index. ONLY a `let` (not `var`
    // — a var could be reassigned) whose initializer is a PLAIN string literal enters. A second, DIFFERENT
    // literal for the same name marks it ambiguous (nil) so it is never resolved (never guess).
    private func recordConstString(name: String, isLet: Bool, initializer: ExprSyntax?) {
        guard isLet, let initializer, let value = plainStringLiteralValue(initializer) else { return }
        if let existing = constStrings[name] {
            if existing != value { constStrings[name] = String?.none }   // same name, ≠ literal → ambiguous
        } else {
            constStrings[name] = value
        }
    }

    private func boundNames(_ pattern: PatternSyntax) -> [String] {
        if let id = pattern.as(IdentifierPatternSyntax.self) { return [id.identifier.text] }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.flatMap { boundNames($0.pattern) }
        }
        return []   // wildcard / other — binds no name (the <main> collector handles wildcard-only)
    }

    private func pushType(_ name: String, inheritance: InheritanceClauseSyntax?, attributes: AttributeListSyntax? = nil,
                          isExtension: Bool = false) {
        typeStack.append(name)
        selfElementStack.append(nil)   // extensions with a `where Element: P` overwrite this below
        localTypes.insert(name)
        localTypePaths.insert(typeStack.joined(separator: "."))
        // An `extension` does not DECLARE the type — it adds to whatever (possibly platform) type already
        // exists. Only a real definition shadows the κ table (see declaredTypes' note).
        if !isExtension {
            declaredTypes.insert(name)
            // ⟨0.33.1⟩ `ifConfigDepth == 0` means THIS declaration is not `#if`-gated — see
            // `declaredTypesUnconditional`'s doc. A name declared BOTH unconditionally (here or
            // elsewhere) and conditionally still ends up in this set (Driver unions per-file), which is
            // right: a real, in-tree declaration exists, so winner-take-all still applies.
            if ifConfigDepth == 0 { declaredTypesUnconditional.insert(name) }
        }
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
                // A `@globalActor` type (`@globalActor actor DBActor { … }`): a decl annotated `@DBActor`
                // is isolation-checked at compile time only — no member is synthesized, no body supplied —
                // so it is the one capitalized decl-attribute explanation that is NOT an attached macro.
                // See `typeMacroAttrs`'s note; only a LOCALLY-declared global actor is exempted this way.
                if an == "globalActor" { globalActorTypes.insert(name) }
            }
        }
        // capitalized @-attributes on the TYPE decl itself (`@Observable class Store`) — raw and
        // unfiltered, same discipline as `FnInfo.uppercaseAttrs`: this pass records candidates, Driver
        // (after every file's tables are unioned) decides what they mean.
        for attr in attributes ?? [] {
            if let a = attr.as(AttributeSyntax.self) {
                let an = a.attributeName.trimmedDescription
                if an.first?.isUppercase == true { typeMacroAttrs[name, default: []].append(an) }
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
            typeGenericParamNames[name, default: []].insert(gp.name.text)
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
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast(); selfElementStack.removeLast() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeGenerics(node.name.text, node.genericParameterClause, node.genericWhereClause)
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast(); selfElementStack.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeGenerics(node.name.text, node.genericParameterClause, node.genericWhereClause)
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast(); selfElementStack.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        recordTypeGenerics(node.name.text, node.genericParameterClause, node.genericWhereClause)
        pushType(node.name.text, inheritance: node.inheritanceClause, attributes: node.attributes); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast(); selfElementStack.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // A non-identifier extended type (`extension [Foo]`, `extension Optional<X>`) needs a
        // STABLE name — the old "?" fallback merged every such extension into one phantom unit
        // ("?.name" showed up as a caller in the swift-argument-parser probe), cross-wiring their
        // methods. The trimmed source text is unique per type; spaces drop for qual hygiene.
        let name = typeName(node.extendedType).name
            ?? node.extendedType.trimmedDescription.replacingOccurrences(of: " ", with: "")
        pushType(name, inheritance: node.inheritanceClause, isExtension: true)
        // A conditional-conformance extension of a COLLECTION (`extension Array where Element: Saveable`):
        // record self's element bound so a bare `forEach { $0.persist() }` over self dispatches (R28). The
        // element param is Swift's collection convention `Element`; a `where Element: P` requirement gives P.
        for req in node.genericWhereClause?.requirements ?? [] {
            guard case .conformanceRequirement(let c) = req.requirement,
                  typeName(c.leftType).name == "Element", let bound = typeName(c.rightType).name else { continue }
            selfElementStack[selfElementStack.count - 1] = bound
        }
        // GENERAL conditional conformance of a USER type (`extension Box: Greeter2 where T: Greeter2`):
        // `Element` above is Swift's own collection convention, one name out of however many a type
        // actually declares — a plain `struct Box<T>` extension needs the SAME requirement recorded under
        // its own param name, not just under the literal string "Element". `recordTypeGenerics` (used for
        // a type's OWN generic clause everywhere else) is exactly that general form, so run it here too;
        // it is additive with the `Element`/`selfElementStack` special case above, not a replacement for
        // it (that one feeds a DIFFERENT consumer — `elementTypeOf`'s `self` case in CallCollector — which
        // still needs its own bound). See `unresolvedGenericFields`'s doc for why a field typed by this
        // bound cannot always be resolved here, in this same pass.
        recordTypeGenerics(name, nil, node.genericWhereClause)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast(); selfElementStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        // ⟨0.23⟩ A protocol is a TYPE PATH for `typeSurface.returns`, and `func make() -> SomeProtocol`
        // is the most idiomatic Swift factory there is. It deliberately does NOT go through `pushType`
        // (a protocol name in `conformers` would pollute the concrete-dispatch CHA), so it is recorded
        // here alone. What the consumer then keys — `<pkg>#Proto.method` — names a REQUIREMENT with no
        // body, and is answered only by an `interfaceUnion` entry the producer emits under
        // CANDOR_WORKSPACE_CHAIN. Without one the lookup misses and falls to half 1's disclosure, so the
        // two mechanisms are LAYERED, never redundant, and the unanswerable key is never silence.
        localTypePaths.insert(typeStack.isEmpty ? node.name.text
                                                : typeStack.joined(separator: ".") + "." + node.name.text)
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
        // SUPER-PROTOCOLS (`protocol Sub: Sup`): a Sup method is callable on a `Sub`-bound / `any Sub`
        // receiver, and Sub's conformers provide the inherited witness. Record the inheritance in a
        // DEDICATED map (NOT `conformers` — a protocol name there would pollute a concrete-dispatch CHA
        // and its `impls.count == conf.count` guard, forcing spurious Unknown). Driver walks this map
        // transitively so the dispatch gate accepts an INHERITED member while still CHA-ing over the
        // sub's own concrete conformers. Without it the super-protocol clause was dropped (this visit
        // does NOT go through `pushType`) and `s.base()` (base ∈ Sup) read silent-pure.
        for inh in node.inheritanceClause?.inheritedTypes ?? [] {
            if let pname = typeName(inh.type).name {
                protocolSupers[node.name.text, default: []].insert(pname)
            }
        }
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
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    // a TUPLE-destructured type member (`static let (a, b) = effectfulInit()`): the
                    // IdentifierPattern-only guard would drop its initializer effect (the member-branch
                    // sibling of the global tuple hole). A STATIC/lazy tuple property is a first-touch
                    // init, exactly like the global — mint a per-name unit for the shared initializer.
                    // (The field/wrapper/type machinery below needs a single name; a tuple member has no
                    // field type to record. An INSTANCE tuple stored property runs in the ctor and is a
                    // rarer residual, noted in the log.)
                    let tnames = boundNames(binding.pattern)
                    if !tnames.isEmpty, let init0 = binding.initializer,
                       (isStatic || node.modifiers.contains(where: { $0.name.text == "lazy" })) {
                        for nm in tnames {
                            var info = FnInfo(qual: "\(tyPath).\(nm)", loc: loc(binding))
                            info.simpleQual = "\(ty).\(nm)"
                            info.body = Syntax(init0.value)
                            info.isAccessor = true
                            fns.append(info)
                        }
                    }
                    continue
                }
                let qual = "\(tyPath).\(name)"          // fully-qualified nested path
                let simpleQual = "\(ty).\(name)"
                // CONST-STRING PROPAGATION — a `static let NAME = "literal"` type member. Keyed by SIMPLE
                // name (a bare/interpolation/concat reference names it without the type path). Only static
                // (a global-equivalent, fixed once); an instance stored `let` is per-object and reached via
                // `self.x`, not a bare name, so it stays out of the bare-name index.
                if isStatic, node.bindingSpecifier.text == "let", binding.accessorBlock == nil {
                    recordConstString(name: name, isLet: true, initializer: binding.initializer?.value)
                }
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
                    if let sp = setterParam {
                        info.paramNames.insert(sp)           // a binder even when its type didn't resolve
                        if let pt = propType { info.params[sp] = pt }
                    }
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
                    // …and that resolution is MONOMORPHIZED — the instantiator of `Pipe` picks one
                    // conformer — so it is recorded as opaque, exactly like a `some P` parameter. `any P`
                    // was written as a type here and stays erased (a real existential field).
                    if let tn = info.name, let bound = typeGenericBounds[ty]?[tn] {
                        info = (bound, info.isFunction)
                        opaqueFields[ty, default: []].insert(name)
                    } else if isOpaqueParam(ann.type) {
                        opaqueFields[ty, default: []].insert(name)
                    } else if let tn = info.name, typeGenericParamNames[ty]?.contains(tn) == true {
                        // `tn` IS a generic parameter of `ty` (so this is exactly the case the branch
                        // above resolves), but no bound is known YET — the constraining extension's
                        // `where` clause sits later in this same file or in a different one. Defer to
                        // Driver's post-merge pass rather than leave it a bare, forever-unresolved param
                        // name (`fields["Box"]["value"] = ("T", false)`, which is what shipped before this
                        // fix and is why `Box(value: NetThing2()).greet2()` under a conditional-conformance
                        // extension read silent-pure: the field never resolved to `Greeter2` at all).
                        unresolvedGenericFields.append((ty, name, tn))
                    }
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
                } else if let initVal = binding.initializer?.value,
                          let ma = initVal.as(MemberAccessExprSyntax.self),
                          let base = ma.base?.as(DeclReferenceExprSyntax.self),
                          base.baseName.text.first?.isUppercase == true,
                          SINGLETON_ACCESSORS.contains(ma.declName.baseName.text) {
                    // THE SINGLETON FIELD. `private let session = URLSession.shared` — the dominant way an
                    // Apple-platform type holds a system service. There is no type ANNOTATION and the
                    // initializer is a member access rather than a ctor CALL, so neither branch above fired:
                    // the field stayed untyped, every `session.dataTask(…)` on it missed κ entirely, and the
                    // function read SILENT-PURE. Measured on a realistic target: three Net-performing methods
                    // absent from the report altogether, which no amount of host extraction can reach.
                    //
                    // The inference is `Type.member : Type`, and it is guarded by an ALLOWLIST of the five
                    // canonical singleton spellings rather than applied to every static member — the
                    // direction is expanding, and a `static let logger: Logger` on a local type would
                    // otherwise be typed as its OWNER and resolve calls to the owner's methods, fabricating
                    // effects. A simple `Type.member` only: a nested `Type.Inner.value` would give the wrong
                    // root, so `base` must be a bare identifier.
                    fields[ty, default: [:]][name] = (base.baseName.text, false)
                }
            }
        } else if isFileScopeBinding(node) {
            // TOP-LEVEL GLOBAL `let/var x = <expr>` — a global's initializer runs at first ACCESS
            // (lazy, like a static), so it's a unit charged to the first bare-name read (`_ = x`).
            // Only a stored global with an initializer; a computed global var is collected via the
            // accessor branch above (which requires a type stack, so handle it here too).
            for binding in node.bindings {
                // A tuple-destructured global (`let (a, b) = effectfulInit()`) binds several names sharing
                // one initializer; mint a unit for EACH so any name's first-touch read carries the effect
                // (a computed global is always a single identifier, so accessor bodies only ever pair with
                // one name). An empty list = a wildcard-only binding — the <main> collector owns that.
                let names = boundNames(binding.pattern)
                if names.isEmpty { continue }
                // CONST-STRING PROPAGATION — a module/global `let NAME = "literal"`. Only a plain-string
                // `let` with no accessor block (a computed global is runtime, not a constant).
                if node.bindingSpecifier.text == "let", binding.accessorBlock == nil,
                   let only = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                    recordConstString(name: only, isLet: true, initializer: binding.initializer?.value)
                }
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
                for name in names {
                    for b in bodies {
                        var info = FnInfo(qual: name, loc: loc(binding))
                        info.simpleQual = name
                        info.body = b
                        info.isAccessor = true
                        fns.append(info)
                    }
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
        // ⟨0.23⟩ `typeSurface.returns`: what a binding bound from THIS function actually holds. See
        // `plainNominalTypeName` for why this is not `typeName` — a wrapper return must publish nothing.
        info.retBoundTypeSpelling = sig.returnClause.flatMap { plainNominalTypeName($0.type) }
        info.selfElementType = selfElementStack.last ?? nil   // collection-extension element bound, if any
        info.body = body.map { Syntax($0) }
        info.isMain = name == "main"
        info.isConditionallyCompiled = ifConfigDepth > 0
        // capture capitalized @-attributes on the func (`@EffBuilder`) — Driver edges to a result-builder
        // type's build methods once all `@resultBuilder` decls are known (declaration order is not assured).
        for attr in Syntax(node).as(FunctionDeclSyntax.self)?.attributes ?? [] {
            if let a = attr.as(AttributeSyntax.self) {
                let an = a.attributeName.trimmedDescription
                if an.first?.isUppercase == true { info.uppercaseAttrs.append(an) }
                // R61 — `@_silgen_name("system")` / `@_extern(c, "name")`: direct C-symbol linkage, no
                // Swift body. Prefer the symbol string the attribute names; fall back to the Swift-side
                // name so a `native:` disclosure is never empty (`@_extern(c)` alone names no string —
                // the linked symbol IS the Swift function's own name in that form).
                if an == "_silgen_name" || an == "_extern" {
                    info.ffiNative = lastStringLiteralArgument(a) ?? name
                }
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
            info.paramNames.insert(pname)
            // ordered signature for overload resolution: the param's simple type name (nil if unresolvable)
            // and whether it has a default (so a call may legitimately omit it).
            info.paramSig.append((t.name, p.defaultValue != nil, p.ellipsis != nil))
            if t.isFunction { info.fnTypedParams.insert(pname); info.fnTypedParamIndex[pname] = idx }
            // Container ELEMENT extraction runs before the plain-typed-param branch: a generic container
            // (`Array<T>`/`Set<T>`/`AsyncStream<T>`/`TaskGroup<T>`) has a non-nil simple name, so without
            // this it landed in `params` as the useless container name and `for x in p` left the loop var
            // untyped — the structured-concurrency `for await x in stream` silent-pure hole. `[T]`/`[K:V]`
            // (no simple name) were already reaching here; this just also catches the angle-bracket forms.
            // `[T]`/`AsyncStream<T>`/…; resolve a GENERIC element to its protocol BOUND (`[T]` where
            // `<T: Doer>` → element `Doer`), mirroring the plain-param resolution below, so `for x in items
            // { x.go() }` dispatches over the bound exactly like an existential `[any Doer]` element does.
            // …and it dispatches over the bound *sound only for the erased spelling*. `[any Doer]` really
            // may hold any conformer; `[T]` under `<T: Doer>` and `[some Doer]` are monomorphized by the
            // CALLER, so the element binder is flagged opaque and the Driver's local-conformer CHA skips
            // it (every other use of the element type — classifier, §2 dep join — proceeds).
            else if let elem = arrayElementName(p.type) {
                info.arrayParams[pname] = genericBounds[elem] ?? elem
                if genericBounds[elem] != nil || (arrayElementType(p.type).map(isOpaqueParam) ?? false) {
                    info.opaqueArrayParams.insert(pname)
                }
            }
            else if let val = dictValueName(p.type) { info.dictParams[pname] = val }        // `[K: V]`/`Dictionary<K,V>`
            else if let tn = t.name {
                // resolve a generic param to its protocol BOUND (`x: T` where `<T: Sender>` → dispatch P)
                let resolved = genericBounds[tn] ?? tn
                if protocolMethods[resolved] != nil { info.protoParams[pname] = resolved }
                // ERASED vs MONOMORPHIZED. `typeName` collapses `some P` and `any P` to `P`, but they are
                // not interchangeable for class-hierarchy analysis: `any P` is an existential, so the
                // types conforming here really are its candidate witnesses, whereas `some P` is opaque and
                // the CALLER picks the single concrete type — dispatching it over every local conformer
                // charges effects the callee cannot perform. Measured: with an IMPORTED protocol,
                // `func f(_ s: some Speaker) { s.speak() }` called only with a pure conformer was charged
                // the effectful conformer's Env. Recording nothing here leaves `some P` behaving exactly
                // like its equivalent spelling `<T: P>`, which was already inert.
                //
                // THE LOCAL-PROTOCOL ARM IS DELIBERATELY UNTOUCHED, AND HERE IS THE ARGUMENT. This
                // comment used to end "see the note in SOUNDNESS-VEIN-crossing-the-scan-boundary.md",
                // and that note WAS NEVER WRITTEN — a citation of an argument that does not exist, which
                // is worse than no comment because a reader cannot tell the two apart. Replaced with the
                // reasoning and the measurement that settled it (2026-07-26).
                //
                // The two cases are NOT the same question. For an IMPORTED protocol the conformers
                // visible here are an ARBITRARY SUBSET of the candidate set: the caller lives in another
                // module and may supply a type this scan has never seen, so unioning our few conformers
                // is neither the true set nor a bound on it — it is one member picked out of an
                // unbounded one. For a LOCALLY declared protocol the conformers in scope BOUND the
                // instantiations (and where they do not — an open hierarchy, an unresolvable witness —
                // `protoDispatches`' completeness test already falls to a disclosed `Unknown` rather
                // than to a partial union). So the union over local conformers is the sound
                // over-approximation of a generic function, not a fabrication.
                //
                // MEASURED, both candidate treatments, 14 real Swift targets / 12 004 entries. The
                // trigger is small and real: 17 monomorphized local-protocol dispatch sites
                // (swift-syntax 4, Alamofire 4, TCA 7, SQLite.swift 1, console-kit 1).
                //   - SUPPRESS THE ARM: 5 effect losses and 7 entries REMOVED, and among them
                //     `_$willModify` goes from a disclosed `Unknown[dispatch:…]` to ABSENT. That is a
                //     purity claim manufactured by a fabrication fix — disqualified outright.
                //   - DISCLOSE `Unknown` INSTEAD: nothing goes silent (Unknown 10 539 → 10 540), but 9
                //     concrete effects degrade to a hedge. Traced, and the headline row is what decides
                //     it: TCA's `final class ScopedCore<Base: Core>: Core { func send() { base.send() } }`
                //     — `Base` is bounded by `Core`, EVERY one of the 8 in-scan conformers is a legal
                //     instantiation, and they compose, so the union IS the candidate set. Replacing it
                //     with `Unknown` trades a correct answer for a hedge.
                // The residual this leaves is real and general rather than protocol-specific: candor
                // does not specialize at call sites, so a generic function whose only instantiation in
                // THIS program is pure still carries the union. That is a statement about what a public
                // generic function can be asked to do, and it is the same answer any caller-agnostic
                // per-function analysis gives.
                else {
                    // RESTORED. Suppressing the type here (the first version of this fix) killed far
                    // more than the local-conformer CHA it was aiming at: `vars` is seeded from
                    // `info.params`, so the receiver lost typed resolution for the classifier AND for
                    // the SPEC §2 cross-package join — and `func upload(_ c: some Uploader) { c.send() }`
                    // went from Fs to ABSENT-and-pure against a chained report that named Uploader.send.
                    // The erasure distinction belongs on the CHA arm alone; it is recorded, not enforced,
                    // here.
                    info.params[pname] = tn
                    if isOpaqueParam(p.type) { info.opaqueParams.insert(pname) }
                }
            }
            // protocol COMPOSITION param (`_ x: A5 & B5`): `t.name` is nil (`typeName` does not collapse
            // a composition to one name — dispatch has to try EACH member, not pick one), so none of the
            // branches above fire and this param was left completely untyped: `x.a5()` inside `func
            // runComposed(_ x: A5 & B5) { x.a5() }` read silent-pure. Record every LOCALLY-declared
            // composed protocol (an imported one has no conformers here to dispatch over anyway); see
            // `protoCompositionSep`'s doc for the encoding and why it is safe through every other consumer.
            else if let comps = compositionTypeNames(p.type)?.filter({ protocolMethods[$0] != nil }), !comps.isEmpty {
                info.protoParams[pname] = comps.joined(separator: String(protoCompositionSep))
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
            if let sp = setterParam {
                info.paramNames.insert(sp)                   // a binder even when its type didn't resolve
                if let et = elemType { info.params[sp] = et }
            }
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
