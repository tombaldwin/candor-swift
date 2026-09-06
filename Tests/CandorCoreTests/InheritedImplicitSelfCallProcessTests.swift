import XCTest
import Foundation

/// **SOUNDNESS R134 — an UNQUALIFIED (implicit-self) call to an INHERITED member resolved to NOTHING,
/// and the caller was ABSENT from `functions[]` under the "nothing hidden" clean bill.**
///
/// `class Sub: Base { func caller(_ p: String) { wipe(p) } }` with `wipe` declared on `Base`: every
/// resolution arm for an unqualified call keyed on the ENCLOSING type (`byQual`/`overloadedBases` on
/// `f.enclosingTypePath`/`f.enclosingType`), so nothing matched and no edge, no `Unknown` and no
/// `unresolved` was recorded. EXECUTED ground truth: the fixture below really deletes a file, and
/// before the fix `pure Sub.caller`, `deny Fs Sub.caller`, `deny Unknown Sub.caller` and
/// `deny Fs Unknown Sub.caller` ALL exited 0. A blanket `deny Fs` exited 1 only INCIDENTALLY, via
/// `Base.wipe`, never naming the caller — which is why a scoped policy is the discriminating form here.
///
/// The measured breadth was 13 of 18 executed spellings, not one. `super.wipe(p)`, `self.wipe(p)`, a
/// same-class `wipe(p)`, an inherited PROPERTY and an inherited SUBSCRIPT were already correct — those
/// five are the controls that pin this as the implicit-self METHOD spelling across an inheritance edge
/// and nothing else.
///
/// EVERY fixture in this file is top-level `main.swift` code that compiles and runs (§E3): an
/// absence-shaped assertion over a fixture that cannot compile is asserting something about nothing.
final class InheritedImplicitSelfCallProcessTests: XCTestCase {

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

    // ── 1. THE DEFECT, in the exact shape the row records ─────────────────────────────────────────
    func testInheritedMethodReachedByImplicitSelfChargesTheCaller() throws {
        let src = """
        import Foundation
        class Base { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
        class Sub: Base { func caller(_ p: String) { wipe(p) } }
        Sub().caller("/tmp/r134")
        """
        let r = try scan(src, name: "R134", policy: "pure Sub.caller\n")
        XCTAssertEqual(r.fns["Sub.caller"], ["Fs"],
                       "THE DEFECT: `wipe(p)` runs `Base.wipe`, which really deletes the file — the "
                       + "caller must not be ABSENT from functions[]: \(r.out)")
        XCTAssertEqual(r.code, 1, "a policy SCOPED to the caller must fail; a blanket `deny Fs` "
                       + "catches this only incidentally via Base.wipe: \(r.out)")
        XCTAssertFalse(r.out.contains("nothing hidden"),
                       "the clean bill must not be issued over the silence: \(r.out)")
    }

    // ── 2. EVERY SPELLING that crosses an inheritance edge ────────────────────────────────────────
    // 13 shapes, all measured SILENT before the fix, all executed (each deletes its own probe file in
    // the sweep fixture this table was derived from). A boundary drawn around the one shape in the row
    // would have missed twelve of them (§9 / §A.2).
    func testEveryInheritanceEdgeSpellingChargesTheCaller() throws {
        let src = """
        import Foundation
        func zap(_ p: String) { try? FileManager.default.removeItem(atPath: p) }

        // two-level Base -> Mid -> Sub
        class B5 { func wipe5(_ p: String) { zap(p) } }
        class M5: B5 {}
        class S5: M5 { func caller(_ p: String) { wipe5(p) } }
        // generic base
        class B6<T> { func wipe6(_ p: String) { zap(p) } }
        class S6: B6<Int> { func caller(_ p: String) { wipe6(p) } }
        // member declared in an EXTENSION of the base
        class B7 {}
        extension B7 { func wipe7(_ p: String) { zap(p) } }
        class S7: B7 { func caller(_ p: String) { wipe7(p) } }
        // protocol-extension default, struct conformer
        protocol P8 {}
        extension P8 { func wipe8(_ p: String) { zap(p) } }
        struct S8: P8 { func caller(_ p: String) { wipe8(p) } }
        // caller declared in an EXTENSION of the subclass
        class B9 { func wipe9(_ p: String) { zap(p) } }
        class S9: B9 {}
        extension S9 { func caller(_ p: String) { wipe9(p) } }
        // inherited CLASS method, unqualified from a static caller
        class B12 { class func wipe12(_ p: String) { zap(p) } }
        class S12: B12 { static func caller(_ p: String) { wipe12(p) } }
        // protocol-extension default reached through a CLASS hierarchy
        protocol P13 {}
        extension P13 { func wipe13(_ p: String) { zap(p) } }
        class B13: P13 {}
        class S13: B13 { func caller(_ p: String) { wipe13(p) } }
        // the call nested inside a CLOSURE
        class B14 { func wipe14(_ p: String) { zap(p) } }
        class S14: B14 { func caller(_ p: String) { [p].forEach { wipe14($0) } } }
        // ARGUMENT-LABELLED inherited call
        class B15 { func wipe15(at p: String) { zap(p) } }
        class S15: B15 { func caller(_ p: String) { wipe15(at: p) } }
        // a protocol requirement WITNESSED on the base class
        protocol P16 { func wipe16(_ p: String) }
        class B16: P16 { func wipe16(_ p: String) { zap(p) } }
        class S16: B16 { func caller(_ p: String) { wipe16(p) } }
        // conformance spelled on an EXTENSION of the struct
        protocol P17 {}
        extension P17 { func wipe17(_ p: String) { zap(p) } }
        struct S17 {}
        extension S17: P17 {}
        extension S17 { func caller(_ p: String) { wipe17(p) } }
        // a NESTED subclass
        class B18 { func wipe18(_ p: String) { zap(p) } }
        enum Outer { class S18: B18 { func caller(_ p: String) { wipe18(p) } } }

        let p = "/tmp/r134sweep"
        S5().caller(p); S6().caller(p); S7().caller(p); S8().caller(p); S9().caller(p)
        S12.caller(p); S13().caller(p); S14().caller(p); S15().caller(p); S16().caller(p)
        S17().caller(p); Outer.S18().caller(p)
        """
        let r = try scan(src, name: "R134Wide")
        for fn in ["S5.caller", "S6.caller", "S7.caller", "S8.caller", "S9.caller", "S12.caller",
                   "S13.caller", "S14.caller", "S15.caller", "S16.caller", "S17.caller",
                   "Outer.S18.caller"] {
            XCTAssertEqual(r.fns[fn], ["Fs"],
                           "\(fn) reaches a real file deletion through an inherited member and must "
                           + "not read silent-pure: \(r.out)")
        }
    }

    // ── 3. THE ALREADY-CORRECT SPELLINGS — the discriminating controls ─────────────────────────────
    // These four were correct BEFORE the fix and must stay correct. They are what makes the finding
    // "the implicit-self spelling across an inheritance edge" rather than "inheritance is broken".
    func testTheExplicitSpellingsAndTheAccessorPathStayCorrect() throws {
        let src = """
        import Foundation
        func zap(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        class B2 { func wipe2(_ p: String) { zap(p) } }
        class S2: B2 { func caller(_ p: String) { self.wipe2(p) } }
        class B3 { func wipe3(_ p: String) { zap(p) } }
        class S3: B3 { func caller(_ p: String) { super.wipe3(p) } }
        class S4 { func wipe4(_ p: String) { zap(p) }
                   func caller(_ p: String) { wipe4(p) } }
        class B10 { var probe = ""
                    var sink: Int { zap(probe); return 1 } }
        class S10: B10 { func caller(_ p: String) { probe = p; _ = sink } }
        class B11 { subscript(p: String) -> Int { zap(p); return 0 } }
        class S11: B11 { func caller(_ p: String) { _ = self[p] } }
        let p = "/tmp/r134ctl"
        S2().caller(p); S3().caller(p); S4().caller(p); S10().caller(p); S11().caller(p)
        """
        let r = try scan(src, name: "R134Ctl")
        for fn in ["S2.caller", "S3.caller", "S4.caller", "S10.caller", "S11.caller"] {
            XCTAssertEqual(r.fns[fn], ["Fs"], "\(fn) was already correct and must stay so: \(r.out)")
        }
    }

    // ── 4. OVER-CHARGE CONTROL: AN OVERRIDE WINS ──────────────────────────────────────────────────
    // GUARD UNDER TEST: the else-if ORDER. The sibling arms (`overloadedBases`, then the
    // `enclosingTypePath` `byQual` hit) run BEFORE the supertype climb, so a subclass that declares
    // its own `wipe` resolves to ITS OWN body and never to the base's. DEGRADATION CHECKED: moving the
    // climb ahead of the `enclosingTypePath` arm makes `Sub.caller` read `["Fs"]` and this test RED.
    //
    // The base's effect is Fs and the override is PURE, so the two are DISTINGUISHABLE (§4): a fix
    // that unioned base+override would show `Fs` here, and one that resolved only the base would too.
    func testAnOverrideWinsOverTheInheritedBody() throws {
        let src = """
        import Foundation
        class Base { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
        class Sub: Base {
            override func wipe(_ p: String) { _ = p.count }     // PURE override — really runs
            func caller(_ p: String) { wipe(p) }
        }
        Sub().caller("/tmp/r134ovr")
        """
        let r = try scan(src, name: "R134Ovr", policy: "deny Fs Sub.caller\n")
        XCTAssertNil(r.fns["Sub.caller"],
                     "the PURE override is what runs — charging it the base's Fs would be a "
                     + "fabrication: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Fs Sub.caller` must PASS: \(r.out)")
        XCTAssertEqual(r.fns["Base.wipe"], ["Fs"],
                       "instrument check — the effectful base body IS in this scan, so the nil above "
                       + "is a measurement and not an empty report: \(r.out)")
    }

    // ── 5. OVER-CHARGE CONTROL: A PURE INHERITED MEMBER CHARGES NOTHING ───────────────────────────
    // The climb is PRECISE-OR-NOTHING: it edges to a real unit, it does not assume the unit is
    // effectful. A subclass calling a pure inherited helper must stay out of `functions[]` entirely.
    // Instrumented: the same package holds an effectful inherited call, so a blanket absence caused by
    // a broken scan would take BOTH rows out and fail the second assertion.
    func testAPureInheritedMemberChargesTheCallerNothing() throws {
        let src = """
        import Foundation
        class PureBase { func helper(_ p: String) -> Int { p.count } }
        class PureSub: PureBase { func caller(_ p: String) { _ = helper(p) } }
        class FxBase { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
        class FxSub: FxBase { func caller(_ p: String) { wipe(p) } }
        PureSub().caller("/tmp/x"); FxSub().caller("/tmp/r134pure")
        """
        let r = try scan(src, name: "R134Pure", policy: "deny Fs PureSub.caller\n")
        XCTAssertNil(r.fns["PureSub.caller"],
                     "a pure inherited member must contribute nothing — no Unknown flood: \(r.out)")
        XCTAssertEqual(r.fns["FxSub.caller"], ["Fs"],
                       "REACH INSTRUMENT: the climb DID fire in this package, so PureSub.caller's "
                       + "absence is a measurement, not an inert scan: \(r.out)")
        XCTAssertEqual(r.code, 0, "no violation for the pure arm: \(r.out)")
    }

    // ── 6. OVER-CHARGE CONTROL: A NAME NO SUPERTYPE DECLARES RESOLVES TO NOTHING ──────────────────
    // GUARD UNDER TEST: `!inherited.isEmpty`. An unqualified call is ALSO how every unresolved std/C
    // free function is spelled, so the arm must not claim `resolved` when it edged nothing — otherwise
    // it swallows the C-native disclosure and the κ/`invisible` disclosure that sit after it.
    // DEGRADATION CHECKED: dropping `!inherited.isEmpty` (taking the arm and setting `resolved = true`
    // unconditionally whenever the enclosing type has any supertype) makes `Sub.f` lose its
    // `native:unlink` Unknown and this test RED.
    func testAnUnresolvedUnqualifiedCallInASubclassKeepsItsNativeDisclosure() throws {
        let src = """
        import Foundation
        class Base { func helper() -> Int { 1 } }
        class Sub: Base { func f(_ p: String) { unlink(p) } }
        Sub().f("/tmp/r134unlink")
        """
        let r = try scan(src, name: "R134Native", policy: "deny Unknown Sub.f\n")
        XCTAssertEqual(r.fns["Sub.f"], ["Unknown"],
                       "`unlink` is declared by no supertype — the climb must edge nothing and leave "
                       + "the C-native disclosure standing: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Unknown Sub.f` must still fail: \(r.out)")
    }

    // ── 7. OVER-CHARGE + UNDER-REPORT CONTROL: AN OVERLOADED INHERITED MEMBER ─────────────────────
    // GUARD UNDER TEST: the `overloadedBases` → `matchOverloads` route. An overloaded declaration's
    // qual carries a SIGNATURE SUFFIX, so plain `resolveQual("Base.run")` returns EMPTY when `Base`
    // declares `run()` beside `run(times:)` — the R32/R44 provided-member class, i.e. exactly the way
    // this fix would reintroduce the sin it closes. DEGRADATION CHECKED: replacing the
    // `overloadedBases` branch in `inheritedUnqualTargets` with a plain `resolveQual(base)` makes
    // `Sub.callsEffectful` vanish from `functions[]` and this test RED.
    //
    // Both directions are pinned in ONE fixture: the pure overload must not be charged the effectful
    // one's Fs, and the effectful one must not vanish.
    func testAnOverloadedInheritedMemberResolvesPreciselyAndNeverVanishes() throws {
        let src = """
        import Foundation
        class Base {
            func run() -> Int { 7 }
            func run(times: Int) { try? FileManager.default.removeItem(atPath: "/tmp/r134ovl") }
        }
        class Sub: Base {
            func callsPure() { _ = run() }
            func callsEffectful() { run(times: 1) }
        }
        Sub().callsPure(); Sub().callsEffectful()
        """
        let r = try scan(src, name: "R134Ovl", policy: "deny Fs Sub.callsPure\n")
        XCTAssertEqual(r.fns["Sub.callsEffectful"], ["Fs"],
                       "the effectful overload must resolve through matchOverloads, not be dropped by "
                       + "a signature-suffixed qual `resolveQual` cannot name: \(r.out)")
        XCTAssertNil(r.fns["Sub.callsPure"],
                     "arity discriminates: the nullary overload is pure and must not inherit its "
                     + "sibling's Fs: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Fs Sub.callsPure` must PASS: \(r.out)")
    }

    // ── 8. THE CLEAN BILL MUST NOT BE ISSUED OVER THE SILENCE ─────────────────────────────────────
    // R134's clean bill is part of the defect, not a side effect of it: the engine printed
    // "candor: nothing hidden — every effect sits where its name says it should." over a provable file
    // deletion whose caller it had dropped. Pinned separately from the effect assertion because the
    // two failed independently before the fix.
    func testTheCleanBillIsNotIssuedOverAnInheritedReach() throws {
        let src = """
        import Foundation
        class Base { func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
        class Sub: Base { func caller(_ p: String) { wipe(p) } }
        Sub().caller("/tmp/r134bill")
        """
        let r = try scan(src, name: "R134Bill")
        XCTAssertFalse(r.out.contains("nothing hidden"),
                       "a reach the engine now sees must displace the false-absolute bill: \(r.out)")
        XCTAssertEqual(r.fns["Sub.caller"], ["Fs"],
                       "REACH INSTRUMENT for the assertion above — the bill is gone BECAUSE the "
                       + "caller is now in functions[], not because the scan came back empty: \(r.out)")
        XCTAssertTrue(r.out.contains("Base.wipe"),
                      "and the summary the bill was covering must cite the reach: \(r.out)")
    }
}
