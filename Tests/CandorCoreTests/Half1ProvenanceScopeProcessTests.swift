import XCTest
import Foundation

/// HALF 1'S PROVENANCE CONJUNCT MUST NOT FIRE ON A LOCAL NAME.
///
/// `let c = build(); c.fetch()` discloses `Unknown[dispatch:untyped cross-package receiver]` when `build`
/// looks like a dependency factory. An idiomatic Swift call into a dependency is spelled BARE, so the
/// conjunct's whole job is telling a dependency's factory from one of our own names — and it only
/// excluded FREE functions. A bare call to a METHOD of the enclosing type, or to a nested `func`, or to
/// `sqrt`, therefore recorded dependency provenance and every later member call on the result disclosed.
///
/// Measured before the fix, instrumented over 14 real Swift targets: the conjunct binds 289 locals, led by
/// `rootOf` (16), `classifyItems`, `createFunction`, `parseMisplacedSpecifiers`, `expandMacros` — all
/// enclosing-type methods — then `sin`/`cos`/`atan2`/`sqrt`/`pow`. Not one is a dependency factory. After:
/// 289 -> 153 with the local-name widening, -> 123 with the libm block, and candor-swift's own 23 -> 2.
/// A hedge that is wrong every time teaches a consumer to ignore the channel; candor-rust narrowed the
/// same conjunct after measuring it fire on `max()`/`min()`.
///
/// THE DANGEROUS DIRECTION IS THE WIDENING, not the narrowing: every name added to the exclusion drops a
/// half-1 disclosure, and that disclosure is what stops an untyped cross-package receiver reading pure.
/// So the exclusion is scoped to the ENCLOSING type and its local supertypes — Swift's own bare-name
/// resolution — and `testASameNamedMethodOnAnUnrelatedTypeDoesNotExempt` is the fixture that forbids the
/// flat leaf set anyone would reach for first.
final class Half1ProvenanceScopeProcessTests: XCTestCase {

    private static let mark = "dispatch:untyped cross-package receiver"

    /// An app importing a COVERED package (the third conjunct), with a dep report that answers nothing —
    /// so every half-1 site either discloses or is silent, and nothing resolves to distract from it.
    private func scanChained(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import DepKit\n" + src, name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = try ProcessHarness.run(bin, ["--version"]).out
            .split(separator: "\n")[0].split(separator: " ")[1]
        let dep = root.appendingPathComponent("dep.json")
        try JSONSerialization.data(withJSONObject: [
            "candor": ["version": "candor-swift-\(v)", "spec": "0.23", "toolchain": "swiftsyntax"],
            "package": "DepKit",
            "functions": [["fn": "somethingElse", "hash": "DepKit#somethingElse", "inferred": ["Fs"]]],
        ] as [String: Any]).write(to: dep)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path],
                                       env: ["CANDOR_DEPS": dep.path])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.App.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return by
    }

    private func discloses(_ by: [String: [String: Any]], _ fn: String) -> Bool {
        ((by[fn]?["unknownWhy"] as? [String]) ?? []).contains(Self.mark)
    }

    /// EVERY ROW HERE HAS AN UNRESOLVABLE RETURN TYPE, and that is deliberate. The conjunct's FIRST
    /// exclusion (`returns[callee] == nil`) already covers a local name whose return type the engine can
    /// pin, so a fixture written with `-> Int` methods passes with the new guards mutated OUT — measured,
    /// and it is how the first version of this suite came to pass three mutants (standing bar item 8: a
    /// green test is not evidence until you have watched it go red). A tuple return and a Void return are
    /// both invisible to `recordReturn`, so these rows reach the new exclusions and nothing else.
    func testALocalNameIsNotADependencyFactory() throws {
        let by = try scanChained("""
        import Foundation
        struct Owner {
            func retTuple() -> (Int, String) { (1, "a") }
            func retVoid() { }
            // (a) bare calls to METHODS of the enclosing type
            func viaMethodTuple() { let c = retTuple(); _ = c.fetch() }
            func viaMethodVoid()  { let c = retVoid();  _ = c.fetch() }
            // (b) a bare call to a NESTED func
            func viaNested() {
                func helper() -> (Int, String) { (1, "a") }
                let c = helper()
                _ = c.fetch()
            }
            // (c) a bare call to a proven-pure stdlib value function
            func viaLibm(_ x: Double) { let c = sqrt(x); _ = c.fetch() }
            // (d) THE CONTROL: a genuine dependency factory must still disclose
            func viaDep() { let c = build(); _ = c.fetch() }
        }
        """)
        XCTAssertTrue(discloses(by, "Owner.viaDep"),
                      "the trigger must be live, or every row below is vacuous")
        for fn in ["Owner.viaMethodTuple", "Owner.viaMethodVoid", "Owner.viaNested", "Owner.viaLibm"] {
            XCTAssertFalse(discloses(by, fn), "\(fn): a local/stdlib name is not a dependency factory")
        }
    }

    /// An INHERITED method is callable bare too, so the exclusion climbs local supertypes.
    func testAnInheritedMethodIsAlsoALocalName() throws {
        let by = try scanChained("""
        class Base { func inheritedMake() -> (Int, String) { (1, "a") } }
        class Sub: Base {
            func viaInherited() { let c = inheritedMake(); _ = c.fetch() }
            func viaDep() { let c = build(); _ = c.fetch() }
        }
        """)
        XCTAssertTrue(discloses(by, "Sub.viaDep"))
        XCTAssertFalse(discloses(by, "Sub.viaInherited"))
    }

    /// THE SECOND FIXTURE, and it is what rules out the flat leaf set. `Unrelated` declares `build`, but a
    /// bare `build()` inside `Consumer` does not resolve to it — Swift would not compile that — so the
    /// dependency factory must still be disclosed. A leaf-keyed exclusion passes every row above and
    /// silently kills this one, which is the cardinal sin the rung exists to close.
    ///
    /// `Unrelated.build` declares NO return type deliberately: see the residual below for why that
    /// matters — with a return type this row cannot test the new guard at all.
    func testASameNamedMethodOnAnUnrelatedTypeDoesNotExempt() throws {
        let by = try scanChained("""
        struct Unrelated { func build() { } }
        struct Consumer {
            func viaDep() { let c = build(); _ = c.fetch() }
        }
        """)
        XCTAssertTrue(discloses(by, "Consumer.viaDep"),
                      "`build` belongs to an UNRELATED type — the exclusion is scoped to the enclosing "
                      + "type and its supertypes, never a flat set of every local member name")
    }

    /// RESIDUAL, PRE-EXISTING, AND FOUND BY THE FIXTURE ABOVE RATHER THAN BY READING THE CODE.
    ///
    /// The conjunct's FIRST exclusion, `returns[callee] == nil`, is meant to say "this bare name is a
    /// local function whose return type we know". But `returnsIdx` is keyed by BARE NAME across the whole
    /// package (`DeclCollector.recordReturn(_ name:)`), so ANY local function or method named `build`
    /// that declares a return type exempts a dependency's `build()` factory ANYWHERE in the package —
    /// the flat leaf set this suite's scoping exists to avoid, already shipped one conjunct earlier.
    ///
    /// NOT fixed here. Scoping `returnsIdx` is not a narrowing of this gate: the index is the local
    /// factory-return typing that `rootOf` runs on, so it needs its own A/B and its own second-direction
    /// fixture. Pinned as a test asserting TODAY's behaviour, so that when the index is scoped this row
    /// fails and whoever did it knows the disclosure is now reachable — the same instruction the write/read
    /// residual carries in candor-java.
    func testRESIDUALaLeafKeyedReturnTypeStillExemptsADependencyFactory() throws {
        let by = try scanChained("""
        struct Unrelated { func build() -> Int { 1 } }
        struct Consumer {
            func viaDep() { let c = build(); _ = c.fetch() }
        }
        """)
        XCTAssertFalse(discloses(by, "Consumer.viaDep"),
                       "IF THIS FAILS, `returnsIdx` has been scoped and the residual is closed — flip this "
                       + "assertion to XCTAssertTrue and delete this note. It is not a regression.")
    }
}
