import XCTest
import Foundation

/// SOUNDNESS R1497 — two files each declaring `fileprivate typealias K = …` (legal Swift): the module-wide alias table
/// was last-writer-wins, so every OTHER file read the last file's target. Silent where that target is pure (`fa1`–`fa3`,
/// executed: the marker is written), fabricated where it is not (`pb1`/`pb2`, executed: nothing written). Controls: a
/// module-visible alias used from another file (`fc1`/`fc2`) and a single fileprivate alias (`fd1`) stay charged; a
/// file's own quiet alias (`pa1`) stays pure.
final class FilePrivateAliasScopeProcessTests: XCTestCase {
    static let files: [String: String] = [
        "AFile.swift": """
// KA: this file's alias is the LOUD one, a later file's is quiet (last-writer-wins read silent here).
fileprivate typealias KA = LoudA
private typealias KB = QuietB
struct UA { private var k: KA = KA(); func go() { k.run() } }
func fa1() { UA().go() }
func fa2() { KA().run() }
func fa3() { let x: KA = KA(); x.run() }
func pb1() { KB().run() }                 // CONTROL: quiet here although a later file's KB is loud
struct UB { private var k = KB(); func go() { k.run() } }
func pb2() { UB().go() }                  // CONTROL
""",
        "BFile.swift": """
// KC: a MODULE-visible alias, used from another file (CONTROL — must stay charged).
typealias KC = LoudC
""",
        "CFile.swift": """
func fc1() { KC().run() }
struct UC { var k = KC(); func go() { k.run() } }
func fc2() { UC().go() }
// KD: one fileprivate alias, used only in its own file — the shape every engine already read (CONTROL).
fileprivate typealias KD = LoudD
func fd1() { KD().run() }
""",
        "Impl.swift": """
import Foundation
func mark(_ s: String) { FileManager.default.createFile(atPath: "/tmp/r1497-" + s, contents: nil) }
struct LoudA { func run() { mark("a") } }
struct QuietA { func run() { } }
struct LoudB { func run() { mark("b") } }
struct QuietB { func run() { } }
struct LoudC { func run() { mark("c") } }
struct LoudD { func run() { mark("d") } }
struct QuietD { func run() { } }
""",
        "ZFile.swift": """
fileprivate typealias KA = QuietA
fileprivate typealias KB = LoudB
func pa1() { KA().run() }                 // CONTROL: quiet here although an earlier file's KA is loud
func fb1() { KB().run() }
struct ZB { fileprivate var k: KB = KB(); func go() { k.run() } }
func fb2() { ZB().go() }
""",
        "main.swift": """
import Foundation
for m in ["a", "b", "c", "d"] { try? FileManager.default.removeItem(atPath: "/tmp/r1497-" + m) }
func seen(_ m: String) -> Bool { let r = FileManager.default.fileExists(atPath: "/tmp/r1497-" + m); try? FileManager.default.removeItem(atPath: "/tmp/r1497-" + m); return r }
pb1(); pb2(); pa1(); print("controls pb1 pb2 pa1 wrote:", seen("a") || seen("b"))
for (n, f, m) in [("fa1", fa1, "a"), ("fa2", fa2, "a"), ("fa3", fa3, "a"), ("fb1", fb1, "b"), ("fb2", fb2, "b"), ("fc1", fc1, "c"), ("fc2", fc2, "c"), ("fd1", fd1, "d")] as [(String, () -> Void, String)] {
    f(); print(n, seen(m))
}
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

    func testAFileprivateAliasAnswersInItsOwnFile() throws {
        let root = try ProcessHarness.makeFilesPackage(Self.files)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in ["fa1", "fa2", "fa3", "fb1", "fb2", "fc1", "fc2", "fd1"] {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Fs"], "\(fn) writes the marker (executed) — \(by[fn] ?? [:])")
        }
        for fn in ["pa1", "pb1", "pb2"] { XCTAssertNil(ProcessHarness.chargedNothing(by, fn), "\(fn) is pure (executed)") }
        let off = try scan(root, env: ["CANDOR_R1497_OFF": "1"])
        XCTAssertNil(ProcessHarness.inferred(off, "fa1"), "the release was silent: \(off["fa1"] ?? [:])")
        XCTAssertEqual(ProcessHarness.inferred(off, "pb1"), ["Fs"], "the release fabricated: \(off["pb1"] ?? [:])")
        XCTAssertEqual(try gate(root, "deny Fs fa1\n"), 1)
        XCTAssertEqual(try gate(root, "deny Fs fa1\n", env: ["CANDOR_R1497_OFF": "1"]), 0)
        XCTAssertEqual(try gate(root, "deny Fs pb1\n"), 0)
        XCTAssertEqual(try gate(root, "deny Fs pb1\n", env: ["CANDOR_R1497_OFF": "1"]), 1)
    }
}
