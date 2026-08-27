import XCTest
import Foundation

/// A Swift MACRO was invisible, with zero disclosure — not `Unknown`, not `unanalyzed`, nothing.
/// `#urlFetch("https://danger.example.com")` (freestanding) and `@MyBodyMacro func doThing() { }`
/// (attached, an apparently-empty body — the shape SwiftData `@Model`, `Observation`'s `@Observable`,
/// and Swift Testing's `@Test`/`@Suite` actually take) both scanned clean under `deny Net`: exit 0,
/// `functions: []`. No visitor existed for `MacroExpansionExprSyntax`, and no attribute handling
/// treated a decl's own custom attributes as a possible attached macro (CHANGELOG `[0.33.0]`, the
/// "macro / codegen reach" fix). These pins hold the boundary this fix drew: a freestanding macro with
/// NO trailing closure and any attached macro attribute are disclosed as `Unknown` (`unknownWhy:
/// "macro:<name>"` / `"macro:@<Attr>"`) — never resolved, never fabricated — while a macro WITH a
/// trailing closure keeps being caught CONCRETELY (its closure body is ordinary Swift the existing
/// `ClosureExprSyntax` visitor already walks), and a compiler-builtin literal (`#file`/`#fileID`/
/// `#isolation`/…), a name-alike non-macro, a LOCAL `@resultBuilder`/`@globalActor`, or a builtin
/// decl-attribute (`@MainActor`) gain nothing.
final class MacroDisclosureProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> (fns: [String: [String: Any]], err: String) {
        let bin = try ProcessHarness.binaryURL(for: MacroDisclosureProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return (try ProcessHarness.fns(ofJson: r.out), r.err)
    }

    // ── 1. THE CARDINAL SIN, freestanding — RED before this fix, GREEN after ─────────────────────────
    func testFreestandingMacroWithNoTrailingClosureDisclosesUnknown() throws {
        let (fns, _) = try scan("""
        import Foundation
        @freestanding(expression)
        macro urlFetch(_ s: String) -> String = #externalMacro(module: "MyMacros", type: "URLFetchMacro")
        func doThing() {
            let result = #urlFetch("https://danger.example.com")
            print(result)
        }
        """)
        let e = try XCTUnwrap(fns["doThing"], "a macro call must not vanish — it used to (`functions: []`)")
        XCTAssertEqual(e["inferred"] as? [String], ["Unknown"])
        XCTAssertEqual(e["unresolved"] as? Bool, true)
        XCTAssertEqual(e["unknownWhy"] as? [String], ["macro:urlFetch"])
    }

    // ── 2. THE CARDINAL SIN, attached — same RED before / GREEN after, a DIFFERENT syntax shape ──────
    func testAttachedMacroAttributeOnAFunctionDisclosesUnknown() throws {
        let (fns, _) = try scan("""
        import Foundation
        @MyBodyMacro
        func doThing() {
        }
        """)
        let e = try XCTUnwrap(fns["doThing"], "an attached macro attribute must not vanish")
        XCTAssertEqual(e["inferred"] as? [String], ["Unknown"])
        XCTAssertEqual(e["unknownWhy"] as? [String], ["macro:@MyBodyMacro"])
    }

    // ── 3. An attached TYPE-level macro (`@Observable class Store`) reaches its EXISTING members ─────
    func testAttachedMacroOnATypeReachesItsCollectedMembers() throws {
        let (fns, _) = try scan("""
        import Foundation
        @Observable
        class Store {
            var count = 0
            func bump() {
                count += 1
            }
        }
        """)
        let e = try XCTUnwrap(fns["Store.bump"])
        XCTAssertEqual(e["inferred"] as? [String], ["Unknown"])
        XCTAssertEqual(e["unknownWhy"] as? [String], ["macro:@Observable"])
    }

    // ── 4. THE CONTROL THAT MUST NOT REGRESS: a trailing closure stays caught CONCRETELY ─────────────
    // `#Preview { ... }`'s closure body is ordinary Swift the existing ClosureExprSyntax visitor already
    // walks — the first cut of this fix added `Unknown` right beside that concrete catch on EVERY such
    // node, unconditionally (measured while building it). A real effect inside the closure must appear
    // as itself, with no additional `Unknown` riding along.
    func testFreestandingMacroWithTrailingClosureStaysConcreteNotUnknown() throws {
        let (fns, _) = try scan("""
        import Foundation
        func makeRequest() {
            URLSession.shared.dataTask(with: URL(string: "https://example.com")!) { _, _, _ in }.resume()
        }
        #Preview {
            makeRequest()
        }
        """)
        let main = try XCTUnwrap(fns["<main>"], "the closure's real effect must still be reached")
        XCTAssertEqual(main["inferred"] as? [String], ["Net"], "a trailing-closure macro must not be downgraded from a concrete effect to Unknown")
        XCTAssertNil(main["unknownWhy"], "no Unknown, so no unknownWhy either")
    }

    // ── 5. NO FABRICATION: a name-alike non-macro gains nothing ──────────────────────────────────────
    func testANameAlikeNonMacroGainsNothing() throws {
        let (fns, _) = try scan("""
        import Foundation
        func urlFetch(_ s: String) -> String { return s }
        struct Observable {}
        @MainActor
        func onMain() { print("main") }
        """)
        XCTAssertNil(fns["urlFetch"], "a function merely NAMED like a macro must stay pure")
        XCTAssertNil(fns["onMain"], "@MainActor is a builtin decl-attribute, not a macro — must gain nothing")
    }

    // ── 6. NO FABRICATION: compiler-builtin freestanding literals stay silent ────────────────────────
    // SE-0382 re-expressed #file/#line/#function/etc. as macros under the hood, so the grammar cannot
    // tell them apart from a real macro — only the NAME can. #fileID (SE-0274) and #isolation (SE-0420)
    // were MISSING from the first cut of this denylist, caught only by the 13-package corpus diff
    // (swift-nio/Nimble default nearly every logging parameter to one of the two).
    func testCompilerBuiltinFreestandingLiteralsStaySilent() throws {
        let (fns, _) = try scan("""
        import Foundation
        func logSite(file: String = #file, line: Int = #line, fn: String = #function,
                      id: String = #fileID) {
            print(file, line, fn, id)
        }
        func onActor(isolation: isolated (any Actor)? = #isolation) async {
            print(isolation as Any)
        }
        """)
        XCTAssertNil(fns["logSite"], "#file/#line/#function/#fileID default params must not disclose Unknown")
        XCTAssertNil(fns["onActor"], "#isolation default params must not disclose Unknown")
    }

    // ── 7. NO REGRESSION: a LOCAL effectful @resultBuilder still resolves CONCRETELY ─────────────────
    func testLocalResultBuilderStaysConcrete() throws {
        let (fns, _) = try scan("""
        import Foundation
        @resultBuilder
        struct NetBuilder {
            static func buildBlock(_ parts: String...) -> String {
                URLSession.shared.dataTask(with: URL(string: "https://example.com")!) { _, _, _ in }.resume()
                return parts.joined()
            }
        }
        @NetBuilder
        func build() -> String {
            "a"
        }
        """)
        let e = try XCTUnwrap(fns["build"])
        XCTAssertEqual(e["inferred"] as? [String], ["Net"], "an unresolved-macro-candidate attribute must not shadow a real, resolved @resultBuilder")
        XCTAssertNil(e["unknownWhy"])
    }

    // ── 8. NO FABRICATION: a LOCAL @globalActor is isolation-checking only, not a macro ───────────────
    func testLocalGlobalActorStaysSilent() throws {
        let (fns, _) = try scan("""
        import Foundation
        @globalActor
        actor DBActor {
            static let shared = DBActor()
        }
        @DBActor
        func onDB() { print("db") }
        """)
        XCTAssertNil(fns["onDB"], "a locally-declared @globalActor must not be treated as an attached macro")
    }
}
