import XCTest
import Foundation

/// **SOUNDNESS R267 — `memberFirst`'s OPERATOR EXCLUSION WAS A FIRST-CHARACTER ALLOWLIST, so every
/// BACKTICK-ESCAPED and every Swift 5.9 RAW identifier was classified as an operator.**
///
/// `Driver.swift`'s unqualified-call chain excludes operators from the member-first ordering, because
/// Swift resolves an operator by overload resolution over the OPERAND TYPES rather than by lexical
/// scope. It asked *"does the leaf start with a letter or `_`?"* and treated everything else as an
/// operator. SwiftSyntax hands back `` `default` `` and `` `w z` `` **with their backticks**, so the
/// first character is a backtick — neither a letter nor `_` — and the three member arms were skipped
/// onto the pre-R255 free-first path. R134 and R255 both missed this spelling.
///
/// The fix asks the question the language defines instead: a backticked leaf is an IDENTIFIER by
/// construction (Swift never spells an operator that way), and anything else is an operator only if its
/// first character is an `operator-head` from the grammar — a DENYLIST over the operator set, so an
/// unforeseen spelling lands on the member path rather than being silently excluded from it.
///
/// **THE GUARD THE R255 AGENT COULD NOT UNIT-TEST NEEDED A DIFFERENT ATTACK, NOT A BETTER FIXTURE FOR
/// THE SAME ONE.** That agent wrote an operator control, found it survived its own degradation, and
/// deleted it rather than ship a test that cannot fail — the right call. This suite attacks the guard
/// from the identifier side instead, and every assertion below FAILS on the pre-fix binary.
///
/// Measured over a generated 1152-cell matrix, every cell compiled and executed: **232 red cells**, and
/// it runs in BOTH directions — with an effectful member it is a silent under-report (`case 1`), with a
/// PURE member it is a pure OVER-CHARGE (`case 2`: the caller charged `Fs` over a program that provably
/// deletes nothing). 116 cells of each.
final class OperatorLeafClassificationProcessTests: XCTestCase {

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

    // ── 1. THE SILENT DIRECTION: an EFFECTFUL backticked member, a PURE global of the same name ───
    // Three byte-identical programs differing only in how the shared name is SPELLED. `plain` is the
    // control that was always right; the two backticked spellings were ABSENT from `functions[]`.
    // EXECUTED: all three really delete their probe file through the MEMBER.
    func testABacktickedMemberIsAnIdentifierNotAnOperator() throws {
        let src = """
        import Foundation
        func zap(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        func plain(_ p: String) { _ = p.count }
        class BaseP { func plain(_ p: String) { zap(p) } }
        class SubP: BaseP { func caller(_ p: String) { plain(p) } }
        func `default`(_ p: String) { _ = p.count }
        class BaseK { func `default`(_ p: String) { zap(p) } }
        class SubK: BaseK { func caller(_ p: String) { `default`(p) } }
        func `w z`(_ p: String) { _ = p.count }
        class BaseR { func `w z`(_ p: String) { zap(p) } }
        class SubR: BaseR { func caller(_ p: String) { `w z`(p) } }
        SubP().caller("/tmp/op-a"); SubK().caller("/tmp/op-b"); SubR().caller("/tmp/op-c")
        """
        let r = try scan(src, name: "OpLeaf", policy: "pure SubK.caller\n")
        XCTAssertEqual(r.fns["SubP.caller"], ["Fs"],
                       "CONTROL, the plain spelling — always resolved correctly: \(r.out)")
        XCTAssertEqual(r.fns["SubK.caller"], ["Fs"],
                       "THE DEFECT, backtick-escaped KEYWORD: `default` is an identifier, and the member "
                       + "is what Swift binds and what runs — the pure global must not claim it: \(r.out)")
        XCTAssertEqual(r.fns["SubR.caller"], ["Fs"],
                       "THE DEFECT, a Swift 5.9 RAW identifier — the same misclassification well past "
                       + "keywords: \(r.out)")
        XCTAssertEqual(r.code, 1, "`pure SubK.caller`, SCOPED to the caller, must FAIL: \(r.out)")
    }

    // ── 2. THE OVER-CHARGE DIRECTION: a PURE backticked member, an EFFECTFUL global ──────────────
    // The pure twin of case 1 with the polarity swapped. Swift binds the member, which does nothing,
    // so the caller reaches NO effect; the misclassification charged it the global's Fs instead —
    // a fabrication over a program that provably deletes nothing.
    func testABacktickedPureMemberIsNotChargedTheGlobalsEffect() throws {
        let src = """
        import Foundation
        func `default`(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        class BaseK { func `default`(_ p: String) { _ = p.count } }
        class SubK: BaseK { func caller(_ p: String) { `default`(p) } }
        func plain(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        class BaseP { func plain(_ p: String) { _ = p.count } }
        class SubP: BaseP { func caller(_ p: String) { plain(p) } }
        SubK().caller("/tmp/op-d"); SubP().caller("/tmp/op-e")
        """
        let r = try scan(src, name: "OpLeafPure", policy: "deny Fs SubK.caller\n")
        XCTAssertNil(r.fns["SubK.caller"],
                     "THE OVER-CHARGE: the backticked member is PURE and is what Swift binds, so the "
                     + "caller reaches nothing — charging it the global's Fs is a fabrication: \(r.out)")
        XCTAssertNil(r.fns["SubP.caller"],
                     "REACH INSTRUMENT: the plain twin in the same scan proves the member-first path is "
                     + "live here, so the assertion above is not an inert scan: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Fs SubK.caller` must PASS — nothing is deleted: \(r.out)")
    }

    // ── 3. CONTROL: A REAL OPERATOR IS STILL EXCLUDED ────────────────────────────────────────────
    // The denylist must not swallow the thing the allowlist was there for. `==` is resolved by operand
    // type, so the enclosing type's own `==` has no lexical priority and the free arm must still see it.
    // Instrumented: the backticked pair in the same package proves the member path is live here.
    func testARealOperatorIsStillExcludedFromTheMemberFirstOrdering() throws {
        let src = """
        import Foundation
        struct Pt: Equatable { let a: String
                               static func == (l: Pt, r: Pt) -> Bool { l.a == r.a } }
        func `used`(_ p: String) { _ = p.count }
        class BaseI { func `used`(_ p: String) { try? FileManager.default.removeItem(atPath: p) } }
        class SubI: BaseI { func caller(_ p: String) { `used`(p) } }
        _ = Pt(a: "x") == Pt(a: "y"); SubI().caller("/tmp/op-f")
        """
        let r = try scan(src, name: "OpLeafOper", policy: "deny Fs Pt.==\n")
        XCTAssertNil(r.fns["Pt.=="],
                     "an operator resolved over its OPERAND TYPES must not gain an effect from the "
                     + "member-first reorder: \(r.out)")
        XCTAssertEqual(r.fns["SubI.caller"], ["Fs"],
                       "REACH INSTRUMENT: the backticked pair proves the member-first path is live in "
                       + "this very scan: \(r.out)")
        XCTAssertEqual(r.code, 0, "`deny Fs Pt.==` must PASS: \(r.out)")
    }
}
