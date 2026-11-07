import XCTest
import Foundation

/// THE `Self` SPELLING (row pending; found by the R1486 hedge-removal accounting). `var h = Self(); h.update(x)` in a
/// protocol extension (swift-crypto's `HashFunction.hash(bufferPointer:)`), `Self().fin()`, `Self.init()` and a parameter
/// annotated `Self` typed the value as the literal `Self`, which no unit carries, so every call on it was DROPPED — in a
/// struct as well as a protocol extension. EXECUTED: every charged caller below writes the marker.
final class SelfSpellingProcessTests: XCTestCase {
    static let src = """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1497-sh-" + s, contents: nil) }
protocol HF { init(); mutating func update(_ x: Int); func fin() -> Int }
protocol HFD: HF {}
extension HF {
    static func hashVar(_ x: Int) -> Int { var h = Self(); h.update(x); return h.fin() }
    static func hashLet(_ x: Int) -> Int { let h = Self(); return h.fin() }
    static func hashDirect(_ x: Int) -> Int { Self().fin() }
    func viaSelf() -> Int { self.fin() }
}
struct Loud: HFD { init() {} ; mutating func update(_ x: Int) { mark("upd") } ; func fin() -> Int { mark("fin"); return 1 } }
func cVar() -> Int { Loud.hashVar(1) }
func cLet() -> Int { Loud.hashLet(1) }
func cDirect() -> Int { Loud.hashDirect(1) }
func cSelf() -> Int { Loud().viaSelf() }
_ = cVar(); _ = cLet(); _ = cDirect(); _ = cSelf()
print(FileManager.default.fileExists(atPath: "/tmp/r1497-sh-upd"), FileManager.default.fileExists(atPath: "/tmp/r1497-sh-fin"))
struct St { init() {}; func fin() -> Int { mark("st"); return 1 }
    static func mk() -> Int { let h = Self(); return h.fin() }
    static func mkD() -> Int { Self().fin() }
    static func mkT() -> Int { let h = St(); return h.fin() } }
func cSt() -> Int { St.mk() }
func cStD() -> Int { St.mkD() }
extension HF { static func hashTyped(_ x: Int) -> Int { let h: Self = Self(); return h.fin() }
               static func viaStatic(_ x: Int) -> Int { Self.sfin() }
               static func sfin() -> Int { 0 }
               func viaBare() -> Int { fin() } }
extension HF { static func viaInit(_ x: Int) -> Int { let h = Self.init(); return h.fin() }
               static func viaParam(_ h: Self) -> Int { h.fin() } }
func cInit() -> Int { Loud.viaInit(1) }
func cParam() -> Int { Loud.viaParam(Loud()) }
func cSt2() -> Int { St.mkD() }
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

    func testSelfConstructedValuesReachTheirMembers() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in ["cVar", "cLet", "cDirect", "cInit", "cParam", "cSt", "cStD", "HF.hashVar", "St.mk", "St.mkD"] {
            XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains("Fs") == true, "\(fn) writes the marker (executed) — \(by[fn] ?? [:])")
        }
        let off = try scan(root, env: ["CANDOR_SELFCTOR_OFF": "1"])
        for fn in ["cVar", "St.mk", "St.mkD"] { XCTAssertNil(ProcessHarness.inferred(off, fn), "the release was silent: \(fn)") }
        XCTAssertEqual(try gate(root, "deny Fs cVar\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs cVar\n", env: ["CANDOR_SELFCTOR_OFF": "1"]), 0)
    }
}
