import Foundation
import Files
// S12 x File: Files.File (the dependency's) writes; Gen9's nested `File` does not, and is not visible here.
public struct UF9 { public init() {}
    public func s12_file_ann(_ p: String) throws { let f: File = try File(path: p); try f.write("x") }
    public func s12_file_ctor(_ p: String) throws { let f = try File(path: p); try f.write("x") }
    public func live(_ p: String) { depWrite9(p) }     // the chained-join liveness control (Files' free function)
}
