import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R559 — THE PACKAGE'S OWN NAME, AND WHAT IT COSTS TO READ IT WITH A REGEX.
///
/// `manifestPackageName` took the FIRST `name: "…"` anywhere in `Package.swift`. Its own doc said that
/// was not good — *"the first `name:` in a manifest is very often a target's"* — and `PackageTargets.swift`
/// named it as the fragile counter-example a structured parse avoids. The limitation was documented in
/// two places and measured in none, which is why it kept costing: a comment that reads as CONSIDERED is a
/// comment nobody measures.
///
/// MEASURED over 11 real packages: **two are wrong.** swift-nio reports itself as `Atomics` — from its
/// line-18 `.product(name: "Atomics", package: "swift-atomics")`, seventeen lines above `Package(` — and
/// swift-collections as `_CollectionsTestSupport`, from a hoisted `let targets:` array. Both idioms are
/// ordinary, and both make a report claim a name that belongs to somebody else.
///
/// IT IS NOT COSMETIC, WHICH IS WHAT THE PROCESS ARM BELOW IS FOR. The package name is SPEC §2 rule 3's
/// COVERAGE key, and a covered package's silence is a PURITY CLAIM. Chaining a report that misnames
/// itself therefore WITHDRAWS the consumer's disclosure for a package that report does not cover — the
/// same "chaining must not DELETE the disclosure" property R475 is about, reached through the identity
/// field instead of the join.
final class PackageIdentityProcessTests: XCTestCase {

    // MARK: - the parse, unit-level (no filesystem, no spawn)

    /// swift-nio's shape, reduced: a hoisted `.product(name:)` seventeen lines above the `Package(` call.
    private let hoistedProduct = """
    // swift-tools-version:5.9
    import PackageDescription
    let swiftAtomics: PackageDescription.Target.Dependency = .product(name: "Atomics", package: "swift-atomics")
    let package = Package(
        name: "swift-nio",
        products: [.library(name: "NIOCore", targets: ["NIOCore"])],
        dependencies: [.package(url: "https://github.com/apple/swift-atomics", from: "1.0.0")],
        targets: [.target(name: "NIOCore", dependencies: [swiftAtomics])])
    """

    /// swift-collections' shape, reduced: a hoisted `let targets:` array above the `Package(` call.
    private let hoistedTargets = """
    // swift-tools-version:5.9
    import PackageDescription
    let targets: [Target] = [
        .target(name: "_CollectionsTestSupport"),
        .target(name: "DequeModule"),
    ]
    let package = Package(name: "swift-collections", targets: targets)
    """

    /// The ORDINARY shape — the 9 of 11 real packages the old regex already answered correctly. Without
    /// this arm a fix that broke every manifest would still satisfy the two above.
    private let plain = """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "Alamofire", products: [.library(name: "Alamofire", targets: ["Alamofire"])])
    """

    func testThePackageNameComesFromThePackageCallAndNotFromWhateverIsSpeltFirst() {
        XCTAssertEqual(parsePackageName(manifestSource: hoistedProduct), "swift-nio",
                       "a `.product(name:)` hoisted above `Package(` is a DEPENDENCY's product name — "
                       + "publishing it as this package's identity keys every hash, every §2 coverage "
                       + "claim and the report filename under somebody else's name")
        XCTAssertEqual(parsePackageName(manifestSource: hoistedTargets), "swift-collections",
                       "a hoisted `let targets:` array names TARGETS, not the package")
        XCTAssertEqual(parsePackageName(manifestSource: plain), "Alamofire",
                       "CONTROL: the ordinary manifest shape must still answer exactly as before")
    }

    func testTheQualifiedPackageSpellingIsAlsoRead() {
        let qualified = """
        import PackageDescription
        let p = PackageDescription.Package(name: "Q", targets: [.target(name: "T")])
        """
        XCTAssertEqual(parsePackageName(manifestSource: qualified), "Q")
    }

    func testANameThatIsNotAPlainLiteralIsRefusedRatherThanGuessed() {
        let computed = """
        import PackageDescription
        let base = "App"
        let package = Package(name: "\\(base)Kit", targets: [.target(name: "AppKitish")])
        """
        XCTAssertNil(parsePackageName(manifestSource: computed),
                     "an interpolated name cannot be read; answering `AppKitish` — the first literal "
                     + "`name:` anywhere after it — is exactly the failure this closes. The caller "
                     + "falls back to the DIRECTORY name, which is uninformative rather than wrong.")
        XCTAssertNil(parsePackageName(manifestSource: "import PackageDescription\nlet x = 1\n"),
                     "no `Package(` call at all is no answer")
    }

    // MARK: - what it costs: a chained report that misnames itself deletes the consumer's disclosure

    /// THE PROPERTY, END TO END. `dep`'s manifest carries swift-nio's exact shape — a hoisted
    /// `.product(name: "Ghost", package: "ghost")` above `Package(name: "Dep")`. The consumer imports
    /// BOTH `Ghost` and `Dep` and chains ONLY `dep`'s report.
    ///
    /// The cross is what makes this readable: `Dep` IS chained and `Ghost` is NOT, so the correct answer
    /// names `Ghost` as uncovered and drops `Dep`… and the observed pre-fix answer was the exact
    /// opposite pairing — `Ghost` withdrawn, `Dep` kept — because the chained report had registered
    /// itself under the name of a package it does not cover. Asserting both halves means the test cannot
    /// pass by everything going silent.
    func testAChainedReportThatMisnamesItselfDoesNotWithdrawAnotherPackagesDisclosure() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r559-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("ghost/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "ghost", products: [.library(name: "Ghost", targets: ["Ghost"])],
            targets: [.target(name: "Ghost")])
        """)
        try write("ghost/Sources/Ghost/g.swift", "public func ghostDo() -> Int { return 1 }\n")
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let ghostDep: PackageDescription.Target.Dependency = .product(name: "Ghost", package: "ghost")
        let package = Package(
            name: "Dep",
            products: [.library(name: "Dep", targets: ["Dep"])],
            dependencies: [.package(path: "../ghost")],
            targets: [.target(name: "Dep", dependencies: [ghostDep])])
        """)
        try write("dep/Sources/Dep/d.swift", "public func depDo() -> Int { return 2 }\n")
        try write("cons/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Cons", products: [.library(name: "Cons", targets: ["Cons"])],
            dependencies: [.package(path: "../ghost"), .package(path: "../dep")],
            targets: [.target(name: "Cons", dependencies: [
                .product(name: "Ghost", package: "ghost"), .product(name: "Dep", package: "dep")])])
        """)
        try write("cons/Sources/Cons/c.swift", """
        import Ghost
        import Dep
        public func use() -> Int { return ghostDo() + depDo() }
        """)

        let depOut = root.appendingPathComponent("depR")
        let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path, "--out", depOut.path])
        XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
        // THE REPORT IS FOUND, NEVER NAMED, and that is load-bearing rather than tidiness: hard-coding
        // `depR.Dep.Swift.json` makes the pre-fix arm fail by CHAINING NOTHING (an absent `CANDOR_DEPS`
        // file refuses, exit 2), so the coverage assertions below would never execute in the arm they
        // exist to catch — a calibration that reds for the wrong reason has not tested the property.
        let written = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("depR.") && $0.hasSuffix(".Swift.json") }
        XCTAssertEqual(written.count, 1, "expected exactly one dependency report; got \(written)")
        let depReport = root.appendingPathComponent(written.first ?? "depR.Dep.Swift.json")
        // The identity itself, at the two places the name reaches a consumer: the filename and the
        // `package` field.
        XCTAssertEqual(written.first, "depR.Dep.Swift.json",
                       "the report must be filed under the PACKAGE's name — filing it under the hoisted "
                       + "product name (`depR.Ghost.Swift.json`) is also where two packages collide in "
                       + "one `.candor/deps/` directory")

        func uncovered(chaining: String?) throws -> Set<String> {
            let tag = chaining == nil ? "un" : "ch"
            let out = root.appendingPathComponent(tag)
            let r = try ProcessHarness.run(bin, [root.appendingPathComponent("cons").path, "--out", out.path],
                                           env: chaining.map { ["CANDOR_DEPS": $0] } ?? [:])
            XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
            let d = try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("\(tag).Cons.Swift.json"))) as? [String: Any]
            let cov = (d?["coverage"] as? [String: Any])?["uncovered"] as? [[String: Any]] ?? []
            return Set(cov.compactMap { $0["name"] as? String })
        }

        // The reference arm, asserted non-vacuous first.
        let un = try uncovered(chaining: nil)
        XCTAssertEqual(un, ["Ghost", "Dep"], "unchained, BOTH imported packages are blind; got \(un.sorted())")

        let ch = try uncovered(chaining: depReport.path)
        XCTAssertTrue(ch.contains("Ghost"),
                      "chaining `Dep`'s report must NOT withdraw the disclosure for `Ghost`, which it "
                      + "does not cover — §2 rule 3 turns a covered package's silence into a PURITY "
                      + "CLAIM, so this deletes a disclosure over code candor has never read; "
                      + "got \(ch.sorted())")
        XCTAssertFalse(ch.contains("Dep"),
                       "…and the package it DOES cover must legitimately drop out, or the assertion "
                       + "above could pass over a chain that simply did nothing; got \(ch.sorted())")
    }
}
