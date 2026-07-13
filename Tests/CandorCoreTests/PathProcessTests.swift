import XCTest
import Foundation

/// PROCESS-layer pins over the `path` query verb (FixCLI.runPathCLI) — the read-only provenance trace the
/// scan-note / `tour` opener names as its ready-to-run follow-up (SPEC §3.1). Read-only over a report a scan
/// wrote; NO re-scan. Spawns the BUILT binary via ProcessHarness. The human + `--json` formats match the
/// Rust reference `candor-query path` byte-for-byte (conformance PART 5 pins the shape four-way).
final class PathProcessTests: XCTestCase {

    /// `Settings.load` inherits Net 2 hops down via `NetLayer.doSend` (the DIRECT source). The intermediary
    /// `Core.relay` carries Net inherited; `NetLayer.doSend` is the direct source.
    private let fixture = """
    import Foundation
    import Network

    enum NetLayer {
        static func doSend() {
            let c = NWConnection(host: "example.com", port: 443, using: .tcp)
            c.start(queue: .main)
        }
    }
    enum Core { static func relay() { NetLayer.doSend() } }
    struct Settings { static func load() { Core.relay() } }
    """

    /// Scan the fixture into `<root>/.candor/report.*` and return the report PREFIX for `--report`.
    private func scanned(_ binary: URL, _ root: URL) throws -> String {
        let prefix = root.appendingPathComponent(".candor/report").path
        let r = try ProcessHarness.run(binary, [root.appendingPathComponent("Sources/App").path, "--out", prefix])
        try XCTSkipUnless(r.code == 0, "scan failed: \(r.err)")
        return prefix
    }

    func testPathHumanTracesTheChain() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["path", "Settings.load", "Net", "--report", prefix])
        XCTAssertEqual(r.code, 0, r.err)
        // Header, then the indented chain down to the DIRECT source, tagged `[Net source @ file:line]`.
        XCTAssertTrue(r.out.hasPrefix("candor path — how `Settings.load` comes to perform Net:\n"), r.out)
        XCTAssertTrue(r.out.contains("\n  Settings.load\n"), r.out)
        XCTAssertTrue(r.out.contains("\n    → Core.relay\n"), r.out)
        XCTAssertTrue(r.out.contains("→ NetLayer.doSend   [Net source @ "), r.out)
    }

    /// A substring match resolves like the Rust reference (`find(exact).or_else(find(contains))`).
    func testPathSubstringMatch() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["path", "load", "Net", "--report", prefix])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("how `Settings.load` comes to perform Net"), r.out)
    }

    func testPathJSONShape() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["path", "Settings.load", "Net", "--report", prefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        // The §3.1 pinned shape: { effect, fn, path:[{ fn, loc, source }] }.
        XCTAssertEqual(d["effect"] as? String, "Net")
        XCTAssertEqual(d["fn"] as? String, "Settings.load")
        let steps = try XCTUnwrap(d["path"] as? [[String: Any]])
        XCTAssertEqual(steps.map { $0["fn"] as? String }, ["Settings.load", "Core.relay", "NetLayer.doSend"])
        // Only the last step is the source; each carries a file:line loc.
        XCTAssertEqual(steps.map { $0["source"] as? Bool }, [false, false, true])
        XCTAssertTrue((steps.last?["loc"] as? String ?? "").contains(":"), r.out)
    }

    /// A fn that does not perform the effect is the honest empty answer (exit 0), NOT an error. Human names
    /// it with the inferred set; `--json` emits `{effect, fn, path:[]}` (a `jq` consumer never chokes).
    func testPathDoesNotPerformEffect() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["path", "Settings.load", "Fs", "--report", prefix])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("Settings.load does not perform Fs"), r.out)

        let j = try ProcessHarness.run(binary, ["path", "Settings.load", "Fs", "--report", prefix, "--json"])
        XCTAssertEqual(j.code, 0, j.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(j.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["effect"] as? String, "Fs")
        XCTAssertEqual((d["path"] as? [Any])?.count, 0)
    }

    /// A missing report fails LOUD (exit 2) — never a silent empty answer (matches the family).
    func testPathFailsLoudWithNoReport() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(binary, ["path", "foo", "Net", "--report", "/nonexistent/candor-path/report"])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("no report"), r.err)
    }

    /// An unmatched fn fails LOUD (exit 2), matching the other engines.
    func testPathFailsLoudOnUnmatchedFn() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["path", "no_such_fn_zzz", "Net", "--report", prefix])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("no function matching"), r.err)
    }

    /// Two positionals are required — a single positional is a usage error (exit 2).
    func testPathRequiresTwoPositionals() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["path", "Settings.load", "--report", prefix])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("usage: candor-swift path"), r.err)
    }
}
