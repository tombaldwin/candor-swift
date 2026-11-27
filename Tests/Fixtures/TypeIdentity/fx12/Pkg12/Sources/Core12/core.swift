#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
// A TOP-LEVEL scan `Data`, visible only to files that import Core12. `write(to:)` is PURE here (Foundation's writes), and
// `wipe12` is LOUD under a name no platform type has, so a binding that wrongly leaves this type shows in BOTH directions.
public struct Data { public init() {}
    public func write(to p: String) {}
    public func wipe12(_ p: String) { if let f = fopen(p, "w") { fclose(f) } } }
