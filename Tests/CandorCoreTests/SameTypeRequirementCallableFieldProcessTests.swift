import XCTest
import Foundation

/// **SOUNDNESS R243 (swift half) — a generic field whose callability is expressed by a SAME-TYPE
/// requirement was invisible, and the caller was ABSENT from `functions[]`.**
///
/// `struct Gen<F> { let op: F }` with `extension Gen where F == (Int) -> Bool { func run(_ v: [Int])
/// -> [Int] { v.filter(op) } }`: `Gen.run` had no row at all, while the same engine correctly disclosed
/// a directly-typed closure property (`dispatch:Direct.cb`) and a protocol-typed one. Ground truth
/// EXECUTED — the fixture really deletes a file through the stored closure.
///
/// **THE ROW'S FRAMING IS WRONG FOR THIS ENGINE, and the correction is the finding.** The row says the
/// discriminator is *where the constraint lives* — the extension rather than the type declaration.
/// Measured: `extension Gen where F: RunnerC` — a constraint on the EXTENSION, exactly where the row
/// says the defect is — is disclosed correctly and identically to the declaration-bound
/// `struct Gen<F: RunnerC>`. What discriminates in candor-swift is the KIND OF REQUIREMENT:
/// `recordTypeGenerics` read `.conformanceRequirement` (`F: P`) and dropped `.sameTypeRequirement`
/// (`F == …`) whole. The two axes look identical from the outside because Swift FORBIDS a same-type
/// requirement to a concrete type on the declaring type's own generic clause ("same-type requirement
/// makes generic parameter non-generic"), so `F == …` can only ever appear on an extension or a member.
///
/// **Five silent spellings, one requirement kind.** The function-typed side (A, B, E, F) and — a second
/// cardinal sin the row does not mention — the CONCRETE-typed side (J), where `extension Gen where
/// F == Wiper { func run() { op.doIt() } }` also had no row over a real file deletion.
///
/// Every fixture here is top-level `main.swift` code that compiles and RUNS (§E3).
final class SameTypeRequirementCallableFieldProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], why: [String: [String]], code: Int32, out: String) {
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
        var by: [String: [String]] = [:], why: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
            why[n] = ((f["unknownWhy"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, why, r.code, r.out + r.err)
    }

    /// The shared preamble: a real effect, plus the two spellings the row records as ALREADY CORRECT.
    private let prelude = """
    import Foundation
    let target = "/tmp/r243-probe"
    func wiper(_ i: Int) -> Bool { try? FileManager.default.removeItem(atPath: target); return true }
    func wipeVoid() { try? FileManager.default.removeItem(atPath: target) }
    """

    // ── 1. THE DEFECT, in the exact shape the row records ─────────────────────────────────────────
    func testASameTypeConstrainedCallableFieldIsDisclosedWhenInvoked() throws {
        let src = prelude + """

        public struct Gen<F> { public let op: F }
        extension Gen where F == (Int) -> Bool {
            public func run(_ v: [Int]) -> [Int] { return v.filter(op) }
        }
        _ = Gen(op: wiper).run([1])
        """
        let r = try scan(src, name: "R243", policy: "deny Unknown Gen.run\n")
        XCTAssertEqual(r.fns["Gen.run"], ["Unknown"],
                       "THE DEFECT: `v.filter(op)` really invokes the stored closure — the caller must "
                       + "not be ABSENT from functions[]: \(r.out)")
        XCTAssertEqual(r.why["Gen.run"], ["dispatch:Gen.op"],
                       "and it must disclose through the SAME channel a directly-typed closure property "
                       + "does — a hedge, never a guess at which closure was stored: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Unknown Gen.run`, SCOPED to the caller, must fail: \(r.out)")
    }

    // ── 2. EVERY SPELLING of a same-type requirement ──────────────────────────────────────────────
    // A: on the extension. B: through a function TYPEALIAS. E: on the METHOD rather than the extension.
    // F: direct `op()` invocation rather than through a HOF. J: the CONCRETE-typed side, a second
    // cardinal sin of the same requirement kind that the row does not name.
    func testEverySameTypeRequirementSpellingIsDisclosed() throws {
        let src = prelude + """

        public struct GenA<F> { public let op: F }
        extension GenA where F == (Int) -> Bool {
            public func run(_ v: [Int]) -> [Int] { return v.filter(op) }
        }
        public typealias PredB = (Int) -> Bool
        public struct GenB<F> { public let op: F }
        extension GenB where F == PredB {
            public func run(_ v: [Int]) -> [Int] { return v.filter(op) }
        }
        public struct GenE<F> { public let op: F }
        extension GenE {
            public func run(_ v: [Int]) -> [Int] where F == (Int) -> Bool { return v.filter(op) }
        }
        public struct GenF<F> { public let op: F }
        extension GenF where F == () -> Void { public func run() { op() } }
        public struct WiperJ { public func doIt() { wipeVoid() } }
        public struct GenJ<F> { public let op: F }
        extension GenJ where F == WiperJ { public func run() { op.doIt() } }

        _ = GenA(op: wiper).run([1]); _ = GenB(op: wiper).run([1]); _ = GenE(op: wiper).run([1])
        GenF(op: wipeVoid).run(); GenJ(op: WiperJ()).run()
        """
        let r = try scan(src, name: "R243Wide")
        for fn in ["GenA.run", "GenB.run", "GenE.run", "GenF.run"] {
            XCTAssertEqual(r.fns[fn], ["Unknown"],
                           "\(fn) invokes a same-type-constrained callable field and must not read "
                           + "silent-pure: \(r.out)")
        }
        XCTAssertEqual(r.fns["GenJ.run"], ["Fs"],
                       "the CONCRETE-typed side of the same requirement resolves EXACTLY, so it earns "
                       + "the real effect rather than a hedge: \(r.out)")
    }

    // ── 3. THE ALREADY-CORRECT SPELLINGS — the controls that correct the row's framing ────────────
    // Both were correct BEFORE the fix. They are what proves the discriminator is the REQUIREMENT KIND
    // and not where the constraint sits: C puts a CONFORMANCE requirement on the EXTENSION — the very
    // position the row blames — and it is disclosed precisely.
    func testAConformanceRequirementIsCorrectOnTheExtensionAndOnTheDeclaration() throws {
        let src = prelude + """

        public protocol RunnerC { func go() }
        public struct WipeC: RunnerC { public func go() { wipeVoid() } }
        public struct GenC<F> { public let op: F }
        extension GenC where F: RunnerC { public func run() { op.go() } }
        public struct GenD<F: RunnerC> { public let op: F
                                         public func run() { op.go() } }
        GenC(op: WipeC()).run(); GenD(op: WipeC()).run()
        """
        let r = try scan(src, name: "R243Conf")
        XCTAssertEqual(r.fns["GenC.run"], ["Fs"],
                       "a bound on the EXTENSION was ALREADY correct — this is the control that "
                       + "corrects the row's 'where the constraint lives' framing: \(r.out)")
        XCTAssertEqual(r.fns["GenD.run"], ["Fs"],
                       "and so was the declaration-bound form: \(r.out)")
    }

    // ── 4. OVER-CHARGE CONTROL: A FIELD HELD BUT NEVER INVOKED ────────────────────────────────────
    // The retype makes the field CALLABLE; it does not charge the holder. Returning or storing the
    // closure without calling it must stay out of `functions[]` entirely.
    // Instrumented: the same package invokes an identically-declared field, so a blanket absence from a
    // broken scan would fail the second assertion.
    func testAFieldHeldButNeverInvokedChargesNothing() throws {
        let src = prelude + """

        public struct Held<F> { public let op: F }
        extension Held where F == () -> Void { public func held() -> F { return op } }
        public struct Fired<F> { public let op: F }
        extension Fired where F == () -> Void { public func fire() { op() } }
        _ = Held(op: wipeVoid).held(); Fired(op: wipeVoid).fire()
        """
        let r = try scan(src, name: "R243Held", policy: "deny Unknown Held.held\n")
        XCTAssertNil(r.fns["Held.held"],
                     "reading a callable field is not invoking it — no charge: \(r.out)")
        XCTAssertEqual(r.fns["Fired.fire"], ["Unknown"],
                       "REACH INSTRUMENT: the retype DID fire in this package, so Held.held's absence "
                       + "is a measurement and not an inert scan: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Unknown Held.held` must PASS: \(r.out)")
    }

    // ── 5. GUARD: A SAME-TYPE REQUIREMENT TO A NON-FUNCTION TYPE IS AN EXACT BOUND, NOT A HEDGE ───
    // GUARD UNDER TEST: `l.isFunction != r.isFunction`, which decides which side names the param AND
    // whether the field is callable at all. A non-function right-hand side must feed `typeGenericBounds`
    // — an EXACT type — so `op.doIt()` resolves to the real unit and earns `Fs`.
    //
    // **The pure `op.n` arm alone does NOT test this guard, and the degradation is how that was found.**
    // Taking the function branch unconditionally left an `op.n`-only fixture GREEN, because a callable
    // field is only ever charged where it is INVOKED and a property read is not an invocation — a
    // control that survives its own degradation is testing nothing. The `Wiper` arm is what
    // discriminates: under the degradation `Ex.run` drops from `['Fs']` to the `['Unknown']` hedge and
    // `deny Fs Ex.run` flips 1 -> 0 over a real, executed file deletion — the degradation introduces a
    // cardinal sin, which is exactly what the guard is for. The pure arm is kept as the second half:
    // it pins that an exact bound to a PURE type still charges nothing.
    func testASameTypeRequirementToANonFunctionTypeResolvesExactlyRatherThanHedging() throws {
        let src = prelude + """

        public struct Payload { public let n: Int }
        public struct Plain<F> { public let op: F }
        extension Plain where F == Payload { public func run() -> Int { return op.n } }
        public struct Wiper { public func doIt() { wipeVoid() } }
        public struct Ex<F> { public let op: F }
        extension Ex where F == Wiper { public func run() { op.doIt() } }
        _ = Plain(op: Payload(n: 1)).run(); Ex(op: Wiper()).run()
        """
        let r = try scan(src, name: "R243Plain", policy: "deny Fs Ex.run\n")
        XCTAssertEqual(r.fns["Ex.run"], ["Fs"],
                       "`F == Wiper` is an EXACT type — `op.doIt()` must resolve to the real unit and "
                       + "charge Fs, not degrade to a callable-field hedge: \(r.out)")
        XCTAssertEqual(r.code, 1, "and `deny Fs Ex.run` must FAIL over the real file deletion: \(r.out)")
        XCTAssertNil(r.fns["Plain.run"],
                     "while an exact bound to a PURE type still charges nothing — no hedge acquired by "
                     + "a struct field that is only read: \(r.out)")
    }

    // ── 6. OVER-CHARGE CONTROL: THE HEDGE IS A HEDGE, NOT ANOTHER INSTANCE'S EFFECT ───────────────
    // The retype must never let one instance's stored closure be charged to a caller that stored a
    // different one. Two instances of the same declaration, one holding an effectful closure and one a
    // pure one: the pure caller gets the `Unknown` hedge every callable field earns, and MUST NOT get
    // `Fs`. This is the direction that would turn a disclosure into a fabricated effect claim.
    func testAPureClosureThroughTheSameShapeGetsTheHedgeAndNeverTheOtherInstancesEffect() throws {
        let src = prelude + """

        public struct Gen<F> { public let op: F }
        extension Gen where F == (Int) -> Bool {
            public func run(_ v: [Int]) -> [Int] { return v.filter(op) }
        }
        public struct Pure<F> { public let op: F }
        extension Pure where F == (Int) -> Bool {
            public func run(_ v: [Int]) -> [Int] { return v.filter(op) }
        }
        _ = Gen(op: wiper).run([1])
        _ = Pure(op: { $0 > 0 }).run([1])
        """
        let r = try scan(src, name: "R243Pure", policy: "deny Fs Pure.run\n")
        XCTAssertEqual(r.fns["Pure.run"], ["Unknown"],
                       "the pure arm earns the same §4 hedge a directly-typed closure property does — "
                       + "no more: \(r.out)")
        XCTAssertFalse((r.fns["Pure.run"] ?? []).contains("Fs"),
                       "and MUST NOT inherit the effectful instance's Fs — that would be a "
                       + "fabrication, not a disclosure: \(r.out)")
        XCTAssertEqual(r.fns["Gen.run"], ["Unknown"],
                       "REACH INSTRUMENT: the effectful arm is present in the same scan, so the "
                       + "assertion above is discriminating: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Fs Pure.run` must PASS: \(r.out)")
    }
}
