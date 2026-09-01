import XCTest
import Foundation

/// SOUNDNESS.md R85 — R79 (`CrossModuleGlobalReceiverProcessTests`) closed the CROSS-MODULE PUBLIC
/// global receiver gap for exactly ONE binder shape: a DIRECT constructor call (`public let
/// sharedWorker = SharedWorker()`). Two sibling shapes dropped the CALLER entirely, silently, and R79's
/// own commit named them as "open by design" — which reads as acceptable, and measured, was not:
///
///   FACTORY:      `public let sharedWorker = makeWorker()` — `Driver.swift` resolved the factory's
///                 vended TYPE in a separate, LATER pass that wrote only into `globalTypesByModule`
///                 and never revisited the cross-module-visible `publicGlobalTypesByModule` table.
///   DESTRUCTURED: `public let (sharedWorker, other) = (Worker(), 42)` — `DeclCollector` ran its
///                 type-inference logic ONLY for the plain-identifier binder shape; a tuple-destructure
///                 pattern's elements never entered `globalTypes`/`globalPublic` at all, for ANY module.
///
/// Coordinator's repro, ground truth EXECUTED (`swift build && ./.build/debug/App` really writes the
/// file): changing ONE line from `= Worker()` to `= makeWorker()`, everything else held constant, took
/// the report from `<main>` + `run` carrying `Fs` to ONLY `Worker.doWork` — both callers gone, and the
/// engine's unqualified "nothing hidden" clean bill fired over the gap regardless.
///
/// THE FIX makes both binder shapes feed the SAME authority the plain-identifier/direct-constructor
/// shape always used (`DeclCollector.inferGlobalType`, `Driver`'s `globalTypesByModule` +
/// `globalPublicByModule` -> a single derived `publicGlobalTypesByModule`), computed ONCE after every
/// pass that can resolve a global's type (including the deferred factory-return-type pass) has run —
/// rather than adding a third write site for the two new shapes that could drift the same way again.
///
/// Six rows, mirroring R79's own four-row structure, one pair per binder shape:
///   1a/1b. THE FIX ITSELF — the caller gains the callee's real effect.
///   2a/2b. OVER-CHARGE CONTROL — a genuinely PURE factory/destructured global call must gain NOTHING.
///   3a/3b. ACCESS CONTROL — a non-`public` factory/destructured global must still NOT resolve; it is
///          genuinely invisible cross-module, and resolving it would be fabrication dressed as a fix.
final class FactoryAndDestructuredGlobalReceiverProcessTests: XCTestCase {

    private func scan(_ root: URL) throws -> (fns: [String: [String: Any]], err: String) {
        let bin = try ProcessHarness.binaryURL(for: FactoryAndDestructuredGlobalReceiverProcessTests.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return (try ProcessHarness.fns(ofJson: r.out), r.err)
    }

    private func makeTwoModulePackage(coreDecl: String, callSite: String,
                                       pkgName: String = "R85Pkg") throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-r85-\(UUID().uuidString)")
        let coreDir = root.appendingPathComponent("Sources/Core")
        let appDir = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: coreDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "\(pkgName)", targets: [
            .target(name: "Core"),
            .executableTarget(name: "App", dependencies: ["Core"]),
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try coreDecl.write(to: coreDir.appendingPathComponent("Core.swift"), atomically: true, encoding: .utf8)
        try callSite.write(to: appDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return root
    }

    // ── 1a. FACTORY FIX — the caller gains the callee's real effect ───────────────────────────────
    func testFactoryInitializedPublicGlobalReceiverResolvesCallerEffect() throws {
        let root = try makeTwoModulePackage(coreDecl: """
            import Foundation
            public final class Worker {
                public init() {}
                public func doWork() { _ = try? String(contentsOfFile: "/etc/hosts") }
            }
            public func makeWorker() -> Worker { return Worker() }
            public let sharedWorker = makeWorker()
            """, callSite: """
            import Core
            func run() { sharedWorker.doWork() }
            run()
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let (by, _) = try scan(root)
        XCTAssertEqual(ProcessHarness.inferred(by, "Worker.doWork"), ["Fs"],
                       "the callee itself was always correctly classified — the bug was never here: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "run"), ["Fs"],
                       "R85 — `run` must carry the FACTORY-initialized cross-module global receiver's "
                       + "real effect, not vanish from functions[] entirely: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Fs"],
                       "R85 — <main> must transitively carry it too: \(by)")
    }

    // ── 2a. FACTORY OVER-CHARGE CONTROL — a genuinely pure factory global call gains NOTHING ──────
    func testPureFactoryInitializedPublicGlobalReceiverGainsNothing() throws {
        let root = try makeTwoModulePackage(coreDecl: """
            public final class PureWorker {
                public init() {}
                public func compute(_ x: Int) -> Int { x * 2 }
            }
            public func makePureWorker() -> PureWorker { return PureWorker() }
            public let sharedPureWorker = makePureWorker()
            """, callSite: """
            import Core
            func run() { print(sharedPureWorker.compute(21)) }
            run()
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let (by, _) = try scan(root)
        XCTAssertNil(ProcessHarness.inferred(by, "PureWorker.compute"),
                     "a genuinely pure callee must stay pure (omitted from the report): \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "run"),
                     "resolving a PURE factory-initialized cross-module global must not mint an "
                     + "effectful caller — the over-charge control this fix's whole direction depends "
                     + "on: \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "<main>"), "\(by)")
    }

    // ── 3a. FACTORY ACCESS CONTROL — a non-public factory global must NOT resolve ──────────────────
    func testNonPublicFactoryInitializedGlobalDoesNotResolve() throws {
        let root = try makeTwoModulePackage(coreDecl: """
            import Foundation
            public final class Worker {
                public init() {}
                public func doWork() { _ = try? String(contentsOfFile: "/etc/hosts") }
            }
            func makeWorker() -> Worker { return Worker() }
            // Deliberately INTERNAL — not visible outside Core in real Swift.
            let sharedWorkerInternal = makeWorker()
            """, callSite: """
            import Core
            func run() { sharedWorkerInternal.doWork() }
            run()
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let (by, _) = try scan(root)
        XCTAssertEqual(ProcessHarness.inferred(by, "Worker.doWork"), ["Fs"],
                       "the callee is still classified correctly on its own: \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "run"),
                     "an internal (non-public) factory-initialized cross-module global must keep "
                     + "missing — resolving it would fabricate visibility real Swift access control "
                     + "refuses: \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "<main>"), "\(by)")
    }

    // ── 1b. DESTRUCTURED FIX — the caller gains the callee's real effect ──────────────────────────
    func testDestructuredPublicGlobalReceiverResolvesCallerEffect() throws {
        let root = try makeTwoModulePackage(coreDecl: """
            import Foundation
            public struct Worker {
                public init() {}
                public func doWork() { _ = try? String(contentsOfFile: "/etc/hosts") }
            }
            public let (sharedWorker, otherThing) = (Worker(), 42)
            """, callSite: """
            import Core
            func run() { sharedWorker.doWork() }
            run()
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let (by, _) = try scan(root)
        XCTAssertEqual(ProcessHarness.inferred(by, "Worker.doWork"), ["Fs"],
                       "the callee itself was always correctly classified — the bug was never here: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "run"), ["Fs"],
                       "R85 — `run` must carry the DESTRUCTURED cross-module global receiver's real "
                       + "effect, not vanish from functions[] entirely: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Fs"],
                       "R85 — <main> must transitively carry it too: \(by)")
    }

    // ── 2b. DESTRUCTURED OVER-CHARGE CONTROL — a genuinely pure destructured global gains NOTHING ─
    func testPureDestructuredPublicGlobalReceiverGainsNothing() throws {
        let root = try makeTwoModulePackage(coreDecl: """
            public struct PureWorker {
                public init() {}
                public func compute(_ x: Int) -> Int { x * 2 }
            }
            public let (sharedPureWorker, otherThing) = (PureWorker(), 42)
            """, callSite: """
            import Core
            func run() { print(sharedPureWorker.compute(21)) }
            run()
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let (by, _) = try scan(root)
        XCTAssertNil(ProcessHarness.inferred(by, "PureWorker.compute"),
                     "a genuinely pure callee must stay pure (omitted from the report): \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "run"),
                     "resolving a PURE destructured cross-module global must not mint an effectful "
                     + "caller — the over-charge control this fix's whole direction depends on: \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "<main>"), "\(by)")
    }

    // ── 3b. DESTRUCTURED ACCESS CONTROL — a non-public destructured global must NOT resolve ───────
    func testNonPublicDestructuredGlobalDoesNotResolve() throws {
        let root = try makeTwoModulePackage(coreDecl: """
            import Foundation
            public struct Worker {
                public init() {}
                public func doWork() { _ = try? String(contentsOfFile: "/etc/hosts") }
            }
            // Deliberately INTERNAL destructured global.
            let (sharedWorkerInternal, otherThing) = (Worker(), 42)
            """, callSite: """
            import Core
            func run() { sharedWorkerInternal.doWork() }
            run()
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let (by, _) = try scan(root)
        XCTAssertEqual(ProcessHarness.inferred(by, "Worker.doWork"), ["Fs"],
                       "the callee is still classified correctly on its own: \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "run"),
                     "an internal (non-public) destructured cross-module global must keep missing — "
                     + "resolving it would fabricate visibility real Swift access control refuses: \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "<main>"), "\(by)")
    }
}
