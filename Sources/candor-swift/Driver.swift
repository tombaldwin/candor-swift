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
    /// ⟨0.23⟩ `typeSurface.returns` (SPEC §2, `DEP-RECEIVER-TYPING-DESIGN.md`): fn qual -> the FULLY
    /// QUALIFIED type a binding bound from that fn HOLDS. Both ends are qualified in this package's own
    /// namespace, so main.swift prefixes each with `<pkg>#` — the same namespace the entry hashes use.
    /// The point of the rung: a PURE factory is absent from `functions` entirely (§2 rule 3), so its
    /// return type can never be recovered from the entries, and every later method call on the binding
    /// drops. Empty when there is nothing to say, and the field is then omitted so the report stays
    /// byte-identical to a pre-rung one.
    var typeSurfaceReturns: [String: String]
}

/// ⟨0.23⟩ THE `typeSurface.returns` PRODUCER (SPEC §2, `DEP-RECEIVER-TYPING-DESIGN.md`).
///
/// `let c = build(); c.fetch()` types `c` from `build`'s RETURN type, and a PURE `build` is absent from
/// the dependency's report entirely (§2 rule 3) — so no consumer can recover it from the entries, and
/// every later method call on `c` drops. This publishes it.
///
/// QUALIFICATION IS THE WHOLE RULE, and it is the defect rust shipped and reverted. A leaf-keyed surface
/// makes `Sync.Client` and `Mock.Client` one string, and a PURE `mockClient()` then charges the real
/// client's effects to a caller that cannot reach them. So the written spelling is resolved against the
/// DECLARING type path, outward exactly as Swift's own lookup runs, and the result must match a declared
/// type path EXACTLY — never a leaf, never a suffix. A name that resolves to nothing (an imported type,
/// a stdlib type, a generic parameter) publishes NOTHING: it names no unit in this report, so a consumer
/// keying through it could only miss, and a miss it cannot explain is worse than an absent entry.
///
/// A fn qual that several functions share (a same-name overload set, whose members may return different
/// types) publishes nothing either — the never-guess rule the whole dep index runs on.
func buildTypeSurfaceReturns(_ allFns: [FnInfo], _ localTypePaths: Set<String>) -> [String: String] {
    var byQualCount: [String: Int] = [:]
    for f in allFns { byQualCount[f.qual, default: 0] += 1 }

    /// Resolve a written type spelling against the scope it was written in. `Client` inside
    /// `enum Sync { … }` is `Sync.Client`; inside `Sync.Inner` it is `Sync.Inner.Client`, else
    /// `Sync.Client`, else the top-level `Client` — the outward walk, stopping at the first EXACT hit.
    func resolveTypePath(_ written: String, scope: String?) -> String? {
        var segs = scope.map { $0.split(separator: ".").map(String.init) } ?? []
        while !segs.isEmpty {
            let cand = segs.joined(separator: ".") + "." + written
            if localTypePaths.contains(cand) { return cand }
            segs.removeLast()
        }
        return localTypePaths.contains(written) ? written : nil
    }
    // THE EXACTNESS OF THAT LAST LINE IS LOAD-BEARING, and it became PROVABLE only once the dep index
    // grew its third key shape (`pkg#<full qual>`, this repo's `9a51e7f`, candor-rust's `5feba18`).
    // Before that, relaxing it to a suffix match (`first { $0.hasSuffix(".\(written)") }`) failed NO
    // test and changed NO corpus output: a suffix match can only return a path of TWO OR MORE segments,
    // the consumer then forms a THREE-segment key, and an index carrying only `pkg#leaf`/`pkg#tail2`
    // misses it — a wrong answer with nowhere to land. An untestable guard is a hope, not a guard, so
    // it was written here as an open question rather than a claim.
    //
    // It is a claim now, and the fixture was written WITH the key: `openForeign() -> Progress` names
    // Foundation's type, which this package does not declare, and a suffix match answers `Mock.Progress`
    // instead — whose `pause` is effectful, so the guess LANDS on the third key and charges Env to a
    // caller holding a Foundation object. `testAForeignReturnSpellingPublishesNothingRatherThanSuffix-
    // Matching` fails under exactly that mutation and its sibling row asserts the other direction: a
    // spelling that resolves EXACTLY must still publish its full path.
    //
    // MEASURED, because "the key is what makes it matter" is itself checkable: with the third key
    // mutated back OUT and the suffix mutant left IN, the CONSUMER rows go green again —
    // `viaForeignFactory` misses and discloses, harmlessly. Only the producer-side "publishes nothing"
    // row still fails. So what the key changed is not that a wrong answer can be OBSERVED; it is that a
    // wrong answer now LANDS.

    var out: [String: String] = [:]
    for f in allFns {
        guard let written = f.retBoundTypeSpelling, byQualCount[f.qual] == 1,
              let resolved = resolveTypePath(written, scope: f.enclosingTypePath) else { continue }
        out[f.qual] = resolved
    }
    if ProcessInfo.processInfo.environment["CANDOR_TYPESURFACE_DEBUG"] != nil {
        let spelled = allFns.filter { $0.retBoundTypeSpelling != nil }.count
        let ambiguous = allFns.filter { $0.retBoundTypeSpelling != nil && byQualCount[$0.qual]! > 1 }.count
        let line = "TYPESURFACE producer: fns=\(allFns.count) plain-nominal-returns=\(spelled) "
            + "ambiguous-qual=\(ambiguous) type-paths=\(localTypePaths.count) published=\(out.count)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
    return out
}

// ════════════════════════════════════════════════════════════════════════════════════════════════
// Drive the two passes
// ════════════════════════════════════════════════════════════════════════════════════════════════

/// Std types that appear in an inheritance clause as a RAW VALUE, not a conformance: `enum Suit: String`
/// makes `String` look like a supertype of `Suit`. Dispatching over the "conformers" of one of these
/// would send every call on a String/Int-typed receiver into raw-value enums' methods — a fabrication,
/// so they are carved out of the imported-supertype CHA below.
let RAW_VALUE_BASE_TYPES: Set<String> = [
    "String", "Character", "Bool", "Double", "Float", "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
]

/// The Swift MODULE (SwiftPM target) a source path belongs to — `Sources/<Target>/…` / `Tests/<Target>/…`,
/// one module per target. Empty for anything outside that layout.
func swiftModuleOf(_ loc: String) -> String {
    let parts = loc.split(separator: ":").first.map(String.init)?.split(separator: "/").map(String.init) ?? []
    for (i, seg) in parts.enumerated() where seg == "Sources" || seg == "Tests" {
        if i + 1 < parts.count { return parts[i + 1] }
    }
    return ""
}

func analyze(sourcePaths: [String], rootDir: String, pkgName: String, deps: DepIndex = DepIndex()) -> Analysis {
    let fm = FileManager.default

    var allFns: [FnInfo] = []
    var fields: [String: [String: (name: String?, isFunction: Bool)]] = [:]
    var fieldArrayElem: [String: [String: String]] = [:]
    var fieldDictValue: [String: [String: String]] = [:]
    var opaqueFields: [String: Set<String>] = [:]
    var caseAssocAll: [String: Set<String>] = [:]
    var staticFactoryFields: [(type: String, field: String, leaf: String)] = []
    var protocolMethods: [String: Set<String>] = [:]
    var protocolSupers: [String: Set<String>] = [:]
    var conformers: [String: [String]] = [:]
    var localTypes: Set<String> = []
    var localTypePaths: Set<String> = []
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
        for (t, fs) in c.opaqueFields { opaqueFields[t, default: []].formUnion(fs) }
        for (cn, ts) in c.caseAssoc { caseAssocAll[cn, default: []].formUnion(ts) }
        for (pn, ms) in c.protocolMethods { protocolMethods[pn, default: []].formUnion(ms) }
        for (pn, ss) in c.protocolSupers { protocolSupers[pn, default: []].formUnion(ss) }
        for (pn, ts) in c.conformers { conformers[pn, default: []].append(contentsOf: ts) }
        localTypes.formUnion(c.localTypes)
        localTypePaths.formUnion(c.localTypePaths)
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
    // FILE-SCOPE GLOBALS are accessor units and so sit outside the overload pass above — which meant two
    // modules each declaring `let cfg` collapsed into ONE unit carrying the union of both initializers'
    // effects, reported at one file's location, and a reader of either was charged both. Give them the same
    // positional disambiguation ordinary functions get, so the units stay distinct; module-scoped resolution
    // below then picks the right one. (candor-spec SOUNDNESS-VEIN-global-unit-identity.md — rust had the
    // same merge on `<lazy>::NAME` and was fixed the same way.)
    var globalDup: [String: Int] = [:]
    for f in allFns where f.isAccessor && f.enclosingType == nil && !f.qual.contains(".") {
        globalDup[f.qual, default: 0] += 1
    }
    let mergedGlobals = Set(globalDup.filter { $0.value > 1 }.keys)
    if !mergedGlobals.isEmpty {
        var seenGlobal: [String: Int] = [:]
        for i in allFns.indices
        where allFns[i].isAccessor && allFns[i].enclosingType == nil
              && !allFns[i].qual.contains(".") && mergedGlobals.contains(allFns[i].qual) {
            let n = seenGlobal[allFns[i].qual, default: 0]
            seenGlobal[allFns[i].qual] = n + 1
            if n > 0 { allFns[i].qual = "\(allFns[i].qual)#\(n)"; allFns[i].simpleQual = allFns[i].qual }
        }
    }
    let overloadedQuals = Set(qualGroup.filter { $0.value > 1 }.keys)
    var overloads: [String: [(qual: String, sig: [(type: String?, hasDefault: Bool, variadic: Bool)], module: String)]] = [:]
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
            overloads[base, default: []].append(("\(allFns[i].qual)\(suffix)", allFns[i].paramSig,
                                                 swiftModuleOf(allFns[i].loc)))
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
    let matchOverloads: (String, Int, [String?], String) -> [String] = { base, argc, argTypes, callerModule in
        guard let cands = overloads[base] else { return [] }
        var hits: [String] = []
        var hitsInCallerModule: [String] = []
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
            if ok {
                hits.append(c.qual)
                if c.module == callerModule { hitsInCallerModule.append(c.qual) }
            }
        }
        let isFreeFunction = !base.contains(".")
        return (isFreeFunction && !hitsInCallerModule.isEmpty) ? hitsInCallerModule : hits
    }

    // MODULE-QUALIFIED FREE CALL (`Core.shared()`). Swift lets a call name the declaring module to
    // disambiguate, and it is the idiomatic way a wrapper delegates to a same-named implementation
    // elsewhere (`SwiftSyntaxMacrosTestSupport` → `SwiftSyntaxMacrosGenericTestSupport.assertMacroExpansion`).
    // Such a call was read as a member call on a TYPE named `Core`, which does not exist, so the edge was
    // DROPPED and the caller came back silent-pure — the cardinal sin (candor-spec
    // SOUNDNESS-VEIN-global-unit-identity.md). Indexed `module -> leaf -> quals`, and used only when the
    // module name is a real target and the leaf is unambiguous within it, so it can never guess.
    var freeFnByModule: [String: [String: [String]]] = [:]
    // module -> bare global name -> unit quals (the quals may carry a `#n` disambiguator).
    var globalsByModule: [String: [String: [String]]] = [:]
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
        if f.enclosingType == nil && !f.isAccessor && !f.isTopLevel {
            freeFnByName[f.qual, default: []].append(f.qual)
            // key on the SIMPLE name: the qual may already carry an overload suffix (`shared()#1`).
            let leaf = f.simpleQual.split(separator: "(").first.map(String.init) ?? f.simpleQual
            freeFnByModule[swiftModuleOf(f.loc), default: [:]][leaf, default: []].append(f.qual)
        }
        if f.isAccessor && f.enclosingType == nil && !f.qual.contains(".") {
            globalUnitNames.insert(f.qual)
            let bare = f.qual.split(separator: "#").first.map(String.init) ?? f.qual
            globalsByModule[swiftModuleOf(f.loc), default: [:]][bare, default: []].append(f.qual)
        }
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
    //
    // `coveredPkgs`, NOT `isChained`, and that asymmetry is the whole of the 2026-07-27 fix. A report
    // §2.1 refused to trust is still CHAINED (its keys are looked up, so rule 2's `Unknown` downgrade
    // fires) but makes NO coverage claim, so the package it names stays blind HERE and a key it does not
    // answer keeps its `invisible` hedge instead of reading pure. See the rule-3 note in Deps.swift.
    let blindModules = Set(importCounts.keys.filter {
        !PLATFORM_MODULES.contains($0) && !KAPPA_MODULES.contains($0) && !internalModules.contains($0)
            && !deps.coveredPkgs.contains($0) })
    var locOf: [String: String] = [:]
    var entryPoints: Set<String> = []
    var callsiteArgs: [String: [[ArgKind]]] = [:]   // resolved target -> each call site's arg kinds
    var deferredCallbacks: [String: (indexes: Set<Int>, names: Set<String>)] = [:]

    // THE ONE APPLY SITE for a chained dependency entry (SPEC §2). It was three, and they had drifted:
    // the chained-GLOBAL read carried the effects, `hosts`, `cmds` and `paths` and silently dropped
    // `tables`, `invisible` and `incomplete`. So a consumer that reached a dependency's effectful lazy
    // global inherited the EFFECT and not the dependency's own honesty markers — its blind-module
    // disclosure vanished, and its masking-incompleteness with it, which is precisely the case SPEC §2
    // names: a benign literal in the consumer must not certify what the dependency declared
    // uncertifiable. candor-rust found three drifted copies of this (7cb5748) and candor-java two
    // (6ab26e4) by asking the same question, so it is a duplication defect and not a swift accident.
    // Every field of `DepEntry` a consumer can inherit is applied HERE and nowhere else; adding one to
    // `DepEntry` and not to this function is the next instance of the same bug.
    func applyDepEntry(_ de: DepEntry, to qual: String) {
        direct[qual, default: []].formUnion(de.effects)
        if de.effects.contains("Unknown") {
            if let why = de.whyReason { whyMap[qual, default: []].insert(why) }
            // ⟨0.19⟩ the dependency's OWN reason tokens travel too, so the reason CLASS survives the
            // boundary and `deny E Unknown[<class>]` is not silently inert on a chained consumer.
            // `dep:<hash>` above names WHERE; these name WHY. See DepEntry.whyClasses.
            whyMap[qual, default: []].formUnion(de.whyClasses)
        }
        hostsD[qual, default: []].formUnion(de.hosts)
        cmdsD[qual, default: []].formUnion(de.cmds)
        pathsD[qual, default: []].formUnion(de.paths)
        tablesD[qual, default: []].formUnion(de.tables)
        if !de.invisible.isEmpty { blindDirect[qual, default: []].formUnion(de.invisible) }
        if !de.incomplete.isEmpty { incompleteD[qual, default: []].formUnion(de.incomplete) }
    }

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
    // Loop-invariant: `freeFnByName` is fully built above (the decl-aggregation pass) and never mutated in
    // the per-fn loop, so its key set is fixed. Build it ONCE here — not once PER function inside the loop
    // (`Set(freeFnByName.keys)` at the CallCollector site was O(freeFns) rebuilt N times = O(N²) on a
    // free-function-heavy corpus). Byte-identical: the set passed to each CallCollector is the same value.
    let localFreeFnNames = Set(freeFnByName.keys)
    // MEMBER NAMES PER LOCAL TYPE, for half 1's provenance conjunct. A bare `foo()` inside `struct Bar`
    // is `self.foo()` when `Bar` declares `foo` — a purely LOCAL call, never a dependency factory — but
    // the conjunct only excluded FREE functions, so every such call recorded a dependency-provenance
    // binding and every later member call on its result disclosed a false
    // `Unknown[dispatch:untyped cross-package receiver]`. Instrumented over 14 real targets: 289 bindings,
    // led by `rootOf` (16), `classifyItems`, `createFunction`, `parseMisplacedSpecifiers`, `expandMacros`
    // — enclosing-type methods, every one.
    //
    // Keyed by TYPE, not a flat leaf set, and the enclosing type's local SUPERS are climbed: the exclusion
    // must be as narrow as Swift's own bare-name resolution, because widening it drops a genuine half-1
    // disclosure, which is the direction that costs soundness. A same-named method on an UNRELATED local
    // type must exempt nothing.
    var localTypeMembers: [String: Set<String>] = [:]
    for f in allFns {
        guard let dot = f.simpleQual.lastIndex(of: ".") else { continue }
        let owner = String(f.simpleQual[..<dot])
        let member = String(f.simpleQual[f.simpleQual.index(after: dot)...])
        localTypeMembers[owner, default: []].insert(member.split(separator: "(").first.map(String.init) ?? member)
    }
    /// `t`'s own members plus every LOCAL supertype's, transitively — an inherited method is callable
    /// bare too. Walked with the same sorted, seen-guarded traversal the dispatch paths use.
    func membersVisibleOn(_ t: String) -> Set<String> {
        var out = localTypeMembers[t] ?? []
        var seen: Set<String> = [t], queue = Array(supertypesOf[t] ?? []).sorted()
        while let s = queue.popLast() {
            guard seen.insert(s).inserted else { continue }
            out.formUnion(localTypeMembers[s] ?? [])
            queue.append(contentsOf: (supertypesOf[s] ?? []).sorted())
        }
        return out
    }
    var membersVisibleCache: [String: Set<String>] = [:]
    for f in allFns {
        locOf[f.qual] = f.loc
        if f.isMain { entryPoints.insert(f.qual) }
        edges[f.qual] = edges[f.qual] ?? []
        guard let body = f.body else { continue }
        let cc = CallCollector(info: f, fields: fields, localTypes: localTypes,
                               declaredTypes: declaredTypes,
                               localProtocols: localProtocolNames, returns: returnsIdx,
                               fieldArrayElem: fieldArrayElem, fieldDictValue: fieldDictValue,
                               opaqueFields: opaqueFields,
                               enumCaseValueType: enumCaseValueType, dynamicMemberTypes: dynamicMemberTypes,
                               propertyWrapperTypes: propertyWrapperTypes, wrappedProps: wrappedProps,
                               localFreeFns: localFreeFnNames, typeAliases: typeAliases,
                               enclosingMembers: f.enclosingType.map { t in
                                   membersVisibleCache[t] ?? {
                                       let m = membersVisibleOn(t); membersVisibleCache[t] = m; return m
                                   }()
                               } ?? [],
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
        // A bare global read resolves in the reader's OWN module when that module declares the name —
        // the same lexical rule the free-function path uses, and the reason the two `cfg`s above needed to
        // stay distinct units first. Falls back to the plain name match, so a module that declares no such
        // global still reaches a uniquely-named one elsewhere exactly as before.
        let readerModule = swiftModuleOf(f.loc)
        for name in cc.globalReads where name != f.qual {
            if let inMod = globalsByModule[readerModule]?[name], inMod.count == 1 {
                edges[f.qual, default: []].insert(inMod[0])
            } else if globalUnitNames.contains(name) {
                edges[f.qual, default: []].insert(name)
            } else if !deps.isEmpty {
                // The global may belong to a chained DEPENDENCY module. Reading it still forces its
                // initializer — swift globals are lazy — and the dep's report records that unit under
                // `<Module>#<name>`, but nothing looked for it, so a consumer of an effectful dependency
                // global read sound-complete pure (candor-spec SOUNDNESS-VEIN-initializer-edge.md; java and
                // rust needed the same edge on their side of the boundary). Effects attach directly, since
                // the dep's unit lives in another report. Only the file's own imports are consulted and only
                // an unambiguous single hit joins, so an unimported or ambiguous name resolves to nothing.
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                var hits: [DepEntry] = []
                for m in fileImports[file] ?? [] where deps.isChained(m) {
                    if let e = deps.lookup("\(m)#\(name)") { hits.append(e) }
                }
                if hits.count == 1, let de = hits.first { applyDepEntry(de, to: f.qual) }
            }
        }
        direct[f.qual, default: []].formUnion(cc.directEffects)
        if cc.unresolved { direct[f.qual, default: []].insert("Unknown") }
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
            // MODULE-QUALIFIED FREE CALL (`Core.shared()`) — checked FIRST, because such a call is neither
            // `typed` (its base names a module, not a type) nor `unqualified`, so it reached no branch at
            // all and the caller came back silent-pure. Swift lets a call name the declaring module to
            // disambiguate, and it is how a wrapper delegates to a same-named implementation elsewhere
            // (`SwiftSyntaxMacrosTestSupport` → `SwiftSyntaxMacrosGenericTestSupport.assertMacroExpansion`).
            // Exact, not a guess: the base must be a real target that is NOT also a local type, and that
            // target must declare exactly one free function of the name — otherwise nothing resolves.
            if !call.typed, !call.unqualified, let modName = call.extOwner,
               !localTypes.contains(modName),                       // a real type shadows a module name
               let inMod = freeFnByModule[modName]?[call.leaf], inMod.count == 1 {
                edges[f.qual, default: []].insert(inMod[0])
                callsiteArgs[inMod[0], default: []].append(call.args)
                resolved = true
            } else if call.extOwner == CallCollector.superMarker {
                // `super.m()` — resolve on the SUPERTYPE chain, never on the enclosing type: for an
                // override (`override func load() { super.load() }`) the enclosing type's own unit IS the
                // caller, so edging there would add nothing and the base's effect stayed silent. Walking the
                // chain also covers the different-name form (`func run() { super.other() }`). Every matching
                // supertype is edged — a union across a chain is sound, and an unresolvable `super` (an
                // external base) resolves to nothing, exactly as before.
                let member = call.leaf
                if let et = f.enclosingType {
                    for sup in supertypesOf[et] ?? [] where sup != et {
                        if let t = resolveQual("\(sup).\(member)") {
                            edges[f.qual, default: []].insert(t)
                            callsiteArgs[t, default: []].append(call.args)
                            resolved = true
                        }
                    }
                }
            } else if call.typed {
                if overloadedBases.contains(call.path) {
                    for t in matchOverloads(call.path, argc, call.argTypes, swiftModuleOf(f.loc)) {
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
                        // SORTED. `supertypesOf` is a [String: Set<String>], and a Set's iteration order
                        // varies between processes — so `.first` below picked a different supertype on
                        // different runs of the SAME binary on the SAME input. Effect sets were unaffected
                        // (Unknown either way), but the DISCLOSURE REASON churned: `dispatch:CodingKey.self`
                        // vs `dispatch:String.self`, and the per-function reason SET even changed size when
                        // two call sites happened to pick differently.
                        //
                        // That is not cosmetic. A/B diffing reports on real code is this project's primary
                        // evidence, and a report that differs from ITSELF injects noise into every diff —
                        // it cost a false datapoint before anyone thought to run a report against itself.
                        // It also makes `gains` noisy between identical inputs, which is product-facing.
                        let extSupers = (supertypesOf[type] ?? []).filter { !localTypes.contains($0) }.sorted()
                        if let eff = extSupers.compactMap({ FLUENT_MODEL_PROTOCOLS.contains($0) ? fluentModelEffect(member) : nil }).first {
                            direct[f.qual, default: []].insert(eff)
                            resolved = true
                        } else if let sup = extSupers.first(where: { !STD_PURE_PROTOCOLS.contains($0) }) {
                            direct[f.qual, default: []].insert("Unknown")
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
                    for t in matchOverloads(call.path, argc, call.argTypes, swiftModuleOf(f.loc)) {
                        edges[f.qual, default: []].insert(t)
                        callsiteArgs[t, default: []].append(call.args)
                        resolved = true
                    }
                } else if let targets = freeFnByName[call.path], targets.count == 1 {
                    edges[f.qual, default: []].insert(targets[0])
                    callsiteArgs[targets[0], default: []].append(call.args)
                    resolved = true
                } else if localTypes.contains(call.path), overloadedBases.contains("\(call.path).init") {
                    for t in matchOverloads("\(call.path).init", argc, call.argTypes, swiftModuleOf(f.loc)) {
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
                    for t in matchOverloads("\(et).\(call.leaf)", argc, call.argTypes, swiftModuleOf(f.loc)) {
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
            // DISPATCH OVER AN IMPORTED PROTOCOL/BASE WHOSE CONFORMERS ARE LOCAL. `s.speak()` where
            // `s: Speaker`, `Speaker` is a DEPENDENCY's protocol and `final class AppSpeaker: Speaker` is
            // declared HERE: `protocolMethods`/`protoParams` are local-only, so `s` was never recognised as
            // protocol-typed and no dispatch was recorded at all — the call read silent-pure even though the
            // witness that runs is a project unit candor analysed correctly two files away
            // (candor-spec/SOUNDNESS-VEIN-crossing-the-scan-boundary.md; `trait_decls is local-only` is the
            // rust sibling). This half is recoverable with NO dep report — the conformance declaration is
            // ours — and `conformers` already records it: Swift's inheritance clause is where a conformance
            // to an imported protocol is spelled, so `subtypesOf[Speaker]` holds our conformers.
            //
            // PRECISE-OR-NOTHING and ADDITIVE. Only real `<conformer>.<member>` units are edged, so a member
            // no conformer declares contributes nothing (no Unknown flood over every external-typed
            // receiver). `resolved` is deliberately NOT set: the local conformer set is a LOWER bound on the
            // true one — a dependency's own conformers are still invisible — so the call keeps its κ/blind
            // disclosure AND still reaches the §2 join below (which is what carries a chained sibling's
            // conformers, via its protocol-CHA union entries).
            //
            // Two carve-outs, both fabrication guards on Swift's OVERLOADED inheritance clause (the same
            // hazard the stringification witness table documents). STD_PURE_PROTOCOLS: their requirements
            // are synthesized and pure, and nearly every type conforms, so CHA there would union unrelated
            // project methods onto `Codable`/`Hashable`/`Sequence`-typed receivers. RAW_VALUE_BASE_TYPES:
            // `enum Suit: String` records `String` as a supertype, so without the carve-out a call on any
            // String/Int-typed value would dispatch into raw-value enums' methods — a pure fabrication.
            // ERASURE, and it belongs HERE rather than at the binding. `some P` is opaque: the CALLER
            // picks one conforming type, so the local conformers are not this receiver's witnesses and
            // unioning them fabricates. `any P` is an existential and genuinely may be any of them.
            // Only THIS arm is suppressed — the §2 dep join below still runs on an opaque receiver, and
            // soundly, since every monomorphization must conform to P. An earlier version enforced the
            // distinction by withholding the receiver's TYPE, which took the dep join with it and made an
            // Fs-performing function read PURE.
            if !resolved, !call.typed, !call.unqualified, !call.opaqueRecv, let owner = call.extOwner,
               !localTypes.contains(owner), !STD_PURE_PROTOCOLS.contains(owner),
               !RAW_VALUE_BASE_TYPES.contains(owner) {
                for sub in subtypesOf[owner] ?? [] {
                    if let t = resolveQual("\(sub).\(call.leaf)") { edges[f.qual, default: []].insert(t) }
                }
            }
            // COULD-NOT-FORM-A-KEY (DEP-RECEIVER-TYPING-DESIGN.md half 1). The receiver was bound from a
            // call out of this target whose return type never travelled, so no key was ever formed and
            // NOTHING was looked up — the dep report's silence is only an answer to a question that was
            // asked. Dropping here makes the caller a confident purity claim; under the ⟨0.21⟩ manifest it
            // is still counted in `analyzed`, so the omission reads as a positive claim rather than a gap.
            //
            // THREE conjuncts, the third learned by measuring in rust: untyped receiver AND dep provenance
            // AND the package is CHAINED. For an UNCHAINED package the κ ledger already discloses
            // `invisible: [M]`, so a second disclosure would be pure false uncertainty; it is precisely
            // when the package IS chained that the ledger correctly falls silent (§2 rule 3) and the
            // silence becomes the claim worth spending a disclosure on.
            if call.path.hasPrefix("<untyped>.") {
                let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
                // ⟨0.23⟩ HALF 2 — DETERMINATION (SPEC §2 `typeSurface.returns`). Ask the dependency what
                // its factory RETURNS, then key the ordinary chained lookup with it. Both ends of the
                // surface are fully qualified in the producing package's namespace — the same namespace
                // the entry hashes use — so the key we form here is `<pkg>#<type qual>.<method>` and no
                // new resolution path is added: it is the shape the join already understands.
                //
                // Same never-guess discipline as every other join on this path: only the file's OWN
                // imports, only packages a loaded report COVERS, and only an unambiguous SINGLE hit.
                if let callee = call.depCallee {
                    var hits: [DepEntry] = []
                    var surfaced: [String] = []
                    for m in fileImports[file] ?? [] where deps.isChained(m) {
                        guard let ty = deps.boundType("\(m)#\(callee)") else { continue }
                        surfaced.append(ty)
                        if let e = deps.lookup("\(ty).\(call.leaf)") { hits.append(e) }
                    }
                    // THE ANSWER MUST BE UNAMBIGUOUS TOO, not only the entry lookup that follows it.
                    // `depCallee` is a BARE name (`build`) — an idiomatic Swift call into a dependency
                    // carries no module — so every covered import of this file is asked the same fn key,
                    // and two libraries may both export a `build`. Gating on `hits.count == 1` alone let
                    // ONE of two different answers be picked whenever the other package's type happened
                    // to have no entry for the member: Alpha publishing `build -> Alpha#Client` (whose
                    // `fetch` is Fs, with `/etc/secrets` in its `paths`) and Beta publishing
                    // `build -> Beta#Stub` (whose `fetch` is pure, so absent) charged Alpha's effect AND
                    // its path literal to a caller that reaches Beta, with `unresolved` left false so
                    // nothing disclosed it. That is a leaf-keyed collapse of two distinct types — rust's
                    // reverted defect 1 — reappearing ACROSS packages rather than within one.
                    //
                    // §2 rule 1 says a key two entries share is DROPPED, never picked from, and the
                    // index enforces that WITHIN a report (`returnsAmbiguous`); this is the same rule
                    // ACROSS the file's imports, where no single report can see the collision. Refusing
                    // falls through to half 1's disclosure below — never to silence.
                    let answers = Set(surfaced)
                    // An A/B diff cannot show that a mechanism never fired, or fired on the wrong thing —
                    // so the trigger, the `returns` answer and the entry lookup are each observable.
                    if ProcessInfo.processInfo.environment["CANDOR_TYPESURFACE_DEBUG"] != nil {
                        let verdict = answers.count > 1 ? "AMBIGUOUS"
                            : (hits.count == 1 ? "HIT " : (surfaced.isEmpty ? "MISS-returns" : "MISS-entry"))
                        let line = "TYPESURFACE-\(verdict) \(f.qual) :: \(callee) -> "
                            + "\(surfaced.isEmpty ? "<no returns entry>" : surfaced.sorted().joined(separator: "|"))"
                            + " :: .\(call.leaf)()\n"
                        FileHandle.standardError.write(line.data(using: .utf8)!)
                    }
                    if answers.count == 1, hits.count == 1, let de = hits.first {
                        applyDepEntry(de, to: f.qual)
                        continue
                    }
                }
                // A MISS — on `returns` OR on the entry lookup that follows a `returns` HIT — falls back
                // to half 1's disclosure, NEVER to silence. The second half is the one that is easy to get
                // wrong and is a requirement rather than belt-and-braces: this index DROPS a key two
                // entries share (§2 rule 1), so a miss cannot distinguish "no such method" from "I
                // withdrew the answer", and a refusal to answer is not a purity claim. rust shipped that
                // `continue` and reverted it.
                if (fileImports[file] ?? []).contains(where: { deps.isChained($0) }) {
                    direct[f.qual, default: []].insert("Unknown")
                    whyMap[f.qual, default: []].insert("dispatch:untyped cross-package receiver")
                }
                continue
            }
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
                for m in fileImports[file] ?? [] where deps.isChained(m) {
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
                    // inherit the dep fn's own honesty markers too, so the consumer's verdict stays
                    // qualified across the chain boundary (a benign literal HERE must not certify the
                    // dep's invisible runtime endpoint) — see applyDepEntry.
                    applyDepEntry(de, to: f.qual)
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
                whyMap[f.qual, default: []].insert("dispatch:\(d.proto).\(d.member)")
                continue
            }
            for c in conf {
                if let t = resolveQual("\(c).\(d.member)") { edges[f.qual, default: []].insert(t) }
            }
        }
        // IMPLICIT STRINGIFICATION over a PROTOCOL-typed operand — `"\(e)"` / `String(describing: e)` /
        // `print(e)` where `e: any P` (or a generic `<T: P>`): the `description`/`debugDescription` that
        // RUNS is the conformer's witness, and no call site spells it. The concrete-receiver form already
        // edged (CallCollector Vector 1/2); the existential form reached NOTHING — the four-way
        // implicit-stringification vein (candor-spec/SOUNDNESS-VEIN-implicit-stringify.md), found on
        // HikariCP through SLF4J parameterized logging and reproduced in all four engines.
        //
        // CHA over the protocol's (transitive) conformers/subclasses, like the property-read rung above —
        // but PRECISE-OR-NOTHING: a conformer set that resolves to no `description` unit edges nothing
        // instead of disclosing `Unknown`, and there is no ≤12 bound (the bound exists to decide when to
        // fall back to Unknown; with no Unknown to fall back to, capping would only DROP real dispatch
        // targets — a silent under-report, the thing being fixed). Rationale for precise-or-nothing (and
        // the honest residual): a conformer that does NOT declare `description` stringifies through the
        // stdlib's PURE reflective default, so "no local witness" is overwhelmingly "nothing runs" rather
        // than "something hidden runs" — and interpolation is pervasive enough in Swift that an Unknown
        // here would flood every program's report (the usability catastrophe the vein write-up warns
        // against). RESIDUAL, recorded not repaired: a conformer declared OUTSIDE the analysed code whose
        // `description` is effectful is still missed.
        for d in cc.stringifyDispatches {
            for c in subtypesOf[d.proto] ?? [] {
                if let t = resolveQual("\(c).\(d.member)") {
                    edges[f.qual, default: []].insert(t)
                } else {
                    // an INHERITED witness (the `description` accessor lives on a superclass / a conformed
                    // protocol's extension) — climb exactly as the accessor-unit edge above does.
                    for sup in supertypesOf[c] ?? [] {
                        if let t = resolveQual("\(sup).\(d.member)") { edges[f.qual, default: []].insert(t) }
                    }
                }
            }
        }
        // DESUGARED EDGES ACROSS THE SCAN BOUNDARY. Two mechanisms that run without any call being
        // spelled at the site — the implicit `description`/`debugDescription` witness of a
        // stringification, and the `deinit` glue of a constructed non-escaping local — are modeled
        // INSIDE the scan by LOCAL-only indexes (`localTypes`, `localProtocols`/`conformers`). When the
        // type belongs to a chained DEPENDENCY it is in none of them, so the site recorded NOTHING, not
        // even Unknown, and a `deny`-gated app went GREEN on code its single-package control fails
        // (candor-spec/SOUNDNESS-VEIN-crossing-the-scan-boundary.md; rust closed its stringification
        // half in candor-rust 1623a07). In both cases the dep's own report already holds the answer
        // under `<Module>#<Type>.<member>` — nothing looked for it.
        //
        // Effects attach DIRECTLY, since the dep's unit lives in another report — the shape the
        // chained-global edge (7a1b077) and the §2 call join both use. Same discipline as both: only the
        // file's OWN imports are consulted, only packages a loaded report COVERS, and only an
        // unambiguous single hit joins, so an unimported, uncovered or ambiguous type resolves to
        // nothing rather than being guessed. Both candidate sets self-filter: a pure witness / a type
        // with no effectful `deinit` is ABSENT from the dep report (reports omit pure functions), so the
        // join adds nothing. With no dep report loaded neither set is consulted at all, which is why the
        // unchained analysis is unchanged by construction.
        //
        // `propertyExternal` is the THIRD member of this set and arrived the same way: an accessor unit
        // is a body that RUNS on a property read, the dep's report carries it under the same
        // `<Module>#<Type>.<member>` key (`unitKind: "accessor"`), and the reader-side branch was
        // local-only so the read was never recorded. It self-filters identically — a STORED property and
        // a PURE computed one are absent from the dep report — and it is a candidate set rather than a
        // `propertyEdges` entry precisely so a local type sharing a dependency type's name resolves to
        // its OWN unit and can never inherit the dependency's (candor-spec SCAN-BOUNDARY-WORK-QUEUE §3c).
        if !deps.isEmpty, !(cc.stringifyExternal.isEmpty && cc.deinitExternal.isEmpty
                            && cc.propertyExternal.isEmpty) {
            let file = String((locOf[f.qual] ?? f.loc).prefix { $0 != ":" })
            for cand in cc.stringifyExternal.union(cc.deinitExternal).union(cc.propertyExternal) {
                var hits: [DepEntry] = []
                for m in fileImports[file] ?? [] where deps.isChained(m) {
                    if let e = deps.lookup("\(m)#\(cand)") { hits.append(e) }
                }
                // An A/B diff shows which FUNCTIONS moved, never which KEY moved them — and the one
                // over-fire this join has had (`String.init`, see `METATYPE_MEMBERS`) was invisible in
                // the diff and obvious in this line. Same reason `CANDOR_TYPESURFACE_DEBUG` exists.
                if ProcessInfo.processInfo.environment["CANDOR_DEPMEMBER_DEBUG"] != nil {
                    let kind = cc.propertyExternal.contains(cand) ? "prop"
                        : (cc.deinitExternal.contains(cand) ? "deinit" : "stringify")
                    FileHandle.standardError.write(
                        "DEPMEMBER-\(hits.count == 1 ? "HIT " : "MISS") \(kind) \(f.qual) :: \(cand)\n"
                            .data(using: .utf8)!)
                }
                guard hits.count == 1, let de = hits.first else { continue }
                applyDepEntry(de, to: f.qual)
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
        invisibleAcc: invisibleAcc, unanalyzed: unanalyzed,
        typeSurfaceReturns: buildTypeSurfaceReturns(allFns, localTypePaths))
}
