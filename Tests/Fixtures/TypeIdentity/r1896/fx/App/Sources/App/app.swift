import Foundation
import Guess
import Core
/// the consumer's OWN `Ledger`: `post` is PURE here, WRITES in Guess
public final class Ledger { public init() {}
    public func post(_ p: String) -> Int { p.count } }
/// the consumer's OWN `Vault`: pure; Core.Vault writes
public final class Vault { public init() {}
    public func stash(_ p: String) -> Int { p.count } }
public struct Msg {
    public var coll = Guess.Ledger()          // dependency type, simple name collides with App.Ledger
    public var own = App.Ledger()             // own type, same simple name as Guess.Ledger
    public var cv = Core.Vault()              // other OWN module's type; App.Vault collides
    public var mk = Guess.Maker()             // uppercase free function, two segments
    public var ta = Guess.Store()             // dependency typealias
    public var fDep = Guess.DepStore()        // control (the lane's s_bare)
    public static let shared = Guess.DepStore()
    public init() {}
    public func c_coll(_ p: String) { coll.post(p) }            // executes Guess.Ledger.post: WRITES
    public func c_coll_self(_ p: String) { self.coll.post(p) }  // WRITES
    public func c_own(_ p: String) -> Int { own.post(p) }       // pure
    public func c_cv(_ p: String) { cv.stash(p) }               // executes Core.Vault.stash: WRITES
    public func c_mk(_ p: String) { mk.wipeDep(p) }             // WRITES
    public func c_ta(_ p: String) { ta.wipeDep(p) }             // WRITES
    public func c_bare(_ p: String) { fDep.wipeDep(p) }         // WRITES (control)
    public func c_static(_ p: String) { Msg.shared.wipeDep(p) } // WRITES
    public func c_static_self(_ p: String) { Self.shared.wipeDep(p) } // WRITES
}
/// the consumer's OWN `Teller`: `settleUp` is PURE here, WRITES in Guess
public final class Teller { public init() {}
    public func settleUp(_ p: String) -> Int { p.count } }
public struct Msg2 {
    public var tc = Guess.Teller()                                 // UNANNOTATED, dependency type colliding with App.Teller
    public var ta: Guess.Teller = Guess.Teller()                   // ANNOTATED control, same collision
    public var ann: Guess.DepStore = Guess.DepStore()              // ANNOTATED control for the no-import extension
    public init() {}
    public func c_tcoll(_ p: String) { tc.settleUp(p) }           // executes Guess.Teller.settleUp: WRITES
    public func c_tcoll_self(_ p: String) { self.tc.settleUp(p) } // WRITES
    public func c_acoll(_ p: String) { ta.settleUp(p) }           // WRITES (annotated spelling)
    public func c_ann_bare(_ p: String) { ann.wipeDep(p) }        // WRITES (annotated, same file)
    public func c_local_mk(_ p: String) { let m = Guess.Maker(); m.wipeDep(p) }   // WRITES (local binder neighbour)
}
public final class OwnPure2 { public init() {}; public func sib(_ p: String) -> Int { p.count } }
public typealias Sibling = OwnPure2                       // local ALIAS sharing the dependency type's name
public struct Msg3 {
    public var rx = Guess.Relay()                         // a type Guess only RE-EXPORTS (@_exported import Dep2)
    public var sb = Guess.Sibling()                       // local typealias collision
    public var bx = Guess.Boxed()                         // dependency alias of a generic specialisation
    public var fDep = Guess.DepStore()                    // for the scoped-import file
    public init() {}
    public func c_reexport(_ p: String) { rx.relayOut(p) }      // WRITES (Dep2 body)
    public func c_reexport_ext(_ p: String) { rx.relayTwice(p) } // WRITES (Guess extension -> Dep2)
    public func c_aliascoll(_ p: String) { sb.sib(p) }           // WRITES (Guess.Sibling.sib)
    public func c_genalias(_ p: String) { bx.wipeGen(p) }        // WRITES
}
public struct GBox<Teller> {                                      // a GENERIC PARAMETER named like the dependency type
    public var t = Guess.Teller()
    public init() {}
    public func c_genparam(_ p: String) { t.settleUp(p) }        // WRITES (Guess.Teller.settleUp)
}
