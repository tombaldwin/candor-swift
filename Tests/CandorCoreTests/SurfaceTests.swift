import XCTest
@testable import CandorCore

/// Unit pins over the cold-repo "surface the best find" hook (CandorCore/Surface.swift) — the Swift port
/// of candor-scan's `src/surface.rs`. These MIRROR the reference's `benign_deep_inherited_beats_shallow_effecty`
/// + fallback tests so a divergence fails AT the function, not three layers up in a cross-engine diff.
/// Swift quals use `.` as the separator (where Rust uses `::`), so the graphs are transliterated.
final class SurfaceTests: XCTestCase {

    private func set(_ items: [String]) -> Set<String> { Set(items) }

    func testTokenizeSplitsAllBoundaries() {
        XCTAssertEqual(surfaceTokenize("settings.Settings.needsUpdate"),
                       ["settings", "settings", "needs", "update"])
        XCTAssertEqual(surfaceTokenize("api_client.latest_version"),
                       ["api", "client", "latest", "version"])
    }

    func testBenignDeepInheritedBeatsShallowEffecty() {
        // Graph:
        //   Settings.load  (benign leaf "load")  -inherits-> Net, 3 hops
        //     -> Core.refresh -> Core.syncState -> NetLayer.doSend (direct Net)
        //   api.fetch  (effecty leaf "fetch") -inherits-> Net, 1 hop  (EXCLUDED — effecty)
        //     -> NetLayer.doSend
        var direct: [String: Set<String>] = [:]
        var inferred: [String: Set<String>] = [:]
        var calls: [String: Set<String>] = [:]

        direct["NetLayer.doSend"] = set(["Net"])
        inferred["NetLayer.doSend"] = set(["Net"])

        inferred["Core.syncState"] = set(["Net"])
        calls["Core.syncState"] = set(["NetLayer.doSend"])

        inferred["Core.refresh"] = set(["Net"])
        calls["Core.refresh"] = set(["Core.syncState"])

        // benign candidate: Settings.load, 3 hops to source.
        inferred["Settings.load"] = set(["Net"])
        calls["Settings.load"] = set(["Core.refresh"])

        // effecty candidate: api.fetch, 1 hop — must be excluded by the EFFECTY leaf/module.
        inferred["api.fetch"] = set(["Net"])
        calls["api.fetch"] = set(["NetLayer.doSend"])

        guard case .winner(let got) = surfaceBestFind(inferred: inferred, direct: direct, calls: calls)
        else { return XCTFail("expected a winner") }
        XCTAssertEqual(got.func_, "Settings.load")
        XCTAssertEqual(got.effect, "Net")
        XCTAssertEqual(got.hops, 3)
        XCTAssertEqual(got.source, "NetLayer.doSend")
        XCTAssertEqual(got.benignToken, "load")
    }

    /// isTest must key off the MODULE (qual minus leaf), NEVER the leaf. A PRODUCTION function whose leaf
    /// begins "test" — `Manifest.testConnection` — is real code and MUST surface; a fn in a `Tests`-suffixed
    /// suite type (`AppTests.testFoo`) or a `.tests.` module segment (`App.tests.helper`) MUST be excluded.
    func testProductionTestPrefixedFunctionIsNotExcluded() {
        var direct: [String: Set<String>] = [:]
        var inferred: [String: Set<String>] = [:]
        var calls: [String: Set<String>] = [:]

        // The real effect source.
        direct["NetLayer.doSend"] = set(["Net"])
        inferred["NetLayer.doSend"] = set(["Net"])

        // PRODUCTION fn, leaf begins "test", module "Manifest" is NOT a test context → KEPT.
        inferred["Manifest.testConnection"] = set(["Net"])
        calls["Manifest.testConnection"] = set(["NetLayer.doSend"])

        // A real test method inside a `Tests`-suffixed suite → EXCLUDED (module "AppTests" ends "Tests").
        inferred["AppTests.testConnect"] = set(["Net"])
        calls["AppTests.testConnect"] = set(["NetLayer.doSend"])

        // A fn under a `.tests.` module segment → EXCLUDED (non-leaf segment "tests").
        inferred["App.tests.helper"] = set(["Net"])
        calls["App.tests.helper"] = set(["NetLayer.doSend"])

        let got = bestFinds(inferred: inferred, direct: direct, calls: calls, loc: [:], n: 10)
        XCTAssertEqual(got.map { $0.func_ }, ["Manifest.testConnection"],
                       "only the production test-prefixed fn surfaces; the two test-module fns are excluded")
    }

    /// Salience: a benign fn whose ONLY inherited reach is mundane (Clock/Log/Rand) must NOT be surfaced —
    /// those score 0, so the package honestly falls back to "nothing hidden" rather than over-promising a
    /// clock/log reach as "the most surprising find" (corpus-dogfood refinement; mirrors surface.rs).
    func testMundaneClockLogRandNeverSurfaces() {
        for eff in ["Clock", "Log", "Rand"] {
            var direct: [String: Set<String>] = [:]
            var inferred: [String: Set<String>] = [:]
            var calls: [String: Set<String>] = [:]
            // A benign-named fn inheriting only the mundane effect, with a real local direct source.
            direct["Ticker.stamp"] = set([eff]); inferred["Ticker.stamp"] = set([eff])
            inferred["Settings.load"] = set([eff]); calls["Settings.load"] = set(["Ticker.stamp"])
            guard case .fallback = surfaceBestFind(inferred: inferred, direct: direct, calls: calls)
            else { return XCTFail("expected the honest fallback for a \(eff)-only reach") }
            XCTAssertTrue(bestFinds(inferred: inferred, direct: direct, calls: calls, loc: [:], n: 10).isEmpty,
                          "\(eff) scores 0 salience — never a tour row")
        }
    }

    func testFallbackWhenNothingQualifies() {
        // One effectful function, but it is a DIRECT source (not inherited) AND effecty-named — no
        // candidate qualifies → the honest fallback.
        var direct: [String: Set<String>] = [:]
        var inferred: [String: Set<String>] = [:]
        let calls: [String: Set<String>] = [:]
        direct["net.client.send"] = set(["Net"])
        inferred["net.client.send"] = set(["Net"])

        guard case .fallback = surfaceBestFind(inferred: inferred, direct: direct, calls: calls)
        else { return XCTFail("expected the honest fallback") }
    }

    func testNothingWhenNoEffects() {
        // No non-Unknown effect anywhere → noEffects (caller emits nothing at all).
        let direct: [String: Set<String>] = [:]
        var inferred: [String: Set<String>] = [:]
        let calls: [String: Set<String>] = [:]
        inferred["util.parse"] = set(["Unknown"])

        guard case .noEffects = surfaceBestFind(inferred: inferred, direct: direct, calls: calls)
        else { return XCTFail("expected noEffects") }
    }

    /// The `tour` verb's top-N heuristic (CandorCore.bestFinds), the Swift port of the Rust
    /// `best_finds`: two distinct benign candidates reach Net at different depths → the list names each
    /// ONCE, ranked (deeper reach first — higher score), and `n` caps the list. Mirrors the reference
    /// `dedup_one_row_per_function_top_n`. (The `syncState` intermediary is EFFECTY-named — `sync` — so it
    /// never adds a row, making the surprising set exactly {Settings.load, Model.render}.)
    func testBestFindsDedupOneRowPerFunctionTopN() {
        var direct: [String: Set<String>] = [:]
        var inferred: [String: Set<String>] = [:]
        var calls: [String: Set<String>] = [:]

        direct["NetLayer.doSend"] = set(["Net"])
        inferred["NetLayer.doSend"] = set(["Net"])

        // Settings.load — 3 hops (benign, deep → higher score). All intermediaries are EFFECTY-named
        // (`syncState` → sync, `downloadStep` → download) so they don't add rows.
        inferred["Core.syncState"] = set(["Net"]); calls["Core.syncState"] = set(["NetLayer.doSend"])
        inferred["Core.downloadStep"] = set(["Net"]); calls["Core.downloadStep"] = set(["Core.syncState"])
        inferred["Settings.load"] = set(["Net"]); calls["Settings.load"] = set(["Core.downloadStep"])

        // Model.render — 1 hop (benign, shallow → lower score).
        inferred["Model.render"] = set(["Net"]); calls["Model.render"] = set(["NetLayer.doSend"])

        let loc: [String: String] = ["NetLayer.doSend": "Net.swift:9"]
        let got = bestFinds(inferred: inferred, direct: direct, calls: calls, loc: loc, n: 10)
        XCTAssertEqual(got.count, 2, "two distinct benign functions, one row each")
        XCTAssertEqual(got[0].func_, "Settings.load")  // deeper reach ranks first
        XCTAssertEqual(got[0].hops, 3)
        XCTAssertEqual(got[0].source, "NetLayer.doSend")
        XCTAssertEqual(got[0].sourceLoc, "Net.swift:9")
        XCTAssertEqual(got[1].func_, "Model.render")
        // `n` caps the list.
        XCTAssertEqual(bestFinds(inferred: inferred, direct: direct, calls: calls, loc: loc, n: 1).count, 1)
        // no function is listed twice.
        XCTAssertEqual(Set(got.map { $0.func_ }).count, got.count)
    }
}
