import XCTest
import Foundation

/// AN ENTRY CARRYING `Unknown` MUST CARRY THE MARKERS THAT SAY SO.
///
/// Swept from candor-ts `e66f29e`, where an entry inherited `Unknown` while its `unresolved` marker was
/// absent — a TIER-1 consumer reading the marker got `false` on an entry that genuinely carries Unknown.
/// candor-swift is structurally immune: `unresolved` is DERIVED from the effect set at the single writer
/// (`main.swift`, `unresolved: inf.contains("Unknown")`), at both Effector construction sites. This suite
/// pins that derivation, because the immunity is a property of one expression and nothing else enforces it.
///
/// Two invariants, over every Unknown-introducing path this engine has (a stale chained dep, an
/// unresolvable external dispatch, an opaque callback, a bounded-CHA overflow), plus their transitive
/// callers, which is the direction the ts defect arrived from:
///   1. `Unknown` in `inferred`  =>  `unresolved: true`
///   2. `Unknown` in `direct`    =>  a non-empty `unknownWhy` (SPEC §4: a direct source names its origin;
///      a purely INHERITED Unknown is deliberately exempt, so the check keys on `direct`)
final class UnknownMarkerInvariantProcessTests: XCTestCase {

    private func assertInvariants(_ out: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as! [String: Any]
        let fns = ((d["functions"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
        var withUnknown = 0
        for e in fns {
            let name = e["fn"] as? String ?? "?"
            let inferred = Set(e["inferred"] as? [String] ?? [])
            let direct = Set(e["direct"] as? [String] ?? [])
            if inferred.contains("Unknown") {
                withUnknown += 1
                XCTAssertTrue(e["unresolved"] as? Bool ?? false,
                              "\(name): carries Unknown but `unresolved` is not set", file: file, line: line)
            } else {
                XCTAssertFalse(e["unresolved"] as? Bool ?? false,
                               "\(name): `unresolved` set with no Unknown in the effect set", file: file, line: line)
            }
            if direct.contains("Unknown") {
                XCTAssertFalse((e["unknownWhy"] as? [String] ?? []).isEmpty,
                               "\(name): a DIRECT Unknown must name its origin (SPEC §4)", file: file, line: line)
            }
        }
        XCTAssertGreaterThanOrEqual(withUnknown, 4,
                                    "the fixture must actually produce Unknowns, or this asserts nothing",
                                    file: file, line: line)
    }

    /// Four different Unknown SOURCES plus a caller that only inherits, so both the direct and the
    /// transitive arm are exercised in one report.
    func testEveryUnknownCarriesItsMarkers() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation

        protocol Wide { func go() }
        \((0...13).map { "struct W\($0): Wide { func go() { print(ProcessInfo.processInfo.environment[\"\($0)\"] ?? \"\") } }" }.joined(separator: "\n"))

        // 1. a bounded-CHA overflow (more conformers than the fan-out limit) -> dispatch:
        func overflow(_ w: Wide) { w.go() }

        // 2. an opaque callback value -> callback:
        func opaqueCallback(_ f: () -> Void) { f() }

        // 3. an unresolvable member on an unknown receiver, reached through a computed callee
        func computedCallee(_ table: [String: () -> Void], _ k: String) { table[k]?() }

        // 4. a caller that only INHERITS — no `unknownWhy` of its own, and that is correct
        func inheritsOnly(_ w: Wide) { overflow(w) }
        """, name: "Marker")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        let r = try ProcessHarness.run(bin, [root.path, "--out", out.path])
        XCTAssertEqual(r.code, 0, r.err)
        try assertInvariants(root.appendingPathComponent("r.Marker.Swift.json"))
    }

    /// The path the ts defect actually travelled: Unknown arriving through the §2 chained-dep join, where
    /// the effect set is written by `applyDepEntry` and not by the local analysis at all.
    func testUnknownInheritedFromAChainedDepCarriesItsMarkers() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\n", name: "Unused")
        defer { try? FileManager.default.removeItem(at: root) }
        // a dep report from ANOTHER engine build: every key it carries downgrades to Unknown (§2.1)
        let depReport = root.appendingPathComponent("dep.json")
        let dep: [String: Any] = [
            "candor": ["version": "candor-swift-0.0.0-other", "spec": "0.23", "toolchain": "swiftsyntax"],
            "package": "DepPkg",
            "functions": [["fn": "depCall", "hash": "DepPkg#depCall", "inferred": ["Fs"]]],
        ]
        try JSONSerialization.data(withJSONObject: dep).write(to: depReport)

        let app = try ProcessHarness.makePackage("""
        import DepPkg
        public func joins() { depCall() }
        public func inheritsTheJoin() { joins() }
        """, name: "App")
        defer { try? FileManager.default.removeItem(at: app) }
        let out = app.appendingPathComponent("r")
        let r = try ProcessHarness.run(bin, [app.path, "--out", out.path],
                                       env: ["CANDOR_DEPS": depReport.path])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: app.appendingPathComponent("r.App.Swift.json"))) as! [String: Any]
        let by = Dictionary(uniqueKeysWithValues: ((d["functions"] as? [Any]) ?? [])
            .compactMap { $0 as? [String: Any] }.map { ($0["fn"] as! String, $0) })

        XCTAssertEqual(Set(by["joins"]?["inferred"] as? [String] ?? []), ["Unknown"])
        XCTAssertTrue(by["joins"]?["unresolved"] as? Bool ?? false,
                      "the joined Unknown must carry the marker")
        XCTAssertEqual(by["joins"]?["unknownWhy"] as? [String], ["dep-stale:DepPkg"])
        // the transitive caller: marker YES (it carries Unknown), own reason NO (it is not the source)
        XCTAssertTrue(by["inheritsTheJoin"]?["unresolved"] as? Bool ?? false,
                      "a caller that inherits Unknown carries the marker too")
        XCTAssertNil(by["inheritsTheJoin"]?["unknownWhy"],
                     "…and does NOT invent a reason it is not the source of (SPEC §4)")
    }
}
