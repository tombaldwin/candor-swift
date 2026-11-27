import Foundation
import Feature
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
let f = F()
cell("F.f_dep") { f.f_dep($0) }
cell("F.f_live") { f.f_live($0) }
