import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R593 — **ONE MODULE IMPORTED TWICE WAS COUNTED AS TWO CANDIDATES.**
///
/// `Driver.foreignOwnerModule` gates on `cands.count == 1` — the never-guess rule — over a filter of
/// `fileImports[file]`, which is a `[String: [String]]`: **a LIST, not a set.** So the rule fired on an
/// ambiguity that does not exist, and the cross-platform `#if` idiom produces exactly that shape as a
/// matter of course. swift-nio's `NIOFileSystem/FileInfo.swift` imports `CNIOLinux` under both
/// `canImport(Glibc)` and `canImport(Musl)`; measured over 11 real packages, **5 files reach this function
/// with a duplicated import and 4 of them have only ONE distinct candidate after dedup.**
///
/// **THE ORDER MATTERS AND IS THE REASON THIS IS A SEPARATE ROW FROM R592.** On that corpus every
/// duplicated import IS a C target of the scanning package, so deduping BEFORE excluding own-package
/// targets would have turned 4 refusals into 4 MISATTRIBUTED keys (`CNIOLinux#…`) rather than into
/// nothing. With R592 landed first the probe reports 84 hits and `now=NONE` on every one, and the A/B is
/// **ADDED 0 REMOVED 0 CHANGED 0** — reached and inert, which is a different claim from unreached.
///
/// This fixture is therefore the only evidence that the dedup does anything at all, and it is built on
/// the shape the corpus lacks: a duplicated import of a GENUINE dependency module.
///
/// CALIBRATION, by reverting the `Set(...)`:
///
///     pre   useBackend -> (no key)                 two list entries, never-guess fires
///     post  useBackend -> ["RatesPkg#Backend.size"]
final class DuplicatedImportOwnerVoteProcessTests: XCTestCase {

    func testAnImportRepeatedAcrossConditionalArmsIsOneCandidate() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r593-\(UUID().uuidString)")
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
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [.product(name: "Rates", package: "dep")])])
        """)
        // THE SHAPE: one module, two `import` lines, mutually exclusive arms. This compiles and runs on
        // every platform — exactly one arm is live — which is why the duplicate is idiomatic rather than
        // a mistake, and why refusing on it costs a real disclosure.
        try write("app/Sources/App/dup.swift", """
        #if canImport(Darwin)
        import Rates
        #elseif canImport(Glibc)
        import Rates
        #endif
        public func useBackend(_ b: Backend) -> Int { return b.size() }
        """)

        let out = root.appendingPathComponent("r")
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", out.path])
        XCTAssertEqual(r.code, 0, "the consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.App.Swift.json"))) as? [String: Any]
        // §E3 — the function must have been analyzed, or the assertion below is about nothing.
        XCTAssertEqual(((d?["analyzed"] as? [String: Any])?["count"] as? Int) ?? 0, 1,
                       "the conditional-import file must be analyzed — stderr: \(r.err)")
        let fns = (d?["functions"] as? [[String: Any]]) ?? []
        let disp = fns.first { ($0["fn"] as? String) == "useBackend" }?["dispatchesOn"] as? [String]

        XCTAssertEqual(disp ?? [], ["RatesPkg#Backend.size"],
                       "`import Rates` written twice under mutually exclusive `#if` arms is ONE candidate; "
                       + "counting the list entries made the never-guess rule refuse an owner that was "
                       + "never ambiguous, and the key — the one a consumer joins on — was dropped")
    }
}
