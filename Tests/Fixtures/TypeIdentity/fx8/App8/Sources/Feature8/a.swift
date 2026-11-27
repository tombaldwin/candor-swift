import Base8
import Ext8X
// the ONLY file of this target importing the modules
let g8 = Pipe8()
public struct A8 { public init() {}
    public func a_ext(_ p: String) { g8.extWipe8(p) }        // control: importing file
    public func a_live(_ p: String) { g8.ownWipe8(p) } }
