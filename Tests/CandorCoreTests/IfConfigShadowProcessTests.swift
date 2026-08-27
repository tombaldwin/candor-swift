import XCTest
import Foundation

/// THE `#if`-GATED STUB: one scope level from the shellOut fix in `NameHeuristicOverloadShadowProcessTests`,
/// and the residual that fix's own CHANGELOG entry filed by name — "6 functions in swift-nio's
/// `_NIOFileSystem`/`NIOFS` lose a real `Env` tag to their own module's Windows-only `getenv` stub".
///
/// `#if os(Windows) func getenv(_:) -> ... { fatalError(...) } #endif` beside `if let v =
/// getenv("PATH") { ... }` in the SAME module, with NO `#else`: this engine models no build
/// configuration, so `DeclCollector` reads every `#if` branch unconditionally (SwiftSyntax's default
/// visitor descends into an `IfConfigDeclSyntax` regardless of which branch, if any, a real build would
/// keep) and the Windows-only stub is exactly as visible here as an unconditional declaration —
/// permanently shadowing the `kappaFree` heuristic for EVERY build, including the one that never
/// contains the stub. `deny Env` exited 0, `policy ✓`, `functions` EMPTY — not even an `Unknown`.
///
/// THE FIX: `FnInfo.isConditionallyCompiled` (DeclCollector.swift) marks a declaration sitting inside any
/// `#if` depth, any condition. The shadow sets Driver.swift builds for `CallCollector.localFreeFns`
/// (`freeFnUnconditionalQuals` scan-wide, `conditionalOnlyFreeFnNamesByModule` per-module — the same
/// module line the shellOut fix already drew for the OVERLOADED case) now exclude a bare name whose ONLY
/// declaration(s) are conditional; a name with even one UNCONDITIONAL declaration keeps shadowing exactly
/// as before (a real resolution exists — winner-take-all is right, same as shellOut). A name shadowed
/// ONLY by a conditional declaration is passed separately as `conditionallyShadowedFreeFns`: the κ
/// heuristic fires (the call may genuinely reach the real platform function on a build without the stub),
/// and the ordinary call edge to the conditional declaration is ALSO kept, so the two readings UNION
/// rather than one picking a winner — resolution is not FAILED here, it is CONDITIONAL, and union is the
/// same safe direction `matchOverloads` already takes when an overload cannot be ruled out.
final class IfConfigShadowProcessTests: XCTestCase {

    private func binaryURL() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try binaryURL()
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    // ── 1. THE DEFECT, minimal repro (the ifhedge-A corpus find) ──────────────────────────────────────
    func testAWindowsOnlyGetenvStubNoLongerPermanentlyShadowsTheRealCallersEnvCharge() throws {
        let by = try scan("""
        #if os(Windows)
        func getenv(_ name: String) -> String? { fatalError("no getenv on windows shim") }
        #endif
        func realUsage() -> String? {
            return getenv("PATH")
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Env"],
                       "the same-module, no-`#else` `#if os(Windows)` stub must not shadow the real "
                       + "cross-platform `getenv` charge — the ifhedge-A cardinal sin: \(by)")
    }

    // ── 2. CONTROL — identical code with the `#if` block removed entirely must be unmoved ─────────────
    // The sibling of the defect above: proves the fix is about the CONDITIONAL declaration specifically,
    // not a coincidental side effect of some other change (ifhedge-control).
    func testTheSameCallWithNoIfBlockAtAllIsUnaffected() throws {
        let by = try scan("""
        func realUsage() -> String? {
            return getenv("PATH")
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Env"],
                       "no local declaration at all — the heuristic must fire exactly as before: \(by)")
    }

    // ── 3. CONTROL — an UNCONDITIONAL same-module local declaration must STILL shadow ──────────────────
    // The whole reason the shadow mechanism exists: a project's own free function of a collision-prone
    // name must never be fabricated as the platform call. Narrowing the shadow to the CONDITIONAL case
    // must not regress this (ifhedge-unconditional).
    func testAnUnconditionalLocalGetenvStillShadowsTheHeuristic() throws {
        let by = try scan("""
        func getenv(_ name: String) -> String? { return nil }
        func realUsage() -> String? {
            return getenv("PATH")
        }
        """)
        XCTAssertNil(by["realUsage"], "an unconditional local `getenv` is a real, unambiguous "
                     + "declaration — it must shadow the heuristic and resolve to its own (pure) body, "
                     + "not fabricate Env: \(by)")
    }

    // ── 4. UNION, not a silent drop — the conditional declaration's OWN effects still count ───────────
    // If the `#if`-gated stub is not a no-op fatalError but performs a real effect of its own, that
    // effect must not be lost the moment the heuristic also fires — the two readings union.
    func testTheConditionalDeclarationsOwnEffectStillCountsAlongsideTheHeuristic() throws {
        let by = try scan("""
        import Foundation
        #if os(Windows)
        func getenv(_ name: String) -> String? {
            NSLog("windows shim reached for %@", name)
            return nil
        }
        #endif
        func realUsage() -> String? {
            return getenv("PATH")
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Env", "Log"],
                       "the heuristic's Env and the conditional stub's own Log must UNION — resolution "
                       + "is conditional here, not failed, so this is not a pick-one situation: \(by)")
    }

    // ── 5. THE swift-nio SHAPE — declared TWICE, once per target, each behind its own `#if` ───────────
    // The exact structure the corpus find traced: two SEPARATE modules each independently declare their
    // own `#if os(Windows)`-gated stub of the same bare name (making it "overloaded" in Driver.swift's
    // sense — see `qualGroup`), and each has its own real caller. A module must resolve to ITS OWN
    // conditional declaration for the union, and must not shadow via the OTHER module's declaration
    // (the module-scoping the shellOut fix already established for the overloaded case).
    func testEachModuleWithItsOwnConditionalStubResolvesIndependently() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-ifconfig-modscope-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Sources/ModA"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Sources/ModB"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "ModA"), .target(name: "ModB")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        #if os(Windows)
        func getenv(_ name: String) -> String? { fatalError("shim A") }
        #endif
        public func realUsageA() -> String? { return getenv("TMPDIR") }
        """.write(to: root.appendingPathComponent("Sources/ModA/A.swift"), atomically: true, encoding: .utf8)
        try """
        #if os(Windows)
        func getenv(_ name: String) -> String? { fatalError("shim B") }
        #endif
        public func realUsageB() -> String? { return getenv("HOME") }
        """.write(to: root.appendingPathComponent("Sources/ModB/B.swift"), atomically: true, encoding: .utf8)

        let bin = try binaryURL()
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let by = try ProcessHarness.fns(ofJson: r.out)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsageA"), ["Env"],
                       "ModA's own conditional stub must not block ModA's real Env charge: \(by)")
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsageB"), ["Env"],
                       "ModB's own conditional stub must not block ModB's real Env charge: \(by)")
    }
}
