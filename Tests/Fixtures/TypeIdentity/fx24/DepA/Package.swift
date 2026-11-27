// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "DepA", products: [.library(name: "DepA", targets: ["DepA"])], targets: [.target(name: "DepA")])
