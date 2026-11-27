import Foundation
import DepA
extension Pipe24 {
    public func extWipe24(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }   // LOUD
    public func extQuiet24(_ p: String) -> Int { p.count } }                                         // PURE twin, unique name
extension Lib24 {
    public func extLib24(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }  // LOUD
