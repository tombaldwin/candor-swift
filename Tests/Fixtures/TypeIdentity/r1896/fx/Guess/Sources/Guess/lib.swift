import Foundation
public final class DepStore { public init() {}
    public func wipeDep(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class DepPure { public init() {}
    public func calmDep(_ p: String) -> Int { p.count } }
/// an uppercase-named FREE FUNCTION that looks like a constructor
public func Maker() -> DepStore { DepStore() }
public typealias Store = DepStore
/// a type the CONSUMER also declares under the same simple name
public final class Ledger { public init() {}
    public func post(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
/// same simple name as a consumer type; member name chosen to match NO platform member
public final class Teller { public init() {}
    public func settleUp(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
@_exported import Dep2
/// same simple name as a consumer TYPEALIAS
public final class Sibling { public init() {}
    public func sib(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
/// a public alias of a GENERIC specialisation
public typealias Boxed = DepGen<Int>
/// a type declared by this module only through an extension of the re-exported one (no own type named Relay2)
extension Relay { public func relayTwice(_ p: String) { relayOut(p) } }
public final class DepGen<T> { public init() {}
    public func wipeGen(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
