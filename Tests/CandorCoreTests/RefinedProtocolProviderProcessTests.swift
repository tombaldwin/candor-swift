import XCTest
import Foundation

/// SOUNDNESS R1486 — A CONCRETE TYPE IS PROVIDED WHAT ITS PROTOCOLS' REFINED PROTOCOLS' EXTENSIONS DECLARE.
/// `struct NSa: NP` with `protocol NP: SP` and `extension SP { var parent … }`: Swift runs `SP.parent` for `s.parent`,
/// but `supertypesOf` holds only the protocols a type SPELLS (protocol inheritance is kept out of the conformer index
/// on purpose, R1109), so the read was ABSENT — silent over an executed file write — while the METHOD twin was hedged
/// `dispatch:NP.parentM` only because `NP` happened not to be extended. And a read of a DEPENDENCY protocol's extension
/// property never asked the dependency at all (`xpd`), where the method twin joined it. Every program below was
/// EXECUTED (marker written: pa pb pc ma mb, and chained xpa xma xpd xmd; none: pureRefined, xpure).
final class RefinedProtocolProviderProcessTests: XCTestCase {

    static let local = """
    import Foundation
    public protocol SP { }
    extension SP { public var parent: Int? { FileManager.default.createFile(atPath: "/tmp/r1481-c", contents: nil); return nil }
                   public func parentM() -> Int? { FileManager.default.createFile(atPath: "/tmp/r1481-c", contents: nil); return nil }
                   public var pureRefined: Int { 4 }
                   public func pureM() -> Int { 4 } }
    public protocol NP: SP {}
    public struct NSa: NP {}
    public struct NSb: NP, Hashable {}
    public struct NSc: SP, Hashable {}
    func useA(_ s: NSa) -> Int? { s.parent }
    func useB(_ s: NSb) -> Int? { s.parent }
    func useC(_ s: NSc) -> Int? { s.parent }
    func callA(_ s: NSa) -> Int? { s.parentM() }
    func callB(_ s: NSb) -> Int? { s.parentM() }
    func purePa(_ s: NSa) -> Int { s.pureRefined }
    func purePM(_ s: NSa) -> Int { s.pureM() }
    """

    private func scan(_ root: URL, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    func testARefinedProtocolsExtensionMemberIsReachedFromAConcreteReceiver() throws {
        let root = try ProcessHarness.makePackage(Self.local)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in ["useA", "useB", "useC"] {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes the marker (executed) — \(by[fn] ?? [:])")
        }
        // The METHOD arm edges the refined provider and RESOLVES, as the property arm does: the release's wrong-reason
        // `dispatch:NP.parentM` hedge is gone (R1486 method path; `CANDOR_R1486_HEDGE=1` restores it).
        for fn in ["callA", "callB"] {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) — \(by[fn] ?? [:])")
        }
        XCTAssertNil(ProcessHarness.inferred(by, "purePa"), "a pure refined-protocol property stays pure — \(by["purePa"] ?? [:])")
        XCTAssertNil(ProcessHarness.inferred(by, "purePM"), "a pure refined-protocol method resolves pure — \(by["purePM"] ?? [:])")
        let kept = try scan(root, env: ["CANDOR_R1486_HEDGE": "1"])
        XCTAssertEqual(ProcessHarness.inferred(kept, "callA"), ["Fs", "Unknown"], "the kept hedge: \(kept["callA"] ?? [:])")
        XCTAssertEqual(ProcessHarness.inferred(kept, "purePM"), ["Unknown"], "the kept hedge: \(kept["purePM"] ?? [:])")
        // The gate at the caller, and the kill switch: the property reads were ABSENT, the methods hedged only.
        let off = try scan(root, env: ["CANDOR_R1486_OFF": "1"])
        XCTAssertNil(ProcessHarness.inferred(off, "useA"), "the release was silent: \(off["useA"] ?? [:])")
        XCTAssertNil(ProcessHarness.inferred(off, "useB"), "the release was silent: \(off["useB"] ?? [:])")
        XCTAssertEqual(ProcessHarness.inferred(off, "callA"), ["Unknown"], "the release hedged the method: \(off["callA"] ?? [:])")
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = root.appendingPathComponent("policy.candor")
        try "deny Fs useA\n".write(to: pol, atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("g").path
        XCTAssertEqual(try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", out]).code, 1)
        XCTAssertEqual(try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", out], env: ["CANDOR_R1486_OFF": "1"]).code, 0)
        // A RESOLUTION, at the caller: `deny Unknown purePM` went 1 -> 0 (the body is pure); `deny Fs callA` stays 1.
        try "deny Unknown purePM\n".write(to: pol, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", out]).code, 0)
        XCTAssertEqual(try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", out], env: ["CANDOR_R1486_HEDGE": "1"]).code, 1)
        try "deny Fs callA\n".write(to: pol, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", out]).code, 1)
    }

    /// ACROSS THE SCAN BOUNDARY: the provided member lives in a CHAINED package's protocol extension.
    func testAPropertyAsksTheChainedDependencyAsTheMethodDoes() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-swift-r1486-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("dep/Sources/DL"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("app/Sources/App"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "dep", products: [.library(name: "DL", targets: ["DL"])], targets: [.target(name: "DL")])
        """.write(to: root.appendingPathComponent("dep/Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public protocol ExtP {}
        extension ExtP {
          public var xParent: Int? { FileManager.default.createFile(atPath: "/tmp/d2x", contents: nil); return nil }
          public func xParentM() -> Int? { FileManager.default.createFile(atPath: "/tmp/d2x", contents: nil); return nil }
          public var xPure: Int { 3 }
        }
        """.write(to: root.appendingPathComponent("dep/Sources/DL/DL.swift"), atomically: true, encoding: .utf8)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "app", dependencies: [.package(path: "../dep")], targets: [
          .executableTarget(name: "App", dependencies: [.product(name: "DL", package: "dep")])])
        """.write(to: root.appendingPathComponent("app/Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import DL
        protocol NP: ExtP {}
        struct NSa: NP {}
        struct Direct: ExtP {}
        func xpa(_ s: NSa) -> Int? { s.xParent }
        func xma(_ s: NSa) -> Int? { s.xParentM() }
        func xpd(_ s: Direct) -> Int? { s.xParent }
        func xmd(_ s: Direct) -> Int? { s.xParentM() }
        func xpure(_ s: NSa) -> Int { s.xPure }
        """.write(to: root.appendingPathComponent("app/Sources/App/main.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path, "--out", root.appendingPathComponent("rep").path]).code, 0)
        let rep = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("rep.") && $0.hasSuffix(".json")
            && !$0.contains("callgraph") && !$0.contains("hierarchy") }.map { root.appendingPathComponent($0).path }
        let env = ["CANDOR_DEPS": rep.joined(separator: " ")]
        let on = try ProcessHarness.fns(ofJson: try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--json"], env: env).out)
        var offEnv = env; offEnv["CANDOR_R1486_OFF"] = "1"
        let off = try ProcessHarness.fns(ofJson: try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--json"], env: offEnv).out)
        for fn in ["xpa", "xpd", "xmd"] {
            XCTAssertEqual(ProcessHarness.inferred(on, fn), ["Fs"], "\(fn) writes the marker (executed) — \(on[fn] ?? [:])")
        }
        XCTAssertEqual(ProcessHarness.inferred(on, "xma"), ["Fs", "Unknown"], "the method keeps its hedge — \(on["xma"] ?? [:])")
        XCTAssertNil(ProcessHarness.inferred(on, "xpure"), "\(on["xpure"] ?? [:])")
        XCTAssertNil(ProcessHarness.inferred(off, "xpa"), "the release was silent: \(off["xpa"] ?? [:])")
        XCTAssertNil(ProcessHarness.inferred(off, "xpd"), "the release was silent: \(off["xpd"] ?? [:])")
        XCTAssertEqual(ProcessHarness.inferred(off, "xma"), ["Unknown"], "the release hedged the method: \(off["xma"] ?? [:])")
    }
}

/// CONTROL for the refined climb: a STORED field shadows a refined protocol's extension property of the same name
/// (RxSwift `ControlProperty.values` vs `extension ObservableConvertibleType { var values }`). Executed: no marker.
final class RefinedProtocolProviderStoredFieldControlTests: XCTestCase {
    func testAStoredFieldIsNotTheRefinedProtocolsExtensionMember() throws {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        public protocol OCT { }
        extension OCT { public var values: Int { FileManager.default.createFile(atPath: "/tmp/r1486-sf", contents: nil); return 0 } }
        public protocol OT: OCT {}
        public struct CP: OT { let values: Int = 3; public func asObs() -> Int { values }; public func asObs2() -> Int { self.values } }
        func reader(_ c: CP) -> Int { c.values }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let by = try ProcessHarness.fns(ofJson: try ProcessHarness.run(bin, [root.path, "--json"]).out)
        for fn in ["CP.asObs", "CP.asObs2", "reader"] {
            XCTAssertNil(ProcessHarness.inferred(by, fn), "\(fn) reads the stored field — \(by[fn] ?? [:])")
        }
    }
}
