import XCTest
import Foundation

/// SOUNDNESS R1526 — A LOCAL COLLECTION WITH NO ITERATOR OF ITS OWN IS ITERATED THROUGH ITS COLLECTION WITNESSES.
/// The stdlib iterates `struct C: BidirectionalCollection` (no `makeIterator`) with `IndexingIterator`, which runs
/// `startIndex`/`endIndex`/`subscript`/`index(after:)` and the Index's `==`; a generic algorithm may run any requirement
/// witness and the Index's `<`. R1048 edged only `makeIterator`/`next`, so every spelling below was ABSENT while the
/// compiled program wrote its marker (executed: `~/candor-handoff/swift-r1526/`, fixture T). One switch per route:
///   (C) `CANDOR_R1526C_OFF` the collection's own witnesses; (I) `CANDOR_R1526I_OFF` the Index's comparison witnesses;
///   (M) `CANDOR_R1526M_OFF` an explicit `makeIterator()`; (G) `CANDOR_R1526G_OFF` a generic `<C: Collection>` callee;
///   (P) `CANDOR_R1526P_OFF` a stdlib property (`count`); (W) `CANDOR_R1526W_OFF` a requirement a generic wrapper reads
///   on its stored `B: Collection` (`isEmpty`); (S) `CANDOR_R1526S_OFF` a stdlib requirement a local extension shadows
///   by name (`partition(by:)` beside `partition(subrange:by:)`).
/// Controls, executed pure: a for-in never runs `index(before:)` or the Index's `<`; a non-witness member never runs;
/// an array HOLDING loud collections is not iterating them.
final class CollectionWitnessIterationProcessTests: XCTestCase {

    static let src = """
    import Foundation
    func mark() { FileManager.default.createFile(atPath: "/tmp/r1526-it", contents: nil) }
    func cwIter<C: Collection>(_ c: C) { for _ in c { } }
    struct CwWrap<B: Collection> { let b: B; func empty() -> Bool { b.isEmpty } }
    extension MutableCollection { mutating func partition(subrange r: Range<Index>, by p: (Element) -> Bool) -> Index { r.lowerBound } }
    struct CwForSubLI: Comparable { var i: Int
      static func < (a: CwForSubLI, b: CwForSubLI) -> Bool { return a.i < b.i }
      static func == (a: CwForSubLI, b: CwForSubLI) -> Bool { return a.i == b.i } }
    struct CwForSubL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwForSubLI { CwForSubLI(i: 0) }; var endIndex: CwForSubLI { CwForSubLI(i: items.count) }
      subscript(p: CwForSubLI) -> Int { mark(); return items[p.i] }
      func index(after i: CwForSubLI) -> CwForSubLI { return CwForSubLI(i: i.i + 1) }
      func index(before i: CwForSubLI) -> CwForSubLI { return CwForSubLI(i: i.i - 1) }
      func helper() { } }

    func cwForSubL() { for _ in CwForSubL() { } }
    struct CwForSubPI: Comparable { var i: Int
      static func < (a: CwForSubPI, b: CwForSubPI) -> Bool { return a.i < b.i }
      static func == (a: CwForSubPI, b: CwForSubPI) -> Bool { return a.i == b.i } }
    struct CwForSubP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwForSubPI { CwForSubPI(i: 0) }; var endIndex: CwForSubPI { CwForSubPI(i: items.count) }
      subscript(p: CwForSubPI) -> Int { return items[p.i] }
      func index(after i: CwForSubPI) -> CwForSubPI { return CwForSubPI(i: i.i + 1) }
      func index(before i: CwForSubPI) -> CwForSubPI { return CwForSubPI(i: i.i - 1) }
      func helper() { } }

    func cwForSubP() { for _ in CwForSubP() { } }
    struct CwForEqLI: Comparable { var i: Int
      static func < (a: CwForEqLI, b: CwForEqLI) -> Bool { return a.i < b.i }
      static func == (a: CwForEqLI, b: CwForEqLI) -> Bool { mark(); return a.i == b.i } }
    struct CwForEqL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwForEqLI { CwForEqLI(i: 0) }; var endIndex: CwForEqLI { CwForEqLI(i: items.count) }
      subscript(p: CwForEqLI) -> Int { return items[p.i] }
      func index(after i: CwForEqLI) -> CwForEqLI { return CwForEqLI(i: i.i + 1) }
      func index(before i: CwForEqLI) -> CwForEqLI { return CwForEqLI(i: i.i - 1) }
      func helper() { } }

    func cwForEqL() { for _ in CwForEqL() { } }
    struct CwForEqPI: Comparable { var i: Int
      static func < (a: CwForEqPI, b: CwForEqPI) -> Bool { return a.i < b.i }
      static func == (a: CwForEqPI, b: CwForEqPI) -> Bool { return a.i == b.i } }
    struct CwForEqP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwForEqPI { CwForEqPI(i: 0) }; var endIndex: CwForEqPI { CwForEqPI(i: items.count) }
      subscript(p: CwForEqPI) -> Int { return items[p.i] }
      func index(after i: CwForEqPI) -> CwForEqPI { return CwForEqPI(i: i.i + 1) }
      func index(before i: CwForEqPI) -> CwForEqPI { return CwForEqPI(i: i.i - 1) }
      func helper() { } }

    func cwForEqP() { for _ in CwForEqP() { } }
    struct CwMakeItLI: Comparable { var i: Int
      static func < (a: CwMakeItLI, b: CwMakeItLI) -> Bool { return a.i < b.i }
      static func == (a: CwMakeItLI, b: CwMakeItLI) -> Bool { mark(); return a.i == b.i } }
    struct CwMakeItL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwMakeItLI { CwMakeItLI(i: 0) }; var endIndex: CwMakeItLI { CwMakeItLI(i: items.count) }
      subscript(p: CwMakeItLI) -> Int { return items[p.i] }
      func index(after i: CwMakeItLI) -> CwMakeItLI { return CwMakeItLI(i: i.i + 1) }
      func index(before i: CwMakeItLI) -> CwMakeItLI { return CwMakeItLI(i: i.i - 1) }
      func helper() { } }

    func cwMakeItL() { var i = CwMakeItL().makeIterator(); _ = i.next() }
    struct CwMakeItPI: Comparable { var i: Int
      static func < (a: CwMakeItPI, b: CwMakeItPI) -> Bool { return a.i < b.i }
      static func == (a: CwMakeItPI, b: CwMakeItPI) -> Bool { return a.i == b.i } }
    struct CwMakeItP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwMakeItPI { CwMakeItPI(i: 0) }; var endIndex: CwMakeItPI { CwMakeItPI(i: items.count) }
      subscript(p: CwMakeItPI) -> Int { return items[p.i] }
      func index(after i: CwMakeItPI) -> CwMakeItPI { return CwMakeItPI(i: i.i + 1) }
      func index(before i: CwMakeItPI) -> CwMakeItPI { return CwMakeItPI(i: i.i - 1) }
      func helper() { } }

    func cwMakeItP() { var i = CwMakeItP().makeIterator(); _ = i.next() }
    struct CwGenericLI: Comparable { var i: Int
      static func < (a: CwGenericLI, b: CwGenericLI) -> Bool { return a.i < b.i }
      static func == (a: CwGenericLI, b: CwGenericLI) -> Bool { return a.i == b.i } }
    struct CwGenericL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwGenericLI { CwGenericLI(i: 0) }; var endIndex: CwGenericLI { CwGenericLI(i: items.count) }
      subscript(p: CwGenericLI) -> Int { mark(); return items[p.i] }
      func index(after i: CwGenericLI) -> CwGenericLI { return CwGenericLI(i: i.i + 1) }
      func index(before i: CwGenericLI) -> CwGenericLI { return CwGenericLI(i: i.i - 1) }
      func helper() { } }

    func cwGenericL() { cwIter(CwGenericL()) }
    struct CwGenericPI: Comparable { var i: Int
      static func < (a: CwGenericPI, b: CwGenericPI) -> Bool { return a.i < b.i }
      static func == (a: CwGenericPI, b: CwGenericPI) -> Bool { return a.i == b.i } }
    struct CwGenericP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwGenericPI { CwGenericPI(i: 0) }; var endIndex: CwGenericPI { CwGenericPI(i: items.count) }
      subscript(p: CwGenericPI) -> Int { return items[p.i] }
      func index(after i: CwGenericPI) -> CwGenericPI { return CwGenericPI(i: i.i + 1) }
      func index(before i: CwGenericPI) -> CwGenericPI { return CwGenericPI(i: i.i - 1) }
      func helper() { } }

    func cwGenericP() { cwIter(CwGenericP()) }
    struct CwCountLI: Comparable { var i: Int
      static func < (a: CwCountLI, b: CwCountLI) -> Bool { return a.i < b.i }
      static func == (a: CwCountLI, b: CwCountLI) -> Bool { return a.i == b.i } }
    struct CwCountL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwCountLI { CwCountLI(i: 0) }; var endIndex: CwCountLI { CwCountLI(i: items.count) }
      subscript(p: CwCountLI) -> Int { return items[p.i] }
      func index(after i: CwCountLI) -> CwCountLI { mark(); return CwCountLI(i: i.i + 1) }
      func index(before i: CwCountLI) -> CwCountLI { return CwCountLI(i: i.i - 1) }
      func helper() { } }

    func cwCountL() { _ = CwCountL().count }
    struct CwCountPI: Comparable { var i: Int
      static func < (a: CwCountPI, b: CwCountPI) -> Bool { return a.i < b.i }
      static func == (a: CwCountPI, b: CwCountPI) -> Bool { return a.i == b.i } }
    struct CwCountP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwCountPI { CwCountPI(i: 0) }; var endIndex: CwCountPI { CwCountPI(i: items.count) }
      subscript(p: CwCountPI) -> Int { return items[p.i] }
      func index(after i: CwCountPI) -> CwCountPI { return CwCountPI(i: i.i + 1) }
      func index(before i: CwCountPI) -> CwCountPI { return CwCountPI(i: i.i - 1) }
      func helper() { } }

    func cwCountP() { _ = CwCountP().count }
    struct CwWrapEmptyLI: Comparable { var i: Int
      static func < (a: CwWrapEmptyLI, b: CwWrapEmptyLI) -> Bool { return a.i < b.i }
      static func == (a: CwWrapEmptyLI, b: CwWrapEmptyLI) -> Bool { mark(); return a.i == b.i } }
    struct CwWrapEmptyL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwWrapEmptyLI { CwWrapEmptyLI(i: 0) }; var endIndex: CwWrapEmptyLI { CwWrapEmptyLI(i: items.count) }
      subscript(p: CwWrapEmptyLI) -> Int { return items[p.i] }
      func index(after i: CwWrapEmptyLI) -> CwWrapEmptyLI { return CwWrapEmptyLI(i: i.i + 1) }
      func index(before i: CwWrapEmptyLI) -> CwWrapEmptyLI { return CwWrapEmptyLI(i: i.i - 1) }
      func helper() { } }

    func cwWrapEmptyL() { _ = CwWrap(b: CwWrapEmptyL()).empty() }
    struct CwWrapEmptyPI: Comparable { var i: Int
      static func < (a: CwWrapEmptyPI, b: CwWrapEmptyPI) -> Bool { return a.i < b.i }
      static func == (a: CwWrapEmptyPI, b: CwWrapEmptyPI) -> Bool { return a.i == b.i } }
    struct CwWrapEmptyP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwWrapEmptyPI { CwWrapEmptyPI(i: 0) }; var endIndex: CwWrapEmptyPI { CwWrapEmptyPI(i: items.count) }
      subscript(p: CwWrapEmptyPI) -> Int { return items[p.i] }
      func index(after i: CwWrapEmptyPI) -> CwWrapEmptyPI { return CwWrapEmptyPI(i: i.i + 1) }
      func index(before i: CwWrapEmptyPI) -> CwWrapEmptyPI { return CwWrapEmptyPI(i: i.i - 1) }
      func helper() { } }

    func cwWrapEmptyP() { _ = CwWrap(b: CwWrapEmptyP()).empty() }
    struct CwPartitionLI: Comparable { var i: Int
      static func < (a: CwPartitionLI, b: CwPartitionLI) -> Bool { return a.i < b.i }
      static func == (a: CwPartitionLI, b: CwPartitionLI) -> Bool { return a.i == b.i } }
    struct CwPartitionL: MutableCollection, BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwPartitionLI { CwPartitionLI(i: 0) }; var endIndex: CwPartitionLI { CwPartitionLI(i: items.count) }
      subscript(p: CwPartitionLI) -> Int { get { return items[p.i] } set { mark(); items[p.i] = newValue } }
      func index(after i: CwPartitionLI) -> CwPartitionLI { return CwPartitionLI(i: i.i + 1) }
      func index(before i: CwPartitionLI) -> CwPartitionLI { return CwPartitionLI(i: i.i - 1) }
      func helper() { } }

    func cwPartitionL() { var m = CwPartitionL(); _ = m.partition(by: { $0 > 1 }) }
    struct CwPartitionPI: Comparable { var i: Int
      static func < (a: CwPartitionPI, b: CwPartitionPI) -> Bool { return a.i < b.i }
      static func == (a: CwPartitionPI, b: CwPartitionPI) -> Bool { return a.i == b.i } }
    struct CwPartitionP: MutableCollection, BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwPartitionPI { CwPartitionPI(i: 0) }; var endIndex: CwPartitionPI { CwPartitionPI(i: items.count) }
      subscript(p: CwPartitionPI) -> Int { get { return items[p.i] } set { items[p.i] = newValue } }
      func index(after i: CwPartitionPI) -> CwPartitionPI { return CwPartitionPI(i: i.i + 1) }
      func index(before i: CwPartitionPI) -> CwPartitionPI { return CwPartitionPI(i: i.i - 1) }
      func helper() { } }

    func cwPartitionP() { var m = CwPartitionP(); _ = m.partition(by: { $0 > 1 }) }
    struct CwArrLI: Comparable { var i: Int
      static func < (a: CwArrLI, b: CwArrLI) -> Bool { return a.i < b.i }
      static func == (a: CwArrLI, b: CwArrLI) -> Bool { mark(); return a.i == b.i } }
    struct CwArrL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwArrLI { CwArrLI(i: 0) }; var endIndex: CwArrLI { CwArrLI(i: items.count) }
      subscript(p: CwArrLI) -> Int { return items[p.i] }
      func index(after i: CwArrLI) -> CwArrLI { return CwArrLI(i: i.i + 1) }
      func index(before i: CwArrLI) -> CwArrLI { return CwArrLI(i: i.i - 1) }
      func helper() { } }

    func cwArrL() { _ = Array(CwArrL()) }
    struct CwArrPI: Comparable { var i: Int
      static func < (a: CwArrPI, b: CwArrPI) -> Bool { return a.i < b.i }
      static func == (a: CwArrPI, b: CwArrPI) -> Bool { return a.i == b.i } }
    struct CwArrP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwArrPI { CwArrPI(i: 0) }; var endIndex: CwArrPI { CwArrPI(i: items.count) }
      subscript(p: CwArrPI) -> Int { return items[p.i] }
      func index(after i: CwArrPI) -> CwArrPI { return CwArrPI(i: i.i + 1) }
      func index(before i: CwArrPI) -> CwArrPI { return CwArrPI(i: i.i - 1) }
      func helper() { } }

    func cwArrP() { _ = Array(CwArrP()) }
    struct CwBeforeLI: Comparable { var i: Int
      static func < (a: CwBeforeLI, b: CwBeforeLI) -> Bool { return a.i < b.i }
      static func == (a: CwBeforeLI, b: CwBeforeLI) -> Bool { return a.i == b.i } }
    struct CwBeforeL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwBeforeLI { CwBeforeLI(i: 0) }; var endIndex: CwBeforeLI { CwBeforeLI(i: items.count) }
      subscript(p: CwBeforeLI) -> Int { return items[p.i] }
      func index(after i: CwBeforeLI) -> CwBeforeLI { return CwBeforeLI(i: i.i + 1) }
      func index(before i: CwBeforeLI) -> CwBeforeLI { mark(); return CwBeforeLI(i: i.i - 1) }
      func helper() { } }

    func cwBeforeL() { for _ in CwBeforeL() { } }
    struct CwBeforePI: Comparable { var i: Int
      static func < (a: CwBeforePI, b: CwBeforePI) -> Bool { return a.i < b.i }
      static func == (a: CwBeforePI, b: CwBeforePI) -> Bool { return a.i == b.i } }
    struct CwBeforeP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwBeforePI { CwBeforePI(i: 0) }; var endIndex: CwBeforePI { CwBeforePI(i: items.count) }
      subscript(p: CwBeforePI) -> Int { return items[p.i] }
      func index(after i: CwBeforePI) -> CwBeforePI { return CwBeforePI(i: i.i + 1) }
      func index(before i: CwBeforePI) -> CwBeforePI { return CwBeforePI(i: i.i - 1) }
      func helper() { } }

    func cwBeforeP() { for _ in CwBeforeP() { } }
    struct CwLessLI: Comparable { var i: Int
      static func < (a: CwLessLI, b: CwLessLI) -> Bool { mark(); return a.i < b.i }
      static func == (a: CwLessLI, b: CwLessLI) -> Bool { return a.i == b.i } }
    struct CwLessL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwLessLI { CwLessLI(i: 0) }; var endIndex: CwLessLI { CwLessLI(i: items.count) }
      subscript(p: CwLessLI) -> Int { return items[p.i] }
      func index(after i: CwLessLI) -> CwLessLI { return CwLessLI(i: i.i + 1) }
      func index(before i: CwLessLI) -> CwLessLI { return CwLessLI(i: i.i - 1) }
      func helper() { } }

    func cwLessL() { for _ in CwLessL() { } }
    struct CwLessPI: Comparable { var i: Int
      static func < (a: CwLessPI, b: CwLessPI) -> Bool { return a.i < b.i }
      static func == (a: CwLessPI, b: CwLessPI) -> Bool { return a.i == b.i } }
    struct CwLessP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwLessPI { CwLessPI(i: 0) }; var endIndex: CwLessPI { CwLessPI(i: items.count) }
      subscript(p: CwLessPI) -> Int { return items[p.i] }
      func index(after i: CwLessPI) -> CwLessPI { return CwLessPI(i: i.i + 1) }
      func index(before i: CwLessPI) -> CwLessPI { return CwLessPI(i: i.i - 1) }
      func helper() { } }

    func cwLessP() { for _ in CwLessP() { } }
    struct CwHelperLI: Comparable { var i: Int
      static func < (a: CwHelperLI, b: CwHelperLI) -> Bool { return a.i < b.i }
      static func == (a: CwHelperLI, b: CwHelperLI) -> Bool { return a.i == b.i } }
    struct CwHelperL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwHelperLI { CwHelperLI(i: 0) }; var endIndex: CwHelperLI { CwHelperLI(i: items.count) }
      subscript(p: CwHelperLI) -> Int { return items[p.i] }
      func index(after i: CwHelperLI) -> CwHelperLI { return CwHelperLI(i: i.i + 1) }
      func index(before i: CwHelperLI) -> CwHelperLI { return CwHelperLI(i: i.i - 1) }
      func helper() { mark(); } }

    func cwHelperL() { _ = Array(CwHelperL()) }
    struct CwHelperPI: Comparable { var i: Int
      static func < (a: CwHelperPI, b: CwHelperPI) -> Bool { return a.i < b.i }
      static func == (a: CwHelperPI, b: CwHelperPI) -> Bool { return a.i == b.i } }
    struct CwHelperP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwHelperPI { CwHelperPI(i: 0) }; var endIndex: CwHelperPI { CwHelperPI(i: items.count) }
      subscript(p: CwHelperPI) -> Int { return items[p.i] }
      func index(after i: CwHelperPI) -> CwHelperPI { return CwHelperPI(i: i.i + 1) }
      func index(before i: CwHelperPI) -> CwHelperPI { return CwHelperPI(i: i.i - 1) }
      func helper() { } }

    func cwHelperP() { _ = Array(CwHelperP()) }
    struct CwElemsLI: Comparable { var i: Int
      static func < (a: CwElemsLI, b: CwElemsLI) -> Bool { return a.i < b.i }
      static func == (a: CwElemsLI, b: CwElemsLI) -> Bool { mark(); return a.i == b.i } }
    struct CwElemsL: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwElemsLI { CwElemsLI(i: 0) }; var endIndex: CwElemsLI { CwElemsLI(i: items.count) }
      subscript(p: CwElemsLI) -> Int { return items[p.i] }
      func index(after i: CwElemsLI) -> CwElemsLI { return CwElemsLI(i: i.i + 1) }
      func index(before i: CwElemsLI) -> CwElemsLI { return CwElemsLI(i: i.i - 1) }
      func helper() { } }

    func cwElemsL() { let a = [CwElemsL(), CwElemsL()]; _ = a.count; for _ in a { } }
    struct CwElemsPI: Comparable { var i: Int
      static func < (a: CwElemsPI, b: CwElemsPI) -> Bool { return a.i < b.i }
      static func == (a: CwElemsPI, b: CwElemsPI) -> Bool { return a.i == b.i } }
    struct CwElemsP: BidirectionalCollection { var items: [Int] = [3, 1, 2]
      var startIndex: CwElemsPI { CwElemsPI(i: 0) }; var endIndex: CwElemsPI { CwElemsPI(i: items.count) }
      subscript(p: CwElemsPI) -> Int { return items[p.i] }
      func index(after i: CwElemsPI) -> CwElemsPI { return CwElemsPI(i: i.i + 1) }
      func index(before i: CwElemsPI) -> CwElemsPI { return CwElemsPI(i: i.i - 1) }
      func helper() { } }

    func cwElemsP() { let a = [CwElemsP(), CwElemsP()]; _ = a.count; for _ in a { } }
    """

    static let loud = ["cwForSubL", "cwForEqL", "cwMakeItL", "cwGenericL", "cwCountL", "cwWrapEmptyL", "cwPartitionL", "cwArrL"]
    static let pure = ["cwForSubP", "cwForEqP", "cwMakeItP", "cwGenericP", "cwCountP", "cwWrapEmptyP", "cwPartitionP", "cwArrP",
                       "cwBeforeL", "cwBeforeP", "cwLessL", "cwLessP", "cwHelperL", "cwHelperP", "cwElemsL", "cwElemsP"]

    private func scan(_ root: URL, env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, "scan must succeed — stderr: \(r.err)")
        return try ProcessHarness.fns(ofJson: r.out)
    }
    private func fs(_ by: [String: [String: Any]], _ fn: String) -> Bool { ProcessHarness.inferred(by, fn)?.contains("Fs") == true }

    func testLocalCollectionWitnessesAreCharged() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let by = try scan(root)
        for fn in Self.loud { XCTAssertTrue(fs(by, fn), "\(fn) runs a loud collection witness — \(by[fn] ?? [:])") }
        for fn in Self.pure { XCTAssertFalse(fs(by, fn), "\(fn) runs no loud witness — \(by[fn] ?? [:])") }
        let off = try scan(root, env: ["CANDOR_R1526_OFF": "1"])
        for fn in Self.loud { XCTAssertFalse(fs(off, fn), "\(fn) under R1526_OFF reads as the release did") }
    }

    func testEachRouteHasItsOwnSwitch() throws {
        let root = try ProcessHarness.makePackage(Self.src)
        defer { try? FileManager.default.removeItem(at: root) }
        let routes: [(String, [String])] = [("C", ["cwForSubL", "cwGenericL", "cwCountL", "cwPartitionL"]), ("I", ["cwForEqL", "cwArrL", "cwMakeItL", "cwWrapEmptyL"]),
                                            ("M", ["cwMakeItL"]), ("G", ["cwGenericL"]), ("P", ["cwCountL"]),
                                            ("W", ["cwWrapEmptyL"]), ("S", ["cwPartitionL"])]
        for (k, gone) in routes {
            let by = try scan(root, env: ["CANDOR_R1526\(k)_OFF": "1"])
            for fn in gone { XCTAssertFalse(fs(by, fn), "\(fn) under R1526\(k)_OFF") }
            for fn in Self.loud where !gone.contains(fn) { XCTAssertTrue(fs(by, fn), "\(fn) does not depend on R1526\(k)") }
        }
    }
}
