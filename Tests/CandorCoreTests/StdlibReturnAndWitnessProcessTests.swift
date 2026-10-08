import XCTest
import Foundation
import CandorCore

/// SOUNDNESS R1032, R1009, R1010, R1044, R1045, R1046 and R905's residual — six questions the stdlib or the
/// platform answers and this engine had answered from a table that did not have the row.
///
/// Each fixture below was EXECUTED before it was written down (`swiftagent-v042/fx/…`): the effectful arm
/// deleted its victim file, the control arm kept it. Every arm here is ONE variable against its control, and
/// every fix has a §1b kill switch whose arm restores the release reading, so the test shows the change is
/// what moved the row (not a neighbouring arm).
///
/// Harness note (R706): under `swift test` the manifest peek can leave a non-violating gate at exit 2, so a
/// must-PASS gate is asserted `!= 1` and a must-FAIL gate `== 1`.
final class StdlibReturnAndWitnessProcessTests: XCTestCase {
    private static let FS = "try? FileManager.default.removeItem(atPath: \"/nonexistent/candor-v042\")"

    private func scan(_ src: String, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        return try ProcessHarness.fns(ofJson: r.out)
    }
    private func gate(_ src: String, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let pf = root.appendingPathComponent("p.policy")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
    }
    private func inf(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["inferred"] as? [String] ?? []).sorted()
    }
    private func why(_ by: [String: [String: Any]], _ fn: String) -> [String] {
        (by[fn]?["unknownWhy"] as? [String] ?? []).sorted()
    }

    // ── R1032 — `randomElement()` / `shuffled()` / `shuffle()` draw entropy ─────────────────────────────
    static let rand = """
    import Foundation
    func pickOne() -> Int { [1, 2, 3].randomElement() ?? 0 }
    func mixAll() -> [Int] { [1, 2, 3].shuffled() }
    func mixInPlace() { var a = [1, 2, 3]; a.shuffle(); print(a) }
    func rangeRand() -> Int? { (0..<10).randomElement() }
    func untyped(_ xs: [String]) -> String? { let ys = xs; return ys.randomElement() }
    struct Ring: RandomAccessCollection { var startIndex: Int { 0 }; var endIndex: Int { 3 }; subscript(i: Int) -> Int { i } }
    func inheritedRand() -> Int? { Ring().randomElement() }
    struct Deck { var cards = [1, 2, 3]; mutating func shuffle() { cards.reverse() } }
    func ownShuffle() { var d = Deck(); d.shuffle(); print(d.cards) }
    func plainFirst() -> Int? { [1, 2, 3].first }
    """
    func testCollectionEntropyMembersAreRand() throws {
        let by = try scan(Self.rand)
        for f in ["pickOne", "mixAll", "mixInPlace", "rangeRand", "untyped", "inheritedRand"] {
            XCTAssertEqual(inf(by, f), ["Rand"], "R1032: \(f) draws entropy; got \(by[f] ?? [:])")
        }
        // THE CONTROLS: a type that DECLARES its own `shuffle()` answers with its own body (here pure), and a
        // non-drawing member is not charged.
        XCTAssertNil(ProcessHarness.chargedNothing(by, "ownShuffle"), "R1032: Deck.shuffle is the project's own")
        XCTAssertNil(ProcessHarness.chargedNothing(by, "plainFirst"), "R1032: `first` draws nothing")
        XCTAssertEqual(try gate(Self.rand, "deny Rand mixAll"), 1, "R1032: the gate must see the draw")
        let off = try scan(Self.rand, env: ["CANDOR_R1032_OFF": "1"])
        XCTAssertNil(ProcessHarness.chargedNothing(off, "mixAll"), "kill switch restores the release reading")
    }

    // ── R1009 — an `@autoclosure` argument is the CALLER's expression ──────────────────────────────────
    static let autoclosure = """
    import Foundation
    enum Result2 { case ok, fail(String)
      static func failing(reason make: @autoclosure () -> String) -> Result2 { .fail(make()) } }
    func qualified() -> Result2 { Result2.failing(reason: "x") }
    func implicit() -> Result2 { .failing(reason: "x") }
    func effArg() -> Result2 { .failing(reason: (try? String(contentsOfFile: "/etc/hosts")) ?? "") }
    func plainCallback(_ f: () -> String) -> String { f() }
    """
    func testAnAutoclosureArgumentIsNotAnOpaqueCallback() throws {
        let by = try scan(Self.autoclosure)
        for f in ["Result2.failing", "qualified", "implicit"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, f), "R1009: \(f) evaluates a string literal; got \(by[f] ?? [:])")
        }
        // THE EFFECT STILL ARRIVES: the argument expression is walked in the caller.
        XCTAssertEqual(inf(by, "effArg"), ["Fs"], "R1009: the caller's own expression is charged to the caller")
        // THE CONTROL: an ordinary fn-typed parameter with no visible caller keeps its `callback:` hedge.
        XCTAssertEqual(why(by, "plainCallback"), ["callback:f"], "a real callback keeps its disclosure")
        let off = try scan(Self.autoclosure, env: ["CANDOR_R1009_OFF": "1"])
        XCTAssertEqual(why(off, "qualified"), ["callback:make"], "kill switch restores the release reading")
    }

    // ── R1010 / R1044 — `func pick<T>(_ x: T) -> T` returns its ARGUMENT's type ─────────────────────────
    static let pickFab = """
    import Foundation
    struct T { func go() -> Int { \(FS); return 0 } }
    struct U { func go() -> Int { 1 } }
    func pick<T>(_ x: T) -> T { x }
    func useChain() -> Int { pick(U()).go() }
    func useLet() -> Int { let u = pick(U()); return u.go() }
    """
    static let pickSilent = """
    import Foundation
    struct E { func go() -> Int { \(FS); return 0 } }
    func pick<T>(_ x: T) -> T { x }
    func useChainE() -> Int { pick(E()).go() }
    func useLetE() -> Int { let u = pick(E()); return u.go() }
    """
    func testAGenericReturnIsItsArgumentNotATypeSpelledT() throws {
        let fab = try scan(Self.pickFab)
        for f in ["useChain", "useLet"] {
            XCTAssertNil(ProcessHarness.chargedNothing(fab, f), "R1010: \(f) runs U.go, not T.go; got \(fab[f] ?? [:])")
        }
        // THE SECOND FIXTURE, WRITTEN FIRST (the fabrication-fix rule): the same shape over an effectful
        // argument must be CHARGED, or poisoning the leaf has only moved the defect to silence.
        let sil = try scan(Self.pickSilent)
        for f in ["useChainE", "useLetE"] {
            XCTAssertEqual(inf(sil, f), ["Fs"], "R1044: \(f) runs E.go; got \(sil[f] ?? [:])")
        }
        XCTAssertEqual(try gate(Self.pickSilent, "deny Fs useChainE"), 1, "R1044: the gate must flip")
        let off = try scan(Self.pickSilent, env: ["CANDOR_R1044_OFF": "1"])
        XCTAssertNil(ProcessHarness.chargedNothing(off, "useChainE"), "R1044 kill switch restores the release silence")
        let offFab = try scan(Self.pickFab, env: ["CANDOR_R1010_OFF": "1", "CANDOR_R1044_OFF": "1"])
        XCTAssertEqual(inf(offFab, "useChain"), ["Fs"], "R1010 kill switch restores the release fabrication")
    }

    // ── R1045 — `a.hash(into:)` / `h.combine(a)` on a generic parameter run the CALLER's witness ────────
    static let hashing = """
    import Foundation
    struct Noisy: Hashable {
      let v: Int
      static func == (a: Noisy, b: Noisy) -> Bool { a.v == b.v }
      func hash(into h: inout Hasher) { \(FS); h.combine(v) }
    }
    struct Plain: Hashable { let v: Int }
    func bucket<T: Hashable>(_ a: T) -> Int { var h = Hasher(); a.hash(into: &h); return h.finalize() }
    func mix<T: Hashable>(_ a: T) -> Int { var h = Hasher(); h.combine(a); return h.finalize() }
    func viaBucket() -> Int { bucket(Noisy(v: 1)) }
    func viaMix() -> Int { mix(Noisy(v: 1)) }
    func viaPlain() -> Int { bucket(Plain(v: 1)) }
    """
    func testAGenericHashCallRunsTheCallersWitness() throws {
        let by = try scan(Self.hashing)
        XCTAssertEqual(inf(by, "viaBucket"), ["Fs"], "R1045: hash(into:) on T runs Noisy.hash; got \(by["viaBucket"] ?? [:])")
        XCTAssertEqual(inf(by, "viaMix"), ["Fs"], "R1045: Hasher.combine(T) runs Noisy.hash; got \(by["viaMix"] ?? [:])")
        XCTAssertNil(ProcessHarness.chargedNothing(by, "viaPlain"), "R1045: a synthesized pure witness charges nothing")
        let off = try scan(Self.hashing, env: ["CANDOR_R1045_OFF": "1"])
        XCTAssertNil(ProcessHarness.chargedNothing(off, "viaBucket"), "kill switch restores the release silence")
    }

    // ── R1046 — an explicitly specialised constructor is the constructor, not a computed callee ─────────
    static let specialised = """
    import Foundation
    struct Box<T> { var v: T }
    struct LoudBox<T> { var v: T; init(v: T) { self.v = v; \(FS) } }
    func a1() -> [Int] { Array<Int>() }
    func a3() -> Box<Int> { Box<Int>(v: 1) }
    func a4() -> NSCache<NSString, NSString> { NSCache<NSString, NSString>() }
    func a7() -> LoudBox<Int> { LoudBox<Int>(v: 1) }
    """
    func testAnExplicitlySpecialisedConstructorIsResolved() throws {
        let by = try scan(Self.specialised)
        for f in ["a1", "a3", "a4"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, f), "R1046: \(f) constructs a pure value; got \(by[f] ?? [:])")
        }
        XCTAssertEqual(inf(by, "a7"), ["Fs"], "R1046: LoudBox<Int>(v:) runs LoudBox.init; got \(by["a7"] ?? [:])")
        let off = try scan(Self.specialised, env: ["CANDOR_R1046_OFF": "1"])
        XCTAssertEqual(why(off, "a1"), ["callback:computed"], "kill switch restores the release hedge")
    }

    // ── R905 (residual) — the rest of the platform's generic-container returns ─────────────────────────
    static let platform = """
    import Foundation
    final class G { func go() { \(FS) } }
    final class Holder {
      let cache = NSCache<NSString, G>()
      let table = NSHashTable<G>.weakObjects()
      let tableA: NSHashTable<G> = .weakObjects()
      let map = NSMapTable<NSString, G>.strongToStrongObjects()
      func viaCache() { cache.object(forKey: "k")?.go() }
      func viaMap() { map.object(forKey: "k")?.go() }
      func viaHash() { table.anyObject?.go() }
      func viaHashA() { tableA.anyObject?.go() }
      func viaHashMember() { table.member(table.anyObject)?.go() }
      func viaLocal() { let t = NSHashTable<G>(options: .strongMemory); t.anyObject?.go() }
      func viaLocalF() { let t = NSHashTable<G>.weakObjects(); t.anyObject?.go() }
      func viaLocalCache() { let c = NSCache<NSString, G>(); c.object(forKey: "k")?.go() }
      func countOnly() -> Int { table.count }
    }
    """
    func testPlatformGenericContainerReturnsReachTheElement() throws {
        let by = try scan(Self.platform)
        for f in ["viaCache", "viaMap", "viaHash", "viaHashA", "viaHashMember", "viaLocal", "viaLocalF", "viaLocalCache"] {
            XCTAssertEqual(inf(by, "Holder.\(f)"), ["Fs"], "R905: Holder.\(f) runs G.go; got \(by["Holder.\(f)"] ?? [:])")
        }
        XCTAssertNil(ProcessHarness.chargedNothing(by, "Holder.countOnly"), "R905: `count` is not the element")
        XCTAssertEqual(try gate(Self.platform, "deny Fs Holder.viaHash"), 1, "R905: the gate must flip")
        let off = try scan(Self.platform, env: ["CANDOR_R905H_OFF": "1"])
        XCTAssertNil(ProcessHarness.chargedNothing(off, "Holder.viaHash"), "kill switch restores the release silence")
    }

    // ── R1047 — an init this scan only ADDS to a platform type is not every constructor of that type ─────
    static let extInit = """
    import Foundation
    extension String {
        init(randomAlphaNumericOfLength length: Int) { self = String((0..<length).map { _ in "ab".randomElement()! }) }
        init(joining parts: String...) { \(FS); self = parts.joined() }
        init(_ n: Int, loud: Bool) { \(FS); self = "\\(n)" }
    }
    func viaLabel() -> String { String(randomAlphaNumericOfLength: 3) }
    func viaDescribing(_ x: Int) -> String { String(describing: x) }
    func viaBare(_ x: Int) -> String { String(x) }
    func viaCString(_ p: UnsafePointer<CChar>) -> String { String(cString: p) }
    func viaVariadic() -> String { String(joining: "a", "b", "c") }
    func viaTwo() -> String { String(3, loud: true) }
    func viaLiteral() -> String { let m: String = "x"; return m }
    extension String { init(_errorCorrecting p: UnsafePointer<CChar>) { self.init(cString: p) } }
    func viaSelfInit(_ p: UnsafePointer<CChar>) -> String { String(_errorCorrecting: p) }
    struct Tag: ExpressibleByStringLiteral { init(stringLiteral v: String) { \(FS) } }
    func viaTagLiteral() { let _: Tag = "t" }
    """
    func testAnExtensionInitAnswersOnlyTheLabelsItDeclares() throws {
        let by = try scan(Self.extInit)
        XCTAssertEqual(inf(by, "viaLabel"), ["Rand"], "R1047: the declared init still runs; got \(by["viaLabel"] ?? [:])")
        XCTAssertEqual(inf(by, "viaVariadic"), ["Fs"], "R1047: a variadic init absorbs its unlabelled arguments")
        XCTAssertEqual(inf(by, "viaTwo"), ["Fs"], "R1047: `_` then `loud:` is matched in order")
        XCTAssertEqual(inf(by, "viaTagLiteral"), ["Fs"], "R1047: a literal still coerces through a declared literal init")
        for f in ["viaDescribing", "viaBare", "viaCString", "viaLiteral", "viaSelfInit"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, f), "R1047: \(f) runs the stdlib's init; got \(by[f] ?? [:])")
        }
        let off = try scan(Self.extInit, env: ["CANDOR_R1047_OFF": "1"])
        XCTAssertFalse(inf(off, "viaCString").isEmpty, "kill switch restores the release fabrication")
    }

    // ── R1048 — a hand-written `next()` runs wherever the stdlib iterates the value ─────────────────────
    static let iteration = """
    import Foundation
    struct Loud: Sequence, IteratorProtocol {
        var n = 0
        mutating func next() -> Int? { \(FS); n += 1; return n > 2 ? nil : n }
    }
    struct LoudColl: Sequence { func makeIterator() -> Loud { Loud() } }
    struct Quiet: Sequence, IteratorProtocol { var n = 0; mutating func next() -> Int? { n += 1; return n > 2 ? nil : n } }
    struct OwnMap: Sequence, IteratorProtocol {
        mutating func next() -> Int? { \(FS); return nil }
        func map(_ f: (Int) -> Int) -> [Int] { [] }
    }
    func genericSum<S: Sequence>(_ s: S) -> Int where S.Element == Int { var t = 0; for x in s { t += x }; return t }
    func someSum(_ s: some Sequence<Int>) -> Int { var t = 0; for x in s { t += x }; return t }
    func anySum(_ s: any Sequence<Int>) -> Int { var t = 0; for x in s { t += x }; return t }
    func viaGeneric() -> Int { genericSum(Loud()) }
    func viaSome() -> Int { someSum(LoudColl()) }
    func viaAny() -> Int { anySum(Loud()) }
    func viaForInColl() -> Int { var t = 0; for x in LoudColl() { t += x }; return t }
    func viaReduce() -> Int { Loud().reduce(0, +) }
    func viaMap() -> [Int] { Loud().map { $0 } }
    func viaArrayInit() -> [Int] { Array(Loud()) }
    func viaContains() -> Bool { Loud().contains(2) }
    func quietGeneric() -> Int { genericSum(Quiet()) }
    func quietReduce() -> Int { Quiet().reduce(0, +) }
    func arraySum() -> Int { genericSum([1, 2, 3]) }
    func ownMap() -> [Int] { OwnMap().map { $0 } }
    """
    func testAHandWrittenIteratorRunsWhereverTheStdlibIterates() throws {
        let by = try scan(Self.iteration)
        for f in ["viaGeneric", "viaSome", "viaAny", "viaForInColl", "viaReduce", "viaMap", "viaArrayInit", "viaContains"] {
            XCTAssertEqual(inf(by, f), ["Fs"], "R1048: \(f) iterates Loud.next; got \(by[f] ?? [:])")
        }
        // THE OVER-CHARGE CONTROLS: a pure iterator, a stdlib array through the same generic, and a type whose
        // OWN `map` answers (it never iterates) — none is charged.
        for f in ["quietGeneric", "quietReduce", "arraySum", "ownMap"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, f), "R1048: \(f) runs no effectful next(); got \(by[f] ?? [:])")
        }
        XCTAssertEqual(try gate(Self.iteration, "deny Fs viaGeneric"), 1, "R1048: the gate must flip")
        let off = try scan(Self.iteration, env: ["CANDOR_R1048_OFF": "1"])
        XCTAssertNil(ProcessHarness.chargedNothing(off, "viaGeneric"), "kill switch restores the release silence")
    }

    // ── R706 (residual) — a member call through an explicit protocol spelling of a BLIND dependency ─────
    // One package whose manifest declares a dependency it has not fetched, so `Iface` is uncovered. The free
    // call is the control the member call must now match.
    func testAProtocolSpelledReceiverOfABlindDependencyIsAttributed() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r706i-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Sources/Mid")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.7
        import PackageDescription
        let package = Package(name: "Mid", dependencies: [.package(path: "../Iface")],
            targets: [.target(name: "Mid", dependencies: ["Iface"])])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Foundation
        import Iface
        public func viaAny(_ s: any Sink) { s.emit() }
        public func viaGen<T: Sink>(_ s: T) { s.emit() }
        public func viaSome(_ s: some Sink) { s.emit() }
        public func viaFree() { sinkAll() }
        public func viaEncoder(_ e: any Encoder) { _ = e.singleValueContainer() }
        public func viaClock() -> Date { Date() }
        """.write(to: src.appendingPathComponent("Mid.swift"), atomically: true, encoding: .utf8)
        func run(_ env: [String: String]) throws -> [String: [String: Any]] {
            try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"], env: env).out)
        }
        let by = try run([:])
        XCTAssertEqual(by["viaFree"]?["invisible"] as? [String], ["Iface"], "the free-call CONTROL")
        for f in ["viaAny", "viaGen", "viaSome"] {
            XCTAssertEqual(by[f]?["invisible"] as? [String], ["Iface"],
                           "R706: \(f) dispatches into the blind module, attributed like the free call; got \(by[f] ?? [:])")
        }
        XCTAssertNil(by["viaEncoder"]?["invisible"], "a PLATFORM protocol receiver is never attributed to Iface")
        XCTAssertNil(by["viaClock"]?["invisible"], "a platform call in the same file is never attributed to Iface")
        let off = try run(["CANDOR_R706I_OFF": "1"])
        XCTAssertNil(off["viaAny"]?["invisible"], "kill switch restores the release silence")
    }

    // ── §E3 — every fixture compiles, and the platform tables are the SDK's, not this file's ───────────
    func testEveryFixtureAndPlatformTableTypechecks() throws {
        var probes = ""
        for (k, idx) in PLATFORM_GENERIC_MEMBER_RETURNS.sorted(by: { $0.key < $1.key }) {
            let owner = String(k.prefix { $0 != "." }), m = String(k.drop { $0 != "." }.dropFirst())
            let decl = owner == "NSHashTable" ? "NSHashTable<P0>()" : "\(owner)<P0, P1>()"
            let call = m == "object" ? "object(forKey: P\(1 - idx)())" : "\(m)(P0())"
            probes += "func probe_\(owner)_\(m)() { let r: P\(idx)? = \(decl).\(call); _ = r }\n"
        }
        for (k, idx) in PLATFORM_GENERIC_PROPERTY_RETURNS.sorted(by: { $0.key < $1.key }) {
            let owner = String(k.prefix { $0 != "." }), m = String(k.drop { $0 != "." }.dropFirst())
            probes += "func probe_\(owner)_\(m)() { let r: P\(idx)? = \(owner)<P0>().\(m); _ = r }\n"
        }
        for (owner, fs) in PLATFORM_GENERIC_SELF_FACTORIES.sorted(by: { $0.key < $1.key }) {
            for f in fs.sorted() {
                let spec = owner == "NSHashTable" ? "\(owner)<P0>" : "\(owner)<P0, P1>"
                probes += "func probe_\(owner)_\(f)() { let r: \(spec) = \(spec).\(f)(); _ = r }\n"
            }
        }
        let tables = "import Foundation\nfinal class P0: NSObject {}\nfinal class P1: NSObject {}\n" + probes
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-v042-tc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var fixtures = [("rand", Self.rand), ("autoclosure", Self.autoclosure), ("pickFab", Self.pickFab),
                        ("pickSilent", Self.pickSilent), ("hashing", Self.hashing),
                        ("specialised", Self.specialised), ("extInit", Self.extInit), ("iteration", Self.iteration)]
        // `NSHashTable`/`NSMapTable` exist only in Apple's Foundation — swift-corelibs-foundation on Linux
        // has neither, so the platform fixture and the SDK-pinned tables can only be typechecked against
        // the SDK the tables were derived from. Measured: the linux CI leg failed on exactly these two.
        #if canImport(Darwin)
        fixtures += [("platform", Self.platform), ("tables", tables)]
        #endif
        for (name, src) in fixtures {
            let f = root.appendingPathComponent("\(name).swift")
            try src.write(to: f, atomically: true, encoding: .utf8)
            let r = try ProcessHarness.run(URL(fileURLWithPath: "/usr/bin/env"), ["swiftc", "-typecheck", f.path])
            if r.code != 0, r.err.contains("env: swiftc") { throw XCTSkip("no swiftc on this host") }
            XCTAssertEqual(r.code, 0, "FIXTURE \(name) MUST COMPILE (§E3); stderr:\n\(r.err)")
        }
    }
}
