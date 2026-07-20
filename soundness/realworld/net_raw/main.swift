// Net driver: a RAW POSIX socket. Non-blocking so connect() fires the syscall immediately (no hang on the
// non-routable TEST-NET address) — the connect carries the marker IP. candor-swift classifies the 3-arg
// free connect() as Net (the wire-verb rung the dynamic oracle motivated). marker: 192.0.2.5
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
func connectRaw() {
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(80).bigEndian
    _ = "192.0.2.5".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
    _ = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    close(fd)
}
connectRaw()
