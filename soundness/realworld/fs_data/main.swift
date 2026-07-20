// Fs: Data(contentsOf: fileURL) reads a file → openat. marker: /tmp/candor-oracle-swift-data
import Foundation
func readData() { _ = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/candor-oracle-swift-data")) }
readData()
