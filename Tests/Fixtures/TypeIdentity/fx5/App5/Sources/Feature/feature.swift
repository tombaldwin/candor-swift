import Foundation
import Guess
// In THIS module: `Lib`, `Vault`, `Kit` are Guess's (Core is not imported). The only scan `Vault` here is NESTED.
public struct Outer { public init() {}
    public struct Vlt { public init() {}
        public func wipeVault(_ p: String) -> Int { p.count }
        public func quietOuterVault(_ p: String) -> Int { p.count } } }          // PURE twin of Guess.Vault.wipeVault
public typealias DepLib = Lib                                               // = Guess.Lib
public func mkLib() -> Lib { Lib() }                                        // returns Guess.Lib
public func mkVault() -> Vault { Vault() }                                  // returns Guess.Vault
public func MkLib() -> Lib { Lib() }                                        // uppercase FREE function
public func withLib(_ f: (Lib) -> Void) { f(Lib()) }                        // closure param typed in the CALLEE's scope
public protocol Wiper { func wipeLib(_ p: String) }
extension Lib: Wiper {}                                                     // Guess.Lib conforms
public struct GB<Lib: Wiper> { let v: Lib; public init(v: Lib) { self.v = v }  // generic PARAMETER named like a type
    public func run(_ p: String) { v.wipeLib(p) } }
// globals
let g_ann_lib: Lib = Lib()
let g_ctor_lib = Lib()
let g_ann_vault: Vault = Vault()
let g_ctor_vault = Vault()
let g_qann_lib: Guess.Lib = Guess.Lib()
let g_qctor_lib = Guess.Lib()
let g_alias_lib: DepLib = DepLib()
let g_fac_lib = mkLib()
let g_upper_lib = MkLib()
let g_own_nested = Outer.Vlt()
let g_mirror_kit = Kit()
public final class Holder { public init() {}
    var f_ann_lib: Lib = Lib()
    var f_ctor_lib = Lib()
    var f_ann_vault: Vault = Vault()
    var f_ctor_vault = Vault()
    var f_qann_lib: Guess.Lib = Guess.Lib()
    var f_qctor_lib = Guess.Lib()
    var f_alias_lib: DepLib = DepLib()
    var f_own_nested = Outer.Vlt()
    var f_mirror_kit = Kit()
    public func h_ann_lib(_ p: String) { f_ann_lib.wipeLib(p) }
    public func h_ctor_lib(_ p: String) { f_ctor_lib.wipeLib(p) }
    public func h_ann_vault(_ p: String) { f_ann_vault.wipeVault(p) }
    public func h_ctor_vault(_ p: String) { f_ctor_vault.wipeVault(p) }
    public func h_qann_lib(_ p: String) { f_qann_lib.wipeLib(p) }
    public func h_qctor_lib(_ p: String) { f_qctor_lib.wipeLib(p) }
    public func h_alias_lib(_ p: String) { f_alias_lib.wipeLib(p) }
    public func h_own_nested(_ p: String) -> Int { f_own_nested.wipeVault(p) }   // pure control
    public func h_mirror_kit(_ p: String) -> Int { f_mirror_kit.tapKit(p) }       // pure (Guess.Kit)
}
public struct C { public init() {}
    public func l_ann_lib(_ p: String) { let x: Lib = Lib(); x.wipeLib(p) }
    public func l_ctor_lib(_ p: String) { let x = Lib(); x.wipeLib(p) }
    public func l_ann_vault(_ p: String) { let x: Vault = Vault(); x.wipeVault(p) }
    public func l_ctor_vault(_ p: String) { let x = Vault(); x.wipeVault(p) }
    public func l_qann_lib(_ p: String) { let x: Guess.Lib = Guess.Lib(); x.wipeLib(p) }
    public func l_qctor_lib(_ p: String) { let x = Guess.Lib(); x.wipeLib(p) }
    public func l_alias_lib(_ p: String) { let x: DepLib = DepLib(); x.wipeLib(p) }
    public func l_fac_lib(_ p: String) { let x = mkLib(); x.wipeLib(p) }
    public func l_fac_vault(_ p: String) { let x = mkVault(); x.wipeVault(p) }
    public func l_upper_lib(_ p: String) { let x = MkLib(); x.wipeLib(p) }
    public func l_inline_lib(_ p: String) { Lib().wipeLib(p) }
    public func l_inline_vault(_ p: String) { Vault().wipeVault(p) }
    public func l_closure_lib(_ p: String) { withLib { $0.wipeLib(p) } }
    public func l_closure_named(_ p: String) { withLib { l in l.wipeLib(p) } }
    public func l_generic(_ p: String) { GB(v: Lib()).run(p) }
    public func l_own_nested(_ p: String) -> Int { let x = Outer.Vlt(); return x.wipeVault(p) }   // pure control
    public func l_mirror_kit(_ p: String) -> Int { let x = Kit(); return x.tapKit(p) }             // pure (Guess.Kit)
    public func g_ann_lib_c(_ p: String) { g_ann_lib.wipeLib(p) }
    public func g_ctor_lib_c(_ p: String) { g_ctor_lib.wipeLib(p) }
    public func g_ann_vault_c(_ p: String) { g_ann_vault.wipeVault(p) }
    public func g_ctor_vault_c(_ p: String) { g_ctor_vault.wipeVault(p) }
    public func g_qann_lib_c(_ p: String) { g_qann_lib.wipeLib(p) }
    public func g_qctor_lib_c(_ p: String) { g_qctor_lib.wipeLib(p) }
    public func g_alias_lib_c(_ p: String) { g_alias_lib.wipeLib(p) }
    public func g_fac_lib_c(_ p: String) { g_fac_lib.wipeLib(p) }
    public func g_upper_lib_c(_ p: String) { g_upper_lib.wipeLib(p) }
    public func g_own_nested_c(_ p: String) -> Int { g_own_nested.quietOuterVault(p) }   // pure control
    public func g_mirror_kit_c(_ p: String) -> Int { g_mirror_kit.tapKit(p) }      // pure (Guess.Kit)
    public func live(_ p: String) { depWrite(p) }
}
