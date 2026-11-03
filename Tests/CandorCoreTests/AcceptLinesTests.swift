import XCTest
import Foundation
@testable import CandorCore

/// SPEC §6.2 ⟨0.41⟩ `accept` lines. The cardinal direction is ACCEPTING A VIOLATION THAT IS NEW, so the
/// load-bearing rows here are the OVER-ACCEPT detectors: each one is a case an engine that read the clause
/// too loosely would accept, expected to stay red. Each was shown able to FAIL against a deliberately
/// broken matcher (prefix on `fn`, no effect-subset test, rule line left out of the key, twins accepted,
/// positional key accepted, reason class ignored) before it was trusted — see the commit message.
final class AcceptLinesParseTests: XCTestCase {

    private let rule = "deny Fs dao\n"

    private func entries(_ extra: String) -> [AcceptEntry] { parsePolicy(rule + extra).accepts }
    private func ignoredLines(_ extra: String) -> [Int] { parsePolicy(rule + extra).ignored.map(\.line) }

    func testAValidLineBecomesAnEntryAndIsNotListedAsIgnored() {
        let p = parsePolicy(rule + "accept dao.a Fs for deny Fs dao because known since 2026\n")
        XCTAssertEqual(p.accepts.count, 1)
        let e = p.accepts[0]
        XCTAssertEqual(e.fn, "dao.a"); XCTAssertEqual(e.effects, ["Fs"]); XCTAssertEqual(e.line, 2)
        XCTAssertEqual(e.ruleKey, "deny Fs dao"); XCTAssertEqual(e.because, "known since 2026")
        XCTAssertEqual(e.code, "AS-EFF-006")
        XCTAssertTrue(p.ignored.isEmpty, "a valid directive is not a dropped line")
        XCTAssertEqual(p.deny.count, 1, "an accept line is a directive: the rule vectors are what they were without it")
    }

    func testAnAcceptOnlyPolicyHasNoRules() {
        let p = parsePolicy("accept dao.a Fs for deny Fs dao because x\n")
        XCTAssertTrue(p.deny.isEmpty && p.allow.isEmpty && p.forbid.isEmpty && p.only.isEmpty)
    }

    func testRuleMayComeAfterTheEntry() {
        XCTAssertEqual(parsePolicy("accept dao.a Fs for deny Fs dao because x\n" + rule).accepts.count, 1)
    }

    func testTheKeyIsTheRawTokensNotTheConsumedOnes() {
        // `deny Fs dao extra` parses as `deny Fs dao`; only the full text names it.
        XCTAssertEqual(parsePolicy("deny Fs dao extra\naccept dao.a Fs for deny Fs dao because x\n").accepts.count, 0)
        XCTAssertEqual(parsePolicy("deny Fs dao extra\naccept dao.a Fs for deny Fs dao extra because x\n").accepts.count, 1)
    }

    func testWhitespaceAndCommentsAreNormalisedOnBothSides() {
        let p = parsePolicy("deny   Fs\tdao   # the rule\naccept  dao.a   Fs for deny Fs   dao because known   since  2026  # why\n")
        XCTAssertEqual(p.accepts.count, 1)
        XCTAssertEqual(p.accepts[0].because, "known since 2026")
        XCTAssertEqual(p.accepts[0].ruleKey, "deny Fs dao")
    }

    func testMalformedLinesAreIgnoredAndListedNeverHonoured() {
        // ◆ no reason · names no parsed rule · missing `for` · deny entry with no effect
        let lines = [
            "accept dao.a Fs for deny Fs dao",
            "accept dao.a Fs for deny Fs app because x",
            "accept dao.a Fs deny Fs dao because x",
            "accept dao.a for deny Fs dao because x",
            "accept dao.a Fs for deny Fs dao because #1",
            "accept",
        ]
        let p = parsePolicy(rule + lines.joined(separator: "\n") + "\n")
        XCTAssertTrue(p.accepts.isEmpty, "every one of these must stay red")
        XCTAssertEqual(p.ignored.map(\.line), [2, 3, 4, 5, 6, 7])
        XCTAssertEqual(p.ignored[0].text, lines[0], "the source line, verbatim")
    }

    func testAllowAndOnlyRulesCannotBeNamed() {
        let p = parsePolicy("allow Net in dao ok.example\nonly dao -> infra\n"
                            + "accept dao.n Net for allow Net in dao ok.example because x\n"
                            + "accept dao.n for only dao -> infra because x\n")
        XCTAssertTrue(p.accepts.isEmpty)
        XCTAssertEqual(p.ignored.map(\.line), [3, 4])
    }

    func testForbidTakesNoEffectsAndDenyRequiresOne() {
        let p = parsePolicy("deny Fs dao\nforbid dao -> infra\n"
                            + "accept dao.a for forbid dao -> infra because x\n"
                            + "accept dao.a Fs for forbid dao -> infra because x\n"
                            + "accept dao.a for deny Fs dao because x\n")
        XCTAssertEqual(p.accepts.map(\.line), [3])
        XCTAssertTrue(p.accepts[0].forbid); XCTAssertEqual(p.accepts[0].code, "AS-EFF-009")
        XCTAssertEqual(p.ignored.map(\.line), [4, 5])
    }

    func testUnknownNeedsAnExplicitClassListAndAliasesAreMalformed() {
        let r = "deny Unknown dao\n"
        for bad in ["Unknown", "Unknown[*]", "Unknown[dynamic]", "Unknown[]", "Net[unknown-host]"] {
            let p = parsePolicy(r + "accept dao.c \(bad) for deny Unknown dao because x\n")
            XCTAssertTrue(p.accepts.isEmpty, bad)
            XCTAssertEqual(p.ignored.map(\.line), [2], bad)
            XCTAssertTrue(p.gateRefusals.isEmpty, "\(bad) is malformed, not a typo: the gate does not refuse")
        }
        let ok = parsePolicy(r + "accept dao.c Unknown[dispatch,native] for deny Unknown dao because x\n")
        XCTAssertEqual(ok.accepts.first?.classes, ["dispatch", "native"])
        XCTAssertEqual(ok.accepts.first?.effects, ["Unknown"])
        let alias = parsePolicy(r + "accept dao.c Unknown[corp] for deny Unknown dao because x\n", aliases: ["corp": ["reflect"]])
        XCTAssertTrue(alias.accepts.isEmpty, "a config alias name is not a class")
        XCTAssertEqual(alias.ignored.map(\.line), [2])
    }

    func testATypoedEffectOrClassTokenIsThePolicyErrorNotAnIgnoredLine() {
        let a = parsePolicy(rule + "accept dao.a Fss for deny Fs dao because x\n")
        XCTAssertEqual(a.gateRefusals.count, 1, "refuses the gate (exit 2), exactly as `deny Nett app` does")
        XCTAssertTrue(a.accepts.isEmpty)
        let b = parsePolicy("deny Unknown dao\naccept dao.c Unknown[dispatchh] for deny Unknown dao because x\n")
        XCTAssertEqual(b.gateRefusals.count, 1)
    }

    func testATypoOnAStructurallyMalformedLineIsIgnoredNotFatal() {
        // Structure is checked BEFORE the effect list (java, rust, swift agree): no reason ⇒ ignored; the typo is
        // never read.
        let p = parsePolicy(rule + "accept dao.a Fss for deny Fs dao\n")
        XCTAssertTrue(p.gateRefusals.isEmpty)
        XCTAssertEqual(p.ignored.map(\.line), [2])
    }

    func testAPositionalKeyIsRefusedAndTheCheckCanFail() {
        // The property, tested directly on this engine's own ordinal spellings.
        XCTAssertTrue(isAcceptPositionalKey("<main>#1"))
        XCTAssertTrue(isAcceptPositionalKey("<main>"))
        XCTAssertTrue(isAcceptPositionalKey("dao.f(Int)#2"))
        XCTAssertTrue(isAcceptPositionalKey("cfg#1"))
        XCTAssertFalse(isAcceptPositionalKey("dao.a"))
        XCTAssertFalse(isAcceptPositionalKey("dao.f(Int)"))
        XCTAssertFalse(isAcceptPositionalKey("dao.#x"), "a `#` not followed by a digit is not an ordinal")
        // …and through the parser: `<main>` is refused with the line listed. (`dao.f#1` can never reach the check —
        // a `#` begins a comment, so the line loses everything after it and is ignored for lacking `for`; that is
        // asserted below so the comment rule cannot be mistaken for the positional check.)
        let p = parsePolicy(rule + "accept <main> Fs for deny Fs dao because x\n")
        XCTAssertTrue(p.accepts.isEmpty); XCTAssertEqual(p.ignored.map(\.line), [2])
        XCTAssertTrue(p.ignored[0].reason.contains("POSITIONAL"), p.ignored[0].reason)
        let hash = parsePolicy(rule + "accept dao.f#1 Fs for deny Fs dao because x\n")
        XCTAssertTrue(hash.accepts.isEmpty); XCTAssertEqual(hash.ignored.map(\.line), [2])
        XCTAssertTrue(hash.ignored[0].reason.contains("`for`"), "ignored by the comment rule, not the positional one")
    }
}

final class AcceptLinesSettleTests: XCTestCase {

    private func entry(_ line: String, aliases: [String: Set<String>] = [:], rules: String = "deny Fs dao\n") -> AcceptEntry {
        parsePolicy(rules + line + "\n", aliases: aliases).accepts[0]
    }
    private func row(_ key: String = "deny Fs dao", name: String = "dao.a", eff: [String] = ["Fs"],
                     classes: [String] = [], hash: String = "ha") -> AcceptRow {
        AcceptRow(ruleKey: key, code: "AS-EFF-006", name: name, hash: hash, effects: eff, classes: classes)
    }
    private func settle(_ es: [AcceptEntry], _ rows: [AcceptRow], unevaluated: Set<String> = [],
                        twins: Set<String> = []) -> AcceptSettlement {
        settleAccepts(es, rows: rows, unevaluated: unevaluated, twinNames: twins, who: "t")
    }

    func testExactFnAcceptsAndOtherRowsStayRed() {
        let e = entry("accept dao.a Fs for deny Fs dao because x")
        let s = settle([e], [row(), row(name: "dao.b", hash: "hb")])
        XCTAssertEqual(s.acceptedRows, [0])
        XCTAssertEqual(s.items.map(\.status), ["accepted"])
        XCTAssertTrue(s.stale.isEmpty)
    }

    func testPrefixOfFnAcceptsNothing() {          // ◆ over-accept: dao.a must not cover dao.ab
        let e = entry("accept dao.a Fs for deny Fs dao because x")
        let s = settle([e], [row(name: "dao.ab", hash: "hab")])
        XCTAssertTrue(s.acceptedRows.isEmpty)
        XCTAssertEqual(s.stale.count, 1, "the row on dao.ab is not the entry's, so the entry matched nothing: stale")
    }

    func testAnEffectBeyondTheListIsNotCoveredAndTheEntryIsExceededNotStale() {   // ◆ no effect-subset test
        let e = entry("accept dao.a Fs for deny Fs Rand dao because x", rules: "deny Fs Rand dao\n")
        let s = settle([e], [row("deny Fs Rand dao", name: "dao.a", eff: ["Fs", "Rand"])])
        XCTAssertTrue(s.acceptedRows.isEmpty)
        XCTAssertEqual(s.items.map(\.status), ["exceeded"])
        XCTAssertTrue(s.stale.isEmpty, "exceeded is never also stale: stale would read as FIXED when the truth is WORSE")
        XCTAssertTrue(s.notes.joined().contains("widen the entry"), "carries a remedy")
    }

    func testTheRuleLineIsPartOfTheKey() {         // ◆ rule line not in key
        let e = entry("accept dao.a Fs for deny Fs dao because x", rules: "deny Fs dao\ndeny Fs\n")
        let s = settle([e], [row("deny Fs", name: "dao.a")])
        XCTAssertTrue(s.acceptedRows.isEmpty, "an entry for `deny Fs dao` must not accept the row `deny Fs` made")
    }

    func testARowTwoLinesMakeIsAcceptedOnlyIfBothLinesAreNamed() {   // ◆ matched after de-duplication
        let e = entry("accept dao.a Fs for deny Fs dao because x", rules: "deny Fs dao\ndeny Fs\n")
        let s = settle([e], [row("deny Fs dao"), row("deny Fs")])
        XCTAssertEqual(s.acceptedRows, [0], "only the named line's row")
    }

    func testTwinsAcceptNeither() {                // ◆ twins accepted
        let e = entry("accept dao.t Fs for deny Fs dao because x")
        let s = settle([e], [row(name: "dao.t", hash: "h1"), row(name: "dao.t", hash: "h2")], twins: ["dao.t"])
        XCTAssertTrue(s.acceptedRows.isEmpty)
        XCTAssertEqual(s.items.map(\.status), ["ambiguous"])
        XCTAssertTrue(s.stale.isEmpty)
    }

    func testAnUnevaluatedRulesEntryIsUnjudgedAndAcceptsNothing() {
        let e = entry("accept dao.a for forbid dao -> infra because x", rules: "forbid dao -> infra\n")
        let s = settle([e], [AcceptRow(ruleKey: "forbid dao -> infra", code: "AS-EFF-009", name: "dao.a", hash: "", effects: [], classes: [])],
                       unevaluated: ["forbid dao -> infra"])
        XCTAssertTrue(s.acceptedRows.isEmpty)
        XCTAssertEqual(s.items.map(\.status), ["unjudged"])
        XCTAssertTrue(s.stale.isEmpty)
    }

    func testUnknownIsCoveredOnlyByAFilterListingEveryClassOfTheRow() {      // ◆ class filter ignored
        let e = entry("accept dao.c Unknown[dispatch] for deny Unknown[dispatch,native] dao because x",
                      rules: "deny Unknown[dispatch,native] dao\n")
        let key = "deny Unknown[dispatch,native] dao"
        XCTAssertEqual(settle([e], [row(key, name: "dao.c", eff: ["Unknown"], classes: ["dispatch"])]).acceptedRows, [0])
        let moved = settle([e], [row(key, name: "dao.c", eff: ["Unknown"], classes: ["native"])])
        XCTAssertTrue(moved.acceptedRows.isEmpty, "the hole moved class: not the one that was accepted")
        XCTAssertEqual(moved.items.map(\.status), ["exceeded"])
        let both = settle([e], [row(key, name: "dao.c", eff: ["Unknown"], classes: ["dispatch", "native"])])
        XCTAssertTrue(both.acceptedRows.isEmpty, "a native hole appeared beside the dispatch one")
        let none = settle([e], [row(key, name: "dao.c", eff: ["Unknown"], classes: [])])
        XCTAssertTrue(none.acceptedRows.isEmpty, "classes not determinable ⇒ no filter covers it (fail closed)")
    }

    func testAnEntryIsStaleOnItsOwnEvenWhenAnotherEntryAcceptsTheRow() {
        let es = parsePolicy("deny Fs dao\naccept dao.a Fs for deny Fs dao because x\naccept dao.a Clock for deny Fs dao because x\n").accepts
        let s = settle(es, [row()])
        XCTAssertEqual(s.acceptedRows, [0])
        XCTAssertEqual(s.stale.map(\.line), [3], "the Clock entry accepted nothing")
        XCTAssertTrue(staleAcceptDetail(s.stale[0]).contains("Delete line 3"), "names the remedy")
    }

    func testItemsAreSortedByLineThenFn() {
        let es = parsePolicy("deny Fs dao\naccept dao.b Fs for deny Fs dao because x\naccept dao.a Fs for deny Fs dao because x\n").accepts
        let s = settle(es, [row(name: "dao.a", hash: "ha"), row(name: "dao.b", hash: "hb")])
        XCTAssertEqual(s.items.map(\.fn), ["dao.b", "dao.a"], "by line (2, 3), not by name")
    }
}
