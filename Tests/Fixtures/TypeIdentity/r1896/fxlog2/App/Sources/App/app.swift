import Foundation
import Logging
public struct Svc {
    public var logger = Logging.Logger(label: "fable.r1896")          // UNANNOTATED, two-segment imported Module.Type()
    public var alog: Logging.Logger = Logging.Logger(label: "fable.a") // ANNOTATED control
    public init() {}
    public func c_log(_ m: String) { logger.info("\(m)") }             // executes: writes the line to stdout
    public func c_alog(_ m: String) { alog.info("\(m)") }
    public func c_local(_ m: String) { let l = Logging.Logger(label: "fable.l"); l.info("\(m)") }
}
