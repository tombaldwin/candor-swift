import Foundation
import Feat23
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
cell("UB23.field_lib") { UB23().field_lib($0) }
cell("UB23.field_kit") { _ = UB23().field_kit($0) }
cell("UB23.bare_lib") { _ = UB23().bare_lib($0) }
cell("UB23.bare_kit") { _ = UB23().bare_kit($0) }
cell("UB23.ret_lib") { UB23().ret_lib($0) }
cell("UC23.field_lib") { UC23().field_lib($0) }
cell("UC23.bare_lib") { _ = UC23().bare_lib($0) }
cell("UT23.t4_overload_lib") { UT23().t4_overload_lib($0) }
cell("UT23.t4_overload_kit") { UT23().t4_overload_kit($0) }
cell("UT23.t4_generic") { UT23().t4_generic($0) }
cell("UT23.t4_shadow") { _ = UT23().t4_shadow($0) }
cell("W23.w_default") { W23().w_default(Enc23Box.make(), $0) }
cell("W23.w_refined") { W23().w_refined($0) }
cell("W23.w_cond") { W23().w_cond($0) }
cell("W23.live") { W23().live($0) }
