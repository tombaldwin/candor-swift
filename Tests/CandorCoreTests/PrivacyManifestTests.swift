import XCTest
import Foundation

/// PROCESS-layer pins over the `privacy-manifest` verb (PrivacyManifestCLI.runPrivacyManifestCLI) — the
/// `privacy/1` extension's product surface (SPEC-EXTENSION-privacy.md, "Product surface"). Scans a real
/// fixture reaching Location+Contacts (so the privacy classifier + the reach are genuinely exercised, not
/// hand-written), then drives GENERATE and VERIFY against hand-built Info.plists. Pins:
///   (a) GENERATE names the Location/Contacts keys;
///   (b) VERIFY against a plist declaring both → ok:true, exit 0;
///   (c) VERIFY against a plist declaring only Location → underDeclared=[Contacts], exit 1;
///   (d) VERIFY against a plist ALSO declaring NSCameraUsageDescription → overDeclared=[NSCamera…], ok:true, exit 0;
///   (e) a missing/corrupt plist → exit 2 loud;
///   (f) Notify reached but no key required → NOT under-declared.
final class PrivacyManifestTests: XCTestCase {

    /// Scan a fixture and write a report under a scratch prefix; return the prefix path.
    private func scanToReport(_ src: String) throws -> (binary: URL, prefix: String, cleanup: () -> Void) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src)
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-pv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let prefix = outDir.appendingPathComponent("report").path
        let r = try ProcessHarness.run(bin, [root.path, "--out", prefix])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return (bin, prefix, {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outDir)
        })
    }

    /// A fixture reaching BOTH Location (CoreLocation) and Contacts (Contacts framework).
    private let locationAndContacts = """
    import Foundation
    import CoreLocation
    import Contacts
    struct Tracker {
        let manager = CLLocationManager()
        func whereAmI() { manager.requestLocation() }
    }
    struct Book {
        func load() {
            let store = CNContactStore()
            _ = try? store.unifiedContacts(matching: .init(), keysToFetch: [])
        }
    }
    Tracker().whereAmI()
    Book().load()
    """

    private func writePlist(_ keys: [String], _ dir: URL) throws -> String {
        var body = ""
        for k in keys { body += "\t<key>\(k)</key>\n\t<string>because</string>\n" }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)</dict>
        </plist>
        """
        let url = dir.appendingPathComponent("Info-\(UUID().uuidString).plist")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // ── (a) GENERATE names the Location + Contacts usage-description keys ────────────────────────────
    func testGenerateNamesRequiredKeys() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let reached = try XCTUnwrap(d["reached"] as? [String])
        XCTAssertTrue(reached.contains("Location") && reached.contains("Contacts"), r.out)
        let required = try XCTUnwrap(d["required"] as? [String: [String]])
        XCTAssertEqual(required["Location"]?.first, "NSLocationWhenInUseUsageDescription", r.out)
        XCTAssertEqual(required["Contacts"], ["NSContactsUsageDescription"], r.out)
    }

    // ── (b) VERIFY against a plist declaring BOTH keys → ok:true, exit 0 ─────────────────────────────
    func testVerifyBothDeclaredIsClean() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        let plist = try writePlist(["NSLocationWhenInUseUsageDescription", "NSContactsUsageDescription"], dir)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["ok"] as? Bool, true, r.out)
        XCTAssertEqual((d["underDeclared"] as? [Any])?.count, 0, r.out)
        XCTAssertEqual((d["overDeclared"] as? [String])?.count, 0, r.out)
    }

    // ── (c) VERIFY against a plist declaring ONLY Location → underDeclared=[Contacts], exit 1 ────────
    func testVerifyMissingContactsUnderDeclares() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        let plist = try writePlist(["NSLocationWhenInUseUsageDescription"], dir)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist, "--json"])
        XCTAssertEqual(r.code, 1, "an under-declaration must exit 1 — stderr: \(r.err)")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["ok"] as? Bool, false, r.out)
        let under = try XCTUnwrap(d["underDeclared"] as? [[String: Any]])
        XCTAssertEqual(under.count, 1, r.out)
        XCTAssertEqual(under.first?["effect"] as? String, "Contacts", r.out)
        XCTAssertEqual(under.first?["keys"] as? [String], ["NSContactsUsageDescription"], r.out)
        XCTAssertFalse((under.first?["fns"] as? [String] ?? []).isEmpty, "the reaching fns must be named: \(r.out)")

        // Human mode carries the ✗ divergence line and also exits 1.
        let h = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist])
        XCTAssertEqual(h.code, 1, h.err)
        XCTAssertTrue(h.out.contains("✗") && h.out.contains("Contacts") && h.out.contains("NSContactsUsageDescription"), h.out)
    }

    // ── (d) VERIFY against a plist ALSO declaring NSCameraUsageDescription → overDeclared, ok:true, exit 0 ─
    func testOverDeclarationAloneIsExitZero() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        let plist = try writePlist(
            ["NSLocationWhenInUseUsageDescription", "NSContactsUsageDescription", "NSCameraUsageDescription"], dir)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist, "--json"])
        XCTAssertEqual(r.code, 0, "over-declaration alone is a warning, not a failure — stderr: \(r.err)")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["ok"] as? Bool, true, r.out)
        XCTAssertEqual((d["underDeclared"] as? [Any])?.count, 0, r.out)
        XCTAssertEqual(d["overDeclared"] as? [String], ["NSCameraUsageDescription"], r.out)
    }

    // ── (e) a missing/corrupt plist → exit 2 loud ───────────────────────────────────────────────────
    func testMissingPlistFailsLoud() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", "/no/such/Info.plist"])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("could not be read or parsed"), r.err)
        XCTAssertFalse(r.out.contains("\"ok\""), "must not emit a result over an unreadable manifest: \(r.out)")
    }

    func testCorruptPlistFailsLoud() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        let bad = dir.appendingPathComponent("bad.plist")
        try "this is not a plist {{{".write(to: bad, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", bad.path])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("could not be read or parsed"), r.err)
    }

    // ── (f) Notify reached but no key required → NOT under-declared (clean verify) ────────────────────
    func testNotifyReachedNeedsNoKey() throws {
        let (bin, prefix, cleanup) = try scanToReport("""
        import Foundation
        import UserNotifications
        struct Alert {
            func ping() {
                let center = UNUserNotificationCenter.current()
                center.add(UNNotificationRequest(identifier: "x", content: .init(), trigger: nil))
            }
        }
        Alert().ping()
        """)
        defer { cleanup() }
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        // A plist declaring NO usage-description keys at all.
        let plist = try writePlist([], dir)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist, "--json"])
        XCTAssertEqual(r.code, 0, "Notify needs no Info.plist key — an empty plist is still clean; stderr: \(r.err)")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["ok"] as? Bool, true, r.out)
        XCTAssertEqual((d["reached"] as? [String]), ["Notify"], r.out)
        XCTAssertEqual((d["underDeclared"] as? [Any])?.count, 0, "Notify must never be under-declared: \(r.out)")
    }

    // A binary plist parses too (NSDictionary/PropertyListSerialization handle both encodings).
    func testBinaryPlistParses() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        let dict: [String: Any] = [
            "NSLocationWhenInUseUsageDescription": "because",
            "NSContactsUsageDescription": "because",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let plist = dir.appendingPathComponent("Info-binary.plist")
        try data.write(to: plist)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist.path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["ok"] as? Bool, true, r.out)
    }
}
