import Foundation
import Feature22
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("H22.a_live") { H22().a_live($0) }
cell("O22.o_nested") { _ = O22().o_nested($0) }
cell("B22.b_field") { B22().b_field($0) }
cell("B22.b_field_mirror") { _ = B22().b_field_mirror($0) }
cell("B22.b_param") { B22().b_param(H22(), $0) }
cell("B22.b_local") { B22().b_local($0) }
cell("B22.b_global") { B22().b_global($0) }
cell("B22.b_global_mirror") { _ = B22().b_global_mirror($0) }
cell("B22.b_ret") { B22().b_ret($0) }
cell("B22.b_closure") { B22().b_closure($0) }
cell("B22.b_ext_sibling") { B22().b_ext_sibling($0) }
cell("B22.b_ext_sibling_quiet") { _ = B22().b_ext_sibling_quiet($0) }
cell("B22.b_nested") { _ = B22().b_nested($0) }
cell("C22.c_field") { C22().c_field($0) }
cell("C22.c_field_mirror") { _ = C22().c_field_mirror($0) }
cell("C22.c_ext") { C22().c_ext($0) }
cell("W22.w_witness") { W22().w_witness(Enc22Box.make(), $0) }
