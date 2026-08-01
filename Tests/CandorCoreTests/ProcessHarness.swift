import XCTest
import Foundation

/// Shared helpers for the PROCESS-layer suites (TESTING.md §5: one fixture/spawn helper per repo).
/// Spawns the BUILT `candor-swift` binary the user runs — no SPM rebuild of fixtures (the engine is a
/// syntactic scan, it never builds its target). EVERY process suite resolves the binary through
/// `binaryURL` here — the three suites that once kept private copies of it (GateProcessTests,
/// ChainingProcessTests, ScanBoundaryVeinProcessTests) now delegate. The copies were tolerated as
/// "avoiding churn" until all four of them turned out to resolve the WRONG directory on Linux, which
/// skipped every process suite on that CI leg silently. A resolver with four copies is four bugs.
enum ProcessHarness {

    /// The debug binary `swift build` produced, in the build directory `.build/<triple>/debug/`.
    ///
    /// Finding that directory from a test bundle is PLATFORM-DIVERGENT, because the test runner has a
    /// genuinely different shape on each host — measured, not assumed:
    ///
    ///                              macOS (Darwin Foundation)          Linux (swift-corelibs-foundation)
    ///   Bundle(for:) === main      false                              TRUE (no per-class lookup exists)
    ///   .bundleURL                 .../debug/<pkg>Tests.xctest        .../debug
    ///                              (a DIRECTORY bundle)               (the runner is a bare ELF file,
    ///                                                                  so this is already the build dir)
    ///   Bundle.main.bundleURL      Xcode's .../Developer/usr/bin      .../debug
    ///
    /// So `.deletingLastPathComponent()` is right on Darwin and one level too HIGH on Linux (it yields
    /// `.build/<triple>/`), while `Bundle.main` is right on Linux and points into Xcode on Darwin. Neither
    /// one-liner works on both. Rather than fork on `#if os(Linux)` — which would encode the divergence in
    /// a place no test can check — resolve it by SEARCH: the build directory is whichever candidate
    /// actually holds the binary. The candidates are disjoint (a `.xctest` bundle directory never contains
    /// `candor-swift`), so this cannot pick the wrong one, and it is a single code path on both hosts.
    static func binaryURL(for testClass: AnyClass) throws -> URL {
        let bundleURL = Bundle(for: testClass).bundleURL
        let candidates = [bundleURL,                               // Linux: already .build/<triple>/debug
                          bundleURL.deletingLastPathComponent()]   // Darwin: parent of the .xctest bundle
        for dir in candidates {
            let exe = dir.appendingPathComponent("candor-swift")
            if FileManager.default.fileExists(atPath: exe.path) { return exe }
        }
        throw XCTSkip("candor-swift binary not built in any build directory next to the test bundle "
                      + "(looked in \(candidates.map(\.path).joined(separator: ", "))) — run `swift build` first")
    }

    /// A throwaway SPM package whose single source file is exactly `mainSwift`. Returns the root;
    /// callers `defer { try? FileManager.default.removeItem(at: root) }`.
    static func makePackage(_ mainSwift: String, name: String = "App") throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-fix-\(UUID().uuidString)")
        let srcDir = root.appendingPathComponent("Sources/\(name)")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "\(name)", targets: [.executableTarget(name: "\(name)")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try mainSwift.write(to: srcDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return root
    }

    /// Run the binary with a SANITIZED environment (no inherited CANDOR_* leaks into a fixture scan)
    /// plus the given overrides. `cwd` pins the working directory (the config-anchoring tests must
    /// prove the CWD does NOT matter). Reads BEFORE waitUntilExit (pipe-buffer deadlock guard).
    static func run(_ binary: URL, _ args: [String], env: [String: String] = [:], cwd: URL? = nil) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        for k in ["CANDOR_POLICY", "CANDOR_CONFIG", "CANDOR_DEPS", "CANDOR_BASELINE"] { environment.removeValue(forKey: k) }
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self),
                p.terminationStatus)
    }

    /// The §2 envelope's functions keyed by `fn` — from a `--json` run's stdout.
    static func fns(ofJson out: String) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        var byName: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let name = f["fn"] as? String { byName[name] = f }
        }
        return byName
    }

    /// A fn's sorted inferred effects, or nil when the fn is absent (pure fns are omitted from reports).
    static func inferred(_ byName: [String: [String: Any]], _ fn: String) -> [String]? {
        guard let e = byName[fn] else { return nil }
        return (e["inferred"] as? [String])?.sorted()
    }
}
