import Foundation
import Base22
extension Pipe22 {
    public func extWipe22(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
    public func extQuiet22(_ p: String) -> Int { p.count } }
