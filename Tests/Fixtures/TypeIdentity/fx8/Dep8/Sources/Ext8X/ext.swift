import Foundation
import Base8
// an EXTENSION member of Base8's type, declared in a different dependency module
extension Pipe8 {
    public func extWipe8(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
    public func extQuiet8(_ p: String) -> Int { p.count } }   // pure twin, unique name
