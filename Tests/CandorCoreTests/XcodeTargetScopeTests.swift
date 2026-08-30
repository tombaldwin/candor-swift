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
        // ⟨file-set⟩ THE PATHS, not just the count: main.swift's `excluded[]` disclosure (SPEC §2 ⟨0.29⟩)
        // needs to name WHICH files, and a count alone cannot be turned back into a file list without a
        // second derivation the caller has no way to keep in sync with this one.
        XCTAssertEqual(scope.platformExcludedFiles.count, 2)
        XCTAssertTrue(scope.platformExcludedFiles.allSatisfy { ($0 as NSString).lastPathComponent == "MacOnly.swift" },
                      "every path this reports must be one of the files actually dropped: \(scope.platformExcludedFiles)")
    }

    /// ⟨guard-deletion sweep⟩ THE READABILITY GUARD in the SAME platform-pruning filter ("Cheap gate
    /// first: no `#if os(` in the text, nothing to evaluate. An unreadable file is KEPT — the scan will
    /// name its failure itself; pruning must never eat one silently"). A file this resolver cannot READ
    /// at all must stay a MEMBER of the target's scope — `swiftFileCompilesToNothing` needs the text to
    /// prove a file dead, and a file it never read cannot be proven dead — so a real effect inside it
    /// (behind `#if os(macOS)`, on the iOS-only target below) is never silently pruned as platform-dead;
    /// whatever downstream step actually tries to read the file is what must disclose the failure.
    ///
    /// Falsified against main.swift's SwiftPM sibling of this exact guard (`PackageTargets.swift`'s
    /// `--target` platform-pruning filter carries the identical "cheap gate" shape) and against a
    /// deliberately neutered copy of THIS guard (folding "cannot read" into "provably dead" — `return
    /// false` instead of `return true`): both passed the ENTIRE 954/955-test suite unmodified, because
    /// no test anywhere constructs an unreadable Swift source file on either path.
    func testAnUnreadableFileIsKeptNotPrunedAsPlatformDead() throws {
        let withPlatform = withPackages.replacingOccurrences(
            of: "TAPP = {",
            with: """
            XCAPP = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = iphoneos; }; name = Release; };
                        CLAPP = { isa = XCConfigurationList; buildConfigurations = ( XCAPP ); };
                        TAPP = {
                            buildConfigurationList = CLAPP;
            """)
        let scope = try xcodeTargetScope(model: model(withPlatform), projectDir: "/repo",
                                         targetName: "App", fs: XcodeScopeFS(
            swiftFilesUnder: { dir in ["\(dir)/Unreadable.swift"] },
            readFile: { path in
                if path.hasSuffix("/Package.swift") {
                    let dir = String(path.dropLast("/Package.swift".count))
                    return ["/repo/Packages/Kit": self.kitManifest, "/repo/Packages/Base": self.baseManifest][dir]
                }
                if path.hasSuffix("/Unreadable.swift") { return nil }   // simulates a permissions failure
                return nil
            },
            subdirectories: { _ in [] },
            directoryExists: { _ in true }))
        XCTAssertEqual(scope.platform, "iOS")
        XCTAssertEqual(scope.platformExcludedCount, 0,
                       "a file this resolver never read cannot be proven to compile to nothing")
        XCTAssertTrue(scope.platformExcludedFiles.isEmpty)
        XCTAssertTrue(scope.files.contains { ($0 as NSString).lastPathComponent == "Unreadable.swift" },
                      "an unreadable file must stay a member of the scope, not vanish as platform-dead: \(scope.files)")
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
        XCTAssertTrue(scope.platformExcludedFiles.isEmpty)
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
        // `dependencies: ["Kit"]` is not decoration: without it `import Kit` does not compile, and since
        // module identity became per TARGET rather than per package, a tree that cannot build is not
        // evidence about one that can. The property under test — a declared, analyzed target must not be
        // named a blind spot — is unchanged.
        let package = Package(name: "App",
            targets: [.executableTarget(name: "App", dependencies: ["Kit"]), .target(name: "Kit")])
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

    /// **…AND THE TEST ABOVE CANNOT SEE THE GUARD IT IS NAMED FOR.** Measured 2026-08-30: deleting
    /// `!t.isPlugin` from `Driver.swift`'s `targetsIn` — the whole fix — leaves
    /// `testAPluginDeclarationCannotClaimASourcesFolder` GREEN, and the full 958-test suite with it.
    ///
    /// The reason is worth more than the fix: in that fixture the disclosure is held up by a DIFFERENT
    /// conjunct. `importable(forTarget:in:)` walks the target's own `dependencies:` graph, and `App`
    /// declares none, so `Stripe` never enters `inPackage` and the `analyzed` filter — the half
    /// `!t.isPlugin` actually feeds — is never consulted about it. Two independent mechanisms produce one
    /// observable, and the arm under test is the one that was not running (AGENT-CORPUS-BRIEF §4).
    ///
    /// Make the plugin name reach the analyzed filter and the guard becomes the only thing left:
    /// `dependencies: ["Stripe"]` puts it in `inPackage`, and without `!t.isPlugin` the stale
    /// `Sources/Stripe/` counts as its source root, `Stripe` reads as analyzed-and-importable, and the
    /// real SDK import goes silent on both channels — round 3's cardinal sin, verbatim.
    ///
    /// SwiftPM itself would REJECT this manifest (a plugin is attached via `plugins:`, and
    /// `.plugin(name:)` in `dependencies:` is a different spelling this parser does not read as a name).
    /// That is the point rather than a caveat: candor never builds the package it scans, so it meets
    /// manifests the build system would refuse — and a stale `Sources/<X>/` beside a declaration that no
    /// longer compiles is exactly the state a half-finished migration leaves behind. A guard whose only
    /// job is to survive a manifest nobody can build must be tested on one.
    func testAPluginNamedInADependencyListStillCannotClaimASourcesFolder() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func probe(_ stripeTarget: String) throws -> String {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-plugdep-\(UUID().uuidString)")
            for d in ["Sources/App", "Sources/Stripe", "Plugins/Stripe"] {
                try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            defer { try? fm.removeItem(at: root) }
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "P", targets: [
                .executableTarget(name: "App", dependencies: ["Stripe"]),
            \(stripeTarget)
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
        // THE OVER-CHARGE CONTROL, first: a real `.target` of that name, whose sources this run DID read,
        // legitimately claims the module — so the disclosure must be ABSENT. Without this arm the
        // assertion below passes for a build that discloses everything unconditionally.
        XCTAssertFalse(try probe("    .target(name: \"Stripe\"),").contains("Stripe"),
                       "a genuine .target declaring Sources/Stripe, analyzed in this run, IS internal — "
                       + "disclosing it here would be the false-disclosure noise this thread began with")
        XCTAssertTrue(try probe("    .plugin(name: \"Stripe\", capability: .buildTool()),").contains("Stripe"),
                      "a .plugin declaration must not claim `Sources/Stripe` even when the app names it "
                      + "as a dependency — app code cannot import a plugin, so the real SDK behind "
                      + "`import Stripe` is still invisible and must still be disclosed")
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
        let package = Package(name: "P", targets: [.target(name: "Core"),
                                                   .executableTarget(name: "App", dependencies: ["Core"])])
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

    /// ⟨0.27 rung, review 2 follow-on⟩ **A DEAD `.library(…)` IS NOT AN EXPOSURE.** package exposure was
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

    // ── ⟨0.28 rung, review 3⟩ PER-TARGET LINK EVIDENCE ────────────────────────────────────────────
    //
    // WRITTEN BEFORE THE CODE, deliberately. The defect is that `localPackageDirs` is a flat union over
    // the closure, so a file in target T inherits a claim justified only by sibling target S's link. The
    // obvious narrowing reintroduces the blind-spot flood the whole rung exists to remove, so BOTH
    // directions are pinned here first and the implementation has to satisfy both at once.
    //
    // A two-target project: `App` (application) embeds `Ext` (framework). Only `Ext` links the local
    // package `Fork`, which exposes a target named `Shared`. `App` links nothing local.
    private let twoTargetProject = """
    {
        objects = {
            ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP, TEXT ); };
            G0 = { isa = PBXGroup; children = ( FAPP, FEXT, FFORK ); sourceTree = "<group>"; };
            FAPP = { isa = PBXFileReference; path = AppMain.swift; sourceTree = "<group>"; };
            FEXT = { isa = PBXFileReference; path = ExtMain.swift; sourceTree = "<group>"; };
            FFORK = { isa = PBXFileReference; lastKnownFileType = wrapper; path = Fork; sourceTree = "<group>"; };
            BAPP = { isa = PBXBuildFile; fileRef = FAPP; };
            BEXT = { isa = PBXBuildFile; fileRef = FEXT; };
            PSAPP = { isa = PBXSourcesBuildPhase; files = ( BAPP ); };
            PSEXT = { isa = PBXSourcesBuildPhase; files = ( BEXT ); };
            PDSHARED = { isa = XCSwiftPackageProductDependency; productName = Shared; };
            DEPEXT = { isa = PBXTargetDependency; target = TEXT; };
            TAPP = {
                isa = PBXNativeTarget;
                buildPhases = ( PSAPP );
                dependencies = ( DEPEXT );
                name = App;
                productType = "com.apple.product-type.application";
            };
            TEXT = {
                isa = PBXNativeTarget;
                buildPhases = ( PSEXT );
                name = Ext;
                packageProductDependencies = ( PDSHARED );
                productType = "com.apple.product-type.framework";
            };
        };
        rootObject = ROOT;
    }
    """
    private let forkManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "Fork",
        products: [.library(name: "Shared", targets: ["Shared"])],
        targets: [.target(name: "Shared")]
    )
    """

    /// THE SIN. `AppMain.swift` imports `Shared`. App links no local package — only its sibling `Ext`
    /// does — so in a real build App's `import Shared` resolves to something else entirely (a binary
    /// framework, a remote package, or nothing). Claiming it internal on Ext's evidence silences a module
    /// App may genuinely never have read.
    /// `localProductsByTarget` as "dir#product" strings, for readable assertions.
    private func links(_ scope: XcodeTargetScope, _ target: String) -> [String] {
        (scope.localProductsByTarget[target] ?? []).map { "\($0.packageDir)#\($0.product)" }
    }

    func testAFileDoesNotInheritASiblingTargetsPackageLink() throws {
        let scope = try xcodeTargetScope(model: model(twoTargetProject), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(
            swiftFilesUnder: { dir in ["\(dir)/S.swift"] },
            manifests: ["/repo/Fork": forkManifest]))
        // The closure DOES include Ext and its package — that is correct for a scan scope.
        XCTAssertTrue(scope.closure.map(\.name).contains("Ext"), "Ext is an embedded dependency of App")
        XCTAssertEqual(scope.localPackages, ["Fork"], "and Fork's sources are in the scan")
        // …but the LINK is Ext's, and per-target evidence must say so.
        XCTAssertEqual(links(scope, "Ext"), ["/repo/Fork#Shared"],
                       "Ext links Fork's `Shared` product")
        XCTAssertEqual(links(scope, "App"), [],
                       "App links NO local package — inheriting Ext's link is the cardinal sin this "
                       + "pins: a file in App importing `Shared` must stay disclosed")
        // And the file→target mapping the driver needs to use it.
        XCTAssertEqual(scope.filesByTarget["App"]?.contains("/repo/AppMain.swift"), true)
        XCTAssertEqual(scope.filesByTarget["Ext"]?.contains("/repo/ExtMain.swift"), true)
        XCTAssertNotEqual(scope.filesByTarget["App"]?.contains("/repo/ExtMain.swift"), true,
                          "App's sources phase does not compile Ext's file")
    }

    /// THE REACH FLOOR, and the reason this fixture is written beside the one above rather than after
    /// it. Narrowing the claim is easy; narrowing it until nothing is claimed reintroduces the
    /// blind-spot flood the rung exists to remove — NetNewsWire went back to 27 uncovered under the
    /// bounded version on main. A target that DOES link a local package must still claim what it exposes.
    func testATargetStillClaimsThePackagesItDoesLink() throws {
        let scope = try xcodeTargetScope(model: model(twoTargetProject), projectDir: "/repo",
                                         targetName: "Ext", fs: fsStub(
            swiftFilesUnder: { dir in ["\(dir)/S.swift"] },
            manifests: ["/repo/Fork": forkManifest]))
        XCTAssertEqual(links(scope, "Ext"), ["/repo/Fork#Shared"],
                       "scoping to Ext itself must still resolve the product it links")
        XCTAssertEqual(scope.localPackages, ["Fork"])
    }

    /// One target, linking ONE product of a local package that itself depends on a second local package.
    private let chainProject = """
    {
        objects = {
            ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP ); };
            G0 = { isa = PBXGroup; children = ( FAPP, FA, FB ); sourceTree = "<group>"; };
            FAPP = { isa = PBXFileReference; path = AppMain.swift; sourceTree = "<group>"; };
            FA = { isa = PBXFileReference; lastKnownFileType = wrapper; path = PkgA; sourceTree = "<group>"; };
            FB = { isa = PBXFileReference; lastKnownFileType = wrapper; path = PkgB; sourceTree = "<group>"; };
            BAPP = { isa = PBXBuildFile; fileRef = FAPP; };
            PSAPP = { isa = PBXSourcesBuildPhase; files = ( BAPP ); };
            PDA = { isa = XCSwiftPackageProductDependency; productName = A; };
            TAPP = { isa = PBXNativeTarget; buildPhases = ( PSAPP ); name = App;
                     packageProductDependencies = ( PDA );
                     productType = "com.apple.product-type.application"; };
        };
        rootObject = ROOT;
    }
    """
    private let pkgAManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "PkgA",
        products: [.library(name: "A", targets: ["A"])],
        dependencies: [.package(path: "../PkgB")],
        targets: [.target(name: "A", dependencies: [.product(name: "B", package: "PkgB")])]
    )
    """
    private let pkgBManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "PkgB",
        products: [.library(name: "B", targets: ["B"])],
        targets: [.target(name: "B")]
    )
    """

    /// **A DIRECT LINK IS NOT THE IMPORT PATH.** Xcode puts the whole package graph reachable from a
    /// linked product on the target's import path, and shipping code relies on it: NetNewsWire's share
    /// extension links `Account` and `RSCore` only, while `Shared/ShareExtension/ExtensionContainersFile`
    /// imports `RSParser` — in the graph because Account's manifest declares `.package(path: "../RSParser")`.
    ///
    /// This is the fixture for a measured regression in this rung's own first version, which recorded
    /// only the DIRECTLY linked dirs: three NetNewsWire targets then named `RSParser`, `Articles` and
    /// `CloudKitSync` blind spots in a run that had read all three. A false disclosure rather than a
    /// silence — but the rung's whole claim is that narrowing the union costs no reach, and that version
    /// cost some. The widening walks only edges `expand` already resolved, so it can restore reach and
    /// never invent it.
    func testATargetReachesThePackageGraphBehindWhatItLinks() throws {
        let scope = try xcodeTargetScope(model: model(chainProject), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(
            swiftFilesUnder: { dir in ["\(dir)/S.swift"] },
            manifests: ["/repo/PkgA": pkgAManifest, "/repo/PkgB": pkgBManifest]))
        XCTAssertEqual(links(scope, "App"), ["/repo/PkgA#A", "/repo/PkgB#B"],
                       "App links A only, but B is on its import path — recording direct links alone "
                       + "names an analyzed module a blind spot")
        XCTAssertEqual(scope.localPackages, ["PkgA", "PkgB"])
    }

    /// Two Xcode targets. App links `AProd` (whose target has NO dependencies); Ext links `BProd`
    /// (whose target pulls in a THIRD package, C). Only Ext should reach C.
    private let siblingGraphProject = """
    {
        objects = {
            ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP, TEXT ); };
            G0 = { isa = PBXGroup; children = ( FAPP, FEXT, FA, FB, FC ); sourceTree = "<group>"; };
            FAPP = { isa = PBXFileReference; path = AppMain.swift; sourceTree = "<group>"; };
            FEXT = { isa = PBXFileReference; path = ExtMain.swift; sourceTree = "<group>"; };
            FA = { isa = PBXFileReference; lastKnownFileType = wrapper; path = PkgA; sourceTree = "<group>"; };
            FB = { isa = PBXFileReference; lastKnownFileType = wrapper; path = PkgB; sourceTree = "<group>"; };
            FC = { isa = PBXFileReference; lastKnownFileType = wrapper; path = PkgC; sourceTree = "<group>"; };
            BAPP = { isa = PBXBuildFile; fileRef = FAPP; };
            BEXT = { isa = PBXBuildFile; fileRef = FEXT; };
            PSAPP = { isa = PBXSourcesBuildPhase; files = ( BAPP ); };
            PSEXT = { isa = PBXSourcesBuildPhase; files = ( BEXT ); };
            PDA = { isa = XCSwiftPackageProductDependency; productName = AProd; };
            PDB = { isa = XCSwiftPackageProductDependency; productName = BProd; };
            DEPEXT = { isa = PBXTargetDependency; target = TEXT; };
            TAPP = { isa = PBXNativeTarget; buildPhases = ( PSAPP ); dependencies = ( DEPEXT );
                     name = App; packageProductDependencies = ( PDA );
                     productType = "com.apple.product-type.application"; };
            TEXT = { isa = PBXNativeTarget; buildPhases = ( PSEXT ); name = Ext;
                     packageProductDependencies = ( PDB );
                     productType = "com.apple.product-type.framework"; };
        };
        rootObject = ROOT;
    }
    """
    /// A and B live in ONE package directory on purpose in the review's reproduction; here they are
    /// separate packages, which is the ordinary shape and still exhibits it once B reaches C.
    private let pkgAOnlyManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "PkgA",
        products: [.library(name: "AProd", targets: ["ATarget"])],
        targets: [.target(name: "ATarget")]
    )
    """
    /// ONE package vending BOTH products — `AProd` inert, `BProd` reaching PkgC.
    private let pkgTwoProductsManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "PkgA",
        products: [
            .library(name: "AProd", targets: ["ATarget"]),
            .library(name: "BProd", targets: ["BTarget"]),
        ],
        dependencies: [.package(path: "../PkgC")],
        targets: [
            .target(name: "ATarget"),
            .target(name: "BTarget", dependencies: [.product(name: "CProd", package: "PkgC")]),
        ]
    )
    """
    private let pkgBToCManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "PkgB",
        products: [.library(name: "BProd", targets: ["BTarget"])],
        dependencies: [.package(path: "../PkgC")],
        targets: [.target(name: "BTarget", dependencies: [.product(name: "CProd", package: "PkgC")])]
    )
    """
    private let pkgCManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "PkgC",
        products: [.library(name: "CProd", targets: ["CTarget"])],
        targets: [.target(name: "CTarget")]
    )
    """

    /// **THE WIDENING MUST FOLLOW THE PRODUCT, NOT THE PACKAGE.** Reported by review of the first
    /// per-target commit, and reproduced here before the fix: the transitive walk was keyed by package
    /// DIRECTORY, so a package accumulated the union of the edges of every one of its targets that any
    /// closure member had caused to expand — and each Xcode target linking that package then inherited
    /// the lot.
    ///
    /// Here App links `AProd`, whose target declares nothing. Ext links `BProd`, whose target reaches
    /// PkgC. Under directory-keyed edges App reached PkgC too, so an `import CTarget` in App resolved to
    /// a module App cannot see — the cardinal sin, one hop further out than the union answer this rung
    /// replaced, and invisible to the single-target graph fixture above because there "the graph behind
    /// what App links" and "the graph behind what the closure links" are the same set.
    func testOneTargetsProductGraphIsNotAnothersEvenInTheSamePackageTree() throws {
        let scope = try xcodeTargetScope(model: model(siblingGraphProject), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(
            swiftFilesUnder: { dir in ["\(dir)/S.swift"] },
            manifests: ["/repo/PkgA": pkgAOnlyManifest, "/repo/PkgB": pkgBToCManifest,
                        "/repo/PkgC": pkgCManifest]))
        XCTAssertEqual(links(scope, "App"), ["/repo/PkgA#AProd"],
                       "App links AProd, which declares no dependencies — PkgC is Ext's reach, not App's")
        XCTAssertEqual(links(scope, "Ext"), ["/repo/PkgB#BProd", "/repo/PkgC#CProd"],
                       "and Ext keeps the whole graph behind BProd")
        XCTAssertEqual(scope.localPackages, ["PkgA", "PkgB", "PkgC"],
                       "all three are still in the SCAN — scope is the closure's union, unchanged")
    }

    /// THE SAME PROPERTY WITH BOTH PRODUCTS IN ONE PACKAGE, which is where directory-keyed edges
    /// actually merge. Separate packages (above) never did — the reproduction needs `AProd` and `BProd`
    /// to be two libraries of the SAME manifest, one inert and one reaching PkgC. Then `pkgEdges[PkgA]`
    /// holds BTarget's edge and App, which links only AProd, inherits it.
    func testAProductsGraphDoesNotLeakToASiblingProductOfTheSamePackage() throws {
        let scope = try xcodeTargetScope(model: model(siblingGraphProject), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(
            swiftFilesUnder: { dir in ["\(dir)/S.swift"] },
            manifests: ["/repo/PkgA": pkgTwoProductsManifest, "/repo/PkgC": pkgCManifest]))
        XCTAssertEqual(links(scope, "App"), ["/repo/PkgA#AProd"],
                       "App links AProd, whose target declares nothing — PkgC is BProd's reach")
        XCTAssertEqual(links(scope, "Ext"), ["/repo/PkgA#BProd", "/repo/PkgC#CProd"],
                       "and Ext, which links BProd, keeps the whole graph behind it")
    }

    /// A pbxproj where ONE file sits in BOTH targets' Sources phases — "Target Membership" ticked
    /// twice, which is ordinary in a shipping project.
    private let sharedFileProject = """
    {
        objects = {
            ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP, TEXT ); };
            G0 = { isa = PBXGroup; children = ( FBOTH, FFORK ); sourceTree = "<group>"; };
            FBOTH = { isa = PBXFileReference; path = Both.swift; sourceTree = "<group>"; };
            FFORK = { isa = PBXFileReference; lastKnownFileType = wrapper; path = Fork; sourceTree = "<group>"; };
            BA = { isa = PBXBuildFile; fileRef = FBOTH; };
            BE = { isa = PBXBuildFile; fileRef = FBOTH; };
            PSAPP = { isa = PBXSourcesBuildPhase; files = ( BA ); };
            PSEXT = { isa = PBXSourcesBuildPhase; files = ( BE ); };
            PDSHARED = { isa = XCSwiftPackageProductDependency; productName = Shared; };
            DEPEXT = { isa = PBXTargetDependency; target = TEXT; };
            TAPP = { isa = PBXNativeTarget; buildPhases = ( PSAPP ); dependencies = ( DEPEXT );
                     name = App; productType = "com.apple.product-type.application"; };
            TEXT = { isa = PBXNativeTarget; buildPhases = ( PSEXT ); name = Ext;
                     packageProductDependencies = ( PDSHARED );
                     productType = "com.apple.product-type.framework"; };
        };
        rootObject = ROOT;
    }
    """

    /// THE MIRROR OF THE FIX, and it caught a defect in the fix's own first spelling. Per-target files
    /// were originally read off the SHARED set — each target credited with however much the set grew
    /// during its pass. That is right only while no two targets compile the same file. Here they do:
    /// the second target's pass sees no growth, so `Both.swift` keeps only App's (empty) link list, and
    /// its `import Shared` — which Ext genuinely links and this run genuinely reads — is named a blind
    /// spot. A false disclosure rather than a silence, so not the cardinal sin, but it gives back
    /// exactly the reach the rung is here to keep.
    func testAFileCompiledByTwoTargetsGetsBothTargetsLinks() throws {
        let scope = try xcodeTargetScope(model: model(sharedFileProject), projectDir: "/repo",
                                         targetName: "App", fs: fsStub(
            swiftFilesUnder: { dir in ["\(dir)/S.swift"] },
            manifests: ["/repo/Fork": forkManifest]))
        XCTAssertEqual(scope.filesByTarget["App"]?.contains("/repo/Both.swift"), true,
                       "App compiles it")
        XCTAssertEqual(scope.filesByTarget["Ext"]?.contains("/repo/Both.swift"), true,
                       "and so does Ext — a set-growth diff credits only whichever target ran first")
        XCTAssertEqual(links(scope, "Ext"), ["/repo/Fork#Shared"])
    }

    /// **THE SIBLING PRODUCT, AT HOP ZERO — and the reason a resolver fixture could not catch it.**
    ///
    /// `testAProductsGraphDoesNotLeakToASiblingProductOfTheSamePackage` above passes on the code that
    /// has this defect: the resolver\'s answer was right. The driver then looked up only the package
    /// DIRECTORY and asked for the PACKAGE\'s exposure, which is every product\'s member targets — so the
    /// product granularity survived the walk and was spent one line later.
    ///
    /// One package vends `AProd` and `BProd`. `App` links `AProd`, its sibling `Ext` links `BProd`.
    /// Four imports, one binary, one run each; the asymmetry is the whole point — each target claims
    /// its own product and discloses the other\'s.
    func testATargetDoesNotClaimTheSiblingProductOfAPackageItLinks() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-sibprod-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["P.xcodeproj", "PkgA/Sources/ATarget", "PkgA/Sources/BTarget"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try siblingProductProject.write(to: root.appendingPathComponent("P.xcodeproj/project.pbxproj"),
                                        atomically: true, encoding: .utf8)
        try pkgTwoLibrariesManifest.write(to: root.appendingPathComponent("PkgA/Package.swift"),
                                          atomically: true, encoding: .utf8)
        try "public func aThing() {}\n".write(to: root.appendingPathComponent("PkgA/Sources/ATarget/A.swift"),
                                              atomically: true, encoding: .utf8)
        try "public func bThing() {}\n".write(to: root.appendingPathComponent("PkgA/Sources/BTarget/B.swift"),
                                              atomically: true, encoding: .utf8)

        func uncovered(target: String, importing module: String, otherFile: String) throws -> [String] {
            try "import \(module)\nfunc entry_\(target)() { print(1) }\n"
                .write(to: root.appendingPathComponent(target == "App" ? "AppMain.swift" : "ExtMain.swift"),
                       atomically: true, encoding: .utf8)
            try "func filler_\(target)() {}\n"
                .write(to: root.appendingPathComponent(otherFile), atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(bin, [root.path, "--target", target, "--json"])
            let doc = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
            let cov = doc?["coverage"] as? [String: Any]
            return ((cov?["uncovered"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        }

        XCTAssertEqual(try uncovered(target: "App", importing: "BTarget", otherFile: "ExtMain.swift"),
                       ["BTarget"],
                       "App links AProd only. It cannot import BTarget, so that name is something else "
                       + "— a remote SDK, a system module — and must stay disclosed.")
        XCTAssertEqual(try uncovered(target: "App", importing: "ATarget", otherFile: "ExtMain.swift"), [],
                       "THE REACH FLOOR: App does link AProd, and ATarget is read in this very run.")
        XCTAssertEqual(try uncovered(target: "Ext", importing: "ATarget", otherFile: "AppMain.swift"),
                       ["ATarget"], "and the mirror — Ext links BProd, so ATarget is not its to claim")
        XCTAssertEqual(try uncovered(target: "Ext", importing: "BTarget", otherFile: "AppMain.swift"), [],
                       "while BTarget is")
    }

    /// **THE PROJECT FILE LISTING A SOURCE IS NOT THIS RUN HAVING READ IT.** Found by the 0.27 go/no-go
    /// panel, in the release's own least-reviewed commits.
    ///
    /// An Xcode target is a module, and a target that contributes no files cannot be one — so the module
    /// claim was guarded on `filesByTarget` being non-empty. But `filesByTarget` is what the PBXPROJ
    /// LISTS, and a group whose path escapes the scan root (`path = "../Shared"` — the shape
    /// `candorAbsolutePath` exists to support) lists files discovery never walks. The target was then
    /// claimed as an analyzed module on the strength of sources this run never opened.
    ///
    /// Measured on the built binary, one framework target whose only file sits outside the scan root:
    ///
    ///     target named `Shared`    functions: []                  ← purity claim over a URLSession upload
    ///     target named `SharedX`   appEntry, invisible: [Shared]  ← correct, and the ONLY difference
    ///
    /// The read-set check now lives in the driver, where the read set exists — the same guard the
    /// `LocalProductRef` channel always had, which is why that channel never showed this.
    func testAModuleIsOnlyClaimedWhenThisRunReadItsSources() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func run(targetNamed: String, scanFromRoot: Bool) throws -> (fns: [String], unc: [String]) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-outside-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            for d in ["repo/App.xcodeproj", "repo/App", "Shared"] {
                try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            try escapedTargetProject.replacingOccurrences(of: "name = Shared;",
                                                         with: "name = \(targetNamed);")
                .write(to: root.appendingPathComponent("repo/App.xcodeproj/project.pbxproj"),
                       atomically: true, encoding: .utf8)
            try "import Shared\nfunc appEntry() { ship() }\n"
                .write(to: root.appendingPathComponent("repo/App/main.swift"),
                       atomically: true, encoding: .utf8)
            try "import Foundation\npublic func ship() { _ = URLSession.shared.dataTask(with: URL(string: \"https://x.example\")!) }\n"
                .write(to: root.appendingPathComponent("Shared/Net.swift"), atomically: true, encoding: .utf8)
            // Scanning `repo/` leaves `Shared/` OUTSIDE the scan; scanning the parent takes it in.
            let target = scanFromRoot ? root.path : root.appendingPathComponent("repo").path
            let r = try ProcessHarness.run(bin, [target, "--json"])
            let doc = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
            let fns = ((doc?["functions"] as? [[String: Any]]) ?? []).compactMap { $0["fn"] as? String }
            let cov = (doc?["coverage"] as? [String: Any])?["uncovered"] as? [[String: Any]] ?? []
            return (fns, cov.compactMap { $0["name"] as? String })
        }
        let sin = try run(targetNamed: "Shared", scanFromRoot: false)
        XCTAssertTrue(sin.fns.contains("appEntry"),
                      "`Shared`'s sources are outside the scan, so `appEntry`'s call into it is "
                      + "unresolved — absence from `functions` is a purity claim over a network upload")
        XCTAssertEqual(sin.unc, ["Shared"], "and the ledger must name it")
        // THE CONTROL: identical tree, one target name different. If this ever stops disclosing, the
        // assertion above has stopped testing what it says.
        let control = try run(targetNamed: "SharedX", scanFromRoot: false)
        XCTAssertEqual(control.unc, ["Shared"])
        // THE REACH FLOOR: scanned from above, the run DOES read those sources, so the module is
        // claimed and the effect travels rather than being hedged.
        let floor = try run(targetNamed: "Shared", scanFromRoot: true)
        XCTAssertEqual(floor.unc, [], "read in this run — claiming it is correct")
        XCTAssertTrue(floor.fns.contains("ship"), "and its own function is in the report")
    }

    private let escapedTargetProject = """
    {
        objects = {
            ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP, TSH ); };
            G0 = { isa = PBXGroup; children = ( GAPP, GOUT ); sourceTree = "<group>"; };
            GAPP = { isa = PBXGroup; children = ( FMAIN ); path = App; sourceTree = "<group>"; };
            GOUT = { isa = PBXGroup; children = ( FNET ); path = "../Shared"; sourceTree = "<group>"; };
            FMAIN = { isa = PBXFileReference; path = main.swift; sourceTree = "<group>"; };
            FNET = { isa = PBXFileReference; path = Net.swift; sourceTree = "<group>"; };
            BMAIN = { isa = PBXBuildFile; fileRef = FMAIN; };
            BNET = { isa = PBXBuildFile; fileRef = FNET; };
            PSAPP = { isa = PBXSourcesBuildPhase; files = ( BMAIN ); };
            PSSH = { isa = PBXSourcesBuildPhase; files = ( BNET ); };
            DEP = { isa = PBXTargetDependency; target = TSH; };
            TAPP = { isa = PBXNativeTarget; buildPhases = ( PSAPP ); dependencies = ( DEP );
                     name = App; productType = "com.apple.product-type.application"; };
            TSH = { isa = PBXNativeTarget; buildPhases = ( PSSH ); name = Shared;
                    productType = "com.apple.product-type.framework"; };
        };
        rootObject = ROOT;
    }
    """

    /// **WHOLE-REPO IDENTITY, and it is still PER FILE.** Without `--target` an app-level file had no
    /// owning `Package.swift` and no resolved scope, so it claimed nothing and every module it imports
    /// was named a blind spot — including local packages this very run analyzed. NetNewsWire: 32
    /// uncovered modules, 14 of them local packages whose sources are in the same report.
    ///
    /// The fix resolves EVERY target and merges per file, and the fixture that matters is the one
    /// showing it did not become a repo-wide union: in a single unscoped run of one tree, `Ext` links
    /// Fork so its file CLAIMS `Shared`, while `App` links nothing so its file still DISCLOSES it. Same
    /// run, same module name, two answers, because they are two files with two targets.
    func testAWholeRepoScanAnswersPerFileNotPerRepo() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-whole-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["P.xcodeproj", "Fork/Sources/Shared"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try twoTargetProject.write(to: root.appendingPathComponent("P.xcodeproj/project.pbxproj"),
                                   atomically: true, encoding: .utf8)
        try forkManifest.write(to: root.appendingPathComponent("Fork/Package.swift"),
                               atomically: true, encoding: .utf8)
        try "import Foundation\npublic func sharedThing() { _ = FileManager.default.contents(atPath: \"/x\") }\n"
            .write(to: root.appendingPathComponent("Fork/Sources/Shared/S.swift"),
                   atomically: true, encoding: .utf8)
        // BOTH files import `Shared`. Only Ext links Fork.
        try "import Shared\nfunc appDoes() { sharedThing() }\n"
            .write(to: root.appendingPathComponent("AppMain.swift"), atomically: true, encoding: .utf8)
        try "import Shared\nfunc extDoes() { sharedThing() }\n"
            .write(to: root.appendingPathComponent("ExtMain.swift"), atomically: true, encoding: .utf8)

        let r = try ProcessHarness.run(bin, [root.path, "--json"])   // NO --target
        let doc = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        let cov = (doc?["coverage"] as? [String: Any])?["uncovered"] as? [[String: Any]] ?? []
        let shared = cov.first { ($0["name"] as? String) == "Shared" }

        // THE LEDGER COUNT IS THE OBSERVABLE, and it separates all three behaviours in one number.
        // Both files import `Shared`; only Ext links Fork.
        //
        //   2  no claims at all      — what shipped before this pass: every app-level import disclosed,
        //                              including the 14 NetNewsWire modules the run had analyzed
        //   0  a repo-wide union     — the one-line shortcut, and the cardinal sin: App's import
        //                              silenced on evidence that belongs to its sibling
        //   1  per FILE              — correct, and the only one of the three that is
        //
        // The per-function `invisible` hedge is deliberately NOT asserted here: both calls RESOLVE (the
        // package's source is in an unscoped scan either way), so neither function needs a hedge and an
        // assertion on it would pass for a reason unrelated to this pass.
        XCTAssertEqual(shared?["calls"] as? Int, 1,
                       "`Shared` must be disclosed EXACTLY once — App's import, not Ext's. 2 means the "
                       + "pass claimed nothing; 0 means it claimed repo-wide, which silences a module "
                       + "App cannot see. stderr: \(r.err)")
    }

    /// **A SIBLING TARGET IS NOT ON YOUR IMPORT PATH — the SwiftPM twin of the `.xcodeproj` defect that
    /// took three review rounds to close.** Module identity was decided per PACKAGE: a file could claim
    /// every target its package declares. SwiftPM lets a target import only what its own `dependencies:`
    /// name, so a package\'s other targets are not on its import path, and starting from all of them let
    /// a local stub silence the real SDK of the same name.
    ///
    /// Measured on the built binary. One package, `App` declaring NO dependencies beside a `.target`
    /// whose name is the only thing that changes between the two runs:
    ///
    ///     sibling named `Stripe`    functions: []                      ← `ship` absent = purity claim
    ///     sibling named `Payments`  ship, invisible: ["Stripe"]        ← correct
    ///
    /// It sat twelve lines from the `.xcodeproj` fixes through three review rounds, because every round
    /// was briefed on the arm that had just been changed.
    func testASiblingTargetTheFilesTargetDoesNotDependOnCannotSilenceIt() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        func run(sibling: String, appDependsOnIt: Bool) throws -> (unc: [String], fns: [String]) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-sib-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            for d in ["Sources/App", "Sources/\(sibling)"] {
                try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            let deps = appDependsOnIt ? ", dependencies: [\"\(sibling)\"]" : ""
            try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "Root", targets: [
                .executableTarget(name: "App"\(deps)),
                .target(name: "\(sibling)"),
            ])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "public func localStub() {}\n"
                .write(to: root.appendingPathComponent("Sources/\(sibling)/S.swift"),
                       atomically: true, encoding: .utf8)
            try "import Stripe\nfunc ship() { StripeClient().charge(amount: 100) }\nship()\n"
                .write(to: root.appendingPathComponent("Sources/App/main.swift"),
                       atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(bin, [root.path, "--json"])
            let doc = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
            let cov = doc?["coverage"] as? [String: Any]
            let fns = (doc?["functions"] as? [[String: Any]]) ?? []
            return (((cov?["uncovered"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String },
                    fns.compactMap { $0["fn"] as? String })
        }
        // THE SIN: App declares nothing, so `import Stripe` cannot be the sibling target.
        let sin = try run(sibling: "Stripe", appDependsOnIt: false)
        XCTAssertEqual(sin.unc, ["Stripe"],
                       "App declares no dependency on the `Stripe` target, so `import Stripe` is the "
                       + "remote SDK and must stay disclosed")
        XCTAssertTrue(sin.fns.contains("ship"),
                      "and `ship` must be IN the report — absence is a purity claim over an SDK call")
        // THE CONTROL: the same tree with the sibling renamed. If this ever stops disclosing, the
        // fixture above has stopped testing what it says.
        let control = try run(sibling: "Payments", appDependsOnIt: false)
        XCTAssertEqual(control.unc, ["Stripe"])
        // THE REACH FLOOR: when App DOES declare it, the name is claimed and nothing is disclosed.
        let floor = try run(sibling: "Stripe", appDependsOnIt: true)
        XCTAssertEqual(floor.unc, [], "a declared dependency IS on the import path")
    }

    /// **THE PBXPROJ\'S SPELLING IS NOT THE DISK\'S.** The membership filter matches case-INSENSITIVELY
    /// on purpose — a `PBXFileReference` whose case drifted from disk still builds in Xcode, and dropping
    /// that file would be the miss-shaped failure — while the driver looks up its link map with the path
    /// it walked off disk. Keying that map the resolver\'s way meant ONE CHARACTER of case reverted this
    /// entire rung for that file: in scope, no links, every module it imports named a blind spot.
    ///
    /// Measured on the built binary, two trees identical but for `path = AppMain.swift` vs
    /// `path = appmain.swift`. The fix joins the two spellings through the lowercased form, but only
    /// where that form picks out exactly one file on each side — on a case-sensitive volume `A.swift`
    /// and `a.swift` are two files, and letting them share a key would hand one the other\'s links,
    /// trading a false disclosure for a purity claim.
    func testAPbxprojPathWhoseCaseDriftedStillGetsItsTargetsLinks() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        for spelling in ["AppMain.swift", "appmain.swift"] {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-case-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            for d in ["P.xcodeproj", "Fork/Sources/Shared"] {
                try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            try twoTargetProject.replacingOccurrences(of: "path = AppMain.swift", with: "path = \(spelling)")
                .write(to: root.appendingPathComponent("P.xcodeproj/project.pbxproj"),
                       atomically: true, encoding: .utf8)
            try forkManifest.write(to: root.appendingPathComponent("Fork/Package.swift"),
                                   atomically: true, encoding: .utf8)
            try "public func sharedThing() {}\n"
                .write(to: root.appendingPathComponent("Fork/Sources/Shared/S.swift"),
                       atomically: true, encoding: .utf8)
            // The DISK always spells it `AppMain.swift`; only the project file drifts.
            try "func appDoes() {}\n".write(to: root.appendingPathComponent("AppMain.swift"),
                                            atomically: true, encoding: .utf8)
            try "import Shared\nfunc extDoes() { sharedThing() }\n"
                .write(to: root.appendingPathComponent("ExtMain.swift"), atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(bin, [root.path, "--target", "Ext", "--json"])
            let doc = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
            let cov = doc?["coverage"] as? [String: Any]
            let unc = ((cov?["uncovered"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            XCTAssertEqual(unc, [], "pbxproj spelling `\(spelling)`: Ext links Fork and `Shared` is read "
                           + "in this run, so it must not be named a blind spot. stderr: \(r.err)")
        }
    }

    /// **THE RESOLVER ASKED SwiftPM; THE CONSUMER RE-ASKED THE PARSER SwiftPM WAS CALLED FOR.** When the
    /// structural manifest read is provably partial the resolver runs `swift package dump-package`,
    /// repairs the product and target lists, and DISCLOSES that it did. That repaired answer used not to
    /// leave the resolver, so `exposed(product:in:)` re-parsed `Package.swift` — returning nil for
    /// exactly those manifests, exposing nothing, and naming every module of that package a blind spot.
    ///
    /// The two halves of the same stderr contradicted each other: "PkgA read via `swift package
    /// dump-package`" beside "ATarget — INVISIBLE to the scan". The membership now travels on
    /// `LocalProductRef`. Third instance in this branch of a consumer discarding a producer\'s answer.
    func testAProductWhoseManifestNeededSwiftPMStillExposesItsTargets() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        // Same tree twice; only the `products:` spelling differs. The literal arm is the control that
        // shows the fixture would notice if exposure broke for an unrelated reason.
        let manifests = [
            "literal": """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Fork",
                products: [.library(name: "Shared", targets: ["Shared"])],
                targets: [.target(name: "Shared")]
            )
            """,
            "programmatic": """
            // swift-tools-version: 6.0
            import PackageDescription
            func makeProducts() -> [Product] { [.library(name: "Shared", targets: ["Shared"])] }
            let package = Package(
                name: "Fork",
                products: makeProducts(),
                targets: [.target(name: "Shared")]
            )
            """,
        ]
        for (label, manifest) in manifests {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("candor-dump-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            for d in ["P.xcodeproj", "Fork/Sources/Shared"] {
                try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            try twoTargetProject.write(to: root.appendingPathComponent("P.xcodeproj/project.pbxproj"),
                                       atomically: true, encoding: .utf8)
            try manifest.write(to: root.appendingPathComponent("Fork/Package.swift"),
                               atomically: true, encoding: .utf8)
            try "public func sharedThing() {}\n"
                .write(to: root.appendingPathComponent("Fork/Sources/Shared/S.swift"),
                       atomically: true, encoding: .utf8)
            try "func appDoes() {}\n".write(to: root.appendingPathComponent("AppMain.swift"),
                                            atomically: true, encoding: .utf8)
            try "import Shared\nfunc extDoes() { sharedThing() }\n"
                .write(to: root.appendingPathComponent("ExtMain.swift"), atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(bin, [root.path, "--target", "Ext", "--json"])
            let doc = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
            let cov = doc?["coverage"] as? [String: Any]
            let unc = ((cov?["uncovered"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            XCTAssertEqual(unc, [], "\(label) manifest: `Shared` is read in this run either way. A scope "
                           + "note that says the package was read via SwiftPM cannot sit beside a ledger "
                           + "calling its module invisible. stderr: \(r.err)")
        }
    }

    /// Two `PBXNativeTarget`s of one name used to kill the process — `Dictionary(uniqueKeysWithValues:)`
    /// traps, exit 133 with a Swift runtime message. Loud, so never the cardinal sin, but the only
    /// outcome for that input and a dead end for whoever hit it. It also means every name-keyed map this
    /// resolver returns would be answering about an ambiguous key, which is why this refuses rather than
    /// picking a winner.
    func testTwoTargetsOfOneNameRefuseRatherThanTrap() throws {
        XCTAssertThrowsError(try xcodeTargetScope(model: model(duplicateNameProject), projectDir: "/repo",
                                                  targetName: "App",
                                                  fs: fsStub(swiftFilesUnder: { _ in [] }))) { err in
            XCTAssertTrue("\(err)".contains("two targets are named"), "got: \(err)")
        }
    }

    private let duplicateNameProject = """
    {
        objects = {
            ROOT = { isa = PBXProject; mainGroup = G0; targets = ( T1, T2 ); };
            G0 = { isa = PBXGroup; children = ( F1, F2 ); sourceTree = "<group>"; };
            F1 = { isa = PBXFileReference; path = One.swift; sourceTree = "<group>"; };
            F2 = { isa = PBXFileReference; path = Two.swift; sourceTree = "<group>"; };
            B1 = { isa = PBXBuildFile; fileRef = F1; };
            B2 = { isa = PBXBuildFile; fileRef = F2; };
            PS1 = { isa = PBXSourcesBuildPhase; files = ( B1 ); };
            PS2 = { isa = PBXSourcesBuildPhase; files = ( B2 ); };
            T1 = { isa = PBXNativeTarget; buildPhases = ( PS1 ); name = App;
                   productType = "com.apple.product-type.application"; };
            T2 = { isa = PBXNativeTarget; buildPhases = ( PS2 ); name = App;
                   productType = "com.apple.product-type.framework"; };
        };
        rootObject = ROOT;
    }
    """

    private let siblingProductProject = """
    {
        objects = {
            ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP, TEXT ); };
            G0 = { isa = PBXGroup; children = ( FAPP, FEXT, FA ); sourceTree = "<group>"; };
            FAPP = { isa = PBXFileReference; path = AppMain.swift; sourceTree = "<group>"; };
            FEXT = { isa = PBXFileReference; path = ExtMain.swift; sourceTree = "<group>"; };
            FA = { isa = PBXFileReference; lastKnownFileType = wrapper; path = PkgA; sourceTree = "<group>"; };
            BAPP = { isa = PBXBuildFile; fileRef = FAPP; };
            BEXT = { isa = PBXBuildFile; fileRef = FEXT; };
            PSAPP = { isa = PBXSourcesBuildPhase; files = ( BAPP ); };
            PSEXT = { isa = PBXSourcesBuildPhase; files = ( BEXT ); };
            PDA = { isa = XCSwiftPackageProductDependency; productName = AProd; };
            PDB = { isa = XCSwiftPackageProductDependency; productName = BProd; };
            DEPEXT = { isa = PBXTargetDependency; target = TEXT; };
            TAPP = { isa = PBXNativeTarget; buildPhases = ( PSAPP ); dependencies = ( DEPEXT );
                     name = App; packageProductDependencies = ( PDA );
                     productType = "com.apple.product-type.application"; };
            TEXT = { isa = PBXNativeTarget; buildPhases = ( PSEXT ); name = Ext;
                     packageProductDependencies = ( PDB );
                     productType = "com.apple.product-type.framework"; };
        };
        rootObject = ROOT;
    }
    """
    private let pkgTwoLibrariesManifest = """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "PkgA",
        products: [
            .library(name: "AProd", targets: ["ATarget"]),
            .library(name: "BProd", targets: ["BTarget"]),
        ],
        targets: [.target(name: "ATarget"), .target(name: "BTarget")]
    )
    """

    /// **A GROUP PATH THAT ESCAPES THE PROJECT DIRECTORY, under an ABSOLUTE scan root.** Reported by
    /// review, reproduced on the built binary, and silent on main too — a pre-existing sin this branch
    /// inherited rather than introduced.
    ///
    /// `std` was `URL(fileURLWithPath:).path`, which absolutizes a relative path correctly but leaves
    /// `..` sitting in an absolute one. The membership filter in `scopeToXcodeTarget` then compared
    /// those keys against discovery paths, which never contain `..`, so every file behind such a group
    /// fell out of the scoped scan — no `unanalyzed` entry, no warning, and the verdict flipping on
    /// whether the user wrote `candor-swift .` or `candor-swift /abs/path`. This is firefox-ios's real
    /// shape: its packages sit at `firefox-ios/../BrowserKit`.
    ///
    /// Both spellings of the root must now answer the same, which is what `candorAbsolutePath` is for.
    func testAGroupPathEscapingTheProjectDirSurvivesAnAbsoluteScanRoot() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-escaped-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Proj/Repo.xcodeproj"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Outside"), withIntermediateDirectories: true)
        try """
        {
            objects = {
                ROOT = { isa = PBXProject; mainGroup = G0; targets = ( TAPP ); };
                G0 = { isa = PBXGroup; children = ( FIN, GOUT ); sourceTree = "<group>"; };
                FIN = { isa = PBXFileReference; path = Inside.swift; sourceTree = "<group>"; };
                GOUT = { isa = PBXGroup; children = ( FOUT ); path = "../Outside"; sourceTree = "<group>"; };
                FOUT = { isa = PBXFileReference; path = Escaped.swift; sourceTree = "<group>"; };
                BIN = { isa = PBXBuildFile; fileRef = FIN; };
                BOUT = { isa = PBXBuildFile; fileRef = FOUT; };
                PS = { isa = PBXSourcesBuildPhase; files = ( BIN, BOUT ); };
                TAPP = { isa = PBXNativeTarget; buildPhases = ( PS ); name = App;
                         productType = "com.apple.product-type.application"; };
            };
            rootObject = ROOT;
        }
        """.write(to: root.appendingPathComponent("Proj/Repo.xcodeproj/project.pbxproj"),
                  atomically: true, encoding: .utf8)
        try "func inside() {}\n".write(to: root.appendingPathComponent("Proj/Inside.swift"),
                                       atomically: true, encoding: .utf8)
        try "import Foundation\nfunc escapedNetCall() { _ = URLSession.shared.dataTask(with: URL(string: \"https://x.example\")!) }\n"
            .write(to: root.appendingPathComponent("Outside/Escaped.swift"), atomically: true, encoding: .utf8)

        // Both spellings of the same tree, run from inside it.
        for (label, arg) in [("absolute", root.path), ("relative", ".")] {
            let r = try ProcessHarness.run(bin, [arg, "--target", "App", "--json"], cwd: root)
            let doc = try JSONSerialization.jsonObject(
                with: Data(r.out.utf8)) as? [String: Any]
            let fns = (doc?["functions"] as? [[String: Any]]) ?? []
            XCTAssertTrue(fns.contains { ($0["fn"] as? String) == "escapedNetCall" },
                          "\(label) root: `Escaped.swift` is in App\'s Sources phase, so its Net must be "
                          + "reported — dropping it is a purity claim over a file the project lists. "
                          + "stderr: \(r.err)")
            XCTAssertTrue(r.err.contains("2 of 2 source file(s)"),
                          "\(label) root: both files must survive the membership filter. stderr: \(r.err)")
        }
    }

    /// THE DRIVER HALF, on the built binary. The resolver fixtures above prove the per-target evidence
    /// is COMPUTED; they cannot prove the scan USES it — and the whole of the previous attempt's defect
    /// was in the consumer, which read the closure's union. Both directions, one tree:
    ///
    ///   `--target App`  App links nothing local → `AppMain`'s `import Shared` is UNCOVERED (disclosed)
    ///   `--target Ext`  Ext links Fork          → `ExtMain`'s `import Shared` is COVERED  (claimed)
    ///
    /// The same module name, the same repository, the same run of the same binary — only the target
    /// differs. Under the union answer the first case goes silent, which is a purity claim over a module
    /// this target cannot see.
    func testTheScanAsksWhatThisFilesTargetLinksNotWhatTheClosureLinks() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-pertarget-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("P.xcodeproj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Fork/Sources/Shared"),
                               withIntermediateDirectories: true)
        try twoTargetProject.write(to: root.appendingPathComponent("P.xcodeproj/project.pbxproj"),
                                   atomically: true, encoding: .utf8)
        try forkManifest.write(to: root.appendingPathComponent("Fork/Package.swift"),
                               atomically: true, encoding: .utf8)
        try "public func sharedThing() {}\n"
            .write(to: root.appendingPathComponent("Fork/Sources/Shared/S.swift"),
                   atomically: true, encoding: .utf8)
        try "import Shared\nfunc appDoes() { sharedThing() }\n"
            .write(to: root.appendingPathComponent("AppMain.swift"), atomically: true, encoding: .utf8)
        try "import Shared\nfunc extDoes() { sharedThing() }\n"
            .write(to: root.appendingPathComponent("ExtMain.swift"), atomically: true, encoding: .utf8)

        let app = try ProcessHarness.run(bin, [root.path, "--target", "App",
                                               "--out", root.appendingPathComponent("a").path])
        XCTAssertTrue(app.err.contains("Shared"),
                      "App links no local package, so its `import Shared` must stay DISCLOSED — "
                      + "inheriting Ext\'s link is the silent under-report. stderr: \(app.err)")
        let ext = try ProcessHarness.run(bin, [root.path, "--target", "Ext",
                                               "--out", root.appendingPathComponent("e").path])
        XCTAssertFalse(ext.err.contains("Shared"),
                       "THE REACH FLOOR: Ext does link Fork, so `Shared` is read in this very run and "
                       + "naming it a blind spot would be a false disclosure. stderr: \(ext.err)")
    }
}
