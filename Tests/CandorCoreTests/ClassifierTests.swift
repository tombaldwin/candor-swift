import XCTest
import SwiftParser
import SwiftSyntax
@testable import CandorCore

/// Native unit tests (XCTest) for CandorCore — the κ classifier, the §6.2 Exec-head refinement, the
/// SPEC §2 SQL-table extraction, and the SwiftSyntax type helpers. The smoke + fuzzer exercise these
/// only through a full scan; this pins their edge cases at the function boundary. Constructing a
/// `TypeSyntax` from a string needs SwiftParser, hence the dependency.
final class ClassifierTests: XCTestCase {

    func parseType(_ s: String) -> TypeSyntax {
        var parser = Parser(s)
        return TypeSyntax.parse(from: &parser)
    }

    // ── isHarnessPath ─────────────────────────────────────────────────────────────────────────────
    func testIsHarnessPath() {
        XCTAssertTrue(isHarnessPath("Package.swift"))
        XCTAssertTrue(isHarnessPath(".build/x/y.swift"))
        XCTAssertTrue(isHarnessPath("Tests/AppTests/FooTests.swift"))
        // a marker NESTED under Sources/ is production code, not harness (the under-report guard)
        XCTAssertFalse(isHarnessPath("Sources/App/Plugins/Render.swift"))
        XCTAssertFalse(isHarnessPath("Sources/App/Service.swift"))
    }

    // ── κ member / free / property classifiers (the cardinal-sin surface) ─────────────────────────
    func testKappaMember() {
        XCTAssertEqual(kappaMember(root: "FileManager", member: "removeItem"), "Fs")
        XCTAssertEqual(kappaMember(root: "URLSession", member: "dataTask"), "Net")
        XCTAssertEqual(kappaMember(root: "Process", member: "run"), "Exec")
        XCTAssertEqual(kappaMember(root: "Logger", member: "info"), "Log")
        XCTAssertEqual(kappaMember(root: "Int", member: "random"), "Rand")
        XCTAssertNil(kappaMember(root: "FileManager", member: "path"))     // pure accessor, not in FS_MEMBERS
        XCTAssertNil(kappaMember(root: "SomeLocalType", member: "save"))   // unknown root → no guess
    }

    func testKappaFree() {
        XCTAssertEqual(kappaFree(name: "Date", argCount: 0), "Clock")      // Date() reads the clock
        XCTAssertNil(kappaFree(name: "Date", argCount: 1))                 // Date(timeInterval:) is arithmetic
        XCTAssertEqual(kappaFree(name: "Process", argCount: 0), "Exec")
        XCTAssertEqual(kappaFree(name: "getenv", argCount: 1), "Env")
        XCTAssertEqual(kappaFree(name: "sqlite3_exec", argCount: 3), "Db") // sqlite3_ prefix → Db
        XCTAssertNil(kappaFree(name: "sqlite3_changes", argCount: 1))      // resident-state read → never Db
        XCTAssertEqual(kappaFree(name: "NSDate", argCount: 0), "Clock")    // legacy Date() twin
        XCTAssertEqual(kappaFree(name: "CACurrentMediaTime", argCount: 0), "Clock")
        XCTAssertEqual(kappaFree(name: "NSLog", argCount: 1), "Log")
        XCTAssertEqual(kappaFree(name: "Pipe", argCount: 0), "Ipc")
        XCTAssertNil(kappaFree(name: "myLocalHelper", argCount: 0))
        // property-read clock surface: ContinuousClock/SuspendingClock `.now`
        XCTAssertEqual(kappaPropertyRead(root: "ContinuousClock", path: ["now"]), "Clock")
        XCTAssertEqual(kappaPropertyRead(root: "SuspendingClock", path: ["now"]), "Clock")
    }

    func testKappaPropertyRead() {
        XCTAssertEqual(kappaPropertyRead(root: "ProcessInfo", path: ["processInfo", "environment"]), "Env")
        XCTAssertEqual(kappaPropertyRead(root: "Date", path: ["now"]), "Clock")
        XCTAssertNil(kappaPropertyRead(root: "Foo", path: ["bar"]))
    }

    // ── classifyCommandHead (§4 Exec refinement — UNAMBIGUOUS tools only) ─────────────────────────
    func testClassifyCommandHead() {
        XCTAssertEqual(classifyCommandHead("curl"), ["Net"])
        XCTAssertEqual(classifyCommandHead("/usr/bin/psql"), ["Db"])   // matched by basename
        XCTAssertEqual(classifyCommandHead("candor-scan"), ["Env", "Fs"])
        XCTAssertEqual(classifyCommandHead("git"), [])                 // multi-modal → no fabrication
    }

    // ── tablesInSql (SPEC §2, token-for-token across engines) ─────────────────────────────────────
    func testTablesInSql() {
        XCTAssertEqual(tablesInSql("SELECT id FROM users WHERE x = 1"), ["users"])
        XCTAssertEqual(tablesInSql("INSERT INTO audit_log (a) VALUES (1)"), ["audit_log"])
        XCTAssertEqual(tablesInSql("SELECT a FROM t1, t2 WHERE x = 1"), ["t1", "t2"]) // comma chain
        XCTAssertEqual(tablesInSql("SELECT a FROM t1 a1, t2"), ["t1"])               // an alias breaks the chain
        XCTAssertEqual(tablesInSql("hello world from nowhere"), [])                  // not SQL → nothing
    }

    // ── SwiftSyntax type helpers ──────────────────────────────────────────────────────────────────
    func testTypeName() {
        XCTAssertEqual(typeName(parseType("Foo")).name, "Foo")
        XCTAssertEqual(typeName(parseType("Foo?")).name, "Foo")        // Optional peeled
        XCTAssertEqual(typeName(parseType("any P")).name, "P")         // existential peeled
        XCTAssertTrue(typeName(parseType("(Int) -> Void")).isFunction) // function-typed
    }

    func testArrayElementName() {
        XCTAssertEqual(arrayElementName(parseType("[Client]")), "Client")
        XCTAssertEqual(arrayElementName(parseType("Set<Worker>")), "Worker")
        XCTAssertEqual(arrayElementName(parseType("Array<Foo>?")), "Foo")
        XCTAssertNil(arrayElementName(parseType("Int")))              // not a collection
    }

    func testTupleElements() {
        let t = tupleElements(parseType("(c: Client, n: Int)"))
        XCTAssertEqual(t["0"], "Client")
        XCTAssertEqual(t["c"], "Client")   // keyed by both position and label
        XCTAssertEqual(t["1"], "Int")
        XCTAssertEqual(t["n"], "Int")
        XCTAssertTrue(tupleElements(parseType("Int")).isEmpty)
    }

    func testDictValueName() {
        XCTAssertEqual(dictValueName(parseType("[String: Client]")), "Client")
        XCTAssertEqual(dictValueName(parseType("Dictionary<String, Worker>")), "Worker")
        XCTAssertNil(dictValueName(parseType("[Client]")))           // an array, not a dict
    }

    // ── propagate (the effect/surface least-fixpoint) ─────────────────────────────────────────────
    func testPropagateTransitive() {
        let r = propagate(["c": ["Fs"]], over: ["a": ["b"], "b": ["c"]])
        XCTAssertEqual(r["a"], ["Fs"])  // a -> b -> c
        XCTAssertEqual(r["b"], ["Fs"])
        XCTAssertEqual(r["c"], ["Fs"])
    }

    func testPropagateUnionsMultipleCallees() {
        let r = propagate(["x": ["Net"], "y": ["Db"]], over: ["caller": ["x", "y"]])
        XCTAssertEqual(r["caller"], ["Db", "Net"])
    }

    func testPropagateTerminatesOnCycle() {
        let r = propagate(["a": ["Fs"]], over: ["a": ["b"], "b": ["a"]]) // a <-> b
        XCTAssertEqual(r["a"], ["Fs"])
        XCTAssertEqual(r["b"], ["Fs"])  // the cycle does not loop forever
    }

    func testPropagateWorksForLiteralSurfaces() {
        // the same fixpoint carries literal surfaces (hosts/paths/…), not just effects
        let r = propagate(["leaf": ["api.example.com"]], over: ["root": ["leaf"]])
        XCTAssertEqual(r["root"], ["api.example.com"])
    }

    func testPropagatePureLeafStaysEmpty() {
        let r = propagate([:], over: ["a": ["b"]])
        XCTAssertNil(r["a"])  // nothing reachable carries a value
    }
}
