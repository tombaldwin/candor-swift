// Exec driver: capture a subprocess's output through a Pipe. candor→Exec (Process) + Ipc (Pipe). The child
// (/bin/sh) opens a marker path via a redirect → openat proves it ran. marker: /tmp/candor-oracle-swift-exec-pipe
import Foundation
func capture() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "echo hi > /tmp/candor-oracle-swift-exec-pipe; echo hi"]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    _ = try? out.fileHandleForReading.readToEnd()
    p.waitUntilExit()
}
capture()
