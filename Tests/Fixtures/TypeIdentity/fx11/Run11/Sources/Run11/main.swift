import Foundation
import Feature11
import Feature11mi
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
let h = Holder11(), b = B11(), hm = HolderMi(), bm = BMi()
cell("Holder11.a_field") { h.a_field($0) }
cell("Holder11.a_live") { h.a_live($0) }
cell("B11.b_ext_field") { b.b_ext_field($0) }
cell("B11.b_ext_factory") { b.b_ext_factory($0) }
cell("B11.b_ext_local") { b.b_ext_local($0) }
cell("B11.b_ext_quiet") { _ = b.b_ext_quiet($0) }
cell("B11.b_own_field") { b.b_own_field($0) }
cell("Holder11.b_ext_self") { h.b_ext_self($0) }
cell("HolderMi.mi_ext") { hm.mi_ext($0) }
cell("HolderMi.mi_ext_quiet") { _ = hm.mi_ext_quiet($0) }
cell("HolderMi.mi_own") { hm.mi_own($0) }
cell("BMi.mi_b_ext") { bm.mi_b_ext($0) }
cell("BMi.mi_b_ext_quiet") { _ = bm.mi_b_ext_quiet($0) }
