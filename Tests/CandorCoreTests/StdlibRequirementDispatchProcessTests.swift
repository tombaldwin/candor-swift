import XCTest
import Foundation

/// SOUNDNESS R1473 — A REQUIREMENT OF A PLATFORM PROTOCOL CALLED THROUGH AN EXISTENTIAL RUNS A CONFORMER'S WITNESS.
///
/// `x.description` on `x: any CustomStringConvertible`, `x.hashValue` / `x.hash(into:)` on `any Hashable`,
/// `it.next()` on `any IteratorProtocol` (a local and an `inout` parameter), `s.makeIterator()` on `any Sequence`,
/// `x.encode(to:)` on `any Encodable`, `x.id` on `any Identifiable`, `x.debugDescription`, and
/// `e.errorDescription` on `any LocalizedError`. Every one was ABSENT on v0.41.3 — in ONE TREE and CHAINED — while
/// the program wrote a file through the conformer's witness (executed: each shape was built and run, the marker
/// file observed; `swiftagent-r1473/sw/groundtruth.txt`). Chained, `"\(x)"` was ABSENT too, while one tree charged
/// it. `any RandomNumberGenerator` / `any Decoder` method calls were already right (charged in one tree, `Unknown`
/// chained) and are the reference the fixed shapes now match.
///
/// Every defect arm asserts the GATE at the dispatching function — one tree `deny Fs <fn>` 0 → 1, chained
/// `deny Unknown <fn>` 0 → 1 — and the witness edge. `CANDOR_R1473_OFF=1` restores v0.41.3 (the kill-switch test
/// pins that the defect arms are ABSENT under it). The controls were written first and pass on both binaries.
final class StdlibRequirementDispatchProcessTests: XCTestCase {

    private static let FS = "_ = FileManager.default.fileExists(atPath: \"/tmp\")"
    private static let ENV = "_ = ProcessInfo.processInfo.environment[\"HOME\"]"

    /// The witnesses. `effectful: false` is the PURE-CONFORMER control: the same types, nothing in the bodies.
    private static func witnesses(effectful: Bool, access: String) -> String {
        let e = effectful ? FS + "; " : ""
        let a = access
        return """
        import Foundation
        \(a)struct FDesc: CustomStringConvertible { \(a)init() {}; \(a)var description: String { \(e)return "f" } }
        \(a)struct FDbg: CustomDebugStringConvertible { \(a)init() {}; \(a)var debugDescription: String { \(e)return "d" } }
        \(a)struct FHash: Hashable { \(a)init() {}; \(a)func hash(into h: inout Hasher) { \(e) }
          \(a)static func == (l: FHash, r: FHash) -> Bool { true } }
        \(a)struct FIt: IteratorProtocol { \(a)init() {}; \(a)mutating func next() -> Int? { \(e)return nil } }
        \(a)struct FSeq: Sequence { \(a)init() {}
          \(a)func makeIterator() -> EmptyCollection<Int>.Iterator { \(e)return EmptyCollection<Int>().makeIterator() } }
        \(a)struct FEnc: Encodable { \(a)init() {}; \(a)func encode(to e: Encoder) throws { \(e) } }
        \(a)struct FId: Identifiable { \(a)init() {}; \(a)var id: Int { \(e)return 1 } }
        \(a)struct FErr: LocalizedError { \(a)init() {}; \(a)var errorDescription: String? { \(e)return "e" } }
        """
    }

    /// The dispatching functions, plus the CONTROLS that must never move: local pure and SYNTHESIZED conformers,
    /// concrete receivers, non-conformers whose same-named members read the environment, and a member a protocol
    /// EXTENSION provides (`Sequence.map`), which an existential dispatches statically (executed: the conformer's own
    /// `map` does not run).
    private static let app = """
    import Foundation
    struct LocalDesc: CustomStringConvertible { var description: String { "l" } }
    struct LocalHash: Hashable { var v = 1; var w = 2 }
    struct LocalEnc: Codable { var v = 1 }
    struct LocalIt: IteratorProtocol { mutating func next() -> Int? { nil } }
    struct NotIt { mutating func next() -> Int? { \(ENV); return nil } }
    struct NotDesc { var description: String { \(ENV); return "" } }
    struct NotHash { func hash(into h: inout Hasher) { \(ENV) } }
    struct LoudMapSeq: Sequence { func makeIterator() -> LocalIt { LocalIt() }
      func map<T>(_ f: (Int) throws -> T) rethrows -> [T] { \(ENV); return [] } }

    func viaDesc(_ x: CustomStringConvertible) -> String { x.description }
    func viaDescAny(_ x: any CustomStringConvertible) -> String { x.description }
    func viaDbg(_ x: any CustomDebugStringConvertible) -> String { x.debugDescription }
    func viaHash(_ x: any Hashable) -> Int { x.hashValue }
    func hashInto(_ x: any Hashable) { var h = Hasher(); x.hash(into: &h) }
    func viaIt(_ seed: Int) -> Int? { var it: any IteratorProtocol = LocalIt(); return it.next() as? Int }
    func itParam(_ it: inout any IteratorProtocol) -> Int? { it.next() as? Int }
    func viaSeqMk(_ s: any Sequence) { var i = s.makeIterator(); _ = i.next() }
    func viaEnc(_ x: any Encodable, _ e: Encoder) throws { try x.encode(to: e) }
    func viaId(_ x: any Identifiable) { _ = x.id }
    func viaLocErr(_ e: any LocalizedError) -> String? { e.errorDescription }
    func descStr(_ x: CustomStringConvertible) -> String { "\\(x)" }
    func viaCast(_ y: Any) -> String { if let c = y as? CustomStringConvertible { return c.description }; return "" }
    struct Holder { let d: any CustomStringConvertible; func viaField() -> String { d.description } }

    func viaMap(_ s: any Sequence) -> Int { s.map { _ in 1 }.count }
    func cDescLocal(_ x: LocalDesc) -> String { x.description }
    func cHashLocal(_ x: LocalHash) -> Int { x.hashValue }
    func cHashIntoLocal(_ x: LocalHash) { var h = Hasher(); x.hash(into: &h) }
    func cEncLocal(_ x: LocalEnc) -> Data? { try? JSONEncoder().encode(x) }
    func useNots() { var n = NotIt(); _ = n.next(); _ = NotDesc().description; var h = Hasher(); NotHash().hash(into: &h) }
    """

    /// (dispatching fn, the witness unit it must edge in one tree, the `unknownWhy` token chained)
    private static let defects: [(fn: String, witness: String, why: String)] = [
        ("viaDesc", "FDesc.description", "dispatch:CustomStringConvertible.description"),
        ("viaDescAny", "FDesc.description", "dispatch:CustomStringConvertible.description"),
        ("viaDbg", "FDbg.debugDescription", "dispatch:CustomDebugStringConvertible.debugDescription"),
        ("viaHash", "FHash.hash", "dispatch:Hashable.hashValue"),
        ("hashInto", "FHash.hash", "dispatch:Hashable.hash"),
        ("viaIt", "FIt.next", "dispatch:IteratorProtocol.next"),
        ("itParam", "FIt.next", "dispatch:IteratorProtocol.next"),
        ("viaSeqMk", "FSeq.makeIterator", "dispatch:Sequence.makeIterator"),
        ("viaEnc", "FEnc.encode", "dispatch:Encodable.encode"),
        ("viaId", "FId.id", "dispatch:Identifiable.id"),
        ("viaLocErr", "FErr.errorDescription", "dispatch:LocalizedError.errorDescription"),
        ("viaCast", "FDesc.description", "dispatch:CustomStringConvertible.description"),
        ("Holder.viaField", "FDesc.description", "dispatch:CustomStringConvertible.description"),
    ]
    private static let controls = ["viaMap", "cDescLocal", "cHashLocal", "cHashIntoLocal", "cEncLocal"]

    // ── harness ─────────────────────────────────────────────────────────────────────────────────────────────
    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private struct Scan { let root: URL, target: URL, deps: String?; let rows: [String: [String: Any]] }

    private func rows(_ url: URL) throws -> [String: [String: Any]] {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var out: [String: [String: Any]] = [:]
        for e in (d?["functions"] as? [[String: Any]]) ?? [] { if let n = e["fn"] as? String { out[n] = e } }
        return out
    }

    /// ONE TREE: the witnesses and the app in one bare directory (no manifest), scanned once.
    private func oneTree(effectful: Bool, env: [String: String] = [:]) throws -> Scan {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1473-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("tree")
        try write(dir.appendingPathComponent("W.swift"), Self.witnesses(effectful: effectful, access: ""))
        try write(dir.appendingPathComponent("A.swift"), Self.app)
        let out = root.appendingPathComponent("rep")
        let r = try ProcessHarness.run(bin, [dir.path, "--out", out.path], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        return Scan(root: root, target: dir, deps: nil, rows: try rows(root.appendingPathComponent("rep.tree.Swift.json")))
    }

    /// CHAINED: the witnesses are a dependency package scanned first; the app imports it and is scanned against its
    /// report. The app's own conformers stay local (pure), so whatever the dispatch reaches in the dependency can
    /// only arrive as a disclosure.
    private func chained(effectful: Bool, env: [String: String] = [:]) throws -> Scan {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1473-\(UUID().uuidString)")
        let dep = root.appendingPathComponent("dep")
        try write(dep.appendingPathComponent("Package.swift"), """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "Dep", products: [.library(name: "Dep", targets: ["Dep"])],
                targets: [.target(name: "Dep")])
            """)
        try write(dep.appendingPathComponent("Sources/Dep/W.swift"), Self.witnesses(effectful: effectful, access: "public "))
        let r1 = try ProcessHarness.run(bin, [dep.path, "--out", root.appendingPathComponent("rep-dep").path], env: env)
        XCTAssertEqual(r1.code, 0, r1.err)
        let depRep = root.appendingPathComponent("rep-dep.Dep.Swift.json").path
        let app = root.appendingPathComponent("app")
        try write(app.appendingPathComponent("Package.swift"), """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "App", dependencies: [.package(path: "../dep")],
                targets: [.executableTarget(name: "App", dependencies: [.product(name: "Dep", package: "dep")])])
            """)
        try write(app.appendingPathComponent("Sources/App/A.swift"), "import Dep\n" + Self.app)
        var e = env; e["CANDOR_DEPS"] = depRep
        let r2 = try ProcessHarness.run(bin, [app.path, "--out", root.appendingPathComponent("rep-app").path], env: e)
        XCTAssertEqual(r2.code, 0, r2.err)
        return Scan(root: root, target: app, deps: depRep, rows: try rows(root.appendingPathComponent("rep-app.App.Swift.json")))
    }

    private func gate(_ s: Scan, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = s.root.appendingPathComponent("p-\(UUID().uuidString).policy")
        try (policy + "\n").write(to: pol, atomically: true, encoding: .utf8)
        var e = env
        if let d = s.deps { e["CANDOR_DEPS"] = d }
        let r = try ProcessHarness.run(bin, [s.target.path, "--out", s.root.appendingPathComponent("g-\(UUID().uuidString)").path,
                                             "--policy", pol.path], env: e)
        return r.code
    }
    private func strs(_ s: Scan, _ fn: String, _ key: String) -> Set<String> { Set((s.rows[fn]?[key] as? [String]) ?? []) }

    // ── defect arms ─────────────────────────────────────────────────────────────────────────────────────────
    func testOneTreeChargesTheConformersWitness() throws {
        let s = try oneTree(effectful: true)
        defer { try? FileManager.default.removeItem(at: s.root) }
        for d in Self.defects {
            XCTAssertTrue(strs(s, d.fn, "calls").contains(d.witness), "\(d.fn) must edge \(d.witness): \(s.rows[d.fn] ?? [:])")
            XCTAssertTrue(strs(s, d.fn, "inferred").contains("Fs"), "\(d.fn): \(s.rows[d.fn] ?? [:])")
            XCTAssertFalse(strs(s, d.fn, "inferred").contains("Unknown"), "one tree is a RESOLUTION, not a hedge: \(d.fn)")
            XCTAssertEqual(try gate(s, "deny Fs \(d.fn)"), 1, "deny Fs \(d.fn) must fire in one tree")
        }
        // the stringification spelling was already charged in one tree; it stays charged
        XCTAssertEqual(try gate(s, "deny Fs descStr"), 1)
    }

    func testChainedDisclosesTheDispatch() throws {
        let s = try chained(effectful: true)
        defer { try? FileManager.default.removeItem(at: s.root) }
        for d in Self.defects + [("descStr", "", "dispatch:CustomStringConvertible.description")] {
            XCTAssertTrue(strs(s, d.fn, "unknownWhy").contains(d.why), "\(d.fn) must disclose \(d.why): \(s.rows[d.fn] ?? [:])")
            XCTAssertEqual(try gate(s, "deny Unknown \(d.fn)"), 1, "deny Unknown \(d.fn) must fire chained")
        }
    }

    // ── controls ────────────────────────────────────────────────────────────────────────────────────────────
    func testPureConformersGainNothingInEitherArm() throws {
        for s in [try oneTree(effectful: false), try chained(effectful: false)] {
            defer { try? FileManager.default.removeItem(at: s.root) }
            // ABSENT, or a row with no effect at all: chained, `cEncLocal` carries the release's ⟨0.39⟩ obligation-1 key
            // `Dep#JSONEncoder.encode` with `inferred: []` (unchanged by this row; the kill-switch arm prints it too).
            for fn in Self.defects.map(\.fn) + ["descStr"] + Self.controls {
                XCTAssertTrue(strs(s, fn, "inferred").isEmpty, "CONTROL: every conformer is pure, so \(fn) gains nothing: \(s.rows[fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Unknown \(fn)"), 0, "deny Unknown \(fn)")
            }
        }
    }

    func testNonConformersAndExtensionMembersAreNeverEdged() throws {
        for s in [try oneTree(effectful: true), try chained(effectful: true)] {
            defer { try? FileManager.default.removeItem(at: s.root) }
            // `NotIt.next` / `NotDesc.description` / `NotHash.hash` read Env and conform to nothing; `LoudMapSeq.map`
            // reads Env and is a conformer's NON-requirement member, which the existential never reaches.
            for fn in Self.defects.map(\.fn) + ["descStr"] + Self.controls {
                XCTAssertFalse(strs(s, fn, "inferred").contains("Env"), "CONTROL: \(fn) must not reach a non-witness: \(s.rows[fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Env \(fn)"), 0, "deny Env \(fn)")
            }
            for fn in Self.controls {
                XCTAssertTrue(strs(s, fn, "inferred").isEmpty, "CONTROL \(fn): \(s.rows[fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Unknown \(fn)"), 0, "deny Unknown \(fn)")
            }
            XCTAssertTrue(strs(s, "useNots", "inferred").contains("Env"), "the non-conformers really do read Env when called")
        }
    }

    /// CONTROL — A MONOMORPHIZED RECEIVER IS THE CALLER'S, NOT AN EXISTENTIAL. A local `Collection` conformer reads Env;
    /// every site below except `exi` is instantiated with `[Int]` (executed: the conformer's body does not run there,
    /// and does through `exi`). The first cut of this fix keyed on the receiver's resolved type and CHA'd a generic
    /// struct's `base.index(after:)` and a protocol extension's `self.count` onto every collection in swift-algorithms;
    /// `stdExistentialRecvR1473` is what excludes them.
    func testMonomorphizedReceiversAreNotDispatchedOver() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1473-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("tree")
        try write(dir.appendingPathComponent("M.swift"), """
            import Foundation
            struct LoudCol: Collection {
              var startIndex: Int { 0 }; var endIndex: Int { 0 }; subscript(i: Int) -> Int { 0 }
              func index(after i: Int) -> Int { \(Self.ENV); return i + 1 }
              var count: Int { \(Self.ENV); return 0 }
            }
            struct GBox<Base: Collection> { let base: Base
              func a(_ i: Base.Index) -> Base.Index { base.index(after: i) }
              func b() -> Int { self.base.count } }
            extension Collection { func selfCount() -> Int { self.count } }
            extension Sequence { func selfCopy() -> Int { let me = self; return me.underestimatedCount } }
            func mkSome() -> some Collection { [1] }
            func useSome() -> Int { let c = mkSome(); return c.count }
            func shadowed<Collection: Swift.Collection>(_ c: Collection) -> Int { c.count }
            func gen<T: Collection>(_ t: T) -> Int { let y = t; return y.count }
            func opq(_ s: some Collection) -> Int { s.count }
            func exi(_ x: any Collection) -> Int { x.count }
            func use() -> Int { GBox(base: [1, 2]).a(0) + GBox(base: [1]).b() + [1].selfCount() + gen([1]) + opq([1])
              + [1].selfCopy() + useSome() + shadowed([1]) }
            """)
        let r = try ProcessHarness.run(bin, [dir.path, "--out", root.appendingPathComponent("rep").path])
        XCTAssertEqual(r.code, 0, r.err)
        let s = Scan(root: root, target: dir, deps: nil, rows: try rows(root.appendingPathComponent("rep.tree.Swift.json")))
        for fn in ["GBox.a", "GBox.b", "Collection.selfCount", "Sequence.selfCopy", "gen", "opq", "useSome", "shadowed", "use"] {
            XCTAssertFalse(strs(s, fn, "inferred").contains("Env"), "CONTROL: \(fn)'s receiver is monomorphized: \(s.rows[fn] ?? [:])")
            XCTAssertEqual(try gate(s, "deny Env \(fn)"), 0, "deny Env \(fn)")
        }
        XCTAssertTrue(strs(s, "exi", "calls").contains("LoudCol.count"), "the existential does reach it: \(s.rows["exi"] ?? [:])")
        XCTAssertEqual(try gate(s, "deny Env exi"), 1)
    }

    func testKillSwitchRestoresTheReleaseSilence() throws {
        let off = ["CANDOR_R1473_OFF": "1"]
        let t = try oneTree(effectful: true, env: off)
        defer { try? FileManager.default.removeItem(at: t.root) }
        let c = try chained(effectful: true, env: off)
        defer { try? FileManager.default.removeItem(at: c.root) }
        for d in Self.defects {
            XCTAssertNil(t.rows[d.fn], "v0.41.3 behaviour under the kill switch (one tree): \(d.fn)")
            XCTAssertNil(c.rows[d.fn], "v0.41.3 behaviour under the kill switch (chained): \(d.fn)")
            XCTAssertEqual(try gate(t, "deny Fs \(d.fn)", env: off), 0)
        }
        XCTAssertNil(c.rows["descStr"], "chained stringification under the kill switch")
    }
}
