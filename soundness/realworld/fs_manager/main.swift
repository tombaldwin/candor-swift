// Fs driver: FileManager creates/removes a file → Fs (openat/unlink). candor→Fs. marker: /tmp/candor-oracle-swift-fm
import Foundation
func manage() {
    FileManager.default.createFile(atPath: "/tmp/candor-oracle-swift-fm", contents: Data([9]))
    try? FileManager.default.removeItem(atPath: "/tmp/candor-oracle-swift-fm")
}
manage()
