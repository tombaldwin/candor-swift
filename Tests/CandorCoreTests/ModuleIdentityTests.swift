import XCTest
import SwiftParser
import SwiftSyntax
@testable import CandorCore

/// SOUNDNESS R1938 (type-identity lane L1) — module identity. `ModuleIdentityIndex` and the MemberImportVisibility manifest read are
/// infrastructure for the type-identity lanes; nothing the engine reports depends on them yet (see `IdentityProbeProcessTests` for
/// the probe that is their only caller and for the byte-equality of reports with it on).
final class ModuleIdentityTests: XCTestCase {

    private func index(files: [String: (module: String?, imports: [String], exports: [String])],
                       depReexports: [String: Set<String>] = [:], miv: [String: MemberImportVisibilitySetting] = [:]) -> ModuleIdentityIndex {
        var m: [String: String] = [:], i: [String: [String]] = [:], e: [String: Set<String>] = [:]
        for (f, v) in files { if let mod = v.module { m[f] = mod }; i[f] = v.imports; e[f] = Set(v.exports) }
        return ModuleIdentityIndex(moduleOfFile: m, importsByFile: i, exportedByFile: e, dependencyReexports: depReexports, memberImportVisibility: miv)
    }

    /// An `@_exported import X` in ANY file of a module makes X visible in EVERY file of it (swift-http-types' `HTTPTypesFoundation`).
    func testExportedImportIsModuleWide() {
        let ix = index(files: ["a.swift": ("M", ["Foundation"], []), "b.swift": ("M", [], ["Y"]), "c.swift": ("N", [], [])])
        XCTAssertEqual(ix.visibleModules(inFile: "a.swift"), ["M", "Foundation", "Y"], "a.swift imports no Y; b.swift's @_exported makes it visible")
        XCTAssertEqual(ix.visibleModules(inFile: "b.swift"), ["M", "Y"])
        XCTAssertEqual(ix.visibleModules(inFile: "c.swift"), ["N"], "another module sees none of it")
        XCTAssertEqual(ix.exportedClosure(ofModule: "M"), ["Y"])
    }

    /// The closure follows `@_exported` through OWN targets (by their files) and DEPENDENCY modules (`dependencyReexports`), and ends on a cycle.
    func testClosureFollowsOwnTargetsAndDependencies() {
        let ix = index(files: ["m.swift": ("M", ["N"], []), "n.swift": ("N", [], ["D"])], depReexports: ["D": ["E"], "E": ["D", "F"]])
        XCTAssertEqual(ix.visibleModules(inFile: "m.swift"), ["M", "N", "D", "E", "F"], "N re-exports D (own file), D re-exports E, E re-exports D and F")
        XCTAssertEqual(ix.exportedClosure(ofModule: "N"), ["D", "E", "F"])
        XCTAssertEqual(ix.exportedClosure(ofModule: "M"), [])
    }

    /// `targetVisibleModules` is the union over the module's files — the set an EXTENSION member is looked up in without
    /// MemberImportVisibility, so the one file that imports the extending module opens it to the whole target.
    func testTargetVisibleIsTheUnionOverFiles() {
        let ix = index(files: ["a.swift": ("M", ["Base", "ExtX"], []), "b.swift": ("M", [], [])])
        XCTAssertEqual(ix.visibleModules(inFile: "b.swift"), ["M"])
        XCTAssertEqual(ix.targetVisibleModules(ofModule: "M"), ["M", "Base", "ExtX"])
    }

    /// A file no manifest or Xcode target claims is UNATTRIBUTED: no module, no module-wide exports, an `unreadable` setting.
    func testUnattributedFileClaimsNothing() {
        let ix = index(files: ["g.swift": (nil, ["Foundation", "X"], []), "m.swift": ("M", [], ["Y"])], miv: ["M": .enabled])
        XCTAssertNil(ix.moduleOf("g.swift"))
        XCTAssertEqual(ix.visibleModules(inFile: "g.swift"), ["Foundation", "X"])
        XCTAssertEqual(ix.memberImportVisibility(ofFile: "g.swift"), .unreadable)
        XCTAssertEqual(ix.memberLookupModules(inFile: "g.swift"), ["Foundation", "X"])
        XCTAssertEqual(ix.ownModules, ["M"])
    }

    /// The member-lookup set: the FILE's own set under MemberImportVisibility, the target-wide set otherwise — and `unreadable` takes the
    /// wider answer, because a lookup that errs wide is a disclosure and one that errs narrow drops a charge.
    func testMemberLookupHonoursTheSetting() {
        for (setting, narrow) in [(MemberImportVisibilitySetting.enabled, true), (.disabled, false), (.unreadable, false)] {
            let ix = index(files: ["a.swift": ("M", ["Base", "ExtX"], []), "b.swift": ("M", ["Base"], [])], miv: ["M": setting])
            XCTAssertEqual(ix.memberLookupModules(inFile: "b.swift"), narrow ? ["M", "Base"] : ["M", "Base", "ExtX"], "\(setting)")
        }
    }

    // MARK: the manifest read

    private func miv(_ manifest: String) -> [String: MemberImportVisibilitySetting] { parsePackageMemberImportVisibility(manifestSource: manifest) }

    func testManifestSpellingsOfTheSetting() {
        let m = miv("""
        // swift-tools-version:5.9
        import PackageDescription
        let shared: [SwiftSetting] = [.enableUpcomingFeature("MemberImportVisibility")]
        let package = Package(name: "P", targets: [
          .target(name: "On", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
          .target(name: "OnExp", swiftSettings: [.enableExperimentalFeature("MemberImportVisibility")]),
          .target(name: "Flags", swiftSettings: [.unsafeFlags(["-enable-upcoming-feature", "MemberImportVisibility"])]),
          .target(name: "Other", swiftSettings: [.enableUpcomingFeature("ExistentialAny"), .define("X")]),
          .target(name: "None"),
          .executableTarget(name: "ViaLet", swiftSettings: shared),
          .target(name: "ViaConcat", swiftSettings: shared + [.define("Y")]),
          .target(name: "Helper", swiftSettings: makeSettings()),
          .target(name: "Unknown", swiftSettings: missing),
          .testTarget(name: "T", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
          .target(name: "Qual", swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
          .target(name: "Cond", swiftSettings: [
            .define("A"),
            ]),
        ])
        """)
        XCTAssertEqual(m["On"], .enabled); XCTAssertEqual(m["OnExp"], .enabled); XCTAssertEqual(m["Flags"], .enabled)
        XCTAssertEqual(m["Other"], .disabled, "another upcoming feature is not this one"); XCTAssertEqual(m["None"], .disabled)
        XCTAssertEqual(m["ViaLet"], .enabled, "a swiftSettings naming a manifest `let` is followed"); XCTAssertEqual(m["ViaConcat"], .enabled)
        XCTAssertEqual(m["Helper"], .unreadable, "a helper call cannot be read — unreadable is not off")
        XCTAssertEqual(m["Unknown"], .unreadable)
        XCTAssertEqual(m["T"], .enabled); XCTAssertEqual(m["Cond"], .disabled)
    }

    /// An `#if` arm inside the settings list: the condition is not an expression to resolve, and a feature in either arm counts.
    func testManifestIfConfigInsideTheSettings() {
        let m = miv("""
        import PackageDescription
        let package = Package(name: "P", targets: [
          .target(name: "A", swiftSettings: [
            .define("X"),
            #if os(Linux)
            .enableUpcomingFeature("MemberImportVisibility"),
            #endif
          ]),
          .target(name: "B", swiftSettings: [
            #if os(Linux)
            .define("L"),
            #endif
          ]),
        ])
        """)
        XCTAssertEqual(m["A"], .enabled); XCTAssertEqual(m["B"], .disabled, "`os(Linux)` is a condition, not an unresolved name")
    }

    /// The tree-taking re-export reader is the one the source-taking one now delegates to: every spelling R837 pinned still reads.
    func testReexportedModulesInTree() {
        let src = """
        @_exported import A
        @preconcurrency @_exported import struct B.T
        @_exported
        import C
        #if os(Linux)
        @_exported import D
        #endif
        import E
        """
        XCTAssertEqual(reexportedModules(in: Parser.parse(source: src)), ["A", "B", "C", "D"])
        XCTAssertEqual(reexportedModules(source: src), reexportedModules(in: Parser.parse(source: src)))
    }
}
