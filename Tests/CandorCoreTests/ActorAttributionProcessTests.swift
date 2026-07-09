import XCTest
import Foundation

/// `actor` declarations — DeclCollector's ActorDecl visitor (pushType) had NO fixture anywhere in
/// the repo (no XCTest, no smoke case, no fuzz form), so an actor's effectful method attributing at
/// all was unverified. Pins: an actor's effectful method attributes to `Actor.method` exactly like a
/// class's; a pure actor contributes nothing; a caller resolves the typed actor receiver's member
/// call to the actor unit (the pushType-fed localTypes/declaredTypes path).
final class ActorAttributionProcessTests: XCTestCase {

    func testActorMethodsAttributeAndPureActorStaysPure() throws {
        let bin = try ProcessHarness.binaryURL(for: ActorAttributionProcessTests.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        actor DiskCache {
            func store() { _ = FileManager.default.contents(atPath: "/tmp/x") }
            func pureMath() -> Int { 40 + 2 }
        }
        actor Counter {
            var n = 0
            func bump() { n += 1 }
        }
        func useCache(_ c: DiskCache) async { await c.store() }
        func useCounter(_ c: Counter) async { await c.bump() }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let by = try ProcessHarness.fns(ofJson: r.out)

        // the effectful actor method attributes to the Actor.method unit
        XCTAssertEqual(ProcessHarness.inferred(by, "DiskCache.store"), ["Fs"],
                       "an actor's Fs method must attribute to Actor.method")
        // a caller through the typed actor receiver inherits the effect (member resolution via pushType)
        XCTAssertEqual(ProcessHarness.inferred(by, "useCache"), ["Fs"],
                       "a typed actor receiver's member call must edge to the actor unit")
        // the pure actor surface stays out — no Unknown, no fabrication on isolation machinery
        XCTAssertNil(by["DiskCache.pureMath"], "a pure actor method must be omitted")
        XCTAssertNil(by["Counter.bump"], "a pure actor must contribute nothing")
        XCTAssertNil(by["useCounter"], "calling a pure actor is pure — never Unknown from actor isolation")
    }

    // an actor's stored-property initializer wires into `Actor.init` like a class's (the synthesized-
    // init orphaned-field-initializer rule must not be class/struct-only).
    func testActorStoredPropertyInitializerChargesConstruction() throws {
        let bin = try ProcessHarness.binaryURL(for: ActorAttributionProcessTests.self)
        let root = try ProcessHarness.makePackage("""
        import Foundation
        actor Wired {
            let home = ProcessInfo.processInfo.environment["HOME"]
        }
        func build() -> Wired { Wired() }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        let by = try ProcessHarness.fns(ofJson: r.out)
        XCTAssertEqual(ProcessHarness.inferred(by, "Wired.init"), ["Env"],
                       "an actor's field initializer runs at construction — it must charge Wired.init")
        XCTAssertEqual(ProcessHarness.inferred(by, "build"), ["Env"],
                       "constructing the actor must reach the synthesized-init unit")
    }
}
