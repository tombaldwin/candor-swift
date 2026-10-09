import XCTest
import Foundation

/// SOUNDNESS R1071 (residual) — AN EXTENSION OF A PLATFORM PROTOCOL, CALLED ON A STANDARD-LIBRARY RECEIVER.
/// `extension Sequence { public func stampAll() /* writes */ }` with `func midSeq(_ a: [Int]) { a.stampAll() }` read
/// ABSENT — standalone, chained on the dependency's report (which carries `Sequence.stampAll` `['Fs']`), and one
/// package further downstream — while the built program wrote the file (executed, `swiftagent-v045/fx/r1071`). The
/// same shape inside ONE package was absent too: nothing knew that `Array` is a `Sequence`, because only the platform
/// declares it. The conformances are now READ from the SDK's module interfaces (`StdlibConformances.swift`, generated
/// by `tools/gen-stdlib-conformances.py`): a receiver whose type conforms is RESOLVED, one whose type the source does
/// not state is DISCLOSED where the extension's body can do anything, and a call the platform's own same-named member
/// could also take is never resolved to the extension (argument types this engine does not have decide it).
///
/// Harness note (R706): a must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class PlatformProtocolExtensionProcessTests: XCTestCase {
    private static let FS = "try? FileManager.default.removeItem(atPath: \"/nonexistent/candor-v045\")"

    private func inf(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["inferred"] as? [String] ?? []).sorted()
    }
    private func write(_ s: String, _ url: URL) throws { try s.write(to: url, atomically: true, encoding: .utf8) }

    func testAStdlibReceiverReachesThisScansPlatformProtocolExtension() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v045-r1071-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/P"), withIntermediateDirectories: true)
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "P")])
        """, root.appendingPathComponent("Package.swift"))
        try write("""
        import Foundation
        extension Sequence { public func stampAll() { \(Self.FS) } }
        extension Collection { public var stampedCount: Int { \(Self.FS); return count } }
        extension Collection { public var isNotEmpty: Bool { !isEmpty } }
        extension RangeReplaceableCollection { public mutating func append(contentsOf m: Marker) { \(Self.FS) } }
        public struct Marker { public init() {} }
        extension Int { public func ownStamp() {} }
        extension Collection { public func ownStamp() { \(Self.FS) } }
        public func sugar(_ a: [Int]) { a.stampAll() }
        public func spelled(_ a: Array<Int>) { a.stampAll() }
        public func aSet(_ a: Set<Int>) { a.stampAll() }
        public func aString(_ a: String) { a.stampAll() }
        public func aDict(_ a: [String: Int]) { a.stampAll() }
        public func aData(_ a: Data) { a.stampAll() }
        public func aRange(_ a: Range<Int>) { a.stampAll() }
        public func aOptional(_ a: [Int]?) { a?.stampAll() }
        public func literal() { [1, 2].stampAll() }
        public func generic<S: Sequence>(_ s: S) { s.stampAll() }
        public func opaque(_ s: some Collection) { s.stampAll() }
        public func existential(_ s: any Sequence) { s.stampAll() }
        public func property(_ a: [Int]) -> Int { a.stampedCount }
        extension Array { public func implicitSelf() { stampAll() } }
        public func untyped(_ a: [Int]) { a.map { $0 }.stampAll() }
        public func untypedPure(_ a: [Int]) -> Bool { a.map { $0 }.isNotEmpty }
        public func ownMember(_ i: Int) { i.ownStamp() }
        public func stdlibAppend(_ a: [Int]) { var b = a; b.append(1); _ = b }
        public func sameLabels(_ a: [Int]) { var b = a; b.append(contentsOf: [1]); _ = b }
        """, root.appendingPathComponent("Sources/P/p.swift"))
        func scan(_ env: [String: String] = [:]) throws -> [String: [String: Any]] {
            try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"], env: env).out)
        }
        let by = try scan()
        for f in ["sugar", "spelled", "aSet", "aString", "aDict", "aData", "aRange", "aOptional", "literal", "generic",
                  "opaque", "existential", "property", "Array.implicitSelf"] {
            XCTAssertTrue(inf(by, f).contains("Fs"), "R1071: \(f)'s receiver conforms, so it runs the extension; got \(by[f] ?? [:])")
        }
        XCTAssertEqual(inf(by, "untyped"), ["Unknown"], "an unstated receiver type discloses; got \(by["untyped"] ?? [:])")
        XCTAssertEqual(by["untyped"]?["unknownWhy"] as? [String], ["dispatch:Sequence.stampAll"])
        XCTAssertNil(by["untypedPure"], "a PURE extension body costs nothing to an unstated receiver; got \(by["untypedPure"] ?? [:])")
        XCTAssertNil(by["ownMember"], "the concrete type's own member is the one Swift runs; got \(by["ownMember"] ?? [:])")
        XCTAssertNil(by["stdlibAppend"], "`append(_:)` is not `append(contentsOf:)`: the labels refuse it; got \(by["stdlibAppend"] ?? [:])")
        XCTAssertEqual(inf(by, "sameLabels"), ["Unknown"],
                       "labels the platform's own `append(contentsOf:)` also takes: disclosed, never charged; got \(by["sameLabels"] ?? [:])")

        let pf = root.appendingPathComponent("p.policy")
        func gate(_ policy: String, _ env: [String: String] = [:]) throws -> Int32 {
            try write(policy + "\n", pf)
            return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
        }
        XCTAssertEqual(try gate("deny Fs sugar"), 1, "the gate sees the write")
        XCTAssertNotEqual(try gate("deny Fs sugar", ["CANDOR_R1071P_OFF": "1"]), 1, "kill switch restores the release's silence")
        XCTAssertNil(try scan(["CANDOR_R1071P_OFF": "1"])["sugar"], "kill switch restores the release reading")
    }

    func testADependencysPlatformProtocolExtensionReachesAStdlibReceiver() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v045-r1071d-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for d in ["Iface/Sources/Iface", "Mid/Sources/Mid", "App/Sources/App", "deps"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Iface", products: [.library(name: "Iface", targets: ["Iface"])], targets: [.target(name: "Iface")])
        """, root.appendingPathComponent("Iface/Package.swift"))
        try write("""
        import Foundation
        extension Sequence { public func stampAll() { \(Self.FS) } }
        """, root.appendingPathComponent("Iface/Sources/Iface/x.swift"))
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Mid", products: [.library(name: "Mid", targets: ["Mid"])],
            dependencies: [.package(path: "../Iface")], targets: [.target(name: "Mid", dependencies: ["Iface"])])
        """, root.appendingPathComponent("Mid/Package.swift"))
        try write("""
        import Foundation
        import Iface
        public func midSeq(_ a: [Int]) { a.stampAll() }
        public func midSeqUntyped(_ a: [Int]) { a.map { $0 }.stampAll() }
        """, root.appendingPathComponent("Mid/Sources/Mid/m.swift"))
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", dependencies: [.package(path: "../Mid"), .package(path: "../Iface")],
            targets: [.executableTarget(name: "App", dependencies: ["Mid", "Iface"])])
        """, root.appendingPathComponent("App/Package.swift"))
        try write("""
        import Mid
        func appSeq() { midSeq([1]) }
        appSeq()
        """, root.appendingPathComponent("App/Sources/App/main.swift"))
        let mid = root.appendingPathComponent("Mid").path, app = root.appendingPathComponent("App").path

        // STANDALONE: the dependency is unchained, so its sources attribute the call — `invisible`, as R1071's
        // platform-TYPE arm attributes `d.stamp()`.
        let standalone = try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [mid, "--json"]).out)
        XCTAssertEqual(standalone["midSeq"]?["invisible"] as? [String], ["Iface"], "got \(standalone["midSeq"] ?? [:])")

        let iface = try ProcessHarness.run(bin, [root.appendingPathComponent("Iface").path, "--json"])
        try Data(iface.out.utf8).write(to: root.appendingPathComponent("deps/iface.json"))
        let chainedRun = try ProcessHarness.run(bin, [mid, "--json"], env: ["CANDOR_DEPS": root.appendingPathComponent("deps").path])
        let chained = try ProcessHarness.fns(ofJson: chainedRun.out)
        XCTAssertTrue(inf(chained, "midSeq").contains("Fs"), "CHAINED: the dependency's `Sequence.stampAll` entry joins; got \(chained["midSeq"] ?? [:])")
        XCTAssertEqual(inf(chained, "midSeqUntyped"), ["Unknown"], "an unstated receiver discloses; got \(chained["midSeqUntyped"] ?? [:])")
        let pf = root.appendingPathComponent("p.policy")
        func gate(_ dir: String, _ policy: String, _ env: [String: String] = [:]) throws -> Int32 {
            try write(policy + "\n", pf)
            return try ProcessHarness.run(bin, [dir, "--policy", pf.path, "--json"],
                                          env: ["CANDOR_DEPS": root.appendingPathComponent("deps").path].merging(env) { _, b in b }).code
        }
        XCTAssertEqual(try gate(mid, "deny Fs midSeq"), 1, "the chained consumer sees the write")
        XCTAssertNotEqual(try gate(mid, "deny Fs Unknown midSeq", ["CANDOR_R1071P_OFF": "1"]), 1, "kill switch restores the release's silence")
        try Data(chainedRun.out.utf8).write(to: root.appendingPathComponent("deps/mid.json"))
        XCTAssertEqual(try gate(app, "deny Fs appSeq"), 1, "…and so does the package one hop further downstream")
    }
}
