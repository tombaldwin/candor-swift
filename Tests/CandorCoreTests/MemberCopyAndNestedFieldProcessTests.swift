import XCTest
import Foundation

/// SOUNDNESS R1491 — `let r = l.w; r.eff()` read ABSENT over an executed file write while `l.w.eff()` and `if let r = l.w`
/// charged: the plain `let` binder typed a member-access copy (`l.w`, `self.w`, `l.w.v`, `Loc.sw`) as NOTHING — stored or
/// computed, generic or not.
///
/// SOUNDNESS R1492 — the calls R1486's kept `dispatch:` hedge was the only cover for in swift-crypto: a stored property
/// read from `extension A.B.T { … }` (the declaration is keyed `T`, the extension `A.B.T`), an owner NAME several types
/// share lending one type's member alias to all of them, a field typed by a generic parameter's ASSOCIATED type, and an
/// implicit `.init()` whose context is a generic parameter or local protocol; plus, exposed by its corpus A/B, a field type
/// spelled by a type nested in the declaring type, and `String(reflecting:)` on a type with only `description`. Every
/// program below was EXECUTED (markers: genLet getLet nomLet nomLet-v optLet staticLet storedLet; rsa-sign ml-init ml-sign
/// cursor reflect); the controls are pure.
final class MemberCopyAndNestedFieldProcessTests: XCTestCase {

    static let r1491Src = """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1491-" + s, contents: nil) }
public struct G<B> { public let b: B; public func eff() { mark("genLet") } }
public struct N { let tag: String; public func eff() { mark(tag) } ; public var v: N2 { N2(tag: tag + "-v") } }
public struct N2 { let tag: String; public func eff() { mark(tag) } }
public struct P { public func eff() { } ; public var q: P { P() } }
public final class Loc {
  public var gw: G<Int> { G(b: 1) }
  public var nw: N { N(tag: "nomLet") }
  public var nwGet: N { get { N(tag: "getLet") } }
  public let st: N = N(tag: "storedLet")
  public var opt: N? { N(tag: "optLet") }
  public var pw: P { P() }
  public let ps: P = P()
  public static var sw: N { N(tag: "staticLet") }
  func innerSelf() { let r = self.nw; r.eff() }
}
func cGenLet(_ l: Loc) { let r = l.gw; r.eff() }
func cNomLet(_ l: Loc) { let r = l.nw; r.eff() }
func cGetLet(_ l: Loc) { let r = l.nwGet; r.eff() }
func cStoredLet(_ l: Loc) { let r = l.st; r.eff() }
func cOptLet(_ l: Loc) { let r = l.opt; r?.eff() }
func cChainLet(_ l: Loc) { let r = l.nw.v; r.eff() }
func cStaticLet() { let r = Loc.sw; r.eff() }
func cVarLet(_ l: Loc) { var r = l.nw; r = l.nw; r.eff() }
func cLocalLoc() { let l = Loc(); let r = l.nw; r.eff() }
// controls: must stay pure
func kPureComputed(_ l: Loc) { let r = l.pw; r.eff() }
func kPureStored(_ l: Loc) { let r = l.ps; r.eff() }
func kPureChain(_ l: Loc) { let r = l.pw.q; r.eff() }
let l = Loc()
cGenLet(l); cNomLet(l); cGetLet(l); cStoredLet(l); cOptLet(l); cChainLet(l); cStaticLet(); cVarLet(l); cLocalLoc(); l.innerSelf()
kPureComputed(l); kPureStored(l); kPureChain(l)
"""

    static let r1492Files: [String: String] = [
        "Cursor.swift": """
// a field spelled by a type NESTED in its declaring type, read from a dotted extension, beside an unrelated top-level
// type of the same simple name (swift-syntax `Lexer.Cursor.position`)
typealias CharacterByte = UInt8
enum Lexer {}
extension Lexer { struct Cursor { var position: Position } }
extension Lexer.Cursor { struct Position { var n = 0 } }
extension Lexer.Cursor.Position {
  mutating func advance(matching c1: CharacterByte, _ c2: CharacterByte) -> Bool { mark("cursor"); return true }
}
extension Lexer.Cursor {
  mutating func advance(matching character1: CharacterByte, _ character2: CharacterByte) -> Bool {
    self.position.advance(matching: character1, character2)
  }
}
struct Position { func advance(matching a: UInt8, _ b: UInt8) -> Bool { true } }
""",
        "Impl.swift": """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1492-" + s, contents: nil) }
struct BoringPriv { func signature(for d: Int) -> Int { mark("rsa-sign"); return d } }
struct Quiet { func signature(for d: Int) -> Int { return d } }
public enum _RSA {}
extension _RSA { public enum Signing {} }
public enum Other { public enum Signing {} }
""",
        "MLDSA.swift": """
import Foundation
protocol KeyParams { associatedtype BackingKey: BackedKey }
protocol BackedKey { init() throws; func sign() -> Int }
enum ML65 {} ; enum ML87 {}
extension ML65 { struct InternalKey { init() throws { mark("ml-init") } ; func sign() -> Int { mark("ml-sign"); return 1 } } }
extension ML87 { struct InternalKey { init() throws { } ; func sign() -> Int { return 2 } } }
extension ML65: KeyParams { typealias BackingKey = ML65.InternalKey }
extension ML87: KeyParams { typealias BackingKey = ML87.InternalKey }
extension ML65.InternalKey: BackedKey {}
extension ML87.InternalKey: BackedKey {}
struct MLImpl<Parameters: KeyParams> {
  private var backing: Parameters.BackingKey
  init() throws { self.backing = try .init() }
  func sign() -> Int { self.backing.sign() }
}
// control: every conformer of the associated type's bound is pure
protocol QParams { associatedtype QK: QKey }
protocol QKey { init(); func go() -> Int }
enum QA: QParams { typealias QK = QAK }
struct QAK: QKey { init() {} ; func go() -> Int { 3 } }
struct QImpl<P: QParams> { var k: P.QK ; init() { self.k = .init() } ; func go() -> Int { k.go() } }
""",
        "OtherPK.swift": """
// a SECOND type with the same simple name and a same-named field of a PURE type: must stay pure
extension Other.Signing {
  public struct PrivateKey { private var backing: Quiet = Quiet() }
}
extension Other.Signing.PrivateKey {
  public func signature(for d: Int) -> Int { return self.backing.signature(for: d) }
}
public enum VOPRF { public struct Key {
  fileprivate typealias BackingPrivateKey = Quiet
  private var backing: BackingPrivateKey = Quiet()
  public func signature(for d: Int) -> Int { return self.backing.signature(for: d) }
} }
// a THIRD declaration of the alias name, nested in an owner that SHARES the simple name `PrivateKey`
public enum P384 { public enum _VOPRF { public struct PrivateKey {
  fileprivate typealias BackingPrivateKey = Quiet
  private var backing: BackingPrivateKey = Quiet()
  public func signature(for d: Int) -> Int { return self.backing.signature(for: d) }
} } }
""",
        "RSA.swift": """
fileprivate typealias BackingPrivateKey = BoringPriv
extension _RSA.Signing {
  public struct PrivateKey {
    private var backing: BackingPrivateKey
    var list: [BoringPriv] = [BoringPriv()]
    public init() { self.backing = BackingPrivateKey() }
  }
}
extension _RSA.Signing.PrivateKey {
  public func signature(for d: Int) -> Int { return self.backing.signature(for: d) }
  public func sigImplicit(for d: Int) -> Int { return backing.signature(for: d) }
  public func sigLet(for d: Int) -> Int { let b = self.backing; return b.signature(for: d) }
  public func sigList(for d: Int) -> Int { list.forEach { _ = $0.signature(for: d) }; return d }
}
""",
        "RSABlind.swift": """
fileprivate typealias BackingPrivateKey = BoringPriv
""",
        "Str.swift": """
// `String(reflecting:)` on a type with only `description` runs `description`; with both, only `debugDescription`
struct Cert: CustomStringConvertible { var description: String { mark("reflect"); return "c" } }
struct Both: CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { mark("both-desc"); return "d" }
  var debugDescription: String { "dd" }
}
struct Diag { var chain: [Cert]; var issuer: Cert; var both: Both
  var reflectIssuer: String { "\\(String(reflecting: issuer))" }
  var reflectChain: String { self.chain.lazy.map { String(reflecting: $0) }.joined() }
  var reflectBoth: String { String(reflecting: both) }
}
""",
        "main.swift": """
import Foundation
func rsaCaller() -> Int { _RSA.Signing.PrivateKey().signature(for: 1) }
func rsaImplicitCaller() -> Int { _RSA.Signing.PrivateKey().sigImplicit(for: 1) }
func rsaLetCaller() -> Int { _RSA.Signing.PrivateKey().sigLet(for: 1) }
func rsaListCaller() -> Int { _RSA.Signing.PrivateKey().sigList(for: 1) }
func otherCaller() -> Int { Other.Signing.PrivateKey().signature(for: 1) }
func voprfCaller() -> Int { VOPRF.Key().signature(for: 1) }
func mlInitCaller() throws { _ = try MLImpl<ML65>() }
func mlSignCaller(_ m: MLImpl<ML65>) -> Int { m.sign() }
func qCaller() -> Int { QImpl<QA>().go() }
_ = P384._VOPRF.PrivateKey().signature(for: 1); _ = rsaCaller(); _ = rsaImplicitCaller(); _ = rsaLetCaller(); _ = rsaListCaller(); _ = otherCaller(); _ = voprfCaller()
try mlInitCaller(); _ = mlSignCaller(try MLImpl<ML65>()); _ = qCaller()
func voprfPKCaller() -> Int { P384._VOPRF.PrivateKey().signature(for: 1) }
_ = voprfPKCaller()
func cursorCaller() -> Bool { var c = Lexer.Cursor(position: .init()); return c.advance(matching: 1, 2) }
func reflectCaller() -> String { Diag(chain: [], issuer: Cert(), both: Both()).reflectIssuer }
func reflectChainCaller() -> String { Diag(chain: [Cert()], issuer: Cert(), both: Both()).reflectChain }
func reflectBothCaller() -> String { Diag(chain: [], issuer: Cert(), both: Both()).reflectBoth }
_ = cursorCaller(); _ = reflectCaller(); _ = reflectChainCaller(); _ = reflectBothCaller()
"""
    ]

    private func scan(_ root: URL, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    private func gate(_ root: URL, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pol = root.appendingPathComponent("policy.candor")
        try policy.write(to: pol, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pol.path, "--out", root.appendingPathComponent("g").path],
                                      env: env).code
    }

    func testAMemberAccessCopyCarriesTheMembersType() throws {
        let root = try ProcessHarness.makePackage(Self.r1491Src)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        let charged = ["cGenLet", "cNomLet", "cGetLet", "cStoredLet", "cOptLet", "cChainLet", "cStaticLet", "cVarLet",
                       "cLocalLoc", "Loc.innerSelf"]
        for fn in charged {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes a marker (executed) — \(by[fn] ?? [:])")
        }
        for fn in ["kPureComputed", "kPureStored", "kPureChain"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, fn), "\(fn) is pure (control)")
        }
        let off = try scan(root, env: ["CANDOR_R1491_OFF": "1"])
        for fn in charged { XCTAssertNil(ProcessHarness.inferred(off, fn), "the release was silent on \(fn)") }
        XCTAssertEqual(try gate(root, "deny Fs cGenLet\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs cGenLet\n", env: ["CANDOR_R1491_OFF": "1"]), 0)
        XCTAssertEqual(try gate(root, "deny Fs kPureComputed\n"), 0)
    }

    func testANestedTypesExtensionReachesItsStoredFieldsAndAssociatedTypes() throws {
        let root = try ProcessHarness.makeFilesPackage(Self.r1492Files)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        let charged = ["rsaCaller", "rsaImplicitCaller", "rsaLetCaller", "rsaListCaller", "mlInitCaller", "mlSignCaller",
                       "cursorCaller", "reflectCaller", "reflectChainCaller"]
        for fn in charged {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes a marker (executed) — \(by[fn] ?? [:])")
        }
        // Controls: a SAME-NAMED type with a same-named PURE field, a nested alias onto a pure type under an owner name
        // the RSA key shares, an associated type whose every conformer is pure, and `String(reflecting:)` on a type
        // whose `debugDescription` is pure and `description` is not (only `debugDescription` runs).
        for fn in ["otherCaller", "voprfCaller", "voprfPKCaller", "qCaller", "reflectBothCaller"] {
            XCTAssertNil(ProcessHarness.chargedNothing(by, fn), "\(fn) is pure (control)")
        }
        let off = try scan(root, env: ["CANDOR_R1492_OFF": "1"])
        for fn in charged { XCTAssertNil(ProcessHarness.inferred(off, fn), "the release was silent on \(fn)") }
        // The owner-name alias half alone: with the full-path field index ON and the alias scoping OFF, RSA's
        // `BackingPrivateKey` is read as P384._VOPRF.PrivateKey's — the swift-crypto shape in which typing the field
        // turned a fabricated self-edge into a silent drop.
        let noM = try scan(root, env: ["CANDOR_R1492M_OFF": "1"])
        XCTAssertNil(ProcessHarness.inferred(noM, "rsaCaller"), "owner-name alias leak: \(noM["rsaCaller"] ?? [:])")
        XCTAssertEqual(try gate(root, "deny Fs mlInitCaller\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs mlInitCaller\n", env: ["CANDOR_R1492I_OFF": "1"]), 0)
        XCTAssertEqual(try gate(root, "deny Fs rsaCaller\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs rsaCaller\n", env: ["CANDOR_R1492_OFF": "1"]), 0)
        XCTAssertEqual(try gate(root, "deny Fs qCaller\n"), 0)
    }

    /// Exposed by R1492's A/B (swift-certificates `Time.makeTime`): `self.init(…)` inside an extension of a type only
    /// EXTENDED here, that no local initializer answers, is the dependency's initializer — the unqualified `T(…)` twin
    /// was disclosed `invisible`, the delegation was not. A disclosure (`invisible`, non-gating); the controls are a
    /// delegation a local initializer answers and a declared type's own `self.init`.
    func testAnExtendedDependencyTypesSelfInitIsDisclosed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("candor-r1492-\(UUID().uuidString)")
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
        extension OrderedSet {
          init(one e: Element) { self.init(minimumCapacity: 1, persistent: false) }
          init(two e: Element) { self.init(one: e) }
        }
        struct Mine { var n: Int; init(n: Int) { self.n = n }; init(z: Int) { self.init(n: z) } }
        func make() -> OrderedSet<Int> { OrderedSet(one: 1) }
        """#.write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let by = try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"]).out)
        for f in ["OrderedSet.init(Element)", "OrderedSet.init(Element)#1", "make"] {
            XCTAssertEqual(by[f]?["invisible"] as? [String], ["OrderedCollections"], "\(f): \(by[f] ?? [:])")
        }
        XCTAssertNil(ProcessHarness.chargedNothing(by, "Mine.init(Int)"), "a local delegation reaches no package")
        let off = try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"], env: ["CANDOR_R1492_OFF": "1"]).out)
        XCTAssertNil(off["OrderedSet.init(Element)"]?["invisible"], "the release was silent: \(off["OrderedSet.init(Element)"] ?? [:])")
    }
}
