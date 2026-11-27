import Foundation
import Base11
// an EXTENSION member of Base11's type, declared in a different dependency module
extension Pipe11 {
    public func extWipe11(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
    public func extQuiet11(_ p: String) -> Int { p.count } }   // pure twin, unique name
