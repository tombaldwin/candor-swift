import XCTest
import Foundation

/// SOURCE-HYGIENE CENSUS — ported from candor-java's `SourceHygieneTest` (BACKLOG item 3).
///
/// Every assertion reads this engine's OWN SOURCE and counts. The defects it catches are invisible to
/// every behavioural test: a rule stated once and then silently copied, or a single rule nothing asks any
/// more. Both keep the suite green. Each carries a VACUITY FLOOR so the census cannot pass by failing to
/// find the source it asserts about.
///
/// **WHERE THIS PORT DEPARTS FROM THE JAVA ORIGINAL.** java asserts the reserved segments are listed
/// exactly ONCE. Asserting that here would be wrong and acting on it would be a bug: this engine's
/// `reportSidecarSegments()` is a deliberate SUBSET of the reserved set used on a DELETION path, where a
/// miss is cheap and an over-reach destroys the operator's verdict document. So this pins the
/// DIFFERENCE — which fails in both directions: widening the sweep and narrowing the reserved set both
/// go red.
final class SourceHygieneTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }


    /// The string literals of a `let <name> = [...]` array, taken from the array ITSELF rather than by
    /// searching the file — see the note in the test below for why that distinction is load-bearing.
    private static func segments(of name: String, in src: String) -> [String] {
        guard let declRange = src.range(of: "let \(name)"),
              let open = src.range(of: "[", range: declRange.upperBound..<src.endIndex),
              let close = src.range(of: "]", range: open.upperBound..<src.endIndex) else { return [] }
        return src[open.upperBound..<close.lowerBound]
            .split(separator: ",")
            .compactMap { part in
                let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.hasPrefix("\""), t.hasSuffix("\""), t.count > 2 else { return nil }
                return String(t.dropFirst().dropLast())
            }
    }

    private func count(_ haystack: String, _ needle: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// SPEC §2.2's reserved set has ONE owner in this engine, and the one place that narrows it does so
    /// BY NAME.
    ///
    /// §2.2 exists, in its own words, *"because the engines were already drifting on it"* — three of the
    /// four excluded these by name and one by segment count, and the by-name lists disagreed. Measured
    /// 2026-09-13 across the family: rust swept a hardcoded five against a seven-name const, and
    /// candor-ts's `isReport` was missing `layerreach` outright, so a real candor-rust sidecar came back
    /// `true` from the predicate that decides what a report is.
    func testTheReservedSidecarSetHasOneOwnerAndItsNarrowingIsNamed() throws {
        let arming = try Self.read("Sources/candor-swift/GateSinkArming.swift")

        // VACUITY FLOOR.
        XCTAssertTrue(arming.contains("let reservedSidecarSegments"),
            "located no reserved-segment set — this census is asserting about source it can no longer "
            + "find, and would go green through the very defect it exists to catch")

        // PARSE THE ARRAY, never `contains` over the whole file. The first cut of this test asked
        // `arming.contains("\"refused\"")` — and `"refused"` also appears in this same file three times
        // as a JSON `reasonKey`, so the assertion passed no matter what the array held. Calibration
        // caught it: renaming the segment to `refuzed` left the census GREEN. Vacuous for precisely the
        // one segment ⟨0.32⟩ added, which is the one this engine's stale comment had already dropped.
        let listed = Self.segments(of: "reservedSidecarSegments", in: arming)
        XCTAssertEqual(listed.count, 7,
            "expected SPEC §2.2's seven reserved segments in reservedSidecarSegments, found \(listed)")
        for seg in ["calibrated", "callgraph", "gate", "hierarchy", "layerreach", "locs", "refused"] {
            XCTAssertTrue(listed.contains(seg),
                "SPEC §2.2 reserves `\(seg)`; reservedSidecarSegments lists \(listed). ⟨0.32⟩ added "
                + "`refused` and this engine's own comment went stale on exactly that name — it "
                + "enumerated six segments plus the family and called them SEVEN.")
        }

        XCTAssertTrue(arming.contains("reservedSidecarSegments.filter { !reportSidecarExcluded.contains($0) }"),
            "reportSidecarSegments() must DERIVE from the reserved set, not restate it — a copy drifts, "
            + "and an eighth reserved segment must reach this sweep by being added in one place")

        XCTAssertTrue(arming.contains("reportSidecarExcluded: Set<String> = [\"gate\", \"refused\"]"),
            "the two names taken out must be NAMED, so the narrowing reads as deliberate rather than as "
            + "an omission. `gate` is the VERDICT SINK's document (deleting it from the report sink fails "
            + "OPEN); `refused` is the ⟨0.32⟩ marker whose guarantee is that a LOST marker fails OPEN "
            + "while a STALE one fails CLOSED.")
    }

    /// THE ONE RULE MUST ACTUALLY BE ASKED. A function nothing consults has stopped being the owner, and
    /// the copies that replaced it are invisible until two of them disagree.
    func testTheReservedSetIsConsultedByMoreThanOneCaller() throws {
        let arming = try Self.read("Sources/candor-swift/GateSinkArming.swift")
        let fixCLI = try Self.read("Sources/candor-swift/FixCLI.swift")
        let gateCLI = try Self.read("Sources/candor-swift/GateReportCLI.swift")

        let uses = count(arming, "reportSidecarSegments()")
            + count(fixCLI, "reportSidecarSegments()")
            + count(gateCLI, "reportSidecarSegments()")
        XCTAssertGreaterThanOrEqual(uses, 3,
            "the single reserved-segment rule must actually be CONSULTED — fewer than three references "
            + "means a locator has stopped asking it and is discriminating some other way, which is the "
            + "drift SPEC §2.2 was written to stop. Found \(uses)")

        // …and nobody may re-type the segments locally.
        XCTAssertEqual(count(fixCLI, "\"layerreach\""), 0,
            "FixCLI must consult reportSidecarSegments(), never its own copy of the segment names")
        XCTAssertEqual(count(gateCLI, "\"layerreach\""), 0,
            "GateReportCLI must consult reportSidecarSegments(), never its own copy — its doc already "
            + "says it 'reads reportSidecarSegments() rather than its own'; this makes that true")
    }
}
