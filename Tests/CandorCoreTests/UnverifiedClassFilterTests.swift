import XCTest
import Foundation
@testable import CandorCore

/// `unverified --class` MUST RESOLVE THE REASON CLASS THE WAY THE GATE DOES.
///
/// `unverified` names the functions a `pure`/`deny E` layer PASSES without proving anything — its whole
/// job is to say "green, but not provably so". The ⟨0.20⟩ `--class` filter narrowed that list by reason
/// class, and it read the REPORT'S `unknownWhy` FIELD DIRECTLY, which is the wrong quantity twice over:
///
///  1. SPEC §4 makes `unknownWhy` **direct-only** — a function that INHERITS its `Unknown` carries none by
///     design. Reading the direct field as if it were the transitive one made every inherited hole match
///     NO class, so the filter dropped it. Measured on pollen under `deny Exec`: 387 holes unfiltered,
///     **230** under `--class dynamic` — and `dynamic` names every genuine class, so those two numbers
///     have to agree. 157 holes (41%) vanished under a filter that excluded nothing.
///  2. SPEC §6.2 ⟨0.24⟩: a function whose `Unknown` carries **no recorded reason CONTRIBUTES**
///     `unresolved` to its class set. The site contributed nothing, so `--class unresolved` — the filter
///     that exists to catch the holes nobody could classify — was the one that missed them.
///
/// Both halves are required and neither is sufficient. Half 1 alone would give an inherited `Unknown`
/// `unresolved` when its callee classified it perfectly well as `dispatch` — trading the fail-open for a
/// fabrication. So the CONTROLS are the point of this suite: a class the function does not have must not
/// match, in both directions.
final class UnverifiedClassFilterTests: XCTestCase {

    /// One report's worth of entries. Every row is `Unknown` and carries no `Exec`, so `deny Exec` passes
    /// all of them and `unverifiedHoleRule` makes each a hole — the filter is then the ONLY variable.
    private func rows() -> [UnverifiedFn] {
        [
            // a DIRECT `Unknown` source with no recorded reason — §6.2's contribution case
            UnverifiedFn(fn: "a.reasonless", inferred: ["Unknown"], direct: ["Unknown"],
                         unknownWhy: [], calls: []),
            // a DIRECT source that classified itself — the control row: `dispatch`, and nothing else
            UnverifiedFn(fn: "b.reasoned", inferred: ["Unknown"], direct: ["Unknown"],
                         unknownWhy: ["dispatch:P.m"], calls: []),
            // INHERITS from the classified source: `dispatch` must travel, `unresolved` must not appear
            UnverifiedFn(fn: "c.inheritsReasoned", inferred: ["Unknown"], direct: [],
                         unknownWhy: [], calls: ["b.reasoned"]),
            // INHERITS from the reasonless source: `unresolved` must travel
            UnverifiedFn(fn: "d.inheritsReasonless", inferred: ["Unknown"], direct: [],
                         unknownWhy: [], calls: ["a.reasonless"]),
            // INHERITS BOTH — the class set is a union, never one or the other
            UnverifiedFn(fn: "e.inheritsBoth", inferred: ["Unknown"], direct: [],
                         unknownWhy: [], calls: ["a.reasonless", "b.reasoned"]),
            // not `Unknown` at all: never a hole, whatever the filter
            UnverifiedFn(fn: "f.clean", inferred: [], direct: [], unknownWhy: [], calls: []),
        ]
    }

    private func holes(_ classSpec: String?) -> [String] {
        let deny = parsePolicy("deny Exec").deny
        let (_, hs) = unverified(rows(), deny, classFilter: parseClassFilter(classSpec))
        return hs.map { $0.fn }.sorted()
    }

    /// THE CONVERGENCE THE NUMBER IS ABOUT: `dynamic` is every genuine class, so it cannot drop a hole.
    func testDynamicNamesEveryGenuineClassSoItDropsNothing() {
        let all = holes(nil)
        XCTAssertEqual(all, ["a.reasonless", "b.reasoned", "c.inheritsReasoned",
                             "d.inheritsReasonless", "e.inheritsBoth"])
        XCTAssertEqual(holes("dynamic"), all,
                       "`--class dynamic` excludes only `setup`; on a report with no setup-class hole it "
                       + "must return the unfiltered list, or the filter is dropping what it cannot classify")
    }

    /// HALF 1 — a reasonless DIRECT `Unknown` contributes `unresolved`, and carries it to its callers.
    func testAReasonlessUnknownContributesUnresolved() {
        XCTAssertEqual(holes("unresolved"),
                       ["a.reasonless", "d.inheritsReasonless", "e.inheritsBoth"])
    }

    /// HALF 2 — the class travels the call graph, exactly as the `Unknown` effect does.
    func testTheClassTravelsTheCallGraph() {
        XCTAssertEqual(holes("dispatch"),
                       ["b.reasoned", "c.inheritsReasoned", "e.inheritsBoth"])
    }

    /// THE CONTROL. A function whose reasons are ALL classifiable and NONE of them `unresolved` must not
    /// match `--class unresolved` — directly (`b.reasoned`) or through inheritance (`c.inheritsReasoned`).
    /// Without this, the fix is indistinguishable from "contribute `unresolved` unconditionally", which
    /// makes every hole match every filter and deletes the verb.
    func testAClassifiedHoleNeverReadsUnresolved() {
        let unres = holes("unresolved")
        XCTAssertFalse(unres.contains("b.reasoned"),
                       "a `dispatch:` reason is not an unclassified hole")
        XCTAssertFalse(unres.contains("c.inheritsReasoned"),
                       "…and inheriting one is not either — resolving the class transitively must not "
                       + "also invent an `unresolved` the callee's report refutes")
        // the mirror: a class nothing in the fixture has matches nothing at all
        XCTAssertEqual(holes("native"), [], "`--class native` has no candidate here")
        XCTAssertEqual(holes("reflect"), [], "`--class reflect` has no candidate here")
    }

    /// A pre-⟨0.24⟩ report (no `direct` field, so `direct` loads empty) must still not silently drop a
    /// hole nobody classified: with nothing anywhere in its reach explaining the `Unknown`, `unresolved`
    /// stands. This is the format-tolerance arm — the fix must not depend on a field a report may lack.
    func testAHoleNothingExplainsStillReadsUnresolved() {
        let deny = parsePolicy("deny Exec").deny
        let fns = [UnverifiedFn(fn: "x.opaque", inferred: ["Unknown"], direct: [],
                                unknownWhy: [], calls: [])]
        let (_, hs) = unverified(fns, deny, classFilter: parseClassFilter("unresolved"))
        XCTAssertEqual(hs.map { $0.fn }, ["x.opaque"])
        let (_, none) = unverified(fns, deny, classFilter: parseClassFilter("dispatch"))
        XCTAssertEqual(none.map { $0.fn }, [], "…and never a guessed class")
    }

    /// THE CLI ARM. The logic above is only reached if `mergeUnverifiedReport` actually loads `direct`
    /// and `calls` off the report — the wiring is where a "reads the direct field" bug lives.
    func testTheCLIReadsDirectAndCallsOffTheReport() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-ucf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func entry(_ fn: String, _ direct: [String], _ why: [String], _ calls: [String]) -> [String: Any] {
            var e: [String: Any] = ["fn": fn, "loc": "S.swift:1", "inferred": ["Unknown"],
                                    "direct": direct, "unresolved": true, "hash": "P#\(fn)", "calls": calls]
            if !why.isEmpty { e["unknownWhy"] = why }
            return e
        }
        let report: [String: Any] = [
            "candor": ["version": "candor-swift-test", "spec": "0.23", "toolchain": "swiftsyntax"],
            "package": "P",
            "functions": [
                entry("a.reasonless", ["Unknown"], [], []),
                entry("b.reasoned", ["Unknown"], ["dispatch:P.m"], []),
                entry("c.inheritsReasoned", [], [], ["b.reasoned"]),
                entry("d.inheritsReasonless", [], [], ["a.reasonless"]),
            ],
        ]
        let rpt = root.appendingPathComponent("r.json")
        try JSONSerialization.data(withJSONObject: report).write(to: rpt)
        let pol = root.appendingPathComponent("p.candor")
        try "deny Exec\n".write(to: pol, atomically: true, encoding: .utf8)

        func names(_ classSpec: String?) throws -> [String] {
            var args = ["unverified", "--report", rpt.path, "--policy", pol.path]
            if let classSpec { args += ["--class", classSpec] }
            let r = try ProcessHarness.run(bin, args)
            XCTAssertEqual(r.code, 0, r.err)
            let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
            let hs = (d?["unverified"] as? [[String: Any]]) ?? []
            return hs.compactMap { $0["fn"] as? String }.sorted()
        }
        let all = try names(nil)
        XCTAssertEqual(all, ["a.reasonless", "b.reasoned", "c.inheritsReasoned", "d.inheritsReasonless"])
        XCTAssertEqual(try names("dynamic"), all, "the CLI must converge too, or `direct`/`calls` never arrived")
        XCTAssertEqual(try names("unresolved"), ["a.reasonless", "d.inheritsReasonless"])
        XCTAssertEqual(try names("dispatch"), ["b.reasoned", "c.inheritsReasoned"])
    }
}
