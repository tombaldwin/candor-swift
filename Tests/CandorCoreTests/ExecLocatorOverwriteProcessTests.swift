import XCTest
import Foundation

/// **THE `Process` COMMAND SURFACE IS NOT A UNION OF EVERY WRITE — A DOMINATING WRITE KILLS THE ONES
/// BEFORE IT.**
///
///     p.executableURL = URL(fileURLWithPath: "/bin/sh")
///     p.executableURL = URL(fileURLWithPath: "/bin/zsh")
///     try? p.run()                                  // reported cmds: ["/bin/sh", "/bin/zsh"]
///
/// Only `/bin/zsh` can run. `/bin/sh` was on the surface for an execution that does not exist, and
/// `allow Exec /bin/zsh` failed on it. The harm is FAIL-CLOSED — a spurious failure, never a missed one —
/// so this is a false positive and not the cardinal sin, which is why the fix is narrow.
///
/// IT WAS WORTH FIXING BECAUSE THE ENGINE'S TWO LOCATOR MECHANISMS DISAGREED ABOUT ONE SHAPE. The
/// URL/URLRequest path WITHHOLDS on a straight-line rebind (`u = URL(…)` puts the name in `movedNames`
/// and no host is claimed at all) while this path unioned, so the same source construct — rebinding a
/// locator in straight-line code — got two different answers depending on which effect it fed. One of the
/// two had to move; withholding here would have cost every ordinary single-write `Process` its command,
/// which is most of them.
///
/// THE RULE: a write W kills an earlier write V iff **W's enclosing statement list is V's list or an
/// ANCESTOR of it** — exactly "control reaching past W has passed through W and can no longer be carrying
/// V". Last-write-wins is decidable for that; a loop-carried or branch-conditional rebind is not, and
/// those must stay unioned.
///
/// **HALF THIS FILE IS THE SECOND FIXTURE, AND IT WAS WRITTEN FIRST.** A test that only shows the false
/// positive closed cannot show what the closing cost, and killing an over-charge is precisely where a
/// silent under-report gets introduced: every drop here is a command that would stop failing an
/// `allow Exec`. So each shape that MUST still union has its own row, and the `single`/`writeAfterRun`
/// controls assert the ordinary case is untouched.
final class ExecLocatorOverwriteProcessTests: XCTestCase {

    private func cmds(_ src: String, _ name: String = "Ovr") throws -> [String: [String]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["cmds"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return by
    }

    private static let src = """
    import Foundation

    // ── the finding ──────────────────────────────────────────────────────────────────────────────
    func straightLine() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        try? p.run()
    }
    func nestedBlockPair() {
        let p = Process()
        if true { p.launchPath = "/bin/sh"; p.launchPath = "/bin/zsh" }
        p.launch()
    }
    func outerAfterInner(_ c: Bool) {
        let p = Process()
        p.launchPath = "/bin/sh"
        if c { p.launchPath = "/bin/b" }
        p.launchPath = "/bin/zsh"
        p.launch()
    }

    // ── what the fix must NOT collapse ───────────────────────────────────────────────────────────
    func branched(_ c: Bool) {
        let p = Process()
        p.launchPath = "/bin/sh"
        if c { p.launchPath = "/bin/zsh" }
        p.launch()
    }
    func innerPairOuterRead(_ c: Bool) {
        let p = Process()
        p.launchPath = "/bin/sh"
        if c { p.launchPath = "/bin/b"; p.launchPath = "/bin/zsh" }
        p.launch()
    }
    func innerPairInnerRead(_ c: Bool) {
        let p = Process()
        p.launchPath = "/bin/sh"
        if c { p.launchPath = "/bin/b"; p.launchPath = "/bin/zsh"; p.launch() }
    }
    func closureWrite(_ xs: [Int]) {
        let p = Process()
        xs.forEach { _ in p.launchPath = "/bin/zsh" }
        p.launchPath = "/bin/sh"
        p.launch()
    }

    // ── the controls: the ordinary case, and the two guards beside this one ──────────────────────
    func single() {
        let p = Process()
        p.launchPath = "/bin/sh"
        p.launch()
    }
    func writeAfterRun() {
        let p = Process()
        p.launchPath = "/bin/sh"
        p.launch()
        p.launchPath = "/bin/zsh"
    }
    func invisibleThenLiteral(_ t: String) {
        let p = Process()
        p.launchPath = t
        p.launchPath = "/bin/zsh"
        p.launch()
    }
    """

    /// THE FINDING. Three shapes where the later write provably overwrites the earlier one.
    func testADominatingLocatorWriteKillsTheOneBeforeIt() throws {
        let by = try cmds(Self.src)
        XCTAssertEqual(by["straightLine"], ["/bin/zsh"],
                       "two straight-line writes to one handle: only the LAST can run, and `/bin/sh` on "
                       + "the surface is a command no execution in this function performs")
        XCTAssertEqual(by["nestedBlockPair"], ["/bin/zsh"],
                       "the pair is straight-line WITHIN a block — the rule is the statement list, not the "
                       + "nesting depth")
        XCTAssertEqual(by["outerAfterInner"], ["/bin/zsh"],
                       "a write in the OUTER list dominates one in a conditional block above it too: "
                       + "control reaches it whether or not the block ran")
    }

    /// THE SECOND FIXTURE. Every shape where the earlier write is still live, and dropping it would turn
    /// a fail-closed false positive into a false `allow Exec` certification — the trade this fix exists
    /// not to make.
    func testAConditionalOrClosureWriteStillUnionsWithTheOneBeforeIt() throws {
        let by = try cmds(Self.src)
        XCTAssertEqual(by["branched"], ["/bin/sh", "/bin/zsh"],
                       "the second write is CONDITIONAL — with `c` false, `/bin/sh` is what runs, and "
                       + "last-write-wins here would certify `allow Exec /bin/zsh` for a `/bin/sh` spawn")
        XCTAssertEqual(by["innerPairOuterRead"], ["/bin/sh", "/bin/zsh"],
                       "`/bin/zsh` kills `/bin/b` (same list) but NOT `/bin/sh`, whose list is an ANCESTOR "
                       + "of theirs — the read below the block still sees it when `c` is false")
        XCTAssertEqual(by["innerPairInnerRead"], ["/bin/sh", "/bin/zsh"],
                       "…and the read INSIDE the block sees the same two: `/bin/b` is dead, `/bin/sh` is "
                       + "not dropped merely because the kill happened in a nested list")
        XCTAssertEqual(by["closureWrite"], ["/bin/sh", "/bin/zsh"],
                       "the chain STOPS at a closure boundary — an escaping closure runs at a time this "
                       + "source-order walk cannot place, so neither write kills the other")
    }

    /// THE CONTROLS. Without these the two rows above pass on an engine that simply stopped recording
    /// `Process` commands, which is the failure mode a narrowing change actually has.
    func testTheOrdinaryCaseAndTheTwoNeighbouringGuardsAreUntouched() throws {
        let by = try cmds(Self.src)
        XCTAssertEqual(by["single"], ["/bin/sh"], "one write, one launch — the case that carries the value")
        XCTAssertEqual(by["writeAfterRun"], ["/bin/sh"],
                       "a write BELOW the launch was never in the surface (the walk is source-ordered) and "
                       + "still is not")
        XCTAssertEqual(by["invisibleThenLiteral"], [],
                       "a literal that dominates an UNREADABLE write does overwrite it, and clearing the "
                       + "refusal on that basis is the one direction here that turns a withholding into a "
                       + "claim. `execLocatorInvisible` is deliberately NOT subject to the kill: the "
                       + "relaxation's only support would be the same dominance argument being introduced "
                       + "alongside it. The handle stays refused.")
    }
}
