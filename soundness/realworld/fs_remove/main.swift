// Fs: FileManager.removeItem → unlink on the marker path. marker: /tmp/candor-oracle-swift-rm
import Foundation
func remove() {
    FileManager.default.createFile(atPath: "/tmp/candor-oracle-swift-rm", contents: nil)
    try? FileManager.default.removeItem(atPath: "/tmp/candor-oracle-swift-rm")
}
remove()
