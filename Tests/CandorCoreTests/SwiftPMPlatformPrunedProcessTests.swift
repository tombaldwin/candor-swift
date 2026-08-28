import XCTest
import Foundation

/// ⟨file-set⟩ SwiftPM `--target` GAINS THE SAME PLATFORM PRUNING THE `.xcodeproj` RESOLVER ALREADY HAD.
///
/// BACKLOG.md filed A4: `328a67f` gave `xcodeTargetScope` (XcodeTargets.swift) its `platform-pruned`
/// `excluded[]` class, but `PackageTargets.swift` — the SwiftPM half of `--target` — never mentioned
/// "platform" or `#if os` at all. Measured against that commit on a real SwiftPM shape (a package
/// declaring `platforms: [.macOS(.v13), .iOS(.v16)]`, a function wholly inside `#if os(watchOS)` calling
/// `FileManager.createFile`): the provably-dead function was reported as a LIVE, undisclosed `Fs` effect
/// — not excluded, not flagged, not disclosed as platform-dead — and a real `--policy deny Fs` gate FAILED
/// on it (`AS-EFF-006`), a false violation over code that can never run. That is WORSE than what
/// `328a67f` fixed: there the file at least reached `excluded[]` under a wrong reason; here it reached
/// nothing.
///
/// The fix reuses `328a67f`'s machinery rather than building a parallel one: `swiftFileCompilesToNothing`
/// (unmodified) decides membership per platform, a new `parsePackagePlatformFamilies` reads the
/// manifest's declared `platforms:` into the SAME family vocabulary, and the SwiftPM `--target` path
/// files a dead file under the SAME `"platform-pruned"` `excludedFiles` class the Xcode path already
/// feeds — so it inherits `PEEKED_CLASSES`, the `outOfScope`/INCOMPLETE machinery, and the disclosure
/// text for free, exactly as the class was designed to be fed from more than one producer.
final class SwiftPMPlatformPrunedProcessTests: XCTestCase {

    private func makePlatformPackage(platforms: String?, files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-spm-platform-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/MyLib"), withIntermediateDirectories: true)
        let platformsArg = platforms.map { "platforms: \($0),\n    " } ?? ""
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(
            name: "MyLib",
            \(platformsArg)products: [.library(name: "MyLib", targets: ["MyLib"])],
            targets: [.target(name: "MyLib")]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for (name, content) in files {
            try content.write(to: root.appendingPathComponent("Sources/MyLib/\(name)"),
                              atomically: true, encoding: .utf8)
        }
        return root
    }

    private let watchOnly = """
    import Foundation
    #if os(watchOS)
    public struct WatchOnlyThing {
        public func doIt() {
            FileManager.default.createFile(atPath: "/tmp/whatever", contents: nil)
        }
    }
    #endif
    """
    private let alwaysHere = "import Foundation\npublic func alwaysHere() {}\n"

    private func doc(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], out)
    }

    /// THE DEFECT CASE, falsified against the pre-fix behaviour before this test existed (see the report):
    /// a package declaring `platforms: [.macOS(.v13), .iOS(.v16)]` never builds for watchOS in ANY
    /// target, so the wholly-`#if os(watchOS)`-gated file must land in `excluded[]` under
    /// `"platform-pruned"`, be peeked, and NOT appear in `functions`.
    func testAWatchOnlyFileInAMacAndIOSPackageIsPlatformPruned() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makePlatformPackage(platforms: "[.macOS(.v13), .iOS(.v16)]",
                                           files: ["Always.swift": alwaysHere, "WatchOnly.swift": watchOnly])
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        let ex = try XCTUnwrap(d["excluded"] as? [[String: Any]], r.out)
        let pruned = try XCTUnwrap(ex.first { $0["class"] as? String == "platform-pruned" },
                                   "WatchOnly.swift compiles to nothing on this package's declared "
                                   + "platforms and must be its own class: \(ex)")
        XCTAssertEqual(pruned["count"] as? Int, 1)
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertFalse(fns.contains { $0.contains("WatchOnlyThing") },
                       "the platform-pruned file was scanned after all — the exclusion is fiction: \(fns)")
    }

    /// THE PEEK reaches the pruned file exactly as the Xcode path's does, and a denied effect flips the
    /// verdict to INCOMPLETE (exit 2) rather than either a silent pass or — the pre-fix behaviour — a
    /// false POLICY VIOLATION (exit 1) over code that can never run.
    func testThePeekReachesItAndTheVerdictGoesIncompleteNotAFalseViolation() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makePlatformPackage(platforms: "[.macOS(.v13), .iOS(.v16)]",
                                           files: ["Always.swift": alwaysHere, "WatchOnly.swift": watchOnly])
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("fs.policy")
        try "deny Fs\n".write(to: policy, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json", "--policy", policy.path],
                                       cwd: root)
        XCTAssertEqual(r.code, 2, "a peeked platform-pruned fn performing the denied effect must be "
                       + "INCOMPLETE, never a false policy violation over dead code: \(r.err)")
        let d = try doc(r.out)
        let oos = try XCTUnwrap(d["outOfScope"] as? [[String: Any]], r.out)
        XCTAssertEqual(oos.count, 1)
        XCTAssertEqual(oos[0]["class"] as? String, "platform-pruned")
        XCTAssertEqual(oos[0]["effects"] as? [String] ?? [], ["Fs"])
        let ex = try XCTUnwrap(d["excluded"] as? [[String: Any]], r.out)
        let pruned = try XCTUnwrap(ex.first { $0["class"] as? String == "platform-pruned" }, "\(ex)")
        XCTAssertEqual(pruned["peeked"] as? Bool, true)
    }

    /// THE OVER-CHARGE CONTROL, and the reason this fix is safe to ship: a package with the SAME
    /// `platforms:` restriction but NO `#if os(…)`-gated code anywhere must produce a byte-identical
    /// report to the pre-fix engine — the new machinery must never fire on ordinary code.
    func testAPackageWithNoPlatformGatedCodeIsUnaffected() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makePlatformPackage(
            platforms: "[.macOS(.v13), .iOS(.v16)]",
            files: ["Always.swift": alwaysHere,
                    "AlsoAlways.swift": "import Foundation\npublic func writesAFile() { "
                        + "FileManager.default.createFile(atPath: \"/tmp/ordinary\", contents: nil) }\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        let ex = (d["excluded"] as? [[String: Any]] ?? [])
        XCTAssertNil(ex.first { $0["class"] as? String == "platform-pruned" },
                     "no platform-gated code exists here — the new class must not appear: \(ex)")
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertTrue(fns.contains("writesAFile"), "ordinary code must still be analyzed and reported: \(fns)")
    }

    /// THE GENUINELY-LIVE CONTROL — the one that matters most: `#if os(macOS)` code in a package that
    /// DOES declare macOS support must still be scanned and its effect reported as a real policy
    /// violation. Excluding it would be the silent under-report a completeness fix must never introduce.
    func testMacOnlyCodeInAMacSupportingPackageStaysLiveAndViolatesPolicy() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let macOnly = """
        import Foundation
        #if os(macOS)
        public struct MacOnlyThing {
            public func doIt() { FileManager.default.createFile(atPath: "/tmp/maconly", contents: nil) }
        }
        #endif
        """
        let root = try makePlatformPackage(platforms: "[.macOS(.v13), .iOS(.v16)]",
                                           files: ["Always.swift": alwaysHere, "MacOnly.swift": macOnly])
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("fs.policy")
        try "deny Fs\n".write(to: policy, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json", "--policy", policy.path],
                                       cwd: root)
        XCTAssertEqual(r.code, 1, "macOS-gated code in a macOS-supporting package is LIVE and must be "
                       + "judged as an ordinary policy violation, not excluded: \(r.err)")
        let d = try doc(r.out)
        let ex = (d["excluded"] as? [[String: Any]] ?? [])
        XCTAssertNil(ex.first { $0["class"] as? String == "platform-pruned" },
                     "live code must never be filed as platform-pruned: \(ex)")
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertTrue(fns.contains { $0.contains("MacOnlyThing") }, "\(fns)")
    }

    /// NO `platforms:` ARGUMENT AT ALL is SwiftPM's own default of "every platform is supported" — the
    /// watchOS-gated file is then live on a platform this package genuinely ships for, and pruning it
    /// would be a silent under-report introduced by a completeness fix.
    func testNoPlatformsDeclarationMeansNoPruning() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makePlatformPackage(platforms: nil, files: ["WatchOnly.swift": watchOnly])
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        let ex = (d["excluded"] as? [[String: Any]] ?? [])
        XCTAssertNil(ex.first { $0["class"] as? String == "platform-pruned" },
                     "an unrestricted manifest supports every platform — nothing here is provably dead: \(ex)")
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertTrue(fns.contains { $0.contains("WatchOnlyThing") }, "\(fns)")
    }

    /// A `platforms:` argument that is NOT a literal array (hoisted into a variable) cannot be read, and
    /// "cannot be read" must not collapse into "supports nothing" — the same rule every other manifest
    /// parser in this engine already follows for `products:`/`targets:`/`dependencies:`.
    func testAnUnreadablePlatformsListMeansNoPruning() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-spm-platform-computed-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/MyLib"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let myPlatforms: [SupportedPlatform] = [.macOS(.v13)]
        let package = Package(
            name: "MyLib",
            platforms: myPlatforms,
            products: [.library(name: "MyLib", targets: ["MyLib"])],
            targets: [.target(name: "MyLib")]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try watchOnly.write(to: root.appendingPathComponent("Sources/MyLib/WatchOnly.swift"),
                           atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        let ex = (d["excluded"] as? [[String: Any]] ?? [])
        XCTAssertNil(ex.first { $0["class"] as? String == "platform-pruned" },
                     "a hoisted `platforms:` list cannot be proven to restrict anything — keep, never guess-exclude: \(ex)")
    }
}
