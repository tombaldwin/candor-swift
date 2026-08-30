import XCTest
import Foundation

/// CONSTANT PROVENANCE rung 4 (`homeAnchoredPath` in `CallCollector.swift`) resolves a COMPUTED path
/// expression (one `plainStringLiteralValue` already failed on) far enough to name a protected-folder
/// class, but ONLY when the computation is anchored at `NSHomeDirectory()` /
/// `homeDirectoryForCurrentUser`. The recursive `A + B` walk carries an explicit guard for exactly this:
///
///     guard out.hasPrefix("/Users/_") else { return nil }   // only a HOME anchor decides a class
///
/// This guard sits on the silent-vs-disclosed boundary: without it, a `+`-concatenation of two PLAIN
/// literals that has nothing to do with the user's home directory (e.g. a literal `/Volumes/...` path,
/// or someone else's `/Users/<name>` — a real path, but not `/Users/_`, the class this rung exists to
/// name) still walks all the way through the function and RESOLVES, because the "plain literal
/// contributes itself" arm earlier in the same function makes no distinction between a home call and an
/// arbitrary string. The guard is the only thing stopping that resolved-but-not-home-anchored value from
/// reaching `pathClasses(_:)`, which itself matches OTHER prefixes (`/Volumes/`, `smb://`, …) that have
/// nothing to do with this rung's home-only contract. Delete the guard and a fully-invented reach
/// (`FolderDocuments`/`RemovableVolume`/`NetworkVolume` disclosed as a CLEAN, fully-resolved surface)
/// silently replaces the honest `incomplete` disclosure the docstring promises ("Returns nil — NOT a
/// guess — for anything else"). Measured: `swift build`, `swift test` (942/942), `smoke.sh`, both
/// `fabrication_probe.py` and `fuzz.py`, and `ci/self-gate.sh` all stayed green with the guard deleted —
/// this suite is what makes deleting it RED.
final class HomeAnchoredPathGuardProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: HomeAnchoredPathGuardProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    private func incompleteEffects(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["incomplete"] as? [String] ?? []).sorted()
    }
    private func direct(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["direct"] as? [String] ?? []).sorted()
    }

    /// THE POSITIVE CONTROL — proves the mechanism itself still works: `NSHomeDirectory() + "/Desktop/x"`
    /// is a genuine home anchor and must still resolve to the protected-folder class. A fix or a test
    /// that broke this in the name of closing the guard's gap would trade one defect for another.
    func testHomeDirectoryConcatenationStillResolvesToProtectedFolder() throws {
        let by = try scan("""
        import Foundation
        func readDesktop() {
            let d = Data(contentsOfFile: NSHomeDirectory() + "/Desktop/x")
            print(d as Any)
        }
        """)
        XCTAssertEqual(direct(by, "readDesktop"), ["Fs", "FolderDesktop"].sorted(),
                       "a genuine home anchor must still resolve — the guard must not overcorrect")
        XCTAssertEqual(incompleteEffects(by, "readDesktop"), [],
                       "a home-anchored concatenation is fully determined, not incomplete")
    }

    /// THE GUARD ITSELF. Two PLAIN literals concatenated with `+` under `/Volumes/` have no home anchor
    /// anywhere in the expression — `homeAnchoredPath`'s docstring calls anything reaching this point
    /// without one "genuinely undetermined", to be "counted by the `incomplete` disclosure rather than
    /// classified on a hunch." Deleting the `hasPrefix("/Users/_")` guard lets the plain-literal arm's
    /// verbatim contribution stand in for a home anchor and resolves this to `RemovableVolume` +
    /// `NetworkVolume` via `pathClasses`'s UNRELATED `/Volumes/` prefix match — a fabricated, fully
    /// "resolved" surface exactly where the design says it must stay `incomplete`.
    func testNonHomeVolumeConcatenationStaysIncompleteNotGuessed() throws {
        let by = try scan("""
        import Foundation
        func readIt() {
            let d = Data(contentsOfFile: "/Volumes/External" + "/Documents/x")
            print(d as Any)
        }
        """)
        XCTAssertEqual(direct(by, "readIt"), ["Fs"],
                       "no path class may be invented for a non-home-anchored literal concatenation")
        XCTAssertEqual(incompleteEffects(by, "readIt"), ["Fs"],
                       "the destination stays genuinely undetermined per the docstring's own contract")
    }

    /// The mirror closest to the guard's own wording: a literal `/Users/<name>` for someone OTHER than
    /// the running user is a real absolute path, but it is not `/Users/_` — not a home anchor — and must
    /// not be treated as one just because it happens to share the `/Users/` prefix.
    func testOtherUsersHomeLiteralConcatenationStaysIncompleteNotGuessed() throws {
        let by = try scan("""
        import Foundation
        func readOtherUser() {
            let d = Data(contentsOfFile: "/Users/someoneelse" + "/Documents/x")
            print(d as Any)
        }
        """)
        XCTAssertEqual(direct(by, "readOtherUser"), ["Fs"],
                       "a literal naming a DIFFERENT user's home is not this process's home anchor")
        XCTAssertEqual(incompleteEffects(by, "readOtherUser"), ["Fs"])
    }
}
