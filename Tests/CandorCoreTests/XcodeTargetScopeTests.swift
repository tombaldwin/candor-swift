import XCTest
import Foundation
@testable import CandorCore

/// PER-TARGET SCOPING FOR `.xcodeproj` REPOS — the pbxproj half of `--target`.
///
/// The defect this closes was measured on shipping apps, not imagined: a whole-repo scan charged
/// NetNewsWire's iOS plist with NSAppleEventsUsageDescription reached only by Mac-target code, and
/// Focus's plist with Speech reached only by firefox's code in a sibling project — while the documented
/// remedy (`--target`) exited 2 on every `.xcodeproj` repo, which is precisely the audience the
/// privacy-manifest verb is promoted to.
///
/// EVERY FIXTURE HERE IS AN ATTRIBUTION BOUNDARY. Scoping makes the scan see LESS, and under ⟨0.21⟩
/// absence from `functions` is a purity claim — so the assertions are as much about what must STAY IN a
/// target's list (the shared file, the dependency's sources, the synchronized folder minus only ITS
/// OWN exceptions) as about what must stay out. The refusal rows mirror TargetScopeProcessTests:
/// unknown name, dangling reference, missing synchronized folder — each throws, never resolves less.
final class XcodeTargetScopeTests: XCTestCase {

    // A two-target classic-format project, shaped like the measured NetNewsWire defect in miniature:
    //   MacApp   compiles Mac/AppDelegate.swift (nested group), Shared/Send.swift (the Apple-events
    //            analog) and Legacy.swift (a SOURCE_ROOT-relative reference)
    //   IosApp   compiles iOS/AppDelegate.swift and Shared/Send.swift's SIBLING Shared/Common.swift
    //            — Send.swift must NOT leak into IosApp's list
    //   Common.swift belongs to BOTH targets (two PBXBuildFiles, one PBXFileReference).
    private let classic = """
    // !$*UTF8*$!
    {
        archiveVersion = 1;
        objectVersion = 56;
        objects = {
            ROOT /* Project object */ = {
                isa = PBXProject;
                mainGroup = G0;
                projectDirPath = "";
                targets = ( TMAC /* MacApp */, TIOS, TTEST );
            };
            G0 = { isa = PBXGroup; children = ( GMAC, GIOS, GSHARED, FLEGACY ); sourceTree = "<group>"; };
            GMAC = { isa = PBXGroup; children = ( GMACNEST ); path = Mac; sourceTree = "<group>"; };
            /* a NESTED group with no path of its own: contributes no path component */
            GMACNEST = { isa = PBXGroup; children = ( FMACAPP ); name = "App Sources"; sourceTree = "<group>"; };
            GIOS = { isa = PBXGroup; children = ( FIOSAPP ); path = iOS; sourceTree = "<group>"; };
            GSHARED = { isa = PBXGroup; children = ( FSEND, FCOMMON ); path = Shared; sourceTree = "<group>"; };
            FMACAPP = { isa = PBXFileReference; path = AppDelegate.swift; sourceTree = "<group>"; };
            FIOSAPP = { isa = PBXFileReference; path = AppDelegate.swift; sourceTree = "<group>"; };
            FSEND = { isa = PBXFileReference; path = Send.swift; sourceTree = "<group>"; };
            FCOMMON = { isa = PBXFileReference; path = Common.swift; sourceTree = "<group>"; };
            /* SOURCE_ROOT-relative: resolves against the project dir, NOT its group's dir */
            FLEGACY = { isa = PBXFileReference; name = Legacy.swift; path = Vendor/Legacy.swift; sourceTree = SOURCE_ROOT; };
            BFMACAPP = { isa = PBXBuildFile; fileRef = FMACAPP; };
            BFSEND = { isa = PBXBuildFile; fileRef = FSEND; };
            BFLEGACY = { isa = PBXBuildFile; fileRef = FLEGACY; };
            BFCOMMONM = { isa = PBXBuildFile; fileRef = FCOMMON; };
            BFIOSAPP = { isa = PBXBuildFile; fileRef = FIOSAPP; };
            BFCOMMONI = { isa = PBXBuildFile; fileRef = FCOMMON; };
            PSMAC = { isa = PBXSourcesBuildPhase; files = ( BFMACAPP, BFSEND, BFLEGACY, BFCOMMONM ); };
            PSIOS = { isa = PBXSourcesBuildPhase; files = ( BFIOSAPP, BFCOMMONI ); };
            PSTEST = { isa = PBXSourcesBuildPhase; files = ( ); };
            TMAC = {
                isa = PBXNativeTarget;
                buildPhases = ( PSMAC );
                name = MacApp;
                productType = "com.apple.product-type.application";
            };
            TIOS = {
                isa = PBXNativeTarget;
                buildPhases = ( PSIOS );
                name = IosApp;
                productType = "com.apple.product-type.application";
            };
            TTEST = {
                isa = PBXNativeTarget;
                buildPhases = ( PSTEST );
                name = IosAppTests;
                productType = "com.apple.product-type.bundle.unit-test";
            };
        };
        rootObject = ROOT;
    }
    """

    private func model(_ text: String) throws -> PbxprojModel {
        try parsePbxproj(text: text, file: "project.pbxproj")
    }
    /// No target in the classic fixture synchronizes a folder, so the filesystem must never be asked.
    private let noFS: (String) -> [String]? = { _ in
        XCTFail("swiftFilesUnder must not be called for a project with no synchronized groups")
        return nil
    }
    /// A dictionary-backed `XcodeScopeFS`. `manifests` maps a package DIRECTORY to its Package.swift
    /// text — the resolver only ever reads that one file.
    private func fsStub(swiftFilesUnder: @escaping (String) -> [String]? = { _ in nil },
                        manifests: [String: String] = [:],
                        subdirs: [String: [String]] = [:]) -> XcodeScopeFS {
        XcodeScopeFS(
            swiftFilesUnder: swiftFilesUnder,
            readFile: { path in
                let suffix = "/Package.swift"
                guard path.hasSuffix(suffix) else { return nil }
                return manifests[String(path.dropLast(suffix.count))]
            },
            subdirectories: { subdirs[$0] ?? [] },
            directoryExists: { _ in true })
    }

    func testNestedGroupAndSourceRootReferencesResolve() throws {
        let scope = try xcodeTargetScope(model: model(classic), projectDir: "/repo",
                                         targetName: "MacApp", fs: fsStub(swiftFilesUnder: noFS))
        XCTAssertEqual(scope.files.sorted(), [
            "/repo/Mac/AppDelegate.swift",      // through a pathless nested group — Mac/, not Mac/App Sources/
            "/repo/Shared/Common.swift",
            "/repo/Shared/Send.swift",
            "/repo/Vendor/Legacy.swift",        // SOURCE_ROOT: project-dir-relative, its group ignored
        ])
    }

    func testOneTargetsSourcesDoNotLeakIntoTheOther() throws {
        // THE MEASURED DEFECT IN MINIATURE. Send.swift is the Apple-events analog: compiled by MacApp
        // only, sitting in a folder both targets draw from. It appearing in IosApp's list is exactly
        // the cross-target attribution the whole feature exists to remove — and Common.swift staying
        // IN both lists is the mirror assertion, because a fix that drops shared files fixes the
        // false alarm by introducing the miss.
        let scope = try xcodeTargetScope(model: model(classic), projectDir: "/repo",
                                         targetName: "IosApp", fs: fsStub(swiftFilesUnder: noFS))
        XCTAssertEqual(scope.files.sorted(), [
            "/repo/Shared/Common.swift",        // membership in BOTH targets — must survive scoping
            "/repo/iOS/AppDelegate.swift",
        ])
    }

    func testUnknownTargetRefusesAndListsShippedProductsFirst() throws {
        let m = try model(classic)
        XCTAssertThrowsError(try xcodeTargetScope(model: m, projectDir: "/repo",
                                                  targetName: "IosApp-typo", fs: fsStub(swiftFilesUnder: noFS))) { e in
            guard case XcodeScopeError.unknownTarget(_, let available) = e else {
                return XCTFail("wrong error: \(e)")
            }
            // The vocabulary, apps before test bundles, each with its kind: a mistyped name must not
            // resolve to the nearest neighbour (`IosApp` vs `IosAppTests` differ by a suffix), and the
            // listing is what lets the user type the right one next.
            XCTAssertEqual(available.map(\.name), ["IosApp", "MacApp", "IosAppTests"])
            XCTAssertEqual(available.map(\.kindLabel), ["application", "application", "bundle.unit-test"])
        }
    }

    func testDanglingFileRefRefusesRatherThanShrugging() throws {
        // A build file whose fileRef names no object COULD have been a Swift source; with the
        // reference gone there is no way to prove otherwise, and dropping it silently would be a
        // purity claim over whatever it was.
        let broken = classic.replacingOccurrences(of: "BFSEND = { isa = PBXBuildFile; fileRef = FSEND; };",
                                                  with: "BFSEND = { isa = PBXBuildFile; fileRef = FGONE; };")
        XCTAssertThrowsError(try xcodeTargetScope(model: model(broken), projectDir: "/repo",
                                                  targetName: "MacApp", fs: fsStub(swiftFilesUnder: noFS))) { e in
            guard case XcodeScopeError.unresolvableSource(let target, _) = e else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(target, "MacApp")
        }
    }

    func testABuildGeneratedSwiftFileIsSkippedNotRefused() throws {
        // Found on WordPress-iOS, not imagined: its `Secrets.swift` is BUILT_PRODUCTS_DIR-relative —
        // generated at build time, not in the repo — and the first draft REFUSED the whole target over
        // it. Skipping is sound precisely because the unscoped scan cannot see the file either; the
        // refusal is reserved for a file that IS in the repo and about to be dropped (the broken-chain
        // case, asserted separately above).
        let withGenerated = classic.replacingOccurrences(
            of: "FLEGACY = { isa = PBXFileReference; name = Legacy.swift; path = Vendor/Legacy.swift; sourceTree = SOURCE_ROOT; };",
            with: "FLEGACY = { isa = PBXFileReference; name = Secrets.swift; path = ../Secrets/Secrets.swift; sourceTree = BUILT_PRODUCTS_DIR; };")
        let scope = try xcodeTargetScope(model: model(withGenerated), projectDir: "/repo",
                                         targetName: "MacApp", fs: fsStub(swiftFilesUnder: noFS))
        XCTAssertEqual(scope.files.sorted(), [
            "/repo/Mac/AppDelegate.swift",
            "/repo/Shared/Common.swift",
            "/repo/Shared/Send.swift",
        ], "the generated file is out; everything the repo holds is still in")
    }

    func testTruncatedPbxprojRefusesWithTheFileName() {
        XCTAssertThrowsError(try model(String(classic.prefix(400)))) { e in
            guard case XcodeScopeError.unparseable(let file, _) = e else {
                return XCTFail("a structurally broken pbxproj must refuse, not resolve less: \(e)")
            }
            XCTAssertEqual(file, "project.pbxproj")
        }
    }

    // ── Xcode 16 synchronized folders ─────────────────────────────────────────────────────────────
    // Five of the seven corpus apps use this form, NetNewsWire included — its Mac-only Apple-event
    // code is kept out of the iOS target by a membership EXCEPTION, so both halves of the exception
    // semantics carry the actual fix: for the OWNING target the listed files are OUT; for another
    // target the same shape means those files are IN (NetNewsWire's Mac share extension is built
    // entirely from additions on folders it does not own).
    private let synchronized = """
    {
        objects = {
            ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP, TEXT ); };
            G0 = { isa = PBXGroup; children = ( GSYNC ); sourceTree = "<group>"; };
            GSYNC = { isa = PBXFileSystemSynchronizedRootGroup; exceptions = ( XAPP, XEXT ); path = App; sourceTree = "<group>"; };
            XAPP = {
                isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
                membershipExceptions = ( MacOnly.swift, "Sub Dir/Helper.xib" );
                target = TAPP;
            };
            XEXT = {
                isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
                membershipExceptions = ( MacOnly.swift );
                target = TEXT;
            };
            TAPP = {
                isa = PBXNativeTarget;
                buildPhases = ( );
                fileSystemSynchronizedGroups = ( GSYNC );
                name = App;
                productType = "com.apple.product-type.application";
            };
            TEXT = {
                isa = PBXNativeTarget;
                buildPhases = ( );
                name = Ext;
                productType = "com.apple.product-type.app-extension";
            };
        };
        rootObject = ROOT;
    }
    """

    func testSynchronizedFolderMembershipIsFilesystemMinusOwnExceptions() throws {
        let scope = try xcodeTargetScope(model: model(synchronized), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(swiftFilesUnder: { dir in
            XCTAssertEqual(dir, "/repo/App")
            return ["/repo/App/Main.swift", "/repo/App/MacOnly.swift", "/repo/App/Sub Dir/Deep.swift"]
        }))
        XCTAssertEqual(scope.files.sorted(), [
            "/repo/App/Main.swift",
            "/repo/App/Sub Dir/Deep.swift",     // recursion into subfolders is the folder's default
        ], "MacOnly.swift is this target's OWN exception and must be out; everything else stays in")
    }

    func testExceptionSetOnAForeignFolderMeansMembershipAddition() throws {
        // Ext does not synchronize the folder; its exception set is the ADDITION form. Reading it as
        // an exclusion (or not reading it) leaves Ext with no sources at all — and MacOnly.swift is
        // in Ext's compiled list even though the folder's owner excludes it from ITS OWN.
        let scope = try xcodeTargetScope(model: model(synchronized), projectDir: "/repo",
                                         targetName: "Ext", fs: fsStub(swiftFilesUnder: { _ in
            XCTFail("Ext owns no synchronized folder; membership additions come from the exception "
                    + "set, not a folder walk")
            return nil
        }))
        XCTAssertEqual(scope.files.sorted(), ["/repo/App/MacOnly.swift"])
    }

    func testAFileExcludedFromTheOwnerButAddedToADependencyStaysInTheClosureUnion() throws {
        // NetNewsWire's real shape, which the first draft dropped: SafariExtensionHandler.swift is
        // membership-EXCLUDED from the Mac app (the folder's owner) and ADDED to `Subscribe to Feed`
        // — and the Mac app DEPENDS on that extension, so both are in the Mac closure. A group-level
        // "owned by someone in the closure ⇒ skip the additions" test loses the file from the union
        // entirely: silently absent, i.e. claimed pure, inside the feature built to stop exactly that.
        // The ownership test must be per EXCEPTION SET.
        let withDep = synchronized
            .replacingOccurrences(of: "fileSystemSynchronizedGroups = ( GSYNC );",
                                  with: "fileSystemSynchronizedGroups = ( GSYNC ); dependencies = ( DEP );")
            .replacingOccurrences(of: "TEXT = {",
                                  with: "DEP = { isa = PBXTargetDependency; target = TEXT; };\n            TEXT = {")
        let scope = try xcodeTargetScope(model: model(withDep), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(swiftFilesUnder: { _ in
            ["/repo/App/Main.swift", "/repo/App/MacOnly.swift", "/repo/App/Sub Dir/Deep.swift"]
        }))
        XCTAssertEqual(scope.closure.map(\.name), ["App", "Ext"])
        XCTAssertEqual(scope.files.sorted(), [
            "/repo/App/MacOnly.swift",          // out of App's own membership, IN via Ext's addition
            "/repo/App/Main.swift",
            "/repo/App/Sub Dir/Deep.swift",
        ])
    }

    func testAMissingSynchronizedFolderRefusesRatherThanScanningLess() throws {
        XCTAssertThrowsError(try xcodeTargetScope(model: model(synchronized), projectDir: "/repo",
                                                  targetName: "App", fs: fsStub())) { e in
            guard case XcodeScopeError.missingSyncFolder(let target, let folder) = e else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(target, "App")
            XCTAssertEqual(folder, "/repo/App", "the refusal must name the folder it could not read")
        }
    }

    // ── the in-project dependency closure ─────────────────────────────────────────────────────────

    func testDependencyClosureIncludesTheFrameworkTargetsSources() throws {
        // An app whose shared code lives in a framework TARGET (the pre-SPM layout, still everywhere):
        // scoping to the app alone would drop the framework's sources — the miss-shaped mirror of the
        // cross-target over-attribution, and the reason the closure exists. Wired through a
        // PBXTargetDependency -> PBXContainerItemProxy pair, which is how pbxproj actually spells it.
        let withDep = """
        {
            objects = {
                ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP, TKIT ); };
                G0 = { isa = PBXGroup; children = ( FAPP, FKIT ); sourceTree = "<group>"; };
                FAPP = { isa = PBXFileReference; path = App.swift; sourceTree = "<group>"; };
                FKIT = { isa = PBXFileReference; path = Kit.swift; sourceTree = "<group>"; };
                BFAPP = { isa = PBXBuildFile; fileRef = FAPP; };
                BFKIT = { isa = PBXBuildFile; fileRef = FKIT; };
                PSAPP = { isa = PBXSourcesBuildPhase; files = ( BFAPP ); };
                PSKIT = { isa = PBXSourcesBuildPhase; files = ( BFKIT ); };
                DEP = { isa = PBXTargetDependency; targetProxy = PROXY; };
                PROXY = { isa = PBXContainerItemProxy; containerPortal = ROOT; proxyType = 1; remoteGlobalIDString = TKIT; };
                TAPP = {
                    isa = PBXNativeTarget;
                    buildPhases = ( PSAPP );
                    dependencies = ( DEP );
                    name = App;
                    productType = "com.apple.product-type.application";
                };
                TKIT = {
                    isa = PBXNativeTarget;
                    buildPhases = ( PSKIT );
                    name = Kit;
                    productType = "com.apple.product-type.framework";
                };
            };
            rootObject = ROOT;
        }
        """
        let scope = try xcodeTargetScope(model: model(withDep), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(swiftFilesUnder: noFS))
        XCTAssertEqual(scope.closure.map(\.name), ["App", "Kit"])
        XCTAssertEqual(scope.files.sorted(), ["/repo/App.swift", "/repo/Kit.swift"])
        // …and scoping to the framework alone must NOT drag the app in: the edge is directed.
        let kitOnly = try xcodeTargetScope(model: model(withDep), projectDir: "/repo",
                                           targetName: "Kit", fs: fsStub(swiftFilesUnder: noFS))
        XCTAssertEqual(kitOnly.files.sorted(), ["/repo/Kit.swift"])
    }

    // ── the OpenStep reader itself, on the corner that would corrupt everything after it ──────────

    func testCommentsAndQuotedStringsParseLikeTheRealFormat() throws {
        // pbxproj annotates nearly every id with `/* name */`, including between a key and its `=`;
        // names with spaces are quoted ("NetNewsWire Share Extension" is a real target name). A parse
        // that mishandles either desynchronises silently — the same failure class the build-settings
        // evaluator's flip #15 records for two comment scanners disagreeing.
        let text = """
        {
            objects = {
                ROOT /* Project object */ = { isa = PBXProject; mainGroup = G0; targets = ( T1 /* app */ ); };
                G0 = { isa = PBXGroup; children = ( F1 ); sourceTree = "<group>"; };
                F1 /* Share View.swift */ = { isa = PBXFileReference; path = "Share View.swift"; sourceTree = "<group>"; };
                B1 = { isa = PBXBuildFile; fileRef = F1 /* Share View.swift */; };
                P1 = { isa = PBXSourcesBuildPhase; files = ( B1, ); };
                T1 = { isa = PBXNativeTarget; buildPhases = ( P1 ); name = "My App"; productType = "com.apple.product-type.application"; };
            };
            rootObject = ROOT;
        }
        """
        let scope = try xcodeTargetScope(model: model(text), projectDir: "/r",
                                         targetName: "My App", fs: fsStub(swiftFilesUnder: noFS))
        XCTAssertEqual(scope.files.sorted(), ["/r/Share View.swift"])
    }

    // ── LOCAL Swift package products ──────────────────────────────────────────────────────────────
    // The IceCubes measurement that forced this half: scoped to its app target, the verify analyzed
    // `[Notify]` while the app's real Camera/Photos reach lived in `Packages/*` — a green tick over a
    // thin shell. Local products resolve INTO the scope; remote ones stay counted-and-disclosed; a
    // local product that cannot be resolved soundly REFUSES.

    /// An app whose product deps are one drag-in local package (`Kit`, no `package` field — the
    /// spelling every corpus app uses) and one remote (`RemoteKit`). Kit's own manifest depends on a
    /// sibling local package `Base` via `.product(name:package:)` — the transitive edge — and Base in
    /// turn depends on a remote product.
    private let withPackages = """
    {
        objects = {
            ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP ); };
            G0 = { isa = PBXGroup; children = ( FAPP, FKIT, FBASE ); sourceTree = "<group>"; };
            FAPP = { isa = PBXFileReference; path = App.swift; sourceTree = "<group>"; };
            FKIT = { isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/Kit; sourceTree = "<group>"; };
            FBASE = { isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/Base; sourceTree = "<group>"; };
            BAPP = { isa = PBXBuildFile; fileRef = FAPP; };
            PS = { isa = PBXSourcesBuildPhase; files = ( BAPP ); };
            PDKIT = { isa = XCSwiftPackageProductDependency; productName = Kit; };
            PDREMOTE = { isa = XCSwiftPackageProductDependency; package = REMOTEREF; productName = RemoteKit; };
            REMOTEREF = { isa = XCRemoteSwiftPackageReference; repositoryURL = "https://example.com/RemoteKit"; };
            TAPP = {
                isa = PBXNativeTarget;
                buildPhases = ( PS );
                name = App;
                packageProductDependencies = ( PDKIT, PDREMOTE );
                productType = "com.apple.product-type.application";
            };
        };
        rootObject = ROOT;
    }
    """
    private let kitManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "Kit",
        products: [.library(name: "Kit", targets: ["Kit"])],
        dependencies: [.package(path: "../Base")],
        targets: [.target(name: "Kit", dependencies: [.product(name: "Base", package: "Base")])]
    )
    """
    private let baseManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "Base",
        products: [.library(name: "Base", targets: ["BaseCore"])],
        targets: [.target(name: "BaseCore",
                          dependencies: [.product(name: "Elsewhere", package: "remote-elsewhere")])]
    )
    """

    func testLocalPackageProductsResolveIntoTheScopeTransitively() throws {
        var walked: [String] = []
        let scope = try xcodeTargetScope(model: model(withPackages), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(
            swiftFilesUnder: { dir in
                walked.append(dir)
                return ["\(dir)/A.swift"]
            },
            manifests: ["/repo/Packages/Kit": kitManifest, "/repo/Packages/Base": baseManifest]))
        XCTAssertEqual(scope.files.sorted(), [
            "/repo/App.swift",
            "/repo/Packages/Base/Sources/BaseCore/A.swift",   // product name Base -> target BaseCore:
                                                              // the products list decides, not the name
            "/repo/Packages/Kit/Sources/Kit/A.swift",
        ], "Kit via the app's product dep, Base via Kit's `.product(…)` edge — losing either is the "
           + "IceCubes shape: a scope that reads as successful while the app's real code is outside it")
        XCTAssertEqual(scope.localPackages, ["Base", "Kit"])
        // RemoteKit (project-level) + Elsewhere (from Base's manifest): counted, disclosed, NOT refused.
        XCTAssertEqual(scope.remoteProductCount, 2)
        XCTAssertEqual(walked.sorted(), ["/repo/Packages/Base/Sources/BaseCore",
                                         "/repo/Packages/Kit/Sources/Kit"])
    }

    /// THE BARE-NAME SPELLING OF THE SAME EDGE — the one NetNewsWire actually uses.
    ///
    /// SwiftPM resolves a bare dependency string against a dependency package's PRODUCTS, so
    /// `.package(path: "../Base")` beside a plain `"Base"` in the target is a cross-package edge with
    /// no `.product(…)` anywhere. `targetClosure` drops a name its own package does not declare —
    /// correct on the SPM `--target` path, where "not declared here" really does mean "no sources in
    /// this tree", and wrong here, where the sibling package is three directories away.
    ///
    /// MEASURED, which is why this test exists: NetNewsWire's `Modules/` holds 17 local packages and
    /// the scope resolved 14. The three missing — CloudKitSync, FeedFinder, NewsBlur — were exactly
    /// those no app TARGET names directly, reachable only through `Account`, whose manifest spells
    /// every dependency as a bare string. `NewsBlurAPICaller` is the app's sync layer, so the scope
    /// analyzed the app minus its network client.
    func testABareNameDependencyOnASiblingLocalPackageResolvesToo() throws {
        let bareNameKit = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Kit",
            products: [.library(name: "Kit", targets: ["Kit"])],
            dependencies: [.package(path: "../Base")],
            targets: [.target(name: "Kit", dependencies: ["Base"])]
        )
        """
        let scope = try xcodeTargetScope(model: model(withPackages), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(
            swiftFilesUnder: { dir in ["\(dir)/A.swift"] },
            manifests: ["/repo/Packages/Kit": bareNameKit, "/repo/Packages/Base": baseManifest]))
        XCTAssertEqual(scope.files.sorted(), [
            "/repo/App.swift",
            "/repo/Packages/Base/Sources/BaseCore/A.swift",
            "/repo/Packages/Kit/Sources/Kit/A.swift",
        ], "Base is reachable ONLY through Kit's bare-string dependency — dropping it scopes the app "
           + "minus a package it compiles")
        XCTAssertEqual(scope.localPackages, ["Base", "Kit"])
    }

    /// …and the floor under it: a bare name matching NO local product is still remote. Without this,
    /// the fix above could be satisfied by resolving every bare string to something.
    func testABareNameMatchingNoLocalPackageStaysRemote() throws {
        let bareRemote = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Kit",
            products: [.library(name: "Kit", targets: ["Kit"])],
            targets: [.target(name: "Kit", dependencies: ["Alamofire"])]
        )
        """
        let noBase = withPackages
            .replacingOccurrences(of: "FBASE = { isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/Base; sourceTree = \"<group>\"; };\n", with: "")
            .replacingOccurrences(of: "children = ( FAPP, FKIT, FBASE )", with: "children = ( FAPP, FKIT )")
        let scope = try xcodeTargetScope(model: model(noBase), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(
            swiftFilesUnder: { dir in ["\(dir)/A.swift"] },
            manifests: ["/repo/Packages/Kit": bareRemote]))
        XCTAssertEqual(scope.localPackages, ["Kit"])
        XCTAssertEqual(scope.files.sorted(), ["/repo/App.swift", "/repo/Packages/Kit/Sources/Kit/A.swift"])
        // RemoteKit (project-level) + Alamofire (Kit's bare name, no local product): both COUNTED.
        // Previously the bare name was dropped at closure level and reached no counter at all.
        XCTAssertEqual(scope.remoteProductCount, 2)
    }

    func testARemoteOnlyProductDependencyIsDisclosedNotRefused() throws {
        // Remove the local packages entirely: the remaining product deps are remote (one by explicit
        // XCRemoteSwiftPackageReference, one a bare name no local package declares). Both must
        // DISCLOSE — refusing here would break every repo that uses any remote dependency, and the
        // κ ledger already carries the uncovered-module story.
        let remoteOnly = withPackages
            .replacingOccurrences(of: "FKIT = { isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/Kit; sourceTree = \"<group>\"; };\n", with: "")
            .replacingOccurrences(of: "FBASE = { isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/Base; sourceTree = \"<group>\"; };\n", with: "")
            .replacingOccurrences(of: "children = ( FAPP, FKIT, FBASE )", with: "children = ( FAPP )")
        let scope = try xcodeTargetScope(model: model(remoteOnly), projectDir: "/repo",
                                         targetName: "App", fs: fsStub())
        XCTAssertEqual(scope.files, ["/repo/App.swift"])
        XCTAssertEqual(scope.localPackages, [])
        XCTAssertEqual(scope.remoteProductCount, 2)
    }

    func testAnAmbiguousLocalProductNameRefuses() throws {
        // Two local packages both declaring product `Kit`: picking one silently would scope to the
        // wrong sources with full confidence — the exact failure mode this feature exists to remove,
        // one level down.
        let twoKits = withPackages.replacingOccurrences(
            of: "path = Packages/Base;", with: "path = Packages/Base2;")
        XCTAssertThrowsError(try xcodeTargetScope(model: model(twoKits), projectDir: "/repo",
                                                  targetName: "App", fs: fsStub(
            manifests: ["/repo/Packages/Kit": kitManifest,
                        "/repo/Packages/Base2": kitManifest]))) { e in
            guard case XcodeScopeError.unresolvableLocalProduct(let p, _) = e else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(p, "Kit")
        }
    }

    func testADeclaredLocalPackageWithNoManifestRefuses() throws {
        // The dep carries an explicit XCLocalSwiftPackageReference whose directory has no readable
        // Package.swift. That package IS the target's code; proceeding without it is a purity claim
        // over all of it.
        let declaredLocal = withPackages
            .replacingOccurrences(of: "PDKIT = { isa = XCSwiftPackageProductDependency; productName = Kit; };",
                                  with: "PDKIT = { isa = XCSwiftPackageProductDependency; package = LOCALREF; productName = Kit; };\n"
                                      + "            LOCALREF = { isa = XCLocalSwiftPackageReference; relativePath = Packages/Gone; };")
        XCTAssertThrowsError(try xcodeTargetScope(model: model(declaredLocal), projectDir: "/repo",
                                                  targetName: "App", fs: fsStub())) { e in
            guard case XcodeScopeError.unresolvableLocalProduct(let p, let why) = e else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(p, "Kit")
            XCTAssertTrue(why.contains("/repo/Packages/Gone"), "the refusal must name the directory: \(why)")
        }
    }

    func testSynchronizedFolderSubdirectoriesAreDiscoveredAsPackages() throws {
        // NetNewsWire's layout: a synchronized `Modules/` folder that no target compiles directly,
        // whose SUBDIRECTORIES are the local packages the product deps name.
        let modulesStyle = withPackages
            .replacingOccurrences(of: "FKIT = { isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/Kit; sourceTree = \"<group>\"; };",
                                  with: "FKIT = { isa = PBXFileSystemSynchronizedRootGroup; path = Modules; sourceTree = \"<group>\"; };")
            .replacingOccurrences(of: "FBASE = { isa = PBXFileReference; lastKnownFileType = wrapper; path = Packages/Base; sourceTree = \"<group>\"; };\n", with: "")
            .replacingOccurrences(of: "children = ( FAPP, FKIT, FBASE )", with: "children = ( FAPP, FKIT )")
        let scope = try xcodeTargetScope(model: model(modulesStyle), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(
            swiftFilesUnder: { dir in ["\(dir)/A.swift"] },
            manifests: ["/repo/Modules/Kit": kitManifest, "/repo/Modules/Base": baseManifest],
            subdirs: ["/repo/Modules": ["/repo/Modules/Kit", "/repo/Modules/Base"]]))
        XCTAssertEqual(scope.files.sorted(), [
            "/repo/App.swift",
            "/repo/Modules/Base/Sources/BaseCore/A.swift",
            "/repo/Modules/Kit/Sources/Kit/A.swift",
        ])
        XCTAssertEqual(scope.localPackages, ["Base", "Kit"])
    }

    /// WordPress's Modules shape: the manifest DECLARES a product whose member target is built by a
    /// helper function (`.xcodeTarget("XcodeTarget_App", dependencies: keystoneDependencies)`), so the
    /// structural parse sees the product but not the target. That provable incompleteness must route
    /// through SwiftPM's own reader (`dump-package`) — and REFUSE when that reader is unavailable,
    /// because "could not read the manifest" must never become "scanned a subset".
    private let dynamicManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "Modules",
        products: helperProducts + [.library(name: "Kit", targets: ["Kit"])],
        targets: [.target(name: "Kit")] + helperTargets
    )
    """
    private let dumpJSON = """
    {"products": [{"name": "Kit", "targets": ["Kit"]},
                  {"name": "XcodeTarget_App", "targets": ["XcodeTarget_App"]}],
     "targets": [{"name": "Kit", "type": "regular", "dependencies": []},
                 {"name": "XcodeTarget_App", "type": "regular",
                  "path": "Sources/XcodeSupport/XcodeTarget_App",
                  "dependencies": [{"byName": ["Kit", null]},
                                   {"product": ["Alamofire", "Alamofire", null, null]}]}]}
    """

    func testAProgrammaticManifestResolvesViaDumpPackageAndSaysSo() throws {
        let project = withPackages.replacingOccurrences(of: "productName = Kit;",
                                                        with: "productName = XcodeTarget_App;")
        let scope = try xcodeTargetScope(model: model(project), projectDir: "/repo",
                                         targetName: "App", fs: XcodeScopeFS(
            swiftFilesUnder: { dir in ["\(dir)/A.swift"] },
            readFile: { path in
                path == "/repo/Packages/Kit/Package.swift" ? self.dynamicManifest : nil
            },
            subdirectories: { _ in [] },
            directoryExists: { _ in true },
            dumpPackage: { dir in dir.hasSuffix("/Packages/Kit") ? self.dumpJSON : nil }))
        XCTAssertEqual(scope.packagesReadViaDump, ["Kit"], "executing the manifest is a different "
                       + "trust statement from parsing it, and the caller must be able to say so")
        XCTAssertTrue(scope.files.contains("/repo/Packages/Kit/Sources/XcodeSupport/XcodeTarget_App/A.swift"),
                      "the dump's explicit `path:` decides the source dir")
        XCTAssertTrue(scope.files.contains("/repo/Packages/Kit/Sources/Kit/A.swift"),
                      "the shim target's byName dependency pulls the real library in")
        XCTAssertEqual(scope.remoteProductCount, 2, "Alamofire from the dump + RemoteKit from the project")
    }

    func testAProgrammaticManifestWithNoDumpAvailableRefuses() throws {
        // Same project, dump unavailable (a machine without a toolchain): the structural parse cannot
        // see the helper-built target, and proceeding without it would scope to a subset that reads
        // as complete. Exit 2, naming the product.
        let project = withPackages.replacingOccurrences(of: "productName = Kit;",
                                                        with: "productName = XcodeTarget_App;")
        XCTAssertThrowsError(try xcodeTargetScope(model: model(project), projectDir: "/repo",
                                                  targetName: "App", fs: XcodeScopeFS(
            swiftFilesUnder: { dir in ["\(dir)/A.swift"] },
            readFile: { path in path == "/repo/Packages/Kit/Package.swift" ? self.dynamicManifest : nil },
            subdirectories: { _ in [] },
            directoryExists: { _ in true }))) { e in
            guard case XcodeScopeError.unresolvableLocalProduct(let p, _) = e else {
                return XCTFail("wrong error: \(e)")
            }
            XCTAssertEqual(p, "XcodeTarget_App")
        }
    }

    // ── platform pruning ──────────────────────────────────────────────────────────────────────────
    // Resolving NetNewsWire's local packages brought the AppleEvents false finding BACK: RSCore's
    // `SendToBlogEditorApp.swift` is a member of the package, wholly inside `#if os(macOS)`, and it
    // compiles to nothing on iOS. A file that compiles to nothing for the target's platform is not in
    // that target's build — but only when the settings SAY the platform, and only when the `#if` is
    // provably false; everything undecidable keeps the file.

    func testWhollyPlatformGatedFileIsPrunedFromTheOtherPlatformsScope() throws {
        // The RSCore shape verbatim: import + one os(macOS)-gated block, in a local package of an
        // app whose SDKROOT says iphoneos.
        let withPlatform = withPackages.replacingOccurrences(
            of: "TAPP = {",
            with: """
            XCAPP = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; }; name = Release; };
                        CLAPP = { isa = XCConfigurationList; buildConfigurations = ( XCAPP ); };
                        TAPP = {
                            buildConfigurationList = CLAPP;
            """)
        let macOnly = """
        import Foundation
        #if os(macOS)
        public struct SendToBlogEditorApp { public func send() {} }
        #endif
        """
        let live = """
        import Foundation
        #if os(macOS)
        func macSide() {}
        #endif
        public func alwaysHere() {}
        """
        let scope = try xcodeTargetScope(model: model(withPlatform), projectDir: "/repo",
                                         targetName: "App", fs: XcodeScopeFS(
            swiftFilesUnder: { dir in ["\(dir)/MacOnly.swift", "\(dir)/Live.swift"] },
            readFile: { path in
                if path.hasSuffix("/Package.swift") {
                    let dir = String(path.dropLast("/Package.swift".count))
                    return ["/repo/Packages/Kit": self.kitManifest, "/repo/Packages/Base": self.baseManifest][dir]
                }
                if path.hasSuffix("/MacOnly.swift") { return macOnly }
                if path.hasSuffix("/Live.swift") { return live }
                return nil
            },
            subdirectories: { _ in [] },
            directoryExists: { _ in true }))
        XCTAssertEqual(scope.platform, "iOS")
        XCTAssertEqual(scope.platformExcludedCount, 2, "one MacOnly.swift per package dir")
        let names = Set(scope.files.map { ($0 as NSString).lastPathComponent })
        XCTAssertFalse(names.contains("MacOnly.swift"),
                       "a file that compiles to nothing on iOS charges the iOS plist with macOS "
                       + "sensors — the NetNewsWire AppleEvents regression, verbatim")
        XCTAssertTrue(names.contains("Live.swift"),
                      "a PARTLY gated file has live declarations and must stay — pruning it would be "
                      + "the cardinal sin this layer exists to avoid")
    }

    func testUnknownPlatformMeansNoPruning() throws {
        // No SDKROOT anywhere: the resolver must not guess a platform, so nothing is pruned.
        let macOnly = "#if os(macOS)\nfunc f() {}\n#endif\n"
        let scope = try xcodeTargetScope(model: model(withPackages), projectDir: "/repo",
                                         targetName: "App", fs: XcodeScopeFS(
            swiftFilesUnder: { dir in ["\(dir)/MacOnly.swift"] },
            readFile: { path in
                if path.hasSuffix("/Package.swift") {
                    let dir = String(path.dropLast("/Package.swift".count))
                    return ["/repo/Packages/Kit": self.kitManifest, "/repo/Packages/Base": self.baseManifest][dir]
                }
                return macOnly
            },
            subdirectories: { _ in [] },
            directoryExists: { _ in true }))
        XCTAssertNil(scope.platform)
        XCTAssertEqual(scope.platformExcludedCount, 0)
        XCTAssertTrue(scope.files.contains("/repo/Packages/Kit/Sources/Kit/MacOnly.swift"))
    }

    func testPlatformConditionEvaluatorDecidesOnlyWhatItCanProve() {
        // Decidable both ways:
        XCTAssertTrue(swiftFileCompilesToNothing(source: "#if os(macOS)\nfunc f() {}\n#endif", on: "iOS"))
        XCTAssertFalse(swiftFileCompilesToNothing(source: "#if os(iOS)\nfunc f() {}\n#endif", on: "iOS"))
        // `#else` of a false condition is LIVE:
        XCTAssertFalse(swiftFileCompilesToNothing(
            source: "#if os(macOS)\nfunc mac() {}\n#else\nfunc other() {}\n#endif", on: "iOS"))
        // `#else` of a TRUE condition is dead — and the true branch's content decides:
        XCTAssertTrue(swiftFileCompilesToNothing(
            source: "#if os(macOS)\nimport AppKit\n#else\nfunc other() {}\n#endif", on: "macOS"))
        // `||` chains and negation:
        XCTAssertTrue(swiftFileCompilesToNothing(
            source: "#if os(macOS) || os(tvOS)\nfunc f() {}\n#endif", on: "iOS"))
        XCTAssertFalse(swiftFileCompilesToNothing(
            source: "#if !os(macOS)\nfunc f() {}\n#endif", on: "iOS"))
        // UNDECIDABLE conditions keep the file — `canImport` says nothing about os() here, and a
        // wrong "prunable" is a dropped live file:
        XCTAssertFalse(swiftFileCompilesToNothing(
            source: "#if canImport(AppKit)\nfunc f() {}\n#endif", on: "iOS"))
        XCTAssertFalse(swiftFileCompilesToNothing(
            source: "#if os(macOS) || canImport(AppKit)\nfunc f() {}\n#endif", on: "iOS"))
        // Mixed operators without parentheses are not folded — unknown, kept:
        XCTAssertFalse(swiftFileCompilesToNothing(
            source: "#if os(macOS) && DEBUG || os(iOS)\nfunc f() {}\n#endif", on: "iOS"))
        // Import-only content is no contribution:
        XCTAssertTrue(swiftFileCompilesToNothing(source: "import Foundation", on: "iOS"))
    }

    // ── the scope travels: this target's own entitlements ─────────────────────────────────────────
    // `--target` scopes the SCAN, but the `privacy-manifest --verify` that follows has only a report
    // and a plist — so it re-discovered `.entitlements` by walking the plist's directory and, on a repo
    // with several shipped binaries, refused to guess and left the entitlement-sourced keys unchecked.
    // Narrowing that SEARCH would still be a search. `CODE_SIGN_ENTITLEMENTS` NAMES the file, per target.

    func testTheTargetsOwnEntitlementsFileIsResolvedFromItsBuildSettings() throws {
        let withEnt = withPackages.replacingOccurrences(
            of: "TAPP = {",
            with: """
            XCAPP = { isa = XCBuildConfiguration; buildSettings = { CODE_SIGN_ENTITLEMENTS = iOS/App.entitlements; }; name = Release; };
                        CLAPP = { isa = XCConfigurationList; buildConfigurations = ( XCAPP ); };
                        TAPP = {
                            buildConfigurationList = CLAPP;
            """)
        let scope = try xcodeTargetScope(model: model(withEnt), projectDir: "/repo",
                                         targetName: "App", fs: XcodeScopeFS(
            swiftFilesUnder: { _ in nil },
            readFile: { path in path == "/repo/iOS/App.entitlements" ? "<plist/>" : nil },
            subdirectories: { _ in [] }, directoryExists: { _ in true }))
        XCTAssertEqual(scope.entitlements, "/repo/iOS/App.entitlements")
    }

    /// **AN UNDEFINED BUILD VARIABLE EXPANDS TO THE EMPTY STRING** — Xcode's rule, and the one that makes
    /// this exact rather than a guess. NetNewsWire writes
    /// `CODE_SIGN_ENTITLEMENTS = iOS/Resources/NetNewsWire$(DEVELOPER_ENTITLEMENTS).entitlements`, and
    /// `DEVELOPER_ENTITLEMENTS` is defined only in a personal file OUTSIDE the checkout (an optional
    /// `#include?` of `../../SharedXcodeSettings/…`). In a clone it is undefined, so the path is
    /// `NetNewsWire.entitlements` — precisely the file that checkout builds against, and the reason both
    /// `NetNewsWire.entitlements` and `NetNewsWire-dev.entitlements` exist beside each other.
    func testAnUndefinedBuildVariableExpandsToEmptyLikeXcode() throws {
        let withVar = withPackages.replacingOccurrences(
            of: "TAPP = {",
            with: """
            XCAPP = { isa = XCBuildConfiguration; buildSettings = { CODE_SIGN_ENTITLEMENTS = "iOS/App$(DEVELOPER_ENTITLEMENTS).entitlements"; }; name = Release; };
                        CLAPP = { isa = XCConfigurationList; buildConfigurations = ( XCAPP ); };
                        TAPP = {
                            buildConfigurationList = CLAPP;
            """)
        var asked: [String] = []
        let scope = try xcodeTargetScope(model: model(withVar), projectDir: "/repo",
                                         targetName: "App", fs: XcodeScopeFS(
            swiftFilesUnder: { _ in nil },
            readFile: { path in
                asked.append(path)
                return path == "/repo/iOS/App.entitlements" ? "<plist/>" : nil
            },
            subdirectories: { _ in [] }, directoryExists: { _ in true }))
        XCTAssertEqual(scope.entitlements, "/repo/iOS/App.entitlements",
                       "asked for: \(asked.filter { $0.hasSuffix(".entitlements") })")
        XCTAssertEqual(expandBuildVariables("a$(X)b${Y}c", defs: ["Y": "Q"]), "abQc",
                       "undefined -> empty, defined -> its value, both spellings")
    }

    /// A PATH THAT NAMES NO FILE IS NOT AN ANSWER. A variable this cannot resolve, a generated
    /// entitlements, a stale setting — each would produce a path, and handing the verify a path to a
    /// file that is not there would replace "we did not check" with "we checked the wrong thing".
    func testAnEntitlementsPathThatDoesNotExistResolvesToNil() throws {
        let missing = withPackages.replacingOccurrences(
            of: "TAPP = {",
            with: """
            XCAPP = { isa = XCBuildConfiguration; buildSettings = { CODE_SIGN_ENTITLEMENTS = nowhere/App.entitlements; }; name = Release; };
                        CLAPP = { isa = XCConfigurationList; buildConfigurations = ( XCAPP ); };
                        TAPP = {
                            buildConfigurationList = CLAPP;
            """)
        let scope = try xcodeTargetScope(model: model(missing), projectDir: "/repo",
                                         targetName: "App", fs: fsStub())
        XCTAssertNil(scope.entitlements)
        // …and a target whose settings name none at all.
        let none = try xcodeTargetScope(model: model(withPackages), projectDir: "/repo",
                                        targetName: "App", fs: fsStub())
        XCTAssertNil(none.entitlements)
    }

    /// **`os(OSX)` IS LIVE SWIFT.** It is the legacy spelling of `os(macOS)` and Swift 6.3 still compiles
    /// its body on macOS — verified with `swiftc`, not assumed. Comparing the condition token to the
    /// platform name alone judged such a file to compile to NOTHING on a macOS target, so the prune
    /// dropped it and its functions were absent from `functions` — a ⟨0.21⟩ purity claim over live code,
    /// with the stderr count asserting a justification that is false for that file. Legacy Mac codebases
    /// are exactly where this spelling survives, and exactly where the Apple-events reach lives.
    func testTheLegacyOSXSpellingIsNotPrunedFromAMacTarget() throws {
        let legacy = """
        import Foundation
        #if os(OSX)
        public struct MacOnly { public func send() {} }
        #endif
        """
        XCTAssertFalse(swiftFileCompilesToNothing(source: legacy, on: "macOS"),
                       "os(OSX) is os(macOS) — pruning it drops live code from a macOS target's scope")
        // …and the control: it really IS inactive on iOS, so the prune still does its job.
        XCTAssertTrue(swiftFileCompilesToNothing(source: legacy, on: "iOS"),
                      "the alias must not make the condition true everywhere")
    }

    /// ⟨2026-08-08⟩ **A DIRECTORY NAMED LIKE A MODULE IS NOT THAT MODULE.** The first attempt at
    /// trimming the κ ledger took any analyzed path segment `Sources/<X>/` as proof module X had been
    /// read. It proves a DIRECTORY named X was read — and naming an integration folder after the SDK it
    /// wraps is ordinary in the `.xcodeproj` trees this release's `--target` serves.
    ///
    /// `internalModules` gates BOTH disclosure channels: the coverage ledger and the per-function
    /// `invisible` set, which is the only thing between an unresolved call into a blind module and a
    /// purity claim. Measured on the shipped binary with a ONE-DIRECTORY-NAME diff: `App/Sources/Stripe/`
    /// reported ZERO effectful functions and no ledger at all, while `App/Sources/StripeIntegration/`
    /// disclosed the import and hedged both functions. A visible false disclosure traded for a silent
    /// missing one — the trade this project forbids.
    ///
    /// This is a PROCESS test rather than a unit one because the rule lives in the scan driver and the
    /// property is about the whole report.
    func testAFolderNamedAfterAnSDKDoesNotSilenceItsDisclosure() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func build(_ folder: String) throws -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-sdkdir-\(UUID().uuidString)")
            try fm.createDirectory(at: root.appendingPathComponent("App/Sources/\(folder)"),
                                   withIntermediateDirectories: true)
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "App", targets: [.executableTarget(name: "App", path: "App")])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try """
            import Foundation
            import Stripe
            func chargeCard() { StripeClient().charge(amount: 100) }
            chargeCard()
            """.write(to: root.appendingPathComponent("App/Sources/\(folder)/Shim.swift"),
                      atomically: true, encoding: .utf8)
            return root
        }
        for folder in ["Stripe", "StripeIntegration"] {
            let root = try build(folder)
            defer { try? fm.removeItem(at: root) }
            let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
            XCTAssertTrue(r.err.contains("Stripe"),
                          "folder `\(folder)`: the uncovered import must be named — the root manifest "
                          + "declares target `App`, not `Stripe`, so nothing here was analyzed under "
                          + "that module name. stderr: \(r.err)")
        }
    }

    /// ⟨2026-08-08, round 3⟩ THE SAME SIN IN TWO MORE SPELLINGS, both measured on the built binary.
    ///
    /// `internalModules` gates the coverage ledger AND the per-function `invisible` hedge, so a name
    /// wrongly marked internal is a purity claim. Three separate rules produced one:
    ///   (a) every entry of `<root>/Sources/` inserted with NO manifest check — a manifest-less,
    ///       `.xcodeproj`-shaped tree with `Sources/Stripe/` reported zero functions. Pre-existing.
    ///   (b) a `.testTarget` (or `.plugin`, or a `path:`-relocated target) named like the SDK accepted
    ///       as proof that `Sources/<X>` is that target's source root — when its sources live under
    ///       `Tests/<X>`, `Plugins/<X>`, or wherever `path:` says. That one was inside the fix for the
    ///       round-2 finding.
    ///
    /// The rule that closes both: an analyzed file must live under a DECLARED TARGET'S ACTUAL SOURCE
    /// ROOT. In an Xcode tree a folder is not a module — an app target compiles everything into one —
    /// so `Sources/<X>` ⇒ module X is honoured only where an SPM manifest says so.
    func testAFolderIsNotAModuleWithoutAManifestSayingSo() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let shim = """
        import Foundation
        import Stripe
        func chargeCard() { StripeClient().charge(amount: 100) }
        chargeCard()
        """
        // (a) no manifest anywhere — the root-level rule.
        let a = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-nm-\(UUID().uuidString)")
        try fm.createDirectory(at: a.appendingPathComponent("Sources/Stripe"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: a) }
        try shim.write(to: a.appendingPathComponent("Sources/Stripe/Shim.swift"), atomically: true, encoding: .utf8)
        let ra = try ProcessHarness.run(bin, [a.path, "--out", a.appendingPathComponent("r").path])
        XCTAssertTrue(ra.err.contains("Stripe"),
                      "no manifest declares `Stripe` a target, so the folder proves nothing: \(ra.err)")

        // (b) a manifest that declares `Stripe` — but as a TEST target, whose sources are Tests/Stripe.
        let b = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-tt-\(UUID().uuidString)")
        try fm.createDirectory(at: b.appendingPathComponent("Sources/Stripe"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: b) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App",
            targets: [.executableTarget(name: "App", path: "Src"), .testTarget(name: "Stripe")])
        """.write(to: b.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try shim.write(to: b.appendingPathComponent("Sources/Stripe/Shim.swift"), atomically: true, encoding: .utf8)
        let rb = try ProcessHarness.run(bin, [b.path, "--out", b.appendingPathComponent("r").path])
        XCTAssertTrue(rb.err.contains("Stripe"),
                      "a testTarget named Stripe has its sources in Tests/Stripe — it says nothing about "
                      + "Sources/Stripe: \(rb.err)")

        // …AND THE OTHER DIRECTION, which is how the path bug was caught: a genuinely declared target
        // must NOT be reported as a blind spot. Scanned RELATIVELY, because that is the invocation that
        // broke it — walking up from `./Sources/X` stopped at `.` before reaching the manifest.
        let c = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-ok-\(UUID().uuidString)")
        try fm.createDirectory(at: c.appendingPathComponent("Sources/Kit"), withIntermediateDirectories: true)
        try fm.createDirectory(at: c.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: c) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App",
            targets: [.executableTarget(name: "App"), .target(name: "Kit")])
        """.write(to: c.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func helper() {}\n".write(to: c.appendingPathComponent("Sources/Kit/K.swift"),
                                              atomically: true, encoding: .utf8)
        try "import Kit\nfunc use() { helper() }\nuse()\n"
            .write(to: c.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        let rc = try ProcessHarness.run(bin, [".", "--out", c.appendingPathComponent("r").path], cwd: c)
        XCTAssertFalse(rc.err.contains("Kit ("),
                       "`Kit` IS a declared target whose sources were analyzed — naming it uncovered is "
                       + "the false disclosure this rule exists to remove: \(rc.err)")
    }

    /// ⟨2026-08-08, round 4⟩ TWO MORE SPELLINGS, both in the rewrite that closed the last two.
    ///
    /// The manifest parse decides which directories are target source roots, and a name wrongly taken
    /// from it is marked internal — which silences the coverage ledger AND the per-function `invisible`
    /// hedge, leaving an effectful call reading pure under ⟨0.21⟩.
    ///   (a) **COMMENTS.** The scan had no comment awareness, so `// .target(name: "Stripe"),` was read
    ///       as a live declaration — and a commented-out target is precisely a directory that is NOT a
    ///       module, the exact exposure this whole derivation exists to close.
    ///   (b) **THE FIRST `name:` IN THE SPAN.** When a target's own name is computed (`name: appName` —
    ///       the helper shape that is live in WordPress-iOS's manifest), the first string-literal `name:`
    ///       inside the declaration belongs to a DEPENDENCY's `.product(name: "…")`. So the name being
    ///       silenced was, by construction, a real third-party module. The read is now depth-scoped to
    ///       the declaration's own arguments.
    func testACommentedOrComputedTargetNameCannotClaimAFolder() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func probe(_ targets: String) throws -> String {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-mf-\(UUID().uuidString)")
            try fm.createDirectory(at: root.appendingPathComponent("Sources/Stripe"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let appName = "App"
            let package = Package(name: "App", targets: [
            \(targets)
            ])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "public struct X {}\n".write(to: root.appendingPathComponent("Sources/Stripe/Shim.swift"),
                                             atomically: true, encoding: .utf8)
            try "import Foundation\nimport Stripe\nfunc pay() { StripeAPI.charge() }\npay()\n"
                .write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path]).err
        }
        // The control first: with no manifest mention of Stripe at all, the folder proves nothing.
        XCTAssertTrue(try probe("    .executableTarget(name: \"App\"),").contains("Stripe"),
                      "control: an SDK-named folder with no declaration must be disclosed")
        XCTAssertTrue(try probe("    // .target(name: \"Stripe\"),\n    .executableTarget(name: \"App\"),").contains("Stripe"),
                      "a COMMENTED-OUT target is not a target — reading it as one silences a real import")
        XCTAssertTrue(try probe("    .target(name: appName, dependencies: [.product(name: \"Stripe\", package: \"s\")]),").contains("Stripe"),
                      "with a computed target name the first literal `name:` in the span is a DEPENDENCY "
                      + "product — by construction the name of a real third-party module")
    }

    /// …and the manifest parse must not be able to kill the scan. An unclosed `.target(` ran the paren
    /// matcher to EOF and formed a range with a negative upper bound, trapping the process — one
    /// malformed `Package.swift` anywhere in an analyzed file's ancestor chain took the whole run down.
    func testAnUnclosedTargetDeclarationDoesNotTrapTheScan() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-eof-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.target(name: \"App\"\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\nfunc f() { _ = FileManager.default.contents(atPath: \"/x\") }\nf()\n"
            .write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertEqual(r.code, 0, "a malformed manifest must not trap the scan — exit \(r.code): \(r.err)")
    }

    /// ⟨2026-08-08, round 5⟩ **A PACKAGE NAME IS NOT A MODULE.** `internalModules` used to be seeded with
    /// the package name — which is not even a declaration: it comes from a first-`name:` regex over the
    /// manifest, falling back to the directory basename. When a package is named after the dependency it
    /// WRAPS, that seed marked a remote, never-analyzed module internal and silenced both disclosure
    /// channels.
    ///
    /// Live on firefox-ios at HEAD, which is how it was found: its `Package.swift` says `name: "Danger"`
    /// and wraps `.product(name: "Danger", package: "swift")`. Across `Dangerfile.swift`'s 41 report
    /// functions, every one hedged `DangerSwiftCoverage` — the sibling import in the SAME file — and
    /// none hedged `Danger`, the dominant one, which was absent from the ledger entirely. The within-file
    /// control is what makes it unarguable.
    func testAPackageNamedAfterItsDependencyDoesNotSilenceIt() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-seed-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Runner"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // The package is NAMED Danger and merely wraps the real one; no target of that name exists.
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Danger",
            targets: [.executableTarget(name: "Runner")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import Danger
        import DangerSwiftCoverage
        func check() { Danger().warn("x"); Coverage.report() }
        check()
        """.write(to: root.appendingPathComponent("Sources/Runner/main.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertTrue(r.err.contains("DangerSwiftCoverage"),
                      "the sibling import is the control — if it is absent the fixture proves nothing: \(r.err)")
        XCTAssertTrue(r.err.contains("Danger ("),
                      "`Danger` is the PACKAGE's name, not a declared target — naming the package after "
                      + "the dependency it wraps must not silence that dependency: \(r.err)")
    }

    /// …and a HOISTED dependency array is not a declaration. `parsePackageTargets` collects `.target(…)`
    /// anywhere in the file, which is right for resolving a scan SCOPE (a stray one dedups harmlessly)
    /// and wrong for deciding module IDENTITY: `let coreDeps: [Target.Dependency] = [.target(name:
    /// "Core")]` reads as a second, path-less declaration, widening Core's claimed roots to the
    /// conventional `Sources/Core` even though the real target lives at `path: "Modules/Core"`. A real
    /// manifest declares each target once, so a `path:`-carrying declaration settles that name.
    func testAHoistedDependencyArrayIsNotASecondDeclaration() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-phantom-\(UUID().uuidString)")
        // A STALE `Sources/Core/` that is not the real target's source root.
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Core"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Modules/Core"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let coreDeps: [Target.Dependency] = [.target(name: "Core")]
        let package = Package(name: "P", targets: [
            .target(name: "Core", path: "Modules/Core"),
            .executableTarget(name: "App", dependencies: coreDeps),
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct Stale {}\n".write(to: root.appendingPathComponent("Sources/Core/Stale.swift"),
                                             atomically: true, encoding: .utf8)
        try "import Foundation\nimport Core\nfunc run() { Core.leak() }\nrun()\n"
            .write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        // Scan the Sources/ subtree only: the real Core is outside it and genuinely unanalyzed.
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("Sources").path,
                                             "--out", root.appendingPathComponent("r").path])
        XCTAssertTrue(r.err.contains("Core"),
                      "the stale `Sources/Core/` is not the declared target's source root — that lives at "
                      + "`Modules/Core` and was never scanned: \(r.err)")
    }

    /// ⟨2026-08-08, round 6⟩ **A PLUGIN IS NOT AN IMPORTABLE MODULE**, and forgetting that reintroduced
    /// round 3's defect three hours after it was fixed.
    ///
    /// `targetSourceDirs` was written to resolve a scan SCOPE, where a `.plugin` target is unreachable
    /// (plugins never appear in `dependencies:`), so it maps every non-test target to `Sources/<name>`.
    /// The hand-rolled parser deleted in `53a733e` knew about `Plugins/`; the shared function does not.
    /// So a path-less `.plugin(name: "Stripe")` beside a stale `Sources/Stripe/` claimed module Stripe
    /// and silenced a real SDK on both channels.
    ///
    /// The fix is on the SEMANTICS rather than the layout: app code cannot `import` a plugin, and this
    /// engine's discovery excludes `Plugins/` outright, so a plugin declaration can never legitimately
    /// account for an analyzed file. Teaching a second place about directory conventions is what put the
    /// knowledge in two places to begin with.
    func testAPluginDeclarationCannotClaimASourcesFolder() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func probe(_ extraTarget: String) throws -> String {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-plug-\(UUID().uuidString)")
            for d in ["Sources/App", "Sources/Stripe", "Plugins/Stripe"] {
                try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            defer { try? fm.removeItem(at: root) }
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "P", targets: [
                .executableTarget(name: "App"),
            \(extraTarget)
            ])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "public struct Stale {}\n".write(to: root.appendingPathComponent("Sources/Stripe/Shim.swift"),
                                                 atomically: true, encoding: .utf8)
            try "struct P {}\n".write(to: root.appendingPathComponent("Plugins/Stripe/plugin.swift"),
                                      atomically: true, encoding: .utf8)
            try "import Foundation\nimport Stripe\nfunc charge() { StripeClient().pay() }\ncharge()\n"
                .write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path]).err
        }
        XCTAssertTrue(try probe("").contains("Stripe"),
                      "control: with no declaration at all the SDK import must be disclosed")
        XCTAssertTrue(try probe("    .plugin(name: \"Stripe\", capability: .buildTool()),").contains("Stripe"),
                      "a plugin is not importable and its sources are excluded from discovery — it can "
                      + "never account for an analyzed file, so it must not claim `Sources/Stripe`")
    }

    /// …and the same commit's other regression, in the safe direction: `Source/` (singular) is one of
    /// SwiftPM's predefined source directories, and the shared resolver did not know it — so an ANALYZED
    /// local module was named a third-party blind spot. A false disclosure, which is the noise this
    /// whole thread began by trying to remove.
    func testTheSingularSourceLayoutIsNotABlindSpot() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-srcsing-\(UUID().uuidString)")
        for d in ["Source/Core", "Source/App"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "Core"), .executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\npublic func leak() { _ = FileManager.default.contents(atPath: \"/x\") }\n"
            .write(to: root.appendingPathComponent("Source/Core/C.swift"), atomically: true, encoding: .utf8)
        try "import Core\nfunc run() { leak() }\nrun()\n"
            .write(to: root.appendingPathComponent("Source/App/main.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertFalse(r.err.contains("Core ("),
                       "`Core` is a declared target whose sources were analyzed under `Source/`: \(r.err)")
    }

    /// ⟨2026-08-08, round 7⟩ **A DEAD REFERENCE IS NOT A DECLARATION.** SwiftPM never validates an
    /// unused `let`, so a leftover `let legacyDeps: [Target.Dependency] = [.target(name: "Analytics")]`
    /// sits in a manifest that builds perfectly. Read as a declaration, and given a source root by a
    /// stale `Sources/Analytics/`, it claimed module Analytics — and a function calling into the real
    /// remote SDK vanished from `functions` with no ledger entry and no `invisible` hedge.
    ///
    /// One dead line, both disclosure channels off. The A/B is the whole test: the two trees differ by
    /// that line alone.
    ///
    /// Identity now asks a stricter question than scope resolution does —
    /// `parsePackageTargetDeclarations` returns only the elements of `Package(targets: [...])`. The
    /// permissive collect-anywhere read stays correct for `--target`, where a stray reference either
    /// names a real target (dedups) or resolves to no sources.
    func testADeadTargetReferenceIsNotADeclaration() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func probe(_ deadLine: String) throws -> String {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-dead-\(UUID().uuidString)")
            for d in ["Sources/App", "Sources/Analytics"] {
                try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            defer { try? fm.removeItem(at: root) }
            try """
            // swift-tools-version:5.9
            import PackageDescription
            \(deadLine)
            let package = Package(name: "P",
                dependencies: [.package(url: "https://x/analytics-swift", from: "1.0.0")],
                targets: [
                    .executableTarget(name: "App",
                        dependencies: [.product(name: "Analytics", package: "analytics-swift")]),
                ])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "public struct Leftover {}\n".write(to: root.appendingPathComponent("Sources/Analytics/Old.swift"),
                                                    atomically: true, encoding: .utf8)
            try "import Foundation\nimport Analytics\nfunc track() { AnalyticsClient().send() }\ntrack()\n"
                .write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path]).err
        }
        XCTAssertTrue(try probe("").contains("Analytics"),
                      "control: the remote SDK must be disclosed when nothing claims its name")
        XCTAssertTrue(try probe("let legacyDeps: [Target.Dependency] = [.target(name: \"Analytics\")]").contains("Analytics"),
                      "a dead hoisted reference is not a declaration — one unused `let` must not silence "
                      + "a real remote SDK on both channels")
    }

    /// …and the floor under that: a manifest whose `targets:` list is HOISTED or computed is "cannot be
    /// read", not "declares nothing". Identity claims nothing from it, which errs toward disclosure —
    /// the opposite of treating an unreadable list as an empty one.
    func testAnUnreadableTargetsListClaimsNothing() throws {
        XCTAssertNil(parsePackageTargetDeclarations(manifestSource: """
        // swift-tools-version:5.9
        import PackageDescription
        let allTargets: [Target] = [.target(name: "Core")]
        let package = Package(name: "P", targets: allTargets)
        """), "a non-literal `targets:` must be nil (unreadable), never an empty list")
        XCTAssertEqual(parsePackageTargetDeclarations(manifestSource: """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "Core")])
        """)?.map(\.name), ["Core"], "and a literal list reads exactly its elements")
    }

    /// ⟨2026-08-08, round 8⟩ **EVERY ELEMENT MUST *BE* A DECLARATION CALL.** Sub-walking each element of
    /// `Package(targets: [...])` found `.target(…)` anywhere inside it — so a ternary read BOTH branches
    /// as declarations, and the dead one claimed a module whose stale directory then silenced a real SDK.
    ///
    /// An element that is not a plain declaration call means the list cannot be READ, which is exactly
    /// what `packageManifestListsAreComplete` already said about the same array sixty lines away. The two
    /// now agree — and "cannot be read" claims nothing, which errs toward disclosure.
    func testATernaryElementsDeadBranchIsNotADeclaration() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-tern-\(UUID().uuidString)")
        for d in ["Sources/App", "Sources/Stripe"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let useMock = false
        let package = Package(name: "P", targets: [
            useMock ? .target(name: "Stripe") : .executableTarget(name: "App"),
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct Old {}\n".write(to: root.appendingPathComponent("Sources/Stripe/S.swift"),
                                           atomically: true, encoding: .utf8)
        try "import Foundation\nimport Stripe\nfunc charge() { StripeClient().pay() }\ncharge()\n"
            .write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertTrue(r.err.contains("Stripe"),
                      "the dead branch of a ternary is not a declaration — it must not claim a folder and "
                      + "silence a real SDK: \(r.err)")
    }

    /// …and the mirror, which the same round found INTRODUCED: `PackageDescription.Package(…)` and
    /// `Target.target(…)` are ordinary spellings, and rejecting them made a package's OWN analyzed
    /// modules read as third-party blind spots. Safe direction, but it is the false-disclosure noise this
    /// whole thread began by trying to remove.
    func testTheQualifiedPackageAndTargetSpellingsAreRead() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-qual-\(UUID().uuidString)")
        for d in ["Sources/Core", "Sources/App"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = PackageDescription.Package(name: "P", targets: [
            Target.target(name: "Core"),
            .executableTarget(name: "App", dependencies: ["Core"]),
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\npublic func leak() { _ = FileManager.default.contents(atPath: \"/x\") }\n"
            .write(to: root.appendingPathComponent("Sources/Core/C.swift"), atomically: true, encoding: .utf8)
        try "import Core\nfunc run() { leak() }\nrun()\n"
            .write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertFalse(r.err.contains("Core ("),
                       "`Core` is declared — via the qualified spellings — and analyzed: \(r.err)")
    }

    /// ⟨2026-08-08, round 9⟩ **MODULE IDENTITY IS PACKAGE-LOCAL; THIS CLAIM IS SCAN-GLOBAL.** Walking
    /// each analyzed file up through every ancestor manifest read names the shipped 0.26 engine could not
    /// see — it looked at the root `Package.swift` and nothing else — and on that new ground it produced
    /// a silent under-report: a nested mock package declaring `.target(name: "AcmePay")` made the ROOT
    /// package's `import AcmePay`, a real remote SDK, read pure on both channels. The root package
    /// declares no dependency on `./Mocks`, so its import cannot resolve there; name-plus-file-presence
    /// is not enough to bridge that.
    ///
    /// The derivation is now bounded to the root manifest, which restores a containment that is actually
    /// true rather than argued: every name claimed is a literal declaration in `rootDir/Package.swift`,
    /// and 0.26's regex over that same file matched all of those and more.
    func testANestedPackagesTargetDoesNotClaimTheRootsImport() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func probe(withMock: Bool) throws -> String {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-nest-\(UUID().uuidString)")
            try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "Root", targets: [.executableTarget(name: "App")])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "import Foundation\nimport AcmePay\nfunc checkout() { AcmePayClient().charge(1) }\ncheckout()\n"
                .write(to: root.appendingPathComponent("Sources/App/AppMain.swift"), atomically: true, encoding: .utf8)
            if withMock {
                try fm.createDirectory(at: root.appendingPathComponent("Mocks/Sources/AcmePay"),
                                       withIntermediateDirectories: true)
                try """
                // swift-tools-version:5.9
                import PackageDescription
                let package = Package(name: "Mocks", targets: [.target(name: "AcmePay")])
                """.write(to: root.appendingPathComponent("Mocks/Package.swift"), atomically: true, encoding: .utf8)
                try "public struct Unrelated {}\n"
                    .write(to: root.appendingPathComponent("Mocks/Sources/AcmePay/Mock.swift"),
                           atomically: true, encoding: .utf8)
            }
            return try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path]).err
        }
        XCTAssertTrue(try probe(withMock: false).contains("AcmePay"),
                      "baseline: the remote SDK is disclosed when nothing shadows its name")
        XCTAssertTrue(try probe(withMock: true).contains("AcmePay"),
                      "a NESTED package's target of the same name is a different module the root cannot "
                      + "import — it must not silence the root's dependency on the real one")
    }

    /// ⟨0.28 rung⟩ **A LOCAL DEPENDENCY IS ONLY INTERNAL IF THIS RUN READ IT.** The rung's whole idea is
    /// that a file's package can import its local `.package(path:)` dependencies — but "can import" is
    /// not "was analyzed", and conflating them silences a call into code the run never opened.
    ///
    /// This is the conjunct my own nine-round fixture battery could not see, because every fixture in it
    /// had the module either analyzed or undeclared — never declared-and-absent. The EXISTING workspace
    /// tests caught it.
    func testADeclaredButUnscannedLocalDependencyStaysBlind() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-unscanned-\(UUID().uuidString)")
        // The dependency exists on disk, one level OUTSIDE the scan target.
        try fm.createDirectory(at: root.appendingPathComponent("App/Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Dep/Sources/DepLib"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App",
            dependencies: [.package(path: "../Dep")],
            targets: [.executableTarget(name: "App", dependencies: [.product(name: "DepLib", package: "Dep")])])
        """.write(to: root.appendingPathComponent("App/Package.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Dep",
            products: [.library(name: "DepLib", targets: ["DepLib"])],
            targets: [.target(name: "DepLib")])
        """.write(to: root.appendingPathComponent("Dep/Package.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\npublic func leak() { _ = FileManager.default.contents(atPath: \"/x\") }\n"
            .write(to: root.appendingPathComponent("Dep/Sources/DepLib/D.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\nimport DepLib\nfunc use() { leak() }\nuse()\n"
            .write(to: root.appendingPathComponent("App/Sources/App/main.swift"), atomically: true, encoding: .utf8)
        // Scan ONLY the App package: DepLib is importable by declaration but was never read.
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("App").path,
                                             "--out", root.appendingPathComponent("r").path])
        XCTAssertTrue(r.err.contains("DepLib"),
                      "declared is not analyzed — a local dependency outside the scan must stay blind, or "
                      + "a call into code this run never opened reads pure: \(r.err)")
    }

    /// ⟨0.28 rung, review 1⟩ **A PACKAGE EXPOSES ITS PRODUCTS, NOT ITS TARGETS.** The rung lets a file
    /// import what its package's local dependencies expose — and "expose" is the products list. A target
    /// left out of every product cannot be imported from outside the package at all.
    ///
    /// The two sets were one function for an hour: `importable` began with every declared target (right
    /// for a file INSIDE the package) and the dependency recursion unioned that whole set into the
    /// parent. So a dependency's INTERNAL target silenced the parent's import of a same-named remote
    /// module — the branch's own motivating sin, one declared `.package(path:)` edge deeper, and the
    /// more common real arrangement: a mocks package you consume for its mock product, whose internal
    /// targets are named after the SDKs they stand in for.
    func testADependencysInternalTargetIsNotImportableByItsParent() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func probe(internalTargetNamed name: String) throws -> String {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-exposed-\(UUID().uuidString)")
            for d in ["Sources/App", "Mocks/Sources/MockKit", "Mocks/Sources/\(name)"] {
                try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            defer { try? fm.removeItem(at: root) }
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "App",
                dependencies: [.package(path: "Mocks")],
                targets: [.executableTarget(name: "App",
                    dependencies: [.product(name: "MockKit", package: "Mocks")])])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "Mocks",
                products: [.library(name: "MockKit", targets: ["MockKit"])],
                targets: [.target(name: "MockKit"), .target(name: "\(name)")])
            """.write(to: root.appendingPathComponent("Mocks/Package.swift"), atomically: true, encoding: .utf8)
            try "public func m() {}\n".write(to: root.appendingPathComponent("Mocks/Sources/MockKit/M.swift"),
                                             atomically: true, encoding: .utf8)
            try "public func stub() {}\n".write(to: root.appendingPathComponent("Mocks/Sources/\(name)/S.swift"),
                                                atomically: true, encoding: .utf8)
            try "import Foundation\nimport AcmePay\nfunc ship(_ s: String) { acmeUpload(s) }\nship(\"x\")\n"
                .write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path]).err
        }
        // Control first — with no name collision the remote SDK is disclosed, so the fixture binds.
        XCTAssertTrue(try probe(internalTargetNamed: "PayMock").contains("AcmePay"),
                      "control: the remote SDK must be disclosed when nothing shadows it")
        XCTAssertTrue(try probe(internalTargetNamed: "AcmePay").contains("AcmePay"),
                      "`AcmePay` is an INTERNAL target of the dependency, in no product — the parent "
                      + "cannot import it, so it must not silence the parent's real remote SDK")
    }

    /// ⟨0.28 rung, review 2⟩ **"ANALYZED" IS A FACT ABOUT A PACKAGE, NOT ABOUT A NAME.** The conjunct
    /// gating every claim was a scan-wide set of bare target names, so "did this run read X" was
    /// answered against ANY package's same-named target rather than the one the file's dependency graph
    /// resolves X to.
    ///
    /// Tenth instance of the pattern every defect in this derivation has been: two questions sharing one
    /// answer. `importable` asks per dependency graph; `analyzedModules` answered per name.
    func testAnUnrelatedPackagesTargetNameDoesNotCertifyADependency() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func probe(unrelatedTargetNamed name: String) throws -> String {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-amcol-\(UUID().uuidString)")
            for d in ["app/Sources/App", "app/Unrelated/Sources/\(name)", "LibA/Sources/Core"] {
                try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            defer { try? fm.removeItem(at: root) }
            // The scan root is `app/`; LibA sits OUTSIDE it and is never read.
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "App",
                dependencies: [.package(path: "../LibA")],
                targets: [.executableTarget(name: "App",
                    dependencies: [.product(name: "Core", package: "LibA")])])
            """.write(to: root.appendingPathComponent("app/Package.swift"), atomically: true, encoding: .utf8)
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "LibA",
                products: [.library(name: "Core", targets: ["Core"])],
                targets: [.target(name: "Core")])
            """.write(to: root.appendingPathComponent("LibA/Package.swift"), atomically: true, encoding: .utf8)
            try "import Foundation\npublic struct CoreClient { public init() {}\n  public func send() { _ = URLSession.shared } }\n"
                .write(to: root.appendingPathComponent("LibA/Sources/Core/C.swift"), atomically: true, encoding: .utf8)
            // An unrelated package INSIDE the scan, which the app does not depend on.
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "Unrelated", targets: [.target(name: "\(name)")])
            """.write(to: root.appendingPathComponent("app/Unrelated/Package.swift"), atomically: true, encoding: .utf8)
            try "public func helper() {}\n"
                .write(to: root.appendingPathComponent("app/Unrelated/Sources/\(name)/U.swift"),
                       atomically: true, encoding: .utf8)
            try "import Foundation\nimport Core\nfunc ship() { CoreClient().send() }\nship()\n"
                .write(to: root.appendingPathComponent("app/Sources/App/main.swift"), atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                                "--out", root.appendingPathComponent("r").path]).err
        }
        XCTAssertTrue(try probe(unrelatedTargetNamed: "Helpers").contains("Core"),
                      "control: LibA's Core was never read, so it must be disclosed")
        XCTAssertTrue(try probe(unrelatedTargetNamed: "Core").contains("Core"),
                      "an UNRELATED package's analyzed target that happens to share the name must not "
                      + "certify a dependency this run never opened")
    }

    /// ⟨0.28 rung, review 2 follow-on⟩ **A DEAD `.library(…)` IS NOT AN EXPOSURE.** `exposed(by:)` was
    /// built on `parsePackageProducts`, the collect-anywhere SCOPE parser — so a `.library(…)` sitting in
    /// a hoisted `let` that nothing references (SwiftPM never validates an unused one) read as a real
    /// product, and the package claimed to expose a module it does not publish.
    ///
    /// The codebase learned this exact distinction for TARGETS and did not carry it to products. This is
    /// that gap closed rather than rediscovered by a later review.
    func testADeadProductDeclarationIsNotAnExposure() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-deadprod-\(UUID().uuidString)")
        for d in ["Sources/App", "Mocks/Sources/AcmePay"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App",
            dependencies: [.package(path: "Mocks")],
            targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // `dead` is referenced by nothing; `products:` is empty. The package exposes NOTHING.
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let dead = [Product.library(name: "AcmePay", targets: ["AcmePay"])]
        let package = Package(name: "Mocks",
            products: [],
            targets: [.target(name: "AcmePay")])
        """.write(to: root.appendingPathComponent("Mocks/Package.swift"), atomically: true, encoding: .utf8)
        try "public func stub() {}\n".write(to: root.appendingPathComponent("Mocks/Sources/AcmePay/S.swift"),
                                            atomically: true, encoding: .utf8)
        try "import Foundation\nimport AcmePay\nfunc ship() { acmeUpload() }\nship()\n"
            .write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertTrue(r.err.contains("AcmePay"),
                      "the dependency's `products:` is empty — a dead hoisted `.library(…)` must not "
                      + "make it expose a module, and so must not silence the real remote one: \(r.err)")
    }
}
