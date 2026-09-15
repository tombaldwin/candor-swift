import XCTest
import Foundation
@testable import CandorCore

/// SOUNDNESS R415 + R432 — **THE LOCATOR TABLE COULD NOT EXPRESS "THE SECOND ARGUMENT", AND ONE NAME WAS
/// STILL LIVE BECAUSE OF IT.**
///
/// R394's table declared which argument holds the locator as a `Set<String>` of LABELS, where `""` means
/// *the first UNLABELED argument*. A C call has no labels, so `""` always meant argument 0 and the schema
/// could not say "the second one" at all. Two consequences, both measured at 0.38.2:
///
///   * **`sqlite3_open_v2(runtimePath, &db, 6, "unix-dotfile")` reported `incomplete: None`.** The VFS
///     name is argument 3 and is a string literal in ordinary code; the whole-argument scan found it,
///     `lit != nil` kept the incompleteness guard from firing, and the literal was then DISCARDED
///     downstream because a filename is not SQL. A runtime-controlled locator whose surface reads
///     COMPLETE — SPEC ⟨0.29⟩'s position rule, which PART 51 pins four-way. Its sibling
///     `sqlite3_open(filename, ppDb)` has no second string and was correct: the one-spelling-of-a-family
///     shape `execvP` had.
///   * **`posix_spawn` could not be added to the old table even though it was the row's headline**, since
///     `[""]` would have landed on `&pid`. It was CORRECT anyway, and NOT by the spelling luck its
///     `exec*` siblings relied on: in `posix_spawn(pid_t *pid, const char *path, …, char *const argv[],
///     char *const envp[])` the only parameter a Swift string literal can inhabit in code that compiles
///     is `path`. Measured before the change — runtime `p` → `incomplete: ["Exec"]`, literal `"/bin/ls"`
///     → `cmds: ["/bin/ls"]`. Declared now anyway, because a name whose correctness rests on a signature
///     nobody wrote down is a name the next author reasons about wrongly.
///
/// R432 rides in the same change because it is the same table's missing THIRD arm: `NWListener`'s
/// locator is a PORT (`NWEndpoint.Port` is `ExpressibleByStringLiteral`), so the free-call spelling
/// `NWListener(using: .tcp, on: "8080")` published `hosts: ["8080"]`, complete — a host that does not
/// exist — while the INT spelling reported `incomplete: ["Net"]`. It is declared by ADDING THE NAME TO
/// `isOpaqueLocatorFree`, which `locatorForFree`'s `.opaque` arm DERIVES from; a second list here would
/// have been R347 on the day it was written.
final class LocatorSlotSchemaProcessTests: XCTestCase {

    private func scan(_ body: String, name: String, policy: String? = nil)
        throws -> (fns: [String: [String: Any]], code: Int32, out: String) {
        let src = """
        import Foundation
        import SQLite3
        import Network
        \(body)
        """
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

    private func incomplete(_ fns: [String: [String: Any]], _ fn: String) -> [String] {
        (fns[fn]?["incomplete"] as? [String]) ?? []
    }

    /// R415's LIVE HALF, with the COVERED-vs-UNCOVERED pair that makes it one variable: two sqlite opens
    /// of a runtime path, differing only in whether a VFS-name sibling literal is present.
    func testR415SqliteOpenV2CannotBeMaskedByItsVfsNameSibling() throws {
        let r = try scan("""
        public func withVfs(_ p: String) { var db: OpaquePointer?; _ = sqlite3_open_v2(p, &db, 6, "unix-dotfile") }
        public func withoutVfs(_ p: String) { var db: OpaquePointer?; _ = sqlite3_open(p, &db) }
        """, name: "R415Sqlite")
        XCTAssertTrue(incomplete(r.fns, "withoutVfs").contains("Db"),
                      "the CONTROL — an open with no sibling literal was already correct: \(r.out)")
        XCTAssertTrue(incomplete(r.fns, "withVfs").contains("Db"),
                      "R415: the VFS NAME is argument 3 and is not the locator. Before the position "
                      + "schema this read `incomplete: None` over a runtime-controlled database: \(r.out)")
    }

    /// **NOT BLANKET OVER-MASKING, which is the control this change most needs.** A literal filename is
    /// still captured at its declared position, so an open whose database IS statically known keeps a
    /// complete surface. Without this, "mark it incomplete" would be indistinguishable from "mark
    /// everything incomplete", and every sqlite program would fail `allow Db` forever.
    func testR415ALiteralLocatorAtItsDeclaredPositionStaysComplete() throws {
        let r = try scan("""
        public func litOpen() { var db: OpaquePointer?; _ = sqlite3_open_v2("/tmp/a.db", &db, 6, "unix-dotfile") }
        public func litExec(_ db: OpaquePointer?) { _ = sqlite3_exec(db, "SELECT * FROM users", nil, nil, nil) }
        """, name: "R415NotBlanket")
        XCTAssertFalse(incomplete(r.fns, "litOpen").contains("Db"),
                       "a literal database name is the locator and still reads complete: \(r.out)")
        XCTAssertEqual(r.fns["litExec"]?["tables"] as? [String], ["users"],
                       "the SQL surface must survive — `sqlite3_exec`'s locator is argument 1: \(r.out)")
        XCTAssertFalse(incomplete(r.fns, "litExec").contains("Db"), r.out)
    }

    /// **THE `posix_spawn` REASONING, MEASURED RATHER THAN ASSERTED.** The row claims this family
    /// resolved correctly by TYPE and not by luck; that claim is the reason nothing was changed about its
    /// behaviour, so it is the claim this test pins. A literal command is captured at argument 1 and a
    /// runtime one fails closed — and `execvP`, whose argument 1 IS a `const char *`, is the sibling that
    /// proves the distinction is real (R415 closed it; this keeps it closed).
    func testR415ExecFamilyLocatorsAreDeclaredNotLucky() throws {
        let r = try scan("""
        public func spawnRuntime(_ p: String) { var pid: pid_t = 0; _ = posix_spawn(&pid, p, nil, nil, nil, nil) }
        public func spawnLiteral() { var pid: pid_t = 0; _ = posix_spawn(&pid, "/bin/ls", nil, nil, nil, nil) }
        public func spawnpRuntime(_ p: String) { var pid: pid_t = 0; _ = posix_spawnp(&pid, p, nil, nil, nil, nil) }
        """, name: "R415Spawn")
        for fn in ["spawnRuntime", "spawnpRuntime"] {
            XCTAssertTrue(incomplete(r.fns, fn).contains("Exec"),
                          "\(fn) launches a caller-controlled program — it must fail closed: \(r.out)")
        }
        XCTAssertEqual(r.fns["spawnLiteral"]?["cmds"] as? [String], ["/bin/ls"],
                       "argument 1 is the command and a literal one is still published: \(r.out)")
        XCTAssertFalse(incomplete(r.fns, "spawnLiteral").contains("Exec"), r.out)
    }

    /// **R431 MUST NOT BE REINTRODUCED BY THE POSITION ARM.** R431 measured that a DECLARED locator was
    /// weaker than an undeclared one, because the table's picker took a plain string literal and nothing
    /// else while the whole-list fallback ran `resolveConstString`. Every name the position schema newly
    /// declares would have inherited that loss had `resolvedAtPosition` been written on the literal
    /// picker alone. One variable per pair: the same `let` spelling, at each newly declared position.
    func testR415AConstBoundLocatorStillResolvesAtEveryDeclaredPosition() throws {
        let r = try scan("""
        public func openConst() { let p = "/tmp/x.db"; var db: OpaquePointer?; _ = sqlite3_open_v2(p, &db, 6, "unix-dotfile") }
        public func spawnConst() { let c = "/bin/ls"; var pid: pid_t = 0; _ = posix_spawn(&pid, c, nil, nil, nil, nil) }
        public func execConst(_ db: OpaquePointer?) { let q = "SELECT * FROM users"; _ = sqlite3_exec(db, q, nil, nil, nil) }
        public func fopenConst() { let p = "/tmp/x.txt"; _ = fopen(p, "r") }
        """, name: "R415Const")
        XCTAssertFalse(incomplete(r.fns, "openConst").contains("Db"),
                       "R431: a const-bound database name resolves at position 0: \(r.out)")
        XCTAssertEqual(r.fns["spawnConst"]?["cmds"] as? [String], ["/bin/ls"],
                       "R431: a const-bound command resolves at position 1: \(r.out)")
        XCTAssertEqual(r.fns["execConst"]?["tables"] as? [String], ["users"],
                       "R431: const-bound SQL resolves at position 1: \(r.out)")
        XCTAssertEqual(r.fns["fopenConst"]?["paths"] as? [String], ["/tmp/x.txt"],
                       "R431's own case must stay closed: \(r.out)")
    }

    /// R432 — TWO SPELLINGS OF ONE LISTEN MUST ANSWER THE SAME, and neither may name a host. The INT
    /// spelling was already right, which is what makes this a comparison with one variable rather than a
    /// judgement about what a listen should report.
    func testR432AListenAddressNeverEntersHosts() throws {
        let r = try scan("""
        public func strPort() { let l = try? NWListener(using: .tcp, on: "8080"); l?.start(queue: .main) }
        public func intPort() { let l = try? NWListener(using: .tcp, on: 8080); l?.start(queue: .main) }
        public func realHost() { let c = NWConnection(host: "api.stripe.com", port: 443, using: .tls); c.start(queue: .main) }
        """, name: "R432Listen")
        XCTAssertNil(r.fns["strPort"]?["hosts"],
                     "R432: `on: \"8080\"` is a PORT. Publishing it as a host names a destination that "
                     + "does not exist — R381's first cut did exactly this with \"443\": \(r.out)")
        XCTAssertTrue(incomplete(r.fns, "strPort").contains("Net"),
                      "R432: withholding the literal is only sound if the surface then fails closed: \(r.out)")
        XCTAssertNil(r.fns["intPort"]?["hosts"], r.out)
        XCTAssertTrue(incomplete(r.fns, "intPort").contains("Net"),
                      "the CONTROL — the int spelling was already correct: \(r.out)")
        // THE DISCRIMINATOR: same framework, same ctor shape, a genuine host. If the opaque arm were
        // keyed on the framework rather than on the name, this would be withheld too and the engine
        // would stop publishing real destinations.
        XCTAssertEqual(r.fns["realHost"]?["hosts"] as? [String], ["api.stripe.com:443"], r.out)
        XCTAssertFalse(incomplete(r.fns, "realHost").contains("Net"), r.out)
    }

    /// THE TABLE'S OWN SHAPE. `.opaque` must be DERIVED from `isOpaqueLocatorFree` — R347 is the record
    /// of what two copies of one list cost, and R432 arrived as "add a name to the opaque arm", which as
    /// a second list here would have been that bug the day it was introduced. Asserted by adding a name
    /// to the AUTHORITY and reading it back through the TABLE.
    func testR415OpaqueArmIsDerivedFromTheAuthority() {
        for n in ["NWBrowser", "NetService", "NetServiceBrowser", "NWListener",
                  "SecItemAdd", "SecItemUpdate", "SecItemDelete", "SecItemCopyMatching"] {
            XCTAssertTrue(isOpaqueLocatorFree(n), "\(n) is opaque by the authority")
            XCTAssertEqual(locatorForFree(n), .opaque,
                           "\(n): the table must ANSWER from `isOpaqueLocatorFree`, not from a copy of it")
        }
        // The positions the old `Set<String>` schema could not express.
        XCTAssertEqual(locatorForFree("posix_spawn"), .position(1))
        XCTAssertEqual(locatorForFree("posix_spawnp"), .position(1))
        XCTAssertEqual(locatorForFree("sqlite3_exec"), .position(1))
        XCTAssertEqual(locatorForFree("sqlite3_open_v2"), .position(0))
        // The ones it could, unchanged.
        XCTAssertEqual(locatorForFree("shellOut"), .label("to"))
        XCTAssertEqual(locatorForFree("fopen"), .position(0))
        XCTAssertEqual(locatorForFree("execvP"), .position(0))
        XCTAssertEqual(locatorForFree("getaddrinfo"), .position(0))
        // A name ABSENT from the table falls back to the whole-list scan and is no worse than before —
        // the property that bounds this change's blast radius by construction.
        XCTAssertNil(locatorForFree("FileHandle"))
        XCTAssertNil(locatorForFree("URLSession"))
    }
}
