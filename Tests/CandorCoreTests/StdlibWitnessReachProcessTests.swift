import XCTest
import Foundation

/// SOUNDNESS R1490 — PLATFORM-PROTOCOL WITNESSES THE R1473 FIX DOES NOT REACH.
///
/// Every shape below was ABSENT at af160cd (R1473), in ONE TREE and CHAINED, while the program ran the conformer's
/// witness and wrote a file (EXECUTED: each shape built and run, the marker observed — `swiftagent-r1490/fx/gt.sh`):
///   (a) a requirement read on a GENERIC or OPAQUE parameter (`<T: CustomStringConvertible>` / `some P` `.description`,
///       `T: Hashable` `.hashValue`, `T: LocalizedError` `.errorDescription`), and on a generic type's stored field —
///       answered at the CALLER from the argument's own type, as R951 answers `==`;
///   (b) a CHAINED type passed to a local generic (`eqGen(FEq(), FEq())`) — the caller-witness answer now asks the
///       dependency's report under `<Type>.<witness>`;
///   (c) `e.localizedDescription` and `e as NSError`, which Foundation's error bridge answers from the conformer's
///       `LocalizedError` / `CustomNSError` witnesses;
///   (d) `JSONEncoder().encode(x)` / `PropertyListEncoder().encode(x)` (the value's `encode(to:)`) and
///       `JSONDecoder().decode(T.self, from:)` (`T.init(from:)`);
///   (e) a concrete `x.hashValue` over a hand-written `hash(into:)`;
///   (f) a loop or closure binder over `[any P]`, and a closure parameter annotated `any P`.
/// The gate is read at the function that holds the instantiation (the caller, for (a)/(b)): one tree `deny Fs` 0 → 1;
/// chained `deny Fs` 0 → 1 where the dependency's row answers, `deny Unknown` 0 → 1 where an existential discloses.
/// `CANDOR_R1490_OFF=1` restores af160cd. The controls were written first and pass on both binaries.
final class StdlibWitnessReachProcessTests: XCTestCase {

    private static let FS = "_ = FileManager.default.fileExists(atPath: \"/tmp\")"
    private static let ENV = "_ = ProcessInfo.processInfo.environment[\"HOME\"]"

    /// The dependency-side conformers. `effectful: false` is the PURE-CONFORMER control: same types, empty witnesses.
    private static func witnesses(effectful: Bool, access a: String) -> String {
        let e = effectful ? FS + "; " : ""
        return """
        import Foundation
        \(a)struct FDesc: CustomStringConvertible { \(a)init() {}; \(a)var description: String { \(e)return "f" } }
        \(a)struct FDbg: CustomDebugStringConvertible { \(a)init() {}; \(a)var debugDescription: String { \(e)return "d" } }
        \(a)struct FEq: Equatable { \(a)init() {}; \(a)static func == (l: FEq, r: FEq) -> Bool { \(e)return true } }
        \(a)struct FHash: Hashable { \(a)init() {}; \(a)func hash(into h: inout Hasher) { \(e) }
          \(a)static func == (l: FHash, r: FHash) -> Bool { true } }
        \(a)struct FErr: LocalizedError { \(a)init() {}; \(a)var errorDescription: String? { \(e)return "e" } }
        \(a)struct FNSErr: CustomNSError { \(a)init() {}; \(a)var errorCode: Int { \(e)return 3 } }
        \(a)struct FEnc: Encodable { \(a)init() {}; \(a)func encode(to x: Encoder) throws { \(e) } }
        \(a)struct FDec: Decodable { \(a)init() {}; \(a)init(from d: Decoder) throws { \(e) } }
        """
    }

    private static let app = """
    import Foundation
    struct LDesc: CustomStringConvertible { var description: String { "l" } }
    struct LHash: Hashable { var v = 1 }
    struct NotDesc { var description: String { \(ENV); return "" } }
    func gDesc<T: CustomStringConvertible>(_ x: T) -> String { x.description }
    func oDesc(_ x: some CustomStringConvertible) -> String { x.description }
    func gDbg<T: CustomDebugStringConvertible>(_ x: T) -> String { x.debugDescription }
    func gHashV<T: Hashable>(_ x: T) -> Int { x.hashValue }
    func gErrD<T: LocalizedError>(_ e: T) -> String? { e.errorDescription }
    func gFwd<T: CustomStringConvertible>(_ x: T) -> String { gDesc(x) }
    func gWhere<T>(_ x: T) -> String where T: CustomStringConvertible { x.description }
    struct GBoxD<T: CustomStringConvertible> { let t: T; func d() -> String { t.description } }
    func eqGen<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
    func cLocGen<E: Error>(_ e: E) -> String { e.localizedDescription }
    func dEncGen<T: Encodable>(_ x: T) -> Data? { try? JSONEncoder().encode(x) }
    func aGDesc() -> String { gDesc(FDesc()) }
    func aODesc() -> String { oDesc(FDesc()) }
    func aGDbg() -> String { gDbg(FDbg()) }
    func aGHashV() -> Int { gHashV(FHash()) }
    func aGErrD() -> String? { gErrD(FErr()) }
    func aGFwd() -> String { gFwd(FDesc()) }
    func aGWhere() -> String { gWhere(FDesc()) }
    func aGBox() -> String { GBoxD(t: FDesc()).d() }
    func bEqGen() -> Bool { eqGen(FEq(), FEq()) }
    func aLocGen() -> String { cLocGen(FErr()) }
    func aEncGen() -> Data? { dEncGen(FEnc()) }
    func cLocAny(_ e: any Error) -> String { e.localizedDescription }
    func cLocCatch() -> String { do { throw FErr() } catch { return error.localizedDescription } }
    func cLocConc(_ e: FErr) -> String { e.localizedDescription }
    func cNS(_ e: any Error) -> Int { (e as NSError).code }
    func dEncAny(_ x: any Encodable) -> Data? { try? JSONEncoder().encode(x) }
    func dEncPlist(_ x: any Encodable) -> Data? { try? PropertyListEncoder().encode(x) }
    func dEncConc(_ x: FEnc) -> Data? { try? JSONEncoder().encode(x) }
    func dDecConc(_ d: Data) -> FDec? { try? JSONDecoder().decode(FDec.self, from: d) }
    func eHashV(_ x: FHash) -> Int { x.hashValue }
    func fLoop(_ xs: [any CustomStringConvertible]) -> Int { var n = 0; for x in xs { n += x.description.count }; return n }
    func fMap(_ xs: [any CustomStringConvertible]) -> [String] { xs.map { $0.description } }
    func fClos(_ xs: [Any]) -> [String] { xs.compactMap { $0 as? CustomStringConvertible }.map { (x: any CustomStringConvertible) in x.description } }
    // CONTROLS: pure / platform instantiations beside the effectful conformers; a protocol extension's `self`; a
    // non-conformer's same-named member over a non-existential array.
    struct LoudSeq: Sequence { func makeIterator() -> IndexingIterator<[Int]> { \(ENV); return [1].makeIterator() } }
    func gSeq<S: Sequence>(_ s: S) -> Int { var it = s.makeIterator(); return it.next() == nil ? 0 : 1 }
    func kGSeqArr() -> Int { gSeq([1, 2]) }
    func kGDescL() -> String { gDesc(LDesc()) }
    func kGDescInt() -> String { gDesc(42) }
    func kODescStr() -> String { oDesc("s") }
    func kGHashL() -> Int { gHashV(LHash()) }
    func kGBoxL() -> String { GBoxD(t: LDesc()).d() }
    func kGFwdL() -> String { gFwd(LDesc()) }
    func kEqInt() -> Bool { eqGen(1, 2) }
    func kHashVL(_ x: LHash) -> Int { x.hashValue }
    extension Collection { func selfCountR1490() -> Int { self.count } }
    func kSelfExt() -> Int { [1].selfCountR1490() }
    func kLoopNot(_ xs: [NotDesc]) -> Int { var n = 0; for x in xs { n += x.description.count }; return n }
    """

    /// (fn, the witness unit it edges in one tree, chained: "Fs" = the dependency's row answers, else the `unknownWhy`)
    private static let defects: [(fn: String, witness: String, chained: String)] = [
        ("aGDesc", "FDesc.description", "Fs"), ("aODesc", "FDesc.description", "Fs"),
        ("aGDbg", "FDbg.debugDescription", "Fs"), ("aGHashV", "FHash.hash", "Fs"),
        ("aGErrD", "FErr.errorDescription", "Fs"), ("aGFwd", "FDesc.description", "Fs"),
        ("aGWhere", "FDesc.description", "Fs"), ("aGBox", "FDesc.description", "Fs"),
        ("bEqGen", "FEq.==", "Fs"), ("aLocGen", "FErr.errorDescription", "Fs"), ("aEncGen", "FEnc.encode", "Fs"),
        ("cLocAny", "FErr.errorDescription", "dispatch:Error.localizedDescription"),
        ("cLocCatch", "FErr.errorDescription", "dispatch:Error.localizedDescription"),
        ("cLocConc", "FErr.errorDescription", "Fs"),
        ("cNS", "FNSErr.errorCode", "dispatch:Error.asNSError"),
        ("dEncAny", "FEnc.encode", "dispatch:Encodable.encode"),
        ("dEncPlist", "FEnc.encode", "dispatch:Encodable.encode"),
        ("dEncConc", "FEnc.encode", "Fs"), ("dDecConc", "FDec.init(Decoder)", "Fs"),
        ("eHashV", "FHash.hash", "Fs"),
        ("fLoop", "FDesc.description", "dispatch:CustomStringConvertible.description"),
        ("fMap", "FDesc.description", "dispatch:CustomStringConvertible.description"),
        ("fClos", "FDesc.description", "dispatch:CustomStringConvertible.description"),
    ]
    private static let controls = ["kGSeqArr", "kGDescL", "kGDescInt", "kODescStr", "kGHashL", "kGBoxL", "kGFwdL", "kEqInt",
                                   "kHashVL", "kSelfExt"]

    // ── harness (the R1473 tests' shape) ──────────────────────────────────────────────────────────────────────
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
    private func oneTree(effectful: Bool, env: [String: String] = [:]) throws -> Scan {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1490-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("tree")
        try write(dir.appendingPathComponent("W.swift"), Self.witnesses(effectful: effectful, access: ""))
        try write(dir.appendingPathComponent("A.swift"), Self.app)
        let r = try ProcessHarness.run(bin, [dir.path, "--out", root.appendingPathComponent("rep").path], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        return Scan(root: root, target: dir, deps: nil, rows: try rows(root.appendingPathComponent("rep.tree.Swift.json")))
    }
    private func chained(effectful: Bool, env: [String: String] = [:]) throws -> Scan {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1490-\(UUID().uuidString)")
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
    func testOneTreeChargesTheWitnessAtTheInstantiation() throws {
        let s = try oneTree(effectful: true)
        defer { try? FileManager.default.removeItem(at: s.root) }
        for d in Self.defects {
            XCTAssertTrue(strs(s, d.fn, "calls").contains(d.witness), "\(d.fn) must edge \(d.witness): \(s.rows[d.fn] ?? [:])")
            XCTAssertTrue(strs(s, d.fn, "inferred").contains("Fs"), "\(d.fn): \(s.rows[d.fn] ?? [:])")
            XCTAssertEqual(try gate(s, "deny Fs \(d.fn)"), 1, "deny Fs \(d.fn) must fire in one tree")
        }
    }

    func testChainedResolvesOrDiscloses() throws {
        let s = try chained(effectful: true)
        defer { try? FileManager.default.removeItem(at: s.root) }
        for d in Self.defects {
            if d.chained == "Fs" {
                XCTAssertTrue(strs(s, d.fn, "inferred").contains("Fs"), "\(d.fn) must join the dependency's row: \(s.rows[d.fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Fs \(d.fn)"), 1, "deny Fs \(d.fn) chained")
            } else {
                XCTAssertTrue(strs(s, d.fn, "unknownWhy").contains(d.chained), "\(d.fn) must disclose \(d.chained): \(s.rows[d.fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Unknown \(d.fn)"), 1, "deny Unknown \(d.fn) chained")
            }
        }
    }

    // ── controls ────────────────────────────────────────────────────────────────────────────────────────────
    func testPureConformersGainNothingInEitherArm() throws {
        for s in [try oneTree(effectful: false), try chained(effectful: false)] {
            defer { try? FileManager.default.removeItem(at: s.root) }
            for fn in Self.defects.map(\.fn) + Self.controls where fn != "kGSeqArr" {
                XCTAssertFalse(strs(s, fn, "inferred").contains("Fs"), "CONTROL: every conformer is pure, \(fn): \(s.rows[fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Unknown \(fn)"), 0, "deny Unknown \(fn)")
                XCTAssertEqual(try gate(s, "deny Fs \(fn)"), 0, "deny Fs \(fn)")
            }
        }
    }

    /// A pure or PLATFORM instantiation of the same generic, beside effectful conformers, must not move; a protocol
    /// extension's `self` is the caller's; a non-conformer's same-named member is never a witness (executed: none runs).
    func testMonomorphizedAndNonConformerControlsDoNotMove() throws {
        for s in [try oneTree(effectful: true), try chained(effectful: true)] {
            defer { try? FileManager.default.removeItem(at: s.root) }
            for fn in Self.controls {
                XCTAssertTrue(strs(s, fn, "inferred").isEmpty, "CONTROL \(fn): \(s.rows[fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Fs \(fn)"), 0, "deny Fs \(fn)")
                XCTAssertEqual(try gate(s, "deny Env \(fn)"), 0, "deny Env \(fn)")
                XCTAssertEqual(try gate(s, "deny Unknown \(fn)"), 0, "deny Unknown \(fn)")
            }
            for d in Self.defects { XCTAssertFalse(strs(s, d.fn, "inferred").contains("Env"), "\(d.fn) reached a non-witness") }
            // `kLoopNot` iterates `[NotDesc]`, a CONCRETE type: its own `description` really runs (Env), and the
            // existential rule must add nothing beside it.
            XCTAssertEqual(strs(s, "kLoopNot", "inferred"), ["Env"], "kLoopNot: \(s.rows["kLoopNot"] ?? [:])")
        }
    }

    func testKillSwitchRestoresAf160cd() throws {
        let off = ["CANDOR_R1490_OFF": "1"]
        let t = try oneTree(effectful: true, env: off)
        defer { try? FileManager.default.removeItem(at: t.root) }
        let c = try chained(effectful: true, env: off)
        defer { try? FileManager.default.removeItem(at: c.root) }
        for d in Self.defects where d.fn != "bEqGen" {
            XCTAssertEqual(try gate(t, "deny Fs \(d.fn)", env: off), 0, "one tree under the kill switch: \(d.fn)")
            XCTAssertTrue(strs(c, d.fn, "inferred").isEmpty, "chained under the kill switch: \(d.fn): \(c.rows[d.fn] ?? [:])")
            XCTAssertEqual(try gate(c, "deny Unknown \(d.fn)", env: off), 0, "chained under the kill switch: \(d.fn)")
        }
        XCTAssertEqual(try gate(t, "deny Fs bEqGen", env: off), 1, "R951 already answered a LOCAL type in one tree")
        XCTAssertTrue(strs(c, "bEqGen", "inferred").isEmpty, "…and nothing chained")
    }
}
