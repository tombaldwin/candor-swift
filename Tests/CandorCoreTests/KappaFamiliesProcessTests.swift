import XCTest
import Foundation

/// End-to-end pins for the κ table families that had no in-repo execution (CoreData, Network's
/// NWConnection ctor, the NIO tier, AsyncHTTPClient) — each family gets the POSITIVE scan (the row
/// fires through a typed receiver, TESTING.md §2.3's table companion at the process layer) and the
/// ANTI-FABRICATION TWIN: a project type DECLARING the modeled name shadows the κ table via
/// `declaredTypes` (Classifier.swift's shadow discipline), so the lookalike must stay pure.
final class KappaFamiliesProcessTests: XCTestCase {

    private func scan(_ src: String) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: KappaFamiliesProcessTests.self)
        let root = try ProcessHarness.makePackage(src)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"])
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }

    // ── the positive family scan: every κ family row fires through a typed receiver ────────────────
    func testKappaFamiliesClassifyEndToEnd() throws {
        let by = try scan("""
        import Foundation
        import CoreData
        import Network
        import NIOCore
        import AsyncHTTPClient

        func cdSave(_ ctx: NSManagedObjectContext) { try? ctx.save() }
        func cdExecute(_ ctx: NSManagedObjectContext) { _ = try? ctx.execute(NSBatchDeleteRequest(fetchRequest: .init(entityName: "E"))) }
        func cdLoad(_ c: NSPersistentContainer) { c.loadPersistentStores { _, _ in } }
        func nwConnect() { let c = NWConnection(host: "h.example.com", port: 1); c.start(queue: .main) }
        func nioConnect(_ b: ClientBootstrap) { _ = b.connect(host: "nio.example.com", port: 80) }
        func nioWrite(_ ch: Channel) { _ = ch.writeAndFlush("payload") }
        func ahcGet(_ h: HTTPClient) { _ = h.get(url: "https://ahc.example.com/x") }
        """)
        XCTAssertEqual(ProcessHarness.inferred(by, "cdSave"), ["Db"], "NSManagedObjectContext.save → Db")
        XCTAssertEqual(ProcessHarness.inferred(by, "cdExecute")?.contains("Db"), true, "ctx.execute → Db")
        XCTAssertEqual(ProcessHarness.inferred(by, "cdLoad"), ["Db"], "NSPersistentContainer.loadPersistentStores → Db")
        XCTAssertEqual(ProcessHarness.inferred(by, "nwConnect"), ["Net"], "NWConnection ctor + start → Net")
        // the NWConnection ctor is an ESTABLISHING free form: its host:port folds into the surface.
        XCTAssertEqual(by["nwConnect"]?["hosts"] as? [String], ["h.example.com:1"],
                       "the establishing ctor carries the host literal into the Net surface")
        XCTAssertEqual(ProcessHarness.inferred(by, "nioConnect"), ["Net"], "ClientBootstrap.connect → Net")
        XCTAssertEqual(by["nioConnect"]?["hosts"] as? [String], ["nio.example.com:80"],
                       "bootstrap.connect(host:port:) folds the establishing host literal")
        XCTAssertEqual(ProcessHarness.inferred(by, "nioWrite"), ["Net"], "Channel.writeAndFlush (USE-verb) → Net")
        XCTAssertEqual(ProcessHarness.inferred(by, "ahcGet"), ["Net"], "HTTPClient.get → Net")
        XCTAssertEqual(by["ahcGet"]?["hosts"] as? [String], ["ahc.example.com"], "HTTPClient.get(url:) host surface")
    }

    // ── the anti-fabrication twins: a PROJECT type declaring a modeled name shadows the κ row ──────
    // One twin per family (TESTING.md §2.3). Every call below is on a locally-DECLARED type (or its
    // ctor), so the shadow discipline (declaredTypes / localFreeFns) must keep all of them pure —
    // any effect here is a fabrication on project code, the cardinal sin.
    func testProjectTypesShadowingKappaNamesStayPure() throws {
        let by = try scan("""
        import Foundation
        struct NWConnection { func send() {}; func start() {} }
        class NSManagedObjectContext { func save() {} }
        struct Channel { func writeAndFlush(_ s: String) {} }
        struct HTTPClient { func get(url: String) {} }
        struct ClientBootstrap { func connect(host: String, port: Int) {} }
        func shadowNWCtorAndVerbs() { let c = NWConnection(); c.send(); c.start() }
        func shadowCoreData(_ ctx: NSManagedObjectContext) { ctx.save() }
        func shadowNIOChannel(_ ch: Channel) { ch.writeAndFlush("x") }
        func shadowNIOBootstrap(_ b: ClientBootstrap) { b.connect(host: "h", port: 1) }
        func shadowAHC(_ h: HTTPClient) { h.get(url: "https://x") }
        """)
        for fn in ["shadowNWCtorAndVerbs", "shadowCoreData", "shadowNIOChannel", "shadowNIOBootstrap", "shadowAHC"] {
            XCTAssertNil(by[fn], "\(fn) calls only the PROJECT's own \(fn.dropFirst(6)) type — " +
                         "classifying it is a fabrication; got \(by[fn] ?? [:])")
        }
    }
}
