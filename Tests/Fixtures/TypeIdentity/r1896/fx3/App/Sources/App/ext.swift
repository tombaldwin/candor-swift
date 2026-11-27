// no `import Guess` here (legal: member visibility crosses files)
extension Msg {
    public func s_b3(_ p: String) { fDep.wipeDep(p) }
    public func s_b3_tc(_ p: String) { tc.settleUp(p) }
}
