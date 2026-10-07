import XCTest
import Foundation

/// SOUNDNESS R983 — A MEMBER WRITTEN IN `extension Outer.Inner { … }` WAS UNREACHABLE FROM ITS QUALIFIED READERS.
///
/// Such a member is keyed DOTTED (`Outer.Inner.unix`); an inline member of the same nested type is keyed by the
/// SIMPLE name (`Inner.unix`), which is the spelling every receiver resolves to. R915 (A) taught the CALL site to
/// emit the dotted key too, one level deep. Nothing else did, so:
///   * a static computed `var` or static `let` of such an extension, read `Outer.Inner.unix`, edged only
///     `Inner.unix` and the reader was ABSENT (swift-nio's `NIOBSDSocket.AddressFamily.*` lost every caller);
///   * a TWO-LEVEL path (`A.Mid.Inner.x`) formed `Mid.Inner`, so even a static `func` was ABSENT;
///   * a bare `Inner.x` written INSIDE `Outer` (Swift's lexical lookup) was ABSENT for both.
///
/// EXECUTED: this source with a driver calling each `s*` cell (`swiftagent-rel/c983`, `c983x`): every `s*` cell
/// read the environment, and neither `f*` cell did. v0.39.3 and 0.40.0 (and R976 `05a2dc9`) read every `s*` cell 0.
/// Cell names are unique and none is a prefix of another (§3.3).
final class R983NestedExtensionMemberProcessTests: XCTestCase {
    static let source = #"""
import Foundation
public enum NS {}
extension NS { public struct AF { public init() {} } }
extension NS.AF {
    public static var unix: NS.AF { _ = getenv("R983_ENV"); return NS.AF() }
    public static let once: NS.AF = { _ = getenv("R983_ENV"); return NS.AF() }()
    public static func mk() -> NS.AF { _ = getenv("R983_ENV"); return NS.AF() }
}
public func s01var() { _ = NS.AF.unix }
public func s02let() { _ = NS.AF.once }
public func s03hop() -> NS.AF { NS.AF.unix }
extension NS { public static func s04inner() { _ = AF.unix } }
extension NS { public static func s05innerf() { _ = AF.mk() } }

public enum Deep { public enum Mid { public struct AF { public init() {} } } }
extension Deep.Mid.AF {
    public static var unix: Deep.Mid.AF { _ = getenv("R983_ENV"); return Deep.Mid.AF() }
    public static func mk() -> Deep.Mid.AF { _ = getenv("R983_ENV"); return Deep.Mid.AF() }
}
public func s06deepvar() { _ = Deep.Mid.AF.unix }
public func s07deepfunc() { _ = Deep.Mid.AF.mk() }

// A top-level namesake of a nested type: the simple key is the namesake's, the dotted one the nested type's.
public struct CH { public init() {} }
extension CH { public static var unix: CH { CH() } }
public enum Z {}
extension Z { public struct CH { public init() {} } }
extension Z.CH { public static var unix: Z.CH { _ = getenv("R983_ENV"); return Z.CH() } }
public func s08nested() { _ = Z.CH.unix }
public func f01top() { _ = CH.unix }

// Two nested types sharing a leaf: only the one named is read (no leaf union).
public enum Y {}
extension Y { public struct AF { public init() {} } }
extension Y.AF { public static var unix: Y.AF { Y.AF() } }
public func f02other() { _ = Y.AF.unix }
"""#

    private func gate(_ root: URL, _ policy: String, env: [String: String] = [:]) throws -> Int32 {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let pf = root.appendingPathComponent("pol-\(UUID().uuidString)")
        try (policy + "\n").write(to: pf, atomically: true, encoding: .utf8)
        return try ProcessHarness.run(bin, [root.path, "--policy", pf.path, "--json"], env: env).code
    }
    static let off = ["CANDOR_R983_OFF": "1"]

    static let silences = ["deny Env s01var", "deny Env s02let", "deny Env s03hop", "deny Env NS.s04inner",
                           "deny Env NS.s05innerf", "deny Env s06deepvar", "deny Env s07deepfunc", "deny Env s08nested"]

    func testEveryQualifiedReaderChargesAndTheSwitchRestoresTheRelease() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        for p in Self.silences {
            XCTAssertEqual(try gate(root, p), 1, "`\(p)` must fail: the effect really happens (executed)")
            XCTAssertNotEqual(try gate(root, p, env: Self.off), 1, "`\(p)` under CANDOR_R983_OFF is the release")
        }
    }

    /// The key is EXACT: a top-level namesake and a same-leaf sibling stay pure (executed: no env read).
    func testNoNamesakeOrSiblingIsCharged() throws {
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.source], name: "T")
        defer { try? FileManager.default.removeItem(at: root) }
        for p in ["deny Env f01top", "deny Env f02other"] {
            XCTAssertNotEqual(try gate(root, p), 1, p)
        }
    }
}
