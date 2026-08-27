import XCTest
import Foundation

/// THE TYPE ANALOGUE of `IfConfigShadowProcessTests` — the residual `098a035`'s own CHANGELOG entry
/// filed by name: "the DECLARED-TYPE analogue of this same defect (a `#if`-gated `class`/`struct` of the
/// same name as a κ-platform type shadowing `declaredTypes` the same way) is not addressed here —
/// measured to exist by construction … and left for a separate pass."
///
/// `DeclCollector.pushType` inserted into `declaredTypes` UNCONDITIONALLY — it never consulted
/// `ifConfigDepth`, unlike `FnInfo.isConditionallyCompiled` which `098a035` added for free functions.
/// `declaredTypes` is the fence every κ ctor arm in `CallCollector.visit(FunctionCallExprSyntax)` fences
/// on (the primary `kappaFree` arm, and the Bonjour/EventKit/privacy-capture bare-ctor arms beside it):
///
///     import Foundation
///     #if os(Windows)
///     class Pipe { init() { fatalError("shim") } }
///     #endif
///     func realUsage() -> Pipe { return Pipe() }
///
/// SwiftSyntax carries no build configuration, so this engine reads the Windows-only `Pipe` exactly as
/// visibly as a real definition — permanently shadowing `Ipc` for every build, including the one that
/// never contains it. `deny Ipc` exited 0, `functions` EMPTY — no `Unknown`, no `incomplete`, nothing.
///
/// THE FIX mirrors `098a035` exactly: `DeclCollector.declaredTypesUnconditional` is the subset of
/// `declaredTypes` declared OUTSIDE any `#if` (per-file, aggregated scan-wide in `Driver.swift` the same
/// way). `CallCollector` is now constructed with THAT restricted set as its `declaredTypes` — a name
/// whose only declaration(s) are conditional no longer shadows, while a name with even one unconditional
/// declaration is unaffected. The "ordinary call edge to the conditional declaration" half of the mirror
/// comes FOR FREE: `keepExtensionCtorEdge`'s own guard (`localTypes.contains(name) &&
/// !declaredTypes.contains(name)`) already exists to keep the edge for an extension-only shadow, and a
/// conditional-only type now satisfies that same guard — so its own effects union in beside the κ charge
/// through the exact mechanism the extension case already uses, with no new call-edge plumbing added.
final class IfConfigShadowTypeTests: XCTestCase {

    private func binaryURL() throws -> URL { try ProcessHarness.binaryURL(for: Self.self) }

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try binaryURL()
        let root = try ProcessHarness.makePackage(src, name: "TS")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    // ── 1. THE DEFECT, minimal repro ───────────────────────────────────────────────────────────────
    func testAWindowsOnlyPipeStubNoLongerPermanentlyShadowsTheRealCallersIpcCharge() throws {
        let by = try scan("""
        import Foundation
        #if os(Windows)
        class Pipe { init() { fatalError("shim") } }
        #endif
        func realUsage() -> Pipe { return Pipe() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Ipc"],
                       "the same-file, no-`#else` `#if os(Windows)` stub must not shadow the real "
                       + "Foundation `Pipe` charge: \(by)")
    }

    // ── 2. CONTROL — identical code with the `#if` block removed entirely must be unmoved ────────────
    func testTheSameConstructorWithNoIfBlockAtAllIsUnaffected() throws {
        let by = try scan("""
        import Foundation
        func realUsage() -> Pipe { return Pipe() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Ipc"],
                       "no local declaration at all — the heuristic must fire exactly as before: \(by)")
    }

    // ── 3. CONTROL — an UNCONDITIONAL local type of the same name must STILL shadow ───────────────────
    // The whole reason the fence exists: a project's own `class Pipe`/`class Process` must never be
    // fabricated as the platform type. Narrowing the shadow to the conditional case must not regress this.
    func testAnUnconditionalLocalPipeStillShadowsTheHeuristic() throws {
        let by = try scan("""
        import Foundation
        class Pipe { init() { } }
        func realUsage() -> Pipe { return Pipe() }
        """)
        XCTAssertNil(by["realUsage"], "an unconditional local `Pipe` is a real, unambiguous "
                     + "declaration — it must shadow the heuristic and resolve to its own (pure) init, "
                     + "not fabricate Ipc: \(by)")
    }

    // ── 4. UNION, not a silent drop — the conditional declaration's OWN effects still count ──────────
    func testTheConditionalDeclarationsOwnEffectStillCountsAlongsideTheHeuristic() throws {
        let by = try scan("""
        import Foundation
        #if os(Windows)
        class Pipe {
            init() { NSLog("windows shim reached") }
        }
        #endif
        func realUsage() -> Pipe { return Pipe() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Ipc", "Log"],
                       "the heuristic's Ipc and the conditional stub's own Log must UNION — resolution "
                       + "is conditional here, not failed, so this is not a pick-one situation: \(by)")
    }

    // ── 5. THE Bonjour/EventKit/privacy-capture bare-ctor arms share the SAME fence ───────────────────
    // 098a035's own residual note flagged these as sharing `localFreeFns` but not the union — for
    // TYPES the fence is `declaredTypes`, shared by all four κ ctor arms, so narrowing it fixes every
    // one uniformly. Proven here rather than assumed: an `#if`-gated `AVCaptureDevice` stub must not
    // silence the camera/mic over-disclosure.
    func testAWindowsOnlyAVCaptureDeviceStubDoesNotSilenceThePrivacyDisclosure() throws {
        let by = try scan("""
        import AVFoundation
        #if os(Windows)
        class AVCaptureDevice { init() { } }
        #endif
        func realUsage() -> AVCaptureDevice { return AVCaptureDevice() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Camera", "Mic"],
                       "an `#if`-gated stub of a privacy-capture type name must not silence the "
                       + "camera/mic over-disclosure: \(by)")
    }

    func testAWindowsOnlyEKEventStoreStubDoesNotSilenceThePrivacyDisclosure() throws {
        let by = try scan("""
        import EventKit
        #if os(Windows)
        class EKEventStore { init() { } }
        #endif
        func realUsage() -> EKEventStore { return EKEventStore() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Calendar", "Reminders"],
                       "an `#if`-gated stub of the EventKit store type name must not silence the "
                       + "calendar/reminders over-disclosure: \(by)")
    }

    func testAWindowsOnlyNWBrowserStubDoesNotSilenceTheBonjourDisclosure() throws {
        let by = try scan("""
        import Network
        #if os(Windows)
        class NWBrowser { init() { } }
        #endif
        func realUsage() -> NWBrowser { return NWBrowser() }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Net"],
                       "an `#if`-gated stub of the Bonjour browser type name must not silence the "
                       + "Net disclosure: \(by)")
    }

    // ── 6. THE `Data`/`NSData`/`String` CONTENT-READ CTOR SHARES THE SAME FENCE, BUT NOT THE SAME ARM ──
    // `chargeContentsCtor` (the shared Data/String(contentsOfFile:/contentsOf:) family) has its own
    // `declaredTypes` bail-out, separate from the four bare-ctor arms above — found by a review pass
    // after this fix's first cut, WORSE than the other four: it does not even fall through to an
    // ordinary (if unresolved) call edge, it returns straight out with NOTHING charged at all.
    func testAWindowsOnlyDataStubDoesNotSilenceTheContentsOfFileFsCharge() throws {
        let by = try scan("""
        import Foundation
        #if os(Windows)
        struct Data { init(contentsOfFile: String) { fatalError("shim") } }
        #endif
        func realUsage(path: String) -> Data { return Data(contentsOfFile: path) }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Fs"],
                       "the same-file, no-`#else` `#if os(Windows)` stub must not shadow the real "
                       + "`Data(contentsOfFile:)` Fs charge: \(by)")
    }

    func testAnUnconditionalLocalDataStillShadowsTheContentsOfFileHeuristic() throws {
        let by = try scan("""
        import Foundation
        struct Data { init(contentsOfFile: String) { } }
        func realUsage(path: String) -> Data { return Data(contentsOfFile: path) }
        """)
        XCTAssertNil(by["realUsage"], "an unconditional local `Data` is a real, unambiguous "
                     + "declaration — it must shadow the heuristic and resolve to its own (pure) init, "
                     + "not fabricate Fs: \(by)")
    }

    func testTheConditionalDataDeclarationsOwnEffectStillCountsAlongsideFs() throws {
        let by = try scan("""
        import Foundation
        #if os(Windows)
        struct Data {
            init(contentsOfFile: String) { NSLog("windows shim reached") }
        }
        #endif
        func realUsage(path: String) -> Data { return Data(contentsOfFile: path) }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "realUsage"), ["Fs", "Log"],
                       "the heuristic's Fs and the conditional stub's own Log must UNION: \(by)")
    }
}
