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
        XCTAssertTrue(bare.out.contains("several .entitlements files here — not read"),
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
        XCTAssertTrue(stale.out.contains("several .entitlements files here — not read"),
                      "a stale scope must fall back to discovery, not silently check nothing: \(stale.out)")
    }
}
