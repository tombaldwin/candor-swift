import XCTest
import Foundation
import SwiftSyntax
import SwiftParser
@testable import CandorCore

/// **R135 — THE `native:` ALLOWLIST FABRICATED ON A NAME THAT IS ALSO A STRUCT.**
///
/// R130 (`eecc458`) wrote the exclusion rule down and did not sweep it. Its own "DELIBERATELY STILL
/// ABSENT" block keeps `stat`/`lstat`/`fstat`/`statfs` off `NATIVE_DISCLOSURE_C_FREE_FNS` *because they
/// are also Foundation structs* — and the same commit ADDED `flock`. `struct flock` is the fcntl
/// advisory-lock record, and `var fl = flock()` is how you build one.
///
/// GROUND TRUTH EXECUTED, BOTH PLATFORMS. The fixture below is a real SPM package that was built and RUN:
///
///     func describeLock() -> Int16 { var fl = flock(); fl.l_type = Int16(F_WRLCK); return fl.l_type }
///
///     macOS               describeLock() = 3   — touches no fd and no path
///     Linux (swift:6.1)   describeLock() = 1   — F_WRLCK differs, the program does not
///
/// and against the binary at 29f317a it reported `['Unknown']` + `unknownWhy ['native:flock']`, with
/// `deny Unknown describeLock` exiting **1** on a function that performs nothing. At the published
/// 819fac6 the function was absent from the report entirely.
///
/// **WHY `!argLabelled` COULD NOT HAVE CAUGHT IT** — the narrowing R130 kept when it dropped the module
/// gate. A Swift struct construction carries no argument labels either, so `flock()` and
/// `flock(fd, LOCK_EX)` are byte-identical on every field that arm reads except the COUNT. That is why
/// the fix is an arity gate and not another label rule; `testTheLabelGateCannotSeparateTheStructFromTheSyscall`
/// below measures it rather than leaving it as an assertion in a comment.
///
/// **THE FIX IS A NARROWING OF A SOUND OVER-APPROXIMATION, WHICH IS THE DANGEROUS DIRECTION (§F1.5).**
/// So it is gated on a fact rather than an intent — a C function that requires an argument cannot be what
/// a bare `name()` bound to — and the exception list is measured, not assumed: `fork(void)`/`vfork(void)`
/// ARE nullary, so a blanket count gate would have traded R130's fabrication for a silent under-report on
/// process creation. `testANullaryCSyscallStillDiscloses` is the pin for that, and it is the row that goes
/// red if anyone "simplifies" this to `argc > 0`.
///
/// **WHICH ROWS DISCRIMINATE THE FIX (§A) — MEASURED BY ACTUALLY REVERTING IT, TWICE, NOT BY REASONING.**
///
///   ARM 1, the fix removed entirely (back to 29f317a's condition):
///     RED   testTheStructConstructionIsNotMistakenForTheSyscall
///     RED   testTheStructConstructionPassesDenyUnknown
///     RED   testTheLabelGateCannotSeparateTheStructFromTheSyscall
///     green testANullaryCSyscallStillDiscloses, testAProjectStructOfAnAllowlistedNameIsNotACBoundary,
///           testEveryUnqualifiedCallSiteRecordsItsArguments, testTheNullaryExemptionsAreAllOnTheAllowlist
///
///   ARM 2, the TEMPTING SIMPLIFICATION — a blanket `argc > 0` with no nullary exemption:
///     RED   testANullaryCSyscallStillDiscloses  (`spawnChild` came back with `["native:waitpid"]` only —
///           `fork()` had gone silent, which is the cardinal sin this fix must not introduce)
///     green everything else, INCLUDING all three of arm 1's defect pins
///
/// Arm 2 is the row that matters most here, and no amount of re-reading arm 1 would have produced it: a
/// suite that only ever reverts the whole change cannot tell a correct narrowing from an over-wide one,
/// because both fix the bug in front of it.
///
/// The four rows green in arm 1 are the fabrication mirror and the assumption pins. They are here because
/// the defect pins are ABSENCE assertions, which a dead branch satisfies just as well as a correct one
/// (§E3) — each defect row therefore carries a DISCRIMINATING arm inside its own fixture.
final class CNativeDisclosureArityProcessTests: XCTestCase {

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
        return (try ProcessHarness.fns(ofJson: r.out), r.code, r.out + r.err)
    }

    /// §E3, mechanised — the same helper `CNativeDisclosureScopeProcessTests` grew after four rows were
    /// found asserting things about programs that cannot compile on Linux. Every fixture here asserts an
    /// ABSENCE, which is exactly what a broken engine also produces, so the program must be proven to
    /// exist before its report means anything.
    private func assertTypechecks(_ src: String, _ label: String) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r135-tc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f.swift")
        try src.write(to: f, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(URL(fileURLWithPath: "/usr/bin/env"), ["swiftc", "-typecheck", f.path])
        XCTAssertEqual(r.code, 0,
                       "the \(label) fixture must COMPILE, or the report taken over it is a statement "
                       + "about a program that does not exist (brief §E3): \(r.err)")
    }

    // ── THE DEFECT ──────────────────────────────────────────────────────────────────────────────────

    /// BOTH ARMS IN ONE FIXTURE, deliberately. The struct arm asserts an absence; on its own it would be
    /// satisfied by the whole `native:` branch being dead. The syscall arm beside it — same spelling, same
    /// (absent) labels, two arguments instead of none — must still disclose, so this row discriminates
    /// "the arity gate works" from "nothing fires here at all".
    ///
    /// `lockIt` is written against a plain descriptor rather than a `FileHandle` so its severity is its
    /// own: a sibling Foundation file call would let a blanket policy pass incidentally and the finding
    /// would disappear.
    private static let flockTree = """
    import Foundation

    // ZERO ARGUMENTS — `struct flock` is the fcntl advisory-lock RECORD. Executed: returns F_WRLCK,
    // touches no fd and no path.
    public func describeLock() -> Int16 {
        var fl = flock()
        fl.l_type = Int16(F_WRLCK)
        return fl.l_type
    }

    // TWO ARGUMENTS, no labels — the real `flock(2)`. This is swift-tools-support-core's shape
    // (Sources/TSCBasic/Lock.swift:146,166).
    public func lockIt(_ fd: Int32) -> Int32 {
        return flock(fd, LOCK_EX)
    }
    """

    /// DEFECT. Red against a release binary built from 29f317a, where `describeLock` carried
    /// `unknownWhy ["native:flock"]`.
    func testTheStructConstructionIsNotMistakenForTheSyscall() throws {
        try assertTypechecks(Self.flockTree, "flock-struct-and-syscall")
        let r = try scan(Self.flockTree, name: "FlockArity")

        let why = (r.fns["describeLock"]?["unknownWhy"] as? [String]) ?? []
        XCTAssertFalse(why.contains("native:flock"),
                       "`var fl = flock()` constructs `struct flock` — a zero-argument call cannot be "
                       + "libc's `flock(fd, op)`, which requires two. R130 added the name without applying "
                       + "its own also-a-type rule: \(why) \(r.out)")
        XCTAssertNil(ProcessHarness.inferred(r.fns, "describeLock"),
                     "and the function performs NOTHING, so it must be absent from the report entirely — "
                     + "the published 819fac6 had it right: \(r.out)")

        XCTAssertEqual(ProcessHarness.inferred(r.fns, "lockIt"), ["Unknown"],
                       "the DISCRIMINATING arm: `flock(fd, LOCK_EX)` is the real advisory lock and must "
                       + "still disclose, or the row above proves only that the branch is dead: \(r.out)")
        XCTAssertEqual(r.fns["lockIt"]?["unknownWhy"] as? [String], ["native:flock"],
                       "and it must still name the syscall")
    }

    /// DEFECT. The gate verdict, which is what a user actually feels. At 29f317a this exited 1 — a gate
    /// failing on code that performs nothing.
    func testTheStructConstructionPassesDenyUnknown() throws {
        let src = """
        import Foundation

        public func describeLock() -> Int16 {
            var fl = flock()
            fl.l_type = Int16(F_WRLCK)
            return fl.l_type
        }
        """
        try assertTypechecks(src, "flock-struct-isolated")
        let r = try scan(src, name: "FlockGate", policy: "deny Unknown describeLock\n")
        XCTAssertEqual(r.code, 0,
                       "`deny Unknown describeLock` over a function that builds a struct and returns an "
                       + "Int16 must PASS. Measured ISOLATED — no sibling file call — so the verdict is "
                       + "this function's own: \(r.out)")
    }

    // ── THE CONTROL THE NARROWING COULD HAVE BROKEN ─────────────────────────────────────────────────

    /// CONTROL, and the row that fails if the arity gate is ever written as a blanket `argc > 0`.
    ///
    /// `fork` and `vfork` are `pid_t fork(void)` in `MacOSX.sdk/usr/include/unistd.h:459,620` and in
    /// glibc's `unistd.h:778,786`. GROUND TRUTH EXECUTED under `swift:6.1`: `let pid = fork(); if pid == 0
    /// { _exit(7) }; waitpid(pid, &st, 0)` builds, runs, really forks, and reaps status 7. A zero-argument
    /// call site here IS the syscall, so suppressing it would be the cardinal sin — the exact direction
    /// [[feedback-fabrication-fixes-cause-misses]] measures at four defects in five fabrication fixes.
    ///
    /// The fixture is spelled `Glibc`-or-`Darwin` rather than `import Foundation` because Darwin marks
    /// `fork()` UNAVAILABLE, so a Foundation-only arm would not type-check on macOS — and `assertTypechecks`
    /// would then be the thing reporting the failure, on both platforms, for the wrong reason.
    func testANullaryCSyscallStillDiscloses() throws {
        let src = """
        #if canImport(Darwin)
        import Darwin
        #else
        import Glibc
        #endif

        public func spawnChild() -> Int32 {
            var st: Int32 = 0
            #if canImport(Darwin)
            let pid: pid_t = -1
            #else
            let pid = fork()
            if pid == 0 { _exit(7) }
            #endif
            waitpid(pid, &st, 0)
            return (st >> 8) & 0xff
        }
        """
        try assertTypechecks(src, "nullary-fork")
        // The engine reads BOTH `#if` arms unconditionally (see the `native:` allowlist doc), so the
        // `fork()` call is visible to the scan on macOS too even though it cannot be COMPILED there.
        let r = try scan(src, name: "NullaryFork")
        let why = (r.fns["spawnChild"]?["unknownWhy"] as? [String]) ?? []
        XCTAssertTrue(why.contains("native:fork"),
                      "`fork()` takes no arguments and creates a process — the arity gate MUST NOT be a "
                      + "blanket `argc > 0`, or R135 trades a fabrication for a silent under-report on "
                      + "process creation: \(why) \(r.out)")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "spawnChild"), ["Unknown"],
                       "and the caller must still be charged: \(r.out)")
    }

    /// DEFECT (it goes red on arm 1, so it is a pin and not a mirror — I had it filed as a control until
    /// the revert said otherwise). The R130 narrowing this one had to sit beside: a struct construction carries NO argument
    /// labels, so `!argLabelled` reads identically on `flock()` and on `flock(fd, LOCK_EX)`; the count is
    /// the only field that separates them. Asserted over the real reports rather than by reading the code,
    /// because "the label flag cannot help here" is exactly the kind of sentence §K says nobody verifies.
    func testTheLabelGateCannotSeparateTheStructFromTheSyscall() throws {
        let src = """
        import Foundation

        public func zeroArg() -> Int16 { let fl = flock(); return fl.l_type }
        public func twoArg(_ fd: Int32) -> Int32 { return flock(fd, LOCK_EX) }

        extension Array {
            // GRDB's shape — `remove(at:)` on an IMPLICIT self, so it really does reach the unqualified
            // arm and is filtered by the LABEL gate rather than never arriving.
            mutating func dropHead() { if !isEmpty { remove(at: 0) } }
        }
        """
        try assertTypechecks(src, "label-vs-arity")
        let r = try scan(src, name: "LabelVsArity")
        // `Array.dropHead` is the arm the LABEL gate separates — a one-argument, unlabelled `remove(0)`
        // there WOULD disclose, so its silence is that gate still working, not this one.
        XCTAssertFalse(((r.fns["Array.dropHead"]?["unknownWhy"] as? [String]) ?? []).contains("native:remove"),
                       "the label gate must still be live: `remove(at:)` is labelled and cannot be libc")
        XCTAssertNil(ProcessHarness.inferred(r.fns, "zeroArg"),
                     "unlabelled, zero arguments → the struct: \(r.out)")
        XCTAssertEqual(r.fns["twoArg"]?["unknownWhy"] as? [String], ["native:flock"],
                       "unlabelled, two arguments → the syscall. Same name, same absent labels, opposite "
                       + "verdicts — which is the measurement that says the label flag could not have "
                       + "closed R135: \(r.out)")
    }

    /// CONTROL — a PROJECT declaration of one of these spellings never reaches the `native:` arm at all;
    /// `localTypes`/`freeFnByName` resolve it several arms earlier. Stated as its own row because the R135
    /// sweep had to rule out "a name that is also a local type in a scanned project" as a second collision
    /// class, and a claim about which arm wins is cheap to check and easy to get backwards.
    func testAProjectStructOfAnAllowlistedNameIsNotACBoundary() throws {
        // ONE argument, no label — so the arity and label gates both let it through, and the only thing
        // that can keep it out of the `native:` arm is the local-type resolution several arms earlier.
        let src = """
        public struct copyfile { public var n: Int; public init(_ n: Int) { self.n = n } }
        public func makesOne() -> Int { let c = copyfile(3); return c.n }
        """
        try assertTypechecks(src, "project-struct-shadow")
        let r = try scan(src, name: "ProjStruct")
        XCTAssertNil(ProcessHarness.inferred(r.fns, "makesOne"),
                     "a project's own `struct copyfile` is project code, not a C boundary: \(r.out)")
    }

    // ── THE ASSUMPTION THE ARITY GATE RESTS ON, PINNED OVER THE SOURCE ──────────────────────────────

    /// The `native:` arm reads `call.args.count`. That is only a trustworthy arity if EVERY `Call` built
    /// with `unqualified: true` actually records its arguments — a construction site that forgot `args:`
    /// would present a real `unlink(path)` as zero-argument and the gate would silence it. `args` defaults
    /// to `[]`, i.e. the SUPPRESSING direction, which is the opposite of the discipline `argRef`/
    /// `argLabelled` state in their own docs, so this cannot be left as a comment (§E2: if you cannot write
    /// a fixture that fails when the claim is false, word it as an assumption — this one CAN be pinned).
    ///
    /// The one site that omits `args` is the bare-identifier ARGUMENT form (`xs.map(loadFree)`), which sets
    /// `argRef: true`; the `native:` arm rejects that on its first condition. So the invariant is: every
    /// `unqualified: true` construction passes `args:` OR `argRef:`.
    ///
    /// Parsed with SwiftSyntax rather than grepped, for the reason §G gives — the repo already owns the
    /// parser, and a regex over Swift source is a second, worse implementation of it.
    func testEveryUnqualifiedCallSiteRecordsItsArguments() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/candor-swift/CallCollector.swift")
        let tree = Parser.parse(source: try String(contentsOf: path, encoding: .utf8))

        final class Finder: SyntaxVisitor {
            var sites: [(line: Int, labels: [String])] = []
            let converter: SourceLocationConverter
            init(_ converter: SourceLocationConverter) {
                self.converter = converter
                super.init(viewMode: .sourceAccurate)
            }
            override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
                      callee.baseName.text == "Call" else { return .visitChildren }
                let labels = node.arguments.compactMap { $0.label?.text }
                if labels.contains("unqualified") {
                    sites.append((converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                                  labels))
                }
                return .visitChildren
            }
        }
        let f = Finder(SourceLocationConverter(fileName: path.path, tree: tree))
        f.walk(tree)

        XCTAssertGreaterThanOrEqual(f.sites.count, 8,
                                    "the finder itself must not go silent — CallCollector.swift had 9 "
                                    + "`unqualified:` Call sites when R135 was written, and a parse that "
                                    + "finds none would pass this row vacuously")
        for site in f.sites {
            XCTAssertTrue(site.labels.contains("args") || site.labels.contains("argRef"),
                          "CallCollector.swift:\(site.line) builds an `unqualified` Call without `args:` "
                          + "and without `argRef:`. The Driver's `native:` arm gates on `args.count`, and "
                          + "`args` defaults to EMPTY — so this site would present a real raw C call as "
                          + "zero-argument and the arity gate would silence it. Labels: \(site.labels)")
        }
    }

    /// The nullary exemption set must be a subset of the list it exempts from — an entry that names
    /// nothing is a rule nobody can find, and one naming a name not on the allowlist reads as coverage
    /// this arm does not have.
    func testTheNullaryExemptionsAreAllOnTheAllowlist() {
        XCTAssertFalse(NATIVE_DISCLOSURE_C_NULLARY_FNS.isEmpty,
                       "an empty exemption set means the gate IS a blanket `argc > 0` — see "
                       + "`testANullaryCSyscallStillDiscloses` for what that costs")
        XCTAssertTrue(NATIVE_DISCLOSURE_C_NULLARY_FNS.isSubset(of: NATIVE_DISCLOSURE_C_FREE_FNS),
                      "every nullary exemption must name a disclosed C function: "
                      + "\(NATIVE_DISCLOSURE_C_NULLARY_FNS.subtracting(NATIVE_DISCLOSURE_C_FREE_FNS))")
    }
}
