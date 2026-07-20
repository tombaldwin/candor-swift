// Fs: FileHandle(forReadingAtPath:) opens an fd for read → openat. marker: /tmp/candor-oracle-swift-fhr
import Foundation
func readHandle() {
    FileManager.default.createFile(atPath: "/tmp/candor-oracle-swift-fhr", contents: nil)
    let h = FileHandle(forReadingAtPath: "/tmp/candor-oracle-swift-fhr")
    _ = try? h?.readToEnd(); try? h?.close()
}
readHandle()
