import XCTest
import Foundation

/// Process-level tests over the BUILT `candor-swift` binary — the §6.2 gate's stdout/stderr split, exit
/// codes, port-ignoring Net matching, `::`-scoped policy, and the `--json`-writes-no-files contract are
/// all properties of the EXECUTABLE (the gate logic lives in main.swift, not the testable CandorCore
/// core), so they can only be pinned by spawning the binary. Mirrors what smoke.sh asserts, but at the
/// function boundary the code review named — and gated by `swift test` (offline, no network).
final class GateProcessTests: XCTestCase {

    /// The debug binary `swift build` produced, alongside this test bundle in .build/<config>/.
    private func binaryURL() throws -> URL {
        let bundleDir = Bundle(for: GateProcessTests.self).bundleURL.deletingLastPathComponent()
        let exe = bundleDir.appendingPathComponent("candor-swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: exe.path),
                          "candor-swift binary not built next to the test bundle (\(exe.path)) — run `swift build` first")
        return exe
    }

    /// A throwaway package whose single function reaches Net at `urlLiteral` (a κ-classified
    /// `URLSession.dataTask(with:)` call records the literal host as the function's Net surface).
    /// Returns the package root; the caller writes any policy file under it.
    private func makeNetFixture(qual typeName: String, urlLiteral: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-gate-\(UUID().uuidString)")
        let srcDir = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        struct \(typeName) {
            func charge(_ runtime: String) {
                let t = URLSession.shared.dataTask(with: "\(urlLiteral)") { _, _, _ in }
                t.resume()
            }
        }
        \(typeName)().charge("x")
        """.write(to: srcDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return root
    }

    /// Run the binary; return (stdout, stderr, exitCode). Spawns directly (no SPM rebuild of the fixture —
    /// candor-swift is a syntactic scan, it never builds its target).
    private func run(_ binary: URL, _ args: [String]) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        // Read BEFORE waitUntilExit to avoid a pipe-buffer deadlock on a large report.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self),
                p.terminationStatus)
    }

    // ── F1: `--json --policy <violating>` keeps stdout a clean JSON document ──────────────────────
    // A violation line on stdout used to break `candor-swift --json --policy p | jq`. Violations now go
    // to stderr; stdout stays the §2 envelope; exit is 1.
    func testJsonPolicyViolationKeepsStdoutPure() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("policy.txt")
        try "allow Net api.example.com\n".write(to: policy, atomically: true, encoding: .utf8)  // does NOT cover stripe

        let r = try run(bin, [root.path, "--json", "--policy", policy.path])
        XCTAssertEqual(r.code, 1, "a violation must exit 1")
        // stdout parses as one JSON object with the §2 envelope — no violation text leaked in.
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertNotNil(obj?["candor"], "stdout must be the clean §2 JSON envelope")
        XCTAssertFalse(r.out.contains("AS-EFF"), "no violation line may appear on stdout")
        // the violation diagnostic is on stderr.
        XCTAssertTrue(r.err.contains("AS-EFF-008"), "violation text must be on stderr; got: \(r.err)")
    }

    // ── F2: a Net allow matches by hostname with the PORT IGNORED (spec §6.2; cross-engine parity) ──
    func testNetMatchingIgnoresPort() throws {
        let bin = try binaryURL()
        // surface URL carries an explicit :443; the allow value names the bare host.
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com:443/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("policy.txt")
        try "allow Net api.stripe.com\n".write(to: policy, atomically: true, encoding: .utf8)

        let r = try run(bin, [root.path, "--json", "--policy", policy.path])
        XCTAssertEqual(r.code, 0, "api.stripe.com must cover api.stripe.com:443 — got stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("policy ✓"), "expected a clean gate; stderr: \(r.err)")
    }

    // and the reverse: an allow VALUE that carries a port still covers the bare-host surface.
    func testNetMatchingPolicyValueCarriesPort() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("policy.txt")
        try "allow Net api.stripe.com:443\n".write(to: policy, atomically: true, encoding: .utf8)

        let r = try run(bin, [root.path, "--json", "--policy", policy.path])
        XCTAssertEqual(r.code, 0, "allow value api.stripe.com:443 must cover api.stripe.com — stderr: \(r.err)")
    }

    // ── F3: a `::`-segmented policy scope matches a dotted Swift qual (was inert in Swift) ──────────
    func testColonColonScopeMatchesDottedQual() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("policy.txt")
        // Rust/Swift path syntax for the SAME scope a dotted Java/Swift qual exposes: `Billing.charge`.
        try "deny Net Billing::charge\n".write(to: policy, atomically: true, encoding: .utf8)

        let r = try run(bin, [root.path, "--json", "--policy", policy.path])
        XCTAssertEqual(r.code, 1, "a ::-scoped deny must reach Billing.charge — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-006") && r.err.contains("Billing.charge"),
                      "expected a deny hit on Billing.charge; stderr: \(r.err)")
    }

    // ── F5: the AS-EFF-008 MASKING message names the masking, not "no visible literal" ─────────────
    // A function with one VISIBLE literal host and one runtime (structurally-invisible) host: the visible
    // literal must not certify the surface (it can't cover for the invisible endpoint), and the diagnostic
    // must say so — not the misleading "no visible literal" (there IS one).
    func testMaskingMessageDistinguishesVisibleLiteral() throws {
        let bin = try binaryURL()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-mask-\(UUID().uuidString)")
        let srcDir = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        struct Billing {
            func charge(_ runtime: String) {
                let a = URLSession.shared.dataTask(with: "https://api.stripe.com/v1/charges") { _, _, _ in }
                a.resume()
                let b = URLSession.shared.dataTask(with: runtime) { _, _, _ in }   // invisible host
                b.resume()
            }
        }
        Billing().charge("x")
        """.write(to: srcDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let policy = root.appendingPathComponent("policy.txt")
        try "allow Net api.stripe.com\n".write(to: policy, atomically: true, encoding: .utf8)

        let r = try run(bin, [root.path, "--json", "--policy", policy.path])
        XCTAssertEqual(r.code, 1, "masking surface must not be certified — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("structurally-invisible Net endpoint a visible literal cannot mask"),
                      "expected the masking-specific message; stderr: \(r.err)")
        XCTAssertFalse(r.err.contains("no visible literal"),
                       "a visible literal IS present — the old misleading message must not fire")
    }

    // ── F4: `--json` is documented as writing NO files — it must not leave an empty `.candor/` ──────
    func testJsonWritesNoCandorDir() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try run(bin, [root.path, "--json"])
        let candor = root.appendingPathComponent(".candor")
        XCTAssertFalse(FileManager.default.fileExists(atPath: candor.path),
                       "--json must not create the .candor/ directory")

        // sanity: a NON-json run DOES write the reports there (the side the dir-create belongs on).
        _ = try run(bin, [root.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: candor.path),
                      "a default (file-writing) run must create .candor/")
    }
}
