import XCTest
import Foundation

/// **A MODULE-SCOPE FUNCTION WITH THE SAME NAME AS A MEMBER OF `self` CLAIMED THE CALL, and the caller
/// was ABSENT from `functions[]`.** (Row id to be allocated — the greppable marker in `Driver.swift` is
/// `SOUNDNESS R255`.)
///
/// `func wipe(_:)` at module scope beside `class Base { func wipe(_:) }`: an unqualified `wipe(p)` inside
/// a subclass, or inside the declaring class itself, resolved to the module-scope function. Where that
/// function is pure and the member is effectful, the caller had NO ROW — a real, EXECUTED file deletion
/// certified silent-pure while the pure global was charged in its place. Found by widening past
/// SOUNDNESS R134 (§9): R134's climb is the LAST arm in the unqualified chain, so it never sees a call
/// the free-function arm has already claimed.
///
/// **SWIFT'S RULE IS SETTLED BY THE COMPILER, not by judgement.** Unqualified lookup stops at the
/// innermost scope holding the name and never widens to module scope. A program where the member exists
/// but its signature does not match DOES NOT COMPILE — `error: use of 'wipeC' refers to instance method
/// rather than global function 'wipeC' in module 'shadow'` — so there is no arity-mismatch fallback to
/// preserve, and reaching the global requires spelling the module (`shadow.wipeC(p)`), which is not an
/// unqualified call. That uncompilable third case is deliberately NOT a test here: a control whose
/// fixture cannot compile is no evidence (§E3). It is recorded as the compiler's answer instead.
///
/// **OPERATORS ARE THE EXCEPTION, AND THAT GUARD IS CORPUS-COVERED, NOT UNIT-COVERED — a stated gap,
/// not a claimed control.** Swift resolves an operator by overload resolution over the OPERAND TYPES,
/// not by lexical scope, so the enclosing type's own `==` has no priority; `Driver.swift`'s `memberFirst`
/// excludes them. Measured on Kingfisher: without the exclusion, three `KFImage.Context` rows leave
/// `functions[]` and `Source.==` LOSES its `Unknown` — a disclosure loss introduced by the very change
/// that closes one. **Three attempts at a minimal in-repo fixture all FAILED to reach that arm** — a
/// typed receiver (`l.a == r.a`), an enum payload binding, and a protocol-typed payload beside a
/// top-level `func ==` each resolve through a different path, and each one PASSED with the guard
/// degraded, i.e. tested nothing. Rather than ship a control that survives its own degradation, the
/// evidence for that guard is recorded as what it is: a 16-package A/B, reproducible by flipping
/// `memberFirst` to `true` and re-scanning Kingfisher. Anyone who can minimise it should add the test.
final class ShadowedMemberPrecedenceProcessTests: XCTestCase {

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

    // ── 1. THE DEFECT, both spellings ─────────────────────────────────────────────────────────────
    // The global is PURE and the member is EFFECTFUL, so the two are distinguishable (§4): binding the
    // wrong one produces silence, binding the right one produces Fs. EXECUTED: the fixture really
    // deletes both probe files, so the member is what runs in both arms.
    func testAMemberOfSelfBeatsAModuleScopeFunctionOfTheSameName() throws {
        let src = """
        import Foundation
        func zap(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        func wipeA(_ p: String) { _ = p.count }                 // PURE global, shadowed
        class BaseA { func wipeA(_ p: String) { zap(p) } }      // EFFECTFUL member — this is what runs
        class SubA: BaseA { func caller(_ p: String) { wipeA(p) } }
        func wipeB(_ p: String) { _ = p.count }                 // PURE global, shadowed
        class OwnB { func wipeB(_ p: String) { zap(p) }
                     func caller(_ p: String) { wipeB(p) } }
        SubA().caller("/tmp/sh-a"); OwnB().caller("/tmp/sh-b")
        """
        let r = try scan(src, name: "Shadow", policy: "pure SubA.caller\n")
        XCTAssertEqual(r.fns["SubA.caller"], ["Fs"],
                       "THE DEFECT, inherited spelling: the member is what Swift binds and what runs — "
                       + "the pure global must not claim the call: \(r.out)")
        XCTAssertEqual(r.fns["OwnB.caller"], ["Fs"],
                       "THE DEFECT, own-class spelling — the same question one arm over: \(r.out)")
        XCTAssertEqual(r.code, 1, "`pure SubA.caller`, SCOPED to the caller, must fail: \(r.out)")
    }

    // ── 3. CONTROL: A FREE FUNCTION THE TYPE DOES NOT SHADOW IS STILL RESOLVED ────────────────────
    // The reorder must not swallow ordinary free-function calls made from inside a type body. A caller
    // in a class that declares NO member of that name must still reach the global's effects.
    // Instrumented: the same package contains a shadowed pair, so the reorder is proven live here.
    func testAnUnshadowedFreeFunctionCallFromInsideATypeStillResolves() throws {
        let src = """
        import Foundation
        func zap(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        func lonely(_ p: String) { zap(p) }                     // no member shadows this
        class Plain { func caller(_ p: String) { lonely(p) } }
        func shadowed(_ p: String) { _ = p.count }
        class Shadower { func shadowed(_ p: String) { zap(p) }
                         func caller(_ p: String) { shadowed(p) } }
        Plain().caller("/tmp/sh-c"); Shadower().caller("/tmp/sh-d")
        """
        let r = try scan(src, name: "ShadowFree", policy: "deny Fs Plain.caller\n")
        XCTAssertEqual(r.fns["Plain.caller"], ["Fs"],
                       "an unshadowed free function called from inside a type must still resolve — the "
                       + "reorder must not swallow the ordinary case: \(r.out)")
        XCTAssertEqual(r.fns["Shadower.caller"], ["Fs"],
                       "REACH INSTRUMENT: the shadowed pair in the same package proves the member-first "
                       + "path is live here, so the assertion above is not an inert scan: \(r.out)")
        XCTAssertEqual(r.code, 1, "`deny Fs Plain.caller` must FAIL: \(r.out)")
    }

    // ── 4. OVER-CHARGE CONTROL: THE MEMBER'S EFFECT IS NOT FABRICATED ONTO THE GLOBAL'S CALLERS ───
    // The reverse direction: a caller at MODULE scope (not inside the type) calling the same name gets
    // the GLOBAL, not the member. Distinguishable effects — the global does Env, the member does Fs.
    func testAModuleScopeCallerStillGetsTheGlobalNotTheMember() throws {
        let src = """
        import Foundation
        func dual(_ p: String) { _ = ProcessInfo.processInfo.environment[p] }   // GLOBAL: Env
        class Holder { func dual(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
                       func inside(_ p: String) { dual(p) } }
        func outside(_ p: String) { dual(p) }
        outside("/tmp/sh-e"); Holder().inside("/tmp/sh-f")
        """
        let r = try scan(src, name: "ShadowOut", policy: "deny Fs outside\n")
        XCTAssertEqual(r.fns["outside"], ["Env"],
                       "a module-scope caller is not inside the type — it must get the GLOBAL's Env and "
                       + "NOT the member's Fs: \(r.out)")
        XCTAssertEqual(r.fns["Holder.inside"], ["Fs"],
                       "while the caller INSIDE the type gets the member's Fs — the two directions in "
                       + "one scan: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Fs outside` must PASS: \(r.out)")
    }
}
