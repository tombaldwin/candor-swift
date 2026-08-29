import XCTest
import Foundation

/// **R33's DEINIT-GLUE ONLY FIRED FOR ONE BINDER SHAPE.** A `let`/`var` local bound to a fresh
/// construction of a type with an effectful `deinit` is supposed to charge that `deinit` to the
/// enclosing function (it runs at scope exit, deterministically under ARC for a non-escaping local —
/// the rust `Drop`-glue's Swift sibling). The mechanism lived entirely inside the `else if let v0 =
/// binding.initializer?.value` arm of `visit(VariableDeclSyntax)`'s per-binding `if let ann =
/// binding.typeAnnotation { … } else if … { … }` — so it only ever ran for a binder with NO type
/// annotation. `let x: Loud = Loud(path)` and `var x: Loud? = Loud(path)` (the ordinary way to spell an
/// explicitly-typed or Optional local — no rarer in real Swift than the inferred form) took the OTHER
/// arm and never reached the glue: `Loud`'s effectful `deinit` read completely silent-pure at the
/// caller, no `Unknown`, no disclosure. `let _ = Loud(path)` (the wildcard binder — arguably the most
/// certain non-escaping shape of all, since there is no name for anything downstream to alias, store,
/// or return) fell through the identifier-only guard before either arm and missed it the same way.
///
/// MEASURED, NOT HYPOTHESISED: an identical `Loud` class (an effectful `deinit` reading a path) charged
/// via the four binder shapes below, against the pre-fix binary — `inferredType` (`let x = Loud(p)`)
/// charged `Fs`; the other three were ABSENT from `functions` entirely.
///
/// Fixed by extracting the glue into one function (`applyDeinitGlue`) keyed off `rootOf` on the
/// INITIALIZER expression — never the annotation, so an annotation naming a supertype/protocol still
/// resolves to what was actually constructed — and calling it from the annotated-binder arm and a new
/// wildcard-binder check, alongside the pre-existing unannotated-binder call site. One authority, three
/// call sites, rather than the disagreement above.
///
/// `testAPureTypeStaysAbsentAcrossAllFourShapes` is the fabrication control: the identical four shapes
/// over a class with NO `deinit` must stay silent, so the new call sites do not turn into a new
/// over-charge. `testAReturnedAnnotatedLocalStaysPure` mirrors the pre-existing ESCAPE control (a
/// factory that returns its product must not be charged) onto the newly-covered annotated shape.
final class DeinitGlueBinderShapeProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--out", root.appendingPathComponent("r").path]
        if let policy {
            let p = root.appendingPathComponent("deny.pol")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        let d = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("r.\(name).Swift.json"))) as? [String: Any]
        var by: [String: [String]] = [:]
        for case let f as [String: Any] in (d?["functions"] as? [Any]) ?? [] {
            guard let n = f["fn"] as? String else { continue }
            by[n] = ((f["inferred"] as? [Any]) ?? []).compactMap { $0 as? String }.sorted()
        }
        return (by, r.code, r.out + r.err)
    }

    private static let loudPrelude = """
    import Foundation
    class Loud {
        let path: String
        init(_ path: String) { self.path = path }
        deinit { _ = try? Data(contentsOf: URL(fileURLWithPath: path)) }
    }
    """

    /// THE CONTROL for the three defects below: the shape that already worked, unaffected by the fix.
    func testInferredBinderAlreadyChargedDeinit() throws {
        let src = Self.loudPrelude + """
        func inferredType() {
            let x = Loud("/etc/passwd")
            print(x.path)
        }
        """
        let r = try scan(src, name: "Inferred", policy: "deny Fs\n")
        XCTAssertEqual(r.fns["inferredType"], ["Fs"], "the pre-existing, unannotated shape: \(r.out)")
        XCTAssertEqual(r.code, 1, "an effectful deinit at scope exit must fail `deny Fs`: \(r.out)")
    }

    /// THE DEFECT, explicit non-Optional annotation.
    func testExplicitTypeAnnotationChargesDeinit() throws {
        let src = Self.loudPrelude + """
        func explicitTypeAnnotation() {
            let x: Loud = Loud("/etc/passwd")
            print(x.path)
        }
        """
        let r = try scan(src, name: "Annotated", policy: "deny Fs\n")
        XCTAssertEqual(r.fns["explicitTypeAnnotation"], ["Fs"],
                       "an explicitly-typed local is no less bound to the construction than an "
                       + "inferred one — the deinit must still fire at scope exit: \(r.out)")
        XCTAssertEqual(r.code, 1, "must fail `deny Fs`, not certify clean: \(r.out)")
    }

    /// THE DEFECT, explicit Optional annotation (the common `var x: T? = T()` shape).
    func testExplicitOptionalAnnotationChargesDeinit() throws {
        let src = Self.loudPrelude + """
        func explicitOptionalAnnotation() {
            var x: Loud? = Loud("/etc/passwd")
            x = nil
        }
        """
        let r = try scan(src, name: "OptAnnotated", policy: "deny Fs\n")
        XCTAssertEqual(r.fns["explicitOptionalAnnotation"], ["Fs"],
                       "typeName peels Optional the same way for annotations as for inference: \(r.out)")
        XCTAssertEqual(r.code, 1, "must fail `deny Fs`: \(r.out)")
    }

    /// THE DEFECT, wildcard binder — no name exists at all, so there is nothing MORE non-escaping
    /// than this shape, and it was silent regardless.
    func testWildcardBinderChargesDeinit() throws {
        let src = Self.loudPrelude + """
        func viaLetWildcard() {
            let _ = Loud("/etc/passwd")
        }
        """
        let r = try scan(src, name: "Wildcard", policy: "deny Fs\n")
        XCTAssertEqual(r.fns["viaLetWildcard"], ["Fs"],
                       "a wildcard binder discards the value immediately — deinit fires right there: \(r.out)")
        XCTAssertEqual(r.code, 1, "must fail `deny Fs`: \(r.out)")
    }

    /// FABRICATION CONTROL: the identical four shapes over a type with NO `deinit` must all stay
    /// silent — the new annotated/wildcard call sites must not manufacture an edge that resolveQual
    /// cannot back with a real unit.
    func testAPureTypeStaysAbsentAcrossAllFourShapes() throws {
        let src = """
        class Quiet {
            let n: Int
            init(_ n: Int) { self.n = n }
        }
        func inferredType() { let x = Quiet(3); print(x.n) }
        func explicitTypeAnnotation() { let x: Quiet = Quiet(3); print(x.n) }
        func explicitOptionalAnnotation() { var x: Quiet? = Quiet(3); x = nil }
        func viaLetWildcard() { let _ = Quiet(3) }
        """
        let r = try scan(src, name: "Pure", policy: "deny Fs\n")
        for fn in ["inferredType", "explicitTypeAnnotation", "explicitOptionalAnnotation", "viaLetWildcard"] {
            XCTAssertNil(r.fns[fn], "\(fn) constructs a type with no deinit at all — it must stay "
                         + "ABSENT (pure), not gain a fabricated effect from the new call sites: \(r.out)")
        }
        XCTAssertEqual(r.code, 0, "nothing here performs Fs: \(r.out)")
    }

    /// ESCAPE CONTROL, annotated edition: a factory that RETURNS its (now annotated) product must stay
    /// pure — mirrors the pre-existing `returnedNames` carve-out the unannotated shape already had.
    func testAReturnedAnnotatedLocalStaysPure() throws {
        let src = Self.loudPrelude + """
        func makes() -> Loud {
            let x: Loud = Loud("/etc/passwd")
            return x
        }
        """
        let r = try scan(src, name: "Escapes", policy: "deny Fs\n")
        XCTAssertNil(r.fns["makes"], "the local escapes via `return` — its deinit does not run here, "
                     + "so charging it would be the over-charge direction: \(r.out)")
        // NOT an exit-code assertion: `Loud.deinit` is itself a directly-effectful unit (it performs
        // `Fs` in its own body) and is reported — and so fails `deny Fs` — independent of whether ANY
        // caller's scope-exit is charged for it. The exit code says nothing about `makes` specifically;
        // the `r.fns["makes"]` check above is the whole assertion.
    }
}
