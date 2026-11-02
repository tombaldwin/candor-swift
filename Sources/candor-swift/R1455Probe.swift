// SOUNDNESS R1455 — PARTITION PROBE for the `droppedMember` population (the `:8735` drop in CallCollector).
//
// Measurement only; OFF unless `CANDOR_R1455_PROBE` is set, and it changes no output. One stderr line per dropped
// explicit member call:
//
//     R1455\t<unit qual>\t<unit loc>\t<member>\t<receiver shape>\t<head binding form>\t<std effect name>\t<receiver text>
//
// The BINDING FORM is the question the row needs answered ("is the receiver type derivable from what the engine
// already sees?"): it names the syntactic place the receiver's head identifier is bound — a closure parameter of
// `map`, a `for` variable, a `let` with an initializer of a given kind, a parameter, a field, or nothing in scope.
// It is syntactic and conservative; it is NOT a type oracle, and its classes are meant to be sampled and read, not
// trusted. STD-EFFECT is a NAME-ONLY upper bound: the member name carries an effect under SOME curated root.

import Foundation
import SwiftSyntax
import CandorCore

enum R1455 {
    static let probe = ProcessInfo.processInfo.environment["CANDOR_R1455_PROBE"] != nil
    private static let roots = ["FileManager", "FileHandle", "URLSession", "URL", "NSURLConnection", "File", "Folder",
        "Storage", "Process", "Logger", "OSLog", "NSPasteboard", "UIPasteboard", "UserDefaults", "Bundle", "Date",
        "ContinuousClock", "DispatchTime", "NWBrowser", "NWConnection", "NSXPCConnection", "NSManagedObjectContext",
        "NSPersistentContainer", "ClientBootstrap", "Channel", "ChannelHandlerContext", "HTTPClient", "Data", "String"]
    /// The first curated root under which `member` is an effect, or "" — a name-only upper bound.
    static func stdEffect(_ member: String) -> String {
        if FS_MEMBERS.contains(member) { return "Fs" }
        for r in roots where kappaMember(root: r, member: "__r1455_not_a_member__") == nil {   // member-gated roots only
            if let e = kappaMember(root: r, member: member) { return "\(r):\(e)" }
        }
        return ""
    }

    /// The identifier at the head of a receiver chain, if the chain starts at one.
    static func head(_ raw: ExprSyntax) -> (name: String, depth: Int)? {
        var e = raw, depth = 0
        while true {
            if let d = e.as(DeclReferenceExprSyntax.self) { return (d.baseName.text, depth) }
            if let m = e.as(MemberAccessExprSyntax.self), let b = m.base { e = b; depth += 1; continue }
            if let c = e.as(FunctionCallExprSyntax.self) { e = c.calledExpression; depth += 1; continue }
            if let s = e.as(SubscriptCallExprSyntax.self) { e = s.calledExpression; depth += 1; continue }
            if let f = e.as(ForceUnwrapExprSyntax.self) { e = f.expression; continue }
            if let o = e.as(OptionalChainingExprSyntax.self) { e = o.expression; continue }
            if let t = e.as(TryExprSyntax.self) { e = t.expression; continue }
            if let a = e.as(AwaitExprSyntax.self) { e = a.expression; continue }
            if let p = e.as(TupleExprSyntax.self), p.elements.count == 1, let f = p.elements.first { e = f.expression; continue }
            return nil
        }
    }

    static func patternNames(_ p: PatternSyntax) -> [String] {
        if let i = p.as(IdentifierPatternSyntax.self) { return [i.identifier.text] }
        if let t = p.as(TuplePatternSyntax.self) { return t.elements.flatMap { patternNames($0.pattern) } }
        if let v = p.as(ValueBindingPatternSyntax.self) { return patternNames(v.pattern) }
        if let x = p.as(ExpressionPatternSyntax.self) { return exprNames(x.expression) }
        return []
    }
    /// `case let .some(x)` / `case .a(let x, let y)` spell their binders inside an expression pattern.
    static func exprNames(_ e: ExprSyntax) -> [String] {
        var out: [String] = []
        func walk(_ n: Syntax) {
            if let v = n.as(PatternExprSyntax.self) { out.append(contentsOf: patternNames(v.pattern)) }
            if let v = n.as(ValueBindingPatternSyntax.self) { out.append(contentsOf: patternNames(v.pattern)) }
            if let d = n.as(IdentifierPatternSyntax.self) { out.append(d.identifier.text) }
            for c in n.children(viewMode: .sourceAccurate) { walk(c) }
        }
        walk(Syntax(e))
        return out
    }

    static func initKind(_ e: ExprSyntax?) -> String {
        guard let e0 = e else { return "none" }
        var e = e0
        while true {
            if let t = e.as(TryExprSyntax.self) { e = t.expression; continue }
            if let a = e.as(AwaitExprSyntax.self) { e = a.expression; continue }
            if let f = e.as(ForceUnwrapExprSyntax.self) { e = f.expression; continue }
            break
        }
        if let c = e.as(FunctionCallExprSyntax.self) {
            if let m = c.calledExpression.as(MemberAccessExprSyntax.self) { return "call.\(m.declName.baseName.text)" }
            if let d = c.calledExpression.as(DeclReferenceExprSyntax.self) {
                return d.baseName.text.first?.isUppercase == true ? "ctor" : "freecall"
            }
            return "call-other"
        }
        if let m = e.as(MemberAccessExprSyntax.self) { return m.base == nil ? "implicit-member" : "member.\(m.declName.baseName.text)" }
        if e.is(DeclReferenceExprSyntax.self) { return "name" }
        if e.is(SubscriptCallExprSyntax.self) { return "subscript" }
        if e.is(ClosureExprSyntax.self) { return "closure" }
        if e.is(AsExprSyntax.self) { return "as-cast" }
        if e.is(StringLiteralExprSyntax.self) || e.is(IntegerLiteralExprSyntax.self) || e.is(BooleanLiteralExprSyntax.self)
            || e.is(FloatLiteralExprSyntax.self) || e.is(NilLiteralExprSyntax.self) { return "literal" }
        if e.is(ArrayExprSyntax.self) || e.is(DictionaryExprSyntax.self) { return "collection-literal" }
        if e.is(SequenceExprSyntax.self) { return "sequence" }
        return "other"
    }

    /// The call a closure is an argument / trailing closure of, as its member or function name.
    static func closureOwner(_ c: ClosureExprSyntax) -> String {
        var cur: Syntax? = c.parent
        while let p = cur {
            if let call = p.as(FunctionCallExprSyntax.self) {
                if let m = call.calledExpression.as(MemberAccessExprSyntax.self) { return m.declName.baseName.text }
                if let d = call.calledExpression.as(DeclReferenceExprSyntax.self) { return d.baseName.text }
                return "?"
            }
            if p.is(CodeBlockItemSyntax.self) || p.is(MemberBlockItemSyntax.self) { return "(stored)" }
            cur = p.parent
        }
        return "?"
    }

    /// Where `name`, used at `node`, is bound. Walks outward; the first scope that binds it wins.
    static func bindingForm(_ name: String, at node: Syntax) -> String {
        if name == "self" || name == "Self" { return "self" }
        if name.hasPrefix("$"), Int(name.dropFirst()) != nil {
            var cur: Syntax? = node.parent
            while let p = cur {
                if let c = p.as(ClosureExprSyntax.self) { return "shorthand:\(closureOwner(c))" }
                cur = p.parent
            }
            return "shorthand:?"
        }
        var child: Syntax = node
        var cur: Syntax? = node.parent
        while let p = cur {
            if let c = p.as(ClosureExprSyntax.self), let sig = c.signature {
                var names: [String] = [], annotated = false
                if let params = sig.parameterClause {
                    if let s = params.as(ClosureShorthandParameterListSyntax.self) { names = s.map { $0.name.text } }
                    if let f = params.as(ClosureParameterClauseSyntax.self) {
                        names = f.parameters.map { ($0.secondName ?? $0.firstName).text }
                        annotated = f.parameters.contains { $0.type != nil }
                    }
                }
                if names.contains(name) { return "closure-param:\(closureOwner(c))\(annotated ? ":annotated" : "")" }
            }
            if let f = p.as(ForStmtSyntax.self), f.body.id == child.id, patternNames(f.pattern).contains(name) {
                return "for-in:\(initKind(f.sequence))"
            }
            if let items = p.as(CodeBlockItemListSyntax.self) {
                for it in items {
                    if it.id == child.id { break }
                    if let v = it.item.as(VariableDeclSyntax.self) {
                        for b in v.bindings where patternNames(b.pattern).contains(name) {
                            let tuple = b.pattern.is(TuplePatternSyntax.self)
                            return "local-var:\(b.typeAnnotation.map { "annotated[" + String($0.type.trimmedDescription.prefix(40)) + "]" } ?? "init=\(initKind(b.initializer?.value))")\(tuple ? ":destructured" : "")"
                        }
                    }
                    if let g = it.item.as(StmtSyntax.self)?.as(GuardStmtSyntax.self) {
                        for cnd in g.conditions {
                            if let ob = cnd.condition.as(OptionalBindingConditionSyntax.self), patternNames(ob.pattern).contains(name) {
                                return "guard-let:\(ob.typeAnnotation != nil ? "annotated" : "init=\(initKind(ob.initializer?.value))")"
                            }
                            if let mp = cnd.condition.as(MatchingPatternConditionSyntax.self), patternNames(mp.pattern).contains(name) {
                                return "guard-case:init=\(initKind(mp.initializer.value))"
                            }
                        }
                    }
                }
            }
            if let i = p.as(IfExprSyntax.self), i.body.id == child.id {
                for cnd in i.conditions {
                    if let ob = cnd.condition.as(OptionalBindingConditionSyntax.self), patternNames(ob.pattern).contains(name) {
                        return "if-let:\(ob.typeAnnotation != nil ? "annotated" : "init=\(initKind(ob.initializer?.value))")"
                    }
                    if let mp = cnd.condition.as(MatchingPatternConditionSyntax.self), patternNames(mp.pattern).contains(name) {
                        return "if-case:init=\(initKind(mp.initializer.value))"
                    }
                }
            }
            if let w = p.as(WhileStmtSyntax.self), w.body.id == child.id {
                for cnd in w.conditions {
                    if let ob = cnd.condition.as(OptionalBindingConditionSyntax.self), patternNames(ob.pattern).contains(name) {
                        return "while-let:init=\(initKind(ob.initializer?.value))"
                    }
                }
            }
            if let sc = p.as(SwitchCaseSyntax.self), let lbl = sc.label.as(SwitchCaseLabelSyntax.self),
               lbl.caseItems.contains(where: { patternNames($0.pattern).contains(name) }) {
                return "switch-case"
            }
            if p.is(CatchClauseSyntax.self) { if name == "error" { return "catch-error" } }
            if let cc = p.as(CatchClauseSyntax.self), cc.catchItems.contains(where: { $0.pattern.map { patternNames($0).contains(name) } ?? false }) {
                return "catch-pattern"
            }
            if let fn = p.as(FunctionDeclSyntax.self) {
                for prm in fn.signature.parameterClause.parameters where (prm.secondName ?? prm.firstName).text == name {
                    return "param:\(String(prm.type.trimmedDescription.prefix(40)))"
                }
            }
            if let ini = p.as(InitializerDeclSyntax.self) {
                for prm in ini.signature.parameterClause.parameters where (prm.secondName ?? prm.firstName).text == name {
                    return "param:\(String(prm.type.trimmedDescription.prefix(40)))"
                }
            }
            if let blk = p.as(MemberBlockSyntax.self) {
                for m in blk.members {
                    if let v = m.decl.as(VariableDeclSyntax.self) {
                        for b in v.bindings where patternNames(b.pattern).contains(name) {
                            return "field:\(b.typeAnnotation.map { "annotated[" + String($0.type.trimmedDescription.prefix(40)) + "]" } ?? "init=\(initKind(b.initializer?.value))")"
                        }
                    }
                }
            }
            child = p
            cur = p.parent
        }
        return "unbound"
    }

    static func line(qual: String, loc: String, member: String, shape: String, base: ExprSyntax) -> String {
        let h = head(base)
        let form = h.map { bindingForm($0.name, at: Syntax(base)) + ($0.depth > 0 ? "+chain\($0.depth)" : "") }
            ?? "no-head"
        let text = String(base.trimmedDescription.prefix(70)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        return "R1455\t\(qual)\t\(loc)\t\(member)\t\(shape)\t\(form)\t\(stdEffect(member))\t\(text)\t\(coarse(shape: shape, form: form, text: text))\n"
    }

    /// Gate for the PRICING arm: `CANDOR_R1455_HEDGE_ONLY=T4,T5,T6` makes the X-arm marker (`CANDOR_CT2_FALLBACK=X`)
    /// fire only at those classes, i.e. prices the hedge for the REMAINDER if the other classes were resolved.
    static let hedgeOnly: Set<String>? = ProcessInfo.processInfo.environment["CANDOR_R1455_HEDGE_ONLY"].map {
        Set($0.split(separator: ",").map(String.init))
    }

    /// How much the receiver's own syntax says about its type (a syntactic ladder, NOT a type oracle):
    ///  T0 the type is spelled or literal at the receiver itself   T1 head bound with an explicit type, receiver is the head
    ///  T2 head bound by a constructor/literal/cast, receiver is the head   T3 receiver is a member/call chain off a T1/T2 head
    ///  T4 head's type needs inference (closure arg, pattern binder, call/member initializer)   T5 head bound nowhere in the unit
    ///  T6 no identifier head (SwiftUI/opaque chains, closures, subscripts of expressions, ...)
    static func coarse(shape: String, form: String, text: String) -> String {
        if shape == "strlit" || shape == "collit" || shape == "genericSpecializationExpr" { return "T0" }
        if text.range(of: #"^[A-Z][A-Za-z0-9_.]*<.*>$"#, options: .regularExpression) != nil { return "T0" }
        if form == "no-head" { return "T6" }
        let chain = form.contains("+chain")
        let base = form.split(separator: "+").first.map(String.init) ?? form
        let kind = base.split(separator: ":", maxSplits: 1).first.map(String.init) ?? base
        let rest = base.contains(":") ? String(base.split(separator: ":", maxSplits: 1)[1]) : ""
        if kind == "unbound" { return chain ? "T5" : "T5" }
        func declared() -> Bool {
            if kind == "param" { return true }
            if rest.hasPrefix("annotated") || rest.contains(":annotated") { return true }
            return false
        }
        func ctorInit() -> Bool {
            let r = rest
            return r.hasPrefix("init=ctor") || r.hasPrefix("init=literal") || r.hasPrefix("init=collection-literal") || r.hasPrefix("init=as-cast")
        }
        if kind == "self" { return "T3" }
        if ["param", "local-var", "field", "guard-let", "if-let", "while-let", "closure-param"].contains(kind) {
            if declared() { return chain ? "T3" : "T1" }
            if kind != "closure-param" && ctorInit() { return chain ? "T3" : "T2" }
        }
        return "T4"
    }
}
