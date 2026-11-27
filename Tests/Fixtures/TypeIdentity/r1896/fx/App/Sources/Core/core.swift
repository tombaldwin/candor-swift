import Foundation
/// Core.Vault WRITES; App.Vault (same simple name, other own module) is pure
public final class Vault { public init() {}
    public func stash(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
