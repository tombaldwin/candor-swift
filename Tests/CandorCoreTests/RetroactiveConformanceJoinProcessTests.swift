import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R657 / R692 — **A LOCAL ANSWER PREEMPTED THE CHAINED DEPENDENCY'S OWN ROW.**
///
/// The external-supertype fallback in `Driver.swift` exists for the case where a project type conforms to
/// a base candor cannot see: it mints `Unknown` + `dispatch:<sup>.<member>` and sets `resolved = true`.
/// That flag is what the §2 CANDOR_DEPS join, ~500 lines further down, is gated on — so wherever the
/// fallback fired, **the dependency's published row for exactly that member was never read**. The consumer
/// ended up reading MORE CERTAINTY than the report it was handed, which is R692's cross-engine statement
/// (candor-java's `crossDepJoin` gated on `effect == null` is the same shape one engine over).
///
/// THE CONTROL THAT SETTLED IT — one program, measured as ONE TREE, then split across a scan boundary.
/// The only variable is whether the dependency's sources sit inside the scanned tree; the consumer's bytes,
/// the binary and the policy are identical in both arms:
///
///     shape                                          ONE TREE          SPLIT + chained (pre-fix)
///     `extension Chan: Marker { }`, `c.poke()`       ['Env'] exit 1    ['Unknown'] exit 0
///     dep protocol-EXTENSION DEFAULT, `m.emit()`     ['Env'] exit 1    ['Unknown'] exit 0
///
/// The second row is the reason this suite is not named for the retroactive conformance the row was filed
/// from: **a consumer's own `struct Mine: Sink` reaching a dependency's protocol-extension default hits the
/// identical preemption**, and no retroactive conformance is involved. The audit boundary would have been
/// drawn around the trigger (brief §9) had only the first been fixtured.
///
/// `deny Env Unknown` DOES catch both pre-fix, so this is a gate flip on the permissive side rather than
/// total silence — a plain `deny Env` passed over a real environment read.
///
/// §1b: `CANDOR_R657_OFF=1` restores the preempting order, so the two defect arms can be SHOWN to fail
/// without a revert. The three control arms pass identically in both.
final class RetroactiveConformanceJoinProcessTests: XCTestCase {

    private struct Arm {
        var rows: [String: Set<String>]
        var why: [String: Set<String>]
        var present: Set<String>
        var depFns: [String]
        var gate: Int32
    }

    /// `chained: false` runs the consumer with NO `CANDOR_DEPS` at all — the arm where the external-super
    /// `Unknown` is the only honest answer there is, and the one this fix must leave untouched.
    private func run(depSource: String, appFiles: [String: String], deny: String, label: String,
                     chained: Bool = true, env extraEnv: [String: String] = [:]) throws -> Arm {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r657-\(label)-\(UUID().uuidString)")
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
        for (name, text) in appFiles { try write("app/Sources/App/\(name)", text) }
        try write("deny.policy", "\(deny)\n")

        let depDir = root.appendingPathComponent("depR")
        try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path,
                                              "--out", depDir.appendingPathComponent("r").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        let report = depDir.appendingPathComponent("r.RatesDep.Swift.json")
        let depDoc = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        let depFns = ((depDoc?["functions"] as? [[String: Any]]) ?? [])
            .map { ($0["fn"] as? String) ?? "?" }.sorted()
        for extra in try FileManager.default.contentsOfDirectory(atPath: depDir.path)
        where extra != report.lastPathComponent {
            try FileManager.default.removeItem(at: depDir.appendingPathComponent(extra))
        }

        var env = extraEnv
        if chained { env["CANDOR_DEPS"] = depDir.path }
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                             "--out", root.appendingPathComponent("ch").path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("ch.App.Swift.json"))) as? [String: Any]
        var rows: [String: Set<String>] = [:]
        var why: [String: Set<String>] = [:]
        var present: Set<String> = []
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            let name = (f["fn"] as? String) ?? "?"
            present.insert(name)
            rows[name] = Set((f["inferred"] as? [String]) ?? [])
            why[name] = Set((f["unknownWhy"] as? [String]) ?? [])
        }
        let g = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path,
                                             "--policy", root.appendingPathComponent("deny.policy").path,
                                             "--out", root.appendingPathComponent("g").path], env: env)
        return Arm(rows: rows, why: why, present: present, depFns: depFns, gate: g.code)
    }

    // MARK: - the two triggers

    /// The dependency owns `Chan` (whose `poke` reads the environment) and the marker protocol. The
    /// consumer writes ONE line — a retroactive conformance — and that line is the whole variable.
    private static let retroDep = """
    import Foundation
    public protocol Marker {}
    open class Chan {
        public init() {}
        open func poke() { _ = ProcessInfo.processInfo.environment["A"] }
    }
    """
    private static let retroCaller = """
    import RatesCore
    public func viaReceiver(_ c: Chan) { c.poke() }
    """
    private static let retroConformance = """
    import RatesCore
    extension Chan: Marker { }
    """

    func testARetroactiveConformanceDoesNotPreemptTheDependencysOwnRow() throws {
        let r = try run(depSource: Self.retroDep,
                        appFiles: ["a.swift": Self.retroCaller, "b.swift": Self.retroConformance],
                        deny: "deny Env", label: "retro")
        XCTAssertEqual(r.depFns, ["Chan.poke"],
                       "§E3 premise: the dependency really does publish the member this join must reach")
        XCTAssertEqual(r.rows["viaReceiver"], ["Env"],
                       "`c.poke()` reaches the dependency's `Chan.poke` (recorded Env). The consumer's own "
                       + "`extension Chan: Marker { }` must not trade that for `Unknown` — a local signal "
                       + "may not preempt the row the dependency published for this exact key")
        XCTAssertEqual(r.why["viaReceiver"] ?? [], [],
                       "and the `dispatch:Marker.poke` reason goes with it: the member is not unanalysable, "
                       + "a chained report analysed it")
        XCTAssertEqual(r.gate, 1, "GATE LEVEL — `deny Env` over a real environment read. Was exit 0")
    }

    /// THE SECOND TRIGGER, AND IT IS NOT A RETROACTIVE CONFORMANCE (brief §9 — do not draw the audit
    /// boundary around the trigger). The consumer's own `struct Mine: Sink` reaches the DEPENDENCY's
    /// protocol-extension default; `Mine` is local, so the ordinary §2 join's key (`RatesDep#Mine.emit`)
    /// cannot match anything. The key that CAN is the external supertype's — the very member this block
    /// was about to name in `dispatch:Sink.emit`.
    func testADependencyProtocolExtensionDefaultIsJoinedThroughTheSupertypeKey() throws {
        let r = try run(depSource: """
        import Foundation
        public protocol Sink {}
        extension Sink {
            public func emit() { _ = ProcessInfo.processInfo.environment["A"] }
        }
        """, appFiles: ["a.swift": """
        import RatesCore
        public struct Mine: Sink { public init() {} }
        public func viaDefault(_ m: Mine) { m.emit() }
        """], deny: "deny Env", label: "protoext")
        XCTAssertEqual(r.depFns, ["Sink.emit"], "§E3 premise: the default body is published")
        XCTAssertEqual(r.rows["viaDefault"], ["Env"])
        XCTAssertEqual(r.why["viaDefault"] ?? [], [])
        XCTAssertEqual(r.gate, 1, "GATE LEVEL — was exit 0")
    }

    // MARK: - the removal audit (this fix can only WITHDRAW an `Unknown`, so each arm asserts one is KEPT)

    /// **UNCHAINED, the arm the fallback exists for.** No `CANDOR_DEPS` at all: nothing published anything
    /// about `Chan.poke`, so `Unknown` + `dispatch:Marker.poke` is the honest answer and must survive
    /// byte for byte. If the reorder ever answers from something other than a chained report, this fails.
    func testControlUnchainedKeepsTheExternalSupertypeUnknown() throws {
        let r = try run(depSource: Self.retroDep,
                        appFiles: ["a.swift": Self.retroCaller, "b.swift": Self.retroConformance],
                        deny: "deny Env Unknown", label: "unchained", chained: false)
        XCTAssertEqual(r.rows["viaReceiver"], ["Unknown"],
                       "with no report chained there is nothing to join — the disclosure must stay")
        XCTAssertEqual(r.why["viaReceiver"], ["dispatch:Marker.poke"],
                       "and it must still say WHICH member it could not see")
        XCTAssertEqual(r.gate, 1, "`deny Env Unknown` catches the disclosed form")
    }

    /// **A KEY THE DEPENDENCY DOES NOT PUBLISH keeps the `Unknown`.** Same retroactive conformance, but
    /// `Chan.poke` is pure in the dependency, so no entry exists under `RatesDep#Chan.poke` and the join
    /// finds nothing. The dependency's report is NOT empty (`Chan.loud` is in it), so this arm
    /// distinguishes "the index was asked and missed" from "the index was never built".
    func testControlAMissingDependencyKeyKeepsTheUnknown() throws {
        let r = try run(depSource: """
        import Foundation
        public protocol Marker {}
        open class Chan {
            public init() {}
            open func poke() { }
            open func loud() { _ = ProcessInfo.processInfo.environment["A"] }
        }
        """, appFiles: ["a.swift": Self.retroCaller, "b.swift": Self.retroConformance],
                        deny: "deny Env Unknown", label: "misskey")
        XCTAssertEqual(r.depFns, ["Chan.loud"],
                       "§E3 premise: the dependency publishes SOMETHING, just not the key under test")
        XCTAssertEqual(r.rows["viaReceiver"], ["Unknown"],
                       "a miss must leave the pre-existing disclosure exactly as it was")
        XCTAssertEqual(r.why["viaReceiver"], ["dispatch:Marker.poke"])
    }

    /// **A LOCAL DECLARATION STILL WINS OUTRIGHT** (§E, the direction the fix must not move). The consumer
    /// declares its own `Chan` whose `poke` touches the filesystem while the dependency's `Chan.poke`
    /// reads the environment. If the new arm ever reached across the boundary over real project code this
    /// row reads `Env`, or both.
    func testControlALocalDeclarationIsNeverOverriddenByTheDependency() throws {
        let r = try run(depSource: Self.retroDep, appFiles: ["a.swift": """
        import Foundation
        import RatesCore
        public class Chan {
            public init() {}
            public func poke() { _ = FileManager.default.contents(atPath: "/tmp/x") }
        }
        extension Chan: Marker { }
        public func viaReceiver(_ c: Chan) { c.poke() }
        """], deny: "deny Env", label: "localwins")
        XCTAssertEqual(r.rows["viaReceiver"], ["Fs"],
                       "the project's own declaration is authoritative — never a guess over project code")
        XCTAssertEqual(r.gate, 0, "`deny Env` must NOT fire: nothing here reads the environment")
    }

    // MARK: - §1b the calibration

    /// The two defect arms above, re-run with the preempting order restored. Both must fail exactly as
    /// measured at HEAD before the fix, which is what makes them gates rather than comments.
    func testCalibrationTheKillswitchReproducesBothDefects() throws {
        let retro = try run(depSource: Self.retroDep,
                            appFiles: ["a.swift": Self.retroCaller, "b.swift": Self.retroConformance],
                            deny: "deny Env", label: "kill-retro", env: ["CANDOR_R657_OFF": "1"])
        XCTAssertEqual(retro.rows["viaReceiver"], ["Unknown"], "pre-fix: the Unknown replaced Env")
        XCTAssertEqual(retro.why["viaReceiver"], ["dispatch:Marker.poke"])
        XCTAssertEqual(retro.gate, 0, "pre-fix: `deny Env` passed over a real environment read")

        let dflt = try run(depSource: """
        import Foundation
        public protocol Sink {}
        extension Sink {
            public func emit() { _ = ProcessInfo.processInfo.environment["A"] }
        }
        """, appFiles: ["a.swift": """
        import RatesCore
        public struct Mine: Sink { public init() {} }
        public func viaDefault(_ m: Mine) { m.emit() }
        """], deny: "deny Env", label: "kill-protoext", env: ["CANDOR_R657_OFF": "1"])
        XCTAssertEqual(dflt.rows["viaDefault"], ["Unknown"], "pre-fix: the Unknown replaced Env")
        XCTAssertEqual(dflt.why["viaDefault"], ["dispatch:Sink.emit"])
        XCTAssertEqual(dflt.gate, 0, "pre-fix: `deny Env` passed")
    }
}
