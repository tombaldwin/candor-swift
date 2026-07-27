import XCTest
import Foundation
@testable import CandorCore

/// SPEC §6.2 ⟨0.24⟩ — **THE `--class` FLAG'S VALUE GRAMMAR**.
///
/// `--class <c>[,<c>…]` takes ONE comma-separated list; it is NOT repeatable (a second occurrence is a
/// usage error, not a union). The accepted tokens are the six reason classes plus the two aliases `*` and
/// `dynamic`. An UNRECOGNISED token is a usage error — **exit 2** — naming the token and listing the
/// accepted set. Before this suite, `unverified --class dyanmic` exited **0** here and in the other three
/// engines: conformance PART 27 found the clause unimplemented four-way rather than divergent, which is
/// why the suite's waiver for it is its only `engine: "*"` one.
///
/// **WHY THE QUERY SIDE REFUSES WHAT THE POLICY SIDE DROPS.** The asymmetry is deliberate and reads as an
/// inconsistency until it is written down. A token dropped out of `deny E Unknown[reflect,dyanmic]`
/// leaves the **wider** rule standing, so the mistake is loud: the gate over-fires and somebody comes to
/// look. The same token dropped out of `--class` leaves a **narrower** filter, and a narrower filter on
/// `unverified` comes back as a **smaller number** — indistinguishable from a real all-clear, in the one
/// verb whose entire job is to say "green, but not provably so". That is precisely the fail-open the
/// surrounding §6.2 clause exists to close, so a query flag that cannot be honoured is refused.
///
/// **THE MESSAGE IS ASSERTED, NOT JUST THE EXIT CODE.** Several unrelated paths through this CLI exit 2
/// (an unknown flag, a report that does not resolve, a `--class` that stopped consuming its value and let
/// its token fall through to the deprecated leading-report peel), so a bare `code == 2` would pass
/// against a mutation that deleted the rule outright — the failure mode that bit a sibling engine in this
/// same area, where `--gate-json` swallowed `--policy` and the command still exited 2 for the wrong
/// reason.
///
/// `unverified` is the ONLY `--class` consumer in this engine (there is no `blindspots` or `callers`
/// verb here), so it is the whole verb surface.
final class ClassFilterGrammarProcessTests: XCTestCase {

    /// A report with two DIRECT `Unknown` sources of DIFFERENT classes plus one function that INHERITS
    /// from the `dispatch` one — so a filter selects a PROPER subset and the regression control below can
    /// assert a count, not just an exit code.
    private func fixture() throws -> (bin: URL, report: String, policy: String, cleanup: URL) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
                entry("domain.srcDispatch", ["Unknown"], ["dispatch:P.m"], []),
                entry("domain.inherits", [], [], ["domain.srcDispatch"]),
                entry("domain.srcNative", ["Unknown"], ["native:strlen"], []),
            ],
        ]
        let rpt = root.appendingPathComponent("r.json")
        try JSONSerialization.data(withJSONObject: report).write(to: rpt)
        let pol = root.appendingPathComponent("p.candor")
        try "deny Exec domain\n".write(to: pol, atomically: true, encoding: .utf8)
        return (bin, rpt.path, pol.path, root)
    }

    private func names(_ bin: URL, _ report: String, _ policy: String,
                       _ classSpec: String?) throws -> (code: Int32, fns: [String], err: String, out: String) {
        var args = ["unverified", "--report", report, "--policy", policy]
        if let classSpec { args += ["--class", classSpec] }
        let r = try ProcessHarness.run(bin, args)
        let d = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
        let hs = (d?["unverified"] as? [[String: Any]]) ?? []
        return (r.code, hs.compactMap { $0["fn"] as? String }.sorted(), r.err, r.out)
    }

    /// (1) a single valid token, (2) a valid comma list, (3) BOTH aliases — and (6) the REGRESSION
    /// CONTROL, which asserts the exact selection rather than an exit code: this change must alter no
    /// verdict and no selection for well-formed input.
    func testAValidFilterStillSelectsExactlyWhatItDidBefore() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.cleanup) }

        // the unfiltered baseline every filter below is a subset of
        let all = try names(f.bin, f.report, f.policy, nil)
        XCTAssertEqual(all.code, 0, all.err)
        XCTAssertEqual(all.fns, ["domain.inherits", "domain.srcDispatch", "domain.srcNative"])

        // (1) ONE valid token → a PROPER subset. This is what makes the control discriminating: a filter
        // that had stopped filtering (the mirror repair to this one) would return all three.
        let one = try names(f.bin, f.report, f.policy, "dispatch")
        XCTAssertEqual(one.code, 0, one.err)
        XCTAssertEqual(one.fns, ["domain.inherits", "domain.srcDispatch"],
                       "`--class dispatch` selects the dispatch source and the fn inheriting from it")

        // (2) a valid COMMA LIST is the union of its tokens…
        let list = try names(f.bin, f.report, f.policy, "dispatch,native")
        XCTAssertEqual(list.code, 0, list.err)
        XCTAssertEqual(list.fns.count, 3, "`--class dispatch,native` unions the two classes")
        // …and the whitespace a shell-quoted list tends to carry is trimmed, not read as a token.
        let spaced = try names(f.bin, f.report, f.policy, " dispatch , native ")
        XCTAssertEqual(spaced.code, 0, spaced.err)
        XCTAssertEqual(spaced.fns.count, 3, "a spaced list is the same list")

        // (3) BOTH ALIASES. `dynamic` is not optional — §6.2's normative diagnostic is stated in terms of
        // it, so an engine that rejected it as unrecognised would break the test every engine carries.
        let dynamic = try names(f.bin, f.report, f.policy, "dynamic")
        XCTAssertEqual(dynamic.code, 0, dynamic.err)
        XCTAssertEqual(dynamic.fns, all.fns, "`dynamic` is every GENUINE class; nothing here is setup-only")
        let star = try names(f.bin, f.report, f.policy, "*")
        XCTAssertEqual(star.code, 0, star.err)
        XCTAssertEqual(star.fns, all.fns, "`*` is all six classes")

        // the mirror control: a VALID class with no candidate is an empty answer at exit 0, never an
        // error — which is what separates "the token was accepted" from "the filter stopped filtering".
        let empty = try names(f.bin, f.report, f.policy, "reflect")
        XCTAssertEqual(empty.code, 0, empty.err)
        XCTAssertEqual(empty.fns, [])
    }

    /// (4) an unrecognised token exits 2, NAMES the token, and lists the accepted set.
    func testAnUnrecognisedTokenIsAUsageErrorNamingTheTokenAndTheAcceptedSet() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.cleanup) }
        let r = try names(f.bin, f.report, f.policy, "dyanmic")  // the transposition a human actually makes
        XCTAssertEqual(r.code, 2, "a --class value that cannot be honoured is refused, not narrowed: \(r.err)")
        // NAME THE TOKEN. Without this the assertion passes against any other exit-2 path in this CLI.
        XCTAssertTrue(r.err.contains("dyanmic"), "the message must name the offending token: \(r.err)")
        XCTAssertTrue(r.err.contains("unrecognised reason-class"),
                      "…and say what is wrong with it, rather than exiting 2 for an unrelated reason: \(r.err)")
        // LIST THE ACCEPTED SET — all six classes and both aliases, so the line is fixable from the
        // message alone without opening the spec.
        for t in ["reflect", "dispatch", "indirect", "native", "unresolved", "setup", "dynamic", "*"] {
            XCTAssertTrue(r.err.contains(t), "the accepted set must list `\(t)`: \(r.err)")
        }
        // NO PARTIAL ANSWER. A refused filter must not also print a (narrower) result document — that is
        // the same fail-open, one exit code away.
        XCTAssertEqual(r.out, "", "a refused --class emits no answer at all")

        // ORDER-INDEPENDENCE: `*` short-circuited the whole list before this change, so a typo AFTER it
        // would have been accepted silently. The refusal is a property of the list, not of its prefix.
        let after = try names(f.bin, f.report, f.policy, "*,dyanmic")
        XCTAssertEqual(after.code, 2, "a typo after `*` is still a typo: \(after.err)")
        XCTAssertTrue(after.err.contains("dyanmic"), after.err)
    }

    /// (5) a repeated `--class` exits 2 — not a union, and not last-wins.
    func testARepeatedClassFlagIsAUsageErrorNotAUnionAndNotLastWins() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.cleanup) }
        let r = try ProcessHarness.run(f.bin, ["unverified", "--report", f.report, "--policy", f.policy,
                                               "--class", "unresolved", "--class", "native"])
        XCTAssertEqual(r.code, 2, "`--class` takes ONE comma-separated list: \(r.err)")
        // BOTH tokens are individually VALID, so this cannot be the unrecognised-token path — and it must
        // not be the unknown-flag path either, which is what a `--class` that stopped consuming its value
        // would produce. Asserting the WORDING is what keeps the two rules distinguishable; an
        // exit-code-only test passes against a mutation that deleted this one.
        XCTAssertTrue(r.err.contains("more than once"), "the message must say the flag was repeated: \(r.err)")
        XCTAssertTrue(r.err.contains("not a union"),
                      "…and that the lists are not unioned — union and last-wins are BOTH silent misreadings: \(r.err)")
        XCTAssertFalse(r.err.contains("unrecognised reason-class"),
                       "`unresolved` and `native` are valid tokens; this is the repeat rule, not the token rule: \(r.err)")
        XCTAssertFalse(r.err.contains("unknown flag"),
                       "…and not the unknown-flag rule, which is how this test would pass for the wrong reason: \(r.err)")
        XCTAssertEqual(r.out, "", "a refused --class emits no answer at all")
    }

    /// The rule at the library boundary, where the CLI's exit code cannot stand in for it: the SAME
    /// `parseClassFilter` the CLI calls throws on the token and accepts every member of the set.
    func testTheParserItselfAcceptsTheWholeSetAndRefusesAnythingElse() throws {
        for t in ["reflect", "dispatch", "indirect", "native", "unresolved", "setup"] {
            XCTAssertEqual(try parseClassFilter(t), Set([t]), "`\(t)` is an accepted token")
        }
        XCTAssertEqual(try parseClassFilter("*"), Set(REASON_CLASSES))
        XCTAssertEqual(try parseClassFilter("dynamic"), Set(REASON_CLASSES).subtracting(["setup"]),
                       "`dynamic` is every GENUINE class, which by its own definition excludes `setup`")
        XCTAssertEqual(try parseClassFilter("reflect,native"), Set(["reflect", "native"]))
        XCTAssertNil(try parseClassFilter(nil), "no flag ⇒ no filter, which is not the same as an empty one")
        for bad in ["dyanmic", "Reflect", "unknown", "reflect;native"] {
            XCTAssertThrowsError(try parseClassFilter(bad), "`\(bad)` must be refused") { e in
                XCTAssertTrue((e as? ClassFilterUsageError)?.message.contains(bad) == true,
                              "the error must name the token it refused: \(e)")
            }
        }
    }
}
