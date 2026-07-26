import XCTest
import Foundation

/// ONE APPLY SITE for a chained dependency entry (SPEC §2).
///
/// This engine carried THREE copies of "inherit a `DepEntry`", and they had drifted: the chained-GLOBAL
/// read applied the effects, `hosts`, `cmds` and `paths` and silently dropped `tables`, `invisible` and
/// `incomplete`. So a consumer that reached a dependency's effectful lazy global inherited the EFFECT and
/// none of the dependency's own honesty markers — which is exactly the case SPEC §2 names when it says
/// the join must apply every surface the ordinary join applies, "not just the effects", because a join
/// that carries the effect and drops `incomplete` lets a benign literal in the consumer certify what the
/// dependency declared uncertifiable.
///
/// candor-rust found three drifted copies of this (`7cb5748`) and candor-java two (`6ab26e4`) by asking
/// the same question. It is a duplication defect, not a swift accident, and the audit is worth repeating
/// in any engine before a new consumer is added on top of it.
final class DepApplySiteProcessTests: XCTestCase {

    private func binaryURL() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    /// A chained dependency's effectful LAZY GLOBAL. Reading it forces the initializer, so the consumer
    /// inherits its `Fs` — and must inherit the dependency's `invisible: [MysteryKit]` with it. Before
    /// the fold the effect crossed the boundary and the disclosure did not, so the consumer read as a
    /// FULLY-ANALYSED `Fs` when the truth is `Fs` plus a blind spot inside the dependency.
    func testChainedGlobalReadInheritsTheDependencysDisclosure() throws {
        let bin = try binaryURL()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-swift-applysite-\(UUID().uuidString)")
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
        // `MysteryKit` is outside the platform frontier and covered by no κ tier, so the dep's own report
        // discloses `invisible: [MysteryKit]` on this global — a blind spot the CONSUMER cannot see for
        // itself and must be told about.
        try """
        import Foundation
        import MysteryKit

        public let boot: Int = {
            mysteryBoot()
            _ = FileManager.default.contents(atPath: "/dep-boot")
            return 1
        }()
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
        try "import DepLib\npublic func readsTheGlobal() -> Int { return boot }\n"
            .write(to: app.appendingPathComponent("Sources/App/App.swift"), atomically: true, encoding: .utf8)

        // Delete the output before each arm — a crashed or stale run otherwise leaves the previous
        // report to be read back as this one's result (standing bar item 7).
        let depOut = root.appendingPathComponent("dep-r.DepLib.Swift.json")
        try? fm.removeItem(at: depOut)
        XCTAssertEqual(try ProcessHarness.run(bin, [dep.path, "--out", root.appendingPathComponent("dep-r").path]).code, 0)

        func entry(_ path: URL, _ name: String) throws -> [String: Any]? {
            let d = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
            for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] where f["fn"] as? String == name {
                return f
            }
            return nil
        }
        let depBoot = try entry(depOut, "boot")
        XCTAssertEqual(depBoot?["invisible"] as? [String], ["MysteryKit"],
                       "PREMISE: the dependency must actually disclose the blind spot, else the consumer "
                       + "assertion below is vacuous; got \(depBoot ?? [:])")

        let appOut = root.appendingPathComponent("app-r.App.Swift.json")
        try? fm.removeItem(at: appOut)
        XCTAssertEqual(try ProcessHarness.run(bin, [app.path, "--out", root.appendingPathComponent("app-r").path],
                                              env: ["CANDOR_DEPS": depOut.path]).code, 0)
        let reader = try entry(appOut, "readsTheGlobal")
        XCTAssertTrue(Set(reader?["inferred"] as? [String] ?? []).contains("Fs"),
                      "CONTROL: reading a dep's lazy global forces its initializer, so the Fs crosses the "
                      + "boundary — this half never broke; got \(reader ?? [:])")
        XCTAssertEqual(reader?["invisible"] as? [String], ["MysteryKit"],
                       "…and the dependency's own blind-module disclosure must cross WITH it. Carrying "
                       + "the effect and dropping the disclosure turns `Fs plus a blind spot` into a "
                       + "fully-analysed `Fs`; got \(reader ?? [:])")
    }
}
