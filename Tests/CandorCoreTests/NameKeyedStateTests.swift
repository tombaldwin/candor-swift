import XCTest
import Foundation
import SwiftParser
import SwiftSyntax

/// THE SET OF NAME-KEYED MAPS A REBIND MUST INVALIDATE IS NOW DERIVED, NOT LISTED.
///
/// One mechanism has produced SEVEN defects in this collector across three days, every one the same
/// shape: a name-keyed fact outliving the binding that set it. Each fix removed one enumeration and
/// left another standing.
///
///   `71de627`, `83cd607`  — a binder form nobody had enumerated did not clear
///   `42093b6`             — THE CATCH-ALL BINDER: `visit(IdentifierPatternSyntax)` is where the
///                           language puts every pattern binding, so an unenumerated binder FORM now
///                           defaults to dropping a stale binding. It removed the enumeration of
///                           binder forms — and clears a LIST of maps, which is the same enumeration
///                           one level up.
///   `c77038f`             — `protoTyped` and `localConstStrings` were not on that list
///   `c2c85e3`             — nor was `fnValueAlias`, and the audit that produced `c77038f` had
///                           explicitly cleared it by probing only the LOSS direction
///
/// So the remedy is not another entry on another list. This file makes the OBLIGATION derived: it
/// parses `CallCollector.swift` with the same parser the engine uses, enumerates the class's stored
/// properties from the parse tree, and requires each one to appear in `disposition` below. Adding a
/// map without classifying it fails a test. Classifying it as cleared without writing the clear fails
/// a test. Classifying it as scoped without saving AND restoring it fails a test.
///
/// WHAT IS AUTHORED AND WHAT IS DERIVED. The SET is derived — nobody keeps it current, and neither a
/// forgotten entry nor a stale one can survive. The JUDGEMENT is authored, and it has to be: whether a
/// `[String: X]` is keyed by a BINDING name or by a TYPE name is a fact about meaning, not syntax, and
/// the two hedging sets must NOT be cleared (clearing them lets a shadowed name resolve to silence,
/// which is the mirror sin). Forcing that judgement to be written down, once per property, is the
/// whole of what this file buys.
///
/// WHAT THIS FILE CANNOT SEE, STATED SO THE NEXT READER DOES NOT ASSUME IT IS COVERED. The derivation
/// is over DECLARATIONS: which maps exist, and whether the clear/save/restore paths mention each one.
/// It says nothing about whether every BINDER SITE takes those paths, and a review found exactly that
/// defect after this file shipped — `typeEnumCaseBinding`'s TYPED branch called `shadowName` (the four
/// FLAGS) and wrote `vars` over the top, so `protoTyped` survived and an enum payload binding shadowing
/// a protocol-typed parameter dispatched over that protocol's conformers. Every row here was green
/// through it, correctly: `protoTyped` IS classified, IS cleared in `clearBindingTypeOnly`, and IS
/// saved and restored. The map's disposition was right; one branch did not honour it.
///
/// THE STRENGTHENING WAS CONSIDERED AND REFUSED, and the reason is a property of the property. What was
/// violated is per-NAME and per-CONTROL-PATH — "before a binder writes a fact about `x`, every other
/// per-binding map keyed by `x` is invalidated" — and a parse tree shows declarations and mentions, not
/// which of two branches ran. The two derivable approximations were both priced:
///   - "every METHOD that writes a per-binding map must also mention a clear helper" — the defective
///     method mentioned BOTH `shadowName` and `clearBinding`; it would have passed.
///   - "every WRITE SITE must be listed in an authored allowlist" — derivable and exact, but the site
///     in question predates the wave, so its entry would have been written years before the branch went
///     wrong; it would have passed too. It also re-introduces the authored list this file exists to
///     delete, one level down, over ~25 `vars` writes.
/// So the remedy is at the SITE, not in a test: the branches were fused so that no path through
/// `typeEnumCaseBinding` can write a type without the clear having run. `TypedRebindShadowProcessTests`
/// is the behavioural gate, with a rename control per row. If a third form of this defect appears, the
/// thing to re-price is the binding-model rewrite (see `enterShadowScope`), not another derivation here.
///
/// A SOURCE-LEVEL TEST BECAUSE REFLECTION IS NOT AVAILABLE: `CallCollector` lives in the EXECUTABLE
/// target, which a test target cannot import, so `Mirror` over a live instance is out. The parse tree
/// is the next-best derivation and is exact rather than approximate — a regex over the source would be
/// the "parser that silently mis-attributes" this project has already been bitten by, so this uses
/// SwiftParser and asserts the extracted set both ways.
final class NameKeyedStateTests: XCTestCase {

    enum Disposition {
        /// A per-binding FACT. A rebind must drop it (`shadowName` or `clearBindingTypeOnly`), and if
        /// `scoped` the enclosing block must give it back (`ShadowSave`) — because dropping it at scope
        /// close costs a real reach, which is the mirror of the fabrication the clear closes.
        case clearedOnRebind(scoped: Bool)
        /// A HEDGE. Clearing it lets a shadowed name fall through to silence — the cardinal sin — so it
        /// is deliberately left alone and over-hedges instead. The reason is the payload.
        case deliberatelyKept(String)
        /// A LEXICAL EXISTENCE SET: not a per-binding FACT that a rebind invalidates, but a claim that
        /// a name IS a local right here. Nothing clears it — a binder only ever adds — so the discipline
        /// it needs is the SCOPE half alone: saved on entry, restored on close, because the claim stops
        /// being true when the block ends. The reason is the payload.
        case lexicallyScoped(String)
        /// KNOWN DEFECTIVE, measured, filed. Recorded here so the next audit inherits the numbers
        /// instead of the surprise.
        case knownDefect(String)
        /// A program-wide index injected at construction — keyed by a TYPE name, a MODULE name or a
        /// declaration name, never by a binding. A rebind has nothing to say about it.
        case immutableIndex
        /// Output, accumulator, or scope bookkeeping. Never consulted to resolve a NAME to a binding.
        case notPerBinding
    }

    /// EVERY stored property of `CallCollector`, and what a rebind does to it.
    static let disposition: [String: Disposition] = [
        // ── per-binding facts: cleared, and scoped because dropping them at scope close costs a reach
        "monoNames":         .clearedOnRebind(scoped: true),
        "depBoundLocals":    .clearedOnRebind(scoped: true),
        "localConstStrings": .clearedOnRebind(scoped: true),
        "fnValueAlias":      .clearedOnRebind(scoped: true),
        "protoTyped":        .clearedOnRebind(scoped: true),
        "opaqueElem":        .clearedOnRebind(scoped: true),
        // ── per-binding TYPES: cleared, deliberately NOT scoped. A stale type is dangerous inward and
        //    merely lossy outward, so the clear is enough; `typeScopes` restores them for a `for`
        //    binder, whose scope is strictly the loop, and that is the only place it is needed.
        "vars":              .clearedOnRebind(scoped: false),
        "arrayElem":         .clearedOnRebind(scoped: false),
        "dictElem":          .clearedOnRebind(scoped: false),
        "tupleElem":         .clearedOnRebind(scoped: false),
        // ── hedges: MUST NOT be cleared
        "fnTyped": .deliberatelyKept(
            "invoking a fn-typed param defers to callback-flow; clearing it on a rebind sends the "
            + "invocation to the unqualified-free-call arm, which resolves to nothing and reads pure"),
        "opaqueFnLocals": .deliberatelyKept(
            "an opaque fn-typed local invoked is §4 Unknown; clearing it drops the Unknown, and an "
            + "over-hedge on a shadowing binder costs precision where the clear would cost soundness"),
        // ── a lexical existence set: nothing clears it, the scope gives it back
        "casePayloadLocals": .lexicallyScoped(
            "enum-case payload bindings (`case let .x(a)` / `case .x(let a)`), which the collector's own "
            + "guards consult alongside `boundLocals`. SEPARATE from it because a payload binding's scope "
            + "is the one case body — folding them into the function-wide set drops the genuine property "
            + "read after the block (swift-syntax `IfConfigDiagnostic.asDiagnostic`), and scoping "
            + "`boundLocals` instead un-shadows the Driver's post-walk guard. Both measured; see "
            + "`EnumPayloadBindingProcessTests`."),
        // ── the locator-move PRE-PASS: kept, and kept for the OPPOSITE reason to the two hedges above
        "movedNames": .deliberatelyKept(
            "the flow-insensitive move set behind locator provenance, computed over the WHOLE body "
            + "BEFORE any call is collected. Every other row here asks what a rebind does to a fact; "
            + "this map IS the record that a rebind happened, so clearing it on one would delete the "
            + "evidence that suppresses the claim and leave a stale host/command literal standing — a "
            + "FABRICATION, the mirror of the silence the other hedges guard. It is not per-binding at "
            + "all: a name in it is refused for the whole unit, deliberately, including at a use that "
            + "is lexically EARLIER than the move (the loop-carried rebind case)."),
        "propWrites": .deliberatelyKept(
            "the companion of `movedNames` — the property spellings written on each name, judged at the "
            + "point of use against a per-binder-kind inert allowlist. Same argument for keeping it: it "
            + "records that `req.url` (or `p.launchPath`) was assigned, and dropping that on a rebind "
            + "would re-admit exactly the locator the write moved. Body-wide by construction, and never "
            + "consulted to resolve a name to a binding — only to REFUSE a literal claim about one."),
        "execLocatorWrites": .deliberatelyKept(
            "the program a `Process` LOCAL was told to execute (`p.launchPath = \"/bin/sh\"`), carried to "
            + "the launching verb, which takes no argument and so has no other source for it. Kept — and "
            + "THE ARGUMENT FOR KEEPING IT WAS WRONG IN ITS PREMISE. It read: a rebind of the handle is "
            + "already recorded in `movedNames` and `recordProcessRun` consults it, so clearing this map "
            + "would lose the literal while the refusal stands. True of a REBIND, false of a shadow "
            + "BINDER — nothing assigns to the outer name, so the move pre-pass has nothing to record, "
            + "and `let p = make(); if true { let p = Process(); p.launchPath = \"/bin/x\" }; p.launch()` "
            + "reported a program that handle never ran (measured; `allow Exec /bin/x` certified it). The "
            + "CONCLUSION survives — clearing the value while the refusal stands is the wrong direction — "
            + "but the shadow needed a gate of its own: `multiplyBoundNames`, consulted at the READ. "
            + "RENAMED from `execLocatorOfLocal` and no longer a flat `Set` of literals: each write now "
            + "carries the chain of statement lists enclosing it, so a LATER write can kill an earlier one "
            + "it dominates (see `ExecLocatorOverwriteProcessTests` — two straight-line writes to one "
            + "handle reported BOTH programs, though only the second can run). That is a kill WITHIN one "
            + "binding and is orthogonal to this file's question: it says nothing about what a REBIND of "
            + "the name does, which is still `movedNames`/`multiplyBoundNames`' job, and the kill is "
            + "gated on statement-list ancestry precisely so it can never reach across a binder."),
        "execLocatorInvisible": .deliberatelyKept(
            "the half that keeps the Exec gate closed: a `launchPath`/`executableURL` write whose value "
            + "could NOT be read statically. Clearing it on a rebind would let a benign visible literal "
            + "certify an `allow Exec` for a function that also spawns a runtime program — the AS-EFF-008 "
            + "masking evasion, and the precise way this mechanism could have made the gate quieter. It "
            + "is monotone by construction: an entry is only ever ADDED, and never for a name."),
        "multiplyBoundNames": .deliberatelyKept(
            "names with more than ONE binder site in this unit, the function's own parameters counted as "
            + "binders. Computed in the locator PRE-PASS, so — like `movedNames` — it is not a fact about "
            + "a binding but the record that the NAME is ambiguous across the body, and clearing it on a "
            + "rebind would delete the refusal it exists to raise. It is the SHADOW half of what "
            + "`movedNames` does for reassignment: `let p = make(); if true { let p = Process(); "
            + "p.launchPath = \"/bin/x\" }; p.launch()` moves nothing, so the move set is empty and the "
            + "second binder's literal stood under the outer name. Refusing costs precision on a name "
            + "reused by two disjoint bindings (both surfaces are dropped, which reads as an incomplete "
            + "surface — the closed direction) and that is the trade the fabrication is worth."),
        // ── known defective, measured and filed rather than patched
        "boundLocals": .knownDefect(
            "written by only 2 of the ~7 binder forms. The ENUM-CASE payload forms are now covered by "
            + "`casePayloadLocals` above (0 gains / 15 report changes over 13 packages, every one traced "
            + "to a fabrication); a CATCH binder, a CLOSURE parameter and a FUNCTION parameter still "
            + "register no shadow, so a bare read of one edges to the enclosing type's same-named "
            + "property or to a same-named global. Writing it in `shadowName` for ALL of them was "
            + "measured at 305 report changes and reverted; what the payload round then established is "
            + "that the vanishing entries in that arm were fabricated `invisible` disclosures being "
            + "withdrawn, and that the residual risk is scope, not the claim. See the work queue."),
        "catchBindings": .knownDefect(
            "same mechanism in the stringification arm: function-wide, and its shadow guard is a "
            + "`!boundLocals.contains` PROXY that stops working the moment `boundLocals` is written by "
            + "every binder. Entangled with the row above and filed with it."),
        // ── program-wide indexes injected at construction
        "moduleConstStrings": .immutableIndex, "fields": .immutableIndex,
        "fieldArrayElem": .immutableIndex, "fieldDictValue": .immutableIndex,
        "opaqueFields": .immutableIndex, "localTypes": .immutableIndex,
        "declaredTypes": .immutableIndex, "enclosingMembers": .immutableIndex,
        "localFreeFns": .immutableIndex, "localProtocols": .immutableIndex,
        // R73 — module-scope GLOBAL name -> concrete type (and its array-element sibling), injected at
        // construction from the Driver's module-sliced merge (`globalTypesByModule`). Keyed by the
        // GLOBAL's own declaration name, not by any binding local to the walked function, and `rootOf`/
        // `elementTypeOf` only ever consult it AFTER `vars`/`fields` have both already missed — so a local
        // binding that shadows a global's bare name is resolved by that CHECK ORDER, exactly the same way
        // an implicit-self field shadow already is, never by clearing this table. A rebind has nothing to
        // say about it, same as `fields` immediately above.
        "globalTypes": .immutableIndex, "globalArrayElem": .immutableIndex,
        // ⟨0.33.1⟩ the SIBLING of `localFreeFns`, injected at construction the same way: bare free-fn
        // names shadowed only by a `#if`-gated declaration (no unconditional one exists). A rebind has
        // nothing to say about it — it is computed scan-wide/per-module in the Driver, not per-binding.
        "conditionallyShadowedFreeFns": .immutableIndex,
        // ⟨0.33.1⟩ the TYPE analogue of the row directly above, same reasoning: bare type names shadowed
        // only by a `#if`-gated declaration, scan-wide/per-Driver, never per-binding.
        "conditionallyShadowedTypes": .immutableIndex,
        "returns": .immutableIndex, "enumCaseValueType": .immutableIndex,
        "dynamicMemberTypes": .immutableIndex, "propertyWrapperTypes": .immutableIndex,
        "wrappedProps": .immutableIndex, "typeAliases": .immutableIndex,
        "opaqueSeqBuilders": .immutableIndex, "seqBuilderConcrete": .immutableIndex,
        "closureFields": .immutableIndex,
        // R96 — the REASSIGNABLE (`var`) subset of the row above, keyed by TYPE + property name and
        // built once in the Driver from every file's declarations. A local binding never reaches it:
        // the sole reader is `closurePropertyInvocation`, asked about an already-resolved receiver
        // type, and each caller gates on `isBoundLocal`/`rootOf` before it gets there.
        "mutableClosureFields": .immutableIndex,
        // MODULE names — this file's imports, and the modules the project itself defines. Keyed by a
        // MODULE, never by a binding: a local `let Foundation = …` does not make the qualifier a value,
        // and `isModuleQualifier` asks `vars`/`fields`/`localTypes` about exactly that at the use site
        // rather than mutating these.
        "importedModules": .immutableIndex, "projectModules": .immutableIndex,
        // The CANDOR_DEPS/--workspace chain (`depShadows`) — keyed by MODULE name (`pkg#leaf`), injected
        // once at construction exactly like the two rows above, and consulted the same way: a rebind of a
        // local name has nothing to say about which packages this SCAN chained.
        "deps": .immutableIndex,
        // ── outputs, accumulators and scope bookkeeping
        "enclosingType": .notPerBinding, "selfElementType": .notPerBinding,
        "calls": .notPerBinding, "directEffects": .notPerBinding, "unresolved": .notPerBinding,
        "why": .notPerBinding, "hosts": .notPerBinding, "cmds": .notPerBinding,
        "paths": .notPerBinding, "tables": .notPerBinding, "incompleteSurfaces": .notPerBinding,
        // SPEC §2 `fs` — a flat per-FUNCTION accumulator of read/write kinds, exactly like the
        // literal surfaces beside it. Not keyed by a binding name, so a shadow scope must neither
        // save nor clear it: a `let` rebinding a name says nothing about which disk verbs the
        // function called.
        "fsKinds": .notPerBinding,
        // Same shape as fsKinds: a flat per-FUNCTION accumulator (effect → directions), not keyed by a
        // binding name. A rebind says nothing about which sensor verbs the function called.
        "privacyKinds": .notPerBinding,
        // The deferred capture-ambiguity pair. Both are FUNCTION-scoped accumulators like `directEffects`
        // — nothing about them is keyed by a binding name, so a rebind is not their concern. What IS
        // their concern is that `resolveAmbiguousCapture` runs once after the whole body is walked, and
        // that is the collector's contract with Driver, not this file's.
        "ambiguousCapture": .notPerBinding,
        "determinateCapture": .notPerBinding,
        // CONSTANT PROVENANCE rung 3. Keyed by a BINDING name, so a rebind must drop it — `let p = home
        // + "/Desktop"` in one function must not charge a later `func f(_ p: String)`'s parameter the
        // Desktop key. Unscoped like `vars`: the collector walks one function at a time and `shadowName`
        // fires on every binder, so a stale entry cannot outlive its scope.
        "homeAnchoredLocals": .clearedOnRebind(scoped: false),
        // Path VALUES and a per-call flag — not keyed by any binding name.
        "resolvedHomePaths": .notPerBinding,
        "lastResolvedHomePath": .notPerBinding,
        "protoDispatches": .notPerBinding, "protoPropReads": .notPerBinding,
        "stringifyDispatches": .notPerBinding, "stringifyExternal": .notPerBinding,
        "deinitExternal": .notPerBinding, "propertyExternal": .notPerBinding,
        "globalReads": .notPerBinding,
        "propertyEdges": .notPerBinding, "callbackInvoked": .notPerBinding,
        // `localFuncs` is a DECLARATION set, not a binding fact: a nested `func` name suppresses the
        // same-named module-level free fn for the whole unit. Its leak direction is SUPPRESSION (a
        // loss), not fabrication, and it is unmeasured — recorded here so it is not mistaken for swept.
        "localFuncs": .notPerBinding,
        // R33's escape gate reads SYNTAX, not names: `bodyRootID` is the identity of the unit BODY node,
        // the stop condition for `constructionEscapes`' ancestor walk. Set once at init from the FnInfo
        // this collector was handed, never written again, so a rebind cannot reach it — and its failure
        // direction if it were ever wrong is a walk that climbs OUT of the unit and reads an enclosing
        // declaration's `return` as this construction's escape, i.e. a silent under-report.
        "bodyRootID": .notPerBinding,
        // Likewise a fact about the unit's own DECLARATION — whether its body IS a stored property's or
        // a global's initializer expression, in which case nothing built there is released there. Set
        // once at init; no binding name reaches it.
        "bodyIsStoredInitializer": .notPerBinding,
        "handledBinders": .notPerBinding, "typeScopes": .notPerBinding,
        "shadowScopes": .notPerBinding, "monoClosureParams": .notPerBinding,
        // R98 — a set of SYNTAX IDs, not names: which `if/guard case` conditions deferred their binder
        // clear to `visitPost` because the initializer mentions the bound name. Entered and removed by
        // the same node's visit/visitPost pair, so no binding name reaches it and a rebind cannot.
        "deferredPatternClears": .notPerBinding,
    ]

    // ── the DERIVATION ──────────────────────────────────────────────────────────────────────────────

    private static let collectorPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/candor-swift/CallCollector.swift")

    private func parsedCollector() throws -> ClassDeclSyntax {
        let src = try String(contentsOf: Self.collectorPath, encoding: .utf8)
        let tree = Parser.parse(source: src)
        final class Finder: SyntaxVisitor {
            var found: ClassDeclSyntax?
            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
                if node.name.text == "CallCollector" { found = node }
                return .visitChildren
            }
        }
        let f = Finder(viewMode: .sourceAccurate)
        f.walk(tree)
        return try XCTUnwrap(f.found, "no `class CallCollector` in \(Self.collectorPath.path)")
    }

    /// Instance stored properties, from the parse tree. `static` is excluded (a constant table, not
    /// per-instance state) and so is anything with an accessor block (a computed property stores
    /// nothing).
    private func storedProperties(_ cls: ClassDeclSyntax) -> [String] {
        var out: [String] = []
        for m in cls.memberBlock.members {
            guard let v = m.decl.as(VariableDeclSyntax.self) else { continue }
            if v.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" }) { continue }
            for b in v.bindings {
                guard let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                guard b.accessorBlock == nil else { continue }
                out.append(name)
            }
        }
        return out
    }

    /// The identifier TOKENS inside a named method's body — trivia (so comments) excluded, which is
    /// what stops a justification written in a comment from satisfying an assertion about the code.
    private func identifiers(inMethod name: String, of cls: ClassDeclSyntax) throws -> Set<String> {
        for m in cls.memberBlock.members {
            guard let f = m.decl.as(FunctionDeclSyntax.self), f.name.text == name, let body = f.body else { continue }
            var out: Set<String> = []
            for tok in body.tokens(viewMode: .sourceAccurate) where tok.tokenKind.isIdentifierToken {
                out.insert(tok.text)
            }
            return out
        }
        XCTFail("no method `\(name)` on CallCollector")
        return []
    }

    // ── the assertions ──────────────────────────────────────────────────────────────────────────────

    /// THE ONE THAT MAKES THE OBLIGATION DERIVED. A new name-keyed map cannot be added without a
    /// decision being written down about what a rebind does to it, and a deleted one cannot leave a
    /// stale claim behind.
    func testEveryStoredPropertyOfTheCollectorIsClassified() throws {
        let props = storedProperties(try parsedCollector())
        XCTAssertGreaterThan(props.count, 40,
                             "the parse found \(props.count) stored properties — that is too few to be "
                             + "the real class, so the DERIVATION is broken and every row below is vacuous")
        let classified = Set(Self.disposition.keys)
        let found = Set(props)
        XCTAssertEqual(found.subtracting(classified), [],
                       "a stored property of CallCollector is not classified in `disposition`. If it is "
                       + "keyed by a BINDING name, deciding what a rebind does to it is the whole of "
                       + "this file's job — seven defects have come from that decision being skipped.")
        XCTAssertEqual(classified.subtracting(found), [],
                       "`disposition` classifies a property that no longer exists — a stale entry hides "
                       + "the absence of a real one")
    }

    /// A CLASSIFICATION IS NOT A CLEAR. Saying a map is cleared on rebind and not writing the clear is
    /// exactly the failure mode this file exists to catch, one indirection along.
    func testEveryMapClassifiedAsClearedIsActuallyCleared() throws {
        let cls = try parsedCollector()
        let shadow = try identifiers(inMethod: "shadowName", of: cls)
        let typeOnly = try identifiers(inMethod: "clearBindingTypeOnly", of: cls)
        // the derivation's own control: these must be the real bodies, or the rows below pass vacuously
        XCTAssertTrue(shadow.contains("monoNames") && typeOnly.contains("vars"),
                      "the two clear paths were not found as expected — the extraction is broken")
        for (name, d) in Self.disposition {
            guard case .clearedOnRebind = d else { continue }
            XCTAssertTrue(shadow.contains(name) || typeOnly.contains(name),
                          "`\(name)` is classified as cleared on rebind but neither `shadowName` nor "
                          + "`clearBindingTypeOnly` mentions it")
        }
    }

    /// …AND A SCOPE IS SAVE **AND** RESTORE. `opaqueElem` shipped with the clear and without the save,
    /// and an inner block's monomorphized `let` then suppressed the CHA on the erased binding it
    /// shadowed for the rest of the function — a silent under-report produced by half a discipline.
    func testEveryMapClassifiedAsScopedIsBothSavedAndRestored() throws {
        let cls = try parsedCollector()
        let enter = try identifiers(inMethod: "enterShadowScope", of: cls)
        let leave = try identifiers(inMethod: "leaveShadowScope", of: cls)
        XCTAssertTrue(enter.contains("monoNames") && leave.contains("monoNames"),
                      "the two scope paths were not found as expected — the extraction is broken")
        for (name, d) in Self.disposition {
            switch d {
            case .clearedOnRebind(let scoped): if !scoped { continue }
            case .lexicallyScoped: break
            default: continue
            }
            XCTAssertTrue(enter.contains(name), "`\(name)` is classified as scoped but `enterShadowScope` does not save it")
            XCTAssertTrue(leave.contains(name), "`\(name)` is classified as scoped but `leaveShadowScope` does not restore it")
        }
    }

    /// A KEPT MAP MUST CARRY ITS REASON, and a defective one its measurement. An empty string is a
    /// classification nobody thought about, which is the state this file is trying to make impossible.
    func testEveryJudgementCarriesItsArgument() {
        for (name, d) in Self.disposition {
            switch d {
            case .deliberatelyKept(let why):
                XCTAssertGreaterThan(why.count, 40, "`\(name)` is kept with no argument for keeping it")
            case .knownDefect(let why):
                XCTAssertGreaterThan(why.count, 40, "`\(name)` is filed as defective with no description")
            case .lexicallyScoped(let why):
                XCTAssertGreaterThan(why.count, 40, "`\(name)` is scoped with no argument for the scope")
            default: continue
            }
        }
    }
}

private extension TokenKind {
    var isIdentifierToken: Bool { if case .identifier = self { return true }; return false }
}
