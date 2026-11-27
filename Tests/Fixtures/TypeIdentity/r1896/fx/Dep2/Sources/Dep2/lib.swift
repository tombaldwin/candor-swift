import Foundation
public final class Relay { public init() {}
    public func relayOut(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
