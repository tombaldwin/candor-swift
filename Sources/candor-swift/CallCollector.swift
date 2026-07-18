// candor-swift — Pass B (per-function call collection with light local type inference).
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation
import SwiftSyntax
import CandorCore

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Pass B — calls per function, with light local type inference
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// One argument's disposition at a call site: a closure literal (its body is already charged to
/// the passer lexically), a named reference (resolvable to a unit), or opaque.
enum ArgKind { case closure, named(String), opaque }
struct Call { var path: String; var leaf: String; var strArg: String?; var typed: Bool; var args: [ArgKind] = []
              var argTypes: [String?] = []     // inferred simple type per positional arg (nil = unknown) — overloads
              var unqualified: Bool = false    // a bare DeclReference `name(…)` (free fn / ctor / self-sibling) —
                                               // NOT a `recv.member(…)` whose receiver type couldn't be resolved
                                               // (those must never be guessed onto a same-named sibling/free fn).
              var extOwner: String? = nil }    // the RESOLVED receiver root of an otherwise-unmatched member
                                               // call (`c.fetch()` where c: RatesClient, an external type) —
                                               // carried ONLY for the §2 CANDOR_DEPS join key (`pkg#Owner.leaf`);
                                               // never consulted by local resolution, so behaviour without a
                                               // loaded dep report is unchanged.

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
    var selfElementType: String?   // self's element bound in a collection extension (R28)
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
         closureFields: [String: Set<String>], moduleConstStrings: [String: String] = [:]) {
        self.moduleConstStrings = moduleConstStrings
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
        self.selfElementType = info.selfElementType
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
        self.returnedNames = info.body.map { ReturnedNameCollector.collect(Syntax($0)) } ?? []
        super.init(viewMode: .sourceAccurate)
    }

    // Names this function RETURNS (any identifier mentioned in a `return <expr>`). A returned binding
    // ESCAPES — its deinit runs at the CALLER, not here — so R33 deinit-glue must skip it. Skipping on
    // any return-mention is the SAFE direction: a missed charge only under-reports, whereas charging the
    // pervasive `let v = View(); …; return v` factory pattern (SwiftUI `makeNSView`) would fabricate.
    private let returnedNames: Set<String>

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

    /// `privacy/1` finding 5 — the statically-visible AVFoundation media-type of a capture call. Reads the
    /// leading-dot member name of the `for:` argument on `AVCaptureDevice.default(for:)` / `.devices(for:)`
    /// (`.audio`→"audio", `.video`→"video"; also `AVMediaType.audio`/`.video` spelled in full). Returns nil
    /// when the media type is NOT statically visible — no such arg (a bare `AVCaptureSession()`), or a
    /// computed/variable value (`for: mt`) — so the caller over-discloses BOTH sensors (never under-declare).
    private func mediaTypeArg(_ args: LabeledExprListSyntax) -> String? {
        for a in args where a.label?.text == "for" || a.label == nil {
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

    // CONST-STRING PROPAGATION — the value of a KNOWN string constant named `name` (a local `let` shadows a
    // module/global of the same name), or nil if it is not a resolvable const. Conservative: only names in
    // the const-string indexes — a `var`, a runtime/computed value, an unknown name → nil (never guess).
    private func constValue(_ name: String) -> String? {
        localConstStrings[name] ?? moduleConstStrings[name]
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
    // Only the curated URL schemes are accepted (matching hostPort's scheme list) so a non-URL literal
    // prefix with an embedded `//…/` can't be misread as an authority.
    static func literalHeadAuthority(_ text: String) -> String? {
        for scheme in ["https://", "http://", "wss://", "ws://", "tcp://"] where text.hasPrefix(scheme) {
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

    private func resolveConstString(_ raw: ExprSyntax) -> String? {
        let expr = Self.peel(raw)
        // a bare const reference
        if let dr = expr.as(DeclReferenceExprSyntax.self), let v = constValue(dr.baseName.text) {
            return v
        }
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
        // Explicit receiver (`xs.forEach{…}`) OR bare/implicit-self (`forEach{…}` inside a Collection ext).
        let iteratorMethod: String? = (node.calledExpression.as(MemberAccessExprSyntax.self))?.declName.baseName.text
            ?? node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
        let pairIterator = iteratorMethod.map(Self.ELEMENT_PAIR_ITERATORS.contains) ?? false
        let iteratorElem: String? = {
            if let ma = node.calledExpression.as(MemberAccessExprSyntax.self),
               Self.ELEMENT_ITERATORS.contains(ma.declName.baseName.text) || pairIterator,
               let base = ma.base {
                return elementTypeOf(base)
            }
            // BARE element-iterator over implicit `self` — `forEach { $0.persist() }` inside
            // `extension Array where Element: Saveable`: self's element is that bound (R28).
            if let dr = node.calledExpression.as(DeclReferenceExprSyntax.self),
               Self.ELEMENT_ITERATORS.contains(dr.baseName.text) || pairIterator {
                return selfElementType
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
                // reported Net, a network read reported Fs (a fabrication — the precision failure; caught fabricating Net
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
                // R35 — a `@dynamicCallable` type: `c(1, 2)` desugars to `c.dynamicallyCall(withArguments:)`
                // (or `withKeywordArguments:`), whose effectful body read silent-pure since the desugar was
                // invisible. Edge to the `dynamicallyCall` witness (soft edge — resolveQual drops it when the
                // type isn't @dynamicCallable / declares no such method, so an ordinary local-type value that
                // is not actually callable adds nothing).
                propertyEdges.insert("\(t).dynamicallyCall")
            } else if let et = enclosingType, !boundLocals.contains(name), !localFreeFns.contains(name),
                      !declaredTypes.contains(et), let eff = kappaMember(root: et, member: name) {
                // an IMPLICIT-self member call inside an `extension <κ-platform-type>`: `launch()` inside
                // `extension Process` is `self.launch()` → Exec (the ShellOut `launchBash` cardinal-sin: it
                // read silent-pure). Mirrors the explicit-self path (line ~1417). Only fires when the
                // enclosing type is NOT declared locally (an extension of the real platform type) and the κ
                // table knows the member — a declared type shadows κ, a local free fn / shadowing local wins.
                let est = isEstablishingMember(effect: eff, root: et, member: name)
                directEffects.insert(eff)
                if eff == "Llm" { directEffects.insert("Net") } // §1 ⟨0.13⟩ a model-SDK call IS network I/O
                recordSurfaces(effect: eff, lit: lit, args: node.arguments, netEstablishing: est)
                if lit == nil, est { incompleteSurfaces.insert(eff) }
            } else if !localTypes.contains(name), !localFreeFns.contains(name),
                      PRIVACY_CAPTURE_TYPES.contains(dealias(name)) {
                // `privacy/1` finding 5 — an AVFoundation capture-type CONSTRUCTOR (`AVCaptureSession()`).
                // A ctor carries no media-type arg → the capture is ambiguous → over-disclose BOTH Camera
                // AND Mic (privacy: never under-declare a real sensor). A local type of the same name
                // already short-circuited above (declaredTypes/localTypes), so this never fabricates on
                // project code. Supersedes the flat Camera in kappaFree for these types.
                for e in privacyCaptureEffects(mediaType: mediaTypeArg(node.arguments)) { directEffects.insert(e) }
            } else if !localTypes.contains(name), !localFreeFns.contains(name),
                      let eff = kappaFree(name: dealias(name), argCount: node.arguments.count) {
                // A LOCALLY-declared type ctor (`Pipe()` where `class Pipe`) or free fn (`NSLog(...)` where
                // `func NSLog`) ALWAYS shadows the platform free-call table — else a project's own
                // `Pipe`/`NSDate`/`NSLog`/`CACurrentMediaTime` fabricates Ipc/Clock/Log (the precision failure;
                // the same shadow discipline the member-call path applies via `localTypes`). When shadowed
                // it falls through to the unqualified Call below, which resolves to the local def.
                // `dealias(name)` resolves a typealias-named ctor (`Proc()`→`Process`→Exec) before κ; a
                // local type/free fn already short-circuited above, so an alias never overrides the project.
                let aliasName = dealias(name)
                let est = isEstablishingFree(effect: eff, name: aliasName)
                directEffects.insert(eff)
                if eff == "Llm" { directEffects.insert("Net") } // §1 ⟨0.13⟩ a model-SDK ctor/call IS network I/O
                recordSurfaces(effect: eff, lit: lit, args: node.arguments, netEstablishing: est)
                if lit == nil, est { incompleteSurfaces.insert(eff) }
            } else {
                // R32 (swift) — an UNQUALIFIED requirement call inside a PROTOCOL EXTENSION (or protocol
                // default body): `self` is `Self: P`, so a bare `req()` may dispatch to each conformer's
                // WITNESS, whose override candor never reached (silent-pure — the protocol-witness sibling
                // of the concrete-receiver default dispatch). Record a protoDispatch; the Driver's bounded
                // CHA resolves it ONLY when `name` is a real requirement of P (`protocolMethods` guard), so
                // a bare free-fn/sibling call is filtered there and resolved by the plain Call below instead.
                if let et = enclosingType, localProtocols.contains(et) {
                    protoDispatches.append((et, name))
                }
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
            } else if let baseDR = ma.base?.as(DeclReferenceExprSyntax.self),
                      arrayElem[baseDR.baseName.text] != nil, localTypes.contains("Array") {
                // an ARRAY receiver (`xs: [Item]`) calling a method a local `extension Array` provides —
                // conditional conformance: `xs.persist()` → `Array.persist` (R28). Uses `propertyEdges` (a
                // resolveQual soft edge) NOT a typed call, so a STD array method (`xs.forEach`, no
                // `Array.forEach` unit) drops SILENTLY — no spurious Unknown, no fabrication.
                propertyEdges.insert("Array.\(member)")
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
            } else if let rt = base.root, PRIVACY_CAPTURE_TYPES.contains(rt), !declaredTypes.contains(rt) {
                // `privacy/1` finding 5 — an AVFoundation CAPTURE call (`AVCaptureDevice.default(for: .audio)`,
                // `.devices(for: .video)`, a bare `AVCaptureSession.startRunning()`): refine the Camera/Mic
                // split by the media-type argument the syntactic engine CAN see. A statically-visible
                // `.audio`→Mic / `.video`→Camera; an ambiguous capture (no visible media-type arg — a bare
                // AVCaptureSession, or a computed `for:` value) over-discloses BOTH (privacy: never
                // under-declare a real sensor). Confirmed-capture-type only, so an unknown receiver still
                // never fabricates. Supersedes the flat Camera in PRIVACY_SDK_TYPES for these types.
                for e in privacyCaptureEffects(mediaType: mediaTypeArg(node.arguments)) { directEffects.insert(e) }
            } else if let rt = base.root, let eff = kappaMember(root: rt, member: member) {
                directEffects.insert(eff)
                if eff == "Llm" { directEffects.insert("Net") } // §1 ⟨0.13⟩ a model-SDK call IS network I/O
                // A two-path Fs op (copyItem/moveItem/createSymbolicLink/…) carries a SOURCE *and* a
                // DESTINATION locator; the single-`lit` guard below captures only the first, so a literal
                // source would MASK a runtime destination (the two-path gate-evasion). Inspect EVERY
                // locator: capture all literals, mark Fs incomplete if any locator is non-literal.
                if eff == "Fs", rt == "FileManager", recordTwoPathFs(member: member, node.arguments) {
                    // handled — surfaces + incompleteness recorded per-locator
                } else {
                    let est = isEstablishingMember(effect: eff, root: rt, member: member)
                    recordSurfaces(effect: eff, lit: lit, args: node.arguments, netEstablishing: est)
                    if lit == nil, est { incompleteSurfaces.insert(eff) }
                }
            } else {
                // `extOwner` carries the CONFIDENTLY-resolved receiver root (a typed value chain, or a
                // bare capitalized type reference — a static call `RatesClient.fetch()`) for the §2
                // CANDOR_DEPS join. An unresolved lowercase receiver (`base.isVar == false` on a plain
                // identifier that is just the receiver's own name) could only ever join by accident —
                // dep quals lead with a type name — but keep the owner honest: only a tracked value
                // (isVar) or a type-looking root qualifies.
                let owner = base.root.flatMap { r in (base.isVar || r.first?.isUppercase == true) ? r : nil }
                calls.append(Call(path: member, leaf: member, strArg: lit, typed: false, args: argKinds(node), argTypes: argTypesOf(node), extOwner: owner))
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
                        protoDispatches.append((proto, opName))
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
            // CONST-STRING PROPAGATION — a LOCAL `let NAME = "literal"` string constant. Resolves a later
            // const-anchored host in the SAME fn body (`let apiBase = "…"; dataTask(with: "\(apiBase)/x")`).
            // ONLY a `let` with a PLAIN string-literal initializer and no accessor block. A `var` of the
            // same name (reassignable) is explicitly EXCLUDED — remove any stale entry so it never resolves.
            if node.bindingSpecifier.text == "let", binding.accessorBlock == nil,
               let v0 = binding.initializer?.value, let sv = plainStringLiteralValue(v0) {
                localConstStrings[name] = sv
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
                        if let t = info.root, info.isVar {
                            vars[name] = t
                            // R33 — deinit-glue: a `let`/`var` LOCAL bound to a fresh CONSTRUCTION (this
                            // ctor/factory-CALL branch, never a bare-identifier ALIAS) of a type with an
                            // effectful `deinit` runs that deinit at scope exit — deterministic under ARC for
                            // a non-escaping local, but silent-pure because the deinit unit has no syntactic
                            // caller (mirrors rust Drop-glue). Edge to `<t>.deinit`; resolveQual DROPS it when
                            // the type has no deinit unit (pure/none → nothing), so this self-filters with no
                            // deinitType threading. An escaping value — `return Type()` (no binding),
                            // `self.f = Type()` (assignment), `let r = other` (alias, not this branch) — is
                            // never charged, so a factory that RETURNS its product stays pure (no over-charge).
                            if localTypes.contains(t), !returnedNames.contains(name) {
                                // A `propertyEdges` SOFT edge, NOT a typed Call: it resolves via resolveQual
                                // and DROPS SILENTLY when the type has no deinit unit (a struct/pure class →
                                // nothing), never reaching the external-protocol member-dispatch fallback that
                                // would fabricate Unknown for any type conforming to a non-pure external
                                // protocol (the ActivityAttributes over-charge). A real class deinit resolves;
                                // an inherited deinit chains via the supertype resolution there.
                                propertyEdges.insert("\(t).deinit")
                            }
                        }
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

/// Collects every identifier mentioned in a `return <expr>` within a function body — the escape signal
/// R33 deinit-glue uses to avoid charging a returned (escaping) local. Descends into the return
/// expression only; a `return v as View` / `return v!` / `return f(v)` all mark `v` as escaping.
private final class ReturnedNameCollector: SyntaxVisitor {
    private var names: Set<String> = []
    static func collect(_ node: Syntax) -> Set<String> {
        let c = ReturnedNameCollector(viewMode: .sourceAccurate)
        c.walk(node)
        return c.names
    }
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if let expr = node.expression {
            for ref in expr.tokens(viewMode: .sourceAccurate) where ref.tokenKind.isIdentifier {
                names.insert(ref.text)
            }
        }
        return .visitChildren
    }
}

private extension TokenKind {
    var isIdentifier: Bool { if case .identifier = self { return true }; return false }
}
