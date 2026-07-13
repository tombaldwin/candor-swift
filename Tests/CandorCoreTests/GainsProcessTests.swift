import XCTest
import Foundation

/// PROCESS-layer pins over the `gains` query verb (FixCLI.runGainsCLI) — the package-level supply-chain
/// alarm (SPEC §5.1). Read-only over report files this suite writes by hand (gains never scans), spawned
/// via ProcessHarness in PathProcessTests' style. Pins the four max-review findings on the verb:
///   A — a NON-EMPTY functions array whose every entry is junk is a CORRUPT report (exit 2), never a
///       {byFunction:[],gained:[]} all-clear;
///   B — the legacy bare-array report form is accepted (a bare `[]` is a VALID clean-empty baseline,
///       as rust/ts/java answer it);
///   C — §2.1 producing-build provenance: baseline_version/engine_version in the JSON + the one-line
///       stderr ⚠ mismatch disclosure;
///   D — a PARTIAL baseline callgraph (a matched sidecar failed to parse) degrades origin to
///       "unknown", never mislabels the dropped file's fns "new".
final class GainsProcessTests: XCTestCase {

    /// A scratch dir the fixture reports live in; callers `defer` removal.
    private func makeDir() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-gains-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ dir: URL, _ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private let curEnvelope = """
    {"candor":{"version":"candor-swift-0.11.0"},"functions":[{"fn":"Pkg.doNet","inferred":["Net"]}]}
    """

    /// FINDING A: a report whose NON-EMPTY functions array yields ZERO usable entries (every entry
    /// dropped) is a parse FAILURE (exit 2 + a naming stderr disclosure) — not a successfully-parsed
    /// empty report that prints a false {byFunction:[],gained:[]} all-clear at exit 0.
    func testAllJunkReportFailsLoud() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(#"{"functions":[{"bogus":1},{"fn":""}]}"#, dir, "cur.json")
        let base = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base, "--json"])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("no usable functions"), r.err)
        XCTAssertTrue(r.err.contains("cur.json"), r.err)
        XCTAssertFalse(r.out.contains("byFunction"), "must not emit an all-clear JSON: \(r.out)")
    }

    /// A well-formed EMPTY functions array stays a VALID pure report — success, not corruption.
    func testEmptyEnvelopeBaselineIsValid() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.out, "Pkg.doNet\tNet\n")
    }

    /// FINDING B: the legacy v0.1 bare-array report — here the clean-empty `[]` every other engine
    /// accepts — is a VALID baseline (exit 0), not a rejected parse (the old behavior exited 2 while
    /// rust/ts/java answered).
    func testBareArrayCleanEmptyBaseline() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write("[]", dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["gained"] as? [String], ["Net"])
        // A bare-array baseline carries no §2.1 header — provenance is the honest "".
        XCTAssertEqual(d["baseline_version"] as? String, "")
        XCTAssertEqual(d["engine_version"] as? String, "candor-swift-0.11.0")
    }

    /// A NON-EMPTY bare-array report still parses (legacy entries load), and effects subtract normally.
    func testBareArrayNonEmptyBaseline() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write(#"[{"fn":"Pkg.doNet","inferred":["Net"]}]"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.out, "", "no gains when the baseline already has the effect: \(r.out)")
    }

    /// FINDING C: when BOTH producing builds are known and differ, gains discloses on stderr (the gain
    /// may be engine reclassification, not the dependency changing) and the JSON carries the
    /// baseline_version/engine_version provenance fields — mirrors candor-ts/candor-java.
    func testVersionMismatchDisclosure() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write(#"{"candor":{"version":"candor-swift-0.10.0"},"functions":[]}"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("⚠ baseline @candor-swift-0.10.0 ≠ engine @candor-swift-0.11.0"), r.err)
        XCTAssertTrue(r.err.contains("reclassifying"), r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["baseline_version"] as? String, "candor-swift-0.10.0")
        XCTAssertEqual(d["engine_version"] as? String, "candor-swift-0.11.0")

        // The human TSV surface is pinned byte-stable — stdout unchanged (disclosure is stderr-only).
        let t = try ProcessHarness.run(binary, ["gains", cur, base])
        XCTAssertEqual(t.code, 0, t.err)
        XCTAssertEqual(t.out, "Pkg.doNet\tNet\n")
        XCTAssertTrue(t.err.contains("⚠ baseline @"), t.err)
    }

    /// Matching versions: NO stderr disclosure; the provenance fields still emit (unconditional).
    func testMatchingVersionsNoDisclosure() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertFalse(r.err.contains("⚠"), r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["baseline_version"] as? String, "candor-swift-0.11.0")
        XCTAssertEqual(d["engine_version"] as? String, "candor-swift-0.11.0")
    }

    /// FINDING D: a PARTIAL baseline callgraph (two sidecars, one corrupt — its nodes dropped with the
    /// stderr disclosure) must NOT label a fn absent from the surviving half "new": the fn may have
    /// lived in the dropped file, so the honest origin is "unknown".
    func testPartialBaselineCallgraphDegradesOriginToUnknown() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "rep.A.Swift.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "rep.B.Swift.json")
        _ = try write(#"{"Other.fn":[]}"#, dir, "rep.A.Swift.callgraph.json")
        _ = try write("NOT JSON{{{", dir, "rep.B.Swift.callgraph.json")
        let basePrefix = dir.appendingPathComponent("rep").path

        let r = try ProcessHarness.run(binary, ["gains", cur, basePrefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("failed to parse"), r.err) // mergeCallgraph's disclosure kept
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(d["byFunction"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["origin"] as? String, "unknown", r.out)
    }

    /// The COMPLETE-graph control for the partial pin: with both sidecars valid and the fn in neither,
    /// origin is a confident "new" — the downgrade is scoped to the corrupt-sidecar case alone.
    func testCompleteBaselineCallgraphStillSaysNew() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "rep.A.Swift.json")
        _ = try write(#"{"Other.fn":[]}"#, dir, "rep.A.Swift.callgraph.json")
        _ = try write(#"{"Another.fn":["Other.fn"]}"#, dir, "rep.B.Swift.callgraph.json")
        let basePrefix = dir.appendingPathComponent("rep").path

        let r = try ProcessHarness.run(binary, ["gains", cur, basePrefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(d["byFunction"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["origin"] as? String, "new", r.out)
    }

    /// A node still IN the partial graph keeps "existing" — only the negative claim degrades.
    func testPartialGraphNodeStaysExisting() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "rep.A.Swift.json")
        _ = try write(#"{"Pkg.doNet":[]}"#, dir, "rep.A.Swift.callgraph.json")
        _ = try write("NOT JSON{{{", dir, "rep.B.Swift.callgraph.json")
        let basePrefix = dir.appendingPathComponent("rep").path

        let r = try ProcessHarness.run(binary, ["gains", cur, basePrefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(d["byFunction"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["origin"] as? String, "existing", r.out)
    }
}
