import XCTest
import Foundation

/// R33's escape gate (`constructionEscapes`, E2) answers "is this binding's name returned" with a
/// WHOLE-FUNCTION set (`returnedNames`, built by `ReturnedNameCollector` walking every `return` in the
/// body once, at construction time). Set MEMBERSHIP cannot see WHICH execution path put the name there
/// — so a name returned on ONE branch marks the binding escaping on EVERY branch, including ones where
/// it demonstrably drops in this scope.
///
/// This is the exact class candor-rust shipped and reverted the same day (commit `7af62f1`, ten minutes
/// to break): `fn f(b: bool) -> Option<G> { let g = G{}; if b { Some(g) } else { None } }` — escapes on
/// `b == true`, drops in-scope on `b == false`. `deny Fs` over the false path silently reads pure.
///
/// GROUND TRUTH EXECUTED, not inferred (2026-08-31, `exec_ground_truth.swift`, unbuffered
/// `FileHandle.standardOutput.write` markers around `deinit`/`CALLING`/`RETURNED`): every "drops"
/// function below printed `DEINIT` BEFORE `RETURNED` on the path asserted; every "escapes" control
/// printed it only after the caller released the value.
///
/// A/B against the REAL pre-fix and post-fix `8a19ca3` binaries confirmed identical (silent-pure)
/// behaviour on all four `testXxxDrops…` fixtures below — this is not a regression `8a19ca3`
/// introduced, it is the SAME whole-function-membership defect the binder path already had
/// (`applyDeinitGlue`'s old `name.map({ !returnedNames.contains($0) })` guard), carried forward
/// unchanged into the new single authority and never given a fixture with a BRANCH between the
/// binding and the qualifying `return`.
final class DeinitGlueConditionalEscapeProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: "CondEscape")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    private static let loudPrelude = """
    import Foundation
    class Loud {
        let path: String
        init(_ path: String) { self.path = path }
        deinit { _ = try? Data(contentsOf: URL(fileURLWithPath: path)) }
    }
    struct E: Error {}
    """

    // ── OVER-CHARGE CONTROLS, written FIRST — every shape the new gate must keep suppressing ────────

    /// The direct sibling of the defect: BOTH arms of the branch return the SAME binding. Nothing here
    /// may regress `testFactoriesThatReturnTheOwnerStayPure` (`DeinitGlueConstructionPositionProcessTests`)
    /// — a value that escapes on every reachable path must stay pure whether or not a branch sits
    /// between its binding and its return.
    func testBothBranchesReturningTheSameLocalStaysPure() throws {
        let src = Self.loudPrelude + """

        func bothBranchesReturn(_ f: Bool) -> Loud {
            let g = Loud("/etc/passwd")
            if f { return g } else { return g }
        }
        func elseIfChainAllReturn(_ n: Int) -> Loud {
            let g = Loud("/etc/passwd")
            if n == 1 { return g } else if n == 2 { return g } else { return g }
        }
        func guardElseThenUnconditionalReturn(_ f: Bool) -> Loud? {
            guard f else { return nil }
            let g = Loud("/etc/passwd")
            return g
        }
        func ifWithoutElseFallsThroughToAReturnThatEscapes(_ f: Bool) -> Loud {
            let g = Loud("/etc/passwd")
            if f { print("noted") }
            return g
        }
        """
        let by = try scan(src)
        for fn in ["bothBranchesReturn", "elseIfChainAllReturn", "guardElseThenUnconditionalReturn",
                   "ifWithoutElseFallsThroughToAReturnThatEscapes"] {
            XCTAssertNil(ProcessHarness.inferred(by, fn),
                         "\(fn) hands the constructed value out on every reachable path — charging it "
                         + "is the over-charge direction that reverted rust's R49 prototype: \(by[fn] ?? [:])")
        }
    }

    // ── THE DEFECT — a branch stands between the binding and the return that mentions it ────────────

    /// candor-rust's `Some(g)`/`None` shape, translated: `g` escapes only when `f` is true.
    func testConditionalEscapeViaIfElseDropsOnTheFalsePath() throws {
        let src = Self.loudPrelude + """

        func conditionalEscape(_ f: Bool) -> Loud? {
            let g = Loud("/etc/passwd")
            if f { return g } else { return nil }
        }
        """
        let by = try scan(src)
        XCTAssertEqual(ProcessHarness.inferred(by, "conditionalEscape"), ["Fs"],
                       "`g` is released in THIS function on the false path (executed proof: "
                       + "exec_ground_truth.swift) — absent is a purity claim that is false whenever "
                       + "`f` is false: \(by["conditionalEscape"] ?? [:])")
    }

    /// Only ONE `switch` case returns the binding; every other case drops it in-scope. `switch` is not
    /// modelled by the escape gate at all, so this also stands as the "unmodelled construct defaults to
    /// NOT proven" control.
    func testSwitchWhereOnlyOneCaseReturnsDropsOnTheOtherCases() throws {
        let src = Self.loudPrelude + """

        func switchOnlyOneCaseReturns(_ n: Int) -> Loud? {
            let g = Loud("/etc/passwd")
            switch n {
            case 1: return g
            default: return nil
            }
        }
        """
        let by = try scan(src)
        XCTAssertEqual(ProcessHarness.inferred(by, "switchOnlyOneCaseReturns"), ["Fs"],
                       "the `default` case drops `g` in this function — proven by execution: "
                       + "\(by["switchOnlyOneCaseReturns"] ?? [:])")
    }

    /// A `throw` between the construction and the qualifying `return` drops the value on the throwing
    /// path — the name is textually present in a LATER `return`, so the whole-function set still marks
    /// it escaping, even though this path never reaches that statement.
    func testThrowBetweenConstructionAndReturnDropsOnTheThrowingPath() throws {
        let src = Self.loudPrelude + """

        func throwingPath(_ f: Bool) throws -> Loud? {
            let g = Loud("/etc/passwd")
            if f { throw E() }
            return g
        }
        """
        let by = try scan(src)
        XCTAssertEqual(ProcessHarness.inferred(by, "throwingPath"), ["Fs"],
                       "`f == true` throws before `g` ever reaches `return` — the deinit runs HERE, "
                       + "proven by execution: \(by["throwingPath"] ?? [:])")
    }

    // ── A SECOND, STAND-ALONE hole found while chasing the first: E5 (`isImplicitReturnPosition`) ──
    //
    // `if`/`switch` are EXPRESSIONS in swift-syntax's grammar whether or not they are actually USED as
    // one, so `if cond { return 1 } else { return 2 } }` parses to the identical `IfExprSyntax` shape
    // as `if cond { 1 } else { 2 }`. E5 could not tell "the sole statement IS the value this function
    // implicitly returns" from "the sole statement is ordinary branching whose ARMS explicitly return"
    // — both read as "one top-level item, function has a return clause". This is UNRELATED to the E2
    // whole-function-membership vein above (confirmed against the pre-my-fix, post-`8a19ca3` binary:
    // same silent-pure result) and a more common trigger — any short function whose entire body is one
    // `if`/`else` with an early return in each arm.

    /// The over-charge control for E5's fix, written FIRST: a genuine if-EXPRESSION implicit return —
    /// no `return` keyword anywhere, both arms are plain trailing value expressions — must stay pure.
    func testGenuineIfExpressionImplicitReturnStaysPure() throws {
        let src = Self.loudPrelude + """

        func genuineImplicitReturn(_ cond: Bool) -> Loud {
            if cond { Loud("/etc/passwd") } else { Loud("/tmp/o") }
        }
        func genuineImplicitReturnViaSwitch(_ n: Int) -> Loud {
            switch n {
            case 1: Loud("/etc/passwd")
            default: Loud("/tmp/o")
            }
        }
        """
        let by = try scan(src)
        for fn in ["genuineImplicitReturn", "genuineImplicitReturnViaSwitch"] {
            XCTAssertNil(ProcessHarness.inferred(by, fn),
                         "\(fn)'s if/switch has no `return` keyword at all — every arm's value IS the "
                         + "function's result, so it escapes on every path: \(by[fn] ?? [:])")
        }
    }

    /// THE DEFECT: an `if`/`else` with EXPLICIT `return`s in both arms, as the SOLE statement of a
    /// function with a declared return type — proven by execution (`exec_ground_truth2.swift`) to drop
    /// `g1` in-scope on the `cond == true` path, several statements before either arm's own `return`.
    func testSoleIfElseWithExplicitReturnsInBothArmsDropsTheEarlyLocal() throws {
        let src = Self.loudPrelude + """

        func soleIfElseWithExplicitReturns(_ cond: Bool) -> Int {
            if cond {
                let g1 = Loud("/etc/passwd")
                _ = g1.path
                return 1
            } else {
                return 2
            }
        }
        """
        let by = try scan(src)
        XCTAssertEqual(ProcessHarness.inferred(by, "soleIfElseWithExplicitReturns"), ["Fs"],
                       "`g1` is bound, read, and never returned by anything — it is released in this "
                       + "function on EVERY call, proven by execution: "
                       + "\(by["soleIfElseWithExplicitReturns"] ?? [:])")
    }

    /// The STRONGEST form: two DIFFERENT locals sharing a NAME across sibling branches. The if-branch's
    /// `g` is never returned by anything — it is a completely separate binding from the else-branch's
    /// `g`, which does escape. `returnedNames` is keyed by identifier TEXT, so it cannot tell two
    /// bindings of the same name apart, regardless of which one the construction under test belongs to.
    func testNameCollisionAcrossSiblingBranchesChargesTheNonEscapingOne() throws {
        let src = Self.loudPrelude + """

        func nameCollisionAcrossBranches(_ cond: Bool) -> Loud? {
            if cond {
                let g = Loud("/etc/passwd")
                _ = g.path
                return nil
            } else {
                let g = Loud("/etc/passwd")
                return g
            }
        }
        """
        let by = try scan(src)
        XCTAssertEqual(ProcessHarness.inferred(by, "nameCollisionAcrossBranches"), ["Fs"],
                       "the if-branch's `g` is a DIFFERENT binding from the else-branch's `g` and is "
                       + "released right there — only the else-branch's escapes: "
                       + "\(by["nameCollisionAcrossBranches"] ?? [:])")
    }

    // ── PERFORMANCE PIN — see `itemsGuaranteeEscape`'s PERFORMANCE doc comment ──────────────────────
    //
    // The first version of `guaranteedToEscape` threaded its fallthrough continuation as an
    // `@escaping () -> Bool` closure, rebuilt one layer deeper at every `if` and invoked from BOTH
    // arms. For N sequential `if`/`else` statements where both arms fall through, that closure gets
    // re-invoked twice at every level — O(2^N). MEASURED: `PrivacyManifestCLI.swift` (1316 lines, this
    // exact shape — a long run of `if usage == "…" { … } else { … }` checks) alone took the whole
    // engine's self-scan from 3 SECONDS to over 9 MINUTES before being killed. `swift test` never
    // self-scans, so the entire 988-test suite stayed green throughout — this is a defect no unit test
    // in this file catches; only TIMING a scan does.

    /// 500 sequential `if`/`else` pairs (neither arm exits) ahead of one non-escaping construction. The
    /// un-fixed closure version does not finish this in any practical time; the linear, eagerly-computed
    /// version should finish in low single-digit seconds even under a debug build and process-spawn
    /// overhead. A generous ceiling (30s) is used because CI/local machine speed varies — the point is
    /// distinguishing "linear" from "the test runner times out", not pinning an exact duration.
    func testPerformanceOnALongSequentialIfElseChainStaysLinear() throws {
        let branches = (0..<500).map { i in
            "if cond\(i % 2 == 0 ? "A" : "B") { noted += 1 } else { noted += 2 }"
        }.joined(separator: "\n            ")
        let src = Self.loudPrelude + """

        var noted = 0
        func longChain(_ condA: Bool, _ condB: Bool) {
            \(branches)
            let g = Loud("/etc/passwd")
            _ = g.path
        }
        """
        let start = Date()
        let by = try scan(src)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 30,
                          "500 sequential if/else pairs took \(elapsed)s — the exponential-blowup shape "
                          + "is back (see itemsGuaranteeEscape's PERFORMANCE note)")
        XCTAssertEqual(ProcessHarness.inferred(by, "longChain"), ["Fs"],
                       "`g` is bound, read, and released in this function on every call — correctness "
                       + "must hold alongside the performance fix: \(by["longChain"] ?? [:])")
    }
}
