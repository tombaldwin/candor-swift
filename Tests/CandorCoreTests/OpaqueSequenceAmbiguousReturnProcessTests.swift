import XCTest
import Foundation

/// FINDING 1 (`Classifier.swift`'s `ITERABLE_PROTOCOLS` doc comment, `DeclCollector.swift`'s
/// `recordOpaqueSeqReturn`) — a function returning an opaque/erased iterable (`some Sequence` /
/// `AnySequence<E>`) hides its concrete iterator from `rootOf`, so `for x in builder()` would silently
/// read pure unless the engine pins the CONCRETE local type the body actually returns. When the body
/// returns through more than one path, `recordOpaqueSeqReturn` must treat ANY unpinnable return as
/// poisoning the WHOLE key — "Ambiguity across multiple `return`s → nil (never guess); the site then
/// reads honest Unknown," per its own doc comment:
///
///     guard let t = concreteIterableType(r) else { seqConcreteRetTmp[key] = String?.none; return }
///
/// This is the guard that enforces "never guess": without it, a loop over `returns` that merely
/// `continue`s past an unpinnable return keeps whatever concrete type a DIFFERENT, pinnable return
/// resolved to — so a builder with one genuinely-unknowable path (a passed-in `AnySequence` parameter)
/// and one path that constructs a known local type silently resolves the WHOLE call to the known type's
/// `next`/`makeIterator`, dropping the disclosure that the other path is unknowable at all. That is a
/// silent-pure result exactly where the design's own comment says the site "reads honest Unknown."
///
/// Measured: with the guard's `return` weakened to a `continue`, `swift build`, `swift test` (951/951),
/// `smoke.sh`, `fabrication_probe.py`, `fuzz.py` and `ci/self-gate.sh` all stayed green — this suite is
/// what makes weakening it RED.
final class OpaqueSequenceAmbiguousReturnProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: OpaqueSequenceAmbiguousReturnProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    /// THE POSITIVE CONTROL — proves the mechanism itself: a builder with ONE unambiguous concrete
    /// return pins the iteration site to that type's `makeIterator`/`next`, precisely.
    func testUnambiguousOpaqueSequenceReturnEdgesItsConcreteIterator() throws {
        let by = try scan("""
        import Foundation
        final class FileEater: Sequence {
            func makeIterator() -> AnyIterator<Int> {
                let t = Process()
                t.launchPath = "/bin/sh"
                try? t.run()
                return AnyIterator { nil }
            }
        }
        final class Builder {
            func build() -> some Sequence {
                return FileEater()
            }
        }
        func caller() {
            let b = Builder()
            for _ in b.build() { }
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "caller"), ["Exec"],
                       "an unambiguous opaque-sequence body must still resolve precisely")
        XCTAssertEqual(by["caller"]?["unresolved"] as? Bool, false)
    }

    /// THE GUARD ITSELF. `Builder.build` returns EITHER a caller-supplied `AnySequence` (genuinely
    /// unknowable — a bare parameter, not a local constructor) OR a known local `FileEater`. The ONLY
    /// sound answer is Unknown: the parameter path could iterate to anything at all, and asserting Exec
    /// (from the FileEater path) would silently drop that possibility rather than disclose it.
    func testAmbiguousOpaqueSequenceReturnStaysUnknownNeverGuessesTheResolvableBranch() throws {
        let by = try scan("""
        import Foundation
        final class FileEater: Sequence {
            func makeIterator() -> AnyIterator<Int> {
                let t = Process()
                t.launchPath = "/bin/sh"
                try? t.run()
                return AnyIterator { nil }
            }
        }
        final class Builder {
            func build(other: AnySequence<Int>, flag: Bool) -> AnySequence<Int> {
                if flag { return other }
                return AnySequence(FileEater())
            }
        }
        func caller(flag: Bool, o: AnySequence<Int>) {
            let b = Builder()
            for _ in b.build(other: o, flag: flag) { }
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "caller"), ["Unknown"],
                       "one unpinnable return must poison the WHOLE key — never resolve to the other branch's type")
        XCTAssertEqual(by["caller"]?["unresolved"] as? Bool, true,
                       "the site must be marked genuinely unresolved, not silently pure nor silently precise")
        XCTAssertFalse((ProcessHarness.inferred(by, "caller") ?? []).contains("Exec"),
                       "the resolvable FileEater branch must not be guessed as the answer for the whole call")
    }

    /// The sibling mirror already covered by the SAME line's second condition (`c != t`): TWO DIFFERENT
    /// resolvable concrete types across branches must also stay ambiguous — recorded here so this file
    /// discriminates the ONE-UNPINNABLE-RETURN case from the TWO-DIFFERENT-CONCRETE-TYPES case rather
    /// than conflating them.
    func testTwoDifferentConcreteReturnTypesStayAmbiguous() throws {
        let by = try scan("""
        import Foundation
        final class FileEater: Sequence {
            func makeIterator() -> AnyIterator<Int> {
                let t = Process()
                t.launchPath = "/bin/sh"
                try? t.run()
                return AnyIterator { nil }
            }
        }
        final class OtherEater: Sequence {
            func makeIterator() -> AnyIterator<Int> { AnyIterator { nil } }
        }
        final class Builder {
            func build(flag: Bool) -> AnySequence<Int> {
                if flag { return AnySequence(FileEater()) }
                return AnySequence(OtherEater())
            }
        }
        func caller(flag: Bool) {
            let b = Builder()
            for _ in b.build(flag: flag) { }
        }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "caller"), ["Unknown"],
                       "two different concrete return types must not silently pick either one's effects")
    }
}
