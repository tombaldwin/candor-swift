import XCTest
import Foundation

/// SOUNDNESS.md R79 — a MODULE-SCOPE PUBLIC global declared in one module, called as a RECEIVER from a
/// file in a DIFFERENT module that imports it (`public let sharedWorker = SharedWorker()` in module
/// `WorkerModule`, `sharedWorker.doWork()` in module `App`). `globalTypes` (R73) is deliberately
/// MODULE-SCOPED — a bare global name is not project-wide unique — so a cross-module reference missed
/// it entirely: `rootOf` fell through to the untyped-name fallback, `owner` came back nil, and the
/// terminal member-access arm recorded a bare-leaf `Call` no edge ever matches. The CALLER's own effects
/// collapsed to empty and it vanished from `functions[]` outright — a cardinal sin (silent under-report),
/// not merely an imprecision, and the engine issued its unqualified "nothing hidden" clean bill over it.
///
/// THE FIX resolves the global through the calling FILE's own `import`s: a name absent from the file's
/// own module is looked up across every OTHER imported PROJECT module's PUBLIC-only global index. It
/// deliberately does NOT touch the terminal fallback's `owner == nil` behaviour itself — that fallback's
/// silence is relied on by ~8 sibling mechanisms (a prior attempt to patch the fallback directly broke 8
/// pre-existing tests and was reverted) — it only stops the R79 shape from REACHING that state.
///
/// Four rows, each independently important:
///   1. The FIX ITSELF — the caller gains the callee's real effect (R79's own shape).
///   2. OVER-CHARGE CONTROL — a genuinely PURE cross-module global call must gain NOTHING.
///   3. ACCESS CONTROL — a non-`public` global in another module is genuinely not visible in real
///      Swift; resolving it anyway would be fabrication dressed as a fix, so it must keep missing.
///   4. AMBIGUITY CONTROL — two imported modules each declaring the same public global name is a real
///      ambiguity this pass cannot adjudicate; it must resolve NOTHING rather than guess either one.
final class CrossModuleGlobalReceiverProcessTests: XCTestCase {

    private func scan(_ root: URL) throws -> (fns: [String: [String: Any]], err: String) {
        let bin = try ProcessHarness.binaryURL(for: CrossModuleGlobalReceiverProcessTests.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return (try ProcessHarness.fns(ofJson: r.out), r.err)
    }

    private func makeTwoModulePackage(globalDecl: String, callSite: String,
                                       pkgName: String = "R79Pkg") throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-r79-\(UUID().uuidString)")
        let workerDir = root.appendingPathComponent("Sources/WorkerModule")
        let appDir = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: workerDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "\(pkgName)", targets: [
            .target(name: "WorkerModule"),
            .executableTarget(name: "App", dependencies: ["WorkerModule"]),
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try globalDecl.write(to: workerDir.appendingPathComponent("Worker.swift"), atomically: true, encoding: .utf8)
        try callSite.write(to: appDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return root
    }

    // ── 1. THE FIX — the caller gains the callee's real effect ────────────────────────────────────
    func testCrossModuleGlobalReceiverResolvesCallerEffect() throws {
        let root = try makeTwoModulePackage(globalDecl: """
            import Foundation
            public final class SharedWorker {
                public init() {}
                public func doWork() { _ = try? String(contentsOfFile: "/etc/hosts") }
            }
            public let sharedWorker = SharedWorker()
            """, callSite: """
            import WorkerModule
            sharedWorker.doWork()
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let (by, _) = try scan(root)
        XCTAssertEqual(ProcessHarness.inferred(by, "SharedWorker.doWork"), ["Fs"],
                       "the callee itself was always correctly classified — the bug was never here: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Fs"],
                       "R79 — <main> must carry the cross-module global receiver's real effect, not "
                       + "vanish from functions[] entirely: \(by)")
    }

    // ── 2. OVER-CHARGE CONTROL — a genuinely pure cross-module global call gains NOTHING ──────────
    func testPureCrossModuleGlobalReceiverGainsNothing() throws {
        let root = try makeTwoModulePackage(globalDecl: """
            public final class PureWorker {
                public init() {}
                public func compute(_ x: Int) -> Int { x * 2 }
            }
            public let pureWorker = PureWorker()
            """, callSite: """
            import WorkerModule
            print(pureWorker.compute(21))
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let (by, _) = try scan(root)
        XCTAssertNil(ProcessHarness.inferred(by, "PureWorker.compute"),
                     "a genuinely pure callee must stay pure (omitted from the report): \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "<main>"),
                     "resolving a PURE cross-module global must not mint an effectful <main> — the "
                     + "over-charge control this fix's whole direction depends on: \(by)")
    }

    // ── 3. ACCESS CONTROL — a non-public global in another module must NOT resolve ────────────────
    func testNonPublicCrossModuleGlobalDoesNotResolve() throws {
        let root = try makeTwoModulePackage(globalDecl: """
            import Foundation
            public final class SharedWorker {
                public init() {}
                public func doWork() { _ = try? String(contentsOfFile: "/etc/hosts") }
            }
            // Deliberately INTERNAL — not visible outside WorkerModule in real Swift.
            let sharedWorkerInternal = SharedWorker()
            """, callSite: """
            import WorkerModule
            sharedWorkerInternal.doWork()
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let (by, _) = try scan(root)
        XCTAssertEqual(ProcessHarness.inferred(by, "SharedWorker.doWork"), ["Fs"],
                       "the callee is still classified correctly on its own: \(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "<main>"),
                     "an internal (non-public) cross-module global must keep missing — resolving it "
                     + "would fabricate visibility real Swift access control refuses. This is the SAME "
                     + "silent-absence R79 reports as a bug when the global IS public; here it is correct, "
                     + "not a residual of the fix: \(by)")
    }

    // ── 4. AMBIGUITY CONTROL — two imported modules declaring the same public global resolve NOTHING
    func testAmbiguousCrossModuleGlobalNameResolvesNothing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-r79-ambig-\(UUID().uuidString)")
        let modADir = root.appendingPathComponent("Sources/ModA")
        let modBDir = root.appendingPathComponent("Sources/ModB")
        let appDir = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: modADir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modBDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "R79Ambig", targets: [
            .target(name: "ModA"),
            .target(name: "ModB"),
            .executableTarget(name: "App", dependencies: ["ModA", "ModB"]),
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public final class WorkerA {
            public init() {}
            public func doWork() { _ = try? String(contentsOfFile: "/etc/hosts") }
        }
        public let sharedWorker = WorkerA()
        """.write(to: modADir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public final class WorkerB {
            public init() {}
            public func doWork() { _ = try? String(contentsOfFile: "/etc/hosts") }
        }
        public let sharedWorker = WorkerB()
        """.write(to: modBDir.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        try """
        import ModA
        import ModB
        sharedWorker.doWork()
        """.write(to: appDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let (by, _) = try scan(root)
        XCTAssertEqual(ProcessHarness.inferred(by, "WorkerA.doWork"), ["Fs"], "\(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "WorkerB.doWork"), ["Fs"], "\(by)")
        XCTAssertNil(ProcessHarness.inferred(by, "<main>"),
                     "two imported modules both declaring `public let sharedWorker` is a genuine "
                     + "ambiguity this pass cannot adjudicate — it must resolve NOTHING (leaving the "
                     + "pre-fix silent-absence unchanged here) rather than guess either module's global: "
                     + "\(by)")
    }
}
