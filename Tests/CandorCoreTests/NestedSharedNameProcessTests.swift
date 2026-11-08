import XCTest
import Foundation

/// SOUNDNESS R1513 — A NESTED TYPE WHOSE SIMPLE NAME ANOTHER TYPE SHARES READ THE OTHER TYPE'S FACTS. Every simple-keyed
/// side map (`fields`, `closureFields`, member returns, `supertypesOf` …) held `A.NT` and `Z.NT` merged under `NT`, last
/// writer winning, so a method in `A.NT`'s body read `Z.NT`'s `l` and `l.eff()` was ABSENT over an executed file write
/// (while the same body in `extension A.NT { … }` charged, since R1492). Four routes, one keying rule — a nested type's
/// facts are read under its FULL path wherever the engine knows the path: (S) an in-body unit of a shared name reads its
/// own type by path, as the extension spelling does; (L) a bare shared name resolves to the type the unit's innermost
/// scope nests; (R) closure fields and member returns are path-keyed too (silent or hedged in BOTH spellings before);
/// (I) a path-keyed type climbs R266's path-keyed supertypes. The program below was EXECUTED (markers: field field2 meta cb
/// ret static deep inh extcb extret; every control wrote nothing — see the lane's handoff).
final class NestedSharedNameProcessTests: XCTestCase {

    static let src = """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1513-" + s, contents: nil) }
struct Loud { let tag: String; func eff() { mark(tag) } }
struct Quiet { func eff() {} }
func loudFree() { mark("cb") }
// The LOUD twin is declared FIRST and the quiet one LAST: the last writer is quiet, the silent direction.
enum NA {
  struct NT {
    var l: Loud = Loud(tag: "field")
    var meta: Loud.Type = Loud.self
    let cb: () -> Void = { loudFree() }
    static var s: Loud = Loud(tag: "static")
    func mk() -> Loud { Loud(tag: "ret") }
    func pField() { l.eff() }
    func pMeta() { meta.init(tag: "meta").eff() }
    func pCb() { cb() }
    func pRet() { mk().eff() }
    func pStatic() { NT.s.eff() }
  }
  static func pParam(_ t: NT) { t.l.eff() }
}
enum NZ {
  struct NT {
    var l: Quiet = Quiet()
    var meta: Quiet.Type = Quiet.self
    let cb: () -> Void = { }
    static var s: Quiet = Quiet()
    func mk() -> Quiet { Quiet() }
    func kField() { l.eff() }
    func kRet() { mk().eff() }
  }
  static func kParam(_ t: NT) { t.l.eff() }
}
// The QUIET twin FIRST and the loud one LAST: the release fabricated the loud facts onto the quiet type.
enum NY { struct MT { var l: Quiet = Quiet(); func cField() { l.eff() } } }
enum NB { struct MT { var l: Loud = Loud(tag: "field2"); func bField() { l.eff() } } }
// Deeper nesting, and an inherited field under a shared leaf.
enum DA { struct Mid { struct Deep { var l: Loud = Loud(tag: "deep"); func pDeep() { l.eff() } } } }
enum DZ { struct Mid { struct Deep { var l: Quiet = Quiet(); func kDeep() { l.eff() } } } }
class LBase { var l: Loud = Loud(tag: "inh") }
class QBase { var l: Quiet = Quiet() }
enum IA { final class CT: LBase { func pInh() { l.eff() } } }
enum IZ { final class CT: QBase { func kInh() { l.eff() } } }
// The extension spelling: closure fields and member returns were keyed by the simple name only.
enum XA { struct XT { let cb: () -> Void = { mark("extcb") }; func mk() -> Loud { Loud(tag: "extret") } } }
enum XZ { struct XT { let cb: () -> Void = { }; func mk() -> Quiet { Quiet() } } }
extension XA.XT { func pExtCb() { cb() }; func pExtRet() { mk().eff() } }
// Controls: both same-named types pure.
enum PA { struct PT { var l: Quiet = Quiet(); func uPure1() { l.eff() } } }
enum PB { struct PT { var l: Quiet = Quiet(); func uPure2() { l.eff() } } }
NA.NT().pField(); NA.NT().pMeta(); NA.NT().pCb(); NA.NT().pRet(); NA.NT().pStatic(); NA.pParam(NA.NT())
NZ.NT().kField(); NZ.NT().kRet(); NZ.kParam(NZ.NT()); NY.MT().cField(); NB.MT().bField()
DA.Mid.Deep().pDeep(); DZ.Mid.Deep().kDeep(); IA.CT().pInh(); IZ.CT().kInh()
XA.XT().pExtCb(); XA.XT().pExtRet(); PA.PT().uPure1(); PB.PT().uPure2()
"""

    static let charged = ["NA.NT.pField", "NA.NT.pMeta", "NA.NT.pCb", "NA.NT.pRet", "NA.NT.pStatic", "NA.pParam",
                          "NB.MT.bField", "DA.Mid.Deep.pDeep", "IA.CT.pInh", "XA.XT.pExtCb", "XA.XT.pExtRet"]
    static let controls = ["NZ.NT.kField", "NZ.NT.kRet", "NZ.kParam", "NY.MT.cField", "DZ.Mid.Deep.kDeep", "IZ.CT.kInh",
                           "PA.PT.uPure1", "PB.PT.uPure2"]

    /// R1513 (A), exposed by the A/B (swift-crypto `_RSA.Signing.PublicKey`): a member alias keyed by the owner's SIMPLE
    /// name was lent to every same-named owner, so `RS.PK`'s field typed by a FILE-level `fileprivate` alias was read
    /// through `VO.PK`'s member alias onto the quiet type. Executed: `pAlias` writes `/tmp/r1513-alias`, `kAlias` nothing.
    static let aliasFiles: [String: String] = [
        "A.swift": """
import Foundation
struct LoudImpl { func eff() { FileManager.default.createFile(atPath: "/tmp/r1513-alias", contents: nil) } }
struct QuietImpl { func eff() {} }
fileprivate typealias BK = LoudImpl
enum RS { struct PK { fileprivate var backing: BK = BK(); func pAlias() { backing.eff() } } }
""",
        "B.swift": """
enum VO { struct PK { fileprivate typealias BK = QuietImpl; fileprivate var backing: BK = BK(); func kAlias() { backing.eff() } } }
""",
        "main.swift": "RS.PK().pAlias(); VO.PK().kAlias()\n"
    ]

    func testASharedOwnerNamesMemberAliasIsReadFromItsOwnPathOnly() throws {
        let root = try ProcessHarness.makeFilesPackage(Self.aliasFiles)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        XCTAssertEqual(ProcessHarness.inferred(by, "RS.PK.pAlias"), ["Fs"], "\(by["RS.PK.pAlias"] ?? [:])")
        XCTAssertNil(ProcessHarness.chargedNothing(by, "VO.PK.kAlias"), "kAlias is pure (control)")
        let off = try scan(root, env: ["CANDOR_R1513A_OFF": "1"])
        XCTAssertNil(ProcessHarness.inferred(off, "RS.PK.pAlias"), "A off: \(off["RS.PK.pAlias"] ?? [:])")
        XCTAssertEqual(try gate(root, "deny Fs RS.PK.pAlias\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs RS.PK.pAlias\n", env: ["CANDOR_R1513_OFF": "1"]), 0)
    }

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

    func testANestedTypeReadsItsOwnFactsWhenItsSimpleNameIsShared() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in Self.charged {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes a marker (executed) — \(by[fn] ?? [:])")
        }
        for fn in Self.controls {
            XCTAssertNil(ProcessHarness.chargedNothing(by, fn), "\(fn) is pure (control)")
        }
        // The release: every one silent (or, for the closure field, only the `var`-less hedge it never had).
        let off = try scan(root, env: ["CANDOR_R1513_OFF": "1"])
        for fn in ["NA.NT.pField", "NA.NT.pMeta", "NA.NT.pRet", "NA.NT.pStatic", "NA.pParam", "DA.Mid.Deep.pDeep",
                   "IA.CT.pInh", "XA.XT.pExtCb", "XA.XT.pExtRet"] {
            XCTAssertNil(ProcessHarness.inferred(off, fn)?.first { $0 == "Fs" }, "the release was silent on \(fn): \(off[fn] ?? [:])")
        }
        XCTAssertEqual(ProcessHarness.inferred(off, "NY.MT.cField"), ["Fs"], "the release fabricated NB.MT's field onto NY.MT")
        XCTAssertEqual(try gate(root, "deny Fs NA.NT.pField\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs NA.NT.pField\n", env: ["CANDOR_R1513_OFF": "1"]), 0)
        XCTAssertEqual(try gate(root, "deny Fs NZ.NT.kField\n"), 0)
        // Each mechanism is load-bearing for its own cells.
        let noS = try scan(root, env: ["CANDOR_R1513S_OFF": "1"])
        XCTAssertNil(ProcessHarness.inferred(noS, "NA.NT.pField"), "S off: \(noS["NA.NT.pField"] ?? [:])")
        let noL = try scan(root, env: ["CANDOR_R1513L_OFF": "1"])
        XCTAssertNil(ProcessHarness.inferred(noL, "NA.pParam"), "L off: \(noL["NA.pParam"] ?? [:])")
        let noR = try scan(root, env: ["CANDOR_R1513R_OFF": "1"])
        XCTAssertNil(ProcessHarness.inferred(noR, "XA.XT.pExtRet"), "R off: \(noR["XA.XT.pExtRet"] ?? [:])")
        let noI = try scan(root, env: ["CANDOR_R1513I_OFF": "1"])
        XCTAssertNil(ProcessHarness.inferred(noI, "IA.CT.pInh"), "I off: \(noI["IA.CT.pInh"] ?? [:])")
    }
}
