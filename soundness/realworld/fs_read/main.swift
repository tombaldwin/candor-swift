// Fs recall driver: read a marker file with Foundation. The kernel shows an openat on the marker path
// iff the read RAN; candor-swift must predict Fs (or disclose uncertainty). marker: /tmp/candor-oracle-swift-fs-read
import Foundation

func readMarker() {
    _ = try? String(contentsOfFile: "/tmp/candor-oracle-swift-fs-read", encoding: .utf8)
}

readMarker()
