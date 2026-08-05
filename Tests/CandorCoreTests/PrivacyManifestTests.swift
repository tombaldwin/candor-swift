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

    /// `--xml`: a paste-ready Info.plist fragment. GENERATE printed a human requirements list
    /// (`Contacts → NSContactsUsageDescription (reached by: …)`), which left a user with an existing
    /// plist to hand-write the XML, invent the description string, and merge by hand — the verb's name
    /// promised a manifest and delivered homework.
    func testXmlEmitsAPasteReadyFragmentWithPlaceholdersThatCannotShipByAccident() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Contacts
        let store = CNContactStore()
        _ = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: "a"),
                                       keysToFetch: [])
        """, name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--xml"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("<key>NSContactsUsageDescription</key>"), r.out)
        XCTAssertTrue(r.out.contains("<string>"), "a key without a string is not paste-ready: \(r.out)")
        // The description must be impossible to leave in by accident — Apple reviews these strings, and a
        // plausible-looking generated one would be both wrong and likely to ship.
        XCTAssertTrue(r.out.contains("TODO"), "the placeholder must announce itself: \(r.out)")
        // A FRAGMENT, not a whole plist: every real app already has one, and emitting a complete
        // document invites overwriting it.
        XCTAssertFalse(r.out.contains("<plist"), "must be a fragment, not a whole plist: \(r.out)")
    }

    /// `--verify --xml` prints exactly the fragment that would FIX the failure, and nothing else, so it
    /// pipes. A verify that names what is missing and then leaves you to look up how to write it has
    /// done half the job.
    func testVerifyXmlPrintsOnlyTheMissingKeysAndKeepsTheVerdict() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Contacts
        import AVFoundation
        let store = CNContactStore()
        _ = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: "a"),
                                       keysToFetch: [])
        let rec = try? AVAudioRecorder(url: URL(fileURLWithPath: "/tmp/x"), settings: [:])
        """, name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        // A plist that declares the microphone but NOT contacts.
        let plist = root.appendingPathComponent("Info.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>NSMicrophoneUsageDescription</key><string>to record</string>
        </dict></plist>
        """.write(to: plist, atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify", plist.path, "--xml"], cwd: root)
        XCTAssertEqual(r.code, 1, "an under-declaration is still exit 1 — the FORMAT must not move the verdict")
        XCTAssertTrue(r.out.contains("NSContactsUsageDescription"), "the missing key must be emitted: \(r.out)")
        XCTAssertFalse(r.out.contains("NSMicrophoneUsageDescription"),
                       "a key already declared is not missing and must not be re-emitted: \(r.out)")
    }

    /// Bare `--verify` discovers the Info.plist, so the documented flow has nothing to look up.
    func testBareVerifyDiscoversTheOnlyInfoPlist() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Contacts
        let s = CNContactStore()
        _ = try? s.containers(matching: nil)
        """, name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        try #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict></dict></plist>"#
            .write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify"], cwd: root)
        XCTAssertEqual(r.code, 1, "the fixture under-declares Contacts, so the verdict is 1: \(r.err)")
        XCTAssertTrue(r.err.contains("discovered"), "it must SAY which file it chose: \(r.err)")
        XCTAssertTrue(r.out.contains("NSContactsUsageDescription"), r.out)
    }

    /// SEVERAL plists → REFUSE. A repo with several shipped binaries has several manifests, and
    /// verifying the wrong one is a confident verdict about a binary the reader did not ask about —
    /// exactly the artifact `--target` exists to remove, reintroduced through the back door.
    func testBareVerifyRefusesWhenSeveralPlistsExist() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\nlet x = 1\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict></dict></plist>"#
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Apps/Other"),
                                                withIntermediateDirectories: true)
        try plist.write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try plist.write(to: root.appendingPathComponent("Apps/Other/Info.plist"), atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify"], cwd: root)
        XCTAssertEqual(r.code, 2, "ambiguity is could-not-evaluate, never a guess: \(r.err)\(r.out)")
        XCTAssertTrue((r.err + r.out).contains("refusing to guess"), r.err + r.out)
        XCTAssertTrue((r.err + r.out).contains("Apps/Other/Info.plist"), "it must NAME the candidates")
    }

    /// A bare `--verify` followed by another flag must not swallow it as a path.
    func testBareVerifyDoesNotEatTheNextFlag() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\nlet x = 1\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        try #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict></dict></plist>"#
            .write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify", "--json"], cwd: root)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("\"ok\""), "--json must still have been parsed as a FLAG: \(r.out)")
    }

    /// §6 of CONSTANT-PROVENANCE-DESIGN.md — the verify reports HOW COMPLETELY, not just which keys.
    /// Without this, reaching 57/57 would silently delete the "here are the keys I do not check" warning
    /// while coverage WITHIN several keys is still partial.
    func testVerifyReportsCoverageByDeterminationBasis() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\nlet x = 1\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        try #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict></dict></plist>"#
            .write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify"], cwd: root)
        XCTAssertTrue(r.out.contains("COVERAGE:"), r.out)
        XCTAssertTrue(r.out.contains("by type"), "the basis breakdown must appear: \(r.out)")
        XCTAssertTrue(r.out.contains("of Apple's"), "the denominator must be Apple's count, not ours: \(r.out)")
    }

    /// The ⊤ COUNT: file I/O whose path could not be determined. It is the concrete form of the folder-key
    /// caveat — those keys are unmodelled AND you cannot rule them out by inspection, and this says by how
    /// much. A function whose path IS a literal must not be counted, or the number means nothing.
    func testVerifyCountsFileOpsWithUndeterminedPaths() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-topcount-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/App"),
                                                withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        func known() { _ = FileManager.default.contents(atPath: "/Users/me/Desktop/x") }
        func unknown(_ p: String) { _ = FileManager.default.contents(atPath: p) }
        """.write(to: root.appendingPathComponent("Sources/App/main.swift"), atomically: true, encoding: .utf8)
        try #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict></dict></plist>"#
            .write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify"], cwd: root)
        XCTAssertTrue(r.out.contains("1 function(s) perform file I/O whose PATH"),
                      "exactly the undetermined one, not the literal one: \(r.out)")
        XCTAssertTrue(r.out.contains("unknown"), "and it must NAME it: \(r.out)")
        XCTAssertFalse(r.out.contains("(known"), "the determined-path function must not be counted: \(r.out)")
        // A LOWER BOUND, and it has to say so — undercounting a disclosure is the dangerous direction.
        XCTAssertTrue(r.out.contains("LOWER BOUND"), r.out)
    }

    /// ENTITLEMENT-SOURCED keys: a different kind of evidence, and the only route to a capability that
    /// has NO call site. Apple's page for NSCriticalMessaging links no symbol at all, because the
    /// capability is granted by an entitlement and the API it unlocks is ordinary messaging code.
    func testEntitlementGrantsRequireTheirKeyAndSayWhereThatCameFrom() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\nlet x = 1\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict></dict></plist>"#
        try empty.write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>com.apple.developer.messages.critical-messaging</key><true/>
        </dict></plist>
        """.write(to: root.appendingPathComponent("App.entitlements"), atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify"], cwd: root)
        XCTAssertTrue(r.out.contains("NSCriticalMessagingUsageDescription"), r.out)
        // It MUST say the evidence is a manifest, not code — presenting a plist diff as a call-graph
        // result would misrepresent what was checked.
        XCTAssertTrue(r.out.contains("not from code"), "the evidence must be labelled: \(r.out)")
    }

    /// An entitlement present but FALSE is not granted. Demanding a key for a capability the app has
    /// switched off is the fabrication direction, and cheap to get wrong when reading a plist.
    func testEntitlementSetToFalseDemandsNothing() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("import Foundation\nlet x = 1\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        try #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict></dict></plist>"#
            .write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>com.apple.developer.messages.critical-messaging</key><false/>
        </dict></plist>
        """.write(to: root.appendingPathComponent("App.entitlements"), atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify"], cwd: root)
        XCTAssertFalse(r.out.contains("grants 1 entitlement"),
                       "an entitlement set to false is not granted: \(r.out)")
    }
}
