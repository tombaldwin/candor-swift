import XCTest
import Foundation

/// SOUNDNESS R1086 — R1081's operand admission refused a REAL operator overload on less than proof, and the release
/// (v0.40.3) read silent where v0.40.2 charged. Executed (`swiftagent-v045/fx/r1081d`), two sources of a non-proof:
///   · a GUESSED operand type: `f + f.name`, `name` inherited from a dependency's class, so `rootOf` kept the outer
///     base `Foo` (`opaqueHop`), and `Foo.+(Foo, String)` was refused because "`Foo` is not `String`";
///   · a literal against a platform type a DEPENDENCY made literal-expressible: `extension URL: @retroactive
///     ExpressibleByStringLiteral` in an imported package, so `x + "https://…"` binds `static func + (a: Self, b: URL)`.
/// Both ran the overload's write; both rows read `[]` and `deny Fs` exited 0. A guess now proves nothing, and a literal
/// proves a platform parameter unbindable only where every imported non-platform module's readable sources add no
/// conformance to that type.
///
/// Harness note (R706): a must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class OperatorGuessedOperandProcessTests: XCTestCase {
    private static let FS = "try? FileManager.default.removeItem(atPath: \"/nonexistent/candor-v045\")"
    private func write(_ s: String, _ url: URL) throws { try s.write(to: url, atomically: true, encoding: .utf8) }

    private func makeTree(depAddsURLLiteral: Bool) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v045-r1086-\(UUID().uuidString)")
        let fm = FileManager.default
        for d in ["Dep/Sources/Dep", "App/Sources/App"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Dep", products: [.library(name: "Dep", targets: ["Dep"])], targets: [.target(name: "Dep")])
        """, root.appendingPathComponent("Dep/Package.swift"))
        try write("""
        import Foundation
        open class DepBase { public init() {}; public var name: String { "x" } }
        """ + (depAddsURLLiteral ? """

        extension URL: @retroactive ExpressibleByStringLiteral {
            public init(stringLiteral v: String) { self.init(string: v)! }
        }
        """ : ""), root.appendingPathComponent("Dep/Sources/Dep/d.swift"))
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", dependencies: [.package(path: "../Dep")],
            targets: [.executableTarget(name: "App", dependencies: [.product(name: "Dep", package: "Dep")])])
        """, root.appendingPathComponent("App/Package.swift"))
        try write("""
        import Foundation
        import Dep
        final class Foo: DepBase { }
        extension Foo { static func + (a: Foo, b: String) -> Foo { \(Self.FS); return a } }
        func viaHop(_ f: Foo) -> Foo { f + f.name }
        func viaTyped(_ f: Foo) -> Foo { let n: String = f.name; return f + n }
        public protocol Linkish {}
        extension Int: Linkish {}
        extension Linkish { static func + (a: Self, b: URL) -> Self { \(Self.FS); return a } }
        func viaLiteral(_ x: Int) -> Int { x + "https://example.com" }
        _ = viaHop(Foo()); _ = viaTyped(Foo()); _ = viaLiteral(1)
        """, root.appendingPathComponent("App/Sources/App/main.swift"))
        return root
    }

    func testAGuessedOperandOrADependencysLiteralConformanceRefusesNothing() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeTree(depAddsURLLiteral: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("App").path
        func scan(_ env: [String: String] = [:]) throws -> [String: [String: Any]] {
            try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [app, "--json"], env: env).out)
        }
        func gate(_ policy: String, _ env: [String: String] = [:]) throws -> Int32 {
            let pf = root.appendingPathComponent("p.policy")
            try write(policy + "\n", pf)
            return try ProcessHarness.run(bin, [app, "--policy", pf.path, "--json"], env: env).code
        }
        let by = try scan()
        for f in ["viaHop", "viaTyped", "viaLiteral"] {
            XCTAssertTrue((by[f]?["inferred"] as? [String] ?? []).contains("Fs"), "R1086: \(f) runs the overload's write; got \(by[f] ?? [:])")
        }
        XCTAssertEqual(try gate("deny Fs viaHop"), 1)
        XCTAssertEqual(try gate("deny Fs viaLiteral"), 1)
        XCTAssertNotEqual(try gate("deny Fs viaHop", ["CANDOR_R1086_OFF": "1"]), 1, "kill switch restores v0.40.3's silence")
        XCTAssertNotEqual(try gate("deny Fs viaLiteral", ["CANDOR_R1086_OFF": "1"]), 1, "kill switch restores v0.40.3's silence")
    }

    /// The control: the SAME tree with the dependency's readable sources adding no conformance to `URL`. The literal
    /// is then proof (R1081's fabrication fix stands), and the guessed operand still proves nothing.
    func testReadableDependencySourcesWithoutTheConformanceStillProve() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeTree(depAddsURLLiteral: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.appendingPathComponent("App").path, "--json"]).out)
        XCTAssertFalse((by["viaLiteral"]?["inferred"] as? [String] ?? []).contains("Fs"),
                       "a string literal cannot bind `URL` when nothing imported makes it: refused; got \(by["viaLiteral"] ?? [:])")
        XCTAssertTrue((by["viaHop"]?["inferred"] as? [String] ?? []).contains("Fs"), "got \(by["viaHop"] ?? [:])")
    }
}
