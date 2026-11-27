import Foundation
import Own27
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("I27.noinit_path") { I27().noinit_path($0) }
cell("I27.noinit_name") { I27().noinit_name($0) }
cell("I27.conv_path") { I27().conv_path($0) }
cell("I27.conv_x") { I27().conv_x($0) }
cell("I27.desig") { I27().desig($0) }
cell("OSub27.via_super") { OSub27().via_super($0) }
cell("O27.sub_go") { O27().sub_go($0) }
cell("O27.sub_quiet") { O27().sub_quiet($0) }
cell("O27.base_go") { O27().base_go($0) }
cell("O27.upcast_go") { O27().upcast_go($0) }
cell("Q27.class_wins") { Q27().class_wins($0) }
cell("Q27.default_runs") { Q27().default_runs($0) }
cell("Q27.existential") { Q27().existential($0) }
cell("GSub27.gen_nested") { GSub27().gen_nested($0) }
cell("Plain27.top") { _ = Plain27().top($0) }
