import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R603 — **⟨0.39⟩ OBLIGATION 2's OWNER VOTE COUNTED MODULES WHERE THE THING IT ASSIGNS IS A
/// PACKAGE.**
///
/// `abstractionOwnerPkg` is filled from `Set(files.compactMap { foreignOwnerModule(inFile: $0) })` under a
/// `count == 1` never-guess gate. The gate is right; the unit was wrong. A consumer that conforms to ONE
/// dependency's protocol across two files which import two modules **of that same package** —
/// `import NIOTLS` here, `import NIOFoundationCompat` there, both `swift-nio` — read as two owners and the
/// entry was dropped. `Deps.chainedPkgs` already carries this exact rationale for the join half: *"a loss
/// manufactured by the fix, on exactly the multi-module dependencies the fix exists for."* This is R565's
/// module-vs-package confusion at the one site R565 did not reach.
///
/// FOUND BY FIXING R592, WHICH IS WHY IT IS FILED SEPARATELY. Excluding own-package C targets un-suppressed
/// `NIOSSL/NIOSSLHandler.swift` to `NIOTLS`; its sibling conformance file already answered
/// `NIOFoundationCompat`; and **36 `swift-nio#ChannelInboundHandler.*` union entries carrying real effects
/// (`Env`/`Net`/`Fs`/`Unknown`) vanished** from nio-ssl's chained report. Deduping by package restores all
/// 36 and loses nothing: in that arm the full removal set is 278 rows, every one a `CNIOBoringSSL#` entry
/// naming nio-ssl's own C shim as the owner of `Equatable`/`Hashable`/`CustomStringConvertible`.
///
/// WHERE IT CANNOT FIRE, and the control below pins it: with no readable dependency manifest
/// `pkgOfModule` falls back to the module name, so `pkgs == mods` and the verdict is unchanged. A/B over
/// 11 unresolved packages is **ADDED 0 REMOVED 0 CHANGED 0** — which is why the reach probe exists, and
/// why the evidence for this row is the CHAINED arm.
final class UnionOwnerPackageVoteProcessTests: XCTestCase {

    private struct Arm {
        /// true: two modules of ONE dependency package (the defect).
        /// false: two modules of TWO DIFFERENT packages (the never-guess control, which must still refuse).
        let oneOwningPackage: Bool
        let label: String
    }

    /// `hash -> inferred` for the consumer's `interfaceUnion` rows.
    private func runArm(_ arm: Arm) throws -> [String: [String]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r603-\(arm.label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        // THE ONE VARIABLE: whether `RatesA` and `RatesB` live in one package or two. The consumer's
        // sources, the conformances, the effect and the binary are byte-identical between the arms.
        if arm.oneOwningPackage {
            try write("depa/Package.swift", """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "RatesPkg",
                products: [.library(name: "RatesA", targets: ["RatesA"]),
                           .library(name: "RatesB", targets: ["RatesB"])],
                targets: [.target(name: "RatesA"), .target(name: "RatesB", dependencies: ["RatesA"])])
            """)
            try write("depa/Sources/RatesA/lib.swift",
                      "public protocol Backend { func size() -> Int }\n")
            try write("depa/Sources/RatesB/extra.swift",
                      "@_exported import RatesA\npublic func extraPure() -> Int { return 1 }\n")
        } else {
            for (dir, pkg, mod) in [("depa", "PkgA", "RatesA"), ("depb", "PkgB", "RatesB")] {
                try write("\(dir)/Package.swift", """
                // swift-tools-version:5.9
                import PackageDescription
                let package = Package(name: "\(pkg)",
                    products: [.library(name: "\(mod)", targets: ["\(mod)"])],
                    targets: [.target(name: "\(mod)")])
                """)
                try write("\(dir)/Sources/\(mod)/lib.swift",
                          "public protocol Backend { func size() -> Int }\n")
            }
            try write("depa/Sources/RatesA/extra.swift", "public func extraPure() -> Int { return 1 }\n")
        }
        let depsList = arm.oneOwningPackage
            ? ".package(path: \"../depa\")"
            : ".package(path: \"../depa\"), .package(path: \"../depb\")"
        let prodB = arm.oneOwningPackage ? "depa" : "depb"
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [\(depsList)],
            targets: [.target(name: "App", dependencies: [
                .product(name: "RatesA", package: "depa"),
                .product(name: "RatesB", package: "\(prodB)")])])
        """)
        // TWO CONFORMANCE FILES, ONE ABSTRACTION SPELLING, ONE IMPORT EACH — the shape that makes the
        // owner vote collect two names. `A.size` carries the effect so the union entry is something a
        // consumer would want; `B.size` is pure, so a lost entry is a lost EFFECT and not just a lost key.
        try write("app/Sources/App/a.swift", """
        import RatesA
        import Foundation
        public struct A: Backend {
            public func size() -> Int {
                return (try? Data(contentsOf: URL(fileURLWithPath: "/etc/hosts")).count) ?? 0
            }
        }
        """)
        try write("app/Sources/App/b.swift", """
        import RatesB
        public struct B: Backend {
            public func size() -> Int { return extraPure() }
        }
        """)

        let out = root.appendingPathComponent("r")
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", out.path])
        XCTAssertEqual(r.code, 0, "the consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.App.Swift.json"))) as? [String: Any]
        // §E3 — an absence assertion over a report that judged nothing is an assertion about nothing.
        XCTAssertEqual(((d?["analyzed"] as? [String: Any])?["count"] as? Int) ?? 0, 2,
                       "both conformers must be analyzed — stderr: \(r.err)")
        var byHash: [String: [String]] = [:]
        for f in ((d?["functions"] as? [[String: Any]]) ?? []) where (f["interfaceUnion"] as? Bool) == true {
            byHash[(f["hash"] as? String) ?? "?"] = (f["inferred"] as? [String]) ?? []
        }
        return byHash
    }

    func testTwoModulesOfOneDependencyPackageAreOneOwnerNotTwo() throws {
        // Pre-fix: [:] — the vote saw `RatesA` and `RatesB` and refused.
        XCTAssertEqual(try runArm(Arm(oneOwningPackage: true, label: "one")),
                       ["RatesPkg#Backend.size": ["Fs"]],
                       "one package's two modules are ONE owner; refusing here drops a union entry whose "
                       + "effect a consumer joining `RatesPkg#Backend.size` would otherwise charge")
    }

    func testTwoDifferentPackagesClaimingOneAbstractionStillRefuse() throws {
        // THE CONTROL for the direction this fix did NOT intend: deduping by package must not collapse
        // the never-guess rule itself. Unchanged by the fix — [:] before and after.
        XCTAssertEqual(try runArm(Arm(oneOwningPackage: false, label: "two")), [:],
                       "two genuinely different packages declaring the same abstraction spelling is an "
                       + "ambiguous key, and an ambiguous key must not be published into either "
                       + "namespace — a same-named abstraction's consumer could join it and be charged "
                       + "for a body it cannot reach")
    }
}
