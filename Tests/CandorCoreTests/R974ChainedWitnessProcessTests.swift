import XCTest
import Foundation

/// SOUNDNESS R974 (a) — A USER `Equatable`/`Comparable`/`Hashable` WITNESS HANDED TO A CHAINED PACKAGE'S GENERIC.
///
/// EXECUTED (`swiftagent-r974/fx1`, `swift build` + run): every `call*` function below writes a file through
/// `Noisy.==`, `Noisy.<` or `Noisy.hash(into:)` inside GenA's generic body. On 0.40.9 each read ABSENT under
/// chaining (`deny Fs Unknown <fn>` exit 0); the dependency's row is pure because the instantiation is its
/// callers', and ⟨0.39⟩'s `dispatchesOn` has no spelling for a stdlib-owned requirement.
///
/// THE FIX IS A DISCLOSURE, NOT A CHARGE: the consumer cannot know the dependency compares, so it adds `Unknown`
/// (reason `dispatch:<P>.<w> witness passed to a chained package`) where one of the argument-carried witnesses
/// can do anything. `Calm`'s pure `==`, `Quiet`'s synthesized one, `Int`, a stdlib `print` / `Array.append`, and a
/// LOCAL generic (R951's own edge) must not move. `plainId` is the stated over-disclosure: an unconstrained
/// generic that never compares is hedged too, because nothing on the wire says it does not.
final class R974ChainedWitnessProcessTests: XCTestCase {

    private func write(_ root: URL, _ rel: String, _ text: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r974a-\(UUID().uuidString)")
        try write(root, "GenA/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "GenA", products: [.library(name: "GenA", targets: ["GenA"])], targets: [.target(name: "GenA")])
        """)
        try write(root, "GenA/Sources/GenA/GenA.swift", """
        public func sameEq<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
        public func lessCmp<T: Comparable>(_ a: T, _ b: T) -> Bool { a < b }
        public func hashOf<T: Hashable>(_ a: T) -> Int { var h = Hasher(); a.hash(into: &h); return h.finalize() }
        public func setCount<T: Hashable>(_ xs: [T]) -> Int { Set(xs).count }
        public func arrSame<T: Equatable>(_ a: [T], _ b: [T]) -> Bool { a == b }
        public func labelled<T: Equatable>(lhs: T, rhs: T) -> Bool { lhs == rhs }
        public func plainId<T>(_ a: T) -> T { a }
        public struct GBox<T: Equatable> {
            public var items: [T] = []
            public init() {}
            public mutating func add(_ x: T) { if !items.contains(x) { items.append(x) } }
        }
        """)
        try write(root, "App/Package.swift", """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", dependencies: [.package(path: "../GenA")],
          targets: [.executableTarget(name: "App", dependencies: [.product(name: "GenA", package: "GenA")])])
        """)
        try write(root, "App/Sources/App/main.swift", """
        import Foundation
        import GenA
        struct Noisy: Equatable, Comparable, Hashable {
            var v: Int
            static func == (l: Noisy, r: Noisy) -> Bool {
                FileManager.default.createFile(atPath: "/tmp/r974-eq.txt", contents: nil); return l.v == r.v
            }
            static func < (l: Noisy, r: Noisy) -> Bool {
                FileManager.default.createFile(atPath: "/tmp/r974-lt.txt", contents: nil); return l.v < r.v
            }
            func hash(into h: inout Hasher) {
                FileManager.default.createFile(atPath: "/tmp/r974-hash.txt", contents: nil); h.combine(v)
            }
        }
        struct Quiet: Equatable { var v: Int }
        struct Wrap: Equatable { var n: Noisy }
        struct Calm: Equatable { var v: Int; static func == (l: Calm, r: Calm) -> Bool { l.v == r.v } }
        func localEq<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
        func callEqX() -> Bool { sameEq(Noisy(v: 1), Noisy(v: 1)) }
        func callLtX() -> Bool { lessCmp(Noisy(v: 1), Noisy(v: 2)) }
        func callHashX() -> Int { hashOf(Noisy(v: 1)) }
        func callSetX() -> Int { setCount([Noisy(v: 1), Noisy(v: 2)]) }
        func callArrX() -> Bool { arrSame([Noisy(v: 1)], [Noisy(v: 1)]) }
        func callWrapX() -> Bool { sameEq(Wrap(n: Noisy(v: 1)), Wrap(n: Noisy(v: 1))) }
        func callLabX() -> Bool { labelled(lhs: Noisy(v: 1), rhs: Noisy(v: 1)) }
        func callBoxX() -> Int { var b = GBox<Noisy>(); b.add(Noisy(v: 1)); return b.items.count }
        func callVarX() -> Bool { let a = Noisy(v: 1); let b = Noisy(v: 1); return sameEq(a, b) }
        func ctrlCalmX() -> Bool { sameEq(Calm(v: 1), Calm(v: 1)) }
        func ctrlQuietX() -> Bool { sameEq(Quiet(v: 1), Quiet(v: 1)) }
        func ctrlIntX() -> Bool { sameEq(1, 1) }
        func ctrlPrintX() { print(Noisy(v: 1)) }
        func ctrlAppendX() -> Int { var xs: [Noisy] = []; xs.append(Noisy(v: 1)); return xs.count }
        func ctrlLocalX() -> Bool { localEq(Noisy(v: 1), Noisy(v: 1)) }
        func overPlainX() -> Noisy { plainId(Noisy(v: 1)) }
        """)
        return root
    }

    private func bin() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    private func depReport(_ root: URL) throws -> String {
        let r = try ProcessHarness.run(try bin(), [root.appendingPathComponent("GenA").path, "--out",
                                                   root.appendingPathComponent("r/GenA").path])
        XCTAssertEqual(r.code, 0, r.err)
        return root.appendingPathComponent("r/GenA.GenA.Swift.json").path
    }

    private func rows(_ root: URL, deps: String?, off: Bool = false) throws -> [String: [String: Any]] {
        var env: [String: String] = [:]
        if let deps { env["CANDOR_DEPS"] = deps }
        if off { env["CANDOR_R974A_OFF"] = "1" }
        let r = try ProcessHarness.run(try bin(), [root.appendingPathComponent("App").path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertGreaterThan(((d["analyzed"] as? [String: Any])?["count"] as? Int) ?? 0, 0, r.err)
        var out: [String: [String: Any]] = [:]
        for case let f as [String: Any] in (d["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { out[n] = f }
        }
        return out
    }
    private func field(_ rows: [String: [String: Any]], _ fn: String, _ k: String) -> Set<String> {
        Set((rows[fn]?[k] as? [String]) ?? [])
    }

    private func gate(_ root: URL, _ policy: String, deps: String, off: Bool = false) throws -> Int32 {
        let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        var env = ["CANDOR_DEPS": deps]
        if off { env["CANDOR_R974A_OFF"] = "1" }
        return try ProcessHarness.run(try bin(), [root.appendingPathComponent("App").path, "--policy", pf.path, "--json"],
                                      env: env).code
    }

    static let disclosed = ["callEqX", "callLtX", "callHashX", "callSetX", "callArrX", "callWrapX", "callLabX",
                            "callBoxX", "callVarX"]
    static let controls = ["ctrlCalmX", "ctrlQuietX", "ctrlIntX", "ctrlPrintX", "ctrlAppendX", "ctrlLocalX"]

    func testAWitnessHandedToAChainedGenericIsDisclosed() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let deps = try depReport(root)
        let on = try rows(root, deps: deps), off = try rows(root, deps: deps, off: true)
        for fn in Self.disclosed {
            // The release's row: ABSENT, or (`callBoxX`) present only for its ⟨0.39⟩ `dispatchesOn` key — `[]` either way.
            XCTAssertTrue(field(off, fn, "inferred").isEmpty && field(off, fn, "invisible").isEmpty,
                          "CANDOR_R974A_OFF=1 must reproduce the release's silent row for \(fn): \(String(describing: off[fn]))")
            XCTAssertEqual(field(on, fn, "inferred"), ["Unknown"], "\(fn): \(String(describing: on[fn]))")
            XCTAssertTrue(field(on, fn, "unknownWhy").contains { $0.hasSuffix(" witness passed to a chained package") },
                          "\(fn) names why: \(String(describing: on[fn]))")
        }
        XCTAssertTrue(field(on, "callLtX", "unknownWhy").contains("dispatch:Comparable.< witness passed to a chained package"))
        XCTAssertTrue(field(on, "callHashX", "unknownWhy").contains("dispatch:Hashable.hash witness passed to a chained package"))
        // The stated over-disclosure: nothing on the wire says `plainId` does not compare.
        XCTAssertEqual(field(on, "overPlainX", "inferred"), ["Unknown"])
    }

    func testControlsDoNotMove() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let deps = try depReport(root)
        let on = try rows(root, deps: deps), off = try rows(root, deps: deps, off: true)
        for fn in Self.controls {
            XCTAssertEqual(on[fn] as NSDictionary?, off[fn] as NSDictionary?, "\(fn) must be byte-identical to the kill-switch row")
            XCTAssertFalse(field(on, fn, "unknownWhy").contains { $0.contains("witness passed to a chained package") }, fn)
        }
        XCTAssertNil(on["ctrlCalmX"], "a PURE hand-written `==` costs nothing")
        XCTAssertEqual(field(on, "ctrlLocalX", "inferred"), ["Fs"], "a local generic is R951's charge, not a hedge")
    }

    func testTheGateFlipsOnlyWhereUnknownIsDenied() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let deps = try depReport(root)
        for fn in ["callEqX", "callArrX", "callBoxX", "callWrapX"] {
            XCTAssertEqual(try gate(root, "deny Fs Unknown \(fn)", deps: deps), 1, fn)
            XCTAssertEqual(try gate(root, "deny Fs Unknown \(fn)", deps: deps, off: true), 0, "\(fn) under the kill switch")
            XCTAssertEqual(try gate(root, "deny Fs \(fn)", deps: deps), 0, "a disclosure, not a charge: \(fn)")
        }
        XCTAssertEqual(try gate(root, "deny Fs Unknown ctrlCalmX", deps: deps), 0)
    }
}
