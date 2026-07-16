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

    /// A throwaway package whose single source file is exactly `body` (the caller controls the effect /
    /// syntax). Returns the package root. For the adversarial / surface cases that `makeNetFixture`'s
    /// fixed Net body can't express (a broken parse, an empty dir, a folded NWConnection port).
    private func makeFixture(_ body: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-fix-\(UUID().uuidString)")
        let srcDir = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try body.write(to: srcDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return root
    }

    /// Run the binary; return (stdout, stderr, exitCode). Spawns directly (no SPM rebuild of the fixture —
    /// candor-swift is a syntactic scan, it never builds its target). `cwd` pins the working directory —
    /// the config-discovery tests need to prove the CWD does NOT matter (spec §3.4 target-anchoring).
    private func run(_ binary: URL, _ args: [String], cwd: URL? = nil) throws -> (out: String, err: String, code: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
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

    // ════════════════════════════════════════════════════════════════════════════════════════════════
    // CLI behaviour matrix — exit codes + stdout/stderr contract over the BUILT binary.
    // ════════════════════════════════════════════════════════════════════════════════════════════════

    // ── G1: a bare scan WRITES report file(s) under .candor/ and exits 0 ────────────────────────────
    func testBareScanWritesReportAndExitsZero() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }

        let r = try run(bin, [root.path])
        XCTAssertEqual(r.code, 0, "a bare scan with no policy is exit 0 — stderr: \(r.err)")
        let candor = root.appendingPathComponent(".candor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: candor.path), "bare scan must write .candor/")
        let reports = try FileManager.default.contentsOfDirectory(atPath: candor.path)
            .filter { $0.hasSuffix(".Swift.json") }
        XCTAssertFalse(reports.isEmpty, "expected a <pkg>.Swift.json report; .candor/ held: \(reports)")
    }

    // ── G2: `--json` (no policy) prints PARSEABLE JSON, writes NO files, exits 0 ─────────────────────
    func testJsonNoPolicyParsesAndWritesNothing() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }

        let r = try run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "clean --json scan is exit 0 — stderr: \(r.err)")
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertNotNil(obj?["candor"], "stdout must be the §2 envelope")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".candor").path),
                       "--json must write no files")
    }

    // ── G3: `--json --policy <clean>` keeps stdout pure JSON and exits 0 (the green twin of F1) ──────
    func testJsonPolicyCleanIsPureJsonExitZero() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("policy.txt")
        try "allow Net api.stripe.com\n".write(to: policy, atomically: true, encoding: .utf8)

        let r = try run(bin, [root.path, "--json", "--policy", policy.path])
        XCTAssertEqual(r.code, 0, "a covered surface is a clean gate — stderr: \(r.err)")
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertNotNil(obj?["candor"], "stdout must remain the clean §2 envelope")
        XCTAssertTrue(r.err.contains("policy ✓"), "expected the clean-gate marker on stderr; got: \(r.err)")
    }

    // ── G4: `--policy <violating>` → 1 ; `--policy <clean>` → 0 (non-json file-writing path) ─────────
    func testPolicyExitCodesFileWritingPath() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("bad.pol"), ok = root.appendingPathComponent("ok.pol")
        try "deny Net\n".write(to: bad, atomically: true, encoding: .utf8)        // denies Net everywhere
        try "allow Net api.stripe.com\n".write(to: ok, atomically: true, encoding: .utf8)

        XCTAssertEqual(try run(bin, [root.path, "--policy", bad.path]).code, 1, "deny Net must exit 1")
        XCTAssertEqual(try run(bin, [root.path, "--policy", ok.path]).code, 0, "a covered allow exits 0")
    }

    // ── G5: a MISSING / unreadable policy must NEVER go green — exit 2 (the §6.2 gateless-green guard) ─
    func testMissingPolicyExitsTwo() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("does-not-exist.pol")

        let r = try run(bin, [root.path, "--policy", missing.path])
        XCTAssertEqual(r.code, 2, "an unreadable policy is exit 2, never green — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("gate NOT enforced"), "must say the gate didn't run; stderr: \(r.err)")
    }

    // ── G6: a trailing valueless `--policy` / `--out` must FAIL (exit 2), never clobber-then-green ───
    func testTrailingValuelessFlagsExitTwo() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }

        // `--policy` with no following value would otherwise nil-clobber the gate and exit 0.
        let p = try run(bin, [root.path, "--policy"])
        XCTAssertEqual(p.code, 2, "valueless --policy must exit 2; stderr: \(p.err)")
        XCTAssertTrue(p.err.contains("--policy requires a value"), "stderr: \(p.err)")
        // and the next-token-is-a-flag form (`--policy --json`) must not consume `--json` as the path.
        let pf = try run(bin, [root.path, "--policy", "--json"])
        XCTAssertEqual(pf.code, 2, "`--policy --json` must reject --json as a value; stderr: \(pf.err)")
        let o = try run(bin, [root.path, "--out"])
        XCTAssertEqual(o.code, 2, "valueless --out must exit 2; stderr: \(o.err)")
        XCTAssertTrue(o.err.contains("--out requires a value"), "stderr: \(o.err)")
    }

    // ── G7: `--version` / `-V` print `candor-swift <ver> (spec <X>)` and exit 0 ─────────────────────
    func testVersionFlag() throws {
        let bin = try binaryURL()
        for flag in ["--version", "-V"] {
            let r = try run(bin, [flag])
            XCTAssertEqual(r.code, 0, "\(flag) exits 0")
            XCTAssertTrue(r.out.range(of: #"^candor-swift \d+\.\d+\.\d+ \(spec \d+\.\d+\)"#,
                                      options: .regularExpression) != nil,
                          "\(flag) first line must be `candor-swift <ver> (spec <X>)`; got: \(r.out)")
        }
    }

    // ── G8: `--help` / `-h` print usage and exit 0 ──────────────────────────────────────────────────
    func testHelpFlag() throws {
        let bin = try binaryURL()
        for flag in ["--help", "-h"] {
            let r = try run(bin, [flag])
            XCTAssertEqual(r.code, 0, "\(flag) exits 0")
            XCTAssertTrue(r.out.contains("USAGE"), "\(flag) must print usage; got: \(r.out)")
        }
    }

    // ── G9: an unknown flag, and a missing scan path, both exit 2 (never become a literal scan path) ─
    func testUnknownFlagAndMissingPathExitTwo() throws {
        let bin = try binaryURL()
        let bogus = try run(bin, ["--bogus"])
        XCTAssertEqual(bogus.code, 2, "an unknown flag must exit 2, not scan a dir named --bogus")
        XCTAssertTrue(bogus.err.contains("unknown flag"), "stderr: \(bogus.err)")

        let missing = try run(bin, ["/no/such/path/\(UUID().uuidString)"])
        XCTAssertEqual(missing.code, 2, "a non-existent scan path must exit 2")
        XCTAssertTrue(missing.err.contains("no such path"), "stderr: \(missing.err)")
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════
    // Host surface — the port stays IN the surface (conformance [4e]); matching ignores it.
    // ════════════════════════════════════════════════════════════════════════════════════════════════

    /// The `hosts` surface for `qual` in a `--json` report (the §2 functions[] entry).
    private func hostsSurface(_ bin: URL, _ root: URL, qual: String) throws -> [String] {
        let r = try run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        let fns = obj?["functions"] as? [[String: Any]] ?? []
        let entry = fns.first { ($0["fn"] as? String) == qual }
        return (entry?["hosts"] as? [String]) ?? []
    }

    // ── H1: a `host:port` STRING URL keeps the port in the recorded surface ([4e]) ──────────────────
    func testStringUrlKeepsPortInSurface() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com:8443/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try hostsSurface(bin, root, qual: "Billing.charge"), ["api.stripe.com:8443"],
                       "the explicit :8443 must be part of the §2 host surface")
    }

    // ── H2: NWConnection(host:,port:) FOLDS the separate port arg into the host:port surface ([4e]) ──
    func testNWConnectionFoldsSeparatePortIntoSurface() throws {
        let bin = try binaryURL()
        let root = try makeFixture("""
        import Foundation
        import Network
        struct Telemetry {
            func emit() {
                let c = NWConnection(host: "metrics.example.com", port: 9090)
                c.start(queue: .main)
            }
        }
        Telemetry().emit()
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try hostsSurface(bin, root, qual: "Telemetry.emit"), ["metrics.example.com:9090"],
                       "the separate `port: 9090` must fold into the host:port surface")
    }

    // ── H3: `allow Net <host>` matches a reached `host:port` (port-insensitive matching) ─────────────
    // The surface KEEPS the port (H2), but the gate MATCHES ignoring it — a bare-host allow covers it.
    func testAllowBareHostCoversFoldedPortSurface() throws {
        let bin = try binaryURL()
        let root = try makeFixture("""
        import Foundation
        import Network
        struct Telemetry {
            func emit() {
                let c = NWConnection(host: "metrics.example.com", port: 9090)
                c.start(queue: .main)
            }
        }
        Telemetry().emit()
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("policy.txt")
        try "allow Net metrics.example.com\n".write(to: policy, atomically: true, encoding: .utf8)

        let r = try run(bin, [root.path, "--json", "--policy", policy.path])
        XCTAssertEqual(r.code, 0, "a bare-host allow must cover the :9090 surface — stderr: \(r.err)")
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════
    // Adversarial inputs — no crash; valid rules still enforce alongside the garbage.
    // ════════════════════════════════════════════════════════════════════════════════════════════════

    // ── A1: a syntactically-broken .swift file is tolerated (SwiftParser recovers), no crash ─────────
    func testBrokenSwiftFileDoesNotCrash() throws {
        let bin = try binaryURL()
        let root = try makeFixture("""
        import Foundation
        struct Broken {
            func oops( {            // unbalanced paren — deliberately un-parseable
                let x = URLSession.shared.dataTask(with: "https://api.example.com/x"
            }
        // missing closing brace
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try run(bin, [root.path, "--json"])
        // The contract is "no crash" — a clean exit (0/1/2), not a signal. A SIGILL/SIGSEGV surfaces as a
        // termination status >= 128; any of those is a failure of the no-crash invariant.
        XCTAssertLessThan(r.code, 128, "a broken parse must not crash the scanner — exit was \(r.code), stderr: \(r.err)")
    }

    // ── A2: an empty directory scans cleanly without crashing (no Swift sources → exit 2, a clean error) ─
    func testEmptyDirDoesNotCrash() throws {
        let bin = try binaryURL()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try run(bin, [root.path])
        XCTAssertEqual(r.code, 2, "an empty dir has no Swift sources — a clean exit-2 error, not a crash")
        XCTAssertTrue(r.err.contains("no Swift sources"), "stderr: \(r.err)")
    }

    // ── A3: a malformed policy line is warned-and-skipped; valid rules in the SAME file still enforce ─
    func testMalformedPolicyLineSkippedValidRulesStillEnforce() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("policy.txt")
        // line 1 garbage (unknown rule kind), line 2 garbage (allow with no values), line 3 a REAL deny.
        try """
        frobnicate Net everything
        allow Net
        deny Net
        """.write(to: policy, atomically: true, encoding: .utf8)

        let r = try run(bin, [root.path, "--json", "--policy", policy.path])
        XCTAssertEqual(r.code, 1, "the valid `deny Net` must still fire despite the garbage lines — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("ignoring policy rule"), "malformed lines must be warned-and-skipped; stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-006"), "the surviving deny must produce a violation; stderr: \(r.err)")
    }

    // ── --gate-json ⟨0.8⟩: the structured gate verdict, faithful to the exit code ─────────────────
    func testGateJsonWritesTheStructuredVerdict() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://evil.example.com/x")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("policy.txt")
        try "deny Net\n".write(to: policy, atomically: true, encoding: .utf8)
        let gate = root.appendingPathComponent("gate.json")

        let r = try run(bin, [root.path, "--policy", policy.path, "--gate-json", gate.path])
        XCTAssertEqual(r.code, 1, "a deny-Net violation exits 1 — stderr: \(r.err)")

        let data = try Data(contentsOf: gate)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["spec"] as? String, "0.17", "verdict declares the spec version")
        XCTAssertEqual(obj?["ok"] as? Bool, false, "ok:false on a failing gate")
        let viols = obj?["violations"] as? [[String: Any]] ?? []
        // The fixture calls `Billing().charge("x")` at the top level, so `deny Net` catches BOTH the
        // method AND the `<main>` top-level unit that transitively reaches it.
        XCTAssertEqual(viols.count, 2, "the method and its top-level transitive caller: \(viols)")
        XCTAssertTrue(viols.allSatisfy { $0["rule"] as? String == "AS-EFF-006" })
        XCTAssertTrue(viols.allSatisfy { ($0["effects"] as? [String]) == ["Net"] }, "effects = the denied set")
        let fns = viols.compactMap { $0["fn"] as? String }
        XCTAssertTrue(fns.contains { $0.contains("charge") }, "names the violating method")
        XCTAssertTrue(fns.contains("<main>"), "names the top-level caller")
    }

    func testGateJsonValuelessFailsClosed() throws {
        let bin = try binaryURL()
        let root = try makeFixture("func pure() {}\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try run(bin, [root.path, "--gate-json"])
        XCTAssertEqual(r.code, 2, "a valueless --gate-json must fail (exit 2) — stderr: \(r.err)")
    }

    // ── --gate-json robustness (max-review findings 7 + 10) ────────────────────────────────────────
    func testGateJsonUnwritablePathDoesNotChangeTheGateVerdict() throws {
        // The verdict is a surfacing side-output: an unwritable path used to route through writeJson's
        // exit(1), turning a PASSING gate into a red check. It must be one stderr line, exit unchanged.
        let bin = try binaryURL()
        let root = try makeFixture("func pure() {}\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("no/such/dir/gate.json")
        let r = try run(bin, [root.path, "--gate-json", bad.path])
        XCTAssertEqual(r.code, 0, "a clean gateless run stays exit 0 despite the unwritable verdict path — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("could not write --gate-json"), "the failure is disclosed on stderr: \(r.err)")
    }

    // ── .candor/config (§config): target-anchored, env-overridden, fail-closed ──────────────────
    func testCandorConfigDrivesTheGateEnvOverridesAndTypoFailsClosed() throws {
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://x.example/x")
        defer { try? FileManager.default.removeItem(at: root) }
        let denyNet = root.appendingPathComponent("deny-net.policy")
        try "deny Net\n".write(to: denyNet, atomically: true, encoding: .utf8)
        let denyDb = root.appendingPathComponent("deny-db.policy")
        try "deny Db\n".write(to: denyDb, atomically: true, encoding: .utf8)
        let candorDir = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candorDir, withIntermediateDirectories: true)
        try "policy \(denyNet.path)\npolcy typo\n".write(to: candorDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        // (a) the checked-in config drives the gate — no flag, no env — discovered via the target's ancestors
        let r = try run(bin, [root.path, "--out", root.appendingPathComponent("r").path])
        XCTAssertEqual(r.code, 1, "the config-supplied deny-Net gates the scan — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-006"), "the violation is reported: \(r.err)")
        XCTAssertTrue(r.err.contains("unknown config key 'polcy'"), "typo protection warns: \(r.err)")

        // (b) CANDOR_POLICY env overrides the config (a passing deny-Db wins over the config's deny-Net)
        let p = Process()
        p.executableURL = bin
        p.arguments = [root.path, "--out", root.appendingPathComponent("r2").path]
        var env = ProcessInfo.processInfo.environment
        env["CANDOR_POLICY"] = denyDb.path
        p.environment = env
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "CANDOR_POLICY env overrides the config")

        // (c) a set-but-unusable CANDOR_CONFIG fails closed (exit 2)
        let p2 = Process()
        p2.executableURL = bin
        p2.arguments = [root.path, "--out", root.appendingPathComponent("r3").path]
        var env2 = ProcessInfo.processInfo.environment
        env2["CANDOR_CONFIG"] = root.appendingPathComponent("no-such").path
        p2.environment = env2
        let errPipe = Pipe(); p2.standardError = errPipe; p2.standardOutput = Pipe()
        try p2.run()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        p2.waitUntilExit()
        XCTAssertEqual(p2.terminationStatus, 2, "a typo'd CANDOR_CONFIG must fail closed")
    }

    // ── config discovery is TARGET-anchored, never CWD (spec §3.4) ─────────────────────────────────
    // The old CWD fallback fired exactly when the CWD was OUTSIDE the target's ancestry — i.e. it applied
    // an UNRELATED repo's config (and its policy) to this scan. Target in dir A, CWD in dir B with its own
    // deny-everything config: B's config must NOT apply (exit 0, no gate, no "using config" line).
    func testUnrelatedCwdConfigDoesNotApply() throws {
        let bin = try binaryURL()
        let target = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: target) }
        let other = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-othercwd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        let otherCandor = other.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: otherCandor, withIntermediateDirectories: true)
        let denyAll = other.appendingPathComponent("deny.pol")
        try "deny Net\n".write(to: denyAll, atomically: true, encoding: .utf8)
        try "policy \(denyAll.path)\n".write(to: otherCandor.appendingPathComponent("config"),
                                             atomically: true, encoding: .utf8)

        let r = try run(bin, [target.path, "--out", target.appendingPathComponent("r").path], cwd: other)
        XCTAssertEqual(r.code, 0, "the CWD repo's config must NOT gate an unrelated target — stderr: \(r.err)")
        XCTAssertFalse(r.err.contains("AS-EFF"), "no gate may fire from the CWD's config: \(r.err)")
        XCTAssertFalse(r.err.contains("using config"), "no config was discovered for the TARGET: \(r.err)")
    }

    // ── a RELATIVE `policy` value in .candor/config resolves against the CONFIG's location ──────────
    // (family decision 2026-07-09) `policy .candor/gate.pol` names <root>/.candor/gate.pol wherever the
    // scan is invoked from — the old plain read resolved it against the invoker's CWD, so the same
    // checked-in config exited 2 (unreadable policy) from any other directory. Also pins the discovery
    // diagnostic: exactly which config governed the run is named on stderr.
    func testConfigRelativePolicyResolvesAgainstConfigLocation() throws {
        let bin = try binaryURL()
        let target = try makeNetFixture(qual: "Billing", urlLiteral: "https://api.stripe.com/v1/charges")
        defer { try? FileManager.default.removeItem(at: target) }
        let candorDir = target.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candorDir, withIntermediateDirectories: true)
        try "deny Net\n".write(to: candorDir.appendingPathComponent("gate.pol"), atomically: true, encoding: .utf8)
        try "policy .candor/gate.pol\n".write(to: candorDir.appendingPathComponent("config"),
                                              atomically: true, encoding: .utf8)
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let r = try run(bin, [target.path, "--out", target.appendingPathComponent("r").path], cwd: elsewhere)
        XCTAssertEqual(r.code, 1, "the config-relative deny-Net policy must gate from ANY cwd — stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-006"), "the deny fires: \(r.err)")
        XCTAssertTrue(r.err.contains("using config \(candorDir.appendingPathComponent("config").path)"),
                      "the discovery diagnostic names the governing config: \(r.err)")
    }

    func testGateJsonDashStreamsAPureVerdictToStdout() throws {
        // `--gate-json -` (the §3.3 pipe form the other three engines accept) was rejected by the
        // dash-guard; it must stream the verdict as PURE stdout JSON, AS-EFF lines on stderr.
        let bin = try binaryURL()
        let root = try makeNetFixture(qual: "Billing", urlLiteral: "https://evil.example.com/x")
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = root.appendingPathComponent("policy.txt")
        try "deny Net\n".write(to: policy, atomically: true, encoding: .utf8)
        let r = try run(bin, [root.path, "--policy", policy.path, "--gate-json", "-"])
        XCTAssertEqual(r.code, 1)
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, false, "stdout parses as the pure verdict — stdout: \(r.out.prefix(200))")
        XCTAssertTrue(r.err.contains("AS-EFF-006"), "the AS-EFF line goes to stderr: \(r.err)")
    }
}
