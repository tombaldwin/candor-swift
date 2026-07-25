import XCTest
import Foundation

/// IMPLICIT STRINGIFICATION through a PROTOCOL-typed operand — the Swift arm of the four-way vein
/// recorded in candor-spec/SOUNDNESS-VEIN-implicit-stringify.md (found on HikariCP via SLF4J
/// parameterized logging, reproduced in all four engines). `"\(e)"` / `String(describing: e)` /
/// `print(e)` runs the operand's `description`; when the operand is a CONCRETE local type that edge
/// already existed (smoke.sh's implicit-conversion battery), but when it is an EXISTENTIAL (`any P`),
/// a GENERIC (`<T: P>`), or a caught `error`, the witness belongs to a CONFORMER and NOTHING was
/// edged — the function read silent-pure while its `description` performed I/O (the cardinal sin).
///
/// Pins the closure and its no-fabrication controls: the witness is reached by CHA over the
/// conformers whose `description` candor can SEE; a pure witness, a String/Int operand, and a
/// raw-value enum (`enum Suit: String`, whose "conformance" to String is a raw type, not a
/// stringification witness) must all contribute NOTHING.
final class ImplicitStringifyProcessTests: XCTestCase {

    /// (a) the vein fixture itself: an effectful `description` reached through an existential, a
    /// generic bound, `String(describing:)` and `print` — plus (b)/(c) the purity controls.
    func testProtocolTypedStringificationReachesTheConformersWitness() throws {
        let bin = try ProcessHarness.binaryURL(for: ImplicitStringifyProcessTests.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        protocol Entry { func state() -> Int }
        struct Impl: Entry, CustomStringConvertible {
            func state() -> Int { 1 }
            var description: String { "t=\\(Date())" }        // Clock, reached only by stringification
        }
        protocol Tag { func id() -> Int }
        struct PureTag: Tag, CustomStringConvertible {
            func id() -> Int { 2 }
            var description: String { "tag" }                 // pure witness — contributes nothing
        }
        func describeExistential(_ e: Entry) -> String { return "entry: \\(e)" }
        func describeGeneric<T: Entry>(_ e: T) -> String { return "entry: \\(e)" }
        func describeDescribing(_ e: Entry) -> String { return String(describing: e) }
        func describePrint(_ e: Entry) { print(e) }
        func describeField(_ b: Box) -> String { return "b: \\(b.entry)" }
        struct Box { let entry: Entry }
        func describePureProto(_ t: Tag) -> String { return "tag: \\(t)" }
        func describeString(_ s: String) -> String { return "s: \\(s)" }
        func describeInt(_ i: Int) -> String { return "i: \\(i)" }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let by = try ProcessHarness.fns(ofJson: r.out)

        XCTAssertEqual(ProcessHarness.inferred(by, "Impl.description"), ["Clock"],
                       "the witness itself must classify (the analysis that was always correct)")
        for fn in ["describeExistential", "describeGeneric", "describeDescribing",
                   "describePrint", "describeField"] {
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ["Clock"],
                           "\(fn): stringifying a protocol-typed value runs the conformer's description — "
                           + "it must not read silent-pure")
        }
        // (b) a PURE `description` contributes nothing — the rung adds an edge, never an effect.
        XCTAssertNil(by["describePureProto"], "a pure conformer witness must contribute nothing")
        // (c) a plain String / Int operand has no local witness at all — no edge, no Unknown.
        XCTAssertNil(by["describeString"], "interpolating a String must stay pure")
        XCTAssertNil(by["describeInt"], "interpolating an Int must stay pure")
        // the rung is precise-or-nothing: it must never disclose Unknown at an interpolation site.
        for (fn, e) in by {
            XCTAssertFalse((e["inferred"] as? [String] ?? []).contains("Unknown"),
                           "\(fn): stringification must not flood the report with Unknown")
        }
    }

    /// The caught-error shape — `catch { log("\(error)") }` is the Swift spelling of the HikariCP
    /// finding (log an object, its `description` runs). The implicit `error`, a `catch let e`, and a
    /// typed `catch let e as MyError` all reach the error type's witness; an error type with a pure
    /// (or no) `description` contributes nothing.
    func testCaughtErrorStringificationReachesTheErrorsWitness() throws {
        let bin = try ProcessHarness.binaryURL(for: ImplicitStringifyProcessTests.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        struct DiskError: Error, CustomStringConvertible {
            var description: String { "at \\(Date())" }       // Clock, via stringification only
        }
        struct QuietError: Error, CustomStringConvertible {
            var description: String { "quiet" }               // pure
        }
        func risky() throws {}
        func logImplicit() { do { try risky() } catch { _ = "failed: \\(error)" } }
        func logNamed() { do { try risky() } catch let e { _ = String(describing: e) } }
        func logTyped() { do { try risky() } catch let e as QuietError { _ = "\\(e)" } catch {} }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let by = try ProcessHarness.fns(ofJson: r.out)

        XCTAssertEqual(ProcessHarness.inferred(by, "logImplicit"), ["Clock"],
                       "the implicit `error` binding is `any Error` — stringifying it runs a conformer's description")
        XCTAssertEqual(ProcessHarness.inferred(by, "logNamed"), ["Clock"],
                       "`catch let e` binds the same existential — String(describing:) must reach the witness")
        // `catch let e as QuietError` is a CONCRETE type: only THAT witness runs, and it is pure —
        // the typed catch must not inherit the sibling error's Clock (precision, not just soundness).
        XCTAssertNil(by["logTyped"], "a typed catch binds a concrete type — a pure witness contributes nothing")
    }

    /// NO FABRICATION on Swift's overloaded inheritance clause: `enum Suit: String` records String as a
    /// "conformed supertype", so an open "dispatch over anything with conformers" rule would edge every
    /// `"\(someString)"` to the enum's `description`. Interpolating a String must stay pure even when a
    /// raw-value enum with an EFFECTFUL description exists in the same package.
    func testRawValueEnumIsNotAStringificationWitnessForString() throws {
        let bin = try ProcessHarness.binaryURL(for: ImplicitStringifyProcessTests.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        enum Suit: String, CustomStringConvertible {
            case hearts
            var description: String { "t=\\(Date())" }        // Clock — must NOT reach String operands
        }
        enum Code: Int, CustomStringConvertible {
            case ok
            var description: String { "t=\\(Date())" }
        }
        func fmtString(_ s: String) -> String { return "s=\\(s)" }
        func fmtInt(_ i: Int) -> String { return "i=\\(i)" }
        func fmtSuit(_ x: Suit) -> String { return "x=\\(x)" }   // the REAL witness — Clock
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let by = try ProcessHarness.fns(ofJson: r.out)

        XCTAssertNil(by["fmtString"], "a raw-value enum's `: String` is not a stringification witness for String")
        XCTAssertNil(by["fmtInt"], "a raw-value enum's `: Int` is not a stringification witness for Int")
        XCTAssertEqual(ProcessHarness.inferred(by, "fmtSuit"), ["Clock"],
                       "the concrete operand's own witness still runs")
    }
}
