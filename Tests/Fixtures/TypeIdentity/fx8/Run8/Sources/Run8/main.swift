import Foundation
import Feature8
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("A8.a_ext") { A8().a_ext($0) }
cell("A8.a_live") { A8().a_live($0) }
cell("B8.b_ext") { B8().b_ext($0) }
cell("B8.b_ext_quiet") { _ = B8().b_ext_quiet($0) }
cell("B8.b_own") { B8().b_own($0) }
