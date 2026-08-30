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

    /// ⟨guard-deletion sweep⟩ THE READABILITY GUARD in the SAME filter (main.swift: "Cheap gate first...
    /// An unreadable file is KEPT — pruning must never eat one silently"), tested independently of the
    /// `#if os(` cheap-gate above it. A file this scan cannot READ at all (permissions, not a parse
    /// failure) must fall through to the engine's general "source failed to read" disclosure
    /// (`unanalyzed`) exactly as it would with no `--target` in play — never be swept into
    /// `platform-pruned` (this filter cannot prove a file it never read compiles to nothing) NOR into
    /// the generic `outside-the-target-closure` bucket the before/after diff produces for files SwiftPM's
    /// own closure excludes (that bucket's whole premise — "an unscoped scan WOULD have judged this" — is
    /// false here: an unscoped scan hits the identical read failure).
    ///
    /// Falsified against a deliberately neutered filter (folding the readability check into the same
    /// "drop it" arm as a proven-dead file): the file was still disclosed, via the target-closure diff's
    /// incidental safety net, but mislabeled `outside-the-target-closure` instead of `unanalyzed` — a
    /// wrong-but-visible reclassification this test exists to catch, since no other test in the suite
    /// exercises an unreadable SOURCE file (as opposed to an unreadable `platforms:` manifest value).
    func testAnUnreadableSourceFileIsDisclosedAsUnreadableNotAsOutsideTheClosure() throws {
        try XCTSkipIf(geteuid() == 0, "root reads through 0000 permissions — the arm is untestable as root")
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makePlatformPackage(platforms: "[.macOS(.v13), .iOS(.v16)]",
                                           files: ["Always.swift": alwaysHere])
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("Sources/MyLib/Secret.swift")
        try """
        import Foundation
        public func doTheThing() { FileManager.default.createFile(atPath: "/tmp/whatever", contents: nil) }
        """.write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret.path) }

        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        let unanalyzed = (d["unanalyzed"] as? [[String: Any]]) ?? []
        XCTAssertTrue(unanalyzed.contains { ($0["path"] as? String)?.hasSuffix("Secret.swift") == true },
                      "an unreadable source file must reach the general 'source failed to read' "
                      + "disclosure exactly as it would outside `--target`: \(d)")
        let ex = (d["excluded"] as? [[String: Any]]) ?? []
        XCTAssertNil(ex.first { $0["class"] as? String == "platform-pruned" },
                     "a file this scan never read cannot be proven to compile to nothing: \(ex)")
        XCTAssertNil(ex.first { $0["class"] as? String == "outside-the-target-closure" },
                     "the file IS in the target's own source list — it simply could not be read, which "
                     + "is a different fact from 'not part of this target': \(ex)")
    }
}

/// ⟨file-set, cardinal-sin fix⟩ SwiftPM's VERSION-SPECIFIC MANIFEST SELECTION governs which
/// `Package.swift`-family file is real, and a structural read of the base file alone is UNSOUND once a
/// `Package@swift-<version>.swift` exists beside it.
///
/// A CARDINAL SIN was reproduced in `ce72431` (the fix `SwiftPMPlatformPrunedProcessTests` above pins):
/// it hardcoded `Package.swift`, so a package whose `Package@swift-6.0.swift` OVERLAY widens the declared
/// `platforms:` (adding a platform the base manifest omits) had its overlay-only code pruned as
/// "platform-pruned" and a real `--policy deny <Effect>` gate PASSED at exit 0 over code that genuinely
/// ships. Measured with the exact reported shape: `Package.swift` declaring `platforms: [.macOS(.v10_15)]`
/// plus `Package@swift-6.0.swift` declaring `platforms: [.macOS(.v10_15), .visionOS(.v1)]`, a function
/// wholly inside `#if os(visionOS)` calling a helper in ANOTHER, in-scope file that performs `Fs` — the
/// unscoped control caught it (`AS-EFF-006`, exit 1) and `--target` answered `policy ✓` at exit 0.
///
/// Fixed by asking SwiftPM ITSELF (`swift package dump-package`) whenever a `Package@swift-*.swift` file
/// exists at all — SwiftPM's own manifest loader is the one sound authority for which file governs and
/// what it declares, since that depends on the toolchain actually invoking the build and not on anything
/// a structural parse of one file can see. A structural read of the base manifest continues, UNCHANGED,
/// whenever no overlay exists (the whole `SwiftPMPlatformPrunedProcessTests` suite above).
final class SwiftPMVersionSpecificManifestProcessTests: XCTestCase {

    private func makePlatformPackage(platforms: String?, files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-spm-versionmanifest-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/MyLib"), withIntermediateDirectories: true)
        let platformsArg = platforms.map { "platforms: \($0),\n    " } ?? ""
        try """
        // swift-tools-version:5.7
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

    /// This repo's own manifest declares `swift-tools-version:6.0`, so any toolchain able to even BUILD
    /// candor-swift (and therefore run this test) is >= 6.0 and selects this overlay over the base —
    /// mirroring SwiftPM's real rule (the highest declared version not exceeding the active toolchain)
    /// without depending on which exact toolchain happens to run the suite.
    private func writeOverlay(_ root: URL, platforms: String?) throws {
        let platformsArg = platforms.map { "platforms: \($0),\n    " } ?? ""
        try """
        // swift-tools-version:6.0
        import PackageDescription
        let package = Package(
            name: "MyLib",
            \(platformsArg)products: [.library(name: "MyLib", targets: ["MyLib"])],
            targets: [.target(name: "MyLib")]
        )
        """.write(to: root.appendingPathComponent("Package@swift-6.0.swift"), atomically: true, encoding: .utf8)
    }

    private func doc(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], out)
    }

    /// THE DEFECT CASE — falsified against `ce72431` before this fix existed (see the report): the base
    /// manifest omits visionOS, the overlay ADDS it, and visionOS-only code must be judged LIVE — a real
    /// `deny Fs` gate must fire on it as an ordinary violation, never a false `policy ✓`.
    func testAnOverlayThatWidensThePlatformSetKeepsTheAddedPlatformsCodeLive() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let visionOnly = """
        import Foundation
        #if os(visionOS)
        public func doVisionStuff() {
            FileManager.default.createFile(atPath: "/tmp/vision-evidence.txt", contents: nil)
        }
        #endif
        """
        let root = try makePlatformPackage(platforms: "[.macOS(.v10_15)]",
                                           files: ["Always.swift": alwaysHere, "Vision.swift": visionOnly])
        try writeOverlay(root, platforms: "[.macOS(.v10_15), .visionOS(.v1)]")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("fs.policy")
        try "deny Fs\n".write(to: policy, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json", "--policy", policy.path],
                                       cwd: root)
        XCTAssertEqual(r.code, 1, "the overlay declares visionOS support the base manifest omits — this "
                       + "function genuinely ships and a real policy violation must fire, not a false "
                       + "`policy ✓` over code the base-only read wrongly proved dead: \(r.err)")
        let d = try doc(r.out)
        let ex = (d["excluded"] as? [[String: Any]] ?? [])
        XCTAssertNil(ex.first { $0["class"] as? String == "platform-pruned" },
                     "the overlay's platforms must govern, not the base's — nothing here is dead: \(ex)")
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertTrue(fns.contains("doVisionStuff"), "\(fns)")
    }

    /// THE EXACT REPORTED SHAPE, cross-file: `doVisionStuff` (`#if os(visionOS)`) reaches `Fs` only
    /// through `helperWritesFile`, a SEPARATE, always-in-scope file — this is the shape that made the
    /// pre-fix defect worse than an ordinary miss, because the wrong-manifest prune (cause A) removed the
    /// caller from `sourcePaths` entirely, and the ⟨0.29⟩ peek safety net that should have caught it
    /// re-scans excluded files in ISOLATION and cannot resolve a call into a file that was never excluded
    /// (cause B) — so the two compounded into a SILENT exit-0 `policy ✓` instead of even an INCOMPLETE.
    /// Fixing cause A removes the trigger: the overlay correctly keeps `Vision.swift` in scope, so it is
    /// scanned NORMALLY (not peeked at all) and the cross-file reach resolves exactly as the unscoped
    /// control already does.
    func testTheExactReportedCrossFileShapeCatchesTheViolation() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let other = "import Foundation\nfunc helperWritesFile() {\n"
            + "    FileManager.default.createFile(atPath: \"/tmp/vision-evidence.txt\", contents: nil)\n}\n"
            + "public func harmlessThing() -> Int { 42 }\n"
        let visionCaller = "#if os(visionOS)\nfunc doVisionStuff() {\n    helperWritesFile()\n}\n#endif\n"
        let root = try makePlatformPackage(platforms: "[.macOS(.v10_15)]",
                                           files: ["Other.swift": other, "VisionCaller.swift": visionCaller])
        try writeOverlay(root, platforms: "[.macOS(.v10_15), .visionOS(.v1)]")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("fs.policy")
        try "deny Fs doVision\n".write(to: policy, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json", "--policy", policy.path],
                                       cwd: root)
        XCTAssertEqual(r.code, 1, "the overlay declares visionOS — `doVisionStuff` is live, reaches `Fs` "
                       + "through `helperWritesFile`, and a real `deny Fs doVision` gate must catch it as "
                       + "an ordinary violation, not answer a false `policy ✓`: \(r.err)")
        let d = try doc(r.out)
        let ex = (d["excluded"] as? [[String: Any]] ?? [])
        XCTAssertNil(ex.first { $0["class"] as? String == "platform-pruned" }, "\(ex)")
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertTrue(fns.contains("doVisionStuff"), "\(fns)")
    }

    /// THE VERSION-MANIFEST CONTROL: an overlay that NARROWS the platform set (the base declares iOS, the
    /// overlay does not) must ALSO be read correctly — code the overlay drops must be pruned+peeked, not
    /// kept live because the wider base manifest still declares it.
    func testAnOverlayThatNarrowsThePlatformSetPrunesWhatItDrops() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let iosOnly = """
        import Foundation
        #if os(iOS)
        public func iosOnlyThing() {
            FileManager.default.createFile(atPath: "/tmp/iosonly.txt", contents: nil)
        }
        #endif
        """
        let root = try makePlatformPackage(platforms: "[.macOS(.v13), .iOS(.v16), .watchOS(.v9)]",
                                           files: ["Always.swift": alwaysHere, "IOSOnly.swift": iosOnly])
        try writeOverlay(root, platforms: "[.macOS(.v13)]")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("fs.policy")
        try "deny Fs\n".write(to: policy, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json", "--policy", policy.path],
                                       cwd: root)
        XCTAssertEqual(r.code, 2, "the overlay drops iOS — this function is provably dead under it, so a "
                       + "peeked violation must be INCOMPLETE, never a live pass or a false violation: \(r.err)")
        let d = try doc(r.out)
        let ex = try XCTUnwrap(d["excluded"] as? [[String: Any]], r.out)
        let pruned = try XCTUnwrap(ex.first { $0["class"] as? String == "platform-pruned" }, "\(ex)")
        XCTAssertEqual(pruned["peeked"] as? Bool, true)
        let oos = try XCTUnwrap(d["outOfScope"] as? [[String: Any]], r.out)
        XCTAssertEqual(oos.first?["fn"] as? String, "iosOnlyThing")
    }

    /// FAIL CLOSED: an overlay that EXISTS but cannot be EXECUTED (SwiftPM itself refuses it) must prune
    /// NOTHING, exactly the existing "cannot be proven" rule for an unreadable `platforms:` — never a
    /// guess that falls back to trusting the base manifest alone, which is the exact defect this fixes.
    func testAnOverlayThatFailsToExecuteMeansNoPruning() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makePlatformPackage(platforms: "[.macOS(.v13)]",
                                           files: ["Always.swift": alwaysHere, "WatchOnly.swift": watchOnly])
        // A syntactically-valid-enough-to-select, semantically-broken overlay: SwiftPM selects it (its
        // declared tools-version is within range) but fails to EXECUTE it, so `dump-package` exits non-zero.
        try """
        // swift-tools-version:6.0
        import PackageDescription
        let package = Package(
            name: "MyLib",
            platforms: [thisIdentifierDoesNotExistAndFailsToCompile],
            targets: [.target(name: "MyLib")]
        )
        """.write(to: root.appendingPathComponent("Package@swift-6.0.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--target", "MyLib", "--json"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        let ex = (d["excluded"] as? [[String: Any]] ?? [])
        XCTAssertNil(ex.first { $0["class"] as? String == "platform-pruned" },
                     "the overlay cannot be executed to prove anything — keep, never guess-exclude: \(ex)")
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertTrue(fns.contains { $0.contains("WatchOnlyThing") }, "\(fns)")
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
}
