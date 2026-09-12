import XCTest
import Foundation

/// SOUNDNESS R395 — THE ENGINE SAW THE DESTINATION, DISCARDED IT, AND CLAIMED THE SURFACE COMPLETE.
///
/// A path literal was recorded only if it contained a slash or began with `.` or `~`. A BARE RELATIVE
/// FILENAME failed that shape test and was dropped — while `lit != nil` kept the incompleteness guard
/// from firing. So `credentials.json`, `id_rsa` and `exfil.txt` each passed `allow Fs /tmp/benign.txt`
/// at **exit 0** beside one benign sibling write. Isolated, every one of them failed closed; the
/// sibling literal was the mask. Published no later than `6f9ef15` (2026-07-09).
///
/// The two arms are fixed DIFFERENTLY and this file pins both, because a uniform fix would have been
/// wrong twice over:
///   * the LABEL-keyed arm (`recordTwoPathFs`) knows the string IS the locator, so it RECORDS it —
///     which also lets `allow Fs id_rsa` legitimately certify;
///   * the POSITIONAL arm (`recordSurfaces`) cannot know that, because `fopen(p, "r")` hands it a MODE
///     string (R393), so recording would FABRICATE a path (R394's shape). It fails closed instead.
///
/// Both CONTROLS are here too: an ordinary absolute write and a fully-literal two-path copy must still
/// certify, or the fix is merely unusable rather than sound.
final class RelativePathSurfaceProcessTests: XCTestCase {
    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--json"]
        if let policy {
            let p = root.appendingPathComponent("p.pol")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        return (try ProcessHarness.fns(ofJson: r.out), r.code, r.out + r.err)
    }

    private static let masked = """
    import Foundation
    public func readCreds() throws -> String {
        try "x".write(toFile: "/tmp/benign.txt", atomically: true, encoding: .utf8)
        return try String(contentsOfFile: "credentials.json", encoding: .utf8)
    }
    public func steal() throws {
        try "x".write(toFile: "/tmp/benign.txt", atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(atPath: "id_rsa", toPath: "stolen.key")
    }
    public func legit() throws {
        try "x".write(toFile: "/tmp/benign.txt", atomically: true, encoding: .utf8)
    }
    """

    /// THE DECISION, not the behaviour: a benign sibling must not certify a bare-filename destination.
    func testBareRelativeFilenameIsNotMaskedByASiblingLiteral() throws {
        let r = try scan(Self.masked, name: "R395Mask", policy: "allow Fs /tmp/benign.txt\n")
        XCTAssertEqual(r.code, 1, "a bare relative destination beside a benign literal must NOT certify:\n\(r.out)")
        XCTAssertTrue(r.out.contains("readCreds"), "the positional arm must name readCreds:\n\(r.out)")
        XCTAssertTrue(r.out.contains("steal"), "the label-keyed arm must name steal:\n\(r.out)")
    }

    /// The two arms answer DIFFERENTLY on purpose, and the difference is the fix.
    func testLabelKeyedArmRecordsThePathWhileThePositionalArmFailsClosed() throws {
        let r = try scan(Self.masked, name: "R395Arms")
        let creds = try XCTUnwrap(r.fns["readCreds"], "readCreds absent:\n\(r.out)")
        XCTAssertEqual(creds["incomplete"] as? [String], ["Fs"],
                       "the positional arm could not tell the literal was the locator — it must fail closed")
        let steal = try XCTUnwrap(r.fns["steal"], "steal absent:\n\(r.out)")
        let paths = (steal["paths"] as? [String]) ?? []
        XCTAssertTrue(paths.contains("id_rsa") && paths.contains("stolen.key"),
                      "the label-keyed arm knows both strings ARE the locators and must record them, got \(paths)")
        XCTAssertNil(steal["incomplete"], "having recorded both locators it must NOT also claim incompleteness")
    }

    /// CONTROL — the fix must not make ordinary code uncertifiable, or nobody can adopt it.
    func testOrdinaryAbsolutePathsStillCertify() throws {
        let src = """
        import Foundation
        public func legit() throws { try "x".write(toFile: "/tmp/benign.txt", atomically: true, encoding: .utf8) }
        public func bothAllowed() throws {
            try FileManager.default.copyItem(atPath: "/tmp/benign.txt", toPath: "/tmp/benign2.txt")
        }
        """
        let r = try scan(src, name: "R395Ctl", policy: "allow Fs /tmp/benign.txt /tmp/benign2.txt\n")
        XCTAssertEqual(r.code, 0, "fully-literal allowed paths must still certify:\n\(r.out)")
        XCTAssertNil(try XCTUnwrap(r.fns["legit"])["incomplete"], "no spurious incompleteness on a plain write")
        XCTAssertNil(try XCTUnwrap(r.fns["bothAllowed"])["incomplete"], "no spurious incompleteness on a two-path copy")
    }
}
