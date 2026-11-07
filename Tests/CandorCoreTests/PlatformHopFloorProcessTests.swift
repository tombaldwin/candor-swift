import XCTest
import Foundation

/// SOUNDNESS R1499 — `final class TLoc: Thread { func removeAllObjects() }` and `l.threadDictionary.removeAllObjects()`:
/// `rootOf` kept `TLoc` across the unexplained hop (R567's floor) and charged `TLoc.removeAllObjects`. EXECUTED: no write
/// happens — `threadDictionary` is Thread's `NSMutableDictionary`. A platform-declared hop is never typed as a type this
/// scan declares, so only an `override` or an `@objc`/`dynamic` member could be reached through it. KEEPS (all executed,
/// all write): a real local field hop (`kField`), a local computed hop (`kMe`), the class's own member called directly
/// (`kSelf`), a second hop a local protocol extension declares (`kKf2`, the Kingfisher shape the first cut silenced).
/// And `kExt` — a local EXTENSION member of the platform hop's type (`extension NSMutableDictionary { func zapAll() }`)
/// — read ABSENT on the release and is now edged. Residual, not fixed: `kKf` (the class declares a pure same-named
/// member, so the floor resolves to it; silent on the release too).
final class PlatformHopFloorProcessTests: XCTestCase {
    static let src = """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1499-" + s, contents: nil) }
func seen(_ s: String) -> Bool { let r = FileManager.default.fileExists(atPath: "/tmp/r1499-" + s); try? FileManager.default.removeItem(atPath: "/tmp/r1499-" + s); return r }
// THE FABRICATION: `threadDictionary` is Thread's (an NSMutableDictionary); TLoc.removeAllObjects never runs.
final class TLoc: Thread { func removeAllObjects() { mark("fab") } }
func fDirect(_ l: TLoc) { l.threadDictionary.removeAllObjects() }
func fLet(_ l: TLoc) { let d = l.threadDictionary; d.removeAllObjects() }
// KEEP 1: a real LOCAL hop (a stored field) to a local type's member — must stay charged.
final class Box { func removeAllObjects() { mark("box") } }
final class TBox: Thread { var box = Box(); func removeAllObjects() { } }
func kField(_ l: TBox) { l.box.removeAllObjects() }
// KEEP 2: a local computed property typed as the class itself.
final class TMe: Thread { var me: TMe { self }; func zap() { mark("me") } }
func kMe(_ l: TMe) { l.me.zap() }
// KEEP 3: a local extension member on the PLATFORM hop's type, same leaf as a member of the class (floor kept: the
// leaf has a declaration outside the class's hierarchy).
extension NSMutableDictionary { @objc func zapAll() { mark("ext") } }
final class TExt: Thread { func zapAll() { } }
func kExt(_ l: TExt) { l.threadDictionary.zapAll() }
// KEEP 4: an OVERRIDE reached through a platform hop typed as a platform superclass (dynamic dispatch).
class MyOp: Operation { override func main() { mark("ovr") } ; func kick() { } }
final class Holder: Thread { }
func kOverride(_ q: OperationQueue) { for op in q.operations { op.main() } }
// KEEP 5: a direct call on the class itself (no hop).
func kSelf(_ l: TLoc) { l.removeAllObjects() }
// KEEP 6 (the corpus shape that the first cut silenced): a SECOND hop a local protocol extension declares.
protocol Compat {}
struct Wrap<B> { let base: B; func cancelTask() { mark("kf") } }
extension Compat { var kf: Wrap<Self> { Wrap(base: self) } }
extension NSMutableDictionary: Compat {}
final class TKf: Thread { func cancelTask() { } }
func kKf(_ l: TKf) { l.threadDictionary.kf.cancelTask() }
final class TKf2: Thread { }
func kKf2(_ l: TKf2) { l.threadDictionary.kf.cancelTask() }
let t = TLoc(); fDirect(t); fLet(t); print("fDirect/fLet wrote:", seen("fab"))
kField(TBox()); print("kField", seen("box"))
kMe(TMe()); print("kMe", seen("me"))
kExt(TExt()); print("kExt", seen("ext"))
kSelf(t); print("kSelf", seen("fab"))
kKf(TKf()); print("kKf", seen("kf"))
kKf2(TKf2()); print("kKf2", seen("kf"))
"""

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

    func testAPlatformHopIsNotTheLocalClass() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in ["fDirect", "fLet"] { XCTAssertNil(ProcessHarness.chargedNothing(by, fn), "\(fn) writes nothing (executed) — \(by[fn] ?? [:])") }
        for fn in ["kField", "kMe", "kSelf", "kExt"] {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes the marker (executed) — \(by[fn] ?? [:])")
        }
        XCTAssertEqual(ProcessHarness.inferred(by, "kKf2"), ["Unknown"], "the release's hedge stays — \(by["kKf2"] ?? [:])")
        let off = try scan(root, env: ["CANDOR_R1499_OFF": "1"])
        XCTAssertEqual(ProcessHarness.inferred(off, "fDirect"), ["Fs"], "the release fabricated: \(off["fDirect"] ?? [:])")
        XCTAssertNil(ProcessHarness.inferred(off, "kExt"), "the release was silent: \(off["kExt"] ?? [:])")
        XCTAssertEqual(try gate(root, "deny Fs fDirect\n"), 0)
        XCTAssertEqual(try gate(root, "deny Fs fDirect\n", env: ["CANDOR_R1499_OFF": "1"]), 1)
        XCTAssertEqual(try gate(root, "deny Fs kExt\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs kField\n"), 1)
    }
}
