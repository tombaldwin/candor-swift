import Foundation
import Feat26
let dir = CommandLine.arguments[1]
let marker = NSTemporaryDirectory() + "/fx26-loudinit"
func cell(_ n: String, _ f: (String) -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
func initCell(_ n: String, _ f: (String) -> Void) { try? FileManager.default.removeItem(atPath: marker); f(dir + "/" + n); print(n, FileManager.default.fileExists(atPath: marker) ? "WRITES" : "pure") }
cell("Sub26.a_grand") { Sub26().a_grand($0) }
cell("Sub26.a_grand_inline") { Sub26().a_grand_inline($0) }
cell("Sub26.a_grand_mirror") { _ = Sub26().a_grand_mirror($0) }
cell("Sub26.a_nearer") { _ = Sub26().a_nearer($0) }
cell("Sub26.a_ext") { Sub26().a_ext($0) }
cell("Sub26.a_ext_mirror") { _ = Sub26().a_ext_mirror($0) }
cell("Outer26.In26.a_in") { Outer26.In26().a_in($0) }
cell("SubF26.f_field") { SubF26().f_field($0) }
cell("SubF26.f_field_mirror") { _ = SubF26().f_field_mirror($0) }
cell("SubA26.b_super_alias") { SubA26().b_super_alias($0) }
cell("ConfA26.b_proto_alias") { _ = ConfA26().b_proto_alias($0) }
cell("OwnA26.b_own_alias") { OwnA26().b_own_alias($0) }
cell("OwnA26.b_own_alias_mirror") { _ = OwnA26().b_own_alias_mirror($0) }
cell("SubD26.d_dep_nested") { SubD26().d_dep_nested($0) }
cell("SubD26.d_dep_nested_mirror") { _ = SubD26().d_dep_nested_mirror($0) }
cell("SubD26.live") { SubD26().live($0) }
let oi = OuterI26()
initCell("OuterI26.i_twin") { oi.i_twin($0) }
initCell("OuterI26.i_lone") { oi.i_lone($0) }
cell("Tbl26.e_field") { Tbl26().e_field($0) }
cell("Tbl26.e_local") { Tbl26().e_local($0) }
cell("Plain26.e_top") { _ = Plain26().e_top($0) }
let propMarker = NSTemporaryDirectory() + "/fx26-markprop"
func propCell(_ n: String, _ f: () -> Void) { try? FileManager.default.removeItem(atPath: propMarker); f(); print(n, FileManager.default.fileExists(atPath: propMarker) ? "WRITES" : "pure") }
propCell("Tbl26.e_field_prop") { _ = Tbl26().e_field_prop("") }
propCell("Tbl26.e_local_prop") { _ = Tbl26().e_local_prop("") }
propCell("Plain26.e_top_prop") { _ = Plain26().e_top_prop("") }
cell("UseP26.p_shared") { UseP26().p_shared($0) }
cell("Back26.g_switch_self") { var b = Back26.custom(LoudStore26()); b.g_switch_self($0) }
cell("Back26.g_if_case_self") { Back26.custom(LoudStore26()).g_if_case_self($0) }
cell("UseH26.h_top_owner") { UseH26().h_top_owner($0) }
let depMarker = NSTemporaryDirectory() + "/fx26-depprop"
try? FileManager.default.removeItem(atPath: depMarker); _ = HoldS26().s_dep_prop(""); print("HoldS26.s_dep_prop", FileManager.default.fileExists(atPath: depMarker) ? "WRITES" : "pure")
cell("TagJ26.j_eq") { _ = TagJ26().j_eq($0) }
