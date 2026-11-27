import Foundation
public final class DepStore { public init() {}
    public func wipeDep(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public final class DepPure { public init() {}
    public func calmDep(_ p: String) -> Int { p.count } }
public final class DepGen<T> { public init() {}
    public func wipeGen(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public func makeStore() -> DepStore { DepStore() }
open class DepBase { public init() {}
    public var inhDep = DepStore() }
public enum DepKind { case Node(Int)
    public func wipeKindDep(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public enum DepNS { public static func Make() -> DepStore { DepStore() } }
public final class Teller { public init() {}
    public func settleUp(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public func Maker() -> DepStore { DepStore() }
