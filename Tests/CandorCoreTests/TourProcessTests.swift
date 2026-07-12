import XCTest
import Foundation

/// PROCESS-layer pins over the `tour` query verb (FixCLI.runTourCLI) — the on-demand, top-N version of the
/// cold-repo opener (SURFACE-BEST-FIND-DESIGN.md, P2). Read-only over a report a scan wrote; NO re-scan.
/// Spawns the BUILT binary via ProcessHarness. The human + JSON formats match the Rust reference
/// `candor-query tour` byte-for-byte (a conformance PART pins this four-way).
final class TourProcessTests: XCTestCase {

    /// A fixture whose `Settings.load` inherits Net 3 hops down via `NetLayer.doSend`, plus a benign
    /// `Model.render` 1 hop away and an EFFECTY-named `api.fetch` that must NOT surface.
    private let fixture = """
    import Foundation
    import Network

    enum NetLayer {
        static func doSend() {
            let c = NWConnection(host: "example.com", port: 443, using: .tcp)
            c.start(queue: .main)
        }
    }
    enum Core {
        static func syncState() { NetLayer.doSend() }
        static func refresh() { syncState() }
    }
    struct Settings { static func load() { Core.refresh() } }
    struct Model { static func render() { NetLayer.doSend() } }
    """

    /// Scan the fixture into `<root>/.candor/report.*` and return the report PREFIX for `--report`.
    private func scanned(_ binary: URL, _ root: URL) throws -> String {
        let prefix = root.appendingPathComponent(".candor/report").path
        let r = try ProcessHarness.run(binary, [root.appendingPathComponent("Sources/App").path, "--out", prefix])
        try XCTSkipUnless(r.code == 0, "scan failed: \(r.err)")
        return prefix
    }

    func testTourHumanListsRankedReaches() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["tour", "--report", prefix])
        XCTAssertEqual(r.code, 0, r.err)
        // Header: crate is the prefix basename (`report`); 3 reaches → plural "reaches".
        XCTAssertTrue(r.out.hasPrefix("candor tour — the 3 most surprising reaches in report:\n"), r.out)
        // The benign-deep reach ranks first, with its ready-to-run command.
        XCTAssertTrue(r.out.contains("1. `Settings.load` performs Net, 3 hops away via `NetLayer.doSend`"), r.out)
        XCTAssertTrue(r.out.contains("→  candor path Settings.load Net"), r.out)
        // The EFFECTY-named fn never appears.
        XCTAssertFalse(r.out.contains("api.fetch"), r.out)
    }

    func testTourNCapsAndSingularWording() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["tour", "1", "--report", prefix])
        XCTAssertEqual(r.code, 0, r.err)
        // N=1 → singular "reach", exactly one numbered line, the top-scoring Settings.load.
        XCTAssertTrue(r.out.hasPrefix("candor tour — the 1 most surprising reach in report:\n"), r.out)
        XCTAssertTrue(r.out.contains("1. `Settings.load`"), r.out)
        XCTAssertFalse(r.out.contains("2. `"), r.out)
    }

    func testTourJSONShapeAndSortedKeys() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["tour", "--json", "--report", prefix])
        XCTAssertEqual(r.code, 0, r.err)
        // stdout is a single compact JSON line with keys sorted alphabetically (matching serde_json::Value).
        XCTAssertTrue(r.out.hasPrefix("{\"reaches\":["), r.out)
        let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        let reaches = try XCTUnwrap(d?["reaches"] as? [[String: Any]])
        XCTAssertEqual(reaches.first?["fn"] as? String, "Settings.load")
        XCTAssertEqual(reaches.first?["hops"] as? Int, 3)
        XCTAssertEqual(reaches.first?["effect"] as? String, "Net")
        // The JSON substring for the first reach has keys in alphabetical order.
        XCTAssertTrue(r.out.contains("{\"effect\":\"Net\",\"fn\":\"Settings.load\",\"hops\":3,"), r.out)
    }

    func testTourFailsLoudWithNoReport() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        // A prefix that resolves to no report → exit 2, never a silent empty answer.
        let r = try ProcessHarness.run(binary, ["tour", "--report", "/nonexistent/candor-tour/report"])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("no report"), r.err)
    }

    func testTourRejectsNonIntegerN() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(fixture)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try scanned(binary, root)

        let r = try ProcessHarness.run(binary, ["tour", "notanumber", "--report", prefix])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("N is a non-negative integer"), r.err)
    }
}
