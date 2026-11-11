import XCTest
import Foundation

/// SOUNDNESS R1676 — a generic bound / existential spelled as a COMPOSITION (`D: Decoder & ~Copyable`, `~Copyable & Decoder`,
/// `Decoder & Sendable`, `some Decoder & ~Copyable`, `any Decoder & Sendable`, `where D: Decoder & ~Copyable`) named NO type, so a
/// call through the value joined no conformer and the caller was ABSENT over a conformer that writes a file. EXECUTED (swiftc,
/// `~/…/swiftagent-r1676/fx`): every `p…` caller writes its marker; the control the pure-only test below runs a pure conformer and writes nothing.
/// The plain `D: Decoder` spelling always dispatched. Residual, not fixed here (single-valued bound map): a call to the SECOND
/// protocol of `D: P & Q`, a second `where D: Q`, and a parameter pack `each D`.
final class R1676SuppressedBoundProcessTests: XCTestCase {
    static let src = """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1676t-" + s, contents: nil) }
protocol Dec: ~Copyable { mutating func removed() }
protocol Other: ~Copyable { func ping() }
struct Loud: Dec { mutating func removed() { mark("x") } }
struct Both: Dec, Other { mutating func removed() { mark("x") }; func ping() { mark("x") } }
final class HPlain<D: Dec> { var d: D; init(_ d: D) { self.d = d }; func pPlain() { d.removed() } }
final class HComp<D: Dec & ~Copyable> { var d: D; init(_ d: consuming D) { self.d = d }; func pComp() { d.removed() } }
final class HFirst<D: ~Copyable & Dec> { var d: D; init(_ d: consuming D) { self.d = d }; func pFirst() { d.removed() } }
final class HWhere<D> where D: Dec & ~Copyable { var d: D; init(_ d: consuming D) { self.d = d }; func pWhere() { d.removed() } }
final class HSend<D: Dec & Sendable> { var d: D; init(_ d: D) { self.d = d }; func pSend() { d.removed() } }
final class HExt<D: ~Copyable> { var d: D; init(_ d: consuming D) { self.d = d } }
extension HExt where D: Dec & ~Copyable { func pExt() { d.removed() } }
final class HTwo<D: Dec & Other> { var d: D; init(_ d: D) { self.d = d }; func pTwo() { d.removed() } }
func pFn<D: Dec & ~Copyable>(_ x: consuming D) { var x = x; x.removed() }
func pSome(_ x: consuming some Dec & ~Copyable) { var x = x; x.removed() }
func pAny(_ x: any Dec & Sendable) { var x = x; x.removed() }
func seen() -> Bool { let r = FileManager.default.fileExists(atPath: "/tmp/r1676t-x"); try? FileManager.default.removeItem(atPath: "/tmp/r1676t-x"); return r }
_ = seen()
let cases: [(String, () -> Void)] = [("pPlain", { HPlain(Loud()).pPlain() }), ("pComp", { HComp(Loud()).pComp() }),
  ("pFirst", { HFirst(Loud()).pFirst() }), ("pWhere", { HWhere(Loud()).pWhere() }), ("pSend", { HSend(Loud()).pSend() }),
  ("pExt", { HExt(Loud()).pExt() }), ("pTwo", { HTwo(Both()).pTwo() }),   ("pFn", { pFn(Loud()) }), ("pSome", { pSome(Loud()) }), ("pAny", { pAny(Loud()) })]
for (n, f) in cases { f(); print(n, seen()) }
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

    func testACompositionBoundDispatchesOverItsNamedProtocol() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        let charged = ["HPlain.pPlain", "HComp.pComp", "HFirst.pFirst", "HWhere.pWhere", "HSend.pSend", "HExt.pExt", "HTwo.pTwo",
                       "pFn", "pSome", "pAny"]
        for fn in charged {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes the marker (executed) — \(by[fn] ?? [:])")
        }
        let off = try scan(root, env: ["CANDOR_R1676_OFF": "1"])
        for fn in ["HComp.pComp", "HFirst.pFirst", "HWhere.pWhere", "HSend.pSend", "HExt.pExt", "HTwo.pTwo", "pFn", "pSome"] {  // pAny was already DISCLOSED (incomplete) by the release
            XCTAssertNil(ProcessHarness.chargedNothing(off, fn), "the release was silent: \(fn) \(off[fn] ?? [:])")
        }
        XCTAssertEqual(ProcessHarness.inferred(off, "HPlain.pPlain"), ["Fs"])
        XCTAssertEqual(try gate(root, "deny Fs HComp.pComp\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs HComp.pComp\n", env: ["CANDOR_R1676_OFF": "1"]), 0)
        XCTAssertEqual(try gate(root, "deny Fs HFirst.pFirst\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs pSome\n"), 1)
    }

    func testAPureConformerOnlyStaysPure() throws {
        let src = """
import Foundation
protocol Dec: ~Copyable { mutating func removed() }
struct Quiet: Dec { mutating func removed() { } }
final class HQuiet<D: Dec & ~Copyable> { var d: D; init(_ d: consuming D) { self.d = d }; func kPure() { d.removed() } }
HQuiet(Quiet()).kPure()
"""
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try gate(root, "deny Fs HQuiet.kPure\n"), 0)
        let by = try scan(root)
        XCTAssertNil(ProcessHarness.chargedNothing(by, "HQuiet.kPure"), "a pure conformer only: nothing to charge (executed: no marker)")
    }
}
