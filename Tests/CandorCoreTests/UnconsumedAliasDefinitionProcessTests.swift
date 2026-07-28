import XCTest
import Foundation

/// ⟨0.24⟩ **A TYPO IN AN `unknown-alias` DEFINITION THE POLICY NEVER REFERENCES MUST NOT REFUSE THE
/// GATE** (SPEC §6.2 ⟨0.24⟩ + §3.1's precedence rule, candor-spec `4c79958`).
///
/// MEASURED 2026-07-28 on the identical triple — one `Fs`-reaching function, `deny Fs` (no bracket for an
/// alias to expand into), and an unused `unknown-alias corp = dispatch,nativ` beside the policy:
///
///     candor-rust    exit 1, the AS-EFF-006 violation CHARGED, the alias warned about on stderr
///     candor-swift   exit 2, refused — THE VIOLATION DELETED FROM EVERY MACHINE CHANNEL
///
/// `4919f68` wired the alias-definition token error into the same list as the policy's own token errors,
/// and that list is consumed by an unreadable-policy early exit which runs BEFORE — and therefore bypasses
/// — the violation-dominates-refusal precedence built the same day.
///
/// **AN ALIAS THE POLICY DOES NOT REFERENCE EXPANDS NO TOKEN, SO IT CANNOT CHANGE ANY VERDICT** — and a
/// thing that cannot change a verdict cannot make one unanswerable. At most it is a DISCLOSURE. The blast
/// radius is what makes it more than a curiosity: config discovery is an ANCESTOR WALK, so one bad token
/// in a parent `.candor/config` red-refused every gate in the whole subtree, including gates whose
/// policies never mention reason classes at all.
///
/// THE MIRROR IS PINNED IN THE SAME FILE, twice, because relaxing a refusal is exactly where a fail-open
/// gets introduced: a CONSUMED definition still refuses, and a definition that loses ALL its tokens still
/// refuses through the referring policy line. `PolicyClassTokenProcessTests` holds the third mirror
/// (`deny Unknown[house]` over `= dispatch,indirct`, the gate-relevant case) and must keep passing.
final class UnconsumedAliasDefinitionProcessTests: XCTestCase {

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// A source tree whose only function reaches `Fs`, plus a policy + a `.candor/config` BESIDE the
    /// policy (⟨0.24⟩ vocabulary anchors at the policy, not the scan target).
    private func makeScanRoot(policy: String, config: String) throws -> URL {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func readIt() -> String {
            return (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? ""
        }
        """)
        let candor = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candor, withIntermediateDirectories: true)
        try config.write(to: candor.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try policy.write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        return root
    }

    /// The same signature as a hand-written report, for the `gate --report` route.
    private func makeReportRoot(policy: String, config: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-unconsumed-\(UUID().uuidString)")
        let candor = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candor, withIntermediateDirectories: true)
        try """
        {"candor":{"spec":"0.23","toolchain":"swiftsyntax","version":"handwritten"},
         "package":"App","analyzed":{"count":1,"digest":"1111111111111111"},
         "functions":[{"fn":"app.readIt","loc":"a.swift:1:1","inferred":["Fs","Unknown"],
                       "direct":["Fs","Unknown"],"unresolved":true,"hash":"App#readIt","calls":[],
                       "unknownWhy":["callback:f"]}]}
        """.write(to: candor.appendingPathComponent("report.App.Swift.json"), atomically: true, encoding: .utf8)
        try config.write(to: candor.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try policy.write(to: root.appendingPathComponent("pol.txt"), atomically: true, encoding: .utf8)
        return root
    }

    // ── THE ROW ────────────────────────────────────────────────────────────────────────────────────

    func testAnUnconsumedAliasTypoDoesNotDeleteACertainViolationOnTheScanRoute() throws {
        let root = try makeScanRoot(policy: "deny Fs\n", config: "unknown-alias corp = dispatch,nativ\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let v = root.appendingPathComponent("v.json")
        let r = try ProcessHarness.run(bin(), [root.path, "--out", root.appendingPathComponent("r").path,
                                               "--policy", root.appendingPathComponent("pol.txt").path,
                                               "--gate-json", v.path])
        XCTAssertEqual(r.code, 1, "`deny Fs` has no bracket for `corp` to expand into, so the alias cannot "
                       + "change this verdict — the Fs violation is CERTAIN. stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: v)) as? [String: Any]
        let vs = d?["violations"] as? [[String: Any]]
        XCTAssertEqual(vs?.count, 1, "AND IT MUST BE IN THE DOCUMENT: \(String(describing: d))")
        XCTAssertEqual(vs?.first?["rule"] as? String, "AS-EFF-006")
        XCTAssertNil(d?["refused"], "not a refusal: \(String(describing: d))")
        // The definition is still DISCLOSED — it is a disclosure, not a nothing.
        XCTAssertTrue(r.err.contains("`nativ`"), "the bad token must still be named on stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("corp"), "and the alias it defines: \(r.err)")
    }

    func testAnUnconsumedAliasTypoDoesNotDeleteACertainViolationOnTheReportRoute() throws {
        let root = try makeReportRoot(policy: "deny Fs\n", config: "unknown-alias corp = dispatch,nativ\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), ["gate", "--report", root.path,
                                               "--policy", root.appendingPathComponent("pol.txt").path,
                                               "--json"])
        XCTAssertEqual(r.code, 1, "the two routes must agree about which policies are readable. stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        XCTAssertEqual((d?["violations"] as? [[String: Any]])?.count, 1,
                       "the certain violation must be in the document: \(r.out)")
    }

    // ── THE MIRRORS. Relaxing a refusal is exactly where a fail-open gets introduced ────────────────

    /// The alias IS consumed: `deny Unknown[corp]` expands through the broken definition, which silently
    /// defines `corp` as `{dispatch}` and stops gating the `native` hole it was written for. Still exit 2.
    func testAConsumedAliasTypoStillRefusesOnBothRoutes() throws {
        let scanRoot = try makeScanRoot(policy: "deny Unknown[corp]\n",
                                        config: "unknown-alias corp = dispatch,nativ\n")
        defer { try? FileManager.default.removeItem(at: scanRoot) }
        let s = try ProcessHarness.run(bin(), [scanRoot.path, "--out", scanRoot.appendingPathComponent("r").path,
                                               "--policy", scanRoot.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(s.code, 2, "a CONSUMED definition narrows a live rule — that is still a policy "
                       + "error, and the relaxation above must not reach it. stderr: \(s.err)")
        XCTAssertTrue(s.err.contains("`nativ`"), "naming the token: \(s.err)")

        let reportRoot = try makeReportRoot(policy: "deny Unknown[corp] app\n",
                                            config: "unknown-alias corp = dispatch,nativ\n")
        defer { try? FileManager.default.removeItem(at: reportRoot) }
        let g = try ProcessHarness.run(bin(), ["gate", "--report", reportRoot.path,
                                               "--policy", reportRoot.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(g.code, 2, "same on the report route: \(g.err)")
    }

    /// The definition loses ALL its tokens, so the alias is never entered in the map and the REFERRING
    /// policy line becomes the error. The reference gate must not swallow this: the alias name is absent
    /// from `usedAliases` precisely BECAUSE it could not be resolved.
    func testAnAliasThatLostEveryTokenStillRefusesThroughTheReferringLine() throws {
        let root = try makeScanRoot(policy: "deny Unknown[corp]\n", config: "unknown-alias corp = nativ\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), [root.path, "--out", root.appendingPathComponent("r").path,
                                               "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 2, "`corp` resolves to nothing, so `deny Unknown[corp]` WIDENS to a bare "
                       + "`deny Unknown` — the fail-open the token rule exists for. stderr: \(r.err)")
        XCTAssertTrue(r.err.contains("`corp`"), "the referring line names the unresolvable token: \(r.err)")
    }

    /// THE CONTROL: without a policy error at all, the same fixture + `deny Fs` exits 1. Without this the
    /// rows above cannot tell "the refusal was lifted" from "this fixture never violated anything".
    func testTheControlWithNoAliasFileAtAllStillFires() throws {
        let root = try makeScanRoot(policy: "deny Fs\n", config: "# no aliases here\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin(), [root.path, "--out", root.appendingPathComponent("r").path,
                                               "--policy", root.appendingPathComponent("pol.txt").path])
        XCTAssertEqual(r.code, 1, "control: the fixture must violate `deny Fs`. stderr: \(r.err)")
    }
}
