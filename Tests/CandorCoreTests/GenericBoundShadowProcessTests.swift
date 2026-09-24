import XCTest
import Foundation

/// SOUNDNESS R580 — R563'S LOCAL-PROTOCOL FILTER RAN BEFORE THE SHADOWING PRECEDENCE, SO AN INNER BOUND
/// THAT IS NOT A LOCAL PROTOCOL COULD NOT DISPLACE THE ENCLOSING TYPE'S. A FABRICATION.
///
/// `protoBoundParams` merged the enclosing type's generic bounds and then the function's, applying
/// `where localProtocolNames.contains(b)` AS IT MERGED. A function bound that is not a local protocol
/// therefore never entered the map — and so could not overwrite the entry the enclosing type had put
/// there. **A filter that runs before a precedence silently reinstates whatever the precedence was there
/// to remove.**
///
///     struct Box<P: Pr> { func shadowByClass<P: Base>(_ t: P.Type) -> Int { P.make() } }
///
/// read `inferred ['Net']`, `dispatchesOn ['Sh3#Pr.make']`, `calls ['EffPr.make']` — while the fixture,
/// which `swift build`s and RUNS, prints `SUB`: it executes `Sub.make`, and `EffPr` is not on the path
/// at all. The caller was charged another abstraction's conformer AND published a wire key naming it.
///
/// ONE VARIABLE, and the three controls are what make that a defect rather than a design:
/// `shadowByProto` shadows with a bound that IS a local protocol, `shadowByEffProto` does the same with
/// an EFFECTFUL one (so the precedence is pinned in the positive direction, not merely as an erasure),
/// and `plain` does not shadow at all (R550's own shape, which must not regress).
///
/// THE ARM NAMES DO NOT SHARE A PREFIX ON PURPOSE. A policy scope matches by prefix, so with the
/// obvious names `deny Net Box.shadowed` was satisfied by `Box.shadowedEff` and the subject arm's gate
/// assertion could never have gone green — a control that cannot fail in the direction it is testing.
///
/// **THE A/B IS SAFETY-ONLY AND THAT IS WRITTEN DOWN RATHER THAN DISCOVERED LATER (§E1).** Over 7 real
/// Swift packages (alamofire, swift-nio, nio-http2, nio-ssl, swift-algorithms, swift-async-algorithms,
/// swift-argument-parser): `ADDED 0 REMOVED 0 CHANGED 0` with **0 reach hits** on the changed branch.
/// An independent SOURCE census — 1,027 `.swift` files, 46 generic functions declared inside generic
/// types — found **0** that shadow a type parameter's name, so the zero is a property of the SHAPE and
/// not of the corpus: generic-parameter shadowing is a warning in Swift 5 and an error in Swift 6
/// language mode. The evidence for this fix is the executing fixture, not the corpus.
///
/// **RESIDUAL, MEASURED AND NOT REPAIRED HERE:** with the fabrication gone, a generic parameter bound to
/// a local CLASS used as a TYPE receiver resolves to nothing — `Box<P: Pr>.shadowedClass<P: EffBase>`
/// over an effectful `EffBase` subclass is silent, while the CONCRETE spelling of the same call
/// (`EffBase.make()`) resolves to `[Net]`. That silence is PRE-EXISTING, not introduced here: before the
/// fix the same row read `[]` too, with the wrong protocol's key attached. Filed separately; R580 is the
/// fabrication, and fixing one is not licence to assert the other away.
final class GenericBoundShadowProcessTests: XCTestCase {

    private func binaryURL() throws -> URL {
        try ProcessHarness.binaryURL(for: GenericBoundShadowProcessTests.self)
    }

    private func run(_ binary: URL, _ args: [String]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT",
                  "CANDOR_WORKSPACE_CHAIN"] {
            environment.removeValue(forKey: k)
        }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let exited = ProcessHarness.exitLatch(p)
        try p.run()
        let outData = ProcessHarness.drain(outPipe)
        let errData = ProcessHarness.drain(errPipe)
        exited.wait()
        return (String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self),
                p.terminationStatus)
    }

    private static let SINK = "_ = URLSession.shared.dataTask(with: URL(string: \"http://h\")!)"

    /// Verbatim from the executable package, minus its top-level driver. Every arm runs and prints:
    /// `SUB`, `PR2`, `SINK EffPrEff`, `SINK EffPr`, `RAN`.
    private static var source: String {
        """
        import Foundation
        public func sink(_ tag: String) -> Int { \(SINK); return 1 }

        public protocol Pr { static func make() -> Int }
        public struct EffPr: Pr { public static func make() -> Int { return sink("EffPr") } }

        public protocol Pr2 { static func make() -> Int }
        public struct PurePr2: Pr2 { public static func make() -> Int { return 0 } }

        public protocol PrEff { static func make() -> Int }
        public struct EffPrEff: PrEff { public static func make() -> Int { return sink("EffPrEff") } }

        public class Base { public class func make() -> Int { return 0 } }
        public final class Sub: Base { public override class func make() -> Int { return 0 } }

        public struct Box<P: Pr> {
            public init() {}
            public func shadowByClass<P: Base>(_ t: P.Type) -> Int { return P.make() }
            public func shadowByProto<P: Pr2>(_ t: P.Type) -> Int { return P.make() }
            public func shadowByEffProto<P: PrEff>(_ t: P.Type) -> Int { return P.make() }
            public func plain() -> Int { return P.make() }
        }
        """
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func scan() throws -> ([String: [String: Any]], URL) {
        let bin = try binaryURL()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r580-\(UUID().uuidString)")
        try write(root.appendingPathComponent("Package.swift"), """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Solo", products: [.library(name: "Solo", targets: ["Solo"])],
            targets: [.target(name: "Solo")])
        """)
        try write(root.appendingPathComponent("Sources/Solo/shadow.swift"), Self.source)
        let r = try run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertEqual(r.code, 0, "scan must succeed; stderr: \(r.err)")
        let doc = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.Solo.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (doc?["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { by[n] = f }
        }
        return (by, root)
    }

    private func eff(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set(by[fn]?["inferred"] as? [String] ?? [])
    }
    private func keys(_ by: [String: [String: Any]], _ fn: String) -> Set<String> {
        Set(by[fn]?["dispatchesOn"] as? [String] ?? [])
    }
    private func gate(_ root: URL, _ policy: String) throws -> Int32 {
        let bin = try binaryURL()
        let p = root.appendingPathComponent("p.policy")
        try write(p, policy + "\n")
        return try run(bin, [root.path, "--out", root.appendingPathComponent("g").path,
                             "--policy", p.path]).code
    }

    // ── THE DEFECT ──────────────────────────────────────────────────────────────────────────────

    /// The shadowed arm must not be charged the ENCLOSING type's bound, on either channel: not the
    /// effect and not the wire key. Ground truth is the running fixture — `shadowByClass(Sub.self)` prints
    /// `SUB`, so nothing on that path reaches `URLSession`.
    func testAnInnerBoundThatIsNotALocalProtocolDisplacesTheEnclosingTypes() throws {
        let (by, root) = try scan()
        XCTAssertFalse(eff(by, "Box.shadowByClass").contains("Net"),
                       "Box.shadowByClass runs Sub.make and reaches nothing; got \(eff(by, "Box.shadowByClass"))")
        XCTAssertFalse(keys(by, "Box.shadowByClass").contains("Solo#Pr.make"),
                       "Box.shadowByClass must not publish the SHADOWED bound's wire key; got \(keys(by, "Box.shadowByClass"))")
        XCTAssertEqual(try gate(root, "deny Net Box.shadowByClass"), 0,
                       "`deny Net Box.shadowByClass` must be green — EffPr is not on this path")
    }

    // ── THE CONTROLS ────────────────────────────────────────────────────────────────────────────

    /// One variable: whether the inner bound is a local protocol. `shadowByProto` shadows with `Pr2`, whose
    /// conformer is pure, and must resolve to it — the fix must displace the outer bound, not delete
    /// every shadowed entry.
    func testAShadowingBoundThatIsALocalProtocolStillResolves() throws {
        let (by, _) = try scan()
        XCTAssertTrue(keys(by, "Box.shadowByProto").contains("Solo#Pr2.make"),
                      "Box.shadowByProto must publish its OWN bound's key; got \(keys(by, "Box.shadowByProto"))")
        XCTAssertTrue(Set(by["Box.shadowByProto"]?["calls"] as? [String] ?? []).contains("PurePr2.make"),
                      "Box.shadowByProto must resolve PurePr2.make")
        XCTAssertFalse(keys(by, "Box.shadowByProto").contains("Solo#Pr.make"),
                       "…and must NOT also carry the enclosing type's bound")
    }

    /// THE PRECEDENCE IN THE POSITIVE DIRECTION, which an erasure would pass by accident: the inner
    /// bound's conformer is the EFFECTFUL one and the outer bound's is not on the path.
    func testTheFunctionsOwnBoundWinsAndCarriesItsEffect() throws {
        let (by, root) = try scan()
        XCTAssertEqual(eff(by, "Box.shadowByEffProto"), ["Net"],
                       "Box.shadowByEffProto runs EffPrEff.make, which reaches URLSession; got \(eff(by, "Box.shadowByEffProto"))")
        XCTAssertTrue(keys(by, "Box.shadowByEffProto").contains("Solo#PrEff.make"),
                      "…under its own bound's key; got \(keys(by, "Box.shadowByEffProto"))")
        XCTAssertEqual(try gate(root, "deny Net Box.shadowByEffProto"), 1, "`deny Net Box.shadowByEffProto` must catch it")
    }

    /// R550/R563 MUST NOT REGRESS: with no shadowing, the enclosing type's bound is still the answer.
    /// This is the arm a fix that simply dropped type-level bounds would have broken.
    func testTheEnclosingTypesBoundIsUnchangedWithoutShadowing() throws {
        let (by, root) = try scan()
        XCTAssertEqual(eff(by, "Box.plain"), ["Net"],
                       "Box.plain dispatches Pr over EffPr; got \(eff(by, "Box.plain"))")
        XCTAssertTrue(keys(by, "Box.plain").contains("Solo#Pr.make"),
                      "Box.plain must still publish Solo#Pr.make; got \(keys(by, "Box.plain"))")
        XCTAssertEqual(try gate(root, "deny Net Box.plain"), 1, "`deny Net Box.plain` must catch it")
    }
}
