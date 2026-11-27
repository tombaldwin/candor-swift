// NO imports: extension members of a dependency type, reached through declarations of the importing file
public struct B11 { public init() {}
    public func b_ext_field(_ p: String) { Holder11().pipe.extWipe11(p) }          // field of a type declared in a.swift
    public func b_ext_factory(_ p: String) { mkLocal11().extWipe11(p) }            // factory return declared in a.swift
    public func b_ext_local(_ p: String) { let q = mkLocal11(); q.extWipe11(p) }   // local bound from that factory
    public func b_ext_quiet(_ p: String) -> Int { Holder11().pipe.extQuiet11(p) }  // pure twin, unique member name
    public func b_own_field(_ p: String) { Holder11().pipe.ownWipe11(p) } }        // the nominal's own member through the same field
extension Holder11 {
    public func b_ext_self(_ p: String) { pipe.extWipe11(p) } }                    // extension of a.swift's type, no imports here
