import Foundation
// ToolC: control, no scan type named Data is relevant except Gen's (same as ToolA) -> see a.swift; this one uses a UNIQUE name
public struct TC { public init() {}
    public func c_bytes_ann(_ p: String) throws { let d: Data = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) }
}
