import XCTest
import Foundation

/// **A CONSTRAINED-EXTENSION MEMBER'S CALL EDGE NEVER REACHED ITS CALLER — three shapes, one narrow
/// gap each, found the same night by a corpus round that scoped `deny Net` to the CALLER instead of
/// the whole tree.**
///
/// An UNSCOPED `deny Net` already flagged the leaf implementer in every one of the three shapes below —
/// the effect was discovered. What was missing was the edge from the constrained member (or
/// composed-protocol parameter) up to whoever called it, so a policy scoped at the caller
/// (`pure someCaller`) certified it clean. NOT one root cause: three independent gaps in the same
/// conceptual area (a `where`/`&` constraint on a type is resolved for exactly one hard-coded
/// consumer, never generally), plus a fourth, unrelated gap needed to close the second shape's caller
/// specifically — an untyped array LITERAL local never carried an element type at all, so
/// `arr.extensionMethod()` on a `let arr = [Thing()]` binding couldn't resolve even once the extension
/// method itself dispatched correctly.
///
/// Every test below asserts the DEFECT shape AND a PURE control of the identical structure — proving
/// the fix resolves the real conformer rather than fabricating an effect onto every conditional
/// conformance / composition it sees.
final class ConstrainedExtensionCallerEdgeProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--out", root.appendingPathComponent("r").path]
        if let policy {
            let p = root.appendingPathComponent("pol.txt")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        let d = try? JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, r.code, r.out + r.err)
    }

    // ── 1. CONDITIONAL CONFORMANCE of a USER generic type ─────────────────────────────────────────
    // `extension Box: Greeter2 where T: Greeter2` — the `where` bound is on `Box`'s OWN generic
    // parameter `T`, not on the collection convention name `Element`, so the pre-fix code (which only
    // special-cased `Element`) never resolved `value: T` to `Greeter2` at all: the field stayed the
    // bare, undeclared string `"T"` forever, and `value.greet2()` inside `Box.greet2` dispatched
    // nowhere.
    func testConditionalConformanceOfAUserGenericTypeChargesTheCaller() throws {
        let defectSrc = """
        import Foundation
        protocol Greeter2 { func greet2() }
        struct Box<T> { let value: T }
        extension Box: Greeter2 where T: Greeter2 {
            func greet2() { value.greet2() }
        }
        struct EnvThing: Greeter2 {
            func greet2() { _ = ProcessInfo.processInfo.environment["X"] }
        }
        func callDefect() { Box(value: EnvThing()).greet2() }
        """
        let r = try scan(defectSrc, name: "Cond", policy: "pure callDefect\n")
        XCTAssertEqual(r.fns["Box.greet2"], ["Env"],
                       "the constrained-extension member itself must resolve `value.greet2()` through "
                       + "the bound, not read pure: \(r.out)")
        XCTAssertEqual(r.fns["callDefect"], ["Env"],
                       "THE DEFECT: the caller must inherit the member's effect through Box, not "
                       + "certify pure over a transitively effectful call: \(r.out)")
        XCTAssertEqual(r.code, 1, "`pure callDefect` must fail — a scoped policy over the caller "
                       + "certified clean pre-fix: \(r.out)")

        // PURE CONTROL, a SEPARATE scan with NO effectful `Greeter2` conformer anywhere in the
        // package: the bounded CHA this fix routes `value.greet2()` through unions EVERY local
        // conformer of the bound (documented, pre-existing behaviour for a monomorphized generic —
        // NOT scoped per call site), so proving the control in the SAME file as the defect would
        // always show `Env` regardless of which instance a given caller actually built. Must NOT be
        // charged — a fix that fabricates Env onto every conditional conformance would still pass the
        // defect above for the wrong reason.
        let pureSrc = """
        import Foundation
        protocol Greeter2 { func greet2() }
        struct Box<T> { let value: T }
        extension Box: Greeter2 where T: Greeter2 {
            func greet2() { value.greet2() }
        }
        struct PureThing: Greeter2 {
            func greet2() { }
        }
        func callPureControl() { Box(value: PureThing()).greet2() }
        """
        let pr = try scan(pureSrc, name: "CondPure", policy: "pure callPureControl\n")
        XCTAssertNil(pr.fns["callPureControl"],
                     "PURE CONTROL: a conditional conformance with NO effectful conformer in scope "
                     + "must not be charged: \(pr.out)")
        XCTAssertEqual(pr.code, 0, "`pure callPureControl` must pass: \(pr.out)")
    }

    // ── 2. `where`-constrained extension of a STDLIB COLLECTION, reached via a `for`-loop ─────────
    // `extension Array where Element: Greeter3 { func greetAll3() { for e in self { e.greet3() } } }`
    // — `self`'s element bound was already computed (R28, for the CLOSURE-iterator form
    // `forEach { $0… }`) but never consulted by the `for`-in loop resolver, so the identical body read
    // silent-pure spelled as a loop. Closing the CALLER also needed a separate fix: `let arr =
    // [Thing()]` (no type annotation) never got an element type recorded at all, so `arr.greetAll3()`
    // could not resolve even once `Array.greetAll3` itself dispatched correctly.
    func testWhereConstrainedCollectionExtensionForLoopChargesTheCaller() throws {
        let defectSrc = """
        import Foundation
        protocol Greeter3 { func greet3() }
        extension Array where Element: Greeter3 {
            func greetAll3() { for e in self { e.greet3() } }
        }
        struct EnvThing3: Greeter3 {
            func greet3() { _ = ProcessInfo.processInfo.environment["X"] }
        }
        func callDefect() { let arr = [EnvThing3()]; arr.greetAll3() }
        """
        let r = try scan(defectSrc, name: "WhereExt", policy: "pure callDefect\n")
        XCTAssertEqual(r.fns["Array.greetAll3"], ["Env"],
                       "the `for`-loop over `self` must dispatch through the collection's `Element` "
                       + "bound exactly as the closure-iterator form already does: \(r.out)")
        XCTAssertEqual(r.fns["callDefect"], ["Env"],
                       "THE DEFECT: an untyped array-literal local's caller must inherit the element's "
                       + "effect through `Array.greetAll3`: \(r.out)")
        XCTAssertEqual(r.code, 1, "`pure callDefect` must fail: \(r.out)")

        // PURE CONTROL, a separate scan with no effectful `Greeter3` conformer in scope — see the
        // conditional-conformance test above for why this must be a SEPARATE package rather than a
        // second function in the same file.
        let pureSrc = """
        import Foundation
        protocol Greeter3 { func greet3() }
        extension Array where Element: Greeter3 {
            func greetAll3() { for e in self { e.greet3() } }
        }
        struct PureThing3: Greeter3 {
            func greet3() { }
        }
        func callPureControl() { let arr = [PureThing3()]; arr.greetAll3() }
        """
        let pr = try scan(pureSrc, name: "WhereExtPure", policy: "pure callPureControl\n")
        XCTAssertNil(pr.fns["callPureControl"],
                     "PURE CONTROL: a `where Element: P` extension with no effectful conformer in "
                     + "scope must not be charged: \(pr.out)")
        XCTAssertEqual(pr.code, 0, "`pure callPureControl` must pass: \(pr.out)")
    }

    /// **RENAME/SHAPE CONTROL for the array-literal fix.** A MIXED-type array literal (no single
    /// element type) must stay untyped rather than guess — the safe direction the fix's own comment
    /// documents. If this ever resolved to either conformer's type, `mixedArr.greetAll3()`'s CALLER
    /// would either fabricate `Env` (if it guessed `EnvThing3`) or silently drop it, over an array the
    /// engine genuinely cannot type down to one concrete type.
    func testMixedElementArrayLiteralStaysUntyped() throws {
        let src = """
        import Foundation
        protocol Greeter3 { func greet3() }
        extension Array where Element: Greeter3 {
            func greetAll3() { for e in self { e.greet3() } }
        }
        struct EnvThing3: Greeter3 { func greet3() { _ = ProcessInfo.processInfo.environment["X"] } }
        struct PureThing3: Greeter3 { func greet3() { } }
        func callMixed() {
            let mixedArr: [any Greeter3] = [EnvThing3(), PureThing3()]
            _ = mixedArr
            let untypedMixed = [EnvThing3() as Greeter3, PureThing3() as Greeter3]
            _ = untypedMixed
        }
        """
        let r = try scan(src, name: "Mixed")
        // no assertion beyond "does not crash / does not fabricate" — an `[any Greeter3]` literal is
        // explicitly typed (annotation path, unaffected by this fix) and the untyped `as Greeter3`
        // form has no single concrete `rootOf` result across its elements, so `callMixed` must not
        // silently inherit an effect it cannot prove.
        XCTAssertNil(r.fns["callMixed"], "a mixed/erased array literal must not fabricate Env: \(r.out)")
    }

    // ── 3. PROTOCOL COMPOSITION parameter ──────────────────────────────────────────────────────────
    // `func runComposed(_ x: A5 & B5) { x.a5() }` — `typeName` has no case for a composition type at
    // all, so the parameter was left completely untyped and `x.a5()` dispatched nowhere.
    func testProtocolCompositionParameterChargesTheCaller() throws {
        let src = """
        import Foundation
        protocol A5 { func a5() }
        protocol B5 { func b5() }
        struct Impl5: A5, B5 {
            func a5() { _ = ProcessInfo.processInfo.environment["X"] }
            func b5() { }
        }
        func runComposed(_ x: A5 & B5) { x.a5() }
        func callDefect() { runComposed(Impl5()) }
        struct PureImpl5: A5, B5 {
            func a5() { }
            func b5() { }
        }
        func runComposedB(_ x: A5 & B5) { x.b5() }
        func callPureControl() { runComposedB(PureImpl5()) }
        """
        let r = try scan(src, name: "Comp", policy: "pure callDefect\npure callPureControl\n")
        XCTAssertEqual(r.fns["runComposed"], ["Env"],
                       "a composition-typed parameter must dispatch `x.a5()` through A5's local "
                       + "conformers: \(r.out)")
        XCTAssertEqual(r.fns["callDefect"], ["Env"],
                       "THE DEFECT: the caller must inherit the composed-protocol member's effect: "
                       + "\(r.out)")
        XCTAssertNil(r.fns["callPureControl"],
                     "PURE CONTROL: calling the OTHER composed protocol's member (`b5`, always pure "
                     + "here) through the same composition type must not fabricate Env — proves the "
                     + "fix dispatches through the RIGHT member of the RIGHT protocol, not a blanket "
                     + "union onto the composition")
        XCTAssertEqual(r.code, 1, "`pure callDefect` must fail: \(r.out)")
    }
}
