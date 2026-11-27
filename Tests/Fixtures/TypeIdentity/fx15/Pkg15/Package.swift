// swift-tools-version:5.9
import PackageDescription
// attack on the round-2 strip's exclusion: an OWN MODULE (`Own15`) whose name is also a scan TOP-LEVEL TYPE in another target (Core15)
let package = Package(name: "Pkg15", products: [.library(name: "Own15", targets: ["Own15"])], targets: [.target(name: "Core15"), .target(name: "Own15")])
