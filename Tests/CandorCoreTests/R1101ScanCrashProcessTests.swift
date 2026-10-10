import XCTest
import Foundation

/// SOUNDNESS R1101 — two shapes that killed the WHOLE SCAN on released 0.40.4 (no report, so the package
/// could not be gated at all). Measured on a 73-package census: hummingbird, SwiftFormat and xcodes died on
/// SIGSEGV (the alias cycle), swift-case-paths on SIGTRAP (the dotted operator name).
///
/// - An alias cycle through the scan's OWN module qualifier (`public typealias Out = Kit.Out` inside module
///   `Kit`, xcodes' `typealias ProcessOutput = XcodesKit.ProcessOutput`) recursed `canonicalTypeRef` without
///   bound. Mutual and member-dotted cycles are pinned alongside.
/// - A free operator whose NAME is dots (`func .. (…)`, swift-case-paths) produced the return-declaration key
///   `..`, which was read as `Owner.name` and force-unwrapped an owner that did not exist.
///
/// Each fixture also carries one REAL effect, so the test asserts the scan still REPORTS it — a scan that
/// merely stopped crashing by giving up would pass an exit-code check and fail this one.
final class R1101ScanCrashProcessTests: XCTestCase {
    private func scan(_ files: [String: String]) throws -> [String: [String]] {
        let root = try ProcessHarness.makeFilesPackage(files, name: "Kit")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "the scan must complete (0.40.4 exited 139/133 here): \(r.err)")
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        var out: [String: [String]] = [:]
        for case let f as [String: Any] in (d["functions"] as? [Any]) ?? [] {
            if let n = f["fn"] as? String { out[n] = f["inferred"] as? [String] ?? [] }
        }
        return out
    }

    func testSelfAliasThroughOwnModuleDoesNotCrash() throws {
        let rows = try scan(["a.swift": #"""
import Foundation
public typealias Out = Kit.Out
public typealias Ping = Kit.Pong
public typealias Pong = Kit.Ping
struct Holder { typealias Inner = Holder.Inner }
func use() -> Bool {
  let e: Error? = nil
  guard let x = e as? Out else { return false }
  return x.isEmpty
}
func usePing(_ p: Ping) -> Bool { p.isEmpty }
func useInner(_ i: Holder.Inner) -> Bool { i.isEmpty }
func touch() { FileManager.default.createFile(atPath: "/tmp/r1101-touch", contents: nil) }
"""#, "main.swift": "touch()\n"])
        XCTAssertEqual(rows.first { $0.key.hasSuffix("touch") }?.value, ["Fs"], "\(rows)")
    }

    func testDottedOperatorNameDoesNotCrash() throws {
        let rows = try scan(["a.swift": #"""
import Foundation
infix operator ..
public func .. (a: Int, b: Int) -> Int { a + b }
struct Path { var p: Int; static func .. (a: Path, b: Int) -> Path { Path(p: a.p + b) } }
func touch() -> Int { FileManager.default.createFile(atPath: "/tmp/r1101-op", contents: nil); return 1 .. 2 }
"""#, "main.swift": "_ = touch()\n"])
        XCTAssertEqual(rows.first { $0.key.hasSuffix("touch") }?.value, ["Fs"], "\(rows)")
    }
}
