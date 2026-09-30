import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R567(a) — **THE §2 DISPATCH KEY TOOK THE OUTER BASE'S TYPE FOR A MEMBER-CHAIN RECEIVER.**
///
/// `rootOf` deliberately KEEPS the outer base's type when a `.member` hop is not a known field, element
/// accessor or tuple member: the whole κ static-chain idiom rides on that fallback
/// (`FileManager.default.removeItem`, `ProcessInfo.processInfo.environment`), where the convention that
/// `Type.singleton` has type `Type` makes the surviving root the right answer. It is a CONVENTION, and
/// the ⟨0.39⟩ obligation-1 publish site and the §2 join both read it as a RESOLUTION — so
/// `channel.embeddedEventLoop.run()` was keyed `swift-nio#EmbeddedChannel.run`, a member the outer base
/// does not have. 13 of the 18 sites of the swift R533 measurement.
///
/// **AND IT IS NOT MERELY AN UNJOINABLE KEY.** When the outer base HAPPENS to declare the same leaf, the
/// join lands on the WRONG MEMBER — a fabrication and a silent under-report at once, in opposite
/// directions. ONE VARIABLE between the arms below: which type of the dependency the consumer's chain
/// really walks to. Everything else — the consumer's text, the dependency's text, the binary — is held.
///
///     dep: Loop.spin -> Env,  Channel.spin -> Fs        consumer: `c.loop.spin()`
///       PRE-FIX   inferred ['Fs']     deny Env exit 0     deny Fs exit 1
///       TRUTH     inferred ['Env']
///
/// `dbe3f68` DROPPED the key and disclosed, but only in a CHAINED scan — and a standalone producer (the
/// ordinary workflow for a middle library) then published neither key nor disclosure, so a three-package
/// chain fell silent against v0.39.2 (R836). Refusing also removed CORRECT charges wherever the outer
/// base's member IS the callee (a self-typed hop, `n.parent.visit()`), and nothing on the wire says which
/// case a hop is. So the release's owner is now a FLOOR — its key is published and joined exactly as
/// v0.39.2 did — and the guess is DISCLOSED instead of acted on, in chained and standalone scans alike.
///
/// **What that costs, pinned here rather than left to be rediscovered:** the fabrication half comes back
/// as v0.39.2 shipped it (`deny Fs` exits 1 over `c.loop.spin()`); the SILENT half stays closed — the row
/// carries `Unknown[dispatch:untyped cross-package receiver]`, so `deny Env Unknown` exits 1 over code
/// that reads the environment through a receiver the engine could not type. Closing the fabrication
/// without re-opening a silence needs the hop's declared type from the dependency (contract work).
///
/// §1b: the disclosure assertions FAIL under `CANDOR_R567A_OFF=1`, which restores the release exactly.
/// The CONTROL arm (`l.spin()` on a directly-typed receiver) passes in both.
final class ReceiverChainOwnerKeyProcessTests: XCTestCase {

    private struct Row {
        let inferred: Set<String>
        let unknownWhy: Set<String>
        let dispatchesOn: Set<String>
        let present: Bool
    }

    /// Scan `dep` with the engine, chain its report, scan `app`, and return one row per consumer fn plus
    /// the two gate exits. The dependency report is produced BY THE SAME BINARY, so the producer half of
    /// any key change is inside the measurement rather than held out of it.
    private func run(depSource: String, appSource: String, label: String)
        throws -> (rows: [String: Row], denyEnv: Int32, denyFs: Int32, denyEnvUnknown: Int32,
                   depFns: [String: [String]]) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r567a-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "RatesDep",
            products: [.library(name: "RatesCore", targets: ["RatesCore"])],
            targets: [.target(name: "RatesCore")])
        """)
        try write("dep/Sources/RatesCore/lib.swift", depSource)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [.product(name: "RatesCore", package: "dep")])])
        """)
        try write("app/Sources/App/app.swift", appSource)
        try write("envdeny.policy", "deny Env\n")
        try write("fsdeny.policy", "deny Fs\n")
        try write("envunk.policy", "deny Env Unknown\n")

        let depDir = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path,
                                              "--out", depDir.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        let report = depDir.appendingPathComponent("r.RatesDep.Swift.json")
        let depDoc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        var depFns: [String: [String]] = [:]
        for f in (depDoc?["functions"] as? [[String: Any]]) ?? [] {
            depFns[(f["fn"] as? String) ?? "?"] = ((f["inferred"] as? [String]) ?? []).sorted()
        }
        // the chaining loader refuses a directory holding anything but reports
        for extra in try FileManager.default.contentsOfDirectory(atPath: depDir.path)
        where extra != report.lastPathComponent {
            try FileManager.default.removeItem(at: depDir.appendingPathComponent(extra))
        }

        let out = root.appendingPathComponent("ch")
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", out.path],
                                       env: ["CANDOR_DEPS": depDir.path])
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Row] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = Row(
                inferred: Set((f["inferred"] as? [String]) ?? []),
                unknownWhy: Set((f["unknownWhy"] as? [String]) ?? []),
                dispatchesOn: Set((f["dispatchesOn"] as? [String]) ?? []),
                present: true)
        }
        let ge = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                              "--policy", root.appendingPathComponent("envdeny.policy").path,
                                              "--out", root.appendingPathComponent("ge").path],
                                        env: ["CANDOR_DEPS": depDir.path])
        let gf = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                              "--policy", root.appendingPathComponent("fsdeny.policy").path,
                                              "--out", root.appendingPathComponent("gf").path],
                                        env: ["CANDOR_DEPS": depDir.path])
        let gu = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                              "--policy", root.appendingPathComponent("envunk.policy").path,
                                              "--out", root.appendingPathComponent("gu").path],
                                        env: ["CANDOR_DEPS": depDir.path])
        return (rows, ge.code, gf.code, gu.code, depFns)
    }

    /// The dependency: `Channel.loop` is a `Loop`, and BOTH types declare `spin`. Only `Loop.spin` is
    /// reachable through `c.loop.spin()`; `Channel.spin` is the decoy the outer-base key lands on.
    private static let twoTypesOneLeaf = """
    import Foundation
    public final class Loop {
        public init() {}
        public func spin() { _ = ProcessInfo.processInfo.environment["Y"] }
    }
    public final class Channel {
        public let loop = Loop()
        public init() {}
        public func spin() { _ = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) }
    }
    """

    func testAMemberChainReceiverThroughAnUntypedHopDisclosesBesideTheReleaseKey() throws {
        let r = try run(depSource: Self.twoTypesOneLeaf, appSource: """
        import RatesCore
        public func chainWrong(_ c: Channel) { c.loop.spin() }
        public func controlDirect(_ l: Loop) { l.spin() }
        """, label: "wrong")

        // §E3 — the dependency must really carry BOTH effects, or every assertion below is about nothing.
        XCTAssertEqual(r.depFns["Loop.spin"], ["Env"], "dep fns: \(r.depFns)")
        XCTAssertEqual(r.depFns["Channel.spin"], ["Fs"], "dep fns: \(r.depFns)")

        let wrong = r.rows["chainWrong"]
        XCTAssertNotNil(wrong, "the row must EXIST — absence is a purity claim under ⟨0.21⟩")
        XCTAssertTrue(wrong?.unknownWhy.contains("dispatch:untyped cross-package receiver") ?? false,
                      "the Env `c.loop.spin()` really reaches is not recoverable by this engine, so the row "
                      + "must DISCLOSE — the silent half of the release's defect; got \(wrong?.unknownWhy ?? [])")
        XCTAssertTrue(wrong?.inferred.contains("Unknown") ?? false, "got \(wrong?.inferred ?? [])")
        XCTAssertEqual(wrong?.dispatchesOn, ["RatesDep#Channel.spin"],
                       "THE FLOOR — the key v0.39.2 published for this call is published again, so no "
                       + "consumer that answered it on the release stops answering it; got \(wrong?.dispatchesOn ?? [])")
        XCTAssertTrue(wrong?.inferred.contains("Fs") ?? false,
                      "THE NAMED RESIDUAL — the decoy's Fs, exactly as v0.39.2 charged it. If this starts "
                      + "failing, the fabrication was closed: re-check that no correct charge went with it")

        // THE CONTROL — a directly-typed receiver, one line away, must be untouched in BOTH directions.
        XCTAssertEqual(r.rows["controlDirect"]?.inferred, ["Env"],
                       "CONTROL: `l.spin()` on a `Loop`-typed parameter resolves as it always did")
        XCTAssertEqual(r.rows["controlDirect"]?.dispatchesOn, ["RatesDep#Loop.spin"],
                       "…including its published key; got \(r.rows["controlDirect"]?.dispatchesOn ?? [])")
        XCTAssertTrue(r.rows["controlDirect"]?.unknownWhy.isEmpty ?? false, "…and is not hedged")

        XCTAssertEqual(r.denyEnvUnknown, 1,
                       "GATE LEVEL, the silence half: `deny Env Unknown` over code that reads the "
                       + "environment through an untyped hop exited 0 on v0.39.2 (the key named the decoy)")
        XCTAssertEqual(r.denyEnv, 1, "`deny Env` passes through the CONTROL's real Env")
        XCTAssertEqual(r.denyFs, 1, "the release's fabricated `deny Fs` — the named residual, not a goal")
    }

    /// A leaf the outer base does not declare at all (`EmbeddedChannel.run`): the release keyed it on the
    /// outer base, missed, and read the miss as purity. The key is kept (the floor) and the row discloses.
    func testAChainLeafTheOuterBaseDoesNotDeclareDisclosesInsteadOfReadingPure() throws {
        let r = try run(depSource: """
        import Foundation
        public final class Loop {
            public init() {}
            public func run() { _ = ProcessInfo.processInfo.environment["Y"] }
        }
        public final class Channel {
            public let loop = Loop()
            public init() {}
        }
        """, appSource: """
        import RatesCore
        public func chainMiss(_ c: Channel) { c.loop.run() }
        """, label: "miss")

        XCTAssertEqual(r.depFns["Loop.run"], ["Env"], "dep fns: \(r.depFns)")
        let miss = r.rows["chainMiss"]
        XCTAssertNotNil(miss, "ABSENT on v0.39.2 — a purity claim over a call that reads the environment")
        XCTAssertTrue(miss?.unknownWhy.contains("dispatch:untyped cross-package receiver") ?? false,
                      "got \(String(describing: miss))")
        XCTAssertEqual(r.denyEnvUnknown, 1, "GATE LEVEL: 0 on v0.39.2")
    }

    /// **THE NARROWING, asserted rather than left to be discovered.** The κ static-chain idiom is the
    /// reason `rootOf`'s fallback keeps the outer base at all, and it runs BEFORE this arm — so
    /// `FileManager.default.removeItem` must still be Fs and `ProcessInfo.processInfo.environment` must
    /// still be Env with no dependency in sight. If this reds, the flag was read one branch too early.
    func testTheKappaStaticChainIdiomIsUntouched() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        public func wipe(_ p: String) { try? FileManager.default.removeItem(atPath: p) }
        public func peek() -> String? { return ProcessInfo.processInfo.environment["HOME"] }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("k")
        let r = try ProcessHarness.run(bin, [root.path, "--out", out.path])
        XCTAssertEqual(r.code, 0, "stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("k.App.Swift.json"))) as? [String: Any]
        var got: [String: Set<String>] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            got[(f["fn"] as? String) ?? "?"] = Set((f["inferred"] as? [String]) ?? [])
        }
        XCTAssertEqual(got["wipe"], ["Fs"],
                       "`FileManager.default.removeItem` walks an UNEXPLAINED `.default` hop — exactly "
                       + "the fallback `opaqueHop` marks — and κ reads it one branch earlier. "
                       + "got \(got)")
        XCTAssertEqual(got["peek"], ["Env"], "…and the property-read spelling of the same idiom; got \(got)")
    }
}
