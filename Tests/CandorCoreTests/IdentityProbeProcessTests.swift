import XCTest
import Foundation

/// SOUNDNESS R1938 (lanes L0/L1) — the type-identity probe (`CANDOR_IDENT_PROBE`, stderr). Two properties:
///   1. OFF by default, and ON changes nothing a report carries: the report and its call-graph sidecar are byte-equal with the probe
///      on and off; only stderr differs.
///   2. The L1 module-identity records say what they should: the manifest answer against `swiftModuleOf`, the attribution gap with its
///      reason, the MemberImportVisibility setting, and the module-wide `@_exported` closure.
final class IdentityProbeProcessTests: XCTestCase {
    typealias H = TypeIdentityHarness

    private func records(_ err: String, _ kind: String) -> [[String]] {
        err.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }.filter { $0.first == kind }
    }

    private func scanFiles(_ st: H.Stage, _ pkg: String, env: [String: String]) throws -> (err: String, files: [String: Data]) {
        let tag = "p-\(UUID().uuidString)"
        let r = try ProcessHarness.run(st.bin, [st.dir(pkg).path, "--out", st.root.appendingPathComponent(tag).path], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        var out: [String: Data] = [:]
        for f in try FileManager.default.contentsOfDirectory(atPath: st.root.path) where f.hasPrefix(tag + ".") {
            out[String(f.dropFirst(tag.count))] = try Data(contentsOf: st.root.appendingPathComponent(f))
        }
        return (r.err, out)
    }

    func testProbeIsOffByDefaultAndChangesNoReportByte() throws {
        let st = try H.stage(Self.self); defer { st.cleanup() }
        for pkg in ["fx4/App4", "fx9/Pkg9", "fx11/App11", "fx6/Pkg6", "fx7/App7"] {
            let off = try scanFiles(st, pkg, env: [:])
            let on = try scanFiles(st, pkg, env: ["CANDOR_IDENT_PROBE": "1"])
            XCTAssertTrue(off.err.split(separator: "\n").allSatisfy { !$0.hasPrefix("ID") }, "\(pkg): the probe is off by default")
            XCTAssertTrue(on.err.contains("\nIDMS\t") || on.err.hasPrefix("IDMS\t") || on.err.contains("IDMS\t"), "\(pkg): the probe wrote records")
            XCTAssertFalse(on.files.isEmpty)
            XCTAssertEqual(Set(on.files.keys), Set(off.files.keys), "\(pkg): same output files")
            for (k, v) in off.files { XCTAssertEqual(on.files[k], v, "\(pkg): \(k) must be byte-equal with the probe on") }
        }
    }

    /// fx11: a SwiftPM package with two targets, one of which enables MemberImportVisibility. The module-wide closure and the
    /// target-wide set are what DESIGN §3 needs for an extension member called from a file that imports nothing.
    func testModuleRecordsOnAMultiTargetPackage() throws {
        let st = try H.stage(Self.self); defer { st.cleanup() }
        let err = try scanFiles(st, "fx11/App11", env: ["CANDOR_IDENT_PROBE": "1"]).err
        let idm = Dictionary(uniqueKeysWithValues: records(err, "IDM").map { ($0[1], $0) })
        let b = try XCTUnwrap(idm["Sources/Feature11/b.swift"])
        XCTAssertEqual(b[2], "Feature11"); XCTAssertEqual(b[3], "manifest"); XCTAssertEqual(b[5], "agree"); XCTAssertEqual(b[6], "disabled")
        XCTAssertEqual(b[7], "Feature11", "b.swift imports nothing, so ITS visible set is its own module")
        let a = try XCTUnwrap(idm["Sources/Feature11mi/a.swift"])
        XCTAssertEqual(a[6], "enabled", "the manifest enables MemberImportVisibility for Feature11mi")
        let ix = Dictionary(uniqueKeysWithValues: records(err, "IDX").map { ($0[1], $0) })
        XCTAssertEqual(ix["Feature11"]?[4], "Base11,Ext11X,Feature11", "target-visible: a.swift's imports reach every file of the target")
        XCTAssertEqual(records(err, "IDMS").first.map { Array($0[1...5]) }, ["files=4", "attributed=4", "agree=4", "disagree=0", "unattributed=0"])
    }

    /// The attribution gap: a file no target claims even though a manifest exists. `moduleOf` says nil and names the reason; the
    /// engine's existing `owningTarget` answer is nil for the same files (GRDB, swift-format, Nimble, Quick on the pool).
    func testTheAttributionGap() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-idm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "Kit", path: "Sources/Kit"), .target(name: "Single", path: "Sources/Single")])
        """)
        try write("Sources/Kit/Image/a.swift", "public struct A {}\n")        // module Kit; swiftModuleOf = Kit  -> agree
        try write("Sources/Single/General/b.swift", "public struct B {}\n")   // module Single; swiftModuleOf = Single -> agree
        try write("Sources/Other/c.swift", "public struct C {}\n")            // no target claims it; a manifest exists at the root
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("o").path], env: ["CANDOR_IDENT_PROBE": "1"])
        XCTAssertEqual(r.code, 0, r.err)
        let idm = Dictionary(uniqueKeysWithValues: records(r.err, "IDM").map { ($0[1], $0) })
        XCTAssertEqual(idm["Sources/Kit/Image/a.swift"]?[2], "Kit")
        let gap = try XCTUnwrap(idm["Sources/Other/c.swift"])
        XCTAssertEqual(gap[2], "-"); XCTAssertEqual(gap[5], "unattributed")
        XCTAssertTrue(gap[3].hasPrefix("none:manifest-unclaimed:"), "the gap's reason is that a manifest exists and claims nothing: \(gap[3])")
        let s = try XCTUnwrap(records(r.err, "IDMS").first)
        XCTAssertTrue(s.contains("unattributed=1"), "\(s)")
    }

    /// Disagreement proper: a SINGLE target with `path: "Sources"` over several directories — `swiftModuleOf` names each directory.
    func testPathTargetOverSeveralDirectoriesDisagrees() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-idm2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Kingfisher", targets: [.target(name: "Kingfisher", path: "Sources")])
        """)
        try write("Sources/Image/a.swift", "public struct A {}\n")
        try write("Sources/General/b.swift", "public struct B {}\n")
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--out", root.appendingPathComponent("o").path], env: ["CANDOR_IDENT_PROBE": "1"])
        XCTAssertEqual(r.code, 0, r.err)
        let idm = Dictionary(uniqueKeysWithValues: records(r.err, "IDM").map { ($0[1], $0) })
        for f in ["Sources/Image/a.swift", "Sources/General/b.swift"] {
            XCTAssertEqual(idm[f]?[2], "Kingfisher", "the manifest target"); XCTAssertEqual(idm[f]?[5], "disagree")
        }
        XCTAssertEqual(idm["Sources/Image/a.swift"]?[4], "Image", "swiftModuleOf's path segment")
        XCTAssertTrue(try XCTUnwrap(records(r.err, "IDMS").first).contains("disagree=2"))
    }

    /// The census instruments must FIRE on the fixtures they were written for and stay quiet on their controls — a census that cannot
    /// fail proves nothing (DESIGN §8, "Seeded"). Runs `tools/identity-census.sh --fixtures` with the BUILT binary and reads its seed
    /// table: binder-site X1+X2+X3 per entry and the use-site X1 answers, then `kappa_shadow.py`.
    func testCensusSeedsFireAtTheDesignNumbers() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/identity-census.sh")
        let py = try ProcessHarness.runRaw(URL(fileURLWithPath: "/usr/bin/env"), ["python3", "--version"])
        guard py.code == 0 else { throw XCTSkip("python3 is not available") }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-census-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        // The SEEDS are the instrument's calibration on the defect, so they run with lane LS switched off (SOUNDNESS R1938 lane
        // LS fixes the shape Pkg6 seeds): with LS on, Pkg6's local use-site answers for `Data` must go to 0 (asserted below).
        let r = try ProcessHarness.runRaw(URL(fileURLWithPath: "/bin/bash"), [script.path, "--fixtures", bin.path, out.path],
                                          env: ["CANDOR_TYPE_ID_SHADOW_OFF": "1"])
        XCTAssertEqual(r.code, 0, r.err)
        var seeds: [String: (binder: Int, use: Int)] = [:]
        for l in r.out.split(separator: "\n") {
            let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if f.count == 3, let b = Int(f[1]), let u = Int(f[2]) { seeds[f[0]] = (b, u) }
        }
        // ident census (binder sites) fx3 4 / fx4 20 / fx5 0 / fx5nw 0 / Pkg6 5 / Pkg6c 0;  use-site fx3 4 / fx4 14 / fx5 3 / fx5nw 3 / Pkg6 3 / Pkg6c 0
        let want: [String: (Int, Int)] = ["App3": (4, 4), "App4": (20, 14), "App5": (0, 3), "App5nw": (0, 3), "Pkg6": (5, 3), "Pkg6c": (0, 0)]
        for (k, w) in want {
            XCTAssertEqual(seeds[k]?.binder, w.0, "\(k): binder-site census"); XCTAssertEqual(seeds[k]?.use, w.1, "\(k): use-site census")
        }
        // kappa_shadow: the platform name `Data` is shadowed in Pkg6 (two declarations, three local answers) and not at all in Pkg6c
        XCTAssertTrue(r.out.contains("Pkg6                           {'Data': (2, 3,"), "kappa_shadow must fire on Pkg6:\n\(r.out)")
        XCTAssertFalse(r.out.contains("Pkg6c                          {"), "kappa_shadow must stay quiet on the renamed control")
        XCTAssertTrue(r.out.contains("0 of 19 attributed files differ"), "the engine's visible-module sets must agree with the independent @_exported reading")
        // lane LS ON: the two declarations are still there, the three local answers are not (the binder census is an EMULATOR of
        // the package-wide rule, so it does not move; the use-site census and kappa_shadow read the engine's real answers)
        let out2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-census-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out2) }
        let r2 = try ProcessHarness.runRaw(URL(fileURLWithPath: "/bin/bash"), [script.path, "--fixtures", bin.path, out2.path])
        XCTAssertEqual(r2.code, 0, r2.err)
        var seeds2: [String: (binder: Int, use: Int)] = [:]
        for l in r2.out.split(separator: "\n") {
            let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if f.count == 3, let b = Int(f[1]), let u = Int(f[2]) { seeds2[f[0]] = (b, u) }
        }
        XCTAssertEqual(seeds2["Pkg6"]?.use, 0, "Pkg6 with lane LS on: no local use-site answer for the shadowed platform name")
        XCTAssertTrue(r2.out.contains("Pkg6                           {'Data': (2, 0,"), "kappa_shadow with LS on: declarations kept, 0 local answers:\n\(r2.out)")
        for k in ["App3", "App4", "App5", "App5nw", "Pkg6c"] { XCTAssertEqual(seeds2[k]?.use, want[k]?.1, "\(k): LS must not move a non-platform name") }
    }
}
