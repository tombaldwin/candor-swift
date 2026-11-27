import Foundation
import Guess
// (b) the ONLY scan-declared type of simple name `Vault` is NESTED; top-level `Vault` in this module is Guess.Vault (loud)
public struct Outer { public init() {}
    public struct Vault { public init() {}
        public func chain() -> Vault { self }
        public func wipeVault(_ p: String) -> Int { p.count } } }     // pure twin of Guess.Vault.wipeVault
public final class Loader { public init() {}
    public func openVault(_ n: String) -> Vault { Vault() }           // Guess.Vault
    public func openNested(_ n: String) -> Outer.Vault { Outer.Vault() } }
let loader = Loader()
let gNest = loader.openVault("x")
let gNestCtor = Vault().chain()                                       // constructor head, same hole
let gNestOwn = loader.openNested("y")                                 // pure twin, really Outer.Vault
// (d) `#if` twins of one type: active arm (macOS) loud
#if os(macOS)
public final class Twin { public init() {}
    public func wipeTwin(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
#else
public final class Twin { public init() {}
    public func wipeTwin(_ p: String) {} }
#endif
public final class TwinLoader { public init() {}
    public func open(_ n: String) -> Twin { Twin() } }
let twinLoader = TwinLoader()
let gTwin = twinLoader.open("t")
let gTwinAnn: Twin = twinLoader.open("t")                             // control: annotated global
// (3) the lane's R73 finding: a plain-constructor global; `Lib` here is Guess.Lib (loud), Core's pure Lib is not imported
let gCtor = Lib()
let gCtorAnn: Lib = Lib()
public struct N {
    public init() {}
    public func n_nested(_ p: String) { gNest.wipeVault(p) }           // WRITES (Guess.Vault)
    public func n_nested_ctor(_ p: String) { gNestCtor.wipeVault(p) }  // WRITES
    public func n_nested_own(_ p: String) -> Int { gNestOwn.wipeVault(p) }   // pure
    public func t_twin(_ p: String) { gTwin.wipeTwin(p) }              // WRITES on macOS
    public func t_twin_ann(_ p: String) { gTwinAnn.wipeTwin(p) }       // WRITES, control
    public func r73_ctor(_ p: String) { gCtor.wipeLib(p) }             // WRITES (Guess.Lib)
    public func r73_ctor_ann(_ p: String) { gCtorAnn.wipeLib(p) }      // WRITES, control
    public func n_live(_ p: String) { depWrite(p) }
}
