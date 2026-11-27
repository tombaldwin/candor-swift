import Foundation
// Foundation is the only import: bare `Data`, `URL`, `Result` are the PLATFORM's. Core9 / Gen9 are not imported.
public struct U9 { public init() {}
    // S1 x S12: Core9 declares a top-level `Data`; this file cannot see it
    public func s1s12_ann(_ p: String) throws { let d: Data = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) }
    public func s1s12_ctor(_ p: String) throws { let d = Data("x".utf8); try d.write(to: URL(fileURLWithPath: p)) }
    public func s1s12_inline(_ p: String) throws { try Data("x".utf8).write(to: URL(fileURLWithPath: p)) }
    // S12 x URL: `checkResourceIsReachable()` is a stat; on a missing path the PLATFORM's throws (the scan types' return true)
    public func s12_url_ann(_ p: String) -> Bool { let u: URL = URL(fileURLWithPath: p); return (try? u.checkResourceIsReachable()) == nil }
    public func s12_url_ctor(_ p: String) -> Bool { let u = URL(fileURLWithPath: p); return (try? u.checkResourceIsReachable()) == nil }
    // S12 x Result: Gen9's nested `Result` has a LOUD get(); Swift.Result.get() is pure (executed: no marker). A REMOVAL cell.
    public func s12_result_get() -> Int { let r: Result<Int, Error> = .success(1); return (try? r.get()) ?? 0 }
}
