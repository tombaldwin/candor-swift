// Non-syscall RECALL corpus — the effects strace can't distinguish from ordinary fd/register ops
// (Ipc/Log/Rand/Env/Clock). Ground truth = documented API semantics (expected.json), checked by recall.sh
// against candor-swift's static prediction. candor-swift is syntactic, so this needs no strace — like rust's
// soundness/realworld/recall. Ipc is the headline (matches rust's ipc_unix); the rest give recall breadth.
import Foundation

func ipc_pipe() { _ = Pipe() }                               // constructs an OS pipe → Ipc
func log_nslog() { NSLog("candor recall marker") }           // unified log / ASL → Log
func rand_uuid() { _ = UUID() }                              // draws v4 entropy → Rand
func env_read() { _ = ProcessInfo.processInfo.environment }  // reads the process environment → Env
func clock_now() { _ = Date() }                              // reads the wall clock → Clock
