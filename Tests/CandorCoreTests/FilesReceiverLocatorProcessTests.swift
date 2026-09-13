import XCTest
import Foundation

/// SOUNDNESS R418 / SPEC ⟨0.37⟩ — **A `Files` VERB ON A CALLER-SUPPLIED `File` DELETED IT AND THE GATE
/// SAID `policy ✓`.**
///
/// R414 closed this shape for `URL` and left `File`/`Folder`/`Storage` (JohnSundell's Files) open,
/// DELIBERATELY and in writing: the deferral argued the ctor `File(path:)` is already establishing, and
/// that no swift corpus on hand carried a Files dependency, so a fix there would ship unpriced.
///
/// **BOTH HALVES OF THAT WERE WRONG, and the second is the one worth remembering.** The deferral priced
/// the FIX and never priced the HOLE. Pricing the hole took one `git clone`: MEASURED on the shipped
/// 0.37.0 binary, one variable —
///
///     public func purge(_ target: File) throws {
///         try "x".write(toFile: "/tmp/benign", atomically: true, encoding: .utf8)
///         try target.delete()
///     }
///
/// reported `paths: ["/tmp/benign"], incomplete: NONE`, printed **"candor: nothing hidden — every effect
/// sits where its name says it should"**, and `allow Fs /tmp/benign` **EXITED 0** over the deletion of a
/// file the caller chose. The ctor spelling of the same deletion exited 1 on that same binary, which is
/// the discriminator: the engine could always see this family, and declined to read its receiver.
///
/// The "no corpus" half was wrong too — `JohnSundell/Publish` is 95 Swift files, 27 of them importing
/// Files. Against it this change loses NO real path, removes one FABRICATED one (a written
/// `.gitignore`'s CONTENTS had been published as a filesystem path), and newly NAMES five destinations
/// that were invisible.
///
/// **THE CONTROLS, which are the half that can make a fix worse than the bug.**
///   * `determined` — `File(path: "/tmp/benign").delete()` has its locator in plain sight and must still
///     certify. ⟨0.37⟩'s rule is that a DETERMINED value is determined however it reaches the call, so a
///     fix keyed on "no literal in the argument list" would have made every literal-named Files write
///     uncertifiable. This is why `LOCATOR_CTOR_ARG` had to learn `File`/`Folder` in the same change.
///   * `localType` — a project's OWN `struct File` must stay silent. Fabricating Fs on a local type
///     would be an over-charge on ordinary code that happens to name a type `File`.
///   * `twoPathDetermined` — a move whose source AND destination are both visible must certify.
///   * `twoPathMasked` — and a move whose destination is runtime-built must NOT, because certifying off
///     the literal SOURCE is the same masking evasion one locator over. This arm is the reason
///     `move`/`copy`/`rename`/`create*` are excluded from `isReceiverLocatorMember` and answered by
///     `recordFilesTwoPath` instead: for them the receiver is only HALF of a destination.
final class FilesReceiverLocatorProcessTests: XCTestCase {
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

    /// ONE function per tree — the gate answers for the WHOLE scan, so two arms in one package let a
    /// correct arm redden the gate and the test passes with the fix reverted (the mistake recorded in
    /// `ReceiverLocatorStatProcessTests`, inherited here rather than repeated).
    private static func tree(_ fn: String, _ second: String, param: String = "") -> String {
        """
        import Files
        public func \(fn)(\(param)) throws {
        \(benignWrite)
        \(second)
        }
        """
    }

    private static let recvMasked = tree("recvMasked", "    try target.delete()", param: "_ target: File")
    private static let ctorMasked = tree("ctorMasked",
        "    let t = try File(path: victim)\n    try t.delete()", param: "_ victim: String")
    /// NO sibling write in the determined arms ON PURPOSE: the benign literal every masked tree writes
    /// would put `/tmp/benign` in `paths` by itself, and the arm would pass without the receiver ever
    /// being read.
    private static let determined = """
    import Files
    public func determined() throws {
        let t = try File(path: "\(ALLOWED)")
        try t.delete()
    }
    """
    private static let localType = """
    struct File {
        let path: String
        func delete() {}
    }
    public func localType(_ target: File) {
        target.delete()
    }
    """
    /// `copy`, not `rename`, and the difference is load-bearing: `rename` MOVES the receiver's own path
    /// (R419), so a rename arm would go red for two reasons at once and stop isolating the masking. Both
    /// are two-locator verbs; `copy` leaves the receiver where it is.
    private static let twoPathMasked = tree("twoPathMasked",
        "    let s = try File(path: \"\(ALLOWED)\")\n    try s.copy(to: dest)", param: "_ dest: String")
    private static let twoPathDetermined = """
    import Files
    public func twoPathDetermined() throws {
        let s = try File(path: "\(ALLOWED)")
        try s.copy(to: "\(ALLOWED)")
    }
    """

    // ── the defect ───────────────────────────────────────────────────────────────────────────────────

    /// THE DECISION, not the behaviour: a benign sibling literal must not certify the DELETION of a
    /// caller-supplied file. This is the case that exited 0 on the shipped 0.37.0 binary.
    func testAFilesVerbOnACallerSuppliedReceiverIsNotCertifiedByASiblingLiteral() throws {
        let r = try scan(Self.recvMasked, name: "R418Recv", policy: Self.allowBenign)
        XCTAssertEqual(r.code, 1, "deleting a caller-supplied File beside a benign literal must NOT certify:\n\(r.out)")
        XCTAssertTrue(r.out.contains("recvMasked"), "the gate must name recvMasked:\n\(r.out)")
    }

    /// The surface, asserted separately from the verdict — a gate can go red for the wrong reason.
    func testAFilesVerbOnACallerSuppliedReceiverMarksTheSurfaceIncomplete() throws {
        let r = try scan(Self.recvMasked, name: "R418Surface")
        let fn = try XCTUnwrap(r.fns["recvMasked"], "recvMasked absent:\n\(r.out)")
        XCTAssertEqual(fn["incomplete"] as? [String], ["Fs"],
                       "the receiver was a parameter — the destination is invisible and must be disclosed")
        XCTAssertEqual(fn["paths"] as? [String], [Self.ALLOWED],
                       "the benign sibling is still a real destination and must stay recorded")
    }

    /// The DISCRIMINATOR that proves this was a locator-reading gap and not a missing classification:
    /// the ctor spelling of the very same deletion already failed closed before this change. If this
    /// ever regresses, the Files type left the κ table entirely and the receiver arm above is moot.
    func testTheCtorSpellingOfTheSameDeletionAlsoFailsClosed() throws {
        let r = try scan(Self.ctorMasked, name: "R418Ctor", policy: Self.allowBenign)
        XCTAssertEqual(r.code, 1, "a File built from a caller-supplied path must not certify:\n\(r.out)")
    }

    // ── the controls ─────────────────────────────────────────────────────────────────────────────────

    /// ⟨0.37⟩: a DETERMINED locator is determined however it reaches the call. Asserts the PATH, not just
    /// the exit code — an arm that certifies because no effect was recorded at all would pass on the exit
    /// code alone, which is the way this control could rot into vacuity.
    ///
    /// **This one passes against the PRE-FIX engine too, and that is correct, not coverage.** Its job is
    /// to catch an over-mask, so it must hold on both sides; pre-fix the literal reached `paths` from the
    /// `File(path:)` CTOR rather than from the receiver. What proves the receiver itself is now read is
    /// the corpus measurement in this file's header — `Publish` newly NAMES five destinations — not this
    /// assertion. Recorded so a later reader does not mistake a passing control for a defect probe.
    func testADeterminedFilesLocatorStillCertifies() throws {
        let r = try scan(Self.determined, name: "R418Det", policy: Self.allowBenign)
        XCTAssertEqual(r.code, 0, "a File named by a literal must still certify:\n\(r.out)")
        let fn = try XCTUnwrap(r.fns["determined"], "determined absent — nothing was recorded:\n\(r.out)")
        XCTAssertEqual(fn["paths"] as? [String], [Self.ALLOWED],
                       "the receiver's literal must be READ, not merely left unflagged")
        XCTAssertNil(fn["incomplete"], "a locator in plain sight is not an invisible destination")
    }

    /// A project's own `File` type shadows the package's — no charge, no fabrication.
    func testAProjectsOwnFileTypeIsNotChargedFs() throws {
        let r = try scan(Self.localType, name: "R418Local", policy: Self.allowBenign)
        XCTAssertEqual(r.code, 0, "a local struct named File must not be charged Fs:\n\(r.out)")
        XCTAssertNil(r.fns["localType"], "a local type's method is not a filesystem effect:\n\(r.out)")
    }

    // ── the two-locator verbs ────────────────────────────────────────────────────────────────────────

    /// Both locators visible → certifies, and BOTH are published. The `paths` assertion is the one that
    /// matters: a fix that recorded only the receiver would still exit 0 here.
    func testATwoLocatorMoveWithBothEndsVisibleCertifies() throws {
        let r = try scan(Self.twoPathDetermined, name: "R418TwoDet", policy: Self.allowBenign)
        XCTAssertEqual(r.code, 0, "a rename with both ends determined must certify:\n\(r.out)")
        let fn = try XCTUnwrap(r.fns["twoPathDetermined"], "twoPathDetermined absent:\n\(r.out)")
        XCTAssertNil(fn["incomplete"], "both locators were visible:\n\(r.out)")
    }

    /// And the half-visible case must NOT certify off the visible half — the masking evasion one locator
    /// over, and the reason the two-locator verbs are not treated as receiver-locators.
    func testATwoLocatorMoveIsNotCertifiedByItsLiteralSource() throws {
        let r = try scan(Self.twoPathMasked, name: "R418TwoMask", policy: Self.allowBenign)
        XCTAssertEqual(r.code, 1, "a literal SOURCE must not mask a runtime destination:\n\(r.out)")
        let fn = try XCTUnwrap(r.fns["twoPathMasked"], "twoPathMasked absent:\n\(r.out)")
        XCTAssertEqual(fn["incomplete"] as? [String], ["Fs"], "the destination was invisible:\n\(r.out)")
    }
}
