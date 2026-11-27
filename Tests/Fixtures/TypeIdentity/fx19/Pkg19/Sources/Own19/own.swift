import Foundation
public struct Resp19 { public init(status: Status19) {}
    public struct Status19 { public let code: Int
        public init(code: Int, path: String) { self.code = code; FileManager.default.createFile(atPath: path, contents: nil) }   // LOUD init
        public static func isValid(_ s: String) -> Bool { !s.isEmpty }
        public init(quiet code: Int) { self.code = code }                                                                         // pure twin
        public static func make(_ p: String) -> Status19 { Status19(code: 1, path: p) } } }                                       // LOUD factory
public struct Parsed19 { public init() {}
    // the unit spells `Status19` only as the MEMBER of `Resp19.Status19` (a static call); the construction is an implicit member with the
    // contextual type Resp19.Status19 (the parameter type of Resp19.init(status:))
    public func resp_init(_ p: String) -> Resp19 { if !Resp19.Status19.isValid(p) { fatalError() }; return Resp19(status: .init(code: 1, path: p)) }   // WRITES
    public func resp_make(_ p: String) -> Resp19 { if !Resp19.Status19.isValid(p) { fatalError() }; return Resp19(status: .make(p)) }               // WRITES
    public func resp_quiet(_ p: String) -> Resp19 { if !Resp19.Status19.isValid(p) { fatalError() }; return Resp19(status: .init(quiet: 1)) }       // pure twin
    public func resp_plain(_ p: String) -> Resp19 { Resp19(status: .init(code: 1, path: p)) }                                                       // WRITES (no other spelling of Status19)
}
