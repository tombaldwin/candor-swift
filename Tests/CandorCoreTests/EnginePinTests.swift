// The engine-pin grammar, as a unit test rather than a forty-minute cross-engine run.
//
// Every row here was verified by hand across all five engines during the ⟨0.27⟩ release review, and
// then existed nowhere: conformance PART 33 pins the BEHAVIOUR five-way, which is the right thing for a
// contract but a slow and coarse instrument for a grammar. A rule with several spellings gets one row
// there, and the review's own lesson was that a row pinning one spelling pins one spelling — the
// two-token `engine 0.26.0 oops` was green five-way while the one-token `engine garbage` split the
// family four against one, silently, for as long as the row existed.
//
// So: the spellings live here, where they are cheap, and PART 33 keeps proving the five engines agree.

import XCTest
@testable import CandorCore

final class EnginePinTests: XCTestCase {

    private let running = "0.27.0"
    private func verdict(_ config: String) -> PinVerdict {
        pinVerdict(enginePinFor(config, "swift"), running)
    }

    // ── The four verdicts, in their plainest spellings.

    func testTheFourVerdicts() {
        XCTAssertEqual(verdict(""), .absent, "no `engine` line at all")
        XCTAssertEqual(verdict("engine 0.27.0"), .match)
        XCTAssertEqual(verdict("engine v0.27.0"), .match, "a leading `v` is accepted")
        XCTAssertEqual(verdict("engine 0.27"), .match, "a two-part version normalises to .0")
        XCTAssertEqual(verdict("engine 0.26.0"), .mismatch)
        XCTAssertEqual(verdict("engine latest"), .malformed,
                       "`latest` is NOT a version that can never match — the operator must be able to "
                       + "tell 'wrong version' from 'that is not a version'")
    }

    // ── Separators. A NO-BREAK SPACE here went silently unenforced in two of five engines while the
    // line was reported as an "unknown config key" — a false disclosure sitting on a fail-open.

    func testUnicodeWhitespaceSeparatesTheKeyFromItsValue() {
        for (name, sep) in [("space", " "), ("tab", "\t"), ("no-break space", "\u{00A0}"),
                            ("em space", "\u{2003}"), ("mixed", " \u{00A0}\t")] {
            XCTAssertEqual(verdict("engine\(sep)0.26.0"), .mismatch,
                           "a MISMATCHED pin separated by a \(name) must still be read")
            XCTAssertEqual(verdict("engine\(sep)0.27.0"), .match,
                           "…and a MATCHING one separated the same way must still hold — an engine "
                           + "must not pass by rejecting the whole line")
        }
    }

    func testCRLFIsNotPartOfTheVersion() {
        XCTAssertEqual(verdict("engine v0.27.0\r\n"), .match,
                       "one engine refused a matching pin on a Windows checkout: same file, two meanings")
    }

    func testTrailingCommentIsNotPartOfTheVersion() {
        XCTAssertEqual(verdict("engine 0.27.0  # pinned with the baseline"), .match)
    }

    // ── Qualification. One config serves a polyglot repo, so a qualified line is not ours…

    func testAQualifiedPinForAnotherImplIsNotOurs() {
        XCTAssertEqual(verdict("engine java 0.0.1"), .absent)
        XCTAssertEqual(verdict("engine rust v9.9.9\nengine ts 1.2.3"), .absent)
    }

    func testAKnownQualifierDecidesOwnershipBeforeArity() {
        // `engine swift` (no version) must not read as a WILDCARD pin whose version is the literal
        // "swift" — that made one operator's forgotten version kill the whole family's runs.
        XCTAssertEqual(verdict("engine java"), .absent, "another impl's line, whatever follows it")
        XCTAssertEqual(verdict("engine java 0.0.1 junk"), .absent, "the skip is WHOLE-LINE")
    }

    func testOurOwnQualifiedPinIsEnforced() {
        XCTAssertEqual(verdict("engine swift 0.26.0"), .mismatch)
        XCTAssertEqual(verdict("engine swift v0.27.0"), .match)
        XCTAssertEqual(verdict("engine java 0.0.1\nengine swift 0.27.0"), .match)
    }

    func testAQualifiedPinWinsOverAnUnqualifiedOne() {
        XCTAssertEqual(verdict("engine 0.0.1\nengine swift 0.27.0"), .match)
    }

    // ── …but unreadability is a property of the LINE, and precedence only decides which VERSION
    // applies. The reference engine was the sole non-conformer here.

    func testAnUnreadableUnqualifiedLineIsNotHiddenByAQualifiedPin() {
        for junk in ["garbage", "0.26.0 oops", "latest", "vv0.27.0"] {
            XCTAssertEqual(verdict("engine \(junk)\nengine swift 0.27.0"), .malformed,
                           "`engine \(junk)` is still yours to read, even beside a pin that applies")
        }
    }

    func testAtMostOneLeadingV() {
        XCTAssertEqual(verdict("engine vv0.27.0"), .malformed,
                       "two engines stripped every `v`, so `vv0.27.0` was a valid pin to them")
    }

    func testTwoLinesThatDisagreeAreMalformedRatherThanLastWins() {
        XCTAssertEqual(verdict("engine 0.27.0\nengine 0.26.0"), .malformed,
                       "one silently discarding the other is the failure this key exists to stop")
        XCTAssertEqual(verdict("engine swift 0.27.0\nengine swift 0.26.0"), .malformed)
    }

    func testTwoIDENTICALLinesAreNotADisagreement() {
        XCTAssertEqual(verdict("engine 0.27.0\nengine 0.27.0"), .match)
    }

    // ── Digits. The review reported that Unicode digits normalise here and hide an unreadable line;
    // measured across five engines they do NOT, and this pins which reading is right.

    func testNonAsciiDigitsAreNotAVersion() {
        XCTAssertEqual(verdict("engine ٣.٣"), .malformed, "Arabic-Indic digits are not a version")
        XCTAssertEqual(verdict("engine ².0"), .malformed, "…nor is a superscript")
        XCTAssertEqual(verdict("engine ٣.٣\nengine swift 0.27.0"), .malformed,
                       "…and an unreadable line stays unreadable beside a qualified pin")
    }

    // ── The engine's own version is an input too.

    func testAnUndeterminedRunningVersionIsDisclosedNeverScored() {
        XCTAssertEqual(pinVerdict("0.27.0", ""), .undetermined)
        XCTAssertEqual(pinVerdict("0.27.0", "unknown"), .undetermined,
                       "a build that cannot say what it is cannot be judged against a pin")
    }

    func testNormalisationRoundTrip() {
        XCTAssertEqual(normalizePinVersion("v1.2"), "1.2.0")
        XCTAssertEqual(normalizePinVersion("1.2.3"), "1.2.3")
        XCTAssertNil(normalizePinVersion("1"))
        XCTAssertNil(normalizePinVersion("1.2.3.4"))
        XCTAssertNil(normalizePinVersion("1..3"))
        XCTAssertNil(normalizePinVersion(""))
    }
}
