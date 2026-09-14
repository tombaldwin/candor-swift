import XCTest
import Foundation

/// SOUNDNESS R419 — **A MUTATING CALL MOVED THE LOCATOR AND THE BINDER'S ORIGINAL LITERAL WENT ON BEING
/// PUBLISHED AS THE DESTINATION.**
///
/// `LocatorMoveScanner` recorded assignment, compound assignment, `&inout`, property writes and binder
/// counts — everything that can rebind a name EXCEPT a method call on it. A `URL` is a VALUE type whose
/// path is edited in place, so `locatorNameIsStable` answered *stable* for a name whose path had just
/// been rewritten, and the literal from the binder was published with `incomplete` absent.
///
/// MEASURED on the shipped 0.37.0 binary, three fixtures, each one variable:
///
///     var u = URL(fileURLWithPath: "/bin"); u.appendPathComponent(s)
///     p.executableURL = u; try p.run()      → cmds ["/bin"], incomplete NONE, `allow Exec /bin` EXIT 0
///
///     var u = URL(fileURLWithPath: "/tmp/benign"); u.appendPathComponent(s)
///     try "x".write(to: u, …)               → paths ["/tmp/benign"] for a write to /tmp/benign/<caller>
///
///     var u = URL(fileURLWithPath: "/tmp/benign/a/b/c"); u.deleteLastPathComponent() ×3
///     try "x".write(to: u, …)               → paths ["/tmp/benign/a/b/c"] for a write to /tmp
///
/// The Exec arm is a GATE BYPASS and it PRE-DATES ⟨0.37⟩. The Fs arms are worse than silence: a positive
/// claim about a path the program never touches, which the corpus brief ranks above a missing one.
///
/// **THE FIX IS AN ALLOWLIST AND THAT IS THE UNCOMFORTABLE DIRECTION, so it is stated.** The sound
/// default has to be "this call moved the path", because the movers are ordinary Foundation spellings
/// and a list of MOVERS would have to be complete to be sound — the hand-list vein this engine has been
/// bitten by repeatedly, and it has no type checker to fall back on. So an unknown member call on a
/// locator name REFUSES the claim, and the allowlist carves out only what is proven not to move a path.
///
/// **THE KIND OF THE BINDER DECIDES WHETHER CALLS COUNT AT ALL.** For a `Process` — a CLASS — no method
/// call can change which object the name denotes, so `p.run()`/`p.waitUntilExit()` must NOT invalidate
/// the command recorded by an earlier `executableURL` write. That consumer passes `inertCalls: nil`, and
/// `testConfigureThenLaunchStillCertifies` is the arm that fails if anyone makes the rule global.
final class LocatorMoveOnMutatingCallTests: XCTestCase {
    private static let allowExecBin = "allow Exec /bin\n"
    private static let allowBenignFs = "allow Fs /tmp/benign\n"

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

    // ── the defect: Exec, the half that is a live gate bypass ────────────────────────────────────────

    private static let execMoved = """
    import Foundation
    public func launch(_ s: String) throws {
        var u = URL(fileURLWithPath: "/bin")
        u.appendPathComponent(s)
        let p = Process()
        p.executableURL = u
        try p.run()
    }
    """

    func testAMutatedExecutableURLIsNotCertifiedByItsOriginalLiteral() throws {
        let r = try scan(Self.execMoved, name: "R419Exec", policy: Self.allowExecBin)
        XCTAssertEqual(r.code, 1, "`allow Exec /bin` must not certify /bin/<caller-supplied>:\n\(r.out)")
    }

    /// The CLAIM, not just the verdict. Withdrawing the literal is the point: the engine cannot know the
    /// true destination, so it must say so rather than name the wrong one. Asserting `cmds` is absent is
    /// what distinguishes this fix from one that merely reddened the gate.
    func testAMutatedExecutableURLWithdrawsTheFabricatedCommand() throws {
        let r = try scan(Self.execMoved, name: "R419ExecClaim")
        let fn = try XCTUnwrap(r.fns["launch"], "launch absent:\n\(r.out)")
        XCTAssertEqual(fn["incomplete"] as? [String], ["Exec"], "the program is invisible and must be disclosed")
        XCTAssertNil(fn["cmds"], "`/bin` was NOT the program executed — publishing it is a fabrication:\n\(r.out)")
    }

    // ── the defect: Fs, where a wrong claim replaces silence ─────────────────────────────────────────

    func testAnAppendedPathComponentWithdrawsTheBindersLiteral() throws {
        let src = """
        import Foundation
        public func save(_ s: String) throws {
            var u = URL(fileURLWithPath: "/tmp/benign")
            u.appendPathComponent(s)
            try "x".write(to: u, atomically: true, encoding: .utf8)
        }
        """
        let r = try scan(src, name: "R419Fs", policy: Self.allowBenignFs)
        XCTAssertEqual(r.code, 1, "the true destination is /tmp/benign/<caller>:\n\(r.out)")
        let fn = try XCTUnwrap(r.fns["save"], "save absent:\n\(r.out)")
        XCTAssertNil(fn["paths"], "/tmp/benign is not where this writes:\n\(r.out)")
    }

    /// Traversal UPWARD, which the append arm would not catch: three `deleteLastPathComponent()` calls
    /// leave the write in `/tmp`, while the published path was the deepest one. A fix keyed on "a
    /// component was added" would pass the arm above and fail this one.
    func testDeletingPathComponentsWithdrawsTheBindersLiteral() throws {
        let src = """
        import Foundation
        public func climb() throws {
            var u = URL(fileURLWithPath: "/tmp/benign/a/b/c")
            u.deleteLastPathComponent()
            u.deleteLastPathComponent()
            u.deleteLastPathComponent()
            try "x".write(to: u, atomically: true, encoding: .utf8)
        }
        """
        let r = try scan(src, name: "R419Up", policy: Self.allowBenignFs)
        XCTAssertEqual(r.code, 1, "this writes to /tmp, not to the deepest path:\n\(r.out)")
        let fn = try XCTUnwrap(r.fns["climb"], "climb absent:\n\(r.out)")
        XCTAssertNil(fn["paths"], "the published path was one the program never touches:\n\(r.out)")
    }

    // ── the controls, which are where an allowlist-shaped fix does its damage ────────────────────────

    /// A `Process` is a CLASS. If call-invalidation is ever made global, THIS is the arm that fails —
    /// `p.run()` is a call on `p`, and configure-then-launch is the shape the whole Exec provenance path
    /// exists to read.
    func testConfigureThenLaunchStillCertifies() throws {
        let src = """
        import Foundation
        public func launch() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ls")
            p.arguments = ["-l"]
            try p.run()
            p.waitUntilExit()
        }
        """
        let r = try scan(src, name: "R419Proc", policy: "allow Exec /bin/ls\n")
        XCTAssertEqual(r.code, 0, "a literal program configured then launched must still certify:\n\(r.out)")
        let fn = try XCTUnwrap(r.fns["launch"], "launch absent — nothing was recorded:\n\(r.out)")
        XCTAssertEqual(fn["cmds"] as? [String], ["/bin/ls"], "the command must be READ, not merely unflagged")
    }

    /// A stat verb on a determined `URL` must survive: ⟨0.37⟩ reads the RECEIVER for these, so treating
    /// one as a move would make a locator in plain sight uncertifiable — R414's own control, broken by a
    /// fix for the row next to it. This arm is why `URL_FS_MEMBERS` is in the inert-call allowlist.
    func testAStatVerbOnADeterminedURLIsNotAMove() throws {
        let src = """
        import Foundation
        public func check() throws {
            let u = URL(fileURLWithPath: "/tmp/benign")
            _ = try? u.checkResourceIsReachable()
        }
        """
        let r = try scan(src, name: "R419Stat", policy: Self.allowBenignFs)
        XCTAssertEqual(r.code, 0, "a stat on a literal URL must still certify:\n\(r.out)")
        let fn = try XCTUnwrap(r.fns["check"], "check absent:\n\(r.out)")
        XCTAssertEqual(fn["paths"] as? [String], ["/tmp/benign"], "the receiver's literal must still resolve")
    }

    /// A property READ is not a call and must not invalidate anything.
    func testAPropertyReadIsNotAMove() throws {
        let src = """
        import Foundation
        public func peek() throws {
            var u = URL(fileURLWithPath: "/tmp/benign")
            _ = u.isFileURL
            try "x".write(to: u, atomically: true, encoding: .utf8)
        }
        """
        let r = try scan(src, name: "R419Prop", policy: Self.allowBenignFs)
        XCTAssertEqual(r.code, 0, "reading a property moves nothing:\n\(r.out)")
    }

    /// SOUNDNESS R436 — **`URL.append(path:)` WAS EXEMPTED BY A SET BORROWED FROM ANOTHER TYPE FAMILY.**
    ///
    /// R419's first cut `.union`ed `FILES_NON_MOVING_MEMBERS` into the URL allowlist so a `File`
    /// binder's `f.delete()` would not withdraw its locator. Both families declare **`append`** and it
    /// means opposite things: appending to a file's CONTENTS moves nothing, while `URL.append(path:)` is
    /// the modern mutating path mover. So the URL spelling was ruled inert and
    /// `allow Fs /tmp/benign` EXITED 0 over a caller-controlled path — while the one-variable sibling
    /// `appendPathComponent` exited 1.
    ///
    /// **The comment above `LOCATOR_INERT_CALLS` listed `append(path:)` among the movers**, thirteen
    /// lines above the union that exempted it. The fix LICENSED the bypass: without it `append` would
    /// have been unknown on a URL and failed closed, so R419 turned "not yet considered" into
    /// "considered and ruled safe" — the state that stops a thing being measured again.
    ///
    /// Both modern spellings are asserted, not just the measured one, and the control is a determined
    /// URL with NO mutation which must still publish its path — a fix that made everything incomplete
    /// would satisfy the arms above and be useless.
    func testAURLPathAppendIsAMoveEvenThoughAFilesAppendIsNot() throws {
        for spelling in ["append(path: s)", "append(component: s)", "appendPathComponent(s)"] {
            let src = """
            import Foundation
            public func go(_ s: String) throws {
                var u = URL(fileURLWithPath: "/tmp/benign")
                u.\(spelling)
                try "x".write(to: u, atomically: true, encoding: .utf8)
            }
            """
            let r = try scan(src, name: "R436\(spelling.prefix(6))", policy: Self.allowBenignFs)
            XCTAssertEqual(r.code, 1, "\(spelling): a URL path append is a MOVE — the binder's literal "
                           + "must not certify a caller-controlled path:\n\(r.out)")
        }
        let ctl = """
        import Foundation
        public func go() throws {
            let u = URL(fileURLWithPath: "/tmp/benign")
            try "x".write(to: u, atomically: true, encoding: .utf8)
        }
        """
        let c = try scan(ctl, name: "R436Ctl", policy: Self.allowBenignFs)
        XCTAssertEqual(c.code, 0, "a determined URL with no mutation must still certify:\n\(c.out)")
        let fn = try XCTUnwrap(c.fns["go"], "go absent:\n\(c.out)")
        XCTAssertEqual(fn["paths"] as? [String], ["/tmp/benign"],
                       "and must still PUBLISH its path — an all-incomplete fix passes the arms above "
                       + "and is useless:\n\(c.out)")
    }

    /// And the Files counterpart of the rule, which is not symmetric with R418's: `f.delete()` acts on
    /// the path the name holds and must NOT invalidate it, while `f.rename(to:)` genuinely relocates the
    /// receiver and must. Both directions in one place, because the cost of getting the split wrong is a
    /// fabricated destination on one side and an unusable over-mask on the other.
    func testAFilesRenameMovesTheReceiverButADeleteDoesNot() throws {
        // The destination is DETERMINED on purpose. An earlier cut of this arm renamed to a caller
        // string and PASSED against the pre-R419 engine — R418's two-locator rule reddened it before the
        // move rule was ever consulted, so it isolated nothing. With both ends of the rename visible,
        // the only thing that can make this red is the WRITE that follows it, whose receiver no longer
        // denotes the path it was bound to.
        let renamed = """
        import Files
        public func shuffle() throws {
            let f = try File(path: "/tmp/benign")
            try f.rename(to: "/tmp/benign")
            try f.write("x")
        }
        """
        let r1 = try scan(renamed, name: "R419Rename", policy: Self.allowBenignFs)
        XCTAssertEqual(r1.code, 1, "after a rename the name no longer denotes /tmp/benign:\n\(r1.out)")

        let deleted = """
        import Files
        public func drop() throws {
            let f = try File(path: "/tmp/benign")
            try f.delete()
        }
        """
        let r2 = try scan(deleted, name: "R419Delete", policy: Self.allowBenignFs)
        XCTAssertEqual(r2.code, 0, "a delete acts on the path it holds and does not move it:\n\(r2.out)")
    }
}
