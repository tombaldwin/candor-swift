import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1895 — `$taskLocal.withValue(…)` calls a member of the PLATFORM's `TaskLocal`, so a chained package that
/// happens to publish a `withValue` must not make it an `Unknown`. The platform's member table is keyed by NAME ALONE
/// (`STDLIB_MEMBER_LABELS`) and cannot gain `withValue` (it would then bind every untyped `.withValue(…)` call), so the
/// members of a projected-value type live in `STDLIB_PROJECTED_VALUE_MEMBER_LABELS` and bind only a receiver shown to be a
/// `@TaskLocal` this scan declares. The SECOND fixture comes first here: a dependency's own `withValue`, called on an
/// untyped receiver that is not a TaskLocal with the SAME labels, must stay disclosed.
final class TaskLocalProjectedValueProcessTests: XCTestCase {

    private static let dep = """
    import Foundation
    public final class Box {
        public init() {}
        public func withValue<R>(_ v: Int, operation: () -> R) -> R { FileManager.default.createFile(atPath: "/tmp/x", contents: nil); return operation() }
    }
    public func makeBoxes() -> [Box] { [Box()] }
    """

    private static let app = """
    import Foundation
    import Guess
    @propertyWrapper public struct Mirror2<V> { public var wrappedValue: V; public init(wrappedValue: V) { self.wrappedValue = wrappedValue }
                                               public var projectedValue: Box { Box() } }
    @TaskLocal public var moduleLocal: Int = 0
    public func tl_global_p(_ p: Int) -> Int { $moduleLocal.withValue(p) { 1 } }          // a module-scope @TaskLocal
    public func notlocal_w(_ p: Int) -> Int { $moduleOther.withValue(p) { 1 } }           // no such @TaskLocal declared
    public enum Ctx {
        @TaskLocal public static var current: Int = 0
        @Mirror2 public static var other: Int = 0
        public static func inside(_ p: Int) -> Int { $current.withValue(p) { 1 } }
        public static func insideOther(_ p: Int) -> Int { $other.withValue(p) { 1 } }   // `$` of a NON-TaskLocal wrapper
        public static func viaSelf(_ p: Int) -> Int { Self.$current.withValue(p) { 1 } }
    }
    // the resolved cells: the receiver is a `@TaskLocal` this scan declares
    public func tl_qualified_p(_ p: Int) -> Int { Ctx.$current.withValue(p) { 1 } }
    public func tl_labelled_p(_ p: Int) -> Int { Ctx.$current.withValue(p, operation: { 1 }) }
    // the second fixture: a dependency's `withValue` on a receiver nothing types — must stay disclosed
    public func untyped_w(_ p: Int) -> Int { let b = makeBoxes().first!; return b.withValue(p) { 1 } }
    public func untyped_shorthand_w(_ p: Int) -> Int { var n = 0; makeBoxes().forEach { n += $0.withValue(p) { 1 } }; return n }
    // `$other` is a scan wrapper (typed through its `projectedValue`, R1904); `$missing` names no wrapped property, so it is hedged
    public func otherwrapper_w(_ p: Int) -> Int { Ctx.$other.withValue(p) { 1 } }
    public func undeclared_w(_ p: Int) -> Int { Ctx.$missing.withValue(p) { 1 } }
    public func wrongowner_w(_ p: Int) -> Int { Elsewhere.$current.withValue(p) { 1 } }
    """

    private struct Fixture { let root: URL; let bin: URL
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") } }

    private func make() throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1895-\(UUID().uuidString)")
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("Guess/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Guess", products: [.library(name: "Guess", targets: ["Guess"])], targets: [.target(name: "Guess")])
        """)
        try write("Guess/Sources/Guess/lib.swift", Self.dep)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../Guess")],
            targets: [.target(name: "App", dependencies: [.product(name: "Guess", package: "Guess")])])
        """)
        try write("app/Sources/App/app.swift", Self.app)
        let fx = Fixture(root: root, bin: bin)
        try FileManager.default.createDirectory(at: fx.depDir, withIntermediateDirectories: true)
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("Guess").path, "--out", fx.depDir.appendingPathComponent("rGuess").path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        for extra in try FileManager.default.contentsOfDirectory(atPath: fx.depDir.path)
            where !(extra.hasSuffix(".Swift.json") && !extra.contains("callgraph") && !extra.contains("hierarchy")) {
            try FileManager.default.removeItem(at: fx.depDir.appendingPathComponent(extra))
        }
        return fx
    }

    private func why(_ fx: Fixture, chained: Bool, env extra: [String: String] = [:]) throws -> [String: Set<String>] {
        var env = extra
        if chained { env["CANDOR_DEPS"] = fx.depDir.path }
        let tag = "o-\(UUID().uuidString)"
        let r = try ProcessHarness.run(fx.bin, [fx.appDir.path, "--out", fx.root.appendingPathComponent(tag).path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: fx.root.appendingPathComponent("\(tag).App.Swift.json"))) as? [String: Any]
        var rows: [String: Set<String>] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] { rows[(f["fn"] as? String) ?? "?"] = Set((f["unknownWhy"] as? [String]) ?? []) }
        return rows
    }

    func testAProjectedTaskLocalIsThePlatformMemberAndEverythingElseStaysDisclosed() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        let tok = "dispatch:<untyped>.withValue"
        for chained in [true, false] {
            let rows = try why(fx, chained: chained)
            for c in ["untyped_w", "untyped_shorthand_w", "notlocal_w", "undeclared_w"] {
                XCTAssertTrue(rows[c]?.contains(tok) ?? false,
                              "chained=\(chained) \(c): a `withValue` the dependency could answer, on a receiver that is NOT a `@TaskLocal` of this scan, stays disclosed — rows: \(rows)")
            }
            // R1904: `$other` is a scan wrapper whose `projectedValue` is a declared `Box`, so the call is TYPED, not the C12 hedge
            // (ProjectedValueWrapperProcessTests asserts what it charges)
            XCTAssertFalse(rows["wrongowner_w"]?.isEmpty ?? true,
                           "chained=\(chained): `Elsewhere.$current` — no scan type declares it — keeps the Unknown it had")
            for c in ["tl_qualified_p", "tl_labelled_p", "Ctx.inside", "Ctx.viaSelf", "tl_global_p"] {
                XCTAssertFalse(rows[c]?.contains(tok) ?? false,
                               "chained=\(chained) \(c): `$current` is a `@TaskLocal` this scan declares — the platform's `TaskLocal.withValue`")
            }
        }
    }
}
