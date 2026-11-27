import Foundation
// NOTE: no `import Guess` in this file — Swift 5 member visibility leaks across files of a target
extension Msg {
    public func c_ext_noimport(_ p: String) { fDep.wipeDep(p) }   // WRITES
    public func c_ext_coll(_ p: String) { coll.post(p) }           // WRITES
}
extension Msg2 {
    public func c_ann_noimport(_ p: String) { ann.wipeDep(p) }     // WRITES (annotated field, no import in this file)
    public func c_tcoll_noimport(_ p: String) { tc.settleUp(p) }   // WRITES
}
