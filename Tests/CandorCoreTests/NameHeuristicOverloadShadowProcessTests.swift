import XCTest
import Foundation

/// THE `shellOut` CORPUS FIND: a hard-coded NAME heuristic (`kappaFree`'s `case "shellOut": return
/// "Exec"`, Classifier.swift) pre-empted a real, in-tree, unambiguous call-graph resolution whenever the
/// project's own same-named function was OVERLOADED.
///
/// ROOT CAUSE: the shadow guard (`localFreeFns`, passed to `CallCollector`) is drawn from
/// `freeFnByName`'s keys, which are read AFTER Driver.swift's overload-suffix rewrite turns `shellOut`
/// into `shellOut(Int)` / `shellOut(String)`. A Swift call site is never spelled with that disambiguator
/// (`shellOut(to: "x")`, never `shellOut(String)(to: "x")`), so once a project overloaded a
/// heuristic-covered name the shadow set no longer contained the bare identifier the call actually used —
/// the heuristic fired UNGUARDED, and the real callee's effects (here, `Fs`) were dropped with no
/// `Unknown`, no `incomplete`, nothing. JohnSundell's ShellOut is the found case; every name in
/// `kappaFree`/`CAPABILITY_FREE_EFFECT` is exposed the same way if a project overloads it.
///
/// THE FIX, two halves:
///   1. Driver.swift captures each free function's BARE name (`localFreeFnBaseNamesByModule`) before the
///      suffix rewrite, keyed by MODULE — not globally — and unions it into the shadow set per caller.
///      MODULE-SCOPED because an unscoped version regressed 1137 functions on the swift-nio corpus: a
///      Windows-only `#if os(Windows) func getenv(...) { fatalError(...) } #endif` stub in one target
///      shadowed `getenv`'s real `Env` charge for every OTHER target in the scan, none of which can even
///      see that declaration. `matchOverloads` already draws this exact line for RESOLUTION
///      (`hitsInCallerModule`, asserted by `DriverResolutionProcessTests
///      .testModuleQualifiedFreeCallResolvesToThatModulesFunction`); the SHADOW guard has to draw it too.
///   2. `depShadows` (CallCollector.swift) + a base-name join key (Deps.swift) extend the same discipline
///      across the scan boundary: a CHAINED (`--workspace`/`CANDOR_DEPS`) dependency's overloaded free
///      function shadows the heuristic exactly as a local one does, and the join answers with the UNION
///      of every overload sharing the base name — the same never-guess-which-one direction
///      `matchOverloads` already takes in-tree when arg types can't select a single candidate.
///
/// See also: soundness/realworld corpus round, 2026-08-27 (the gate-level two-package proof —
/// `deny Fs`/`deny Ipc` exiting 0 over code that plainly does both — is this fix's cross-package half).
final class NameHeuristicOverloadShadowProcessTests: XCTestCase {

    private func binaryURL() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try binaryURL()
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    // ── 1. THE DEFECT, minimal repro — an overloaded LOCAL `shellOut` must resolve in-tree ───────────
    func testOverloadedLocalShellOutResolvesToTheRealSiblingsFsNotTheExecHeuristic() throws {
        let by = try scan("""
        import Foundation
        func shellOut(to command: String) {
            let data = Data()
            try? data.write(to: URL(fileURLWithPath: "/tmp/x"))
        }
        func shellOut(to n: Int) {
            shellOut(to: "literal")
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "shellOut(Int)"), ["Fs"],
                       "an overloaded sibling call must resolve to the REAL callee's Fs, not the "
                       + "`kappaFree` name heuristic's fabricated Exec: \(by)")
        XCTAssertNil(by["shellOut(Int)"]?["cmds"],
                     "no `cmds` surface — the heuristic must not have fired at all: \(by)")
    }

    // ── 2. CONTROL — the heuristic must still fire where it is genuinely needed ───────────────────────
    // Deleting the heuristic to fix the override above would be the fix-deletes-the-feature failure; an
    // out-of-tree/unresolvable `shellOut`-shaped call (no local declaration anywhere) must still charge
    // Exec.
    func testOutOfTreeShellOutStillChargesExecTheHeuristicIsStillNeededHere() throws {
        let by = try scan("""
        func run() { shellOut(to: "echo hi") }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "run"), ["Exec"],
                       "genuinely unresolvable — the platform heuristic is the only signal available "
                       + "and must still fire: \(by)")
    }

    // ── 3. CONTROL — the shadow is MODULE-scoped, not scan-wide ───────────────────────────────────────
    // An overloaded same-named free function declared in one target must not shadow the heuristic for a
    // call in an UNRELATED target that cannot see it (the swift-nio `getenv`/`#if os(Windows)` regression
    // an unscoped version of this fix produced — measured at 1137 functions on that corpus).
    func testAnOverloadInOneModuleDoesNotShadowTheHeuristicInAnUnrelatedModule() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-modscope-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Stubs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Real"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "Stubs"), .target(name: "Real")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        // `Stubs` OVERLOADS `shellOut` with two do-nothing bodies — the shape that made a bare name
        // "overloaded" in Driver.swift's sense (two same-name, same-module declarations).
        try """
        func shellOut(to s: String) {}
        func shellOut(to n: Int) {}
        """.write(to: root.appendingPathComponent("Sources/Stubs/Stubs.swift"), atomically: true, encoding: .utf8)
        // `Real` declares NEITHER overload and does not import `Stubs` — a bare `shellOut(...)` call here
        // can only ever mean the platform heuristic.
        try """
        func run() { shellOut(to: "echo hi") }
        """.write(to: root.appendingPathComponent("Sources/Real/Real.swift"), atomically: true, encoding: .utf8)

        let bin = try binaryURL()
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let by = try ProcessHarness.fns(ofJson: r.out)
        XCTAssertEqual(ProcessHarness.inferred(by, "run"), ["Exec"],
                       "`Real.run` cannot see `Stubs`'s overloaded shellOut — an unscoped shadow set "
                       + "would have dropped the heuristic here anyway, a silent under-report: \(by)")
    }

    // ── 4. THE GATE-LEVEL SHAPE — an overloaded CHAINED DEPENDENCY's free function ────────────────────
    // JohnSundell's ShellOut, vendored as a `--workspace`/`CANDOR_DEPS` dependency: the ShellOutCommand
    // overload delegates to the String overload, which really performs Fs. A bare consumer call must
    // inherit that real effect through the join, not the bare heuristic's Exec-only answer.
    func testChainedDependencysOverloadedFreeFunctionJoinsTheRealUnionedEffectNotTheHeuristicAlone() throws {
        let bin = try binaryURL()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-depshadow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let dep = root.appendingPathComponent("deplib"), app = root.appendingPathComponent("app")
        try fm.createDirectory(at: dep.appendingPathComponent("Sources/DepLib"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "DepLib", targets: [.target(name: "DepLib")])
        """.write(to: dep.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        public struct Cmd { public var s: String; public init(s: String) { self.s = s } }
        public func shellOut(to s: String) { _ = try? FileManager.default.contents(atPath: s) }  // real Fs
        public func shellOut(to c: Cmd) { shellOut(to: c.s) }                                     // delegates
        """.write(to: dep.appendingPathComponent("Sources/DepLib/Lib.swift"), atomically: true, encoding: .utf8)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [.package(path: "../deplib")],
            targets: [.target(name: "App", dependencies: [.product(name: "DepLib", package: "deplib")])]
        )
        """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import DepLib
        func setupRepo() { shellOut(to: Cmd(s: "/x")) }
        """.write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)

        let depOut = root.appendingPathComponent("dep-r.DepLib.Swift.json")
        try? fm.removeItem(at: depOut)
        XCTAssertEqual(try ProcessHarness.run(bin, [dep.path, "--out", root.appendingPathComponent("dep-r").path]).code, 0)

        let appOut = root.appendingPathComponent("app-r.App.Swift.json")
        try? fm.removeItem(at: appOut)
        XCTAssertEqual(try ProcessHarness.run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                                              env: ["CANDOR_DEPS": depOut.path]).code, 0)
        let by = try ProcessHarness.fns(ofJson: String(decoding: try Data(contentsOf: appOut), as: UTF8.self))
        XCTAssertEqual(ProcessHarness.inferred(by, "setupRepo"), ["Fs"],
                       "the consumer's bare `shellOut(to: Cmd(...))` must join the dependency's REAL "
                       + "Fs (through the ShellOutCommand -> String overload chain), not read Exec from "
                       + "the platform heuristic alone — the gate-level cardinal sin (`deny Fs` exiting "
                       + "0 over code that plainly does): \(by)")
    }
}
