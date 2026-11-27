import Foundation
public struct Outer15 { public init() {}
    public func a_pure(_ p: String) { let d = Data(); d.write(to: p) }          // Outer15.Data (ext.swift, head spelled `Own15.Outer15`): pure
    public func a_loud(_ p: String) { let d = Data(); d.wipe15(p) }            // WRITES
}
public struct Plain15 { public init() {}
    public func p_data(_ p: String) throws { let d = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) } }  // Foundation: WRITES
