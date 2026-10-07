import XCTest
import Foundation

/// SOUNDNESS R910 — THE CONSUMER CHAINS A CONFORMER'S PACKAGE BUT NOT THE PROTOCOL OWNER'S.
///
/// `joinTiers` asks `<p>#<owner>.<member>` only of packages that are chained AND imported. A protocol
/// requirement's answer is the `interfaceUnion` entry the CONFORMER's report publishes under the OWNER's
/// prefix, so with the owner unchained that entry sat in the index unasked and the row read pure.
///
/// EXECUTED (`swiftagent-r910/fx910`, `swift run`): every `via*` call wrote `/tmp/sv_910_put`, `viaGo910`
/// set its env value, `viaProp910` listed `/tmp`. On the pending stack, chained on IQ alone,
/// `oneImport910` and `viaGo910` read `[]` and `viaProp910` was ABSENT — `deny Fs` / `deny Env` exit 0.
///
/// THE FIX IS ADDITIVE, and these tests pin that as a property rather than per row: with the owner
/// unchained every row is a SUPERSET of the kill-switch row; with the owner chained the two are
/// byte-identical (the §2 join already asked the same string). The PART 92 shapes it must not move
/// (c5/c10 unchained, c9 zero implementors, c12 pure-only) are reproduced as rows of the same tree.
final class R910OwnerKeyJoinProcessTests: XCTestCase {

    private func write(_ root: URL, _ rel: String, _ text: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r910-\(UUID().uuidString)")
        func lib(_ n: String, _ deps: [String]) throws {
            let pd = deps.map { ".package(path: \"../\($0)\")" }.joined(separator: ", ")
            let td = deps.map { ".product(name: \"\($0)\", package: \"\($0)\")" }.joined(separator: ", ")
            try write(root, "\(n)/Package.swift", """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "\(n)", products: [.library(name: "\(n)", targets: ["\(n)"])],
                dependencies: [\(pd)], targets: [.target(name: "\(n)", dependencies: [\(td)])])
            """)
        }
        try lib("PQ", [])
        try write(root, "PQ/Sources/PQ/p.swift", """
        public protocol Store910 { func put(); var level: Int { get } }
        public protocol PureP910 { func ping() }
        public protocol Gen910 { func go() }
        public protocol Zero910 { func nothing() }
        public struct Conc910 { public init() {}; public func work() {} }
        """)
        try lib("IQ", ["PQ"])
        try write(root, "IQ/Sources/IQ/i.swift", """
        import Foundation
        import PQ
        public struct FsStore910: Store910 {
            public init() {}
            public func put() { _ = FileManager.default.createFile(atPath: "/tmp/sv_910_put", contents: nil) }
            public var level: Int { (try? FileManager.default.contentsOfDirectory(atPath: "/tmp"))?.count ?? 0 }
        }
        public struct PureImpl910: PureP910 { public init() {}; public func ping() {} }
        public struct GenImpl910: Gen910 { public init() {}; public func go() { setenv("SV910_GO", "yes", 1) } }
        public func carrier910() { _ = FileManager.default.createFile(atPath: "/tmp/sv_910_carrier", contents: nil) }
        """)
        // A platform conformance in a one-import file: the release's floor keys it `PQ#CustomStringConvertible…`.
        try write(root, "IQ/Sources/IQ/cs.swift", """
        import Foundation
        import PQ
        public struct Loud910: CustomStringConvertible { public init() {}; public var description: String { _ = FileManager.default.createFile(atPath: "/tmp/sv_910_desc", contents: nil); return "" } }
        """)
        try write(root, "AQ/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "AQ", dependencies: [.package(path: "../PQ"), .package(path: "../IQ")],
          targets: [.executableTarget(name: "AQ", dependencies: [.product(name: "PQ", package: "PQ"), .product(name: "IQ", package: "IQ")])])
        """)
        try write(root, "AQ/Sources/AQ/one.swift", """
        import PQ
        func oneImport910(_ s: Store910) { s.put() }
        func descOne910(_ x: CustomStringConvertible) -> String { x.description }
        func zeroOne910(_ z: Zero910) { z.nothing() }
        """)
        try write(root, "AQ/Sources/AQ/main.swift", """
        import Foundation
        import PQ
        import IQ
        func viaParam910(_ s: Store910) { s.put() }
        func viaLet910() { let s: Store910 = FsStore910(); s.put() }
        func viaProp910(_ s: Store910) -> Int { s.level }
        func viaGo910(_ g: Gen910) { g.go() }
        func caller910() { viaParam910(FsStore910()) }
        func zero910(_ z: Zero910) { z.nothing() }
        func pureOnly910(_ p: PureP910) { carrier910(); p.ping() }
        func conc910(_ c: Conc910) { c.work() }
        func direct910() { FsStore910().put() }
        """)
        return root
    }

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    private func depReports(_ root: URL, _ deps: [String]) throws -> String {
        var out: [String] = []
        for d in deps {
            let r = try ProcessHarness.run(try bin(), [root.appendingPathComponent(d).path, "--out",
                                                       root.appendingPathComponent("r/\(d)").path])
            XCTAssertEqual(r.code, 0, r.err)
            out.append(root.appendingPathComponent("r/\(d).\(d).Swift.json").path)
        }
        return out.joined(separator: ":")
    }

    private func rows(_ root: URL, deps: String?, off: Bool = false) throws -> [String: [String: Any]] {
        var env: [String: String] = [:]
        if let deps { env["CANDOR_DEPS"] = deps }
        if off { env["CANDOR_R910_OFF"] = "1" }
        let r = try ProcessHarness.run(try bin(), [root.appendingPathComponent("AQ").path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        // §E3 — an absence assertion over a report that judged nothing is an assertion about nothing.
        XCTAssertGreaterThan(((d["analyzed"] as? [String: Any])?["count"] as? Int) ?? 0, 0, r.err)
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { out[n] = f }
        }
        return out
    }
    private func inferred(_ rows: [String: [String: Any]], _ fn: String) -> Set<String>? {
        rows[fn].map { Set(($0["inferred"] as? [String]) ?? []) }
    }

    private func gate(_ root: URL, _ policy: String, deps: String, off: Bool = false) throws -> Int32 {
        let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        var env = ["CANDOR_DEPS": deps]
        if off { env["CANDOR_R910_OFF"] = "1" }
        return try ProcessHarness.run(try bin(), [root.appendingPathComponent("AQ").path, "--policy", pf.path, "--json"],
                                      env: env).code
    }

    func testTheOwnerKeyIsAskedWhenOnlyTheConformerIsChained() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let deps = try depReports(root, ["IQ"])
        let on = try rows(root, deps: deps), off = try rows(root, deps: deps, off: true)
        // The defect, as the kill switch reproduces it.
        XCTAssertEqual(inferred(off, "oneImport910"), [], "CANDOR_R910_OFF=1 must reproduce the silent row")
        XCTAssertEqual(inferred(off, "viaGo910"), [])
        XCTAssertNil(off["viaProp910"], "the property read was ABSENT")
        // The resolution: the conformer's union entry, under the owner's key.
        XCTAssertTrue(inferred(on, "oneImport910")?.contains("Fs") == true, "a one-import file: \(String(describing: on["oneImport910"]))")
        XCTAssertTrue(inferred(on, "viaParam910")?.contains("Fs") == true)
        XCTAssertTrue(inferred(on, "viaLet910")?.contains("Fs") == true)
        XCTAssertTrue(inferred(on, "caller910")?.contains("Fs") == true, "the caller inherits it through the local edge")
        XCTAssertEqual(inferred(on, "viaGo910"), ["Env"])
        XCTAssertEqual(inferred(on, "viaProp910"), ["Fs"], "the property-read sibling route asks the owner key too")
        // The gate, on code that really performs the effect — and on the CALLER, one hop out.
        for pol in ["deny Fs oneImport910", "deny Env viaGo910", "deny Fs viaProp910", "deny Fs caller910"] {
            XCTAssertEqual(try gate(root, pol, deps: deps), 1, "`\(pol)` must fail")
            XCTAssertNotEqual(try gate(root, pol, deps: deps, off: true), 1, "`\(pol)` passed before R910 (§1b)")
        }
    }

    /// ADDITIVE: every row with the owner unchained is a superset of its kill-switch row, field by field
    /// for `inferred`, and no row disappears.
    func testThePartialChainOnlyAdds() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let deps = try depReports(root, ["IQ"])
        let on = try rows(root, deps: deps), off = try rows(root, deps: deps, off: true)
        for (fn, r) in off {
            let a = Set((r["inferred"] as? [String]) ?? [])
            XCTAssertTrue(a.isSubset(of: inferred(on, fn) ?? []), "\(fn) lost an effect: \(a) -> \(String(describing: on[fn]))")
            XCTAssertEqual(r["unknownWhy"] as? [String], on[fn]?["unknownWhy"] as? [String], "\(fn): no disclosure moves")
            XCTAssertEqual(r["invisible"] as? [String], on[fn]?["invisible"] as? [String], "\(fn): the κ hedge stays")
        }
    }

    /// With the owner chained the §2 join already asked the identical string: nothing moves.
    func testTheFullChainIsUnchanged() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let deps = try depReports(root, ["IQ", "PQ"])
        let on = try rows(root, deps: deps), off = try rows(root, deps: deps, off: true)
        XCTAssertEqual(Set(on.keys), Set(off.keys))
        for (fn, r) in off {
            XCTAssertEqual(NSDictionary(dictionary: r), NSDictionary(dictionary: on[fn] ?? [:]), "\(fn) moved under a full chain")
        }
        XCTAssertTrue(inferred(on, "viaParam910")?.contains("Fs") == true, "the full chain resolves it, as before")
    }

    /// The PART 92 shapes and the guards this must not regress, as rows of the same tree.
    func testTheShapesThatMustNotMove() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let deps = try depReports(root, ["IQ"])
        let on = try rows(root, deps: deps), off = try rows(root, deps: deps, off: true)
        // c9 — zero implementors anywhere: no union entry exists, so nothing is joined.
        for fn in ["zero910", "zeroOne910"] {
            XCTAssertEqual(inferred(on, fn), inferred(off, fn), "\(fn): no implementor, nothing to join")
            XCTAssertFalse(inferred(on, fn)?.contains("Fs") == true)
        }
        // c12 — the only implementor is PURE: the row carries the carrier and nothing else, no `Unknown`.
        XCTAssertEqual(inferred(on, "pureOnly910"), ["Fs"], "the carrier only")
        XCTAssertEqual(inferred(on, "pureOnly910"), inferred(off, "pureOnly910"))
        // R706's guard — a resolved concrete dependency call gains no `Unknown`.
        XCTAssertEqual(inferred(on, "direct910"), ["Fs"])
        XCTAssertEqual(inferred(on, "conc910"), [], "a pure concrete member of an unchained package stays pure")
        XCTAssertEqual(inferred(on, "conc910"), inferred(off, "conc910"))
        // The release's one-import FLOOR keys a platform conformance under the file's sole dependency
        // (`PQ#CustomStringConvertible.description`); asking that key would charge every `description`
        // read in such a file. A platform name is never a dependency's owner key.
        XCTAssertEqual(inferred(on, "descOne910"), inferred(off, "descOne910"),
                       "a platform protocol's member is not asked under a dependency's prefix")
        // c5 / c10 — unchained: no index, nothing to ask; byte-identical.
        let u = try rows(root, deps: nil), uOff = try rows(root, deps: nil, off: true)
        XCTAssertEqual(Set(u.keys), Set(uOff.keys))
        for (fn, r) in uOff { XCTAssertEqual(NSDictionary(dictionary: r), NSDictionary(dictionary: u[fn] ?? [:]), fn) }
    }
}
