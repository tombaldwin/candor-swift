import XCTest
import Foundation

/// SOUNDNESS R1485 — A PLATFORM CLASS INHERITS WHAT THIS SCAN GIVES `NSObject`. RxSwift's own spelling is
/// `extension NSObject: ReactiveCompatible {}` with `extension ReactiveCompatible { var rx: Reactive<Self> }`, and every
/// RxCocoa member reaches its shared helper as `base.rx.controlProperty…(…)` on a UIKit/AppKit/Foundation class. Those
/// classes are imported from Objective-C, so no supertype was recorded for them and the `rx` hop, and every call behind
/// it, was dropped — silent. Every program below was EXECUTED on macOS (the runner deletes the marker, calls one
/// function, then checks the marker):
///
///     zzNoParam zzDirect zzCtor zzRoot zzDeep zzBound zzLocalSub s1…s6 s8  -> /tmp/b2x-cpd created
///     zzPure ctlPure k1 k2                                                 -> none
///     (chained) cPlat cSibM cSibRc cRoot                                   -> created;  cPure -> none
///
/// The CONTROLS were written first: a pure member reached the same way (`pureRx`, `sibPureNs`), a stdlib Swift value
/// type whose NATIVE `count` shares a name with an `NSObject` extension member (`[Int]`, `Data`, `String` — not
/// `NSObject`s, so never reached), and a package that does NOT extend `NSObject`, where a platform class's own
/// `string(from:)` must not reach a local protocol extension's same-named member.
final class PlatformClassObjcRootProcessTests: XCTestCase {

    static let rx = """
    import Foundation
    public struct Reactive<Base> { public let base: Base; public init(_ base: Base) { self.base = base } }
    public protocol ReactiveCompatible {
      associatedtype ReactiveBase
      static var rx: Reactive<ReactiveBase>.Type { get set }
      var rx: Reactive<ReactiveBase> { get set }
    }
    extension ReactiveCompatible {
      public static var rx: Reactive<Self>.Type { get { Reactive<Self>.self } set {} }
      public var rx: Reactive<Self> { get { Reactive(self) } set {} }
    }
    extension NSObject: ReactiveCompatible {}
    func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/b2x-" + s, contents: nil) }
    extension Reactive where Base: NSObject {
      public func effCPD<T>(getter: @escaping (Base) -> T, setter: @escaping (Base, T) -> Void) -> Int { mark("cpd"); return 0 }
      public func pureRx() -> Int { 1 }
    }
    extension Reactive where Base: NumberFormatter {
      public var zzNoParam: Int { base.rx.effCPD(getter: { p in p.zeroSymbol ?? "" }, setter: { p, v in p.zeroSymbol = v }) }
      public var zzPure: Int { base.rx.pureRx() }
    }
    public func zzDirect(_ n: NumberFormatter) -> Int { n.rx.effCPD(getter: { _ in 0 }, setter: { _, _ in }) }
    public func zzCtor() -> Int { NumberFormatter().rx.effCPD(getter: { _ in 0 }, setter: { _, _ in }) }
    public func zzRoot() -> Int { NSObject().rx.effCPD(getter: { _ in 0 }, setter: { _, _ in }) }
    public func zzDeep(_ n: DateFormatter) -> Int { n.rx.effCPD(getter: { _ in 0 }, setter: { _, _ in }) }
    public func zzBound<B: NumberFormatter>(_ n: B) -> Int { n.rx.effCPD(getter: { _ in 0 }, setter: { _, _ in }) }
    public func zzLocalSub(_ n: Mine) -> Int { n.rx.effCPD(getter: { _ in 0 }, setter: { _, _ in }) }
    public final class Mine: NSObject {}
    public func ctlPure(_ n: NumberFormatter) -> Int { n.rx.pureRx() }
    """
    static let sib = """
    import Foundation
    func markS(_ s: String) { FileManager.default.createFile(atPath: "/tmp/b2x-" + s, contents: nil) }
    extension NSObject {
      public func sibNsM() { markS("cpd") }
      public var sibNsP: Int { markS("cpd"); return 0 }
      public static func sibNsS() { markS("cpd") }
      @objc public var sibPureNs: Int { 2 }
    }
    extension ReactiveCompatible {
      public func sibRcM() { markS("cpd") }
      public var sibRcP: Int { markS("cpd"); return 0 }
    }
    public func s1(_ n: NumberFormatter) { n.sibNsM() }
    public func s2(_ n: NumberFormatter) -> Int { n.sibNsP }
    public func s3(_ n: NumberFormatter) { n.sibRcM() }
    public func s4(_ n: NumberFormatter) -> Int { n.sibRcP }
    public func s5() { NumberFormatter.sibNsS() }
    public func s6(_ n: DateFormatter) { n.rx.base.sibNsM() }
    public func s8(_ ns: [NumberFormatter]) { ns.forEach { $0.sibNsM() } }
    public func k1(_ n: NumberFormatter) -> Int { n.sibPureNs }
    extension NSObject { public var count: Int { markS("cpd"); return 0 } }
    public func k2(_ a: [Int], _ d: Data, _ s: String) -> Int { a.count + d.count + s.count }
    """
    static let charged = ["Reactive.zzNoParam", "zzDirect", "zzCtor", "zzRoot", "zzDeep", "zzBound", "zzLocalSub",
                          "s1", "s2", "s3", "s4", "s5", "s6", "s8"]
    /// Silent before this change (published 0.41.3 and 1d351eb): every charged row but the two that resolved already.
    static let wasSilent = charged.filter { $0 != "zzRoot" && $0 != "zzLocalSub" }
    static let pure = ["Reactive.zzPure", "ctlPure", "k1", "k2"]

    private func pkg() throws -> URL {
        try ProcessHarness.makeFilesPackage(["Rx.swift": Self.rx, "Sib.swift": Self.sib, "main.swift": "print(0)\n"])
    }
    private func scan(_ root: URL, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }
    private func gate(_ root: URL, _ rule: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = root.appendingPathComponent("policy.candor")
        try "\(rule)\n".write(to: pol, atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("gate-out").path
        return try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", out], env: env).code
    }

    func testAPlatformClassReachesWhatThisScanGivesNSObject() throws {
        let root = try pkg(); defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in Self.charged {
            XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) writes the marker (executed) — \(by[fn] ?? [:])")
        }
        for fn in Self.pure {
            XCTAssertFalse(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) is pure (executed: no marker) — \(by[fn] ?? [:])")
        }
    }

    /// The gate at the CALLER flips 0 -> 1, and the kill switch shows the row able to fail.
    func testTheGateFlipsAtTheCallerAndTheKillSwitchRestoresTheSilence() throws {
        let root = try pkg(); defer { try? FileManager.default.removeItem(at: root) }
        for fn in ["zzDirect", "Reactive.zzNoParam", "s1", "s3"] {
            XCTAssertEqual(try gate(root, "deny Fs \(fn)"), 1, "\(fn): deny Fs must fail over an executed file write")
            XCTAssertEqual(try gate(root, "deny Fs \(fn)", env: ["CANDOR_R1485_OFF": "1"]), 0, "\(fn): the release was silent")
        }
        let off = try scan(root, env: ["CANDOR_R1485_OFF": "1"])
        for fn in Self.wasSilent {
            XCTAssertNil(ProcessHarness.inferred(off, fn), "\(fn) under CANDOR_R1485_OFF — the release's silence: \(off[fn] ?? [:])")
        }
    }

    /// No `NSObject` extension here: a platform class's own `string(from:)` never reaches a local protocol extension
    /// member of the same name (executed: no marker), while a local conformer does (executed: marker).
    func testWithoutAnNSObjectExtensionNothingIsInherited() throws {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        public protocol RC {}
        extension RC { public func string(from n: NSNumber) -> String? { FileManager.default.createFile(atPath: "/tmp/k3x", contents: nil); return nil } }
        public final class Plain: RC {}
        func k3noRoot(_ f: NumberFormatter) -> String? { f.string(from: 1) }
        func k3plain(_ p: Plain) -> String? { p.string(from: 1) }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        XCTAssertNil(ProcessHarness.inferred(by, "k3noRoot"), "\(by["k3noRoot"] ?? [:])")
        XCTAssertEqual(ProcessHarness.inferred(by, "k3plain"), ["Fs"])
    }

    /// ACROSS THE SCAN BOUNDARY: the dependency extends `NSObject`; the consumer calls on a platform class.
    func testAChainedConsumerReachesTheDependencysNSObjectMember() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-swift-r1485-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("dep/Sources/RxLike"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("app/Sources/App"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "dep", products: [.library(name: "RxLike", targets: ["RxLike"])], targets: [.target(name: "RxLike")])
        """.write(to: root.appendingPathComponent("dep/Package.swift"), atomically: true, encoding: .utf8)
        try Self.rx.write(to: root.appendingPathComponent("dep/Sources/RxLike/Rx.swift"), atomically: true, encoding: .utf8)
        try Self.sib.write(to: root.appendingPathComponent("dep/Sources/RxLike/Sib.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "app", dependencies: [.package(path: "../dep")], targets: [
          .executableTarget(name: "App", dependencies: [.product(name: "RxLike", package: "dep")])])
        """.write(to: root.appendingPathComponent("app/Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import RxLike
        func cSibM(_ n: NumberFormatter) { n.sibNsM() }
        func cPlat(_ n: NumberFormatter) -> Int { n.rx.effCPD(getter: { _ in 0 }, setter: { _, _ in }) }
        """.write(to: root.appendingPathComponent("app/Sources/App/main.swift"), atomically: true, encoding: .utf8)
        let d = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path, "--out", root.appendingPathComponent("rep").path])
        XCTAssertEqual(d.code, 0, d.err)
        let rep = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("rep.") && $0.hasSuffix(".json")
            && !$0.contains("callgraph") && !$0.contains("hierarchy") }.map { root.appendingPathComponent($0).path }
        XCTAssertEqual(rep.count, 1)
        let on = try ProcessHarness.fns(ofJson: try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--json"],
                                                                       env: ["CANDOR_DEPS": rep.joined(separator: " ")]).out)
        let off = try ProcessHarness.fns(ofJson: try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--json"],
                                                                        env: ["CANDOR_DEPS": rep.joined(separator: " "), "CANDOR_R1485_OFF": "1"]).out)
        XCTAssertEqual(ProcessHarness.inferred(on, "cSibM"), ["Fs"], "\(on["cSibM"] ?? [:])")
        XCTAssertFalse(ProcessHarness.inferred(off, "cSibM")?.contains("Fs") == true, "the release was silent: \(off["cSibM"] ?? [:])")
        // The `rx` hop across the boundary is DISCLOSED (not resolved) on both arms: the producer publishes no
        // retroactive conformance on a platform type (`typeSurface.adds` carries foreign keys only).
        XCTAssertTrue(ProcessHarness.inferred(on, "cPlat")?.contains("Unknown") == true, "\(on["cPlat"] ?? [:])")
    }
}
