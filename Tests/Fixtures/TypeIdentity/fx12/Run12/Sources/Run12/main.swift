import Foundation
import Own12
import Feat12
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) {
    let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? FileManager.default.removeItem(atPath: p + ".inner")
    try? f(p)
    print(n, FileManager.default.fileExists(atPath: p) || FileManager.default.fileExists(atPath: p + ".inner") ? "WRITES" : "pure")
}
let o = O12(), out = Outer12(), h = H12()
cell("Outer12.inner_nested") { out.inner_nested($0) }
cell("O12.as_cast") { try o.as_cast($0) }
cell("O12.opt_ann") { try o.opt_ann($0) }
cell("O12.static_init") { try o.static_init($0) }
cell("O12.rebind_for") { o.rebind_for($0) }
cell("O12.rebind_closure") { o.rebind_closure($0) }
cell("O12.rebind_block") { try o.rebind_block($0) }
cell("String.fe_data") { try "x".fe_data($0) }
cell("L12.body_local") { L12().body_local($0) }
cell("Sp12.sp_data") { try Sp12().sp_data($0) }
cell("Plain12.pe_data") { try Conf12().pe_data($0) }
cell("Conf12.ce_data") { try Conf12().ce_data($0) }
cell("Wit12.w_data") { Wit12().w_data($0) }
cell("Wit12b.wb_data") { Wit12b().wb_data($0) }
cell("H12.own_top") { h.own_top($0) }
cell("H12.own_top_pure") { h.own_top_pure($0) }
cell("H12.b3r_plat") { h.b3r_plat($0) }
cell("H12.b3r_plat_pure") { h.b3r_plat_pure($0) }
cell("H12.b3r_copy") { h.b3r_copy($0) }
cell("H12.b_found") { try h.b_found($0) }
