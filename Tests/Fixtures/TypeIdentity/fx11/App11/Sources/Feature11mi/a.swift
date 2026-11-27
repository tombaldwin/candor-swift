import Base11
import Ext11X
// MemberImportVisibility is ON for this target: every file imports what it uses
public final class HolderMi { public init() {}
    public var pipe = Pipe11()
    public func mi_ext(_ p: String) { pipe.extWipe11(p) }        // WRITES (the importing file)
    public func mi_ext_quiet(_ p: String) -> Int { pipe.extQuiet11(p) }   // pure twin
    public func mi_own(_ p: String) { pipe.ownWipe11(p) } }
