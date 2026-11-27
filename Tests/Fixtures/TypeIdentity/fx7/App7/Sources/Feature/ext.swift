// NO imports at all: F-B3r use file. `c` is Core.Lib; Swift 5 member visibility lets this compile.
extension H {
    public func b3r(_ p: String) { c.wipeLib(p) }   // WRITES
}
