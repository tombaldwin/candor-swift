import XCTest
import Foundation
@testable import CandorCore

/// ⟨0.21⟩ The completeness manifest (COMPLETENESS-MANIFEST-DESIGN.md): distinguish provably-pure from
/// never-seen, and make incompleteness MACHINE-legible so a --gate-json/agent consumer can't read
/// `ok:true` over source candor never analyzed. Ports the candor-java reference (CompletenessManifestTest).
///
/// - Gap 1 — the report envelope carries `analyzed:{count,digest}`; the count is the analyzed universe
///   (pure leaves included, so it exceeds |functions|); the digest is stable across a same-input re-scan.
/// - Gap 2 — an UNREADABLE source file appears in the report's `unanalyzed`, and a CONFIGURED gate over it
///   fails closed: the verdict carries `ok:false, incomplete:true, unanalyzed:[…]` and the run exits 2
///   (could-not-evaluate) — never a green gate over unseen code. A real violation still exits 1.
final class CompletenessManifestTests: XCTestCase {

    /// An app with one effectful fn (Fs) and one PURE fn → the analyzed universe exceeds |functions|.
    private func app() throws -> URL {
        try ProcessHarness.makePackage(#"""
        import Foundation
        func reads() { _ = try? String(contentsOfFile: "/tmp/x", encoding: .utf8) }
        func pure(_ x: Int) -> Int { return x + 1 }
        """#)
    }

    /// Add an UNREADABLE .swift to the package's source dir (invalid UTF-8 so `String(contentsOfFile:)`
    /// returns nil — the try? failure that Driver silently skipped). Returns the file path.
    @discardableResult
    private func addUnreadable(_ root: URL, name: String = "App") throws -> String {
        let bad = root.appendingPathComponent("Sources/\(name)/Corrupt.swift")
        // 0xFF 0xFE are not valid UTF-8 lead bytes → `String(contentsOfFile:encoding:.utf8)` returns nil.
        try Data([0xFF, 0xFE, 0xFF, 0xFE]).write(to: bad)
        return bad.path
    }

    // Gap 1 (a): analyzed.count > effectful count for a fixture with a pure fn; (d) digest stable on re-scan.
    func testAnalyzedSummaryExceedsEffectfulCountAndDigestIsStable() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root) }

        let r1 = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r1.code, 0, r1.err)
        let env1 = try JSONSerialization.jsonObject(with: Data(r1.out.utf8)) as? [String: Any]
        let analyzed1 = env1?["analyzed"] as? [String: Any]
        XCTAssertNotNil(analyzed1, "the envelope always carries the completeness manifest")
        let count = analyzed1?["count"] as? Int ?? -1
        let functions = (env1?["functions"] as? [Any])?.count ?? 0
        XCTAssertGreaterThan(count, functions,
            "analyzed count includes pure fns the report omits (count=\(count), |functions|=\(functions))")
        let digest1 = analyzed1?["digest"] as? String ?? ""
        XCTAssertEqual(digest1.count, 16, "the digest is 16 hex chars")
        XCTAssertTrue(digest1.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
                      "the digest is lowercase hex")
        XCTAssertNil(env1?["unanalyzed"], "a complete scan carries no `unanalyzed` (byte-compatible)")

        // (d) the digest is stable across a same-input re-scan.
        let r2 = try ProcessHarness.run(bin, [root.path, "--json"])
        let env2 = try JSONSerialization.jsonObject(with: Data(r2.out.utf8)) as? [String: Any]
        let digest2 = (env2?["analyzed"] as? [String: Any])?["digest"] as? String ?? ""
        XCTAssertEqual(digest1, digest2, "the analyzed-set digest is stable across a same-input re-scan")
    }

    // Gap 2 (b): an unreadable file → `unanalyzed` in the report (bare scan still exit 0).
    func testUnreadableSourceIsMachineLegibleInTheReport() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root) }
        try addUnreadable(root)

        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "a bare scan does not fail on an unreadable file — it discloses it")
        let env = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        let un = env?["unanalyzed"] as? [[String: Any]]
        XCTAssertEqual(un?.count, 1, "the unreadable file is machine-legible in the report's `unanalyzed`")
        XCTAssertTrue((un?.first?["path"] as? String ?? "").contains("Corrupt"),
                      "the unanalyzed entry names the offending file")
        XCTAssertEqual(un?.first?["reason"] as? String, "source failed to read")
    }

    // Gap 2 (c): a configured gate over it → verdict {ok:false, incomplete:true, unanalyzed:[…]} + exit 2;
    // and a real violation still dominates (exit 1) while still disclosing the incompleteness.
    func testConfiguredGateOverUnanalyzedFailsClosed() throws {
        let bin = try ProcessHarness.binaryURL(for: type(of: self))
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root) }
        try addUnreadable(root)

        // (c) a CONFIGURED gate that finds NO violation still cannot certify → exit 2, verdict incomplete.
        let pol = root.appendingPathComponent("no-db.policy")
        try "deny Db\n".write(to: pol, atomically: true, encoding: .utf8)   // the app performs Fs, not Db
        let verdict = root.appendingPathComponent("v.json")
        let gated = try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--gate-json", verdict.path])
        XCTAssertEqual(gated.code, 2, "a gate over unanalyzed code cannot be green — exit 2 (could-not-evaluate)")
        let v = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict)) as? [String: Any]
        XCTAssertEqual(v?["ok"] as? Bool, false, "ok:false — the gate did not certify")
        XCTAssertEqual(v?["incomplete"] as? Bool, true, "incomplete:true")
        let vun = v?["unanalyzed"] as? [[String: Any]]
        XCTAssertEqual(vun?.count, 1, "the verdict names the unanalyzed unit (a machine learns WHY)")
        XCTAssertNotNil(v?["analyzed"] as? [String: Any], "the verdict mirrors the report's analyzed summary")
        XCTAssertNotNil((v?["analyzed"] as? [String: Any])?["count"] as? Int)

        // a real violation still dominates (exit 1), and the verdict still discloses incompleteness.
        let pol2 = root.appendingPathComponent("no-fs.policy")
        try "deny Fs\n".write(to: pol2, atomically: true, encoding: .utf8)  // the app performs Fs → a violation
        let verdict2 = root.appendingPathComponent("v2.json")
        let gated2 = try ProcessHarness.run(bin, [root.path, "--policy", pol2.path, "--gate-json", verdict2.path])
        XCTAssertEqual(gated2.code, 1, "a real violation outranks the incompleteness (exit 1)")
        let v2 = try JSONSerialization.jsonObject(with: Data(contentsOf: verdict2)) as? [String: Any]
        XCTAssertEqual(v2?["incomplete"] as? Bool, true, "the incompleteness is still disclosed on a violating run")
    }

    // The digest algorithm matches java's FNV-1a-64 byte-for-byte (one spec, one algorithm).
    func testFnv1aHexIsDeterministicAndWellFormed() {
        let a = fnv1aHex(["app.pure(x:)", "app.reads()"])
        let b = fnv1aHex(["app.pure(x:)", "app.reads()"])
        XCTAssertEqual(a, b, "same input → same digest")
        XCTAssertEqual(a.count, 16)
        XCTAssertNotEqual(a, fnv1aHex(["app.reads()"]), "a different set → a different digest")
        // The empty set is the FNV offset basis with no bytes consumed = 0xcbf29ce484222325.
        XCTAssertEqual(fnv1aHex([]), "cbf29ce484222325")
        // Byte-for-byte agreement with candor-java's FNV-1a-64 over the SAME sorted quals (one algorithm,
        // one spec) — the java reference computes these exact hexes (verified out-of-band):
        XCTAssertEqual(a, "7452ef9d9bc2102a", "matches candor-java's FNV-1a-64 for the same set")
    }
}
