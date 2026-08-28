import XCTest
import Foundation

/// ⟨file-set⟩ PLATFORM-PRUNED FILES ARE THEIR OWN `excluded` CLASS, not folded into
/// `outside-the-target-closure`.
///
/// `--target`'s Xcode-project resolver (`xcodeTargetScope`, XcodeTargets.swift) drops a file from a
/// target's scope for two UNRELATED reasons that both just remove a path from `sourcePaths`: the file is
/// compiled by a SIBLING target (ordinary attribution), or the file's every top-level declaration sits
/// inside `#if os(…)` clauses provably FALSE for this target's platform — it builds into NOTHING, on ANY
/// target, on this platform (`main.swift`'s "platform prune", NetNewsWire's `SendToBlogEditorApp.swift`).
/// A single before/after diff over `sourcePaths` cannot tell the two apart on its own, and before this
/// class existed both landed under `outside-the-target-closure`, whose OWN reason string calls them
/// "production sources... an unscoped scan WOULD have judged" — true of a sibling-target file, but only
/// half the story for one that is dead code on this platform in EVERY target's build.
///
/// This is a PRECISION fix, not a completeness one: the file was already in `excluded[]`, already
/// PEEKED (both classes sit in `PEEKED_CLASSES`), and an effect denied by policy inside one already
/// flipped the verdict to INCOMPLETE via `outOfScope` before this class was split out — see
/// `testAPlatformPrunedEffectWasAlreadyCaughtButMislabeled` for the falsifying control against the
/// pre-fix behaviour. What was missing was the CLASS matching the engine's own stated reason (SPEC §2:
/// "`reason` ... MUST say why the class exists, in the engine's own terms").
final class PlatformPrunedFileSetProcessTests: XCTestCase {

    private var bin: URL!
    private var dir: URL!

    override func setUpWithError() throws {
        bin = try ProcessHarness.binaryURL(for: Self.self)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("candor-platform-pruned-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("App"), withIntermediateDirectories: true)
        // The RSCore/NetNewsWire shape verbatim: an iOS-targeted app with one file wholly inside
        // `#if os(macOS)`, reaching a real Fs effect, and one always-live file.
        try "import Foundation\npublic func alwaysHere() {}\n"
            .write(to: dir.appendingPathComponent("App/AppDelegate.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        #if os(macOS)
        public struct SendToBlogEditorApp {
            public func send() {
                FileManager.default.contents(atPath: "/etc/passwd")
            }
        }
        #endif
        """.write(to: dir.appendingPathComponent("App/MacOnly.swift"), atomically: true, encoding: .utf8)
        try """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tobjectVersion = 56;
        \tobjects = {
        \t\tROOT /* Project object */ = { isa = PBXProject; mainGroup = G0; projectDirPath = ""; targets = ( TAPP ); };
        \t\tG0 = { isa = PBXGroup; children = ( GAPP ); sourceTree = "<group>"; };
        \t\tGAPP = { isa = PBXGroup; children = ( FAPPDEL, FMACONLY ); path = App; sourceTree = "<group>"; };
        \t\tFAPPDEL = { isa = PBXFileReference; path = AppDelegate.swift; sourceTree = "<group>"; };
        \t\tFMACONLY = { isa = PBXFileReference; path = MacOnly.swift; sourceTree = "<group>"; };
        \t\tBFAPPDEL = { isa = PBXBuildFile; fileRef = FAPPDEL; };
        \t\tBFMACONLY = { isa = PBXBuildFile; fileRef = FMACONLY; };
        \t\tPSAPP = { isa = PBXSourcesBuildPhase; files = ( BFAPPDEL, BFMACONLY ); };
        \t\tXCAPP = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; }; name = Release; };
        \t\tCLAPP = { isa = XCConfigurationList; buildConfigurations = ( XCAPP ); };
        \t\tTAPP = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildPhases = ( PSAPP );
        \t\t\tbuildConfigurationList = CLAPP;
        \t\t\tname = App;
        \t\t\tproductType = "com.apple.product-type.application";
        \t\t};
        \t};
        \trootObject = ROOT;
        }
        """.write(to: dir.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        try "deny Fs\n".write(to: dir.appendingPathComponent("fs.policy"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func doc(_ out: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], out)
    }

    /// THE SCOPE names the RIGHT reason, and only once. Two things a shared before/after diff makes easy
    /// to get wrong: filing the platform-pruned file under the sibling-target class (imprecise, this
    /// test's main assertion), and filing it under BOTH (double-counting one exclusion — the second
    /// assertion, `outside-the-target-closure` must not exist here at all since nothing else was pruned).
    func testPlatformPrunedFileGetsItsOwnClassNotOutsideTheTargetClosure() throws {
        let r = try ProcessHarness.run(bin, [dir.path, "--target", "App", "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try doc(r.out)
        let ex = try XCTUnwrap(d["excluded"] as? [[String: Any]], r.out)
        func find(_ cls: String) -> [String: Any]? { ex.first { $0["class"] as? String == cls } }

        let pruned = try XCTUnwrap(find("platform-pruned"),
                                   "MacOnly.swift compiles to nothing on iOS and must be its own class: \(ex)")
        XCTAssertEqual(pruned["count"] as? Int, 1)
        let why = pruned["reason"] as? String ?? ""
        XCTAssertTrue(why.contains("#if os"), "the reason must name the actual mechanism: \(why)")
        // No policy configured yet, so no peek ran — same rule as every other class (⟨0.29⟩).
        XCTAssertEqual(pruned["peeked"] as? Bool, false)

        XCTAssertNil(find("outside-the-target-closure"),
                     "nothing else was pruned from this one-file-excluded target — a second entry here "
                     + "would mean the platform-pruned file was ALSO counted under the generic class: \(ex)")

        // …and the excluded file is genuinely not analyzed under this target's report.
        let fns = (d["functions"] as? [[String: Any]] ?? []).compactMap { $0["fn"] as? String }
        XCTAssertFalse(fns.contains { $0.contains("SendToBlogEditorApp") },
                       "the platform-pruned file was scanned after all — the exclusion is fiction: \(fns)")
    }

    /// THE PEEK reaches into the platform-pruned file exactly as it already did under the generic class,
    /// and the verdict goes INCOMPLETE (⟨0.30⟩) — this class carries no LESS disclosure than the one it
    /// was split from, only a more precise name.
    func testThePeekReachesThePlatformPrunedFileAndTheVerdictGoesIncomplete() throws {
        let r = try ProcessHarness.run(bin, [dir.path, "--target", "App", "--json",
                                             "--policy", dir.appendingPathComponent("fs.policy").path])
        let d = try doc(r.out)
        let oos = try XCTUnwrap(d["outOfScope"] as? [[String: Any]], r.out)
        XCTAssertEqual(oos.count, 1, "the platform-pruned file's Fs must be reported: \(oos)")
        XCTAssertEqual(oos[0]["class"] as? String, "platform-pruned")
        XCTAssertEqual(oos[0]["effects"] as? [String] ?? [], ["Fs"])
        XCTAssertEqual(oos[0]["fn"] as? String, "SendToBlogEditorApp.send")
        XCTAssertEqual(oos[0]["path"] as? String, "App/MacOnly.swift")

        let ex = try XCTUnwrap(d["excluded"] as? [[String: Any]], r.out)
        let pruned = try XCTUnwrap(ex.first { $0["class"] as? String == "platform-pruned" }, "\(ex)")
        XCTAssertEqual(pruned["peeked"] as? Bool, true, "the peek read this class on this run: \(pruned)")

        XCTAssertEqual(r.code, 2, "a peeked platform-pruned fn performing the denied effect makes the "
                       + "verdict incomplete: \(r.err)")
        XCTAssertTrue(r.err.contains("OUTSIDE this scan's scope (platform-pruned)"), r.err)
    }

    /// THE OVER-CHARGE CONTROL, and the reason this fix is safe to ship: an ordinary `--target` scope
    /// exclusion with NO platform involved (a ordinary sibling-target file, `inferPlatform` sees no
    /// SDKROOT and prunes nothing) must still land under `outside-the-target-closure`, unaffected by the
    /// new class existing at all.
    func testAnOrdinarySiblingTargetExclusionIsUnaffected() throws {
        let fm = FileManager.default
        let cross = FileManager.default.temporaryDirectory
            .appendingPathComponent("candor-crosstarget-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: cross) }
        try fm.createDirectory(at: cross.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cross.appendingPathComponent("App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cross.appendingPathComponent("Other"), withIntermediateDirectories: true)
        try "import Foundation\npublic func alwaysHere() {}\n"
            .write(to: cross.appendingPathComponent("App/AppDelegate.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\npublic func otherThing() { FileManager.default.contents(atPath: \"/etc/passwd\") }\n"
            .write(to: cross.appendingPathComponent("Other/OtherOnly.swift"), atomically: true, encoding: .utf8)
        // NO SDKROOT anywhere — `inferPlatform` must return nil, so the platform-pruning arm never runs;
        // this is a pure cross-target membership exclusion, the shape `outside-the-target-closure` exists for.
        try """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tobjectVersion = 56;
        \tobjects = {
        \t\tROOT /* Project object */ = { isa = PBXProject; mainGroup = G0; projectDirPath = ""; targets = ( TAPP, TOTHER ); };
        \t\tG0 = { isa = PBXGroup; children = ( GAPP, GOTHER ); sourceTree = "<group>"; };
        \t\tGAPP = { isa = PBXGroup; children = ( FAPPDEL ); path = App; sourceTree = "<group>"; };
        \t\tGOTHER = { isa = PBXGroup; children = ( FOTHER ); path = Other; sourceTree = "<group>"; };
        \t\tFAPPDEL = { isa = PBXFileReference; path = AppDelegate.swift; sourceTree = "<group>"; };
        \t\tFOTHER = { isa = PBXFileReference; path = OtherOnly.swift; sourceTree = "<group>"; };
        \t\tBFAPPDEL = { isa = PBXBuildFile; fileRef = FAPPDEL; };
        \t\tBFOTHER = { isa = PBXBuildFile; fileRef = FOTHER; };
        \t\tPSAPP = { isa = PBXSourcesBuildPhase; files = ( BFAPPDEL ); };
        \t\tPSOTHER = { isa = PBXSourcesBuildPhase; files = ( BFOTHER ); };
        \t\tTAPP = { isa = PBXNativeTarget; buildPhases = ( PSAPP ); name = App; productType = "com.apple.product-type.application"; };
        \t\tTOTHER = { isa = PBXNativeTarget; buildPhases = ( PSOTHER ); name = Other; productType = "com.apple.product-type.application"; };
        \t};
        \trootObject = ROOT;
        }
        """.write(to: cross.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        try "deny Fs\n".write(to: cross.appendingPathComponent("fs.policy"), atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, [cross.path, "--target", "App", "--json",
                                             "--policy", cross.appendingPathComponent("fs.policy").path])
        let d = try doc(r.out)
        let ex = try XCTUnwrap(d["excluded"] as? [[String: Any]], r.out)
        XCTAssertNil(ex.first { $0["class"] as? String == "platform-pruned" },
                     "no platform pruning happened here — the new class must not appear: \(ex)")
        let outside = try XCTUnwrap(ex.first { $0["class"] as? String == "outside-the-target-closure" },
                                    "the sibling-target file must still land in the pre-existing class: \(ex)")
        XCTAssertEqual(outside["count"] as? Int, 1)
        XCTAssertEqual(outside["peeked"] as? Bool, true)

        let oos = try XCTUnwrap(d["outOfScope"] as? [[String: Any]], r.out)
        XCTAssertEqual(oos.count, 1)
        XCTAssertEqual(oos[0]["class"] as? String, "outside-the-target-closure")
        XCTAssertEqual(r.code, 2, r.err)
    }
}
