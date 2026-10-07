import XCTest
import Foundation

/// VEIN A(i) — ONE TYPE IDENTITY, ONE CANONICALISER (`CallCollector.canonicalTypeRef`).
///
/// Every spelling of a LOCAL type other than its simple name — `Yard.Crane`, `T.Yard.Crane` (the scan's
/// own module), a file alias onto a nested type, a dotted member alias, a body-local alias — was read as
/// a foreign owner or not typed at all, and the call fell out of `functions[]` with no disclosure.
/// EXECUTED (`swiftagent-r910/ai-matrix`, 118 cells, 9 spellings × 14 sites): every effect runs; the
/// release charged only the simple-name columns. These rows pin the spellings, the three adjacent
/// defects the same table found (N-a own-module qualifier, N-b a constructor through an alias, N-c the
/// `.init()` binder), the alias-scope fabrication (N-d), and the guards the canonicaliser must not break.
/// `CANDOR_AI_OFF=1` restores the release; every defect row asserts that it does (§1b).
final class AiTypeIdentityProcessTests: XCTestCase {
    static let source = #"""
import Foundation
func mk(_ p: String) { _ = FileManager.default.createFile(atPath: "/tmp/ai_" + p, contents: nil) }
public enum Yard {
    public struct Crane: Comparable {
        public init() {}
        public func lift() { mk("lift") }
        public var load: Int { mk("load"); return 1 }
        public static func sweep() { mk("sweep") }
        public static func < (a: Crane, b: Crane) -> Bool { mk("lt"); return false }
        public static func == (a: Crane, b: Crane) -> Bool { true }
    }
    public struct Boom { public init() { mk("boom") } }
    public final class Hook { public init() {}; deinit { mk("hook") } }
}
public struct TopBoom { public init() { mk("topboom") } }
public struct TopCrane { public init() {}; public func lift() { mk("toplift") } }
public typealias FACrane = Yard.Crane
public typealias FTBoom = TopBoom
extension Yard { public typealias MACrane = Crane }

public func aiDotParam(_ c: Yard.Crane) { c.lift() }
public func aiModParam(_ c: T.Yard.Crane) { c.lift() }
public func aiFileAliasParam(_ c: FACrane) { c.lift() }
public func aiMemberAliasParam(_ c: Yard.MACrane) { c.lift() }
public func aiBodyAlias() { typealias L = Yard.Crane; let c = L(); c.lift() }
public func aiDotBind() { let c = Yard.Crane(); c.lift() }
public func aiDotCtor() { _ = Yard.Boom() }
public func aiDotDeinit() { _ = Yard.Hook() }
public func aiDotStatic() { T.Yard.Crane.sweep() }
public func aiDotKeyPath(_ c: Yard.Crane) -> [Int] { [c].map(\Yard.Crane.load) }
public func aiDotSorted(_ a: [Yard.Crane]) -> [Yard.Crane] { a.sorted() }
public func aiDotCaller() { aiDotParam(Yard.Crane()) }
// N-a — the scan's own module on a TOP-level type
public func aiOwnModule() { let c = T.TopCrane(); c.lift() }
// N-b — a constructor through an alias of a top-level local type
public func aiAliasCtor() { _ = FTBoom() }
// N-c — the explicit `.init` spelling as a binder
public func aiInitBinder() { let c = TopCrane.init(); c.lift() }
"""#

    /// N-d — the GLOBAL alias table turned a generic PARAMETER into another type's member alias. Executed:
    /// `Box(Safe()).runParam(Safe())` never writes; the release charged `Danger.go`'s Fs.
    static let aliasScope = #"""
import Foundation
func ndMark(_ p: String) { _ = FileManager.default.createFile(atPath: "/tmp/nd_" + p, contents: nil) }
public protocol Goer { func go() }
public struct Danger { public init() {}; public func go() { ndMark("danger") } }
public struct Safe: Goer { public init() {}; public func go() {} }
public struct Box<Kind: Goer> { public let k: Kind; public init(_ k: Kind) { self.k = k }
  public func runParam(_ x: Kind) { x.go() } }
public struct Other { public typealias Kind = Safe; public func viaOwnAlias(_ k: Kind) { k.go() } }
// a κ alias used from INSIDE its own type must keep charging
public struct Owner { public typealias Kind = Danger; public typealias Store = FileManager }
extension Owner { public func storeUse() -> Bool { Store.default.fileExists(atPath: "/tmp") } }
public func outsideQualified(_ k: Owner.Kind) { k.go() }
"""#

    /// THE SEEDED C3 — real effects reachable ONLY through member aliases INHERITED from a superclass,
    /// while an unrelated type declares the same alias names. A scoped lookup that forgot supertypes
    /// (`CANDOR_AI_SEED_NOSUPERS=1`, the plausible half-fix) loses both; executed, both happen.
    static let seed = #"""
import Foundation
public struct MemStore { public static func wipe() {} }
public struct Elsewhere { public typealias FM = Data; public typealias Store = MemStore }
public struct DiskStore { public static func wipe() { _ = FileManager.default.createFile(atPath: "/tmp/seed_store", contents: nil) } }
public class Base { public typealias FM = FileManager; public typealias Store = DiskStore; public init() {} }
public final class Sub: Base {
    public func wipe() { try? FM.default.removeItem(atPath: "/tmp/seed_c3") }
    public func flush() { Store.wipe() }
}
"""#

    /// R266 / R132 — a SHARED simple name. The dotted spelling must reach ITS type, never the namesake.
    static let shared = #"""
import Foundation
public enum DiskStorage { public final class Backend { public init() {}
    public func store() { _ = FileManager.default.createFile(atPath: "/tmp/r132", contents: nil) } } }
public enum MemoryStorage { public final class Backend { public init() {}
    public func store() { _ = ProcessInfo.processInfo.environment["R132"] } } }
public final class Backend { public init() {}; public func store() { _ = URL(string: "x").map { try? Data(contentsOf: $0) } } }
public func diskDotted(_ b: DiskStorage.Backend) { b.store() }
public func memDotted(_ b: MemoryStorage.Backend) { b.store() }
public func topBare(_ b: Backend) { b.store() }
"""#

    private func rows(_ root: URL, env: [String: String] = [:]) throws -> [String: Set<String>] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertGreaterThan(((d["analyzed"] as? [String: Any])?["count"] as? Int) ?? 0, 0, r.err)   // §E3
        var out: [String: Set<String>] = [:]
        for case let f as [String: Any] in (d["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { out[n] = Set((f["inferred"] as? [String]) ?? []) }
        }
        return out
    }
    private func gate(_ root: URL, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
    }
    static let off = ["CANDOR_AI_OFF": "1"]

    func testEverySpellingOfALocalTypeIsTheType() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        let on = try rows(root), off = try rows(root, env: Self.off)
        let cells = ["aiDotParam", "aiModParam", "aiFileAliasParam", "aiMemberAliasParam", "aiBodyAlias",
                     "aiDotBind", "aiDotCtor", "aiDotDeinit", "aiDotStatic", "aiDotKeyPath", "aiDotSorted",
                     "aiDotCaller", "aiOwnModule", "aiAliasCtor", "aiInitBinder"]
        for c in cells {
            XCTAssertEqual(on[c], ["Fs"], "\(c): the type's own effect, through this spelling")
            XCTAssertNil(off[c], "\(c): CANDOR_AI_OFF=1 must reproduce the release's ABSENT row (§1b)")
        }
        // The gate, on code that really performs the effect; none of these names prefixes another unit.
        for p in ["deny Fs aiDotParam", "deny Fs aiDotCaller", "deny Fs aiAliasCtor", "deny Fs aiInitBinder"] {
            XCTAssertEqual(try gate(root, p), 1, "`\(p)` must fail")
            XCTAssertEqual(try gate(root, p, env: Self.off), 0, "`\(p)` passed on the release")
        }
    }

    func testAnAliasIsScopedAndAGenericParameterIsNeverOne() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.aliasScope], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        let on = try rows(root), off = try rows(root, env: Self.off)
        XCTAssertEqual(off["Box.runParam"], ["Fs"], "the release's FABRICATION (N-d), as the switch restores it")
        XCTAssertNil(on["Box.runParam"], "`Kind` is Box's generic parameter, not `Owner.Kind`: nothing runs Danger.go")
        XCTAssertEqual(on["Owner.storeUse"], ["Fs"], "a κ alias used inside its own type still charges")
        XCTAssertNil(on["Other.viaOwnAlias"], "its own alias (Safe) is what it calls")
        XCTAssertEqual(on["outsideQualified"], ["Fs"], "`Owner.Kind` spelled from outside is Danger")
        XCTAssertEqual(try gate(root, "deny Fs Box.runParam"), 0)
        XCTAssertEqual(try gate(root, "deny Fs Box.runParam", env: Self.off), 1)
    }

    /// The seeded C3 is CHARGED by the real engine and LOST by the seeded half-fix — the guard has teeth.
    func testAnInheritedMemberAliasKeepsItsEffect() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.seed], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        let on = try rows(root), seeded = try rows(root, env: ["CANDOR_AI_SEED_NOSUPERS": "1"])
        XCTAssertEqual(on["Sub.wipe"], ["Fs"], "`FM` inherited from Base is FileManager")
        XCTAssertEqual(on["Sub.flush"], ["Fs"], "`Store` inherited from Base is DiskStore")
        XCTAssertNil(seeded["Sub.flush"], "the half-fix without supertypes loses it — the C3 this row guards")
        XCTAssertNil(seeded["Sub.wipe"])
    }

    /// R266 / R132 — the canonical spelling of a SHARED simple name is its full path: each dotted spelling
    /// reaches its own type's member and not the namesake's.
    func testASharedSimpleNameResolvesToItsOwnPath() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.shared], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        let on = try rows(root)
        XCTAssertEqual(on["diskDotted"], ["Fs"], "DiskStorage.Backend.store only")
        XCTAssertEqual(on["memDotted"], ["Env"], "MemoryStorage.Backend.store only — not the Disk namesake")
        let off = try rows(root, env: Self.off)
        XCTAssertEqual(on["topBare"], off["topBare"], "the bare top-level spelling is the release's reading")
    }
}
