import XCTest
import Foundation

/// **R61 (`ec3e50f`) — SCAN-LEVEL PINS for the three FFI mechanisms that read silent-pure with no
/// disclosure at all**, closed the same day the corpus round that found them ran. `ec3e50f` shipped with
/// zero committed tests: every `native:dlopen` fixture that existed before it (`AdvisoryBoundProcessTests`,
/// `GateReportVerbProcessTests`, `ScopedUnknownRemedyProcessTests`) hand-writes a JSON report string and
/// feeds it straight to `gate`/`fix-gate`/`unverified` — a DOWNSTREAM consumer of a disclosure, never the
/// scan that must PRODUCE one. Reverting `ec3e50f`'s entire production diff in an isolated worktree left
/// all 934 XCTest cases, `smoke.sh`, `fabrication_probe.py` and `fuzz.py` green — confirmed directly, not
/// assumed (candor/bin/AGENT-CORPUS-BRIEF.md "THE ATTACKS THAT WORK" §A, the revert test).
///
/// Three independent mechanisms, three independent isolations — reverting ONE of the three production
/// hunks below must turn exactly its own test red and leave the other two (and every OVER-CHARGE control)
/// green, because the fix commit itself frames them as three separable fixes sharing one vocabulary:
///
///   1. `@_silgen_name`/`@_extern` bodyless C-symbol linkage — isolated in `DeclCollector.swift`'s
///      `ffiNative` field/`lastStringLiteralArgument` plus `Driver.swift`'s body-nil guard. Touches
///      neither `Classifier.swift`'s new constants nor `CallCollector.swift`.
///   2. `dlsym`/`unsafeBitCast` → invocation — isolated ENTIRELY in `CallCollector.swift`'s
///      `unsafeBitCast` detection (the `opaqueFnLocals.insert(name)` arm). Does not read
///      `NATIVE_DISCLOSURE_C_FREE_FNS` at all — a bitcast off a plain parameter, no `dlopen`/`dlsym` call
///      anywhere in the function, still discloses once invoked.
///   3. the raw-syscall allowlist (`system`/`unlink`/… under a `C_PLATFORM_MODULES` import) — isolated in
///      `Classifier.swift`'s two new `public let`s, `Driver.swift`'s `NATIVE_DISCLOSURE_C_FREE_FNS`
///      branch, and `CallCollector.swift`'s `argRef` flag (the RTLD_NOW-as-argument control that keeps
///      this allowlist from misreading a bare-identifier ARGUMENT as a call).
///
/// EVERY DEFECT ROW IS PAIRED WITH ITS OWN OVER-CHARGE CONTROL (rule E), because the fabrication direction
/// this fix must never take is charging a boundary that was never crossed:
///   1. a bodyless declaration that is NOT FFI-linked (an ordinary protocol requirement) must gain
///      nothing, and its CALLER must keep the plain `dispatch:` reason it always had — never a relabelled
///      `native:`.
///   2. a function pointer manufactured by `unsafeBitCast` but never CALLED must gain nothing from the
///      bitcast alone — only an actual invocation is a boundary crossing.
///   3. a call to a project-LOCAL declaration that merely shares one of the allowlisted names (a local
///      `system(_:)`) must resolve to the local declaration, never fall through to the FFI fallback.
final class OpaqueFFIFallbackProcessTests: XCTestCase {

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--json"]
        if let policy {
            let p = root.appendingPathComponent("deny.pol")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        let by = try ProcessHarness.fns(ofJson: r.out)
        return (by, r.code, r.out + r.err)
    }

    // ── FIX 1: @_silgen_name / @_extern bodyless C-symbol linkage ───────────────────────────────────

    /// The defect fixture ALONGSIDE its over-charge control in one tree — they do not collide (a
    /// `@_silgen_name` free function and a protocol requirement share no name), so one scan answers both.
    private static let silgenTree = """
    // FIX 1 DEFECT: a bodyless func wired straight to a native symbol. Before ec3e50f this was the one
    // bodyless shape the Driver's body-nil guard skipped past with NO effect at all — R61's "modelled
    // Process API stayed correctly charged throughout" control for this mechanism is exactly the
    // difference between this and an ordinary protocol requirement below.
    @_silgen_name("system")
    func c_system(_ cmd: UnsafePointer<CChar>) -> Int32

    func runsViaSilgen() {
        "id".withCString { cs in
            _ = c_system(cs)
        }
    }

    // FIX 1 OVER-CHARGE CONTROL: a bodyless declaration that is NOT FFI-linked. A protocol requirement is
    // bodyless for an unrelated reason (it dispatches via CHA, never is itself a call target) and must
    // gain nothing from the FFI seed — and its caller must keep its ORDINARY dispatch: reason, not a
    // relabelled native: one.
    protocol Loader { func load() -> String }
    func useLoader(_ l: Loader) -> String { return l.load() }
    """

    func testSilgenLinkedBodylessDeclarationDisclosesNativeUnknownAndPropagates() throws {
        let r = try scan(Self.silgenTree, name: "Silgen")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "c_system"), ["Unknown"],
                       "a bodyless @_silgen_name declaration IS a real call target with a real, unseeable "
                       + "body — it must not be skipped by the body-nil guard: \(r.out)")
        XCTAssertEqual(r.fns["c_system"]?["unknownWhy"] as? [String], ["native:system"],
                       "the LINKED symbol name, not the Swift-side name, must appear in the disclosure")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "runsViaSilgen"), ["Unknown"],
                       "the caller must inherit Unknown transitively through the ordinary propagate() "
                       + "fixpoint — this silent drop is exactly what R61 found: \(r.out)")
        XCTAssertNil(r.fns["runsViaSilgen"]?["unknownWhy"],
                     "unknownWhy is direct-only (SPEC §4) — the caller must not carry the callee's reason")
    }

    func testBodylessProtocolRequirementGainsNothingFromTheFfiFix() throws {
        let r = try scan(Self.silgenTree, name: "Silgen")
        XCTAssertNil(r.fns["Loader.load"],
                     "an unattributed bodyless protocol requirement is never itself a call target — it "
                     + "must stay absent from `functions` exactly as before the fix")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "useLoader"), ["Unknown"])
        XCTAssertEqual(r.fns["useLoader"]?["unknownWhy"] as? [String], ["dispatch:Loader.load"],
                       "a conformer-less protocol dispatch keeps ITS OWN reason class — a fix that "
                       + "broadened to catch every bodyless unit would relabel this native: instead")
    }

    /// Gated SEPARATELY from `silgenTree`: the over-charge control (`useLoader`) has its OWN honest
    /// `dispatch:` Unknown, which would fire `deny Unknown` on its own and make this gate check pass
    /// whether or not the fix under test exists — exactly the confound rule A warns against ("a test
    /// that passes with and without the fix is worse than none"). This fixture carries ONLY the defect.
    private static let silgenDefectOnly = """
    @_silgen_name("system")
    func c_system(_ cmd: UnsafePointer<CChar>) -> Int32

    func runsViaSilgen() {
        "id".withCString { cs in
            _ = c_system(cs)
        }
    }
    """

    func testTheSilgenDefectFailsDenyUnknown() throws {
        let r = try scan(Self.silgenDefectOnly, name: "SilgenGate", policy: "deny Unknown\n")
        XCTAssertEqual(r.code, 1, "a tree that reaches a native symbol via @_silgen_name must FAIL "
                       + "`deny Unknown` — the verdict is the teeth: \(r.out)")
    }

    // ── FIX 2: dlsym/unsafeBitCast → invocation ──────────────────────────────────────────────────────

    /// No `dlopen`/`dlsym` call anywhere in the defect function — the pointer arrives as a PARAMETER, so
    /// this mechanism cannot be confused with fix 3's allowlist branch, which never fires here at all
    /// (`import Darwin` is not even present). Isolates fix 2 from fix 3 completely.
    private static let bitcastTree = """
    import Darwin

    // FIX 2 DEFECT: an opaque pointer resolved to a function type via unsafeBitCast, then CALLED. Before
    // ec3e50f this fell into the ordinary "plausible dependency factory" heuristic, which is consulted
    // only by a later MEMBER call on the local, never a direct invocation `fn()` — so the call fell all
    // the way through to the free-function fixpoint resolver, matched nothing, and silently vanished.
    func invokeFromRaw(_ raw: UnsafeMutableRawPointer) {
        let fn = unsafeBitCast(raw, to: (@convention(c) () -> Void).self)
        fn()
    }

    // FIX 2 OVER-CHARGE CONTROL: dlopen's result IS bitcast to a function type, but the result is NEVER
    // CALLED. The only disclosure this function may carry is fix 3's own native:dlopen (a real boundary
    // crossing, charged at the dlopen call site regardless of what happens to its result) — the bitcast
    // itself, absent an invocation, must add nothing on top.
    func opensAndCastsButNeverCalls() {
        guard let h = dlopen("/usr/lib/libSystem.dylib", RTLD_NOW) else { return }
        let fn = unsafeBitCast(h, to: (@convention(c) () -> Void).self)
        _ = fn
    }
    """

    func testUnsafeBitCastResolvedFunctionPointerDisclosesCallbackUnknownWhenInvoked() throws {
        let r = try scan(Self.bitcastTree, name: "Bitcast")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "invokeFromRaw"), ["Unknown"],
                       "an unsafeBitCast-resolved function pointer, once actually CALLED, must disclose "
                       + "Unknown — this is a silent-pure defect with no dlopen/dlsym in sight, isolating "
                       + "fix 2 from fix 3's allowlist entirely: \(r.out)")
        XCTAssertEqual(r.fns["invokeFromRaw"]?["unknownWhy"] as? [String], ["callback:fn"],
                       "routed through the SAME opaqueFnLocals machinery a stored opaque closure property "
                       + "already uses — reused infrastructure, not a new disclosure vocabulary")
    }

    func testUnsafeBitCastResultNeverInvokedGainsNothingBeyondItsOwnDlopenCall() throws {
        let r = try scan(Self.bitcastTree, name: "Bitcast")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "opensAndCastsButNeverCalls"), ["Unknown"],
                       "the ONLY effect here comes from the dlopen call itself (fix 3's allowlist) — the "
                       + "bitcast must not double it: \(r.out)")
        XCTAssertEqual(r.fns["opensAndCastsButNeverCalls"]?["unknownWhy"] as? [String], ["native:dlopen"],
                       "must be EXACTLY native:dlopen — a spurious callback:fn here would mean creating "
                       + "an opaque local, without ever calling it, fabricates a disclosure on its own")
    }

    // ── FIX 3: the raw-syscall allowlist, gated on a C-platform import ──────────────────────────────

    /// Kept in its OWN package: a project-local `system(_:)` declared in the SAME file as the real-C-call
    /// defect would shadow it project-wide and silently defeat the very case under test — this is the
    /// sibling-route trap the `ExecCapabilityProcessTests`/`ExtensionShadowConstructorProcessTests` pair
    /// already document (a lookalike type/fn must live in its own tree, never beside the real one).
    private static let rawcDefect = """
    import Darwin

    // FIX 3 DEFECT: a raw C free function under a C-platform import, resolved against NOTHING project-
    // local. Before ec3e50f this measured complete silence — no Unknown, no unresolved, nothing — at
    // exit 0 under `deny Exec`/`deny Fs`.
    func doRm() {
        system("rm -rf /tmp/x")
    }
    """

    private static let rawcControl = """
    import Darwin

    // FIX 3 OVER-CHARGE CONTROL: a project-local declaration that merely SHARES an allowlisted name. The
    // allowlist branch is the Driver's TERMINAL arm, reached only after every resolution arm above it —
    // including the ordinary local free-fn edge — has already failed. A real project `system(_:)` must
    // resolve to itself and stay pure, never fall through to the FFI fallback.
    func system(_ x: Int) -> Int { return x + 1 }
    func usesLocalSystem() -> Int { return system(5) }
    """

    func testRawCPlatformSyscallDisclosesNativeUnknown() throws {
        let r = try scan(Self.rawcDefect, name: "Rawc")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "doRm"), ["Unknown"],
                       "a raw `system(...)` call under `import Darwin`, unresolved against any project "
                       + "declaration, must disclose Unknown — R61's third silent mechanism: \(r.out)")
        XCTAssertEqual(r.fns["doRm"]?["unknownWhy"] as? [String], ["native:system"],
                       "names the SPECIFIC allowlisted syscall, never a generic marker")
    }

    func testLocalDeclarationSharingAnAllowlistedNameStaysGenuinelyClassified() throws {
        let r = try scan(Self.rawcControl, name: "RawcCtrl")
        XCTAssertNil(r.fns["system"],
                     "a pure project-local `system(_:)` must stay absent from `functions` — it is genuine "
                     + "project code, not a C boundary")
        XCTAssertNil(r.fns["usesLocalSystem"],
                     "calling the LOCAL system(_:) must resolve to it and stay pure — the allowlist is a "
                     + "terminal fallback, never a name match that jumps the queue ahead of a real "
                     + "project declaration: \(r.out)")
    }

    func testTheRawcDefectFailsDenyUnknownAndTheControlPasses() throws {
        // NOTE: `deny Exec Fs` alone does NOT fail here — an unresolved Unknown is not itself a denied
        // CONCRETE effect (matching `ScopedUnknownRemedyProcessTests`'s documented gate/unverified split:
        // a bare Unknown PASSES a policy that never named Unknown at all). `deny Unknown` is the policy
        // that actually moves on this disclosure, exactly as it does for fix 1's silgen tree above.
        let defect = try scan(Self.rawcDefect, name: "RawcGate", policy: "deny Unknown\n")
        XCTAssertEqual(defect.code, 1, "a raw `system(...)` call under `import Darwin` must FAIL "
                       + "`deny Unknown` — the verdict is the teeth: \(defect.out)")
        let control = try scan(Self.rawcControl, name: "RawcCtrlGate", policy: "deny Unknown\n")
        XCTAssertEqual(control.code, 0, "a project-local `system(_:)` sharing the name must PASS the "
                       + "identical policy: \(control.out)")
    }
}
