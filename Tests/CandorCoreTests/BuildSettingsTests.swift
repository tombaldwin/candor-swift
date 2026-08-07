// The build-settings evaluator's regression battery.
//
// Every case here is a CONFIRMED flip from one of the three adversarial reviews of this reader — each
// one a key counted DECLARED when the shipped build has none, which is the answer that gets an app
// rejected after candor said it was clean. They had never been tested because the evaluator lived in
// the executable target; that is why there are fourteen of them.
//
// The `NONE` cases are the cardinal-sin direction and matter most. The declared cases are the mirror:
// a false "missing key" warning is what teaches a reader to distrust the verb, and three of the flips
// were introduced by a fix for the other direction.

import XCTest
@testable import CandorCore

final class BuildSettingsTests: XCTestCase {

    private func keys(_ text: String) -> Set<String> { usageKeysInBuildSettings(text) }
    // The build-setting SPELLING (what appears in the file) …
    private let cam = "INFOPLIST_KEY_NSCameraUsageDescription"
    private let mic = "INFOPLIST_KEY_NSMicrophoneUsageDescription"
    // … and the INFO.PLIST KEY the evaluator must return, which is what the caller unions with the keys
    // read from the plist. Returning the prefixed form matches nothing and reads as MISSING for every
    // app that declares via build settings — the mirror defect, caught by a negative control.
    private let camKey = "NSCameraUsageDescription"
    private let micKey = "NSMicrophoneUsageDescription"

    // ── The cardinal-sin direction: none of these ship a camera usage description.

    func testKeyNameInsideAnotherSettingsQuotedValueIsNotADeclaration() {
        XCTAssertEqual(keys(#"shellScript = "echo \#(cam) = present";"#), [])
    }

    func testTwoSettingsOnOneLineAreTwoAssignments() {
        // The empty CAM had been read as declared (its "value" ran to end of line) AND the genuine MIC
        // was never seen — both honesty halves broken by one line.
        XCTAssertEqual(keys(#"\#(cam) = ""; \#(mic) = "Record audio";"#), [micKey])
    }

    func testEveryBracketGroupIsSkippedNotJustTheFirst() {
        // Only the first `]` was skipped, so the "value" was `*] = ""` — non-empty, declared.
        XCTAssertEqual(keys(#""\#(cam)[config=Debug][sdk=*]" = "";"#), [])
        XCTAssertEqual(keys(#"\#(cam)[config=Debug][sdk=*] = "";"#), [])
    }

    func testASlashStarInsideAQuotedPathDoesNotOpenABlockComment() {
        // `"$(SRCROOT)/Vendor/**"` opened a comment that swallowed the later undeclare.
        XCTAssertEqual(keys("""
        HEADER_SEARCH_PATHS = "$(SRCROOT)/Vendor/**";
        \(cam) = "Take photos";
        \(cam) = "";
        """), [])
    }

    func testAKeyEmptyInAnyConfigurationIsNotDeclared() {
        // Last-assignment-wins made the answer depend on serialisation order, and an App Store archive
        // is RELEASE. Both orders must agree, and both must be "not declared".
        XCTAssertEqual(keys("\(cam) = \"\";\n\(cam) = \"Take photos\";"), [])
        XCTAssertEqual(keys("\(cam) = \"Take photos\";\n\(cam) = \"\";"), [])
    }

    func testCommentedOutKeysAreNotDeclarations() {
        XCTAssertEqual(keys("// \(cam) = For photos"), [])
        XCTAssertEqual(keys("# \(cam) = For photos"), [])
        XCTAssertEqual(keys("/* \(cam) = disabled */"), [])
    }

    func testUnclosedBlockCommentRunsToEndOfFile() {
        // What xcodebuild sees. The stripper had skipped only CLOSED blocks.
        XCTAssertEqual(keys("/* disabled:\n\(cam) = \"For photos\";"), [])
    }

    func testValuesThatAreOnlyBuildVariablesAreNotDeclarations() {
        // `$(inherited)` with nothing to inherit resolves to EMPTY at build time.
        XCTAssertEqual(keys("\(cam) = $(inherited);"), [])
        XCTAssertEqual(keys(#"\#(cam) = "${FOO}";"#), [])
        XCTAssertEqual(keys("\(cam) = $FOO;"), [])
        XCTAssertEqual(keys(#"\#(cam) = "$(inherited)";"#), [])
    }

    func testCRLFDoesNotDefeatTheEmptyValueGuard() {
        // `.whitespaces` never trims `\r`, so the `;` and quote strips missed and BOTH earlier fixes
        // came back at once.
        XCTAssertEqual(keys("\(cam) = \"\";\r\n"), [])
        XCTAssertEqual(keys("\(cam) = $(inherited);\r\n"), [])
    }

    // ── The mirror direction: these DO ship one, and calling them missing is the failure that teaches
    // a reader to distrust the verb.

    func testRealDeclarationsAreFound() {
        XCTAssertEqual(keys(#"\#(cam) = "Take photos";"#), [camKey])
        XCTAssertEqual(keys("\(cam) = Take photos;"), [camKey])
        XCTAssertEqual(keys("\t\(cam)\t=\t\"Take photos\";"), [camKey])
    }

    func testCommentMarkersInsideAQuotedValueArePartOfTheValue() {
        // `##"…"##`: the `"#` in the value would close a `#"…"#` raw string.
        XCTAssertEqual(keys(##"\##(cam) = "#1 best camera app";"##), [camKey])
        XCTAssertEqual(keys(#"\#(cam) = "See https://example.com/x";"#), [camKey])
        XCTAssertEqual(keys(#"\#(cam) = "a // b";"#), [camKey])
    }

    func testAConditionalDeclarationStillCounts() {
        // The condition is a build detail; the declaration is real. Xcode writes the name quoted.
        XCTAssertEqual(keys(#""\#(cam)[sdk=iphoneos*]" = "For photos";"#), [camKey])
        XCTAssertEqual(keys(#"\#(cam)[sdk=iphoneos*] = "For photos";"#), [camKey])
    }

    func testEscapedQuotesInsideAValueDoNotEndIt() {
        XCTAssertEqual(keys(#"\#(cam) = "a \"quoted\" bit";"#), [camKey])
    }

    func testSemicolonInsideAQuotedValueDoesNotSplitTheStatement() {
        XCTAssertEqual(keys(#"\#(cam) = "photos; videos";"#), [camKey])
    }

    func testAClosedBlockCommentInsideALineIsRemovedWithoutEatingTheValue() {
        XCTAssertEqual(keys(#"\#(cam) /* why */ = "For photos";"#), [camKey])
    }

    // ── FLIP #15: the comment strippers and the statement splitter each tracked quotes SEPARATELY, so
    // any one of them desynchronising corrupted everything after it. Now one state machine.

    func testAStrayQuoteInALineCommentDoesNotResurrectACommentedOutBlock() {
        // The block-comment pass ran on RAW text, so this line comment's lone `"` opened a string and the
        // `/* … */` after it was never stripped — a commented-out key read as DECLARED, verified end to
        // end as exit 0 on an app whose plist has none.
        XCTAssertEqual(keys("""
        // the "shared config
        /*
        \(cam) = "For photos"
        */
        """), [])
    }

    func testALineCommentContainingASlashStarDoesNotEatTheRestOfTheFile() {
        // The mirror of the above, in the loss direction.
        XCTAssertEqual(keys("""
        // see the note /* about camera
        \(cam) = "For photos";
        \(mic) = "Rec";
        """), [camKey, micKey])
    }

    func testAMultiLineQuotedValueDoesNotSwallowALaterUndeclare() {
        // Legal in an OpenStep plist. The per-line comment pass cut this value's `#` with a fresh quote
        // state, taking the closing quote with it, and the splitter then absorbed the empty undeclare.
        XCTAssertEqual(keys("""
        \(cam) = "For photos";
        RELEASE_NOTES = "line one
        see # note";
        \(cam) = "";
        """), [])
    }

    func testAnIncludeDirectiveSurvivesCommentStripping() {
        XCTAssertEqual(keys("#include \"other.xcconfig\"\n\(cam) = \"For photos\";"), [camKey])
    }

    // ── FLIP #16: the `#include` branch copied its whole line VERBATIM to preserve the directive, so a
    // comment opened on that line never registered.

    func testAnIncludeLineCanStillOpenABlockComment() {
        // Identical to the control below except for the `#include`, which is what makes it diagnostic.
        XCTAssertEqual(keys("""
        #include "shared.xcconfig" /* disabled:
        \(cam) = "For photos"
        */
        """), [])
        XCTAssertEqual(keys("""
        /* disabled:
        \(cam) = "For photos"
        */
        """), [], "control: the same file without the include line")
    }

    func testALineCommentOnAnIncludeLineIsStillAComment() {
        XCTAssertEqual(keys("#include \"x.xcconfig\" // \(mic) = \"m\"\n\(cam) = \"For photos\";"),
                       [camKey], "the mic key is inside a comment; the camera key is not")
    }

    func testOnlyTheDirectiveItselfIsADirective() {
        // A bare `hasPrefix` also matched these, so the rest of the line survived as code.
        XCTAssertEqual(keys("#includes \(cam) = \"For photos\";"), [])
        XCTAssertEqual(keys("#include_foo \(cam) = \"For photos\";"), [])
        XCTAssertEqual(keys("#include? \"x.xcconfig\"\n\(cam) = \"For photos\";"), [camKey],
                       "…but xcconfig's optional form IS one")
    }

    // ── The consistency rule itself, which replaced last-wins.

    func testInconsistentDeclarationIsReportedSeparatelyAndNotCountedAsDeclared() {
        let a = usageAssignmentsInBuildSettings("\(cam) = \"real\";\n\(cam) = \"\";")
        let r = declaredKeys(from: a)
        XCTAssertEqual(r.declared, [], "an assignment that leaves the key empty must not read as declared")
        XCTAssertEqual(r.inconsistent, [camKey], "…and the disagreement is a finding about the project")
    }

    func testAKeyDeclaredEverywhereIsNotFlaggedInconsistent() {
        let a = usageAssignmentsInBuildSettings("\(cam) = \"a\";\n\(cam) = \"b\";")
        let r = declaredKeys(from: a)
        XCTAssertEqual(r.declared, [camKey])
        XCTAssertEqual(r.inconsistent, [])
    }

    // ── Shapes that must not be read as usage-description assignments at all.

    func testNonUsageDescriptionSettingsAreIgnored() {
        XCTAssertEqual(keys(#"INFOPLIST_KEY_CFBundleDisplayName = "MyApp";"#), [])
        XCTAssertEqual(keys(#"SOME_OTHER_NSCameraUsageDescription = "x";"#), [])
    }

    func testAnAssignmentWithNoEqualsIsNotADeclaration() {
        XCTAssertEqual(keys("\(cam);"), [])
    }
}
