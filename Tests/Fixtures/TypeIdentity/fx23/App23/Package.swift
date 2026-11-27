// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "App23", products: [.library(name: "Feat23", targets: ["Feat23"])],
    dependencies: [.package(path: "../DepA"), .package(path: "../DepB")],
    targets: [.target(name: "Core23"),
              .target(name: "Feat23", dependencies: [.product(name: "DepA", package: "DepA"), .product(name: "DepB", package: "DepB"), "Core23"])])
