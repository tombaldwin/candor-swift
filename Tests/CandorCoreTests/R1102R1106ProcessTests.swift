import XCTest
import Foundation

/// SOUNDNESS R1102, R1104, R1105, R1106 — found by the 73-package census over released 0.40.4.
///
/// Every READ/WRITE verdict below was EXECUTED (`swiftagent-v046/fx/acc`, `acc3`, `shadow`, `vh`): the property's
/// observer / setter / the shadowed global writes a marker file, and the marker was observed (or not) after
/// calling each function alone. A read row must leave `functions[]` (pure); a write row must keep `Fs`.
final class R1102R1106ProcessTests: XCTestCase {
    private func rows(_ files: [String: String], name: String = "App", env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let root = try ProcessHarness.makeFilesPackage(files, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        return try ProcessHarness.fns(ofJson: r.out)
    }
    private func inferred(_ rows: [String: [String: Any]], _ fn: String) -> [String] {
        (rows[fn]?["inferred"] as? [String]) ?? []
    }

    // ── R1105 (a) — an observer runs on a WRITE, never on a read ─────────────────────────────────────────────
    static let observed = #"""
import Foundation
func hit() { FileManager.default.createFile(atPath: "/tmp/r1105", contents: nil) }
extension String { func shout() -> String { uppercased() } }   // Whisky: `String` is EXTENDED here, still the platform's
infix operator <~ : AssignmentPrecedence
func <~ (lhs: inout Int, rhs: Int) { lhs = rhs }
protocol Bumpable {}
extension Bumpable { mutating func bump2() {} }
struct Inner: Bumpable {
  var tag: String = "x"; var n = 0; var list: [Int] = []
  mutating func bump() { list.append(1) }
  func peek() -> Int { list.count }
}
final class Box { var v = 0 }
struct Val { var n = 0; var box = Box() }
final class Obs: Hashable {
  var settings: Inner = Inner() { didSet { hit() } }
  var o: Inner? = Inner() { willSet { hit() } }
  var val: Val = Val() { didSet { hit() } }
  static func == (a: Obs, b: Obs) -> Bool { a.settings.tag == b.settings.tag }
  func hash(into h: inout Hasher) { h.combine(settings.tag) }
  static func < (a: Obs, b: Obs) -> Bool { a.settings.tag.lowercased() < b.settings.tag.lowercased() }
  func readPeek() -> Int { settings.peek() }
  func readPass() -> Int { take(settings) }
  func readSelf() -> String { self.settings.tag }
  func readLoop() -> Int { var t = 0; for x in settings.list { t += x }; return t }
  func readTernary() -> Int { settings.n > 0 ? settings.n : -settings.n }
  func readClosure() -> Int { let f = { self.settings.n }; return f() }
  func readOpt() -> String? { o?.tag }
  func readClassHop() -> Int { val.box.v }
  func writeAssign() { settings = Inner() }
  func writeMember() { settings.tag = "y" }
  func writeCompound() { settings.tag += "z" }
  func writePlatformMutating() { settings.list.append(2) }
  func writeLocalMutating() { settings.bump() }
  func writeProtoExtMutating() { settings.bump2() }
  func writeInout() { poke(&settings) }
  func writeTuple() { (settings.tag, settings.n) = ("a", 1) }
  func writeCustomOp() { settings.n <~ 5 }
  func writeSubscript() { settings.list[0] = 2 }
  func writeOptChain() { o?.tag = "q" }
  func writeClosure() { let f = { self.settings.n = 2 }; f() }
}
func take(_ i: Inner) -> Int { i.list.count }
func poke(_ i: inout Inner) { i.tag = "p" }
func extRead(_ x: Obs) -> String { x.settings.tag }
func extWrite(_ x: Obs) { x.settings.list.append(3) }
"""#

    func testAnObserverIsChargedToWritesOnly() throws {
        let r = try rows(["a.swift": Self.observed])
        for fn in ["Obs.==", "Obs.hash", "Obs.<", "Obs.readPeek", "Obs.readPass", "Obs.readSelf", "Obs.readLoop",
                   "Obs.readTernary", "Obs.readClosure", "Obs.readOpt", "Obs.readClassHop", "extRead"] {
            XCTAssertFalse(inferred(r, fn).contains("Fs"), "\(fn) only READS; no observer runs (executed): \(r[fn] ?? [:])")
        }
        for fn in ["Obs.writeAssign", "Obs.writeMember", "Obs.writeCompound", "Obs.writePlatformMutating",
                   "Obs.writeLocalMutating", "Obs.writeProtoExtMutating", "Obs.writeInout", "Obs.writeTuple",
                   "Obs.writeCustomOp", "Obs.writeSubscript", "Obs.writeOptChain", "Obs.writeClosure", "extWrite"] {
            XCTAssertTrue(inferred(r, fn).contains("Fs"), "\(fn) WRITES; the observer runs (executed): \(r[fn] ?? [:])")
        }
        // the union unit, the key a writer and a dependent consumer join on, is unchanged
        XCTAssertEqual(inferred(r, "Obs.settings"), ["Fs"])
        let off = try rows(["a.swift": Self.observed], env: ["CANDOR_R1105_OFF": "1"])
        XCTAssertTrue(inferred(off, "Obs.==").contains("Fs"), "kill switch restores the release's union edge")
    }

    // ── R1106 — a getter and a setter are different code ─────────────────────────────────────────────────────
    func testAReadRunsTheGetterAndNotTheSetter() throws {
        let r = try rows(["a.swift": #"""
import Foundation
func hit() { FileManager.default.createFile(atPath: "/tmp/r1106", contents: nil) }
struct GS {
  var store = 0
  var p: Int { get { store } set { hit(); store = newValue } }
  var q: Int { get { hit(); return store } set { store = newValue } }
  func readP() -> Int { p }
  mutating func writeP() { p = 3 }
  func readQ() -> Int { q }
  func passQ() -> Int { id(q) }
}
func id(_ x: Int) -> Int { x }
"""#])
        XCTAssertFalse(inferred(r, "GS.readP").contains("Fs"), "executed pure: \(r["GS.readP"] ?? [:])")
        XCTAssertEqual(inferred(r, "GS.writeP"), ["Fs"])
        XCTAssertEqual(inferred(r, "GS.readQ"), ["Fs"], "an effectful GETTER still reaches its reader")
        XCTAssertEqual(inferred(r, "GS.passQ"), ["Fs"], "…by the argument spelling too")
        XCTAssertEqual(inferred(r, "GS.q.<get>"), ["Fs"], "the getter view is a real unit, so `calls` stays transitive")
    }

    // TCA `PresentationState.hash`: `self.wrappedValue.hash(into:)` over a generic `State?` reads the getter only.
    func testHashingAGetSetPropertyRunsItsGetter() throws {
        let r = try rows(["main.swift": #"""
struct PS<State: Hashable>: Hashable {
  final class Storage { var state: State?; init(_ s: State?) { state = s } }
  private var storage: Storage
  init(_ s: State?) { storage = Storage(s) }
  var wrappedValue: State? {
    get { storage.state }
    set { _ = Int.random(in: 0...9); storage = Storage(newValue) }
  }
  static func == (l: Self, r: Self) -> Bool { l.wrappedValue == r.wrappedValue }
  func hash(into hasher: inout Hasher) { self.wrappedValue.hash(into: &hasher) }
  mutating func reset() { wrappedValue = nil }
}
"""#])
        XCTAssertNil(r["PS.hash"], "executed: the setter's Rand never runs: \(r["PS.hash"] ?? [:])")
        XCTAssertNil(r["PS.=="])
        XCTAssertEqual(inferred(r, "PS.reset"), ["Rand"], "CONTROL: a write runs the setter")
    }

    // ── R1105 (c) — a member shadows a same-named global; an EXTENDED type's witness is not synthesized ─────────
    func testAFieldShadowsASameNamedGlobal() throws {
        let r = try rows(["g.swift": #"""
import Foundation
let package: String = { FileManager.default.createFile(atPath: "/tmp/r1105c", contents: nil); return "" }()
func start() -> Int { FileManager.default.createFile(atPath: "/tmp/r1105c", contents: nil); return 1 }
"""#, "main.swift": #"""
struct C: Hashable {
  var package: String = "p"
  var start: Int = 0
  func hash(into h: inout Hasher) { h.combine(package) }
  func useArg() -> Int { id(start) }
  func useRet() -> String { package }
  func useOp() -> Bool { package == "x" }
}
struct D { func readsGlobal() -> String { package }; func callsFree() -> Int { id(start()) } }
func id(_ x: Int) -> Int { x }
"""#])
        for fn in ["C.hash", "C.useArg", "C.useRet", "C.useOp"] {
            XCTAssertNil(r[fn], "\(fn) reads its own field (executed pure): \(r[fn] ?? [:])")
        }
        XCTAssertEqual(inferred(r, "D.readsGlobal"), ["Fs"], "CONTROL: no field — the bare name IS the global")
        XCTAssertEqual(inferred(r, "D.callsFree"), ["Fs"], "CONTROL: a call of the free function")
    }

    func testAnExtendedPlatformTypeHashesWithItsOwnWitness() throws {
        let r = try rows(["a.swift": #"""
import Foundation
enum Frag: Hashable {
  case a(String)
  func hash(into h: inout Hasher) { FileManager.default.createFile(atPath: "/tmp/r1105v", contents: nil) }
}
protocol FragConv { var frag: Frag? { get } }
extension String: FragConv { var frag: Frag? { .a(self) } }
struct MT: Hashable {
  var type: String
  func hash(into hasher: inout Hasher) { self.type.hash(into: &hasher) }
}
struct Holder: Hashable { var f: Frag }
func hashHolder(_ h: Holder) -> Int { h.hashValue }
func combineHolder(_ h: Holder) { var x = Hasher(); x.combine(h) }
"""#])
        XCTAssertFalse(inferred(r, "MT.hash").contains("Fs"), "String.hash(into:) is the platform's (executed pure): \(r["MT.hash"] ?? [:])")
        XCTAssertEqual(inferred(r, "combineHolder"), ["Fs"], "CONTROL: a DECLARED type's synthesized witness hashes its stored Frag")
    }

    // ── R1104 — a dependency that was never fetched ──────────────────────────────────────────────────────────
    func testAnUnfetchedDependencysTypeIsDisclosedPerFunction() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1104-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("Sources/Fx")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fx",
          dependencies: [.package(url: "https://github.com/apple/swift-collections.git", exact: "1.1.4")],
          targets: [.executableTarget(name: "Fx", dependencies: [.product(name: "OrderedCollections", package: "swift-collections")])])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try #"""
        import Foundation
        import OrderedCollections
        struct Box: Hashable { var k: Int }
        final class Holder {
          struct Storage { var coins: OrderedSet<Box> = [] }
          var storage = Storage()
          func viaProp(_ b: Box) -> Bool { storage.coins.append(b).inserted }
          func viaUpdate(_ b: Box) -> Bool { storage.coins.updateOrAppend(b) != nil }
          func viaContains(_ b: Box) -> Bool { storage.coins.contains(b) }
          func viaLocal(_ b: Box) -> Bool { var s: OrderedSet<Box> = []; return s.append(b).inserted }
          func platformOnly() -> String { "a".lowercased() }
        }
        struct Field: Hashable { var k: Int; func hash(into h: inout Hasher) { h.combine(k) } }
        """#.write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let by = try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"]).out)
        for f in ["Holder.viaProp", "Holder.viaUpdate", "Holder.viaContains", "Holder.viaLocal"] {
            XCTAssertEqual(by[f]?["invisible"] as? [String], ["OrderedCollections"], "\(f): \(by[f] ?? [:])")
        }
        XCTAssertNil(by["Holder.platformOnly"]?["invisible"], "a platform receiver is never attributed")
        XCTAssertNil(by["Field.hash"]?["invisible"], "a stored-field ARGUMENT reaches no package at all")
        let off = try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_R1104_OFF": "1"]).out)
        XCTAssertNil(off["Holder.viaProp"]?["invisible"], "kill switch restores the release silence")
    }

    // ── R1102 — a refusal's marker goes to the prefix the run was TOLD to write ───────────────────────────────
    func testARefusalMarksTheNamedOutPrefix() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1102-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("tree"), out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try "no swift here\n".write(to: tree.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        for argv in [[tree.path, "--out", out.appendingPathComponent("p").path],
                     ["--out", out.appendingPathComponent("p").path, tree.path]] {
            try? FileManager.default.removeItem(at: out)
            let r = try ProcessHarness.run(bin, argv)
            XCTAssertEqual(r.code, 2, "no Swift sources: unevaluable")
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("p.refused.json").path),
                          "\(argv): the marker belongs to the named prefix")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tree.appendingPathComponent(".candor").path),
                           "\(argv): nothing is written into the scanned tree")
        }
    }
}
