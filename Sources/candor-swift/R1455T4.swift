// SOUNDNESS R1455 (class T4, the closure-parameter sub-tiers) — A CLOSURE PARAMETER TYPED BY ITS CALLEE'S DECLARATION.
//
// `printer.withIndentation { p in p.print(…) }`, `RawSyntax.makeLayout(…) { layout in layout.initializeElement(…) }`,
// `Observable.create { observer in observer.on(.next(x)) }`: the closure's parameter has no annotation, so before this
// every member call on it was R1455's `droppedMember` — no edge and no `Unknown` — and where the member performs an
// effect the caller read silent. Swift types that parameter from the CALLEE's declared function type, which this scan
// parses whenever the callee is declared in it. This index holds, per callee leaf, each declaration's function-typed
// parameters and the type each of their own parameters is written as, so the call site can give the closure parameter
// exactly the binding its annotated twin `{ (p: CodePrinter) in … }` gets — no new resolution rule, the annotated arm's.
//
// WHAT MAKES IT SOUND, and every refusal below exists for a measured or constructed wrong-type case:
//  - the callee's owner is ESTABLISHED (a receiver `rootOf` types without an unexplained hop, a type reference, a
//    constructor, implicit `self`) and is a type this scan declares — never a guess, never a leaf-name union;
//  - EVERY declaration that could be the callee (the owner's own and its supertypes', every overload whose labels fit
//    the call) must agree on the closure parameter's type; a declaration that cannot be read refuses the whole site;
//  - the written type must name a CONCRETE type: not a generic parameter of the function or of any enclosing type, not
//    an associated type, not `Self`, not a member typealias of the declaring type (which names something else in the
//    caller's scope);
//  - an owner with a supertype this scan does not declare (beyond the marker protocols) refuses: a foreign extension
//    can supply an overload this scan cannot see.
// A refusal leaves the parameter exactly as before (cleared), i.e. the release's behaviour.

import Foundation
import SwiftSyntax
import CandorCore

/// One declaration's facts for the closure-parameter question.
struct ClosureSigT4 {
    let owner: String?                 // the enclosing type's simple name; nil for a free function
    let labels: [String]               // external labels per position (`_` = none)
    let sig: [(type: String?, hasDefault: Bool, variadic: Bool)]
    /// position -> the closure's parameter spellings, one per closure parameter (nil = that one cannot be typed)
    let fnParams: [Int: [String?]]
    /// positions whose written type could accept a closure but cannot be read (a generic parameter, `Any`, an alias)
    let opaquePositions: Set<Int>
    let unreadable: Bool               // an accessor / something this index cannot speak for: refuse when it is a candidate
}

struct ClosureSigIndexT4 {
    var byLeaf: [String: [ClosureSigT4]] = [:]
    var fieldOwnersByLeaf: [String: Set<String>] = [:]
    var isEmpty: Bool { byLeaf.isEmpty }

    static let off = Env.on("CANDOR_R1455T4_OFF")

    /// The well-known associated-type / generic-parameter spellings of the standard library's protocols and types. A
    /// declaration on a type this scan declares may still write one of them when it is a conformer's witness
    /// (`func next() -> Element?` inside a `Sequence` conformer's iterator), and a same-named local type would then be
    /// the wrong answer.
    static let stdAssocNames: Set<String> = ["Element", "Index", "Iterator", "SubSequence", "Indices", "Key", "Value",
        "Failure", "Output", "Input", "Body", "ID", "RawValue", "Stride", "Magnitude", "Words", "Base", "Wrapped",
        "Success", "ChildTaskResult", "Result", "Content", "Label", "Configuration", "AsyncIterator", "Bound", "Pointee",
        "Scalar", "Self"]

    /// The written name resolved in the DECLARING scope, outward as Swift's lookup runs: `Ctx` inside `Outer` is
    /// `Outer.Ctx` when that is declared. nil when the name resolves to no declared path, or when it resolves to a
    /// top-level type whose simple name another declared type path also ends in (the engine's simple-name keys would
    /// not keep the two apart).
    static func resolveInScope(_ written: String, scope: String?, _ paths: Set<String>) -> (path: String?, ambiguous: Bool) {
        var segs = scope.map { $0.split(separator: ".").map(String.init) } ?? []
        while !segs.isEmpty {
            let cand = segs.joined(separator: ".") + "." + written
            if paths.contains(cand) { return (cand, false) }
            segs.removeLast()
        }
        guard paths.contains(written) else { return (nil, false) }
        let simple = written.split(separator: ".").last.map(String.init) ?? written
        let others = paths.contains { $0 != written && $0.hasSuffix("." + simple) }
        return (written, others)
    }

    static func build(_ allFns: [FnInfo], localTypes: Set<String>, localProtocols: Set<String>,
                      typeGenerics: [String: Set<String>], nonTypeNames: Set<String>,
                      memberTypeAliases: [String: [String: String]], fnTypeAliases: Set<String>,
                      typeAliases: [String: String], localTypePaths: Set<String>,
                      fields: [String: [String: (name: String?, isFunction: Bool)]]) -> ClosureSigIndexT4 {
        var idx = ClosureSigIndexT4()
        guard !off else { return idx }
        for (owner, fs) in fields { for (leaf, _) in fs { idx.fieldOwnersByLeaf[leaf, default: []].insert(owner) } }
        // A default-argument expression is collected as an accessor unit under its FUNCTION's qual; it is not a
        // separate declaration of that leaf.
        // A qual may carry an overload signature (`T.m(A.B,Int)`) or an ordinal (`#1`); the declared NAME is before both.
        func baseQual(_ q: String) -> String {
            String(q.prefix { $0 != "(" && $0 != "#" })
        }
        let fnQuals = Set(allFns.lazy.filter { !$0.isAccessor }.map { baseQual($0.qual) })
        for f in allFns {
            if f.isAccessor, fnQuals.contains(baseQual(f.qual)) { continue }
            guard let leaf = baseQual(f.qual).split(separator: ".").last.map(String.init), !leaf.isEmpty, !f.isMain else { continue }
            let owner = f.enclosingType
            if f.isAccessor {
                if CallCollector.t4Debug { FileHandle.standardError.write("T4SIG\t\(f.qual)\taccessor\n".data(using: .utf8)!) }
                idx.byLeaf[leaf, default: []].append(ClosureSigT4(owner: owner, labels: [], sig: [], fnParams: [:],
                                                                  opaquePositions: [], unreadable: true))
                continue
            }
            var generics = f.genericParamNames.union(nonTypeNames).union(stdAssocNames)
            for seg in (f.enclosingTypePath ?? f.enclosingType ?? "").split(separator: ".") {
                generics.formUnion(typeGenerics[String(seg)] ?? [])
            }
            let ownerAliases = owner.flatMap { memberTypeAliases[$0] } ?? [:]
            var byIndex: [Int: TypeSyntax] = [:]
            for (n, i) in f.paramIndex { if let t = f.paramDeclTypes[n] { byIndex[i] = t } }
            var fnParams: [Int: [String?]] = [:], opaque = Set<Int>()
            var unreadable = byIndex.count != f.paramLabels.count || f.paramSig.count != f.paramLabels.count
            for i in 0..<f.paramLabels.count {
                guard let t = byIndex[i] else { unreadable = true; continue }
                switch functionTypeParams(t) {
                case .function(let ps):
                    fnParams[i] = ps.map { p in
                        guard let s = elementSpelling(p), s != FUNCTION_TYPE_ELEMENT else { return nil }
                        let head = String(s.split(separator: ".").first ?? "")
                        if generics.contains(head) || ownerAliases[head] != nil { return nil }
                        if fnTypeAliases.contains(head) { return nil }
                        // A concrete type this scan declares (or a module-level alias of one, which `rootOf`
                        // dealiases exactly as it does the annotated twin), or a curated platform nominal.
                        // Anything else (a dependency's type, an unknown spelling) is left to the release's reading.
                        // The declaring scope decides what a LOCAL name means (`Ctx` inside `Outer` is `Outer.Ctx`).
                        let r = resolveInScope(s, scope: f.enclosingTypePath ?? f.enclosingType, localTypePaths)
                        if let path = r.path { return r.ambiguous ? nil : path }
                        if localTypePaths.contains(where: { $0.hasSuffix("." + s) }) { return nil }
                        let named = typeAliases[head].map { String($0.split(separator: "<").first ?? "") } ?? head
                        guard localTypes.contains(named) || localProtocols.contains(named)
                              || STDLIB_NOMINALS.contains(named) || PLATFORM_VALUE_TYPES.contains(named) else { return nil }
                        return s
                    }
                case .notFunction(let name):
                    // A position that cannot take a closure ONLY when its type is a known concrete non-function
                    // nominal; a generic parameter, `Any`, an alias or an unknown spelling might.
                    if let n = name, !generics.contains(n), !fnTypeAliases.contains(n), typeAliases[n] == nil,
                       ownerAliases[n] == nil,
                       localTypes.contains(n) || STDLIB_NOMINALS.contains(n) || PLATFORM_VALUE_TYPES.contains(n) {
                        continue
                    }
                    opaque.insert(i)
                }
            }
            if CallCollector.t4Debug {
                FileHandle.standardError.write("T4SIG\t\(f.qual)\tunreadable=\(unreadable) labels=\(f.paramLabels) idx=\(byIndex.count) sig=\(f.paramSig.count) fn=\(fnParams) opaque=\(opaque)\n".data(using: .utf8)!)
            }
            idx.byLeaf[leaf, default: []].append(ClosureSigT4(owner: owner, labels: f.paramLabels, sig: f.paramSig,
                                                              fnParams: fnParams, opaquePositions: opaque,
                                                              unreadable: unreadable))
        }
        return idx
    }

    enum FnShape { case function([TypeSyntax]); case notFunction(String?) }

    /// The parameter types of a written function type, peeling `@escaping`/`@Sendable`, `inout`, an Optional and a
    /// one-element tuple (`((A) -> B)?`). Anything else is not a function type.
    static func functionTypeParams(_ raw: TypeSyntax) -> FnShape {
        var t = desugaredType(raw)
        while true {
            if let a = t.as(AttributedTypeSyntax.self) { t = a.baseType; continue }
            if let o = t.as(OptionalTypeSyntax.self) { t = o.wrappedType; continue }
            if let o = t.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { t = o.wrappedType; continue }
            if let tu = t.as(TupleTypeSyntax.self), tu.elements.count == 1, let only = tu.elements.first,
               only.firstName == nil { t = only.type; continue }
            break
        }
        if let ft = t.as(FunctionTypeSyntax.self) { return .function(ft.parameters.map { $0.type }) }
        return .notFunction(t.as(IdentifierTypeSyntax.self)?.name.text)
    }

}
