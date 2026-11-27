import Foundation
// own-leaf hedge truth: a platform-named leaf the package also declares loudly
public final class Sink { public init() {}
    public func write(_ s: String) { FileManager.default.createFile(atPath: s, contents: nil) }     // loud; `write(_:)` is also a platform member name
    public func scribble(_ s: String) { FileManager.default.createFile(atPath: s, contents: nil) }  // loud; unique leaf
    public func hush(_ s: String) -> Int { s.count } }
public func withSink(_ f: (Sink) -> Void) { f(Sink()) }
public struct H {
    public init() {}
    public func h_write(_ p: String) { withSink { $0.write(p) } }           // WRITES — platform-named leaf
    public func h_scribble(_ p: String) { withSink { $0.scribble(p) } }     // WRITES — own-only leaf
    public func h_hush(_ p: String) { withSink { _ = $0.hush(p) } }         // pure
}
