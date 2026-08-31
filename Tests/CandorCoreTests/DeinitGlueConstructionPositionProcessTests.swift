import XCTest
import Foundation

/// **R33's deinit-glue only ever fired where the construction ROOTED A LOCAL BINDING.** Every other
/// position a construction can occupy — discarded (`_ = Ctor()`), a bare expression statement, a call
/// ARGUMENT, an ARRAY / DICTIONARY / TUPLE literal element, a STRUCT FIELD, a capture list, a
/// conditional binding (`if let` / `guard let` / `switch`), a tuple DESTRUCTURING, a ternary arm, a
/// receiver (`Ctor().member`) — was a SILENT UNDER-REPORT: the constructed value is created and
/// released inside the constructing function, its `deinit` runs there, and nothing said so. Not a
/// closure/existential shape at all (most of these positions contain no closure), so the binder-shape
/// framing of `DeinitGlueBinderShapeProcessTests` could not see it; the discriminator was POSITION.
///
/// MEASURED, ground truth EXECUTED (2026-08-31): each shape below was compiled and run with a `deinit`
/// that writes to stdout unbuffered, interleaved against `calling`/`returned` markers — every one
/// printed its `DEINIT` line BEFORE the constructing function returned. The escape controls printed
/// theirs only after the caller dropped the value. Against the pre-fix binary, all of the charged rows
/// here were ABSENT from `functions` entirely (no `Unknown`, no per-fn `incomplete`, no advisory) while
/// `let x = Ctor()` on the identical class charged `Fs`.
///
/// The fix states the rule ONCE, at the construction expression itself (`visit(FunctionCallExprSyntax)`
/// → `applyDeinitGlue`), and gates it with `constructionEscapes` — a lexical walk to the unit body
/// root. The three binder call sites were REMOVED rather than left beside it: two paths computing one
/// fact are free to disagree, which is how this vein opened in the first place.
///
/// **The escape gate is the load-bearing half** (candor-spec SOUNDNESS.md R49): rust's first prototype
/// of the analogous `Drop` fix went regression-green and was REVERTED on the A/B, fabricating 14 false
/// `Unknown`s on flate2 — `Compress::new`-style factories that CONSTRUCT AND RETURN the owner, whose
/// destructor runs in the CALLER. `testFactoriesThatReturnTheOwnerStayPure` is that control, in every
/// position; `testAPureTypeStaysAbsentInEveryConstructionPosition` is the fabrication control.
final class DeinitGlueConstructionPositionProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--out", root.appendingPathComponent("r").path]
        if let policy {
            let p = root.appendingPathComponent("deny.pol")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, r.code, r.out + r.err)
    }

    private static let loudPrelude = """
    import Foundation
    class Loud {
        let path: String
        init(_ path: String) { self.path = path }
        deinit { _ = try? Data(contentsOf: URL(fileURLWithPath: path)) }
    }
    func sink(_ x: Any) {}
    struct Holder { let g: Loud }
    """

    /// Every position that is NOT a local binding root. All ABSENT pre-fix; all `Fs` after.
    private static let positionBodies: [(String, String)] = [
        ("discardedUnderscore", #"_ = Loud("/etc/passwd")"#),
        ("bareExpressionStatement", #"Loud("/etc/passwd")"#),
        ("callArgument", #"sink(Loud("/etc/passwd"))"#),
        ("captureList", #"let f = { [g = Loud("/etc/passwd")] in _ = g.path }; f()"#),
        ("arrayLiteralElement", #"let xs = [Loud("/etc/passwd")]; _ = xs.count"#),
        ("structFieldArgument", #"let h = Holder(g: Loud("/etc/passwd")); _ = h.g.path"#),
        ("dictionaryLiteralValue", #"let d = ["k": Loud("/etc/passwd")]; _ = d.count"#),
        ("tupleLiteralElement", #"let t = (Loud("/etc/passwd"), 2); _ = t.1"#),
        ("receiverOfAMemberRead", #"_ = Loud("/etc/passwd").path"#),
        ("ifLetCondition", #"if let x = Loud("/etc/passwd") as Loud? { _ = x.path }"#),
        ("guardLetCondition", #"guard let x = Loud("/etc/passwd") as Loud? else { return }; _ = x.path"#),
        ("switchSubject", #"switch Loud("/etc/passwd") { case let l: _ = l.path }"#),
        ("tupleDestructuring", #"let (a, b) = (Loud("/etc/passwd"), 1); _ = a.path; _ = b"#),
        ("ternaryArm", #"let c = true; let x = c ? Loud("/etc/passwd") : Loud("/tmp/o"); _ = x.path"#),
        ("bareInDefer", #"defer { _ = Loud("/etc/passwd") }; _ = 1"#),
        ("appendedToALocalArray", #"var xs: [Loud] = []; xs.append(Loud("/etc/passwd")); _ = xs.count"#),
    ]

    /// THE DEFECT — sixteen construction positions, each its own function, each measured silent-pure
    /// against the pre-fix binary and each proven by execution to run the `deinit` before returning.
    func testEveryConstructionPositionChargesTheDeinit() throws {
        let bodies = Self.positionBodies.map { "func \($0.0)() { \($0.1) }" }.joined(separator: "\n")
        let r = try scan(Self.loudPrelude + "\n" + bodies, name: "Positions", policy: "deny Fs\n")
        for (name, body) in Self.positionBodies {
            XCTAssertEqual(r.fns[name], ["Fs"],
                           "`\(body)` constructs a Loud that is released before \(name) returns — its "
                           + "deinit performs Fs HERE. Absent means an affirmative purity claim: \(r.out)")
        }
        XCTAssertEqual(r.code, 1, "a scoped deny must fail over these: \(r.out)")
    }

    /// FABRICATION CONTROL — the identical sixteen positions over a class with NO `deinit` at all.
    /// The construction hook fires on every one of them; not one may gain an effect.
    func testAPureTypeStaysAbsentInEveryConstructionPosition() throws {
        let prelude = """
        import Foundation
        class Quiet {
            let path: String
            init(_ path: String) { self.path = path }
        }
        func sink(_ x: Any) {}
        struct Holder { let g: Quiet }
        """
        let bodies = Self.positionBodies
            .map { "func \($0.0)() { \($0.1.replacingOccurrences(of: "Loud", with: "Quiet")) }" }
            .joined(separator: "\n")
        let r = try scan(prelude + "\n" + bodies, name: "PurePositions", policy: "deny Fs\n")
        for (name, _) in Self.positionBodies {
            XCTAssertNil(r.fns[name], "\(name) constructs a type with no deinit — it must stay ABSENT, "
                         + "not gain a fabricated effect from the construction hook: \(r.out)")
        }
        XCTAssertEqual(r.code, 0, "nothing here performs Fs: \(r.out)")
    }

    /// THE R49 CONTROL — the case that reverted rust's first prototype of this same fix. A function
    /// that CONSTRUCTS AND RETURNS the owner does not run its deinit; charging it fabricates. Measured
    /// by execution: the `DEINIT` line prints only after the CALLER releases the value.
    func testFactoriesThatReturnTheOwnerStayPure() throws {
        let src = Self.loudPrelude + """

        func returnsCtorDirectly() -> Loud { return Loud("/etc/passwd") }
        func returnsCtorImplicitly() -> Loud { Loud("/etc/passwd") }
        func returnsViaBinding() -> Loud { let x = Loud("/etc/passwd"); return x }
        func returnsViaAnnotatedBinding() -> Loud? { let x: Loud? = Loud("/etc/passwd"); return x }
        func returnsInsideAnArray() -> [Loud] { return [Loud("/etc/passwd")] }
        func returnsInsideAStruct() -> Holder { return Holder(g: Loud("/etc/passwd")) }
        func returnsViaTupleDestructuring() -> Loud { let (a, _) = (Loud("/etc/passwd"), 1); return a }
        func storesIntoAMemberOfAParameter(_ h: Box) { h.g = Loud("/etc/passwd") }
        func storesIntoASubscript(_ d: inout [String: Loud]) { d["k"] = Loud("/etc/passwd") }
        class Box { var g: Loud? = nil }
        """
        let r = try scan(src, name: "Escapes", policy: "deny Fs\n")
        for fn in ["returnsCtorDirectly", "returnsCtorImplicitly", "returnsViaBinding",
                   "returnsViaAnnotatedBinding", "returnsInsideAnArray", "returnsInsideAStruct",
                   "returnsViaTupleDestructuring", "storesIntoAMemberOfAParameter",
                   "storesIntoASubscript"] {
            XCTAssertNil(r.fns[fn], "\(fn) hands the constructed value OUT of its scope — the deinit "
                         + "runs at the caller, so charging it here is the over-charge direction that "
                         + "reverted rust's R49 prototype on flate2: \(r.out)")
        }
    }

    /// STORED DESTINATIONS — the three shapes found FABRICATING on the corpus by the first cut of this
    /// fix, each closed and each pinned here. Asserted as an EXACT charged set rather than as a list of
    /// `XCTAssertNil`s, because a nil-check over a name the scan never emits passes for the wrong
    /// reason: `localHoldsAndReleases` proves in the same document that this scan can and does charge.
    ///
    ///  · a stored PROPERTY initializer (`let g = Loud(…)`) — MEASURED on Kingfisher, where four
    ///    `AnimatedImageView()` property initializers charged `GIFHeavyViewController`'s synthesized
    ///    init the `Unknown` of deinits that run when the VIEW CONTROLLER dies. The unit's body IS the
    ///    initializer expression, so the ancestor walk stops before reaching the binding that would say
    ///    "stored" — the whole-body `bodyIsStoredInitializer` check exists for exactly this.
    ///  · a file-level GLOBAL (`let g = Loud(…)`) — same mechanism; MEASURED on swift-crypto's
    ///    `emptyStorage`.
    ///  · IMPLICIT SELF in an `init` (`token = Loud(…)`, no `self.`) — MEASURED on Alamofire's
    ///    `StreamOf.Iterator.init`. Read as an assignment to a local, this charged the initializer for
    ///    a `deinit` that runs when the ITERATOR dies. A bare identifier is only a local if this body
    ///    actually binds it.
    func testStoredDestinationsDoNotChargeTheWritingScope() throws {
        let src = Self.loudPrelude + """

        final class Owner {
            let g = Loud("/etc/passwd")
            let many = [Loud("/etc/passwd"), Loud("/etc/passwd")]
            func touch() { _ = g.path }
        }
        let globalLoud = Loud("/etc/passwd")
        let globalMany = [Loud("/etc/passwd")]
        func localHoldsAndReleases() { let x = Loud("/etc/passwd"); _ = x.path }
        """
        let r = try scan(src, name: "Stored", policy: "deny Fs\n")
        let charged = Set(r.fns.filter { $0.value.contains("Fs") }.keys)
        XCTAssertEqual(charged, ["Loud.deinit", "localHoldsAndReleases"],
                       "only the deinit's own body and the one function that genuinely releases a "
                       + "constructed value may carry Fs. A stored property and a global both hand the "
                       + "value to something that outlives the writing scope: \(r.out)")
    }

    /// IMPLICIT SELF in an initializer — the Alamofire `StreamOf.Iterator.init` shape. `token =
    /// Loud(…)` with no `self.` is an assignment to a FIELD, so the value lives as long as the
    /// instance; read as an assignment to a local it charged the initializer for a `deinit` that
    /// cannot run there. All three declaration shapes are asserted, because the guard is about the
    /// NAME not resolving to a local binder and nothing else about them differs — each one was
    /// confirmed charged against a build with the guard removed, and the three separately confirmed
    /// that a `struct` init, a `let` field and an Optional `var` field all reach it.
    func testImplicitSelfFieldWriteDoesNotChargeTheInitializer() throws {
        let src = Self.loudPrelude + """

        struct Wrap {
            private let token: Loud
            private var n: Int
            init(_ n: Int) { self.n = n; token = Loud("/etc/passwd") }
        }
        final class Held {
            let token: Loud
            init() { token = Loud("/etc/passwd") }
        }
        final class OptionallyHeld {
            var token: Loud?
            init() { token = Loud("/etc/passwd") }
        }
        func localHoldsAndReleases() { let x = Loud("/etc/passwd"); _ = x.path }
        """
        let r = try scan(src, name: "ImplicitSelf", policy: "deny Fs\n")
        let charged = Set(r.fns.filter { $0.value.contains("Fs") }.keys)
        XCTAssertEqual(charged, ["Loud.deinit", "localHoldsAndReleases"],
                       "a bare `token = Loud(…)` inside an initializer stores onto the instance — the "
                       + "deinit runs when the INSTANCE dies, not when the initializer returns: \(r.out)")
    }

    /// The SHADOW control for the implicit-self rule above. A body that really does bind the name must
    /// keep being charged — the fix must distinguish "bare identifier" from "field", not silence both.
    ///
    /// The ASSIGNMENT is the only construction in this body, deliberately. Written first with `var
    /// token = Loud(…)` as the binder, this test passed with the local-shadow check AND without it: the
    /// binder's own construction carried the `Fs` either way, so the assertion could not see which
    /// answer the assignment got. It discriminates now because the binder builds nothing.
    func testALocalShadowingAFieldNameIsStillCharged() throws {
        let src = Self.loudPrelude + """

        final class Owner {
            var token: Loud?
            func rebinds() {
                var token: Loud? = nil
                token = Loud("/etc/passwd")
                _ = token?.path
            }
        }
        """
        let r = try scan(src, name: "Shadow", policy: "deny Fs\n")
        XCTAssertEqual(r.fns["Owner.rebinds"], ["Fs"],
                       "`token` here is a LOCAL that shadows the field of the same name — the value it "
                       + "is assigned is released when `rebinds` returns: \(r.out)")
    }
}
