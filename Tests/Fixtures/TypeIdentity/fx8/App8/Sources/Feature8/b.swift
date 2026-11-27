// NO imports: extension member of a dependency type, reached through a global declared in a.swift
public struct B8 { public init() {}
    public func b_ext(_ p: String) { g8.extWipe8(p) }        // WRITES (Swift 5 member-visibility leak)
    public func b_ext_quiet(_ p: String) -> Int { g8.extQuiet8(p) }   // pure twin
    public func b_own(_ p: String) { g8.ownWipe8(p) } }      // own member of the nominal
