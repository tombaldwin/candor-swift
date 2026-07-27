import XCTest
import Foundation

/// THE §4 `unknownWhy` KIND VOCABULARY, END TO END — the fifth kind and the off-vocabulary control.
///
/// SPEC §4 ⟨0.24⟩ adds `ambiguous:` as a fifth kind (the analyser's own name resolution was ambiguous, so
/// no owner could be formed at all) and requires the amender to prove a FABRICATED off-vocabulary kind
/// still behaves as §2 forward-compatibility says: round-tripped verbatim, classified through the
/// conservative catch-all. Without that second half, "added a fifth kind" and "stopped checking the kind
/// set" are the same diff.
///
/// candor-swift EMITS no `ambiguous:` — its five reason producers are `dispatch:`, `callback:`,
/// `dynamicMemberLookup:`, `contentsOf:` and the `dep:`/`dep-stale:` provenance pointers. It RELAYS one:
/// `Deps.loadDepIndex` copies a dependency's own `unknownWhy` tokens into `DepEntry.whyClasses` and
/// `Driver.applyDepEntry` unions them into the consumer's `whyMap`, so a kind produced only by another
/// engine's language model (candor-rust emits `ambiguous:` on 8710 of 19607 Unknown-bearing entries,
/// SPEC §4 ⟨0.24⟩) lands verbatim in candor-swift's report and is gated on there. That is the path
/// exercised here, because it is the only path by which this engine can meet the kind at all.
///
/// Both kinds are driven through TWO shipped verbs, `scan --policy` and `unverified --class`, because the
/// class set is accumulated twice in this engine by two independent code paths — `Gate.buildGateInput`
/// and `Fix.reasonClassesTransitive` — and a divergence between them is exactly the shape §4 ⟨0.24⟩
/// describes.
final class UnknownWhyVocabularyProcessTests: XCTestCase {

    private struct Fixture { let root: URL, consumer: URL, deps: URL }

    /// A hand-written dependency report carrying one `ambiguous:` entry and one fabricated
    /// `banana:` entry, plus a consumer package calling both. The report is written by hand rather than
    /// scanned because no Swift source makes THIS engine emit either kind — the point is the relay.
    private func makeFixture(_ bin: URL) throws -> Fixture {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-vocab-\(UUID().uuidString)")
        let consumer = root.appendingPathComponent("PkgB")
        try fm.createDirectory(at: consumer.appendingPathComponent("Sources/PkgB"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "PkgB", targets: [.target(name: "PkgB")])
        """.write(to: consumer.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import PkgC
        public func bAmbig() { cAmbig() }
        public func bBanana() { cBanana() }
        """.write(to: consumer.appendingPathComponent("Sources/PkgB/S.swift"), atomically: true, encoding: .utf8)

        // The producer version has to match this build or §2.1 staleness answers instead of the join.
        let v = try ProcessHarness.run(bin, ["--version"]).out
            .split(separator: "\n")[0].split(separator: " ")[1]
        let deps = root.appendingPathComponent("deps")
        try fm.createDirectory(at: deps, withIntermediateDirectories: true)
        let report: [String: Any] = [
            "candor": ["version": "candor-swift-\(v)", "spec": "0.23", "toolchain": "swiftsyntax"],
            "package": "PkgC",
            "functions": [
                ["fn": "cAmbig", "hash": "PkgC#cAmbig", "inferred": ["Unknown"],
                 "unknownWhy": ["ambiguous:go"]],
                ["fn": "cBanana", "hash": "PkgC#cBanana", "inferred": ["Unknown"],
                 "unknownWhy": ["banana:whatever"]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: report).write(to: deps.appendingPathComponent("c.json"))
        return Fixture(root: root, consumer: consumer, deps: deps)
    }

    private func scan(_ bin: URL, _ f: Fixture, out: String) throws -> [String: [String: Any]] {
        let prefix = f.root.appendingPathComponent(out)
        let r = try ProcessHarness.run(bin, [f.consumer.path, "--out", prefix.path],
                                       env: ["CANDOR_DEPS": f.deps.path])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: f.root.appendingPathComponent("\(out).PkgB.Swift.json"))) as? [String: Any]
        var by: [String: [String: Any]] = [:]
        for case let e as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            if let n = e["fn"] as? String { by[n] = e }
        }
        return by
    }

    private func gate(_ bin: URL, _ f: Fixture, _ policy: String) throws -> (out: String, err: String, code: Int32) {
        let p = f.root.appendingPathComponent("p-\(UUID().uuidString).candor")
        try policy.write(to: p, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [f.consumer.path, "--policy", p.path],
                                      env: ["CANDOR_DEPS": f.deps.path])
    }

    /// The fns `unverified --class <c>` reports, over a report the caller has already written.
    private func unverifiedFns(_ bin: URL, _ f: Fixture, prefix: String, cls: String) throws -> [String] {
        let p = f.root.appendingPathComponent("pure.candor")
        try "pure\n".write(to: p, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(bin, ["unverified", "--report", f.root.appendingPathComponent(prefix).path,
                                             "--policy", p.path, "--class", cls, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any]
        return ((d?["unverified"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["fn"] as? String }.sorted()
    }

    /// SPEC §4 ⟨0.24⟩ + §6.2's table: a relayed `ambiguous:` round-trips verbatim and projects to class
    /// `dispatch` — not `indirect` (the rejected reclassification, which would silently narrow every
    /// `deny E Unknown[dispatch]` gate in the field) and not `unresolved` (which would mean the token was
    /// falling through the catch-all, i.e. the kind is not in the vocabulary at all).
    func testARelayedAmbiguousKindRoundTripsAndGatesAsDispatch() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let f = try makeFixture(bin)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let fns = try scan(bin, f, out: "r1")

        XCTAssertEqual(fns["bAmbig"]?["unknownWhy"] as? [String], ["ambiguous:go"],
                       "the fifth kind crosses the join VERBATIM — no rewriting, no `dep:` pointer beside it")
        XCTAssertEqual(try gate(bin, f, "deny Unknown[dispatch] bAmbig\n").code, 1,
                       "`ambiguous:` projects to class `dispatch` (§6.2) — the gate must bite")
        XCTAssertEqual(try gate(bin, f, "deny Unknown[indirect] bAmbig\n").code, 0,
                       "…and NOT to `indirect`: the rejected ⟨0.24⟩ reclassification would narrow every "
                       + "shipped `deny E Unknown[dispatch]`")
        XCTAssertEqual(try gate(bin, f, "deny Unknown[unresolved] bAmbig\n").code, 0,
                       "…and NOT through the catch-all, which is what an absent kind looks like")
        XCTAssertEqual(try unverifiedFns(bin, f, prefix: "r1", cls: "dispatch"), ["bAmbig"],
                       "the second class path (`unverified --class`) must answer the same way as the gate")
    }

    /// THE OFF-VOCABULARY CONTROL (SPEC §4 ⟨0.24⟩ names it). `banana:whatever` is in the same
    /// `kind:detail` shape as the five real kinds. §2 forward-compatibility: round-tripped verbatim,
    /// classified through the conservative catch-all, and NOT admitted to any narrower class.
    ///
    /// MUTATION-VERIFIED, and each mutation was caught by a different arm — so no arm here is decoration:
    ///  - `reasonClass`'s catch-all → `dispatch` (the blanket) fails BOTH tests in this file and three
    ///    lines of `PolicyTests.testReasonClassMapsRawReasons`.
    ///  - the `ambiguous` prefix test replaced by a bare `contains(":")` — recognising the SHAPE instead
    ///    of the SET — leaves every GATE arm of the `ambiguous:` test above green, and is caught only by
    ///    this test and by the cross-kind separation arm both tests share.
    ///  - relaying the dep's token as `reasonClass(token)` instead of verbatim is caught by the
    ///    round-trip arms alone; the gate arms survive it, because the class does.
    func testAFabricatedOffVocabularyKindRoundTripsAndFallsToTheCatchAll() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let f = try makeFixture(bin)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let fns = try scan(bin, f, out: "r2")

        XCTAssertEqual(fns["bBanana"]?["unknownWhy"] as? [String], ["banana:whatever"],
                       "§2: an unrecognized kind round-trips VERBATIM — never dropped, never normalized")
        XCTAssertEqual(try gate(bin, f, "deny Unknown[unresolved] bBanana\n").code, 1,
                       "§6.2's conservative catch-all — an unclassifiable hole is still gated")
        for cls in ["dispatch", "reflect", "native", "indirect", "setup"] {
            XCTAssertEqual(try gate(bin, f, "deny Unknown[\(cls)] bBanana\n").code, 0,
                           "a fabricated kind must not be admitted to `\(cls)` — the arm a blanket "
                           + "catch-all returning a real class fails")
        }
        XCTAssertEqual(try unverifiedFns(bin, f, prefix: "r2", cls: "unresolved"), ["bBanana"],
                       "the second class path agrees: catch-all, not silence")
        XCTAssertEqual(try unverifiedFns(bin, f, prefix: "r2", cls: "dispatch"), ["bAmbig"],
                       "…and it separates the two kinds, so neither arm is passing vacuously")
    }
}
