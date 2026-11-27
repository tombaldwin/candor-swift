import Foundation
// ToolA: Foundation.Data; the only scan `Data` is Gen's nested Node.Data (another target, not imported)
public struct TA { public init() {}
    public func a_data_ann(_ p: String) throws { let d: Data = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) }
    public func a_data_ctor(_ p: String) throws { let d = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) }
}
