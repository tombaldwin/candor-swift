import XCTest
import Foundation

/// PROCESS-layer pins over the ⟨0.15 staged⟩ COVERAGE surface (candor-spec/COVERAGE-DESIGN.md; SPEC §2
/// `coverage` + per-fn `invisible` + verb conditionality). Three pieces, each pinned both ways:
///   (a) the `coverage` ENVELOPE field: emitted (same names/counts as the stderr κ ledger) when an
///       uncovered module is imported; OMITTED entirely on a fully-covered scan (wire-compatibility —
///       a fully-covered report is byte-identical to a pre-⟨0.15⟩ one);
///   (b) `privacy-manifest --verify` CONDITIONALITY: `conditional:true` + a `coverage` block (+ the
///       human ⚠ line) when the ledger is non-empty; both ABSENT when fully covered; the EXIT CODE is
///       computed exactly as before in both directions (disclosure, not a gate);
///   (c) the `--gate-json` advisory `coverage` note: present when the ledger is non-empty,
///       VERDICT-PRESERVING (ok/violations/exit unchanged — the ⟨0.9⟩ provable-purity precedent),
///       absent when fully covered (so PART 12 consumers see the exact pre-⟨0.15⟩ document).
final class CoverageProcessTests: XCTestCase {

    /// An UNCOVERED-module fixture: `SomeSDK` is no platform/κ/internal module, so it lands on the
    /// κ ledger, and the module-qualified call attributes per-fn `invisible` to `f`.
    private let uncoveredSrc = """
    import SomeSDK
    func f() { SomeSDK.doThing() }
    f()
    """

    /// A fully-covered fixture: Foundation only — no ledger, no coverage field anywhere.
    private let coveredSrc = """
    import Foundation
    func g() { _ = try? String(contentsOfFile: "/x") }
    g()
    """

    /// Location reach + an uncovered import — the wikipedia-ios shape in miniature.
    private let locationPlusUncoveredSrc = """
    import Foundation
    import CoreLocation
    import SomeSDK
    struct T { let m = CLLocationManager(); func w() { m.requestLocation(); SomeSDK.doThing() } }
    T().w()
    """

    /// Location reach only — fully covered.
    private let locationOnlySrc = """
    import Foundation
    import CoreLocation
    struct T { let m = CLLocationManager(); func w() { m.requestLocation() } }
    T().w()
    """

    private func scanToReport(_ src: String) throws -> (binary: URL, prefix: String, cleanup: () -> Void) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src)
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-cov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let prefix = outDir.appendingPathComponent("report").path
        let r = try ProcessHarness.run(bin, [root.path, "--out", prefix])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return (bin, prefix, {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outDir)
        })
    }

    private func writePlist(_ keys: [String]) throws -> URL {
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
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-cov-\(UUID().uuidString).plist")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], s)
    }

    // ── (a) envelope: `coverage` emitted with the ledger's names/counts + per-fn `invisible` ────────
    func testEnvelopeCoverageEmittedForUncoveredModule() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(uncoveredSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try json(r.out)
        let cov = try XCTUnwrap(d["coverage"] as? [String: Any], "envelope must carry `coverage` — \(r.out)")
        let unc = try XCTUnwrap(cov["uncovered"] as? [[String: Any]])
        XCTAssertEqual(unc.count, 1, r.out)
        XCTAssertEqual(unc.first?["name"] as? String, "SomeSDK")
        XCTAssertEqual(unc.first?["calls"] as? Int, 1, "swift counts IMPORTS; the wire name stays `calls`")
        // the stderr ledger line is UNCHANGED and agrees with the wire field
        XCTAssertTrue(r.err.contains("classifier doesn't cover 1 module"), r.err)
        XCTAssertTrue(r.err.contains("SomeSDK (1 import)"), r.err)
        // per-fn attribution: `f` demonstrably calls into the uncovered module
        let fns = try ProcessHarness.fns(ofJson: r.out)
        XCTAssertEqual(fns["f"]?["invisible"] as? [String], ["SomeSDK"], r.out)
    }

    func testEnvelopeCoverageOmittedWhenFullyCovered() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(coveredSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try json(r.out)
        XCTAssertNil(d["coverage"], "a fully-covered scan's envelope must OMIT `coverage` entirely — \(r.out)")
        XCTAssertFalse(r.err.contains("doesn't cover"), r.err)
    }

    // ── (b) privacy-manifest --verify conditionality ─────────────────────────────────────────────────
    func testVerifyConditionalWhenUncovered() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationPlusUncoveredSrc)
        defer { cleanup() }
        let plist = try writePlist(["NSLocationWhenInUseUsageDescription"])
        defer { try? FileManager.default.removeItem(at: plist) }
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist.path, "--json"])
        XCTAssertEqual(r.code, 0, "coverage is DISCLOSURE, not a gate — a declared reach still exits 0: \(r.err)")
        let d = try json(r.out)
        XCTAssertEqual(d["ok"] as? Bool, true, r.out)
        XCTAssertEqual(d["conditional"] as? Bool, true, r.out)
        let cov = try XCTUnwrap(d["coverage"] as? [String: Any], r.out)
        XCTAssertEqual(cov["uncovered"] as? Int, 1, r.out)
        XCTAssertEqual(cov["modules"] as? [String], ["SomeSDK"], r.out)
        // human surface: the ⚠ conditional line, same verdict/exit
        let h = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist.path])
        XCTAssertEqual(h.code, 0, h.err)
        XCTAssertTrue(h.out.contains("⚠ verdict is conditional on 1 uncovered module"), h.out)
    }

    func testVerifyConditionalKeepsUnderDeclarationExit() throws {
        // The under-declared direction: conditionality must not soften (or double-fail) the exit.
        let (bin, prefix, cleanup) = try scanToReport(locationPlusUncoveredSrc)
        defer { cleanup() }
        let plist = try writePlist([])   // declares nothing → Location under-declared
        defer { try? FileManager.default.removeItem(at: plist) }
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist.path, "--json"])
        XCTAssertEqual(r.code, 1, "under-declaration still exits 1, coverage or not: \(r.err)")
        let d = try json(r.out)
        XCTAssertEqual(d["ok"] as? Bool, false, r.out)
        XCTAssertEqual(d["conditional"] as? Bool, true, r.out)
    }

    func testVerifyNotConditionalWhenFullyCovered() throws {
        let (bin, prefix, cleanup) = try scanToReport(locationOnlySrc)
        defer { cleanup() }
        let plist = try writePlist(["NSLocationWhenInUseUsageDescription"])
        defer { try? FileManager.default.removeItem(at: plist) }
        let r = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist.path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try json(r.out)
        XCTAssertEqual(d["ok"] as? Bool, true, r.out)
        XCTAssertNil(d["conditional"], "fully covered → `conditional` ABSENT (pre-⟨0.15⟩ shape): \(r.out)")
        XCTAssertNil(d["coverage"], r.out)
        let h = try ProcessHarness.run(bin, ["privacy-manifest", "--report", prefix, "--verify", plist.path])
        XCTAssertFalse(h.out.contains("conditional"), h.out)
    }

    // ── (c) --gate-json advisory coverage note, verdict-preserving ───────────────────────────────────
    func testGateJsonAdvisoryCoveragePresentAndVerdictPreserving() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        // Uncovered import + a genuine Fs reach: `deny Fs` has a real violation to preserve.
        let root = try ProcessHarness.makePackage("""
        import Foundation
        import SomeSDK
        func f() { SomeSDK.doThing() }
        func w() { _ = try? String(contentsOfFile: "/x") }
        f(); w()
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-cov-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdictPath = dir.appendingPathComponent("verdict.json").path

        // FAILING gate: `deny Fs` catches `w` — exit 1, ok:false, the violation intact, coverage ADDED.
        let deny = dir.appendingPathComponent("deny.policy")
        try "deny Fs\n".write(to: deny, atomically: true, encoding: .utf8)
        let bad = try ProcessHarness.run(bin, [root.path, "--json", "--policy", deny.path, "--gate-json", verdictPath])
        XCTAssertEqual(bad.code, 1, "the gate verdict/exit must be UNCHANGED by coverage: \(bad.err)")
        let badV = try json(String(contentsOfFile: verdictPath, encoding: .utf8))
        XCTAssertEqual(badV["ok"] as? Bool, false)
        // `w` violates directly and `<main>` inherits the reach — both records intact.
        let badViolations = try XCTUnwrap(badV["violations"] as? [[String: Any]], "\(badV)")
        XCTAssertEqual(badViolations.count, 2, "\(badV)")
        XCTAssertTrue(badViolations.contains { $0["fn"] as? String == "w" }, "\(badV)")
        let badCov = try XCTUnwrap(badV["coverage"] as? [String: Any], "\(badV)")
        XCTAssertEqual(badCov["uncovered"] as? Int, 1)
        XCTAssertEqual(badCov["modules"] as? [String], ["SomeSDK"])

        // PASSING gate: `deny Exec` matches nothing — exit 0, ok:true, [], coverage still disclosed.
        let pass = dir.appendingPathComponent("pass.policy")
        try "deny Exec\n".write(to: pass, atomically: true, encoding: .utf8)
        let good = try ProcessHarness.run(bin, [root.path, "--json", "--policy", pass.path, "--gate-json", verdictPath])
        XCTAssertEqual(good.code, 0, good.err)
        let goodV = try json(String(contentsOfFile: verdictPath, encoding: .utf8))
        XCTAssertEqual(goodV["ok"] as? Bool, true)
        XCTAssertEqual((goodV["violations"] as? [Any])?.count, 0)
        XCTAssertNotNil(goodV["coverage"], "\(goodV)")
    }

    // ── (d) gains --json coverage re-disclosure + coverageDelta ─────────────────────────────────────
    func testGainsJsonCoverageAndDelta() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        // baseline: fully covered; current: gains an uncovered import (the "dep became uncovered" signal).
        let (_, basePrefix, baseCleanup) = try scanToReport(coveredSrc)
        defer { baseCleanup() }
        let (_, curPrefix, curCleanup) = try scanToReport(uncoveredSrc)
        defer { curCleanup() }

        let r = try ProcessHarness.run(bin, ["gains", curPrefix, basePrefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try json(r.out)
        // the CURRENT report's envelope block, verbatim shape
        let cov = try XCTUnwrap(d["coverage"] as? [String: Any], r.out)
        let unc = try XCTUnwrap(cov["uncovered"] as? [[String: Any]], r.out)
        XCTAssertEqual(unc.count, 1, r.out)
        XCTAssertEqual(unc.first?["name"] as? String, "SomeSDK", r.out)
        XCTAssertEqual(unc.first?["calls"] as? Int, 1, r.out)
        // the name-set delta (names only)
        let delta = try XCTUnwrap(d["coverageDelta"] as? [String: Any], r.out)
        XCTAssertEqual(delta["nowUncovered"] as? [String], ["SomeSDK"], r.out)
        XCTAssertEqual(delta["noLongerUncovered"] as? [String], [], r.out)
        // existing fields untouched
        XCTAssertNotNil(d["gained"], r.out)
        XCTAssertNotNil(d["byFunction"], r.out)

        // human TSV unchanged: pinned consumer surface — no coverage lines ride it
        let tsv = try ProcessHarness.run(bin, ["gains", curPrefix, basePrefix])
        XCTAssertEqual(tsv.code, 0, tsv.err)
        XCTAssertFalse(tsv.out.lowercased().contains("coverage"), tsv.out)

        // same report on both sides → identical name sets, block present, DELTA absent
        let same = try ProcessHarness.run(bin, ["gains", curPrefix, curPrefix, "--json"])
        XCTAssertEqual(same.code, 0, same.err)
        let sd = try json(same.out)
        XCTAssertNotNil(sd["coverage"], same.out)
        XCTAssertNil(sd["coverageDelta"], "equal uncovered name sets must emit NO coverageDelta: \(same.out)")

        // fully covered on both sides → both keys absent (pre-⟨0.15⟩ shape)
        let clean = try ProcessHarness.run(bin, ["gains", basePrefix, basePrefix, "--json"])
        XCTAssertEqual(clean.code, 0, clean.err)
        let cd = try json(clean.out)
        XCTAssertNil(cd["coverage"], clean.out)
        XCTAssertNil(cd["coverageDelta"], clean.out)
    }

    func testGateJsonNoCoverageWhenFullyCovered() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(coveredSrc)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-cov-gate2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let verdictPath = dir.appendingPathComponent("verdict.json").path
        let pass = dir.appendingPathComponent("pass.policy")
        try "deny Exec\n".write(to: pass, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path, "--json", "--policy", pass.path, "--gate-json", verdictPath])
        XCTAssertEqual(r.code, 0, r.err)
        let v = try json(String(contentsOfFile: verdictPath, encoding: .utf8))
        XCTAssertEqual(v["ok"] as? Bool, true)
        XCTAssertNil(v["coverage"], "fully covered → the verdict document keeps the exact pre-⟨0.15⟩ shape: \(v)")
    }

    // ── SETUP warning (⟨0.19⟩, SPEC §6.2 §3): a manifest declaring deps but with no fetched .build/checkouts ──
    func testSetupWarningOnUnfetchedDeps() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage("print(\"hi\")")
        defer { try? FileManager.default.removeItem(at: root) }
        // Declare a dependency; .build/checkouts is absent (deps not fetched) → the setup remediation fires.
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App",
          dependencies: [ .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0") ],
          targets: [ .executableTarget(name: "App") ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, [root.path])
        XCTAssertTrue(r.err.contains("SETUP") && r.err.contains("swift build"),
                      "unfetched declared deps must emit the SETUP remediation — stderr: \(r.err)")
        // A fetched .build/checkouts silences it (no false setup nag on a resolved project).
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/checkouts"), withIntermediateDirectories: true)
        let r2 = try ProcessHarness.run(bin, [root.path])
        XCTAssertFalse(r2.err.contains("SETUP"), "a fetched .build/checkouts must silence the setup warning — stderr: \(r2.err)")
    }
}
