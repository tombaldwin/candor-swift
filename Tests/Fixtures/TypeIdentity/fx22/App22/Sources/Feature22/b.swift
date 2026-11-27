// NO imports: every receiver's type is decided by a declaration in a.swift
public struct B22 { public init() {}
    public func b_field(_ p: String) { H22().lib.wipe22(p) }                  // WRITES (Base22.Lib22)
    public func b_field_mirror(_ p: String) -> Int { H22().kit.tap22(p) }     // pure (Base22.Kit22; Core22's twin writes)
    public func b_param(_ h: H22, _ p: String) { h.lib.wipe22(p) }            // WRITES, through a parameter of the scan type
    public func b_local(_ p: String) { let h = H22(); let l = h.lib; l.wipe22(p) }   // WRITES, a local bound from the field
    public func b_global(_ p: String) { gLib22.wipe22(p) }                     // WRITES
    public func b_global_mirror(_ p: String) -> Int { gKit22.tap22(p) }       // pure
    public func b_ret(_ p: String) { mkLib22().wipe22(p) }                     // WRITES
    public func b_closure(_ p: String) { withLib22 { $0.wipe22(p) } }          // WRITES (T4: the callee is declared in a.swift)
    public func b_ext_sibling(_ p: String) { H22().pipe.extWipe22(p) }        // WRITES: Ext22X is imported by s.swift, not a.swift
    public func b_ext_sibling_quiet(_ p: String) -> Int { H22().pipe.extQuiet22(p) }   // pure twin
    public func b_nested(_ p: String) -> Int { O22().f.wipe22(p) } }          // pure (O22.Lib22, a scan type)
