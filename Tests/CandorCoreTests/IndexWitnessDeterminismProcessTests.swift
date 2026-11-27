import XCTest
import Foundation

/// SOUNDNESS R1943 — THE REPORT MUST NOT DEPEND ON THE PROCESS'S HASH SEED.
///
/// swift-collections' `BigString` read two different edge sets on two runs of one binary over one tree: its Index witnesses
/// came out as `BigString.Index.<`/`==` on one run and `BigString._Chunk.Index.<`/`==` on the next. The Index's own comparison
/// witnesses are collected per collection type by `byOwnerMember.first { $0.key.hasPrefix("<t>.") }` — an arbitrary DICTIONARY
/// entry, and one that ALSO matches an extension spelled `<t>._Chunk`, so which nested type's paths seeded the lookup was a
/// coin toss per process. (A second site of the same kind: the R1490 witness question's dedup key left out the protocol, so
/// whichever overload asked first decided whether the conformance guard answered.)
///
/// WHY THE TEST SCANS REPEATEDLY AND THE OUTPUTS ARE COMPARED ACROSS PROCESSES. Swift seeds Set/Dictionary hashing PER PROCESS,
/// so two scans inside one test process share a seed and can agree while the defect is live. Each `ProcessHarness.run` is a
/// fresh process. Measured on main 144e602 with this fixture: about one run in two differs, so sixteen scans disagree with
/// probability 1 - 2^-15.
final class IndexWitnessDeterminismProcessTests: XCTestCase {

    static let src: String = {
        var chunk = ""
        for i in 0..<8 { chunk += "  func chunkMember\(i)() {}\n" }
        return """
        import Foundation
        func mark() { FileManager.default.createFile(atPath: "/tmp/r1943", contents: nil) }
        struct Big: BidirectionalCollection {
          struct Index: Comparable { var i: Int
            static func < (a: Index, b: Index) -> Bool { mark(); return a.i < b.i }
            static func == (a: Index, b: Index) -> Bool { mark(); return a.i == b.i } }
          struct _Chunk { var n = 0 }
          var items: [Int] = [1, 2]
          var startIndex: Index { Index(i: 0) }
          var endIndex: Index { Index(i: items.count) }
          subscript(p: Index) -> Int { items[p.i] }
          func index(after i: Index) -> Index { Index(i: i.i + 1) }
          func index(before i: Index) -> Index { Index(i: i.i - 1) }
        }
        extension Big._Chunk {
          struct Index: Comparable { var i: Int
            static func < (a: Index, b: Index) -> Bool { mark(); return a.i < b.i }
            static func == (a: Index, b: Index) -> Bool { mark(); return a.i == b.i } }
        \(chunk)}
        func cwIter<C: Collection>(_ c: C) { for _ in c { } }
        func go() { cwIter(Big()) }
        """
    }()

    func testCollectionIndexWitnessesDoNotDependOnTheHashSeed() throws {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makePackage(Self.src, name: "Det")
        defer { try? FileManager.default.removeItem(at: root) }
        var reports: [Data] = []
        var goCalls: [Set<String>] = []
        for i in 0..<16 {
            let out = root.appendingPathComponent("r\(i)")
            let r = try ProcessHarness.run(bin, [root.path, "--out", out.path])
            XCTAssertEqual(r.code, 0, "scan must succeed; stderr: \(r.err)")
            let data = try Data(contentsOf: root.appendingPathComponent("r\(i).Det.Swift.json"))
            reports.append(data)
            let d = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let fns = (d["functions"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            goCalls.append(Set(fns.first { $0["fn"] as? String == "go" }?["calls"] as? [String] ?? []))
        }
        // the trigger must be live: `go` edges the Index witnesses at all, or the comparison below is vacuous
        XCTAssertTrue(goCalls[0].contains("Big.Index.<") || goCalls[0].contains("Big._Chunk.Index.<"),
                      "fixture not live; go calls \(goCalls[0].sorted())")
        // the RIGHT answer, not merely a stable one: `Big`'s Index is `Big.Index`, never the nested `Big._Chunk.Index`
        for c in goCalls {
            XCTAssertTrue(c.contains("Big.Index.<") && c.contains("Big.Index.=="), "calls \(c.sorted())")
            XCTAssertFalse(c.contains("Big._Chunk.Index.<") || c.contains("Big._Chunk.Index.=="), "calls \(c.sorted())")
        }
        XCTAssertEqual(Set(reports).count, 1, "sixteen scans of one tree produced \(Set(reports).count) distinct reports")
    }
}
