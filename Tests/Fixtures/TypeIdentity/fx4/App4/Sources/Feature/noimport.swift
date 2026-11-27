// NO `import Guess` here (Swift 5 member visibility lets the calls compile).
public struct NI { public init() {}
    public func ni_global_ctor(_ p: String) { g_ctor_lib.wipeLib(p) }
    public func ni_global_qann(_ p: String) { g_qann_lib.wipeLib(p) }
    public func ni_field_qann(_ p: String) { Holder().niQann(p) }
}
extension Holder {
    public func niQann(_ p: String) { f_qann_lib.wipeLib(p) }
    public func niCtor(_ p: String) { f_ctor_lib.wipeLib(p) }
}
