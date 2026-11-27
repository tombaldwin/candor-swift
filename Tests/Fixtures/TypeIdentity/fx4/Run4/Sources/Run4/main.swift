import Foundation
import Feature
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
let h = Holder(); let c = C(); let ni = NI()
cell("Holder.h_ann_lib") { _ = h.h_ann_lib($0) }
cell("Holder.h_ctor_lib") { _ = h.h_ctor_lib($0) }
cell("Holder.h_ann_vault") { _ = h.h_ann_vault($0) }
cell("Holder.h_ctor_vault") { _ = h.h_ctor_vault($0) }
cell("Holder.h_qann_lib") { _ = h.h_qann_lib($0) }
cell("Holder.h_qctor_lib") { _ = h.h_qctor_lib($0) }
cell("Holder.h_alias_lib") { _ = h.h_alias_lib($0) }
cell("Holder.h_own_nested") { _ = h.h_own_nested($0) }
cell("Holder.h_mirror_kit") { _ = h.h_mirror_kit($0) }
cell("C.l_ann_lib") { _ = c.l_ann_lib($0) }
cell("C.l_ctor_lib") { _ = c.l_ctor_lib($0) }
cell("C.l_ann_vault") { _ = c.l_ann_vault($0) }
cell("C.l_ctor_vault") { _ = c.l_ctor_vault($0) }
cell("C.l_qann_lib") { _ = c.l_qann_lib($0) }
cell("C.l_qctor_lib") { _ = c.l_qctor_lib($0) }
cell("C.l_alias_lib") { _ = c.l_alias_lib($0) }
cell("C.l_fac_lib") { _ = c.l_fac_lib($0) }
cell("C.l_fac_vault") { _ = c.l_fac_vault($0) }
cell("C.l_upper_lib") { _ = c.l_upper_lib($0) }
cell("C.l_inline_lib") { _ = c.l_inline_lib($0) }
cell("C.l_inline_vault") { _ = c.l_inline_vault($0) }
cell("C.l_closure_lib") { _ = c.l_closure_lib($0) }
cell("C.l_closure_named") { _ = c.l_closure_named($0) }
cell("C.l_generic") { _ = c.l_generic($0) }
cell("C.l_own_nested") { _ = c.l_own_nested($0) }
cell("C.l_mirror_kit") { _ = c.l_mirror_kit($0) }
cell("C.g_ann_lib_c") { _ = c.g_ann_lib_c($0) }
cell("C.g_ctor_lib_c") { _ = c.g_ctor_lib_c($0) }
cell("C.g_ann_vault_c") { _ = c.g_ann_vault_c($0) }
cell("C.g_ctor_vault_c") { _ = c.g_ctor_vault_c($0) }
cell("C.g_qann_lib_c") { _ = c.g_qann_lib_c($0) }
cell("C.g_qctor_lib_c") { _ = c.g_qctor_lib_c($0) }
cell("C.g_alias_lib_c") { _ = c.g_alias_lib_c($0) }
cell("C.g_fac_lib_c") { _ = c.g_fac_lib_c($0) }
cell("C.g_upper_lib_c") { _ = c.g_upper_lib_c($0) }
cell("C.g_own_nested_c") { _ = c.g_own_nested_c($0) }
cell("C.g_mirror_kit_c") { _ = c.g_mirror_kit_c($0) }
cell("C.live") { _ = c.live($0) }
cell("NI.ni_global_ctor") { ni.ni_global_ctor($0) }
cell("NI.ni_global_qann") { ni.ni_global_qann($0) }
cell("NI.ni_field_qann") { ni.ni_field_qann($0) }
cell("Holder.niQann") { h.niQann($0) }
cell("Holder.niCtor") { h.niCtor($0) }
