// Exec recall driver: spawn a subprocess (Foundation Process → Exec). The child (/bin/sh, always present)
// opens a marker path via a redirect, so the openat on that path in the CHILD proves the subprocess RAN —
// more robust than matching argv inside the parent's execve (Process routes through posix_spawn on Linux).
// candor-swift must predict Exec. marker: /tmp/candor-oracle-swift-exec-ran
import Foundation

func spawn() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "echo ran > /tmp/candor-oracle-swift-exec-ran"]
    try? p.run()
    p.waitUntilExit()
}

spawn()
