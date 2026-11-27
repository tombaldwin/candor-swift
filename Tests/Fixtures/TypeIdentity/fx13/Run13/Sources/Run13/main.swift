import Foundation
import Own13
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("Outer13.a_pure") { Outer13().a_pure($0) }
cell("Outer13.a_loud") { Outer13().a_loud($0) }
cell("Outer13.a_inline") { Outer13().a_inline($0) }
cell("Outer13b.b_pure") { Outer13b().b_pure($0) }
cell("Outer13b.b_loud") { Outer13b().b_loud($0) }
cell("C13.c_alias") { C13().c_alias($0) }
print("Q13.q_url", Q13().q_url(dir + "/missing13") ? "TOUCHES" : "pure")
cell("Sub13.s_pure") { Sub13().s_pure($0) }
cell("Sub13.s_loud") { Sub13().s_loud($0) }
cell("Plain13.p_data") { try Plain13().p_data($0) }
