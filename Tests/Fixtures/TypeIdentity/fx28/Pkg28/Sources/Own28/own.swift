import Foundation
// attack on the LABEL filter for inherited designated inits (round 2): every subclass declares NO init, so Swift inherits all of these
open class Base28 {
    public init(path: String, work: () -> Void) { FileManager.default.createFile(atPath: path, contents: nil); work() }   // LOUD, trailing-closure shape
    public init(name: String, work: () -> Void) { work() }                                                                 // PURE, same labels but the first
    public init(_ loud: String) { FileManager.default.createFile(atPath: loud, contents: nil) }                           // LOUD, unlabeled
    public init(_ quiet: Int) { _ = quiet }                                                                                  // PURE, unlabeled, same arity
    public init(name: String, flag: Bool = false) { _ = name; _ = flag }                                                   // PURE, defaulted second
    public init(parts: String...) { _ = parts }                                                                             // PURE, variadic
    public init?(maybe: String) { if maybe.isEmpty { return nil } }                                                         // PURE, failable
    public init<T>(value: T) { _ = value }                                                                                   // PURE, generic
    public init(write: String, count: Int) { FileManager.default.createFile(atPath: write, contents: nil); _ = count }      // LOUD, 2 labels
}
public final class Sub28: Base28 {}
public struct U28 { public init() {}
    public func trailing_pure(_ p: String) { _ = Sub28(name: p) { } }                                                      // pure (init(name:work:) with a trailing closure)
    public func trailing_loud(_ p: String) { _ = Sub28(path: p) { } }                                                      // WRITES
    public func unlabeled_pure(_ p: String) { _ = Sub28(5) }                                                                 // pure (init(_ quiet: Int))
    public func unlabeled_loud(_ p: String) { _ = Sub28(p) }                                                                 // WRITES (init(_ loud: String))
    public func defaulted(_ p: String) { _ = Sub28(name: p) }                                                               // pure (init(name:flag:) with the default)
    public func variadic(_ p: String) { _ = Sub28(parts: p, "x") }                                                           // pure
    public func failable(_ p: String) { _ = Sub28(maybe: p) }                                                               // pure
    public func generic(_ p: String) { _ = Sub28(value: 1) }                                                                // pure
    public func two_labels(_ p: String) { _ = Sub28(write: p, count: 1) }                                                   // WRITES
}
