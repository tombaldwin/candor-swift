import Foundation
import Own9
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
let o = Outer9(), s = Sub9(), pl = Plain9()
cell("Outer9.r_nested") { o.r_nested($0) }
cell("Outer9.r_nested_ann") { o.r_nested_ann($0) }
cell("Outer9.r_qualified") { try o.r_qualified($0) }
cell("Sub9.r_super") { s.r_super($0) }
cell("Plain9.p_data") { try pl.p_data($0) }
