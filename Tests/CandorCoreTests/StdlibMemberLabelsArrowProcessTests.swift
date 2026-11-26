import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1903 — the stdlib table generator's `split_top` read the `>` of `->` as a closing bracket, so a platform
/// member with a closure parameter followed by more parameters lost its later labels (`assumeIsolated` read `_`, not
/// `_,file=,line=`). The labels are now complete, which WIDENS platform admission: a call with the full label set now
/// binds the platform member and drops the C12 `dispatch:<untyped>.<leaf>` hedge. The second fixture comes first: a
/// dependency's own member of that name, with the complete label set, on a receiver nothing types, must STAY disclosed
/// by the other arms (chained: `untyped cross-package receiver`; unchained: `invisible:[Guess]`) — dropping the C12 token
/// must not be the only disclosure that goes.
final class StdlibMemberLabelsArrowProcessTests: XCTestCase {

    private static let dep = """
    import Foundation
    public final class Box {
        public init() {}
        public func assumeIsolated(_ body: () -> Int, file: String = "f", line: Int = 0) -> Int { FileManager.default.createFile(atPath: "/tmp/x", contents: nil); return body() }
        public func preconditionIsolated(_ m: String = "", file: String = "f", line: Int = 0) { FileManager.default.createFile(atPath: "/tmp/x", contents: nil) }
        public func assertIsolated(_ m: String = "", file: String = "f", line: Int = 0) { FileManager.default.createFile(atPath: "/tmp/x", contents: nil) }
        public func enumerator(at: URL, includingPropertiesForKeys: [String]?, options: Int = 0, errorHandler: ((URL, Error) -> Bool)? = nil) -> Int { FileManager.default.createFile(atPath: "/tmp/x", contents: nil); return 1 }
        public func withCancellationHandler(handler: () -> Void, operation: () -> Int) -> Int { FileManager.default.createFile(atPath: "/tmp/x", contents: nil); return operation() }
    }
    public func makeBoxes() -> [Box] { [Box()] }
    """

    private static let app = """
    import Foundation
    import Guess
    public func u_assume() -> Int { let b = makeBoxes().first!; return b.assumeIsolated({ 1 }, file: "a", line: 2) }
    public func u_assume_short() -> Int { let b = makeBoxes().first!; return b.assumeIsolated({ 1 }) }
    public func u_precond() { let b = makeBoxes().first!; b.preconditionIsolated("m", file: "a", line: 2) }
    public func u_assert() { let b = makeBoxes().first!; b.assertIsolated("m", file: "a", line: 2) }
    public func u_enum() -> Int { let b = makeBoxes().first!; return b.enumerator(at: URL(fileURLWithPath: "/"), includingPropertiesForKeys: nil, options: 0, errorHandler: nil) }
    public func u_enum_short() -> Int { let b = makeBoxes().first!; return b.enumerator(at: URL(fileURLWithPath: "/"), includingPropertiesForKeys: nil) }
    public func u_wch() -> Int { let b = makeBoxes().first!; return b.withCancellationHandler(handler: {}, operation: { 1 }) }
    public func u_wch_trail() -> Int { let b = makeBoxes().first!; return b.withCancellationHandler(handler: {}) { 1 } }
    """

    private struct Fixture { let root: URL; let bin: URL
        var depDir: URL { root.appendingPathComponent("depR") }
        var appDir: URL { root.appendingPathComponent("app") } }

    private func make() throws -> Fixture {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1903-\(UUID().uuidString)")
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
        for f in (d?["functions"] as? [[String: Any]]) ?? [] { rows[(f["fn"] as? String) ?? "?"] = Set(((f["unknownWhy"] as? [String]) ?? []) + ((f["invisible"] as? [String]) ?? []).map { "invisible:" + $0 }) }
        return rows
    }

    func testACompleteLabelSetStaysDisclosedOnAnUntypedDependencyReceiver() throws {
        let fx = try make(); defer { try? FileManager.default.removeItem(at: fx.root) }
        let cells = ["u_assume", "u_assume_short", "u_precond", "u_assert", "u_enum", "u_enum_short", "u_wch", "u_wch_trail"]
        for chained in [true, false] {
            let rows = try why(fx, chained: chained)
            let tok = chained ? "dispatch:untyped cross-package receiver" : "invisible:Guess"
            for c in cells {
                XCTAssertTrue(rows[c]?.contains(tok) ?? false,
                              "chained=\(chained) \(c): a dependency's member of a platform member's NAME, called with the platform's complete labels on an untyped receiver, must stay disclosed (\(tok)) — rows: \(rows)")
            }
        }
    }
}
