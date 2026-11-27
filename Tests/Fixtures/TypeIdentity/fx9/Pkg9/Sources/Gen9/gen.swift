import Foundation
// A sibling target Use9 does NOT import, declaring NESTED types named like platform types (S2 x S12).
public struct Node9 {
    public struct URL { public init(fileURLWithPath p: String) {}
        public func checkResourceIsReachable() -> Bool { true } }
    public struct File { public init(path: String) throws {}
        public func write(_ s: String) throws {} }
    public struct Result { public init() {}
        public func get() { FileManager.default.createFile(atPath: NSTemporaryDirectory() + "cand9-nested-result-get", contents: nil) } }   // LOUD; Swift.Result.get() is pure
}
