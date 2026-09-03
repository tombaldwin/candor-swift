import XCTest
import Foundation

/// R180 — ⟨0.35⟩ AT A PROTOCOL DISPATCH SITE, AND WHY THE FIX THE ROW ASKED FOR IS THE WRONG ONE.
///
/// The row reads: *"swift fails ⟨0.35⟩(b)'s third conjunct — `Widget.fire` is `['Unknown']`
/// `unresolved: true` with NO `unknownWhy`"*, with the remedy *"emit `dispatch:<Protocol>.<method>`"*.
/// The observation is exact. The conclusion does not follow, and this file is the measurement rather
/// than the argument, because a row is not evidence until someone tries to break it.
///
/// **⟨0.35⟩ IS A DISJUNCTION AND THIS ENGINE TAKES BRANCH (a).** The clause: the calling function's
/// `inferred` MUST either **(a)** include that implementor's own effects, or **(b)** contain `Unknown`
/// with `unresolved: true` and a `callback:`/`dispatch:` `unknownWhy`. `Driver`'s conformer CHA edges to
/// every conformer's unit when they all resolve, and falls to `direct: Unknown` +
/// `dispatch:<Proto>.<member>` only when one does not — i.e. it implements both branches and prefers the
/// better one. (b)'s conjuncts bind an engine that took (b).
///
/// `testTheClauseToggleDoesNotReproduce` instantiates the toggle the clause actually names — one
/// conformer whose effect is visible, then an unrelated pure conformer added and NOTHING else changed —
/// and the caller carries `Fs` in both arms. That is the java/ts sin the clause was written from, and it
/// does not happen here. `cha_completeness_check.verdict(..., "Fs")` returns True in all four cells.
///
/// **AND `unknownWhy` ON THAT ROW IS FORBIDDEN, NOT MISSING.** SPEC §2 (the report shape,
/// `"unknownWhy"`): *"REQUIRED when this fn introduces `Unknown` DIRECTLY (a source); **absent if purely
/// inherited**… Omitted when this fn introduces no direct Unknown"* — restated in the ⟨0.6⟩ changelog
/// entry that tightened the field. In the row's own fixture `Widget.fire` has `direct: []`: it RESOLVED
/// the dispatch, to a conformer whose own effect happens to be `Unknown` because that conformer invokes
/// a stored closure field, and it is that conformer, `ClosureTask.go`, which carries
/// `dispatch:ClosureTask.f`. Emitting a reason on the inheriting caller would claim it as an Unknown
/// SOURCE, which is the one thing `blindspots` exists to separate from the smear — SPEC §3.1: *"a fn
/// whose `Unknown` is inherited (no `unknownWhy` of its own) is NOT a source and is excluded"*. The
/// reason is not lost to a consumer either: `path Widget.fire Unknown` answers
/// `Widget.fire → ClosureTask.go [Unknown source @ main.swift:4:47]`.
///
/// **WHAT IS ACTUALLY WRONG IS IN candor-spec, AND THIS REPO DOES NOT OWN IT.**
/// `conformance/cha_completeness_check.py` encodes branch (a) as *"the CONCRETE effect appears in
/// `inferred`"*. For a completed candidate set whose implementor's OWN effect is `Unknown` — the SPEC's
/// wording for (a), and exactly the row's fixture — that reading fails (a), routes the report to (b),
/// and then demands a field §2 requires to be omitted. **The two branches are jointly unsatisfiable for
/// that shape**, and no engine change can make them both hold. Reported, not fixed: one owner per repo.
/// (Third, independent reason the clause does not bind that fixture: its antecedent is a *"compiler-
/// synthesised or structural implementor — a lambda or closure coerced to an interface/protocol"*, and
/// `ClosureTask` is a hand-written nominal struct. Swift cannot conform a closure to a protocol at all,
/// which is why the fixture needed the wrapper struct in the first place.)
///
/// THESE THREE ROWS PASS WITH AND WITHOUT THIS BRANCH'S OTHER COMMITS, AND THAT IS NOT COVERAGE —
/// stated rather than left to be discovered, because a test that cannot fail reads as protection. They
/// pin a DECISION, so their discrimination had to be shown a different way, and it was, twice:
/// the calibration below proves this engine's branch-(b) machinery really fires on a genuinely
/// incomplete candidate set (without it the toggle row proves nothing about disclosure); and
/// `testAPurelyInheritedUnknownCarriesNoReasonAndItsSourceDoes` was measured against the change the row
/// asked for — adding the `dispatch:` insert to the CHA's EDGE branch reds it, so the emission this file
/// argues against cannot land silently.
final class ChaCompletenessDisclosureProcessTests: XCTestCase {

    private func scan(_ files: [(String, String)], _ name: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(files.first!.1, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        for (fname, body) in files.dropFirst() {
            try body.write(to: root.appendingPathComponent("Sources/\(name)/\(fname)"),
                           atomically: true, encoding: .utf8)
        }
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

    private static let visibleEffectConformer = """
    import Foundation
    protocol Task { func go() }
    struct Writer: Task { func go() { try? "x".write(toFile: "/tmp/r180.txt", atomically: true, encoding: .utf8) } }
    final class Widget {
      var held: Task? = nil
      func install() { held = Writer() }
      func fire() { held?.go() }
      func fireIfLet() { if let h = held { h.go() } }
    }
    let w = Widget(); w.install(); w.fire(); w.fireIfLet()
    """

    /// THE CLAUSE'S OWN TOGGLE: add ONE pure unrelated conformer, change nothing else. On published
    /// 0.34.0 java and ts the calling function VANISHED from `functions[]` and `deny Unknown` flipped
    /// 1 → 0. Here the caller keeps the conformer's effects in both arms — branch (a), which the clause
    /// calls the better answer wherever the engine can already see the body.
    func testTheClauseToggleDoesNotReproduce() throws {
        let zero = try scan([("main.swift", Self.visibleEffectConformer)], "R180zero")
        let one = try scan([("main.swift", Self.visibleEffectConformer),
                            ("other.swift", "final class Repaint: Task { static var n = 0; func go() { Repaint.n += 1 } }")],
                           "R180one")
        for (arm, by) in [("zero-conformer", zero), ("one-unrelated-conformer", one)] {
            for caller in ["Widget.fire", "Widget.fireIfLet"] {
                let f = by[caller]
                XCTAssertNotNil(f, "\(arm): \(caller) is ABSENT — the ⟨0.35⟩ sin's exact signature")
                XCTAssertEqual(Set((f?["inferred"] as? [String]) ?? []), ["Fs"],
                               "\(arm): \(caller) must carry the implementor's own effects (branch (a)); "
                               + "got \(String(describing: f?["inferred"]))")
            }
        }
    }

    /// CALIBRATION — the instrument must be proven able to fail (§6). A conformer that satisfies the
    /// requirement by INHERITANCE has no `Sub.go` unit for the CHA to resolve, so the candidate set is
    /// genuinely incomplete and the engine takes branch (b): `Unknown`, `unresolved: true`, and the
    /// normative `dispatch:Task.go`. Without this row, the row above proves nothing about disclosure.
    func testAnUnresolvableConformerTakesBranchBAndNamesTheOwner() throws {
        let src = """
        import Foundation
        protocol Task { func go() }
        class Base { func go() { try? "x".write(toFile: "/tmp/r180c.txt", atomically: true, encoding: .utf8) } }
        final class Sub: Base, Task {}
        final class Widget { var held: Task? = nil
          func install() { held = Sub() }
          func fire() { held?.go() } }
        let w = Widget(); w.install(); w.fire()
        """
        let by = try scan([("main.swift", src)], "R180calib")
        let f = by["Widget.fire"]
        XCTAssertEqual(Set((f?["inferred"] as? [String]) ?? []), ["Unknown"])
        XCTAssertEqual(f?["unresolved"] as? Bool, true)
        XCTAssertEqual(Set((f?["unknownWhy"] as? [String]) ?? []), ["dispatch:Task.go"],
                       "branch (b) must carry the one normative detail in the §4 vocabulary")
        XCTAssertTrue(Set((f?["direct"] as? [String]) ?? []).contains("Unknown"),
                      "…and it must be a DIRECT source, which is what licenses the reason")
    }

    /// THE ROW'S OWN FIXTURE, pinned with the disposition this file argues for: the caller RESOLVED the
    /// dispatch (`direct: []`, both conformers in `calls`) and therefore carries NO `unknownWhy`, while
    /// the conformer that genuinely cannot see through its stored closure field carries the reason. A
    /// future change that "fixes" R180 by emitting a reason on the caller reds this test, which is the
    /// point of writing it down.
    func testAPurelyInheritedUnknownCarriesNoReasonAndItsSourceDoes() throws {
        let src = """
        import Foundation
        protocol Task { func go() }
        struct Store { func write() { try? "x".write(toFile: "/tmp/r180p.txt", atomically: true, encoding: .utf8) } }
        struct ClosureTask: Task { let f: () -> Void; func go() { f() } }
        final class Widget {
          var held: Task? = nil
          func install(_ s: Store) { held = ClosureTask(f: { s.write() }) }
          func fire() { held?.go() }
        }
        """
        let by = try scan([("main.swift", src),
                           ("other.swift", "final class Repaint: Task { static var n = 0; func go() { Repaint.n += 1 } }")],
                          "R180proto")
        let caller = by["Widget.fire"]
        XCTAssertNotNil(caller, "the caller must be PRESENT — absence would be the sin")
        XCTAssertEqual(Set((caller?["inferred"] as? [String]) ?? []), ["Unknown"])
        XCTAssertTrue(Set((caller?["direct"] as? [String]) ?? []).isEmpty,
                      "the dispatch RESOLVED — the Unknown is inherited, not introduced here")
        XCTAssertTrue(Set((caller?["calls"] as? [String]) ?? []).isSuperset(of: ["ClosureTask.go", "Repaint.go"]),
                      "branch (a): the candidate set includes BOTH conformers; got "
                      + "\(String(describing: caller?["calls"]))")
        XCTAssertNil(caller?["unknownWhy"],
                     "SPEC §2: `unknownWhy` is REQUIRED on a DIRECT Unknown source and ABSENT if purely "
                     + "inherited. Emitting one here would claim this row as a source and put it in "
                     + "`blindspots`, which exists to separate the few sources from exactly this smear.")

        let source = by["ClosureTask.go"]
        XCTAssertTrue(Set((source?["direct"] as? [String]) ?? []).contains("Unknown"),
                      "the SOURCE is the conformer that cannot see through its stored closure field")
        XCTAssertEqual(Set((source?["unknownWhy"] as? [String]) ?? []), ["dispatch:ClosureTask.f"],
                       "…and it is the one that owes the reason, which it pays")
    }
}
