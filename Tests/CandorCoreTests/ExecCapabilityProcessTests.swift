import XCTest
import Foundation

/// **SPEC §1 ⟨0.32⟩ — `Exec` REACHES THE SUBPROCESS CAPABILITY, NOT ONLY THE LAUNCH.**
///
/// An invocation object carries its OWN payload — program, argv, environment — and travels fully armed,
/// so the function that ARMS one holds the capability exactly as the one that spawns does. Two measured
/// silent under-reports in this engine, both found while candor-java's PART 66 cell was being built
/// (candor-spec SOUNDNESS.md, 2026-08-24 row):
///
///   S1  CONFIGURATION of a RECEIVED invocation was not charged at all. `func f(_ t: Process) {
///       t.arguments = ["-x"] }` reported NO EFFECT — absent from `functions`, which under ⟨0.21⟩ is a
///       purity claim — and passed `deny Exec` at exit 0. The engine charged CONSTRUCTION (`Process()`)
///       and an enumerated list of LAUNCH verbs, and everything between them read pure. That is java's
///       gap in the opposite direction and it has the same cause: an ALLOWLIST under-reports every verb
///       nobody enumerated, which is why §1 ⟨0.32⟩ states the carve-outs as a DENYLIST and forbids the
///       enumeration.
///
///   S2  A QUALIFIED SPELLING of the same constructor was invisible. `Foundation.Process()` reported
///       nothing where the bare `Process()` reported `Exec` — one spelling of one constructor visible
///       and the other not, the sibling-route defect this project has recorded repeatedly. It cost the
///       receiver too: `let t = Foundation.Process(); try t.run()` typed `t` as nothing, so the LAUNCH
///       went silent as well.
///
/// **THE CONTROLS WERE WRITTEN FIRST AND ARE HALF THIS FILE**, because a whole-type rule is trivially
/// satisfied by charging MORE, and killing an under-report is exactly where an over-charge gets
/// introduced (the same trade the `ExecLocatorOverwrite` suite documents from the other side):
///
///   · `readBack` — Swift spells a setter and its read-back with ONE name, so the property GET is the
///     carve-out that java keys on the descriptor. Reading `t.arguments` back arms nothing.
///   · `lookalike` — a project-local type that merely shares the name gains nothing, verdict included.
///   · `unrelatedRequest` — a NON-invocation Foundation type whose property writes stay pure: an option
///     builder's resource arrives at the terminal verb, which is charged at its own call site (the
///     boundary §1 ⟨0.32⟩ draws around this rule).
///   · every control carries a CLOCK MARKER and is asserted PRESENT with a non-empty effect set — pure
///     units are omitted from a report, so "absent" would pass a control that asked nothing (PART 37 (e)).
///
/// TWO ROWS AT THE END WERE EXPECTED-FAILURE RATCHETS, not omissions: residuals ⟨0.32⟩ MEASURED and
/// deliberately did not fix, each with the reason its obvious fix is worse. They fail if the defect is
/// ever closed, so they cannot outlive it — and the SPELLING one no longer does. It is now a positive
/// parity assertion (`testAQualifiedSpellingReachesTheDeclReferenceKeyedCtorArms`), with the loop form
/// in `ModuleQualifierSpellingProcessTests`. The `extension Process` shadow below is still open.
final class ExecCapabilityProcessTests: XCTestCase {

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

    // ── the capability tree ──────────────────────────────────────────────────────────────────────
    private static let cap = """
    import Foundation

    typealias Job = Process

    // S1 — CONFIGURING a RECEIVED invocation. Every one of these reported NO EFFECT AT ALL.
    func configuredArgs(_ t: Process) { t.arguments = ["-x"] }
    func configuredExe(_ t: Process, _ u: URL) { t.executableURL = u }
    func configuredLaunchPath(_ t: Process, _ p: String) { t.launchPath = p }
    func configuredCwd(_ t: Process, _ u: URL) { t.currentDirectoryURL = u }
    func configuredStdin(_ t: Process, _ p: Pipe) { t.standardInput = p }
    func configuredStdout(_ t: Process, _ p: Pipe) { t.standardOutput = p }
    func configuredStderr(_ t: Process, _ p: Pipe) { t.standardError = p }
    func configuredHandler(_ t: Process) { t.terminationHandler = { _ in } }

    // …and `environment` is the ONE named carve-out that is REDIRECTED rather than dropped: arming a
    // child's environment is `Env`, matching java's ruling on `ProcessBuilder.environment()`.
    func configuredEnv(_ t: Process, _ e: [String: String]) { t.environment = e }

    // the CONTROL verbs on a live child — `suspend`/`resume` were simply not in the enumerated list
    func controlled(_ t: Process) { t.suspend(); t.resume() }

    // THE SHAPE REAL CODE USES, and the one the corpus A/B actually hit (swift-syntax's ProcessRunner):
    // the handle is a STORED PROPERTY armed in one method and launched from another.
    final class Runner {
        private let child: Process = Process()
        func arm(_ argv: [String]) { child.arguments = argv }
        func armExplicit(_ argv: [String]) { self.child.arguments = argv }
    }

    // S2 — the QUALIFIED spelling of the very same constructor
    func qualifiedCtor() -> Foundation.Process { _ = Date(); return Foundation.Process() }
    func qualifiedThenLaunched() throws { _ = Date(); let t = Foundation.Process(); try t.run() }
    func qualifiedClock() -> Foundation.Date { return Foundation.Date() }
    func qualifiedRand() -> Foundation.UUID { return Foundation.UUID() }
    func qualifiedFs() -> Foundation.FileHandle? { _ = Date(); return Foundation.FileHandle(forReadingAtPath: "/tmp/x") }
    func qualifiedUnknown() -> Foundation.NumberFormatter { _ = Date(); return Foundation.NumberFormatter() }

    // already green BEFORE the fix — they must stay green after it
    func armed(_ p: String) -> Process { let t = Process(); t.executableURL = URL(fileURLWithPath: p); return t }
    func launched(_ t: Process) throws { try t.run() }
    func aliasedCtor() -> Job { _ = Date(); return Job() }

    // ── THE OVER-CHARGE CONTROLS ─────────────────────────────────────────────────────────────────
    // a READ-BACK arms nothing. Swift gives the setter and the getter one name, so this is the
    // property-GET half of java's descriptor carve-out.
    func readBack(_ t: Process) -> [String]? { _ = Date(); return t.arguments }
    func readBackState(_ t: Process) -> Int32 { _ = Date(); if t.isRunning { return t.processIdentifier }; return t.terminationStatus }
    // a NON-invocation Foundation type: an option builder's resource arrives at the terminal verb.
    func unrelatedRequest(_ u: URL) -> URLRequest { _ = Date(); var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 5; return r }
    func unrelatedQualified() -> URL { _ = Date(); return Foundation.URL(fileURLWithPath: "/tmp/x") }
    """

    // ── the lookalike tree: a PROJECT-LOCAL type that merely shares the name ─────────────────────
    private static let look = """
    import Foundation

    final class Process {
        var argv: [String] = []
        var environment: [String: String] = [:]
        init() {}
        func run() {}
    }

    func lookalike() -> Process { _ = Date(); let p = Process(); p.argv = ["-x"]; p.run(); return p }
    func lookalikeEnv(_ p: Process, _ e: [String: String]) { _ = Date(); p.environment = e }
    """

    /// S1 — CONFIGURING a received invocation is the capability, and it was charged NOWHERE.
    func testConfiguringAReceivedInvocationIsCharged() throws {
        let r = try scan(Self.cap, name: "Cap")
        for fn in ["configuredArgs", "configuredExe", "configuredLaunchPath", "configuredCwd",
                   "configuredStdin", "configuredStdout", "configuredStderr", "configuredHandler"] {
            XCTAssertEqual(r.fns[fn], ["Exec"],
                           "\(fn) arms a subprocess handed to it and travels fully armed — splitting build "
                           + "from launch across two functions must not make the builder invisible (§1 ⟨0.32⟩)")
        }
        XCTAssertEqual(r.fns["controlled"], ["Exec"],
                       "suspend/resume control a LIVE child; they were absent from the enumerated verb list, "
                       + "which is the failure mode an allowlist has")
        for fn in ["Runner.arm", "Runner.armExplicit"] {
            XCTAssertEqual(r.fns[fn], ["Exec"],
                           "\(fn) arms a handle held as a STORED PROPERTY — the shape the corpus A/B hit "
                           + "(swift-syntax's ProcessRunner arms in the init and launches in run()), and "
                           + "the one a param-only fixture would never have asked about")
        }
    }

    /// `environment` is the named carve-out that REDIRECTS — java's ruling, not a drop.
    func testArmingTheChildEnvironmentIsEnvNotExec() throws {
        let r = try scan(Self.cap, name: "Cap")
        XCTAssertEqual(r.fns["configuredEnv"], ["Env"],
                       "`ProcessBuilder.environment()` stays `Env` in the reference engine; a carve-out that "
                       + "DROPPED the effect instead of redirecting it would be the cardinal sin wearing a "
                       + "carve-out's clothes")
    }

    /// S2 — every spelling that reaches one constructor must answer the same.
    func testAQualifiedSpellingAnswersTheSameAsTheBareOne() throws {
        let r = try scan(Self.cap, name: "Cap")
        XCTAssertEqual(r.fns["qualifiedCtor"], ["Clock", "Exec"],
                       "`Foundation.Process()` IS `Process()` — one spelling visible and the other not is "
                       + "the sibling-route defect")
        XCTAssertEqual(r.fns["qualifiedThenLaunched"], ["Clock", "Exec"],
                       "the invisible ctor cost the RECEIVER too: `t` typed as nothing, so `t.run()` — an "
                       + "actual launch — was silent as well")
        // THE RULE IS THE INVARIANT, NOT THE ROW THAT WAS FOUND BROKEN. A module qualifier is a spelling
        // of the bare name for EVERY κ constructor, so each family the free-call path classifies is
        // asserted here — otherwise the next one to be spelled `Module.X()` is silent again and nothing
        // in this repo would say so.
        XCTAssertEqual(r.fns["qualifiedClock"], ["Clock"],
                       "the rule is about SPELLINGS, not about Process: `Foundation.Date()` reads the clock "
                       + "exactly as `Date()` does")
        XCTAssertEqual(r.fns["qualifiedRand"], ["Rand"], "`Foundation.UUID()` draws v4 entropy")
        XCTAssertEqual(r.fns["qualifiedFs"], ["Clock", "Fs"], "`Foundation.FileHandle(forReadingAtPath:)` opens an fd")
        XCTAssertEqual(r.fns["qualifiedUnknown"], ["Clock"],
                       "…and a qualified ctor κ does NOT know gains nothing: the rule adds the spellings "
                       + "that were invisible, it does not invent effects for the rest")
        XCTAssertEqual(r.fns["aliasedCtor"], ["Clock", "Exec"],
                       "the typealias spelling already agreed — it must still")
    }

    /// The rows that were green BEFORE. A fix that quietly moved them would be trading one silence for
    /// another.
    func testConstructionAndLaunchAreUntouched() throws {
        let r = try scan(Self.cap, name: "Cap")
        XCTAssertEqual(r.fns["armed"], ["Exec"], "constructing the handle was always the Exec intent")
        XCTAssertEqual(r.fns["launched"], ["Exec"], "the launch verb was always charged")
    }

    /// THE OVER-CHARGE CONTROLS. Without these every row above passes on an engine that answers `Exec`
    /// for everything, which is useless.
    func testAReadBackAndAnUnrelatedTypeGainNothing() throws {
        let r = try scan(Self.cap, name: "Cap")
        XCTAssertEqual(r.fns["readBack"], ["Clock"],
                       "reading `t.arguments` BACK arms nothing — and the Clock marker proves the unit is "
                       + "present and was asked, rather than absent and asking nothing")
        XCTAssertEqual(r.fns["readBackState"], ["Clock"],
                       "`isRunning`/`processIdentifier`/`terminationStatus` are resident-state reads")
        XCTAssertEqual(r.fns["unrelatedRequest"], ["Clock"],
                       "a URLRequest's property writes stay pure: its resource arrives at the terminal verb, "
                       + "which is charged at its own call site — the boundary §1 ⟨0.32⟩ draws")
        XCTAssertEqual(r.fns["unrelatedQualified"], ["Clock"],
                       "the module-qualified spelling must not turn an unrelated Foundation ctor effectful")
    }

    /// THE LOOKALIKE, effects AND verdict. A project's own `Process` is not Foundation's.
    func testAProjectLocalTypeSharingTheNameStaysPure() throws {
        let r = try scan(Self.look, name: "Look", policy: "deny Exec\n")
        XCTAssertEqual(r.fns["lookalike"], ["Clock"],
                       "a locally DECLARED type always shadows the platform table — constructing, "
                       + "configuring and calling it is project code")
        XCTAssertEqual(r.fns["lookalikeEnv"], ["Clock"],
                       "…including the property write that would have been the `Env` carve-out")
        XCTAssertEqual(r.code, 0, "the lookalike tree under `deny Exec` must PASS: \(r.out)")
    }

    /// THE VERDICT IS THE TEETH. An effect that does not move a gate has not been charged where it counts.
    func testTheCapabilityTreeFailsDenyExec() throws {
        let r = try scan(Self.cap, name: "Cap", policy: "deny Exec\n")
        XCTAssertEqual(r.code, 1, "a tree that arms subprocesses must FAIL `deny Exec`: \(r.out)")
    }

    /// `XCTExpectFailure` is Darwin-XCTest only; swift-corelibs-xctest (Linux) does not ship it, and a
    /// bare call is a COMPILE error there rather than a runtime skip. Same shape as
    /// `NetLocatorProvenanceProcessTests.expectKnownFailure`, for the same reason.
    private func expectKnownFailure(_ reason: String) throws {
        #if canImport(Darwin)
        XCTExpectFailure(reason)
        #else
        throw XCTSkip("\(reason) — ratchet held on the macOS leg; XCTExpectFailure is unavailable in swift-corelibs-xctest")
        #endif
    }

    /// **A MEASURED, UNFIXED RESIDUAL, FOUND BY THIS CHANGE'S CORPUS A/B — filed here so it is tracked
    /// rather than remembered.** An `extension Process` ANYWHERE in the scanned target puts `Process`
    /// into `localTypes`, and the free-call κ path shadows on `localTypes` — so the CONSTRUCTOR
    /// `Process()` reads pure across the whole target. The member-call path already reasons correctly
    /// about this (it shadows on `declaredTypes`, because an extension of a platform type is not a
    /// project type), so the two paths answer the same question differently: the sibling-route shape.
    ///
    /// MEASURED ON REAL CODE, not hypothetically: swift-syntax has one `extension Process` (in
    /// `Logger.swift`) and its `ProcessRunner.init` — `process = Process()` followed by three
    /// configuring writes — reported `Env` alone before this change. It reports `Exec` now only because
    /// the CONFIGURATION half is charged; the construction is still invisible, and a class that ONLY
    /// constructs would still read pure.
    ///
    /// **NOT FIXED HERE BECAUSE THE OBVIOUS FIX IS A REGRESSION, AND THAT WAS MEASURED TOO.** Swapping
    /// the guard to `declaredTypes` makes κ answer — and DROPS the local call edge the fall-through arm
    /// was providing, because an extension may supply a `convenience init`. A/B'd over the same corpus:
    /// 91 firebase-ios-sdk units changed, and the majority LOST a true `Env` that had been arriving
    /// through that edge. Killing a silent under-report is exactly where a silent under-report gets
    /// introduced. The real fix charges κ *and* keeps a soft edge to `<Type>.init`, and it needs its own
    /// A/B — it moves every κ ctor in every target that extends a platform type, not just `Process`.
    func testExtensionOnlyLocalTypeStillShadowsTheConstructor() throws {
        try expectKnownFailure("an `extension Process` zeroes `Process()` target-wide — free-call κ "
                               + "shadows on localTypes where the member path shadows on declaredTypes")
        let src = """
        import Foundation
        extension Process { var tag: String { "t" } }
        func makesOnly() -> Process { _ = Date(); return Process() }
        """
        let r = try scan(src, name: "Ext")
        XCTAssertEqual(r.fns["makesOnly"], ["Clock", "Exec"],
                       "constructing a subprocess handle is `Exec` whether or not the project happens to "
                       + "extend the type")
    }

    /// **THE SECOND RESIDUAL OF THE SPELLING RULE — RATCHET CLOSED.** ⟨0.32⟩'s spelling rule reached the
    /// κ FREE-CALL table (`kappaFree` and the three privacy/bonjour ctor families), which is where
    /// `Process` lives, but NOT the ctor arm keyed directly on a `DeclReferenceExpr` callee earlier in
    /// the same visitor — so `Foundation.Data(contentsOf: url)` read `Clock` alone where
    /// `Data(contentsOf: url)` disclosed `Unknown`, and the https form lost `Net` outright.
    ///
    /// The fix is the one this ratchet named, at the level it named: the content-read arm is now a
    /// FUNCTION (`chargeContentsCtor`) that BOTH spellings call, so the two cannot answer differently
    /// about the same program. It is NOT the literal "normalise the callee at the top of the visitor",
    /// and the reason is structural rather than aesthetic: that visitor's `DeclReferenceExpr` branch
    /// also holds the LOCAL-NAME arms (a fn-typed param, a stored closure property, a `callAsFunction`
    /// value), and its member-access sibling is what carries `extOwner` into the §2 dependency join —
    /// routing a qualified callee through the bare branch would hand `DepModule.factory()` to arms that
    /// reason about local bindings and would drop that join. `chargeModuleQualifiedSpelling` IS the
    /// normalisation point; what changed is that every family it runs is now a shared function.
    ///
    /// THE ANSWER ASSERTED HERE IS NOT THE ONE THIS ROW ORIGINALLY EXPECTED, and that is the second
    /// finding. It said `Fs, Net` — written from the defect rather than from the classifier — so the
    /// row would have gone on "passing" as a ratchet long after the defect was closed, because the
    /// wrong expectation kept failing. An unresolvable URL is EITHER a file or a remote endpoint, and
    /// claiming both fabricates one of them, so the bare spelling discloses `Unknown`. PARITY with the
    /// bare spelling, whatever it says, is the invariant; the loop form of it lives in
    /// `ModuleQualifierSpellingProcessTests`.
    func testAQualifiedSpellingReachesTheDeclReferenceKeyedCtorArms() throws {
        let src = """
        import Foundation
        func readsBare(_ u: URL) throws -> Data { _ = Date(); return try Data(contentsOf: u) }
        func readsQualified(_ u: URL) throws -> Data { _ = Date(); return try Foundation.Data(contentsOf: u) }
        func readsQualifiedFile(_ p: String) throws -> String { _ = Date(); return try Foundation.String(contentsOfFile: p) }
        """
        let r = try scan(src, name: "Q")
        XCTAssertEqual(r.fns["readsQualified"], r.fns["readsBare"],
                       "`Foundation.Data(contentsOf:)` reads a file or a URL exactly as `Data(contentsOf:)` "
                       + "does — the qualifier is a spelling")
        XCTAssertEqual(r.fns["readsQualified"], ["Clock", "Unknown"],
                       "…and the shared answer is the honest one: I/O happens and its category is unprovable")
        XCTAssertEqual(r.fns["readsQualifiedFile"], ["Clock", "Fs"],
                       "a PATH read has no scheme to resolve — unconditionally `Fs`, in either spelling")
    }

    /// The gate-level form of S1 ALONE — the configuring function with no construction and no launch
    /// anywhere in the tree. This is the exact shape that passed at exit 0.
    func testAConfigureOnlyTreeFailsDenyExec() throws {
        let src = """
        import Foundation
        func arm(_ t: Process, _ argv: [String]) { t.arguments = argv }
        """
        let r = try scan(src, name: "Only", policy: "deny Exec\n")
        XCTAssertEqual(r.code, 1,
                       "the whole tree's only subprocess contact is one property write on a received "
                       + "handle, and it certified clean at exit 0: \(r.out)")
    }
}
