import Foundation
public protocol LogHandler { func log(_ level: Int, _ message: String) }
/// Counts the lines it was asked to emit, so the Run package can observe "this cell logged" without parsing stdout.
public struct StreamLogHandler: LogHandler { public init() {}
    nonisolated(unsafe) public static var emitted = 0
    public func log(_ level: Int, _ message: String) { StreamLogHandler.emitted += 1; FileHandle.standardError.write((message + "\n").data(using: .utf8)!) } }
public struct Logger {
    public let label: String
    var handler: LogHandler
    public init(label: String) { self.label = label; self.handler = StreamLogHandler() }
    public func info(_ message: @autoclosure () -> String) { handler.log(2, "\(label): \(message())") }
}
