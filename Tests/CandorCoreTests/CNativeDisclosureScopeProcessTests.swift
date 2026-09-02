import XCTest
import Foundation

/// **R130 — THE C-SYMBOL SCOPE GATE, AND THE SIBLINGS R61's ALLOWLIST NEVER ASKED ABOUT.**
///
/// R61 disclosed `Unknown` + `native:<name>` for a raw C call on a curated allowlist, but ONLY in a file
/// whose imports named a `C_PLATFORM_MODULES` umbrella (`Darwin`/`Glibc`/`Musl`/`WinSDK`). That second
/// condition was itself the cardinal sin, over the whole allowlist at once: **the imports that put the C
/// surface in scope are not the ones that name it.** Foundation re-exports Darwin on Apple platforms —
/// and, measured under `swift:6.1` in Docker rather than assumed, swift-corelibs-foundation re-exports
/// Glibc on Linux, so the hole was on both platforms CI runs.
///
/// GROUND TRUTH EXECUTED, BOTH ARMS. Two SPM packages differing in ONE line — `import Darwin` versus
/// `import Foundation`, same `doWork`, same body — were `swift build`-ed and RUN, and each really created
/// a symlink on disk, verified by `lstat` + `S_IFLNK` in the program's own output, not by inspection.
/// Against the pre-fix release binary the two arms did not agree:
///
///     import Darwin      →  doWork: Unknown, unknownWhy ["native:symlink"];   `deny Unknown` exit 1
///     import Foundation  →  functions: 0, no excluded[], no invisible[];      ALL FIVE policy forms
///                           (`deny Fs`, `deny Unknown`, `deny Fs Unknown`, `deny Fs doWork`,
///                            `pure doWork`) exit 0
///
/// Both scans were taken over a BARE directory, not an SPM tree, so the ⟨0.30⟩ manifest-exclusion
/// escalation could not mask the verdict (brief §5 — every SPM package excludes `Package.swift`, and an
/// `outOfScope` entry turns every would-be pass into exit 2, which hides exactly this).
///
/// The severity was measured ISOLATED, in a file performing NO `FileManager` call, because a blanket
/// `deny Fs` beside a sibling `FileManager.default.createSymbolicLink` passes incidentally and the
/// finding disappears.
///
/// HALF 2 is CLAUDE.md §9 applied to R61's own list: its names were the ones its repro used. The `*at`
/// twins of five names ALREADY on it (`unlinkat`/`renameat`/`mkdirat`/`symlinkat`/`linkat`/`fchmodat`/
/// `fchownat`), plus `chroot`/`chdir`/`mkfifo`/`mknod`/`opendir`/`readdir`/`flock`/`fsync`/`mmap`/
/// `waitpid` and the `execl*` family, were silent under BOTH imports — measured one executed fixture per
/// name. `execve`/`execvP`/`fexecve`/`posix_spawnp` were absent from BOTH tables and are now concretely
/// `Exec` alongside `execv`/`execvp`/`posix_spawn`, AND establishing (`isEstablishingFree`), so a
/// runtime-built command through them can no longer mask an `allow Exec` allowlist while the same command
/// through `posix_spawn` fails closed.
///
/// THE OVER-CHARGE CONTROLS, and which of them could have failed. The three named `CONTROL` below pass
/// with AND without this fix — they are the fabrication mirror, not regression pins, and saying so is the
/// point (brief §A: a test that cannot discriminate the fix from its absence must not be counted as
/// coverage for it). The rows named `DEFECT` are the pins: every one was verified red against a release
/// binary built from the parent commit in a separate worktree.
final class CNativeDisclosureScopeProcessTests: XCTestCase {

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

    /// **§E3, MECHANISED RATHER THAN ASSERTED IN A COMMENT.** A control that asserts an ABSENCE is no
    /// evidence at all if its fixture cannot compile: the engine omits pure functions by design, so an
    /// unreachable program and a broken engine produce the same bytes. Every fixture in this file is
    /// type-checked by the real compiler before its report is read.
    ///
    /// It has already earned its keep: the first Docker run of this file failed HERE, not on a report
    /// assertion — the `execve`/`posix_spawnp` fixtures passed `nil` for argv/envp, which Darwin accepts
    /// (implicitly-unwrapped optionals) and Glibc rejects. Two rows were quietly asserting things about a
    /// program that could not exist on the platform CI runs on, and nothing else in the suite would have
    /// said so.
    private func assertTypechecks(_ src: String, _ label: String) throws {
        let swiftc = "/usr/bin/env"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r130-tc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("f.swift")
        try src.write(to: f, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(URL(fileURLWithPath: swiftc), ["swiftc", "-typecheck", f.path])
        XCTAssertEqual(r.code, 0,
                       "the \(label) fixture must COMPILE, or the report taken over it is a statement "
                       + "about a program that does not exist (brief §E3): \(r.err)")
    }

    // ── HALF 1: the module-import gate ──────────────────────────────────────────────────────────────

    /// The ONE-VARIABLE PAIR. Identical but for the import line. `doWork` performs no FileManager call,
    /// so its severity is its own and not a sibling's.
    private static func symlinkArm(_ importLine: String) -> String {
        """
        \(importLine)

        public func doWork(_ dir: String) {
            _ = symlink(dir + "/target.txt", dir + "/link.txt")
        }
        """
    }
    private static let darwinOnly = symlinkArm("#if canImport(Darwin)\nimport Darwin\n#else\nimport Glibc\n#endif")
    private static let foundationOnly = symlinkArm("import Foundation")

    /// DEFECT (half 1). The whole R61 allowlist read silent-pure here. Pre-fix: `doWork` absent entirely.
    func testRawCSyscallUnderAFoundationOnlyImportDisclosesNative() throws {
        // UNCONDITIONAL, and that is itself a measurement (brief §L — run the guard on the OTHER
        // platform). The first cut of this row guarded the typecheck on `canImport(Darwin)`, assuming
        // Foundation-re-exports-C was an Apple-overlay property. Checked under `swift:6.1` in Docker:
        // `import Foundation` + `symlink(...)` type-checks on LINUX too — swift-corelibs-foundation
        // re-exports Glibc the same way. The hole was never platform-specific, and a guard here would
        // have quietly halved this row's coverage on the platform CI actually runs.
        try assertTypechecks(Self.foundationOnly, "Foundation-only")
        let r = try scan(Self.foundationOnly, name: "FndOnly")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "doWork"), ["Unknown"],
                       "`symlink(a, b)` with only `import Foundation` creates a real symlink on disk "
                       + "(ground truth executed) — it must not read PURE just because the file did not "
                       + "spell `import Darwin`: \(r.out)")
        XCTAssertEqual(r.fns["doWork"]?["unknownWhy"] as? [String], ["native:symlink"],
                       "and it must name the syscall, exactly as the Darwin arm does")
    }

    /// DEFECT (half 1). PARITY, stated as its own row: the two arms must be byte-identical on every
    /// disclosure field. The row above could be satisfied by a disclosure that differed in KIND from the
    /// Darwin arm's; this one cannot.
    func testTheDarwinAndFoundationArmsAgreeOnEveryDisclosureField() throws {
        let d = try scan(Self.darwinOnly, name: "DarwinArm")
        let f = try scan(Self.foundationOnly, name: "FoundationArm")
        for key in ["inferred", "direct", "unknownWhy", "incomplete", "unresolved"] {
            let a = String(describing: d.fns["doWork"]?[key] ?? "<nil>")
            let b = String(describing: f.fns["doWork"]?[key] ?? "<nil>")
            XCTAssertEqual(a, b,
                           "the arms differ in exactly one thing — the import line — so `\(key)` must "
                           + "agree. Darwin=\(a) Foundation=\(b)\n\(f.out)")
        }
    }

    /// DEFECT (half 1). The gate verdict, which is what a user actually feels. Pre-fix this was exit 0.
    func testTheFoundationArmFailsDenyUnknownClosed() throws {
        let r = try scan(Self.foundationOnly, name: "FndGate", policy: "deny Unknown\n")
        XCTAssertEqual(r.code, 1,
                       "`deny Unknown` must catch the raw syscall through the Foundation spelling — "
                       + "pre-fix all five policy forms exited 0 over an executed symlink: \(r.out)")
    }

    // ── HALF 2: the siblings the allowlist never asked about ────────────────────────────────────────

    /// DEFECT (half 2). Each of these was silent under BOTH imports before R130 — the `*at` twins of
    /// names already on the list, and the directory/root/special-file verbs beside them.
    private static let siblingTree = """
    #if canImport(Darwin)
    import Darwin
    #else
    import Glibc
    #endif

    public func doSymlinkAt(_ p: String) { _ = symlinkat(p, -2, p) }
    public func doUnlinkAt(_ p: String) { _ = unlinkat(-2, p, 0) }
    public func doRenameAt(_ p: String) { _ = renameat(-2, p, -2, p) }
    public func doMkdirAt(_ p: String) { _ = mkdirat(-2, p, 0o755) }
    public func doLinkAt(_ p: String) { _ = linkat(-2, p, -2, p, 0) }
    public func doFchmodAt(_ p: String) { _ = fchmodat(-2, p, 0o600, 0) }
    public func doFchownAt(_ p: String) { _ = fchownat(-2, p, 0, 0, 0) }
    public func doChroot(_ p: String) { _ = chroot(p) }
    public func doChdir(_ p: String) { _ = chdir(p) }
    public func doMkfifo(_ p: String) { _ = mkfifo(p, 0o644) }
    public func doOpendir(_ p: String) { _ = opendir(p) }
    public func doUmask() { _ = umask(0o022) }
    public func doFsync() { _ = fsync(3) }
    public func doCreat(_ p: String) { _ = creat(p, 0o644) }
    """

    func testTheAtSiblingsOfAlreadyListedSyscallsDiscloseLikeTheirBaseNames() throws {
        try assertTypechecks(Self.siblingTree, "sibling-syscall")
        let r = try scan(Self.siblingTree, name: "Siblings")
        let expected = ["doSymlinkAt": "native:symlinkat", "doUnlinkAt": "native:unlinkat",
                        "doRenameAt": "native:renameat", "doMkdirAt": "native:mkdirat",
                        "doLinkAt": "native:linkat", "doFchmodAt": "native:fchmodat",
                        "doFchownAt": "native:fchownat", "doChroot": "native:chroot",
                        "doChdir": "native:chdir", "doMkfifo": "native:mkfifo",
                        "doOpendir": "native:opendir", "doUmask": "native:umask",
                        "doFsync": "native:fsync", "doCreat": "native:creat"]
        for (fn, why) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(ProcessHarness.inferred(r.fns, fn), ["Unknown"],
                           "`\(fn)` performs a real syscall and read silent-pure before R130 — the "
                           + "allowlist's boundary was drawn around R61's own repro (CLAUDE.md §9): \(r.out)")
            XCTAssertEqual(r.fns[fn]?["unknownWhy"] as? [String], [why],
                           "`\(fn)` must name its own syscall")
        }
    }

    /// DEFECT (half 2). `execve` is the syscall the other `exec*` spellings wrap, and `posix_spawnp`
    /// differs from `posix_spawn` only in PATH lookup. Both were in NEITHER table.
    private static let execTree = """
    #if canImport(Darwin)
    import Darwin
    #else
    import Glibc
    #endif

    // argv/envp are spelled as a real array rather than `nil`: Glibc types them non-optional, so the
    // `nil` form compiles on Darwin and NOT on Linux — caught by `assertTypechecks` on the first Docker
    // run of this file, which is the whole reason that helper exists.
    public func viaExecve(_ p: String) {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(p), nil]
        _ = execve(p, &argv, &argv)
    }
    public func viaSpawnp(_ p: String) {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(p), nil]
        _ = posix_spawnp(&pid, p, nil, nil, &argv, &argv)
    }
    """

    func testExecveAndPosixSpawnpAreChargedExecLikeTheirModelledSiblings() throws {
        try assertTypechecks(Self.execTree, "exec-family")
        let r = try scan(Self.execTree, name: "ExecFam")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "viaExecve"), ["Exec"],
                       "`execve` replaces the process image — `execv`/`execvp` were already Exec and it "
                       + "was silent: \(r.out)")
        XCTAssertEqual(ProcessHarness.inferred(r.fns, "viaSpawnp"), ["Exec"],
                       "`posix_spawnp` differs from the already-modelled `posix_spawn` only in PATH "
                       + "lookup: \(r.out)")
    }

    /// DEFECT (half 2), the GATE-MASKING half. A spelling added to `kappaFree` but not to
    /// `isEstablishingFree` charges the effect and then lets a runtime-built command slip past an
    /// `allow Exec` allowlist, which is the AS-EFF-008 evasion this project already closed once for
    /// `posix_spawn`. MEASURED LIVE on swift-tools-support-core: `Process.launch` spawns through
    /// `posix_spawnp(&processID, argv.cArray[0]!, …)` and 22 of its callers gained
    /// `incomplete: ["Fs"] → ["Exec", "Fs"]` from this row alone.
    func testARuntimeCommandThroughPosixSpawnpMarksExecIncomplete() throws {
        let src = """
        #if canImport(Darwin)
        import Darwin
        #else
        import Glibc
        #endif

        public func spawnRuntime(_ cmd: String) {
            var pid: pid_t = 0
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(cmd), nil]
            _ = posix_spawnp(&pid, cmd, nil, nil, &argv, &argv)
        }
        """
        try assertTypechecks(src, "posix_spawnp-masking")
        let r = try scan(src, name: "SpawnMask")
        XCTAssertEqual(r.fns["spawnRuntime"]?["incomplete"] as? [String], ["Exec"],
                       "the command is an argument of THIS call and is not a literal, so the Exec "
                       + "surface is structurally invisible and must fail an `allow Exec` closed: \(r.out)")
    }

    // ── THE OVER-CHARGE CONTROLS ────────────────────────────────────────────────────────────────────

    /// CONTROL — passes with and without the fix; here as the fabrication mirror for the ONE narrowing
    /// R130 keeps in place of the module gate. A C function imported into Swift has NO argument labels,
    /// so `remove(at: i)` provably cannot bind to libc's `remove(_: UnsafePointer<CChar>)`. This is a
    /// fact about the language, not a guess about intent — which is the difference between this and the
    /// heuristics §F1.5 warns about, and it is why the assertion is testable at all.
    ///
    /// MEASURED, not supposed: without it, GRDB's `RangeReplaceableCollection.removeFirst` and
    /// `Dictionary.removeFirst` — both `remove(at: index)` on an implicit `self` — each gained a
    /// spurious `native:remove`. With it, both are clean and the corpus A/B shows them gone.
    /// BOTH ARMS IN ONE FIXTURE, deliberately: an absence assertion alone could be satisfied by the
    /// branch being dead altogether, which is the failure mode §E3 is about. The unlabelled arm beside it
    /// must still disclose, so this row discriminates "the label gate works" from "nothing fires here".
    func testALabelledArgumentCallCannotBeTheCFunctionAndIsNotDisclosed() throws {
        let src = """
        import Foundation

        extension Array {
            // GRDB's exact shape: `remove(at:)` on an implicit `self`, which gained a spurious
            // `native:remove` when the module gate came off and the label check was not yet there.
            mutating func dropFirstMatch(_ keep: (Element) -> Bool) {
                if let i = firstIndex(where: { !keep($0) }) { remove(at: i) }
            }
        }

        // The discriminating arm: same name, NO label, nothing project-local to resolve against.
        public func deletesByPath(_ p: String) { _ = remove(p) }
        """
        try assertTypechecks(src, "labelled-argument")
        let r = try scan(src, name: "Labelled")
        let why = (r.fns["Array.dropFirstMatch"]?["unknownWhy"] as? [String]) ?? []
        XCTAssertFalse(why.contains("native:remove"),
                       "`remove(at: i)` is `RangeReplaceableCollection.remove(at:)` on implicit self — a "
                       + "LABELLED call cannot bind to libc's unlabelled `remove`, so no native: reason "
                       + "may appear (the row itself legitimately carries `callback:keep` for the closure "
                       + "parameter it invokes): \(why) \(r.out)")
        XCTAssertEqual(r.fns["deletesByPath"]?["unknownWhy"] as? [String], ["native:remove"],
                       "and the UNLABELLED sibling must still disclose — otherwise the row above proves "
                       + "only that the branch is dead: \(r.out)")
    }

    /// CONTROL — passes with and without the fix. With the module gate gone, the NAME allowlist is the
    /// only thing standing between a real project declaration and a fabricated boundary. The allowlist
    /// arm is the Driver's TERMINAL branch, so a project's own `symlink` must still win. Its OWN package:
    /// a lookalike declared beside the real defect would shadow it project-wide and silently defeat the
    /// case under test (the sibling-route trap `ExecCapabilityProcessTests` documents).
    func testAProjectDeclarationSharingAnAllowlistedNameStillWinsWithoutTheModuleGate() throws {
        let src = """
        import Foundation

        func symlink(_ a: Int) -> Int { return a + 1 }
        func usesLocalSymlink() -> Int { return symlink(5) }
        """
        try assertTypechecks(src, "local-shadow")
        let r = try scan(src, name: "LocalShadow")
        XCTAssertNil(r.fns["symlink"],
                     "a pure project `symlink(_:)` is project code, not a C boundary")
        XCTAssertNil(r.fns["usesLocalSymlink"],
                     "and its caller must resolve to it rather than fall through to the allowlist — the "
                     + "module gate was never what made this work: \(r.out)")
    }

    /// CONTROL — passes with and without the fix, and it is the reason `stat`/`lstat`/`fstat`/`statfs`
    /// are deliberately ABSENT from the allowlist rather than merely forgotten. `stat` is also a struct,
    /// and `var s = stat()` is how every Swift program that stats anything makes one; disclosing on that
    /// spelling would answer a question nobody asked, on a name that appears in essentially every file
    /// that touches the syscall at all.
    func testTheStatStructConstructorIsNotMistakenForTheStatSyscall() throws {
        let src = """
        #if canImport(Darwin)
        import Darwin
        #else
        import Glibc
        #endif

        public func sizeOf(_ p: String) -> Int {
            var s = stat()
            guard lstat(p, &s) == 0 else { return -1 }
            return Int(s.st_size)
        }
        """
        try assertTypechecks(src, "stat-struct")
        let r = try scan(src, name: "StatStruct")
        XCTAssertNil((r.fns["sizeOf"]?["unknownWhy"] as? [String])?.first(where: { $0.hasPrefix("native:stat") }),
                     "no `native:stat` may appear — the zero-argument `stat()` here constructs the "
                     + "STRUCT: \(r.out)")
    }
}
