import Foundation
// module-qualified head; `Own15` here is the MODULE (Core15's type `Own15` is not imported in this file)
extension Own15.Outer15 { public struct Data { public init() {}
    public func write(to p: String) {}
    public func wipe15(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } } }
