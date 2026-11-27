import Foundation
import Use10
let dir = CommandLine.arguments[1]
func cell(_ n: String, _ f: (String) -> Void) { let p = dir + "/" + n; try? FileManager.default.removeItem(atPath: p); f(p); print(n, FileManager.default.fileExists(atPath: p) ? "WRITES" : "pure") }
let so = SubOther(), sd = SubDep(), sg = SubGen(), cf = Conf10(), m = M10(), e = Ext10()
cell("SubOther.inh_other_module") { so.inh_other_module($0) }
cell("SubOther.inh_other_pure") { _ = so.inh_other_pure($0) }
cell("SubDep.inh_dependency") { sd.inh_dependency($0) }
cell("SubDep.inh_dep_pure") { _ = sd.inh_dep_pure($0) }
cell("SubGen.inh_generic") { sg.inh_generic($0) }
cell("SubGen.inh_generic_pure") { _ = sg.inh_generic_pure($0) }
cell("Conf10.alias_conformance") { cf.alias_conformance($0) }
cell("Conf10.alias_conformance_pure") { _ = cf.alias_conformance_pure($0) }
cell("M10.assoc_witness") { _ = m.assoc_witness($0) }
cell("Ext10.s13_ext_nested") { e.s13_ext_nested($0) }
cell("Ext10.s13_ext_pure") { _ = e.s13_ext_pure($0) }
cell("Ext10.live") { e.live($0) }
