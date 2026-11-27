// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Pkg20", products: [.library(name: "Own20", targets: ["Own20"])], targets: [.target(name: "Own20"), .target(name: "Gen20")])
