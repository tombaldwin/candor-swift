import Foundation
// Own12 nests its own `Outer12.Data` (pure). Bare `Data` OUTSIDE Outer12 is Foundation's.
public struct Outer12 { public init() {}
    public struct Data { public init() {}
        public func write(to p: String) {} }                                              // pure
    public func inner_nested(_ p: String) { let d = Data(); d.write(to: p) }               // Outer12.Data: pure (visible nested)
}
public struct O12 { public init() {}
    let od: [Outer12.Data] = [Outer12.Data()]
    public func as_cast(_ p: String) throws { let any: Any = Data("x".utf8); let d = any as! Data; try d.write(to: URL(fileURLWithPath: p)) }
    public func opt_ann(_ p: String) throws { let d: Data? = Data("x".utf8); try d?.write(to: URL(fileURLWithPath: p)) }
    public func static_init(_ p: String) throws { try Data.init("x".utf8).write(to: URL(fileURLWithPath: p)) }
    // REBINDS: the inner binding is Outer12.Data (pure); the outer platform binding must not leak onto it
    public func rebind_for(_ p: String) { let d: Data = Data(); _ = d.count; for d in od { d.write(to: p) } }
    public func rebind_closure(_ p: String) { let d: Data = Data(); _ = d.count; od.forEach { d in d.write(to: p) } }
    // the outer binding written AFTER an inner block shadowed it: Foundation write
    public func rebind_block(_ p: String) throws {
        let d: Data = Data("x".utf8)
        do { let d = od[0]; d.write(to: p + ".inner") }
        try d.write(to: URL(fileURLWithPath: p))
    }
}
// REFUSAL: an extension of a platform type (its member types are not the scan's to know): stays at main's reading
extension String {
    public func fe_data(_ p: String) throws { try Data(self.utf8).write(to: URL(fileURLWithPath: p)) }
}
// REFUSAL: a body-local `Data` IS what the body's bare spelling names (pure); a platform reading would fabricate Fs
public struct L12 { public init() {}
    public func body_local(_ p: String) { struct Data { func write(to p: String) {} }; let d = Data(); d.write(to: p) }
}
// REFUSAL: a superclass this scan does not declare (its member types are not the scan's to know): stays at main's reading
open class Sp12: NSObject {
    public func sp_data(_ p: String) throws { try Data("x".utf8).write(to: URL(fileURLWithPath: p)) }
}
