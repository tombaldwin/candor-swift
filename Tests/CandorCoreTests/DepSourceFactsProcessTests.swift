import XCTest
import Foundation

/// SOUNDNESS R1071 and R1072 — what an UNCHAINED dependency's own readable sources answer.
///
/// - R1072 (resolution): `func f(_ b: Box<E>) { b.get().go() }` with `Box<V>` declared by the dependency read `[]`
///   (R1066 then disclosed it). The dependency's sources are now run through the same instantiation collector as the
///   scanned files and offered to the files that import it, so `get()` is `E` and `E.go` is CHARGED. A local type
///   whose member shares the leaf (`Holder.get() -> P`) no longer types every `.get()` as `P`: a receiver whose
///   instantiation is read answers first.
/// - R1071 (disclosure): `d.stamp()` where the dependency declares `extension Date { public func stamp() }` read `[]`
///   with no `invisible`; the dependency's public extension members are read from its sources.
///
/// Every positive arm was EXECUTED (`swiftagent-v044/fx/ext`): the program wrote its marker through it; every
/// control wrote nothing. Harness note (R706): a must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class DepSourceFactsProcessTests: XCTestCase {
    private static let FS = "try? FileManager.default.removeItem(atPath: \"/nonexistent/candor-v044\")"

    private func inf(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["inferred"] as? [String] ?? []).sorted()
    }
    private func write(_ s: String, _ url: URL) throws { try s.write(to: url, atomically: true, encoding: .utf8) }

    func testADependencysSourcesResolveItsGenericTypesAndExtensionMembers() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v044-r1072-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for d in ["Iface/Sources/Iface", "Mid/Sources/Mid"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try write("""
        // swift-tools-version:5.7
        import PackageDescription
        let package = Package(name: "Iface", products: [.library(name: "Iface", targets: ["Iface"])], targets: [.target(name: "Iface")])
        """, root.appendingPathComponent("Iface/Package.swift"))
        try write("""
        import Foundation
        extension Date { public func stamp() { \(Self.FS) } }
        public extension URL { func touch() { \(Self.FS) } }
        extension Data { func hiddenStamp() { \(Self.FS) } }
        public struct Box<V> { public let v: V; public init(v: V) { self.v = v }; public func get() -> V { v } }
        public struct Holder<V> { public let v: V; public init(v: V) { self.v = v }; public func get() -> V { v } }
        public struct Pair<A, B> {
            public let a: A; public let b: B
            public init(a: A, b: B) { self.a = a; self.b = b }
            public func first() -> A { a }; public func second() -> B { b }
        }
        """, root.appendingPathComponent("Iface/Sources/Iface/Iface.swift"))
        try write("""
        // swift-tools-version:5.7
        import PackageDescription
        let package = Package(name: "Mid", products: [.library(name: "Mid", targets: ["Mid"])],
            dependencies: [.package(path: "../Iface")], targets: [.target(name: "Mid", dependencies: ["Iface"])])
        """, root.appendingPathComponent("Mid/Package.swift"))
        try write("""
        import Foundation
        import Iface
        public struct E { public init() {}; public func go() { \(Self.FS) } }
        public struct P { public init() {}; public func go() { _ = 1 } }
        struct Holder<V> { let v: V; func get() -> P { P() } }
        public func viaParam(_ b: Box<E>) { b.get().go() }
        public func viaCtor() { Box(v: E()).get().go() }
        public func viaQual(_ b: Iface.Box<E>) { b.get().go() }
        public func viaNested() { Box(v: Box(v: E())).get().get().go() }
        public func viaSecond() { Pair(a: P(), b: E()).second().go() }
        public func viaExt(_ d: Date) { d.stamp() }
        public func viaTouch(_ u: URL) { u.touch() }
        // CONTROLS: the pure instantiation, the other pair position, a LOCAL type shadowing the dependency's
        // (`Holder.get() -> P`, Swift picks the local one), and platform members no dependency declares.
        public func ctlPure() { Box(v: P()).get().go() }
        public func ctlFirst() { Pair(a: P(), b: E()).first().go() }
        public func ctlShadow() { Holder(v: E()).get().go() }
        public func ctlPlat(_ d: Date) { _ = d.addingTimeInterval(1) }
        public func ctlData(_ d: Data) { _ = d.base64EncodedString() }
        """, root.appendingPathComponent("Mid/Sources/Mid/Mid.swift"))
        let mid = root.appendingPathComponent("Mid").path
        func scan(_ env: [String: String] = [:]) throws -> [String: [String: Any]] {
            try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [mid, "--json"], env: env).out)
        }
        func gate(_ policy: String) throws -> Int32 {
            let pf = root.appendingPathComponent("p.policy")
            try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [mid, "--policy", pf.path, "--json"]).code
        }
        let by = try scan()
        for f in ["viaParam", "viaCtor", "viaQual", "viaNested", "viaSecond"] {
            XCTAssertEqual(inf(by, f), ["Fs"], "R1072: \(f) runs E.go; got \(by[f] ?? [:])")
        }
        for f in ["ctlPure", "ctlFirst", "ctlShadow", "ctlPlat", "ctlData"] {
            XCTAssertFalse(inf(by, f).contains("Fs"), "R1072: \(f) runs nothing effectful; got \(by[f] ?? [:])")
            XCTAssertFalse(inf(by, f).contains("Unknown"), "R1072: \(f) is not hedged; got \(by[f] ?? [:])")
        }
        for f in ["viaExt", "viaTouch"] {
            XCTAssertEqual(by[f]?["invisible"] as? [String], ["Iface"], "R1071: \(f) calls Iface's extension member; got \(by[f] ?? [:])")
        }
        for f in ["ctlPlat", "ctlData"] {
            XCTAssertNil(by[f]?["invisible"], "R1071: \(f) is a platform member no dependency declares; got \(by[f] ?? [:])")
        }
        XCTAssertEqual(try gate("deny Fs viaParam"), 1, "R1072: the plain gate flips")
        XCTAssertEqual(try gate("deny Fs viaNested"), 1, "R1072: nested over a dependency's type")
        XCTAssertNotEqual(try gate("deny Fs ctlShadow"), 1, "the local type keeps its own reading")
        XCTAssertNotEqual(try gate("deny Fs Unknown ctlPure"), 1, "the pure instantiation passes")

        let off = try scan(["CANDOR_R1072_OFF": "1", "CANDOR_R1071_OFF": "1"])
        XCTAssertFalse(inf(off, "viaParam").contains("Fs"), "R1072 kill switch restores the disclosure-only reading")
        XCTAssertNil(off["viaExt"]?["invisible"], "R1071 kill switch restores the release reading")
    }
}
