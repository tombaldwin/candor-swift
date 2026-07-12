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
}
