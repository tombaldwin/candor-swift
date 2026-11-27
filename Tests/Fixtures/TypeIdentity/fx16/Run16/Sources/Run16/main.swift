import Foundation
import Feat16
import Ext16
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) throws -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); try? f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
let u = U16()
cell("U16.s1_ann") { u.s1_ann($0) }
cell("U16.s1_inline") { u.s1_inline($0) }
cell("U16.s1_as") { u.s1_as($0) }
cell("U16.s1_ext") { u.s1_ext($0) }
cell("U16.s1_ext_quiet") { _ = u.s1_ext_quiet($0) }
cell("U16.s2_nested") { u.s2_nested($0) }
cell("U16.s3_qual") { u.s3_qual($0) }
cell("U16.s3_qual_ann") { u.s3_qual_ann($0) }
cell("U16.s5_alias") { u.s5_alias($0) }
cell("U16.m_kit") { _ = u.m_kit($0) }
cell("U16.m_kit_inline") { _ = u.m_kit_inline($0) }
cell("U16.live") { u.live($0) }
cell("Outer16.s4_own") { _ = Outer16().s4_own($0) }
cell("Outer16a.r_inner_loud") { Outer16a().r_inner_loud($0) }
cell("Outer16a.r_inner_inline") { Outer16a().r_inner_inline($0) }
cell("Outer16b.r_inner_pure") { _ = Outer16b().r_inner_pure($0) }
cell("Outer16b.r_top_loud") { Outer16b().r_top_loud($0) }
cell("Plain16.r_plain_top") { Plain16().r_plain_top($0) }
cell("Outer16c.Mid16.r_mid_pure") { _ = Outer16c.Mid16().r_mid_pure($0) }
cell("Outer16c.r_outer_loud") { Outer16c().r_outer_loud($0) }
cell("Outer16d.q_found_pure") { _ = Outer16d().q_found_pure($0) }
cell("Outer16d.q_nested_loud") { Outer16d().q_nested_loud($0) }
cell("Outer16d.q_found_write") { try Outer16d().q_found_write($0) }
cell("Outer16e.q_dep") { Outer16e().q_dep($0) }
cell("Outer16e.q_nested_pure") { _ = Outer16e().q_nested_pure($0) }
cell("Outer16f.r_unseen_nested") { _ = Outer16f().r_unseen_nested($0) }
cell("U16.implicit_member") { _ = u.implicit_member($0) }
cell("Ext16Use.q_own_loud") { Ext16Use().q_own_loud($0) }
