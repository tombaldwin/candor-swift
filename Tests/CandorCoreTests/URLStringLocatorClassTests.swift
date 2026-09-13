import XCTest
import Foundation

/// SOUNDNESS R420 — **TWO SPELLINGS OF ONE DESTINATION DISAGREED, AND THE PROTECTED-FOLDER CLASS
/// SURVIVED ONLY ONE OF THEM.**
///
/// `resolveConstString`/`locatorCtorLiteral` treat `URL(string: X)` and `URL(fileURLWithPath: X)`
/// identically. That is correct for the Net surface they were built for and wrong the moment the result
/// lands in `paths`, because `pathClasses` decides the class from a PREFIX and a scheme defeats it.
/// MEASURED on the shipped 0.37.0 binary, the same file named two ways:
///
///     URL(fileURLWithPath: "/Users/t/Desktop/x").checkResourceIsReachable()
///         → inferred ["FolderDesktop", "Fs"]   `deny FolderDesktop` EXIT 1
///     URL(string: "file:///Users/t/Desktop/x")!.checkResourceIsReachable()
///         → inferred ["Fs"]                    `deny FolderDesktop` EXIT 0   ← SILENT
///
/// **An app whose privacy manifest lacks `NSDesktopFolderUsageDescription` verified green.** And because
/// a literal WAS captured, R395's incompleteness guard never fired either — the report said the surface
/// was complete while the class it existed to name had been dropped.
///
/// The mirror, in the same family: `URL(string: "https://example.com/a")` was published in `paths` as
/// a FILESYSTEM path. Lower severity (it fails closed against an allowlist) but a false claim in the
/// report, and the over-charge direction of the same confusion.
///
/// **THE FIX HAS ONE OWNER ON PURPOSE.** Four sites inserted into `paths` directly, which is how one
/// could publish a URL string while another published a path. They now all route through
/// `insertFsPath`, and the protected-folder classification happens there against the NORMALISED path —
/// it used to run on the raw literal, which is precisely where this hid.
final class URLStringLocatorClassTests: XCTestCase {
    private static let DESKTOP = "/Users/t/Desktop/secret.txt"

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

    private static func tree(_ ctor: String) -> String {
        """
        import Foundation
        public func peek() throws {
            _ = try? \(ctor).checkResourceIsReachable()
        }
        """
    }

    /// THE DECISION. Not "the URL spelling is handled" but "the two spellings AGREE" — which is the only
    /// form of this assertion that cannot be satisfied by a fix that changes both in the same wrong way.
    func testTheTwoSpellingsOfOneDestinationAgree() throws {
        let byPath = try scan(Self.tree("URL(fileURLWithPath: \"\(Self.DESKTOP)\")"), name: "R420Path")
        let byURL  = try scan(Self.tree("URL(string: \"file://\(Self.DESKTOP)\")!"), name: "R420URL")
        let a = try XCTUnwrap(byPath.fns["peek"], "peek absent from the path spelling:\n\(byPath.out)")
        let b = try XCTUnwrap(byURL.fns["peek"], "peek absent from the URL spelling:\n\(byURL.out)")
        XCTAssertEqual(a["paths"] as? [String], [Self.DESKTOP],
                       "the control spelling must publish the bare path — if this moved, the arm below "
                       + "is comparing two wrong answers")
        XCTAssertEqual(b["paths"] as? [String], a["paths"] as? [String],
                       "the same file named two ways must publish the same path:\n\(byURL.out)")
        XCTAssertEqual((b["inferred"] as? [String])?.sorted(), (a["inferred"] as? [String])?.sorted(),
                       "the protected-folder class must not depend on the spelling:\n\(byURL.out)")
    }

    /// The verdict, separately from the report: this is the arm that says a privacy manifest gap is
    /// actually CAUGHT rather than merely described.
    func testTheURLSpellingIsNamedByADenyOfItsFolderClass() throws {
        let r = try scan(Self.tree("URL(string: \"file://\(Self.DESKTOP)\")!"),
                         name: "R420Deny", policy: "deny FolderDesktop\n")
        XCTAssertEqual(r.code, 1, "`deny FolderDesktop` must fire on the file:// spelling:\n\(r.out)")
    }

    /// Foundation's own parser does the decoding, so the escaped form is not a separate rule to get
    /// wrong. A fix by string surgery (`dropFirst(7)`) passes the arm above and fails this one.
    func testAPercentEscapedFileURLDecodesToItsRealPath() throws {
        let r = try scan(Self.tree("URL(string: \"file:///Users/t/Desktop/my%20secret.txt\")!"),
                         name: "R420Escaped")
        let fn = try XCTUnwrap(r.fns["peek"], "peek absent:\n\(r.out)")
        XCTAssertEqual(fn["paths"] as? [String], ["/Users/t/Desktop/my secret.txt"],
                       "the escape must be decoded by the parser that defines it:\n\(r.out)")
        XCTAssertTrue((fn["inferred"] as? [String])?.contains("FolderDesktop") ?? false,
                      "the folder class must survive decoding:\n\(r.out)")
    }

    /// The over-charge mirror: a non-file scheme names NO filesystem destination, so publishing it as a
    /// path is a fabrication. Withheld and disclosed, not silently dropped — dropping it while leaving
    /// the surface "complete" is R395's defect, which this must not reintroduce.
    func testAnHTTPURLIsNotPublishedAsAFilesystemPath() throws {
        let r = try scan(Self.tree("URL(string: \"https://example.com/a\")!"), name: "R420Http")
        let fn = try XCTUnwrap(r.fns["peek"], "peek absent:\n\(r.out)")
        XCTAssertNil(fn["paths"], "an https URL is not a filesystem path:\n\(r.out)")
        XCTAssertEqual(fn["incomplete"] as? [String], ["Fs"],
                       "withholding it must DISCLOSE, not silently drop — R395:\n\(r.out)")
    }

    /// And it must still fail closed against an allowlist, which is the property that makes withholding
    /// safe rather than merely tidy. **This arm passes against the pre-fix engine too** — there the https
    /// string was published as a path and simply did not match, so the verdict agreed for the wrong
    /// reason. It is kept as a GUARD (withholding a locator must never open a gate), not as evidence.
    func testAnHTTPURLLocatorFailsClosedAgainstAnAllowlist() throws {
        let r = try scan(Self.tree("URL(string: \"https://example.com/a\")!"),
                         name: "R420HttpGate", policy: "allow Fs /tmp/ok\n")
        XCTAssertEqual(r.code, 1, "an undetermined Fs destination cannot be certified:\n\(r.out)")
    }

    /// THE CONTROL THAT KEEPS THE SCHEME TEST HONEST: a relative name containing a colon is not a URL.
    /// The scheme rule requires the remainder to begin with `/` for exactly this reason, and without the
    /// control a future tightening could start reading `a:b` as scheme `a` and fail closed on a path.
    func testARelativeNameContainingAColonIsNotTreatedAsAURL() throws {
        let src = """
        import Foundation
        public func peek() throws {
            _ = try? URL(fileURLWithPath: "./odd:name.txt").checkResourceIsReachable()
        }
        """
        let r = try scan(src, name: "R420Colon")
        let fn = try XCTUnwrap(r.fns["peek"], "peek absent:\n\(r.out)")
        XCTAssertEqual(fn["paths"] as? [String], ["./odd:name.txt"],
                       "a colon in a filename does not make it a URL:\n\(r.out)")
    }
}
