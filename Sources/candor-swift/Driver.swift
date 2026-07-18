// candor-swift — the two-pass drive: collect declarations, collect calls, resolve, fixpoint.
// Split out of main.swift (structural refactor, byte-identical output); see main.swift's header
// for the engine architecture overview.

import Foundation
import SwiftParser
import SwiftSyntax
import CandorCore

/// Everything the report/ledger/gate stages need from the analysis — returned as one value so the
/// two-pass drive is a callable unit (it was ~500 lines of top-level statements in main.swift).
struct Analysis {
    var allFns: [FnInfo]
    var conformers: [String: [String]]
    var importCounts: [String: Int]
    var internalModules: Set<String>
    var direct: [String: Set<String>]
    var edges: [String: Set<String>]
    var whyMap: [String: Set<String>]
    var locOf: [String: String]
    var entryPoints: Set<String>
    var inferred: [String: Set<String>]
    var hostsAcc: [String: Set<String>]
    var cmdsAcc: [String: Set<String>]
    var pathsAcc: [String: Set<String>]
    var tablesAcc: [String: Set<String>]
    var incompleteAcc: [String: Set<String>]
    var invisibleAcc: [String: Set<String>]
    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): the TARGET's own .swift source candor could NOT read/parse —
    // a file whose `String(contentsOfFile:)` returned nil (unreadable: EACCES, invalid UTF-8, gone).
    // (SwiftSyntax's Parser.parse is error-TOLERANT — always returns a tree, never throws — so the
    // practical swift "unanalyzed" case is an unreadable file, not a parse failure.) Its effects are
    // absent NOT because pure but because never seen; carried into the report + gate verdict so a gate
    // over skipped source fails closed, never green. (path, reason), in discovery order.
    var unanalyzed: [(path: String, reason: String)]
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Drive the two passes
// ════════════════════════════════════════════════════════════════════════════════════════════════

func analyze(sourcePaths: [String], rootDir: String, pkgName: String, deps: DepIndex = DepIndex()) -> Analysis {
    let fm = FileManager.default

    var allFns: [FnInfo] = []
    var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:]
    var fieldArrayElem: [String: [String: String]] = [:]
    var fieldDictValue: [String: [String: String]] = [:]
    var caseAssocAll: [String: Set<String>] = [:]
    var staticFactoryFields: [(type: String, field: String, leaf: String)] = []
    var protocolMethods: [String: Set<String>] = [:]
    var protocolSupers: [String: Set<String>] = [:]
    var conformers: [String: [String]] = [:]
    var localTypes: Set<String> = []
    var declaredTypes: Set<String> = []
    var typeAliases: [String: String] = [:]
    var dynamicMemberTypes: Set<String> = []
    var propertyWrapperTypes: Set<String> = []
    var resultBuilderTypes: Set<String> = []
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
    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): a file that fails to read used to be SILENTLY skipped by the
    // `guard…else { continue }` — a green report would then hide the code candor never saw. Track it.
    var unanalyzed: [(path: String, reason: String)] = []
    for p in sourcePaths {
        guard let src = try? String(contentsOfFile: p, encoding: .utf8) else {
            unanalyzed.append((path: p, reason: "source failed to read"))
            continue
        }
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
    // CONST-STRING PROPAGATION — module/global + static string constants, aggregated across files. Same
    // ambiguity rule: a name bound to ≥2 DIFFERENT literals (here, across files) → nil (never resolved).
    var constStrings: [String: String?] = [:]
    for c in collectors {
        opaqueSeqLeaves.formUnion(c.opaqueSeqLeaves)
        for (k, v) in c.seqConcreteRetTmp {
            if let existing = seqConcreteTmp[k] {
                if existing != v { seqConcreteTmp[k] = String?.none }   // ambiguous across files — never guess
            } else { seqConcreteTmp[k] = v }
        }
        for (t, ps) in c.closureFields { closureFields[t, default: []].formUnion(ps) }
        for (k, v) in c.constStrings {
            if let existing = constStrings[k] {
                if existing != v { constStrings[k] = String?.none }   // ambiguous across files — never guess
            } else { constStrings[k] = v }
        }
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
        for (pn, ss) in c.protocolSupers { protocolSupers[pn, default: []].formUnion(ss) }
        for (pn, ts) in c.conformers { conformers[pn, default: []].append(contentsOf: ts) }
        localTypes.formUnion(c.localTypes)
        declaredTypes.formUnion(c.declaredTypes)
        for (a, u) in c.typeAliases { typeAliases[a] = u }   // last-writer-wins (a redeclared alias is rare)
        dynamicMemberTypes.formUnion(c.dynamicMemberTypes)
        propertyWrapperTypes.formUnion(c.propertyWrapperTypes)
        resultBuilderTypes.formUnion(c.resultBuilderTypes)
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
    // `<main>` top-level units are excluded from overload suffixing (like accessors): the wire name MUST
    // stay exactly `<main>` (never `<main>()`), and a multi-file package's per-file top levels union under
    // the one `<main>` module-entry unit rather than becoming spurious overloads.
    for f in allFns where !f.isAccessor && !f.isTopLevel { qualGroup[f.qual, default: 0] += 1 }
    let overloadedQuals = Set(qualGroup.filter { $0.value > 1 }.keys)
    var overloads: [String: [(qual: String, sig: [(type: String?, hasDefault: Bool, variadic: Bool)])]] = [:]
    var overloadedBases = Set<String>()
    if !overloadedQuals.isEmpty {
        var seen: [String: Int] = [:]   // identical type-sigs get a positional suffix so they stay distinct nodes
        for i in allFns.indices where !allFns[i].isAccessor && !allFns[i].isTopLevel && overloadedQuals.contains(allFns[i].qual) {
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
        // `<main>` is not a callable free function (no Swift call site names it) — keep it out of the
        // free-fn index so it neither resolves phantom `<main>()` calls nor makes any name ambiguous.
        if f.enclosingType == nil && !f.isAccessor && !f.isTopLevel { freeFnByName[f.qual, default: []].append(f.qual) }
        if f.isAccessor && f.enclosingType == nil && !f.qual.contains(".") { globalUnitNames.insert(f.qual) }
    }
    // Resolve a simple "Type.member" call target to a full nested qual: an exact full-qual hit (top-level,
    // already full), else the unique simple→full mapping, else nil (ambiguous/unknown → drop the edge).
    // A closure (not a global func) so it captures the function-local indexes built just above.
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
    // not a platform-frontier module, not a κ tier, not an internal target — effects through them are
    // INVISIBLE. A module a chained sibling report COVERS is exempt (SPEC §2 rule 3): the report — even an
    // EMPTY one — is the producer's claim over that package, so a joined-nothing call into it reads pure,
    // not blind.
    let blindModules = Set(importCounts.keys.filter {
        !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0) && !internalModules.contains($0)
            && !deps.coveredPkgs.contains($0) })
    var locOf: [String: String] = [:]
    var entryPoints: Set<String> = []
    var callsiteArgs: [String: [[ArgKind]]] = [:]   // resolved target -> each call site's arg kinds
    var deferredCallbacks: [String: (indexes: Set<Int>, names: Set<String>)] = [:]

    let localProtocolNames = Set(protocolMethods.keys)  // loop-invariant: build once, not per fn
    // Does protocol `p` declare `member` DIRECTLY, or INHERIT it from a (transitive) super-protocol
    // (`protocol Sub: Sup` → `protocolSupers[Sub] = {Sup}`)? A super-protocol method IS callable on a
    // `Sub`-bound / `any Sub` receiver, and the sub's own concrete conformers (which provide the inherited
    // witness — `Impl.base`) resolve it via the `conformers[Sub]` CHA below. Walked transitively with a
    // visited-set (a cyclic/deep hierarchy terminates); only genuine super-PROTOCOLs are in the map, so no
    // unrelated type hijacks a Sub receiver. Without this `s.base()` (base ∈ Sup, `s: any Sub`) read
    // silent-pure — the dispatch gate checked `protocolMethods[Sub]` alone.
    func protoOrSuperDeclares(_ p: String, _ member: String) -> Bool {
        var seen = Set<String>(), frontier = [p]
        while let cur = frontier.popLast() {
            if !seen.insert(cur).inserted { continue }
            if protocolMethods[cur]?.contains(member) == true { return true }
            frontier.append(contentsOf: protocolSupers[cur] ?? [])
        }
        return false
    }
    // Collapse the const-string index: drop ambiguous (nil) names, keep only the unambiguous NAME→literal.
    var globalConstStrings: [String: String] = [:]
    for (k, v) in constStrings { if let v { globalConstStrings[k] = v } }
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
                               closureFields: closureFields, moduleConstStrings: globalConstStrings)
        cc.walk(body)
        // accessor units: a property READ/WRITE of a known accessor unit is an edge (the reader inherits
        // the getter/observer/subscript's effects — `c.data` reaching the Fs inside `var data: Data { … }`).
        // resolveQual matches the OWN type's `Type.member` unit; when the accessor is INHERITED (the body
        // lives on a superclass or conformed protocol — `d.payload` where `payload`'s getter is on `Base`)
        // the own-type key misses. Climb `supertypesOf` exactly as the method-call path does (an inherited
        // METHOD already resolves this way) — else an effectful inherited accessor reads SILENT-PURE (the
        // swift inherited-property-accessor vein: methods climbed, property/observer/subscript units did not).
        // Only when the own key doesn't resolve — an override on the subclass wins (its unit resolves first),
        // so we never fabricate over a real overriding accessor; a member no supertype defines edges nothing.
        for pe in cc.propertyEdges {
            if let t = resolveQual(pe) {
                edges[f.qual, default: []].insert(t)
            } else if let dot = pe.lastIndex(of: "."), localTypes.contains(String(pe[..<dot])) {
                let type = String(pe[..<dot]), member = String(pe[pe.index(after: dot)...])
                for sup in supertypesOf[type] ?? [] {
                    if let t = resolveQual("\(sup).\(member)") { edges[f.qual, default: []].insert(t) }
                }
            }
        }
        // @resultBuilder: a func annotated `@SomeBuilder` (where SomeBuilder is a local `@resultBuilder`
        // type) has its body transformed into `SomeBuilder.build*(…)` calls that RUN when the func is
        // called — edge to the builder's build-method units so an effectful builder isn't silently pure
        // (R29). resolveQual drops the build methods the builder doesn't define; a pure builder's methods
        // contribute nothing (no flood, no fabrication).
        for attr in f.uppercaseAttrs where resultBuilderTypes.contains(attr) {
            for m in ["buildBlock", "buildExpression", "buildOptional", "buildEither", "buildArray",
                      "buildFinalResult", "buildPartialBlock", "buildLimitedAvailability"] {
                if let t = resolveQual("\(attr).\(m)") { edges[f.qual, default: []].insert(t) }
            }
        }
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
            // CANDOR_DEPS cross-package JOIN (SPEC §2), GATED: an unclassified call that resolved to NO
            // local unit, in a file that IMPORTS a package a sibling report covers, inherits the dep fn's
            // recorded effects + literal surfaces. Key shapes (§2 rule 1 — the way THIS engine names the
            // call): a bare free call `hit()` → `M#hit`; a bare ctor `Rates()` → `M#Rates.init`; a member
            // call on a resolved external owner `c.fetch()` / static `RatesClient.fetch()` → `M#Owner.leaf`;
            // a module-qualified free call `RatesDep.hit()` (owner == the module) → `M#hit`. EXACTLY ONE
            // hit across the file's covered imports joins — two candidates (or an index-ambiguous key) are
            // dropped, never picked from. A local resolution above is always authoritative (never guess
            // over project code), so this runs only when !resolved.
            if !resolved, !deps.isEmpty, !call.typed {
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                var hits: [DepEntry] = []
                for m in fileImports[file] ?? [] where deps.coveredPkgs.contains(m) {
                    if call.unqualified {
                        if let e = deps.lookup("\(m)#\(call.path)") ?? deps.lookup("\(m)#\(call.path).init") {
                            hits.append(e)
                        }
                    } else if let owner = call.extOwner {
                        if let e = deps.lookup("\(m)#\(owner).\(call.leaf)")
                            ?? (owner == m ? deps.lookup("\(m)#\(call.leaf)") : nil) {
                            hits.append(e)
                        }
                    }
                }
                if hits.count == 1, let de = hits.first {
                    direct[f.qual, default: []].formUnion(de.effects)
                    if de.effects.contains("Unknown") {
                        unresolvedSet.insert(f.qual)
                        if let why = de.whyReason { whyMap[f.qual, default: []].insert(why) }
                    }
                    hostsD[f.qual, default: []].formUnion(de.hosts)
                    cmdsD[f.qual, default: []].formUnion(de.cmds)
                    pathsD[f.qual, default: []].formUnion(de.paths)
                    tablesD[f.qual, default: []].formUnion(de.tables)
                    // inherit the dep fn's own honesty markers so the consumer's verdict stays qualified
                    // across the chain boundary: its blind-module disclosure and its masking-incompleteness
                    // (a benign literal HERE must not certify the dep's invisible runtime endpoint).
                    if !de.invisible.isEmpty { blindDirect[f.qual, default: []].formUnion(de.invisible) }
                    if !de.incomplete.isEmpty { incompleteD[f.qual, default: []].formUnion(de.incomplete) }
                    resolved = true
                }
            }
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
            } else if !resolved, let owner = call.extOwner, blindModules.contains(owner) {
                // ⟨0.15 staged⟩ a MODULE-QUALIFIED member call whose confidently-resolved receiver root IS
                // a blind imported module (`SomeSDK.doThing()` — extOwner == the module name, in this file's
                // import scope) demonstrably reaches that exact module. PRECISE, not file-granular — it names
                // only the module the call text targets, so the sweep-[33]/[36] guard (member calls on
                // stdlib/κ-pure receivers must NOT flood blind imports) is untouched: an unresolvable member
                // call on any OTHER receiver still attributes nothing and stays covered by the scan ledger.
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                if (fileImports[file] ?? []).contains(owner) {
                    blindDirect[f.qual, default: []].insert(owner)
                }
            }
        }

        // Bounded CHA over local protocols (SPEC §4, 0.5): the protocol is local and declares the
        // method; resolve ≤12 conformers, otherwise honest Unknown.
        for d in cc.protoDispatches {
            guard protoOrSuperDeclares(d.proto, d.member) else { continue }
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
            guard protoOrSuperDeclares(d.proto, d.member) else { continue }
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

    // ⟨0.21⟩ COMPLETENESS MANIFEST (Gap 2): a LOUD stderr line naming the count (like rust/java), so a
    // human sees the incompleteness even when they don't read the JSON. The machine-legible disclosure
    // rides the report's `unanalyzed` + the gate verdict (built in main.swift from this array).
    if !unanalyzed.isEmpty {
        FileHandle.standardError.write(
            "candor-swift: \(unanalyzed.count) source file(s) could not be read — NOT analyzed (their effects are unseen, not pure); see `unanalyzed` in the report\n"
                .data(using: .utf8)!)
    }
    return Analysis(
        allFns: allFns, conformers: conformers, importCounts: importCounts,
        internalModules: internalModules, direct: direct, edges: edges, whyMap: whyMap,
        locOf: locOf, entryPoints: entryPoints, inferred: inferred, hostsAcc: hostsAcc,
        cmdsAcc: cmdsAcc, pathsAcc: pathsAcc, tablesAcc: tablesAcc, incompleteAcc: incompleteAcc,
        invisibleAcc: invisibleAcc, unanalyzed: unanalyzed)
}
