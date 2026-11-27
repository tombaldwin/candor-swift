import Foundation
import App
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) -> Void) {
    let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p)
    print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure")
}
let a = A(); let h = H()
cell("A.a_dep") { a.a_dep($0) }
cell("A.a_quiet") { _ = a.a_quiet($0) }
cell("A.a_store") { _ = a.a_store($0) }
cell("A.a_store_ann") { _ = a.a_store_ann($0) }
cell("A.a_ov") { a.a_ov($0) }
cell("A.a_stat") { _ = a.a_stat($0) }
cell("A.a_inst") { a.a_inst($0) }
cell("A.a_sub") { _ = a.a_sub($0) }
cell("A.a_boxed") { a.a_boxed($0) }
cell("A.a_any") { a.a_any($0) }
cell("A.a_shadow_loud") { a.a_shadow_loud($0) }
cell("A.a_param_loud") { a.a_param_loud(Vault(), $0) }
cell("A.a_closure_loud") { a.a_closure_loud($0) }
cell("A.a_live") { a.a_live($0) }
cell("H.h_write") { h.h_write($0) }
cell("H.h_scribble") { h.h_scribble($0) }
cell("H.h_hush") { h.h_hush($0) }
