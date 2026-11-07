import XCTest
import Foundation

/// SOUNDNESS R1490 RESIDUALS (1)(2)(3)(5)(6), R1502 and R1503 — PLATFORM-PROTOCOL WITNESSES STILL NOT REACHED AFTER 4f2240c.
///
/// Every defect shape below was ABSENT at b6452a0, in one tree and/or chained, while the program ran the witness and wrote
/// a file (EXECUTED: each shape built and run, the marker observed — `swiftagent-vein/fx/W`, `gt.sh`):
///   (1)  a coding CONTAINER's `encode(_:forKey:)` / `encode(_:)` / `decode(_:forKey:)` inside a hand-written
///        `encode(to:)` / `init(from:)`, and `JSONEncoder().encode([FEnc()])` (an array value);
///   (2)  a SYNTHESIZED `Encodable` / `Decodable` conformer's stored properties (nested, optional, array, generic);
///   (3)  `self` inside a protocol extension (`extension CustomStringConvertible`, `extension Encodable { encode(self) }`,
///        a bare requirement read in `extension LP` with `protocol LP: CustomStringConvertible`);
///   (5)  a stored `[any P]` field iterated (`for`, `.map`, `self.xs`);
///   (6)  a platform type this scan conforms (`extension Int: LocalizedError`) passed to a generic;
///   R1502  `JSONDecoder().decode(T.self, from:)` where `T`'s one hand-written init is `init(from:)` (bare qual `T.init`);
///   R1503  a CHAINED type the consumer extends (`extension FDesc: LP3 {}`) passed to a local generic.
/// The gate is read at the function holding the call: `deny Fs` 0 → 1 (one tree, and chained where the dependency's row
/// answers); `deny Unknown` 0 → 1 chained where an existential discloses. Controls were written first.
final class WitnessVeinResidualProcessTests: XCTestCase {

    private static let FS = "_ = FileManager.default.fileExists(atPath: \"/tmp\")"

    /// The dependency-side conformers; `effectful: false` is the PURE-CONFORMER control (same types, empty witnesses).
    private static func witnesses(effectful: Bool, access a: String) -> String {
        let e = effectful ? FS + "; " : ""
        return """
        import Foundation
        \(a)struct FEnc: Encodable { \(a)init() {}; \(a)func encode(to x: Encoder) throws { \(e)var c = x.singleValueContainer(); try c.encode(1) } }
        \(a)struct FDec: Decodable { \(a)init(from d: Decoder) throws { \(e) } }
        \(a)struct PEnc: Encodable { \(a)init() {}; \(a)func encode(to x: Encoder) throws { var c = x.singleValueContainer(); try c.encode(1) } }
        \(a)struct FDesc: CustomStringConvertible { \(a)init() {}; \(a)var description: String { \(e)return "f" } }
        \(a)struct PDesc: CustomStringConvertible { \(a)init() {}; \(a)var description: String { "p" } }
        \(a)struct FErr: LocalizedError { \(a)init() {}; \(a)var errorDescription: String? { \(e)return "e" } }
        """
    }

    private static let app = """
    import Foundation
    func gDesc<T: CustomStringConvertible>(_ x: T) -> String { x.description }
    func gErrD<T: LocalizedError>(_ e: T) -> String? { e.errorDescription }
    enum K: String, CodingKey { case i }
    struct O1K: Encodable { let inner: FEnc
      func encode(to e: Encoder) throws { var c = e.container(keyedBy: K.self); try c.encode(inner, forKey: .i) } }
    struct O1S: Encodable { let inner: FEnc
      func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(inner) } }
    struct O1U: Encodable { let inner: FEnc
      func encode(to e: Encoder) throws { var c = e.unkeyedContainer(); try c.encode(inner) } }
    struct O1D: Decodable { let inner: FDec
      init(from d: Decoder) throws { let c = try d.container(keyedBy: K.self); inner = try c.decode(FDec.self, forKey: .i) } }
    struct LDec1: Decodable { init(from d: Decoder) throws { \(FS) } }
    struct Syn: Encodable { var inner = FEnc() }
    struct SynOpt: Encodable { var inner: FEnc? = FEnc() }
    struct SynArr: Encodable { var inner = [FEnc()] }
    struct SynD: Decodable { let inner: FDec }
    struct SynNest: Encodable { var syn = Syn() }
    extension CustomStringConvertible { func shout3() -> String { self.description } }
    extension Encodable { func json3() -> Data? { try? JSONEncoder().encode(self) } }
    protocol LP3: CustomStringConvertible {}
    extension LP3 { func bare3() -> String { description } }
    struct L3: LP3 { var description: String { \(FS); return "" } }
    extension FDesc: LP3 {}
    final class H5 { var xs: [any CustomStringConvertible] = []
      func loop() -> Int { var n = 0; for x in xs { n += x.description.count }; return n }
      func mapped() -> [String] { xs.map { $0.description } }
      func selfLoop() -> Int { var n = 0; for x in self.xs { n += x.description.count }; return n } }
    extension Int: LocalizedError { public var errorDescription: String? { \(FS); return "i" } }
    func r1K() -> Data? { try? JSONEncoder().encode(O1K(inner: FEnc())) }
    func r1S() -> Data? { try? JSONEncoder().encode(O1S(inner: FEnc())) }
    func r1U() -> Data? { try? JSONEncoder().encode(O1U(inner: FEnc())) }
    func r1DO(_ d: Data) -> O1D? { try? JSONDecoder().decode(O1D.self, from: d) }
    func r1DLoc(_ d: Data) -> LDec1? { try? JSONDecoder().decode(LDec1.self, from: d) }
    func r1DDep(_ d: Data) -> FDec? { try? JSONDecoder().decode(FDec.self, from: d) }
    func r1Arr() -> Data? { try? JSONEncoder().encode([FEnc()]) }
    func r2Enc() -> Data? { try? JSONEncoder().encode(Syn()) }
    func r2Opt() -> Data? { try? JSONEncoder().encode(SynOpt()) }
    func r2Arr() -> Data? { try? JSONEncoder().encode(SynArr()) }
    func r2Dec(_ d: Data) -> SynD? { try? JSONDecoder().decode(SynD.self, from: d) }
    func r2Nest() -> Data? { try? JSONEncoder().encode(SynNest()) }
    func r3Self() -> String { FDesc().shout3() }
    func r3Json() -> Data? { FEnc().json3() }
    func r3BareF() -> String { FDesc().bare3() }
    func r3BareL() -> String { L3().bare3() }
    func r5Loop() -> Int { H5().loop() }
    func r5Map() -> [String] { H5().mapped() }
    func r5Self() -> Int { H5().selfLoop() }
    func r6Gen() -> String? { gErrD(5) }
    func r7ExtGen() -> String { gDesc(FDesc()) }
    // CONTROLS — pure values beside the effectful ones; a non-coder's same-named member; members a synthesized
    // conformance does not encode (CodingKeys-excluded, computed, static); a local init that is not `init(from:)`.
    struct NotCoder { func encode(_ x: FEnc, forKey k: K) { } }
    struct O1KP: Encodable { let inner: PEnc
      func encode(to e: Encoder) throws { var c = e.container(keyedBy: K.self); try c.encode(inner, forKey: .i) } }
    struct O1KI: Encodable { let n: Int
      func encode(to e: Encoder) throws { var c = e.container(keyedBy: K.self); try c.encode(n, forKey: .i) } }
    struct LInit1: Decodable { var n = 0; init(n: Int) { \(FS) } }
    struct SynP: Encodable { var inner = PEnc() }
    struct SynCK: Encodable { var inner = FEnc(); var n = 1; enum CodingKeys: String, CodingKey { case n } }
    struct SynComp: Encodable { var n = 1; var inner: FEnc { FEnc() } }
    struct SynStatic: Encodable { var n = 1; static var inner = FEnc() }
    final class H5P { var xs: [PDesc] = [PDesc()]
      func loop() -> Int { var n = 0; for x in xs { n += x.description.count }; return n } }
    func kNot() { NotCoder().encode(FEnc(), forKey: .i) }
    func kKP() -> Data? { try? JSONEncoder().encode(O1KP(inner: PEnc())) }
    func kKI() -> Data? { try? JSONEncoder().encode(O1KI(n: 1)) }
    func kDInit(_ d: Data) -> LInit1? { try? JSONDecoder().decode(LInit1.self, from: d) }
    func kSynP() -> Data? { try? JSONEncoder().encode(SynP()) }
    func kSynCK() -> Data? { try? JSONEncoder().encode(SynCK()) }
    func kSynComp() -> Data? { try? JSONEncoder().encode(SynComp()) }
    func kSynStatic() -> Data? { try? JSONEncoder().encode(SynStatic()) }
    func kShoutP() -> String { PDesc().shout3() }
    func kJsonP() -> Data? { PEnc().json3() }
    func kLoopP() -> Int { H5P().loop() }
    func kGDescP() -> String { gDesc(PDesc()) }
    func kGDescInt() -> String { gDesc(42) }
    """

    /// (fn, one-tree expectation is always `Fs`; chained: "Fs" = the dependency's row answers, else the `unknownWhy`;
    /// the kill switch that alone restores b6452a0's reading in one tree, or nil where one tree already charged.)
    private static let defects: [(fn: String, chained: String, oneTreeSwitch: String?)] = [
        ("r1K", "Fs", "CANDOR_R1490R1_OFF"), ("r1S", "Fs", "CANDOR_R1490R1_OFF"), ("r1U", "Fs", "CANDOR_R1490R1_OFF"),
        ("r1DO", "Fs", "CANDOR_R1490R1_OFF"), ("r1Arr", "Fs", "CANDOR_R1490R1_OFF"),
        ("r1DLoc", "Fs", "CANDOR_R1502_OFF"), ("r1DDep", "Fs", "CANDOR_R1502_OFF"),
        ("r2Enc", "Fs", "CANDOR_R1490R2_OFF"), ("r2Opt", "Fs", "CANDOR_R1490R2_OFF"), ("r2Arr", "Fs", "CANDOR_R1505_OFF"),
        ("r2Dec", "Fs", "CANDOR_R1490R2_OFF"), ("r2Nest", "Fs", "CANDOR_R1490R2_OFF"),
        ("r3Self", "Fs", "CANDOR_R1490R3_OFF"), ("r3Json", "Fs", "CANDOR_R1490R3_OFF"),
        ("r3BareF", "Fs", "CANDOR_R1490R3_OFF"), ("r3BareL", "Fs", "CANDOR_R1490R3_OFF"),
        ("r5Loop", "dispatch:CustomStringConvertible.description", "CANDOR_R1490R5_OFF"),
        ("r5Map", "dispatch:CustomStringConvertible.description", "CANDOR_R1490R5_OFF"),
        ("r5Self", "dispatch:CustomStringConvertible.description", "CANDOR_R1490R5_OFF"),
        ("r6Gen", "Fs", "CANDOR_R1490R6_OFF"), ("r7ExtGen", "Fs", nil),
    ]
    private static let controls = ["kNot", "kKP", "kKI", "kDInit", "kSynP", "kSynCK", "kSynComp", "kSynStatic", "kShoutP",
                                   "kJsonP", "kLoopP", "kGDescP", "kGDescInt"]

    // ── harness (the R1490 tests' shape) ──────────────────────────────────────────────────────────────────────
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
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-wvr-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("tree")
        try write(dir.appendingPathComponent("W.swift"), Self.witnesses(effectful: effectful, access: ""))
        try write(dir.appendingPathComponent("A.swift"), Self.app)
        let r = try ProcessHarness.run(bin, [dir.path, "--out", root.appendingPathComponent("rep").path], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        return Scan(root: root, target: dir, deps: nil, rows: try rows(root.appendingPathComponent("rep.tree.Swift.json")))
    }
    private func chained(effectful: Bool, env: [String: String] = [:]) throws -> Scan {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-wvr-\(UUID().uuidString)")
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

    /// A `deny E <fn>` scope matches by PREFIX (§3.3): no fixture name may be a prefix of another, or a gate reads a sibling.
    func testFixtureNamesAreNotPrefixesOfEachOther() {
        let names = Self.defects.map(\.fn) + Self.controls
        for a in names { for b in names where a != b { XCTAssertFalse(b.hasPrefix(a), "\(a) is a prefix of \(b)") } }
    }

    // ── defect arms ─────────────────────────────────────────────────────────────────────────────────────────
    func testOneTreeChargesTheWitness() throws {
        let s = try oneTree(effectful: true)
        defer { try? FileManager.default.removeItem(at: s.root) }
        for d in Self.defects {
            XCTAssertTrue(strs(s, d.fn, "inferred").contains("Fs"), "\(d.fn): \(s.rows[d.fn] ?? [:])")
            XCTAssertEqual(try gate(s, "deny Fs \(d.fn)"), 1, "deny Fs \(d.fn) must fire in one tree")
        }
    }

    func testChainedResolvesOrDiscloses() throws {
        let s = try chained(effectful: true)
        defer { try? FileManager.default.removeItem(at: s.root) }
        for d in Self.defects {
            if d.chained == "Fs" {
                XCTAssertTrue(strs(s, d.fn, "inferred").contains("Fs"), "\(d.fn) must reach the witness chained: \(s.rows[d.fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Fs \(d.fn)"), 1, "deny Fs \(d.fn) chained")
            } else {
                // the reason sits on the unit that dispatches (`H5.loop`); the caller inherits the `Unknown`
                XCTAssertTrue(strs(s, d.fn, "inferred").contains("Unknown"), "\(d.fn) must disclose: \(s.rows[d.fn] ?? [:])")
                let unit = ["r5Loop": "H5.loop", "r5Map": "H5.mapped", "r5Self": "H5.selfLoop"][d.fn] ?? d.fn
                XCTAssertTrue(strs(s, unit, "unknownWhy").contains(d.chained), "\(unit) must disclose \(d.chained): \(s.rows[unit] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Unknown \(d.fn)"), 1, "deny Unknown \(d.fn) chained")
            }
        }
    }

    // ── controls ────────────────────────────────────────────────────────────────────────────────────────────
    func testPureConformersGainNoEffect() throws {
        for s in [try oneTree(effectful: false), try chained(effectful: false)] {
            defer { try? FileManager.default.removeItem(at: s.root) }
            // `r1DLoc`, `r3BareL` and `r6Gen` reach witnesses declared in the APP, which stay effectful here.
            for fn in Self.defects.map(\.fn) + Self.controls where !["r1DLoc", "r3BareL", "r6Gen"].contains(fn) {
                XCTAssertFalse(strs(s, fn, "inferred").contains("Fs"), "CONTROL: every dependency witness is pure, \(fn): \(s.rows[fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Fs \(fn)"), 0, "deny Fs \(fn)")
            }
        }
    }

    func testControlsDoNotMove() throws {
        for s in [try oneTree(effectful: true), try chained(effectful: true)] {
            defer { try? FileManager.default.removeItem(at: s.root) }
            for fn in Self.controls {
                XCTAssertFalse(strs(s, fn, "inferred").contains("Fs"), "CONTROL \(fn): \(s.rows[fn] ?? [:])")
                XCTAssertEqual(try gate(s, "deny Fs \(fn)"), 0, "deny Fs \(fn)")
            }
        }
    }

    /// Each fix's own switch alone restores b6452a0's silence for its shapes in one tree (`r7ExtGen` was charged there).
    func testEachKillSwitchRestoresItsSilence() throws {
        for sw in Set(Self.defects.compactMap(\.oneTreeSwitch)).sorted() {
            let env = [sw: "1"]
            let s = try oneTree(effectful: true, env: env)
            defer { try? FileManager.default.removeItem(at: s.root) }
            for d in Self.defects where d.oneTreeSwitch == sw {
                XCTAssertEqual(try gate(s, "deny Fs \(d.fn)", env: env), 0, "\(sw) must restore the silence of \(d.fn): \(s.rows[d.fn] ?? [:])")
            }
        }
        let env = ["CANDOR_R1490R6_OFF": "1"]
        let c = try chained(effectful: true, env: env)
        defer { try? FileManager.default.removeItem(at: c.root) }
        XCTAssertEqual(try gate(c, "deny Fs r7ExtGen", env: env), 0, "R1503: the extended chained type is dropped without R1490R6")
    }
}

/// SOUNDNESS R1504 — R656'S PROPERTY AND CONSTRUCTOR HALVES. With ANY `extension DT { }` in the consumer (EMPTY included),
/// a dependency type's constructor `DT(v: 1)`, its computed property `d.prop` / `DT().prop`, and `self.prop` /
/// `self.init(v:)` inside that extension read ABSENT chained, while the same consumer WITHOUT the extension charged them
/// and the program ran the dependency's bodies (executed, `swiftagent-vein/fx/D3`; published 0.41.3 too). One variable:
/// the extension file. The fix must make the extended consumer read exactly what the unextended one reads.
final class ExtensionOnlyCtorAndPropertyProcessTests: XCTestCase {
    private static let FS = "_ = FileManager.default.fileExists(atPath: \"/tmp\")"
    private static let dep = """
    import Foundation
    public struct DT { public init() {}; public init(v: Int) { \(FS) }; public var prop: Int { \(FS); return 1 } }
    public struct PT { public init() {}; public init(v: Int) {}; public var prop: Int { 1 } }
    """
    private static let use = """
    func e9Ctor() { _ = DT(v: 1) }
    func e9Prop() -> Int { DT().prop }
    func e9PropP(_ d: DT) -> Int { d.prop }
    func kPureCtor() { _ = PT(v: 1) }
    func kPureProp(_ p: PT) -> Int { p.prop }
    """
    private static let ext = """
    extension DT { }
    extension PT { }
    extension DT {
      init(w: Int) { self.init(v: w) }
      func viaSelfProp() -> Int { self.prop }
    }
    func e9Init() { _ = DT(w: 1) }
    func e9SelfProp() -> Int { DT().viaSelfProp() }
    """

    private func scan(extended: Bool, env: [String: String] = [:]) throws -> (rows: [String: [String: Any]], gate: (String) throws -> Int32, root: URL) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1504-\(UUID().uuidString)")
        func write(_ u: URL, _ t: String) throws {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try t.write(to: u, atomically: true, encoding: .utf8)
        }
        let depDir = root.appendingPathComponent("dep")
        try write(depDir.appendingPathComponent("Package.swift"), """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "Dep", products: [.library(name: "Dep", targets: ["Dep"])], targets: [.target(name: "Dep")])
            """)
        try write(depDir.appendingPathComponent("Sources/Dep/D.swift"), Self.dep)
        let r1 = try ProcessHarness.run(bin, [depDir.path, "--out", root.appendingPathComponent("rep-dep").path], env: env)
        XCTAssertEqual(r1.code, 0, r1.err)
        let depRep = root.appendingPathComponent("rep-dep.Dep.Swift.json").path
        let app = root.appendingPathComponent("app")
        try write(app.appendingPathComponent("Package.swift"), """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "App", dependencies: [.package(path: "../dep")],
                targets: [.executableTarget(name: "App", dependencies: [.product(name: "Dep", package: "dep")])])
            """)
        try write(app.appendingPathComponent("Sources/App/A.swift"), "import Dep\n" + Self.use)
        if extended { try write(app.appendingPathComponent("Sources/App/E.swift"), "import Dep\n" + Self.ext) }
        var e = env; e["CANDOR_DEPS"] = depRep
        let r2 = try ProcessHarness.run(bin, [app.path, "--out", root.appendingPathComponent("rep-app").path], env: e)
        XCTAssertEqual(r2.code, 0, r2.err)
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("rep-app.App.Swift.json"))) as? [String: Any]
        var rows: [String: [String: Any]] = [:]
        for f in (d?["functions"] as? [[String: Any]]) ?? [] { if let n = f["fn"] as? String { rows[n] = f } }
        let gate: (String) throws -> Int32 = { policy in
            let pol = root.appendingPathComponent("p-\(UUID().uuidString)")
            try (policy + "\n").write(to: pol, atomically: true, encoding: .utf8)
            return try ProcessHarness.run(bin, [app.path, "--out", root.appendingPathComponent("g-\(UUID().uuidString)").path,
                                               "--policy", pol.path], env: e).code
        }
        return (rows, gate, root)
    }
    private func inf(_ rows: [String: [String: Any]], _ fn: String) -> Set<String> { Set((rows[fn]?["inferred"] as? [String]) ?? []) }

    func testTheExtensionNoLongerSilencesTheDependency() throws {
        let plain = try scan(extended: false)
        defer { try? FileManager.default.removeItem(at: plain.root) }
        let ext = try scan(extended: true)
        defer { try? FileManager.default.removeItem(at: ext.root) }
        for fn in ["e9Ctor", "e9Prop", "e9PropP"] {
            XCTAssertTrue(inf(plain.rows, fn).contains("Fs"), "UNEXTENDED baseline \(fn): \(plain.rows[fn] ?? [:])")
            XCTAssertTrue(inf(ext.rows, fn).contains("Fs"), "an `extension DT { }` must not silence \(fn): \(ext.rows[fn] ?? [:])")
            XCTAssertEqual(try ext.gate("deny Fs \(fn)"), 1, "deny Fs \(fn) with the extension")
        }
        for fn in ["e9Init", "e9SelfProp"] {   // the extension's own `self.init(v:)` and `self.prop`
            XCTAssertTrue(inf(ext.rows, fn).contains("Fs"), "\(fn): \(ext.rows[fn] ?? [:])")
            XCTAssertEqual(try ext.gate("deny Fs \(fn)"), 1, "deny Fs \(fn)")
        }
        for fn in ["kPureCtor", "kPureProp"] {   // CONTROL: the dependency's pure ctor / property stay pure in both arms
            XCTAssertTrue(inf(plain.rows, fn).isEmpty && inf(ext.rows, fn).isEmpty, "CONTROL \(fn)")
            XCTAssertEqual(try ext.gate("deny Fs \(fn)"), 0, "deny Fs \(fn)")
        }
    }

    func testKillSwitchRestoresTheSilence() throws {
        let env = ["CANDOR_R1504_OFF": "1"]
        let ext = try scan(extended: true, env: env)
        defer { try? FileManager.default.removeItem(at: ext.root) }
        for fn in ["e9Ctor", "e9Prop", "e9PropP", "e9Init", "e9SelfProp"] {
            XCTAssertFalse(inf(ext.rows, fn).contains("Fs"), "CANDOR_R1504_OFF restores b6452a0: \(fn): \(ext.rows[fn] ?? [:])")
        }
    }
}

/// SOUNDNESS R1498 / R1492 residuals and R1505 — three receiver-typing gaps on the same `T.eff()` call (executed,
/// `swiftagent-vein/fx/T`): `for (a, _) in xs` / `for t in xs` over `xs: [(Loud, Int)]`; a field's written GENERIC
/// ARGUMENT (`var gen: Box<Loud>`) read from `extension A.B.T`; an UNANNOTATED array-literal stored property
/// (`var arr2 = [Loud()]`). Controls: the same bodies over a pure slot / a same-named `Z.T` holding `Quiet`.
final class LoopTupleAndFieldElementProcessTests: XCTestCase {
    private static let src = """
    import Foundation
    struct Loud { func eff() { _ = FileManager.default.fileExists(atPath: "/tmp") } }
    struct Quiet { func eff() { } }
    struct Box<V> { var v: V }
    enum A { enum B { struct T { var gen: Box<Loud> = Box(v: Loud()); var arr2 = [Loud()] } } }
    enum Z { struct T { var gen: Box<Quiet> = Box(v: Quiet()); var arr2 = [Quiet()]; var mixed = [Loud(), Quiet()] } }
    extension A.B.T { func cGen() { gen.v.eff() }; func cArr2() { for x in arr2 { x.eff() } } }
    extension Z.T { func kGen() { gen.v.eff() }; func kArr2() { for x in arr2 { x.eff() } }; func kMixed() { for x in mixed { _ = x } } }
    func tForIn(_ xs: [(Loud, Int)]) { for (a, _) in xs { a.eff() } }
    func tForIn2(_ xs: [(Int, Loud)]) { for (_, b) in xs { b.eff() } }
    func tForLab(_ xs: [(a: Loud, n: Int)]) { for t in xs { t.a.eff() } }
    func tForLocal() { let xs: [(Loud, Int)] = [(Loud(), 1)]; for (a, _) in xs { a.eff() } }
    func kForIn(_ xs: [(Quiet, Loud)]) { for (a, _) in xs { a.eff() } }
    """
    private static let charged: [(fn: String, sw: String)] = [
        ("A.B.T.cGen", "CANDOR_R1492F_OFF"), ("A.B.T.cArr2", "CANDOR_R1505_OFF"), ("tForIn", "CANDOR_R1498F_OFF"),
        ("tForIn2", "CANDOR_R1498F_OFF"), ("tForLab", "CANDOR_R1498F_OFF"), ("tForLocal", "CANDOR_R1498F_OFF")]
    private static let controls = ["Z.T.kGen", "Z.T.kArr2", "Z.T.kMixed", "kForIn"]

    private func scan(_ env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        return try ProcessHarness.fns(ofJson: r.out)
    }

    func testEachShapeIsChargedAndControlsStayPure() throws {
        let by = try scan()
        for c in Self.charged { XCTAssertEqual(ProcessHarness.inferred(by, c.fn), ["Fs"], "\(c.fn) writes the marker (executed) — \(by[c.fn] ?? [:])") }
        for k in Self.controls { XCTAssertNil(ProcessHarness.inferred(by, k), "CONTROL \(k): \(by[k] ?? [:])") }
    }

    func testEachKillSwitchRestoresItsSilence() throws {
        for sw in Set(Self.charged.map(\.sw)).sorted() {
            let by = try scan([sw: "1"])
            for c in Self.charged where c.sw == sw { XCTAssertNil(ProcessHarness.inferred(by, c.fn), "\(sw): \(c.fn) — \(by[c.fn] ?? [:])") }
        }
    }
}
