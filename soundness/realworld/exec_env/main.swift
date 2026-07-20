// Exec: Process with a set environment → child execve (openat marker via redirect). marker: /tmp/candor-oracle-swift-execenv
import Foundation
func run() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "echo x > /tmp/candor-oracle-swift-execenv"]
    p.environment = ["CANDOR_MARK": "1"]
    try? p.run(); p.waitUntilExit()
}
run()
