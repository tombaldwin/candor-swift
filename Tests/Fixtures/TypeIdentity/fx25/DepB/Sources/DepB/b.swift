import Foundation
import DepA
// DepB is a TWIN (declares its own Lib25) AND extends DepA's Lib25 with the member the use site calls
public final class Lib25 { public init() {}
    public func wipe25(_ p: String) -> Int { p.count } }                                                   // pure twin
extension DepA.Lib25 {
    public func extWipe25(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }         // LOUD extension of DepA's type, in the twin module
    public func extQuiet25(_ p: String) -> Int { p.count } }                                                // pure, unique name
