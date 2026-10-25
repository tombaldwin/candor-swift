import XCTest
import Foundation

/// CALL-TARGET ROUND 1 (SOUNDNESS R1415, R1416, R1310) — pinned on the shapes the exhaustive matrix
/// (`tools/calltarget/`) measured SILENT on the published 0.40.16 binary, every one EXECUTED there.
///
/// R1416 / R1310 — the PRODUCER half of ⟨0.39⟩ obligation 1 for an `open` class member (and a local protocol's
///   formatting member): `dispFn(_ b: Base) { b.m() }` over a pure `Base.m` was ABSENT from the library's
///   report, so a chained consumer passing its own effectful subclass read pure. The row is now present,
///   effect-free, naming `Lib#Base.m`, and the consumer's existing join charges its own override.
/// R1415 — the CONSUMER half for implicit hooks: an operator, a subscript, a literal's `init`, an iteration,
///   a comparison witness over a DEPENDENCY's type recorded nothing; they now ask the dependency's report
///   through the one external-member channel.
///
/// Each defect arm has its control: the decoy (a pure type of the same shape) stays absent, and the kill
/// switches `CANDOR_R1415_OFF` / `CANDOR_R1416_OFF` restore the release's answer on the same binary.
final class CallTargetRound1ProcessTests: XCTestCase {

    private static let SINK = "_ = FileManager.default.createFile(atPath: \"/tmp/x\", contents: nil)"

    private func run(_ bin: URL, _ args: [String], env: [String: String]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE", "CANDOR_REPORT",
                  "CANDOR_WORKSPACE_CHAIN", "CANDOR_R1415_OFF", "CANDOR_R1416_OFF"] { e.removeValue(forKey: k) }
        for (k, v) in env { e[k] = v }
        p.environment = e
        let o = Pipe(), r = Pipe()
        p.standardOutput = o; p.standardError = r
        let exited = ProcessHarness.exitLatch(p)
        try p.run()
        let od = ProcessHarness.drain(o), ed = ProcessHarness.drain(r)
        exited.wait()
        return (String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self), p.terminationStatus)
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fns(_ url: URL) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] { if let n = f["fn"] as? String { out[n] = f } }
        return out
    }

    private static let LIB = """
    import Foundation
    open class Base { public init() {}
      open func m() { }
      open var v: Int { return 0 }
      open subscript(i: Int) -> Int { return i }
      public func tmpl() { m() } }
    public func dispFn(_ b: Base) { b.m() }
    public func dispProp(_ b: Base) -> Int { return b.v }
    public func dispSub(_ b: Base) -> Int { return b[0] }
    public func dispTmpl(_ b: Base) { b.tmpl() }
    public protocol Conv: CustomStringConvertible { }
    public func dispFmt(_ c: any Conv) -> String { return "\\(c)" }
    public func dispDesc(_ c: any Conv) -> String { return c.description }
    public struct Eq: Equatable { public init() {}
      public static func == (a: Eq, b: Eq) -> Bool { \(SINK); return true } }
    public struct Quiet: Equatable { public init() {}
      public static func == (a: Quiet, b: Quiet) -> Bool { return true } }
    public struct Sub { public init() {}
      public subscript(i: Int) -> Int { \(SINK); return i } }
    public struct Lit: ExpressibleByStringLiteral { public init(stringLiteral v: String) { \(SINK) } }
    public struct Seq: Sequence, IteratorProtocol { var n = 0; public init() {}
      public mutating func next() -> Int? { \(SINK); n += 1; return n > 1 ? nil : n } }
    public struct Ord: Comparable { public let k: Int; public init(_ k: Int) { self.k = k }
      public static func < (a: Ord, b: Ord) -> Bool { \(SINK); return a.k < b.k } }
    """

    private static let APP = """
    import Foundation
    import Lib
    final class Mine: Base {
      override func m() { \(SINK) }
      override var v: Int { \(SINK); return 1 }
      override subscript(i: Int) -> Int { \(SINK); return i } }
    struct MyConv: Conv { var description: String { \(SINK); return "d" } }
    func viaMethod() { dispFn(Mine()) }
    func viaProp() -> Int { return dispProp(Mine()) }
    func viaSub() -> Int { return dispSub(Mine()) }
    func viaTmpl() { dispTmpl(Mine()) }
    func viaFmt() -> String { return dispFmt(MyConv()) }
    func viaDesc() -> String { return dispDesc(MyConv()) }
    func eqOp() -> Bool { return Eq() == Eq() }
    func neqOp() -> Bool { return Eq() != Eq() }
    func quietOp() -> Bool { return Quiet() == Quiet() }
    func subOp() -> Int { return Sub()[0] }
    func litInit() { let x: Lit = "s"; _ = x }
    func forIn() { for _ in Seq() { } }
    func sortedOp() -> [Ord] { return [Ord(2), Ord(1)].sorted() }
    """

    /// (lib report, app report) for one arm. `env` goes to BOTH scans (a kill switch is a whole-engine control).
    private func arm(_ env: [String: String]) throws -> ([String: [String: Any]], [String: [String: Any]]) {
        let bin = try ProcessHarness.binaryURL(for: CallTargetRound1ProcessTests.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-ct1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("lib/Package.swift"), """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Lib", products: [.library(name: "Lib", targets: ["Lib"])],
            targets: [.target(name: "Lib")])
        """)
        try write(root.appendingPathComponent("lib/Sources/Lib/lib.swift"), Self.LIB)
        try write(root.appendingPathComponent("app/Package.swift"), """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../lib")],
            targets: [.target(name: "App", dependencies: [.product(name: "Lib", package: "lib")])])
        """)
        try write(root.appendingPathComponent("app/Sources/App/app.swift"), Self.APP)
        let lr = try run(bin, [root.appendingPathComponent("lib").path, "--out", root.appendingPathComponent("dep").path], env: env)
        XCTAssertEqual(lr.code, 0, "library scan must succeed; stderr: \(lr.err)")
        let rep = root.appendingPathComponent("dep.Lib.Swift.json")
        var e = env; e["CANDOR_DEPS"] = rep.path
        let ar = try run(bin, [root.appendingPathComponent("app").path, "--out", root.appendingPathComponent("out").path], env: e)
        XCTAssertEqual(ar.code, 0, "consumer scan must succeed; stderr: \(ar.err)")
        return (try fns(rep), try fns(root.appendingPathComponent("out.App.Swift.json")))
    }

    private func inferred(_ by: [String: [String: Any]], _ fn: String) -> [String] { by[fn]?["inferred"] as? [String] ?? [] }

    private let charged = ["viaMethod", "viaProp", "viaSub", "viaTmpl", "viaFmt", "viaDesc",
                           "eqOp", "neqOp", "subOp", "litInit", "forIn", "sortedOp"]

    func testProducerNamesOpenClassMembersAndTheConsumerChargesItsOverride() throws {
        let (lib, app) = try arm([:])
        let want = ["dispFn": "Lib#Base.m", "dispProp": "Lib#Base.v", "dispSub": "Lib#Base.subscript",
                    "dispTmpl": "Lib#Base.m", "dispFmt": "Lib#Conv.description", "dispDesc": "Lib#Conv.description"]
        for (fn, key) in want {
            XCTAssertEqual(inferred(lib, fn), [], "\(fn): the producer sees only the pure base body")
            XCTAssertTrue((lib[fn]?["dispatchesOn"] as? [String] ?? []).contains(key),
                          "\(fn): ⟨0.39⟩ obligation 1 names \(key) on the otherwise-pure row; got \(String(describing: lib[fn]))")
        }
        for fn in charged {
            XCTAssertTrue(inferred(app, fn).contains("Fs"), "\(fn): the executed effect must be charged chained; got \(inferred(app, fn))")
        }
        // the decoy: a dependency type whose `==` is pure is absent from the dependency's report, so nothing joins
        XCTAssertNil(app["quietOp"], "a pure dependency witness must contribute nothing")
        for (fn, e) in app {
            XCTAssertFalse((e["inferred"] as? [String] ?? []).contains("Unknown"), "\(fn): the round adds no hedge")
        }
    }

    func testKillSwitchesRestoreTheReleaseAnswer() throws {
        let (lib, app) = try arm(["CANDOR_R1415_OFF": "1", "CANDOR_R1416_OFF": "1"])
        for fn in ["dispFn", "dispProp", "dispSub", "dispTmpl"] {
            XCTAssertNil(lib[fn], "\(fn): with R1416 off the release published nothing")
        }
        for fn in ["viaMethod", "viaProp", "viaSub", "viaTmpl", "eqOp", "neqOp", "subOp", "litInit", "forIn", "sortedOp"] {
            XCTAssertFalse(inferred(app, fn).contains("Fs"), "\(fn): the release read this pure — the control must reproduce it")
        }
    }
}
