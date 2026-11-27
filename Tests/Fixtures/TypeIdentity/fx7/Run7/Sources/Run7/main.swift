import Foundation
import Feature
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("H.b3r") { H().b3r($0) }
cell("S6.s6_sib") { S6().s6_sib($0) }
cell("Sub.inh_nested") { Sub().inh_nested($0) }
cell("Sub2.inh_shared") { Sub2().inh_shared($0) }
cell("Pure.other_knob") { _ = Pure().other_knob($0) }
