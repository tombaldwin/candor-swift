// candor-swift — Pass B (per-function call collection with light local type inference).
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation
import SwiftSyntax
import CandorCore

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Pass B — calls per function, with light local type inference
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// The locator-move PRE-PASS (see `CallCollector.prescanLocatorMoves`). A single flow-insensitive sweep of
/// one function body recording every name whose value can move: `moved` for the name ITSELF (a whole-name
/// or compound assignment, an `inout` pass), `propWrites` for the property spellings written on it. The
/// caller decides which spellings are inert for the kind of binder it is holding — this class only reports.
final class LocatorMoveScanner: SyntaxVisitor {
    private(set) var moved: Set<String> = []
    private(set) var propWrites: [String: Set<String>] = [:]

    /// The ROOT identifier of an assignment target, plus the property spelling written on it (nil when the
    /// bare name itself is the target). A deeper target (`a.b.c = …`) reports its root with the OUTERMOST
    /// spelling, and `a.b` reaching through an unrecognised property already fails the caller's allowlist.
    private func record(target: ExprSyntax) {
        let lhs = CallCollector.peel(target)
        if let dr = lhs.as(DeclReferenceExprSyntax.self) {
            moved.insert(dr.baseName.text)
        } else if let ma = lhs.as(MemberAccessExprSyntax.self), let base = ma.base {
            let spelling = ma.declName.baseName.text
            var root = CallCollector.peel(base)
            // `self.p.launchPath = …` / `a.b.c = …` — walk to the leading identifier.
            while let inner = root.as(MemberAccessExprSyntax.self), let b = inner.base { root = CallCollector.peel(b) }
            if let dr = root.as(DeclReferenceExprSyntax.self) {
                propWrites[dr.baseName.text, default: []].insert(spelling)
            }
        } else if let sub = lhs.as(SubscriptCallExprSyntax.self) {
            // `xs[0] = …` — an element write; treat the container as moved (we cannot say which element).
            record(target: sub.calledExpression)
        }
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elems = Array(node.elements)
        for i in 1..<max(elems.count, 1) {
            // `x = y` parses as [lhs, AssignmentExpr, rhs]; `x += y` as [lhs, BinaryOperator("+="), rhs].
            var isAssign = elems[i].is(AssignmentExprSyntax.self)
            if let op = elems[i].as(BinaryOperatorExprSyntax.self) {
                let t = op.operator.text
                isAssign = t.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!=="].contains(t)
            }
            if isAssign { record(target: elems[i - 1]) }
        }
        return .visitChildren
    }

    /// `f(&p)` — the callee may write through the reference, so the name's value can move.
    override func visit(_ node: InOutExprSyntax) -> SyntaxVisitorContinueKind {
        if let dr = CallCollector.peel(node.expression).as(DeclReferenceExprSyntax.self) {
            moved.insert(dr.baseName.text)
        }
        return .visitChildren
    }

    // ── BINDER SITES, one count per name ────────────────────────────────────────────────────────
    // A name bound TWICE in one body is not a name a body-wide literal claim can be made about: the
    // claim is keyed by NAME, and the second binder is a DIFFERENT binding that happens to spell
    // itself the same way. `moved` is the same conservatism for the same reason one step along — it
    // refuses a name whose value can be reassigned — and a SHADOW is not a reassignment, so nothing
    // in `moved` records it. Counted here, in the pre-pass, so the refusal is body-wide and does not
    // depend on where in the walk the shadow happens to sit relative to the use.
    private(set) var binderCounts: [String: Int] = [:]
    private func countBinder(_ name: String) { binderCounts[name, default: 0] += 1 }

    /// `IdentifierPatternSyntax` is where the language puts every PATTERN binding — `let`/`var`
    /// declarations, `for`-in patterns, `case`/`if case`/`guard case` patterns, `catch` patterns,
    /// and optional bindings. Parameters are TOKENS rather than patterns, so the three overrides
    /// below cover the closure/nested-function forms; the ENCLOSING function's own parameters are
    /// not in its body at all and are handed in separately (see `prescanLocatorMoves`).
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        countBinder(node.identifier.text); return .visitChildren
    }
    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        countBinder((node.secondName ?? node.firstName).text); return .visitChildren
    }
    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        countBinder(node.name.text); return .visitChildren
    }
    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        countBinder((node.secondName ?? node.firstName).text); return .visitChildren
    }
}

/// One argument's disposition at a call site: a closure literal (its body is already charged to
/// the passer lexically), a named reference (resolvable to a unit), or opaque.
enum ArgKind { case closure, named(String), opaque }
struct Call { var path: String; var leaf: String; var strArg: String?; var typed: Bool; var args: [ArgKind] = []
              var argTypes: [String?] = []     // inferred simple type per positional arg (nil = unknown) — overloads
              var unqualified: Bool = false    // a bare DeclReference `name(…)` (free fn / ctor / self-sibling) —
                                               // NOT a `recv.member(…)` whose receiver type couldn't be resolved
                                               // (those must never be guessed onto a same-named sibling/free fn).
              // The receiver is an OPAQUE `some P` parameter. The type is still carried (the §2 dep join
              // and the classifier both need it, and both are SOUND here: every monomorphization must
              // conform to P, so P's own reported effects apply). Only the LOCAL-CONFORMER CHA must be
              // suppressed — the caller picks ONE conforming type, so unioning every local conformer's
              // effects fabricates. Suppressing the type itself, as the first version of this fix did,
              // took the dep join with it and made an Fs-performing function read PURE.
              var opaqueRecv: Bool = false
              /// ⟨0.23⟩ The NAME of the dependency factory this receiver was bound from — the other half
              /// of the `<untyped>.` marker. Half 1 needed only "no key could be formed"; half 2 needs to
              /// say WHICH function's return type would have formed it, and the callee name is the only
              /// evidence a bare Swift call site carries (see `depBoundLocals`).
              var depCallee: String? = nil
              /// R61 — true for the ONE `unqualified` shape that is NOT a call expression at all: a bare
              /// identifier passed as an ARGUMENT to some other call (`xs.map(loadFree)`), recorded so it
              /// can resolve to a genuine local free-function reference. Left `false` (the default) it
              /// would carry the same `unqualified` shape as a real `name(…)` call site, and the Driver's
              /// C-platform-import `native:` fallback (R61) cannot tell the two apart from `path` alone —
              /// `dlopen(path, RTLD_NOW)` synthesized exactly this shape for its plain Int32 ARGUMENT
              /// `RTLD_NOW` (this engine cannot resolve `dlopen`'s signature to know the parameter isn't
              /// closure-typed), and without this flag the fallback disclosed `native:RTLD_NOW` — a real
              /// boundary answer to a question that was never asked, since nothing here was CALLED.
              var argRef: Bool = false
              var extOwner: String? = nil }    // the RESOLVED receiver root of an otherwise-unmatched member
                                               // call (`c.fetch()` where c: RatesClient, an external type) —
                                               // carried ONLY for the §2 CANDOR_DEPS join key (`pkg#Owner.leaf`);
                                               // never consulted by local resolution, so behaviour without a
                                               // loaded dep report is unchanged.

final class CallCollector: SyntaxVisitor {
    /// Receiver marker for `super.m()`; resolved against the supertype chain in the driver.
    static let superMarker = "<super>"
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
                                            // A RESOLUTION table, so it is cleared on rebind and scoped
                                            // by the enclosing block — see `shadowName`.
    // CONST-STRING PROPAGATION — the module/global + static string-constant index (SIMPLE name → literal),
    // shared read-only across all fn units. `localConstStrings` overlays it with a `let NAME = "literal"`
    // bound INSIDE this fn body (a local const shadows a global of the same name). Both hold ONLY plain
    // string literals of a `let`; used to resolve a bare/interpolation-prefix/concat-left host reference
    // through the SAME host-refinement path as an inline literal — never a `var`, never a runtime value.
    let moduleConstStrings: [String: String]
    var localConstStrings: [String: String] = [:]
    var protoTyped: [String: String]        // param -> local protocol
    var arrayElem: [String: String]         // name -> element type of a `[T]` local/param (loop typing)
    var dictElem: [String: String]          // name -> VALUE type of a `[K: V]` local/param (dict loops)
    var tupleElem: [String: [String: String]]  // name -> tuple element types (`p.0` / `p.c`)
    let fields: [String: [String: (name: String?, isFunction: Bool)]]
    /// R73 — module-scope global NAME -> its concrete type, MODULE-SLICED by the Driver before
    /// construction (see `Driver.globalTypesByModule`). Consulted by `rootOf`'s bare-identifier branch,
    /// same rung as `vars`/`fields`: a local/param shadows a global of the same name (checked first via
    /// `vars`), an implicit-`self` field shadows a global too (checked next, matching real Swift lookup
    /// order — a type's own member wins over an outer-scope global of the same bare name) — a global is
    /// consulted only once neither of those answers. Before this table existed there was NOTHING for a
    /// module-scope global receiver to resolve through, so `worker.doWork()` fell to the untyped-name
    /// fallback and the call edge silently pointed at `worker` itself (which has no members) instead of
    /// `Worker.doWork` — SOUNDNESS.md R73.
    let globalTypes: [String: String]
    /// R73's loop sibling — module-scope `[T]` global name -> ELEMENT type, consulted by
    /// `elementTypeOf`'s bare-identifier branch the same way `globalTypes` is consulted by `rootOf`'s.
    let globalArrayElem: [String: String]
    let fieldArrayElem: [String: [String: String]]  // Type -> field -> [T] element (self.field loops)
    let fieldDictValue: [String: [String: String]]  // Type -> field -> [K: V] value
    let opaqueFields: [String: Set<String>]         // Type -> fields whose type is monomorphized
    let localTypes: Set<String>
    /// The modules THIS FILE imports, and the modules the SCANNED PROJECT itself defines. Together they
    /// decide whether a dotted callee (`Foundation.Process()`) is a MODULE-QUALIFIED SPELLING of a free
    /// name or an ordinary member access on a value. MEASURED before this was plumbed:
    /// `Foundation.Process()` reported NOTHING where the bare `Process()` reported `Exec` — one spelling
    /// of one constructor visible and its sibling not — and it cost the receiver as well, because the
    /// unclassified ctor left `let t = Foundation.Process()` untyped and the `t.run()` below it silent.
    /// `projectModules` is the anti-fabrication half: under `@testable import App`, `App.Process()` names
    /// the PROJECT's own type, not Foundation's, so the κ table must not answer for it.
    let importedModules: Set<String>
    let projectModules: Set<String>
    /// The CANDOR_DEPS/--workspace chain, so a bare free-call name can be shadowed by a CHAINED
    /// dependency's REAL declaration exactly as `localFreeFns` shadows a local one — see `depShadows`.
    /// Defaults to empty so every construction site that predates this field (tests, an unchained scan)
    /// is byte-identical: an empty `DepIndex` answers `isChained`/`lookup` false/nil for everything.
    let deps: DepIndex
    let declaredTypes: Set<String>  // types with a REAL local definition (NOT extension-only) — the shadow
                                    // discipline keys on this so a member call on an extension-only κ-platform
                                    // type (`self.launch()` in `extension Process`) reaches the κ table.
    /// Member names callable BARE on the enclosing type — its own plus every local supertype's. A bare
    /// `foo()` inside `struct Bar` that `Bar` declares is `self.foo()`, a purely local call; half 1's
    /// provenance conjunct treated it as a dependency factory and disclosed for it. Scoped to the
    /// ENCLOSING type rather than a flat leaf set, because widening the exclusion drops a genuine
    /// disclosure, which is the direction that costs soundness.
    let enclosingMembers: Set<String>
    let localFreeFns: Set<String>   // local free-function names — a bare `name(...)` call to one is the
                                    // project's OWN fn, so the platform free-call classifier (kappaFree)
                                    // must NOT fire (else a local `func NSLog`/`Pipe`-ctor fabricates)
    /// ⟨0.33.1⟩ Bare free-fn names whose ONLY declaration(s) reachable here sit inside a `#if`
    /// conditional-compilation block — see `FnInfo.isConditionallyCompiled` and the Driver's
    /// `conditionalOnlyFreeFnNamesByModule`/`conditionalOnlyFreeFnNames`. Disjoint from `localFreeFns` by
    /// construction (a name with even one unconditional declaration is in `localFreeFns` instead, and
    /// keeps winner-take-all — a real resolution exists). For a name in THIS set the shadow is lifted
    /// (`localFreeFns` does not contain it, so the κ heuristic below fires normally) and the bare call is
    /// ADDITIONALLY kept as an ordinary call edge to the conditional declaration, so the two readings
    /// UNION: whichever the real build keeps — the platform function the heuristic models, or the local
    /// declaration that may or may not exist — its effects are counted. Resolution is not FAILED here (a
    /// name with no local declaration at all resolves the heuristic outright, same as always); it is
    /// CONDITIONAL, and union rather than a single winner is the safe reading of "cannot tell which".
    let conditionallyShadowedFreeFns: Set<String>
    /// ⟨0.33.1⟩ THE TYPE ANALOGUE of `conditionallyShadowedFreeFns` — bare TYPE names (`Pipe`,
    /// `AVCaptureDevice`, `EKEventStore`, `NWBrowser`, …) whose ONLY declaration(s) reachable in this scan
    /// sit inside a `#if` (see `DeclCollector.declaredTypesUnconditional` and the Driver's
    /// `conditionallyShadowedTypeNames`). Disjoint from `declaredTypes` shadowing by construction: a name
    /// with even one UNCONDITIONAL declaration stays a normal shadow (still `declaredTypes.contains`,
    /// winner-take-all — a real resolution exists). Consulted ONLY by the four BARE-CONSTRUCTOR κ arms in
    /// `visit(FunctionCallExprSyntax)` (kappaFree, privacy-capture, Bonjour, EventKit) — deliberately NOT
    /// by any TYPED-RECEIVER member-dispatch arm (`kappaMember` via a resolved `base.root`). MEASURED WHY:
    /// widening this to the typed-receiver arms too (an earlier version of this fix did) changed 16
    /// swift-nio functions, several of which LOST their existing `Clock`/`Env`/`Unknown` in favour of a
    /// bare `Net` — `ClientBootstrap`'s OWN internal self-dispatch between its overloads is exactly the
    /// case a locally-declared type's shadow exists to protect (`declaredTypes.contains(rt)` at the typed
    /// arm), and `ClientBootstrap` is declared exactly once, inside `NIOPosix/Bootstrap.swift`'s file-wide
    /// `#if !os(WASI)`, so it reads as "conditional-only" with no alternate declaration anywhere — a
    /// materially different shape from a Windows-only STUB beside a real cross-platform declaration. A
    /// bare CONSTRUCTOR call has no such internal-self-dispatch risk, so the narrowing is confined here.
    let conditionallyShadowedTypes: Set<String>
    /// Swift stdlib free functions carved OUT of the half-1 provenance trigger, which cannot otherwise
    /// tell a bare `max(a, b)` from a bare imported `build()` — Swift spells both without a module root.
    ///
    /// THE PROPERTY EVERY ENTRY MUST SATISFY: the binding's type is fixed by the ARGUMENTS' types, or is
    /// `Void`. Then no dependency-chosen type can enter the function through the call, and a member call
    /// on the result cannot be a dependency reach. Entry by entry, rather than as a group:
    ///
    ///   max/min/abs    -> `T`, an argument's own type
    ///   swap           -> `Void` — there is no member to call on the result
    ///   zip            -> `Zip2Sequence<S1, S2>`
    ///   stride         -> `StrideTo<T>` / `StrideThrough<T>`
    ///   repeatElement  -> `Repeated<T>`     (stdlib structs generic over the ARGUMENTS' types)
    ///
    /// FOUR ENTRIES DID NOT SATISFY IT and were removed. The doc comment asserting the property is what
    /// kept them here — standing-bar item 9, a justification stated in a comment is not a proof:
    ///
    ///   withUnsafePointer, withoutActuallyEscaping — return the TRAILING CLOSURE's own result, and the
    ///       closure body can call anything:
    ///       `let c = withoutActuallyEscaping(mk) { _ in DepLib.buildClient() }; c.fetch()` read pure.
    ///   unsafeDowncast — returns the `to:` argument's NAMED type, which the caller picks and which is
    ///       very often a dependency class: `unsafeDowncast(o, to: DepLib.LibClient.self)`.
    ///   sequence — NOT for the reason it looks like. It returns `UnfoldFirstSequence<T>` /
    ///       `UnfoldSequence<T, State>`, a stdlib type, not the closure's result. But in the
    ///       `state:next:` overload the ELEMENT type `T` is the CLOSURE's, not an argument's, and both
    ///       overloads share the bare name this set is keyed on — so `sequence` is not PROVEN, and an
    ///       entry that is not proven does not belong in a denylist of proven-safe cases.
    ///   numericCast — returns a target type inferred from CONTEXT, not from an argument.
    ///
    /// What the list omits costs precision (a spurious `Unknown`), never soundness — measured: removing
    /// the four adds ZERO markers across pollen and candor-swift, chained and unchained.
    ///
    /// Residual, stated rather than hidden: a dependency's protocol EXTENSION on a stdlib type
    /// (`extension Sequence { func depFetch() }`) makes a member call on a stdlib-typed value a
    /// dependency reach. That is universal — it applies to every literal and every stdlib value in the
    /// program — so it is not what this list governs, and no entry here is carved out on its strength.
    ///
    /// THE LIBM BLOCK was added after instrumenting the conjunct on 14 real targets: with the local-name
    /// widening in place it still fired 153 times, and the largest remaining false population was `sin`
    /// (7), `cos` (5), `atan2` (5), `sqrt` (4), `pow` (3), `asin` (3). Each satisfies the criterion by
    /// its SIGNATURE — `(Double) -> Double`, `(Float) -> Float` — so a member call on the result is a
    /// member call on a floating-point value. That is the same argument the block above makes, applied
    /// to a family rather than to seven names; it is not a judgement about what the callees do.
    static let PURE_STDLIB_FREE_FNS: Set<String> = [
        "max", "min", "abs", "swap", "zip", "stride", "repeatElement",
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh",
        "sqrt", "cbrt", "pow", "exp", "exp2", "log", "log2", "log10", "hypot",
        "floor", "ceil", "round", "trunc", "fmod", "fabs",
    ]
    /// Member spellings that are NEVER a property accessor, however the receiver types. `T.init` is an
    /// initializer reference, `T.self` a metatype value, `T.Type`/`T.Protocol` metatype spellings — none
    /// of them can run an accessor body, so no accessor unit in a dependency's report can legitimately
    /// answer them. Consumed only by the `propertyExternal` candidate gate.
    static let METATYPE_MEMBERS: Set<String> = ["init", "self", "Type", "Protocol"]
    /// Names bound to a value whose type is caller-MONOMORPHIZED rather than erased, so the conformers
    /// visible here are not its candidate witnesses (see `isOpaqueParam`). Three sources, all the same
    /// question under different spellings: a `some P` parameter; a binder that takes its type from a
    /// `[some P]` / `[T]`-where-`T: P` element (`for x in xs`, `xs.forEach { $0 … }`); and `self`'s
    /// element in an `extension Array where Element: P`. Consumed ONLY by the local-conformer CHA arm.
    var monoNames: Set<String> = []
    /// Names whose ARRAY ELEMENT type is monomorphized — the container form of `monoNames`, kept in
    /// lockstep with `arrayElem`: every write to one writes the other, so a rebind can never leave a
    /// stale opacity sitting behind a fresh type. SCOPED exactly like `monoNames`
    /// (see `enterShadowScope`): the lockstep gets the CLEAR half of the discipline right and says
    /// nothing about the RESTORE half, and an inner block's monomorphized `let` of an existing name
    /// suppressed the CHA on the ERASED binding it shadowed for the rest of the function.
    var opaqueElem: Set<String> = []
    let localProtocols: Set<String> // local protocol names — a receiver typed as one is DISPATCH
    let returns: [String: String]   // unambiguous factory return types (the candor-scan move)
    /// Locals bound from a CALL whose return type we could not determine, where the callee is not a local
    /// function — `let s = build()` with `build` living in a dependency. The value's PROVENANCE is known
    /// (a call out of this target) even though its TYPE is not, which is the "could-not-form-a-key" case:
    /// a later `s.save()` asks no question of the chained report, so the report's silence licenses nothing.
    /// See candor-spec/DEP-RECEIVER-TYPING-DESIGN.md half 1. The CHAINED conjunct is applied in Driver,
    /// which is where fileImports and the covered-package set live.
    var depBoundLocals: [String: String] = [:]
    let enumCaseValueType: [String: String]  // unambiguous enum case -> associated value type
    var enclosingType: String?
    var selfElementType: String?   // self's element bound in a collection extension (R28)
    var calls: [Call] = []
    var directEffects: Set<String> = []
    /// A capture whose media type this function did NOT make statically visible — a bare
    /// `AVCaptureSession()`, or a device call whose media-type argument is a computed value.
    ///
    /// DEFERRED rather than resolved at the call site, because the answer is a property of the FUNCTION.
    /// Charging Camera+Mic the moment a bare session appeared made the commonest camera-only idiom in
    /// iOS — construct a session, add a `.video` device — report Mic, and a shipping app (Bitwarden, a
    /// QR scanner with no microphone key) was told its manifest was wrong. The over-disclosure is right
    /// when nothing in the function says which medium; it is a fabrication when the next line says.
    var ambiguousCapture = false
    /// Capture effects this function established from a VISIBLE media type. Their presence is what
    /// resolves `ambiguousCapture`; their absence is what leaves the over-disclosure standing.
    var determinateCapture: Set<String> = []

    /// Fold a deferred ambiguous capture into the function's effects. Called once, after the whole body
    /// has been walked, so `determinateCapture` is complete.
    func resolveAmbiguousCapture() {
        guard ambiguousCapture else { return }
        if determinateCapture.isEmpty {
            directEffects.insert("Camera")
            directEffects.insert("Mic")
        }
    }
    /// SPEC §2 `fs` — the read/write kinds this function's OWN Fs calls revealed. Accumulated only from
    /// verbs that actually say; a verb that does not contributes nothing, so an undetermined direction
    /// stays undetermined rather than defaulting to one side.
    var fsKinds: Set<String> = []
    /// `privacy/2` — per privacy EFFECT, the read/write directions this function's own calls revealed.
    /// Same direct-only discipline as `fsKinds`: an undetermined direction stays undetermined.
    var privacyKinds: [String: Set<String>] = [:]
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
    /// Locals bound to a home-anchored path expression — `let p = NSHomeDirectory() + "/Desktop"`.
    var homeAnchoredLocals: [String: String] = [:]
    /// Home-anchored paths rung 4 resolved — so the `incomplete` marker can be withdrawn.
    var resolvedHomePaths: Set<String> = []
    /// Set by `recordSurfaces` when rung 4 resolved THIS call's destination; read by the call site
    /// immediately after, so a resolved path is not then marked undetermined. Marking a determined
    /// folder incomplete would be the ⊤-count inflation reintroduced one layer down.
    var lastResolvedHomePath = false
    /// A protocol-typed dispatch site. The ARGUMENT SHAPE travels with it: the Driver resolves the
    /// extension-PROVIDED half of the member space through the same overload machinery the typed-call path
    /// uses, and without argc/argTypes an overloaded provided member (`extension TokenConsumer { func
    /// at(_: TokenSpec); func at(_: SyntaxText) }`) could only be unioned or dropped. MEASURED on
    /// swift-syntax/swift-protobuf/firebase: dropping it lost 19 units' worth of sibling-overload edges.
    /// `argc < 0` means the site carries no argument shape (an operator witness) — union every overload.
    struct ProtoDispatch {
        let proto: String, member: String
        var argc: Int = -1
        var argTypes: [String?] = []
        var args: [ArgKind] = []
    }
    var protoDispatches: [ProtoDispatch] = []
    var protoPropReads: [(proto: String, member: String)] = []  // protocol PROPERTY/subscript reads — CHA
    // IMPLICIT-STRINGIFICATION dispatch: a PROTOCOL-typed (existential / generic-bound) operand of an
    // interpolation / `String(describing:)` / `print` — the `description`/`debugDescription` witness that
    // runs belongs to the CONFORMER, so it is resolved by CHA over the conformers in the Driver. SEPARATE from
    // `protoPropReads` because the member is NOT a declared requirement of the local protocol (the
    // `protoOrSuperDeclares` gate would drop it) and because an unresolvable conformer set must NOT
    // become `Unknown` here: interpolation is pervasive in Swift, and a conformer that doesn't declare a
    // `description` uses the stdlib's PURE default — so this rung is precise-or-nothing, never a flood.
    var stringifyDispatches: [(proto: String, member: String)] = []
    // IMPLICIT STRINGIFICATION over an operand whose type is NOT declared in the analysed code —
    // `"\(e)"` where `e: DepLib.Entry`. Neither index above can name the witness (a dep type is in
    // neither `localTypes` nor `localProtocols`), so the site recorded NOTHING and an effectful
    // dependency `description` was absorbed silently. `Type.member` candidates, resolved ONLY against a
    // chained sibling report in the Driver (`<Module>#<Type>.<member>`, the key the dep's own report
    // already carries) — with no dep report loaded nothing consults this set, so the unchained analysis
    // is byte-identical. See candor-spec/SOUNDNESS-VEIN-crossing-the-scan-boundary.md.
    var stringifyExternal: Set<String> = []
    // DEINIT GLUE (R33) over a type declared OUTSIDE the analysed code — a chained DEPENDENCY's class,
    // constructed and held as a non-escaping local, whose `deinit` runs at scope exit. `Type.deinit`
    // candidates, resolved ONLY against a sibling report in the Driver (`<Module>#<Type>.deinit`).
    var deinitExternal: Set<String> = []
    // A PROPERTY ACCESSOR READ on a type declared OUTSIDE the analysed code — `l.v` where `L` is a chained
    // dependency's type and `v` is a computed/lazy/static property whose body performs I/O. `Type.member`
    // candidates, resolved ONLY against a sibling report in the Driver (`<Module>#<Type>.<member>`, which
    // is exactly the key the dep's own report already carries, `unitKind: "accessor"`). With no dep report
    // loaded nothing consults this set, so the unchained analysis is byte-identical. Sibling of
    // `stringifyExternal`/`deinitExternal`; see candor-spec/SCAN-BOUNDARY-WORK-QUEUE.md §3c.
    var propertyExternal: Set<String> = []
    var globalReads: Set<String> = []     // bare-name reads — candidate edges to GLOBAL initializer units
    var boundLocals: Set<String> = []     // EVERY local binding name (even literal/unresolved-type ones,
                                          // which `vars` drops) — so a bare read / fn-ref of a SHADOWING
                                          // local isn't mistaken for an implicit-self property or a free fn.
                                          // FUNCTION-WIDE and monotone: `Driver` reads it after the walk,
                                          // where "is this a local" has no lexical position to be asked at.
    /// ENUM-CASE PAYLOAD BINDINGS — `case let .x(a)` / `case .x(let a)` — as a SEPARATE, LEXICALLY SCOPED
    /// set, and the separation is the whole safety argument rather than tidiness.
    ///
    /// They belong with `boundLocals`: a payload binding is a local, and until it said so a bare read of
    /// one charged the enclosing type's same-named property and passing one as an argument charged a
    /// same-named FREE FUNCTION (see `typeEnumCaseBinding`). But `boundLocals` is FUNCTION-WIDE, and a
    /// payload binding's scope is the one `case` or `if case` body — so putting them in it suppresses the
    /// genuine property read that follows the block. Measured, on swift-syntax's `IfConfigDiagnostic`:
    /// `if case .integerLiteralCondition(let syntax, _) = self { … }` … `return Diagnostic(node: syntax)`
    /// — the trailing `syntax` IS the property, and the function-wide spelling of this fix dropped that
    /// edge. A silent under-report manufactured by a fabrication fix, which is the thing the standing bar
    /// says to expect.
    ///
    /// SO WHY NOT SCOPE `boundLocals` ITSELF? Because `Driver` reads it once, at the END of the walk, and
    /// a restored set is empty there: scoping it makes `if c { let helper = { }; helper() }` edge to a
    /// same-named FREE FUNCTION and charge its effects to the caller. MEASURED, and pinned by
    /// `scopingBoundLocalsWouldUnshadowTheDriverGuard`. Scoping also un-masks a SEPARATE latent
    /// fabrication one door over — a bare read of a PARAMETER charging the enclosing type's same-named
    /// property, which today only stays hidden because some inner binder happens to have poisoned the
    /// function-wide set (swift-syntax `TokenKind.fromRaw`). Both are filed in the work queue; neither is
    /// this change's to fix, and a second set is what lets this change not depend on either.
    private var casePayloadLocals: Set<String> = []
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
         globalTypes: [String: String] = [:], globalArrayElem: [String: String] = [:],
         declaredTypes: Set<String>,
         localProtocols: Set<String>, returns: [String: String],
         fieldArrayElem: [String: [String: String]], fieldDictValue: [String: [String: String]],
         opaqueFields: [String: Set<String>] = [:],
         enumCaseValueType: [String: String], dynamicMemberTypes: Set<String>,
         propertyWrapperTypes: Set<String>, wrappedProps: [String: [String: String]],
         localFreeFns: Set<String>, conditionallyShadowedFreeFns: Set<String> = [],
         conditionallyShadowedTypes: Set<String> = [], typeAliases: [String: String],
         enclosingMembers: Set<String> = [],
         opaqueSeqBuilders: Set<String>, seqBuilderConcrete: [String: String],
         closureFields: [String: Set<String>], moduleConstStrings: [String: String] = [:],
         importedModules: Set<String> = [], projectModules: Set<String> = [], deps: DepIndex = DepIndex()) {
        self.importedModules = importedModules
        self.projectModules = projectModules
        self.deps = deps
        self.moduleConstStrings = moduleConstStrings
        self.opaqueSeqBuilders = opaqueSeqBuilders
        self.seqBuilderConcrete = seqBuilderConcrete
        self.closureFields = closureFields
        self.typeAliases = typeAliases
        self.localFreeFns = localFreeFns
        self.conditionallyShadowedFreeFns = conditionallyShadowedFreeFns
        self.conditionallyShadowedTypes = conditionallyShadowedTypes
        self.enclosingMembers = enclosingMembers
        self.propertyWrapperTypes = propertyWrapperTypes
        self.wrappedProps = wrappedProps
        self.dynamicMemberTypes = dynamicMemberTypes
        self.enumCaseValueType = enumCaseValueType
        self.vars = info.params
        self.selfElementType = info.selfElementType
        self.fnTyped = info.fnTypedParams
        self.protoTyped = info.protoParams
        self.monoNames = info.opaqueParams
        self.opaqueElem = info.opaqueArrayParams
        self.arrayElem = info.arrayParams
        self.dictElem = info.dictParams
        self.tupleElem = info.tupleParams
        self.fields = fields
        self.globalTypes = globalTypes
        self.globalArrayElem = globalArrayElem
        self.fieldArrayElem = fieldArrayElem
        self.fieldDictValue = fieldDictValue
        self.opaqueFields = opaqueFields
        self.localTypes = localTypes
        self.declaredTypes = declaredTypes
        self.localProtocols = localProtocols
        self.returns = returns
        self.enclosingType = info.enclosingType
        self.bodyRootID = info.body?.id
        self.bodyIsStoredInitializer = info.body.map { Self.isStoredInitializerBody(Syntax($0)) } ?? false
        super.init(viewMode: .sourceAccurate)
    }

    /// The unit body this collector was handed, so `constructionEscapes`' ancestor walk STOPS there.
    /// SwiftSyntax nodes keep their parent links, so an unbounded walk would climb out of a nested
    /// `func` or closure into the ENCLOSING declaration and read ITS `return` as this construction's
    /// escape — a FALSE escape, i.e. a silent under-report, which is the direction that must never be
    /// left to chance.
    private let bodyRootID: SyntaxIdentifier?

    /// True when this unit's BODY IS a stored declaration's initializer expression — a stored property
    /// (`let imageViews = [AnimatedImageView(), …]`, collected onto the type's synthesized `init`) or a
    /// file-level global. E4 in `constructionEscapes` cannot see these: the walk starts INSIDE the
    /// initializer and stops at the body root before it ever reaches the `PatternBinding` that would
    /// say "stored". MEASURED, not predicted — Kingfisher's `GIFHeavyViewController` charged its
    /// synthesized init the `Unknown` of four `AnimatedImageView.deinit`s that run when the VIEW
    /// CONTROLLER dies, and swift-crypto's `emptyStorage` global the same way. Whatever such an
    /// expression builds is retained by the declaration, so nothing in it is released here.
    private let bodyIsStoredInitializer: Bool

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
    /// `mono` says the resolved type is a caller-MONOMORPHIZED generic (a `some P` param, a `[T: P]`
    /// element binder, a `T`-typed field of a generic type) rather than an erased existential — see
    /// `monoNames`. It travels WITH the resolution rather than being re-derived at the call site,
    /// because the same receiver spelling can resolve through vars, a field, or a subscript element,
    /// and only the resolving branch knows which one answered.
    private func rootOf(_ raw: ExprSyntax, _ depth: Int = 0) -> (root: String?, isVar: Bool, path: [String], mono: Bool) {
        // Receiver chains recurse with the syntactic nesting (`a.b.c…`, ternary arms, subscript bases —
        // the last via elementTypeOf/dictValueOf, which call back here). Real receivers nest <10 deep;
        // a pathological/generated expression could otherwise overflow the stack. Past a generous bound,
        // give up resolving the type (root = nil = untyped receiver) — the SAFE direction (the call may
        // under-report, never a crash), exactly what an unresolvable receiver already yields.
        if depth > 200 { return (nil, false, [], false) }
        let expr = Self.peel(raw)
        // `super.m()` — an explicit call to the SUPERCLASS's implementation. It is not a DeclReference, so it
        // fell through this resolver entirely and the call was dropped: `override func load() { super.load() }`
        // and `func run() { super.other() }` both read silent-pure while the base's `load`/`other` carried the
        // effect two lines up. Resolving it to the ENCLOSING type would be wrong for the override case (the
        // edge would point at the overriding method itself and add nothing), so mark it and let the driver
        // walk the supertype chain, skipping the enclosing type.
        if expr.is(SuperExprSyntax.self) { return (Self.superMarker, true, [], false) }
        if let dr = expr.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            // `self` (instance) and `Self` (the enclosing TYPE, used for `Self.staticMethod()`) both resolve
            // to the enclosing type for member resolution — so `Self.decode(…)` is a precise typed call on the
            // type, not a guessed bare member that would either drop or mis-link to a same-named sibling.
            if n == "self" || n == "Self" { return (enclosingType, true, [], false) }
            if let t = vars[n] { return (t, true, [n], monoNames.contains(n)) }
            // IMPLICIT SELF: a bare identifier inside a method body can be a FIELD of the
            // enclosing type (`handler.log(s)` ≡ `self.handler.log(s)`) — the protocol-field probe
            // found dispatchers resolving as raw names and missing the field index entirely.
            if let et = enclosingType, let f = fields[et]?[n], let ft = f.name {
                return (ft, true, [n], opaqueFields[et]?.contains(n) == true)
            }
            // R73 — a MODULE-SCOPE GLOBAL `let`/`var` receiver (`worker.doWork()` where `let worker =
            // Worker()` sits at file scope). Checked after locals/params and implicit-self fields, which
            // is the real Swift lookup order — either would otherwise SHADOW a global of the same bare
            // name. Before this branch existed the identifier fell straight to the untyped-name fallback
            // below, which returns `isVar: false` — so the terminal owner-resolution arm in
            // `visit(FunctionCallExprSyntax)` treated `worker` as neither a typed receiver nor a valid
            // extension owner and dropped the call edge entirely. The caller's only surviving edge came
            // from a SEPARATE mechanism (a lazy-global-read edge straight to the global's own unit,
            // Driver.swift's `cc.globalReads` handling) — which points at the global, not the method,
            // and the global itself has no effects. That produced `invoke -> ["worker"]` with `worker`
            // a dead end and `Worker.doWork` disconnected: the caller's effects collapsed to empty and it
            // vanished from `functions[]` outright (SOUNDNESS.md R73).
            if let t = globalTypes[n] { return (t, true, [n], false) }
            // a bare TYPE/alias reference (`FM.default`, the base of a static-member chain): resolve a
            // typealias to its underlying type so κ keys on the real spelling (`FM`→`FileManager`).
            return (dealias(n), false, [n], false)
        }
        if let ma = expr.as(MemberAccessExprSyntax.self) {
            // tuple element/member: `p.0` / `p.c` where p is a tuple-typed local/param
            if let baseDR = ma.base?.as(DeclReferenceExprSyntax.self),
               let elemType = tupleElem[baseDR.baseName.text]?[ma.declName.baseName.text] {
                return (elemType, true, [], false)
            }
            let inner = ma.base.map { rootOf($0, depth + 1) } ?? (root: nil, isVar: false, path: [], mono: false)
            let member = ma.declName.baseName.text
            // WALK THROUGH A FIELD: if the chain so far is a local type with `member` as a stored
            // field, the chain's type becomes the FIELD's type — so `self.client.send()` /
            // `outer.inner.save()` resolve the method on the field's type, not the enclosing type
            // (explicit `self.field.method()` and field-of-field chains otherwise resolved against the
            // wrong type and dropped to pure — the bare-identifier implicit-self path already did this).
            if let rt = inner.root, let f = fields[rt]?[member], let ft = f.name, !f.isFunction {
                return (ft, true, inner.path + [member], opaqueFields[rt]?.contains(member) == true)
            }
            return (inner.root, inner.isVar, inner.path + [member], inner.mono)
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            // `Svc().act()` — a constructor call types the chain; a FACTORY's unambiguous return
            // type does too (`db.makeStatement(...).execute()` — the GRDB shape).
            if let ctor = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let n = ctor.baseName.text
                // `Proc()` where `typealias Proc = Process` — the ctor types the value as the aliased
                // type so its members classify (`p.run()`→Exec). A LOCAL type shadows (dealias no-ops).
                if n.first?.isUppercase == true { return (dealias(n), true, [n], false) }
                if let rt = returns[n] { return (rt, true, [n], false) }
            }
            // `AVAudioSession.sharedInstance()` — a SINGLETON FACTORY METHOD on a type, returning an
            // instance of that type by convention. `SINGLETON_ACCESSORS` already covers the PROPERTY
            // spellings (`FileManager.default`, `URLSession.shared`); the parenthesised form is a call
            // and fell through here, so `AVAudioSession.sharedInstance().setCategory(.record)` resolved
            // to no root at all — the microphone entry point every recording app uses, reading pure.
            // Restricted to the conventional NAMES on an uppercase base: a factory whose return type is
            // recorded is already handled above, and guessing Self for an arbitrary static method is the
            // free-factory fabrication a previous review caught.
            if let fm = call.calledExpression.as(MemberAccessExprSyntax.self),
               let fb = fm.base?.as(DeclReferenceExprSyntax.self),
               fb.baseName.text.first?.isUppercase == true,
               SINGLETON_FACTORY_METHODS.contains(fm.declName.baseName.text),
               returns[fm.declName.baseName.text] == nil {
                return (dealias(fb.baseName.text), true, [fb.baseName.text], false)
            }
            // `Outer.Inner()` — a NESTED-TYPE constructor: the callee is a member-access spelling a dotted
            // TYPE path (`Outer.Inner`), not a factory member. When that dotted path is a known local type,
            // the value carries it so its methods resolve (`let i = Outer.Inner(); i.wipe()` → Fs). Checked
            // BEFORE the factory-return path so a nested ctor isn't mistaken for a `.member`-named factory.
            if let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
               let dotted = dottedTypePath(Syntax(ma)), localTypes.contains(dealias(dotted)) {
                return (dealias(dotted), true, [ma.declName.baseName.text], false)
            }
            // `Foundation.Process()` — a MODULE-QUALIFIED constructor. The qualifier is a SPELLING of the
            // bare name, so the value carries the same type the bare `Process()` gives it. Without this
            // the binding typed as NOTHING and every member call on it went silent: the classification of
            // the ctor itself (charged in the member-call path) is only half of what a missing spelling
            // costs — `let t = Foundation.Process(); try t.run()` lost the LAUNCH as well.
            if let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
               let mod = ma.base?.as(DeclReferenceExprSyntax.self)?.baseName.text, isModuleQualifier(mod),
               ma.declName.baseName.text.first?.isUppercase == true {
                let n = ma.declName.baseName.text
                return (dealias(n), true, [n], false)
            }
            if let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
               let rt = returns[ma.declName.baseName.text] {
                return (rt, true, [ma.declName.baseName.text], false)
            }
            return (nil, false, [], false)
        }
        // `coll[i]` — an array subscript yields the element type, a dictionary subscript the value
        // type (`cs[0].send()` / `d["k"]?.send()` resolved against the bare base and dropped to pure).
        if let sub = expr.as(SubscriptCallExprSyntax.self) {
            if let e = elementTypeOf(sub.calledExpression, depth + 1) {
                return (e.name, true, [], e.mono)
            }
            if let v = dictValueOf(sub.calledExpression, depth + 1) {
                return (v, true, [], false)   // a `[K: V]` VALUE is never bound-resolved (see dictValueOf)
            }
        }
        // SwiftParser leaves operators UNFOLDED, so `x as! T` and `cond ? a : b` are SequenceExprs:
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            // `x as! T` / `x as? T` → `[operand, unresolvedAsExpr, typeExpr]`: the type is the result.
            if elems.count == 3, elems[1].is(UnresolvedAsExprSyntax.self),
               let te = elems[2].as(TypeExprSyntax.self), let t = typeName(te.type).name {
                return (t, true, [], isOpaqueParam(te.type))
            }
            // `cond ? a : b` → `[cond, unresolvedTernaryExpr(then), elseExpr]`: both arms one type.
            //
            // OPACITY COMPOSES BY CONJUNCTION, and it is the only join in this resolver that has to
            // decide. `mono` is a claim that the value is caller-MONOMORPHIZED, which is what licenses
            // SUPPRESSING the local-conformer CHA; the receiver of `(c ? m : e).speak()` is `m` on one
            // branch and `e` on the other, so the claim holds of the expression only if it holds of
            // EVERY arm. Disjunction let one monomorphized arm speak for an ERASED sibling: with
            // `m: some Speaker` and `e: any Speaker` both arms resolve to the root `Speaker`, the guard
            // below passes, and the CHA was skipped for the erased arm too — a positive purity claim on
            // a function that performs the conformer's effect whenever `c` is false. The mirror is
            // asserted beside it: an ALL-monomorphized ternary must stay suppressed, or this re-opens
            // the fabrication d62dd69/02fb0ad closed.
            if elems.count == 3, let tern = elems[1].as(UnresolvedTernaryExprSyntax.self) {
                let a = rootOf(tern.thenExpression, depth + 1), b = rootOf(elems[2], depth + 1)
                // MEASURED rather than assumed (standing bar item 8): instrumented over 14 real Swift
                // targets the join fires 12 times and every one is ERASED/ERASED, so the corpus cannot
                // tell `&&` from `||` and is the fabrication CONTROL here, not the evidence — the
                // fixtures are. The probe is not shipped: `rootOf` is the hot path, and an env read
                // here charged Env+Fs to 26 of candor's OWN functions in its self-scan.
                if let ra = a.root, ra == b.root, a.isVar, b.isVar {
                    return (ra, true, [], a.mono && b.mono)
                }
            }
        }
        return (nil, false, [], false)
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

    /// `privacy/1` finding 5 — the statically-visible AVFoundation media-type of a capture call. Reads the
    /// leading-dot member name of the `for:` argument on `AVCaptureDevice.default(for:)` / `.devices(for:)`
    /// (`.audio`→"audio", `.video`→"video"; also `AVMediaType.audio`/`.video` spelled in full). Returns nil
    /// when the media type is NOT statically visible — no such arg (a bare `AVCaptureSession()`), or a
    /// computed/variable value (`for: mt`) — so the caller over-discloses BOTH sensors (never under-declare).
    /// The AVAudioSession category argument, on exactly `mediaTypeArg`'s pattern: a leading-dot or
    /// fully-qualified static member is readable, anything computed is not — and "not readable" means
    /// AMBIGUOUS, which `privacyAudioSessionEffects` resolves by charging Mic.
    /// The `FileManager.urls(for:in:)` search-path constant — `mediaTypeArg`'s pattern a third time.
    /// Unreadable ⇒ nil ⇒ NO folder class, unlike the capture/audio cases which over-disclose. The
    /// asymmetry is deliberate: an unreadable MEDIA TYPE still means a capture is happening, whereas an
    /// unreadable search path is overwhelmingly an app-scoped directory that needs no key at all, and
    /// charging all three folders on every `urls(for:)` call would fabricate on ordinary code. The miss
    /// is caught by the undetermined-path disclosure instead.
    /// Is a `.bonjour(…)` service descriptor among these arguments? mDNS by definition, so this needs no
    /// over-disclosure rule: a descriptor that is not bonjour is simply not local-network.
    private func bonjourDescriptorArg(_ args: LabeledExprListSyntax) -> Bool {
        for a in args {
            guard let call = Self.peel(a.expression).as(FunctionCallExprSyntax.self),
                  let m = call.calledExpression.as(MemberAccessExprSyntax.self) else {
                if let ma = Self.peel(a.expression).as(MemberAccessExprSyntax.self),
                   ma.declName.baseName.text == "bonjour" { return true }
                continue
            }
            if m.declName.baseName.text == "bonjour" || m.declName.baseName.text == "bonjourWithTXTRecord" {
                return true
            }
        }
        return false
    }

    private func searchPathArg(_ args: LabeledExprListSyntax) -> String? {
        for a in args where a.label?.text == "for" {
            if let ma = Self.peel(a.expression).as(MemberAccessExprSyntax.self) {
                return ma.declName.baseName.text
            }
            return nil
        }
        return nil
    }

    private func audioCategoryArg(_ args: LabeledExprListSyntax) -> String? {
        for a in args where a.label == nil || a.label?.text == "category" {
            if let ma = Self.peel(a.expression).as(MemberAccessExprSyntax.self) {
                return ma.declName.baseName.text
            }
            return nil
        }
        return nil
    }

    /// Three-valued, because "no media argument exists" and "a media argument exists and is computed"
    /// are DIFFERENT FACTS and only one of them may be deferred. See `MediaTypeArg`.
    enum MediaTypeArg {
        /// `.audio` / `.video` — statically visible.
        case determined(String)
        /// A media-type argument IS present and is not statically readable (a var, a computed value).
        /// This call is an INDEPENDENT capture source of unknown medium: nothing else in the function
        /// speaks for it, so it must charge BOTH here and now.
        case undetermined
        /// No media-type position at all — a bare `AVCaptureSession()`, a `startRunning()`. The medium
        /// comes from the devices this function adds, so this one may be DEFERRED to the whole-body
        /// resolution and dropped if a sibling call names the medium.
        case absent
    }
    private func mediaTypeArgKind(_ args: LabeledExprListSyntax) -> MediaTypeArg {
        // A LABELLED `for:`/`mediaType:` WINS OVER AN UNLABELLED POSITIONAL. Taking the first argument
        // that could be the media type read the deviceType of the commonest setup call there is —
        // `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)` — saw
        // `.builtInWideAngleCamera` was neither `.audio` nor `.video`, and returned `.undetermined`
        // without ever looking at the `for: .video` sitting two arguments along. A camera-only function
        // charged Mic, which is the exact user-facing complaint the deferral was built to kill, coming
        // back through a different overload. The unlabelled arm still matters — `devices(.audio)` — so
        // it stays, as the FALLBACK it should always have been.
        func classify(_ expr: ExprSyntax) -> MediaTypeArg {
            if let ma = Self.peel(expr).as(MemberAccessExprSyntax.self) {
                let name = ma.declName.baseName.text
                if name == "audio" || name == "video" { return .determined(name) }
            }
            return .undetermined
        }
        for a in args where a.label?.text == "for" || a.label?.text == "mediaType" {
            return classify(a.expression)
        }
        for a in args where a.label == nil {
            return classify(a.expression)
        }
        return .absent
    }

    private func mediaTypeArg(_ args: LabeledExprListSyntax) -> String? {
        // `mediaType:` TOO — `AVCaptureDevice.DiscoverySession(deviceTypes:mediaType:position:)` spells
        // the same discriminant with a different label, and reading only `for:`/positional made that
        // call ambiguous. Ambiguous over-discloses BOTH, so a camera-only QR scanner was charged Mic:
        // Bitwarden, on the App Store without a microphone key, was told its manifest was wrong. The
        // over-disclosure rule is deliberate and stays — but it must fire on calls whose media type is
        // genuinely undetermined, not on ones spelled with the other label.
        for a in args where a.label?.text == "for" || a.label?.text == "mediaType" || a.label == nil {
            let e = Self.peel(a.expression)
            // `.audio` / `.video` — a leading-dot member access (contextual enum-like static member).
            if let ma = e.as(MemberAccessExprSyntax.self) {
                let name = ma.declName.baseName.text
                // Fully-qualified `AVMediaType.audio` too — the terminal member carries the discriminant.
                if name == "audio" || name == "video" { return name }
            }
            // an arg is present but not a recognized static media type (a var, a computed value) → ambiguous.
            return nil
        }
        return nil  // no `for:`/positional media-type arg at all (a bare capture) → ambiguous
    }

    /// `privacy/2` — is `toShare:` a literal `nil`? The canonical read-only HealthKit authorization, and
    /// the one case where the argument that discriminates read from write IS statically visible. Returns
    /// nil when the label is absent or its value is anything else (a Set, a variable) — ambiguous, and
    /// the caller then declares both.
    private func toShareIsNilArg(_ args: LabeledExprListSyntax) -> Bool? {
        for a in args where a.label?.text == "toShare" {
            return Self.peel(a.expression).is(NilLiteralExprSyntax.self) ? true : false
        }
        return nil
    }

    /// `privacy/2` — EventKit's entity-type discriminant, the exact analog of `mediaTypeArg`. EKEventStore
    /// serves calendars AND reminders and the choice is per call (`requestAccess(to: .event)`,
    /// `predicateForReminders(in:)`), so a statically-visible `.event`/`.reminder` refines and anything
    /// else is ambiguous → both. Same shape, same trade-off, deliberately the same code shape so the two
    /// cannot drift into different rules for the same problem.
    private func entityTypeArg(_ args: LabeledExprListSyntax) -> String? {
        for a in args where a.label?.text == "to" || a.label?.text == "for" || a.label == nil {
            let e = Self.peel(a.expression)
            if let ma = e.as(MemberAccessExprSyntax.self) {
                let name = ma.declName.baseName.text
                if name == "event" || name == "reminder" { return name }
            }
            return nil   // an arg is present but not a recognized entity type → ambiguous
        }
        return nil       // no entity-type arg at all → ambiguous
    }

    // CONST-STRING PROPAGATION — the value of a KNOWN string constant named `name` (a local `let` shadows a
    // module/global of the same name), or nil if it is not a resolvable const. Conservative: only names in
    // the const-string indexes — a `var`, a runtime/computed value, an unknown name → nil (never guess).
    private func constValue(_ name: String) -> String? {
        localConstStrings[name] ?? moduleConstStrings[name]
    }

    // ── LOCATOR MOVE PRE-PASS ───────────────────────────────────────────────────────────────────────
    // Locator provenance is a claim about the value a name holds AT THE CALL, but this walk is flow-
    // INSENSITIVE: it records a binding when it reaches the declaration and reads it when it reaches the
    // call, in SOURCE order. A rebind that is later in the text — or earlier in TIME, because the pair sits
    // in a loop — would leave a stale literal standing and the report would name a destination the program
    // never contacts. That is the fabrication mirror of the under-report this whole vein closes, so the
    // claim is not made at all for any name whose value can move ANYWHERE in the body.
    //
    // "Can move" is deliberately coarse and computed up front, before a single call is collected: a
    // whole-name assignment (`p = other`), a compound assignment, an `inout` pass (`&p`), or a property
    // write. Property writes are then filtered by an ALLOWLIST of spellings proven not to move the
    // locator — `req.httpMethod = "POST"` is the reason a `var` binder is usable at all, since URLRequest
    // cannot be configured any other way — and everything unrecognised counts as a move. Allowlist, not
    // denylist, because the direction here is RELAXING: an unknown property might be `req.url`.
    private var movedNames: Set<String> = []            // the name itself was reassigned / passed inout
    private var propWrites: [String: Set<String>] = [:] // name → the property spellings written on it

    /// Property writes that provably do NOT move the locator of a `URLRequest`/`URL` binder: they set the
    /// method, body, headers and caching knobs. `url`/`mainDocumentURL` are POINTEDLY absent.
    private static let LOCATOR_INERT_WRITES: Set<String> = [
        "httpMethod", "httpBody", "httpBodyStream", "allHTTPHeaderFields", "cachePolicy",
        "timeoutInterval", "networkServiceType", "allowsCellularAccess", "allowsExpensiveNetworkAccess",
        "allowsConstrainedNetworkAccess", "httpShouldHandleCookies", "httpShouldUsePipelining",
        "assumesHTTP3Capable", "attribution",
    ]
    /// The same idea for a `Process` handle: writes that configure the child WITHOUT changing which program
    /// is executed. `arguments` is inert BY THE FAMILY'S RULE — the Exec surface is argv[0], the HEAD, and a
    /// literal `"curl"` in `arguments` must not refine the cliff (conformance `exec_dyn_head`).
    private static let PROCESS_INERT_WRITES: Set<String> = [
        "arguments", "environment", "currentDirectoryPath", "currentDirectoryURL",
        "standardInput", "standardOutput", "standardError", "qualityOfService", "terminationHandler",
    ]
    /// The two spellings that DO name the program a `Process` will execute.
    private static let PROCESS_LOCATOR_WRITES: Set<String> = ["launchPath", "executableURL"]

    /// True when `name` may hold a different value at a use site than at its binding — see `movedNames`.
    /// `inert` is the spelling allowlist for this binder's kind.
    private func locatorNameIsStable(_ name: String, inert: Set<String>) -> Bool {
        if movedNames.contains(name) { return false }
        return (propWrites[name] ?? []).isSubset(of: inert)
    }

    /// Names bound MORE THAN ONCE in this unit — counting the function's own parameters as binders.
    /// A body-wide, name-keyed literal claim about such a name is a claim about two bindings at once,
    /// so it is not made at all (see `LocatorMoveScanner.binderCounts` and `recordProcessRun`).
    private var multiplyBoundNames: Set<String> = []

    /// Walk the body ONCE before collection and fill `movedNames`/`propWrites`. Driven from the Driver so
    /// the ordering is explicit rather than an accident of which visitor happens to fire first.
    /// `params` are the ENCLOSING function's parameter names: they are binders that are not IN the body,
    /// and a body binder that shadows one is exactly the shape this refuses.
    func prescanLocatorMoves(_ body: some SyntaxProtocol, params: Set<String> = []) {
        let s = LocatorMoveScanner(viewMode: .sourceAccurate)
        s.walk(body)
        movedNames = s.moved
        propWrites = s.propWrites
        multiplyBoundNames = Set(s.binderCounts.filter { $0.value + (params.contains($0.key) ? 1 : 0) > 1 }.keys)
    }

    // ── PROCESS COMMAND PROVENANCE ──────────────────────────────────────────────────────────────────
    // `Process()` takes NO command: the program is named by a PROPERTY WRITE (`p.launchPath = "/bin/sh"`,
    // `p.executableURL = URL(fileURLWithPath: …)`) and executed later by `p.run()`/`p.launch()`, which take
    // no argument at all. The direct-argument rule therefore saw no literal anywhere on the Foundation
    // subprocess surface, so EVERY `Process` form yielded no `cmds` — `allow Exec` failed closed over all
    // of it, and the `classifyCommandHead` cliff refinement (a visible `curl` reaching Net) never fired.
    // These two maps carry the write forward to the launching verb.
    //
    // BOTH ARE BODY-WIDE AND NAME-KEYED, AND NEITHER IS IN `ShadowSave` — which is correct for the
    // second (a refusal must survive its scope) and was a FABRICATION in the first. A `let p` inside a
    // block that SHADOWS an outer handle wrote its literal under the outer name, and the outer
    // `p.launch()` below the block then reported a program that handle was never given:
    //
    //     func f(make: () -> Process) {
    //         let p = make()                                        // locator unknown, never written here
    //         if true { let p = Process(); p.launchPath = "/bin/x" } // a DIFFERENT binding
    //         p.launch()                                            // reported cmds: ["/bin/x"]
    //     }
    //
    // `movedNames` does not cover it, because a shadow is not a rebind — nothing assigns to the outer
    // `p`, so there is nothing for the move pre-pass to record. `execLocatorInvisible` does not cover it
    // either: the outer handle takes no write at all here, so no refusal is ever raised. The gate is the
    // binder COUNT (`multiplyBoundNames`) — a name with two binder sites in one unit is not a name a
    // body-wide claim can be made about — and it lives at the READ (`recordProcessRun`) rather than at
    // the write, so the suppressing half stays monotone.
    //
    // ⟨THE OVERWRITE⟩ THE LITERALS ARE NOT A UNION — A WRITE THAT DOMINATES AN EARLIER ONE KILLS IT.
    // Straight-line, one handle, two writes:
    //
    //     p.executableURL = URL(fileURLWithPath: "/bin/sh")
    //     p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    //     try? p.run()                              // reported cmds: ["/bin/sh", "/bin/zsh"]
    //
    // Only `/bin/zsh` can run, so `/bin/sh` was on the surface for no execution that exists, and
    // `allow Exec /bin/zsh` failed on it. FAIL-CLOSED — a spurious failure, never a missed one — so this
    // is a false positive rather than the cardinal sin, which is why it is fixed narrowly rather than
    // aggressively. It was worth fixing anyway because THE ENGINE'S TWO LOCATOR MECHANISMS DISAGREED
    // ABOUT ONE SHAPE: the URL/URLRequest path REFUSES on a straight-line rebind (`u = URL(…)` puts the
    // name in `movedNames` and no host is claimed at all), while this path unioned. One of the two had to
    // move, and withholding here would have cost every genuine single-write `Process` its command.
    //
    // THE RULE, and it is the whole safety argument: a write W kills an earlier write V **iff W's
    // enclosing statement list is V's list or an ANCESTOR of it**. That is exactly "control reaching W's
    // successor has passed through W and can no longer be carrying V". Each recorded literal therefore
    // travels with the CHAIN of statement lists enclosing it, and the test is `W.list ∈ V.chain`.
    //
    // The three shapes this is deliberately unable to collapse, all of which MUST stay unioned — each is
    // pinned by a test, because the fixture that proves the false positive closed cannot show the reach
    // closed with it:
    //
    //   - `p.launchPath = A; if c { p.launchPath = B }; p.run()` — B is in a NESTED list, so it does not
    //     kill A, and if `c` is false A is what runs.
    //   - `p.launchPath = A; if c { p.launchPath = B; p.launchPath = C; p.run() }` — C kills B (same
    //     list) but NOT A (A's list is an ancestor of C's, not a descendant), and the outer read below
    //     the block still sees A.
    //   - anything inside a CLOSURE or a nested function: the chain STOPS at that boundary, so an
    //     outer write never kills a closure's and vice versa. An escaping closure runs at a time this
    //     walk cannot order.
    //
    // AND `execLocatorInvisible` IS NOT SUBJECT TO IT. A literal that dominates an unreadable write does
    // in fact overwrite it, so clearing the refusal would be *correct* — and it is the one direction here
    // that turns a refusal into a claim. The whole surface's value is that it fails closed; a relaxation
    // whose only support is the same dominance argument that is being introduced in the same commit is
    // not one to take on trust. The refusal stands, and a mixed literal/runtime handle still reports
    // nothing.
    private struct LocatorWrite {
        let lit: String
        /// The statement lists enclosing this write, innermost outward, stopping at the nearest closure or
        /// nested-function boundary. A later write kills this one iff its own list is in here.
        let enclosing: Set<SyntaxIdentifier>
    }
    private var execLocatorWrites: [String: [LocatorWrite]] = [:]  // name → the live literal writes, in order
    private var execLocatorInvisible: Set<String> = []             // name → some write was NOT statically known

    /// The chain of `CodeBlockItemList`s enclosing `node`, innermost outward, STOPPING at the nearest
    /// closure / nested-function boundary (see `LocatorWrite.enclosing`). The first element is the list the
    /// write itself is a statement of — the one a later sibling write must match to kill it.
    private static func enclosingStatementLists(_ node: Syntax) -> [SyntaxIdentifier] {
        var out: [SyntaxIdentifier] = []
        var cur: Syntax? = node.parent
        while let n = cur {
            if n.is(ClosureExprSyntax.self) || n.is(FunctionDeclSyntax.self)
                || n.is(InitializerDeclSyntax.self) || n.is(DeinitializerDeclSyntax.self)
                || n.is(AccessorDeclSyntax.self) { break }
            if n.is(CodeBlockItemListSyntax.self) { out.append(n.id) }
            cur = n.parent
        }
        return out
    }

    /// `p.launchPath = <expr>` / `p.executableURL = <expr>` on a bare local. Records the literal, or the
    /// fact that there was a write we could not read — which is the half that keeps the gate closed.
    private func recordProcessLocatorWrite(_ elems: [ExprSyntax]) {
        for i in 1..<max(elems.count, 1) where elems[i].is(AssignmentExprSyntax.self) && i + 1 < elems.count {
            guard let ma = Self.peel(elems[i - 1]).as(MemberAccessExprSyntax.self),
                  Self.PROCESS_LOCATOR_WRITES.contains(ma.declName.baseName.text),
                  let base = ma.base,
                  let dr = Self.peel(base).as(DeclReferenceExprSyntax.self) else { continue }
            let name = dr.baseName.text
            // THE RHS IS THE WHOLE REMAINDER, not the next element. A `SequenceExpr` is FLAT: the parser
            // gives `p.launchPath = "/usr/bin/" + tool` as [lhs, =, "/usr/bin/", +, tool], so reading
            // `elems[i + 1]` yielded the literal `"/usr/bin/"` and reported THAT as the program — a
            // fabricated command that `allow Exec /usr/bin/` would then have certified for an entirely
            // runtime program. Found by the A/B, on a negative control in the corpus, after 25 fixtures
            // had passed. Re-wrapping the remainder hands `resolveConstString` the concatenation it
            // already knows how to refuse (or resolve, when the head is a genuine const).
            let tail = Array(elems[(i + 1)...])
            let rhs: ExprSyntax = tail.count == 1
                ? tail[0]
                : ExprSyntax(SequenceExprSyntax(elements: ExprListSyntax(tail)))
            // `resolveConstString` carries the mechanism-1 ctor unwrap, so `URL(fileURLWithPath: "/bin/sh")`
            // and a const-anchored `let tool = "/bin/sh"` both resolve here through one resolver.
            if let lit = plainStringLiteralValue(rhs) ?? resolveConstString(rhs) {
                // ⟨THE OVERWRITE⟩ kill every earlier write this one dominates — see `LocatorWrite`. When
                // the write sits in no statement list at all (a top-level expression, or a shape this walk
                // does not reach a list from) the chain is empty, nothing matches, and the behaviour is the
                // union it always was.
                let chain = Self.enclosingStatementLists(Syntax(ma))
                if let mine = chain.first {
                    execLocatorWrites[name]?.removeAll { $0.enclosing.contains(mine) }
                }
                execLocatorWrites[name, default: []]
                    .append(LocatorWrite(lit: decodeEscapes(lit), enclosing: Set(chain)))
            } else {
                execLocatorInvisible.insert(name)
            }
        }
    }

    /// SPEC §1 ⟨0.32⟩ — **CONFIGURING an invocation is the capability, exactly as constructing and
    /// launching one are.** `t.arguments = argv` / `t.executableURL = u` on a `Process` this function
    /// RECEIVED hands its caller back a fully-armed child, and this engine charged NOTHING for it: the
    /// unit was absent from `functions` (a purity claim, ⟨0.21⟩) and the tree passed `deny Exec` at exit
    /// 0. Splitting build from launch across two functions must not make the builder invisible.
    ///
    /// Every write on a proven handle is charged; `environment` is REDIRECTED to `Env` (java's ruling on
    /// `ProcessBuilder.environment()`), and the READ direction is the carve-out — `let a = t.arguments`
    /// arms nothing and reaches no code here, because a read is not an assignment.
    ///
    /// Compound assignment counts. `t.arguments += ["-x"]` is a read-modify-WRITE that leaves the child
    /// armed exactly as `=` does; SwiftParser spells it as a `BinaryOperatorExpr` rather than an
    /// `AssignmentExpr`, which is the sort of second spelling this project keeps finding on the wrong
    /// side of a fix. The comparison operators that merely END in `=` are excluded by name.
    private func recordInvocationConfigWrite(_ elems: [ExprSyntax]) {
        for i in 1..<max(elems.count, 1) where Self.isAssignment(elems[i]) {
            guard let ma = Self.peel(elems[i - 1]).as(MemberAccessExprSyntax.self),
                  let base = ma.base, isInvocationValue(base),
                  let eff = kappaPropertyWrite(root: "Process", member: ma.declName.baseName.text)
            else { continue }
            directEffects.insert(eff)
        }
    }

    /// `=` or a compound assignment (`+=`, `*=`, …) — NOT a comparison that happens to end in `=`.
    private static func isAssignment(_ e: ExprSyntax) -> Bool {
        if e.is(AssignmentExprSyntax.self) { return true }
        guard let op = e.as(BinaryOperatorExprSyntax.self)?.operator.text else { return false }
        // `~=` is Swift's PATTERN-MATCH operator, not an assignment — it ends in `=` like the comparisons.
        return op.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!==", "~="].contains(op)
    }

    /// **True when `expr` IS a `Process` handle — not merely a chain whose root typed as one.**
    ///
    /// The whole-type rule of §1 ⟨0.32⟩ is charged only through this predicate, and the reason is a real
    /// over-charge it would otherwise make: `rootOf` walks a member chain and KEEPS the root it started
    /// with, so `t.arguments.joined()` answers root `Process`, member `joined` — a read-back of argv that
    /// a blanket whole-type rule would charge `Exec`. The question the rule needs answered is about the
    /// RECEIVER, so it is asked of the receiver EXPRESSION: a bound name, a stored property, `self` in
    /// the type's own extension, or a constructor result. Anything else falls through to the verb floor
    /// (`PROCESS_MEMBERS`), which under-reports rather than fabricates.
    ///
    /// A locally DECLARED `Process` always shadows — `declaredTypes` is the same fence every κ path uses,
    /// and it is what keeps a project's own `class Process` (the lookalike control) pure.
    private func isInvocationValue(_ raw: ExprSyntax) -> Bool {
        guard !declaredTypes.contains("Process") else { return false }
        let expr = Self.peel(raw)
        if let dr = expr.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            if let t = vars[n] { return dealias(t) == "Process" }
            if let et = enclosingType, let f = fields[et]?[n], let ft = f.name { return dealias(ft) == "Process" }
            return false
        }
        if let ma = expr.as(MemberAccessExprSyntax.self), let base = ma.base {
            // `self.child` / `outer.inner.child` — a STORED PROPERTY typed `Process`.
            let inner = rootOf(base)
            if let rt = inner.root, let f = fields[rt]?[ma.declName.baseName.text], let ft = f.name,
               !f.isFunction { return dealias(ft) == "Process" }
            return false
        }
        // `Process().run()` / `Foundation.Process().run()` — the ctor result IS the handle.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let dr = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                return dealias(dr.baseName.text) == "Process"
            }
            if let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
               let mod = ma.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
               isModuleQualifier(mod) { return dealias(ma.declName.baseName.text) == "Process" }
        }
        return false
    }

    /// True when a dotted callee's base names an imported MODULE rather than a value or a local type —
    /// `Foundation.Process()`, `AVFoundation.AVCaptureSession()`. See `importedModules`.
    private func isModuleQualifier(_ name: String) -> Bool {
        guard importedModules.contains(name), !projectModules.contains(name) else { return false }
        if vars[name] != nil || localTypes.contains(name) { return false }
        if let et = enclosingType, fields[et]?[name] != nil { return false }
        return true
    }

    /// A bare free-call NAME is shadowed by a CHAINED (`--workspace`/`CANDOR_DEPS`) dependency's REAL
    /// declaration, exactly as `localFreeFns` shadows a same-package one — the sibling half of the
    /// `shellOut` fix. `localFreeFns` only sees names THIS file's own module declares; a name declared in
    /// an imported LOCAL package (JohnSundell's ShellOut vendored as a workspace dep, say) is invisible to
    /// it, so a bare `shellOut(to: .gitInit())` in the CONSUMER fell straight to the platform heuristic —
    /// `deny Fs`/`deny Ipc` exited 0 with "nothing hidden" over a call that plainly reaches both, via the
    /// dependency's own `shellOut(ShellOutCommand) -> shellOut(String) -> Process.launchBash` chain (the
    /// 0.33.0 gate-level cardinal sin). ONLY this file's own imports are consulted, and ONLY a package a
    /// loaded report actually chains — the §2 never-guess rule: an unimported/unchained module's same name
    /// never shadows, so an out-of-tree/unresolvable `shellOut` (no such package in scope) still reaches
    /// the heuristic, which is the one place it is still needed.
    func depShadows(_ name: String) -> Bool {
        for m in importedModules where deps.isChained(m) {
            if deps.lookup("\(m)#\(name)") != nil { return true }
        }
        return false
    }

    /// The member-call κ answer, with SPEC §1 ⟨0.32⟩'s whole-type rule applied to a receiver PROVEN to be
    /// a subprocess handle. `kappaMember`'s `Process` entry stays the verb FLOOR for every other receiver
    /// (an `extension Process`'s implicit self, a stale chain root) — see `PROCESS_MEMBERS`.
    private func memberEffect(root: String, member: String, receiver: ExprSyntax?) -> String? {
        if root == "Process", let r = receiver, isInvocationValue(r) {
            return processCapabilityEffect(member: member)
        }
        return kappaMember(root: root, member: member)
    }

    /// **AN EXTENSION IS NOT A DECLARATION — AND THE EDGE IT MIGHT NEED IS KEPT ANYWAY.**
    ///
    /// The four κ free-call ctor arms in `visit(FunctionCallExprSyntax)` fence on `declaredTypes`, not
    /// `localTypes`, because `extension Process { var tag: String … }` says the project EXTENDS
    /// Foundation's type: the constructor it calls is still Foundation's, and `Process()` is still the
    /// subprocess capability. Fenced on `localTypes` — which `pushType` fills from extensions too — ONE
    /// extension anywhere in the scan zeroed the constructor PACKAGE-WIDE (the scan's name sets are
    /// per-package, so that is the blast radius). MEASURED, not hypothesised: swift-syntax has a
    /// single `extension Process` (Logger.swift) and its `ProcessRunner.init` — `process = Process()`
    /// plus three configuring writes — reported `Env` alone. A class whose only subprocess contact is
    /// construction read pure across the whole package. The member-call path has always reasoned this
    /// way (`declaredTypes`, the ShellOut cardinal-sin fix); the free-call path did not. The sibling
    /// route, one more time.
    ///
    /// **THE OBVIOUS FIX — SWAP THE FENCE — WAS A/B'd AND REVERTED, AND THIS FUNCTION IS WHY.** An
    /// extension may supply a `convenience init`, and when it does, the call resolves to a REAL LOCAL
    /// UNIT. The fall-through arm at the end of this chain was what emitted that edge; the swapped fence
    /// preempts the arm, so the edge disappeared with it. Measured then: 91 firebase-ios-sdk units
    /// changed and the majority LOST a true `Env`. Killing a silent under-report is exactly where the
    /// next one gets introduced.
    ///
    /// So the fix charges κ *and* keeps the edge, and it keeps it by emitting the SAME `Call` the
    /// fall-through arm would have emitted — same path, same literal, same arg kinds — for exactly the
    /// set that arm used to serve (`localTypes` minus `declaredTypes`: extension-only). The delta over
    /// the previous behaviour is therefore ADDITIVE BY CONSTRUCTION: every edge that existed still
    /// exists, and a κ effect is added beside it. That is a property of the code, not a hope about the
    /// corpus, and the corpus A/B agrees (zero effects lost).
    ///
    /// Consulting what the extension DECLARES — shadowing only when it offers an `init` — was considered
    /// and is strictly weaker: it leaves `Process()` silent in every target whose extension happens to
    /// declare one, which is the same defect with a smaller trigger. The union needs no such reading,
    /// and if the call really does resolve to a convenience init, that init still constructs the
    /// platform type, so the κ effect is true of it as well.
    private func keepExtensionCtorEdge(_ name: String, _ node: FunctionCallExprSyntax, lit: String?) {
        guard localTypes.contains(name), !declaredTypes.contains(name) else { return }
        calls.append(Call(path: name, leaf: name, strArg: lit, typed: false,
                          args: argKinds(node), argTypes: argTypesOf(node), unqualified: true))
    }

    /// ⟨0.33.1⟩ THE CONDITIONAL-TYPE SIBLING of `keepExtensionCtorEdge` — UNION, not winner-take-all: a
    /// bare ctor arm fired (kappaFree, privacy-capture, Bonjour, EventKit, or the Data/String content-read
    /// family) because `name` matched a κ spelling with no UNCONDITIONAL local declaration shadowing it,
    /// but `conditionallyShadowedTypes` says a `#if`-gated one DOES exist — a build that actually compiles
    /// that branch runs IT, not the platform meaning the heuristic just charged. Keep the ordinary call
    /// edge to the conditional declaration alive too, so its own effects (if it has any beyond the stub
    /// shape this was found on) are counted ALONGSIDE the κ charge rather than discarded — the same
    /// discipline `conditionallyShadowedFreeFns` established for free functions. A no-op when `name` has
    /// no local declaration at all, or an unconditional one (that case already shadowed outright, above).
    private func unionConditionalTypeEdge(_ name: String, _ node: FunctionCallExprSyntax, lit: String?) {
        guard conditionallyShadowedTypes.contains(name) else { return }
        calls.append(Call(path: name, leaf: name, strArg: lit, typed: false,
                          args: argKinds(node), argTypes: argTypesOf(node), unqualified: true))
    }

    /// **THE `Data`/`NSData`/`String` CONTENT-READ CONSTRUCTOR — ONE FUNCTION, BOTH SPELLINGS.**
    /// `Data(contentsOfFile:)` / `Data(contentsOf:)` and their `Foundation.`-qualified twins. Returns
    /// true when it classified, false when the name/label pair is not this ctor (or a local declaration
    /// shadows it), so the caller falls through to the arms it always reached.
    ///
    /// It exists as a function, rather than as an arm of the free-call chain, because it was the last
    /// free-name family keyed on the CALLEE NODE instead of on a name: ⟨0.32⟩ made a module qualifier a
    /// spelling for the κ table and the three privacy ctor families, and this arm — the only one that
    /// reads a FILE — kept answering one spelling. Measured: `Foundation.Data(contentsOf: u)` reported
    /// `Clock` alone where `Data(contentsOf: u)` reported `Clock, Unknown`, and
    /// `Foundation.Data(contentsOf: URL(string: "https://…")!)` reported no `Net` at all.
    ///
    /// `shadowable` IS THE ONE THING THE TWO CALL SITES DISAGREE ABOUT, and it is the same disagreement
    /// every other family has: the BARE spelling is shadowed by a local declaration of the name, the
    /// QUALIFIED one is not — naming the module is precisely how Swift code reaches Foundation's `Data`
    /// from a file that declares its own. The bare guard is `declaredTypes`/`localFreeFns`, the fence
    /// every κ path uses, and it CLOSES A MEASURED FABRICATION this extraction surfaced: a project's own
    /// `struct Data { init(contentsOfFile:) }` was charged `Fs`, and its `init(contentsOf:)` acquired an
    /// `Unknown`, because this arm — alone among the free-name families — applied no shadow guard at all.
    /// An extension-only `extension Data {…}` does NOT shadow (`declaredTypes`, not `localTypes`): a
    /// project that extends Foundation's `Data` is still calling Foundation's ctor.
    ///
    /// RESIDUAL, MEASURED AND FILED RATHER THAN LEFT TO BE DISCOVERED: `declaredTypes` is keyed on the
    /// SIMPLE NAME and is PACKAGE-WIDE, so a NESTED or `fileprivate` declaration shadows further than
    /// Swift's own resolution does — swift-syntax has a `fileprivate enum Data` nested in `Node`, and in
    /// a single-package scan that silences a real `Data(contentsOfFile:)` in another file. That
    /// imprecision is NOT introduced here: measured at ⟨0.32⟩ HEAD, a nested `fileprivate enum Pipe`
    /// already silences `Pipe()` package-wide, so this arm now shares the fence every κ family has
    /// rather than inventing one. (It cost nothing on the corpus A/B: swift-syntax keeps its nested
    /// `Data` and its content reads in DIFFERENT packages, so no unit moved.) The escape hatch is the
    /// spelling rule directly above — `Foundation.Data(contentsOfFile:)` is charged whatever the package
    /// declares, which is measured in `ModuleQualifierSpellingProcessTests`.
    private func chargeContentsCtor(_ name: String, _ node: FunctionCallExprSyntax, lit: String?,
                                    shadowable: Bool) -> Bool {
        guard ["Data", "NSData", "String"].contains(name) else { return false }
        if shadowable, localFreeFns.contains(name) { return false }
        // ⟨0.33.1⟩ the SAME conditional-only carve-out the other four bare-ctor arms got: a name whose
        // ONLY local declaration(s) sit inside a `#if` (`conditionallyShadowedTypes`) does not bail this
        // arm out — an UNCONDITIONAL declaration still does (real resolution exists, winner-take-all).
        // MEASURED RESIDUAL this closes: a `#if`-gated local `Data`/`NSData`/`String` silently dropped
        // the WHOLE `Fs` charge here (not even `Unknown`) — worse than the other four arms, which at
        // least fall through to an ordinary (if unresolved) call edge; this one returned `false` all the
        // way out with no side effect at all, so the caller charged nothing whatsoever.
        if shadowable, declaredTypes.contains(name), !conditionallyShadowedTypes.contains(name) { return false }
        let label = node.arguments.first?.label?.text
        if label == "contentsOfFile" {
            // `String(contentsOfFile: path, …)` / `Data(contentsOfFile:)` take a FILE PATH, not a
            // URL — there is no scheme to resolve, so this is UNCONDITIONALLY a file read → Fs.
            // (The `contentsOf:` scheme-resolution path below would have let it fall through to
            // pure — the 1725d0a guard keyed on `contentsOf` only — the review's under-report find.)
            directEffects.insert("Fs")
            // ⟨0.29⟩ …AND ITS DIRECTION, which the comment above already proves: "UNCONDITIONALLY a
            // file read". See the write site below for the measurement and why this matters.
            fsKinds.insert("read")
            recordSurfaces(effect: "Fs", lit: lit)
            if lit == nil {
                // CONSTANT PROVENANCE rung 4 — the literal was unreadable, but a HOME-ANCHORED
                // expression still names a protected folder: `NSHomeDirectory() + "/Desktop/x"` is
                // the spelling real code uses, and the class is decided by the proved prefix. Only
                // when that also fails is the destination genuinely undetermined.
                let resolved = node.arguments.lazy.compactMap { self.homeAnchoredPath($0.expression) }.first
                if let r = resolved, !pathClasses(r).isEmpty {
                    for c in pathClasses(r) { directEffects.insert(c) }
                } else {
                    incompleteSurfaces.insert("Fs")
                }
            }
            unionConditionalTypeEdge(name, node, lit: lit)
            return true
        }
        if label == "contentsOf" {
            // `Data/String(contentsOf: url)` reads from a URL that is EITHER a file (Fs) or a
            // remote endpoint (Net) — exactly one is true, but which depends on the URL's scheme.
            // Asserting BOTH (the old behaviour) always FABRICATES the wrong one — a file read
            // reported Net, a network read reported Fs (a fabrication — the precision failure; caught fabricating Net
            // on SwiftFormat's config reads, where the URL is a fileURLWithPath from a helper).
            // Resolve the scheme when it's statically provable; otherwise it's an indeterminate
            // effect we can't categorise → honest `Unknown`, never a guess.
            // ⟨0.29⟩ THE `contentsOf:` ARGUMENT, not the whole argument list. `node.arguments
            // .description` is a text search over EVERY argument, which is the "literal anywhere"
            // hazard this rung removed from `Fs`/`Net`/`Db`/`Exec` wearing different clothes: a
            // scheme in a trailing argument would decide the category of a URL it is not.
            let urlArgText = node.arguments.first?.expression.description ?? ""
            if urlArgText.contains("fileURLWithPath") || urlArgText.contains("filePath:") {
                directEffects.insert("Fs") // a provably-FILE URL
            } else if urlArgText.contains("\"http://") || urlArgText.contains("\"https://")
                        || urlArgText.contains("\"ftp://") {
                directEffects.insert("Net") // a literal remote URL
                // ⟨0.29⟩ …AND CAPTURE ITS HOST. This branch proved a remote endpoint and recorded no
                // `hosts`, so `String(contentsOf: URL(string: "https://sentry.io/api")!)` — the
                // idiomatic Foundation one-line GET — came back with an EMPTY Net surface while
                // `URLSession.shared.dataTask(with:)` on the same URL captured `sentry.io`. The gate
                // failed CLOSED (AS-EFF-008, "no visible literal"), so nothing was ever certified
                // wrongly; the cost was that `allow Net` could not be used for this shape at all, and
                // a `deny Net[unknown-host]` fired on a host the classifier can plainly read.
                // Routed through `recordSurfaces` so the host, the ⟨0.13⟩ model-host refinement and
                // the destination-class derivation all behave exactly as on every other Net call.
                recordSurfaces(effect: "Net", lit: lit)
            } else {
                unresolved = true // indeterminate scheme: I/O happens, category unprovable
                why.insert("contentsOf:indeterminate-url-scheme")
            }
            unionConditionalTypeEdge(name, node, lit: lit)
            return true
        }
        return false
    }

    /// Charge `Module.Name(…)` exactly as the BARE `Name(…)` free-call path charges it, and report
    /// whether anything was charged. Returns false — leaving the call to the arms it always reached —
    /// when the bare spelling would classify nothing, so this can only ADD the spellings that were
    /// invisible.
    ///
    /// The FIVE families are the five the free-call path runs, in ITS order, and each one delegates to
    /// the same function that path delegates to (`chargeContentsCtor`, `privacyCaptureEffects`,
    /// `bonjourDescriptorArg`, `privacyEventKitEffects`, `kappaFree`) so the two spellings cannot answer
    /// differently about what an effect IS. `ExecCapabilityProcessTests` asserts the parity on a Process,
    /// a Date, a URL and a UUID; `ModuleQualifierSpellingProcessTests` asserts it as a LOOP over every
    /// classified ctor spelling — the invariant, not the one row that was found broken.
    ///
    /// `chargeContentsCtor` is FIRST because it is first in the bare chain, and it is a shared function
    /// rather than a re-implementation for the reason this whole helper exists: the `Data`/`String`
    /// content-read arm was the ONE free-name family that stayed keyed on a `DeclReferenceExpr` callee
    /// when ⟨0.32⟩ made the qualifier a spelling, so `Foundation.Data(contentsOf: url)` read pure while
    /// `Data(contentsOf: url)` did not. A family that lives in a function BOTH call sites invoke cannot
    /// drift again; one that is spelled out twice already has.
    ///
    /// The local-shadow guards the bare path applies (`localTypes`/`localFreeFns`) are DELIBERATELY NOT
    /// applied here: a module qualifier exists precisely to name the module's version when a local
    /// declaration would otherwise shadow it, so `Foundation.Process()` in a file that also declares its
    /// own `Process` is Foundation's. `isModuleQualifier` already refuses when the qualifier is the
    /// project's OWN module (`@testable import App` — `App.Process()` is the project's type).
    private func chargeModuleQualifiedSpelling(_ name: String, _ node: FunctionCallExprSyntax,
                                               lit: String?) -> Bool {
        // The `Data`/`String` content-read ctor, on the UN-dealiased name — the bare chain keys that arm
        // on the written name too, and parity with the bare spelling is the invariant here.
        if chargeContentsCtor(name, node, lit: lit, shadowable: false) { return true }
        let alias = dealias(name)
        if PRIVACY_CAPTURE_TYPES.contains(alias) {
            switch mediaTypeArgKind(node.arguments) {
            case .determined(let mt):
                for e in privacyCaptureEffects(mediaType: mt) { directEffects.insert(e); determinateCapture.insert(e) }
            case .undetermined:
                directEffects.insert("Camera"); directEffects.insert("Mic")
            case .absent:
                ambiguousCapture = true
            }
            return true
        }
        if alias == "NWBrowser" || alias == "NetServiceBrowser" {
            if bonjourDescriptorArg(node.arguments) { directEffects.insert("LocalNetwork") }
            if let eff = kappaFree(name: alias, argCount: node.arguments.count) { directEffects.insert(eff) }
            return true
        }
        if PRIVACY_EVENTKIT_TYPES.contains(alias) {
            for e in privacyEventKitEffects(entityType: entityTypeArg(node.arguments)) { directEffects.insert(e) }
            return true
        }
        guard let eff = kappaFree(name: alias, argCount: node.arguments.count) else { return false }
        let est = isEstablishingFree(effect: eff, name: alias)
        directEffects.insert(eff)
        if eff == "Fs" { let ks = fsKind(root: alias, member: "<init>")
                          if ks.isEmpty { fsKinds.insert("?") } else { for k in ks { fsKinds.insert(k) } } }
        if eff == "Llm" { directEffects.insert("Net") } // §1 ⟨0.13⟩ a model-SDK ctor/call IS network I/O
        recordSurfaces(effect: eff, lit: lit, args: node.arguments, netEstablishing: est)
        if lit == nil, est, !(eff == "Fs" && lastResolvedHomePath) { incompleteSurfaces.insert(eff) }
        return true
    }

    /// The launching verb on a `Process` LOCAL. Either the program is statically known — in which case the
    /// command surface is recorded and `allow Exec <list>` can certify it — or it is not, and `Exec` is
    /// marked INCOMPLETE. That second branch is not optional: without it, a function that spawns one
    /// visible `/bin/sh` and one runtime program would have its visible literal MASK the invisible one and
    /// certify under an `allow` that should have failed closed (the AS-EFF-008 gate-evasion). Marking it
    /// changes nothing for the all-invisible case the engine shipped with — an empty surface already fails.
    private func recordProcessRun(receiver: ExprSyntax?) {
        guard let recv = receiver, let dr = Self.peel(recv).as(DeclReferenceExprSyntax.self) else {
            incompleteSurfaces.insert("Exec"); return          // a field/computed handle — not tracked here
        }
        let name = dr.baseName.text
        let inert = Self.PROCESS_INERT_WRITES.union(Self.PROCESS_LOCATOR_WRITES)
        // The writes still LIVE at this point in the walk: dominated ones were removed when the dominating
        // write was recorded, and writes textually below this launch have not been walked yet.
        let literals = Set((execLocatorWrites[name] ?? []).map(\.lit))
        // `multiplyBoundNames` is the SHADOW half of the refusal (see `execLocatorWrites`): two binder
        // sites for one name means the literal under it was written about a binding that may not be the
        // one being launched here. Refusing empties the surface, which `allow Exec` reads as incomplete —
        // the same direction the two guards beside it fail in.
        guard !literals.isEmpty, !execLocatorInvisible.contains(name),
              !multiplyBoundNames.contains(name),
              locatorNameIsStable(name, inert: inert) else {
            incompleteSurfaces.insert("Exec"); return
        }
        for lit in literals { recordSurfaces(effect: "Exec", lit: lit) }
    }

    // The PLAIN string-literal value of an expression (no interpolation), else nil. Same pure-segment
    // discipline as firstStringLiteral; used to record a LOCAL `let NAME = "literal"` const.
    private func plainStringLiteralValue(_ raw: ExprSyntax) -> String? {
        guard let lit = Self.peel(raw).as(StringLiteralExprSyntax.self) else { return nil }
        var out = ""
        for seg in lit.segments {
            if let plain = seg.as(StringSegmentSyntax.self) { out += plain.content.text } else { return nil }
        }
        return out
    }

    // Resolve an expression to a STATICALLY-KNOWN string when it is anchored on a string constant, so a
    // const-built URL is refined through the SAME host path as an inline literal (SPEC §1: a statically-
    // known model host classifies Llm). Handles exactly three const-anchored shapes:
    //   • a bare const reference — `dataTask(with: apiBase)` → apiBase's value
    //   • an interpolation whose FIRST segment is a const — `"\(apiBase)/chat"` → value + "/chat" tail
    //   • a concatenation with a const-string LEFT operand — `apiBase + "/chat"` → value + tail
    // A literal PREFIX before the interpolation (`"https://\(h)/x"`) is NOT const-anchored on the host (the
    // host is the interpolated part, not the leading literal) → nil — UNLESS that leading literal itself
    // already completes the authority (`"https://api.openai.com/v1/\(p)"`), in which case the host comes from
    // the LITERAL head (see literalHeadAuthority below). A non-const reference → nil. The tail (plain
    // segments / a literal right operand) is appended so the host part parses correctly; an interpolated/
    // non-literal tail is dropped (only the host prefix matters). Returns the resolved string (already
    // escape-decoded) or nil to leave the arg unresolved (bare Net today).

    // LITERAL-HEAD HOST EXTRACTION: given the plain literal TEXT before the first `\(…)` of an interpolation
    // (or the LEFT literal of a `"lit" + x` concat), return `scheme://authority/` when that text ALREADY
    // completes the authority — a `/` appears AFTER the `://` within this literal, so the host is fully
    // present in the literal and any interpolation is confined to the PATH. Returns the head (through the
    // first `/` after `://`, port-and-all) so the existing host refinement (`hostPort`/`isModelHost`) parses
    // it identically to a whole-URL literal. Returns nil when the authority is NOT terminated by a `/` inside
    // this literal segment (the `\(…)` could be inside the host or port — `"https://\(h)/…"`,
    // `"https://api.\(x).com/…"`, `"https://api.openai.com:\(port)/…"`) → the caller leaves it bare Net.
    // Only the curated URL schemes are accepted — `URL_SCHEMES`, the SAME list `hostPort` strips, so a
    // non-URL literal prefix with an embedded `//…/` can't be misread as an authority. This was a second
    // hand-maintained copy held in agreement with the first by a comment saying "matching hostPort's
    // scheme list"; both copies had tests for `https://`/`http://` and none for `wss://`/`ws://`/`tcp://`.
    static func literalHeadAuthority(_ text: String) -> String? {
        for scheme in URL_SCHEMES where text.hasPrefix(scheme) {
            let afterScheme = text.index(text.startIndex, offsetBy: scheme.count)
            // The authority ends at the FIRST `/` after the scheme. Require it to be WITHIN this literal —
            // if there is none, the `\(…)` (which follows this literal) is the authority terminator or lies
            // inside the authority → the host is not statically complete → nil.
            guard let slash = text[afterScheme...].firstIndex(of: "/") else { return nil }
            // Guard the empty-authority form `scheme:///…` (no host between `://` and `/`): nothing to refine.
            if slash == afterScheme { return nil }
            return String(text[..<text.index(after: slash)])   // `scheme://authority/`
        }
        return nil
    }

    // LOCATOR-CONSTRUCTOR UNWRAP. Foundation puts a CONSTRUCTOR between the literal and the call that
    // consumes it — `URLSession.shared.dataTask(with: URL(string: "https://…")!)`, `p.executableURL =
    // URL(fileURLWithPath: "/bin/sh")`, `URLSession.shared.dataTask(with: URLRequest(url: URL(string:…)!))`.
    // The direct-argument rule this engine shipped with therefore saw NO literal on the ENTIRE URLSession
    // surface (only `NWConnection(host:)` — the one idiom conformance PART 4e pins), so every Apple-platform
    // request read `unknown-host`: a narrowed `deny Net[known-telemetry]` passed GREEN over a call to a
    // telemetry host, and `api.openai.com` never reached the §1 ⟨0.13⟩ `Llm` refinement. rust/java/ts all
    // unwrap their equivalents.
    //
    // Each entry maps a ctor NAME to the argument label that carries the locator. The direction of this
    // change is RELAXING (a captured host turns a fail-closed `unknown-host` into a classified destination),
    // so the guard is an ALLOWLIST of companion arguments — the exact inverse of the denylist rule that
    // governs NARROWING a sound over-approximation. An unrecognised companion label means the ctor's
    // semantics are not the ones assumed here, so NO claim is made. `relativeTo:` is precisely why this
    // matters: `URL(string: "/v1/track", relativeTo: base)` has its authority in `base`, and reading the
    // `string:` argument as the destination would FABRICATE the host "/v1/track" — the mirror defect.
    private static let LOCATOR_CTOR_ARG: [String: String] = [
        "URL": "string", "NSURL": "string", "URLRequest": "url", "NSURLRequest": "url",
    ]
    /// `URL`'s FILE spellings — the same ctor, a different locator label. Kept separate only for clarity;
    /// both resolve through the same allowlisted-companion rule.
    private static let LOCATOR_CTOR_FILE_ARGS: Set<String> = ["fileURLWithPath", "filePath"]
    /// Companion arguments that provably do NOT move the locator: they tune parsing/caching, never the
    /// authority or the path root. ANY other label (`relativeTo`, `relativeToURL`, `baseURL`, …) refuses.
    private static let LOCATOR_CTOR_INERT_ARGS: Set<String> = [
        "encodingInvalidCharacters",       // URL(string:encodingInvalidCharacters:) — a parse-strictness knob
        "isDirectory", "directoryHint",    // URL(fileURLWithPath:isDirectory:) — a trailing-slash hint
        "cachePolicy", "timeoutInterval",  // URLRequest(url:cachePolicy:timeoutInterval:)
    ]

    /// Resolve `URL(string: "…")` / `URL(fileURLWithPath: "…")` / `URLRequest(url: URL(string: "…")!)` to the
    /// locator literal it carries, or nil when the locator is not statically recoverable. Recurses through
    /// nested locator ctors (bounded). A LOCALLY-DECLARED type or free function of the same name SHADOWS the
    /// Foundation ctor and refuses, exactly as every other κ entry point in this engine does.
    private func locatorCtorLiteral(_ raw: ExprSyntax, _ depth: Int = 0) -> String? {
        if depth > 4 { return nil }
        guard let call = Self.peel(raw).as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return nil }
        let name = dealias(callee.baseName.text)
        guard !declaredTypes.contains(name), !localFreeFns.contains(name) else { return nil }
        var locatorArg: ExprSyntax? = nil
        for a in call.arguments {
            let lab = a.label?.text ?? ""
            if Self.LOCATOR_CTOR_ARG[name] == lab || (name == "URL" || name == "NSURL")
                && Self.LOCATOR_CTOR_FILE_ARGS.contains(lab) {
                locatorArg = a.expression
            } else if !Self.LOCATOR_CTOR_INERT_ARGS.contains(lab) {
                return nil   // an unrecognised companion (`relativeTo:`) — the locator may not be this arg
            }
        }
        guard let locatorArg else { return nil }
        // The locator is itself a plain/const-anchored string (`URL(string: "…")`, `URL(string: apiBase)`),
        // or ANOTHER locator ctor (`URLRequest(url: URL(string: "…")!)`).
        if let lit = plainStringLiteralValue(locatorArg) { return decodeEscapes(lit) }
        return resolveConstString(locatorArg, depth + 1)
    }

    private func resolveConstString(_ raw: ExprSyntax, _ depth: Int = 0) -> String? {
        if depth > 4 { return nil }
        let expr = Self.peel(raw)
        // a bare const reference
        if let dr = expr.as(DeclReferenceExprSyntax.self), let v = constValue(dr.baseName.text) {
            return v
        }
        // a LOCATOR CONSTRUCTOR interposed between the literal and the call — see locatorCtorLiteral.
        if expr.is(FunctionCallExprSyntax.self), let v = locatorCtorLiteral(expr, depth) { return v }
        // an interpolation whose FIRST segment is `\(const)` — the URL prefix is the constant's value
        if let lit = expr.as(StringLiteralExprSyntax.self) {
            var segs = Array(lit.segments)
            // The parser may emit a leading EMPTY plain segment before the first `\(…)`; skip it. A leading
            // NON-EMPTY plain segment is a literal PREFIX — the host is NOT the const (e.g. `"https://\(h)/x"`)
            // → not const-anchored. BUT a leading literal prefix that itself already contains a COMPLETE
            // `scheme://authority/` (a `/` after the `://` WITHIN the literal, so the `\(…)` is only in the
            // path — `"https://api.openai.com/v1/\(p)"`) STATICALLY determines the host from the LITERAL head.
            // Extract that head and refine it (SPEC §1: a statically-known model host classifies Llm). A
            // prefix that does NOT complete the authority (`"https://api.\(x).com/…"`, `"https://\(h)/…"`,
            // `"https://api.openai.com:\(port)/…"` — interp inside the authority/port) stays unresolved →
            // bare Net (soundness: never treat an interpolated authority segment as a host).
            if let first = segs.first, let plain = first.as(StringSegmentSyntax.self) {
                if plain.content.text.isEmpty { segs.removeFirst() }
                else if let head = Self.literalHeadAuthority(decodeEscapes(plain.content.text)) { return head }
                else { return nil }
            }
            guard let firstExpr = segs.first?.as(ExpressionSegmentSyntax.self),
                  firstExpr.expressions.count == 1,
                  let head = firstExpr.expressions.first?.expression.as(DeclReferenceExprSyntax.self),
                  let v = constValue(head.baseName.text) else { return nil }
            // Append the immediately-following PLAIN tail (`/chat`) so host:port/path parse correctly; stop
            // at any further interpolation (a runtime tail can't be reconstructed, and host extraction only
            // needs the const-anchored prefix).
            var out = v
            for seg in segs.dropFirst() {
                if let plain = seg.as(StringSegmentSyntax.self) { out += plain.content.text } else { break }
            }
            return decodeEscapes(out)
        }
        // a concatenation `const + "..."` — const LEFT operand anchors the host
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            // `"https://api.openai.com/v1/" + x` — a plain-string-literal LEFT operand that already completes
            // the authority statically determines the host (same rule as the interpolation literal head). A
            // left literal that does NOT complete the authority (or an interpolated left) → fall through → nil.
            if elems.count >= 3, let op = elems[1].as(BinaryOperatorExprSyntax.self), op.operator.text == "+",
               let leftPlain = plainStringLiteralValue(elems[0]),
               let head = Self.literalHeadAuthority(decodeEscapes(leftPlain)) {
                return head
            }
            if elems.count >= 3, let op = elems[1].as(BinaryOperatorExprSyntax.self), op.operator.text == "+",
               let leftDR = Self.peel(elems[0]).as(DeclReferenceExprSyntax.self), let v = constValue(leftDR.baseName.text) {
                // append a literal right operand's plain value (the path tail); a non-literal right → host only
                if let rlit = Self.peel(elems[2]).as(StringLiteralExprSyntax.self) {
                    var tail = ""
                    var pure = true
                    for seg in rlit.segments {
                        if let plain = seg.as(StringSegmentSyntax.self) { tail += plain.content.text } else { pure = false; break }
                    }
                    if pure { return decodeEscapes(v + tail) }
                }
                return v
            }
        }
        return nil
    }

    /// CONSTANT PROVENANCE, rung 4 — resolve a COMPUTED path expression far enough to name its class.
    ///
    /// The design's insight is that the answer is a CLASS, not a path: a proved PREFIX decides which
    /// protected folder a value falls in, and the unknowable tail cannot move it. So this never tries to
    /// reconstruct a string — it looks for a known home-directory root and the literal that follows,
    /// which is exactly the shape real code uses:
    ///
    ///     NSHomeDirectory() + "/Documents/x"
    ///     "\(NSHomeDirectory())/Desktop/report.txt"
    ///     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    ///
    /// Returns nil — NOT a guess — for anything else, so an ordinary computed path stays undetermined and
    /// is counted by the `incomplete` disclosure rather than classified on a hunch.
    private func homeAnchoredPath(_ expr: ExprSyntax, _ depth: Int = 0) -> String? {
        if depth > 8 { return nil }
        let e = Self.peel(expr)
        // `NSHomeDirectory()` / `FileManager.default.homeDirectoryForCurrentUser`
        if let call = e.as(FunctionCallExprSyntax.self),
           let dr = call.calledExpression.as(DeclReferenceExprSyntax.self),
           dr.baseName.text == "NSHomeDirectory" { return "/Users/_" }
        if let ma = e.as(MemberAccessExprSyntax.self),
           ma.declName.baseName.text == "homeDirectoryForCurrentUser" { return "/Users/_" }
        // a plain literal contributes itself
        if let lit = e.as(StringLiteralExprSyntax.self), lit.segments.count == 1,
           let seg = lit.segments.first?.as(StringSegmentSyntax.self) { return seg.content.text }
        // `A + B` — a SequenceExpr. Resolve the head; append literal tails. A non-literal tail STOPS the
        // walk rather than failing it: the prefix already decided the class.
        if let seq = e.as(SequenceExprSyntax.self) {
            let parts = Array(seq.elements)
            guard let head = parts.first, var out = homeAnchoredPath(head, depth + 1) else { return nil }
            guard out.hasPrefix("/Users/_") else { return nil }   // only a HOME anchor decides a class
            var i = 1
            while i + 1 < parts.count {
                guard let op = parts[i].as(BinaryOperatorExprSyntax.self), op.operator.text == "+" else { break }
                guard let piece = homeAnchoredPath(parts[i + 1], depth + 1) else { break }
                out += piece; i += 2
            }
            return out
        }
        // `"\(NSHomeDirectory())/Desktop/x"` — an interpolation whose FIRST segment resolves to home.
        if let lit = e.as(StringLiteralExprSyntax.self) {
            var out = ""
            for seg in lit.segments {
                if let plain = seg.as(StringSegmentSyntax.self) { out += plain.content.text; continue }
                guard let ex = seg.as(ExpressionSegmentSyntax.self), ex.expressions.count == 1,
                      let inner = ex.expressions.first?.expression,
                      let v = homeAnchoredPath(inner, depth + 1) else {
                    return out.hasPrefix("/Users/_") ? out : nil   // an unresolvable tail keeps the prefix
                }
                out += v
            }
            return out.hasPrefix("/Users/_") ? out : nil
        }
        // `<home>.appendingPathComponent("Downloads")` — the URL spelling of the same thing.
        if let call = e.as(FunctionCallExprSyntax.self),
           let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
           ma.declName.baseName.text == "appendingPathComponent",
           let base = ma.base, let root = homeAnchoredPath(base, depth + 1),
           let arg = call.arguments.first.map({ Self.peel($0.expression) }),
           let lit = arg.as(StringLiteralExprSyntax.self), lit.segments.count == 1,
           let seg = lit.segments.first?.as(StringSegmentSyntax.self) {
            return root + "/" + seg.content.text
        }
        // a local bound to any of the above
        if let dr = e.as(DeclReferenceExprSyntax.self), let bound = homeAnchoredLocals[dr.baseName.text] {
            return bound
        }
        return nil
    }

    private func firstStringLiteral(_ args: LabeledExprListSyntax) -> String? {
        for a in args {
            guard let lit = a.expression.as(StringLiteralExprSyntax.self) else {
                // CONST-STRING PROPAGATION — not a plain literal: try a const-anchored resolution (a bare
                // const ref, or a const-left concatenation). An interpolation is a StringLiteralExpr and is
                // handled in the loop body below, so only NON-literal args reach here.
                if let v = resolveConstString(a.expression) { return v }
                continue
            }
            // Concatenate ALL plain segments: the parser may split a literal around escapes, so a
            // single-segment assumption silently dropped multi-line SQL (caught by the four-way
            // conformance differential on this engine's first wiring). An INTERPOLATED literal
            // (any non-plain segment) is runtime-computed — no literal claim as-is, but a
            // const-anchored interpolation (`"\(apiBase)/chat"`) DOES resolve (const-string propagation).
            var out = ""
            var pure = true
            for seg in lit.segments {
                if let plain = seg.as(StringSegmentSyntax.self) { out += plain.content.text } else { pure = false; break }
            }
            if pure { return decodeEscapes(out) }
            if let v = resolveConstString(a.expression) { return v }
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

    // `netEstablishing`: the Net literal surface is captured ONLY at establishing forms (connect/bind/
    // ctor — where the host is conceptually an argument of THIS call). At a USE verb on an established
    // channel (`Channel.writeAndFlush("x")`, `NWConnection.send`) the string arg is a PAYLOAD, not a
    // destination — capturing it minted a bogus host that could trip `allow Net` on data (found by the
    // 2026-07-10 coverage wave; candor-java and candor-ts capture only at establishing forms). Fs/Exec/Db
    // arms are unaffected: their shape guards (path chars, SQL statement keyword) already reject payloads.
    private func recordSurfaces(effect: String, lit: String?, args: LabeledExprListSyntax? = nil,
                                netEstablishing: Bool = true) {
        // CONSTANT PROVENANCE rung 4, in the ONE place every Fs surface passes through. The literal was
        // unreadable, but a HOME-ANCHORED expression still names a protected folder —
        // `NSHomeDirectory() + "/Desktop/x"` is the spelling real code uses, and the class is decided by
        // the proved prefix, so the unknowable tail does not matter. Only when this ALSO fails is the
        // destination genuinely undetermined, and the caller's `incomplete` marker stands.
        lastResolvedHomePath = false
        if lit == nil, effect == "Fs", let args,
           let resolved = args.lazy.compactMap({ self.homeAnchoredPath($0.expression) }).first {
            for c in pathClasses(resolved) { directEffects.insert(c) }
            if !pathClasses(resolved).isEmpty { resolvedHomePaths.insert(resolved); lastResolvedHomePath = true }
        }
        guard let lit else { return }
        switch effect {
        case "Net":
            if !netEstablishing { break }
            var h = hostPort(lit)
            // Fold a SEPARATE integer port arg (NWConnection(host: "…", port: 8080)) into host:port, so the
            // surface reads like the URL-string forms the other engines see (conformance §2 [4e]). Skipped
            // when the host already carries a colon (an embedded port, or an IPv6 literal).
            if !h.contains(":"), let args, let p = intLiteralForLabel(args, "port") { h = "\(h):\(p)" }
            // SPEC §1 ⟨0.13⟩ `Llm` host-literal refinement: a known model host classifies `Llm` IN ADDITION
            // to `Net` (Net never dropped), just as a jdbc URL classifies `Db`. `isModelHost` also covers the
            // local Ollama `…:11434` endpoint and `*.bedrock*.amazonaws.com`.
            if isModelHost(h) {
                directEffects.insert("Llm")
                // Ollama's local endpoint names a DOTLESS host (`localhost`/`127.0.0.1`) — the model signal
                // is the `:11434` port, not the host. Add `Llm` but do NOT capture the host as a Net/Llm
                // literal (matching candor-java's dotless-host gate): `allow Llm localhost` then has no
                // certifiable surface and fails CLOSED. A DOTTED model host (api.openai.com, a bedrock
                // runtime host) IS a real host literal → captured below like any Net host.
                if !hostPart(h).contains(".") { break }
            }
            // CONSTANT-PROVENANCE, host axis: a determined endpoint also says whether it is on the LOCAL
            // network, which Apple gates behind its own key. Exactly the `isModelHost` refinement one line
            // up — a host literal classifying an ADDITIONAL effect beside Net, never instead of it.
            for c in hostClasses(h) { directEffects.insert(c) }
            hosts.insert(h)
        case "Exec":
            let head = lit.split(separator: " ").first.map(String.init) ?? lit
            cmds.insert(head)
            // a known literal head refines the cliff (curl→Net, candor→Fs/Env); Exec stays
            for e in classifyCommandHead(head) { directEffects.insert(e) }
        case "Fs":
            if lit.contains("/") || lit.hasPrefix(".") || lit.hasPrefix("~") {
                paths.insert(lit)
                // CONSTANT-PROVENANCE rung 1: a determined path also names a protected FOLDER, and Apple
                // requires a usage-description key for three of them plus mounted volumes. The class is
                // decided by the prefix; an unrecognised path yields nothing, so ordinary sandbox I/O is
                // untouched. The UNDETERMINED case is not handled here at all — it is the absence of a
                // path, counted and disclosed by the verify rather than guessed at from this side.
                for c in pathClasses(lit) { directEffects.insert(c) }
            }
        case "Db": for t in tablesInSql(lit) { tables.formUnion([t]) }
        default: break
        }
    }

    // The ELEMENT type a sequence yields per iteration. A `[T]` local/param/field; `self.field`; an
    // element-PRESERVING transform (`coll.filter/sorted/reversed/prefix/…`) → coll's element. A
    // literal/computed/transforming (map) sequence is left untyped — never guess.
    private func elementTypeOf(_ expr: ExprSyntax, _ depth: Int = 0) -> (name: String, mono: Bool)? {
        if depth > 200 { return nil }   // bounds the rootOf ⇄ elementTypeOf recursion (see rootOf)
        let e = Self.peel(expr)
        if let dr = e.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            if let t = arrayElem[n] { return (t, opaqueElem.contains(n)) }
            // implicit-self field. `fieldArrayElem` records the element SPELLING and never resolves it
            // through `typeGenericBounds`, so a `[T]` field's element is `T` (resolves to nothing) and
            // there is no monomorphized protocol name to guard — hence `false`, not an omission.
            if let et = enclosingType, let t = fieldArrayElem[et]?[n] { return (t, false) }
            // R73's loop sibling — a module-scope `[T]` global iterated bare (`for w in workers { … }`).
            // Checked after locals/fields, the same shadowing order `rootOf`'s global lookup uses.
            if let t = globalArrayElem[n] { return (t, false) }
            // bare `self` iterated directly — `for e in self { e.persist() }` inside `extension Array
            // where Element: Saveable`. `selfElementType` is exactly the bound `typeClosureParams`'s bare
            // element-iterator branch already consults for the CLOSURE form (`forEach { $0.persist() }`,
            // R28); a `for`-in loop over the same `self` reached a different resolver here that never
            // asked it, so the identical extension body read silent-pure when spelled as a loop instead of
            // a closure call. Always `mono` for the same reason R28 is: `Element` is monomorphized by
            // whoever holds the concrete array, never erased.
            if n == "self", let elem = selfElementType { return (elem, true) }
            return nil
        }
        // `dict.values` iteration (`for v in m.values { v.go() }`) yields the dict's VALUE type — the
        // container sibling of the `for (k, v)` pair form. Without this the loop var was untyped and a
        // `v.go()` over `[K: any Doer]`/`[K: T where T: Doer]` read silent-pure. `.keys` is the KEY type
        // (dispatch-irrelevant for the value payload) so only `.values` carries.
        if let ma = e.as(MemberAccessExprSyntax.self), let base = ma.base,
           ma.declName.baseName.text == "values", let v = dictValueOf(base, depth + 1) {
            return (v, false)
        }
        if let ma = e.as(MemberAccessExprSyntax.self), let base = ma.base,
           let bt = rootOf(base, depth + 1).root, let t = fieldArrayElem[bt]?[ma.declName.baseName.text] {
            return (t, false)  // a `[E]` field of ANY typed receiver: `self.items` / `pool.clients` / `ps[0].items`
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
        clearBindingTypeOnly(name)
        shadowName(name)
    }

    // `clearBinding` minus the name-keyed FLAGS, for a binder whose shadow SCOPE is entered somewhere
    // else. The only such binder is a CLOSURE PARAMETER: `typeClosureParams` runs on the enclosing
    // CALL node, which is visited BEFORE the closure, so clearing a flag there would happen outside
    // the closure's save and could never be restored — `let c = depBuild(); xs.forEach { c in … };
    // c.fetch()` would lose its disclosure for good. `visit(ClosureExprSyntax)` does the flag clearing
    // instead, after the save.
    private func clearBindingTypeOnly(_ name: String) {
        vars.removeValue(forKey: name)
        protoTyped.removeValue(forKey: name)
        arrayElem.removeValue(forKey: name)
        opaqueElem.remove(name)
        dictElem.removeValue(forKey: name)
        tupleElem.removeValue(forKey: name)
    }

    // `arrayElem` and `opaqueElem` describe the same binding and must move together: a name rebound to a
    // NON-monomorphized collection has to LOSE its opacity, or the CHA stays suppressed on a receiver that
    // is now erased — a silent under-report. One writer, so the pair can never drift.
    private func setArrayElem(_ name: String, _ elem: (name: String, mono: Bool)) {
        arrayElem[name] = elem.name
        if elem.mono { opaqueElem.insert(name) } else { opaqueElem.remove(name) }
    }

    /// Every binder a pattern introduces, as the `IdentifierPatternSyntax` NODES — `x`, `(k, v)`,
    /// `(a, (b, c))`, `let x?`, `.some(let x)`, `let x as T`, `case let .pair(a, b)`, and anything else
    /// the grammar grows.
    ///
    /// STRUCTURAL RATHER THAN AN ENUMERATION OF PATTERN KINDS, and that is the whole point. The previous
    /// version listed three of the seven `PatternSyntax` kinds and returned `[]` for the rest, so
    /// `for case let item? in xs` never reached `shadowName` and the enclosing signature's
    /// `monoNames`/`depBoundLocals` entry stayed attached to the loop's own, unrelated binding — the
    /// third scope leak from the same gate, and a purity claim on a body that performs the conformer's
    /// effect. Adding `OptionalPattern`/`ExpressionPattern`/enum-case to the list would have been the
    /// fourth one-off; the grammar decides how many spellings there are, so the rule has to be a
    /// property of the parse tree rather than a list somebody keeps current.
    ///
    /// The property, VERIFIED IN BOTH DIRECTIONS against SwiftParser rather than assumed: every bound
    /// name is an `identifierPattern` node somewhere in the subtree (`let x?` →
    /// `valueBinding > expressionPattern > optionalChainingExpr > patternExpr > identifierPattern`;
    /// `.some(let y)` and `case let .two(m, n)` reach one through `labeledExpr > patternExpr`), and a
    /// NON-binding expression pattern never produces one — a matched constant, an enum case with
    /// literal payloads and a range (`for case konst in`, `case E.one(3)`, `case 1...2`) parse to
    /// `declReferenceExpr`/literal nodes, and `_` is a `wildcardPattern`. So the walk is exact, not
    /// conservative, in both directions.
    /// Does `expr` mention `name` as a declaration reference anywhere in its subtree? Used by the
    /// VariableDecl rebind to tell `let u = s` (the old binding is dead the moment the pattern is seen)
    /// from `let u = u.asURL()` (the old binding is what the initializer resolves through). Conservative
    /// in the safe direction: a false YES keeps a stale type — which is the shape `clearBindingTypeOnly`
    /// still catches on any binder that cannot type — while a false NO would drop a live one.
    private static func referencesName(_ expr: ExprSyntax?, _ name: String) -> Bool {
        guard let expr else { return false }
        var found = false
        func walk(_ n: Syntax) {
            if found { return }
            if let dr = n.as(DeclReferenceExprSyntax.self), dr.baseName.text == name { found = true; return }
            for c in n.children(viewMode: .sourceAccurate) { walk(c) }
        }
        walk(Syntax(expr))
        return found
    }

    private static func patternBinders(_ pattern: PatternSyntax) -> [IdentifierPatternSyntax] {
        var out: [IdentifierPatternSyntax] = []
        func walk(_ n: Syntax) {
            if let ip = n.as(IdentifierPatternSyntax.self) { out.append(ip); return }  // a leaf node
            for c in n.children(viewMode: .sourceAccurate) { walk(c) }
        }
        walk(Syntax(pattern))
        return out
    }

    private static func patternNames(_ pattern: PatternSyntax) -> [String] {
        patternBinders(pattern).map { $0.identifier.text }
    }

    /// Binder nodes a specific visitor has already accounted for, so `visit(IdentifierPatternSyntax)`
    /// leaves them alone. See that visitor for why the marking is the load-bearing half.
    private var handledBinders: Set<SyntaxIdentifier> = []

    private func markBinders(_ pattern: PatternSyntax) {
        for b in Self.patternBinders(pattern) { handledBinders.insert(b.id) }
    }

    /// The TYPE indexes for one name, saved so a binder whose scope is narrower than the function can
    /// give the name back (see `visit(ForStmtSyntax)`). These four are exactly the maps
    /// `clearBindingTypeOnly` drops; `opaqueElem` is restored by the shadow scope with the other flags,
    /// and it is written only in lockstep with `arrayElem`, so the pair cannot come back inconsistent.
    private typealias TypeBinding = (type: String?, arrayElem: String?, dictElem: String?, tupleElem: [String: String]?)
    private var typeScopes: [SyntaxIdentifier: [(String, TypeBinding)]] = [:]

    private func snapshotType(_ name: String) -> TypeBinding {
        (vars[name], arrayElem[name], dictElem[name], tupleElem[name])
    }

    private func restoreType(_ name: String, _ b: TypeBinding) {
        vars[name] = b.type
        arrayElem[name] = b.arrayElem
        dictElem[name] = b.dictElem
        tupleElem[name] = b.tupleElem
    }

    // A binder REBINDS `name`, so the name-keyed FLAGS carried by the signature or by an earlier
    // binding no longer describe it. Called by EVERY binder — `clearBinding`, and also the paths that
    // succeed in typing the new binding, which do not go through `clearBinding` at all.
    //
    // `vars` is deliberately function-wide (see `clearBinding`): a stale TYPE is dangerous inward and
    // harmless outward, so clearing is enough there. These two sets INVERT that, and each is wrong in
    // BOTH directions, which is why they need a scope rather than a clear:
    //
    //   - `monoNames` suppresses the local-conformer CHA (d62dd69). Leaking it INTO a shadowing
    //     binder suppresses the CHA for a receiver that is not the opaque parameter at all — the call
    //     reads silent-pure, the cardinal sin. Dropping it when the shadowing scope CLOSES re-fabricates
    //     the effect on the genuine `some P` receiver, which is the defect d62dd69 closed.
    //   - `depBoundLocals` drives the half-1 disclosure (47bb69a). Leaking it in discloses a purely
    //     local value (81a9dc3 added the clear for exactly that); dropping it at scope close sends a
    //     genuinely factory-bound receiver back to silent-pure — `let c = depBuild(); for c in xs {};
    //     c.fetch()` lost its disclosure when 81a9dc3 landed the clear without the restore.
    //   - `protoTyped` drives the LOCAL-protocol CHA (`protoDispatches` → `subtypesOf`). Leaking it in
    //     charges every conformer's effects to a call on a value that is not the protocol-typed
    //     parameter at all — a FABRICATION, and the direction the other two do not cover. MEASURED, and
    //     the rename control is what isolates it: `func f(_ j: Job, _ xs: [String]) { for j in xs {
    //     j.run() } }` reads `['Env']` from `RealJob`, and the identical body with the binder named `t`
    //     is ABSENT. Dropping it at scope close would send the genuine parameter's own `j.run()` below
    //     the loop back to silent-pure, so it needs the scope and not just the clear.
    //   - `localConstStrings` drives the const-anchored literal surfaces (PART 4q). Leaking it in
    //     attributes a LITERAL endpoint to a call whose address is a runtime value: `let u =
    //     "https://telemetry.example.com/beacon"` followed by `for u in xs { …dataTask(with: u)… }`
    //     reported `hosts: ['telemetry.example.com']`, and the same body with the binder named `v`
    //     reports none. `hosts` is what an `allow`/`forbid` host rule matches on, so the fabricated
    //     literal is policy-visible. Dropping it at scope close would lose a genuine literal, which
    //     empties the surface and is the direction `forbid` reads as incomplete — safe, but still a
    //     loss, so it takes the same scope.
    //   - `fnValueAlias` RESOLVES a bare `g()` to a named local function. Leaking it in edges an
    //     unrelated value's invocation to that function's body and charges its whole transitive effect
    //     set — the widest fabrication of the five, because the target is a real unit rather than a type
    //     index. MEASURED with the rename control: `func f(_ jobs: [() -> Void]) { let g = eff; for g in
    //     jobs { g() } }` reads `['Fs']` from `eff`, and the identical body with the binder named `h` is
    //     ABSENT — as is the same body with no alias above it, which is the point: the alias is the only
    //     thing charging it. Dropping it at scope close sends `let g = eff; if c { let g = {} }; g()`
    //     back to silent-pure, so — like the four above — it needs the scope and not just the clear.
    //
    // So: a binder CLEARS, the enclosing scope RESTORES (see enterShadowScope/leaveShadowScope).
    // FIVE maps now, and this list is no longer the OBLIGATION. `NameKeyedStateTests` parses this
    // file and requires every stored property of this class to be classified — cleared, scoped,
    // deliberately kept, or not per-binding — so a map added without that decision fails a test, and a
    // map classified as cleared without the clear being written fails a different one.
    private func shadowName(_ name: String) {
        monoNames.remove(name)
        depBoundLocals.removeValue(forKey: name)
        localConstStrings.removeValue(forKey: name)
        fnValueAlias.removeValue(forKey: name)
        // A REBIND MUST DROP THE PATH. Without this, `func a() { let p = NSHomeDirectory() + "/Desktop" }`
        // followed by `func b(_ p: String) { …contents(atPath: p) }` charged b's PARAMETER the Desktop
        // key — a fabrication from a name collision, which is the exact class NameKeyedStateTests exists
        // to force a decision about, and it caught this one.
        homeAnchoredLocals.removeValue(forKey: name)
    }

    /// A BINDER THAT **CAN** TYPE THE NEW BINDING STILL HAS TO INVALIDATE THE OLD ONE, and the branches
    /// that could type it were the ones not doing it. `shadowName` drops the four FLAGS;
    /// `clearBindingTypeOnly` drops the TYPE indexes; a branch that called the first and then wrote
    /// `vars` left `protoTyped` (and `arrayElem`/`dictElem`/`tupleElem`) describing a binding that is no
    /// longer there. `protoTyped` is the sharp one — the member-dispatch site consults it BEFORE the
    /// `vars` root, so a fresh type on the shadowing binding does not mask the stale protocol, and the
    /// call dispatches over the shadowed parameter's conformers. Five binder sites had it; four are
    /// routed through here and the fifth (`typeEnumCaseBinding`) goes through `clearBinding` directly.
    ///
    /// `through` IS A DENYLIST AND IT IS LOAD-BEARING. SwiftSyntax walks a binding's PATTERN before its
    /// INITIALIZER, so when the initializer MENTIONS the name the old binding is still live while the
    /// initializer's own calls are collected: `let u = u.asURL()` and `if let u = u.asURL()` resolve
    /// THROUGH the entry being cleared (Alamofire's `URLRequest.init(url: any URLConvertible)` — the
    /// reach `visit(VariableDeclSyntax)` already states this carve-out for). Conservative in the safe
    /// direction: a false YES keeps a stale type, which every binder that CANNOT type still clears.
    private func rebindTyped(_ name: String, through initializer: ExprSyntax?) {
        guard !Self.referencesName(initializer, name) else { return }
        clearBindingTypeOnly(name)
    }

    /// Is `name` a LOCAL BINDING at this point in the walk? The union of the function-wide set and the
    /// lexically-scoped payload set — every guard in this file asks it at a position, so both apply.
    private func isBoundLocal(_ name: String) -> Bool {
        boundLocals.contains(name) || casePayloadLocals.contains(name)
    }

    // The name-keyed per-binding state saved per scope-delimiting node and restored when the node
    // closes. Keyed by node id rather than a stack so an un-entered scope can never pop someone else's
    // save; SwiftSyntax calls `visitPost` for every visited node (including one whose `visit` returned
    // `.skipChildren`), so entries cannot leak.
    private struct ShadowSave {
        var opaque: Set<String>, opaqueElem: Set<String>, depBound: [String: String]
        var protoTyped: [String: String], constStrings: [String: String]
        var fnValueAlias: [String: String], casePayload: Set<String>
    }
    private var shadowScopes: [SyntaxIdentifier: ShadowSave] = [:]

    /// Closure node -> element parameters the enclosing call typed from a MONOMORPHIZED element. Handed
    /// over rather than set directly because `typeClosureParams` runs before the closure is entered (see
    /// `visit(ClosureExprSyntax)`). Consumed once, so an un-entered closure cannot leak an entry.
    private var monoClosureParams: [SyntaxIdentifier: Set<String>] = [:]

    private func enterShadowScope(_ node: some SyntaxProtocol) {
        // Saved UNCONDITIONALLY. The old `guard !isEmpty` skipped the save when both sets were empty on
        // entry — fine while the sets could only ever SHRINK inside a scope, and wrong now that a binder
        // can ADD to `monoNames` (a `for x in xs` element that is monomorphized). With no save there is
        // nothing to restore, so that flag leaked out past the loop and suppressed the CHA on a later,
        // unrelated `x` — the silent under-report this whole mechanism exists to avoid.
        //
        // `opaqueElem` IS THE SAME ARGUMENT ONE CONTAINER OUT, and it shipped without the save. It is
        // written in lockstep with `arrayElem`, which is the CLEAR half of the discipline — a rebind
        // cannot leave a stale opacity behind a fresh element type — and says nothing about the RESTORE
        // half. `if c { let ys = xs.filter { … } }` inside a function taking `ys: [any Speaker]` marks
        // `ys` monomorphized from the `[some P]` source, the block ends, and the ERASED parameter it
        // shadowed spends the rest of the body with the CHA suppressed. Measured: identical bodies,
        // Env when the inner binding is named `zs` and silent-pure when it is named `ys`.
        //
        // `protoTyped` and `localConstStrings` joined the save the same way — by being found leaking on
        // a fixture, not by being reasoned onto the list. THAT IS THE POINT WORTH CARRYING: this save
        // and `shadowName` are two enumerations of the same set, and the previous round filed "fuse the
        // flags into `vars`" as a rewrite of the binding model over ~9 name-keyed maps rather than
        // attempt it. RE-PRICED after the parse-tree walk landed, and the answer has not changed —
        // `visit(IdentifierPatternSyntax)` removed the enumeration of BINDER FORMS, which is what it
        // claimed to remove, and this is a different enumeration: WHICH FACTS a rebind invalidates.
        // Fusing them into `vars` still requires `vars` to become lexically scoped, which it
        // deliberately is not (function-wide with clear-on-rebind, because a stale TYPE is dangerous
        // inward and merely lossy outward), and doing it without that scoping would make every flag
        // leak outward the way types do — i.e. `71de627` permanently.
        //
        // What DID change is the price of leaving it: the audit that found these two enumerated the
        // collector's name-keyed state and probed every member with a rename control.
        //
        // TWO OF ITS THREE CLEAN VERDICTS WERE WRONG, and how they were wrong is the durable part. It
        // reported `fnValueAlias` safe on the evidence that "an aliased fn value called after a
        // shadowing loop still resolves" — which is the LOSS direction, and the fabrication direction
        // was never probed: an aliased name rebound by that same loop resolved to the aliased function
        // for the rest of the body. `boundLocals` was not on its list at all, because it is not a
        // per-binding FACT but a per-binding EXISTENCE claim, and the audit was looking for facts. A
        // rename control run in one direction is half a control. `fnValueAlias` now carries the
        // discipline; `boundLocals` does NOT, and is filed with its measurement in
        // `NameKeyedStateTests.disposition` rather than left to be rediscovered. The residual the note
        // used to end on — "a NEW map added later without being added here" — now fails a test.
        shadowScopes[node.id] = ShadowSave(opaque: monoNames, opaqueElem: opaqueElem,
                                           depBound: depBoundLocals, protoTyped: protoTyped,
                                           constStrings: localConstStrings, fnValueAlias: fnValueAlias,
                                           casePayload: casePayloadLocals)
    }

    private func leaveShadowScope(_ node: some SyntaxProtocol) {
        guard let saved = shadowScopes.removeValue(forKey: node.id) else { return }
        monoNames = saved.opaque
        opaqueElem = saved.opaqueElem
        depBoundLocals = saved.depBound
        protoTyped = saved.protoTyped
        localConstStrings = saved.constStrings
        fnValueAlias = saved.fnValueAlias
        casePayloadLocals = saved.casePayload
    }

    /// THE CATCH-ALL BINDER, and it exists to invert a failure mode rather than to add a case.
    ///
    /// Four of the five defects this gate has produced were the same shape: a name-keyed flag outliving
    /// the binding that set it, because some binder form was not on somebody's list. The lists are the
    /// problem — a binder nobody enumerated LEAKS the enclosing signature's opacity onto an unrelated
    /// value, which suppresses the local-conformer CHA and reads silent-pure, and leaks half 1's
    /// dependency provenance, which discloses `Unknown` for a purely local value.
    ///
    /// `IdentifierPatternSyntax` is where the language puts every binding, and nowhere else: parameters
    /// and closure parameters are TOKENS (`FunctionParameterSyntax.secondName`,
    /// `ClosureParameterSyntax.name`), never patterns, so this fires on `let`/`var` declarations,
    /// `for`-in patterns, `case` patterns, `if`/`while`/`guard case` patterns and `catch` patterns — the
    /// complete set of pattern binders — and on nothing else.
    ///
    /// Unmarked ⇒ no specific visitor claimed this binder ⇒ CLEAR it. So an unenumerated form now
    /// defaults to dropping a stale binding (the direction the collector already documents as safe:
    /// harmless outward, and the only direction that cannot fabricate) instead of to keeping one. The
    /// MARKING is what carries the risk, not the clearing: a visitor that types a binding must claim it,
    /// or this would wipe the type/provenance it just established — which is why
    /// `visit(OptionalBindingConditionSyntax)` marks UNCONDITIONALLY, including the shorthand
    /// `guard let c` that deliberately keeps the enclosing binding's type.
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        if !handledBinders.contains(node.id) { clearBinding(node.identifier.text) }
        return .visitChildren
    }

    // THE SCOPES. A brace-delimited block covers `let`/`guard let` shadows; the statement/expression
    // nodes cover binders written OUTSIDE their block (a `for` pattern, an `if let`/`while let`
    // condition, a `case let`, a `catch let`), which are visited before the block is entered.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind { enterShadowScope(node); return .visitChildren }
    override func visitPost(_ node: CodeBlockSyntax) { leaveShadowScope(node) }
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind { enterShadowScope(node); return .visitChildren }
    override func visitPost(_ node: IfExprSyntax) { leaveShadowScope(node) }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { enterShadowScope(node); return .visitChildren }
    override func visitPost(_ node: WhileStmtSyntax) { leaveShadowScope(node) }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind { enterShadowScope(node); return .visitChildren }
    override func visitPost(_ node: SwitchCaseSyntax) { leaveShadowScope(node) }
    override func visitPost(_ node: CatchClauseSyntax) { leaveShadowScope(node) }
    override func visitPost(_ node: ForStmtSyntax) {
        leaveShadowScope(node)
        for (n, b) in typeScopes.removeValue(forKey: node.id) ?? [] { restoreType(n, b) }
    }
    // A closure's PARAMETERS are cleared here rather than in `typeClosureParams` (which runs on the
    // enclosing CALL, i.e. before this node is entered, so the save would capture the already-cleared
    // set and restore nothing).
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        enterShadowScope(node)
        // …and `protoTyped` with them, HERE rather than in `typeClosureParams`, for the reason the
        // comment above gives: this map is in `ShadowSave`, so a clear inside the scope is given back
        // when the closure closes. `typeClosureParams` clears the type indexes for the params it cannot
        // type (outside the save, lossy-but-safe) and TYPES the annotated/element ones — and typing them
        // left the enclosing protocol parameter's entry standing, so `func f(_ p: Job, _ xs: [Int]) {
        // xs.forEach { (p: Ctx) in p.run() } }` dispatched over `Job`'s conformers. Rename control: the
        // identical body with the closure parameter named `q` is ABSENT.
        for p in closureParamNames(node) { shadowName(p.name); protoTyped.removeValue(forKey: p.name) }
        // …then re-apply the opacity the enclosing call's `typeClosureParams` determined for the element
        // parameter (`xs.forEach { $0.greet() }` over a `[T]`/`[some P]`): the shadow above is what makes
        // the flag scoped to THIS closure, so it has to be set after it, not before.
        if let mono = monoClosureParams.removeValue(forKey: node.id) { monoNames.formUnion(mono) }
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { leaveShadowScope(node) }

    // `for x in coll` / `for (k, v) in dict` / `for (i, x) in coll.enumerated()` — type the iteration
    // variable from the collection so its member calls resolve (else dropped to pure — §4 under-report).
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        enterShadowScope(node)
        modelImplicitIteration(node.sequence)
        // EVERY name the pattern binds is CLEARED, including the ones no branch below types (a
        // `for (key, _) in dict` key, a tuple arity this doesn't model, a `for case let x? in`) — an
        // untyped loop variable is still a rebind, and leaving the opaque/provenance flag on it is what
        // made `func f(_ c: some P) { for c in xs { c.m() } }` read silent-pure. The TYPE goes with the
        // flags rather than being left behind: this loop used to `shadowName` only, so a pattern no
        // branch below reaches (`for case let item? in xs`) kept the enclosing parameter's type for the
        // name — resolving the loop's receiver against a type it does not have, which is the fabrication
        // direction of the same leak. `clearBinding` is `shadowName` plus the type indexes; the branches
        // below then re-establish what they can determine.
        //
        // The pattern's binders are then MARKED as claimed, so `visit(IdentifierPatternSyntax)` — which
        // walks into this pattern a moment later — does not undo the typing done here.
        //
        // A LOOP BINDER'S TYPE DOES NOT OUTLIVE THE LOOP, and this is the first place the collector had
        // to say so. `vars` is deliberately function-wide (see `clearBinding`) because a stale type is
        // dangerous inward and merely lossy outward — but the `for case` branch below TYPES a name whose
        // scope is strictly the loop body, and the outward leak then bites in the honesty direction:
        // `let c = depBuild(); for case let c? in xs { … }; c.speak()` typed the loop's `c` from the
        // sequence, that type survived the loop, and the factory-bound receiver below it stopped
        // reaching half 1's `<untyped>` marker — a disclosed gap turned back into a silent purity claim
        // by a fix aimed at the opposite defect (standing bar item 0). So the pattern's names have their
        // TYPE indexes saved here and restored in `visitPost`, which also closes the same outward leak
        // for the plain `for x in xs` binder that has always had it.
        typeScopes[node.id] = Self.patternNames(node.pattern).map { ($0, snapshotType($0)) }
        for n in Self.patternNames(node.pattern) { clearBinding(n) }
        markBinders(node.pattern)
        // `for var x in xs` is `for x in xs` with a mutable binding, and it parses as a
        // `valueBindingPattern` WRAPPING the identifier — so this test failed and the loop variable was
        // never typed at all. Found by instrumenting the `for case` branch below, not by reading the
        // grammar: five sites on the corpus land there with an element type already in hand
        // (`for var p in fgParticles` → `Particle`). Peeled so both spellings share the one rule.
        if let name = Self.plainBinderName(node.pattern) {
            // An EXPLICIT loop-var annotation (`for await x: Item in s`) names the element type directly —
            // honor it over the sequence's inferred element, so an unpinned/async sequence whose element
            // type candor can't infer still types the loop var (was ignored → `x.member()` silent-pure).
            if let ann = node.typeAnnotation, let tn = typeName(ann.type).name {
                vars[name] = tn
            } else if let elem = elementTypeOf(node.sequence) {
                vars[name] = elem.name
                if elem.mono { monoNames.insert(name) }   // `for x in xs` over `[T]`/`[some P]` (shadowName ran above)
            } else { clearBinding(name) }
        } else if let tup = node.pattern.as(TuplePatternSyntax.self), tup.elements.count == 2,
                  let second = tup.elements.last?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            if let v = dictValueOf(node.sequence) {
                vars[second] = v  // for (key, value) in dict — value carries the type
            } else if let call = Self.peel(node.sequence).as(FunctionCallExprSyntax.self),
                      let ma = call.calledExpression.as(MemberAccessExprSyntax.self),
                      ma.declName.baseName.text == "enumerated", let base = ma.base,
                      let elem = elementTypeOf(base) {
                vars[second] = elem.name  // for (offset, element) in coll.enumerated()
                if elem.mono { monoNames.insert(second) }
            } else { clearBinding(second) }
        } else if Self.patternBinders(node.pattern).count == 1,
                  let only = Self.patternBinders(node.pattern).first {
            // A `for case` pattern binding exactly ONE name. Scoping it (above) is what stops the
            // enclosing signature's flags riding on it, but scoping ALONE leaves the binder untyped and
            // the receiver still resolves to nothing — the leak stops fabricating and the call stays
            // silent, which is the same purity claim by a different route. So the two forms whose type
            // is available WITHOUT inference are typed here:
            //
            //   `for case let x as T in …`  — T is written in the source. Nothing is inferred.
            //   `for case let x?     in …`  — Optional-unwrap sugar, and `elementTypeOf` already peels
            //                                 the Optional (`[Speaker?]` → `Speaker`), so the sequence's
            //                                 element type IS the binder's type.
            //
            // `.some(let x)` is deliberately NOT accepted through the second door even though it means
            // the same thing: a local enum with a case named `some` parses identically, and there the
            // element type is the ENUM and not the payload — a fabrication. That spelling is a
            // leading-dot case pattern and belongs to `typeEnumCaseBinding`, which types it from
            // `enumCaseValueType` or clears it. `x?` has no second reading in the grammar.
            let name = only.identifier.text
            if let t = Self.castBinderType(node.pattern).flatMap({ typeName($0).name }) {
                vars[name] = dealias(t)
            } else if Self.isOptionalUnwrapBinder(node.pattern), let elem = elementTypeOf(node.sequence) {
                vars[name] = elem.name
                if elem.mono { monoNames.insert(name) }
            }
        }
        return .visitChildren
    }

    /// `case let x as T` — the type the cast NAMES. SwiftParser leaves `as` unfolded, so the pattern is
    /// `[valueBinding >] expressionPattern > sequenceExpr [patternExpr, unresolvedAsExpr, typeExpr]`.
    private static func castBinderType(_ pattern: PatternSyntax) -> TypeSyntax? {
        var p = pattern
        if let vb = p.as(ValueBindingPatternSyntax.self) { p = vb.pattern }
        guard let ex = p.as(ExpressionPatternSyntax.self),
              let seq = ex.expression.as(SequenceExprSyntax.self) else { return nil }
        let elems = Array(seq.elements)
        guard elems.count == 3, elems[1].is(UnresolvedAsExprSyntax.self), elems[0].is(PatternExprSyntax.self),
              let te = elems[2].as(TypeExprSyntax.self) else { return nil }
        return te.type
    }

    /// The name of a pattern that is JUST a binder — `x` or `var x`/`let x`.
    private static func plainBinderName(_ pattern: PatternSyntax) -> String? {
        var p = pattern
        if let vb = p.as(ValueBindingPatternSyntax.self) { p = vb.pattern }
        return p.as(IdentifierPatternSyntax.self)?.identifier.text
    }

    /// `case let x?` — Optional-unwrap sugar, and only that spelling (see the caller for why `.some`).
    private static func isOptionalUnwrapBinder(_ pattern: PatternSyntax) -> Bool {
        var p = pattern
        if let vb = p.as(ValueBindingPatternSyntax.self) { p = vb.pattern }
        guard let ex = p.as(ExpressionPatternSyntax.self) else { return false }
        return ex.expression.is(OptionalChainingExprSyntax.self)
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

    // SYNC callback-invokers: standard higher-order methods on Sequence/Collection/Optional that
    // invoke their closure argument SYNCHRONOUSLY, in-thread, before returning. An OPAQUE closure arg
    // (a fn-typed PARAM, or an unresolvable callable value) passed to one of these is therefore CALLED
    // right here — its effects are reachable but unaddressable → `Unknown` (SPEC §4 callback). This is
    // the exact sibling of the direct opaque call `cb()`: `xs.forEach(cb)` runs `cb` too. INLINE closure
    // literals (`xs.forEach { … }`) are charged to the passer lexically and keep their analyzed effect
    // (they are ClosureExprSyntax, not opaque refs — never reach this guard); a RESOLVABLE named callable
    // (`xs.forEach(loadFree)`) keeps its resolved effect via the fn-ref edge above. Only the OPAQUE arg
    // discloses — low over-disclosure. Swift arm of the four-way sync-callback parity fix (candor-java).
    // reduce's closure is `(Acc, Element)`, still synchronously invoked; forEach/map/filter/… likewise.
    private static let SYNC_CALLBACK_INVOKERS: Set<String> =
        ["forEach", "map", "filter", "compactMap", "flatMap", "reduce",
         "first", "contains", "allSatisfy", "sorted", "min", "max",
         "firstIndex", "lastIndex", "last", "partition", "removeAll", "split",
         "drop", "prefix"]

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
        // Explicit receiver (`xs.forEach{…}`) OR bare/implicit-self (`forEach{…}` inside a Collection ext).
        let iteratorMethod: String? = (node.calledExpression.as(MemberAccessExprSyntax.self))?.declName.baseName.text
            ?? node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
        let pairIterator = iteratorMethod.map(Self.ELEMENT_PAIR_ITERATORS.contains) ?? false
        let iteratorElem: (name: String, mono: Bool)? = {
            if let ma = node.calledExpression.as(MemberAccessExprSyntax.self),
               Self.ELEMENT_ITERATORS.contains(ma.declName.baseName.text) || pairIterator,
               let base = ma.base {
                if let e = elementTypeOf(base) { return e }
                // `o.map { $0.go() }` where `o: (any Doer)?` — Optional.map's closure param is the
                // WRAPPED payload, here the protocol. `elementTypeOf` doesn't type an optional, so fall
                // back to a protocol-typed base (the optional sibling of the array-element map path). The
                // over-fire guard is `closure == elemClosure` + `localProtocols` at dispatch: a concrete
                // or non-protocol optional payload isn't in `protoTyped`, so it stays untyped (pure).
                if let dr = Self.peel(base).as(DeclReferenceExprSyntax.self), let proto = protoTyped[dr.baseName.text] {
                    return (proto, false)
                }
            }
            // BARE element-iterator over implicit `self` — `forEach { $0.persist() }` inside
            // `extension Array where Element: Saveable`: self's element is that bound (R28).
            if let dr = node.calledExpression.as(DeclReferenceExprSyntax.self),
               Self.ELEMENT_ITERATORS.contains(dr.baseName.text) || pairIterator {
                // `extension Array where Element: P` — Element is a generic parameter of the ARRAY the
                // caller holds, so it is monomorphized there, never erased. Always `mono`.
                return selfElementType.map { ($0, true) }
            }
            return nil
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
                    // iterator element param — typed (both params for a pair-iterator like
                    // sorted/min/max; only the first for the rest)
                    vars[p.name] = elem.name
                    // …and its opacity is DEFERRED to `visit(ClosureExprSyntax)`. This runs on the
                    // enclosing CALL, before the closure node is entered, and that visit shadows every
                    // closure parameter — so a flag set here would be wiped a moment later. Record it
                    // against the closure and let the closure's own visit re-apply it inside its save.
                    if elem.mono { monoClosureParams[closure.id, default: []].insert(p.name) }
                } else {
                    clearBindingTypeOnly(p.name)             // every other param — CLEARED, never leak
                    // (the FLAGS are cleared in visit(ClosureExprSyntax), inside the closure's save)
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
        //
        // ONLY the `.active(let c)` spelling is TYPED here. The `case let .active(c)` spelling puts the
        // `let` outside the parens, so its argument is a bare `patternExpr > identifierPattern` with no
        // `ValueBindingPattern`, and typing it from `singleAssoc` is a SEPARATE change with its own
        // measurement (it types operands that then reach the external-supertype disclosure rung — four
        // new `Unknown`s and one withdrawn over thirteen packages, filed in the work queue, not landed
        // with this). What BOTH spellings now do is register the name as a LOCAL, below.
        //
        // A PAYLOAD BINDING IS A LOCAL EVEN WHEN NOTHING CAN TYPE IT, and until `boundLocals` said so
        // the untyped case — the `case let .active(c)` spelling, an ambiguous case name, or any
        // multi-payload pattern, which the arity guard above refuses to type — left the name in NEITHER
        // `vars` NOR `boundLocals`, i.e. invisible to every shadow guard in this file. Two fabrications
        // followed, and the second is the one that cost a report entry:
        //   - a BARE READ of the name charged the enclosing type's same-named property, and
        //   - passing it as an argument (`help(ctx)`) charged a same-named FREE FUNCTION, because the
        //     fn-ref-as-argument rule can only skip arguments it can see are locals.
        // The free-fn form resolves to nothing, which marks the unit as reaching code the scan cannot
        // see — so an `invisible` disclosure was manufactured out of a local binding's name. See
        // `EnumPayloadBindingProcessTests`.
        //
        // KEYING ON `patternExpr` IS WHAT MAKES THE SECOND SPELLING EXACT, verified against SwiftParser
        // in the other direction too: a MATCHED CONSTANT (`case .three(konst)`) parses to
        // `declReferenceExpr` and a matched literal to `integerLiteralExpr`, neither of which is a
        // `PatternExprSyntax`. The enclosing `case let` is exactly what makes the parser wrap a bound
        // identifier in a pattern node, so this cannot mistake a value being compared for a name being
        // bound.
        let singleAssoc = node.arguments.count == 1 ? enumCaseValueType[ma.declName.baseName.text] : nil
        for arg in node.arguments {
            guard let pat = arg.expression.as(PatternExprSyntax.self) else { continue }
            // `.active(let c)` — the `let` inside the parens; the only spelling this types.
            if let vb = pat.pattern.as(ValueBindingPatternSyntax.self),
               let name = vb.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                // A REBIND DROPS EVERY INDEX FOR THE NAME, NOT JUST THE FLAGS. `shadowName` clears the
                // four flag maps; the TYPE indexes (`vars`, `protoTyped`, `arrayElem`/`opaqueElem`,
                // `dictElem`, `tupleElem`) live in `clearBindingTypeOnly`, and the typed branch below
                // used to reach neither — it wrote `vars` over the top and left the rest standing. So a
                // payload binding shadowing a same-named PROTOCOL-TYPED parameter still dispatched over
                // that protocol's conformers: `func f(_ p: Job, _ e: E) { switch e { case .active(let p):
                // p.run() } }` read `['Fs']` from `RealJob.run`, and the identical body with the binding
                // renamed `q` is ABSENT. `protoTyped` is consulted BEFORE the `vars` type at the member-
                // dispatch site, so writing the payload's own type over `vars` does not mask it.
                //
                // The clear is SCOPED, not permanent: `protoTyped` and `opaqueElem` are in `ShadowSave`
                // and the enclosing `SwitchCaseSyntax`/`IfExprSyntax` gives them back, so the genuine
                // parameter's dispatch below the case is untouched (asserted, not argued).
                clearBinding(name)
                if let singleAssoc { vars[name] = singleAssoc }
                casePayloadLocals.insert(name)
                markBinders(vb.pattern)
            } else if let ip = pat.pattern.as(IdentifierPatternSyntax.self) {
                // `case let .active(c)` — claimed for the EXISTENCE claim only. `clearBinding` is
                // exactly what `visit(IdentifierPatternSyntax)` did with it before, so the sole
                // difference this branch makes is the `casePayloadLocals` entry.
                clearBinding(ip.identifier.text)
                casePayloadLocals.insert(ip.identifier.text)
                markBinders(PatternSyntax(ip))
            }
        }
    }

    /// THE DEPENDENCY-FACTORY PROVENANCE GUARD, shared by BOTH spellings of the same call.
    ///
    /// `expr` is a call whose result `rootOf` could not type. This decides whether that untyped result
    /// plausibly came out of a CHAINED DEPENDENCY, which is what licenses the `<untyped>.` marker the
    /// Driver turns into either a `typeSurface.returns` determination or a half-1 disclosure.
    ///
    /// PROVENANCE IS THE HARD PART IN SWIFT, and measurement is what showed it. Unlike Rust, where the
    /// callee path carries a crate root, an idiomatic Swift call to an imported function is spelled BARE
    /// — `build()`, not `DepLib.build()` — so nothing at the call site distinguishes a dependency's
    /// factory from the stdlib's `max()` or from one of our own functions. Instrumented on real code, the
    /// unguarded form bound 239 locals on pollen and 50 on candor-swift, and the top hits were `max()`,
    /// `min()`, `abs()`, and LOCAL functions (`rootOf()`, `typeName()`) — not a dependency factory
    /// among them.
    ///
    /// `localFreeFns` removes the local leak outright. `PURE_STDLIB_FREE_FNS` is a carve-out of
    /// PROVEN-PURE value functions: each returns an ordinary value of an argument's own type, so a member
    /// call on the result is never a dependency reach. Carving proven-safe cases out of a sound
    /// over-approximation is the right direction; the list is deliberately short and admittedly
    /// incomplete, and what it misses costs precision (a spurious `Unknown`), never soundness.
    ///
    /// `enclosingMembers`/`localFuncs` are the two LOCAL-name kinds `localFreeFns` does not cover.
    /// MEASURED, not guessed: instrumented over 14 real targets the conjunct fires 289 times and the
    /// population is led by `rootOf` (16), `classifyItems`, `createFunction`, `parseMisplacedSpecifiers`,
    /// `expandMacros` — enclosing-type methods, with nested funcs behind them. Not one is a dependency
    /// factory, and a hedge wrong every time teaches a consumer to ignore the channel. candor-rust
    /// narrowed the same conjunct after measuring it fire on `max()`/`min()`. `enclosingMembers` is
    /// scoped to THIS type and its local supertypes, matching Swift's own bare-name resolution: a flat
    /// leaf set over every local type would let an unrelated same-named method exempt a real dependency
    /// factory, and losing a half-1 disclosure re-opens the silent purity claim this rung exists to
    /// close — the widening is the dangerous direction here, not the narrowing.
    ///
    /// IT IS A HELPER RATHER THAN AN INLINE CONDITION because there are TWO spellings of the same
    /// program and the guard has to be identical in both: `let c = build(); c.fetch()` (the binding, and
    /// the only one PART 21's fixture wrote) and `build().fetch()` (no binding at all). The unbound
    /// spelling read silent-pure while the bound one resolved or disclosed — a shipped guard whose
    /// fixture had picked one spelling (candor-spec `SCAN-BOUNDARY-WORK-QUEUE.md` §3c).
    func depFactoryCallee(_ expr: ExprSyntax) -> String? {
        guard let callee = Self.peel(expr).as(FunctionCallExprSyntax.self)?.calledExpression
                            .as(DeclReferenceExprSyntax.self)?.baseName.text,
              callee.first?.isUppercase == false, returns[callee] == nil,
              !localTypes.contains(callee), !localFreeFns.contains(callee),
              !enclosingMembers.contains(callee), !localFuncs.contains(callee),
              !Self.PURE_STDLIB_FREE_FNS.contains(callee) else { return nil }
        return callee
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // R33 — deinit-glue, asked of the CONSTRUCTION rather than of a binder. See `applyDeinitGlue`
        // for the vein this position closes and `constructionEscapes` for the gate that keeps a
        // factory's returned product uncharged.
        noteConstructionForDeinitGlue(node)
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
        // Is the callee a SYNC callback-invoker (`xs.forEach(…)` / bare `forEach(…)` in a Collection
        // extension)? Then an OPAQUE closure ARG is invoked synchronously here (see SYNC_CALLBACK_INVOKERS).
        let invokerMethod: String? = (node.calledExpression.as(MemberAccessExprSyntax.self))?.declName.baseName.text
            ?? node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
        let isSyncInvoker = invokerMethod.map(Self.SYNC_CALLBACK_INVOKERS.contains) ?? false
        for arg in node.arguments {
            let e = Self.peel(arg.expression)
            if let dr = e.as(DeclReferenceExprSyntax.self) {
                let n = dr.baseName.text
                // OPAQUE closure PARAM passed to a sync callback-invoker (`xs.forEach(cb)` where `cb` is a
                // fn-typed param): it is CALLED here, its effects reachable but unaddressable → deferred to
                // callback-flow (drops to pure iff every caller passes a closure/named fn; else §4 Unknown),
                // the exact machinery of the direct `cb()`. INLINE closures never reach here (ClosureExpr);
                // a RESOLVABLE named fn keeps its resolved effect via the fn-ref edge below.
                if isSyncInvoker && fnTyped.contains(n) {
                    if opaqueFnLocals.contains(n) {
                        // an OPAQUE fn-typed LOCAL (origin indeterminate, not a param) invoked via forEach:
                        // call-site flow can never resolve it → §4 Unknown directly (sibling of the direct
                        // `cb()` opaqueFnLocals path).
                        unresolved = true
                        why.insert("callback:\(n)")
                    } else {
                        // a fn-typed PARAM invoked via forEach — defer to callback-flow (index-resolved).
                        callbackInvoked.insert(n)
                    }
                }
                // skip a bound LOCAL (a value, not a free-fn reference) — `vars` drops literal-typed
                // locals, so `boundLocals` guards them too, else passing such a local fabricates a
                // same-named free fn's effect.
                if vars[n] == nil && !fnTyped.contains(n) && !isBoundLocal(n) {
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
                        calls.append(Call(path: n, leaf: n, strArg: nil, typed: false, unqualified: true, argRef: true))
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
            if chargeContentsCtor(name, node, lit: lit, shadowable: true) {
                // `Data`/`String(contentsOfFile:|contentsOf:)` — classified by the SHARED family function
                // so the module-qualified spelling of the same ctor answers identically (see it).
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
            } else if let et = enclosingType, !isBoundLocal(name), closureFields[et]?.contains(name) == true {
                // FINDING 2 — a bare `f(0)` invoking a stored CLOSURE PROPERTY of the enclosing type
                // (`self.f` implicit): the closure body runs. Edge to its property-scoped unit `<Type>.f` so
                // the closure's effects are reached (was silent-pure — the deferred/direct closure-property
                // hole). Guarded against a shadowing local `f` (boundLocals), which is a different value.
                propertyEdges.insert("\(et).\(name)")
            } else if let et = enclosingType, !isBoundLocal(name),
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
                // R35 — a `@dynamicCallable` type: `c(1, 2)` desugars to `c.dynamicallyCall(withArguments:)`
                // (or `withKeywordArguments:`), whose effectful body read silent-pure since the desugar was
                // invisible. Edge to the `dynamicallyCall` witness (soft edge — resolveQual drops it when the
                // type isn't @dynamicCallable / declares no such method, so an ordinary local-type value that
                // is not actually callable adds nothing).
                propertyEdges.insert("\(t).dynamicallyCall")
            } else if let et = enclosingType, !isBoundLocal(name), !localFreeFns.contains(name),
                      !declaredTypes.contains(et), let eff = kappaMember(root: et, member: name) {
                // an IMPLICIT-self member call inside an `extension <κ-platform-type>`: `launch()` inside
                // `extension Process` is `self.launch()` → Exec (the ShellOut `launchBash` cardinal-sin: it
                // read silent-pure). Mirrors the explicit-self path (line ~1417). Only fires when the
                // enclosing type is NOT declared locally (an extension of the real platform type) and the κ
                // table knows the member — a declared type shadows κ, a local free fn / shadowing local wins.
                let est = isEstablishingMember(effect: eff, root: et, member: name)
                directEffects.insert(eff)
                // SPEC §2 `fs` — refine an Fs we just PROVED with the direction its verb implies. A verb that
                // does not say contributes nothing, so the field stays absent rather than half-claimed.
                if eff == "Fs" { let ks = fsKind(root: et, member: name)
                                  if ks.isEmpty { fsKinds.insert("?") } else { for k in ks { fsKinds.insert(k) } } }
                if PRIVACY_EFFECTS_ALL.contains(eff) { for k in privacyKind(root: et, member: name) { privacyKinds[eff, default: []].insert(k) } }
                if eff == "Llm" { directEffects.insert("Net") } // §1 ⟨0.13⟩ a model-SDK call IS network I/O
                recordSurfaces(effect: eff, lit: lit, args: node.arguments, netEstablishing: est)
                if lit == nil, est, !(eff == "Fs" && lastResolvedHomePath) { incompleteSurfaces.insert(eff) }
            } else if (!declaredTypes.contains(name) || conditionallyShadowedTypes.contains(name)),
                      !localFreeFns.contains(name),
                      PRIVACY_CAPTURE_TYPES.contains(dealias(name)) {
                keepExtensionCtorEdge(name, node, lit: lit)
                // `privacy/1` finding 5 — an AVFoundation capture-type CONSTRUCTOR (`AVCaptureSession()`).
                // A ctor carries no media-type arg → the capture is ambiguous → over-disclose BOTH Camera
                // AND Mic (privacy: never under-declare a real sensor). A local type of the same name
                // already short-circuited above (declaredTypes/localTypes), so this never fabricates on
                // project code. Supersedes the flat Camera in kappaFree for these types.
                // DEFER the ambiguous case to `resolveAmbiguousCapture` — see `ambiguousCapture`.
                // ⟨fixed⟩ DEFER ONLY WHAT MAY BE DEFERRED. Deferring on `mt == nil` folded two different
                // facts into one flag: a call with NO media argument (a bare session — the medium comes
                // from the devices added beside it, so a sibling `.video` really does settle it) and a
                // call whose media argument IS present and computed (an INDEPENDENT capture source whose
                // medium nothing else in the function speaks for). Measured: a function opening a
                // `.video` device beside `AVCaptureDevice.default(for: kind)` reported Camera ALONE — the
                // possible Mic reach absent from `functions`, no `Unknown`, nothing in the ledger, and
                // `privacy-manifest --verify` telling the developer to declare only the camera key. A
                // silent under-report, introduced by the fabrication fix that added the deferral.
                switch mediaTypeArgKind(node.arguments) {
                case .determined(let name):
                    for e in privacyCaptureEffects(mediaType: name) { directEffects.insert(e); determinateCapture.insert(e) }
                case .undetermined:
                    // No sibling call can settle THIS one — charge both where it stands.
                    directEffects.insert("Camera"); directEffects.insert("Mic")
                case .absent:
                    ambiguousCapture = true
                }
                unionConditionalTypeEdge(name, node, lit: lit)
            } else if (!declaredTypes.contains(name) || conditionallyShadowedTypes.contains(name)),
                      !localFreeFns.contains(name),
                      dealias(name) == "NWBrowser" || dealias(name) == "NetServiceBrowser" {
                keepExtensionCtorEdge(name, node, lit: lit)
                // A BONJOUR BROWSER CONSTRUCTOR — `NWBrowser(for: .bonjour(…), using:)`, which is the
                // spelling real code uses; the member arm below only sees `browser.start()`. `.bonjour` is
                // mDNS by definition, so the descriptor decides the key with no over-disclosure rule
                // needed: a non-bonjour descriptor is simply not local-network. `Net` still comes from
                // kappaFree, which now knows this type at all — it did not before.
                if bonjourDescriptorArg(node.arguments) { directEffects.insert("LocalNetwork") }
                if let eff = kappaFree(name: dealias(name), argCount: node.arguments.count) {
                    directEffects.insert(eff)
                }
                unionConditionalTypeEdge(name, node, lit: lit)
            } else if (!declaredTypes.contains(name) || conditionallyShadowedTypes.contains(name)),
                      !localFreeFns.contains(name),
                      PRIVACY_EVENTKIT_TYPES.contains(dealias(name)) {
                keepExtensionCtorEdge(name, node, lit: lit)
                // `privacy/2` — an EventKit store CONSTRUCTOR (`EKEventStore()`). Carries no entity type,
                // so the store is ambiguous → over-disclose BOTH Calendar and Reminders, on the same
                // reasoning as the capture ctor directly above.
                for e in privacyEventKitEffects(entityType: entityTypeArg(node.arguments)) { directEffects.insert(e) }
                unionConditionalTypeEdge(name, node, lit: lit)
            } else if (!declaredTypes.contains(name) || conditionallyShadowedTypes.contains(name)),
                      !localFreeFns.contains(name), !depShadows(name),
                      let eff = kappaFree(name: dealias(name), argCount: node.arguments.count) {
                // A LOCALLY-DECLARED type ctor (`Pipe()` where `class Pipe`) or free fn (`NSLog(...)` where
                // `func NSLog`) ALWAYS shadows the platform free-call table — else a project's own
                // `Pipe`/`NSDate`/`NSLog`/`CACurrentMediaTime` fabricates Ipc/Clock/Log (the precision failure;
                // the same shadow discipline the member-call path applies via `declaredTypes`). When shadowed
                // it falls through to the unqualified Call below, which resolves to the local def.
                // `dealias(name)` resolves a typealias-named ctor (`Proc()`→`Process`→Exec) before κ; a
                // local type/free fn already short-circuited above, so an alias never overrides the project.
                // `depShadows` extends the SAME discipline across the scan boundary: a name a CHAINED
                // workspace dependency declares (`shellOut`, vendored ShellOut) shadows exactly as a local
                // declaration does — the 0.33.0 gate-level cardinal sin (see `depShadows`'s doc).
                keepExtensionCtorEdge(name, node, lit: lit)
                let aliasName = dealias(name)
                let est = isEstablishingFree(effect: eff, name: aliasName)
                directEffects.insert(eff)
                // SPEC §2 `fs` — refine an Fs we just PROVED with the direction its verb implies. A verb that
                // does not say contributes nothing, so the field stays absent rather than half-claimed.
                if eff == "Fs" { let ks = fsKind(root: aliasName, member: "<init>")
                                  if ks.isEmpty { fsKinds.insert("?") } else { for k in ks { fsKinds.insert(k) } } }
                if eff == "Llm" { directEffects.insert("Net") } // §1 ⟨0.13⟩ a model-SDK ctor/call IS network I/O
                recordSurfaces(effect: eff, lit: lit, args: node.arguments, netEstablishing: est)
                if lit == nil, est, !(eff == "Fs" && lastResolvedHomePath) { incompleteSurfaces.insert(eff) }
                // ⟨0.33.1⟩ UNION, not winner-take-all: `name` matched the κ table because no UNCONDITIONAL
                // local declaration shadows it, but `conditionallyShadowedFreeFns`/`conditionallyShadowedTypes`
                // says a `#if`-gated one exists — a build that actually compiles that branch runs IT, not
                // the platform function the heuristic just charged. Keep the ordinary call edge alive too,
                // so the local declaration's own effects (if it has any beyond the stub shape this was
                // found on) are ALSO counted rather than discarded the moment the heuristic answered.
                if conditionallyShadowedFreeFns.contains(name) || conditionallyShadowedTypes.contains(name) {
                    calls.append(Call(path: name, leaf: name, strArg: lit, typed: false,
                                      args: argKinds(node), argTypes: argTypesOf(node), unqualified: true))
                }
            } else {
                // R32 (swift) — an UNQUALIFIED requirement call inside a PROTOCOL EXTENSION (or protocol
                // default body): `self` is `Self: P`, so a bare `req()` may dispatch to each conformer's
                // WITNESS, whose override candor never reached (silent-pure — the protocol-witness sibling
                // of the concrete-receiver default dispatch). Record a protoDispatch; the Driver's bounded
                // CHA resolves it ONLY when `name` is a real requirement of P (`protocolMethods` guard), so
                // a bare free-fn/sibling call is filtered there and resolved by the plain Call below instead.
                if let et = enclosingType, localProtocols.contains(et) {
                    protoDispatches.append(ProtoDispatch(proto: et, member: name, argc: node.arguments.count,
                                                         argTypes: argTypesOf(node), args: argKinds(node)))
                }
                calls.append(Call(path: name, leaf: name, strArg: lit, typed: false, args: argKinds(node), argTypes: argTypesOf(node), unqualified: true))
            }
        } else if let ma = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let member = ma.declName.baseName.text
            let base = ma.base.map { rootOf($0) } ?? (root: nil, isVar: false, path: [], mono: false)
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
            } else if let pr = ma.base?.as(DeclReferenceExprSyntax.self), let proto = protoTyped[pr.baseName.text] {
                // dispatch through a LOCAL protocol-typed param — bounded CHA or honest Unknown. A
                // COMPOSITION param (`_ x: A & B`) is joined into one `protoCompositionSep`-delimited
                // string (see its doc); splitting is a no-op for the ordinary single-protocol case, which
                // contains no separator and yields itself back as the sole element. One dispatch per
                // composed protocol — the Driver's `protoOrSuperDeclares` guard silently skips whichever
                // one(s) do not actually declare `member`, so trying B when the call is really `x.a()`
                // costs nothing (see the fixture: `runComposed(_ x: A5 & B5) { x.a5() }`).
                for p in proto.split(separator: protoCompositionSep) {
                    protoDispatches.append(ProtoDispatch(proto: String(p), member: member,
                                                         argc: node.arguments.count, argTypes: argTypesOf(node), args: argKinds(node)))
                }
            } else if let baseDR = ma.base?.as(DeclReferenceExprSyntax.self),
                      arrayElem[baseDR.baseName.text] != nil, localTypes.contains("Array") {
                // an ARRAY receiver (`xs: [Item]`) calling a method a local `extension Array` provides —
                // conditional conformance: `xs.persist()` → `Array.persist` (R28). Uses `propertyEdges` (a
                // resolveQual soft edge) NOT a typed call, so a STD array method (`xs.forEach`, no
                // `Array.forEach` unit) drops SILENTLY — no spurious Unknown, no fabrication.
                propertyEdges.insert("Array.\(member)")
            } else if let rt = base.root, localTypes.contains(rt),
                      // A LOCAL PROTOCOL IS NOT A CONCRETE TYPE, even though `localTypes` holds its name.
                      // `visit(ExtensionDeclSyntax)` calls `pushType` on whatever it extends, so `extension
                      // Sink {…}` puts `Sink` in `localTypes` — and this branch then answered every call on
                      // a `Sink`-typed field/local with the single unit `Sink.<member>`. For an
                      // extension-PROVIDED member that unit exists and the answer looked right; for a
                      // REQUIREMENT there is no body to name, `resolveQual` found nothing, and the call was
                      // DROPPED SILENTLY — so `service.deploy(tag)` through a `Deployer` seam certified pure
                      // while `LiveDeployer.deploy` shells out. The protocol having ANY extension anywhere in
                      // the package was the whole trigger: with no extension the name never entered
                      // `localTypes`, this branch missed, and the CHA branch below answered correctly.
                      // Sending every protocol-typed receiver to that one branch makes BOTH member kinds
                      // resolve out of ONE member space (the Driver unions the extension default with the
                      // conformers' witnesses), instead of each lookup path covering one half.
                      !localProtocols.contains(rt),
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
                protoDispatches.append(ProtoDispatch(proto: rt, member: member, argc: node.arguments.count,
                                                     argTypes: argTypesOf(node), args: argKinds(node)))
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
                // ⟨0.29⟩ …AND ITS DIRECTION. This branch is GATED ON `isFileWrite`, so the direction is
                // proved by the very condition that selected it — and it was never recorded, while the
                // general `kappaMember` branch has always called `fsKind`. MEASURED: `d.write(to: url)`
                // and `s.write(toFile:)` published `fs: None` where `FileManager.createFile` publishes
                // `fs: ["write"]` on the same tree; `Data(contentsOfFile:)` above had the same gap for
                // reads. §2.1 `resolves` declares this producer COMPUTES `fs`, so a per-call gap
                // reintroduces per-unit the absent-vs-undetermined overload that declaration exists to
                // remove — PART 21's three-row rule, one level in.
                //
                // Found by the question that has now paid three times: enumerate every refinement the
                // GENERAL path performs, then check each carved-out special case against that list
                // (EventKit missed `privacyKind`; `FS_USE_VERBS`/`EXEC_USE_VERBS` missed one branch each).
                // No gate filters on `fs`, so this moves no verdict — it makes the report say what the
                // selecting condition already proved.
                fsKinds.insert("write")
                recordSurfaces(effect: "Fs", lit: lit)
                if lit == nil {
                    // CONSTANT PROVENANCE rung 4 — the literal was unreadable, but a HOME-ANCHORED
                    // expression still names a protected folder: `NSHomeDirectory() + "/Desktop/x"` is
                    // the spelling real code uses, and the class is decided by the proved prefix. Only
                    // when that also fails is the destination genuinely undetermined.
                    let resolved = node.arguments.lazy.compactMap { self.homeAnchoredPath($0.expression) }.first
                    if let r = resolved, !pathClasses(r).isEmpty {
                        for c in pathClasses(r) { directEffects.insert(c) }
                    } else {
                        incompleteSurfaces.insert("Fs")
                    }
                }
            } else if let rt = base.root, rt == "NWBrowser" || rt == "NetServiceBrowser",
                      !declaredTypes.contains(rt) {
                // A BONJOUR DESCRIPTOR is local-network by definition — `.bonjour(type:domain:)` is mDNS,
                // there is no non-LAN spelling of it. Unlike a HOST literal (where an unreadable value must
                // stay silent, or every networking app gains the key) this argument is a closed set, so an
                // unrecognised descriptor simply yields nothing rather than needing a judgement call.
                if bonjourDescriptorArg(node.arguments) { directEffects.insert("LocalNetwork") }
                // …AND the κ answer, for the same reason as the FileManager arm above: this branch fires
                // for ANY member on a browser receiver, so without this `b.start(queue:)` — the verb that
                // actually begins discovery — was silent-pure, and the `Net` entry this very wave added to
                // kappaMember was unreachable for exactly the receivers it was written for.
                if let eff = kappaMember(root: rt, member: member) { directEffects.insert(eff) }
            } else if let rt = base.root, rt == "FileManager", member == "urls" || member == "url",
                      !declaredTypes.contains(rt) {
                // CONSTANT-PROVENANCE rung 2 — `FileManager.default.urls(for: .desktopDirectory, in: …)`.
                // The CANONICAL spelling: real code asks for the search-path constant far more often than
                // it writes the path out, and unlike a literal it is always readable.
                //
                // ADDS TO the κ classification, never replaces it. `urls`/`url` are in FS_MEMBERS, and
                // this arm sits BEFORE the generic κ arm in the else-if chain — so the first cut dropped
                // the `Fs` those calls had always carried: `urls(for: .cachesDirectory,…)` and
                // `url(forUbiquityContainerIdentifier:)` went ABSENT from `functions` entirely, which
                // under ⟨0.21⟩ is a purity claim over a real file operation, and `urls(for:
                // .documentDirectory)` kept only the folder key. A refinement that swallows what it
                // refines is the cardinal sin wearing a feature's clothes — and the host-class arm one
                // screen up says exactly this in its own comment ("never instead of it").
                for c in searchPathClasses(searchPathArg(node.arguments)) { directEffects.insert(c) }
                if let eff = kappaMember(root: rt, member: member) {
                    directEffects.insert(eff)
                    if eff == "Fs" { fsKinds.insert("?") }   // destination is an enum, not a literal path
                }
            } else if let rt = base.root, PRIVACY_AUDIO_SESSION_TYPES.contains(rt), !declaredTypes.contains(rt) {
                // AVAudioSession / AVAudioApplication. `setCategory(.record)` is how essentially every
                // recording app reaches the microphone, and it emitted NOTHING until a recall battery
                // measured it. Mic is a MODELLED sensor, so this was not a vocabulary gap — it was a
                // covered sensor with its most common entry point missing, which is exactly the shape
                // that gets an app rejected AFTER a green verify. Playback apps configure sessions too,
                // so the type cannot be charged flatly; the category discriminates, and a category this
                // engine cannot read over-discloses.
                if PRIVACY_MIC_PERMISSION_MEMBERS.contains(member) {
                    directEffects.insert("Mic")                  // permission APIs mean the mic outright
                } else if member == "setCategory" {
                    // `setActive` WAS here and must not be: it never carries a category, so the argument
                    // reader returned nil and the unreadable-argument rule over-disclosed Mic to every
                    // audio app that activates a session — including one that just called
                    // `setCategory(.playback)`. The over-disclose rule is for a category it cannot READ,
                    // not for a call that has none.
                    for e in privacyAudioSessionEffects(category: audioCategoryArg(node.arguments)) {
                        directEffects.insert(e)
                    }
                }
            } else if let rt = base.root, PRIVACY_CAPTURE_TYPES.contains(rt), !declaredTypes.contains(rt),
                      !PRIVACY_CAPTURE_TEARDOWN_MEMBERS.contains(member) {
                // `privacy/1` finding 5 — an AVFoundation CAPTURE call (`AVCaptureDevice.default(for: .audio)`,
                // `.devices(for: .video)`, a bare `AVCaptureSession.startRunning()`): refine the Camera/Mic
                // split by the media-type argument the syntactic engine CAN see. A statically-visible
                // `.audio`→Mic / `.video`→Camera; an ambiguous capture (no visible media-type arg — a bare
                // AVCaptureSession, or a computed `for:` value) over-discloses BOTH (privacy: never
                // under-declare a real sensor). Confirmed-capture-type only, so an unknown receiver still
                // never fabricates. Supersedes the flat Camera in PRIVACY_SDK_TYPES for these types.
                // DEFER the ambiguous case to `resolveAmbiguousCapture` — see `ambiguousCapture`.
                // ⟨fixed⟩ DEFER ONLY WHAT MAY BE DEFERRED. Deferring on `mt == nil` folded two different
                // facts into one flag: a call with NO media argument (a bare session — the medium comes
                // from the devices added beside it, so a sibling `.video` really does settle it) and a
                // call whose media argument IS present and computed (an INDEPENDENT capture source whose
                // medium nothing else in the function speaks for). Measured: a function opening a
                // `.video` device beside `AVCaptureDevice.default(for: kind)` reported Camera ALONE — the
                // possible Mic reach absent from `functions`, no `Unknown`, nothing in the ledger, and
                // `privacy-manifest --verify` telling the developer to declare only the camera key. A
                // silent under-report, introduced by the fabrication fix that added the deferral.
                switch mediaTypeArgKind(node.arguments) {
                case .determined(let name):
                    for e in privacyCaptureEffects(mediaType: name) { directEffects.insert(e); determinateCapture.insert(e) }
                case .undetermined:
                    // No sibling call can settle THIS one — charge both where it stands.
                    directEffects.insert("Camera"); directEffects.insert("Mic")
                case .absent:
                    ambiguousCapture = true
                }
            } else if let rt = base.root, PRIVACY_EVENTKIT_TYPES.contains(rt), !declaredTypes.contains(rt) {
                // `privacy/2` — an EventKit STORE call (`store.requestAccess(to: .reminder)`,
                // `store.predicateForEvents(...)`): refine the Calendar/Reminders split by the entity-type
                // argument when it is statically visible, and over-disclose both when it is not. The
                // `!declaredTypes` guard is the same anti-fabrication fence as the capture arm: a project's
                // own `EKEventStore` is not EventKit's.
                for e in privacyEventKitEffects(entityType: entityTypeArg(node.arguments)) {
                    directEffects.insert(e)
                    // ⟨0.29⟩ …AND ITS DIRECTION, which this branch did not record. `privacyKind` already
                    // classifies EventKit's verbs (`calendars`/`events` read, `save`/`removeEvent` write)
                    // and `PRIVACY_DIRECTION_KEYS` already splits Calendar's keys read-vs-write — but the
                    // only caller of `privacyKind` was the GENERAL `kappaMember` branch below, and an
                    // EventKit store call never reaches it. So `privacy` was absent for Calendar and
                    // Reminders, the "no direction proved" fallback applied, and every key in the family
                    // counted as an acceptable alternative.
                    //
                    // MEASURED: a plist declaring ONLY `NSCalendarsWriteOnlyAccessUsageDescription`
                    // verified GREEN (exit 0) over code calling `EKEventStore().calendars(for: .event)` —
                    // a READ. Apple rejects that app. The same probe against Health (write over
                    // Share-only) and Photos (read over Add-only) correctly exits 1, so this was the one
                    // family of the three whose direction never arrived.
                    //
                    // The third time this rung: a rule honoured by one branch and not by its sibling
                    // (`FS_USE_VERBS` missed readv/writev, `EXEC_USE_VERBS` missed the cmds branch). When
                    // a special case is carved out, re-check every refinement the general path performed.
                    for k in privacyKind(root: rt, member: member) { privacyKinds[e, default: []].insert(k) }
                }
            } else if let mod = ma.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
                      isModuleQualifier(mod),
                      chargeModuleQualifiedSpelling(member, node, lit: lit) {
                // A MODULE-QUALIFIED SPELLING OF A FREE NAME — `Foundation.Process()`, and not a member
                // call on a value at all. MEASURED: it reported NOTHING where the bare `Process()`
                // reported `Exec`, and the loss compounded — `let t = Foundation.Process()` left `t`
                // untyped, so the `try t.run()` beneath it was silent too. One spelling of one
                // constructor visible and its sibling not is the defect class this project has recorded
                // more often than any other; the fix is the general rule (a module qualifier is a
                // SPELLING) rather than an entry for this one type.
                //
                // The predicate is `isModuleQualifier` — an IMPORTED module of this file that the
                // project does not itself define — and `chargeModuleQualifiedSpelling` answers only when
                // the BARE spelling would classify, so every callee κ does not know keeps the behaviour
                // it had (the dep-join and local-resolution arms below are untouched).
                //
                // TWO CONSEQUENCES, stated because they are the price of matching the bare spelling
                // rather than accidents. (1) When κ answers, the `extOwner` dep-join this arm preempts
                // does not run — the same trade the bare spelling has always made, since κ answers there
                // first too. (2) A dependency module that exports a type sharing a κ name is charged the
                // κ effect; that exposure is IDENTICAL to the bare spelling's and is not created here.
                // What is NOT covered: the ctor arms keyed directly on a `DeclReferenceExpr` callee
                // earlier in this visitor (`Data`/`String(contentsOf:)`). Pinned as an expected-failure
                // ratchet in `ExecCapabilityProcessTests`, with the reason the fix belongs one level up.
            } else if let rt = base.root, let eff = memberEffect(root: rt, member: member, receiver: ma.base) {
                directEffects.insert(eff)
                // SPEC §2 `fs` — refine an Fs we just PROVED with the direction its verb implies. A verb that
                // does not say contributes nothing, so the field stays absent rather than half-claimed.
                if eff == "Fs" { let ks = fsKind(root: rt, member: member)
                                  if ks.isEmpty { fsKinds.insert("?") } else { for k in ks { fsKinds.insert(k) } } }
                if PRIVACY_EFFECTS_ALL.contains(eff) { for k in privacyKind(root: rt, member: member, toShareIsNil: toShareIsNilArg(node.arguments)) { privacyKinds[eff, default: []].insert(k) } }
                // A member-gated family that ADDS rather than replaces — see PRIVACY_MEMBER_ALSO.
                if let also = PRIVACY_MEMBER_ALSO[rt]?[member] { directEffects.insert(also) }
                if eff == "Llm" { directEffects.insert("Net") } // §1 ⟨0.13⟩ a model-SDK call IS network I/O
                // A two-path Fs op (copyItem/moveItem/createSymbolicLink/…) carries a SOURCE *and* a
                // DESTINATION locator; the single-`lit` guard below captures only the first, so a literal
                // source would MASK a runtime destination (the two-path gate-evasion). Inspect EVERY
                // locator: capture all literals, mark Fs incomplete if any locator is non-literal.
                if eff == "Fs", rt == "FileManager", recordTwoPathFs(member: member, node.arguments) {
                    // handled — surfaces + incompleteness recorded per-locator
                } else if rt == "Process", ["run", "launch"].contains(member) {
                    // The LAUNCHING verb on a Process handle. Its command was fixed by an earlier property
                    // write, not by an argument here, so the locator comes from `execLocatorWrites` —
                    // or the surface is marked incomplete. Every other member (waitUntilExit, terminate,
                    // interrupt, suspend, resume, and the whole-type ⟨0.32⟩ tail) is teardown, wait or
                    // configuration: it names no program, so no command surface is claimed for it.
                    // CONSEQUENCE, stated rather than left to be discovered: a function that ARMS a
                    // handle and hands it on carries `Exec` with an EMPTY `cmds`, which `allow Exec
                    // <list>` reads as uncertifiable — fail-CLOSED. The literal is recorded at the
                    // launch because that is the point at which the dominance analysis knows which
                    // write survives; claiming it at the write would claim a program for an execution
                    // that may never happen with that value.
                    recordProcessRun(receiver: ma.base)
                } else {
                    let est = isEstablishingMember(effect: eff, root: rt, member: member)
                    recordSurfaces(effect: eff, lit: lit, args: node.arguments, netEstablishing: est)
                    if lit == nil, est, !(eff == "Fs" && lastResolvedHomePath) { incompleteSurfaces.insert(eff) }
                }
            } else {
                // `extOwner` carries the CONFIDENTLY-resolved receiver root (a typed value chain, or a
                // bare capitalized type reference — a static call `RatesClient.fetch()`) for the §2
                // CANDOR_DEPS join. An unresolved lowercase receiver (`base.isVar == false` on a plain
                // identifier that is just the receiver's own name) could only ever join by accident —
                // dep quals lead with a type name — but keep the owner honest: only a tracked value
                // (isVar) or a type-looking root qualifies.
                let owner = base.root.flatMap { r in (base.isVar || r.first?.isUppercase == true) ? r : nil }
                calls.append(Call(path: member, leaf: member, strArg: lit, typed: false, args: argKinds(node), argTypes: argTypesOf(node), opaqueRecv: base.mono, extOwner: owner))
                // COULD-NOT-FORM-A-KEY: the receiver is a local bound from a dependency call we could not
                // type, and nothing above resolved it. Emit a marker the Driver consumes into an honest
                // `Unknown`; it resolves to NOTHING by design — it exists to say no key was formed, not to
                // carry an effect. Distinguishable from a real path (angle brackets), exactly as the rust
                // `<untyped>` and `<drop>` markers are, so it can never reach local resolution or κ.
                if owner == nil, let r = base.root, let callee = depBoundLocals[r] {
                    calls.append(Call(path: "<untyped>.\(member)", leaf: member, strArg: nil,
                                      typed: false, args: [], argTypes: [],
                                      depCallee: callee, extOwner: nil))
                }
                // THE SAME PROGRAM WITH NO INTERMEDIATE BINDING: `build().fetch()` rather than
                // `let c = build(); c.fetch()`. There is no local to carry `depBoundLocals`, so the
                // branch above cannot fire and `rootOf` yields no root for an untypeable dep factory —
                // the call was dropped outright and the caller read silent-pure, while the bound
                // spelling of the identical program resolved (via `typeSurface.returns`) or disclosed
                // `Unknown`. Recover the provenance from the receiver EXPRESSION instead of from a
                // binding, through `depFactoryCallee` — the same guard, so the two spellings cannot
                // drift again — and emit the marker the Driver already understands.
                else if base.root == nil, let recvExpr = ma.base,
                        let callee = depFactoryCallee(recvExpr) {
                    calls.append(Call(path: "<untyped>.\(member)", leaf: member, strArg: nil,
                                      typed: false, args: [], argTypes: [],
                                      depCallee: callee, extOwner: nil))
                }
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
        // Claimed UNCONDITIONALLY, before the branch below decides whether it can type it: the
        // shorthand `guard let c` deliberately keeps the enclosing binding — `c` is the SAME value,
        // unwrapped — so letting `visit(IdentifierPatternSyntax)` clear it would drop a genuine type and
        // half 1's provenance with it. This is the one place where "unmarked means clear" would be
        // wrong, and it is marked for exactly that reason.
        markBinders(node.pattern)
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
           let initVal = node.initializer?.value {
            shadowName(name)  // a rebind, typed or not — the `if`/`while` (or the enclosing block, for
                              // `guard let`, whose binding runs to the end of that block) restores it
            // …and the TYPE indexes with them. Every branch below either types the name or clears it,
            // and the typing ones wrote `vars` over a live `protoTyped`: `func f(_ p: Job, _ o: Ctx?) {
            // if let p = o { p.run() } }` dispatched over `Job`'s conformers, where the same body with
            // the binding named `q` is ABSENT. `through: initVal` is what keeps `if let u = u.asURL()`
            // — see `rebindTyped`, and note the protocol-unwrap branch below READS `protoTyped` for the
            // initializer's own name, which the carve-out is exactly what preserves.
            rebindTyped(name, through: initVal)
            // `guard let d = s.data(using:.utf8)` / `= enc.encode(x)` — the unwrapped value is Data, so a
            // later `d.write(to:)` is Fs (the via-optional-binding dogfood vein; matches the plain-`let` path).
            if producesFoundationData(initVal) { vars[name] = "Data" }
            // `if let d = o` where `o: (any Doer)?` — unwrapping a PROTOCOL-typed optional param yields
            // the protocol; type `d` as the protocol so `d.go()` dispatches over the conformers (the
            // optional sibling of the array-element/dict-value existential paths). `protoTyped` holds the
            // protocol (rootOf leaves a proto param's root the bare name), so route `d` through `vars` —
            // rootOf(`d`) then resolves to the protocol name and the localProtocols dispatch fires.
            else if let dr = Self.peel(initVal).as(DeclReferenceExprSyntax.self), let proto = protoTyped[dr.baseName.text] {
                vars[name] = proto
            }
            else {
                let info = rootOf(initVal)
                if info.isVar, let t = info.root { vars[name] = t }
                else if let elem = elementTypeOf(initVal) { setArrayElem(name, elem) }
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
            let recv = node.base.map { rootOf($0) } ?? (root: nil, isVar: false, path: [], mono: false)
            var kappaClassified = false
            if let root = recv.root, !declaredTypes.contains(root),
               // a REAL local type named like a platform clock/env owner (`struct ContinuousClock { let now }`)
               // shadows the κ table; an EXTENSION of a platform type (`extension ProcessInfo {…}`) does NOT
               // — it's in localTypes but not declaredTypes. Gate on declaredTypes (parity with the method
               // κ-path) so env/fs property reads aren't silently zeroed project-wide by such an extension
               // (the real-world dogfood vein: `extension ProcessInfo` nulled all Env detection).
               let eff = kappaPropertyRead(root: root, path: recv.path + [node.declName.baseName.text]) {
                directEffects.insert(eff)
                // SPEC §2 `fs` — refine an Fs we just PROVED with the direction its verb implies. A verb that
                // does not say contributes nothing, so the field stays absent rather than half-claimed.
                if eff == "Fs" { let ks = fsKind(root: root, member: node.declName.baseName.text)
                                  if ks.isEmpty { fsKinds.insert("?") } else { for k in ks { fsKinds.insert(k) } } }
                if PRIVACY_EFFECTS_ALL.contains(eff) { for k in privacyKind(root: root, member: node.declName.baseName.text) { privacyKinds[eff, default: []].insert(k) } }
                kappaClassified = true
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
            } else if let root = recvRoot, localTypes.contains(root), !localProtocols.contains(root) {
                // …and NOT a local protocol: `extension P {…}` puts `P` in `localTypes`, so a read through a
                // `P`-typed field took this branch and edged the single soft key `P.<prop>`. An
                // extension-provided computed property resolved; a property REQUIREMENT has no body, so the
                // soft edge dropped and the read certified pure — the property sibling of the method-dispatch
                // hole above, with the same trigger (the protocol having any extension). Fall through to the
                // CHA branch, which now unions the extension default with the conformers' accessor units.
                // A PROPERTY-WRAPPED stored property (`@Logged var count`): `s.count` (read OR write)
                // desugars to `s._count.wrappedValue` — edge to the wrapper's wrappedValue accessor unit
                // so its I/O isn't silently pure. Gated on the attribute being a real `@propertyWrapper`
                // type (confirmed across all files), so a non-wrapper attribute never fabricates. `count`
                // itself is a stored property (no accessor unit), so the plain `S.count` edge below is
                // inert here; the wrappedValue edge is the real one.
                if prop.hasPrefix("$"), let wrapper = wrappedProps[root]?[String(prop.dropFirst())],
                   propertyWrapperTypes.contains(wrapper) {
                    // PROJECTED value: `m.$name` runs the wrapper's `projectedValue` accessor, not
                    // `wrappedValue` — edge to that unit so an effectful projection isn't silently pure.
                    propertyEdges.insert("\(wrapper).projectedValue")
                } else if let wrapper = wrappedProps[root]?[prop], propertyWrapperTypes.contains(wrapper) {
                    propertyEdges.insert("\(wrapper).wrappedValue")
                }
                propertyEdges.insert("\(root).\(prop)")
            } else if let root = recvRoot, localProtocols.contains(root) {
                // PROTOCOL PROPERTY-REQUIREMENT dispatch: `p.payload` where `p` is a protocol-typed
                // receiver — resolve to the conformers' `payload` accessor units (bounded CHA) or honest
                // Unknown, exactly like a method dispatch. The CHA-as-method-requirement path (~line 1299)
                // only knew FUNCTION requirements; a property requirement read was silently pure.
                protoPropReads.append((root, prop))
            } else if !kappaClassified, let root = recvRoot, !root.hasPrefix("<"),
                      !Self.METATYPE_MEMBERS.contains(prop),
                      recv.isVar || root.first?.isUppercase == true {
                // A PROPERTY ACCESSOR ON A CHAINED DEPENDENCY'S TYPE. `l.v` where `L` belongs to a
                // dependency: every branch above is LOCAL-ONLY (`localTypes`/`localProtocols`), so the
                // read fell off the end of this chain and was never recorded at all — the reader read
                // silent-pure while the dep's report carried `L.v ['Fs'] accessor` under exactly the key
                // needed. Reading a computed/lazy property RUNS its body, which is the same reach a
                // method call has, and the method path has joined the dep report since §2 shipped.
                //
                // NOT lazy-specific: a plain computed `var`, and a STATIC accessor read off the type
                // name, are the same shape and were equally silent. PART 19's swift fixture reads a
                // module-level GLOBAL, which IS modelled — so the accessor form had never been asked
                // (candor-spec `SCAN-BOUNDARY-WORK-QUEUE.md` §3c).
                //
                // A CANDIDATE, joined against a sibling report ONLY (in the Driver), exactly like
                // `deinitExternal`/`stringifyExternal`. Self-filtering in the way that matters here:
                // a STORED property and a PURE computed one have no entry in the dep report, so this
                // adds nothing for them — the effectful accessor is the only thing it can pick up.
                // Not `propertyEdges`, which is the LOCAL resolution set: a local type reaches its own
                // unit through the branch above and never gets here, so a dependency type sharing a
                // local type's name cannot lend it an effect.
                //
                // Three gates keep the key honest. Two are copied from the method path's `extOwner`: κ
                // classified reads are already answered (`ProcessInfo.processInfo.environment` must not
                // also be asked of the dependency), and only a tracked value (`isVar`) or a type-looking
                // root qualifies — an unresolved lowercase identifier is just the receiver's own name and
                // could join only by accident, since dep quals lead with a type name.
                //
                // The third, `METATYPE_MEMBERS`, was FOUND BY THE A/B on real code and is not a
                // hypothetical: `scope.split(separator: ".").map(String.init)` is a MemberAccessExpr with
                // the member `init`, and swift-syntax's report carries `SwiftSyntax#String.init` for its
                // OWN `extension String` — so the join charged that extension's `Unknown` to every caller
                // passing the STDLIB's `String.init` as a function reference. `.init`/`.self`/`.Type`/
                // `.Protocol` are metatype and initializer spellings, never property accessors, so no
                // accessor unit can legitimately answer them; excluding them removes the whole class
                // rather than the one collision that surfaced.
                propertyExternal.insert("\(root).\(prop)")
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
            // ...but a global read is still a read when it is the BASE of a member access or subscript:
            // `dbg.count` / `table[k]` force `dbg`/`table`'s initializer exactly as a bare `dbg` does, and
            // the base's own visitor is the only place that sees it. Skipping the whole form left an
            // effectful global silent at every reader that touched a member OF it — by far the commoner
            // shape (candor-spec SOUNDNESS-VEIN-initializer-edge.md).
            // Two exclusions keep it exact: the member NAME (this visitor fires on that too, and recording
            // it would edge to a global that was never read), and an INSTANCE PROPERTY of the enclosing type
            // — a bare `typeStack.append(x)` in a method is `self.typeStack`, which the bare-read path
            // already routes to `propertyEdges`.
            let isReadBase = (p.as(MemberAccessExprSyntax.self)?.base?.id == node.id)
                || (p.as(SubscriptCallExprSyntax.self)?.calledExpression.id == node.id)
            if isReadBase {
                if let et = enclosingType, fields[et]?[n] != nil { return .skipChildren }
                globalReads.insert(n)
                return .skipChildren
            }
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
        if let et = enclosingType, !isBoundLocal(n) { propertyEdges.insert("\(et).\(n)") }
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
        recordProcessLocatorWrite(elems)
        recordInvocationConfigWrite(elems)   // SPEC §1 ⟨0.32⟩ — configuring an invocation IS the capability
        var i = 0
        while i + 2 < elems.count + 1 && i + 1 < elems.count {
            guard let op = elems[i + 1].as(BinaryOperatorExprSyntax.self) else { i += 1; continue }
            let opName = op.operator.text
            // resolve a local operand type from either side (the lhs first, then rhs)
            let lt = rootOf(elems[i]), rt = i + 2 < elems.count ? rootOf(elems[i + 2]) : (root: nil, isVar: false, path: [], mono: false)
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
            // GENERIC / protocol-typed operand: `a + b` where `a: T: P` and `P` declares the operator —
            // dispatch to `P`'s conformers' operator WITNESSES via bounded CHA, the operator analog of the
            // generic-METHOD path (`x.act()` on `x: T: P` already resolves; the operator did not, so an
            // effectful `static func + ` witness read silent-pure). The concrete-operand edge above needs a
            // localTypes type; a generic/protocol operand has none. The Driver's CHA gates on `P` actually
            // declaring `opName`, so a std operator over a `Numeric`/`Comparable` bound (no local conformer /
            // not a declared requirement) resolves to nothing — no fabrication.
            if !localOperand {
                for operandExpr in [elems[i], (i + 2 < elems.count ? elems[i + 2] : nil)].compactMap({ $0 }) {
                    if let dr = Self.peel(operandExpr).as(DeclReferenceExprSyntax.self),
                       let proto = protoTyped[dr.baseName.text] {
                        protoDispatches.append(ProtoDispatch(proto: proto, member: opName))
                    }
                }
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

    // A well-known Swift COMPILER-BUILTIN freestanding expression macro. SE-0382 (Swift 5.9) re-expressed
    // the language's source-location literals and Objective-C interop literals as macros under the hood,
    // so `#file`/`#line`/`#function`/… parse as the SAME `MacroExpansionExprSyntax` node a real third-
    // party macro does — the grammar cannot tell them apart, only the macro NAME can. All of these resolve
    // entirely at compile time to a value the compiler already knows; none of them is a call, and none can
    // carry an effect. Denylisted here so the fix below discloses genuine unresolved macros without
    // drowning every defaulted `file: String = #file` / `line: Int = #line` parameter — by far the most
    // common `#`-expressions in real Swift — in noise that would fabricate the opposite failure this fix
    // exists to close (AGENT-CORPUS-BRIEF rule 9: a control must not gain on a `#` expression that isn't
    // really a macro).
    //
    // `fileID` (SE-0274) and `isolation` (SE-0420's default-isolated-parameter literal, `isolation:
    // isolated (any Actor)? = #isolation`) were MEASURED missing from the first cut of this list — the
    // 13-package before/after corpus diff surfaced 93 `fileID` and 8 `isolation` hits (swift-nio and
    // Nimble default nearly every logging/assertion parameter to one or the other), which would have been
    // exactly the noise this denylist exists to prevent. `error`/`warning` are the compiler's source
    // diagnostics (`#error("…")`) — this engine reads BOTH arms of every `#if` unconditionally (its
    // documented `#if` policy), so an `#else #error(...) #endif` platform stub is walked like any other
    // code; diagnostics run at compile time only and can carry no runtime effect either.
    private static let KNOWN_PURE_FREESTANDING_MACROS: Set<String> = [
        "file", "filePath", "fileID", "line", "column", "function", "dsohandle", "isolation",
        "selector", "keyPath", "colorLiteral", "imageLiteral", "error", "warning",
    ]

    // A freestanding macro EXPRESSION (`#urlFetch("...")`) had no visitor at all before this — not even
    // FunctionCallExprSyntax matches its syntax shape (`MacroExpansionExprSyntax` is its own node kind) —
    // so a call reaching an arbitrary macro-injected effect (Net, Fs, …) read completely silent-pure: no
    // `Unknown`, no `unresolved`, nothing. A macro cannot be expanded without running its compiler plugin,
    // which is out of reach for a syntax-only engine, so this does not attempt to resolve what the macro
    // actually does (that would be fabrication in the opposite direction) — it discloses that candor could
    // not see past it, in the SAME vocabulary an unaddressable dispatch/callback already uses (`why:
    // "macro:<name>"`, SPEC §4's `unknownWhy`).
    //
    // A TRAILING CLOSURE on the same node (`#Preview { call() }`) is ordinary Swift the compiler runs
    // verbatim, and the existing `ClosureExprSyntax` visitor already walks it regardless of what
    // syntactically contains it — so a trailing closure's own effects are ALREADY caught concretely with
    // no help from this visitor. Disclosing `Unknown` ANYWAY on that same node would sit the vague verdict
    // right beside the concrete one this scan already earned for free, which is precisely the "regression
    // from precise to vague" this fix must not cause (measured: it double-counted `#Preview { … }` in first
    // testing here, adding `Unknown` next to a real Net catch for no reason — the exact caution named in
    // the brief). So the disclosure below is gated to the residual the brief scoped this to: a freestanding
    // macro with NO trailing closure at all (neither the shorthand `trailingClosure` nor the multiple-
    // closure form) — `.visitChildren` still runs either way, so a closure body or ordinary arguments are
    // still walked exactly as before.
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.macroName.text
        let hasClosure = node.trailingClosure != nil || !node.additionalTrailingClosures.isEmpty
        if !hasClosure && !Self.KNOWN_PURE_FREESTANDING_MACROS.contains(name) {
            unresolved = true
            why.insert("macro:\(name)")
        }
        return .visitChildren
    }

    // `obj[i]` / `obj[i] = v` — a subscript ACCESS runs the subscript's getter/setter body (a
    // `Type.subscript` unit). Resolve the base receiver's type; a local-type base edges to its
    // subscript unit (read/write indistinguishable here — over-approximate to the union, the sound
    // direction). A protocol-typed or untyped base is left to the existing postures (no fabrication).
    override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        let base = rootOf(node.calledExpression)
        // `!localProtocols` for the same reason as the method/property paths: an `extension P` puts `P` in
        // `localTypes`, and a subscript REQUIREMENT has no `P.subscript` unit to soft-edge to, so the access
        // dropped silently instead of dispatching over the conformers' subscript units.
        if let rt = base.root, localTypes.contains(rt), !localProtocols.contains(rt) {
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
            // implicit root `\.prop`: two enclosing forms give the root type differently —
            //  · `base[keyPath: \.prop]` — a SUBSCRIPT application: the root is the RECEIVER's OWN type.
            //  · `recv.map(\.prop)` — an element-iterator call: the root is the receiver's ELEMENT type.
            // Walk to whichever encloses first. (The subscript form read silent-pure: the old walk skipped
            // straight past it to a FunctionCall — R25.)
            var p: Syntax? = node.parent
            while let cur = p, !cur.is(FunctionCallExprSyntax.self), !cur.is(SubscriptCallExprSyntax.self) {
                p = cur.parent
            }
            if let sub = p?.as(SubscriptCallExprSyntax.self), sub.arguments.first?.label?.text == "keyPath" {
                rootType = rootOf(sub.calledExpression).root      // `h[keyPath: \.prop]` → type of `h`
            } else if let call = p?.as(FunctionCallExprSyntax.self),
                      let ma = call.calledExpression.as(MemberAccessExprSyntax.self), let base = ma.base {
                rootType = elementTypeOf(base)?.name
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

    /// NON-LOCAL protocols whose conformance is declared IN the analysed code and whose witness is what a
    /// stringification site runs: the two `Custom*StringConvertible` protocols themselves, and the error
    /// protocols (`catch { log("\(error)") }` is the Swift spelling of the HikariCP finding — log an
    /// object, its `description` runs). NAMED explicitly rather than "any type that has local conformers"
    /// because Swift's inheritance clause is overloaded: `enum Suit: String` / `enum Code: Int` record
    /// String/Int as conformed supertypes, so an open rule would edge every `"\(someString)"` to a raw-
    /// value enum's `description` — a fabrication. This is the one place the family's denylist-over-
    /// allowlist rule inverts: a denylist here is the FABRICATING direction, so the list is closed and
    /// what it omits under-reports (recorded below as the residual) instead of inventing an effect.
    private static let EXTERNAL_STRINGIFY_PROTOCOLS: Set<String> =
        ["CustomStringConvertible", "CustomDebugStringConvertible", "Error", "LocalizedError"]

    /// The TYPE a stringification operand DISPATCHES over when it is not a plain local type: a LOCAL
    /// PROTOCOL (an existential `any P` / bare `P` param, a `P`-typed field or binding, or a generic
    /// `<T: P>` param — DeclCollector already resolves a generic bound to its protocol), one of the
    /// external stringify protocols above, or the type of a CATCH binding. nil when the operand has no
    /// such type. A protocol-typed operand's witness is only knowable by DISPATCH over the conformers, so
    /// it can't go through `localTypeOfOperand` (protocols are deliberately absent from `localTypes`).
    private func dispatchTypeOfOperand(_ raw: ExprSyntax) -> String? {
        let e = Self.peel(raw)
        if let dr = e.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            // a protocol-typed PARAM is held in `protoTyped`, NOT `vars` — rootOf leaves its root the bare
            // param name (isVar false), exactly as the method-dispatch/property-read paths handle it.
            if let p = protoTyped[n] { return p }
            // a CATCH binding (`catch { … "\(error)" }`'s implicit `error`, `catch let e`, `catch let e as
            // MyError`): no other index types these, so the interpolation resolved to NOTHING. A param or
            // any other LOCAL binding of the same name SHADOWS — `boundLocals` carries the literal-typed
            // locals `vars` drops (a `let error = "oops"` must not dispatch over the Error conformers).
            if vars[n] == nil, !isBoundLocal(n), let t = catchBindings[n] { return t }
        }
        let r = rootOf(e)
        // a protocol-typed FIELD / `let` / loop var / unwrapped optional: rootOf resolves the chain to the
        // protocol NAME with isVar set. `isVar` is required so a bare identifier that merely SPELLS a
        // protocol name (never a value) can't dispatch.
        guard r.isVar, let t = r.root else { return nil }
        if localProtocols.contains(t) || Self.EXTERNAL_STRINGIFY_PROTOCOLS.contains(t) { return t }
        return nil
    }

    /// Names bound by an enclosing `catch` clause → the type caught (the concrete type of a
    /// `catch let e as MyError`, else `Error`). Consulted ONLY by the stringification path, so it cannot
    /// perturb any other resolution. Function-wide like every other binding index here — a name leaking
    /// past its catch block can at most add a stringify edge for a same-named value.
    private var catchBindings: [String: String] = [:]

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        enterShadowScope(node)   // `catch let e` is a rebind scoped to the clause (see shadowName)
        // `catch { … }` with no items binds the IMPLICIT `error`.
        if node.catchItems.isEmpty { catchBindings["error"] = "Error"; shadowName("error") }
        for item in node.catchItems {
            guard let pat = item.pattern else { catchBindings["error"] = "Error"; shadowName("error"); continue }
            guard let vb = pat.as(ValueBindingPatternSyntax.self) else { continue }   // `catch is X` binds nothing
            if let id = vb.pattern.as(IdentifierPatternSyntax.self) {
                catchBindings[id.identifier.text] = "Error"          // `catch let e`
                shadowName(id.identifier.text)                       // …and it REBINDS the name
                markBinders(vb.pattern)
            } else if let ex = vb.pattern.as(ExpressionPatternSyntax.self),
                      let seq = ex.expression.as(SequenceExprSyntax.self) {
                // `catch let e as MyError` — SwiftParser leaves `as` unfolded: [binder, UnresolvedAs,
                // Type]. Bind the CONCRETE type so the witness resolves precisely (a non-local type
                // resolves to no unit and contributes nothing).
                //
                // The binder is a `patternExpr > identifierPattern`, NOT a bare `declReferenceExpr` —
                // this read `elems[0].as(DeclReferenceExprSyntax)` and so never fired, leaving `e`
                // untyped AND unshadowed. Dumped from SwiftParser rather than reasoned about, after the
                // same wrong assumption produced `patternBinders`' three-kind list.
                let elems = Array(seq.elements)
                if elems.count == 3, elems[1].is(UnresolvedAsExprSyntax.self),
                   let pe = elems[0].as(PatternExprSyntax.self),
                   let name = pe.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                    shadowName(name)                                 // a rebind whether or not it types
                    if let te = elems[2].as(TypeExprSyntax.self), let tn = typeName(te.type).name {
                        catchBindings[name] = dealias(tn)
                    }
                    markBinders(pe.pattern)
                }
            }
        }
        return .visitChildren
    }

    /// Edge an interpolation/`String(describing:)`/`print` operand to its local type's stringification
    /// witness. `reflecting` picks `debugDescription` (the `CustomDebugStringConvertible` witness), else
    /// `description`. A property READ (the getter runs) — `propertyEdges`/resolveQual drop it when the
    /// type declares no such accessor unit (a stored property, or a synthesised/external witness) → no
    /// fabrication; a PURE `description` accessor contributes nothing.
    ///
    /// PROTOCOL-EXISTENTIAL / GENERIC operand (`"\(e)"` where `e: any Entry` / `<T: Entry>`): the witness
    /// that runs is the CONFORMER's, which only DISPATCH can name — the concrete-type path above resolves
    /// nothing (a protocol is not in `localTypes`), so such a site read SILENT-PURE even though every
    /// conformer's `description` was analysed correctly (the four-way implicit-stringification vein:
    /// candor-spec/SOUNDNESS-VEIN-implicit-stringify.md). Record a stringify dispatch; the Driver resolves
    /// it by CHA over the protocol's conformers, edging ONLY to `description` accessor units that
    /// genuinely exist — a conformer with no (or a pure) `description` contributes nothing.
    private func edgeStringWitness(_ operand: ExprSyntax, reflecting: Bool) {
        let member = reflecting ? "debugDescription" : "description"
        if let t = localTypeOfOperand(operand) {
            propertyEdges.insert("\(t).\(member)")
        } else if let d = dispatchTypeOfOperand(operand) {
            // a CONCRETE local type from a typed catch (`catch let e as MyError`) is a precise witness —
            // the same soft property edge as the plain concrete path; anything else DISPATCHES.
            if localTypes.contains(d) { propertyEdges.insert("\(d).\(member)") }
            else { stringifyDispatches.append((d, member)) }
        } else if let x = externalTypeOfOperand(operand) {
            // The operand has a confidently-resolved type that is NOT declared here — most often a
            // chained DEPENDENCY's type. Record the `Type.member` candidate; the Driver joins it against
            // a sibling report only (`<Module>#<Type>.<member>`) and drops it otherwise, so a stdlib or
            // unchained operand contributes exactly nothing, as today.
            stringifyExternal.insert("\(x).\(member)")
        }
    }

    /// The NON-LOCAL type of a stringification operand: the same confidently-resolved value type the
    /// local path demands (`rootOf(...).isVar` — a bare identifier that merely SPELLS a type name has
    /// isVar false and is rejected), minus the `localTypes` membership. `Entry` for `e: Entry`,
    /// `Entry()` inline, and a `[Entry]` element bound to a closure's `$0` — all three resolve through
    /// this one resolver, which is why the three silent forms close together.
    private func externalTypeOfOperand(_ raw: ExprSyntax) -> String? {
        let r = rootOf(raw)
        // `<super>` is rootOf's marker, not a type — rejected by its bracketed spelling (no Swift type
        // name starts with `<`), which also keeps any future marker out.
        guard r.isVar, let t = r.root, !t.hasPrefix("<"), !localTypes.contains(t) else { return nil }
        return t
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
        guard let elem = elementTypeOf(base)?.name, localTypes.contains(elem) else { return }
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
    //
    // ITS PARAMETERS ARE ITS OWN, and they are a SCOPE like every other binder. The enclosing unit's
    // signature flags are keyed by NAME, and a nested `func` re-declaring one of those names does not
    // inherit what the outer spelling meant: `func outer(_ s: some Speaker) { func inner(_ s: any
    // Speaker) { s.speak() } }` had `inner`'s genuinely ERASED receiver suppressed by the outer
    // parameter's opacity and read silent-pure — measured, and Env the moment the outer parameter is
    // spelled `any`. This is the swift form of the nested-item leak candor-rust's R4 needed a third
    // carve-out for: a nested item has its own signature but its calls attribute to the enclosing unit,
    // so its parameters SHADOW the outer ones.
    //
    // A shadow alone would be the mirror sin — `func inner(_ s: some Speaker)` inside an erased outer
    // would start dispatching over the local conformers — so the nested signature's OWN opacity is
    // re-applied, through the same `isOpaqueParam`/`arrayElementType` predicates DeclCollector uses for
    // a top-level parameter rather than a second copy of the rule. RESIDUAL, deliberately untouched:
    // the TYPE indexes (`vars`/`arrayElem`) are function-wide by design and still hold the enclosing
    // binding's type for the name — a pre-existing leak in both directions, unchanged here, and a
    // separate measurement from this one.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        localFuncs.insert(node.name.text)
        enterShadowScope(node)
        for p in node.signature.parameterClause.parameters {
            let name = (p.secondName ?? p.firstName).text
            guard name != "_" else { continue }
            shadowName(name)
            opaqueElem.remove(name)
            // A NESTED FUNC'S PARAMETER REBINDS THE NAME TOO. `protoTyped` and `opaqueElem` are the two
            // scoped maps, so clearing them here is given back at `visitPost` and costs nothing outside;
            // without it `func f(_ p: Job) { func inner(_ p: Ctx) { p.run() } }` dispatched over `Job`'s
            // conformers, against a rename control that is ABSENT. The type indexes are deliberately NOT
            // touched — `vars` is not in `ShadowSave`, so clearing it here would leak the clear outward
            // past the nested func, which is the pre-existing leak the note above this visitor files as
            // a separate measurement.
            protoTyped.removeValue(forKey: name)
            if isOpaqueParam(p.type) { monoNames.insert(name) }
            if arrayElementType(p.type).map(isOpaqueParam) == true { opaqueElem.insert(name) }
        }
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { leaveShadowScope(node) }

    // R33 — deinit-glue. A CONSTRUCTION of a type with an effectful `deinit` runs that deinit where
    // the value's last reference dies; for a value that never leaves the constructing function that is
    // THIS scope, deterministically under ARC — but silent-pure, because the deinit unit has no
    // syntactic caller (mirrors rust's Drop-glue).
    //
    // THE VEIN, measured 2026-08-31 with ground truth EXECUTED: this mechanism used to hang off the
    // BINDER — three call sites inside `visit(VariableDeclSyntax)` — so it fired if and only if the
    // construction rooted a `let`/`var` local. Every OTHER position a construction can occupy was a
    // silent under-report, and most of them contain no closure and no existential, so the "binder
    // shape" framing the previous fix was filed under could not see them: `_ = Ctor()` (no `let`), a
    // bare expression statement, a call ARGUMENT, an array / dictionary / tuple literal element, a
    // struct-field argument, a capture list, `if let` / `guard let` / a `switch` subject, a TUPLE
    // DESTRUCTURING, a ternary arm, `Ctor().member`, `xs.append(Ctor())`. Sixteen positions were
    // compiled and RUN with an unbuffered `deinit`: every one printed before its function returned.
    //
    // So the rule is stated ONCE, at the construction expression (`visit(FunctionCallExprSyntax)` →
    // `noteConstructionForDeinitGlue`), and the three binder call sites were REMOVED rather than left
    // beside it. Two paths computing one fact are free to disagree, which is exactly how this vein
    // opened: the annotated binder and the unannotated binder had drifted, that drift was closed by
    // factoring THEM together, and the factoring left the position question unasked.
    private func applyDeinitGlue(root t: String) {
        if localTypes.contains(t) {
            // A `propertyEdges` SOFT edge, NOT a typed Call: it resolves via resolveQual and DROPS
            // SILENTLY when the type has no deinit unit (a struct/pure class → nothing), never
            // reaching the external-protocol member-dispatch fallback that would fabricate Unknown for
            // any type conforming to a non-pure external protocol (the ActivityAttributes
            // over-charge). A real class deinit resolves; an inherited deinit chains via the
            // supertype resolution there.
            propertyEdges.insert("\(t).deinit")
        } else if !t.hasPrefix("<") {
            // THE SAME GLUE ONE SCAN BOUNDARY OUT: the constructed type belongs to a chained
            // DEPENDENCY, so it is not in `localTypes` and the soft edge above never fires — a dep
            // class whose `deinit` is effectful, held as a local, reads silent-pure with the dep's
            // report chained even though that report records the unit under `<Module>#<Type>.deinit`
            // (candor-spec/SOUNDNESS-VEIN-crossing-the-scan-boundary.md). Recorded as a candidate and
            // joined against the sibling report ONLY, in the Driver; with no dep report loaded
            // nothing consults it. Self-filtering the same way: a struct or a class with no (or a
            // pure) `deinit` has no entry in the dep report, so the join adds nothing.
            deinitExternal.insert("\(t).deinit")
        }
    }

    /// The TYPE a call CONSTRUCTS, or nil if the call is not a construction.
    ///
    /// `rootOf` answers a BROADER question — "what type does this expression's value have" — and two of
    /// its arms are true of that question and false of this one. Both were MEASURED on the corpus, not
    /// reasoned about, and the second is the one that would have shipped a fabrication:
    ///
    /// · a SINGLETON accessor (`AVAudioSession.sharedInstance()`) hands back a shared instance this
    ///   scope neither created nor releases;
    /// · a MEMBER-ACCESS FACTORY (`X.make()`) resolves through `returns`, which is keyed by LEAF NAME
    ///   across the whole module. An ENUM CASE WITH A PAYLOAD is spelled identically. GRDB has both a
    ///   `Database.TraceEvent.statement(_:)` case and an unrelated `func statement(_:) -> Statement`,
    ///   so `trace(TraceEvent.statement(s))` resolved to `Statement` and charged `Database.trace_v2`
    ///   the `Db` of `Statement.deinit`'s `sqlite3_finalize` — a construction that never happened, of a
    ///   type that never appears in that function. `TraceEvent.Statement` is a STRUCT, with no `deinit`
    ///   at all. Caught by the A/B, which is the only thing that could have caught it.
    ///
    /// So a construction is a CONSTRUCTOR SPELLING: an uppercase bare callee, a dotted path naming a
    /// local nested type, a module-qualified uppercase name, or a bare call to a known local free
    /// FACTORY (`localFreeFns` narrows the same leaf-key collision that sinks the member form).
    /// Resolution itself is still delegated to `rootOf`, so the type this yields cannot drift from the
    /// type the rest of the collector believes the value has.
    ///
    /// STATED NARROWING: `let s = db.makeStatement(…)` — a member-access factory bound to a local — WAS
    /// charged before this commit and is not now. There is no measured instance of it recovering a real
    /// deinit anywhere in the 13-package corpus, and one measured instance of it fabricating.
    private func constructedTypeOf(_ call: FunctionCallExprSyntax) -> String? {
        let callee = call.calledExpression
        var isConstructorSpelling = false
        if let dr = callee.as(DeclReferenceExprSyntax.self) {
            let n = dr.baseName.text
            isConstructorSpelling = n.first?.isUppercase == true
                || (returns[n] != nil && localFreeFns.contains(n))
        } else if let ma = callee.as(MemberAccessExprSyntax.self) {
            if let dotted = dottedTypePath(Syntax(ma)), localTypes.contains(dealias(dotted)) {
                isConstructorSpelling = true
            } else if let mod = ma.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
                      isModuleQualifier(mod), ma.declName.baseName.text.first?.isUppercase == true {
                isConstructorSpelling = true
            }
        }
        guard isConstructorSpelling else { return nil }
        let info = rootOf(ExprSyntax(call))
        guard let t = info.root, info.isVar, t != Self.superMarker else { return nil }
        return t
    }

    /// R33's ESCAPE GATE — the load-bearing half of this fix, and the half rust's analogous `Drop`
    /// prototype was missing when it went regression-green and was REVERTED on the A/B for fabricating
    /// 14 false `Unknown`s on flate2 (`Compress::new` and friends: constructors that CONSTRUCT AND
    /// RETURN the owner, whose destructor runs in the CALLER's scope). candor-spec SOUNDNESS.md R49.
    ///
    /// A construction's value LEAVES this scope by exactly these lexical routes, checked by walking the
    /// ancestors from the construction up to (and stopping at) the unit body:
    ///
    ///   E1  inside a `return` or `throw` expression — handed to the caller.
    ///   E2  inside the initializer of a binding ANY of whose names is returned — `let h = Holder(g:
    ///       Ctor()); return h`, and the tuple-destructuring form, where any element name returning
    ///       takes the whole initializer with it.
    ///   E3  on the right of an ASSIGNMENT into something that outlives this scope: a member
    ///       (`self.f = Ctor()`, `box.f = Ctor()`), a subscript (`d[k] = Ctor()`), or a plain local
    ///       that is itself returned. An assignment to an ordinary local is NOT an escape — `var x =
    ///       A(); x = B()` releases the first value right there, and the shipped binder path already
    ///       charged it.
    ///   E4  the initializer of a STORED PROPERTY or a file-level global — the value is stored on the
    ///       instance, or lives for the process, either way not released where it is written.
    ///   E5  the sole expression of a single-expression body — Swift's implicit return, from a function
    ///       with a return clause, an accessor, or a closure.
    ///
    /// STATED LIMIT, not a closure claim, and deliberately NOT drawn around this vein's own trigger:
    /// a value handed to a callee that STORES it (`self.registry.append(Ctor())`, a completion handler
    /// that retains) is charged here, because syntax cannot see the callee's retention. That is the
    /// over-charge direction, it is the same over-approximation the SHIPPED bound-local path already
    /// made (`let x = Ctor(); self.registry.append(x)` has always been charged), and extending it
    /// rather than special-casing it is what keeps the two answers equal. It is measured, not assumed:
    /// see the corpus A/B in this commit's message.
    private func constructionEscapes(_ node: Syntax) -> Bool {
        if bodyIsStoredInitializer { return true }                                         // E4, whole-body
        var child = node
        var cursor = node.parent
        while let n = cursor {
            if n.is(ReturnStmtSyntax.self) || n.is(ThrowStmtSyntax.self) { return true }   // E1
            if let pb = n.as(PatternBindingSyntax.self) {
                if let item = pb.parent?.parent?.parent?.as(CodeBlockItemSyntax.self),      // E2
                   guaranteedToEscape(Set(Self.patternNames(pb.pattern)), after: item) { return true }
                if Self.isStoredDeclaration(pb) { return true }                            // E4
            }
            if assignmentStoresOutOfScope(n, rhs: child) { return true }                    // E3
            if Self.isImplicitReturnPosition(n, of: child) { return true }                 // E5
            if n.id == bodyRootID { break }
            child = n
            cursor = n.parent
        }
        return false
    }

    /// E2/E3's PATH-SENSITIVE replacement for whole-function name membership (`returnedNames`, below).
    ///
    /// THE VEIN, measured 2026-08-31 with ground truth EXECUTED: `returnedNames` is a SET, built once
    /// per unit by walking every `return` in the body and collecting every identifier it mentions. Set
    /// MEMBERSHIP cannot see WHICH execution path put a name there, so a name returned on ONE branch
    /// marked the binding escaping on EVERY branch — mirrors candor-rust's `7af62f1` `Drop`-glue bug,
    /// ten minutes to break: `let g = Loud(); if f { return g } else { return nil }` escapes only when
    /// `f`, and stayed silent-pure on the drop path against BOTH the pre- and post-`8a19ca3` binary (this
    /// is not a regression that commit introduced — the binder path's old `applyDeinitGlue` guard had
    /// the identical `returnedNames.contains` check, carried forward unchanged). A `switch` where only
    /// one case returns, a `throw` on the path that never reaches the qualifying `return`, and two
    /// UNRELATED same-named locals in sibling branches all reproduced it the same way.
    ///
    /// So this asks a narrower, SOUND question instead: does EVERY reachable path forward from `after`
    /// hit a `return`/`throw` that actually carries one of `names`, before any path can fall through,
    /// exit some other way, or reach a construct this scan does not model? NOT a full CFG — the STATED
    /// LIMIT is the safe one: `switch`, loops, `do`/`catch`, a name reassigned or reshadowed mid-block,
    /// and anything else unmodelled answer "not proven", which routes to CHARGE, never the reverse. The
    /// two cases this DOES resolve — `if`/`else`(`-if`) chains and `guard … else { <exit> }` — are
    /// measured to be the ones real Swift actually writes between a construction and its return; see
    /// `testBothBranchesReturningTheSameLocalStaysPure`, the over-charge control for exactly this gate.
    private func guaranteedToEscape(_ names: Set<String>, after item: CodeBlockItemSyntax) -> Bool {
        guard let list = Syntax(item).parent?.as(CodeBlockItemListSyntax.self),
              let idx = list.firstIndex(where: { $0.id == item.id }) else { return false }
        let rest = Array(list[list.index(after: idx)...])
        return Self.itemsGuaranteeEscape(rest, names: names, onFallThrough: fallsThrough(list, names: names))
    }

    /// What happens if control falls off the END of `list` with no exit inside it — climb to whatever
    /// comes after the CONSTRUCT that owns this list (an `if`/`else` body), recursively. Anything this
    /// does not recognise — the unit body root, a closure, a loop, an accessor block — ends the climb
    /// at "not proven" (`false`), which is the safe default: it can only cause MORE charging.
    private func fallsThrough(_ list: CodeBlockItemListSyntax, names: Set<String>) -> Bool {
        guard list.id != bodyRootID, let block = Syntax(list).parent?.as(CodeBlockSyntax.self),
              let owner = Syntax(block).parent else { return false }
        if let ifExpr = owner.as(IfExprSyntax.self),
           let ifItem = Syntax(ifExpr).parent?.as(CodeBlockItemSyntax.self) {
            return guaranteedToEscape(names, after: ifItem)
        }
        return false
    }

    /// The straight-line scan proper: `first` decides, `rest` is the tail, `onFallThrough` is the
    /// ALREADY-COMPUTED answer for "falls off the end with no exit" (a plain `Bool`, not a thunk — see
    /// the PERFORMANCE note below for why that distinction is load-bearing).
    ///
    /// PERFORMANCE, measured 2026-08-31: the first version of this threaded `onFallThrough` as an
    /// `@escaping () -> Bool` CLOSURE, rebuilt one layer deeper at every `if` so a branch's own
    /// fallthrough could reach the code after it. That closure is invoked from BOTH `thenEscapes` and
    /// `elseEscapes` in `ifGuaranteesEscape` below — so for a straight-line run of N sequential
    /// `if`/`else` statements (no nesting, both arms of each falling through — the shape a long chain
    /// of `if usage == "…" { … } else { … }` privacy-key checks actually has), evaluating statement K's
    /// continuation re-invokes the UNMEMOIZED closure for statement K+1 twice, which each re-invoke
    /// K+2's twice, doubling at every step: O(2^N). `PrivacyManifestCLI.swift` (1316 lines, exactly this
    /// shape) alone made `self-gate.sh` — 3s before this fix existed — run for **over 9 minutes** before
    /// being killed; `swift build`/`swift test` never exercise a self-scan and stayed fast throughout, so
    /// the whole 988-test suite was GREEN while this shipped. Found by TIMING the self-gate this file's
    /// own commit message cites as a passed gate, not by reading the recursion.
    ///
    /// The fix computes each `onFallThrough` value ONCE, eagerly, before branching, and passes the
    /// plain `Bool` down — so a nested `if`'s own continuation is computed exactly once regardless of
    /// how many arms above it would otherwise have asked for it. This is what turns the recursion back
    /// into a single linear pass over the statement list (`testPerformanceOnALongSequentialIfElseChain`
    /// pins 500 sequential `if`/`else` pairs finishing in seconds, not the un-fixed version's arbitrary
    /// blowup).
    private static func itemsGuaranteeEscape(
        _ items: [CodeBlockItemSyntax], names: Set<String>, onFallThrough: Bool
    ) -> Bool {
        guard let first = items.first else { return onFallThrough }
        let rest = Array(items.dropFirst())
        if let ret = first.item.as(ReturnStmtSyntax.self) {
            guard let expr = ret.expression else { return false }              // bare `return` — drops
            return Self.exprMentionsAnyIdentifier(Syntax(expr), names)
        }
        if first.item.is(ThrowStmtSyntax.self) { return false }                // exits without carrying
        // `if`/`switch` are EXPRESSIONS in swift-syntax's grammar (Swift 5.9+), so one used as a bare
        // statement is wrapped in `ExpressionStmtSyntax` rather than appearing directly as `.item` —
        // MEASURED by direct SwiftSyntax probe, not assumed: `item.item.as(IfExprSyntax.self)` silently
        // returns nil for every `if` at statement position, which sent EVERY `if`/`else` through the
        // unmodelled-construct bail below. That bail defaults to "not proven" (charge), which happens
        // to be the right answer for three of this file's four defect fixtures but the WRONG one for
        // the escaping-both-arms control — caught by `testBothBranchesReturningTheSameLocalStaysPure`
        // regressing to a false CHARGE the moment this fix was first tried unwrapped.
        if let ifExpr = (first.item.as(IfExprSyntax.self)
                          ?? first.item.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self)) {
            // Computed ONCE — see this function's PERFORMANCE note — then handed to BOTH arms below.
            let afterIf = itemsGuaranteeEscape(rest, names: names, onFallThrough: onFallThrough)
            return ifGuaranteesEscape(ifExpr, names: names, onFallThrough: afterIf)
        }
        if let guardStmt = first.item.as(GuardStmtSyntax.self) {
            // The `else` block MUST exit (the compiler enforces it); if it exits by returning/throwing
            // WITHOUT carrying `names`, that path drops — checked with `onFallThrough: false` because the
            // block falling through here would be uncompilable, so "not proven" is inert either way.
            let elseEscapes = itemsGuaranteeEscape(Array(guardStmt.body.statements), names: names, onFallThrough: false)
            let continueEscapes = itemsGuaranteeEscape(rest, names: names, onFallThrough: onFallThrough)
            return elseEscapes && continueEscapes
        }
        if Self.mightRebind(first, names: names) || Self.containsEarlyExit(Syntax(first.item)) {
            return false                // can no longer trust the name, or a construct we don't model
        }                                // might exit early some other way — bail to NOT PROVEN
        return itemsGuaranteeEscape(rest, names: names, onFallThrough: onFallThrough)
    }

    /// `if`/`else`/`else if` all considered — every arm the condition can take must independently
    /// guarantee escape, because at analysis time we cannot know which one runs. `onFallThrough` is the
    /// PRECOMPUTED value for "this whole `if` falls through" — see `itemsGuaranteeEscape`'s PERFORMANCE
    /// note; passing it as a value rather than a closure is what keeps an `else if` chain linear.
    private static func ifGuaranteesEscape(
        _ ifExpr: IfExprSyntax, names: Set<String>, onFallThrough: Bool
    ) -> Bool {
        let thenEscapes = itemsGuaranteeEscape(Array(ifExpr.body.statements), names: names, onFallThrough: onFallThrough)
        let elseEscapes: Bool
        if let elseIf = ifExpr.elseBody?.as(IfExprSyntax.self) {
            elseEscapes = ifGuaranteesEscape(elseIf, names: names, onFallThrough: onFallThrough)
        } else if let elseBlock = ifExpr.elseBody?.as(CodeBlockSyntax.self) {
            elseEscapes = itemsGuaranteeEscape(Array(elseBlock.statements), names: names, onFallThrough: onFallThrough)
        } else {
            elseEscapes = onFallThrough                       // no `else` — condition false skips straight past
        }
        return thenEscapes && elseEscapes
    }

    /// A statement between the binding and its return that could invalidate the name tracking: a NEW
    /// declaration shadowing one of `names`, or a plain `name = …` reassignment (the same unfolded
    /// `SequenceExprSyntax` shape `assignmentStoresOutOfScope` reads). Either means a later `return
    /// name` would return something OTHER than the construction under test — bail to NOT PROVEN rather
    /// than risk crediting an escape that belongs to a different value.
    private static func mightRebind(_ item: CodeBlockItemSyntax, names: Set<String>) -> Bool {
        if let vd = item.item.as(VariableDeclSyntax.self) {
            for b in vd.bindings where Self.patternNames(b.pattern).contains(where: names.contains) { return true }
        }
        // Confirmed by direct SwiftSyntax probe (unlike `if`): an assignment's `SequenceExprSyntax`
        // appears directly as `.item`, with no `ExpressionStmtSyntax` wrapper.
        if let seq = item.item.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            if let opIdx = elems.firstIndex(where: { $0.is(AssignmentExprSyntax.self) }), opIdx > 0,
               let dr = Self.peel(elems[0]).as(DeclReferenceExprSyntax.self), names.contains(dr.baseName.text) {
                return true
            }
        }
        return false
    }

    /// Whether `node`'s subtree contains a `return`/`throw`/`break`/`continue` this scan does not
    /// otherwise model here — an UNMODELLED early exit, not the modelled `return`/`throw`/`guard`/`if`
    /// cases above (those are peeled off before this runs). Deliberately does not descend into a
    /// nested `FunctionDeclSyntax`/`ClosureExprSyntax`: a `return` inside one exits THAT scope, not the
    /// enclosing function, and treating it as an exit here would only widen the safe (over-charge)
    /// direction for no reason.
    private static func containsEarlyExit(_ node: Syntax) -> Bool {
        if node.is(FunctionDeclSyntax.self) || node.is(ClosureExprSyntax.self) { return false }
        if node.is(ReturnStmtSyntax.self) || node.is(ThrowStmtSyntax.self)
            || node.is(BreakStmtSyntax.self) || node.is(ContinueStmtSyntax.self) { return true }
        for c in node.children(viewMode: .sourceAccurate) where containsEarlyExit(c) { return true }
        return false
    }

    /// Whether `expr` mentions any identifier in `names` — used to check a `return`'s expression
    /// against the binding names it might carry (a tuple-destructuring return element, in particular).
    private static func exprMentionsAnyIdentifier(_ expr: Syntax, _ names: Set<String>) -> Bool {
        for tok in expr.tokens(viewMode: .sourceAccurate) where tok.tokenKind.isIdentifier {
            if names.contains(tok.text) { return true }
        }
        return false
    }

    /// E4 — a binding declared in a TYPE's member block or at FILE scope, rather than in a body.
    private static func isStoredDeclaration(_ pb: PatternBindingSyntax) -> Bool {
        guard let decl = pb.parent?.parent?.as(VariableDeclSyntax.self), let owner = decl.parent else {
            return false
        }
        return owner.is(MemberBlockItemSyntax.self)
            || owner.as(CodeBlockItemSyntax.self)?.parent?.parent?.is(SourceFileSyntax.self) == true
    }

    /// E4 asked of the unit BODY rather than of an ancestor — see `bodyIsStoredInitializer`.
    private static func isStoredInitializerBody(_ body: Syntax) -> Bool {
        var cursor: Syntax? = body
        while let n = cursor {
            if let pb = n.as(PatternBindingSyntax.self) { return isStoredDeclaration(pb) }
            // Stop at anything that introduces a body of its own: past here we are no longer inside an
            // initializer EXPRESSION, and a `let x = { … }()` property would otherwise silence the
            // closure's own constructions.
            if n.is(CodeBlockSyntax.self) || n.is(ClosureExprSyntax.self) { return false }
            cursor = n.parent
        }
        return false
    }

    /// E3 — `<lhs> = <…rhs…>` where `lhs` outlives this scope. SwiftParser leaves operators unfolded,
    /// so an assignment is a `SequenceExprSyntax` whose `elements` are an `ExprListSyntax` of
    /// `[lhs, AssignmentExprSyntax, rhs…]`.
    ///
    /// Checked at the LIST, not at the SequenceExpr: the walk climbs one link at a time, so by the time
    /// `n` is the SequenceExpr the `child` it came from is the whole ExprList and matches no element.
    /// Written the other way first, this silently answered "not an assignment" for every shape it
    /// exists to catch — `b.g = Ctor()` and `d["k"] = Ctor()` were both charged, which is how it was
    /// found (the escape control was RUN, not reasoned about).
    private func assignmentStoresOutOfScope(_ n: Syntax, rhs child: Syntax) -> Bool {
        guard let list = n.as(ExprListSyntax.self), list.parent?.is(SequenceExprSyntax.self) == true
        else { return false }
        let elems = Array(list)
        guard let opIdx = elems.firstIndex(where: { $0.is(AssignmentExprSyntax.self) }),
              let childIdx = elems.firstIndex(where: { $0.id == child.id }), childIdx > opIdx,
              let lhs = elems.first else { return false }
        let target = Self.peel(lhs)
        // A member or subscript destination is reached THROUGH some other object, which outlives the
        // assignment.
        if target.is(MemberAccessExprSyntax.self) || target.is(SubscriptCallExprSyntax.self) { return true }
        guard let dr = target.as(DeclReferenceExprSyntax.self) else { return false }
        let name = dr.baseName.text
        // Path-sensitive, not whole-function membership — see `guaranteedToEscape`'s doc for the vein
        // this closes: `var x = A(); if f { x = B() } ; return x` must not read `A()`'s construction
        // (this assignment target is `x`, but the CONSTRUCTION under test at THIS call is `B()`, whose
        // own binder path already charges the reassignment normally) as escaping on a path where `x`
        // is never actually returned.
        if let seq = n.parent?.as(SequenceExprSyntax.self),
           let item = Syntax(seq).parent?.as(CodeBlockItemSyntax.self),
           guaranteedToEscape([name], after: item) { return true }
        // A BARE identifier is not necessarily a local. Inside a method — and above all inside an
        // `init` — it is very often IMPLICIT SELF, and then the assignment stores onto the instance.
        // MEASURED: Alamofire's `StreamOf.Iterator.init` writes `token = Token(onDeinit:)`, whose
        // `deinit` invokes the escaping cancellation closure when the ITERATOR dies; read as a local,
        // it charged the initializer an `Unknown` for a deinit that cannot run there. A name this body
        // actually binds wins, exactly as it does in `rootOf` — a local shadows the field.
        if isBoundLocal(name) || vars[name] != nil { return false }
        if let et = enclosingType, fields[et]?[name] != nil { return true }
        return false
    }

    /// E5 — Swift's implicit return: the sole expression of a body IS that body's result.
    ///
    /// Deliberately NOT applied to a CLOSURE body, though a closure's sole expression is equally its
    /// result. A closure returning a value says nothing about whether the value leaves the FUNCTION:
    /// `_ = xs.map { Ctor() }` builds and discards the products right here, while every route by which
    /// such an array actually escapes — `return xs.map { … }`, `self.items = xs.map { … }`, a binding
    /// that is later returned — is already E1/E2/E3. A closure arm was written first and cost exactly
    /// that under-report for nothing; the enclosing function's own implicit return still fires, because
    /// the walk carries on past the closure to it.
    ///
    /// THE VEIN, measured 2026-08-31 with ground truth EXECUTED: `if`/`switch` are EXPRESSIONS in
    /// swift-syntax's grammar whether or not they are actually USED as one — `if cond { return 1 } else
    /// { return 2 } }` parses to the identical `IfExprSyntax` shape as `if cond { 1 } else { 2 }`, so
    /// this check could not tell "the sole statement is a value this function implicitly returns" from
    /// "the sole statement is ordinary branching whose ARMS explicitly return." Both read as "one
    /// top-level item, function has a return clause" — so `func f(_ cond: Bool) -> Int { if cond { let
    /// g = Loud(…); …; return 1 } else { return 2 } }` marked the ENTIRE if/else escaping, silencing a
    /// construction that sits several statements before either arm's own `return` — proven by execution
    /// to drop in-scope, and NOT a shape `constructionEscapes`'s other checks reach: E1 never fires
    /// (the construction is not nested inside the `ReturnStmtSyntax`, a separate later statement is),
    /// E2 is correctly false (the bound name is never returned). This is a stand-alone hole, present
    /// before this file's `guaranteedToEscape` was added and unrelated to it — a single-statement
    /// `if`/`else` with an early return in it is an exceedingly common Swift shape.
    ///
    /// So this now additionally requires that `child`'s subtree contains no explicit `return`/`throw`/
    /// `break`/`continue` — the same `containsEarlyExit` used to bail `guaranteedToEscape` to NOT
    /// PROVEN. A genuine implicit-return `if`/`switch` (`if cond { Loud(a) } else { Loud(b) }`, no
    /// `return` keyword anywhere) has none, so it still fires — see
    /// `testGenuineIfExpressionImplicitReturnStaysPure`, the over-charge control for this exact carve-out.
    private static func isImplicitReturnPosition(_ n: Syntax, of child: Syntax) -> Bool {
        guard let item = n.as(CodeBlockItemSyntax.self), item.item.id == child.id,
              let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
              !Self.containsEarlyExit(child) else { return false }
        // `var x: T { Ctor() }` — the getter shorthand, whose items hang off the accessor block itself.
        if list.parent?.is(AccessorBlockSyntax.self) == true { return true }
        guard let owner = list.parent?.as(CodeBlockSyntax.self)?.parent else { return false }
        if let fd = owner.as(FunctionDeclSyntax.self) { return fd.signature.returnClause != nil }
        // An explicit `get { Ctor() }`; a `set`/`willSet`/`didSet` returns nothing, so it is not one.
        if let acc = owner.as(AccessorDeclSyntax.self) { return acc.accessorSpecifier.text == "get" }
        return false
    }

    /// R33's ONE call site. Every construction the walk reaches is asked the same two questions —
    /// what does it construct, and does the value leave — instead of the binder deciding for it.
    private func noteConstructionForDeinitGlue(_ node: FunctionCallExprSyntax) {
        guard let t = constructedTypeOf(node), !constructionEscapes(Syntax(node)) else { return }
        applyDeinitGlue(root: t)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            // `let (a, b) = (X(), Y())` — destructure: bind each name from the initializer tuple element
            if let tp = binding.pattern.as(TuplePatternSyntax.self),
               let tupleInit = binding.initializer?.value.as(TupleExprSyntax.self) {
                // …and the type indexes, with the same carve-out the identifier form gets below: the
                // element branch TYPES each name from `rootOf(ve.expression)` and left a live
                // `protoTyped` under it, so `func f(_ p: Job) { let (p, _) = (Ctx(), 1); p.run() }`
                // dispatched over `Job`'s conformers against an ABSENT rename control. `through` is the
                // WHOLE tuple initializer rather than the matching element — conservative in the safe
                // direction, and it covers the arities the zip below does not reach.
                for n in Self.patternNames(PatternSyntax(tp)) {
                    shadowName(n); rebindTyped(n, through: binding.initializer?.value)
                }
                markBinders(PatternSyntax(tp))
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
            // (R33's WILDCARD-binder call site stood here. Its comment claimed to cover `_ = Loud(path)`
            //  and described it as found-and-closed — but the code sat inside `visit(VariableDeclSyntax)`
            //  behind a `WildcardPatternSyntax` check, which is the `let _ =` spelling. A bare
            //  `_ = Loud(path)` is not a VariableDecl at all and never reached it, so the comment named
            //  a shape the code could not see and, being written down, stopped it being measured. Both
            //  spellings are now answered at the construction itself — see `applyDeinitGlue`.)
            // Claimed for the whole binding — the identifier form is typed below, and a form this
            // visitor does NOT model (`let (a, b) = pair()`, a tuple pattern with a non-tuple
            // initializer) falls out of the guard on the next line, so leaving it unclaimed lets
            // `visit(IdentifierPatternSyntax)` clear it rather than let the enclosing signature's flags
            // ride on it.
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            markBinders(binding.pattern)
            boundLocals.insert(name)  // record the SHADOW (any local, even a literal-typed one `vars` drops)
            // THE SAME ORDERING CARVE-OUT `protoTyped` needs below, for the same reason and with a
            // fixture of its own: `shadowName` runs before the initializer is walked, so a
            // SELF-REFERENTIAL rebind (`let g = g`, `let g = g()`) would drop the alias the initializer
            // is about to resolve through — and the re-aliasing branch at the bottom cannot restore it,
            // because its RHS is a shadowed local rather than a `localFreeFns` name. Captured before,
            // reinstated after, only when the initializer MENTIONS the name.
            let aliasBeforeRebind = fnValueAlias[name]
            // CONSTANT PROVENANCE rung 3 — a local bound to a home-anchored path carries it, so
            // `let docs = NSHomeDirectory() + "/Documents"; …contents(atPath: docs)` resolves.
            //
            // AFTER `shadowName`, and that ordering is the whole of it: recorded before, the rebind
            // immediately wiped it and the binding form silently stopped resolving while the inline form
            // still worked. This is the same ordering carve-out `fnValueAlias` documents six lines up,
            // hit for the same reason — the file warned about it and I still had to measure it.
            var homePathForThisBinding: String? = nil
            if let iv = binding.initializer?.value, let hp = homeAnchoredPath(iv),
               hp.hasPrefix("/Users/_") { homePathForThisBinding = hp }
            shadowName(name)          // a rebind: the signature's `some P` opacity and any earlier
                                      // dependency provenance stop applying to the NAME here. Runs
                                      // BEFORE the branches below, one of which re-inserts the
                                      // provenance for this binding's own initializer.
            if let hp = homePathForThisBinding { homeAnchoredLocals[name] = hp }
            // `protoTyped` is NOT in `shadowName`, and the reason is an ORDERING fact that cost a real
            // reach before it was understood. SwiftSyntax walks a binding's PATTERN before its
            // INITIALIZER, so anything cleared here is already gone by the time the initializer's own
            // calls are collected — and `let u = u.asURL()` (Alamofire's `URLRequest.init(url: any
            // URLConvertible …)`) resolves `u.asURL()` through exactly the entry being cleared. Putting
            // it in `shadowName` closed the loop-binder fabrication and turned that function from a
            // disclosed `Unknown` into ABSENT: the fabrication traded for its mirror, which item 1 of
            // the vein's standing bar forbids. Measured on the corpus as one loss, reduced to
            // `selfRebind` in the ordering fixture.
            //
            // So the clear lives in `clearBindingTypeOnly` — the path a binder takes when it CANNOT type
            // the new binding, which is where the fabrication actually arises (a loop/case binder) and
            // which the self-referential `let` never reaches. This line covers the remaining hole: a
            // binding that DOES type still rebinds the name, so the protocol type stops applying —
            // unless the initializer mentions the name, which is the one case where the old binding is
            // still live while the initializer is walked. A DENYLIST (clear unless proven unsafe), not
            // an allowlist of binder shapes.
            if !Self.referencesName(binding.initializer?.value, name) { protoTyped.removeValue(forKey: name) }
            else if let a = aliasBeforeRebind { fnValueAlias[name] = a }
            // CONST-STRING PROPAGATION — a LOCAL `let NAME = "literal"` string constant. Resolves a later
            // const-anchored host in the SAME fn body (`let apiBase = "…"; dataTask(with: "\(apiBase)/x")`).
            // ONLY a `let` with a PLAIN string-literal initializer and no accessor block. A `var` of the
            // same name (reassignable) is explicitly EXCLUDED — remove any stale entry so it never resolves.
            if node.bindingSpecifier.text == "let", binding.accessorBlock == nil,
               let v0 = binding.initializer?.value, let sv = plainStringLiteralValue(v0) {
                localConstStrings[name] = sv
            } else if binding.accessorBlock == nil, let v0 = binding.initializer?.value,
                      let loc = locatorCtorLiteral(v0),
                      locatorNameIsStable(name, inert: Self.LOCATOR_INERT_WRITES) {
                // LOCATOR-BINDER PROVENANCE — `let u = URL(string: "…")!`, `var req = URLRequest(url: u)`.
                // The literal travels through the SAME const-string index the direct form uses, so the host
                // refinement, the ⟨0.13⟩ `Llm` classification and the privacy manifest all follow with no
                // second resolver. Unlike a plain string const this admits `var`: `URLRequest` cannot be
                // configured without mutation, so `var req = …; req.httpMethod = "POST"` IS the idiom. The
                // `var` is safe here and not for strings because `locatorNameIsStable` has already proved —
                // over the WHOLE body, before any call was collected — that nothing reassigns the name and
                // that every property written on it is on the inert allowlist.
                localConstStrings[name] = loc
            } else {
                localConstStrings.removeValue(forKey: name)
            }
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
                else if let elem = arrayElementName(ann.type) {                            // `let xs: [T]`
                    setArrayElem(name, (elem, arrayElementType(ann.type).map(isOpaqueParam) ?? false))
                }
                else if let val = dictValueName(ann.type) { dictElem[name] = val }        // `let m: [K: V]`
                // (R33's ANNOTATED-BINDER call site stood here, and the unannotated one in the `else if`
                //  below. Both are gone: the annotation was never the question — the CONSTRUCTION is —
                //  and keeping a binder-shaped copy beside the construction hook is what let the
                //  annotated and unannotated spellings drift apart in the first place.)
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
                    else if let callee = v.as(FunctionCallExprSyntax.self)?.calledExpression
                                .as(DeclReferenceExprSyntax.self)?.baseName.text,
                            callee == "unsafeBitCast", !localFreeFns.contains(callee) {
                        // R61 — `unsafeBitCast(_, to: SomeFnType.self)` manufactures an opaque VALUE by
                        // raw bit reinterpretation, most idiomatically a function pointer resolved via
                        // `dlsym`. Left to the ordinary ctor/factory arm below, this fell into
                        // `depFactoryCallee`'s "plausible dependency factory" heuristic (`unsafeBitCast`
                        // is lowercase and not in `PURE_STDLIB_FREE_FNS`), which sets `depBoundLocals` —
                        // consulted ONLY by a later MEMBER call on the local (`fn.foo()`, line ~3151) and
                        // consulted NOT AT ALL by a direct invocation `fn()`, which is the shape this
                        // mechanism actually uses (`unsafeBitCast(sym, to: WipeFn.self); fn()`). That call
                        // then had no local-name signal to match against ANY branch at the call site and
                        // fell all the way to the plain unqualified-Call default, which the Driver's
                        // fixpoint resolves against declared free functions ONLY — never against a local
                        // variable — so it silently dropped: R61, exit 0, `deny Exec`. Route it instead
                        // through the SAME machinery a stored/computed opaque closure property already
                        // uses: `opaqueFnLocals`. A later bare `fn()` hits the existing check at the call
                        // site (`opaqueFnLocals.contains(name)`, checked before `vars`/`fnTyped`) and
                        // discloses `Unknown`/`callback:fn` — never a fabricated concrete effect, since
                        // what the cast actually produces is, by construction, unknowable here. Mutually
                        // exclusive with `vars`/`depBoundLocals` for this name: a bitcast result is not a
                        // typed value this engine can chase any further than "opaque, possibly callable".
                        opaqueFnLocals.insert(name)
                        vars.removeValue(forKey: name)
                        depBoundLocals.removeValue(forKey: name)
                    }
                    else {
                        // ctor or unambiguous factory — one resolver for both (rootOf handles peeling)
                        let info = rootOf(v)
                        // PROVENANCE WITHOUT A TYPE. `returns` holds LOCAL factory returns only, so a
                        // dependency's factory yields no root at all and the binding stays untyped —
                        // every later member call on it then falls through silently. Record it so the
                        // call site can DISCLOSE instead (half 1). Cleared on any rebind by the
                        // clearBinding path below, and never set when the call DID type.
                        //
                        // The guard that decides "plausibly a dependency factory" lives in
                        // `depFactoryCallee`, with the measurements that shaped it — it is shared with the
                        // UNBOUND spelling of the same call (`build().fetch()`), which is why it is a
                        // function and not the inline condition it used to be.
                        if info.root == nil, let callee = depFactoryCallee(v) {
                            depBoundLocals[name] = callee
                        } else { depBoundLocals.removeValue(forKey: name) }
                        if let t = info.root, info.isVar {
                            vars[name] = t
                            // (R33's third and original call site stood here. The construction hook in
                            //  `visit(FunctionCallExprSyntax)` reaches this same initializer — this
                            //  visitor returns `.visitChildren` — so the charge is unchanged and the
                            //  binder no longer has an opinion about it.)
                        }
                        // a collection TRANSFORM result keeps the element type: `let active = cs.filter {…}`
                        // (then `for c in active` resolves). Element-preserving transforms only.
                        else if let elem = elementTypeOf(v0) { setArrayElem(name, elem) }
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
                } else if let arr = v.as(ArrayExprSyntax.self) {
                    // `let arr = [NetThing3()]` — an UNTYPED array LITERAL local. Every branch above types
                    // the local from its single initializer expression; a collection literal instead needs
                    // its ELEMENT type recorded (`arrayElem`), so `for x in arr` / a conditional-conformance
                    // extension method (`arr.greetAll3()`, `extension Array where Element: Greeter3`)
                    // resolves `x`'s/the element's members — else the CALLER of such an extension method
                    // never inherited the array's element type and read silent-pure even once the extension
                    // method itself correctly dispatched (found via that exact fixture: `whereext`).
                    // Conservative: only an UNAMBIGUOUS single element type is recorded — every element
                    // must resolve, via `rootOf`, to the SAME type — an empty, mixed, or unresolvable
                    // literal is left untyped (never guessed) rather than fabricated.
                    let roots = arr.elements.map { rootOf($0.expression).root }
                    if let first = roots.first, let firstType = first, roots.allSatisfy({ $0 == first }) {
                        setArrayElem(name, (firstType, false))
                    } else {
                        clearBinding(name)
                    }
                } else if let dr = v.as(DeclReferenceExprSyntax.self),
                          localFreeFns.contains(dr.baseName.text),
                          vars[dr.baseName.text] == nil, !isBoundLocal(dr.baseName.text) {
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

private extension TokenKind {
    var isIdentifier: Bool { if case .identifier = self { return true }; return false }
}
