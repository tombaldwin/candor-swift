import XCTest
import Foundation

/// PROCESS-layer pins over the INERT-KEY DISCLOSURE in the §3.4 `.candor/config` layer (the family
/// config amendment, 2026-07-09).
///
/// `.candor/config` has ONE key vocabulary across the four engines, but not every engine wires every
/// key: `closed-world`, `strict`, `no-ambient` and `taint` are gates the JVM engine really does honour
/// and this one does not. A checked-in `closed-world true` therefore used to mean a genuine behaviour
/// change on java, an "it is NOT active" line on candor-scan, and SILENCE here — the reader believes a
/// gate is on that never ran. That is a declared-gate-silently-off, the exact divergence this tool
/// exists to catch, so a recognized-but-unimplemented key now discloses on stderr.
///
/// The suite pins BOTH directions, because the cheap fix (warn about everything recognized) would be
/// its own lie: an IMPLEMENTED key must stay quiet, and the disclosure must not displace the separate
/// unknown-key warning (typo protection — a misspelt `policy` is a different failure entirely).
final class ConfigInertKeyProcessTests: XCTestCase {

    /// The stable fragment of the disclosure — the CLAIM (recognized family-wide, not active here)
    /// rather than the whole sentence, so wording can be tuned but the meaning cannot drift. Byte-shape
    /// with candor-scan's, which is what a user comparing two engines' stderr actually reads.
    private let inertMark = "is recognized by the candor family but not implemented by candor-swift"

    /// A package with one real Net reach, plus a `.candor/config` holding exactly `configBody`. Returns
    /// (root, configPath) — the caller writes any policy file under the root.
    private func makeFixture(config configBody: String) throws -> (root: URL, config: URL) {
        let root = try ProcessHarness.makePackage("""
        import Foundation
        struct Billing {
            func charge() {
                let t = URLSession.shared.dataTask(with: "https://api.stripe.com/v1/charges") { _, _, _ in }
                t.resume()
            }
        }
        Billing().charge()
        """)
        let candorDir = root.appendingPathComponent(".candor")
        try FileManager.default.createDirectory(at: candorDir, withIntermediateDirectories: true)
        let cfg = candorDir.appendingPathComponent("config")
        try configBody.write(to: cfg, atomically: true, encoding: .utf8)
        return (root, cfg)
    }

    private func scan(_ root: URL, _ extraArgs: [String] = []) throws -> (out: String, err: String, code: Int32) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        return try ProcessHarness.run(bin, [root.path] + extraArgs)
    }

    // ── it fires: a recognized key this engine does not wire ────────────────────────────────────────

    func testUnimplementedFamilyKeyIsDisclosed() throws {
        let (root, _) = try makeFixture(config: "closed-world true\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try scan(root)
        XCTAssertEqual(r.code, 0, "disclosure only — the exit code is untouched: \(r.err)")
        XCTAssertTrue(r.err.contains("config key 'closed-world' \(inertMark)"),
                      "the inert key must be named, not silently dropped: \(r.err)")
        XCTAssertTrue(r.err.contains("NOT active on this scan"),
                      "the disclosure has to say what the reader loses: \(r.err)")
        XCTAssertFalse(r.err.contains("unknown config key 'closed-world'"),
                       "it is RECOGNIZED — the typo warning would misdescribe it: \(r.err)")
    }

    /// All four inert keys, one config: each is named on its own line. A per-key assertion (rather than
    /// one representative) is what stops a future wiring of, say, `taint` from leaving a stale claim.
    func testEveryUnimplementedKeyIsNamedIndividually() throws {
        let (root, _) = try makeFixture(config: "strict true\nno-ambient true\nclosed-world true\ntaint on\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try scan(root)
        XCTAssertEqual(r.code, 0, r.err)
        for key in ["strict", "no-ambient", "closed-world", "taint"] {
            XCTAssertTrue(r.err.contains("config key '\(key)' \(inertMark)"),
                          "\(key) is inert in this engine and must say so: \(r.err)")
        }
    }

    // ── it does NOT fire: the keys this engine really wires ─────────────────────────────────────────

    /// The half that keeps the fix from degenerating into "warn about everything". `policy` is asserted
    /// LIVE, not merely quiet — the config-supplied deny actually gates the scan — so a future change
    /// that silences the disclosure by breaking the wiring cannot pass this test either.
    func testImplementedKeyIsNotDisclosedAndStillDrivesTheGate() throws {
        let (root, _) = try makeFixture(config: "policy .candor/gate.pol\n")
        defer { try? FileManager.default.removeItem(at: root) }
        try "deny Net\n".write(to: root.appendingPathComponent(".candor/gate.pol"),
                               atomically: true, encoding: .utf8)
        let r = try scan(root)
        XCTAssertEqual(r.code, 1, "precondition: the config's policy IS wired and fires: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-006"), "the deny fires: \(r.err)")
        XCTAssertFalse(r.err.contains(inertMark),
                       "an implemented key must never be disclosed as inert: \(r.err)")
    }

    /// The other three wired keys — `baseline`, `deps` and `unknown-ratchet` — in one config. Values are
    /// benign (an empty deps dir chains nothing), so this isolates the classification: the run stays
    /// clean AND says nothing about them.
    ///
    /// THE BASELINE IS RECORDED FIRST, and it did not used to be: this test's own comment said "an
    /// absent baseline is a note", which stopped being true when a baseline DECLARED in `.candor/config`
    /// became exit 2 (a checked-in declaration says the repo HAS one, so an absent file was deleted or
    /// never committed). The test was right about its intent and wrong about its premise — so it now
    /// supplies a real baseline rather than relying on an absent one being harmless, which keeps it
    /// testing the classification instead of the guard.
    func testTheOtherImplementedKeysStaySilent() throws {
        let (root, _) = try makeFixture(config: "baseline .candor/baseline.json\ndeps .candor/deps\nunknown-ratchet true\n")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".candor/deps"),
                                                withIntermediateDirectories: true)
        // Record the baseline with THIS build, so the guard is active and SATISFIED rather than absent.
        // `--out` is a PREFIX the engine decorates (`<prefix>.<package>.Swift.json`) — `--json` prints to
        // stdout and writes nothing — so the produced report is found and copied to the exact path the
        // config names.
        let pre = root.appendingPathComponent(".candor/rec")
        _ = try scan(root, ["--out", pre.path])
        // EVERY SIDECAR IS EXCLUDED, not just the callgraph. `--out rec` also writes
        // `rec.<pkg>.Swift.hierarchy.json` and can write `.locs.json`, all of which match "starts with
        // rec., ends in .json" — so the first version of this picked whichever the filesystem happened
        // to enumerate first and copied a SIDECAR in as the baseline. It passed on macOS and failed the
        // Linux CI leg, which is the tell for an ordering assumption: `contentsOfDirectory` promises no
        // order, and two platforms obliged differently.
        let sidecars = ["callgraph", "hierarchy", "locs"]
        let produced = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent(".candor"), includingPropertiesForKeys: nil)
            .first { u in
                u.lastPathComponent.hasPrefix("rec.") && u.pathExtension == "json"
                    && !sidecars.contains(where: { u.lastPathComponent.contains(".\($0).") })
            }
        XCTAssertNotNil(produced, "precondition: the scan wrote a report to copy as the baseline")
        // …and that it is the REPORT. Asserting only non-nil is what let a sidecar through: the copy
        // then "succeeded" and the failure surfaced two steps later as an unexplained exit 2.
        if let produced {
            let body = try String(contentsOf: produced, encoding: .utf8)
            XCTAssertTrue(body.contains("\"functions\""),
                          "picked \(produced.lastPathComponent), which is not a §2 report")
        }
        if let produced {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".candor/baseline.json"))
            try FileManager.default.copyItem(at: produced, to: root.appendingPathComponent(".candor/baseline.json"))
        }
        let r = try scan(root)
        XCTAssertEqual(r.code, 0, "no gate configured, so a clean exit: \(r.err)")
        XCTAssertFalse(r.err.contains(inertMark),
                       "baseline/deps/unknown-ratchet are all wired here: \(r.err)")
    }

    /// `unknown-alias` is MULTI-VALUE (⟨0.19⟩ reason-class aliases, parsed off the config TEXT rather
    /// than the single-value map), so it leaves the loader early and never reaches the implemented-key
    /// check. It is implemented — asserted by the alias resolving at the gate — and must stay quiet.
    func testMultiValueUnknownAliasIsImplementedAndSilent() throws {
        let (root, _) = try makeFixture(config: "unknown-alias blind = dispatch\npolicy .candor/gate.pol\n")
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        protocol Sink { func write() }
        struct Mid { let s: Sink; func go() { s.write() } }
        struct App { let m: Mid; func entry() { m.go() } }
        """.write(to: root.appendingPathComponent("Sources/App/Dispatch.swift"),
                  atomically: true, encoding: .utf8)
        try "deny Net Unknown[blind] App\n".write(to: root.appendingPathComponent(".candor/gate.pol"),
                                                  atomically: true, encoding: .utf8)
        let r = try scan(root)
        XCTAssertEqual(r.code, 1, "precondition: the alias resolved, so the gate fired: \(r.err)")
        XCTAssertTrue(r.err.contains("AS-EFF-006") && r.err.contains("App.entry"), r.err)
        XCTAssertFalse(r.err.contains(inertMark),
                       "`unknown-alias` is wired via parseUnknownAliases — never inert: \(r.err)")
    }

    // ── the two cases stay distinct ──────────────────────────────────────────────────────────────────

    /// A key OUTSIDE the vocabulary is a typo, not an inert gate: it keeps its own warning (a misspelt
    /// `policy` must not silently drop the gate) and must NOT be described as a family key.
    func testOutOfVocabularyKeyKeepsTheTypoWarning() throws {
        let (root, _) = try makeFixture(config: "polcy /nope\nclosed-world true\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try scan(root)
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("unknown config key 'polcy'"), "typo protection survives: \(r.err)")
        XCTAssertFalse(r.err.contains("config key 'polcy' \(inertMark)"),
                       "a typo is not a recognized-but-inert key: \(r.err)")
        XCTAssertTrue(r.err.contains("config key 'closed-world' \(inertMark)"),
                      "…and the inert disclosure still fires alongside it: \(r.err)")
    }

    // ── the safety contract ──────────────────────────────────────────────────────────────────────────

    /// stderr-only: the disclosure cannot reach a machine consumer's stdout, and it moves neither the
    /// verdict document nor the exit code of a FAILING gate.
    func testDisclosureNeverContaminatesJsonStdoutOrTheVerdict() throws {
        let (root, _) = try makeFixture(config: "closed-world true\npolicy .candor/gate.pol\n")
        defer { try? FileManager.default.removeItem(at: root) }
        try "deny Net\n".write(to: root.appendingPathComponent(".candor/gate.pol"),
                               atomically: true, encoding: .utf8)
        let verdict = root.appendingPathComponent("verdict.json")
        let r = try scan(root, ["--json", "--gate-json", verdict.path])
        XCTAssertEqual(r.code, 1, "the exit is the gate's, not the disclosure's: \(r.err)")
        XCTAssertTrue(r.err.contains(inertMark), "precondition: the disclosure DID fire on this run")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
                              "stdout must stay pure JSON: \(r.out)")
        XCTAssertNotNil(d["functions"], r.out)
        XCTAssertFalse(r.out.contains("closed-world"), "no config text may leak into the report: \(r.out)")
        let vText = try String(contentsOf: verdict, encoding: .utf8)
        let v = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(vText.utf8)) as? [String: Any])
        XCTAssertEqual(v["ok"] as? Bool, false, "\(v)")
        XCTAssertFalse(vText.contains("closed-world"), "the verdict document is untouched: \(vText)")
    }
}
