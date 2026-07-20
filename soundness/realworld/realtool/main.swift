// A REALISTIC multi-effect tool (not a single-effect driver): load a config, read an env var, run a build
// step, write a log — the mixed-effect call structure real Swift CLIs have. The oracle checks MULTIPLE
// effects at once: Fs (writeLog opens the log path) and Exec (runStep's child shell opens the step path).
// candor predicts loadConfig→Fs, runStep→Exec, writeLog→Fs, home→Env (Env is recall-tier, not strace-visible).
import Foundation
struct Tool {
    let configPath: String
    func loadConfig() -> String? { try? String(contentsOfFile: configPath, encoding: .utf8) }        // Fs
    func home() -> String? { ProcessInfo.processInfo.environment["HOME"] }                            // Env
    func runStep(_ cmd: String) {                                                                     // Exec
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try? p.run(); p.waitUntilExit()
    }
    func writeLog(_ msg: String) { try? msg.write(toFile: "/tmp/realtool-log", atomically: false, encoding: .utf8) } // Fs
    func perform() {
        _ = loadConfig(); _ = home()
        runStep("echo step > /tmp/realtool-step")
        writeLog("done")
    }
}
Tool(configPath: "/tmp/realtool-config").perform()
