import XCTest
import Foundation

/// SOUNDNESS R468 — `--target`'s stderr note NAMED TARGETS ITS OWN VERDICT EXCLUDED.
///
/// Measured on swift-argument-parser at `630f142`: `--target ArgumentParserEndToEndTests` printed
/// *"scanning 4 target(s) [ArgumentParser, ArgumentParserEndToEndTests, ArgumentParserTestHelpers,
/// ArgumentParserToolInfo] … This verdict covers that closure ONLY"* while the report held zero
/// functions from `Tests/` and filed 67 files under `harness-target`. Both statements are in the same
/// envelope and they contradict each other — a FALSE DISCLOSURE, which this register treats as worse
/// than silence, because the reader checking whether their test target was judged reads the sentence.
///
/// The cause is ordering, not logic: the note printed the RESOLVER's closure, and the harness/test
/// exclusions run before it. The fix derives the named list from the files that survived into
/// `sourcePaths`, so the sentence cannot disagree with the verdict it introduces. This file is what
/// stops it drifting back: a restated note is green on every suite until someone reads the stderr.
final class TargetNoteDerivationProcessTests: XCTestCase {

    /// A package with a library target and a TEST target that depends on it. The test target's sources
    /// live under `Tests/`, which the harness walk excludes as `harness-target` long before `--target`
    /// resolution runs — so the closure names it and the verdict cannot cover it.
    private func makeLibAndTestsPackage() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-r468-\(UUID().uuidString)")
        let lib = root.appendingPathComponent("Sources/Core")
        let tests = root.appendingPathComponent("Tests/CoreTests")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Core",
            targets: [
                .target(name: "Core"),
                .testTarget(name: "CoreTests", dependencies: ["Core"]),
            ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public func libWork() { try? "x".write(toFile: "/tmp/core", atomically: true, encoding: .utf8) }
        """.write(to: lib.appendingPathComponent("Core.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        func testWork() { try? "x".write(toFile: "/tmp/test", atomically: true, encoding: .utf8) }
        """.write(to: tests.appendingPathComponent("CoreTests.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private func note(_ root: URL, target: String) throws -> (note: String, json: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--target", target, "--json"])
        let line = r.err.split(separator: "\n").first { $0.contains("--target \(target) —") }
        return (line.map(String.init) ?? r.err, r.out)
    }

    /// THE DEFECT: naming a target the verdict does not cover.
    func testR468TheTargetNoteNamesOnlyTargetsThatContributedAFile() throws {
        let root = try makeLibAndTestsPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let (line, json) = try note(root, target: "CoreTests")

        // CALIBRATION — the run must actually have resolved a closure containing the test target, or
        // the assertions below are about a note that was never printed.
        XCTAssertTrue(line.contains("--target CoreTests"),
                      "no --target disclosure line was printed at all: \(line)")
        // The verdict genuinely excludes it: no function from Tests/ is in the report.
        let fns = try ProcessHarness.fns(ofJson: json)
        XCTAssertNil(fns["testWork"],
                     "premise check: the test target's function must NOT be in the report, or this is "
                     + "not the shape R468 is about: \(json)")

        XCTAssertFalse(line.contains("scanning 2 target(s) [Core, CoreTests]"),
                       "R468: the note must not present an excluded target as scanned: \(line)")
        XCTAssertTrue(line.contains("scanning 1 target(s) [Core]"),
                      "the scanned list is derived from the files that survived: \(line)")
        XCTAssertTrue(line.contains("NOT covered [CoreTests]"),
                      "…and the excluded closure member is named as excluded, not omitted — silence "
                      + "here would trade a false statement for a missing one: \(line)")
    }

    /// THE OVER-CHARGE CONTROL, and it is the direction that would hurt: a target that DID contribute
    /// files must never be reported as uncovered. A note that cries "NOT covered" over a real scan is
    /// the same false-disclosure defect pointing the other way.
    func testATargetThatContributedFilesIsNotReportedUncovered() throws {
        let root = try makeLibAndTestsPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let (line, json) = try note(root, target: "Core")
        XCTAssertTrue(line.contains("scanning 1 target(s) [Core]"), "\(line)")
        XCTAssertFalse(line.contains("NOT covered"),
                       "Core contributed its sources; claiming otherwise is the mirror defect: \(line)")
        let fns = try ProcessHarness.fns(ofJson: json)
        XCTAssertNotNil(fns["libWork"], "the library's effectful function must be in the report: \(json)")
    }
}
