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
/// The fix DROPS the key (§2 rule 1: never guess) and emits the COULD-NOT-FORM-A-KEY marker the sibling
/// arm already uses, so the row discloses rather than falling silent — dropping alone trades a wrong
/// answer for a positive purity claim, which is the same defect wearing a different face.
///
/// §1b: every assertion here FAILS under `CANDOR_R567A_OFF=1`, which restores the pre-fix owner. The
/// CONTROL arm (`l.run()` on a directly-typed receiver) passes in BOTH, or a "fix" that dropped every
/// foreign key would read green.
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
        throws -> (rows: [String: Row], denyEnv: Int32, denyFs: Int32, depFns: [String: [String]]) {
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
        return (rows, ge.code, gf.code, depFns)
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

    func testAMemberChainReceiverDoesNotInheritTheOuterBasesSameNamedMember() throws {
        let r = try run(depSource: Self.twoTypesOneLeaf, appSource: """
        import RatesCore
        public func chainWrong(_ c: Channel) { c.loop.spin() }
        public func controlDirect(_ l: Loop) { l.spin() }
        """, label: "wrong")

        // §E3 — the dependency must really carry BOTH effects, or every assertion below is about nothing.
        XCTAssertEqual(r.depFns["Loop.spin"], ["Env"], "dep fns: \(r.depFns)")
        XCTAssertEqual(r.depFns["Channel.spin"], ["Fs"], "dep fns: \(r.depFns)")

        let wrong = r.rows["chainWrong"]
        XCTAssertNotNil(wrong,
                        "the row must EXIST: dropping the key without disclosing trades a wrong answer "
                        + "for a positive purity claim, and a fn absent from `functions[]` while counted "
                        + "in `analyzed` is exactly that under ⟨0.21⟩")
        XCTAssertFalse(wrong?.inferred.contains("Fs") ?? true,
                       "`Channel.spin` is Fs and is NOT what `c.loop.spin()` reaches. Keying the chain to "
                       + "the OUTER BASE charged it anyway — a fabrication; got \(wrong?.inferred ?? [])")
        XCTAssertTrue(wrong?.unknownWhy.contains("dispatch:untyped cross-package receiver") ?? false,
                      "…and the Env it DOES reach is not recoverable by this engine, so the row must "
                      + "DISCLOSE rather than fall silent — the same marker and the same token the "
                      + "sibling could-not-form-a-key arm uses; got \(wrong?.unknownWhy ?? [])")
        XCTAssertTrue(wrong?.dispatchesOn.isEmpty ?? false,
                      "obligation 1 must publish NO key here: `RatesDep#Channel.spin` names a member the "
                      + "receiver's real type does not have, and a consumer joining it inherits the "
                      + "decoy's effects; got \(wrong?.dispatchesOn ?? [])")

        // THE CONTROL — a directly-typed receiver, one line away, must be untouched in BOTH directions.
        XCTAssertEqual(r.rows["controlDirect"]?.inferred, ["Env"],
                       "CONTROL: `l.spin()` on a `Loop`-typed parameter resolves as it always did. A fix "
                       + "that dropped every foreign key would read green on the arm above and red here")
        XCTAssertEqual(r.rows["controlDirect"]?.dispatchesOn, ["RatesDep#Loop.spin"],
                       "…including its published key; got \(r.rows["controlDirect"]?.dispatchesOn ?? [])")

        XCTAssertEqual(r.denyFs, 0,
                       "GATE LEVEL, the fabrication half: `deny Fs` over a consumer that opens no file "
                       + "exited 1 before this fix — the decoy's effect reaching a policy")
        XCTAssertEqual(r.denyEnv, 1,
                       "GATE LEVEL, the silence half: `deny Env` over code that reads the environment "
                       + "exited 0 before this fix. It passes now through the CONTROL's real Env, and "
                       + "the disclosed row is what makes `deny Env Unknown` fire on the chain itself")
    }

    /// The row's own shape: a leaf the outer base does not declare at all (`EmbeddedChannel.run`). No
    /// decoy, so nothing is fabricated either way — what is measured is that the unjoinable key is not
    /// PUBLISHED, and that the call discloses instead of vanishing.
    func testAChainLeafTheOuterBaseDoesNotDeclarePublishesNoKey() throws {
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
        XCTAssertTrue(miss?.dispatchesOn.isEmpty ?? false,
                      "`RatesDep#Channel.run` is obligation 1's key for a member `Channel` does not have "
                      + "— unjoinable by construction, and additive noise in every consumer's index; "
                      + "got \(miss?.dispatchesOn ?? [])")
        XCTAssertTrue(miss?.unknownWhy.contains("dispatch:untyped cross-package receiver") ?? false,
                      "got \(miss?.unknownWhy ?? [])")
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
