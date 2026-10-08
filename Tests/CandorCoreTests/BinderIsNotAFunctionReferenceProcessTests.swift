import Foundation
import XCTest

/// SOUNDNESS R1011 — a name a binder in scope has claimed is not a free-function reference. An UNTYPED `for`
/// variable or closure parameter named like a free function and passed as a bare argument was read as a
/// reference to that function: `for line in xs { consume(line) }` beside `func line(_:)` that deletes a file was
/// charged `Fs` on v0.40.0 (and the fake call attributed a file's blind modules as `invisible` elsewhere).
/// Executed (`swiftagent-v041/gt1011`): `loopVar` and `closureParam` never call `line`; `realRef` does.
final class BinderIsNotAFunctionReferenceProcessTests: XCTestCase {
    static let src = """
    import Foundation
    func line(_ s: String) { try? FileManager.default.removeItem(atPath: s) }
    func consume(_ s: String) { }
    public func loopVar(_ xs: Any) { for line in xs as! [String] { consume(line) } }
    public func closureParam(_ xs: Any) { (xs as! [String]).forEach { line in consume(line) } }
    public func realRef() { ["x"].forEach(line) }
    """
    private func scan(_ env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makeFilesPackage(["a.swift": Self.src])
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        return try ProcessHarness.fns(ofJson: r.out)
    }
    func testABoundNameIsNotAFreeFunctionReference() throws {
        let by = try scan()
        for fn in ["loopVar", "closureParam"] {
            XCTAssertFalse(ProcessHarness.inferred(by, fn)?.contains("Fs") ?? false,
                           "\(fn) never calls `line` (executed) — Fs is a fabrication; got \(by[fn] ?? [:])")
        }
        XCTAssertEqual(ProcessHarness.inferred(by, "realRef"), ["Fs"], "a REAL reference keeps its edge")
        let off = try scan(["CANDOR_R1011_OFF": "1"])
        XCTAssertEqual(ProcessHarness.inferred(off, "loopVar"), ["Fs"], "§1b — the release's fabrication")
    }

    /// THE DISCLOSURE THIS MUST NOT DELETE, and the false one it must. `direct`/`withBinder` really call into the
    /// blind module and keep their `invisible`; `TSV.get`'s only "call" into it was the binder `raw` read as a
    /// free-function reference (swift-nio's `ThreadSpecificVariable.get`). `CANDOR_R990_OFF` keeps `raw` UNTYPED,
    /// as the release left it, so the arm isolates this fix rather than R990's typing of the binder.
    func testARealBlindCallKeepsItsDisclosureAndAFakeOneGoes() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makeFilesPackage(["a.swift": """
        import Foundation
        import SomeBlindModule
        public func direct() { blindCall() }
        public func withBinder(_ xs: [Int]) { for x in xs { blindCall(x) } }
        final class Box<T> { let value: T; init(_ v: T) { value = v } }
        public final class TSV<Value: AnyObject> {
          private typealias BoxedType = Box<(AnyObject, AnyObject)>
          final class Key { func get() -> UnsafeMutableRawPointer? { nil } }
          private let key = Key()
          func get() -> Value? {
            guard let raw = self.key.get() else { return nil }
            return (Unmanaged<BoxedType>.fromOpaque(raw).takeUnretainedValue().value.1 as! Value)
          }
        }
        final class Other { func get() -> Int { 1 } }
        """])
        defer { try? FileManager.default.removeItem(at: root) }
        func scan(_ env: [String: String]) throws -> [String: [String: Any]] {
            try ProcessHarness.fns(ofJson: ProcessHarness.run(bin, [root.path, "--json"], env: env).out)
        }
        let by = try scan(["CANDOR_R990_OFF": "1"])
        for fn in ["direct", "withBinder"] {
            XCTAssertEqual(by[fn]?["invisible"] as? [String], ["SomeBlindModule"],
                           "\(fn) really calls into the blind module; got \(by[fn] ?? [:])")
        }
        XCTAssertNil(by["TSV.get"]?["invisible"], "`raw` is a binder, not a call into SomeBlindModule")
        let off = try scan(["CANDOR_R990_OFF": "1", "CANDOR_R1011_OFF": "1"])
        XCTAssertEqual(off["TSV.get"]?["invisible"] as? [String], ["SomeBlindModule"], "§1b — the release's false disclosure")
    }
}
