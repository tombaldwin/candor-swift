import XCTest
import Foundation
// `XMLParser` lives in Foundation on Darwin and in the SEPARATE `FoundationXML` module on
// swift-corelibs-foundation. Without this the Linux leg does not merely skip a row, it FAILS TO
// COMPILE — `XMLParser` resolves to a bare `AnyObject` with no initializers. Found by running the
// suite in the `swift:6.1` container, which is the same lesson as the row two functions below.
#if canImport(FoundationXML)
import FoundationXML
#endif

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

    /// ⟨0.29⟩ EVENTKIT'S DIRECTION REACHES THE REPORT — the third family of three, and the one that never
    /// arrived. Apple splits Calendars into full-access (read) and write-only, `privacyKind` already
    /// classifies EventKit's verbs, and `PRIVACY_DIRECTION_KEYS` already splits the keys — but the ONLY
    /// caller of `privacyKind` was the general `kappaMember` branch, and an EventKit store call is handled
    /// by its own earlier branch (the one that discriminates Calendar from Reminders by entity type). So
    /// `privacy` came back ABSENT for Calendar and Reminders, the no-direction-proved fallback applied, and
    /// every key in the family counted as an acceptable alternative.
    ///
    /// MEASURED before the fix: a plist declaring ONLY `NSCalendarsWriteOnlyAccessUsageDescription`
    /// verified GREEN over `EKEventStore().calendars(for: .event)` — a READ. Apple rejects that app. The
    /// same probe against Health (write over Share-only) and Photos (read over Add-only) exits 1, so this
    /// was the one family whose direction was silently missing while a code comment two hundred lines away
    /// still claimed NONE of the three were covered.
    ///
    /// THE SHAPE, for the third time in this rung: a refinement the general path performs and a carved-out
    /// special case does not (`FS_USE_VERBS` missed readv/writev; `EXEC_USE_VERBS` missed the cmds branch).
    /// When a special case is added, re-check every refinement the branch it bypasses was doing.
    func testEventKitReadDirectionIsNotSatisfiedByTheWriteOnlyKey() throws {
        let (bin, prefix, cleanup) = try scanToReport("""
        import Foundation
        import EventKit
        public func readCal() { _ = EKEventStore().calendars(for: .event) }
        """)
        defer { cleanup() }
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()

        // THE DEFECT: write-only is not an acceptable alternative for a READ.
        let writeOnly = try writePlist(["NSCalendarsWriteOnlyAccessUsageDescription",
                                        "NSRemindersUsageDescription"], dir)
        let bad = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix,
                                               "--verify", writeOnly])
        XCTAssertEqual(bad.code, 1, "a write-only key over READING code must exit 1: \(bad.out)\(bad.err)")
        XCTAssertTrue(bad.out.contains("✗") && bad.out.contains("Calendar"),
                      "the divergence must name the family: \(bad.out)")

        // CONTROL: a read-capable key present ⇒ clean. Without this the row is satisfied by an engine that
        // rejects every Calendar plist, which fails the assertion above for free and makes the verb useless.
        let full = try writePlist(["NSCalendarsFullAccessUsageDescription",
                                   "NSCalendarsWriteOnlyAccessUsageDescription",
                                   "NSRemindersUsageDescription"], dir)
        let ok = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", full])
        XCTAssertEqual(ok.code, 0, "a full-access declaration satisfies a read: \(ok.out)\(ok.err)")

        // …and the DIRECTION is in the report itself, which is what the verify reads.
        let rep = try XCTUnwrap((try? FileManager.default.contentsOfDirectory(
            atPath: dir.path))?.first { $0.hasSuffix(".Swift.json")
                && !$0.contains("callgraph") && !$0.contains("hierarchy") && !$0.contains("locs") })
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent(rep))) as? [String: Any])
        let fns = try XCTUnwrap(doc["functions"] as? [[String: Any]])
        let read = fns.first { ($0["fn"] as? String) == "readCal" }
        XCTAssertEqual((read?["privacy"] as? [String: [String]])?["Calendar"], ["read"],
                       "the report must carry the proved direction, not just the effect: \(fns)")
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

    // ── ⟨0.28⟩ the completeness envelope (SPEC §2 — the "same MUST, not the same shape problem" cell) ──

    /// A hand-built report carrying a privacy reach AND an `unanalyzed` manifest, plus a judged-nothing
    /// report, under one scratch dir.
    private func partialFixtures() throws -> (bin: URL, dir: URL) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-pv028-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {
          "candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.28"},
          "functions": [
            {"fn": "P.snap", "inferred": ["Camera"], "direct": ["Camera"], "calls": []}
          ],
          "analyzed": {"count": 1},
          "unanalyzed": [{"path": "src/Broken.swift", "reason": "parse error"}]
        }
        """.write(to: dir.appendingPathComponent("partial.json"), atomically: true, encoding: .utf8)
        try """
        {
          "candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.28"},
          "functions": [], "analyzed": {"count": 0}
        }
        """.write(to: dir.appendingPathComponent("nothing.json"), atomically: true, encoding: .utf8)
        return (bin, dir)
    }

    /// GENERATE over a report declaring `unanalyzed` carries the pinned caveat keys IN the machine
    /// document. Before ⟨0.28⟩ this verb loaded `model.completeness` and never read it: measured, a bare
    /// `{reached, required}` shipped over a partial report, and `reached: []` over a corrupt sibling —
    /// a clean "no sensors reached" about code nobody examined.
    func testGenerateOverAPartialReportCarriesTheCompletenessCaveat() throws {
        let (bin, dir) = try partialFixtures()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try ProcessHarness.run(bin, ["privacy-manifest",
                                             "--report", dir.appendingPathComponent("partial.json").path,
                                             "--json"])
        XCTAssertEqual(r.code, 0, "exit is UNTOUCHED — a disclosure, not an exit code: \(r.err)")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["incomplete"] as? Bool, true, r.out)
        let un = try XCTUnwrap(d["unanalyzed"] as? [[String: Any]], r.out)
        XCTAssertEqual(un.first?["path"] as? String, "src/Broken.swift")
        XCTAssertEqual((d["reached"] as? [String]), ["Camera"],
                       "the answer still ships — the caveat qualifies it rather than replacing it")
        XCTAssertTrue(r.err.contains("⚠ INCOMPLETE"),
                      "the prose half goes to stderr in JSON mode (stdout carries a document): \(r.err)")
    }

    /// A corrupt SIBLING raises `incomplete: true` (the `unreadable` cause — no key of its own, the file
    /// is named in prose) — this was #65's sharpest measured form: a clean bill of health over a report
    /// set the gate refuses.
    func testGenerateOverACorruptSiblingHedges() throws {
        let (bin, dir) = try partialFixtures()
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        {
          "candor": {"version": "t", "toolchain": "swiftsyntax", "spec": "0.28"},
          "functions": [
            {"fn": "A.ok", "inferred": ["Camera"], "direct": ["Camera"], "calls": []}
          ],
          "analyzed": {"count": 1}
        }
        """.write(to: dir.appendingPathComponent("c.A.Swift.json"), atomically: true, encoding: .utf8)
        try #"{"candor": {"trunc"#
            .write(to: dir.appendingPathComponent("c.B.Swift.json"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, ["privacy-manifest",
                                             "--report", dir.appendingPathComponent("c").path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["incomplete"] as? Bool, true,
                       "a sibling the gate hard-fails over cannot read as clean here: \(r.out)")
        XCTAssertEqual((d["reached"] as? [String]), ["Camera"], "the surviving sibling still answers")
    }

    /// `judgedNothing` is the ARRAY of report paths — the pinned wire shape (a verb reading a prefix
    /// answers over many siblings, and WHICH judged nothing is the actionable content).
    func testJudgedNothingIsAnArrayOfReportPaths() throws {
        let (bin, dir) = try partialFixtures()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nothing = dir.appendingPathComponent("nothing.json").path
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", nothing, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["incomplete"] as? Bool, true)
        XCTAssertEqual(d["judgedNothing"] as? [String], [nothing],
                       "an ARRAY of report paths, never a boolean — the 3-of-4 wire shape: \(r.out)")
    }

    /// VERIFY carries the caveat in its verdict document and keeps its exit: a declared sensor over a
    /// partial report is still `ok: true` at exit 0 — with `incomplete: true` beside it, so the CI
    /// consumer finally receives the condition the human channel always had.
    func testVerifyOverAPartialReportCarriesTheCaveatAndKeepsItsExit() throws {
        let (bin, dir) = try partialFixtures()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = try writePlist(["NSCameraUsageDescription"], dir)
        let r = try ProcessHarness.run(bin, ["privacy-manifest",
                                             "--report", dir.appendingPathComponent("partial.json").path,
                                             "--verify", plist, "--json"])
        XCTAssertEqual(r.code, 0, "the exit is the declared-vs-reached verdict, untouched: \(r.err)")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["ok"] as? Bool, true)
        XCTAssertEqual(d["incomplete"] as? Bool, true, r.out)
        XCTAssertNotNil(d["unanalyzed"], r.out)
    }

    /// THE CONTROL: over a complete report every caveat key is ABSENT — generate output is
    /// byte-identical to its pre-⟨0.28⟩ form (the property every engine measured for this rung).
    ///
    /// ⟨0.32⟩ **AND "COMPLETE" NOW HAS TO INCLUDE THE FILE SET, WHICH IS WHY THE FIXTURE IS REWRITTEN
    /// BEFORE IT IS ASKED.** A bare `candor-swift <dir> --out r` publishes `excluded` entries with
    /// `peeked: false` — an SPM tree always has at least `manifest` (`Package.swift`, which every
    /// `swift build` runs) — and the 2026-08-24 four-way ruling makes a class the scan never opened
    /// hedge a descriptive ANSWER (see `ReportCompleteness.mustHedge`). So this fixture was never
    /// complete in the ⟨0.32⟩ sense; it passed because nothing asked. Flipping `peeked` to true is the
    /// producer's own statement that the peek READ those files, which is exactly the condition the
    /// unhedged answer is licensed by — and rewriting the document is how the same control is written
    /// four-way in conformance PART 62.
    func testCompleteReportCarriesNoCaveatKeys() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        try markEveryExcludedClassPeeked(prefix: prefix)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        for key in ["incomplete", "unanalyzed", "judgedNothing"] {
            XCTAssertNil(d[key], "`\(key)` must be omitted when it does not apply — byte-identity is "
                         + "the property this rung must not spend")
        }
        XCTAssertFalse(r.err.contains("INCOMPLETE"), "no prose caveat either: \(r.err)")
    }

    /// ⟨0.32⟩ **THE OTHER DIRECTION, WHICH IS THE ONE THE RULING IS ABOUT.** The control above passes
    /// for an engine that has simply deleted the hedge, so it is only half a row: over the SAME tree
    /// with the classes left as the scan wrote them — `peeked: false`, nothing opened them — this verb
    /// MUST say so on both channels, and MUST NOT move its exit code (⟨0.24⟩: a disclosure, not an exit
    /// code). `ok` still answers the declared-vs-reached question; the caveat qualifies it.
    func testAnUnreadExclusionClassHedgesWithoutMovingTheExit() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        // THE PREMISE, asserted so a broken fixture cannot pass as a green: some report under this
        // prefix really does publish a class nothing opened. Found by looking for the KEY rather than by
        // guessing a filename — the sidecar sits in the same directory and parses as JSON too.
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        var excluded: [[String: Any]] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".json") {
            guard let d = try? JSONSerialization.jsonObject(
                    with: Data(contentsOf: dir.appendingPathComponent(name))) as? [String: Any],
                  let ex = d["excluded"] as? [[String: Any]] else { continue }
            excluded += ex
        }
        XCTAssertTrue(excluded.contains { $0["peeked"] as? Bool == false && $0["judgedElsewhere"] == nil },
                      "the fixture must publish an UNREAD class: \(excluded)")

        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--json"])
        XCTAssertEqual(r.code, 0, "a disclosure, not an exit code: \(r.err)")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["incomplete"] as? Bool, true, "the DOCUMENT must say so: \(r.out)")
        XCTAssertNil(d["unread"], "…and it mints no wire key of its own — the flag IS the surface: \(r.out)")
        XCTAssertTrue(r.err.contains("exclusion class(es) the scan did NOT READ"),
                      "the prose channel must name the CAUSE, not just wave: \(r.err)")
    }

    /// Rewrite every `excluded` member of every report under `prefix` to `peeked: true` — the
    /// producer's own statement that the peek read those files. See the control above for why.
    private func markEveryExcludedClassPeeked(prefix: String) throws {
        let dir = URL(fileURLWithPath: prefix).deletingLastPathComponent()
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name.hasSuffix(".json") && !name.hasSuffix(".callgraph.json") {
            let u = dir.appendingPathComponent(name)
            guard var d = try JSONSerialization.jsonObject(with: Data(contentsOf: u))
                    as? [String: Any],
                  let ex = d["excluded"] as? [[String: Any]] else { continue }
            d["excluded"] = ex.map { m -> [String: Any] in var m = m; m["peeked"] = true; return m }
            try JSONSerialization.data(withJSONObject: d).write(to: u)
        }
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

    /// THE NON-SWIFT COUNT MUST NOT WANDER OUT OF THE APP'S TREE.
    ///
    /// The project-root walk that bounds it gives up after eight hops, and the first version enumerated
    /// wherever it stopped — so a plist with NO project marker above it (a temp dir, `/tmp`, an
    /// extracted archive) walked to the filesystem root and enumerated THAT. This test is the exact
    /// shape that caught it: the very same marker-less temp layout `testBinaryPlistParses` uses, plus a
    /// `.c` file planted two levels ABOVE the plist. Before the fix the run took 21 minutes and counted
    /// that file (and every other `.c` on the machine) as this app's unread source — unbounded work AND
    /// a disclosure about somebody else's code attributed to the target.
    func testNonSwiftCountStaysInsideTheAppsTreeWhenNoProjectRootIsFound() throws {
        let fm = FileManager.default
        let outer = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-nsw-\(UUID().uuidString)")
        let holder = outer.appendingPathComponent("holder")
        try fm.createDirectory(at: holder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outer) }
        // Two levels above the plist, and NOT under any marker — the tree the walk must refuse to claim.
        try "void foreign(void) {}\n".write(to: outer.appendingPathComponent("foreign.c"),
                                            atomically: true, encoding: .utf8)
        let (bin, prefix, cleanup) = try scanToReport(locationAndContacts)
        defer { cleanup() }
        let plist = holder.appendingPathComponent("Info.plist")
        try #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict>\#n"#
            .appending("<key>NSLocationWhenInUseUsageDescription</key><string>because</string>\n")
            .appending("<key>NSContactsUsageDescription</key><string>because</string>\n")
            .appending("</dict></plist>\n")
            .write(to: plist, atomically: true, encoding: .utf8)
        let started = Date()
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist.path])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertFalse(r.out.contains("NON-SWIFT source file"),
                       "a .c file with no project root to justify a wider tree must not be counted as "
                       + "this target's unread source: \(r.out)")
        XCTAssertTrue(r.out.contains("NOT counted"),
                      "…and the run must SAY the count was not taken. A silent `0` here is a "
                      + "\"nothing unread\" claim over a tree the run could not identify: \(r.out)")
        // The wall-clock assertion is the other half of the same defect and is deliberately loose: the
        // failure mode it guards is a filesystem-root census, which is minutes, not seconds.
        XCTAssertLessThan(Date().timeIntervalSince(started), 60,
                          "the root walk enumerated a tree far larger than the app's")
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
        // The caveat must state the REAL limitation. It used to say "a function with one determined path
        // and one undetermined counts as determined" — same-function, which sounds narrow. A review
        // measured the actual rule: `paths` PROPAGATES, so one logger with a literal destination masks the
        // count to zero for a whole call graph. Understating a limitation is the same defect as
        // understating a finding, so the test pins the honest wording rather than the comfortable one.
        XCTAssertTrue(r.out.contains("ZERO here means zero"), r.out)
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

    /// THE MASKING CASE, which is why the count reads a per-function signal rather than `paths`.
    /// `paths` PROPAGATES: a caller inherits its callees' literals, so a function writing to a computed
    /// destination looked "determined" the moment anything it called named a literal path. One logger
    /// zeroed the count for a whole call graph, and every real app has one.
    func testUndeterminedCountIsNotMaskedByALiteralPathElsewhereInTheGraph() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        func cfg() -> Data? { FileManager.default.contents(atPath: "/etc/hosts") }
        func exportAll(_ dest: String) {
            _ = cfg()
            try? "x".write(toFile: dest, atomically: true, encoding: .utf8)
        }
        """, name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        try #"<?xml version="1.0" encoding="UTF-8"?>\#n<plist version="1.0"><dict></dict></plist>"#
            .write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify"], cwd: root)
        XCTAssertTrue(r.out.contains("exportAll"),
                      "the computed-destination write must be counted even though its callee named a "
                      + "literal path: \(r.out)")
        XCTAssertFalse(r.out.contains("(cfg,") || r.out.contains(" cfg)"),
                       "the literal-path function must NOT be counted: \(r.out)")
    }

    /// ⟨scope travels⟩ THE VERIFY MUST USE THE FILE THE SCAN RESOLVED, NOT SEARCH FOR ONE.
    ///
    /// `--target` scopes the scan; the verify that follows has only a report and a plist, so it walked
    /// the plist's directory looking for `.entitlements` and — on exactly the multi-binary repos
    /// `--target` exists for — found several, refused to guess, and left the entitlement-sourced keys
    /// unchecked. This drives the consumer directly with a hand-built report so the assertion is about
    /// the PREFERENCE, not about resolving a project: two `.entitlements` sit beside the plist (so
    /// discovery would refuse), and the report names one.
    func testTheVerifyPrefersTheEntitlementsTheScanResolved() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-scope-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // Two entitlements files: discovery alone cannot choose, which is the whole point.
        let mine = root.appendingPathComponent("App.entitlements")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>com.apple.developer.messages.critical-messaging</key><true/>
        </dict></plist>
        """.write(to: mine, atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict></dict></plist>\n"
            .write(to: root.appendingPathComponent("Other.entitlements"), atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict></dict></plist>\n"
            .write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        func report(_ scope: String?) throws -> String {
            let p = root.appendingPathComponent("r\(scope == nil ? "0" : "1").json").path
            let body = scope.map { ",\n \"scope\": {\"target\": \"App\", \"project\": \"A.xcodeproj\", \"entitlements\": \"\($0)\"}" } ?? ""
            try("{\n \"candor\": {\"spec\": \"0.27\"},\n \"package\": \"App\",\n"
                + " \"functions\": []\(body)\n}\n").write(toFile: p, atomically: true, encoding: .utf8)
            return p
        }
        // WITHOUT a scope: the pre-rung behaviour — several files, none read.
        let bare = try ProcessHarness.run(bin, ["privacy-manifest", "--report", try report(nil),
                                                "--verify", root.appendingPathComponent("Info.plist").path])
        XCTAssertTrue(bare.out.contains("several .entitlements files here — none attributed"),
                      "the control must show the ambiguity this rung removes: \(bare.out)")
        // WITH a scope: the named file is read, its finding appears, and the provenance is stated.
        let scoped = try ProcessHarness.run(bin, ["privacy-manifest", "--report", try report(mine.path),
                                                  "--verify", root.appendingPathComponent("Info.plist").path])
        XCTAssertFalse(scoped.out.contains("several .entitlements files here"),
                       "the scan already named the file — the verify must not be searching: \(scoped.out)")
        XCTAssertTrue(scoped.out.contains("named by the scanned target's CODE_SIGN_ENTITLEMENTS"),
                      "provenance must be stated on a pass too: \(scoped.out)")
        XCTAssertTrue(scoped.out.contains("NSCriticalMessagingUsageDescription"),
                      "the granted entitlement's key must now be CHECKED — that key was previously "
                      + "unchecked on every multi-binary repo: \(scoped.out)")
        // A RECORDED PATH THAT NO LONGER EXISTS falls back rather than failing — the report can be
        // older than the tree, and "we checked a file that is not there" is not an answer.
        let stale = try ProcessHarness.run(bin, ["privacy-manifest",
                                                 "--report", try report(root.appendingPathComponent("gone.entitlements").path),
                                                 "--verify", root.appendingPathComponent("Info.plist").path])
        XCTAssertTrue(stale.out.contains("several .entitlements files here — none attributed"),
                      "a stale scope must fall back to discovery, not silently check nothing: \(stale.out)")
    }

    // MARK: - the vendor-directory entitlement hole, and the refusal that was silent on --json

    /// Build a fixture package: an app whose `.entitlements` GRANTS critical-messaging, an `Info.plist`
    /// that declares the key or not, and optionally one vendored `.entitlements` under `vendor/Lib/`.
    private func makeEntitlementFixture(vendor: String?, declaresKey: Bool) throws -> URL {
        let root = try ProcessHarness.makePackage("import Foundation\nprint(\"hi\")\n", name: "App")
        let plist = declaresKey
            ? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n"
              + "<key>NSCriticalMessagingUsageDescription</key><string>emergency alerts</string>\n</dict></plist>\n"
            : "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict></dict></plist>\n"
        try plist.write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n"
             + "<key>com.apple.developer.messages.critical-messaging</key><true/>\n</dict></plist>\n")
            .write(to: root.appendingPathComponent("App.entitlements"), atomically: true, encoding: .utf8)
        if let vendor {
            let d = root.appendingPathComponent("\(vendor)/Lib")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict></dict></plist>\n"
                .write(to: d.appendingPathComponent("Vendored.entitlements"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func verifyJSON(_ bin: URL, _ root: URL, _ extra: [String] = []) throws
        -> (doc: [String: Any], code: Int32) {
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--verify", "--json"] + extra, cwd: root)
        let d = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
        XCTAssertNotNil(d, "the --json surface must emit a parseable document: \(r.out)\n\(r.err)")
        return (d ?? [:], r.code)
    }

    /// **THE CARDINAL SIN: a vendor directory's NAME decided whether an undeclared entitlement was
    /// reported at all.** Two trees identical in every respect but the name of the vendored dependency
    /// directory. `discoverEntitlements` carried the FOURTH literal copy of the skip set and that copy
    /// had lost `Carthage` (914b0b0 added it to the other three), so the vendored `.entitlements` was
    /// discovered too, `found.count > 1` refused to guess, and the app's own file was never read — a
    /// clean `ok: true` over an undeclared entitlement, on the surface CI reads.
    ///
    /// This is an A/B and the ONLY thing that varies is the directory name. Both arms are asserted, so
    /// the `Pods` arm is simultaneously the control proving the fixture reaches the finding at all.
    func testAVendorDirectorysNameCannotDecideWhetherAnUndeclaredEntitlementIsReported() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        var seen: [String: (ok: Bool, key: Bool, code: Int32)] = [:]
        for vendor in ["Pods", "Carthage"] {
            let root = try makeEntitlementFixture(vendor: vendor, declaresKey: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let (doc, code) = try verifyJSON(bin, root)
            let keys = doc["entitlementUnderDeclared"] as? [String] ?? []
            seen[vendor] = (doc["ok"] as? Bool ?? true,
                            keys.contains("NSCriticalMessagingUsageDescription"), code)
        }
        // The CONTROL arm — if this is not red the fixture never reached the finding and the A/B below
        // would be two identical nothings agreeing with each other.
        XCTAssertEqual(seen["Pods"]?.code, 1, "control: the Pods arm must find the undeclared entitlement")
        XCTAssertEqual(seen["Pods"]?.key, true, "control: the key must be named in the JSON document")
        XCTAssertEqual(seen["Pods"]?.ok, false, "control: ok must agree with the exit code")
        // …and the arms must agree, because the only difference between them is a directory NAME.
        XCTAssertEqual(seen["Carthage"]?.code, seen["Pods"]?.code,
                       "renaming Pods/ to Carthage/ changed the EXIT CODE: \(seen)")
        XCTAssertEqual(seen["Carthage"]?.key, seen["Pods"]?.key,
                       "renaming Pods/ to Carthage/ removed entitlementUnderDeclared from the JSON: \(seen)")
        XCTAssertEqual(seen["Carthage"]?.ok, seen["Pods"]?.ok,
                       "renaming Pods/ to Carthage/ flipped ok to true: \(seen)")
    }

    /// **THE DISCLOSURE HALF, which the skip-list fix does NOT cover.** Adding `Carthage` to a list
    /// closes one cause; the next vendored dependency directory will not be on the list either. What
    /// makes the class survivable is that the REFUSAL — "several .entitlements, none read" — reaches the
    /// machine surface, where it used to print under `!pm.json, !pm.xml` and so reached nobody. The
    /// directory here is `Externals/`, deliberately on NO skip list: the ambiguity still happens, and
    /// the document must say so. The arm here is the BENIGN one (the key is declared, so no candidate
    /// bears and the verdict stays green) — the bearing arm, where the verdict moves, is
    /// `testABearingUnattributableEntitlementsFileMakesTheVerdictIncompleteOnEveryRoute`.
    func testTheEntitlementsRefusalIsDisclosedOnTheMachineSurfacesNotOnlyToAHuman() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeEntitlementFixture(vendor: "Externals", declaresKey: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (doc, code) = try verifyJSON(bin, root)
        XCTAssertEqual(code, 0, "no candidate bears — the refusal must not start failing: \(doc)")
        guard let unread = doc["entitlementsUnread"] as? [String: Any] else {
            return XCTFail("`ok: true` over an entitlements file the verb refused to read, with NOTHING "
                           + "in the document saying so — the cardinal sin: \(doc)")
        }
        XCTAssertEqual(unread["reason"] as? String, "several")
        let cands = unread["candidates"] as? [String] ?? []
        XCTAssertTrue(cands.contains("App.entitlements"),
                      "the refusal must name what it refused over: \(cands)")
        XCTAssertTrue(cands.contains("Externals/Lib/Vendored.entitlements"),
                      "candidate paths must be relative to the plist, not bare basenames: \(cands)")
        XCTAssertEqual(unread["uncheckedKeys"] as? [String], ["NSCriticalMessagingUsageDescription"],
                       "the reader must be told WHICH keys went unattributed: \(unread)")
        // …and the third surface. `--xml` prints "nothing missing", which is a completeness claim.
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let x = try ProcessHarness.run(bin, ["privacy-manifest", "--verify", "--xml"], cwd: root)
        XCTAssertTrue(x.out.contains("NONE READ"),
                      "--xml's `nothing missing` was printed over an unread entitlements file: \(x.out)")
    }

    /// **`--xml` MUST EMIT WELL-FORMED XML, CHECKED BY A PARSER RATHER THAN BY EYE.** The whole point of
    /// that surface is that the output pastes into somebody's `Info.plist`, and its comments carried
    /// `<!-- candor privacy-manifest --verify: … -->`. XML forbids `--` inside a comment. Apple's
    /// `plutil -lint` accepts it (measured), which is exactly why it survived — the lenient parser is the
    /// one anybody would reach for, and a second `--` was about to be added by the entitlements caveat.
    ///
    /// Parsed here with `XMLParser`, which is strict on both Darwin Foundation and
    /// swift-corelibs-foundation. Driven over BOTH arms — the caveat comment and the plain
    /// "nothing missing" one — because they are separate print sites and only one of them was wrong the
    /// first time.
    func testTheXmlSurfaceIsWellFormedXml() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        // several-and-benign, the ordinary pass, then several-and-BEARING (the INCOMPLETE comment is a
        // third print site, and the first two were wrong once each).
        for (vendor, declaresKey) in [("Externals", true), (nil, true), ("Externals", false)] {
            let root = try makeEntitlementFixture(vendor: vendor, declaresKey: declaresKey)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ProcessHarness.run(bin, [root.path], cwd: root)
            let x = try ProcessHarness.run(bin, ["privacy-manifest", "--verify", "--xml"], cwd: root)
            let doc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n"
                + x.out + "\n</dict></plist>\n"
            let parser = XMLParser(data: Data(doc.utf8))
            let ok = parser.parse()
            let why = parser.parserError.map { "\($0)" } ?? "no error reported"
            XCTAssertTrue(ok, "`--xml` output does not parse as XML once pasted into a plist (\(why)) — "
                          + "vendor=\(vendor ?? "none"), output:\n\(x.out)")
        }
    }

    /// **THE OVER-CHARGE CONTROL — the direction the fix did NOT intend.** A tree whose entitlement IS
    /// declared must still pass, and must NOT grow the disclosure key: a fix that makes every verify
    /// noisy, or that starts failing a correct manifest, has deleted the feature rather than repaired
    /// it. Run with the vendor directory present (so the skip set is genuinely exercised and the app's
    /// own file IS the single candidate) and without it.
    func testAGenuinelyDeclaredEntitlementStillPassesCleanlyAndSilently() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        for vendor in ["Carthage", "Pods", nil] {
            let root = try makeEntitlementFixture(vendor: vendor, declaresKey: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let (doc, code) = try verifyJSON(bin, root)
            let where_ = vendor ?? "<no vendor dir>"
            XCTAssertEqual(code, 0, "\(where_): a declared entitlement must still exit 0: \(doc)")
            XCTAssertEqual(doc["ok"] as? Bool, true, "\(where_): ok must stay true: \(doc)")
            XCTAssertNil(doc["entitlementUnderDeclared"],
                         "\(where_): the SAFE value must not be charged: \(doc)")
            XCTAssertNil(doc["entitlementsUnread"],
                         "\(where_): the app's own file WAS read — a disclosure here would be a false "
                         + "caveat, and a caveat on every run is a caveat nobody reads: \(doc)")
        }
    }

    /// **THE OVER-CHARGE CONTROL FOR THE VERDICT BOUND — written before the bound.** A repo with MANY
    /// `.entitlements` files where NONE could bear on a key this run is checking MUST stay exit 0 /
    /// `ok: true`. This is the NetNewsWire shape (eight files across targets, granting sandbox-class
    /// capabilities no usage-description key depends on), and it is the COMMON case on exactly the
    /// multi-target repos the verb serves — moving the verdict here would delete the feature. Two arms,
    /// and the second is the sharp one:
    ///   1. eight benign candidates → green, disclosure present, no `couldBear`, no `incomplete`;
    ///   2. a candidate GRANTS critical-messaging but the plist DECLARES its key → STILL green,
    ///      because the bound is "could flip THIS run's verdict", never "grants something somewhere".
    func testManyEntitlementsFilesThatCannotBearOnTheVerdictStayGreen() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        for grantsButDeclared in [false, true] {
            let root = try ProcessHarness.makePackage("import Foundation\nprint(\"hi\")\n", name: "App")
            defer { try? FileManager.default.removeItem(at: root) }
            let plist = grantsButDeclared
                ? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n"
                  + "<key>NSCriticalMessagingUsageDescription</key><string>emergency alerts</string>\n"
                  + "</dict></plist>\n"
                : "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict></dict></plist>\n"
            try plist.write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            let benign = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n"
                + "<key>com.apple.security.app-sandbox</key><true/>\n</dict></plist>\n"
            for target in ["iOS", "Mac", "Widget", "ShareExtension", "Intents", "IntentsUI", "Sync"] {
                let d = root.appendingPathComponent(target)
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                try benign.write(to: d.appendingPathComponent("App.entitlements"),
                                 atomically: true, encoding: .utf8)
            }
            let eighth = grantsButDeclared
                ? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n"
                  + "<key>com.apple.developer.messages.critical-messaging</key><true/>\n</dict></plist>\n"
                : benign
            try eighth.write(to: root.appendingPathComponent("App.entitlements"),
                             atomically: true, encoding: .utf8)
            let (doc, code) = try verifyJSON(bin, root)
            let arm = grantsButDeclared ? "granted-but-declared" : "eight-benign"
            XCTAssertEqual(code, 0, "\(arm): no candidate can flip this run's verdict — exit must "
                           + "stay 0 or the feature is deleted: \(doc)")
            XCTAssertEqual(doc["ok"] as? Bool, true, "\(arm): ok must stay true: \(doc)")
            // NOT asserted: `incomplete` — an SPM fixture's report already carries it (the ⟨0.28⟩
            // REPORT-completeness disclosure fires on the excluded `Package.swift`, exit untouched).
            // Two mechanisms share that label; the verdict keys above are the discriminating ones.
            guard let unread = doc["entitlementsUnread"] as? [String: Any] else {
                return XCTFail("\(arm): the refusal-to-attribute still happened and must still be "
                               + "disclosed: \(doc)")
            }
            XCTAssertNil(unread["couldBear"], "\(arm): nothing bears — the key must be absent: \(unread)")
        }
    }

    /// **THE DEFECT DIRECTION: a bearing candidate makes the verdict INCOMPLETE, on every route.**
    /// The Carthage/Pods A/B above is closed by the skip list (both arms attribute and exit 1); this is
    /// the NEXT vendor directory, the one no list names (`Externals/`) — the app's own file grants
    /// critical-messaging, the key is undeclared, and discovery cannot tell the two candidates apart.
    /// The peek CAN tell that one of them bears on the verdict, so certifying (`ok: true`, exit 0) would
    /// be the cardinal sin with the evidence in hand, and filing `entitlementUnderDeclared` (exit 1)
    /// would attribute a possibly-vendored grant to the app — a fabrication the other way. The verdict
    /// is INCOMPLETE: `ok: false`, `incomplete: true`, exit 2, `couldBear` named. Checked on the
    /// document AND the exit code, on all three surfaces — two fixes in this family passed every gate
    /// because each gate checked the exit and none the document.
    func testABearingUnattributableEntitlementsFileMakesTheVerdictIncompleteOnEveryRoute() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try makeEntitlementFixture(vendor: "Externals", declaresKey: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (doc, code) = try verifyJSON(bin, root)
        XCTAssertEqual(code, 2, "a candidate could flip the verdict and none was attributed — the run "
                       + "cannot answer, and exit 0 here is the cardinal sin: \(doc)")
        XCTAssertEqual(doc["ok"] as? Bool, false, "ok must agree with the incomplete verdict: \(doc)")
        XCTAssertEqual(doc["incomplete"] as? Bool, true, "the ⟨0.21⟩ vocabulary: incomplete, not a "
                       + "violation: \(doc)")
        XCTAssertNil(doc["entitlementUnderDeclared"], "no file was attributed, so filing the violation "
                     + "would fabricate — the grant may be the vendored file's: \(doc)")
        guard let unread = doc["entitlementsUnread"] as? [String: Any] else {
            return XCTFail("the refusal must still be disclosed: \(doc)")
        }
        XCTAssertEqual(unread["reason"] as? String, "several")
        XCTAssertEqual(unread["couldBear"] as? [String], ["NSCriticalMessagingUsageDescription"],
                       "the bearing keys must be named so the reader knows WHY this went red: \(unread)")
        let cands = unread["candidates"] as? [String] ?? []
        XCTAssertTrue(cands.contains("App.entitlements") && cands.contains("Externals/Lib/Vendored.entitlements"),
                      "the refusal must still name what it refused over: \(cands)")
        // ROUTE EQUALITY: --xml and the human surface must reach the same verdict (exit 2) and carry
        // the caveat. §3.1 — the original sin was exactly a divergence between these surfaces.
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let x = try ProcessHarness.run(bin, ["privacy-manifest", "--verify", "--xml"], cwd: root)
        XCTAssertEqual(x.code, 2, "--xml must reach the same verdict as --json: \(x.out)\n\(x.err)")
        XCTAssertTrue(x.out.contains("NONE READ"), "--xml must carry the caveat: \(x.out)")
        XCTAssertTrue(x.out.contains("INCOMPLETE"), "--xml must say the verdict moved, not just that "
                      + "files were unread: \(x.out)")
        let h = try ProcessHarness.run(bin, ["privacy-manifest", "--verify"], cwd: root)
        XCTAssertEqual(h.code, 2, "the human surface must reach the same verdict: \(h.out)\n\(h.err)")
        XCTAssertTrue(h.out.contains("NSCriticalMessagingUsageDescription"),
                      "the human reader must be told which key could flip the verdict: \(h.out)")
        XCTAssertFalse(h.out.contains("✓"), "an incomplete verdict must not print a ✓ line: \(h.out)")
    }

    /// **THE SIBLING THE ANALYSIS FOUND: a CHOSEN entitlements file that cannot be parsed certified
    /// clean.** `entitlementRequiredKeys` returned `[]` for garbage bytes — indistinguishable from "read
    /// and grants nothing" — so a corrupt `.entitlements` was a silent pass (the plist gets fail-loud
    /// treatment; the entitlements file got silence). Same bound, `reason: "unreadable"`: an unparseable
    /// grant set could contain any entitlement, so `couldBear` is every undeclared entitlement-sourced
    /// key — and when the key IS declared, nothing can flip and the verdict stays green (the control).
    func testACorruptChosenEntitlementsFileCannotCertifyClean() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        for declaresKey in [false, true] {
            let root = try makeEntitlementFixture(vendor: nil, declaresKey: declaresKey)
            defer { try? FileManager.default.removeItem(at: root) }
            try "not a plist at all".write(to: root.appendingPathComponent("App.entitlements"),
                                           atomically: true, encoding: .utf8)
            let (doc, code) = try verifyJSON(bin, root)
            let unread = doc["entitlementsUnread"] as? [String: Any]
            if declaresKey {
                XCTAssertEqual(code, 0, "control: with the key declared nothing can flip — the corrupt "
                               + "file must not start failing correct manifests: \(doc)")
                XCTAssertEqual(doc["ok"] as? Bool, true, "control: ok stays true: \(doc)")
                XCTAssertNil(unread?["couldBear"], "control: nothing bears: \(String(describing: unread))")
            } else {
                XCTAssertEqual(code, 2, "a grant set that cannot be read could grant anything — "
                               + "certifying it clean is the silent form of the vendor-name defect: \(doc)")
                XCTAssertEqual(doc["ok"] as? Bool, false, "ok must agree: \(doc)")
                XCTAssertEqual(doc["incomplete"] as? Bool, true, "incomplete, not a violation: \(doc)")
                XCTAssertEqual(unread?["reason"] as? String, "unreadable",
                               "the reader must be told WHY nothing was checked: \(doc)")
                XCTAssertEqual(unread?["couldBear"] as? [String], ["NSCriticalMessagingUsageDescription"],
                               "the bearing keys must be named: \(String(describing: unread))")
            }
        }
    }

    /// **⟨0.24⟩ PRECEDENCE: a CERTAIN violation dominates the incomplete refusal.** Code that reaches
    /// Location with no key declared is a judged finding; the bearing-but-unattributed entitlements
    /// refusal fires beside it. The verdict is exit 1 naming the violation — never softened to exit 2 —
    /// with `incomplete: true` and `couldBear` riding the same document. And the `--xml` surface must
    /// not announce "exit 2" beside an actual exit 1 (the first cut of this change did).
    func testACertainViolationDominatesTheIncompleteEntitlementsRefusal() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(
            "import CoreLocation\nfunc whereAmI() { let m = CLLocationManager(); "
            + "m.requestWhenInUseAuthorization() }\nwhereAmI()\n", name: "App")
        defer { try? FileManager.default.removeItem(at: root) }
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict></dict></plist>\n"
            .write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\n"
             + "<key>com.apple.developer.messages.critical-messaging</key><true/>\n</dict></plist>\n")
            .write(to: root.appendingPathComponent("App.entitlements"), atomically: true, encoding: .utf8)
        try "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict></dict></plist>\n"
            .write(to: root.appendingPathComponent("Other.entitlements"), atomically: true, encoding: .utf8)
        let (doc, code) = try verifyJSON(bin, root)
        XCTAssertEqual(code, 1, "the certain Location violation must keep exit 1 — precedence: \(doc)")
        XCTAssertEqual(doc["ok"] as? Bool, false, "ok agrees with the violation: \(doc)")
        let under = (doc["underDeclared"] as? [[String: Any]])?.compactMap { $0["effect"] as? String } ?? []
        XCTAssertTrue(under.contains("Location"), "the judged finding must not be deleted by the "
                      + "refusal (the ⟨0.24⟩ measured defect, in this verb's shape): \(doc)")
        let unread = doc["entitlementsUnread"] as? [String: Any]
        XCTAssertEqual(unread?["couldBear"] as? [String], ["NSCriticalMessagingUsageDescription"],
                       "the refusal still travels beside the violation: \(doc)")
        _ = try ProcessHarness.run(bin, [root.path], cwd: root)
        let x = try ProcessHarness.run(bin, ["privacy-manifest", "--verify", "--xml"], cwd: root)
        XCTAssertEqual(x.code, 1, "route equality under precedence: \(x.out)")
        XCTAssertFalse(x.out.contains("exit 2"), "an xml comment must not announce exit 2 beside an "
                       + "actual exit 1: \(x.out)")
        XCTAssertTrue(x.out.contains("could additionally require NSCriticalMessagingUsageDescription"),
                      "the caveat itself must still travel on --xml: \(x.out)")
    }

    /// The four literal copies of the vendor skip set are now ONE, so this class cannot come back by the
    /// route it came the first time: a list edited in three places out of four. Asserted on the SOURCE,
    /// because that is where the defect lived — the behavioural A/B above cannot see a fifth copy added
    /// tomorrow, and "same exclusions as X" comments are what let the fourth one drift for good.
    func testThereIsExactlyOneVendorSkipListInTheSources() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let srcRoot = repo.appendingPathComponent("Sources")
        guard let en = FileManager.default.enumerator(atPath: srcRoot.path) else {
            throw XCTSkip("no Sources/ beside the test file — this pin reads the tree, not the binary")
        }
        // NON-VACUOUSNESS FIRST: if the walk reads no Swift at all, "zero extra copies" is a statement
        // about an empty set. Same failure shape as a gate whose reference value went missing.
        var swiftFiles = 0
        var sites: [String] = []
        for case let rel as String in en where rel.hasSuffix(".swift") {
            swiftFiles += 1
            let abs = srcRoot.appendingPathComponent(rel).path
            guard let text = try? String(contentsOfFile: abs, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("\"node_modules\"") && line.contains("\"Pods\"") {
                sites.append("\(rel):\(i + 1)")
            }
        }
        XCTAssertGreaterThan(swiftFiles, 10, "the source walk found almost nothing — this pin is vacuous")
        XCTAssertEqual(sites.count, 1,
                       "the vendored-directory skip list must be spelled out ONCE (VENDOR_SKIP_DIRS). It "
                       + "was written out four times, one copy silently lost `Carthage`, and that "
                       + "divergence was a silent under-report. Found at: \(sites)")
    }
}
