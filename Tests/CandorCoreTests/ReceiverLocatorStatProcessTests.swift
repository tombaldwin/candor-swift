import XCTest
import Foundation

/// SOUNDNESS R414 / SPEC ⟨0.37⟩ — **A RECEIVER-FORM PATH STAT NAMED ITS DESTINATION AND WAS SILENT.**
///
/// `FileManager.default.fileExists(atPath: p)` takes its path as an ARGUMENT, and this engine has always
/// marked it: no literal there means the destination is invisible, so the `Fs` surface is incomplete and
/// `allow Fs <benign>` must fail closed. `u.checkResourceIsReachable()` is the SAME syscall spelled on
/// the path itself — and it took the branch reserved for use-verbs on an already-opened handle, where a
/// missing literal is the legitimate split-construct/use shape rather than the masking signal.
///
/// MEASURED on the shipped 0.36.2 binary, ONE VARIABLE — a benign allowed literal beside a
/// caller-controlled `URL`, and nothing else different between the arms:
///
///     paths: ["/tmp/benign"], incomplete: NONE      →  `allow Fs /tmp/benign` EXIT 0
///
/// over a stat of a path the caller chose. The AS-EFF-008 masked-literal evasion, by another spelling.
/// Family-wide: rust's `p.exists()` and java's `f.exists()` were measured silent on the same fixture
/// shape the same day. The cross-engine part is `candor-spec/conformance/gen_stat_locator.py`, whose
/// four arms (`a1arg`/`a2recv`/`a3handle`/`a4local`) are the four groups below.
///
/// **EVERY GATE ARM SCANS ITS OWN TREE, and that is not tidiness.** The first cut of this file put all
/// five functions in ONE package and asserted the gate's exit code over it. The gate answers for the
/// WHOLE scan, so `argMasked` — which was already correct — made the masked arm exit 1 with the fix
/// reverted: a test that passed with AND without the change, reading as coverage. Caught by running it
/// against a rebuilt pre-fix engine rather than by reasoning about it.
///
/// **THE CONTROLS ARE NOT AFTERTHOUGHTS AND BREAKING ONE IS WORSE THAN THE BUG.**
///   * `a3handle` — a `FileHandle` use-verb has NO locator of its own (the path was fixed at the ctor,
///     which this analysis already saw). Marking it would fail every program that opens a file by a
///     literal name. It must still certify.
///   * `a4local` / the determined-receiver arms — ⟨0.37⟩ says a locator whose value is statically
///     determined is determined HOWEVER it reaches the call. A fix keyed on "no literal was captured
///     from the argument list" would have made `URL(fileURLWithPath: "/tmp/benign")` uncertifiable,
///     which is the over-mask the ⟨0.37⟩ ruling draft records for rust and ts on this rung (R416 —
///     cited from that table, not re-measured here). The receiver
///     resolves through the same const / locator-ctor resolver the argument positions use, so these two
///     arms IMPROVE on the pre-fix engine: it recorded no path for them at all.
final class ReceiverLocatorStatProcessTests: XCTestCase {
    private static let ALLOWED = "/tmp/benign"
    private static let allowBenign = "allow Fs \(ALLOWED)\n"
    private static let benignWrite =
        "    try \"x\".write(toFile: \"\(ALLOWED)\", atomically: true, encoding: .utf8)"

    private func scan(_ src: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32, out: String) {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(src, name: name)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = [root.path, "--json"]
        if let policy {
            let p = root.appendingPathComponent("p.pol")
            try policy.write(to: p, atomically: true, encoding: .utf8)
            args += ["--policy", p.path]
        }
        let r = try ProcessHarness.run(bin, args)
        return (try ProcessHarness.fns(ofJson: r.out), r.code, r.out + r.err)
    }

    /// ONE function per tree, and every one of them writes the SAME benign allowed literal first — the
    /// second call is the only variable, within an arm and between arms.
    private static func tree(_ fn: String, _ second: String, param: String = "") -> String {
        """
        import Foundation
        public func \(fn)(\(param)) throws {
        \(benignWrite)
        \(second)
        }
        """
    }

    private static let recvMasked  = tree("recvMasked", "    _ = try? u.checkResourceIsReachable()", param: "_ u: URL")
    private static let argMasked   = tree("argMasked", "    _ = FileManager.default.fileExists(atPath: p)", param: "_ p: String")
    private static let handleUse   = tree("handleUse", "    _ = h.availableData", param: "_ h: FileHandle")
    /// The determined-receiver arms carry NO sibling write ON PURPOSE: the benign literal every other
    /// tree writes would put `/tmp/benign` in `paths` by itself, so the arm would pass without the
    /// receiver ever being read. The only possible source of the path here is the receiver.
    private static let recvInline = """
    import Foundation
    public func recvInline() throws {
        _ = try? URL(fileURLWithPath: "\(ALLOWED)").checkResourceIsReachable()
    }
    """
    private static let recvBound = """
    import Foundation
    public func recvBound() throws {
        let u = URL(fileURLWithPath: "\(ALLOWED)")
        _ = try? u.checkResourceIsReachable()
    }
    """

    // ── a2recv — the defect ──────────────────────────────────────────────────────────────────────────

    /// THE DECISION, not the behaviour: a benign sibling literal must not certify a stat of a
    /// caller-controlled URL. This is the case that exited 0 on 0.36.2, isolated so nothing else in the
    /// tree can make the gate red for another reason.
    func testReceiverFormStatIsNotCertifiedByASiblingLiteral() throws {
        let r = try scan(Self.recvMasked, name: "R414Recv", policy: Self.allowBenign)
        XCTAssertEqual(r.code, 1, "a receiver-form stat of a runtime URL beside a benign literal must NOT certify:\n\(r.out)")
        XCTAssertTrue(r.out.contains("recvMasked"), "the gate must name recvMasked:\n\(r.out)")
    }

    /// The surface itself, not just the verdict: the engine must SAY the destination was invisible. A
    /// gate can go red for the wrong reason (R381's fabricated `"443"` host is the standing example), so
    /// the report is asserted separately from the exit code.
    func testReceiverFormStatMarksTheFsSurfaceIncomplete() throws {
        let r = try scan(Self.recvMasked, name: "R414Surface")
        let recv = try XCTUnwrap(r.fns["recvMasked"], "recvMasked absent:\n\(r.out)")
        XCTAssertEqual(recv["incomplete"] as? [String], ["Fs"],
                       "the receiver was a parameter — the destination is invisible and must be disclosed")
        XCTAssertEqual(recv["paths"] as? [String], [Self.ALLOWED],
                       "the benign sibling is still a real, determined destination and must stay recorded")
        XCTAssertEqual((recv["fs"] as? [String])?.sorted(), ["read", "write"],
                       "the stat is a READ and the sibling a WRITE — neither direction may be dropped")
    }

    // ── a1arg — the discriminator ────────────────────────────────────────────────────────────────────

    /// **CORRECT BEFORE THIS FIX AND AFTER IT, DELIBERATELY.** The argument-form spelling of the same
    /// syscall is what proves the receiver-form silence was a GAP IN THIS ENGINE rather than a rung it
    /// had not reached — the two arms differ in the locator's position and in nothing else. It is here
    /// as the discriminator and as a regression guard; it is NOT evidence for the fix, and it passes
    /// against a pre-fix binary.
    func testArgumentFormStatStillFailsClosed() throws {
        let r = try scan(Self.argMasked, name: "R414Arg", policy: Self.allowBenign)
        XCTAssertEqual(r.code, 1, "the argument-form stat must still fail closed:\n\(r.out)")
        let arg = try XCTUnwrap(r.fns["argMasked"], "argMasked absent:\n\(r.out)")
        XCTAssertEqual(arg["incomplete"] as? [String], ["Fs"], "argument-form: destination invisible")
    }

    // ── a3handle — the over-charge control ───────────────────────────────────────────────────────────

    /// `h.availableData` reads a descriptor opened somewhere this analysis has already seen; it names no
    /// destination of its own. Marking it would fail every program that opens a file by a literal name,
    /// which is worse than the bug this file closes.
    func testHandleUseVerbStillCertifies() throws {
        let r = try scan(Self.handleUse, name: "R414Handle", policy: Self.allowBenign)
        XCTAssertEqual(r.code, 0, "a handle use-verb must still certify under the allowlist:\n\(r.out)")
        let h = try XCTUnwrap(r.fns["handleUse"], "handleUse absent:\n\(r.out)")
        XCTAssertNil(h["incomplete"], "a handle use-verb has no locator of its own — it must not be marked")
        XCTAssertEqual(h["paths"] as? [String], [Self.ALLOWED])
    }

    // ── a4local, in the receiver position — the determined-locator control ───────────────────────────

    /// ⟨0.37⟩'s "DETERMINED IS A PROPERTY OF THE VALUE, NOT OF THE SYNTAX". Both spellings a real
    /// program uses must certify: the ctor written inline on the call, and the ctor bound to a `let`
    /// first (the locator-binder provenance index). The ⟨0.37⟩ ruling draft records rust and ts losing
    /// this on the same rung (R416) — cited, not measured here; what IS measured here is that swift had
    /// half of it already, recording NO path for either spelling before this fix.
    func testDeterminedReceiverStillCertifies() throws {
        for (name, src) in [("R414Inline", Self.recvInline), ("R414Bound", Self.recvBound)] {
            let r = try scan(src, name: name, policy: Self.allowBenign)
            XCTAssertEqual(r.code, 0, "\(name): a determined receiver must certify:\n\(r.out)")
            let f = try XCTUnwrap(r.fns.values.first, "\(name): no function reported:\n\(r.out)")
            XCTAssertNil(f["incomplete"], "\(name): the receiver's value is statically determined")
            XCTAssertEqual(f["paths"] as? [String], [Self.ALLOWED],
                           "\(name): the determined receiver IS the destination and must be recorded")
        }
    }

    /// **THE CERTIFICATION IS REAL, NOT AN ABSENCE.** The arm above passes if the engine records the
    /// path AND it passes if the engine has nothing to check — which is exactly what the pre-fix engine
    /// did: `URL(fileURLWithPath: "/tmp/benign").checkResourceIsReachable()` charged `Fs`, recorded NO
    /// path and claimed the surface complete, so a policy naming a DIFFERENT directory certified it too.
    /// Absence is what a broken engine produces, so the determined arms are paired with a policy that
    /// must REFUSE them.
    func testADeterminedReceiverIsCheckedAgainstThePolicyRatherThanIgnored() throws {
        for (name, src) in [("R414InlineDeny", Self.recvInline), ("R414BoundDeny", Self.recvBound)] {
            let r = try scan(src, name: name, policy: "allow Fs /tmp/somewhere-else\n")
            XCTAssertEqual(r.code, 1, "\(name): a recorded destination outside the allowlist must fail:\n\(r.out)")
            XCTAssertTrue(r.out.contains(Self.ALLOWED), "\(name): the gate must name the destination:\n\(r.out)")
        }
    }

    // ── the capture-NO half ──────────────────────────────────────────────────────────────────────────

    /// **WORDED AS THE ASSUMPTION IT IS, because measuring it demoted it from a finding.** The fix does
    /// not merely add an incompleteness marker: it also stops the ARGUMENT list being read for this
    /// call's locator, on the R385 establishing-yes / capture-no pattern. The reason is that a resource
    /// KEY is not a path, and publishing one would name a destination the program never contacts.
    ///
    /// MEASURED against the pre-fix engine: it did NOT publish `/tmp/evil` either — the picker cannot
    /// read through an array literal, so no member of `URL_FS_MEMBERS` as they are spelled today can
    /// actually reach the fabrication. So this arm is a GUARD ON THE NEXT MEMBER ADDED to that set, not
    /// a repair of a measured fabrication, and only its `incomplete` assertion discriminates the fix.
    func testAResourceKeyIsNotPublishedAsAPath() throws {
        let src = """
        import Foundation
        public func keys(_ u: URL) throws {
            _ = try? u.resourceValues(forKeys: [URLResourceKey(rawValue: "/tmp/evil")])
        }
        """
        let r = try scan(src, name: "R414Fab")
        let f = try XCTUnwrap(r.fns["keys"], "keys absent:\n\(r.out)")
        XCTAssertFalse(((f["paths"] as? [String]) ?? []).contains("/tmp/evil"),
                       "a resource key is not a locator — publishing it fabricates a destination")
        XCTAssertEqual(f["incomplete"] as? [String], ["Fs"],
                       "the receiver is a parameter, so the destination is invisible — say so")
    }
}
