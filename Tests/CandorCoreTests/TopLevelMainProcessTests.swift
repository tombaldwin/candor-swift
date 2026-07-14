import XCTest
import Foundation

/// End-to-end pins for the synthetic `<main>` unit (SPEC §2 `unitKind: "initializer"`) that captures a
/// file's TOP-LEVEL executable statements. Swift allows bare executable statements directly at file scope
/// in `main.swift` / script files; before this they were collected by nothing (they belong to no
/// declaration), so a file whose only effect lived at the top level scanned as an EMPTY report — a false
/// "pure" verdict (the cardinal sin, top-level edition). These are properties of the whole scan, so they
/// are pinned at the process layer (mirrors LlmProcessTests / KappaFamiliesProcessTests).
final class TopLevelMainProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: TopLevelMainProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    // ── a top-level effectful statement mints a `<main>` unit with unitKind "initializer" ──────────────
    func testTopLevelEffectMintsMainInitializerUnit() throws {
        let by = try scan("""
        import Foundation
        let _ = URLSession.shared.dataTask(with: "https://api.openai.com/x") { _, _, _ in }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Llm", "Net"],
                       "a top-level model-reaching statement must surface on `<main>` — a false-pure verdict is the cardinal sin")
        XCTAssertEqual(by["<main>"]?["unitKind"] as? String, "initializer",
                       "the top-level unit carries unitKind \"initializer\" (SPEC §2; the JVM engine's <clinit> uses the same kind)")
        XCTAssertEqual(by["<main>"]?["fn"] as? String, "<main>", "the wire name must be exactly <main>")
    }

    // a wildcard `let _ = try? String(contentsOfFile:)` binds no name (no lazy global unit) → `<main>` [Fs].
    func testTopLevelWildcardBindingIsCaptured() throws {
        let by = try scan("""
        import Foundation
        let _ = try? String(contentsOfFile: "/etc/x")
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Fs"],
                       "a top-level wildcard binding runs its initializer for effect — captured on <main>")
    }

    // a top-level CALL reaches its callee TRANSITIVELY (edge), not by inlining the callee's body as direct.
    func testTopLevelCallReachesCalleeTransitively() throws {
        let by = try scan("""
        import Foundation
        func work() { _ = URLSession.shared.dataTask(with: "https://api.openai.com/x") { _, _, _ in } }
        work()
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "work"), ["Llm", "Net"], "the named function is unchanged")
        XCTAssertEqual(ProcessHarness.inferred(by, "<main>"), ["Llm", "Net"],
                       "the top-level `work()` call makes work's effects transitively visible on <main>")
        // transitive, NOT inlined: <main> edges to work and carries NO direct effect of its own.
        XCTAssertEqual((by["<main>"]?["direct"] as? [String])?.sorted() ?? [], [],
                       "the callee's effects reach <main> via the call edge, not as <main>'s direct effects")
        XCTAssertEqual((by["<main>"]?["calls"] as? [String])?.sorted(), ["work"])
    }

    // a plain LIBRARY file — imports + declarations, no top-level executable statements — gains NO `<main>`.
    func testPureLibraryFileGetsNoMainUnit() throws {
        let by = try scan("""
        import Foundation
        struct S { func f() {} }
        func g() -> Int { 1 }
        """)
        XCTAssertNil(by["<main>"], "a file with no top-level executable statements must not gain a <main> unit (no flood)")
    }

    // a NAMED top-level global is still its own first-touch unit, NOT folded into `<main>`.
    func testNamedGlobalIsNotFoldedIntoMain() throws {
        let by = try scan("""
        import Foundation
        let token = try? String(contentsOfFile: "/etc/t")
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "token"), ["Fs"], "the named global keeps its own lazy unit")
        XCTAssertNil(by["<main>"], "a named global-var decl is not a bare top-level statement — no <main>")
    }
}
