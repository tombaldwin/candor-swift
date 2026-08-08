import XCTest
import Foundation
@testable import CandorCore

/// PER-TARGET SCAN SCOPING (`--target`).
///
/// The defect this closes was found by WRITING THE CASE STUDY, not by a test: scanning a multi-target
/// package whole and verifying against one product's `Info.plist` reported
///
///     ✗ code reaches Mic (via iOSBlowMonitor.…) but Info.plist declares no NSMicrophoneUsageDescription
///
/// for a sensor only the iOS target can reach, against the macOS app's plist. The analysis was right and
/// the UNIT was wrong, and the documented remedy — hand-build a separate `Package.swift` per binary — is a
/// workaround wearing methodology's clothes.
///
/// EVERY ASSERTION BELOW IS ABOUT SEEING LESS, which is the dangerous direction. Under ⟨0.21⟩ absence from
/// `functions` is a positive purity claim, so a `--target` that quietly resolved to fewer sources than the
/// user asked for would be the cardinal sin behind a convenience flag. Hence the refusal rows: an unknown
/// target, a missing source dir and an empty result must each EXIT 2, never scan-less-and-continue.
final class TargetScopeProcessTests: XCTestCase {

    // MARK: - the resolver, unit-level (no filesystem, no spawn)

    private let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "MultiTarget",
        dependencies: [.package(url: "https://example.com/x.git", from: "1.0.0")],
        targets: [
            .target(name: "Core"),
            .target(name: "Shared", dependencies: ["Core"]),
            .executableTarget(name: "MacApp", dependencies: ["Shared", .product(name: "Ext", package: "x")]),
            .executableTarget(name: "IosApp", dependencies: ["Core"], path: "Apps/Ios"),
            .testTarget(name: "CoreTests", dependencies: [.target(name: "Core")]),
        ]
    )
    """

    func testParsesEveryTargetKindAndItsShape() {
        let ts = parsePackageTargets(manifestSource: manifest)
        XCTAssertEqual(ts.map(\.name).sorted(), ["Core", "CoreTests", "IosApp", "MacApp", "Shared"])
        let byName = Dictionary(ts.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byName["IosApp"]?.path, "Apps/Ios", "an explicit `path:` must be read, not assumed")
        XCTAssertNil(byName["MacApp"]?.path)
        XCTAssertTrue(byName["CoreTests"]?.isTest ?? false)
        // `.target(name:)` in a dependency list is an in-package reference and must resolve like a bare string.
        XCTAssertEqual(byName["CoreTests"]?.dependencies, ["Core"])
    }

    func testProductDependenciesAreExcludedFromTheClosure() throws {
        let ts = parsePackageTargets(manifestSource: manifest)
        XCTAssertEqual(Dictionary(ts.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })["MacApp"]?.dependencies,
                       ["Shared"],
                       "a `.product(name:package:)` is EXTERNAL — it has no sources in this tree, and it stays "
                       + "disclosed by the coverage ledger rather than silently joining the closure")
    }

    func testClosureIsTransitiveAndIncludesItself() throws {
        let ts = parsePackageTargets(manifestSource: manifest)
        XCTAssertEqual(try targetClosure("MacApp", in: ts).map(\.name), ["Core", "MacApp", "Shared"],
                       "MacApp -> Shared -> Core must be walked transitively; stopping at the direct "
                       + "dependency would drop Core's effects from a binary that compiles them")
        XCTAssertEqual(try targetClosure("IosApp", in: ts).map(\.name), ["Core", "IosApp"])
        XCTAssertEqual(try targetClosure("Core", in: ts).map(\.name), ["Core"])
    }

    func testUnknownTargetRefusesAndNamesWhatExists() {
        let ts = parsePackageTargets(manifestSource: manifest)
        XCTAssertThrowsError(try targetClosure("Nope", in: ts)) { e in
            guard case TargetScopeError.unknownTarget(_, let available) = e else {
                return XCTFail("wrong error: \(e)")
            }
            // A dead end must carry its remedy — the standing UX rule. "no such target" alone makes the
            // reader go read Package.swift to find out what they could have typed.
            XCTAssertEqual(available, ["Core", "CoreTests", "IosApp", "MacApp", "Shared"])
        }
    }

    func testAMissingSourceDirRefusesRatherThanScanningLess() {
        let ts = parsePackageTargets(manifestSource: manifest)
        let closure = try! targetClosure("MacApp", in: ts)
        // Core's directory does not exist. Skipping it would scan MacApp+Shared and report on a closure
        // that is missing a member — every Core function then ABSENT from `functions`, i.e. claimed pure.
        XCTAssertThrowsError(try targetSourceDirs(closure, packageRoot: "/pkg",
                                                  exists: { !$0.hasSuffix("/Core") })) { e in
            guard case TargetScopeError.missingSourceDir(let t, let tried) = e else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(t, "Core")
            // `Source/` (singular) joined the candidates: it is one of SwiftPM's predefined source
            // directories, and omitting it made an ANALYZED module read as a third-party blind spot.
            // The assertion is the full list on purpose — the refusal must name everything it tried, so
            // adding a candidate without adding it here would leave the message and the code disagreeing.
            XCTAssertEqual(tried, ["/pkg/Sources/Core", "/pkg/Source/Core", "/pkg/Core"],
                           "the error must name what it TRIED")
        }
    }

    func testExplicitPathWinsOverTheConvention() throws {
        let ts = parsePackageTargets(manifestSource: manifest)
        let dirs = try targetSourceDirs(try targetClosure("IosApp", in: ts), packageRoot: "/pkg",
                                        exists: { _ in true })
        XCTAssertEqual(dirs.sorted(), ["/pkg/Apps/Ios", "/pkg/Sources/Core"])
    }

    // MARK: - the whole point, end to end

    /// The case study's §1 and §2, as a fixture: two products sharing a core, one sensor in each product,
    /// and a THIRD sensor reached only through the shared core. Scanning whole charges both products with
    /// both sensors; scoping charges each with what it actually compiles.
    func testScopingChangesWhichSensorsAProductIsChargedWith() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-target-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for t in ["Core", "MacApp", "IosApp"] {
            try fm.createDirectory(at: root.appendingPathComponent("Sources/\(t)"), withIntermediateDirectories: true)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "MultiTarget", targets: [
            .target(name: "Core"),
            .executableTarget(name: "MacApp", dependencies: ["Core"]),
            .executableTarget(name: "IosApp", dependencies: ["Core"]),
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Contacts
        public struct ContactsService {
            public init() {}
            public func resolve() -> [CNContact] {
                let store = CNContactStore()
                return (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: "a"),
                                                   keysToFetch: [])) ?? []
            }
        }
        """.write(to: root.appendingPathComponent("Sources/Core/ContactsService.swift"),
                  atomically: true, encoding: .utf8)
        try """
        import Core
        let svc = ContactsService()
        _ = svc.resolve()
        """.write(to: root.appendingPathComponent("Sources/MacApp/main.swift"), atomically: true, encoding: .utf8)
        try """
        import AVFoundation
        public final class BlowMonitor {
            public init() {}
            public func actuallyStart() {
                let r = try? AVAudioRecorder(url: URL(fileURLWithPath: "/tmp/x"), settings: [:])
                r?.record()
            }
        }
        """.write(to: root.appendingPathComponent("Sources/IosApp/BlowMonitor.swift"),
                  atomically: true, encoding: .utf8)

        func keys(scopedTo target: String?) throws -> String {
            var args = [root.path]
            if let t = target { args += ["--target", t] }
            let scan = try ProcessHarness.run(bin, args, cwd: root)
            XCTAssertEqual(scan.code, 0, "scan failed: \(scan.err)")
            return try ProcessHarness.run(bin, ["privacy-manifest"], cwd: root).out
        }

        let whole = try keys(scopedTo: nil)
        XCTAssertTrue(whole.contains("NSMicrophoneUsageDescription"), "whole-tree scan should see the iOS mic")
        XCTAssertTrue(whole.contains("NSContactsUsageDescription"))

        // THE FIX. MacApp does not compile IosApp, so it must not be charged with the microphone —
        // this exact false finding is what the case study opens with.
        let mac = try keys(scopedTo: "MacApp")
        XCTAssertFalse(mac.contains("NSMicrophoneUsageDescription"),
                       "MacApp was charged with a sensor only IosApp can reach — the artifact --target exists to remove")
        XCTAssertTrue(mac.contains("NSContactsUsageDescription"),
                      "Contacts reaches MacApp THROUGH the shared core — scoping must not lose a real reach")

        // And the other product keeps both: its own sensor, plus the one through the shared core. That
        // second half is the case study's §2 — a reach grep cannot see from the target's own sources.
        let ios = try keys(scopedTo: "IosApp")
        XCTAssertTrue(ios.contains("NSMicrophoneUsageDescription"))
        XCTAssertTrue(ios.contains("NSContactsUsageDescription"))
    }

    /// A scoped scan must SAY it is scoped. A clean verdict over one target reads exactly like a clean
    /// verdict over the package unless the report's reader is told which it is.
    func testAScopedScanDisclosesItsScope() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\nlet x = 1\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--target", "App"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("--target App"), "the scope must be disclosed on stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("covers that closure ONLY"),
                      "a scoped verdict must say what it does NOT cover: \(r.err)")
    }

    /// A SCOPED REPORT MUST NOT BE JOINABLE AS THE WHOLE PACKAGE. This is the cardinal-sin channel the
    /// feature opened: the report is byte-shaped exactly like a whole-package one — same `package`, same
    /// key namespace, just fewer functions — and the stderr scope note is not in the artifact anyone
    /// chains. Under ⟨0.21⟩ absence from `functions` is a positive purity claim, so a consumer chaining a
    /// scoped report under the package's name reads every function in the unscanned targets as pure.
    /// Qualifying the key fails in the SAFE direction instead: the lookup simply misses, and a miss is
    /// disclosed.
    func testAScopedReportIsNotJoinableAsTheWholePackage() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\nlet p = FileManager.default.currentDirectoryPath\n",
                                                  name: "App")
        defer { try? FileManager.default.removeItem(at: root) }

        let whole = try ProcessHarness.run(bin, [root.path, "--json"], cwd: root)
        let scoped = try ProcessHarness.run(bin, [root.path, "--target", "App", "--json"], cwd: root)
        XCTAssertEqual(whole.code, 0, whole.err); XCTAssertEqual(scoped.code, 0, scoped.err)
        func env(_ s: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        }
        let w = try env(whole.out), sc = try env(scoped.out)
        XCTAssertEqual(w["package"] as? String, "App")
        XCTAssertEqual(sc["package"] as? String, "App/App",
                       "a scoped scan must not claim the package's identity")
        // and the per-function join keys must carry it too — `package` alone would leave every `hash`
        // colliding with the whole-package report's.
        let hashes = (sc["functions"] as? [[String: Any]] ?? []).compactMap { $0["hash"] as? String }
        XCTAssertFalse(hashes.isEmpty, "fixture produced no functions to check")
        XCTAssertTrue(hashes.allSatisfy { $0.hasPrefix("App/App#") },
                      "scoped hashes must not be joinable as the package's: \(hashes.prefix(3))")
    }

    /// THE FILENAME MUST NOT carry the scope. Encoding it there let a package's scoped reports coexist,
    /// and discovery then picked one: after `--target MacApp` the privacy verb reported the MICROPHONE,
    /// which only the iOS target reaches. A silently wrong answer is worse than the overwrite it replaced.
    func testAScopedScanWritesTheOneCurrentReport() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("let x = 1\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        _ = try ProcessHarness.run(bin, [root.path, "--target", "App"], cwd: root)
        let dir = root.appendingPathComponent(".candor")
        let reports = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".Swift.json") }
        XCTAssertEqual(reports.count, 1,
                       "a scoped scan must REPLACE the current report, not sit beside it — several "
                       + "reports in one .candor/ is an ambiguity discovery resolves by guessing: \(reports)")
    }

    /// `path: "."` is legal SwiftPM — a single-target package rooted at the manifest. The naive prefix
    /// match refused it with "no Swift sources are under ./." while the sources sat right there: a dead
    /// end whose stated remedy could not work. `standardizingPath` alone did NOT fix it, because it
    /// strips a leading `./` from the files while leaving `.` as `.`, so the two sides still never met.
    func testATargetRootedAtThePackageDirectoryResolves() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-dot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Everything"),
                                                withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Rev2", targets: [.target(name: "Everything", path: ".")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\npublic func e() { _ = FileManager.default.contents(atPath: \"/tmp/e\") }\n"
            .write(to: root.appendingPathComponent("Sources/Everything/e.swift"),
                   atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--target", "Everything"], cwd: root)
        XCTAssertEqual(r.code, 0, "a target rooted at `.` must resolve, not refuse: \(r.err)")
        XCTAssertTrue(r.err.contains("--target Everything"), r.err)
    }

    /// A target name that is a PREFIX of another must not swallow it. `Sources/App` and
    /// `Sources/AppKit2` differ by a suffix, and a prefix match without the trailing separator would
    /// scan both while reporting the scope as one — charging a product with effects it never compiles.
    func testASiblingTargetWithAPrefixNameIsNotSwallowed() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for t in ["App", "AppKit2"] {
            try fm.createDirectory(at: root.appendingPathComponent("Sources/\(t)"),
                                   withIntermediateDirectories: true)
            try "import Foundation\npublic func \(t.lowercased())() { _ = FileManager.default.contents(atPath: \"/tmp/x\") }\n"
                .write(to: root.appendingPathComponent("Sources/\(t)/f.swift"),
                       atomically: true, encoding: .utf8)
        }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Rev", targets: [.target(name: "App"), .target(name: "AppKit2")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--target", "App"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("1 of 2 source file(s)"),
                      "App must scan ONE file, not swallow AppKit2's: \(r.err)")
    }

    func testUnknownTargetExitsTwoRatherThanScanningEverything() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("let x = 1\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--target", "Ghost"], cwd: root)
        XCTAssertEqual(r.code, 2, "an unknown target must REFUSE — falling back to a whole-tree scan would "
                       + "answer a different question and look identical")
        XCTAssertTrue(r.err.contains("This package declares:"), r.err)
    }

    func testValuelessTargetFailsClosed() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("let x = 1\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [[root.path, "--target"], [root.path, "--target", "--json"]] {
            let r = try ProcessHarness.run(bin, args, cwd: root)
            XCTAssertEqual(r.code, 2, "`\(args.joined(separator: " "))` must fail closed")
        }
    }

    /// A REFUSAL MUST CARRY ITS REMEDY. bitwarden/ios GENERATES its Xcode project (XcodeGen), so a fresh
    /// clone has no `.xcodeproj` at all — and the bare "neither found" told a user with a perfectly
    /// ordinary repo only that something was missing. The spec file is sitting right there; naming it,
    /// and the command, is the difference between a dead end and an instruction.
    ///
    /// It names EVERY spec rather than picking one: bitwarden has five and the alphabetically-first
    /// builds the Authenticator, not the app. Suggesting one command that generates the wrong product
    /// is the same guess this resolver refuses to make everywhere else.
    func testAGeneratedProjectRepoIsToldWhatToGenerate() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-gen-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "import Foundation\nfunc f() {}\n".write(to: root.appendingPathComponent("a.swift"),
                                                     atomically: true, encoding: .utf8)
        // The CONTROL first: Swift sources, no project, no generator — the plain message, and no advice
        // this repo cannot act on.
        let bare = try ProcessHarness.run(bin, [root.path, "--target", "App"], cwd: root)
        XCTAssertEqual(bare.code, 2, bare.err)
        XCTAssertTrue(bare.err.contains("neither found"), bare.err)
        XCTAssertFalse(bare.err.contains("GENERATES"),
                       "a repo with no generator must not be told to run one: \(bare.err)")
        // Now the split-spec shape.
        for spec in ["project-bwa.yml", "project-pm.yml"] {
            try "name: X\n".write(to: root.appendingPathComponent(spec), atomically: true, encoding: .utf8)
        }
        let gen = try ProcessHarness.run(bin, [root.path, "--target", "App"], cwd: root)
        XCTAssertEqual(gen.code, 2, gen.err)
        XCTAssertTrue(gen.err.contains("GENERATES"), gen.err)
        XCTAssertTrue(gen.err.contains("xcodegen generate --spec project-bwa.yml")
                      && gen.err.contains("xcodegen generate --spec project-pm.yml"),
                      "every spec must be named — picking one guesses which product you meant: \(gen.err)")
    }
}
