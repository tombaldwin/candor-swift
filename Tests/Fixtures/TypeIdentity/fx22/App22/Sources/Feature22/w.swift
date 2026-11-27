import Foundation
import Base22
// a SCAN protocol a DEPENDENCY type conforms to by a scan extension whose own member is the witness (vapor's
// `extension FormDataEncoder: ContentEncoder { func encode … }`): the CHA must keep that extension member
public protocol Encoding22 { func enc22(_ p: String) }
extension Enc22: Encoding22 { public func enc22(_ p: String) { FileManager.default.createFile(atPath: p, contents: nil) } }
public struct W22 { public init() {}
    public func w_witness(_ e: Encoding22, _ p: String) { e.enc22(p) } }      // WRITES (with an Enc22)
public enum Enc22Box { public static func make() -> Encoding22 { Enc22() } }
