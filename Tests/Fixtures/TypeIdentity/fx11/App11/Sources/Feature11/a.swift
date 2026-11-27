import Base11
import Ext11X
// the ONLY file of this target importing the modules
public final class Holder11 { public init() {}
    public var pipe = Pipe11()                                  // field: type decided here, by the importing file
    public func a_field(_ p: String) { pipe.extWipe11(p) }      // control: importing file
    public func a_live(_ p: String) { pipe.ownWipe11(p) } }
func mkLocal11() -> Pipe11 { mkPipe11() }                        // factory return declared here
