import Foundation
// This file does NOT import Core12: bare `Data` is Foundation's here. The FIELD `c` is still Core12.Data (its declaration's scope).
extension H12 {
    public func b3r_plat(_ p: String) { c.wipe12(p) }                                    // field: Core12.Data, WRITES (lost if read as the platform's)
    public func b3r_plat_pure(_ p: String) { c.write(to: p) }                            // field: Core12.Data, pure (fabricated if read as the platform's)
    public func b3r_copy(_ p: String) { let x = c; x.wipe12(p) }                         // copy of the field: Core12.Data, WRITES
    public func b_found(_ p: String) throws { let d = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) }   // Foundation: WRITES
}
