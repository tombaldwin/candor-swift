// Fs recall driver: write a marker file with Foundation (non-atomic → opens the marker path directly, so
// the openat carries the marker). candor-swift must predict Fs. marker: /tmp/candor-oracle-swift-fs-write
import Foundation

func writeMarker() {
    try? "candor".write(toFile: "/tmp/candor-oracle-swift-fs-write", atomically: false, encoding: .utf8)
}

writeMarker()
