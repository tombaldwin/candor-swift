import Base11
import Ext11X
// a second file that ALSO imports both, reaching the first file's field
public struct BMi { public init() {}
    public func mi_b_ext(_ p: String) { HolderMi().pipe.extWipe11(p) }
    public func mi_b_ext_quiet(_ p: String) -> Int { HolderMi().pipe.extQuiet11(p) } }
