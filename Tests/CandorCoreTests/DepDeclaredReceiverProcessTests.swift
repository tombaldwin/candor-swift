import XCTest
import Foundation

/// SOUNDNESS R1066 — the OWNER of a member call's receiver in a standalone scan. A member call on a receiver whose
/// type a blind dependency DECLARES (`func f(_ b: Box<E>) { b.get().go() }`) read `[]` with no `invisible`, and the
/// downstream consumer that chained this report joined the floor key `Iface#Box.get`, found the dependency's pure
/// `get`, and passed `deny Fs Unknown` over a call that runs `E.go` (executed, `swiftagent-v044/fx/ext`). Ownership
/// is read off the dependency's own SOURCES, never off the ⟨0.39⟩ key: the key is published for platform receivers
/// too (`Iface#Date.addingTimeInterval`), and it cannot be narrowed — where the dependency EXTENDS the platform type
/// (`extension Date { func stamp() }`) the same spelling is the only route of the member's effect downstream.
///
/// Harness note (R706): a must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class DepDeclaredReceiverProcessTests: XCTestCase {
    private static let FS = "try? FileManager.default.removeItem(atPath: \"/nonexistent/candor-v044\")"

    private func inf(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["inferred"] as? [String] ?? []).sorted()
    }

    // ── R1066 — a standalone member call on a dependency-declared receiver ───────────────────────────────
    private func write(_ s: String, _ url: URL) throws { try s.write(to: url, atomically: true, encoding: .utf8) }

    func testADependencyDeclaredReceiverIsAttributedFromItsSources() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v044-r1066-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for d in ["Iface/Sources/Iface", "Mid/Sources/Mid", "App/Sources/App", "deps"] {
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
        public struct Box<V> { public let v: V; public init(v: V) { self.v = v }; public func get() -> V { v } }
        public struct Sink { public init() {}; public func put() { \(Self.FS) } }
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
        public func midBoxParam(_ b: Box<E>) { b.get().go() }
        public func midBoxCtor() { Box(v: E()).get().go() }
        public func midBoxQual(_ b: Iface.Box<E>) { b.get().go() }
        public func midBoxPure(_ b: Box<Int>) -> Int { b.get() }
        public func midSink(_ s: Sink) { s.put() }
        public func midExt(_ d: Date) { d.stamp() }
        public func midPlat(_ d: Date) { _ = d.addingTimeInterval(1) }
        public func midData(_ d: Data) { _ = d.base64EncodedString() }
        public func midEnc<T: Encoder>(_ e: T) { _ = e.singleValueContainer() }
        public func midHandle(_ h: FileHandle) { h.closeFile() }
        public struct Named { public var path: String = "" }
        public func midUrl(_ u: URL) -> String { u.appendingPathComponent("x").path }
        """, root.appendingPathComponent("Mid/Sources/Mid/Mid.swift"))
        try write("""
        // swift-tools-version:5.7
        import PackageDescription
        let package = Package(name: "App", dependencies: [.package(path: "../Mid"), .package(path: "../Iface")],
            targets: [.target(name: "App", dependencies: ["Mid", "Iface"])])
        """, root.appendingPathComponent("App/Package.swift"))
        try write("""
        import Foundation
        import Mid
        import Iface
        func appBox() { midBoxParam(Box(v: E())) }
        func appPure() { _ = midBoxPure(Box(v: 1)) }
        func appExt() { midExt(Date()) }
        """, root.appendingPathComponent("App/Sources/App/App.swift"))
        let mid = root.appendingPathComponent("Mid").path, app = root.appendingPathComponent("App").path
        let deps = root.appendingPathComponent("deps")
        func scanMid(_ env: [String: String] = [:]) throws -> (by: [String: [String: Any]], json: String) {
            let r = try ProcessHarness.run(bin, [mid, "--json"], env: env)
            return (try ProcessHarness.fns(ofJson: r.out), r.out)
        }
        let (by, midJson) = try scanMid()
        for f in ["midBoxParam", "midBoxCtor", "midBoxQual", "midBoxPure", "midSink"] {
            XCTAssertEqual(by[f]?["invisible"] as? [String], ["Iface"], "R1066: \(f)'s receiver is Iface's by its sources; got \(by[f] ?? [:])")
        }
        for f in ["midBoxParam", "midBoxCtor", "midBoxQual"] {
            XCTAssertEqual(inf(by, f), ["Unknown"], "R1066: \(f)'s hop may run a local `go`; got \(by[f] ?? [:])")
        }
        XCTAssertFalse(inf(by, "midBoxPure").contains("Unknown"), "no next member, no hedge")
        // PLATFORM receivers: no dependency source declares them, so nothing is attributed — the six false
        // `invisible`s attributing on the KEY produced (`swiftagent-v043/fx/enc`).
        for f in ["midExt", "midPlat", "midData", "midEnc", "midHandle", "midUrl"] {
            XCTAssertNil(by[f]?["invisible"], "R1066: \(f) is a platform receiver; got \(by[f] ?? [:])")
            XCTAssertFalse(inf(by, f).contains("Unknown"), "R1066: \(f) is not hedged; got \(by[f] ?? [:])")
        }
        // THE FLOOR KEY STAYS, platform receiver included: it is the only route of `stamp`'s effect downstream.
        XCTAssertEqual(by["midExt"]?["dispatchesOn"] as? [String], ["Iface#Date.stamp"], "the floor key is kept")

        let iface = try ProcessHarness.run(bin, [root.appendingPathComponent("Iface").path, "--json"])
        try Data(iface.out.utf8).write(to: deps.appendingPathComponent("iface.json"))
        try Data(midJson.utf8).write(to: deps.appendingPathComponent("mid.json"))
        func gateApp(_ policy: String) throws -> Int32 {
            let pf = root.appendingPathComponent("p.policy")
            try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [app, "--policy", pf.path, "--json"], env: ["CANDOR_DEPS": deps.path]).code
        }
        XCTAssertEqual(try gateApp("deny Fs Unknown appBox"), 1, "R1066: the downstream consumer is no longer silent")
        XCTAssertNotEqual(try gateApp("deny Fs Unknown appPure"), 1, "the pure instantiation passes downstream")
        XCTAssertEqual(try gateApp("deny Fs appExt"), 1, "the platform-receiver key still carries `stamp` downstream")

        let off = try scanMid(["CANDOR_R1066_OFF": "1"]).by
        XCTAssertNil(off["midBoxParam"]?["invisible"], "kill switch restores the release reading")
        XCTAssertTrue(inf(off, "midBoxParam").isEmpty, "kill switch restores the release reading")
    }
}
