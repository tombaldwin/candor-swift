import XCTest
import Foundation

/// SOUNDNESS R1938 (lane L0) — the matrix's own checks. No process is spawned.
///
/// A `target` column that equals `main` in every arm, or a table that forgets an executed cell, would make the later lanes'
/// acceptance tests vacuous: they would pass on an engine that changed nothing. These tests are the proof the columns can fail.
final class TypeIdentityTargetCalibrationTests: XCTestCase {
    typealias H = TypeIdentityHarness

    /// Every cell that names a lane must have a target that main does NOT satisfy in at least one arm: otherwise flipping its lane
    /// flag asserts nothing. (`CANDOR_IDENT_EXPECT_TARGET=all` then makes the matrix FAIL on this branch, which is the other half
    /// of the calibration; the report quotes the count.)
    func testEveryTargetDiffersFromMainInSomeArm() {
        for (name, f) in TypeIdentityFixtures.all {
            for c in H.cells(f.table) {
                guard let t = c.target, let lane = c.lane else { continue }
                var arms: [(String, String, String)] = [("un", c.main.un, t.un), ("ch", c.main.ch, t.ch)]
                if let m = c.main.unr, let tu = t.unr { arms.append(("unr", m, tu)) }
                let differs = arms.contains { arm in !arm.2.split(separator: "/").contains { H.satisfies(arm.1, String($0)) } }
                XCTAssertTrue(differs, "\(name) \(c.fn) [\(lane.rawValue)]: target \(t) is satisfied by main's reading — the cell would pass on an unchanged engine")
            }
        }
    }

    /// Every lane that has a design target has at least one cell, and every cell names a lane the harness knows.
    func testEveryLaneOwnsCells() {
        var byLane: [TypeIdentityLane: Int] = [:]
        for (_, f) in TypeIdentityFixtures.all { for c in H.cells(f.table) { if let l = c.lane { byLane[l, default: 0] += 1 } } }
        for l in TypeIdentityLane.allCases { XCTAssertGreaterThan(byLane[l] ?? 0, 0, "lane \(l.rawValue) owns no cell") }
    }

    /// Every executed cell of every fixture is in its table (a fixture's ground truth is the cell list), with the same truth.
    func testTablesCoverEveryExecutedCell() throws {
        for (name, f) in TypeIdentityFixtures.all {
            let truth = try H.truth(file: f.truthFile)
            let table = Dictionary(uniqueKeysWithValues: H.cells(f.table).map { ($0.fn, $0.truth) })
            XCTAssertEqual(Set(truth.keys), Set(table.keys), "\(name): table cells and executed cells differ")
            for (fn, t) in truth { XCTAssertEqual(table[fn], t, "\(name) \(fn)") }
        }
    }

    /// The matcher: a pure target is exact, a charged one names the effect set and requires the flags it lists.
    func testSatisfiesMatcher() {
        XCTAssertTrue(H.satisfies("ABSENT", "ABSENT")); XCTAssertFalse(H.satisfies("-", "ABSENT")); XCTAssertFalse(H.satisfies("-+U", "-"))
        XCTAssertTrue(H.satisfies("Fs+inc", "Fs")); XCTAssertTrue(H.satisfies("Fs+U+inc", "Fs+inc")); XCTAssertFalse(H.satisfies("Fs", "Fs+inc"))
        XCTAssertFalse(H.satisfies("Fs+Net", "Fs")); XCTAssertFalse(H.satisfies("ABSENT", "-+inv")); XCTAssertTrue(H.satisfies("-+U+inv", "-+inv"))
        XCTAssertFalse(H.satisfies("-+U", "-+inv")); XCTAssertFalse(H.satisfies("Fs+inc", "-+inv"))
    }

    /// The reading notation round-trips the engine's rows.
    func testReadingNotation() {
        XCTAssertEqual(IdentityRow.reading(nil), "ABSENT")
        XCTAssertEqual(IdentityRow.reading(IdentityRow(effects: [], unknown: false, unknownWhy: [], invisible: [], incomplete: false, dispatchesOn: [])), "-")
        XCTAssertEqual(IdentityRow.reading(IdentityRow(effects: ["Fs"], unknown: true, unknownWhy: [], invisible: ["G"], incomplete: true, dispatchesOn: [])), "Fs+U+inv+inc")
    }
}

/// `tools/identity-exec.sh --check`: EXECUTE every fixture under swiftc and diff against the checked-in ground truth. Off by default
/// (it builds twenty small packages); CI and a lane run it with `CANDOR_IDENT_EXEC=1`.
final class TypeIdentityExecutionTests: XCTestCase {
    func testEveryFixtureExecutesToItsCheckedInGroundTruth() throws {
        guard ProcessInfo.processInfo.environment["CANDOR_IDENT_EXEC"] == "1" else { throw XCTSkip("set CANDOR_IDENT_EXEC=1 to execute the fixtures under swiftc") }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/identity-exec.sh")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-identity-exec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let r = try ProcessHarness.runRaw(URL(fileURLWithPath: "/bin/bash"), [script.path, "--check", "--scratch", scratch.path])
        XCTAssertEqual(r.code, 0, "fixture execution differs from the checked-in ground truth:\n\(r.out)\n\(r.err)")
    }
}
