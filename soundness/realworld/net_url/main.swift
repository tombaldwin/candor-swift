// Net recall driver: a URLSession request to a TEST-NET-1 address (RFC 5737, 192.0.2.0/24 — never routed,
// so nothing leaves the host but the connect() syscall fires). The kernel shows a connect to the marker
// IP iff Net RAN; candor-swift must predict Net. A short timeout keeps CI from hanging. marker: 192.0.2.1
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func fetch() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 2
    cfg.timeoutIntervalForResource = 2
    let session = URLSession(configuration: cfg)
    let sem = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: URL(string: "http://192.0.2.1/")!) { _, _, _ in sem.signal() }
    task.resume()
    _ = sem.wait(timeout: .now() + 4)
}

fetch()
