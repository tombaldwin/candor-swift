import XCTest
import Foundation

/// THE REPORT MUST NOT DIFFER FROM ITSELF.
///
/// `23eafc2` fixed the first instance (`supertypesOf` is a `[String: Set<String>]` and Swift seeds Set
/// hashing PER PROCESS, so `.first(where:)` picked a different supertype per run and the `unknownWhy`
/// reason churned). This suite pins the second, which lived in the code path added after it: the
/// protocol-CHA union entries were appended inside two DICTIONARY loops (`conformers`, then `byMethod`),
/// so the ORDER in which they land in `functions` varied per process. Measured on the release binary
/// before the fix: five runs over Alamofire under `CANDOR_WORKSPACE_CHAIN=1` produced five different
/// report hashes carrying the same 879 union entries.
///
/// WHY THE ASSERTION IS A PROPERTY AND NOT A DOUBLE SCAN. Two scans inside ONE test process share a hash
/// seed, so "run it twice and compare" can pass while the defect is live — the trap `23eafc2` recorded.
/// The property asserted instead is the one the fix establishes: the union entries appear in ascending
/// `hash` order, which is a total order (`<pkg>#<proto>.<method>`, and (proto, method) is a key pair).
///
/// This matters more than its blast radius suggests. A/B diffing reports on real code is this project's
/// primary evidence, and a report that differs from itself injects noise into every diff; `gains` — the
/// supply-chain effect-diff — goes noisy between identical inputs, which is product-facing. And the path
/// it survived in is the cross-package PUBLISHING path: these are the bytes a chained consumer reads.
final class ReportDeterminismProcessTests: XCTestCase {

    /// Several protocols, several conformers each, every conformed method effectful — so the union
    /// emitter has enough entries that a random order is essentially never the sorted one.
    private func makeFixture() throws -> URL {
        var src = "import Foundation\n"
        for p in ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"] {
            src += "protocol \(p) { func run(); func stop() }\n"
            for c in ["One", "Two", "Three"] {
                src += """
                struct \(p)\(c): \(p) {
                    func run() { try? "x".write(toFile: "/tmp/\(p)\(c)", atomically: true, encoding: .utf8) }
                    func stop() { print(ProcessInfo.processInfo.environment["\(p)\(c)"] ?? "") }
                }

                """
            }
        }
        return try ProcessHarness.makePackage(src, name: "Det")
    }

    func testProtocolUnionEntriesAreEmittedInADeterministicOrder() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        let r = try ProcessHarness.run(bin, [root.path, "--out", out.path],
                                       env: ["CANDOR_WORKSPACE_CHAIN": "1"])
        XCTAssertEqual(r.code, 0, "scan must succeed; stderr: \(r.err)")

        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.Det.Swift.json"))) as! [String: Any]
        let fns = (d["functions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let unionHashes = fns.filter { $0["interfaceUnion"] as? Bool == true }
            .compactMap { $0["hash"] as? String }

        // the trigger must actually fire — an empty list would make the ordering assertion vacuous
        XCTAssertGreaterThanOrEqual(unionHashes.count, 10,
                                    "the fixture must produce enough union entries to order; got \(unionHashes)")
        XCTAssertEqual(unionHashes, unionHashes.sorted(),
                       "protocol-CHA union entries must be emitted in a deterministic (hash-sorted) order — "
                       + "they are appended from DICTIONARY iterations, whose order is per-process random")
    }

    /// The second direction: sorting must not change WHICH entries are emitted, only their order.
    func testSortingDidNotChangeTheUnionCONTENT() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("r")
        XCTAssertEqual(try ProcessHarness.run(bin, [root.path, "--out", out.path],
                                              env: ["CANDOR_WORKSPACE_CHAIN": "1"]).code, 0)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.Det.Swift.json"))) as! [String: Any]
        let fns = (d["functions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let unions = fns.filter { $0["interfaceUnion"] as? Bool == true }
        // 5 protocols x 2 requirements, each unioned over 3 conformers; `run` is Fs, `stop` is Env.
        XCTAssertEqual(Set(unions.compactMap { $0["fn"] as? String }),
                       Set(["Alpha", "Beta", "Gamma", "Delta", "Epsilon"].flatMap { ["\($0).run", "\($0).stop"] }))
        for u in unions {
            let inf = Set(u["inferred"] as? [String] ?? [])
            let expected: Set<String> = (u["fn"] as? String)?.hasSuffix(".run") == true ? ["Fs"] : ["Env"]
            XCTAssertEqual(inf, expected, "\(u["fn"] ?? "?") union content changed")
        }
        // …and an ORDINARY entry is untouched by the sort (it is appended before the union block).
        let ordinary = fns.filter { $0["interfaceUnion"] as? Bool != true }.compactMap { $0["fn"] as? String }
        XCTAssertEqual(ordinary, ordinary.sorted(), "ordinary entries were already emitted qual-sorted")
    }
}
