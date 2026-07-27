import XCTest
import Foundation

/// AN ENUM-CASE PAYLOAD BINDING IS A LOCAL, AND UNTIL `casePayloadLocals` NOTHING IN THE COLLECTOR
/// KNEW IT — the eighth instance of this repo's recurring shape, and the first one where the damage
/// showed up as a report ENTRY VANISHING rather than as an effect appearing.
///
/// `typeEnumCaseBinding` typed `case .active(let c)` when the case name was unambiguous and had exactly
/// one payload. Everything else — the `case let .active(c)` spelling, an ambiguous case name, every
/// multi-payload pattern — was left in NEITHER `vars` NOR `boundLocals`, i.e. invisible to every shadow
/// guard in `CallCollector`. Two fabrications followed:
///
///   a BARE READ of the name charged the enclosing type's same-named property
///                       (`AuthenticationInterceptor.adapt` → `AuthenticationInterceptor.credential`,
///                        `WebSocketRequest.didClose` → `Request.error`, and `TypeSyntax.identifier`
///                        reported as its own caller)
///   PASSING it as an argument charged a same-named FREE FUNCTION, because the fn-ref-as-argument rule
///                       can only skip arguments it can SEE are locals
///
/// AND THE SECOND ONE MANUFACTURED A DISCLOSURE. A phantom free-fn reference resolves to no local unit,
/// which is how the Driver decides a unit reaches code the scan cannot see — so `DecodingError.reason`
/// in vapor's `AbortError.swift`, whose only "unresolvable call" was the name of its own `case let
/// .dataCorrupted(ctx)` binding, carried an `invisible: [HTTPTypes]` it had no business carrying, and
/// `DecodingError.description` inherited it through `self.reason`. Both units are in the report ONLY
/// because of that disclosure, so removing the fabrication removes the entries. **A vanishing entry
/// looked like the cardinal sin and was the withdrawal of a fabricated disclosure** — which is why the
/// previous round reverted, correctly, rather than ship 305 changes it could not name.
///
/// THE SECOND-DIRECTION ROWS ARE FIRST IN THIS FILE BECAUSE THEY WERE WRITTEN FIRST, and two of them
/// changed the design rather than confirming it:
///   - `afterBlock` (swift-syntax's `IfConfigDiagnostic.asDiagnostic`) shows why the payload set is
///     LEXICALLY SCOPED: put these names in the function-wide `boundLocals` and the genuine property
///     read that follows the `if case` block loses its edge.
///   - `driverGuard` shows why `boundLocals` ITSELF is not scoped: `Driver` reads it AFTER the walk,
///     where a restored set is empty, so scoping it lets `if c { let loadIt = { }; loadIt() }` edge to
///     a same-named free function. Measured: that arm charges `driverGuard` Env.
/// Together they are why this is two sets and not one.
final class EnumPayloadBindingProcessTests: XCTestCase {

    private func scan(_ src: String, _ name: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return by
    }

    /// Every fabrication row has its RENAME CONTROL: an identical body with the binding renamed. That is
    /// the only thing separating "the name collided" from "this shape was never charged anyway".
    private static let src = """
    import Foundation
    func readEnv() -> String { ProcessInfo.processInfo.environment["X"] ?? "" }

    // a FREE FUNCTION whose name is also an enum payload binding below
    func ctx() { _ = readEnv() }
    // a free function NO binding shadows — the guard's other direction
    func loadIt() { _ = readEnv() }

    struct Ctx { let v: Int }
    enum E { case one(Ctx), two(Ctx, Ctx), three(String) }

    struct Holder {
        // EFFECTFUL properties whose names are also payload bindings below
        var ctx: String { readEnv() }
        var syntax: String { readEnv() }

        // ── the second direction, written first ────────────────────────────────────────────────────
        // the genuine property read AFTER the `if case` block (IfConfigDiagnostic.asDiagnostic)
        func afterBlock(_ e: E) -> String {
            if case .two(let syntax, _) = e { return "\\(syntax)" }
            return syntax
        }
        // a genuine free-fn reference nothing shadows
        func freeRef(_ xs: [Int]) { xs.forEach { _ in loadIt() } }
        // the Driver's guard is function-wide: an inner-block local still shadows the free fn
        func driverGuard(_ c: Bool) { if c { let loadIt = { }; loadIt() } }
        // a MATCHED CONSTANT is not a binding — `case .three(ctx)` (no `let` anywhere) parses to a
        // declReferenceExpr, so it is a READ of the enclosing type's `ctx` accessor and must stay one
        func matched(_ e: E) { switch e { case .three(ctx): break; default: break } }

        // ── the fabrications ───────────────────────────────────────────────────────────────────────
        // `case let .one(ctx)` — the `let` OUTSIDE the parens, the spelling nothing claimed
        func argRef(_ e: E) { switch e { case let .one(ctx): use(ctx); default: break } }
        func argRefRenamed(_ e: E) { switch e { case let .one(zzz): use(zzz); default: break } }
        func bareRead(_ e: E) -> String { switch e { case let .one(ctx): return "\\(ctx)"; default: return "" } }
        func bareReadRenamed(_ e: E) -> String { switch e { case let .one(zzz): return "\\(zzz)"; default: return "" } }
        // the MULTI-payload form: `let` INSIDE the parens, but the arity guard refuses to type it
        func multi(_ e: E) -> String { switch e { case .two(let ctx, _): return "\\(ctx)"; default: return "" } }
        func multiRenamed(_ e: E) -> String { switch e { case .two(let zzz, _): return "\\(zzz)"; default: return "" } }
    }
    func use(_ x: Any) {}
    """

    // ── the second direction ───────────────────────────────────────────────────────────────────────

    func testAGenuinePropertyReadAfterTheCaseBlockKeepsItsEdge() throws {
        let by = try scan(Self.src, "Payload")
        XCTAssertEqual(by["Holder.syntax"]?["inferred"] as? [String], ["Env"],
                       "the accessor must be effectful, or the row below is vacuous")
        XCTAssertEqual(by["Holder.afterBlock"]?["inferred"] as? [String] ?? [], ["Env"],
                       "`syntax` after the `if case` block IS the property — scoping the payload set is "
                       + "what keeps this edge, and the function-wide spelling of this fix dropped it")
        XCTAssertEqual(by["Holder.afterBlock"]?["calls"] as? [String] ?? [], ["Holder.syntax"])
    }

    func testAFreeFunctionReferenceNoBindingShadowsStillEdges() throws {
        let by = try scan(Self.src, "Payload")
        XCTAssertEqual(by["Holder.freeRef"]?["inferred"] as? [String] ?? [], ["Env"],
                       "the fn-ref-as-argument rule must still fire on a name that is NOT a local")
    }

    func testScopingIsConfinedToThePayloadSetSoTheDriverGuardStaysFunctionWide() throws {
        let by = try scan(Self.src, "Payload")
        XCTAssertNil(by["Holder.driverGuard"],
                     "`Driver` consults `boundLocals` AFTER the walk, so scoping THAT set would answer "
                     + "with an empty one and edge `loadIt()` to the free function — measured to charge "
                     + "Env on the arm that scoped it. The payload set is separate for exactly this.")
    }

    func testAMatchedConstantIsNotABinding() throws {
        let by = try scan(Self.src, "Payload")
        XCTAssertTrue((by["Holder.matched"]?["calls"] as? [String] ?? []).contains("Holder.ctx"),
                       "`case .three(ctx)` with no `let` anywhere parses to a declReferenceExpr, not a "
                       + "patternExpr — a value being COMPARED must not be swallowed as a name being "
                       + "bound. Relaxing the key to any bare-identifier argument loses this edge.")
        XCTAssertEqual(by["Holder.matched"]?["inferred"] as? [String] ?? [], ["Env"])
    }

    // ── the fabrications ───────────────────────────────────────────────────────────────────────────

    func testAPayloadBindingPassedAsAnArgumentIsNotAFreeFunctionReference() throws {
        let by = try scan(Self.src, "Payload")
        XCTAssertEqual(by["ctx"]?["inferred"] as? [String], ["Env"],
                       "the free function must be effectful, or the row is vacuous")
        XCTAssertNil(by["Holder.argRef"],
                     "`case let .one(ctx)` binds a local — `use(ctx)` charged BOTH the free fn `ctx` and "
                     + "the enclosing type's `ctx` accessor")
        XCTAssertNil(by["Holder.argRefRenamed"], "the rename control: same body, different binding name")
    }

    func testABareReadOfAPayloadBindingIsNotAnImplicitSelfPropertyRead() throws {
        let by = try scan(Self.src, "Payload")
        XCTAssertEqual(by["Holder.ctx"]?["inferred"] as? [String], ["Env"],
                       "the accessor must be effectful, or the rows are vacuous")
        XCTAssertNil(by["Holder.bareRead"], "`case let .one(ctx)` — the read is the local, not `self.ctx`")
        XCTAssertNil(by["Holder.bareReadRenamed"], "the rename control")
        XCTAssertNil(by["Holder.multi"],
                     "`case .two(let ctx, _)` — the arity guard refuses to TYPE a multi-payload pattern, "
                     + "which is exactly why the existence claim has to be recorded separately from it")
        XCTAssertNil(by["Holder.multiRenamed"], "the rename control")
    }

    /// THE DISCLOSURE THE FABRICATION MANUFACTURED, reduced from vapor's `AbortError.swift` — the repro
    /// the previous round could not explain, and the reason it reverted.
    ///
    /// `DecodingError.reason` has no effects. It was in the report at all because it carried
    /// `invisible: [HTTPTypes]`, and it carried that because `self.contextReason(ctx)` passed `ctx` — a
    /// `case let .dataCorrupted(ctx)` binding — which the fn-ref-as-argument rule emitted as an
    /// unqualified call to a free function `ctx`, which resolved to nothing, which is precisely the
    /// Driver's test for "this unit reaches code the scan cannot see". `description` reads `self.reason`
    /// and inherited the disclosure transitively. Both entries vanish when the phantom does, and
    /// **that is the fabrication being withdrawn, not a reach being lost**: there is no unresolvable
    /// call in either body once a local binding stops being mistaken for a function.
    func testAPhantomFreeFnRefDoesNotManufactureAnInvisibleDisclosure() throws {
        let src = """
        import BlindMod
        struct Ctx {}
        enum E { case one(Ctx) }
        extension E {
            var reason: String {
                switch self {
                case let .one(ctx): return help(ctx)
                }
            }
            var description: String { "d: \\(self.reason)" }
            func help(_ c: Ctx) -> String { return "x" }
        }
        """
        let by = try scan(src, "Vanish")
        XCTAssertNil(by["E.reason"],
                     "`ctx` is a local binding — an `invisible` disclosure built out of its name is a "
                     + "claim about a call this body does not make")
        XCTAssertNil(by["E.description"],
                     "…and the reader of `self.reason` inherited that disclosure transitively")
        XCTAssertNotNil(by["E.help"] == nil ? "pure" : nil,
                        "the sibling stays pure in both arms — this fixture's only moving part is the "
                        + "phantom")
    }
}
