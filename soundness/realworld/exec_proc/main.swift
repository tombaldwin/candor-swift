// Exec recall driver: spawn a subprocess. The kernel shows an execve carrying the marker arg iff it RAN;
// candor-swift must predict Exec. marker: candor-oracle-swift-exec
import Foundation

func spawn() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/echo")
    p.arguments = ["candor-oracle-swift-exec"]
    try? p.run()
    p.waitUntilExit()
}

spawn()
