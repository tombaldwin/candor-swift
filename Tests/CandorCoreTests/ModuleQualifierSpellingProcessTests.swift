import XCTest
import Foundation

/// **A MODULE QUALIFIER IS A SPELLING — ASSERTED AS A LOOP, NOT AS A ROW.**
///
/// ⟨0.32⟩ (commit `fdd8a4b`) ruled that `Foundation.Process()` answers exactly as `Process()` does, and
/// wired that ruling into the κ free-call table and the three privacy ctor families. It did NOT reach
/// the `Data`/`String` content-read arm, which was keyed on the callee NODE (a `DeclReferenceExpr`)
/// rather than on a name — so `Foundation.Data(contentsOf: url)` reported `Clock` alone where
/// `Data(contentsOf: url)` reported `Clock, Unknown`, and `Foundation.Data(contentsOf: URL(string:
/// "https://…")!)` reported no `Net` at all. That was filed as an expected-failure ratchet in
/// `ExecCapabilityProcessTests` and is closed here.
///
/// **THE POINT OF THIS FILE IS THAT IT IS A LOOP.** The defect was not that one entry was missing; it
/// was that the two spellings are classified by two pieces of code, so a family added to one is absent
/// from the other until somebody notices. The fix makes every family a FUNCTION both call sites invoke
/// (`chargeContentsCtor`, `privacyCaptureEffects`, `bonjourDescriptorArg`, `privacyEventKitEffects`,
/// `kappaFree`); this battery is the gate that says so. Each subject is written TWICE in one fixture —
/// bare and qualified — and the assertion is that the pair agrees, whatever the answer is. A new family
/// added to one path only fails here without anybody having to remember this file exists.
///
/// EVERY UNIT CARRIES A CLOCK MARKER. A pure function is omitted from a report, so `nil == nil` would
/// pass a parity row that asked nothing (PART 37 (e)); `hasTeeth` then asserts that the battery contains
/// real effects, so a fixture that stopped classifying anything could not pass either.
final class ModuleQualifierSpellingProcessTests: XCTestCase {

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

    /// Every subject, in BOTH spellings. `bare<K>` and `qual<K>` are the same program.
    private static let pairs = """
    import Foundation

    // the arm the ratchet was filed against — a URL whose scheme is not statically provable
    func bareContentsOf(_ u: URL) throws -> Data { _ = Date(); return try Data(contentsOf: u) }
    func qualContentsOf(_ u: URL) throws -> Data { _ = Date(); return try Foundation.Data(contentsOf: u) }
    // …its two RESOLVED forms, where the scheme decides the effect
    func bareContentsOfFileURL(_ p: String) throws -> Data { _ = Date(); return try Data(contentsOf: URL(fileURLWithPath: p)) }
    func qualContentsOfFileURL(_ p: String) throws -> Data { _ = Date(); return try Foundation.Data(contentsOf: URL(fileURLWithPath: p)) }
    func bareContentsOfHttp() throws -> Data { _ = Date(); return try Data(contentsOf: URL(string: "https://evil.example/x")!) }
    func qualContentsOfHttp() throws -> Data { _ = Date(); return try Foundation.Data(contentsOf: URL(string: "https://evil.example/x")!) }
    // …and the PATH form, which has no scheme to resolve at all
    func bareContentsOfFile(_ p: String) throws -> String { _ = Date(); return try String(contentsOfFile: p) }
    func qualContentsOfFile(_ p: String) throws -> String { _ = Date(); return try Foundation.String(contentsOfFile: p) }
    func bareContentsOfFileLit() throws -> String { _ = Date(); return try String(contentsOfFile: "/etc/passwd") }
    func qualContentsOfFileLit() throws -> String { _ = Date(); return try Foundation.String(contentsOfFile: "/etc/passwd") }

    // the κ free-call table — the families ⟨0.32⟩ already covered, kept in the loop so a REGRESSION of
    // that fix fails here rather than only in the row that found it
    func bareProc() -> Process { _ = Date(); return Process() }
    func qualProc() -> Foundation.Process { _ = Date(); return Foundation.Process() }
    func barePipe() -> Pipe { _ = Date(); return Pipe() }
    func qualPipe() -> Foundation.Pipe { _ = Date(); return Foundation.Pipe() }
    func bareUUID() -> UUID { _ = Date(); return UUID() }
    func qualUUID() -> Foundation.UUID { _ = Date(); return Foundation.UUID() }
    func bareFH() -> FileHandle? { _ = Date(); return FileHandle(forReadingAtPath: "/tmp/x") }
    func qualFH() -> Foundation.FileHandle? { _ = Date(); return Foundation.FileHandle(forReadingAtPath: "/tmp/x") }
    // a ctor κ does not know must gain NOTHING through either spelling
    func bareUnknownCtor() -> NumberFormatter { _ = Date(); return NumberFormatter() }
    func qualUnknownCtor() -> Foundation.NumberFormatter { _ = Date(); return Foundation.NumberFormatter() }
    func bareURL() -> URL { _ = Date(); return URL(fileURLWithPath: "/tmp/x") }
    func qualURL() -> Foundation.URL { _ = Date(); return Foundation.URL(fileURLWithPath: "/tmp/x") }
    """

    /// THE INVARIANT. Not "`Foundation.Data(contentsOf:)` is `Fs`" — that answer is the classifier's to
    /// give — but "the two spellings of one program answer the same".
    func testEverySpellingPairAgrees() throws {
        let r = try scan(Self.pairs, name: "Pairs")
        let subjects = r.fns.keys.filter { $0.hasPrefix("bare") }.map { String($0.dropFirst(4)) }.sorted()
        XCTAssertEqual(subjects.count, 11,
                       "every `bare*` unit must be PRESENT in the report (the Clock marker guarantees it) "
                       + "— a missing one would make its parity row vacuous: \(r.fns.keys.sorted())")
        for s in subjects {
            XCTAssertEqual(r.fns["bare\(s)"], r.fns["qual\(s)"],
                           "`\(s)`: the bare spelling answered \(r.fns["bare\(s)"] ?? []) and the "
                           + "module-qualified spelling answered \(r.fns["qual\(s)"] ?? []). A module "
                           + "qualifier is a SPELLING — whichever answer is right, both must give it.")
        }
        // TEETH: the loop above is satisfied by a fixture that classifies nothing at all.
        let effectful = subjects.filter { (r.fns["bare\($0)"] ?? []).contains { $0 != "Clock" } }
        XCTAssertGreaterThanOrEqual(effectful.count, 8,
                                    "the battery must carry real effects, else the parity loop passes by "
                                    + "asking nothing: \(effectful)")
        // …and the specific rows the ratchet was filed on, stated so a silent collapse to `Clock` on BOTH
        // sides (which the parity loop alone would accept) is caught.
        XCTAssertEqual(r.fns["qualContentsOf"], ["Clock", "Unknown"],
                       "an unresolvable URL: I/O happens and its category is unprovable — the qualified "
                       + "spelling must disclose exactly what the bare one does")
        XCTAssertEqual(r.fns["qualContentsOfFile"], ["Clock", "Fs"], "a PATH read is unconditionally Fs")
        XCTAssertEqual(r.fns["qualContentsOfHttp"], ["Clock", "Net"], "a literal https URL is a remote read")
        XCTAssertEqual(r.fns["qualContentsOfFileURL"], ["Clock", "Fs"], "a fileURLWithPath URL is a file read")
    }

    /// THE GATE-LEVEL FORM. An effect that does not move a verdict has not been charged where it counts:
    /// the qualified spelling was a `deny Fs` bypass, and the bare spelling of the identical program was
    /// not.
    func testTheQualifiedSpellingFailsDenyFs() throws {
        let src = """
        import Foundation
        func readConfig(_ p: String) throws -> String { return try Foundation.String(contentsOfFile: p) }
        """
        let r = try scan(src, name: "Q", policy: "deny Fs\n")
        XCTAssertEqual(r.code, 1,
                       "the tree's only filesystem contact is a module-qualified content read, and it "
                       + "certified clean at exit 0: \(r.out)")
    }

    // ── THE OVER-CHARGE CONTROLS ─────────────────────────────────────────────────────────────────
    // Written and confirmed BEFORE the fix. Making a qualifier a spelling is trivially satisfied by
    // charging more; these are the rows that decide whether it was done right.

    /// A PROJECT'S OWN `Data` IS NOT FOUNDATION'S. This row FAILED before the fix — the content-read arm
    /// was the one free-name family with no shadow guard at all, so a project type that happened to
    /// offer `init(contentsOfFile:)` was charged `Fs` and its `init(contentsOf:)` acquired an `Unknown`.
    /// Both are fabrications on project code; extracting the arm into `chargeContentsCtor` gave it the
    /// `declaredTypes`/`localFreeFns` fence every other family already had.
    func testAProjectDeclaredDataIsNotFoundations() throws {
        let src = """
        import Foundation
        struct Data {
            init(contentsOfFile: String) {}
            init(contentsOf: URL) {}
        }
        func localDataFile(_ p: String) -> Data { _ = Date(); return Data(contentsOfFile: p) }
        func localDataURL(_ u: URL) -> Data { _ = Date(); return Data(contentsOf: u) }
        """
        let r = try scan(src, name: "Local", policy: "deny Fs\n")
        XCTAssertEqual(r.fns["localDataFile"], ["Clock"],
                       "constructing a project's own type reads no file — the Clock marker proves the "
                       + "unit is present and was asked")
        XCTAssertEqual(r.fns["localDataURL"], ["Clock"],
                       "…and it is not an indeterminate URL read either: no hedge, no `Unknown`")
        XCTAssertEqual(r.code, 0, "and the verdict follows the effects: \(r.out)")
    }

    /// **THE SHADOW AND ITS ESCAPE HATCH, IN ONE PROGRAM.** This is the row that makes the shadow guard
    /// above safe to add. A package that declares its own `Data` shadows the BARE ctor — which is what
    /// Swift itself does, resolving a bare name to the module's own type — and reaches Foundation's
    /// through the qualifier, which is the entire reason the qualifier exists. Without the spelling rule
    /// (W1) there would be no way to say "Foundation's" at all, and the shadow guard would be a way to
    /// lose an effect rather than a way to stop fabricating one.
    ///
    /// FILED RESIDUAL, measured while adding the guard: `declaredTypes` is keyed on the SIMPLE NAME and
    /// is PACKAGE-wide, so a NESTED or `fileprivate` declaration shadows further than Swift's own
    /// resolution — swift-syntax's `fileprivate enum Data` (nested in `Node`) silences a bare
    /// `Data(contentsOfFile:)` elsewhere in the same package. That is the fence EVERY κ family uses, not
    /// one this change invented: at ⟨0.32⟩ HEAD a nested `fileprivate enum Pipe` already silenced
    /// `Pipe()` the same way. The qualifier below is the escape hatch for both.
    func testTheQualifierIsTheEscapeHatchFromALocalShadow() throws {
        let src = """
        import Foundation
        enum Data { case x }
        func readsBare(_ p: String) throws -> Foundation.Data { _ = Date(); return try Data(contentsOfFile: p) }
        func readsQualified(_ p: String) throws -> Foundation.Data { _ = Date(); return try Foundation.Data(contentsOfFile: p) }
        """
        let r = try scan(src, name: "Shadow")
        XCTAssertEqual(r.fns["readsBare"], ["Clock"],
                       "a bare `Data` in a package that declares its own names the PROJECT's type — "
                       + "which is how Swift resolves it, so charging `Fs` here fabricates")
        XCTAssertEqual(r.fns["readsQualified"], ["Clock", "Fs"],
                       "…and the qualified spelling names Foundation's, whatever the package declares")
    }

    /// AN EXTENSION IS NOT A DECLARATION. `extension Data {…}` says the project extends FOUNDATION's
    /// type — the ctor it calls is still Foundation's, so the shadow fence is `declaredTypes` and not
    /// `localTypes`. (The same reading W2 applies to `extension Process`.)
    func testAnExtensionOfDataDoesNotShadowTheContentRead() throws {
        let src = """
        import Foundation
        extension Data { var tag: String { "t" } }
        func reads(_ p: String) throws -> Data { _ = Date(); return try Data(contentsOfFile: p) }
        """
        let r = try scan(src, name: "ExtData")
        XCTAssertEqual(r.fns["reads"], ["Clock", "Fs"],
                       "extending a platform type does not make its constructor project code")
    }

    /// THE PROJECT'S OWN MODULE IS NOT AN IMPORTED ONE. Under `@testable import App`, `App.Process()`
    /// and `App.Data(contentsOfFile:)` name the PROJECT's types — `isModuleQualifier` refuses, and the
    /// spelling rule must not reach them. This is the guard ⟨0.32⟩ built; the shared family function
    /// inherits it because the call site is the same, and this row is what says so.
    func testTheProjectsOwnModuleQualifierStaysLocal() throws {
        let src = """
        @testable import App
        import Foundation

        final class Process { init() {} }
        struct Data { init(contentsOfFile: String) {} }

        func ownProc() -> App.Process { _ = Date(); return App.Process() }
        func ownData(_ p: String) -> App.Data { _ = Date(); return App.Data(contentsOfFile: p) }
        """
        let r = try scan(src, name: "App", policy: "deny Exec\ndeny Fs\n")
        XCTAssertEqual(r.fns["ownProc"], ["Clock"],
                       "`App.Process()` under `@testable import App` is the PROJECT's type, not Foundation's")
        XCTAssertEqual(r.fns["ownData"], ["Clock"],
                       "…and so is `App.Data(contentsOfFile:)` — the qualifier names the project's own module")
        XCTAssertEqual(r.code, 0, "neither may move a verdict: \(r.out)")
    }

    /// A READ-BACK / a non-content ctor label gains nothing through either spelling: the arm is keyed on
    /// the ARGUMENT LABEL, and `Data(count:)` allocates a buffer rather than reading anything.
    func testUnrelatedDataConstructorsStayPure() throws {
        let src = """
        import Foundation
        func alloc() -> Data { _ = Date(); return Data(count: 8) }
        func allocQualified() -> Foundation.Data { _ = Date(); return Foundation.Data(count: 8) }
        func fromBytes(_ b: [UInt8]) -> Data { _ = Date(); return Data(b) }
        """
        let r = try scan(src, name: "Alloc")
        for fn in ["alloc", "allocQualified", "fromBytes"] {
            XCTAssertEqual(r.fns[fn], ["Clock"],
                           "\(fn) touches no file and no network — the content-read arm is keyed on the "
                           + "`contentsOf`/`contentsOfFile` label, in BOTH spellings")
        }
    }
}
