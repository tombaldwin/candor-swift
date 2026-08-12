import XCTest
import Foundation

/// PROCESS-layer pins over the `gains` query verb (FixCLI.runGainsCLI) — the package-level supply-chain
/// alarm (SPEC §5.1). Read-only over report files this suite writes by hand (gains never scans), spawned
/// via ProcessHarness in PathProcessTests' style. Pins the four max-review findings on the verb:
///   A — a NON-EMPTY functions array whose every entry is junk is a CORRUPT report (exit 2), never a
///       {byFunction:[],gained:[]} all-clear;
///   B — the legacy bare-array report form is accepted (a bare `[]` is a VALID clean-empty baseline,
///       as rust/ts/java answer it);
///   C — §2.1 producing-build provenance: baseline_version/engine_version in the JSON + the one-line
///       stderr ⚠ mismatch disclosure;
///   D — a PARTIAL baseline callgraph (a matched sidecar failed to parse) degrades origin to
///       "unknown", never mislabels the dropped file's fns "new";
///   E — junk entries among good ones are disclosed with a COUNT (rust load_entries_inner parity),
///       never silently dropped;
///   F — one corrupt sibling among valid reports is tolerated but SUMMARIZED (partial-surface line);
///       every-sibling-corrupt is a net-empty hard failure (exit 2, rust load_fninfo_loud parity).
final class GainsProcessTests: XCTestCase {

    /// A scratch dir the fixture reports live in; callers `defer` removal.
    private func makeDir() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-gains-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, _ dir: URL, _ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private let curEnvelope = """
    {"candor":{"version":"candor-swift-0.11.0"},"functions":[{"fn":"Pkg.doNet","inferred":["Net"]}]}
    """

    /// FINDING A: a report whose NON-EMPTY functions array yields ZERO usable entries (every entry
    /// dropped) is a parse FAILURE (exit 2 + a naming stderr disclosure) — not a successfully-parsed
    /// empty report that prints a false {byFunction:[],gained:[]} all-clear at exit 0.
    func testAllJunkReportFailsLoud() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(#"{"functions":[{"bogus":1},{"fn":""}]}"#, dir, "cur.json")
        let base = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base, "--json"])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("no usable functions"), r.err)
        XCTAssertTrue(r.err.contains("cur.json"), r.err)
        XCTAssertFalse(r.out.contains("byFunction"), "must not emit an all-clear JSON: \(r.out)")
    }

    /// A well-formed EMPTY functions array stays a VALID pure report — success, not corruption.
    func testEmptyEnvelopeBaselineIsValid() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.out, "Pkg.doNet\tNet\n")
    }

    /// FINDING B: the legacy v0.1 bare-array report — here the clean-empty `[]` every other engine
    /// accepts — is a VALID baseline (exit 0), not a rejected parse (the old behavior exited 2 while
    /// rust/ts/java answered).
    func testBareArrayCleanEmptyBaseline() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write("[]", dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["gained"] as? [String], ["Net"])
        // A bare-array baseline carries no §2.1 header — provenance is the honest "".
        XCTAssertEqual(d["baseline_version"] as? String, "")
        XCTAssertEqual(d["engine_version"] as? String, "candor-swift-0.11.0")
    }

    /// A NON-EMPTY bare-array report still parses (legacy entries load), and effects subtract normally.
    func testBareArrayNonEmptyBaseline() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write(#"[{"fn":"Pkg.doNet","inferred":["Net"]}]"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.out, "", "no gains when the baseline already has the effect: \(r.out)")
    }

    /// FINDING C: when BOTH producing builds are known and differ, gains discloses on stderr (the gain
    /// may be engine reclassification, not the dependency changing) and the JSON carries the
    /// baseline_version/engine_version provenance fields — mirrors candor-ts/candor-java.
    func testVersionMismatchDisclosure() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write(#"{"candor":{"version":"candor-swift-0.10.0"},"functions":[]}"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("⚠ baseline @candor-swift-0.10.0 ≠ engine @candor-swift-0.11.0"), r.err)
        XCTAssertTrue(r.err.contains("reclassifying"), r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["baseline_version"] as? String, "candor-swift-0.10.0")
        XCTAssertEqual(d["engine_version"] as? String, "candor-swift-0.11.0")

        // The human TSV surface is pinned byte-stable — stdout unchanged (disclosure is stderr-only).
        let t = try ProcessHarness.run(binary, ["gains", cur, base])
        XCTAssertEqual(t.code, 0, t.err)
        XCTAssertEqual(t.out, "Pkg.doNet\tNet\n")
        XCTAssertTrue(t.err.contains("⚠ baseline @"), t.err)
    }

    /// Matching versions: NO stderr disclosure; the provenance fields still emit (unconditional).
    func testMatchingVersionsNoDisclosure() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        let base = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertFalse(r.err.contains("⚠"), r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["baseline_version"] as? String, "candor-swift-0.11.0")
        XCTAssertEqual(d["engine_version"] as? String, "candor-swift-0.11.0")
    }

    /// FINDING D: a PARTIAL baseline callgraph (two sidecars, one corrupt — its nodes dropped with the
    /// stderr disclosure) must NOT label a fn absent from the surviving half "new": the fn may have
    /// lived in the dropped file, so the honest origin is "unknown".
    func testPartialBaselineCallgraphDegradesOriginToUnknown() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "rep.A.Swift.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "rep.B.Swift.json")
        _ = try write(#"{"Other.fn":[]}"#, dir, "rep.A.Swift.callgraph.json")
        _ = try write("NOT JSON{{{", dir, "rep.B.Swift.callgraph.json")
        let basePrefix = dir.appendingPathComponent("rep").path

        let r = try ProcessHarness.run(binary, ["gains", cur, basePrefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("failed to parse"), r.err) // mergeCallgraph's disclosure kept
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(d["byFunction"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["origin"] as? String, "unknown", r.out)
    }

    /// The COMPLETE-graph control for the partial pin: with both sidecars valid and the fn in neither,
    /// origin is a confident "new" — the downgrade is scoped to the corrupt-sidecar case alone.
    func testCompleteBaselineCallgraphStillSaysNew() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "rep.A.Swift.json")
        _ = try write(#"{"Other.fn":[]}"#, dir, "rep.A.Swift.callgraph.json")
        _ = try write(#"{"Another.fn":["Other.fn"]}"#, dir, "rep.B.Swift.callgraph.json")
        let basePrefix = dir.appendingPathComponent("rep").path

        let r = try ProcessHarness.run(binary, ["gains", cur, basePrefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(d["byFunction"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["origin"] as? String, "new", r.out)
    }

    /// FINDING E (max-review): junk entries AMONG good ones are disclosed with a COUNT (the Rust
    /// load_entries_inner rule — "N function entries could not be parsed and are OMITTED"), never
    /// silently dropped; the good entries still answer (exit 0, TSV intact).
    func testJunkEntriesAmongGoodOnesDisclosedWithCount() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(
            #"{"candor":{"version":"candor-swift-0.11.0"},"functions":[{"bogus":1},{"fn":"Pkg.doNet","inferred":["Net"]},{"fn":""}]}"#,
            dir, "cur.json")
        let base = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "base.json")

        let r = try ProcessHarness.run(binary, ["gains", cur, base])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(r.out, "Pkg.doNet\tNet\n", "the usable entry still answers: \(r.out)")
        XCTAssertTrue(r.err.contains("2 function entries could not be parsed and are OMITTED"), r.err)
        XCTAssertTrue(r.err.contains("cur.json"), r.err)
        XCTAssertTrue(r.err.contains("re-run the scan"), r.err)
    }

    /// FINDING F (max-review): ONE corrupt sibling among valid baseline reports stays
    /// disclosed-and-tolerated (the Rust net rule — NOT a hard fail), but the answer must carry the
    /// NET consequence: the per-file OMITTED note PLUS the partial-surface summary line
    /// ("1 of 2 baseline reports failed to load — the delta is computed over a PARTIAL baseline").
    /// Exit 0, valid JSON.
    func testCorruptSiblingDisclosesPartialBaselineSummary() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[{"fn":"Pkg.other","inferred":["Fs"]}]}"#,
                      dir, "rep.A.Swift.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[{"fn":"Pkg."#,
                      dir, "rep.B.Swift.json")   // truncated mid-write
        let basePrefix = dir.appendingPathComponent("rep").path

        let r = try ProcessHarness.run(binary, ["gains", cur, basePrefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.err.contains("rep.B.Swift.json"), r.err)                      // the casualty is named
        XCTAssertTrue(r.err.contains("OMITTED from this gains answer"), r.err)        // with its consequence
        XCTAssertTrue(
            r.err.contains("1 of 2 baseline reports failed to load — the delta is computed over a PARTIAL baseline"),
            r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(d["gained"] as? [String], ["Net"], r.out)
    }

    /// The tolerant-merge control: with EVERY baseline sibling corrupt the merge is net-empty over a
    /// hard failure — exit 2 (never an empty all-clear), the Rust load_fninfo_loud net rule.
    func testAllSiblingsCorruptFailsLoud() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        _ = try write("NOT JSON{{{", dir, "rep.A.Swift.json")
        _ = try write(#"{"functions":[{"fn":"#, dir, "rep.B.Swift.json")
        let basePrefix = dir.appendingPathComponent("rep").path

        let r = try ProcessHarness.run(binary, ["gains", cur, basePrefix, "--json"])
        XCTAssertEqual(r.code, 2, r.out)
        XCTAssertTrue(r.err.contains("every report found at baseline prefix"), r.err)
        XCTAssertTrue(r.err.contains("refusing to report an empty (all-clear) answer"), r.err)
        XCTAssertFalse(r.out.contains("byFunction"), "must not emit JSON over a corrupt baseline: \(r.out)")
    }

    /// A node still IN the partial graph keeps "existing" — only the negative claim degrades.
    func testPartialGraphNodeStaysExisting() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cur = try write(curEnvelope, dir, "cur.json")
        _ = try write(#"{"candor":{"version":"candor-swift-0.11.0"},"functions":[]}"#, dir, "rep.A.Swift.json")
        _ = try write(#"{"Pkg.doNet":[]}"#, dir, "rep.A.Swift.callgraph.json")
        _ = try write("NOT JSON{{{", dir, "rep.B.Swift.callgraph.json")
        let basePrefix = dir.appendingPathComponent("rep").path

        let r = try ProcessHarness.run(binary, ["gains", cur, basePrefix, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(d["byFunction"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["origin"] as? String, "existing", r.out)
    }

    // ── ⟨0.28⟩ the ⟨0.21⟩ completeness manifest travels into `gains`, on BOTH sides ──────────────────

    /// SPEC §2 ⟨0.28⟩ / conformance PART 39 (ii). The `coverage` rider has ridden this verb since ⟨0.15⟩
    /// for the reason §2 gives — *a "no gains" over an uncovered dep reads clean with false confidence* —
    /// and the SAME verb, on the SAME report, in the SAME output, dropped the STRONGER caveat:
    /// `coverage.uncovered` says "I could not see into this dependency", `unanalyzed` says "I could not
    /// read this file of YOUR OWN CODE", `analyzed.count: 0` says "I judged nothing at all".
    ///
    /// BOTH SIDES, SEPARATELY, because the answer rests on two reports that fail differently: an
    /// incomplete CURRENT means the gained set may be SHORT, an incomplete BASELINE means the comparison
    /// floor is soft and the existing-vs-new `origin` split is unreliable. One combined flag would leave a
    /// supply-chain reviewer unable to act on it. Key names are the candor-rust `fe5d831` wire set,
    /// character for character — this is a cross-engine surface and PART 39's row greps it.
    func testTheCompletenessManifestTravelsOnBothSidesOfGains() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The PART 39 fixture shape: a baseline carrying BOTH caveats, a clean current that gained Net.
        _ = try write(#"""
        {"candor":{"version":"t"},"analyzed":{"count":3},
         "coverage":{"uncovered":[{"name":"mystery-crate","calls":7}]},
         "unanalyzed":[{"path":"src/broken.swift","reason":"parse error"}],
         "functions":[{"fn":"a","inferred":["Fs"]}]}
        """#, dir, "hedged.M.Swift.json")
        _ = try write(#"""
        {"candor":{"version":"t"},"analyzed":{"count":3},
         "functions":[{"fn":"a","inferred":["Fs","Net"]}]}
        """#, dir, "clean.M.Swift.json")
        let hedgedPre = dir.appendingPathComponent("hedged").path
        let cleanPre = dir.appendingPathComponent("clean").path

        // A — an incomplete BASELINE: the floor is soft, and the output says which half.
        let a = try ProcessHarness.run(binary, ["gains", cleanPre, hedgedPre, "--json"])
        XCTAssertEqual(a.code, 0, a.err)
        let da = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(a.out.utf8)) as? [String: Any])
        XCTAssertEqual(da["baselineIncomplete"] as? Bool, true,
                       "the comparison floor is soft, so the existing-vs-new split is unreliable: \(a.out)")
        XCTAssertEqual((da["baselineUnanalyzed"] as? [[String: Any]])?.first?["path"] as? String,
                       "src/broken.swift", "…and the unread file is NAMED: \(a.out)")
        XCTAssertNil(da["incomplete"], "the CURRENT side is complete — its flag must stay off: \(a.out)")
        XCTAssertNil(da["unanalyzed"], "…and so must its manifest: \(a.out)")
        // The ⟨0.15⟩ precedent still rides alongside — PART 39 (i) is a hard FAIL, never a SKIP.
        XCTAssertTrue(a.out.contains("mystery-crate"), "coverage still travels: \(a.out)")

        // B — an incomplete CURRENT: the gained set may be SHORT, which is the other failure entirely.
        let b = try ProcessHarness.run(binary, ["gains", hedgedPre, cleanPre, "--json"])
        XCTAssertEqual(b.code, 0, b.err)
        let db = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(b.out.utf8)) as? [String: Any])
        XCTAssertEqual(db["incomplete"] as? Bool, true,
                       "effects the reader is not being told about: \(b.out)")
        XCTAssertEqual((db["unanalyzed"] as? [[String: Any]])?.first?["path"] as? String, "src/broken.swift",
                       b.out)
        XCTAssertNil(db["baselineIncomplete"], "the two sides are disclosed SEPARATELY: \(b.out)")
        XCTAssertNil(db["baselineUnanalyzed"], b.out)
        XCTAssertEqual(db["gained"] as? [String], [],
                       "AND THE ANSWER IS AN EMPTY GAINED SET — a supply-chain all-clear out of a report "
                       + "that names a file it could not read is exactly what the caveat is for: \(b.out)")

        // …and `analyzed.count: 0` is the SECOND CAUSE — no unread FILE to name, so the flag rises alone.
        _ = try write(#"{"candor":{"version":"t"},"analyzed":{"count":0},"functions":[{"fn":"a","inferred":["Fs"]}]}"#,
                      dir, "zero.M.Swift.json")
        let z = try ProcessHarness.run(binary,
                                       ["gains", cleanPre, dir.appendingPathComponent("zero").path, "--json"])
        let dz = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(z.out.utf8)) as? [String: Any])
        XCTAssertEqual(dz["baselineIncomplete"] as? Bool, true,
                       "a baseline that judged NOTHING is the softest floor of all: \(z.out)")
        XCTAssertNil(dz["baselineUnanalyzed"], "…with no unread file to name: \(z.out)")

        // C — TWO INTACT REPORTS: the document is exactly what it was. Asserted as the whole KEY SET
        // rather than four `XCTAssertNil`s, because the failure this control exists to catch is a
        // re-serialisation that reorders or ADDS something — the BTreeMap re-sort candor-rust caught.
        _ = try write(#"{"candor":{"version":"t"},"analyzed":{"count":3},"functions":[{"fn":"a","inferred":["Fs"]}]}"#,
                      dir, "intact.M.Swift.json")
        let c = try ProcessHarness.run(binary,
                                       ["gains", cleanPre, dir.appendingPathComponent("intact").path, "--json"])
        XCTAssertEqual(c.code, 0, c.err)
        let dc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(c.out.utf8)) as? [String: Any])
        XCTAssertEqual(Set(dc.keys), ["baseline_version", "byFunction", "engine_version", "gained"],
                       "a complete pair emits the pre-⟨0.28⟩ document unchanged: \(c.out)")

        // D — THE VERDICT DOES NOT MOVE. `gains` is advisory by default and `--strict` keys on the GAINED
        // SET, which this rung does not touch: a hedged pair that gained Net still exits 1 under --strict
        // (not the 2 that would claim candor could not evaluate), and a hedged pair that gained NOTHING
        // still exits 0. A caveat is added; nothing is refused.
        // A hedged CURRENT that also gained, so the row is about the caveat and not about the empty set.
        _ = try write(#"""
        {"candor":{"version":"t"},"analyzed":{"count":3},
         "unanalyzed":[{"path":"src/broken.swift","reason":"parse error"}],
         "functions":[{"fn":"a","inferred":["Fs","Net"]}]}
        """#, dir, "hedgedgain.M.Swift.json")
        let hedgedGainPre = dir.appendingPathComponent("hedgedgain").path
        let intactPre = dir.appendingPathComponent("intact").path
        for (label, argv, want) in [
            ("hedged baseline, gained",  ["gains", cleanPre, hedgedPre, "--json", "--strict"], Int32(1)),
            ("hedged current, gained",   ["gains", hedgedGainPre, intactPre, "--strict"], Int32(1)),
            ("hedged current, NO gain",  ["gains", hedgedPre, cleanPre, "--json", "--strict"], Int32(0)),
            ("hedged baseline, NO gain", ["gains", hedgedPre, hedgedPre, "--json", "--strict"], Int32(0)),
        ] {
            let r = try ProcessHarness.run(binary, argv)
            XCTAssertEqual(r.code, want, "\(label): the exit keys on the gained set, not the caveat")
        }
    }

    /// ⟨0.28⟩ **`judgedNothing` TRAVELS ON THIS VERB, AND ITS SHAPE IS THE PATH LIST — the family
    /// ruling that ended a three-way split.** This engine withheld the key on the reasoning that the
    /// reference did not emit it and a key one engine emits and another does not is a divergence a
    /// consumer sees; the instinct was right and the premise was stale — java had already shipped it as
    /// a path list and ts as a boolean, so the withholding PRODUCED the divergence it was avoiding (the
    /// names appear in SPEC zero times, which is how three engines decided three ways). The ruling: the
    /// key is carried, and it names WHICH report judged nothing, because `baselineIncomplete` alone
    /// cannot — the repair differs per file. The current side carries the unprefixed key for the same
    /// symmetry `unanalyzed`/`baselineUnanalyzed` already have.
    func testJudgedNothingIsNamedAsAPathListOnBothSidesOfGains() throws {
        let binary = try ProcessHarness.binaryURL(for: Self.self)
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try write(#"{"candor":{"version":"t"},"analyzed":{"count":0},"functions":[{"fn":"a","inferred":["Fs"]}]}"#,
                      dir, "zero.M.Swift.json")
        _ = try write(#"{"candor":{"version":"t"},"analyzed":{"count":3},"functions":[{"fn":"a","inferred":["Fs","Net"]}]}"#,
                      dir, "clean.M.Swift.json")
        let zeroPre = dir.appendingPathComponent("zero").path
        let cleanPre = dir.appendingPathComponent("clean").path

        // BASELINE side: prefixed key, path-list shape. `as? [String]` is the SHAPE assertion — a
        // boolean here (the ts drift) or an object fails this line, not just a count.
        let a = try ProcessHarness.run(binary, ["gains", cleanPre, zeroPre, "--json"])
        XCTAssertEqual(a.code, 0, a.err)
        let da = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(a.out.utf8)) as? [String: Any])
        XCTAssertEqual(da["baselineIncomplete"] as? Bool, true, a.out)
        let bjn = try XCTUnwrap(da["baselineJudgedNothing"] as? [String],
                                "the key is a PATH LIST, never a boolean: \(a.out)")
        XCTAssertEqual(bjn.count, 1, a.out)
        XCTAssertTrue(bjn[0].hasSuffix("zero.M.Swift.json"),
                      "…naming WHICH report judged nothing: \(a.out)")
        XCTAssertNil(da["judgedNothing"], "the two sides stay separate: \(a.out)")
        XCTAssertNil(da["incomplete"], a.out)

        // CURRENT side: the unprefixed keys, same shape.
        let b = try ProcessHarness.run(binary, ["gains", zeroPre, cleanPre, "--json"])
        XCTAssertEqual(b.code, 0, b.err)
        let db = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(b.out.utf8)) as? [String: Any])
        XCTAssertEqual(db["incomplete"] as? Bool, true, b.out)
        let jn = try XCTUnwrap(db["judgedNothing"] as? [String], "path list on this side too: \(b.out)")
        XCTAssertTrue(jn.count == 1 && jn[0].hasSuffix("zero.M.Swift.json"), b.out)
        XCTAssertNil(db["baselineJudgedNothing"], b.out)
        XCTAssertNil(db["baselineIncomplete"], b.out)

        // ⟨0.28⟩ and the `unreadable` arm reaches this verb through the same struct: a corrupt sibling
        // on the baseline side raises the flag with NO manifest to name — three engines already hedged
        // these bytes and this one answered clean.
        _ = try write(#"{"candor":{"version":"t"},"functions":[{"fn":"#, dir, "part.M.Swift.json")
        _ = try write(#"{"candor":{"version":"t"},"analyzed":{"count":3},"functions":[{"fn":"a","inferred":["Fs"]}]}"#,
                      dir, "part.N.Swift.json")
        let r = try ProcessHarness.run(binary, ["gains", cleanPre, dir.appendingPathComponent("part").path, "--json"])
        XCTAssertEqual(r.code, 0, r.err)
        let dr = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(dr["baselineIncomplete"] as? Bool, true,
                       "a baseline sibling that does not load is a soft floor: \(r.out)")
        XCTAssertNil(dr["baselineUnanalyzed"], "…with no manifest key of its own — `incomplete` is the "
                                             + "wire for this cause, matching the reference: \(r.out)")
        XCTAssertNil(dr["baselineJudgedNothing"], r.out)
    }
}
