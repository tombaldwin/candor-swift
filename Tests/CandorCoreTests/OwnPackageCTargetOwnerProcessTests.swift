import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R592 — **A TARGET OF THE FILE'S OWN PACKAGE IS NOT A FOREIGN OWNER, ANALYZED OR NOT.**
///
/// `Driver.foreignOwnerModule` names the owner of a foreign abstraction as the file's one import that
/// its target DECLARES and that is not `importableByFile`. `importableByFile` is `declaredNames`
/// INTERSECTED WITH `analyzedTargets`, and that intersection is the trap: it answers *did this run read
/// it*, not *is it ours*. **A C target has no `.swift` files, so no run ever reads one** — `declared`
/// holds it, `importable` never can, and it therefore survived every filter as the file's "foreign"
/// candidate.
///
/// Measured at 96211f0 over 11 real packages: 21,807 `dispatchesOn` occurrences, 4,952 foreign-prefixed,
/// **4,880 of those (98.5%) prefixed with a C target of the package being scanned** — `CNIOLinux` 3,071,
/// `CNIOWindows` 1,205, `CNIOBoringSSL` 587, `CNIOAtomics` 14, `CNIOLLHTTP` 3.
///
/// **BOTH ERROR DIRECTIONS WERE LIVE, AND ONE FIXTURE DRIVES BOTH** — which is the point of this file,
/// because a test written for either one alone would pass with the other still broken (§A.2):
///
///   · `describe.swift` imports ONLY the C target. Pre-fix it publishes `CShim#Swift.type`, a key whose
///     package half no producer's hash can equal — **MISATTRIBUTION**, the `DepLib#String.lowercased`
///     class, dead on the wire in both directions.
///   · `useBackend.swift` imports the C target BESIDE the genuine dependency. Pre-fix `cands.count == 2`,
///     the never-guess rule fires, and the real owner's key is dropped outright — **SUPPRESSION**. So
///     the fix makes keys APPEAR as well as disappear.
///
/// CALIBRATION — the arms differ in nothing but the engine, and each assertion below was watched to fail
/// on the pre-fix binary:
///
///     PRE   describe   -> ["CShim#Swift.type"]        useBackend -> (no key)
///     POST  describe   -> (no key)                    useBackend -> ["RatesPkg#Backend.size"]
///
/// `RatesPkg` — the dependency's `Package(name:)`, not its module name `Rates` — is what makes the
/// surviving key JOINABLE (R565); asserting on the module name would pass over a key no consumer can ask.
final class OwnPackageCTargetOwnerProcessTests: XCTestCase {

    /// Builds the two-package tree and returns `fn -> dispatchesOn` for the consumer's report.
    private func runFixture() throws -> [String: [String]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r592-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "RatesPkg",
            products: [.library(name: "Rates", targets: ["Rates"])],
            targets: [.target(name: "Rates")])
        """)
        try write("dep/Sources/Rates/lib.swift", "public protocol Backend { func size() -> Int }\n")
        // A REAL C TARGET: declared in the manifest, with a source root that holds no `.swift` file, so
        // `analyzedTargets` can never contain it however much of this package the run reads.
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "CShim"),
                      .target(name: "App", dependencies: [
                          "CShim", .product(name: "Rates", package: "dep")])])
        """)
        try write("app/Sources/CShim/shim.c", "int shim_noop(void) { return 0; }\n")
        try write("app/Sources/CShim/include/shim.h", "int shim_noop(void);\n")
        try write("app/Sources/App/useBackend.swift", """
        import CShim
        import Rates
        public func useBackend(_ b: Backend) -> Int { return b.size() }
        """)
        try write("app/Sources/App/describe.swift", """
        import CShim
        public func describe(_ x: Int) -> String { return "\\(Swift.type(of: x))" }
        """)

        let out = root.appendingPathComponent("r")
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", out.path])
        XCTAssertEqual(r.code, 0, "the consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.App.Swift.json"))) as? [String: Any]
        let fns = (d?["functions"] as? [[String: Any]]) ?? []
        // §E3 — prove the two functions this test is about REACHED the engine at all. Without this every
        // assertion below is satisfied by an empty report, which is also what a broken scan produces.
        XCTAssertEqual(((d?["analyzed"] as? [String: Any])?["count"] as? Int) ?? 0, 2,
                       "both fixture functions must be analyzed, or the absences asserted below are "
                       + "assertions about nothing")
        var byFn: [String: [String]] = [:]
        for f in fns {
            guard let n = f["fn"] as? String else { continue }
            byFn[n] = (f["dispatchesOn"] as? [String]) ?? []
        }
        return byFn
    }

    func testAnOwnPackageCTargetIsNeverTheOwnerOfAForeignAbstraction() throws {
        let byFn = try runFixture()

        // DIRECTION (a) — MISATTRIBUTION. Pre-fix: ["CShim#Swift.type"].
        XCTAssertEqual(byFn["describe"] ?? [], [],
                       "a file whose only non-platform import is its OWN package's C target has no "
                       + "decidable foreign owner; publishing `CShim#…` names a package that does not "
                       + "exist, which looks like an answer and can never be joined")

        // DIRECTION (b) — SUPPRESSION. Pre-fix: [] (two candidates, never-guess fires).
        XCTAssertEqual(byFn["useBackend"] ?? [], ["RatesPkg#Backend.size"],
                       "the C target sitting beside the genuine dependency import made `cands.count == 2` "
                       + "and dropped the real owner's key; excluding own-package targets hands it back — "
                       + "keyed on the dependency's PACKAGE name (R565), which is what a consumer asks on")
    }
}
