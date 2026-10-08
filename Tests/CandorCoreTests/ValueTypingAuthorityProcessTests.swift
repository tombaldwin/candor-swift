import Foundation
import XCTest

/// SOUNDNESS R990–R1000, R791, R792, R773, R905, R974 — HOW A BINDING OR A COLLECTION GETS ITS TYPE, as one executed fixture.
///
/// Every `pos*` cell really reaches `Ctx.invoke()`, which reads the environment (`Env`); every `ctl*` cell really
/// runs only code that performs nothing (`testFixtureGroundTruthExecutes` compiles and runs the program and
/// checks both). On v0.40.0 every `pos*` cell was ABSENT (`deny Env` exit 0); `CANDOR_VT_OFF` restores that.
/// The `ctl*` cells are the fabrication direction of each mechanism, and each was shown able to fail by deleting
/// the guard it pins (lane notes, `swiftagent-v041`): `ctl990shadow` (a local closure shadowing the member),
/// `ctl992memberLocal` (a member alias of ANOTHER type), `ctl994shadow` (a local shadowing the global),
/// `ctl996chain`/`ctl996shorthand` (`x?.map` and `if let x` — the payload's own `map`), `ctl999overload`
/// (overloads that disagree on the parameter type), `ctl999closure` (a closure's `return` is not the
/// function's), `ctl792local` (a LOCAL callee, judged by callback-flow at its own body).
final class ValueTypingAuthorityProcessTests: XCTestCase {
    static let lib = #"""

import Foundation
public var HITS: Set<String> = []
public var CUR = ""
public final class Ctx: Hashable {
  public init() {}
  public func invoke() { _ = ProcessInfo.processInfo.environment["CANDOR_V041"]; HITS.insert(CUR) }
  public static func == (a: Ctx, b: Ctx) -> Bool { a === b }
  public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}
public final class Pure { public init() {}; public func invoke() { } }
// R990 — the leaf `mk` is POISONED: two types declare it with different returns.
public final class Ma { public init() {}; func mk() -> Ctx { Ctx() }
  public func pos990bare() { let x = mk(); x.invoke() }
  public func pos990self() { let x = self.mk(); x.invoke() }
  public func pos990direct() { mk().invoke() } }
public final class Mb { public init() {}; func mk() -> Int { 1 }; let a = Ma()
  public func pos990member() { let x = a.mk(); x.invoke() }
  public func pos990memberDirect() { a.mk().invoke() } }
public final class Mc { public init() {}; static func mk() -> [Ctx] { [Ctx()] }
  public func pos990static() { for y in Mc.mk() { y.invoke() } } }
// CTL — a local closure value named like the member shadows it (Swift resolves the local).
public final class Md { public init() {}; func mk() -> [Ctx] { [Ctx()] }
  public func ctl990shadow() { let mk: () -> [Pure] = { [Pure()] }; for y in mk() { y.invoke() } } }
// R991 — free functions returning containers.
public func mkArr() -> [Ctx] { [Ctx()] }
public func mkSet() -> Set<Ctx> { [Ctx()] }
public func mkDict() -> [String: Ctx] { ["k": Ctx()] }
public func mkNested() -> [[Ctx]] { [[Ctx()]] }
public func mkOptArr() -> [Ctx]? { [Ctx()] }
public func pos991arr() { let x = mkArr(); for y in x { y.invoke() } }
public func pos991direct() { for y in mkArr() { y.invoke() } }
public func pos991set() { let x = mkSet(); for y in x { y.invoke() } }
public func pos991dict() { let x = mkDict(); x["k"]?.invoke() }
public func pos991dictFor() { for (_, v) in mkDict() { v.invoke() } }
public func pos991nested() { let x = mkNested(); for z in x { for y in z { y.invoke() } } }
public func pos991optArr() { if let x = mkOptArr() { for y in x { y.invoke() } } }
public func pos991forEach() { mkArr().forEach { $0.invoke() } }
// R992 — container typealiases: file scope, member scope, as param / local.
public typealias Ctxs = [Ctx]
public typealias CtxMap = [String: Ctx]
public func pos992param(_ x: Ctxs) { for y in x { y.invoke() } }
public func pos992dictParam(_ x: CtxMap) { x["k"]?.invoke() }
public func pos992local() { let x: Ctxs = [Ctx()]; for y in x { y.invoke() } }
public final class Al { public init() {}; typealias Items = [Ctx]
  func run(_ xs: Items) { for y in xs { y.invoke() } }
  public func pos992member() { run([Ctx()]) } }
public final class Am { public init() {}; public typealias Items = [Pure]
  public func ctl992memberScope(_ xs: Items) { for y in xs { y.invoke() } }
  public func ctl992memberLocal() { let xs: Items = [Pure()]; for y in xs { y.invoke() } } }
// R993 — container-annotated closure parameters.
public func pos993arr() { let f = { (x: [Ctx]) in for y in x { y.invoke() } }; f([Ctx()]) }
public func pos993dict() { let f = { (x: [String: Ctx]) in x["k"]?.invoke() }; f(["k": Ctx()]) }
public func pos993set() { let f = { (x: Set<Ctx>) in for y in x { y.invoke() } }; f([Ctx()]) }
public func pos993alias() { let f = { (x: Ctxs) in x.first?.invoke() }; f([Ctx()]) }
// R994 — module globals.
public var gDict: [String: Ctx] = ["k": Ctx()]
public var gSet: Set<Ctx> = [Ctx()]
public var gDictOpt: [String: Ctx?] = ["k": Ctx()]
public func pos994dict() { gDict["k"]?.invoke() }
public func pos994dictFor() { for (_, v) in gDict { v.invoke() } }
public func pos994set() { for y in gSet { y.invoke() } }
public func pos994dictOpt() { gDictOpt["k"]??.invoke() }
public var gPure: [String: Pure] = ["k": Pure()]
public func opaqueId<T>(_ x: T) -> T { x }
public func ctl994shadow() { let gDict = opaqueId(gPure); gDict["k"]?.invoke() }
// R995 — annotated locals whose type has a NAME and is a container.
public func pos995set() { let x: Set<Ctx> = [Ctx()]; for y in x { y.invoke() } }
public func pos995setVar() { var x: Set<Ctx>; x = [Ctx()]; x.forEach { $0.invoke() } }
public func pos995contig() { let x: ContiguousArray<Ctx> = [Ctx()]; for y in x { y.invoke() } }
// R996 — Optional.map over a parameter.
public func pos996map(_ x: Ctx?) { _ = x.map { $0.invoke() } }
public func pos996flatMap(_ x: Ctx?) { _ = x.flatMap { $0.invoke() } }
public func pos996named(_ x: Ctx?) { _ = x.map { c in c.invoke() } }
public final class Wrap { public init() {}; public func invoke() { _ = ProcessInfo.processInfo.environment["CANDOR_V041"]; HITS.insert("WRAP") }
  public func map(_ f: (Pure) -> Void) { f(Pure()) } }
public func ctl996chain(_ x: Wrap?) { x?.map { $0.invoke() } }
public func ctl996shorthand(_ x: Wrap?) { if let x { x.map { $0.invoke() } } }
// R997 — a dictionary's element tuple.
public func pos997each(_ d: [String: Ctx]) { d.forEach { $0.value.invoke() } }
public func pos997splat(_ d: [String: Ctx]) { d.forEach { k, v in v.invoke() } }
public func pos997filter(_ d: [String: Ctx]) { _ = d.filter { $0.value.invoke(); return true } }
public func pos997local() { let d: [String: Ctx] = ["k": Ctx()]; d.forEach { $0.value.invoke() } }
public final class Fd { public init() {}; var d: [String: Ctx] = ["k": Ctx()]
  public func pos997field() { d.forEach { $0.value.invoke() } } }
public func ctl997reduce(_ d: [String: Pure]) -> Int { d.reduce(0) { acc, kv in kv.value.invoke(); return acc } }
// R998 — `[Ctx]?` routes.
public final class Fo { public init() {}; var f: [Ctx]? = [Ctx()]; var g: [String: Ctx]? = ["k": Ctx()]
  public func pos998self() { if let a = self.f { for y in a { y.invoke() } } }
  public func pos998guard() { guard let a = self.f else { return }; for y in a { y.invoke() } }
  public func pos998dictSelf() { if let m = self.g { m["k"]?.invoke() } }
  public func pos998coalesceField() { for y in f ?? [] { y.invoke() } } }
public final class No { public init() {}; var next: Fo? = Fo()
  public func pos998hop() { if let n = next { if let a = n.f { for y in a { y.invoke() } } } } }
public func pos998coalesce(_ x: [Ctx]?) { for y in x ?? [] { y.invoke() } }
public func pos998coalesceDict(_ x: [String: Ctx]?) { (x ?? [:])["k"]?.invoke() }
public func ctl998pure(_ x: [Pure]?) { for y in x ?? [] { y.invoke() } }

// R990 — a return spelled with the OWNER's member alias, while a top-level type of the same name exists.
public final class Connection<S> { public init() {}; public func connect() { } }
public final class ConnA<E> { public init() {}; public func connect() { Ctx().invoke() } }
public final class ShareA<E> { public init() {}; typealias Connection = ConnA<E>
  public func pos990alias() { let c = synchronizedSubscribe(); c.connect() }
  private func synchronizedSubscribe() -> Connection { ConnA<E>() } }
public final class ShareB { public init() {}; func synchronizedSubscribe() -> Int { 1 } }
// R999 — implicit member expressions with a written contextual type.
public enum NS { public struct AF { public init() {} } }
extension NS.AF {
  public static var unix: NS.AF { Ctx().invoke(); return NS.AF() }
  public static func mk() -> NS.AF { Ctx().invoke(); return NS.AF() }
}
public struct Top { public init() {}; public static var unix: Top { Ctx().invoke(); return Top() }
  public static func mk() -> Top { Ctx().invoke(); return Top() } }
public struct Quiet { public init() {}; public static var unix: Quiet { Quiet() } }
public func takeAF(domain: NS.AF) { _ = domain }
public func takeTop(_ t: Top) { _ = t }
public func pos999annot() { let x: NS.AF = .unix; _ = x }
public func pos999arg() { takeAF(domain: .unix) }
public func pos999call() { let x: Top = .mk(); _ = x }
public func pos999return() -> Top { return .unix }
public func pos999sole() -> Top { .mk() }
public func pos999assign() { var x = Top(); x = .unix; _ = x }
public func pos999argCall() { takeTop(.mk()) }
public func pos999optional() { let x: Top? = .unix; _ = x }
// CTL — overloads that DISAGREE on the parameter type: the context is refused (Swift picks by return type).
public func pick(_ a: Top) -> Int { 1 }
public func pick(_ b: Quiet) -> String { "" }
public func ctl999overload() { let s: String = pick(.unix); _ = s }
public func ctl999quiet() { let q: Quiet = .unix; _ = q }
public func ctl999closure() -> Top { _ = { () -> Quiet in return .unix }(); return Top.init() }
// R1000 — a metatype binding of a nested type.
public func pos1000read() { let t = NS.AF.self; _ = t.unix }
public func pos1000call() { let t = NS.AF.self; _ = t.mk() }
// R791 — stdlib element closures the hand list did not name.
public func pos791count(_ v: [Ctx]) { _ = v.count(where: { $0.invoke(); return true }) }
public func pos791sort(_ v: [Ctx]) { var w = v; w.sort { $0.invoke(); _ = $1; return false } }
public func pos791mapValues(_ d: [String: Ctx]) { _ = d.mapValues { $0.invoke() } }
public func pos791merging(_ d: [String: Ctx]) { _ = d.merging(d) { a, b in a.invoke(); return b } }
public func pos791elementsEqual(_ v: [Ctx]) { _ = v.elementsEqual([1]) { c, _ in c.invoke(); return true } }
// R792 — an opaque callable handed to a callee outside the scan (deferred: discharged only by a visible caller).
public func pos792lifetime(_ cb: () -> Void) { withExtendedLifetime(0, cb) }
public func pos792mapValues(_ cb: (Int) -> Int) { _ = ["a": 1].mapValues(cb) }
public func pos792bytes(_ cb: (UnsafeRawBufferPointer) -> Void) { var x = 1; withUnsafeBytes(of: &x, cb) }
func localTake(_ f: () -> Void) { }
public func ctl792local(_ cb: () -> Void) { localTake(cb) }

// R773 — a module-qualified C free function in a file importing only Foundation (which re-exports Darwin/Glibc).
public func pos773qualified() {
  #if canImport(Darwin)
  _ = Darwin.getenv("CANDOR_V041")
  #else
  _ = Glibc.getenv("CANDOR_V041")
  #endif
  HITS.insert(CUR) }
// R905 — a platform generic container's element: NSCache<K, V>.object(forKey:) is a V.
public final class StorageObject<T> { let value: T; public init(_ v: T) { value = v }; func touch() { Ctx().invoke() } }
public final class Backend<T> { let storage = NSCache<NSString, StorageObject<T>>(); public init(_ v: T) { storage.setObject(StorageObject(v), forKey: "k") }
  public func pos905object() { guard let o = storage.object(forKey: "k") else { return }; o.touch() } }
// R974 — container operations and generic forwarding run the element's Equatable/Hashable witnesses.
public struct Noisy: Hashable { public let v: Int; public init(_ v: Int) { self.v = v }
  public static func == (a: Noisy, b: Noisy) -> Bool { Ctx().invoke(); return a.v == b.v }
  public func hash(into h: inout Hasher) { Ctx().invoke(); h.combine(v) } }
public func pos974setContains(_ s: Set<Noisy>) -> Bool { s.contains(Noisy(1)) }
public func pos974arrIndex(_ a: [Noisy]) -> Int? { a.firstIndex(of: Noisy(1)) }
public func pos974dictSub(_ d: [Noisy: Int]) -> Int? { d[Noisy(1)] }
func eqGeneric<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
func fwdGeneric<T: Equatable>(_ a: T, _ b: T) -> Bool { eqGeneric(a, b) }
public func pos974forward() -> Bool { fwdGeneric(Noisy(1), Noisy(2)) }
public func ctl974pureArray(_ a: [Int]) -> Int? { a.firstIndex(of: 1) }
"""#
    static let driver = #"""
CUR = "pos990bare"; HITS.remove("WRAP"); Ma().pos990bare(); print((HITS.contains("pos990bare") || HITS.contains("WRAP")) ? "RAN pos990bare" : "QUIET pos990bare")
CUR = "pos990self"; HITS.remove("WRAP"); Ma().pos990self(); print((HITS.contains("pos990self") || HITS.contains("WRAP")) ? "RAN pos990self" : "QUIET pos990self")
CUR = "pos990direct"; HITS.remove("WRAP"); Ma().pos990direct(); print((HITS.contains("pos990direct") || HITS.contains("WRAP")) ? "RAN pos990direct" : "QUIET pos990direct")
CUR = "pos990member"; HITS.remove("WRAP"); Mb().pos990member(); print((HITS.contains("pos990member") || HITS.contains("WRAP")) ? "RAN pos990member" : "QUIET pos990member")
CUR = "pos990memberDirect"; HITS.remove("WRAP"); Mb().pos990memberDirect(); print((HITS.contains("pos990memberDirect") || HITS.contains("WRAP")) ? "RAN pos990memberDirect" : "QUIET pos990memberDirect")
CUR = "pos990static"; HITS.remove("WRAP"); Mc().pos990static(); print((HITS.contains("pos990static") || HITS.contains("WRAP")) ? "RAN pos990static" : "QUIET pos990static")
CUR = "ctl990shadow"; HITS.remove("WRAP"); Md().ctl990shadow(); print((HITS.contains("ctl990shadow") || HITS.contains("WRAP")) ? "RAN ctl990shadow" : "QUIET ctl990shadow")
CUR = "pos991arr"; HITS.remove("WRAP"); pos991arr(); print((HITS.contains("pos991arr") || HITS.contains("WRAP")) ? "RAN pos991arr" : "QUIET pos991arr")
CUR = "pos991direct"; HITS.remove("WRAP"); pos991direct(); print((HITS.contains("pos991direct") || HITS.contains("WRAP")) ? "RAN pos991direct" : "QUIET pos991direct")
CUR = "pos991set"; HITS.remove("WRAP"); pos991set(); print((HITS.contains("pos991set") || HITS.contains("WRAP")) ? "RAN pos991set" : "QUIET pos991set")
CUR = "pos991dict"; HITS.remove("WRAP"); pos991dict(); print((HITS.contains("pos991dict") || HITS.contains("WRAP")) ? "RAN pos991dict" : "QUIET pos991dict")
CUR = "pos991dictFor"; HITS.remove("WRAP"); pos991dictFor(); print((HITS.contains("pos991dictFor") || HITS.contains("WRAP")) ? "RAN pos991dictFor" : "QUIET pos991dictFor")
CUR = "pos991nested"; HITS.remove("WRAP"); pos991nested(); print((HITS.contains("pos991nested") || HITS.contains("WRAP")) ? "RAN pos991nested" : "QUIET pos991nested")
CUR = "pos991optArr"; HITS.remove("WRAP"); pos991optArr(); print((HITS.contains("pos991optArr") || HITS.contains("WRAP")) ? "RAN pos991optArr" : "QUIET pos991optArr")
CUR = "pos991forEach"; HITS.remove("WRAP"); pos991forEach(); print((HITS.contains("pos991forEach") || HITS.contains("WRAP")) ? "RAN pos991forEach" : "QUIET pos991forEach")
CUR = "pos992param"; HITS.remove("WRAP"); pos992param([Ctx()]); print((HITS.contains("pos992param") || HITS.contains("WRAP")) ? "RAN pos992param" : "QUIET pos992param")
CUR = "pos992dictParam"; HITS.remove("WRAP"); pos992dictParam(["k": Ctx()]); print((HITS.contains("pos992dictParam") || HITS.contains("WRAP")) ? "RAN pos992dictParam" : "QUIET pos992dictParam")
CUR = "pos992local"; HITS.remove("WRAP"); pos992local(); print((HITS.contains("pos992local") || HITS.contains("WRAP")) ? "RAN pos992local" : "QUIET pos992local")
CUR = "pos992member"; HITS.remove("WRAP"); Al().pos992member(); print((HITS.contains("pos992member") || HITS.contains("WRAP")) ? "RAN pos992member" : "QUIET pos992member")
CUR = "ctl992memberScope"; HITS.remove("WRAP"); Am().ctl992memberScope([Pure()]); print((HITS.contains("ctl992memberScope") || HITS.contains("WRAP")) ? "RAN ctl992memberScope" : "QUIET ctl992memberScope")
CUR = "ctl992memberLocal"; HITS.remove("WRAP"); Am().ctl992memberLocal(); print((HITS.contains("ctl992memberLocal") || HITS.contains("WRAP")) ? "RAN ctl992memberLocal" : "QUIET ctl992memberLocal")
CUR = "pos993arr"; HITS.remove("WRAP"); pos993arr(); print((HITS.contains("pos993arr") || HITS.contains("WRAP")) ? "RAN pos993arr" : "QUIET pos993arr")
CUR = "pos993dict"; HITS.remove("WRAP"); pos993dict(); print((HITS.contains("pos993dict") || HITS.contains("WRAP")) ? "RAN pos993dict" : "QUIET pos993dict")
CUR = "pos993set"; HITS.remove("WRAP"); pos993set(); print((HITS.contains("pos993set") || HITS.contains("WRAP")) ? "RAN pos993set" : "QUIET pos993set")
CUR = "pos993alias"; HITS.remove("WRAP"); pos993alias(); print((HITS.contains("pos993alias") || HITS.contains("WRAP")) ? "RAN pos993alias" : "QUIET pos993alias")
CUR = "pos994dict"; HITS.remove("WRAP"); pos994dict(); print((HITS.contains("pos994dict") || HITS.contains("WRAP")) ? "RAN pos994dict" : "QUIET pos994dict")
CUR = "pos994dictFor"; HITS.remove("WRAP"); pos994dictFor(); print((HITS.contains("pos994dictFor") || HITS.contains("WRAP")) ? "RAN pos994dictFor" : "QUIET pos994dictFor")
CUR = "pos994set"; HITS.remove("WRAP"); pos994set(); print((HITS.contains("pos994set") || HITS.contains("WRAP")) ? "RAN pos994set" : "QUIET pos994set")
CUR = "pos994dictOpt"; HITS.remove("WRAP"); pos994dictOpt(); print((HITS.contains("pos994dictOpt") || HITS.contains("WRAP")) ? "RAN pos994dictOpt" : "QUIET pos994dictOpt")
CUR = "ctl994shadow"; HITS.remove("WRAP"); ctl994shadow(); print((HITS.contains("ctl994shadow") || HITS.contains("WRAP")) ? "RAN ctl994shadow" : "QUIET ctl994shadow")
CUR = "pos995set"; HITS.remove("WRAP"); pos995set(); print((HITS.contains("pos995set") || HITS.contains("WRAP")) ? "RAN pos995set" : "QUIET pos995set")
CUR = "pos995setVar"; HITS.remove("WRAP"); pos995setVar(); print((HITS.contains("pos995setVar") || HITS.contains("WRAP")) ? "RAN pos995setVar" : "QUIET pos995setVar")
CUR = "pos995contig"; HITS.remove("WRAP"); pos995contig(); print((HITS.contains("pos995contig") || HITS.contains("WRAP")) ? "RAN pos995contig" : "QUIET pos995contig")
CUR = "pos996map"; HITS.remove("WRAP"); pos996map(Ctx()); print((HITS.contains("pos996map") || HITS.contains("WRAP")) ? "RAN pos996map" : "QUIET pos996map")
CUR = "pos996flatMap"; HITS.remove("WRAP"); pos996flatMap(Ctx()); print((HITS.contains("pos996flatMap") || HITS.contains("WRAP")) ? "RAN pos996flatMap" : "QUIET pos996flatMap")
CUR = "pos996named"; HITS.remove("WRAP"); pos996named(Ctx()); print((HITS.contains("pos996named") || HITS.contains("WRAP")) ? "RAN pos996named" : "QUIET pos996named")
CUR = "ctl996chain"; HITS.remove("WRAP"); ctl996chain(Wrap()); print((HITS.contains("ctl996chain") || HITS.contains("WRAP")) ? "RAN ctl996chain" : "QUIET ctl996chain")
CUR = "ctl996shorthand"; HITS.remove("WRAP"); ctl996shorthand(Wrap()); print((HITS.contains("ctl996shorthand") || HITS.contains("WRAP")) ? "RAN ctl996shorthand" : "QUIET ctl996shorthand")
CUR = "pos997each"; HITS.remove("WRAP"); pos997each(["k": Ctx()]); print((HITS.contains("pos997each") || HITS.contains("WRAP")) ? "RAN pos997each" : "QUIET pos997each")
CUR = "pos997splat"; HITS.remove("WRAP"); pos997splat(["k": Ctx()]); print((HITS.contains("pos997splat") || HITS.contains("WRAP")) ? "RAN pos997splat" : "QUIET pos997splat")
CUR = "pos997filter"; HITS.remove("WRAP"); pos997filter(["k": Ctx()]); print((HITS.contains("pos997filter") || HITS.contains("WRAP")) ? "RAN pos997filter" : "QUIET pos997filter")
CUR = "pos997local"; HITS.remove("WRAP"); pos997local(); print((HITS.contains("pos997local") || HITS.contains("WRAP")) ? "RAN pos997local" : "QUIET pos997local")
CUR = "pos997field"; HITS.remove("WRAP"); Fd().pos997field(); print((HITS.contains("pos997field") || HITS.contains("WRAP")) ? "RAN pos997field" : "QUIET pos997field")
CUR = "ctl997reduce"; HITS.remove("WRAP"); _ = ctl997reduce(["k": Pure()]); print((HITS.contains("ctl997reduce") || HITS.contains("WRAP")) ? "RAN ctl997reduce" : "QUIET ctl997reduce")
CUR = "pos998self"; HITS.remove("WRAP"); Fo().pos998self(); print((HITS.contains("pos998self") || HITS.contains("WRAP")) ? "RAN pos998self" : "QUIET pos998self")
CUR = "pos998guard"; HITS.remove("WRAP"); Fo().pos998guard(); print((HITS.contains("pos998guard") || HITS.contains("WRAP")) ? "RAN pos998guard" : "QUIET pos998guard")
CUR = "pos998dictSelf"; HITS.remove("WRAP"); Fo().pos998dictSelf(); print((HITS.contains("pos998dictSelf") || HITS.contains("WRAP")) ? "RAN pos998dictSelf" : "QUIET pos998dictSelf")
CUR = "pos998coalesceField"; HITS.remove("WRAP"); Fo().pos998coalesceField(); print((HITS.contains("pos998coalesceField") || HITS.contains("WRAP")) ? "RAN pos998coalesceField" : "QUIET pos998coalesceField")
CUR = "pos998hop"; HITS.remove("WRAP"); No().pos998hop(); print((HITS.contains("pos998hop") || HITS.contains("WRAP")) ? "RAN pos998hop" : "QUIET pos998hop")
CUR = "pos998coalesce"; HITS.remove("WRAP"); pos998coalesce([Ctx()]); print((HITS.contains("pos998coalesce") || HITS.contains("WRAP")) ? "RAN pos998coalesce" : "QUIET pos998coalesce")
CUR = "pos998coalesceDict"; HITS.remove("WRAP"); pos998coalesceDict(["k": Ctx()]); print((HITS.contains("pos998coalesceDict") || HITS.contains("WRAP")) ? "RAN pos998coalesceDict" : "QUIET pos998coalesceDict")
CUR = "ctl998pure"; HITS.remove("WRAP"); ctl998pure([Pure()]); print((HITS.contains("ctl998pure") || HITS.contains("WRAP")) ? "RAN ctl998pure" : "QUIET ctl998pure")
CUR = "pos990alias"; HITS.remove("WRAP"); ShareA<Int>().pos990alias(); print((HITS.contains("pos990alias") || HITS.contains("WRAP")) ? "RAN pos990alias" : "QUIET pos990alias")
CUR = "pos999annot"; HITS.remove("WRAP"); pos999annot(); print((HITS.contains("pos999annot") || HITS.contains("WRAP")) ? "RAN pos999annot" : "QUIET pos999annot")
CUR = "pos999arg"; HITS.remove("WRAP"); pos999arg(); print((HITS.contains("pos999arg") || HITS.contains("WRAP")) ? "RAN pos999arg" : "QUIET pos999arg")
CUR = "pos999call"; HITS.remove("WRAP"); pos999call(); print((HITS.contains("pos999call") || HITS.contains("WRAP")) ? "RAN pos999call" : "QUIET pos999call")
CUR = "pos999return"; HITS.remove("WRAP"); _ = pos999return(); print((HITS.contains("pos999return") || HITS.contains("WRAP")) ? "RAN pos999return" : "QUIET pos999return")
CUR = "pos999sole"; HITS.remove("WRAP"); _ = pos999sole(); print((HITS.contains("pos999sole") || HITS.contains("WRAP")) ? "RAN pos999sole" : "QUIET pos999sole")
CUR = "pos999assign"; HITS.remove("WRAP"); pos999assign(); print((HITS.contains("pos999assign") || HITS.contains("WRAP")) ? "RAN pos999assign" : "QUIET pos999assign")
CUR = "pos999argCall"; HITS.remove("WRAP"); pos999argCall(); print((HITS.contains("pos999argCall") || HITS.contains("WRAP")) ? "RAN pos999argCall" : "QUIET pos999argCall")
CUR = "pos999optional"; HITS.remove("WRAP"); pos999optional(); print((HITS.contains("pos999optional") || HITS.contains("WRAP")) ? "RAN pos999optional" : "QUIET pos999optional")
CUR = "ctl999overload"; HITS.remove("WRAP"); ctl999overload(); print((HITS.contains("ctl999overload") || HITS.contains("WRAP")) ? "RAN ctl999overload" : "QUIET ctl999overload")
CUR = "ctl999quiet"; HITS.remove("WRAP"); ctl999quiet(); print((HITS.contains("ctl999quiet") || HITS.contains("WRAP")) ? "RAN ctl999quiet" : "QUIET ctl999quiet")
CUR = "ctl999closure"; HITS.remove("WRAP"); _ = ctl999closure(); print((HITS.contains("ctl999closure") || HITS.contains("WRAP")) ? "RAN ctl999closure" : "QUIET ctl999closure")
CUR = "pos1000read"; HITS.remove("WRAP"); pos1000read(); print((HITS.contains("pos1000read") || HITS.contains("WRAP")) ? "RAN pos1000read" : "QUIET pos1000read")
CUR = "pos1000call"; HITS.remove("WRAP"); pos1000call(); print((HITS.contains("pos1000call") || HITS.contains("WRAP")) ? "RAN pos1000call" : "QUIET pos1000call")
CUR = "pos791count"; HITS.remove("WRAP"); pos791count([Ctx()]); print((HITS.contains("pos791count") || HITS.contains("WRAP")) ? "RAN pos791count" : "QUIET pos791count")
CUR = "pos791sort"; HITS.remove("WRAP"); pos791sort([Ctx(), Ctx()]); print((HITS.contains("pos791sort") || HITS.contains("WRAP")) ? "RAN pos791sort" : "QUIET pos791sort")
CUR = "pos791mapValues"; HITS.remove("WRAP"); pos791mapValues(["k": Ctx()]); print((HITS.contains("pos791mapValues") || HITS.contains("WRAP")) ? "RAN pos791mapValues" : "QUIET pos791mapValues")
CUR = "pos791merging"; HITS.remove("WRAP"); pos791merging(["k": Ctx()]); print((HITS.contains("pos791merging") || HITS.contains("WRAP")) ? "RAN pos791merging" : "QUIET pos791merging")
CUR = "pos791elementsEqual"; HITS.remove("WRAP"); pos791elementsEqual([Ctx()]); print((HITS.contains("pos791elementsEqual") || HITS.contains("WRAP")) ? "RAN pos791elementsEqual" : "QUIET pos791elementsEqual")
CUR = "pos792lifetime"; HITS.remove("WRAP"); pos792lifetime { Ctx().invoke() }; print((HITS.contains("pos792lifetime") || HITS.contains("WRAP")) ? "RAN pos792lifetime" : "QUIET pos792lifetime")
CUR = "pos792mapValues"; HITS.remove("WRAP"); pos792mapValues { Ctx().invoke(); return $0 }; print((HITS.contains("pos792mapValues") || HITS.contains("WRAP")) ? "RAN pos792mapValues" : "QUIET pos792mapValues")
CUR = "pos792bytes"; HITS.remove("WRAP"); pos792bytes { _ in Ctx().invoke() }; print((HITS.contains("pos792bytes") || HITS.contains("WRAP")) ? "RAN pos792bytes" : "QUIET pos792bytes")
CUR = "ctl792local"; HITS.remove("WRAP"); ctl792local { Ctx().invoke() }; print((HITS.contains("ctl792local") || HITS.contains("WRAP")) ? "RAN ctl792local" : "QUIET ctl792local")
CUR = "pos773qualified"; HITS.remove("WRAP"); pos773qualified(); print((HITS.contains("pos773qualified") || HITS.contains("WRAP")) ? "RAN pos773qualified" : "QUIET pos773qualified")
CUR = "pos905object"; HITS.remove("WRAP"); Backend(1).pos905object(); print((HITS.contains("pos905object") || HITS.contains("WRAP")) ? "RAN pos905object" : "QUIET pos905object")
CUR = "pos974setContains"; HITS.remove("WRAP"); _ = pos974setContains([Noisy(1)]); print((HITS.contains("pos974setContains") || HITS.contains("WRAP")) ? "RAN pos974setContains" : "QUIET pos974setContains")
CUR = "pos974arrIndex"; HITS.remove("WRAP"); _ = pos974arrIndex([Noisy(1)]); print((HITS.contains("pos974arrIndex") || HITS.contains("WRAP")) ? "RAN pos974arrIndex" : "QUIET pos974arrIndex")
CUR = "pos974dictSub"; HITS.remove("WRAP"); _ = pos974dictSub([Noisy(1): 1]); print((HITS.contains("pos974dictSub") || HITS.contains("WRAP")) ? "RAN pos974dictSub" : "QUIET pos974dictSub")
CUR = "pos974forward"; HITS.remove("WRAP"); _ = pos974forward(); print((HITS.contains("pos974forward") || HITS.contains("WRAP")) ? "RAN pos974forward" : "QUIET pos974forward")
CUR = "ctl974pureArray"; HITS.remove("WRAP"); _ = ctl974pureArray([1]); print((HITS.contains("ctl974pureArray") || HITS.contains("WRAP")) ? "RAN ctl974pureArray" : "QUIET ctl974pureArray")
"""#
    static let positive: [(cell: String, fn: String)] = [
        ("pos990bare", "Ma.pos990bare"),
        ("pos990self", "Ma.pos990self"),
        ("pos990direct", "Ma.pos990direct"),
        ("pos990member", "Mb.pos990member"),
        ("pos990memberDirect", "Mb.pos990memberDirect"),
        ("pos990static", "Mc.pos990static"),
        ("pos991arr", "pos991arr"),
        ("pos991direct", "pos991direct"),
        ("pos991set", "pos991set"),
        ("pos991dict", "pos991dict"),
        ("pos991dictFor", "pos991dictFor"),
        ("pos991nested", "pos991nested"),
        ("pos991optArr", "pos991optArr"),
        ("pos991forEach", "pos991forEach"),
        ("pos992param", "pos992param"),
        ("pos992dictParam", "pos992dictParam"),
        ("pos992local", "pos992local"),
        ("pos992member", "Al.pos992member"),
        ("pos993arr", "pos993arr"),
        ("pos993dict", "pos993dict"),
        ("pos993set", "pos993set"),
        ("pos993alias", "pos993alias"),
        ("pos994dict", "pos994dict"),
        ("pos994dictFor", "pos994dictFor"),
        ("pos994set", "pos994set"),
        ("pos994dictOpt", "pos994dictOpt"),
        ("pos995set", "pos995set"),
        ("pos995setVar", "pos995setVar"),
        ("pos995contig", "pos995contig"),
        ("pos996map", "pos996map"),
        ("pos996flatMap", "pos996flatMap"),
        ("pos996named", "pos996named"),
        ("pos997each", "pos997each"),
        ("pos997splat", "pos997splat"),
        ("pos997filter", "pos997filter"),
        ("pos997local", "pos997local"),
        ("pos997field", "Fd.pos997field"),
        ("pos998self", "Fo.pos998self"),
        ("pos998guard", "Fo.pos998guard"),
        ("pos998dictSelf", "Fo.pos998dictSelf"),
        ("pos998coalesceField", "Fo.pos998coalesceField"),
        ("pos998hop", "No.pos998hop"),
        ("pos998coalesce", "pos998coalesce"),
        ("pos998coalesceDict", "pos998coalesceDict"),
        ("pos990alias", "ShareA.pos990alias"),
        ("pos999annot", "pos999annot"),
        ("pos999arg", "pos999arg"),
        ("pos999call", "pos999call"),
        ("pos999return", "pos999return"),
        ("pos999sole", "pos999sole"),
        ("pos999assign", "pos999assign"),
        ("pos999argCall", "pos999argCall"),
        ("pos999optional", "pos999optional"),
        ("pos1000read", "pos1000read"),
        ("pos1000call", "pos1000call"),
        ("pos791count", "pos791count"),
        ("pos791sort", "pos791sort"),
        ("pos791mapValues", "pos791mapValues"),
        ("pos791merging", "pos791merging"),
        ("pos791elementsEqual", "pos791elementsEqual"),
        ("pos792lifetime", "pos792lifetime"),
        ("pos792mapValues", "pos792mapValues"),
        ("pos792bytes", "pos792bytes"),
        ("pos773qualified", "pos773qualified"),
        ("pos905object", "Backend.pos905object"),
        ("pos974setContains", "pos974setContains"),
        ("pos974arrIndex", "pos974arrIndex"),
        ("pos974dictSub", "pos974dictSub"),
        ("pos974forward", "pos974forward"),
    ]
    static let controls: [(cell: String, fn: String)] = [
        ("ctl990shadow", "Md.ctl990shadow"),
        ("ctl992memberScope", "Am.ctl992memberScope"),
        ("ctl992memberLocal", "Am.ctl992memberLocal"),
        ("ctl994shadow", "ctl994shadow"),
        ("ctl996chain", "ctl996chain"),
        ("ctl996shorthand", "ctl996shorthand"),
        ("ctl997reduce", "ctl997reduce"),
        ("ctl998pure", "ctl998pure"),
        ("ctl999overload", "ctl999overload"),
        ("ctl999quiet", "ctl999quiet"),
        ("ctl999closure", "ctl999closure"),
        ("ctl792local", "ctl792local"),
        ("ctl974pureArray", "ctl974pureArray"),
    ]

    private func scan(_ env: [String: String] = [:]) throws -> [String: [String: Any]] {
        let bin = try ProcessHarness.binaryURL(for: Self.self)
        let root = try ProcessHarness.makeFilesPackage(["v.swift": Self.lib], name: "V")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try ProcessHarness.run(bin, [root.path, "--json"], env: env)
        XCTAssertEqual(r.code, 0, r.err)
        return try ProcessHarness.fns(ofJson: r.out)
    }

    /// The effect each positive cell must carry: `Env`, or — for an opaque callable handed to a callee the
    /// scan cannot see (R792) — the deferred `Unknown` the listed invokers already give.
    private static func expected(_ cell: String) -> String { cell.contains("792") ? "Unknown" : "Env" }

    func testEveryCellChargesAndTheSwitchRestoresTheRelease() throws {
        let by = try scan(), off = try scan(["CANDOR_VT_OFF": "1"])
        for (cell, fn) in Self.positive {
            let e = Self.expected(cell)
            XCTAssertTrue(ProcessHarness.inferred(by, fn)?.contains(e) ?? false,
                          "\(cell): `\(fn)` really performs the effect (executed); must carry \(e), got \(by[fn] ?? [:])")
            XCTAssertFalse(ProcessHarness.inferred(off, fn)?.contains(e) ?? false,
                           "\(cell): CANDOR_VT_OFF is the release, where this was silent; got \(off[fn] ?? [:])")
        }
    }

    func testTheControlsGainNothing() throws {
        let by = try scan(), off = try scan(["CANDOR_VT_OFF": "1"])
        for (cell, fn) in Self.controls {
            XCTAssertFalse(ProcessHarness.inferred(by, fn)?.contains("Env") ?? false,
                           "\(cell): `\(fn)` performs nothing (executed) — Env is a fabrication; got \(by[fn] ?? [:])")
            XCTAssertEqual(ProcessHarness.inferred(by, fn), ProcessHarness.inferred(off, fn),
                           "\(cell): a control's row must be the release's")
        }
    }

    // EXECUTED GROUND TRUTH (§E3) — the program compiles and runs, and each cell does what it is filed as.
    func testFixtureGroundTruthExecutes() throws {
        #if os(macOS) || os(Linux)
        let env = URL(fileURLWithPath: "/usr/bin/env")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("candor-v041-gt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("gt.swift")
        try (Self.lib + "\n" + Self.driver).write(to: src, atomically: true, encoding: .utf8)
        let r = try ProcessHarness.run(env, ["swift", src.path], cwd: dir)
        XCTAssertEqual(r.code, 0, "the fixture must COMPILE AND RUN (§E3).\n\(r.err)")
        let lines = Set(r.out.split(separator: "\n").map(String.init))
        for (cell, _) in Self.positive { XCTAssertTrue(lines.contains("RAN \(cell)"), "\(cell) must really run Ctx.invoke") }
        for (cell, _) in Self.controls { XCTAssertTrue(lines.contains("QUIET \(cell)"), "\(cell) must really do nothing") }
        #endif
    }
}
