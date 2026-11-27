// A sibling target Use9 does NOT import, declaring TOP-LEVEL types named like platform types.
public struct Data { public init() {}
    public func write(to url: Any) {} }                          // pure here; Foundation.Data.write(to:) WRITES
public struct URL { public init(fileURLWithPath p: String) {}
    public func checkResourceIsReachable() -> Bool { true } }     // pure here; Foundation.URL.checkResourceIsReachable() stats
