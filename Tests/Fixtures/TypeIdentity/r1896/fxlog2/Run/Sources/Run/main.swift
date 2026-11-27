import Foundation
import App
import Logging
// `argv[1]` is accepted for the shared exec protocol and unused: the effect observed here is a log line, not a file.
func cell(_ n: String, _ f: () -> Void) {
    let before = StreamLogHandler.emitted; f()
    print(n, StreamLogHandler.emitted > before ? "LOGS" : "pure")
}
let s = Svc()
cell("Svc.c_log") { s.c_log("MARK-c_log") }
cell("Svc.c_alog") { s.c_alog("MARK-c_alog") }
cell("Svc.c_local") { s.c_local("MARK-c_local") }
