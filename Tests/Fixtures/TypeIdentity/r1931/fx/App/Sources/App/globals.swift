import Foundation
import Guess
public final class Lib { public init() {}                       // App's Lib: PURE wipeLib
    public func wipeLib(_ p: String) -> Int { p.count } }
public final class Vault { public init() {}                     // loud, unique leaf
    public func wipeVault(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public class Store { public init() {}
    public func wipeStore(_ p: String) -> Int { p.count } }
public final class LoudStore: Store {
    public override func wipeStore(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 } }
public class Base { public init() {}
    public func cfg() -> Self { self }
    public func wipeBase(_ p: String) -> Int { p.count } }
public final class Sub: Base {
    public override func wipeBase(_ p: String) -> Int { FileManager.default.createFile(atPath: p, contents: nil); return 1 } }
public final class Loader { public init() {}
    public func openDep(_ n: String) -> Guess.Lib { Guess.Lib() }       // module-qualified DEPENDENCY type sharing App's `Lib` name
    public func openQuiet(_ n: String) -> Lib { Lib() }                 // App's pure Lib
    public func openLoud(_ n: String) -> Store { LoudStore() }          // declared Store, returns the loud subclass
    public func open2() -> Lib { Lib() }                                 // overloads: different labels, different returns
    public func open2(loud: Bool) -> Vault { Vault() }
    public static func open3() -> Lib { Lib() }                          // static vs instance of one name, different returns
    public func open3() -> Vault { Vault() }
    public func openAny(_ n: String) -> Any { Vault() }
}
public struct Box<Value> { public let v: Value; public init(v: Value) { self.v = v }
    public func get() -> Value { v } }
public typealias Value = Lib                                             // a scan ALIAS named like Box's generic parameter
public struct Holder { public let v: Lib; public init(v: Lib) { self.v = v }
    public func get() -> Lib { v } }
let loader = Loader()
let gDep = loader.openDep("x")
let gQuiet = loader.openQuiet("q")
let gStore = loader.openLoud("y")
let gStoreAnn: Store = loader.openLoud("y")        // control: main's annotated-global mechanism
let gOv = loader.open2(loud: true)                 // poisoned key? (two returns)
let gStat = Loader.open3()                         // static (-> Lib, pure)  vs instance (-> Vault, loud)
let gInst = Loader().open3()
let gSub = Sub().cfg()                             // `-> Self` declared on Base, head is the subclass
let gBoxed = Box(v: Vault()).get()                 // generic return `Value` while a scan alias `Value` exists
let gAny = loader.openAny("a") as! Vault
public struct A {
    public init() {}
    public func a_dep(_ p: String) { gDep.wipeLib(p) }                  // WRITES (Guess.Lib)
    public func a_quiet(_ p: String) -> Int { gQuiet.wipeLib(p) }       // pure
    public func a_store(_ p: String) -> Int { gStore.wipeStore(p) }     // WRITES (LoudStore)
    public func a_store_ann(_ p: String) -> Int { gStoreAnn.wipeStore(p) }   // WRITES, control
    public func a_ov(_ p: String) { gOv.wipeVault(p) }                  // WRITES
    public func a_stat(_ p: String) -> Int { gStat.wipeLib(p) }         // pure
    public func a_inst(_ p: String) { gInst.wipeVault(p) }              // WRITES
    public func a_sub(_ p: String) -> Int { gSub.wipeBase(p) }          // WRITES (Sub)
    public func a_boxed(_ p: String) { gBoxed.wipeVault(p) }            // WRITES
    public func a_any(_ p: String) { gAny.wipeVault(p) }                // WRITES
    public func a_shadow_loud(_ p: String) { let gQuiet = Vault(); gQuiet.wipeVault(p) }            // WRITES: a LOUD local shadows the pure-typed global
    public func a_param_loud(_ gQuiet: Vault, _ p: String) { gQuiet.wipeVault(p) }                    // WRITES
    public func a_closure_loud(_ p: String) { [Vault()].forEach { gQuiet in gQuiet.wipeVault(p) } }  // WRITES
    public func a_live(_ p: String) { depWrite(p) }                      // chained-join liveness control
}
