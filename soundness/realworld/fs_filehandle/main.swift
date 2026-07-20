// Fs driver: FileHandle opens an fd on the marker path (openat). candor→Fs. marker: /tmp/candor-oracle-swift-fh
import Foundation
func openHandle() {
    FileManager.default.createFile(atPath: "/tmp/candor-oracle-swift-fh", contents: nil)
    let h = FileHandle(forWritingAtPath: "/tmp/candor-oracle-swift-fh")
    try? h?.write(contentsOf: Data([1,2,3]))
    try? h?.close()
}
openHandle()
