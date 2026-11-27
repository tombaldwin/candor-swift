import Foundation
import Guess
public final class Loader { public init() {}
    public func open(_ n: String) -> Lib { Lib() } }     // UNQUALIFIED: in this target `Lib` is Guess.Lib (loud); the package's other target also has a `Lib`
let loader = Loader()
let gLib = loader.open("x")
public struct F {
    public init() {}
    public func f_dep(_ p: String) { gLib.wipeLib(p) }   // WRITES (Guess.Lib)
    public func f_live(_ p: String) { depWrite(p) }
}
