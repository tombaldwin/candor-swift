import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R1872 (chained half), R1868 shape (d), R1874 — **A CONSUMER'S `extension <DependencyType>` MADE THE TYPE LOOK
/// LOCAL, AND `super.<member>` INTO A DEPENDENCY CLASS RESOLVED TO NOTHING.**
///
/// `pushType` puts everything an `extension` extends into `localTypes`; only a real definition enters `declaredTypes`. Two
/// routes asked `localTypes` the question *"is this type ours?"* and so answered "yes" for a dependency type the consumer
/// merely extends (the R651/R656 shape one door over):
///   - `dispatchAbstraction` refused a generic bound found in `localTypes`, so `func f<C: HTTPClient>(_ c: C) { c.tally() }` published
///     no key and the chained join read the call as pure;
///   - the concrete-receiver arm's `extSupers` dropped an extended supertype, so `Sub().tally()` (a consumer subclass of the
///     dependency class) lost the hedge the same source carries without the extension.
/// And `super.<m>` into a superclass that no scanned unit and no chained report answers resolved to nothing (R1874).
///
/// Every fixture has a PURE twin with its own name, a CONTROL that must not move (a LOCALLY DECLARED base shadows), and every
/// assertion is shown able to fail by running the same suite against the pre-fix binary.
final class ShadowDisciplineAndSuperProcessTests: XCTestCase {

    private static let dep = """
    import Foundation
    open class HTTPClient {
        public init() {}
        open func tally(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 }
        open func quiet(_ p: String) -> Int { p.count }
    }
    """

    /// `ext` adds `extension HTTPClient { … }` (the one variable); everything else is byte-identical between arms.
    private func app(ext: Bool) -> String {
        """
        import AsyncHTTPClient
        \(ext ? "extension HTTPClient { public func zzzUnused() -> Int { 0 } }" : "")
        public func gTally<C: HTTPClient>(_ c: C, _ p: String) -> Int { c.tally(p) }
        public func gQuiet<C: HTTPClient>(_ c: C, _ p: String) -> Int { c.quiet(p) }
        public final class SubOne: HTTPClient {}
        public func subTally(_ p: String) -> Int { SubOne().tally(p) }
        public func subQuiet(_ p: String) -> Int { SubOne().quiet(p) }
        public final class Over: HTTPClient {
            public override func tally(_ p: String) -> Int { super.tally(p) }
            public override func quiet(_ p: String) -> Int { super.quiet(p) }
        }
        """
    }

    private func scan(app appText: String, chained: Bool, label: String) throws -> [String: (inf: Set<String>, why: Set<String>)] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-r1872-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ rel: String, _ text: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        try write("dep/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "AsyncHTTPClient",
            products: [.library(name: "AsyncHTTPClient", targets: ["AsyncHTTPClient"])],
            targets: [.target(name: "AsyncHTTPClient")])
        """)
        try write("dep/Sources/AsyncHTTPClient/lib.swift", Self.dep)
        try write("app/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", products: [.library(name: "App", targets: ["App"])],
            dependencies: [.package(path: "../dep")],
            targets: [.target(name: "App", dependencies: [.product(name: "AsyncHTTPClient", package: "dep")])])
        """)
        try write("app/Sources/App/cells.swift", appText)
        var env: [String: String] = [:]
        if chained {
            let depDir = root.appendingPathComponent("depR")
            try FileManager.default.createDirectory(at: depDir, withIntermediateDirectories: true)
            let rd = try ProcessHarness.run(bin, [root.appendingPathComponent("dep").path, "--out", depDir.appendingPathComponent("r").path])
            XCTAssertEqual(rd.code, 0, "dependency scan must succeed — stderr: \(rd.err)")
            let report = depDir.appendingPathComponent("r.AsyncHTTPClient.Swift.json")
            for extra in try FileManager.default.contentsOfDirectory(atPath: depDir.path) where extra != report.lastPathComponent {
                try FileManager.default.removeItem(at: depDir.appendingPathComponent(extra))
            }
            env["CANDOR_DEPS"] = depDir.path
        }
        let r = try ProcessHarness.run(bin, [root.appendingPathComponent("app").path, "--out", root.appendingPathComponent("o").path], env: env)
        XCTAssertEqual(r.code, 0, "consumer scan must succeed — stderr: \(r.err)")
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("o.App.Swift.json"))) as? [String: Any]
        var rows: [String: (inf: Set<String>, why: Set<String>)] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] {
            rows[(f["fn"] as? String) ?? "?"] = (Set((f["inferred"] as? [String]) ?? []), Set((f["unknownWhy"] as? [String]) ?? []))
        }
        return rows
    }

    // MARK: R1872 chained half — a generic bound the consumer extends

    func testGenericBoundOnExtendedDependencyTypeJoinsChained() throws {
        for ext in [false, true] {
            let rows = try scan(app: app(ext: ext), chained: true, label: "gen\(ext)")
            XCTAssertEqual(rows["gTally"]?.inf, ["Fs"], "ext=\(ext): the chained row of HTTPClient.work must reach the bounded call")
            // the pure twin is not charged Fs (a fabrication); it may carry the walk's hedge or be absent, as before.
            XCTAssertFalse(rows["gQuiet"]?.inf.contains("Fs") ?? false, "ext=\(ext): pure twin gQuiet must not read Fs")
        }
    }

    func testGenericBoundControlLocallyDeclaredBaseShadows() throws {
        // CONTROL: the consumer DECLARES its own `HTTPClient` (pure `work`): the dependency's row must not be reached.
        let text = """
        import AsyncHTTPClient
        public class HTTPClient { public init() {}; public func tally(_ p: String) -> Int { p.count } }
        public func gLocalWork<C: HTTPClient>(_ c: C, _ p: String) -> Int { c.tally(p) }
        """
        let rows = try scan(app: text, chained: true, label: "genlocal")
        XCTAssertFalse(rows["gLocalWork"]?.inf.contains("Fs") ?? false, "a locally declared HTTPClient shadows the dependency's")
    }

    // MARK: R1868(d) — a consumer subclass of a dependency class keeps its hedge whether or not the consumer extends the root

    func testConsumerSubclassHedgeDoesNotDependOnAnExtension() throws {
        var plain: [String: (inf: Set<String>, why: Set<String>)] = [:]
        for ext in [false, true] {
            let rows = try scan(app: app(ext: ext), chained: false, label: "sub\(ext)")
            if !ext { plain = rows }
            XCTAssertTrue(rows["subTally"]?.inf.contains("Unknown") ?? false, "ext=\(ext): unchained subTally must be disclosed")
            XCTAssertEqual(rows["subTally"]?.why, plain["subTally"]?.why, "ext=\(ext): same token with and without the extension")
        }
        for ext in [false, true] {
            let rows = try scan(app: app(ext: ext), chained: true, label: "subch\(ext)")
            XCTAssertEqual(rows["subTally"]?.inf, ["Fs"], "ext=\(ext): chained subTally reads the dependency's Fs")
            XCTAssertFalse(rows["subQuiet"]?.inf.contains("Fs") ?? false, "ext=\(ext): pure twin subQuiet must not read Fs")
        }
    }

    func testConsumerSubclassControlLocallyDeclaredBaseIsNotHedged() throws {
        let text = """
        import AsyncHTTPClient
        public class HTTPClient { public init() {} }
        extension HTTPClient { public func zzz() {} }
        public final class SubL: HTTPClient {}
        public func subLocal(_ p: String) -> Int { SubL().missing(p) }
        """
        // `missing` does not exist anywhere; the point is that a DECLARED base is never reported as an external one
        let rows = try scan(app: text, chained: false, label: "sublocal")
        XCTAssertFalse(rows["subLocal"]?.why.contains(where: { $0.hasPrefix("dispatch:HTTPClient.") }) ?? false,
                       "a locally declared HTTPClient (even when extended) is not an external supertype")
    }

    // MARK: R1874 — super.<member> into a dependency class

    func testSuperIntoDependencyClassIsDisclosedUnchainedAndJoinsChained() throws {
        for ext in [false, true] {
            let un = try scan(app: app(ext: ext), chained: false, label: "sup\(ext)")
            XCTAssertTrue(un["Over.tally"]?.inf.contains("Unknown") ?? false, "ext=\(ext): unchained super.tally must be disclosed")
            XCTAssertEqual(un["Over.tally"]?.why, ["dispatch:HTTPClient.tally"], "ext=\(ext): the typed-receiver token")
            let ch = try scan(app: app(ext: ext), chained: true, label: "supch\(ext)")
            XCTAssertEqual(ch["Over.tally"]?.inf, ["Fs"], "ext=\(ext): chained super.tally reads the dependency's row")
            // the pure twin: a chained miss is a pure member; silence is the reading there, as for every chained join
            XCTAssertFalse(ch["Over.quiet"]?.inf.contains("Fs") ?? false, "ext=\(ext): pure twin Over.quiet must not read Fs")
        }
    }

    func testSuperControlsDeclaredBaseAndPlatformBaseAreNotDisclosed() throws {
        let text = """
        import AsyncHTTPClient
        import Foundation
        public class LBase { public init() {}; public func tally() -> Int { 1 } }
        public final class LOver: LBase { public override func tally() -> Int { super.tally() } }
        public final class Plat: NSObject { public override init() { super.init() } }
        """
        let rows = try scan(app: text, chained: false, label: "suplocal")
        XCTAssertNil(rows["LOver.tally"], "a super call answered by a local unit is pure and gets no hedge")
        XCTAssertNil(rows["Plat.init"], "super.init() into a platform class is not a disclosure (NSObject is no dependency's type)")
        // a DECLARED class that shares a κ root's NAME shadows it: the guard that a declared base is never external can FAIL here.
        let shadow = """
        import AsyncHTTPClient
        public class HTTPClient { public init() {} }
        public final class LOver2: HTTPClient { public func tallyIt() -> Int { super.tally() } }
        """
        let rows2 = try scan(app: shadow, chained: false, label: "supshadow")
        XCTAssertFalse(rows2["LOver2.tallyIt"]?.inf.contains("Unknown") ?? false, "a declared base is not an external base")
    }

    func testSuperIntoPlatformClassCarriesTheKappaVerb() throws {
        let text = """
        import Foundation
        public final class P: Process { public override func run() throws { try super.run() } }
        public final class Q: Process { public override func interrupt() { super.interrupt() } }
        """
        let rows = try scan(app: text, chained: false, label: "supproc")
        XCTAssertTrue(rows["P.run"]?.inf.contains("Exec") ?? false, "super.run() on a Process subclass is the κ verb (Exec)")
    }
}
