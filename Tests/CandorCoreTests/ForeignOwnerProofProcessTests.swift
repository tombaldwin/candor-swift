import XCTest
import Foundation
@testable import CandorCore

/// VEIN D — SOUNDNESS R774, R548 (the two-import half) and R843(ii) (the member half).
///
/// `foreignOwnerModule` decides "which dependency module declares the foreign name `X`" from the FILE
/// alone, and a file importing two dependency modules refuses for every name in it. The refusal then
/// costs three things at once, and disclosed none of them: obligation 1's `dispatchesOn` key (a consumer
/// of the middle package goes silent), obligation 2's union entry (a consumer dispatching on the
/// dependency's protocol goes silent), and ⟨0.40⟩'s `supers` (kind-only).
///
/// THE FIX IS A PROOF, NOT A BETTER COUNT, AND THE RELEASE'S ANSWER IS ITS FLOOR. Wherever the release
/// answered, nothing moves; where it refused, the owner is taken only from evidence that names it — the
/// dependency's own SOURCES (one candidate declares the name publicly at file scope, every other one is
/// read and does not) or the chained ⟨0.40⟩ `types` manifests. A name proven to be a dependency's but not
/// WHICH one's is DISCLOSED (`Unknown`), never keyed.
///
/// EXECUTED: the same five-package shape was built with SwiftPM and run (the conformer writes a marker
/// file, the leaf reads an env value) in `swiftagent-veinsDC/fxD`; the two-import arm wrote the file and
/// read the value while v0.39.3 and 344b57b read `deny Fs` / `deny Env` exit 0 over it.
final class ForeignOwnerProofProcessTests: XCTestCase {

    /// Builds DProto (the abstraction), DExtra (the second import), Leaf (a final class), DImpl (the
    /// conformer) and Mid (a relay). `extraImport`: the conformance/relay files also `import DExtra`
    /// (the one variable of the defect). `internalTwin`: DExtra also declares INTERNAL same-named types —
    /// legal Swift (they are invisible to the importer), and exactly the case the proof must REFUSE.
    private func makeTree(extraImport: Bool, internalTwin: Bool = false, protoBody: Bool = false,
                          label: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-veind-\(label)-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        func lib(_ n: String, _ deps: [String]) throws {
            let pd = deps.map { ".package(path: \"../\($0)\")" }.joined(separator: ", ")
            let td = deps.map { ".product(name: \"\($0)\", package: \"\($0)\")" }.joined(separator: ", ")
            try write("\(n)/Package.swift", """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "\(n)", products: [.library(name: "\(n)", targets: ["\(n)"])],
                dependencies: [\(pd)], targets: [.target(name: "\(n)", dependencies: [\(td)])])
            """)
        }
        try lib("DProto", [])
        try write("DProto/Sources/DProto/p.swift", "public protocol PumpSinkD { func pumpEmit() }\n"
                  + (protoBody ? "public func protoVersionD() -> Int { 1 }\n" : ""))
        try lib("DExtra", [])
        try write("DExtra/Sources/DExtra/x.swift", "public func extraTickD() -> Int { 1 }\n" + (internalTwin
            ? "protocol PumpSinkD { func pumpEmit() }\nfinal class LeafReaderD { func readLeafD() -> String? { nil } }\n" : ""))
        try lib("Leaf", [])
        try write("Leaf/Sources/Leaf/l.swift", """
        import Foundation
        public final class LeafReaderD { public init() {}; public func readLeafD() -> String? { ProcessInfo.processInfo.environment["SV_VD"] } }
        """)
        let extra = extraImport ? "import DExtra\n" : ""
        try lib("DImpl", ["DProto", "DExtra"])
        try write("DImpl/Sources/DImpl/impl.swift", """
        import Foundation
        import DProto
        \(extra)public struct FileSinkD: PumpSinkD { public init() {}; public func pumpEmit() { _ = FileManager.default.createFile(atPath: "/tmp/vd_sink", contents: nil) } }
        public struct NamedSinkD: CustomStringConvertible { public var description: String { _ = FileManager.default.createFile(atPath: "/tmp/vd_desc", contents: nil); return "" } }
        """)
        try lib("Mid", ["Leaf", "DExtra"])
        try write("Mid/Sources/Mid/m.swift", """
        import Leaf
        \(extra)public func midRelay(_ r: LeafReaderD) -> String? { r.readLeafD() }
        public func midCountD(_ s: Set<Int>) -> Int { s.count }
        """)
        return root
    }

    private func scan(_ dir: URL, env: [String: String] = [:]) throws -> [String: Any] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [dir.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan of \(dir.lastPathComponent) — stderr: \(r.err)")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        // §E3 — an absence assertion over a report that judged nothing is an assertion about nothing.
        XCTAssertGreaterThan(((d["analyzed"] as? [String: Any])?["count"] as? Int) ?? 0, 0, "judged nothing: \(r.err)")
        return d
    }
    private func rows(_ d: [String: Any]) -> [[String: Any]] { (d["functions"] as? [[String: Any]]) ?? [] }
    private func unions(_ d: [String: Any]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for f in rows(d) where (f["interfaceUnion"] as? Bool) == true {
            out[(f["hash"] as? String) ?? "?", default: []] += (f["inferred"] as? [String]) ?? []
        }
        return out
    }
    private func row(_ d: [String: Any], _ fn: String) -> [String: Any]? {
        rows(d).first { ($0["fn"] as? String) == fn && ($0["interfaceUnion"] as? Bool) != true }
    }
    private func supers(_ d: [String: Any], _ key: String) -> [String]? {
        (((d["typeSurface"] as? [String: Any])?["types"] as? [String: Any])?[key] as? [String: Any])?["supers"] as? [String]
    }

    // ── obligation 2 (R774) ──────────────────────────────────────────────────────────────────────────

    func testTwoImportConformanceIsKeyedUnderTheProvenOwner() throws {
        let root = try makeTree(extraImport: true, label: "obl2")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try scan(root.appendingPathComponent("DImpl"))
        XCTAssertEqual(unions(d), ["DProto#PumpSinkD.pumpEmit": ["Fs"]],
                       "DProto's sources declare `PumpSinkD` publicly and DExtra's are read and do not: the "
                       + "owner is proven, and the union entry a consumer of DProto joins must be published")
        XCTAssertEqual(supers(d, "DImpl#FileSinkD"), ["DProto#PumpSinkD"], "⟨0.40⟩ `supers` follows the same proof")
        // THE CONTROL: a PLATFORM conformance in the same two-import file is never keyed under a dependency.
        XCTAssertFalse(unions(d).keys.contains { $0.contains("CustomStringConvertible") },
                       "no candidate declares `CustomStringConvertible`, so nothing may be keyed under one")
        // §1b — the kill switch restores the release's refusal, so the assertion above can fail.
        let off = try scan(root.appendingPathComponent("DImpl"), env: ["CANDOR_VEIND_OFF": "1"])
        XCTAssertEqual(unions(off), [:], "CANDOR_VEIND_OFF=1 must reproduce 344b57b's refusal")
        XCTAssertNil(supers(off, "DImpl#FileSinkD"), "…and its kind-only `types` entry")
    }

    func testOneImportFloorIsUnchanged() throws {
        let root = try makeTree(extraImport: false, label: "floor")
        defer { try? FileManager.default.removeItem(at: root) }
        let on = try scan(root.appendingPathComponent("DImpl"))
        let off = try scan(root.appendingPathComponent("DImpl"), env: ["CANDOR_VEIND_OFF": "1"])
        XCTAssertEqual(unions(on)["DProto#PumpSinkD.pumpEmit"], ["Fs"])
        XCTAssertEqual(unions(on), unions(off), "where the release answered, the proof is never consulted")
        // RECORDED, NOT CHANGED: the one-import FLOOR also keys the platform conformance under the file's
        // one dependency (`DProto#CustomStringConvertible.description`, the vein analysis's N7). The proof
        // never does that (the two-import test above asserts it); the floor is left exactly as released.
        XCTAssertEqual(unions(on)["DProto#CustomStringConvertible.description"], ["Fs"],
                       "the floor's N7 behaviour is pinned as it is, so a change to it is seen")
    }

    func testAnInternalTwinMakesTheOwnerUndecidedAndDisclosed() throws {
        let root = try makeTree(extraImport: true, internalTwin: true, label: "undecided2")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try scan(root.appendingPathComponent("DImpl"))
        // An internal `PumpSinkD` in DExtra is invisible to DImpl, so DProto IS the owner — but the proof
        // counts every declaration for EXCLUSION, so it refuses rather than reason about access it cannot
        // fully see (`@testable import`). Refusing must not be silence: `Unknown` under each possible owner.
        XCTAssertEqual(unions(d), ["DProto#PumpSinkD.pumpEmit": ["Unknown"], "DExtra#PumpSinkD.pumpEmit": ["Unknown"]],
                       "an undecided owner publishes `Unknown` under every package that may own it, and no "
                       + "concrete effect under any of them")
        XCTAssertNil(supers(d, "DImpl#FileSinkD"), "undecided stays kind-only — ⟨0.40⟩'s own disclosure")
    }

    /// THE PUBLISHED-SURFACE PROOF, and the guard that keeps it from naming the wrong owner. The producer
    /// is scanned CHAINED from a directory where its dependencies' sources do not exist, so only the
    /// reports can speak. A report that judged nothing (a protocol-only package: `analyzed.count` 0) is
    /// distrusted by ⟨0.24⟩ and its `types` are not indexed — so its SILENCE must not exclude it. Measured
    /// before this guard existed: with DExtra's internal twin chained beside a judged-nothing DProto, the
    /// proof answered `DExtra#PumpSinkD.pumpEmit` with the conformer's `Fs` — the wrong package.
    private func chainedLone(_ root: URL, _ deps: [String]) throws -> [String: Any] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        var reports: [String] = []
        for dep in deps {
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent(dep).path, "--out",
                                                 root.appendingPathComponent("r/\(dep)").path])
            XCTAssertEqual(r.code, 0, r.err)
            reports.append(root.appendingPathComponent("r/\(dep).\(dep).Swift.json").path)
        }
        let lone = root.appendingPathComponent("lone/DImpl")
        try FileManager.default.createDirectory(at: lone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("DImpl"), to: lone)
        return try scan(lone, env: ["CANDOR_DEPS": reports.joined(separator: ":")])
    }

    func testPublishedSurfaceProvesTheOwnerWhenSourcesAreAbsent() throws {
        let root = try makeTree(extraImport: true, protoBody: true, label: "surface")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try chainedLone(root, ["DProto", "DExtra"])
        XCTAssertEqual(unions(d), ["DProto#PumpSinkD.pumpEmit": ["Fs"]],
                       "DProto's trusted ⟨0.40⟩ manifest declares `PumpSinkD`; DExtra's does not")
    }

    func testAJudgedNothingReportNeverExcludesItsPackage() throws {
        let root = try makeTree(extraImport: true, internalTwin: true, label: "distrusted")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try chainedLone(root, ["DProto", "DExtra"])
        XCTAssertNil(unions(d)["DExtra#PumpSinkD.pumpEmit"].flatMap { $0.contains("Fs") ? $0 : nil },
                     "the wrong package must never carry the conformer's concrete effect")
        XCTAssertEqual(unions(d), ["DProto#PumpSinkD.pumpEmit": ["Unknown"], "DExtra#PumpSinkD.pumpEmit": ["Unknown"]],
                       "DProto's judged-nothing report says nothing either way, DExtra declares the name: undecided, disclosed")
    }

    // ── obligation 1 (R548's two-import half, R843(ii)'s member half) ────────────────────────────────

    func testTwoImportMemberCallPublishesTheProvenKey() throws {
        let root = try makeTree(extraImport: true, label: "obl1")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try scan(root.appendingPathComponent("Mid"))
        let relay = try XCTUnwrap(row(d, "midRelay"), "midRelay must keep its row")
        XCTAssertEqual(relay["dispatchesOn"] as? [String], ["Leaf#LeafReaderD.readLeafD"],
                       "the key the one-import file publishes, now published from the two-import file")
        XCTAssertNil(row(d, "midCountD"), "a stdlib receiver (`Set`) is no candidate's type: no key, no row")
        // R1066 (candor-swift v044) attributes `invisible: [Leaf]` to this row independently of vein D — `Leaf`'s own
        // sources declare `LeafReaderD` — so reproducing 344b57b's row needs both switches.
        let off = try scan(root.appendingPathComponent("Mid"), env: ["CANDOR_VEIND_OFF": "1", "CANDOR_R1066_OFF": "1"])
        XCTAssertNil(row(off, "midRelay"), "CANDOR_VEIND_OFF=1 must reproduce 344b57b's ABSENT row")
        let offD = try scan(root.appendingPathComponent("Mid"), env: ["CANDOR_VEIND_OFF": "1"])
        XCTAssertEqual(row(offD, "midRelay")?["invisible"] as? [String], ["Leaf"],
                       "R1066: with no key, the source-proven receiver is still attributed to its module")
    }

    func testUndecidedMemberCallIsDisclosedNotKeyed() throws {
        let root = try makeTree(extraImport: true, internalTwin: true, label: "undecided1")
        defer { try? FileManager.default.removeItem(at: root) }
        let d = try scan(root.appendingPathComponent("Mid"))
        let relay = try XCTUnwrap(row(d, "midRelay"))
        XCTAssertEqual(relay["inferred"] as? [String], ["Unknown"])
        XCTAssertEqual(relay["unknownWhy"] as? [String], ["dispatch:LeafReaderD.readLeafD"])
        XCTAssertNil(relay["dispatchesOn"], "an unproven owner never mints a key")
    }

    // ── the chain, end to end: the gate flips on code that really performs the effect ─────────────────

    func testChainedConsumerGateFlips() throws {
        let root = try makeTree(extraImport: true, label: "chain")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        var reports: [String] = []
        for dep in ["DProto", "DExtra", "Leaf", "DImpl", "Mid"] {
            let out = root.appendingPathComponent("r/\(dep)")
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent(dep).path, "--out", out.path])
            XCTAssertEqual(r.code, 0, r.err)
            reports.append(root.appendingPathComponent("r/\(dep).\(dep).Swift.json").path)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/Sources/App"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App",
          dependencies: [.package(path: "../DProto"), .package(path: "../DImpl"), .package(path: "../Mid"), .package(path: "../Leaf")],
          targets: [.executableTarget(name: "App", dependencies: [.product(name: "DProto", package: "DProto"), .product(name: "DImpl", package: "DImpl"), .product(name: "Mid", package: "Mid"), .product(name: "Leaf", package: "Leaf")])])
        """.write(to: root.appendingPathComponent("App/Package.swift"), atomically: true, encoding: .utf8)
        try """
        import DProto
        import DImpl
        import Mid
        import Leaf
        func pumpViaProto(_ s: PumpSinkD) { s.pumpEmit() }
        func driveSink() { pumpViaProto(FileSinkD()) }
        func appRelay() -> String? { midRelay(LeafReaderD()) }
        func topRelay() -> String? { appRelay() }
        """.write(to: root.appendingPathComponent("App/Sources/App/main.swift"), atomically: true, encoding: .utf8)
        let env = ["CANDOR_DEPS": reports.joined(separator: ":")]
        for (pol, label) in [("deny Fs pumpViaProto", "the unit"), ("deny Fs driveSink", "its caller"),
                             ("deny Env appRelay", "the relay's caller"), ("deny Env topRelay", "one hop further")] {
            let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
            try (pol + "\n").write(to: pf, atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent("App").path, "--policy", pf.path, "--json"], env: env)
            // A must-FAIL arm (R706's harness note: under `swift test` a non-violating gate can exit 2).
            XCTAssertEqual(r.code, 1, "`\(pol)` (\(label)) must fail — it read exit 0 on v0.39.3 and 344b57b. stderr: \(r.err)")
        }
    }
}
