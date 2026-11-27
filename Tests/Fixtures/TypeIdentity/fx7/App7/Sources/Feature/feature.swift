import Foundation
import Core
public final class H { public init() {}
    var c: Lib = Lib() }                                                            // F-B3r: the field IS Core's loud Lib (declared in a file that imports Core)
public struct S6 { public init() {}
    public func s6_sib(_ p: String) { let x = Lib(); x.wipeLib(p) } }               // S6: sibling imported, no dependency -> Core.Lib, WRITES
public final class Sub: Base { public override init() {}
    public func inh_nested(_ p: String) { let c = Cfg(); c.wipeCfg(p) } }           // bare `Cfg` = inherited Base.Cfg, WRITES
public final class Sub2: Base2 { public override init() {}
    public func inh_shared(_ p: String) { let k = Knob(); k.turnKnob(p) } }         // bare `Knob` = inherited Base2.Knob (leaf shared with pure Other.Knob), WRITES
public struct Pure { public init() {}
    public func other_knob(_ p: String) -> Int { let k = Other.Knob(); return k.turnKnob(p) } }  // pure control
