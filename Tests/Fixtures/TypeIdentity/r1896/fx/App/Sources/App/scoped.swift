import Foundation
import class Guess.DepPure     // a SCOPED import: the file names the module only through `import class`
extension Msg3 {
    public func c_scoped_import(_ p: String) { fDep.wipeDep(p) }   // WRITES
}
