import Foundation
import Feature
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
let n = N()
cell("N.n_nested") { n.n_nested($0) }
cell("N.n_nested_ctor") { n.n_nested_ctor($0) }
cell("N.n_nested_own") { _ = n.n_nested_own($0) }
cell("N.t_twin") { n.t_twin($0) }
cell("N.t_twin_ann") { n.t_twin_ann($0) }
cell("N.r73_ctor") { n.r73_ctor($0) }
cell("N.r73_ctor_ann") { n.r73_ctor_ann($0) }
cell("N.n_live") { n.n_live($0) }
