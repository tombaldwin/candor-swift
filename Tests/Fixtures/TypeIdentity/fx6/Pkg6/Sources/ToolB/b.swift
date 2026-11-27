import Foundation
// ToolB: its OWN module nests a `Data` (Outer.Data); bare `Data` outside Outer is still Foundation.Data
public struct Outer { public struct Data { public init() {}
    public func write(to url: Any) {} } }
public struct TB { public init() {}
    public func b_data_ann(_ p: String) throws { let d: Data = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) }
    public func b_data_ctor(_ p: String) throws { let d = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) }
    public func b_own_nested(_ p: String) { let d = Outer.Data(); d.write(to: p) }      // pure control
}
