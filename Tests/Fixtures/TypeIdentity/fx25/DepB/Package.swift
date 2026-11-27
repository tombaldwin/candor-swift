// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "DepB", products: [.library(name: "DepB", targets: ["DepB"])], dependencies: [.package(path: "../DepA")],
    targets: [.target(name: "DepB", dependencies: [.product(name: "DepA", package: "DepA")])])
