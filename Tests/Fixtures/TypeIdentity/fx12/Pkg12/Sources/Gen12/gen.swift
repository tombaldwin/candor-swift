// A sibling target nobody imports: a NESTED `Data` that captures every bare `Data` in the package today.
public struct Node12 { public struct Data { public init() {}
    public init<S>(_ s: S) {}
    public func write(to url: Any) {} } }
