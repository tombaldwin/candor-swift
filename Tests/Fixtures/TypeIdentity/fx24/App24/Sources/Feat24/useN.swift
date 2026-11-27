// NO imports (the subset case): DepAX's extension members are visible because useX.swift imports DepAX (Swift 5 member leak)
public struct UN24 { public init() {}
    public func ext_pipe(_ p: String) { H24().pipe.extWipe24(p) }                          // WRITES
    public func ext_quiet(_ p: String) -> Int { H24().pipe.extQuiet24(p) }                 // pure
    public func field_lib(_ p: String) { H24().lib.wipe24(p) }                              // WRITES
    public func field_kit(_ p: String) -> Int { H24().kit.tap24(p) } }                     // pure
