import XCTest
import Foundation

/// Shared helpers for the PROCESS-layer suites (TESTING.md §5: one fixture/spawn helper per repo).
/// Spawns the BUILT `candor-swift` binary the user runs — no SPM rebuild of fixtures (the engine is a
/// syntactic scan, it never builds its target). New process suites use this; the two pre-existing
/// suites (GateProcessTests / ChainingProcessTests) keep their private copies to avoid churn.
enum ProcessHarness {

    /// The debug binary `swift build` produced, alongside the test bundle in .build/<config>/.
    static func binaryURL(for testClass: AnyClass) throws -> URL {
        let bundleDir = Bundle(for: testClass).bundleURL.deletingLastPathComponent()
        let exe = bundleDir.appendingPathComponent("candor-swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: exe.path),
                          "candor-swift binary not built next to the test bundle (\(exe.path)) — run `swift build` first")
        return exe
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
