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
        // ── known defective, measured and filed rather than patched
        "boundLocals": .knownDefect(
            "written by only 2 of the ~7 binder forms and never scoped; a `case let`/`catch` binder "
            + "registers no shadow, so a bare read of the name edges to the enclosing type's property "
            + "or to a same-named global. Three forms reproduced with rename controls. The obvious fix "
            + "(write it in `shadowName`, save it in `ShadowSave`) costs 305 report changes over 34 "
            + "real packages, including disclosed Unknowns disappearing — see the work queue."),
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
        "returns": .immutableIndex, "enumCaseValueType": .immutableIndex,
        "dynamicMemberTypes": .immutableIndex, "propertyWrapperTypes": .immutableIndex,
        "wrappedProps": .immutableIndex, "typeAliases": .immutableIndex,
        "opaqueSeqBuilders": .immutableIndex, "seqBuilderConcrete": .immutableIndex,
        "closureFields": .immutableIndex, "returnedNames": .immutableIndex,
        // ── outputs, accumulators and scope bookkeeping
        "enclosingType": .notPerBinding, "selfElementType": .notPerBinding,
        "calls": .notPerBinding, "directEffects": .notPerBinding, "unresolved": .notPerBinding,
        "why": .notPerBinding, "hosts": .notPerBinding, "cmds": .notPerBinding,
        "paths": .notPerBinding, "tables": .notPerBinding, "incompleteSurfaces": .notPerBinding,
        "protoDispatches": .notPerBinding, "protoPropReads": .notPerBinding,
        "stringifyDispatches": .notPerBinding, "stringifyExternal": .notPerBinding,
        "deinitExternal": .notPerBinding, "globalReads": .notPerBinding,
        "propertyEdges": .notPerBinding, "callbackInvoked": .notPerBinding,
        // `localFuncs` is a DECLARATION set, not a binding fact: a nested `func` name suppresses the
        // same-named module-level free fn for the whole unit. Its leak direction is SUPPRESSION (a
        // loss), not fabrication, and it is unmeasured — recorded here so it is not mistaken for swept.
        "localFuncs": .notPerBinding,
        "handledBinders": .notPerBinding, "typeScopes": .notPerBinding,
        "shadowScopes": .notPerBinding, "monoClosureParams": .notPerBinding,
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
            guard case .clearedOnRebind(let scoped) = d, scoped else { continue }
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
            default: continue
            }
        }
    }
}

private extension TokenKind {
    var isIdentifierToken: Bool { if case .identifier = self { return true }; return false }
}
