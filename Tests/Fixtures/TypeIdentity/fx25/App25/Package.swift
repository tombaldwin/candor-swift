// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "App25", products: [.library(name: "Feat25", targets: ["Feat25"])],
    dependencies: [.package(path: "../DepA"), .package(path: "../DepB")],
    targets: [.target(name: "Feat25", dependencies: [.product(name: "DepA", package: "DepA"), .product(name: "DepB", package: "DepB")])])
