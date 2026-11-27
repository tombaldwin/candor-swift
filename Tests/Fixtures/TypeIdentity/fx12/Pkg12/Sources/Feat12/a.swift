import Core12
// This file sees Core12.Data (top-level, imported): bare `Data` IS the scan type here.
public final class H12 { public init() {}
    var c: Data = Data()                                                                 // Core12.Data
    public func own_top(_ p: String) { let d = Data(); d.wipe12(p) }                     // Core12.Data: WRITES (visible module top level)
    public func own_top_pure(_ p: String) { let d = Data(); d.write(to: p) }             // Core12.Data: pure (a platform reading would fabricate Fs)
}
