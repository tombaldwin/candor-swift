import XCTest
import Foundation

/// SOUNDNESS R344 — AN OPTIONAL PAYLOAD BOUND BY A `case` PATTERN WAS NEVER TYPED.
///
/// `if let h = o { h.run() }` typed `h` and charged. Every MATCH spelling of the same unwrap did not:
/// `switch o { case .some(let h) }`, `case let .some(h)`, the same with a `default:` arm, and
/// `if case let .some(h) = o` all left `h` untyped, so the enclosing function was ABSENT from
/// `functions[]` — a positive purity claim under SPEC §2 rule 3 — over a real file write. Measured on
/// one fixture with the spelling as the only variable, and both `deny Fs` and `pure` exited 0 with
/// nothing disclosed: no `unanalyzed`, no `unresolved`, absent entirely.
///
/// THE CAUSE WAS ALREADY WRITTEN DOWN, one comment above the site. `visitPost(SwitchCaseItemSyntax)`
/// says the pattern "is walked by `typeEnumCaseBinding` (which CLEARS the binding — `enumCaseValueType`
/// has nothing to say about `Optional.some`)", and the two branches that follow it answer only the
/// CALLABLE form (R178) and the CONTAINER form (R269). The CONCRETE nominal payload had no branch at
/// all. That is the same shape candor-rust closed as R185 on the same day, one engine over: the
/// dispatch route for an unwrap binder existed and the concrete one did not.
///
/// THE TWO SITES ARE FIXED TOGETHER AND BOTH ARE ASSERTED HERE. Fixing only `SwitchCaseItemSyntax`
/// left `if case let .some(h) = o` silent while three of four spellings turned green — which looks
/// like a finished job. The `if case` spelling reaches `MatchingPatternConditionSyntax` instead, and
/// it needed the new branch placed OUTSIDE that site's `casePayloadLocals` guard: probed rather than
/// reasoned, `typeEnumCaseBinding` CLAIMS the binder into that set during the pattern walk and then
/// has nothing to say about `Optional.some`, so the binder is claimed-but-UNTYPED and a guard meant to
/// stop a later pass UNDOING a real typing was skipping the one case that had none.
///
/// `pureSwitch` IS THE FABRICATION CONTROL and it is why the fix may widen typing at all: binding a
/// name out of an Optional TYPES it, it does not charge it. A pure payload through the same patterns
/// must stay absent, or this trades a silence for an over-report on one of the commonest shapes in
/// Swift.
final class OptionalPayloadMatchBinderProcessTests: XCTestCase {

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

    /// One PROBE PATH per arm so no arm's answer can be supplied by another's. `Pure` has the same
    /// `run()` selector as `Guard` and does nothing, so charging it is a fabrication rather than a
    /// conservative guess.
    private static let src = """
    import Foundation

    final class Guard { func run(_ p: String) { try? "x".write(toFile: p, atomically: true, encoding: .utf8) } }
    final class Pure { func run(_ p: String) -> Int { p.count } }

    final class Holder {
        var o: Guard?
        var p: Pure?

        func ifLet()      { if let h = o { h.run("/tmp/r344-a") } }
        func caseSomeLet() { switch o { case .some(let h): h.run("/tmp/r344-b"); case .none: break } }
        func caseLetSome() { switch o { case let .some(h): h.run("/tmp/r344-c"); case .none: break } }
        func caseDefault() { switch o { case .some(let h): h.run("/tmp/r344-d"); default: break } }
        func ifCaseLet()   { if case let .some(h) = o { h.run("/tmp/r344-e") } }

        func pureSwitch() -> Int { switch p { case .some(let h): return h.run("/tmp/r344-f"); case .none: return 0 } }
    }
    """

    func testEveryOptionalUnwrapSpellingBindsThePayloadType() throws {
        let by = try scan(Self.src, "R344")
        for arm in ["Holder.ifLet", "Holder.caseSomeLet", "Holder.caseLetSome",
                    "Holder.caseDefault", "Holder.ifCaseLet"] {
            guard let f = by[arm] else {
                return XCTFail("\(arm) is ABSENT from functions[] — a purity claim over a real write")
            }
            XCTAssertEqual((f["inferred"] as? [String])?.sorted(), ["Fs"],
                           "\(arm) unwraps a Guard and calls it; the SPELLING must not decide whether the effect is seen")
        }
    }

    func testAPurePayloadThroughTheSamePatternStaysPure() throws {
        let by = try scan(Self.src, "R344")
        XCTAssertNil(by["Holder.pureSwitch"],
                     "binding a name out of an Optional TYPES it, it does not CHARGE it — a pure payload must stay pure")
    }
}
