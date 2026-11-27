import Foundation
// the Alamofire shape: a LOUD extension init on Swift.Result, reached through a GENERIC typealias of the platform type
extension Result where Failure == Error {
    public init(loud p: String, value: Success) { FileManager.default.createFile(atPath: p, contents: nil); self = .success(value) }   // WRITES
    public init(quiet value: Success) { self = .success(value) }                                                                     // pure
}
public typealias MyResult<S> = Result<S, Error>
public typealias IntResult = Result<Int, Error>
public struct U20 { public init() {}
    public func alias_generic(_ p: String) -> Int { let r = MyResult<Int>(loud: p, value: 1); return (try? r.get()) ?? 0 }      // WRITES
    public func alias_plain(_ p: String) -> Int { let r = IntResult(loud: p, value: 1); return (try? r.get()) ?? 0 }             // WRITES
    public func direct(_ p: String) -> Int { let r = Result<Int, Error>(loud: p, value: 1); return (try? r.get()) ?? 0 }       // WRITES (no alias)
    public func alias_quiet(_ p: String) -> Int { let r = MyResult<Int>(quiet: 1); return (try? r.get()) ?? 0 }                 // pure twin
}
