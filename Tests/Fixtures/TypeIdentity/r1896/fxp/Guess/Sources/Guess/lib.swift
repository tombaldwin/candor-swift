import Foundation
public final class DepStore { public init() {}
    public func wipeDep(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
/// a dependency type whose simple name is also a PLATFORM type (os.Logger)
public final class Logger { public init() {}
    public func emitL(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
