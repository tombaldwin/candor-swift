import Foundation
public final class File { public let path: String
    public init(path: String) throws { self.path = path }
    public func write(_ s: String) throws { FileManager.default.createFile(atPath: path, contents: Data(s.utf8)) } }
public func depWrite9(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) }
