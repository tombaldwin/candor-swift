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
}
